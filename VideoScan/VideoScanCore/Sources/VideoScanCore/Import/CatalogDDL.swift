// CatalogDDL.swift
// The CHECK-list vocabularies of docs/design/catalog_sqlite_schema_v1.sql
// (v1.3) as Swift enums, one per (table, column), raw values in DDL order.
// `CatalogDDLVocabularyTests` reads the DDL FILE at test time and pins every
// enum's raw values against the list it names in `ddlLocation`, so a DDL
// edit that is not mirrored here fails loudly (and the reverse).
//
// Namespaced under `CatalogDDL` so no top-level name can collide with an
// app type (the app re-exports VideoScanCore).
//
// (For Rick: string-backed enums ≈ `enum class` with a to_string table the
// compiler keeps in step with the cases.)

import Foundation

public enum CatalogDDL {

    /// Where a vocabulary lives in the DDL: `CREATE TABLE <table>`, first
    /// `<column> IN (` list after it.
    public struct Location: Sendable, Equatable {
        public let table: String
        public let column: String
        public init(_ table: String, _ column: String) {
            self.table = table
            self.column = column
        }
    }

    /// files.stream_type (StreamType raw values, plus '' for never probed).
    public enum StreamType: String, Codable, CaseIterable, Sendable {
        case videoAndAudio = "Video+Audio"
        case videoOnly = "Video only"
        case audioOnly = "Audio only"
        case noStreams = "No A/V streams"
        case ffprobeFailed = "ffprobe failed"
        case unprobed = ""
        public static let ddlLocation = Location("files", "stream_type")
    }

    /// files.lifecycle (LifecycleStage, C/ArchiveModels.swift:15).
    public enum Lifecycle: String, Codable, CaseIterable, Sendable {
        case cataloged = "Cataloged"
        case inTriage = "In Triage"
        case workbench = "Workbench"
        case archived = "Archived"
        case trashed = "Trashed"
        case deleted = "Deleted"
        public static let ddlLocation = Location("files", "lifecycle")
    }

    /// files.archive_stage (ArchiveStage, C/ArchiveModels.swift:47).
    public enum ArchiveStage: String, Codable, CaseIterable, Sendable {
        case none = "None"
        case healthy = "Healthy"
        case master = "Master"
        case backedUp = "Backed Up"
        case ready = "Ready"
        case archived = "Archived"
        case manuallyDeleted = "Manually Deleted"
        case salvageFailed = "Salvage Failed"
        public static let ddlLocation = Location("files", "archive_stage")
    }

    /// files.digest_source.
    public enum DigestSource: String, Codable, CaseIterable, Sendable {
        case contentFixity, archiveFixity, rescan
        public static let ddlLocation = Location("files", "digest_source")
    }

    /// files.removal_state / tombstones.state (RemovalMarker.State).
    public enum RemovalState: String, Codable, CaseIterable, Sendable {
        case inTrash, removedFromCatalog, missing
        public static let ddlLocation = Location("files", "removal_state")
    }

    /// content.first_seen_how.
    public enum FirstSeenHow: String, Codable, CaseIterable, Sendable {
        case `import`, rescan, job
        public static let ddlLocation = Location("content", "first_seen_how")
    }

    /// archive_copies.promoted_by.
    public enum PromotedBy: String, Codable, CaseIterable, Sendable {
        case promote, orphanAdopt, `import`
        public static let ddlLocation = Location("archive_copies", "promoted_by")
    }

    /// backup_destinations.kind (BackupEntry.BackupKind).
    public enum BackupKind: String, Codable, CaseIterable, Sendable {
        case local = "Local"
        case cloud = "Cloud"
        case offsite = "Offsite"
        public static let ddlLocation = Location("backup_destinations", "kind")
    }

    /// knowledge_sources.field — the curated fields the comparator counts
    /// (contract §a "Curated fields the comparator counts", §10b).
    public enum KnowledgeField: String, Codable, CaseIterable, Sendable {
        case userNotes, tags, mediaDisposition, starRating, confirmedByUserPeople
        case rejectedPeople, userDate, userDateConfidence, userPlace, userPlaceConfidence
        case backupAttestations, repairConfirmedDate, footageDecisions, familyMusic
        case setAsideReason, archivedAt, archiveFixity, lineage, supersededByID
        case mediaReportCard
        public static let ddlLocation = Location("knowledge_sources", "field")
    }

    /// user_dates.confidence / user_places.confidence.
    public enum DateConfidence: String, Codable, CaseIterable, Sendable {
        case estimated, known
        public static let ddlLocation = Location("user_dates", "confidence")
    }

    /// people_tags.kind.
    public enum PeopleTagKind: String, Codable, CaseIterable, Sendable {
        case detected, suspected, confirmed, rejected
        public static let ddlLocation = Location("people_tags", "kind")
    }

    /// backup_attestations.kind (BackupAttestation.Kind).
    public enum AttestationKind: String, Codable, CaseIterable, Sendable {
        case cloud, offsite, drive
        public static let ddlLocation = Location("backup_attestations", "kind")
    }

