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
// Checks (contract §f, brief deliverable 3; fix 2026-10-17, codex D′ #1/#3):
//   * every catalog.json row occurrence lands exactly once in files ∪ quarantine,
//     by (run, ordinal), IN THE TABLE THE GATE SAYS, on the row with ITS id and
//     ITS digest; no two occurrences share one files row;
//   * every distinct agreeing whole-file digest is a `content` row;
//   * every curated value equals its `knowledge_sources.value_json` AND hangs on
//     the occurrence's own row id and digest, or — for a quarantined
//     occurrence — is carried by its `raw_row`;
//   * every derived value is in `derived_unverified` by (digest, kind, seq,
//     source row), and every sha256 sound print in `sound_prints`;
//   * the sidecar rows the JSON side would write — events, decisions, ignored
//     entries, ledger lines, audit results, markers (with the file's hash) —
//     EQUAL the rows read back, by ordinal; the RESOLVED event members (digest
//     and range per event) equal `event_members`; an unresolvable member key
//     is listed; every pf_cache row is accounted for.
//
// (For Rick: a set-difference report over two snapshots, like a `diff` that
// names each missing or differing line.)

import Foundation

public enum ImportComparator {

    // MARK: - JSON side (re-decoded independently)

    /// Where the gate (plus the preflight) says an occurrence lands.
    public struct ExpectedLanding: Sendable, Equatable {
        public var table: CatalogDDL.LandedTable
        /// The quarantine reason; nil for a files landing.
        public var reason: CatalogDDL.ReasonCode?

        public static let files = ExpectedLanding(table: .files, reason: nil)
        public static func quarantine(_ reason: CatalogDDL.ReasonCode) -> ExpectedLanding {
            ExpectedLanding(table: .quarantine, reason: reason)
        }

        /// An unrepresentable occurrence wrote no content, derived or bound
        /// row: its digest has no content row through it, its knowledge hangs
        /// on no digest (codex D′ #6).
        public var isUnrepresentable: Bool { reason == .unrepresentable }
    }

    /// What the gate needs from a re-decoded row to say where it lands.
    public struct GateFacts: Sendable, Equatable {
        public var digestState: CatalogRecordDTO.DigestState
        public var markerSet: Bool
        public var fullPath: String
        public var auditSeenAt: Int64?
        public var pairGroupID: String?
        public var preflight: RowPreflight.Report

        public init(digestState: CatalogRecordDTO.DigestState, markerSet: Bool, fullPath: String, auditSeenAt: Int64?,
                    pairGroupID: String?, preflight: RowPreflight.Report) {
            self.digestState = digestState
            self.markerSet = markerSet
            self.fullPath = fullPath
            self.auditSeenAt = auditSeenAt
            self.pairGroupID = pairGroupID
            self.preflight = preflight
        }
    }

    public struct RowOccurrence: Sendable, Equatable {
        public var ordinal: Int
        public var jsonRowID: String
        /// The agreeing whole-file digest, or nil.
        public var digest: String?
        public var knowledge: [CatalogRecordDTO.KnowledgeSourceRow]
        public var derived: [CatalogRecordDTO.DerivedValueRow]
        /// The bound sound print's digest, when the row carries one.
        public var soundPrintDigest: String?
        /// The gate's facts (nil for a hand-built occurrence).
        public var gate: GateFacts?
        /// Where this occurrence must have landed; nil = identity not checked.
        public var expected: ExpectedLanding?

        public init(ordinal: Int, jsonRowID: String, digest: String?,
                    knowledge: [CatalogRecordDTO.KnowledgeSourceRow] = [],
                    derived: [CatalogRecordDTO.DerivedValueRow] = [], soundPrintDigest: String? = nil,
                    gate: GateFacts? = nil, expected: ExpectedLanding? = nil) {
            self.ordinal = ordinal
            self.jsonRowID = jsonRowID
            self.digest = digest
            self.knowledge = knowledge
            self.derived = derived
            self.soundPrintDigest = soundPrintDigest
            self.gate = gate
            self.expected = expected
        }

