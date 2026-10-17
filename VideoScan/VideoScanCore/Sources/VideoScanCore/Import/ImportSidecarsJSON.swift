// ImportSidecarsJSON.swift
// The importer's own readings of the two gate files (contract §f "Inputs"):
//   * catalog-audit.json — `CatalogAuditRunRecord` (A/MediaOps/CatalogAuditRun.swift)
//     with A′'s per-row results; the contract adds, per non-present row, the
//     path it was judged at, and the run's `savedGeneration` (N1, F6);
//   * integrity-latest.json — `IntegrityReport` schema 2
//     (A/Integrity/IntegrityReport.swift:146).
// Both are Codable mirrors so the PoisonedCatalogFixture writes exactly what
// the importer reads. Pure: callers pass Data.
//
// (For Rick: two POD mirrors of the app's JSON files plus the few facts the
// gate needs from each.)

import Foundation

/// catalog-audit.json as the importer reads it.
public struct AuditMarkerJSON: Codable, Sendable, Equatable {

    /// One per-row result. `result` is kept as a word: a word outside the
    /// contract's six reads as "no result" (→ neverSeen), never as a guess.
    public struct Row: Codable, Sendable, Equatable {
        public var id: String
        public var result: String
        public var detail: String?
        /// The path the audit judged (N1: required unless present).
        public var judgedPath: String?
        public var seenOn: VideoRecordJSON.AuditSeenOnJSON?

        public init(id: String, result: String, detail: String? = nil, judgedPath: String? = nil,
                    seenOn: VideoRecordJSON.AuditSeenOnJSON? = nil) {
            self.id = id
            self.result = result
            self.detail = detail
            self.judgedPath = judgedPath
            self.seenOn = seenOn
        }
    }

    public var startedAt: CatalogJSONDate
    public var finishedAt: CatalogJSONDate?
    public var outcome: String
    public var partial: Bool
    public var counts: [String: Int]
    public var marked: Int
    public var rows: [Row]?
    public var savedGeneration: Int?

    public init(startedAt: CatalogJSONDate, finishedAt: CatalogJSONDate?, outcome: String, partial: Bool,
                counts: [String: Int], marked: Int, rows: [Row]?, savedGeneration: Int?) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outcome = outcome
        self.partial = partial
        self.counts = counts
        self.marked = marked
        self.rows = rows
        self.savedGeneration = savedGeneration
    }

    public static func decode(_ data: Data) throws -> AuditMarkerJSON {
        try JSONDecoder().decode(AuditMarkerJSON.self, from: data)
    }

    public var facts: ImportGate.AuditMarkerFacts {
        ImportGate.AuditMarkerFacts(outcome: outcome, partial: partial, startedAt: startedAt.unixSeconds,
                                    finishedAt: finishedAt?.unixSeconds, hasRowResults: rows != nil,
                                    savedGeneration: savedGeneration)
    }

    /// [startedAt, finishedAt]; an unfinished run's window ends at its start.
    public var window: ImportGate.AuditWindow {
        ImportGate.AuditWindow(startedAt: startedAt.unixSeconds,
                               finishedAt: finishedAt?.unixSeconds ?? startedAt.unixSeconds)
    }

    /// Canonical row id → its result (first answer wins; the reader refuses
    /// a duplicate elsewhere).
    public func evidenceByID() -> [String: ImportGate.AuditEvidence] {
        var out: [String: ImportGate.AuditEvidence] = [:]
        for row in rows ?? [] {
            let id = CatalogRecordDTO.canonicalID(row.id)
            guard out[id] == nil, let result = CatalogDDL.AuditResult(rawValue: row.result) else { continue }
            out[id] = ImportGate.AuditEvidence(result: result, judgedPath: row.judgedPath)
        }
        return out
    }
}

/// integrity-latest.json as the importer reads it (schema 2).
public struct IntegrityReportJSON: Codable, Sendable, Equatable {