    /// backup_attestations.answer (BackupAttestation.Answer).
    public enum AttestationAnswer: String, Codable, CaseIterable, Sendable {
        case yes, no, notApplicable
        public static let ddlLocation = Location("backup_attestations", "answer")
    }

    /// footage_decisions.verdict (FootageDecision.Verdict).
    public enum FootageVerdict: String, Codable, CaseIterable, Sendable {
        case same, notSame
        public static let ddlLocation = Location("footage_decisions", "verdict")
    }

    /// dispositions.disposition ('Unreviewed' = no row).
    public enum Disposition: String, Codable, CaseIterable, Sendable {
        case important = "Important"
        case recoverable = "Recoverable"
        case suspectedJunk = "Suspected Junk"
        case confirmedJunk = "Confirmed Junk"
        public static let ddlLocation = Location("dispositions", "disposition")
        /// MediaDisposition's default, which has no row.
        public static let unreviewed = "Unreviewed"
    }

    /// sound_prints.outcome (AudioFingerprintStamp.Outcome).
    public enum SoundOutcome: String, Codable, CaseIterable, Sendable {
        case fingerprinted, noAudio
        public static let ddlLocation = Location("sound_prints", "outcome")
    }

    /// captions.kind.
    public enum CaptionKind: String, Codable, CaseIterable, Sendable {
        case scene, ocrDate, ocrText
        public static let ddlLocation = Location("captions", "kind")
    }

    /// derived_unverified.kind.
    public enum DerivedKind: String, Codable, CaseIterable, Sendable {
        case scene, ocrDate, ocrText
        case captionRun, transcript, dossier, inferredDate
        case audioCheck, videoCheck, reportCard, perceptualPrint, footageMembership
        case detectedPerson, suspectedPerson
        public static let ddlLocation = Location("derived_unverified", "kind")
    }

    /// media_checks.kind.
    public enum MediaCheckKind: String, Codable, CaseIterable, Sendable {
        case audio, video, reportCard
        public static let ddlLocation = Location("media_checks", "kind")
    }

    /// regen_context.kind.
    public enum RegenKind: String, Codable, CaseIterable, Sendable {
        case folderDate, donorDate
        public static let ddlLocation = Location("regen_context", "kind")
    }

    /// person_searches.outcome.
    public enum SearchOutcome: String, Codable, CaseIterable, Sendable {
        case searched, unreadable
        public static let ddlLocation = Location("person_searches", "outcome")
    }

    /// person_searches.provenance.
    public enum Provenance: String, Codable, CaseIterable, Sendable {
        case bound, unverified
        public static let ddlLocation = Location("person_searches", "provenance")
    }

    /// lineage.kind (contract §b "Derivation kinds"; `unrecorded` when the
    /// writer set derivedFrom with no kind and no recipe — never guessed).
    public enum LineageKind: String, Codable, CaseIterable, Sendable {
        case trim, balanceAudio, rebuildAudio, repair, externalRepair
        case cleanup, reformat, transcode, triage, combine, unrecorded
        public static let ddlLocation = Location("lineage", "kind")
    }

    /// lineage_pending.relation.
    public enum LineageRelation: String, Codable, CaseIterable, Sendable {
        case derivedFrom, supersededBy
        public static let ddlLocation = Location("lineage_pending", "relation")
    }

    /// av_pairs.confidence / duplicate_members.confidence.
    public enum Confidence: String, Codable, CaseIterable, Sendable {
        case high = "High"
        case medium = "Medium"
        case low = "Low"
        public static let ddlLocation = Location("av_pairs", "confidence")
    }

    /// duplicate_members.disposition ('' = not elected = no member row value).
    public enum DuplicateDisposition: String, Codable, CaseIterable, Sendable {
        case keep = "Keep"
        case review = "Review"
        case extraCopy = "Extra copy"
        public static let ddlLocation = Location("duplicate_members", "disposition")
    }

    /// ignored_content.binding.
    public enum IgnoredBinding: String, Codable, CaseIterable, Sendable {
        case unbound, jsonDigest, personDecided, hashedWhenIgnored
        public static let ddlLocation = Location("ignored_content", "binding")
    }

    /// quarantine.reason_code (contract §f table + §g rescan codes).
    public enum ReasonCode: String, Codable, CaseIterable, Sendable {
        case noWholeFileDigest, auditGone, auditNeverSeen, auditCouldNotCheck, auditChanged
        case tier5Finding, referenceMovie, fixityDisagree, duplicateId, removedNoDigest
        case stillBeingWritten, pathReplaced, unreadable
        public static let ddlLocation = Location("quarantine", "reason_code")

        /// quarantine.reason_class (F5): a presence reason may be resolved
        /// by a rescan's byte match; every other code is a finding.
        public var isPresenceReason: Bool {
            switch self {
            case .auditGone, .auditNeverSeen, .auditCouldNotCheck, .noWholeFileDigest, .removedNoDigest:
                return true
            default:
                return false
            }
        }
    }

