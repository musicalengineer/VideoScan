// ImportGate.swift
// The importer's gate (contract §f, docs/design/catalog_contract_freeze_2026_10_17.md):
// where ONE catalog.json row occurrence lands — `files` (live or tombstoned)
// or `quarantine` with a reason code, the family-app words and every tier-5
// finding for its record — and which run-level conditions refuse the whole
// import before anything is written.
//
// Pure: the caller fills `Input` / `RunInput` from the frozen files; the gate
// stats nothing and opens nothing (§f "the importer does NOT stat or open
// anything").
//
// Precedence is the §f table, first match wins, and it is a PARTITION:
//   1 duplicateId → 2 fixityDisagree → 3 marker (3 / 3b / 3c) → 4 audit
//   (4 / 4b / 4c / 4d) → 5 present without digest → 6 tier-5 → 7 tier-4 only
//   → 8 main.
//
// (For Rick: a pure decision function ≈ a C++ `constexpr` truth table.)

import Foundation

public enum ImportGate {

    public typealias ReasonCode = CatalogDDL.ReasonCode

    /// One integrity finding (IntegrityReport `findings`,
    /// A/Integrity/IntegrityReport.swift:136).
    public struct Finding: Codable, Sendable, Equatable, Hashable {
        public var tier: Int
        public var rule: String
        public var recordID: String?
        public var words: String
        public var needsDecision: Bool

        public init(tier: Int, rule: String, recordID: String?, words: String, needsDecision: Bool) {
            self.tier = tier
            self.rule = rule
            self.recordID = recordID
            self.words = words
            self.needsDecision = needsDecision
        }
    }

    /// The row's result in catalog-audit.json (A′ per-row results).
    public struct AuditEvidence: Codable, Sendable, Equatable {
        public var result: CatalogDDL.AuditResult
        /// The path the audit judged (required unless `present`, N1).
        public var judgedPath: String?

        public init(result: CatalogDDL.AuditResult, judgedPath: String? = nil) {
            self.result = result
            self.judgedPath = judgedPath
        }
    }

    /// The audit run's window, unix seconds: [startedAt, finishedAt] (N1).
    public struct AuditWindow: Codable, Sendable, Equatable {
        public var startedAt: Int64
        public var finishedAt: Int64

        public init(startedAt: Int64, finishedAt: Int64) {
            self.startedAt = startedAt
            self.finishedAt = finishedAt
        }

        public func contains(_ t: Int64) -> Bool { t >= startedAt && t <= finishedAt }
    }

    /// The per-row evidence §f names.
    public struct Input: Sendable, Equatable {
        /// How many times this row's UUID occurs in catalog.json (§f row 1).
        public var occurrences: Int
        /// `storedFullDigest` + the both-fixities rule (§f "Digest").
        public var digest: CatalogRecordDTO.DigestState
        /// The removal marker is set (§f "Marker").
        public var markerSet: Bool
        /// The row's audit result; nil = no result (reads as `neverSeen`).
        public var audit: AuditEvidence?
        /// The row's own `fullPath` in the frozen JSON.
        public var rowFullPath: String
        /// The row's own `auditSeenOn.seenAt` (unix seconds); nil = no stamp.
        public var rowAuditSeenAt: Int64?
        public var auditWindow: AuditWindow
        /// EVERY finding naming this record (any tier); the gate reads tier 5
        /// and tier 4 from it and keeps all tier-5 ones on a quarantine row.
        public var findings: [Finding]

        public init(occurrences: Int = 1, digest: CatalogRecordDTO.DigestState, markerSet: Bool = false,
                    audit: AuditEvidence?, rowFullPath: String, rowAuditSeenAt: Int64?,
                    auditWindow: AuditWindow, findings: [Finding] = []) {
            self.occurrences = occurrences
            self.digest = digest
            self.markerSet = markerSet
            self.audit = audit
            self.rowFullPath = rowFullPath
            self.rowAuditSeenAt = rowAuditSeenAt
            self.auditWindow = auditWindow
            self.findings = findings
        }

        /// Build from a mapped row (the importer's path).
        public init(record: CatalogRecordDTO, occurrences: Int, audit: AuditEvidence?,
                    auditWindow: AuditWindow, findings: [Finding]) {
            self.init(occurrences: occurrences, digest: record.digestState, markerSet: record.removal != nil,
                      audit: audit, rowFullPath: record.file.fullPath, rowAuditSeenAt: record.auditStamp?.auditSeenAt,
                      auditWindow: auditWindow, findings: findings)
        }
    }

    public enum Landing: Sendable, Equatable {
        case main(tombstoned: Bool)
        case quarantine(reason: ReasonCode, words: String, findings: [Finding])

