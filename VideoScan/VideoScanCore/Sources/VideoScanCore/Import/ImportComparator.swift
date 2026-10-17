// ImportComparator.swift
// The independent check that closes an import (contract §f "Comparator"):
// it compares what the JSON side says was there with what the SQLite side
// says landed, ROWS not counters. Any miss → the import rolls back and the
// report names the miss.
//
// Pure: both sides are plain values the caller fills — the JSON side by
// re-decoding every input file by its own path (independently of the
// importer), the SQLite side by SQL. Nothing here reads a file or a database.
//
// Checks (contract §f, brief deliverable 3):
//   * every catalog.json row occurrence lands exactly once in files ∪ quarantine,
//     by (run, ordinal); no two occurrences share one files row;
//   * every distinct agreeing whole-file digest is a `content` row;
//   * every curated value equals its `knowledge_sources.value_json`, or — for a
//     quarantined occurrence — is carried by its `raw_row`;
//   * every derived value is in `derived_unverified` by (digest, kind, seq,
//     source row), and every sha256 sound print in `sound_prints`;
//   * every event decision, event member key (resolved or listed), ledger line,
//     ignored entry, marker file, per-row audit result (with `accepted`
//     recomputed by N1) and pf_cache row is accounted for.
//
// (For Rick: a set-difference report over two snapshots, like a `diff` that
// names each missing line.)

import Foundation

public enum ImportComparator {

    // MARK: - JSON side (re-decoded independently)

    public struct RowOccurrence: Sendable, Equatable {
        public var ordinal: Int
        public var jsonRowID: String
        /// The agreeing whole-file digest, or nil.
        public var digest: String?
        public var knowledge: [CatalogRecordDTO.KnowledgeSourceRow]
        public var derived: [CatalogRecordDTO.DerivedValueRow]
        /// The bound sound print's digest, when the row carries one.
        public var soundPrintDigest: String?

        public init(ordinal: Int, jsonRowID: String, digest: String?,
                    knowledge: [CatalogRecordDTO.KnowledgeSourceRow] = [],
                    derived: [CatalogRecordDTO.DerivedValueRow] = [], soundPrintDigest: String? = nil) {
            self.ordinal = ordinal
            self.jsonRowID = jsonRowID
            self.digest = digest
            self.knowledge = knowledge
            self.derived = derived
            self.soundPrintDigest = soundPrintDigest
        }

        /// From a re-decoded row (the comparator's own decode, not the importer's).
        public init(ordinal: Int, record: VideoRecordJSON) {
            let dto = CatalogRecordDTO(record: record, migrationLoadedAt: 0)
            self.init(ordinal: ordinal, jsonRowID: dto.file.id, digest: dto.digestState.digest,
                      knowledge: dto.knowledgeSources, derived: dto.derivedUnverified,
                      soundPrintDigest: dto.soundPrint?.digest)
        }
    }

    public struct EventMember: Sendable, Equatable, Hashable {
        public var eventID: String
        public var key: String
        public init(eventID: String, key: String) {
            self.eventID = eventID
            self.key = key
        }
    }

    public struct MarkerKey: Sendable, Equatable, Hashable {
        public var sourceFile: CatalogDDL.ImportSourceFile
        public var ordinal: Int
        public init(sourceFile: CatalogDDL.ImportSourceFile, ordinal: Int) {
            self.sourceFile = sourceFile
            self.ordinal = ordinal
        }
    }

    /// One per-row audit result with the facts N1 needs to recompute `accepted`.
    public struct AuditResultOccurrence: Sendable, Equatable {
        public var ordinal: Int
        public var evidence: ImportGate.AuditEvidence
        public var rowFullPath: String
        public var rowAuditSeenAt: Int64?
        public init(ordinal: Int, evidence: ImportGate.AuditEvidence, rowFullPath: String, rowAuditSeenAt: Int64?) {
            self.ordinal = ordinal
            self.evidence = evidence
            self.rowFullPath = rowFullPath
            self.rowAuditSeenAt = rowAuditSeenAt
        }
    }