    /// import_items.source_file.
    public enum ImportSourceFile: String, Codable, CaseIterable, Sendable {
        case catalog = "catalog.json"
        case eventsDecisions = "events-decisions.json"
        case ignoredContent = "ignored-content.json"
        case mediaLedger = "media-ledger.jsonl"
        case catalogAudit = "catalog-audit.json"
        case fullHashBackfill = "fullhash-backfill.json"
        case personFinderCache = "personfinder_cache.sqlite"
        public static let ddlLocation = Location("import_items", "source_file")
    }

    /// import_items.item_kind.
    public enum ImportItemKind: String, Codable, CaseIterable, Sendable {
        case row, event, eventDecision, ignored, ledgerLine, marker, auditResult, personSearch
        public static let ddlLocation = Location("import_items", "item_kind")
    }

    /// import_items.landed_table.
    public enum LandedTable: String, Codable, CaseIterable, Sendable {
        case files, quarantine, events
        case eventDecisions = "event_decisions"
        case ignoredContent = "ignored_content"
        case ledger
        case jobMarkers = "job_markers"
        case auditResults = "audit_results"
        case personSearches = "person_searches"
        public static let ddlLocation = Location("import_items", "landed_table")
    }

    /// audit_results.result (contract §f per-row audit words, A′).
    public enum AuditResult: String, Codable, CaseIterable, Sendable {
        case present, gone, neverSeen, couldNotCheck, changed, link
        public static let ddlLocation = Location("audit_results", "result")
    }

    /// job_markers.job.
    public enum JobKind: String, Codable, CaseIterable, Sendable {
        case audit, fullHash, soundPrint, freshness, verifyCatalog
        public static let ddlLocation = Location("job_markers", "job")
    }

    /// job_markers.outcome.
    public enum JobOutcome: String, Codable, CaseIterable, Sendable {
        case completed, stopped, failed
        public static let ddlLocation = Location("job_markers", "outcome")
    }

    /// Every vocabulary above with its location — the test walks this list.
    public static let vocabularies: [(location: Location, rawValues: [String])] = [
        (StreamType.ddlLocation, StreamType.allCases.map(\.rawValue)),
        (Lifecycle.ddlLocation, Lifecycle.allCases.map(\.rawValue)),
        (ArchiveStage.ddlLocation, ArchiveStage.allCases.map(\.rawValue)),
        (DigestSource.ddlLocation, DigestSource.allCases.map(\.rawValue)),
        (RemovalState.ddlLocation, RemovalState.allCases.map(\.rawValue)),
        (FirstSeenHow.ddlLocation, FirstSeenHow.allCases.map(\.rawValue)),
        (PromotedBy.ddlLocation, PromotedBy.allCases.map(\.rawValue)),
        (BackupKind.ddlLocation, BackupKind.allCases.map(\.rawValue)),
        (KnowledgeField.ddlLocation, KnowledgeField.allCases.map(\.rawValue)),
        (DateConfidence.ddlLocation, DateConfidence.allCases.map(\.rawValue)),
        (PeopleTagKind.ddlLocation, PeopleTagKind.allCases.map(\.rawValue)),
        (AttestationKind.ddlLocation, AttestationKind.allCases.map(\.rawValue)),
        (AttestationAnswer.ddlLocation, AttestationAnswer.allCases.map(\.rawValue)),
        (FootageVerdict.ddlLocation, FootageVerdict.allCases.map(\.rawValue)),
        (Disposition.ddlLocation, Disposition.allCases.map(\.rawValue)),
        (SoundOutcome.ddlLocation, SoundOutcome.allCases.map(\.rawValue)),
        (CaptionKind.ddlLocation, CaptionKind.allCases.map(\.rawValue)),
        (DerivedKind.ddlLocation, DerivedKind.allCases.map(\.rawValue)),
        (MediaCheckKind.ddlLocation, MediaCheckKind.allCases.map(\.rawValue)),
        (RegenKind.ddlLocation, RegenKind.allCases.map(\.rawValue)),
        (SearchOutcome.ddlLocation, SearchOutcome.allCases.map(\.rawValue)),
        (Provenance.ddlLocation, Provenance.allCases.map(\.rawValue)),
        (LineageKind.ddlLocation, LineageKind.allCases.map(\.rawValue)),
        (LineageRelation.ddlLocation, LineageRelation.allCases.map(\.rawValue)),
        (Confidence.ddlLocation, Confidence.allCases.map(\.rawValue)),
        (DuplicateDisposition.ddlLocation, DuplicateDisposition.allCases.map(\.rawValue)),
        (IgnoredBinding.ddlLocation, IgnoredBinding.allCases.map(\.rawValue)),
        (ReasonCode.ddlLocation, ReasonCode.allCases.map(\.rawValue)),
        (ImportSourceFile.ddlLocation, ImportSourceFile.allCases.map(\.rawValue)),
        (ImportItemKind.ddlLocation, ImportItemKind.allCases.map(\.rawValue)),
        (LandedTable.ddlLocation, LandedTable.allCases.map(\.rawValue)),
        (AuditResult.ddlLocation, AuditResult.allCases.map(\.rawValue)),
        (JobKind.ddlLocation, JobKind.allCases.map(\.rawValue)),
        (JobOutcome.ddlLocation, JobOutcome.allCases.map(\.rawValue)),
    ]
}
