// IntegrityReport.swift
// The report Verify Catalog leaves behind (docs/design/integrity_first_2026_10_16.md
// §4): `integrity-latest.json` beside catalog.json plus a dated copy
// `integrity-<ISO date>.json` (one per day; a later run the same day
// replaces it). Per tier 0–6: name, when and by which run it was verified,
// the result, the counts, how long; then the findings (capped at
// `findingsCap`, with the true total). Catalog Status reads the latest
// through `IntegrityReportFacts`.
//
// Written ONLY through AtomicFilePublish (MOPS-15). Read with a STRICT
// reader: a missing file is "never run"; garbage, a newer schema or an
// unreadable file is `.unreadable(why)` — the row says so and nothing
// crashes, nothing is written over it.
//
// "Keep the last 30" (the design): this slice writes the dated copies and
// never deletes one — the lane's one write is the report (MOPS-15), and a
// prune is a delete. At ≤ 1 MB a day they are bounded by the calendar, not
// by this code; see the handoff report.
//
// (For Rick: `IntegrityTierResult` is a tagged union with a hand-written
// JSON shape — `{"kind":"needsDecision","count":3}` — instead of Swift's
// synthesized `{"needsDecision":{"_0":3}}`, so the file reads well.)

import Foundation
import VideoScanCore

// MARK: - Values

/// How one tier ended.
enum IntegrityTierResult: Equatable, Sendable {
    case ok
    case needsDecision(Int)
    case couldNotCheck(Int)
    case notRun(String)

    var words: String {
        switch self {
        case .ok: return "ok"
        case .needsDecision(let n): return "\(n.formatted()) need\(n == 1 ? "s" : "") a decision"
        case .couldNotCheck(let n): return "\(n.formatted()) could not be checked"
        case .notRun(let why): return "not run — \(why)"
        }
    }

    var isNotRun: Bool {
        if case .notRun = self { return true }
        return false
    }
}

extension IntegrityTierResult: Codable {
    private enum Kind: String, Codable { case ok, needsDecision, couldNotCheck, notRun }
    private enum CodingKeys: String, CodingKey { case kind, count, words }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .ok: self = .ok
        case .needsDecision: self = .needsDecision(try c.decode(Int.self, forKey: .count))
        case .couldNotCheck: self = .couldNotCheck(try c.decode(Int.self, forKey: .count))
        case .notRun: self = .notRun(try c.decode(String.self, forKey: .words))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ok:
            try c.encode(Kind.ok, forKey: .kind)
        case .needsDecision(let n):
            try c.encode(Kind.needsDecision, forKey: .kind)
            try c.encode(n, forKey: .count)
        case .couldNotCheck(let n):
            try c.encode(Kind.couldNotCheck, forKey: .kind)
            try c.encode(n, forKey: .count)
        case .notRun(let why):
            try c.encode(Kind.notRun, forKey: .kind)
            try c.encode(why, forKey: .words)
        }
    }
}

/// One tier's line in the report.
struct IntegrityTier: Codable, Equatable, Sendable, Identifiable {
    var tier: Int
    var name: String
    /// When this tier was last verified; nil when it was not run.
    var verifiedAt: Date?
    /// The run that verified it; nil when another job's record stands in
    /// (tier 0 reads the audit's marker) or it was not run.
    var runID: UUID?
    var result: IntegrityTierResult
    var checked = 0
    var passed = 0
    var needsDecision = 0
    var couldNotCheck = 0
    var elapsedSeconds: Double = 0
    /// One short line in family words ("3 rows share a path").
    var summary: String

    var id: Int { tier }

    init(tier: Int, name: String, verifiedAt: Date? = nil, runID: UUID? = nil, result: IntegrityTierResult,
         checked: Int = 0, passed: Int = 0, needsDecision: Int = 0, couldNotCheck: Int = 0,
         elapsedSeconds: Double = 0, summary: String) {
        self.tier = tier
        self.name = name
        self.verifiedAt = verifiedAt
        self.runID = runID
        self.result = result
        self.checked = checked
        self.passed = passed
        self.needsDecision = needsDecision
        self.couldNotCheck = couldNotCheck
        self.elapsedSeconds = elapsedSeconds
        self.summary = summary
    }
}

