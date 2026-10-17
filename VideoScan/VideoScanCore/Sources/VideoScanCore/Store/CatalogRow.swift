// CatalogRow.swift (VideoScanCore/Store)
// The domain values that cross the CatalogRepository seam in step C′ part
// 2b: one value per table row the importer (and later the rescan) writes,
// plus the small readings the comparator asks for. Foundation only — no
// GRDB or SQLite type is named here (the seam rule, CatalogStoreSensorTests).
//
// The rows of ONE catalog.json occurrence (`files`, `content`, the curated
// and derived values) already live on `CatalogRecordDTO`; this file holds the
// rest: quarantine, the import bookkeeping, tombstones, the sidecar tables
// and the relation edges. Property names are the DDL column names in
// lowerCamelCase (docs/design/catalog_sqlite_schema_v1.sql).
//
// (For Rick: plain PODs — one `struct` per INSERT statement, and one `enum`
// with associated values (`Relation`) where a family of INSERTs shares a
// door. Nothing here has behaviour.)

import Foundation

public enum CatalogRow {

    // MARK: - Quarantine (DDL §8), origin 'import'

    public struct Quarantine: Sendable, Equatable {
        public var importRun: String
        public var sourceOrdinal: Int
        public var jsonRowID: String
        public var fullPath: String
        public var sizeBytes: Int64?
        /// The agreeing whole-file digest; NULL when none or on disagreement.
        public var digest: String?
        /// Every whole-file digest the row carried (both, on disagreement).
        public var evidenceDigests: [String]
        public var sampledHash: String?
        public var reasonCode: CatalogDDL.ReasonCode
        public var words: String
        public var findings: [ImportGate.Finding]
        /// The whole JSON row, verbatim.
        public var rawRow: [String: CatalogJSONValue]
        public var quarantinedAt: Int64

        public init(importRun: String, sourceOrdinal: Int, jsonRowID: String, fullPath: String, sizeBytes: Int64?,
                    digest: String?, evidenceDigests: [String], sampledHash: String?, reasonCode: CatalogDDL.ReasonCode,
                    words: String, findings: [ImportGate.Finding], rawRow: [String: CatalogJSONValue], quarantinedAt: Int64) {
            self.importRun = importRun
            self.sourceOrdinal = sourceOrdinal
            self.jsonRowID = jsonRowID
            self.fullPath = fullPath
            self.sizeBytes = sizeBytes
            self.digest = digest
            self.evidenceDigests = evidenceDigests
            self.sampledHash = sampledHash
            self.reasonCode = reasonCode
            self.words = words
            self.findings = findings
            self.rawRow = rawRow
            self.quarantinedAt = quarantinedAt
        }
    }

    // MARK: - Import bookkeeping (DDL §8a)

    /// `import_runs`, inserted OPEN (the trigger refuses a finished insert).
    public struct ImportRun: Sendable, Equatable {
        public var runID: String
        public var startedAt: Int64
        public var sourceSHA256: String
        public var sourceGeneration: Int
        public var integrityRunID: String
        public var auditRunStartedAt: Int64
        public var auditRunFinishedAt: Int64
        public var auditGeneration: Int
        public var integrityStartedAt: Int64
        public var integrityGeneration: Int

        public init(runID: String, startedAt: Int64, sourceSHA256: String, sourceGeneration: Int, integrityRunID: String,
                    auditRunStartedAt: Int64, auditRunFinishedAt: Int64, auditGeneration: Int,
                    integrityStartedAt: Int64, integrityGeneration: Int) {
            self.runID = runID
            self.startedAt = startedAt
            self.sourceSHA256 = sourceSHA256
            self.sourceGeneration = sourceGeneration
            self.integrityRunID = integrityRunID
            self.auditRunStartedAt = auditRunStartedAt
            self.auditRunFinishedAt = auditRunFinishedAt
            self.auditGeneration = auditGeneration
            self.integrityStartedAt = integrityStartedAt
            self.integrityGeneration = integrityGeneration
        }
    }

    /// The counters `finishImportRun` writes; the DDL's finish trigger
    /// recomputes every one of them from the rows and refuses a lie.
    public struct ImportCounters: Sendable, Equatable {
        public var rowsBefore: Int
        public var rowsMain: Int
        public var rowsQuarantine: Int
        public var digestsSeen: Int
        public var knowledgeRows: Int

