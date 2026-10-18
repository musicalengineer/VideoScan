// CatalogRecordDiff.swift
// What differs between the row the store holds (read back as a load would
// give it, then mapped like any record) and the record the app holds now —
// part by part, so a commit writes only what changed (cutover B2):
//   * a curated field nobody touched keeps its display row, including a
//     CONFLICT (shown empty on both sides → equal → not written, so a
//     conflict is never resolved silently by an unrelated edit — Rick's
//     decision 1, 2026-10-17);
//   * a derived kind nobody touched keeps its provenance (an unverified
//     value is not rewritten as bound because a star changed beside it).
// Pure: two DTOs in, a value out. Both sides come from the SAME mapping
// (`CatalogRecordDTO.init(snapshot:)`), so equal state compares equal.
//
// (For Rick: a structural diff of two PODs, grouped by the table each part
// lands in.)

import Foundation

public struct CatalogRecordDiff: Sendable, Equatable {
    /// The `files` columns (removal marker included) or the volume names.
    public var file = false
    /// The removal marker (state, dates, path, revision).
    public var marker = false
    public var archiveCopy = false
    public var backups = false
    public var footageDecisions = false
    public var duplicate = false
    public var soundPrint = false
    /// The knowledge fields whose verbatim value differs.
    public var knowledge: [CatalogDDL.KnowledgeField] = []
    public var pair = false
    public var derived: [CatalogDDL.DerivedKind] = []

    public var isEmpty: Bool {
        !file && !marker && !archiveCopy && !backups && !footageDecisions && !duplicate && !soundPrint
            && knowledge.isEmpty && !pair && derived.isEmpty
    }

    /// `stored` nil = a row the store does not have yet: everything the
    /// record carries is new.
    public init(stored: CatalogRecordDTO?, current: CatalogRecordDTO) {
        self.init()
        guard let stored else {
            describeNew(current)
            return
        }
        file = Self.comparable(stored.file) != Self.comparable(current.file) || stored.volume != current.volume
        marker = Self.marker(stored.file) != Self.marker(current.file)
        archiveCopy = stored.archiveCopy != current.archiveCopy
        backups = stored.backupDestinations != current.backupDestinations
        footageDecisions = stored.curated.footageDecisions != current.curated.footageDecisions
        duplicate = stored.duplicateMember != current.duplicateMember
        soundPrint = stored.soundPrint != current.soundPrint
        knowledge = CatalogDDL.KnowledgeField.allCases.filter {
            CatalogRecordDTO.knowledgeValue($0, raw: stored.raw) != CatalogRecordDTO.knowledgeValue($0, raw: current.raw)
        }
        pair = stored.pairLink != current.pairLink
        derived = CatalogDDL.DerivedKind.allCases.filter { kind in
            stored.derivedUnverified.filter { $0.kind == kind } != current.derivedUnverified.filter { $0.kind == kind }
        }
    }

    private init() {}

    /// Keep a SHARED curated field (one every copy of the content shows)
    /// only when the record itself changed it since its own baseline
    /// (cutover B2.1, codex P1-1): a sibling's stale copy is never a reason
    /// to write. Row-scoped knowledge is untouched.
    public mutating func restrictShared(to edited: Set<CatalogDDL.KnowledgeField>) {
        knowledge = knowledge.filter { !CatalogCommitWords.sharedByCopies.contains($0) || edited.contains($0) }
    }

    private mutating func describeNew(_ current: CatalogRecordDTO) {
        file = true
        marker = false            // a new row's marker is its first state (the insert trigger records it)
        archiveCopy = current.archiveCopy != nil
        backups = !current.backupDestinations.isEmpty
        footageDecisions = !current.curated.footageDecisions.isEmpty
        duplicate = current.duplicateMember != nil
        soundPrint = current.soundPrint != nil
        knowledge = current.curatedFields
        pair = current.pairLink != nil
        derived = Array(Set(current.derivedUnverified.map(\.kind))).sorted { $0.rawValue < $1.rawValue }
    }

    /// The columns a commit writes, as the store keeps them: the importer's
    /// own storable() shape (a lone embedded date lives in probe_extra), and
    /// `catalogued_at`, which no record carries, set aside.
    static func comparable(_ file: CatalogRecordDTO.FileRow) -> CatalogRecordDTO.FileRow {
        var f = OccurrenceWriter.storable(file)
        f.cataloguedAt = nil
        return f
    }

    static func marker(_ f: CatalogRecordDTO.FileRow) -> [String?] {
        [f.removalState, f.removalSince.map(String.init), f.removalReason, f.removalTrashPath,
         f.removalTrashEmptiedAt.map(String.init), f.removalLastSeen.map(String.init), String(f.removalRevision)]
    }
}