/// One finding, as written to the file (and shown in the detail view).
struct IntegrityFinding: Codable, Equatable, Sendable {
    var tier: Int
    /// `CatalogConstraints.Rule.rawValue`, or a tier's own rule name.
    var rule: String
    var recordID: UUID?
    var filename: String?
    var words: String
    var needsDecision: Bool
}

struct IntegrityReport: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable { case completed, stopped, failed }

    static let currentSchemaVersion = 1
    /// Findings kept in the file and in memory; `findingsTotal` keeps the truth.
    static let findingsCap = 5_000

    var schemaVersion: Int = IntegrityReport.currentSchemaVersion
    var runID: UUID
    var startedAt: Date
    /// When the run COMPLETED every tier; nil for a stopped or failed run.
    var verifiedAt: Date?
    var outcome: Outcome
    var catalogFile: String
    var catalogGeneration: Int?
    var catalogSHA256: String?
    var catalogByteCount: Int64?
    var rowsTotal: Int
    var rowsLive: Int
    var elapsedSeconds: Double
    var tiers: [IntegrityTier]
    var findings: [IntegrityFinding]
    var findingsTotal: Int

    init(runID: UUID, startedAt: Date, verifiedAt: Date? = nil, outcome: Outcome, catalogFile: String,
         catalogGeneration: Int? = nil, catalogSHA256: String? = nil, catalogByteCount: Int64? = nil,
         rowsTotal: Int, rowsLive: Int, elapsedSeconds: Double, tiers: [IntegrityTier],
         findings: [IntegrityFinding], findingsTotal: Int) {
        self.runID = runID
        self.startedAt = startedAt
        self.verifiedAt = verifiedAt
        self.outcome = outcome
        self.catalogFile = catalogFile
        self.catalogGeneration = catalogGeneration
        self.catalogSHA256 = catalogSHA256
        self.catalogByteCount = catalogByteCount
        self.rowsTotal = rowsTotal
        self.rowsLive = rowsLive
        self.elapsedSeconds = elapsedSeconds
        self.tiers = tiers
        self.findings = findings
        self.findingsTotal = findingsTotal
    }

    func tier(_ n: Int) -> IntegrityTier? { tiers.first { $0.tier == n } }

    /// The chip's red: decisions pending across every tier.
    var needsDecisionTotal: Int { tiers.reduce(0) { $0 + $1.needsDecision } }
    var couldNotCheckTotal: Int { tiers.reduce(0) { $0 + $1.couldNotCheck } }

    /// The band's words: the tiers with decisions pending, worst first,
    /// each in its own summary ("3 rows share a path · 519 headers say
    /// sound the print never heard"). nil when nothing is pending.
    var decisionWords: String? {
        let pending = tiers.filter { $0.needsDecision > 0 }.sorted { $0.needsDecision > $1.needsDecision }
        guard !pending.isEmpty else { return nil }
        return pending.map(\.summary).joined(separator: " · ")
    }

    /// The OUTCOME line's tally.
    var outcomeLine: String {
        let ran = tiers.filter { !$0.result.isNotRun }.count
        var s = "\(needsDecisionTotal.formatted()) finding(s) need a decision across \(ran) tier(s) run"
        if couldNotCheckTotal > 0 { s += " · \(couldNotCheckTotal.formatted()) could not be checked" }
        if findingsTotal > findings.count { s += " · \(findings.count.formatted()) of \(findingsTotal.formatted()) findings kept in the report" }
        return s
    }
}

// MARK: - Store (the one writer, the strict reader)

enum IntegrityReportStore {

    static let latestFileName = "integrity-latest.json"
    /// The design's history depth; see the file header for why no prune.
    static let datedCopiesKept = 30

    static func latestURL(besideCatalogAt catalogFile: URL) -> URL {
        catalogFile.deletingLastPathComponent().appendingPathComponent(latestFileName)
    }