        public init(rowsBefore: Int, rowsMain: Int, rowsQuarantine: Int, digestsSeen: Int, knowledgeRows: Int) {
            self.rowsBefore = rowsBefore
            self.rowsMain = rowsMain
            self.rowsQuarantine = rowsQuarantine
            self.digestsSeen = digestsSeen
            self.knowledgeRows = knowledgeRows
        }
    }

    /// `import_items`: one per occurrence in every input file (F1).
    public struct ImportItem: Sendable, Equatable {
        public var importRun: String
        public var sourceFile: CatalogDDL.ImportSourceFile
        public var sourceOrdinal: Int
        public var itemKind: CatalogDDL.ImportItemKind
        public var sourceKey: String?
        public var curatedFields: [CatalogDDL.KnowledgeField]
        public var landedTable: CatalogDDL.LandedTable
        /// files.id | quarantine.qid | events.event_id | '' (keyed by run + ordinal).
        public var landedRef: String

        public init(importRun: String, sourceFile: CatalogDDL.ImportSourceFile, sourceOrdinal: Int,
                    itemKind: CatalogDDL.ImportItemKind, sourceKey: String?, curatedFields: [CatalogDDL.KnowledgeField] = [],
                    landedTable: CatalogDDL.LandedTable, landedRef: String) {
            self.importRun = importRun
            self.sourceFile = sourceFile
            self.sourceOrdinal = sourceOrdinal
            self.itemKind = itemKind
            self.sourceKey = sourceKey
            self.curatedFields = curatedFields
            self.landedTable = landedTable
            self.landedRef = landedRef
        }
    }

    // MARK: - Tombstones (DDL §4, F11)

    public struct Tombstone: Sendable, Equatable {
        public var fileID: String
        public var revision: Int
        public var state: CatalogDDL.RemovalState?
        public var since: Int64?
        public var reason: String?
        public var trashPath: String?
        public var trashEmptiedAt: Int64?
        public var lastSeen: Int64?
        public var writtenAt: Int64
        /// 'stampRemoval','clearRemoval','revertRemoval','trashEmptied','undo','replacedAtPath','import'
        public var door: String

        public init(fileID: String, revision: Int, state: CatalogDDL.RemovalState?, since: Int64?, reason: String?,
                    trashPath: String?, trashEmptiedAt: Int64?, lastSeen: Int64?, writtenAt: Int64, door: String) {
            self.fileID = fileID
            self.revision = revision
            self.state = state
            self.since = since
            self.reason = reason
            self.trashPath = trashPath
            self.trashEmptiedAt = trashEmptiedAt
            self.lastSeen = lastSeen
            self.writtenAt = writtenAt
            self.door = door
        }
    }

    // MARK: - Knowledge and derived evidence, keyed by occurrence (DDL §6.0, §6b, §6c)

    public struct KnowledgeSource: Sendable, Equatable {
        public var importRun: String
        public var sourceOrdinal: Int
        public var jsonRowID: String
        public var digest: String?
        public var value: CatalogRecordDTO.KnowledgeSourceRow

        public init(importRun: String, sourceOrdinal: Int, jsonRowID: String, digest: String?,
                    value: CatalogRecordDTO.KnowledgeSourceRow) {
            self.importRun = importRun
            self.sourceOrdinal = sourceOrdinal
            self.jsonRowID = jsonRowID
            self.digest = digest
            self.value = value
        }
    }

    public struct DerivedUnverified: Sendable, Equatable {
        public var digest: String
        public var sourceJSONRowID: String
        public var importRun: String
        public var sourceOrdinal: Int
        public var value: CatalogRecordDTO.DerivedValueRow

        public init(digest: String, sourceJSONRowID: String, importRun: String, sourceOrdinal: Int,
                    value: CatalogRecordDTO.DerivedValueRow) {
            self.digest = digest
            self.sourceJSONRowID = sourceJSONRowID
            self.importRun = importRun
            self.sourceOrdinal = sourceOrdinal
            self.value = value
        }
    }

