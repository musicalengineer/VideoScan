// CatalogLoadedRow.swift
// Everything a SQLite load reads for ONE `files` row — the domain value the
// store streams to the loader (cutover B1, docs/design/
// catalog_cutover_f_prime_2026_10_17.md §2 "The read side"). Raw SQL stays
// in Store/; this is plain data, `Sendable`, built from the same
// table-shaped values the importer wrote (`CatalogRecordDTO`'s nested rows),
// so the load is visibly the reverse of the import.
//
// Where each part comes from:
//   file, volume        files ⋈ volumes
//   archiveCopy         archive_copies (archiveFixity + archivedAt)
//   backupDestinations  backup_destinations
//   soundPrint          sound_prints (by digest: bound, sha256 only)
//   shown               the display tables by digest (stars, user_dates, …);
//                       a field whose copies disagree is EMPTY and listed in
//                       `shown.conflicts` (Rick's go, §10 decision 1)
//   rowKnowledge        knowledge_sources of the occurrence that became this
//                       row, for the four row-scoped values no table can give
//                       back by row id: lineage (derivedFrom names a ROW, the
//                       lineage table is digest → digest), supersededByID,
//                       repairConfirmedDate, and archivedAt when the row has
//                       no archive copy
//   footageDecisions    footage_decisions (row_id)
//   pair                legacy_pair_ids of the occurrence
//   duplicate           duplicate_members ⋈ duplicate_groups (+ member count)
//   derived             bound tables by digest, else the row's own
//                       derived_unverified values (`unverifiedDerived` counts
//                       those — "values from before the port")
//
// (For Rick: a fat POD — one struct per joined row, filled by the store's
// cursor, consumed once by the app.)

import Foundation

public struct CatalogLoadedRow: Sendable, Equatable {

    /// The display-table values a content shows, conflicts already emptied.
    public struct Shown: Sendable, Equatable {
        public var starRating: Int?
        public var userNotes: String?
        public var mediaDisposition: String?
        public var userDate: CatalogRecordDTO.UserDateRow?
        public var userPlace: CatalogRecordDTO.UserPlaceRow?
        public var familyMusic: CatalogRecordDTO.FamilyMusicRow?
        public var tags: [String] = []
        public var confirmedPeople: [CatalogRecordDTO.PeopleTagRow] = []
        public var rejectedPeople: [String] = []
        public var backupAttestations: [CatalogRecordDTO.BackupAttestationRow] = []
        /// The fields shown empty because the copies disagree.
        public var conflicts: [CatalogDDL.KnowledgeField] = []

        public init() {}
    }

    /// `legacy_pair_ids`, verbatim.
    public struct PairIDs: Sendable, Equatable {
        public var pairedWithID: String?
        public var pairGroupID: String?

        public init(pairedWithID: String?, pairGroupID: String?) {
            self.pairedWithID = pairedWithID
            self.pairGroupID = pairGroupID
        }
    }

    public var file: CatalogRecordDTO.FileRow
    public var volume: CatalogRecordDTO.VolumeRowDTO
    public var archiveCopy: CatalogRecordDTO.ArchiveCopyRow?
    public var backupDestinations: [CatalogRecordDTO.BackupDestinationRow] = []
    public var soundPrint: CatalogRecordDTO.SoundPrintRow?
    public var shown = Shown()
    public var rowKnowledge: [CatalogDDL.KnowledgeField: CatalogJSONValue] = [:]
    public var footageDecisions: [CatalogRecordDTO.FootageDecisionRow] = []
    public var pair: PairIDs?
    public var duplicate: CatalogRecordDTO.DuplicateMemberRow?
    public var duplicateGroupCount = 0
    public var derived: [CatalogRecordDTO.DerivedValueRow] = []
    /// How many of `derived` came from `derived_unverified`.
    public var unverifiedDerived = 0

    public init(file: CatalogRecordDTO.FileRow, volume: CatalogRecordDTO.VolumeRowDTO) {
        self.file = file
        self.volume = volume
    }

    /// The `knowledge_sources` fields read per occurrence (see header).
    public static let rowKnowledgeFields: [CatalogDDL.KnowledgeField] = [.lineage, .supersededByID, .repairConfirmedDate, .archivedAt]
}

/// The counts a load reports beside the records (Catalog Status words).
public struct CatalogLoadCounts: Sendable, Equatable {
    /// `quarantine` rows not yet resolved — they are NOT records.
    public var quarantineOpen = 0
    /// Display rows shown empty because copies disagree (`conflict = 1`).
    public var conflicts = 0
    /// `files` rows (live + tombstoned) — what the load should yield.
    public var files = 0

    public init(quarantineOpen: Int = 0, conflicts: Int = 0, files: Int = 0) {
        self.quarantineOpen = quarantineOpen
        self.conflicts = conflicts
        self.files = files
    }
}