        /// From a re-decoded row (the comparator's own decode, not the importer's).
        public init(ordinal: Int, record: VideoRecordJSON) {
            let dto = CatalogRecordDTO(record: record, migrationLoadedAt: 0)
            let facts = GateFacts(digestState: dto.digestState, markerSet: dto.removal != nil, fullPath: dto.file.fullPath,
                                  auditSeenAt: dto.auditStamp?.auditSeenAt, pairGroupID: dto.legacyPairIDs?.pairGroupID,
                                  preflight: RowPreflight.report(dto))
            self.init(ordinal: ordinal, jsonRowID: dto.file.id, digest: dto.digestState.digest,
                      knowledge: dto.knowledgeSources, derived: dto.derivedUnverified,
                      soundPrintDigest: dto.soundPrint?.digest, gate: facts)
        }

        /// The digest this occurrence's content / derived / knowledge rows
        /// hang on: none when the row is unrepresentable (codex D′ #6).
        public var boundDigest: String? { expected?.isUnrepresentable == true ? nil : digest }
    }

    /// A member key that did not resolve (listed, never dropped).
    public struct EventMember: Sendable, Equatable, Hashable {
        public var eventID: String
        public var key: String
        public init(eventID: String, key: String) {
            self.eventID = eventID
            self.key = key
        }
    }

    /// One resolved `event_members` row (codex D′ #1): the digest and range
    /// per event. The key is deliberately NOT part of it: two keys that
    /// resolve to one digest are one row.
    public struct ResolvedMember: Sendable, Hashable {
        public var eventID: String
        public var digest: String
        public var rangeStart: Double?
        public var rangeEnd: Double?
        public init(eventID: String, digest: String, rangeStart: Double? = nil, rangeEnd: Double? = nil) {
            self.eventID = eventID
            self.digest = digest
            self.rangeStart = rangeStart
            self.rangeEnd = rangeEnd
        }

        var words: String {
            let range = rangeStart.map { "\($0)–\(rangeEnd ?? $0) s" } ?? "whole file"
            return "event \(eventID): member \(digest.prefix(12))… (\(range))"
        }
    }

    public struct MarkerKey: Sendable, Equatable, Hashable {
        public var sourceFile: CatalogDDL.ImportSourceFile
        public var ordinal: Int
        /// The SHA-256 of the file the marker came from (codex D′ #3/#4); nil = not checked.
        public var fileSHA256: String?
        public init(sourceFile: CatalogDDL.ImportSourceFile, ordinal: Int, fileSHA256: String? = nil) {
            self.sourceFile = sourceFile
            self.ordinal = ordinal
            self.fileSHA256 = fileSHA256
        }
    }

    public struct JSONSide: Sendable, Equatable {
        public var rows: [RowOccurrence]
        public var events: [CatalogRow.Event]
        public var eventDecisions: [CatalogRow.EventDecision]
        public var resolvedMembers: Set<ResolvedMember>
        public var listedMembers: [EventMember]
        public var ledgerLines: [CatalogRow.Ledger]
        public var ignoredEntries: [CatalogRow.Ignored]
        public var markers: [MarkerKey]
        public var auditResults: [CatalogRow.AuditResult]
        public var personSearchOrdinals: [Int]

        public init(rows: [RowOccurrence], events: [CatalogRow.Event] = [], eventDecisions: [CatalogRow.EventDecision] = [],
                    resolvedMembers: Set<ResolvedMember> = [], listedMembers: [EventMember] = [],
                    ledgerLines: [CatalogRow.Ledger] = [], ignoredEntries: [CatalogRow.Ignored] = [],
                    markers: [MarkerKey] = [], auditResults: [CatalogRow.AuditResult] = [],
                    personSearchOrdinals: [Int] = []) {
            self.rows = rows
            self.events = events
            self.eventDecisions = eventDecisions
            self.resolvedMembers = resolvedMembers
            self.listedMembers = listedMembers
            self.ledgerLines = ledgerLines
            self.ignoredEntries = ignoredEntries
            self.markers = markers
            self.auditResults = auditResults
            self.personSearchOrdinals = personSearchOrdinals
        }