    public struct RegenContext: Sendable, Equatable {
        public var importRun: String
        public var sourceOrdinal: Int
        public var jsonRowID: String
        public var digest: String?
        public var value: CatalogRecordDTO.RegenContextRow

        public init(importRun: String, sourceOrdinal: Int, jsonRowID: String, digest: String?,
                    value: CatalogRecordDTO.RegenContextRow) {
            self.importRun = importRun
            self.sourceOrdinal = sourceOrdinal
            self.jsonRowID = jsonRowID
            self.digest = digest
            self.value = value
        }
    }

    public struct LegacyPairIDs: Sendable, Equatable {
        public var importRun: String
        public var sourceOrdinal: Int
        public var jsonRowID: String
        public var digest: String?
        public var value: CatalogRecordDTO.LegacyPairIDsRow
        /// The event member keys that cite this row's pair or id (F9).
        public var eventMemberKeys: [String]

        public init(importRun: String, sourceOrdinal: Int, jsonRowID: String, digest: String?,
                    value: CatalogRecordDTO.LegacyPairIDsRow, eventMemberKeys: [String]) {
            self.importRun = importRun
            self.sourceOrdinal = sourceOrdinal
            self.jsonRowID = jsonRowID
            self.digest = digest
            self.value = value
            self.eventMemberKeys = eventMemberKeys
        }
    }

    // MARK: - Relations (DDL §7 and the footage / duplicate / event tables)

    /// One edge, by family. `insertRelation` switches on it; a new relation
    /// is a new case, not a new door. (For Rick: `std::variant` of edge
    /// shapes.)
    public enum Relation: Sendable, Equatable {
        case lineage(childDigest: String, parentDigest: String, value: CatalogRecordDTO.LineageValue, recordedAt: Int64?)
        case lineagePending(importRun: String, sourceOrdinal: Int, relation: CatalogDDL.LineageRelation,
                            childRowID: String, childDigest: String?, parentRowID: String, parentDigest: String?,
                            payload: CatalogJSONValue)
        case supersession(retiredDigest: String, byDigest: String, confirmedAt: Int64?)
        case duplicateCandidate(fileID: String, member: CatalogRecordDTO.DuplicateMemberRow)
        case footageDecision(importRun: String, sourceOrdinal: Int, decision: CatalogRecordDTO.FootageDecisionRow,
                             digest: String?, otherDigest: String?)
        case eventMembership(eventID: String, digest: String, rangeStart: Double?, rangeEnd: Double?, importedKey: String)
    }

    /// What `insertRelation` did. `alreadyPresent` is the same edge from a
    /// byte-identical copy; `refused` carries the DDL's reason in words
    /// (the caller keeps the value elsewhere — never dropped).
    public enum RelationLanding: Sendable, Equatable {
        case landed
        case alreadyPresent
        case refused(String)
    }

    // MARK: - Sidecar tables (DDL §7 events / ignored, §9 markers / audit, §10 ledger)

    public struct Event: Sendable, Equatable {
        public var eventID: String
        public var name: String
        public var state: String
        public var categories: [String]
        public var note: String?
        public var createdAt: Int64
        public var updatedAt: Int64
        public var importRun: String
        public var sourceOrdinal: Int

        public init(eventID: String, name: String, state: String, categories: [String], note: String?,
                    createdAt: Int64, updatedAt: Int64, importRun: String, sourceOrdinal: Int) {
            self.eventID = eventID
            self.name = name
            self.state = state
            self.categories = categories
            self.note = note
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.importRun = importRun
            self.sourceOrdinal = sourceOrdinal
        }
    }

    public struct EventDecision: Sendable, Equatable {
        public var kind: String
        public var payload: CatalogJSONValue
        public var importRun: String
        public var sourceOrdinal: Int

        public init(kind: String, payload: CatalogJSONValue, importRun: String, sourceOrdinal: Int) {
            self.kind = kind
            self.payload = payload
            self.importRun = importRun
            self.sourceOrdinal = sourceOrdinal
        }
    }

    public struct Ignored: Sendable, Equatable {
        public var entryID: String
        public var importRun: String
        public var sourceOrdinal: Int
        public var partialMD5: String
        public var sizeBytes: Int64
        public var filename: String
        public var reason: String
        public var addedAt: Int64
        public var samplePath: String
        /// F7: NULL unless bound by a JSON digest or a person; `binding` follows it.
        public var digest: String?
        public var binding: CatalogDDL.IgnoredBinding