    /// "integrity-2026-10-16.json" — the calendar date where Rick is.
    static func datedFileName(for date: Date, calendar: Calendar = .current) -> String {
        let p = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "integrity-%04d-%02d-%02d.json", p.year ?? 0, p.month ?? 0, p.day ?? 0)
    }

    /// Publish the report beside the catalog: the latest, then the dated
    /// copy. Throws the first failure (the latest is tried first, so a
    /// thrown error means nothing landed for this run).
    @discardableResult
    static func write(_ report: IntegrityReport, besideCatalogAt catalogFile: URL, now: Date = Date()) throws -> (latest: URL, dated: URL) {
        let data = try encoder.encode(report)
        let folder = catalogFile.deletingLastPathComponent()
        let latest = folder.appendingPathComponent(latestFileName)
        let dated = folder.appendingPathComponent(datedFileName(for: now))
        try AtomicFilePublish.write(data, to: latest, durability: .fullFsync, createIntermediates: false)
        try AtomicFilePublish.write(data, to: dated, durability: .fast, createIntermediates: false)
        return (latest, dated)
    }

    /// What the strict reader found.
    enum Read: Equatable, Sendable {
        case missing
        /// The file exists and cannot be used — why, in words.
        case unreadable(String)
        case report(IntegrityReport)

        var report: IntegrityReport? {
            if case .report(let r) = self { return r }
            return nil
        }
    }

    static func read(besideCatalogAt catalogFile: URL) -> Read {
        let url = latestURL(besideCatalogAt: catalogFile)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else { return .unreadable("the file could not be read") }
        return read(data: data)
    }

    /// Strict: the whole file decodes at this build's schema, or it is
    /// unreadable. Never a crash, never a partial report.
    static func read(data: Data) -> Read {
        guard let probe = try? decoder.decode(SchemaProbe.self, from: data) else {
            return .unreadable("not readable as an integrity report")
        }
        if probe.schemaVersion > IntegrityReport.currentSchemaVersion {
            return .unreadable("written by a newer VideoScan (schema \(probe.schemaVersion)) — not read")
        }
        guard let report = try? decoder.decode(IntegrityReport.self, from: data) else {
            return .unreadable("the report is damaged — the next run replaces it")
        }
        return .report(report)
    }

    private struct SchemaProbe: Decodable { let schemaVersion: Int }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

// MARK: - Facts for Catalog Status (pure)

/// What the Integrity row of Catalog Status reads off the latest report.
struct IntegrityReportFacts: Sendable, Equatable {
    var lastCompleted: Date?
    var outcome: FreshnessRow.Outcome = .neverRan
    /// The sum of needs-a-decision counts across tiers.
    var needsDecision = 0
    /// The report exists but cannot be read — the row's red words.
    var problem: String?
    /// The tiers with decisions pending, worst first (IntegrityReport.decisionWords).
    var decisionWords: String?

    init(lastCompleted: Date? = nil, outcome: FreshnessRow.Outcome = .neverRan, needsDecision: Int = 0,
         problem: String? = nil, decisionWords: String? = nil) {
        self.lastCompleted = lastCompleted
        self.outcome = outcome
        self.needsDecision = needsDecision
        self.problem = problem
        self.decisionWords = decisionWords
    }

    static func from(_ read: IntegrityReportStore.Read) -> IntegrityReportFacts {
        switch read {
        case .missing:
            return IntegrityReportFacts()
        case .unreadable(let why):
            return IntegrityReportFacts(problem: "\(IntegrityReportStore.latestFileName) can't be read: \(why)")
        case .report(let r):
            return from(report: r)
        }
    }

    static func from(report r: IntegrityReport) -> IntegrityReportFacts {
        var f = IntegrityReportFacts(needsDecision: r.needsDecisionTotal, decisionWords: r.decisionWords)
        switch r.outcome {
        case .completed:
            f.outcome = .ok
            f.lastCompleted = r.verifiedAt
        case .stopped:
            f.outcome = .partial
        case .failed:
            f.outcome = .failed
        }
        return f
    }
}