        /// Every occurrence of a re-decoded catalog file, ordinal = position.
        public static func occurrences(from catalog: CatalogFileJSON) -> [RowOccurrence] {
            catalog.records.enumerated().map { RowOccurrence(ordinal: $0.offset, record: $0.element) }
        }

        /// Where each occurrence must land (codex D′ #1): the gate's verdict
        /// on the re-decoded facts, then the preflight (codex D′ #6).
        public static func expectLandings(_ rows: inout [RowOccurrence], evidence: [String: ImportGate.AuditEvidence],
                                          window: ImportGate.AuditWindow, findings: [String: [ImportGate.Finding]]) {
            var occurrences: [String: Int] = [:]
            for row in rows { occurrences[row.jsonRowID, default: 0] += 1 }
            for i in rows.indices {
                guard let facts = rows[i].gate else { continue }
                let input = ImportGate.Input(occurrences: occurrences[rows[i].jsonRowID] ?? 1, digest: facts.digestState,
                                             markerSet: facts.markerSet, audit: evidence[rows[i].jsonRowID],
                                             rowFullPath: facts.fullPath, rowAuditSeenAt: facts.auditSeenAt,
                                             auditWindow: window, findings: findings[rows[i].jsonRowID] ?? [])
                rows[i].expected = Self.landing(ImportGate.decide(input), preflight: facts.preflight)
            }
        }

        /// The gate's landing as an expectation, the preflight overriding it.
        public static func landing(_ gate: ImportGate.Landing, preflight: RowPreflight.Report) -> ExpectedLanding {
            if !preflight.violations(for: gate).isEmpty { return .quarantine(.unrepresentable) }
            switch gate {
            case .main: return .files
            case .quarantine(let reason, _, _): return .quarantine(reason)
            }
        }
    }

    // MARK: - SQLite side (read by SQL)

    /// An `import_items` row of item_kind 'row' joined to the files row it names.
    public struct FileLanding: Sendable, Equatable {
        public var ordinal: Int
        public var fileID: String
        /// `files.content_digest`; nil = not read (a hand-built side).
        public var digest: String?
        public init(ordinal: Int, fileID: String, digest: String? = nil) {
            self.ordinal = ordinal
            self.fileID = fileID
            self.digest = digest
        }
    }

    /// An `import_items` row of item_kind 'row' joined to the quarantine row it names.
    public struct QuarantineLanding: Sendable, Equatable {
        public var ordinal: Int
        public var jsonRowID: String
        public var digest: String?
        public init(ordinal: Int, jsonRowID: String, digest: String? = nil) {
            self.ordinal = ordinal
            self.jsonRowID = jsonRowID
            self.digest = digest
        }
    }