    public struct JSONSide: Sendable, Equatable {
        public var rows: [RowOccurrence]
        public var eventDecisionOrdinals: [Int]
        public var eventMembers: [EventMember]
        public var ledgerOrdinals: [Int]
        public var ignoredOrdinals: [Int]
        public var markers: [MarkerKey]
        public var auditResults: [AuditResultOccurrence]
        public var auditWindow: ImportGate.AuditWindow
        public var personSearchOrdinals: [Int]

        public init(rows: [RowOccurrence], eventDecisionOrdinals: [Int] = [], eventMembers: [EventMember] = [],
                    ledgerOrdinals: [Int] = [], ignoredOrdinals: [Int] = [], markers: [MarkerKey] = [],
                    auditResults: [AuditResultOccurrence] = [],
                    auditWindow: ImportGate.AuditWindow = ImportGate.AuditWindow(startedAt: 0, finishedAt: 0),
                    personSearchOrdinals: [Int] = []) {
            self.rows = rows
            self.eventDecisionOrdinals = eventDecisionOrdinals
            self.eventMembers = eventMembers
            self.ledgerOrdinals = ledgerOrdinals
            self.ignoredOrdinals = ignoredOrdinals
            self.markers = markers
            self.auditResults = auditResults
            self.auditWindow = auditWindow
            self.personSearchOrdinals = personSearchOrdinals
        }

        /// Every occurrence of a re-decoded catalog file, ordinal = position.
        public static func occurrences(from catalog: CatalogFileJSON) -> [RowOccurrence] {
            catalog.records.enumerated().map { RowOccurrence(ordinal: $0.offset, record: $0.element) }
        }
    }

    // MARK: - SQLite side (read by SQL)

    /// An `import_items` row of item_kind 'row' joined to the row it names.
    public struct FileLanding: Sendable, Equatable {
        public var ordinal: Int
        public var fileID: String
        public init(ordinal: Int, fileID: String) {
            self.ordinal = ordinal
            self.fileID = fileID
        }
    }

    public struct KnowledgeKey: Sendable, Equatable {
        public var ordinal: Int
        public var field: CatalogDDL.KnowledgeField
        public var valueJSON: CatalogJSONValue
        public init(ordinal: Int, field: CatalogDDL.KnowledgeField, valueJSON: CatalogJSONValue) {
            self.ordinal = ordinal
            self.field = field
            self.valueJSON = valueJSON
        }
    }

    public struct DerivedKey: Sendable, Equatable, Hashable {
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

    public struct SQLiteSide: Sendable, Equatable {
        /// Occurrences that landed in `files` (and exist there).
        public var fileLandings: [FileLanding]
        /// Ordinals of `quarantine` rows (origin 'import') of this run.
        public var quarantineOrdinals: [Int]
        /// `quarantine.raw_row` by ordinal.
        public var quarantineRawRows: [Int: [String: CatalogJSONValue]]
        public var contentDigests: Set<String>
        public var knowledgeSources: [KnowledgeKey]
        public var derivedUnverified: Set<DerivedKey>
        public var soundPrintDigests: Set<String>
        public var eventDecisionOrdinals: Set<Int>
        /// `event_members` (event_id, imported_key).
        public var eventMembers: Set<EventMember>
        /// Member keys kept unresolved (stream + `legacy_pair_ids.event_member_keys`).
        public var listedMemberKeys: Set<String>
        public var ledgerOrdinals: Set<Int>
        public var ignoredOrdinals: Set<Int>
        public var markers: Set<MarkerKey>
        /// `audit_results` ordinal → accepted.
        public var auditResults: [Int: Bool]
        public var personSearchOrdinals: Set<Int>