    /// `IntegrityTierResult` (kind + count / words).
    public struct TierResult: Codable, Sendable, Equatable {
        public var kind: String
        public var count: Int?
        public var words: String?

        public init(kind: String, count: Int? = nil, words: String? = nil) {
            self.kind = kind
            self.count = count
            self.words = words
        }
    }

    public struct Tier: Codable, Sendable, Equatable {
        public var tier: Int
        public var name: String
        public var verifiedAt: CatalogJSONDate?
        public var runID: String?
        public var result: TierResult
        public var checked: Int?
        public var passed: Int?
        public var needsDecision: Int?
        public var couldNotCheck: Int?
        public var elapsedSeconds: Double?
        public var summary: String?

        public init(tier: Int, name: String, verifiedAt: CatalogJSONDate?, runID: String?, result: TierResult,
                    checked: Int, passed: Int, needsDecision: Int, couldNotCheck: Int,
                    elapsedSeconds: Double, summary: String) {
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

    public var schemaVersion: Int
    public var runID: String
    public var startedAt: CatalogJSONDate
    public var verifiedAt: CatalogJSONDate?
    public var outcome: String
    public var catalogFile: String
    public var snapshotGeneration: Int?
    public var catalogGeneration: Int?
    public var catalogSHA256: String?
    public var catalogByteCount: Int64?
    public var catalogChangedDuringRun: Bool?
    public var catalogHashCertified: Bool?
    public var rowsTotal: Int
    public var rowsLive: Int
    public var elapsedSeconds: Double
    public var tiers: [Tier]
    public var findings: [ImportGate.Finding]
    public var findingsTotal: Int

    public init(runID: String, startedAt: CatalogJSONDate, verifiedAt: CatalogJSONDate?, outcome: String,
                catalogFile: String, snapshotGeneration: Int?, catalogGeneration: Int?, catalogSHA256: String?,
                catalogByteCount: Int64?, catalogHashCertified: Bool, rowsTotal: Int, rowsLive: Int,
                tiers: [Tier], findings: [ImportGate.Finding], findingsTotal: Int) {
        self.schemaVersion = 2
        self.runID = runID
        self.startedAt = startedAt
        self.verifiedAt = verifiedAt
        self.outcome = outcome
        self.catalogFile = catalogFile
        self.snapshotGeneration = snapshotGeneration
        self.catalogGeneration = catalogGeneration
        self.catalogSHA256 = catalogSHA256
        self.catalogByteCount = catalogByteCount
        self.catalogChangedDuringRun = false
        self.catalogHashCertified = catalogHashCertified
        self.rowsTotal = rowsTotal
        self.rowsLive = rowsLive
        self.elapsedSeconds = 0
        self.tiers = tiers
        self.findings = findings
        self.findingsTotal = findingsTotal
    }

    public static func decode(_ data: Data) throws -> IntegrityReportJSON {
        try JSONDecoder().decode(IntegrityReportJSON.self, from: data)
    }

    public var facts: ImportGate.ReportFacts {
        ImportGate.ReportFacts(outcome: outcome, catalogHashCertified: catalogHashCertified ?? false,
                               catalogSHA256: catalogSHA256, snapshotGeneration: snapshotGeneration,
                               startedAt: startedAt.unixSeconds, findingsTotal: findingsTotal,
                               findingsListed: findings.count,
                               tiersNotRun: tiers.filter { $0.result.kind == "notRun" }.map(\.tier),
                               tiersPresent: tiers.map(\.tier))
    }

    /// Canonical record id → every finding naming it.
    public func findingsByRecord() -> [String: [ImportGate.Finding]] {
        var out: [String: [ImportGate.Finding]] = [:]
        for f in findings {
            guard let id = f.recordID else { continue }
            out[CatalogRecordDTO.canonicalID(id), default: []].append(f)
        }
        return out
    }
}