    public struct KnowledgeKey: Sendable, Equatable {
        public var ordinal: Int
        public var field: CatalogDDL.KnowledgeField
        public var valueJSON: CatalogJSONValue
        /// The binding (codex D′ #1): the row id and digest the value hangs on.
        public var jsonRowID: String
        public var digest: String?
        public init(ordinal: Int, field: CatalogDDL.KnowledgeField, valueJSON: CatalogJSONValue,
                    jsonRowID: String = "", digest: String? = nil) {
            self.ordinal = ordinal
            self.field = field
            self.valueJSON = valueJSON
            self.jsonRowID = jsonRowID
            self.digest = digest
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
        public var fileLandings: [FileLanding]
        public var quarantineLandings: [QuarantineLanding]
        /// `quarantine.raw_row` by ordinal.
        public var quarantineRawRows: [Int: [String: CatalogJSONValue]]
        public var contentDigests: Set<String>
        public var knowledgeSources: [KnowledgeKey]
        public var derivedUnverified: Set<DerivedKey>
        public var soundPrintDigests: Set<String>
        public var events: [CatalogRow.Event]
        public var eventDecisions: [CatalogRow.EventDecision]
        public var eventMembers: Set<ResolvedMember>
        /// Member keys kept unresolved (stream + `legacy_pair_ids.event_member_keys`).
        public var listedMemberKeys: Set<String>
        public var ledgerLines: [CatalogRow.Ledger]
        public var ignoredEntries: [CatalogRow.Ignored]
        public var markers: Set<MarkerKey>
        public var auditResults: [CatalogRow.AuditResult]
        public var personSearchOrdinals: Set<Int>

        public init(fileLandings: [FileLanding], quarantineLandings: [QuarantineLanding] = [],
                    quarantineRawRows: [Int: [String: CatalogJSONValue]] = [:],
                    contentDigests: Set<String>, knowledgeSources: [KnowledgeKey] = [],
                    derivedUnverified: Set<DerivedKey> = [], soundPrintDigests: Set<String> = [],
                    events: [CatalogRow.Event] = [], eventDecisions: [CatalogRow.EventDecision] = [],
                    eventMembers: Set<ResolvedMember> = [], listedMemberKeys: Set<String> = [],
                    ledgerLines: [CatalogRow.Ledger] = [], ignoredEntries: [CatalogRow.Ignored] = [],
                    markers: Set<MarkerKey> = [], auditResults: [CatalogRow.AuditResult] = [],
                    personSearchOrdinals: Set<Int> = []) {
            self.fileLandings = fileLandings
            self.quarantineLandings = quarantineLandings
            self.quarantineRawRows = quarantineRawRows
            self.contentDigests = contentDigests
            self.knowledgeSources = knowledgeSources
            self.derivedUnverified = derivedUnverified
            self.soundPrintDigests = soundPrintDigests
            self.events = events
            self.eventDecisions = eventDecisions
            self.eventMembers = eventMembers
            self.listedMemberKeys = listedMemberKeys
            self.ledgerLines = ledgerLines
            self.ignoredEntries = ignoredEntries
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
            case rowMissing, rowLandedTwice, rowLandedElsewhere, rowIdentityWrong, rowDigestWrong, fileRowShared, rowNotInSource
            case digestMissing, curatedValueMissing, curatedValueDiffers, curatedBindingWrong
            case derivedValueMissing, soundPrintMissing
            case eventMissing, eventDiffers, eventDecisionMissing, eventDecisionDiffers
            case eventMemberMissing, eventMemberNotInSource
            case ledgerLineMissing, ledgerLineDiffers, ignoredEntryMissing, ignoredEntryDiffers
            case markerMissing, markerDiffers, auditResultMissing, auditResultDiffers, auditAcceptanceWrong
            case personSearchMissing
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
        public static func rowLandedElsewhere(ordinal: Int, expected: ExpectedLanding, actual: CatalogDDL.LandedTable) -> Miss {
            let where_ = expected.reason.map { "quarantine (\($0.rawValue))" } ?? "files"
            return Miss(kind: .rowLandedElsewhere, words: "catalog row \(ordinal) belongs in \(where_) but landed in \(actual.rawValue)")
        }
        public static func rowIdentityWrong(ordinal: Int, jsonRowID: String, landedOn: String) -> Miss {
            Miss(kind: .rowIdentityWrong, words: "catalog row \(ordinal) (\(jsonRowID)) landed on the row of \(landedOn)")
        }
        public static func rowDigestWrong(ordinal: Int, expected: String?, actual: String?) -> Miss {
            Miss(kind: .rowDigestWrong,
                 words: "catalog row \(ordinal) landed with digest \(actual ?? "none"), not its own \(expected ?? "none")")
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
        public static func curatedBindingWrong(ordinal: Int, field: CatalogDDL.KnowledgeField) -> Miss {
            Miss(kind: .curatedBindingWrong,
                 words: "catalog row \(ordinal): its \(field.rawValue) was kept, but bound to another row or digest")
        }
        public static func derivedValueMissing(ordinal: Int, kind: CatalogDDL.DerivedKind, seq: Int) -> Miss {
            Miss(kind: .derivedValueMissing, words: "catalog row \(ordinal): derived \(kind.rawValue) #\(seq) was not kept")
        }
        public static func soundPrintMissing(ordinal: Int, digest: String) -> Miss {
            Miss(kind: .soundPrintMissing, words: "catalog row \(ordinal): its sound print for \(digest) was not kept")
        }
        public static func eventMissing(ordinal: Int) -> Miss {
            Miss(kind: .eventMissing, words: "event record \(ordinal) was not kept")
        }
        public static func eventDiffers(ordinal: Int) -> Miss {
            Miss(kind: .eventDiffers, words: "event record \(ordinal) was kept with other values")
        }
        public static func eventDecisionMissing(ordinal: Int) -> Miss {
            Miss(kind: .eventDecisionMissing, words: "event decision \(ordinal) was not kept")
        }
        public static func eventDecisionDiffers(ordinal: Int) -> Miss {
            Miss(kind: .eventDecisionDiffers, words: "event decision \(ordinal) was kept with another payload")
        }
        public static func eventMemberMissing(eventID: String, key: String) -> Miss {
            Miss(kind: .eventMemberMissing, words: "event \(eventID): member \(key) is neither resolved nor listed")
        }
        public static func eventMemberMissing(_ member: ResolvedMember) -> Miss {
            Miss(kind: .eventMemberMissing, words: "\(member.words) is not in event_members")
        }
        public static func eventMemberNotInSource(_ member: ResolvedMember) -> Miss {
            Miss(kind: .eventMemberNotInSource, words: "\(member.words) is in event_members, but no decision resolves to it")
        }
        public static func ledgerLineMissing(ordinal: Int) -> Miss {
            Miss(kind: .ledgerLineMissing, words: "ledger line \(ordinal) was not kept")
        }
        public static func ledgerLineDiffers(ordinal: Int) -> Miss {
            Miss(kind: .ledgerLineDiffers, words: "ledger line \(ordinal) was kept with other words")
        }
        public static func ignoredEntryMissing(ordinal: Int) -> Miss {
            Miss(kind: .ignoredEntryMissing, words: "ignored entry \(ordinal) was not kept")
        }
        public static func ignoredEntryDiffers(ordinal: Int) -> Miss {
            Miss(kind: .ignoredEntryDiffers, words: "ignored entry \(ordinal) was kept with other values")
        }
        public static func markerMissing(file: String, ordinal: Int) -> Miss {
            Miss(kind: .markerMissing, words: "marker \(file) #\(ordinal) was not kept")
        }
        public static func markerDiffers(file: String, ordinal: Int) -> Miss {
            Miss(kind: .markerDiffers, words: "marker \(file) #\(ordinal) was kept from other bytes than the file holds")
        }
        public static func auditResultMissing(ordinal: Int) -> Miss {
            Miss(kind: .auditResultMissing, words: "audit result \(ordinal) was not kept")
        }
        public static func auditResultDiffers(ordinal: Int) -> Miss {
            Miss(kind: .auditResultDiffers, words: "audit result \(ordinal) was kept with other words")
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
        misses += eventMisses(json, sqlite)
        misses += sidecarMisses(json, sqlite)
        misses += auditMisses(json, sqlite)
        return misses.isEmpty ? .ok : .misses(misses)
    }

    private static func rowMisses(_ json: JSONSide, _ sqlite: SQLiteSide) -> [Miss] {
        var out: [Miss] = []
        var files: [Int: [FileLanding]] = [:]
        var ordinalsByFile: [String: [Int]] = [:]
        for l in sqlite.fileLandings {
            files[l.ordinal, default: []].append(l)
            ordinalsByFile[l.fileID, default: []].append(l.ordinal)
        }
        var quarantine: [Int: [QuarantineLanding]] = [:]
        for q in sqlite.quarantineLandings { quarantine[q.ordinal, default: []].append(q) }

        let sourceOrdinals = Set(json.rows.map(\.ordinal))
        for row in json.rows {
            let inFiles = files[row.ordinal] ?? []
            let inQuarantine = quarantine[row.ordinal] ?? []
            switch inFiles.count + inQuarantine.count {
            case 0: out.append(.rowMissing(ordinal: row.ordinal, jsonRowID: row.jsonRowID))
            case 1: out += identityMisses(row, file: inFiles.first, quarantine: inQuarantine.first)
            default: out.append(.rowLandedTwice(ordinal: row.ordinal))
            }
        }
        for (fileID, ordinals) in ordinalsByFile.sorted(by: { $0.key < $1.key }) where ordinals.count > 1 {
            out.append(.fileRowShared(fileID: fileID, ordinals: ordinals.sorted()))
        }
        let landedOrdinals = Set(files.keys).union(quarantine.keys)
        for o in landedOrdinals.subtracting(sourceOrdinals).sorted() {
            out.append(.rowNotInSource(ordinal: o))
        }
        return out
    }

    /// codex D′ #1: the one landing is in the table the gate says, on the row
    /// that carries THIS occurrence's id, with THIS occurrence's digest.
    private static func identityMisses(_ row: RowOccurrence, file: FileLanding?, quarantine: QuarantineLanding?) -> [Miss] {
        let actual: CatalogDDL.LandedTable = file != nil ? .files : .quarantine
        if let expected = row.expected, expected.table != actual {
            return [.rowLandedElsewhere(ordinal: row.ordinal, expected: expected, actual: actual)]
        }
        let landedID = file?.fileID ?? quarantine?.jsonRowID ?? ""
        if landedID != row.jsonRowID {
            return [.rowIdentityWrong(ordinal: row.ordinal, jsonRowID: row.jsonRowID, landedOn: landedID)]
        }
        // A files row always carries its digest (NOT NULL): nil there is a hand-built side that did not read it.
        if let file, file.digest == nil { return [] }
        let landedDigest = file?.digest ?? quarantine?.digest
        if landedDigest != row.digest {
            return [.rowDigestWrong(ordinal: row.ordinal, expected: row.digest, actual: landedDigest)]
        }
        return []
    }

    private static func digestMisses(_ json: JSONSide, _ sqlite: SQLiteSide) -> [Miss] {
        let digests = Set(json.rows.compactMap(\.boundDigest))
        return digests.subtracting(sqlite.contentDigests).sorted().map { Miss.digestMissing($0) }
    }

    private static func curatedMisses(_ json: JSONSide, _ sqlite: SQLiteSide) -> [Miss] {
        var kept: [Int: [CatalogDDL.KnowledgeField: KnowledgeKey]] = [:]
        for k in sqlite.knowledgeSources { kept[k.ordinal, default: [:]][k.field] = k }
        let quarantined = Set(sqlite.quarantineLandings.map(\.ordinal))
        var out: [Miss] = []
        for row in json.rows {
            for value in row.knowledge {
                if let stored = kept[row.ordinal]?[value.field] {
                    if stored.valueJSON != value.valueJSON {
                        out.append(.curatedValueDiffers(ordinal: row.ordinal, field: value.field))
                    } else if !isBound(stored, to: row) {
                        out.append(.curatedBindingWrong(ordinal: row.ordinal, field: value.field))
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

    /// codex D′ #1: the value hangs on THIS occurrence's row id and digest
    /// (no digest when the occurrence is unrepresentable). An empty stored
    /// row id is a hand-built side that did not read it.
    private static func isBound(_ key: KnowledgeKey, to row: RowOccurrence) -> Bool {
        (key.jsonRowID.isEmpty || key.jsonRowID == row.jsonRowID) && key.digest == row.boundDigest
    }

    private static func derivedMisses(_ json: JSONSide, _ sqlite: SQLiteSide) -> [Miss] {
        var out: [Miss] = []
        for row in json.rows {
            // A row with no digest has no derived home (§10b: dropped, re-run
            // after the rescan) — its values stay in quarantine.raw_row.
            guard let digest = row.boundDigest else { continue }
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

    /// codex D′ #1/#3: event records and decisions by payload; the RESOLVED
    /// members as a set (missing and strangers both named); listed keys listed.
    private static func eventMisses(_ json: JSONSide, _ sqlite: SQLiteSide) -> [Miss] {
        var out: [Miss] = []
        out += byOrdinal(json.events, sqlite.events, ordinal: \.sourceOrdinal, missing: Miss.eventMissing, differs: Miss.eventDiffers)
        out += byOrdinal(json.eventDecisions, sqlite.eventDecisions, ordinal: \.sourceOrdinal,
                         missing: Miss.eventDecisionMissing, differs: Miss.eventDecisionDiffers)
        for m in json.resolvedMembers.subtracting(sqlite.eventMembers).sorted(by: { $0.words < $1.words }) {
            out.append(.eventMemberMissing(m))
        }
        for m in sqlite.eventMembers.subtracting(json.resolvedMembers).sorted(by: { $0.words < $1.words }) {
            out.append(.eventMemberNotInSource(m))
        }
        for m in json.listedMembers where !sqlite.listedMemberKeys.contains(m.key) {
            out.append(.eventMemberMissing(eventID: m.eventID, key: m.key))
        }
        return out
    }

    /// codex D′ #3: ledger lines, ignored entries and markers by payload.
    private static func sidecarMisses(_ json: JSONSide, _ sqlite: SQLiteSide) -> [Miss] {
        var out: [Miss] = []
        out += byOrdinal(json.ledgerLines, sqlite.ledgerLines, ordinal: \.sourceOrdinal,
                         missing: Miss.ledgerLineMissing, differs: Miss.ledgerLineDiffers)
        out += byOrdinal(json.ignoredEntries, sqlite.ignoredEntries, ordinal: \.sourceOrdinal,
                         missing: Miss.ignoredEntryMissing, differs: Miss.ignoredEntryDiffers)
        var markers: [MarkerKey: String?] = [:]
        for m in sqlite.markers { markers[MarkerKey(sourceFile: m.sourceFile, ordinal: m.ordinal)] = m.fileSHA256 }
        for m in json.markers {
            guard let stored = markers[MarkerKey(sourceFile: m.sourceFile, ordinal: m.ordinal)] else {
                out.append(.markerMissing(file: m.sourceFile.rawValue, ordinal: m.ordinal))
                continue
            }
            if let hash = m.fileSHA256, stored != hash { out.append(.markerDiffers(file: m.sourceFile.rawValue, ordinal: m.ordinal)) }
        }
        for o in json.personSearchOrdinals where !sqlite.personSearchOrdinals.contains(o) {
            out.append(.personSearchMissing(ordinal: o))
        }
        return out
    }

    /// codex D′ #3/#4: every audit row by its whole payload; `accepted` (N1,
    /// recomputed from the re-decoded facts) is named on its own.
    private static func auditMisses(_ json: JSONSide, _ sqlite: SQLiteSide) -> [Miss] {
        var stored: [Int: CatalogRow.AuditResult] = [:]
        for a in sqlite.auditResults { stored[a.sourceOrdinal] = a }
        var out: [Miss] = []
        for a in json.auditResults {
            guard let there = stored[a.sourceOrdinal] else {
                out.append(.auditResultMissing(ordinal: a.sourceOrdinal))
                continue
            }
            if there.accepted != a.accepted {
                out.append(.auditAcceptanceWrong(ordinal: a.sourceOrdinal, expected: a.accepted))
            } else if there != a {
                out.append(.auditResultDiffers(ordinal: a.sourceOrdinal))
            }
        }
        return out
    }

    /// Expected rows against stored rows by ordinal: missing, or not equal.
    private static func byOrdinal<Row: Equatable>(_ expected: [Row], _ actual: [Row], ordinal: (Row) -> Int,
                                                  missing: (Int) -> Miss, differs: (Int) -> Miss) -> [Miss] {
        var stored: [Int: Row] = [:]
        for row in actual { stored[ordinal(row)] = row }
        var out: [Miss] = []
        for row in expected {
            let o = ordinal(row)
            guard let there = stored[o] else {
                out.append(missing(o))
                continue
            }
            if there != row { out.append(differs(o)) }
        }
        return out
    }
}