        public init(fileLandings: [FileLanding], quarantineOrdinals: [Int],
                    quarantineRawRows: [Int: [String: CatalogJSONValue]] = [:],
                    contentDigests: Set<String>, knowledgeSources: [KnowledgeKey] = [],
                    derivedUnverified: Set<DerivedKey> = [], soundPrintDigests: Set<String> = [],
                    eventDecisionOrdinals: Set<Int> = [], eventMembers: Set<EventMember> = [],
                    listedMemberKeys: Set<String> = [], ledgerOrdinals: Set<Int> = [],
                    ignoredOrdinals: Set<Int> = [], markers: Set<MarkerKey> = [],
                    auditResults: [Int: Bool] = [:], personSearchOrdinals: Set<Int> = []) {
            self.fileLandings = fileLandings
            self.quarantineOrdinals = quarantineOrdinals
            self.quarantineRawRows = quarantineRawRows
            self.contentDigests = contentDigests
            self.knowledgeSources = knowledgeSources
            self.derivedUnverified = derivedUnverified
            self.soundPrintDigests = soundPrintDigests
            self.eventDecisionOrdinals = eventDecisionOrdinals
            self.eventMembers = eventMembers
            self.listedMemberKeys = listedMemberKeys
            self.ledgerOrdinals = ledgerOrdinals
            self.ignoredOrdinals = ignoredOrdinals
            self.markers = markers
            self.auditResults = auditResults
            self.personSearchOrdinals = personSearchOrdinals
        }
    }

    // MARK: - Verdict

    /// One miss: its kind (for grouping in the report) and its words,
    /// composed where the facts are. (For Rick: constants as data — a
    /// `struct { Kind kind; std::string words; }` with one named factory per
    /// miss class, not a switch that grows with every class.)
    public struct Miss: Sendable, Equatable {
        public enum Kind: String, Sendable, CaseIterable {
            case rowMissing, rowLandedTwice, fileRowShared, rowNotInSource, digestMissing
            case curatedValueMissing, curatedValueDiffers, derivedValueMissing, soundPrintMissing
            case eventDecisionMissing, eventMemberMissing, ledgerLineMissing, ignoredEntryMissing
            case markerMissing, auditResultMissing, auditAcceptanceWrong, personSearchMissing
        }

        public let kind: Kind
        public let words: String

        public init(kind: Kind, words: String) {
            self.kind = kind
            self.words = words
        }

        public static func rowMissing(ordinal: Int, jsonRowID: String) -> Miss {
            Miss(kind: .rowMissing, words: "catalog row \(ordinal) (\(jsonRowID)) landed nowhere")
        }
        public static func rowLandedTwice(ordinal: Int) -> Miss {
            Miss(kind: .rowLandedTwice, words: "catalog row \(ordinal) landed in both files and quarantine")
        }
        public static func fileRowShared(fileID: String, ordinals: [Int]) -> Miss {
            Miss(kind: .fileRowShared,
                 words: "catalog rows \(ordinals.map { String($0) }.joined(separator: ", ")) all landed on file \(fileID)")
        }
        public static func rowNotInSource(ordinal: Int) -> Miss {
            Miss(kind: .rowNotInSource, words: "a landing names catalog row \(ordinal), which the file does not have")
        }
        public static func digestMissing(_ digest: String) -> Miss {
            Miss(kind: .digestMissing, words: "whole-file digest \(digest) has no content row")
        }
        public static func curatedValueMissing(ordinal: Int, field: CatalogDDL.KnowledgeField) -> Miss {
            Miss(kind: .curatedValueMissing, words: "catalog row \(ordinal): its \(field.rawValue) was not kept")
        }
        public static func curatedValueDiffers(ordinal: Int, field: CatalogDDL.KnowledgeField) -> Miss {
            Miss(kind: .curatedValueDiffers,
                 words: "catalog row \(ordinal): its \(field.rawValue) was kept with a different value")
        }
        public static func derivedValueMissing(ordinal: Int, kind: CatalogDDL.DerivedKind, seq: Int) -> Miss {
            Miss(kind: .derivedValueMissing, words: "catalog row \(ordinal): derived \(kind.rawValue) #\(seq) was not kept")
        }
        public static func soundPrintMissing(ordinal: Int, digest: String) -> Miss {
            Miss(kind: .soundPrintMissing, words: "catalog row \(ordinal): its sound print for \(digest) was not kept")
        }
        public static func eventDecisionMissing(ordinal: Int) -> Miss {
            Miss(kind: .eventDecisionMissing, words: "event decision \(ordinal) was not kept")
        }
        public static func eventMemberMissing(eventID: String, key: String) -> Miss {
            Miss(kind: .eventMemberMissing, words: "event \(eventID): member \(key) is neither resolved nor listed")
        }
        public static func ledgerLineMissing(ordinal: Int) -> Miss {
            Miss(kind: .ledgerLineMissing, words: "ledger line \(ordinal) was not kept")
        }
        public static func ignoredEntryMissing(ordinal: Int) -> Miss {
            Miss(kind: .ignoredEntryMissing, words: "ignored entry \(ordinal) was not kept")
        }
        public static func markerMissing(file: String, ordinal: Int) -> Miss {
            Miss(kind: .markerMissing, words: "marker \(file) #\(ordinal) was not kept")
        }
        public static func auditResultMissing(ordinal: Int) -> Miss {
            Miss(kind: .auditResultMissing, words: "audit result \(ordinal) was not kept")
        }
        public static func auditAcceptanceWrong(ordinal: Int, expected: Bool) -> Miss {
            Miss(kind: .auditAcceptanceWrong,
                 words: "audit result \(ordinal) should be \(expected ? "accepted" : "refused") under the snapshot rule")
        }
        public static func personSearchMissing(ordinal: Int) -> Miss {
            Miss(kind: .personSearchMissing, words: "person search \(ordinal) was not kept")
        }
    }

