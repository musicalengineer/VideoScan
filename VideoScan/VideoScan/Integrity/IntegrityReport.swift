// IntegrityReport.swift
// The report Verify Catalog leaves behind (docs/design/integrity_first_2026_10_16.md
// §4): `integrity-latest.json` beside catalog.json plus a dated copy
// `integrity-<ISO date>.json` (one per day; a later run the same day
// replaces it). Per tier 0–6: name, when and by which run it was verified,
// the result, the counts, how long; then the findings (capped at
// `findingsCap`, with the true total). Catalog Status reads the latest
// through `IntegrityReportFacts`.
//
// SCHEMA 2 (codex, Verify Catalog slice 1): the report says which catalog
// GENERATION its findings describe (`snapshotGeneration`), whether the
// file on disk had moved on by the time it was hashed
// (`catalogChangedDuringRun`), and whether the recorded hash is CERTIFIED
// — the file's generation equals the snapshot's — or merely recorded. A
// schema-1 file (none of the three) still reads: nothing certified.
//
// Written ONLY through AtomicFilePublish (MOPS-15), the DATED copy first:
// the latest is what Catalog Status reads, so it moves only once the day's
// copy has landed; if either write fails the previous latest stands and the
// job says Failed. Read with a STRICT reader: a missing file is "never
// run"; garbage, a newer schema or an unreadable file is `.unreadable(why)`
// — the row says so and nothing crashes, nothing is written over it.
//
// "Keep the last 30" (the design): this slice writes the dated copies and
// never deletes one — the lane's one write is the report (MOPS-15), and a
// prune is a delete. At ≤ 1 MB a day they are bounded by the calendar, not
// by this code; see the handoff report.
//
// (For Rick: `IntegrityTierResult` is a tagged union with a hand-written
// JSON shape — `{"kind":"needsDecision","count":3}` — instead of Swift's
// synthesized `{"needsDecision":{"_0":3}}`, so the file reads well.
// `IntegrityReport.init(from:)` is hand-written only to default the three
// schema-2 keys when a schema-1 file lacks them — `decodeIfPresent` ≈ a
// field with a default in a versioned struct.)

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
    /// Tier 5 only (QA 2026-10-20): of `couldNotCheck`, the part that is
    /// the catalog file itself — catalog.sqlite's generation could not be
    /// read, or catalog.json could not be hashed (0 or 1). Carried
    /// explicitly so the band never derives it from kept findings, which
    /// the findings cap can drop. nil = not said (another tier, or a report
    /// written before 2026-10-20 — decoded as absent; additive key).
    var catalogFileUnchecked: Int?

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

    /// "tier 1 File identity".
    var label: String { "tier \(tier) \(name)" }
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

    static let currentSchemaVersion = 2
    /// Findings kept in the file and in memory; `findingsTotal` keeps the truth.
    static let findingsCap = 5_000

    var schemaVersion: Int = IntegrityReport.currentSchemaVersion
    var runID: UUID
    var startedAt: Date
    /// When the run COMPLETED every tier; nil for a stopped or failed run.
    var verifiedAt: Date?
    var outcome: Outcome
    var catalogFile: String
    /// The generation the ROWS came from — what the findings describe.
    var snapshotGeneration: Int?
    /// The generation in the FILE that was hashed.
    var catalogGeneration: Int?
    var catalogSHA256: String?
    var catalogByteCount: Int64?
    /// The file's generation is not the snapshot's: a save landed during
    /// the run. The findings stand for `snapshotGeneration`; run again.
    var catalogChangedDuringRun = false
    /// `catalogSHA256` was taken from a file carrying exactly the
    /// snapshot's generation. False when there is no hash, the file has no
    /// generation, or the generation moved.
    var catalogHashCertified = false
    var rowsTotal: Int
    var rowsLive: Int
    var elapsedSeconds: Double
    var tiers: [IntegrityTier]
    var findings: [IntegrityFinding]
    var findingsTotal: Int

    init(runID: UUID, startedAt: Date, verifiedAt: Date? = nil, outcome: Outcome, catalogFile: String,
         snapshotGeneration: Int? = nil, catalogGeneration: Int? = nil, catalogSHA256: String? = nil,
         catalogByteCount: Int64? = nil, catalogChangedDuringRun: Bool = false, catalogHashCertified: Bool = false,
         rowsTotal: Int, rowsLive: Int, elapsedSeconds: Double, tiers: [IntegrityTier],
         findings: [IntegrityFinding], findingsTotal: Int) {
        self.runID = runID
        self.startedAt = startedAt
        self.verifiedAt = verifiedAt
        self.outcome = outcome
        self.catalogFile = catalogFile
        self.snapshotGeneration = snapshotGeneration
        self.catalogGeneration = catalogGeneration
        self.catalogSHA256 = catalogSHA256
        self.catalogByteCount = catalogByteCount
        self.catalogChangedDuringRun = catalogChangedDuringRun
        self.catalogHashCertified = catalogHashCertified
        self.rowsTotal = rowsTotal
        self.rowsLive = rowsLive
        self.elapsedSeconds = elapsedSeconds
        self.tiers = tiers
        self.findings = findings
        self.findingsTotal = findingsTotal
    }

    /// Schema 1 lacked the three generation keys: they default to
    /// "unknown / not certified". Every other key is required as before.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        runID = try c.decode(UUID.self, forKey: .runID)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        verifiedAt = try c.decodeIfPresent(Date.self, forKey: .verifiedAt)
        outcome = try c.decode(Outcome.self, forKey: .outcome)
        catalogFile = try c.decode(String.self, forKey: .catalogFile)
        snapshotGeneration = try c.decodeIfPresent(Int.self, forKey: .snapshotGeneration)
        catalogGeneration = try c.decodeIfPresent(Int.self, forKey: .catalogGeneration)
        catalogSHA256 = try c.decodeIfPresent(String.self, forKey: .catalogSHA256)
        catalogByteCount = try c.decodeIfPresent(Int64.self, forKey: .catalogByteCount)
        catalogChangedDuringRun = try c.decodeIfPresent(Bool.self, forKey: .catalogChangedDuringRun) ?? false
        catalogHashCertified = try c.decodeIfPresent(Bool.self, forKey: .catalogHashCertified) ?? false
        rowsTotal = try c.decode(Int.self, forKey: .rowsTotal)
        rowsLive = try c.decode(Int.self, forKey: .rowsLive)
        elapsedSeconds = try c.decode(Double.self, forKey: .elapsedSeconds)
        tiers = try c.decode([IntegrityTier].self, forKey: .tiers)
        findings = try c.decode([IntegrityFinding].self, forKey: .findings)
        findingsTotal = try c.decode(Int.self, forKey: .findingsTotal)
    }

    func tier(_ n: Int) -> IntegrityTier? { tiers.first { $0.tier == n } }

    /// The tiers this build evaluates, in tier order (the verdict's input).
    var builtTiers: [IntegrityTier] {
        tiers.filter { VerifyCatalogTiers.builtTiers.contains($0.tier) }.sorted { $0.tier < $1.tier }
    }

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

    /// "findings describe generation 10; the file on disk is generation 11
    /// — run again" when the catalog changed during the run; else nil.
    var generationMismatchWords: String? {
        guard catalogChangedDuringRun, let snapshot = snapshotGeneration else { return nil }
        return VerifyCatalogTiers.generationMismatch(snapshot: snapshot, file: catalogGeneration)
    }

    /// The OUTCOME line's tally.
    var outcomeLine: String {
        let ran = tiers.filter { !$0.result.isNotRun }.count
        var s = "\(needsDecisionTotal.formatted()) finding(s) need a decision across \(ran) tier(s) run"
        if couldNotCheckTotal > 0 { s += " · \(couldNotCheckTotal.formatted()) could not be checked" }
        if findingsTotal > findings.count { s += " · \(findings.count.formatted()) of \(findingsTotal.formatted()) findings kept in the report" }
        if let mismatch = generationMismatchWords { s += " · \(mismatch)" }
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

    /// Publish the report beside the catalog: the DATED copy first, and
    /// only when it landed, the latest (what Catalog Status reads, synced
    /// to disk). Throws the first failure; a thrown error means the
    /// previous latest still stands, whatever happened to the dated copy.
    @discardableResult
    static func write(_ report: IntegrityReport, besideCatalogAt catalogFile: URL, now: Date = Date()) throws -> (latest: URL, dated: URL) {
        let data = try encoder.encode(report)
        let folder = catalogFile.deletingLastPathComponent()
        let latest = folder.appendingPathComponent(latestFileName)
        let dated = folder.appendingPathComponent(datedFileName(for: now))
        try AtomicFilePublish.write(data, to: dated, durability: .fast, createIntermediates: false)
        try AtomicFilePublish.write(data, to: latest, durability: .fullFsync, createIntermediates: false)
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

    /// Strict: the whole file decodes at this build's schema (or an older
    /// one it still understands), or it is unreadable. Never a crash,
    /// never a partial report.
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

/// What the Integrity row of Catalog Status reads off the latest report —
/// derived from the BUILT tiers only (codex, slice 1, P1: a completed run
/// must not read "current" while a built tier could not check, was not
/// run, or is older than its day).
struct IntegrityReportFacts: Sendable, Equatable {
    /// The OLDEST built tier's verified-at (tier 0 stands on the audit's
    /// own date), so the day's cadence judges the stalest tier. nil unless
    /// the run completed.
    var lastCompleted: Date?
    var outcome: FreshnessRow.Outcome = .neverRan
    /// The sum of needs-a-decision counts across the built tiers.
    var needsDecision = 0
    /// Rows some built tier could not verify — the largest single gap (a
    /// tier not run counts every live row); 0 when every built tier is ok.
    var unverified = 0
    /// The gaps, each naming its tier ("tier 1 File identity: 660 files
    /// still have only a sampled hash — Fill In Full Hashes"); nil = none.
    var unverifiedWords: String?
    /// Said whatever the colour: which tier the date is (when the built
    /// tiers' dates differ) and which tiers are not built.
    var note: String?
    /// The report exists but cannot be read — the row's red words.
    var problem: String?
    /// The tiers with decisions pending, worst first (IntegrityReport.decisionWords).
    var decisionWords: String?
    /// The report was made from catalog.json before the switch to SQLite
    /// (`CatalogFreshnessFactsReader.predatesSwitch`): it says nothing
    /// about the catalog in use — no decision, no date, every row unverified.
    var predatesSwitch = false
    /// The report's findings and gaps sorted into break / unsettled /
    /// review / information for the band (Rick 2026-10-20). Empty unless a
    /// report of THIS catalog was read.
    var reality = IntegrityRealityFacts()

    init(lastCompleted: Date? = nil, outcome: FreshnessRow.Outcome = .neverRan, needsDecision: Int = 0,
         unverified: Int = 0, unverifiedWords: String? = nil, note: String? = nil,
         problem: String? = nil, decisionWords: String? = nil, predatesSwitch: Bool = false) {
        self.lastCompleted = lastCompleted
        self.outcome = outcome
        self.needsDecision = needsDecision
        self.unverified = unverified
        self.unverifiedWords = unverifiedWords
        self.note = note
        self.problem = problem
        self.decisionWords = decisionWords
        self.predatesSwitch = predatesSwitch
    }

    /// `switchedAt` = when `catalog.cutover` says the catalog switched to
    /// SQLite (nil = no switch): a report whose run STARTED before it is
    /// catalog.json's, not this catalog's.
    static func from(_ read: IntegrityReportStore.Read, switchedAt: Date? = nil) -> IntegrityReportFacts {
        switch read {
        case .missing:
            return IntegrityReportFacts()
        case .unreadable(let why):
            return IntegrityReportFacts(problem: "\(IntegrityReportStore.latestFileName) can't be read: \(why)")
        case .report(let r):
            if CatalogFreshnessFactsReader.predatesSwitch(r.startedAt, switchedAt: switchedAt) {
                return IntegrityReportFacts(predatesSwitch: true)
            }
            return from(report: r)
        }
    }

    static func from(report r: IntegrityReport) -> IntegrityReportFacts {
        let built = r.builtTiers
        var f = IntegrityReportFacts(needsDecision: built.reduce(0) { $0 + $1.needsDecision }, decisionWords: r.decisionWords)
        f.note = note(for: r)
        f.reality = IntegrityRealityFacts.from(report: r)
        switch r.outcome {
        case .failed:
            f.outcome = .failed
            return f
        case .stopped:
            f.outcome = .partial
        case .completed:
            f.outcome = .ok
            f.lastCompleted = oldest(built)?.verifiedAt
        }
        var gaps = built.compactMap { gap($0, rowsLive: r.rowsLive) }
        if let mismatch = r.generationMismatchWords {
            gaps.append((max(1, r.rowsLive), "the catalog changed during the run: \(mismatch)"))
        }
        f.unverified = gaps.map(\.count).max() ?? 0
        f.unverifiedWords = gaps.isEmpty ? nil : gaps.map(\.words).joined(separator: " · ")
        return f
    }

    /// What one built tier leaves unverified, naming the tier; nil when it
    /// verified everything it was asked.
    static func gap(_ t: IntegrityTier, rowsLive: Int) -> (count: Int, words: String)? {
        switch t.result {
        case .notRun(let why):
            return (max(1, rowsLive), "\(t.label): not run — \(why)")
        case .couldNotCheck(let n):
            return (n, "\(t.label): \(t.summary)")
        case .ok, .needsDecision:
            return t.couldNotCheck > 0 ? (t.couldNotCheck, "\(t.label): \(t.couldNotCheck.formatted()) could not be checked") : nil
        }
    }

    /// The built tier with the oldest verified-at (among those that ran).
    static func oldest(_ built: [IntegrityTier]) -> IntegrityTier? {
        built.filter { $0.verifiedAt != nil }.min { ($0.verifiedAt ?? .distantPast) < ($1.verifiedAt ?? .distantPast) }
    }

    /// "oldest: tier 0 File presence · tiers 2 and 6 not built" — the first
    /// part only when the oldest built tier was verified by ANOTHER run
    /// (tier 0 stands on the audit's record) and is strictly older than
    /// the run's own tiers, so the row's date is named.
    static func note(for r: IntegrityReport) -> String? {
        var parts: [String] = []
        let built = r.builtTiers
        if let old = oldest(built), old.runID != r.runID,
           let newest = built.compactMap(\.verifiedAt).max(), (old.verifiedAt ?? newest) < newest {
            parts.append("oldest: \(old.label)")
        }
        let notBuilt = VerifyCatalogTiers.notBuiltTiers.filter { n in r.tier(n)?.result.isNotRun ?? true }
        if !notBuilt.isEmpty {
            let list = notBuilt.map(String.init).joined(separator: " and ")
            parts.append("tier\(notBuilt.count == 1 ? "" : "s") \(list) not built")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