        public var reason: ReasonCode? {
            if case .quarantine(let r, _, _) = self { return r }
            return nil
        }
    }

    // MARK: - Words (contract §f table, verbatim)

    public enum Words {
        public static func duplicateId(_ n: Int) -> String {
            "this catalog entry appears \(n) times; each copy kept"
        }
        public static let fixityDisagree = "two full hashes disagree; neither is trusted"
        public static let removedNoDigest = "left the catalog before its identity was read; kept as history"
        public static let auditGone = "not at its path when last checked"
        public static let auditNeverSeen = "no audit has seen this file — Fix Links decides"
        public static let auditCouldNotCheck = "its drive was not connected, or a link is in the path"
        public static let auditChanged = "the file changed since its identity was read"
        public static let noWholeFileDigest =
            "on disk, but its identity was never read in full; Fill In Full Hashes, then rescan"
    }

    /// The rule name of the reference-movie finding (CatalogConstraints
    /// `referenceMovie`, contract §d 2b).
    public static let referenceMovieRule = "referenceMovie"

    // MARK: - N1: a result gates its row only when bound to the snapshot

    /// `audit_results.accepted` (DDL trigger `audit_results_bound_to_snapshot`):
    /// `present` needs the row's own stamp inside the audit window; any other
    /// result needs the judged path to equal the row's path.
    public static func accepts(_ audit: AuditEvidence, rowFullPath: String, rowAuditSeenAt: Int64?,
                               window: AuditWindow) -> Bool {
        if audit.result == .present {
            guard let seen = rowAuditSeenAt else { return false }
            return window.contains(seen)
        }
        return audit.judgedPath == rowFullPath
    }

    /// The result the gate reads: an unaccepted or missing result is `neverSeen`.
    public static func effectiveAudit(_ input: Input) -> CatalogDDL.AuditResult {
        guard let audit = input.audit,
              accepts(audit, rowFullPath: input.rowFullPath, rowAuditSeenAt: input.rowAuditSeenAt,
                      window: input.auditWindow) else { return .neverSeen }
        return audit.result
    }

    /// Every tier-5 finding for the record — kept on a quarantine row whichever
    /// reason won (F5r3).
    public static func tier5Findings(_ input: Input) -> [Finding] {
        input.findings.filter { $0.tier == 5 }
    }

    /// The tier-5 findings that gate (§f "Tier 5 — any finding with this
    /// recordID and needsDecision").
    private static func gatingTier5(_ input: Input) -> [Finding] {
        input.findings.filter { $0.tier == 5 && $0.needsDecision }
    }

    /// §f row 7: a main row with a tier-4 finding only — listed in the import
    /// report, its stale stamp imports `unverified`.
    public static func tier4Listed(_ input: Input) -> Bool {
        guard case .main(_) = decide(input) else { return false }
        return input.findings.contains { $0.tier == 4 && $0.needsDecision }
    }

    private static func findingLanding(_ gating: [Finding], all: [Finding]) -> Landing {
        let isReferenceMovie = gating.contains { $0.rule == referenceMovieRule }
        let words = gating.map(\.words).joined(separator: " · ")
        return .quarantine(reason: isReferenceMovie ? .referenceMovie : .tier5Finding, words: words, findings: all)
    }

    // MARK: - Decide

    public static func decide(_ input: Input) -> Landing {
        let all5 = tier5Findings(input)
        // 1
        if input.occurrences > 1 {
            return .quarantine(reason: .duplicateId, words: Words.duplicateId(input.occurrences), findings: all5)
        }
        // 2
        if case .disagree(_) = input.digest {
            return .quarantine(reason: .fixityDisagree, words: Words.fixityDisagree, findings: all5)
        }
        let gating = gatingTier5(input)
        let hasDigest = input.digest.digest != nil
        // 3 / 3b / 3c
        if input.markerSet {
            if !hasDigest {
                return .quarantine(reason: .removedNoDigest, words: Words.removedNoDigest, findings: all5)
            }
            if !gating.isEmpty { return findingLanding(gating, all: all5) }
            return .main(tombstoned: true)
        }
        // 4 / 4b / 4c / 4d
        switch effectiveAudit(input) {
        case .gone:
            return .quarantine(reason: .auditGone, words: Words.auditGone, findings: all5)
        case .neverSeen:
            return .quarantine(reason: .auditNeverSeen, words: Words.auditNeverSeen, findings: all5)
        case .couldNotCheck, .link:
            return .quarantine(reason: .auditCouldNotCheck, words: Words.auditCouldNotCheck, findings: all5)
        case .changed:
            return .quarantine(reason: .auditChanged, words: Words.auditChanged, findings: all5)
        case .present:
            break
        }
        // 5
        if !hasDigest {
            return .quarantine(reason: .noWholeFileDigest, words: Words.noWholeFileDigest, findings: all5)
        }
        // 6
        if !gating.isEmpty { return findingLanding(gating, all: all5) }
        // 7 / 8
        return .main(tombstoned: false)
    }