        public init(entryID: String, importRun: String, sourceOrdinal: Int, partialMD5: String, sizeBytes: Int64,
                    filename: String, reason: String, addedAt: Int64, samplePath: String,
                    digest: String? = nil, binding: CatalogDDL.IgnoredBinding = .unbound) {
            self.entryID = entryID
            self.importRun = importRun
            self.sourceOrdinal = sourceOrdinal
            self.partialMD5 = partialMD5
            self.sizeBytes = sizeBytes
            self.filename = filename
            self.reason = reason
            self.addedAt = addedAt
            self.samplePath = samplePath
            self.digest = digest
            self.binding = binding
        }
    }

    public struct Ledger: Sendable, Equatable {
        public var at: Int64
        public var kind: String
        public var actor: String
        public var recordID: String
        public var contentKey: String
        public var digest: String?
        public var path: String
        public var payload: CatalogJSONValue
        public var importRun: String
        public var sourceOrdinal: Int

        public init(at: Int64, kind: String, actor: String, recordID: String, contentKey: String, digest: String?,
                    path: String, payload: CatalogJSONValue, importRun: String, sourceOrdinal: Int) {
            self.at = at
            self.kind = kind
            self.actor = actor
            self.recordID = recordID
            self.contentKey = contentKey
            self.digest = digest
            self.path = path
            self.payload = payload
            self.importRun = importRun
            self.sourceOrdinal = sourceOrdinal
        }
    }

    public struct JobMarker: Sendable, Equatable {
        public var job: CatalogDDL.JobKind
        public var scope: String
        public var startedAt: Int64
        public var finishedAt: Int64?
        public var outcome: CatalogDDL.JobOutcome?
        public var generation: Int
        public var detail: CatalogJSONValue
        public var importRun: String
        public var sourceFile: CatalogDDL.ImportSourceFile
        public var sourceOrdinal: Int

        public init(job: CatalogDDL.JobKind, scope: String, startedAt: Int64, finishedAt: Int64?,
                    outcome: CatalogDDL.JobOutcome?, generation: Int, detail: CatalogJSONValue,
                    importRun: String, sourceFile: CatalogDDL.ImportSourceFile, sourceOrdinal: Int) {
            self.job = job
            self.scope = scope
            self.startedAt = startedAt
            self.finishedAt = finishedAt
            self.outcome = outcome
            self.generation = generation
            self.detail = detail
            self.importRun = importRun
            self.sourceFile = sourceFile
            self.sourceOrdinal = sourceOrdinal
        }
    }

    public struct AuditResult: Sendable, Equatable {
        public var importRun: String
        public var sourceOrdinal: Int
        public var jsonRowID: String
        public var result: CatalogDDL.AuditResult
        public var detail: CatalogJSONValue
        public var judgedPath: String?
        public var rowFullPath: String
        public var rowAuditSeenAt: Int64?
        /// N1, computed by `ImportGate.accepts`; the DDL trigger recomputes it.
        public var accepted: Bool

        public init(importRun: String, sourceOrdinal: Int, jsonRowID: String, result: CatalogDDL.AuditResult,
                    detail: CatalogJSONValue, judgedPath: String?, rowFullPath: String, rowAuditSeenAt: Int64?,
                    accepted: Bool) {
            self.importRun = importRun
            self.sourceOrdinal = sourceOrdinal
            self.jsonRowID = jsonRowID
            self.result = result
            self.detail = detail
            self.judgedPath = judgedPath
            self.rowFullPath = rowFullPath
            self.rowAuditSeenAt = rowAuditSeenAt
            self.accepted = accepted
        }
    }

    public struct PersonSearch: Sendable, Equatable {
        public var digest: String?
        public var personID: String?
        public var personName: String
        public var searchedAt: Int64
        public var engine: String
        public var threshold: Double
        public var hits: Int
        public var outcome: CatalogDDL.SearchOutcome
        public var sourceJSONRowID: String?
        public var provenance: CatalogDDL.Provenance
        public var sourceKey: CatalogJSONValue
        public var importRun: String?
        public var sourceOrdinal: Int?

