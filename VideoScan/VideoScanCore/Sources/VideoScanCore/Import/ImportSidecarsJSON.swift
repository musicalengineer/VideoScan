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
// fix 2026-10-17 (codex D′ #3/#4): the mapping from an audit row to its
// `audit_results` row lives HERE, once, so the row pass (from the gate's
// decode) and the comparator (from its own re-decode of the same file) build
// the row by one rule and compare whole rows. A result word outside the
// contract's six is a RUN refusal (`unknownResultWords`), never a silent skip.
//
// (For Rick: two POD mirrors of the app's JSON files plus the few facts the
// gate needs from each.)

import Foundation

/// catalog-audit.json as the importer reads it.
public struct AuditMarkerJSON: Codable, Sendable, Equatable {

    /// One per-row result. `result` is kept as a word; a word outside the
    /// contract's six refuses the run at the gate (codex D′ #4).
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

        /// `audit_results.detail`: the audit's words, verbatim, under one key.
        public var detailObject: CatalogJSONValue {
            .object(detail.map { ["detail": .string($0)] } ?? [:])
        }

        /// The `audit_results` row this result becomes (N1: `accepted` by the
        /// snapshot rule against the row's own path and stamp). Throws on a
        /// result word the gate should already have refused.
        func auditResultRow(ordinal: Int, run: String, index: ImportRowIndex, window: ImportGate.AuditWindow) throws -> CatalogRow.AuditResult {
            guard let result = CatalogDDL.AuditResult(rawValue: self.result) else {
                throw ImportFailure(words: "audit result \(ordinal) carries the unknown word \"\(self.result)\" — the gate should have refused it")
            }
            let canonical = CatalogRecordDTO.canonicalID(id)
            let facts = index.facts[canonical]
            let evidence = ImportGate.AuditEvidence(result: result, judgedPath: judgedPath)
            return CatalogRow.AuditResult(
                importRun: run, sourceOrdinal: ordinal, jsonRowID: canonical, result: result, detail: detailObject,
                judgedPath: judgedPath, rowFullPath: facts?.fullPath ?? "", rowAuditSeenAt: facts?.auditSeenAt,
                accepted: ImportGate.accepts(evidence, rowFullPath: facts?.fullPath ?? "", rowAuditSeenAt: facts?.auditSeenAt,
                                             window: window))
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

    /// The source ordinal of row `index` (the marker itself is ordinal 0).
    public static func rowOrdinal(_ index: Int) -> Int { 1 + index }

    public var facts: ImportGate.AuditMarkerFacts {
        ImportGate.AuditMarkerFacts(outcome: outcome, partial: partial, startedAt: startedAt.unixSeconds,
                                    finishedAt: finishedAt?.unixSeconds, hasRowResults: rows != nil,
                                    savedGeneration: savedGeneration, unknownResultWords: unknownResultWords)
    }

    /// [startedAt, finishedAt]; an unfinished run's window ends at its start.
    public var window: ImportGate.AuditWindow {
        ImportGate.AuditWindow(startedAt: startedAt.unixSeconds,
                               finishedAt: finishedAt?.unixSeconds ?? startedAt.unixSeconds)
    }

    /// Result words outside the contract's six, by source ordinal (codex D′ #4).
    public var unknownResultWords: [Int: String] {
        var out: [Int: String] = [:]
        for (index, row) in (rows ?? []).enumerated() where CatalogDDL.AuditResult(rawValue: row.result) == nil {
            out[Self.rowOrdinal(index)] = row.result
        }
        return out
    }

    /// Rows the `audit_results` table would refuse (codex D′ #6).
    public var faults: [RowPreflight.SidecarFault] {
        (rows ?? []).enumerated().flatMap { index, row in
            RowPreflight.violations(auditRow: row).map {
                RowPreflight.SidecarFault(file: .catalogAudit, ordinal: Self.rowOrdinal(index), words: $0)
            }
        }
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

    /// `job_markers.detail` for the audit marker: the file body without its
    /// per-row results (they are the `audit_results` rows), plus the hash of
    /// the whole file and how many rows it carried (codex D′ #4).
    public func markerDetail(fileSHA256: String) -> CatalogJSONValue {
        var body = (try? CatalogJSONValue.of(self).objectValue) ?? [:]
        body.removeValue(forKey: "rows")
        body[CatalogRow.JobMarker.fileSHA256Key] = .string(fileSHA256)
        body[CatalogRow.JobMarker.rowCountKey] = .int(Int64(rows?.count ?? 0))
        return .object(body)
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