    // MARK: - Run-level refusals (§f "nothing is written")

    /// The integrity report's facts the gate reads (integrity-latest.json).
    public struct ReportFacts: Sendable, Equatable {
        public var outcome: String
        public var catalogHashCertified: Bool
        public var catalogSHA256: String?
        public var snapshotGeneration: Int?
        /// run.startedAt, unix seconds.
        public var startedAt: Int64
        public var findingsTotal: Int
        public var findingsListed: Int
        /// Tiers whose result is `notRun` (a tier absent from the report also counts).
        public var tiersNotRun: [Int]
        public var tiersPresent: [Int]

        public init(outcome: String, catalogHashCertified: Bool, catalogSHA256: String?, snapshotGeneration: Int?,
                    startedAt: Int64, findingsTotal: Int, findingsListed: Int, tiersNotRun: [Int], tiersPresent: [Int]) {
            self.outcome = outcome
            self.catalogHashCertified = catalogHashCertified
            self.catalogSHA256 = catalogSHA256
            self.snapshotGeneration = snapshotGeneration
            self.startedAt = startedAt
            self.findingsTotal = findingsTotal
            self.findingsListed = findingsListed
            self.tiersNotRun = tiersNotRun
            self.tiersPresent = tiersPresent
        }
    }

    /// catalog-audit.json's facts (A′ marker, CatalogAuditRun.swift).
    public struct AuditMarkerFacts: Sendable, Equatable {
        public var outcome: String
        public var partial: Bool
        public var startedAt: Int64
        public var finishedAt: Int64?
        /// The marker carries a per-row results part (an audit from after A′).
        public var hasRowResults: Bool
        /// The generation the audit's stamp save produced (N1).
        public var savedGeneration: Int?

        public init(outcome: String, partial: Bool, startedAt: Int64, finishedAt: Int64?,
                    hasRowResults: Bool, savedGeneration: Int?) {
            self.outcome = outcome
            self.partial = partial
            self.startedAt = startedAt
            self.finishedAt = finishedAt
            self.hasRowResults = hasRowResults
            self.savedGeneration = savedGeneration
        }
    }

    public struct RunInput: Sendable, Equatable {
        public var catalogVersion: Int
        public var catalogGeneration: Int
        /// SHA-256 of the frozen catalog.json bytes (lowercase hex).
        public var catalogSHA256: String
        public var report: ReportFacts?
        public var audit: AuditMarkerFacts?
        /// Event ids that occur more than once in events-decisions.json (F4).
        public var duplicateEventIDs: [String]
        public var openDeleteDuplicatesPlans: [String]
        public var openAngelBatches: [String]
        /// Writers found running ("the app", "the headless audit").
        public var runningWriters: [String]

        public init(catalogVersion: Int, catalogGeneration: Int, catalogSHA256: String,
                    report: ReportFacts?, audit: AuditMarkerFacts?, duplicateEventIDs: [String] = [],
                    openDeleteDuplicatesPlans: [String] = [], openAngelBatches: [String] = [],
                    runningWriters: [String] = []) {
            self.catalogVersion = catalogVersion
            self.catalogGeneration = catalogGeneration
            self.catalogSHA256 = catalogSHA256
            self.report = report
            self.audit = audit
            self.duplicateEventIDs = duplicateEventIDs
            self.openDeleteDuplicatesPlans = openDeleteDuplicatesPlans
            self.openAngelBatches = openAngelBatches
            self.runningWriters = runningWriters
        }
    }

    /// The tiers that must have run (§f "Tiers 0, 1 or 5 notRun").
    public static let requiredTiers = [0, 1, 5]

    public enum RunRefusal: Sendable, Equatable {
        case jsonVersionTooNew(Int)
        case reportMissing
        case reportNotCompleted(String)
        case reportNotCertified
        case reportHashMismatch(report: String?, file: String)
        case reportGenerationMismatch(report: Int?, file: Int)
        case auditGenerationMismatch(audit: Int?, snapshot: Int?, file: Int)
        case findingsTruncated(total: Int, listed: Int)
        case tierNotRun(Int)
        case auditMissing
        case auditPartial
        case auditNotCompleted(String)
        case auditFinishedAfterIntegrityStarted
        case auditHasNoRowResults
        case duplicateEventID(String)
        case openDeleteDuplicatesPlan(String)
        case openAngelBatch(String)
        case anotherWriterRunning(String)