    public enum Verdict: Sendable, Equatable {
        case ok
        case misses([Miss])

        public var isOK: Bool { self == .ok }
    }

    // MARK: - Compare

    public static func compare(json: JSONSide, sqlite: SQLiteSide) -> Verdict {
        var misses: [Miss] = []
        misses += rowMisses(json, sqlite)
        misses += digestMisses(json, sqlite)
        misses += curatedMisses(json, sqlite)
        misses += derivedMisses(json, sqlite)
        misses += sidecarMisses(json, sqlite)
        return misses.isEmpty ? .ok : .misses(misses)
    }

    private static func rowMisses(_ json: JSONSide, _ sqlite: SQLiteSide) -> [Miss] {
        var out: [Miss] = []
        var filesByOrdinal: [Int: Int] = [:]
        var ordinalsByFile: [String: [Int]] = [:]
        for l in sqlite.fileLandings {
            filesByOrdinal[l.ordinal, default: 0] += 1
            ordinalsByFile[l.fileID, default: []].append(l.ordinal)
        }
        var quarantineByOrdinal: [Int: Int] = [:]
        for o in sqlite.quarantineOrdinals { quarantineByOrdinal[o, default: 0] += 1 }

        let sourceOrdinals = Set(json.rows.map(\.ordinal))
        for row in json.rows {
            let landed = (filesByOrdinal[row.ordinal] ?? 0) + (quarantineByOrdinal[row.ordinal] ?? 0)
            if landed == 0 {
                out.append(.rowMissing(ordinal: row.ordinal, jsonRowID: row.jsonRowID))
            } else if landed > 1 {
                out.append(.rowLandedTwice(ordinal: row.ordinal))
            }
        }
        for (fileID, ordinals) in ordinalsByFile.sorted(by: { $0.key < $1.key }) where ordinals.count > 1 {
            out.append(.fileRowShared(fileID: fileID, ordinals: ordinals.sorted()))
        }
        let landedOrdinals = Set(filesByOrdinal.keys).union(quarantineByOrdinal.keys)
        for o in landedOrdinals.subtracting(sourceOrdinals).sorted() {
            out.append(.rowNotInSource(ordinal: o))
        }
        return out
    }

    private static func digestMisses(_ json: JSONSide, _ sqlite: SQLiteSide) -> [Miss] {
        let digests = Set(json.rows.compactMap(\.digest))
        return digests.subtracting(sqlite.contentDigests).sorted().map { Miss.digestMissing($0) }
    }