        public init(digest: String?, personID: String?, personName: String, searchedAt: Int64, engine: String,
                    threshold: Double, hits: Int, outcome: CatalogDDL.SearchOutcome, sourceJSONRowID: String?,
                    provenance: CatalogDDL.Provenance, sourceKey: CatalogJSONValue, importRun: String?, sourceOrdinal: Int?) {
            self.digest = digest
            self.personID = personID
            self.personName = personName
            self.searchedAt = searchedAt
            self.engine = engine
            self.threshold = threshold
            self.hits = hits
            self.outcome = outcome
            self.sourceJSONRowID = sourceJSONRowID
            self.provenance = provenance
            self.sourceKey = sourceKey
            self.importRun = importRun
            self.sourceOrdinal = sourceOrdinal
        }
    }

    // MARK: - Readings (what the comparator asks the store)

    /// An `import_items` row of kind 'row' with where it landed.
    public struct RowLanding: Sendable, Equatable {
        public var ordinal: Int
        public var landedTable: CatalogDDL.LandedTable
        public var landedRef: String
        public init(ordinal: Int, landedTable: CatalogDDL.LandedTable, landedRef: String) {
            self.ordinal = ordinal
            self.landedTable = landedTable
            self.landedRef = landedRef
        }
    }

    public struct KnowledgeReading: Sendable, Equatable {
        public var ordinal: Int
        public var jsonRowID: String
        public var field: CatalogDDL.KnowledgeField
        public var value: CatalogJSONValue
        public init(ordinal: Int, jsonRowID: String, field: CatalogDDL.KnowledgeField, value: CatalogJSONValue) {
            self.ordinal = ordinal
            self.jsonRowID = jsonRowID
            self.field = field
            self.value = value
        }
    }

    /// One quarantine row as the import report lists it.
    public struct QuarantineReading: Sendable, Equatable {
        public var ordinal: Int
        public var jsonRowID: String
        public var digest: String?
        public var reasonCode: CatalogDDL.ReasonCode
        public var words: String
        public var findingsCount: Int
        public init(ordinal: Int, jsonRowID: String, digest: String?, reasonCode: CatalogDDL.ReasonCode, words: String, findingsCount: Int) {
            self.ordinal = ordinal
            self.jsonRowID = jsonRowID
            self.digest = digest
            self.reasonCode = reasonCode
            self.words = words
            self.findingsCount = findingsCount
        }
    }

    public struct DerivedKeyReading: Sendable, Equatable {
        public var digest: String
        public var kind: CatalogDDL.DerivedKind
        public var seq: Int
        public var sourceJSONRowID: String
        public init(digest: String, kind: CatalogDDL.DerivedKind, seq: Int, sourceJSONRowID: String) {
            self.digest = digest
            self.kind = kind
            self.seq = seq
            self.sourceJSONRowID = sourceJSONRowID
        }
    }

    public struct EventMemberReading: Sendable, Hashable {
        public var eventID: String
        public var importedKey: String
        public init(eventID: String, importedKey: String) {
            self.eventID = eventID
            self.importedKey = importedKey
        }
    }

    public struct MarkerReading: Sendable, Hashable {
        public var sourceFile: CatalogDDL.ImportSourceFile
        public var ordinal: Int
        public init(sourceFile: CatalogDDL.ImportSourceFile, ordinal: Int) {
            self.sourceFile = sourceFile
            self.ordinal = ordinal
        }
    }

    public struct AuditResultReading: Sendable, Equatable {
        public var ordinal: Int
        public var accepted: Bool
        public init(ordinal: Int, accepted: Bool) {
            self.ordinal = ordinal
            self.accepted = accepted
        }
    }

    /// How many rows the record tables hold — the importer's "is it empty".
    public struct TableCounts: Sendable, Equatable {
        public var files: Int
        public var quarantine: Int
        public var content: Int
        public var importRuns: Int
        public init(files: Int, quarantine: Int, content: Int, importRuns: Int) {
            self.files = files
            self.quarantine = quarantine
            self.content = content
            self.importRuns = importRuns
        }
        public var isEmpty: Bool { files == 0 && quarantine == 0 && content == 0 && importRuns == 0 }
    }
}