        /// The contract states the conditions, not their words; these are the
        /// importer's words, pinned by the tests.
        public var words: String {
            switch self {
            case .jsonVersionTooNew(let v):
                return "catalog.json is version \(v); this importer reads versions 1–\(CatalogFileJSON.newestVersion)"
            case .reportMissing:
                return "no Verify Catalog report — run Verify Catalog first"
            case .reportNotCompleted(let o):
                return "the last Verify Catalog did not complete (\(o)) — run it again"
            case .reportNotCertified:
                return "the last Verify Catalog did not certify the catalog file's hash — run it again"
            case .reportHashMismatch(let report, let file):
                return "the catalog file (\(file)) is not the one Verify Catalog checked (\(report ?? "none"))"
            case .reportGenerationMismatch(let report, let file):
                return "Verify Catalog checked generation \(report.map { String($0) } ?? "unknown"); the file is generation \(file)"
            case .auditGenerationMismatch(let audit, let snapshot, let file):
                return "the audit saved generation \(audit.map { String($0) } ?? "unknown"), Verify Catalog checked \(snapshot.map { String($0) } ?? "unknown"), the file is \(file) — something saved in between; audit and verify again"
            case .findingsTruncated(let total, let listed):
                return "Verify Catalog listed \(listed) of \(total) findings; fix them and verify again"
            case .tierNotRun(let t):
                return "Verify Catalog tier \(t) did not run"
            case .auditMissing:
                return "no audit marker — run Audit Catalog first"
            case .auditPartial:
                return "the last audit was partial — run it to the end"
            case .auditNotCompleted(let o):
                return "the last audit did not complete (\(o))"
            case .auditFinishedAfterIntegrityStarted:
                return "the audit finished after Verify Catalog started — verify again"
            case .auditHasNoRowResults:
                return "the last audit carries no per-row results — run Audit Catalog again"
            case .duplicateEventID(let id):
                return "event \(id) appears twice in events-decisions.json"
            case .openDeleteDuplicatesPlan(let p):
                return "a Delete Duplicates plan is still open (\(p))"
            case .openAngelBatch(let b):
                return "an Archive Angel batch is still open (\(b))"
            case .anotherWriterRunning(let w):
                return "\(w) is running — one writer at a time"
            }
        }
    }

    public static func runLevelRefusals(_ run: RunInput) -> [RunRefusal] {
        var out: [RunRefusal] = []
        if run.catalogVersion > CatalogFileJSON.newestVersion {
            out.append(.jsonVersionTooNew(run.catalogVersion))
        }
        if let r = run.report {
            if r.outcome != "completed" { out.append(.reportNotCompleted(r.outcome)) }
            if !r.catalogHashCertified { out.append(.reportNotCertified) }
            if r.catalogSHA256?.lowercased() != run.catalogSHA256.lowercased() {
                out.append(.reportHashMismatch(report: r.catalogSHA256, file: run.catalogSHA256))
            }
            if r.snapshotGeneration != run.catalogGeneration {
                out.append(.reportGenerationMismatch(report: r.snapshotGeneration, file: run.catalogGeneration))
            }
            if r.findingsTotal > r.findingsListed {
                out.append(.findingsTruncated(total: r.findingsTotal, listed: r.findingsListed))
            }
            for t in requiredTiers where r.tiersNotRun.contains(t) || !r.tiersPresent.contains(t) {
                out.append(.tierNotRun(t))
            }
        } else {
            out.append(.reportMissing)
        }
        if let a = run.audit {
            if a.savedGeneration != run.report?.snapshotGeneration || a.savedGeneration != run.catalogGeneration {
                out.append(.auditGenerationMismatch(audit: a.savedGeneration, snapshot: run.report?.snapshotGeneration,
                                                    file: run.catalogGeneration))
            }
            if a.partial { out.append(.auditPartial) }
            if a.outcome != "completed" { out.append(.auditNotCompleted(a.outcome)) }
            if let finished = a.finishedAt {
                if let r = run.report, finished >= r.startedAt { out.append(.auditFinishedAfterIntegrityStarted) }
            } else if a.outcome == "completed" {
                out.append(.auditNotCompleted("unfinished"))
            }
            if !a.hasRowResults { out.append(.auditHasNoRowResults) }
        } else {
            out.append(.auditMissing)
        }
        out += run.duplicateEventIDs.map { RunRefusal.duplicateEventID($0) }
        out += run.openDeleteDuplicatesPlans.map { RunRefusal.openDeleteDuplicatesPlan($0) }
        out += run.openAngelBatches.map { RunRefusal.openAngelBatch($0) }
        out += run.runningWriters.map { RunRefusal.anotherWriterRunning($0) }
        return out
    }
}