    private static func curatedMisses(_ json: JSONSide, _ sqlite: SQLiteSide) -> [Miss] {
        var kept: [Int: [CatalogDDL.KnowledgeField: CatalogJSONValue]] = [:]
        for k in sqlite.knowledgeSources { kept[k.ordinal, default: [:]][k.field] = k.valueJSON }
        let quarantined = Set(sqlite.quarantineOrdinals)
        var out: [Miss] = []
        for row in json.rows {
            for value in row.knowledge {
                if let stored = kept[row.ordinal]?[value.field] {
                    if stored != value.valueJSON {
                        out.append(.curatedValueDiffers(ordinal: row.ordinal, field: value.field))
                    }
                    continue
                }
                // Not a knowledge_sources row: a quarantined occurrence may still
                // carry it in raw_row (brief: "present by digest or in raw_row").
                if quarantined.contains(row.ordinal), let raw = sqlite.quarantineRawRows[row.ordinal],
                   let carried = CatalogRecordDTO.knowledgeValue(value.field, raw: raw) {
                    if carried != value.valueJSON {
                        out.append(.curatedValueDiffers(ordinal: row.ordinal, field: value.field))
                    }
                    continue
                }
                out.append(.curatedValueMissing(ordinal: row.ordinal, field: value.field))
            }
        }
        return out
    }

    private static func derivedMisses(_ json: JSONSide, _ sqlite: SQLiteSide) -> [Miss] {
        var out: [Miss] = []
        for row in json.rows {
            // A row with no digest has no derived home (§10b: dropped, re-run
            // after the rescan) — its values stay in quarantine.raw_row.
            guard let digest = row.digest else { continue }
            for d in row.derived {
                let key = DerivedKey(digest: digest, kind: d.kind, seq: d.seq, sourceJSONRowID: row.jsonRowID)
                if !sqlite.derivedUnverified.contains(key) {
                    out.append(.derivedValueMissing(ordinal: row.ordinal, kind: d.kind, seq: d.seq))
                }
            }
            if let printDigest = row.soundPrintDigest, !sqlite.soundPrintDigests.contains(printDigest) {
                out.append(.soundPrintMissing(ordinal: row.ordinal, digest: printDigest))
            }
        }
        return out
    }

    private static func sidecarMisses(_ json: JSONSide, _ sqlite: SQLiteSide) -> [Miss] {
        var out: [Miss] = []
        for o in json.eventDecisionOrdinals where !sqlite.eventDecisionOrdinals.contains(o) {
            out.append(.eventDecisionMissing(ordinal: o))
        }
        for m in json.eventMembers where !sqlite.eventMembers.contains(m) && !sqlite.listedMemberKeys.contains(m.key) {
            out.append(.eventMemberMissing(eventID: m.eventID, key: m.key))
        }
        for o in json.ledgerOrdinals where !sqlite.ledgerOrdinals.contains(o) {
            out.append(.ledgerLineMissing(ordinal: o))
        }
        for o in json.ignoredOrdinals where !sqlite.ignoredOrdinals.contains(o) {
            out.append(.ignoredEntryMissing(ordinal: o))
        }
        for m in json.markers where !sqlite.markers.contains(m) {
            out.append(.markerMissing(file: m.sourceFile.rawValue, ordinal: m.ordinal))
        }
        for a in json.auditResults {
            guard let accepted = sqlite.auditResults[a.ordinal] else {
                out.append(.auditResultMissing(ordinal: a.ordinal))
                continue
            }
            let expected = ImportGate.accepts(a.evidence, rowFullPath: a.rowFullPath,
                                              rowAuditSeenAt: a.rowAuditSeenAt, window: json.auditWindow)
            if accepted != expected { out.append(.auditAcceptanceWrong(ordinal: a.ordinal, expected: expected)) }
        }
        for o in json.personSearchOrdinals where !sqlite.personSearchOrdinals.contains(o) {
            out.append(.personSearchMissing(ordinal: o))
        }
        return out
    }
}
