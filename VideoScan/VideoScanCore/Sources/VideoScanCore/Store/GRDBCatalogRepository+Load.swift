// GRDBCatalogRepository+Load.swift (VideoScanCore/Store)
// The load readings (cutover B1, docs/design/catalog_cutover_f_prime_2026_10_17.md
// §2): every `files` row with everything a VideoRecord needs, streamed as
// `CatalogLoadedRow` values. Raw SQL only (CatalogStoreSensorTests).
//
// Shape of the read, chosen for memory (Rick's rule: stream, don't buffer):
//   * ONE cursor over `files` ⋈ its single-valued tables (volume, archive
//     copy, duplicate member, sound print, the scalar display tables, the
//     occurrence's pair ids), ordered by (content_digest, id);
//   * the multi-valued DIGEST-keyed tables (tags, people, attestations, the
//     bound derived tables, derived_unverified) are cursors ordered by
//     digest, merge-joined against the main cursor — each holds one digest's
//     group at a time;
//   * the sparse ROW-keyed tables (backup destinations, footage decisions,
//     the occurrence's lineage / supersession / archivedAt knowledge) are
//     read into small dictionaries first — they hold curated rows only.
// Worst-case memory: the row-keyed maps (curated rows: hundreds to a few
// thousand entries) + one digest group per side cursor + the visitor's own
// accumulation. The caller (`CatalogLoad.read`) keeps the rows it is given.
//
// Bound beats unverified: a derived KIND present in a bound table for the
// digest is taken from there; otherwise the row's OWN derived_unverified
// values of that kind (keyed by the row id — the value this row carried in
// catalog.json, never a sibling's).
//
// Cutover B2 (v1.7): the row-scoped values and the pair link are read from
// the import's evidence AND then from `row_knowledge` (newest entry per
// field wins; JSON null = cleared). `storedRow(id:)` is the same read for
// ONE row — what a commit compares the record against.
//
// (For Rick: a sort-merge join written by hand — N sorted cursors advanced in
// lock-step, like merging sorted files on tape.)

import Foundation
import GRDB

// MARK: - The readings

extension GRDBRecordHandle {

    func loadedRows(_ visit: (CatalogLoadedRow) throws -> Void) throws {
        let rowMaps = try LoadRowMaps(db)
        var groups = try LoadDigestGroups(db)
        let cursor = try Row.fetchCursor(db, sql: LoadSQL.main)
        while let row = try cursor.next() {
            var loaded = LoadSQL.loadedRow(row)
            rowMaps.fill(&loaded)
            try groups.fill(&loaded)
            try visit(loaded)
        }
    }

    func storedRow(id: String) throws -> CatalogLoadedRow? {
        guard let row = try Row.fetchOne(db.cachedStatement(sql: LoadSQL.oneRow), arguments: [id]) else { return nil }
        var loaded = LoadSQL.loadedRow(row)
        try LoadRowMaps(db, only: id).fill(&loaded)
        if let digest = loaded.file.contentDigest {
            var groups = try LoadDigestGroups(db, only: digest)
            try groups.fill(&loaded)
        }
        return loaded
    }

    func volumeCaseSensitive(_ volumeUUID: String) throws -> Bool {
        try Int.fetchOne(db, sql: "SELECT case_sensitive FROM volumes WHERE volume_uuid = ?", arguments: [volumeUUID]) == 1
    }

    func masterArchiveJSON() throws -> String? {
        try String.fetchOne(db, sql: "SELECT master_archive FROM catalog_state WHERE singleton = 1")
    }

    func lastFinishedImport() throws -> CatalogRow.FinishedImport? {
        guard let r = try Row.fetchOne(db, sql: """
            SELECT run_id, finished_at, source_sha256, source_generation FROM import_runs
             WHERE finished_at IS NOT NULL AND comparator_ok = 1 ORDER BY finished_at DESC, run_id DESC LIMIT 1
            """) else { return nil }
        return CatalogRow.FinishedImport(runID: r[0], finishedAt: r[1], sourceSHA256: r[2], sourceGeneration: r[3])
    }

    func finishedImports() throws -> Int {
        try Int.fetchOne(db, sql: "SELECT count(*) FROM import_runs WHERE finished_at IS NOT NULL AND comparator_ok = 1") ?? 0
    }

    func loadCounts() throws -> CatalogLoadCounts {
        let row = try Row.fetchOne(db, sql: """
            SELECT (SELECT count(*) FROM quarantine WHERE resolved_at IS NULL),
                   (SELECT count(*) FROM stars WHERE conflict = 1) + (SELECT count(*) FROM user_dates WHERE conflict = 1)
                 + (SELECT count(*) FROM user_places WHERE conflict = 1) + (SELECT count(*) FROM user_notes WHERE conflict = 1)
                 + (SELECT count(*) FROM dispositions WHERE conflict = 1) + (SELECT count(*) FROM family_music WHERE conflict = 1)
                 + (SELECT count(*) FROM people_tags WHERE conflict = 1),
                   (SELECT count(*) FROM files)
            """)
        guard let row else { return CatalogLoadCounts() }
        return CatalogLoadCounts(quarantineOpen: row[0], conflicts: row[1], files: row[2])
    }
}

// MARK: - Statements (cutover B2.2)

extension Database {
    /// A load reading's cursor. `oneRow`: the commit's read-back of ONE row
    /// (`storedRow(id:)`), which runs the same SQL for every changed row —
    /// so its statements are prepared once per connection (GRDB's statement
    /// cache). Measured 2026-10-18 (M4, Debug, 14k rows): preparing the
    /// one-row SELECT each time was 0.66 ms of a 0.71 ms read; since B2.2
    /// that read runs on the main actor. The full load runs each statement
    /// once and is not cached. (For Rick: a prepared-statement cache keyed
    /// by SQL text, as with `sqlite3_prepare_v3` + `SQLITE_PREPARE_PERSISTENT`.)
    func loadCursor(_ sql: String, arguments: StatementArguments, oneRow: Bool) throws -> RowCursor {
        guard oneRow else { return try Row.fetchCursor(self, sql: sql, arguments: arguments) }
        return try Row.fetchCursor(cachedStatement(sql: sql), arguments: arguments)
    }
}

// MARK: - Reading columns in SELECT order

/// Reads a row's columns left to right, so each reader below names the
/// columns in the order its SELECT fragment lists them.
struct ColumnCursor {
    let row: Row
    private(set) var index = 0

    init(_ row: Row) { self.row = row }

    mutating func next<T: DatabaseValueConvertible>() -> T? {
        defer { index += 1 }
        return row[index]
    }

    mutating func text() -> String { next() ?? "" }
    mutating func int() -> Int64 { next() ?? 0 }
    mutating func flag() -> Bool { (next() as Int64?) == 1 }
    mutating func skip(_ n: Int) { index += n }
}

// MARK: - The main SELECT

enum LoadSQL {

    static let fileColumns = """
        f.id, f.content_digest, f.volume_uuid, f.full_path, f.path_fold, f.filename, f.ext, f.directory, f.size_bytes,
        f.fs_created_at, f.fs_modified_at, f.stamp_device, f.stamp_inode, f.stamp_mtime_ns, f.stamp_ctime_ns,
        f.stamp_volume_uuid, f.digest_computed_at, f.digest_source, f.sampled_hash, f.sampled_hash_at, f.partial_md5,
        f.stream_type, f.duration_s, f.container, f.video_codec, f.audio_codec, f.embedded_created_at,
        f.embedded_created_source, f.probe_extra, f.scan_host, f.scanned_at, f.scan_root_label, f.bundle_container,
        f.source_host, f.original_full_path, f.origin_volume, f.machine_notes, f.lifecycle, f.archive_stage,
        f.master_location, f.set_aside_reason, f.needs_reformat, f.workspace_active, f.removal_state, f.removal_since,
        f.removal_reason, f.removal_trash_path, f.removal_trash_emptied_at, f.removal_last_seen, f.removal_revision,
        f.audit_seen_volume_uuid, f.audit_seen_mount_from, f.audit_seen_device_key, f.audit_seen_at, f.catalogued_at
        """

    private static let select = """
        SELECT \(fileColumns),
               v.last_name, v.mount_type, v.remote_server,
               ac.file_id, ac.source_row_id, ac.archived_at, ac.fixity_verified_at, ac.promoted_by,
               dm.group_id, dm.confidence, dm.disposition, dm.reasons, dm.best_match, dg.analyzed_at,
               (SELECT count(*) FROM duplicate_members x WHERE x.group_id = dm.group_id),
               sp.digest, sp.engine_version, sp.outcome, sp.analyzed_s, sp.complete, sp.landmarks, sp.blob_bytes, sp.computed_at,
               st.digest, st.rating, st.conflict,
               ud.digest, ud.value, ud.confidence, ud.conflict,
               up.digest, up.place, up.confidence, up.conflict,
               un.digest, un.text, un.conflict,
               di.digest, di.disposition, di.conflict,
               fm.digest, fm.performer, fm.title, fm.marked_at, fm.conflict,
               lp.import_run, lp.paired_with_id, lp.pair_group_id
          FROM files f
          JOIN volumes v ON v.volume_uuid = f.volume_uuid
          LEFT JOIN archive_copies ac ON ac.file_id = f.id
          LEFT JOIN duplicate_members dm ON dm.file_id = f.id
          LEFT JOIN duplicate_groups dg ON dg.group_id = dm.group_id
          LEFT JOIN sound_prints sp ON sp.digest = f.content_digest
          LEFT JOIN stars st ON st.digest = f.content_digest
          LEFT JOIN user_dates ud ON ud.digest = f.content_digest
          LEFT JOIN user_places up ON up.digest = f.content_digest
          LEFT JOIN user_notes un ON un.digest = f.content_digest
          LEFT JOIN dispositions di ON di.digest = f.content_digest
          LEFT JOIN family_music fm ON fm.digest = f.content_digest
          LEFT JOIN import_items ii ON ii.source_file = 'catalog.json' AND ii.landed_table = 'files' AND ii.landed_ref = f.id
          LEFT JOIN legacy_pair_ids lp ON lp.import_run = ii.import_run AND lp.source_ordinal = ii.source_ordinal
        """

    /// Every `files` row, copies of one content consecutive.
    static let main = select + "\n ORDER BY f.content_digest, f.id"

    /// One `files` row by id (a commit's read-back).
    static let oneRow = select + "\n WHERE f.id = ?"

    /// A JSON object column; the common empty `{}` without a parse.
    static func object(_ text: String) -> [String: CatalogJSONValue] {
        text == "{}" ? [:] : CatalogJSONValue.parse(text)?.objectValue ?? [:]
    }

    static func loadedRow(_ row: Row) -> CatalogLoadedRow {
        var c = ColumnCursor(row)
        let file = CatalogRecordDTO.FileRow(loading: &c)
        let volume = CatalogRecordDTO.VolumeRowDTO(volumeUUID: file.volumeUUID, lastName: c.text(), mountType: c.text(),
                                                    remoteServer: c.text())
        var loaded = CatalogLoadedRow(file: file, volume: volume)
        loaded.archiveCopy = archiveCopy(&c)
        (loaded.duplicate, loaded.duplicateGroupCount) = duplicate(&c)
        loaded.soundPrint = soundPrint(&c)
        loaded.shown = LoadShownScalars.read(&c)
        loaded.pair = pair(&c)
        return loaded
    }

    private static func archiveCopy(_ c: inout ColumnCursor) -> CatalogRecordDTO.ArchiveCopyRow? {
        guard (c.next() as String?) != nil else { c.skip(4); return nil }
        let source: String? = c.next()
        let archived: Int64? = c.next()
        let verified = c.int()
        let by = CatalogDDL.PromotedBy(rawValue: c.text()) ?? .import
        return CatalogRecordDTO.ArchiveCopyRow(sourceRowID: source, archivedAt: archived, fixityVerifiedAt: verified, promotedBy: by)
    }

    private static func duplicate(_ c: inout ColumnCursor) -> (CatalogRecordDTO.DuplicateMemberRow?, Int) {
        guard let group: String = c.next() else { c.skip(6); return (nil, 0) }
        let member = CatalogRecordDTO.DuplicateMemberRow(groupID: group, confidence: c.next(), disposition: c.text(),
                                                         reasons: c.text(), bestMatch: c.text(), analyzedAt: c.next())
        return (member, Int(c.int()))
    }

    private static func soundPrint(_ c: inout ColumnCursor) -> CatalogRecordDTO.SoundPrintRow? {
        guard let digest: String = c.next() else { c.skip(7); return nil }
        return CatalogRecordDTO.SoundPrintRow(digest: digest, engineVersion: Int(c.int()), outcome: c.text(), analyzedS: c.next() ?? 0,
                                              complete: c.flag(), landmarks: Int(c.int()), blobBytes: Int(c.int()),
                                              computedAt: c.int())
    }

    private static func pair(_ c: inout ColumnCursor) -> CatalogLoadedRow.PairIDs? {
        guard (c.next() as String?) != nil else { return nil }
        return CatalogLoadedRow.PairIDs(pairedWithID: c.next(), pairGroupID: c.next())
    }

    /// `row_knowledge` 'pair' value → the pair link (an empty object = none).
    static func pairLink(_ value: CatalogJSONValue) -> CatalogLoadedRow.PairIDs? {
        guard let object = value.objectValue, !object.isEmpty else { return nil }
        return CatalogLoadedRow.PairIDs(pairedWithID: object["pairedWithID"]?.stringValue,
                                        pairGroupID: object["pairGroupID"]?.stringValue,
                                        pairConfidence: object["pairConfidence"]?.stringValue,
                                        combinedFromPairID: object["combinedFromPairID"]?.stringValue)
    }
}

// MARK: - files columns → FileRow (the reverse of insertFile)

extension CatalogRecordDTO.FileRow {

    /// The `files` row, in `LoadSQL.fileColumns` order.
    init(loading c: inout ColumnCursor) {
        id = c.text(); contentDigest = c.next(); volumeUUID = c.text(); fullPath = c.text(); pathFold = c.text()
        filename = c.text(); ext = c.text(); directory = c.text(); sizeBytes = c.int()
        fsCreatedAt = c.next(); fsModifiedAt = c.next(); stampDevice = c.next(); stampInode = c.next()
        stampMtimeNs = c.next(); stampCtimeNs = c.next(); stampVolumeUUID = c.next(); digestComputedAt = c.next()
        digestSource = (c.next() as String?).flatMap(CatalogDDL.DigestSource.init(rawValue:))
        sampledHash = c.next(); sampledHashAt = c.next(); partialMD5 = c.next()
        streamType = c.text(); durationS = c.next() ?? 0; container = c.text(); videoCodec = c.text(); audioCodec = c.text()
        embeddedCreatedAt = c.next(); embeddedCreatedSource = c.next()
        probeExtra = LoadSQL.object(c.text())
        scanHost = c.text(); scannedAt = c.next(); scanRootLabel = c.text(); bundleContainer = c.text(); sourceHost = c.text()
        originalFullPath = c.next(); originVolume = c.next(); machineNotes = c.text()
        lifecycle = c.text(); archiveStage = c.text(); masterLocation = c.text(); setAsideReason = c.next()
        needsReformat = c.flag(); workspaceActive = c.flag()
        removalState = c.next(); removalSince = c.next(); removalReason = c.next(); removalTrashPath = c.next()
        removalTrashEmptiedAt = c.next(); removalLastSeen = c.next(); removalRevision = Int(c.int())
        auditSeenVolumeUUID = c.next(); auditSeenMountFrom = c.next(); auditSeenDeviceKey = c.next(); auditSeenAt = c.next()
        cataloguedAt = c.next()
    }
}

// MARK: - The scalar display tables (conflict → empty + named)

enum LoadShownScalars {

    static func read(_ c: inout ColumnCursor) -> CatalogLoadedRow.Shown {
        var s = CatalogLoadedRow.Shown()
        if present(&c) {
            let rating: Int64? = c.next()
            if c.flag() { s.conflicts.append(.starRating) } else { s.starRating = rating.map(Int.init) }
        } else { c.skip(2) }
        if present(&c) {
            let date = CatalogRecordDTO.UserDateRow(value: c.next(), confidence: c.next())
            if c.flag() { s.conflicts.append(.userDate) } else { s.userDate = date }
        } else { c.skip(3) }
        if present(&c) {
            let place = CatalogRecordDTO.UserPlaceRow(place: c.next(), confidence: c.next())
            if c.flag() { s.conflicts.append(.userPlace) } else { s.userPlace = place }
        } else { c.skip(3) }
        readTail(&c, into: &s)
        return s
    }

    /// user_notes, dispositions, family_music.
    private static func readTail(_ c: inout ColumnCursor, into s: inout CatalogLoadedRow.Shown) {
        if present(&c) {
            let text: String? = c.next()
            if c.flag() { s.conflicts.append(.userNotes) } else { s.userNotes = text }
        } else { c.skip(2) }
        if present(&c) {
            let disposition: String? = c.next()
            if c.flag() { s.conflicts.append(.mediaDisposition) } else { s.mediaDisposition = disposition }
        } else { c.skip(2) }
        if present(&c) {
            let performer: String? = c.next()
            let title: String? = c.next()
            let marked: Int64? = c.next()
            if c.flag() {
                s.conflicts.append(.familyMusic)
            } else if let marked {
                s.familyMusic = CatalogRecordDTO.FamilyMusicRow(performer: performer, title: title, markedAt: marked)
            }
        } else { c.skip(4) }
    }

    /// The LEFT JOIN found a row (its digest column is not NULL).
    private static func present(_ c: inout ColumnCursor) -> Bool { (c.next() as String?) != nil }
}

// MARK: - Sparse row-keyed tables, read first

struct LoadRowMaps {
    var backups: [String: [CatalogRecordDTO.BackupDestinationRow]] = [:]
    var decisions: [String: [CatalogRecordDTO.FootageDecisionRow]] = [:]
    var knowledge: [String: [CatalogDDL.KnowledgeField: CatalogJSONValue]] = [:]
    /// v1.7 `row_knowledge`, newest per (row, field): the row-scoped fields
    /// and 'pair'. A JSON null is kept (it means "cleared").
    var written: [String: [String: CatalogJSONValue]] = [:]

    /// `only`: one row's maps (a commit's read-back); nil = every row.
    init(_ db: Database, only fileID: String? = nil) throws {
        let one = fileID.map { StatementArguments([$0]) } ?? []
        let b = try db.loadCursor("""
            SELECT file_id, name, kind, recorded_at FROM backup_destinations \(fileID == nil ? "" : "WHERE file_id = ?")
             ORDER BY file_id, recorded_at, name
            """, arguments: one, oneRow: fileID != nil)
        while let r = try b.next() {
            backups[r[0], default: []].append(CatalogRecordDTO.BackupDestinationRow(name: r[1], kind: r[2], recordedAt: r[3]))
        }
        let d = try db.loadCursor("""
            SELECT row_id, other_row_id, verdict, decided_at FROM footage_decisions \(fileID == nil ? "" : "WHERE row_id = ?")
             ORDER BY row_id, decision_id
            """, arguments: one, oneRow: fileID != nil)
        while let r = try d.next() {
            decisions[r[0], default: []].append(CatalogRecordDTO.FootageDecisionRow(rowID: r[0], otherRowID: r[1], verdict: r[2], decidedAt: r[3]))
        }
        try readImportedKnowledge(db, only: fileID)
        try readWrittenKnowledge(db, only: fileID)
    }

    private static let rowFields = CatalogLoadedRow.rowKnowledgeFields.map { "'\($0.rawValue)'" }.joined(separator: ",")

    private mutating func readImportedKnowledge(_ db: Database, only fileID: String?) throws {
        let k = try db.loadCursor("""
            SELECT ii.landed_ref, k.field, k.value_json
              FROM import_items ii
              JOIN knowledge_sources k ON k.import_run = ii.import_run AND k.source_ordinal = ii.source_ordinal
             WHERE ii.source_file = 'catalog.json' AND ii.landed_table = 'files' AND k.field IN (\(Self.rowFields))
                   \(fileID == nil ? "" : "AND ii.landed_ref = ?")
            """, arguments: fileID.map { [$0] } ?? [], oneRow: fileID != nil)
        while let r = try k.next() {
            guard let field = CatalogDDL.KnowledgeField(rawValue: r[1]), let value = CatalogJSONValue.parse(r[2]) else { continue }
            knowledge[r[0], default: [:]][field] = value
        }
    }

    private mutating func readWrittenKnowledge(_ db: Database, only fileID: String?) throws {
        let w = try db.loadCursor("""
            SELECT file_id, field, value_json FROM row_knowledge
             WHERE field IN (\(Self.rowFields), '\(CatalogLiveWritesSchema.pairField)') \(fileID == nil ? "" : "AND file_id = ?")
             ORDER BY write_id
            """, arguments: fileID.map { [$0] } ?? [], oneRow: fileID != nil)
        while let r = try w.next() {
            guard let value = CatalogJSONValue.parse(r[2]) else { continue }
            written[r[0], default: [:]][r[1]] = value
        }
    }

    func fill(_ loaded: inout CatalogLoadedRow) {
        let id = loaded.file.id
        loaded.backupDestinations = backups[id] ?? []
        loaded.footageDecisions = decisions[id] ?? []
        loaded.rowKnowledge = knowledge[id] ?? [:]
        guard let newer = written[id] else { return }
        for field in CatalogLoadedRow.rowKnowledgeFields {
            guard let value = newer[field.rawValue] else { continue }
            loaded.rowKnowledge[field] = value == .null ? nil : value
        }
        if let link = newer[CatalogLiveWritesSchema.pairField] {
            loaded.pair = LoadSQL.pairLink(link)
        }
    }
}

// MARK: - Digest-keyed multi-valued tables, merge-joined

/// One digest-ordered cursor; `group(for:)` answers the elements of one
/// digest, advancing past digests no file has (orphans: quarantined rows'
/// knowledge). The last group is remembered, because copies of one content
/// are consecutive in the main cursor and each asks for the same group.
struct DigestRun<Element> {
    private let cursor: RowCursor
    private let element: (Row) -> Element
    private var pending: (digest: String, element: Element)?
    private var last: (digest: String, group: [Element])?

    init(_ db: Database, sql: String, arguments: StatementArguments = [], element: @escaping (Row) -> Element) throws {
        cursor = try db.loadCursor(sql, arguments: arguments, oneRow: !arguments.isEmpty)
        self.element = element
    }

    mutating func group(for digest: String) throws -> [Element] {
        if let last, last.digest == digest { return last.group }
        var out: [Element] = []
        while true {
            if pending == nil, let row = try cursor.next() { pending = (row[0], element(row)) }
            guard let p = pending, p.digest <= digest else { break }
            if p.digest == digest { out.append(p.element) }
            pending = nil
        }
        last = (digest, out)
        return out
    }
}

struct LoadDigestGroups {
    private var tags: DigestRun<String>
    private var people: DigestRun<(tag: CatalogRecordDTO.PeopleTagRow, conflict: Bool)>
    private var attestations: DigestRun<CatalogRecordDTO.BackupAttestationRow>
    private var bound: DigestRun<CatalogRecordDTO.DerivedValueRow?>
    private var unverified: DigestRun<(rowID: String, value: CatalogRecordDTO.DerivedValueRow?)>

    /// `only`: one digest's groups (a commit's read-back); nil = every digest.
    init(_ db: Database, only digest: String? = nil) throws {
        let one: StatementArguments = digest.map { [$0] } ?? []
        let whereDigest = digest == nil ? "" : "WHERE digest = ?"
        let andDigest = digest == nil ? "" : "AND digest = ?"
        tags = try DigestRun(db, sql: "SELECT digest, tag FROM workflow_tags \(whereDigest) ORDER BY digest, tag", arguments: one) { $0[1] }
        people = try DigestRun(db, sql: """
            SELECT digest, name, kind, confirmed_at, conflict FROM people_tags
             WHERE kind IN ('confirmed','rejected') \(andDigest) ORDER BY digest, kind, name
            """, arguments: one) { r in
            (CatalogRecordDTO.PeopleTagRow(name: r[1], kind: CatalogDDL.PeopleTagKind(rawValue: r[2]) ?? .rejected, confirmedAt: r[3]),
             (r[4] as Int64) == 1)
        }
        attestations = try DigestRun(db, sql: """
            SELECT digest, kind, answer, label, attested_at, by_whom FROM backup_attestations \(whereDigest)
             ORDER BY digest, attested_at, kind
            """, arguments: one) { r in
            CatalogRecordDTO.BackupAttestationRow(kind: r[1], answer: r[2], label: r[3], attestedAt: r[4], byWhom: r[5])
        }
        bound = try DigestRun(db, sql: digest == nil ? LoadBoundSQL.union : LoadBoundSQL.unionForOne, arguments: one,
                              element: LoadBoundSQL.derived)
        unverified = try DigestRun(db, sql: """
            SELECT digest, kind, seq, value_json, stamp_json, source_json_row_id FROM derived_unverified \(whereDigest)
             ORDER BY digest
            """, arguments: one) { r in ((r[5] as String), LoadBoundSQL.derived(r)) }
    }

    mutating func fill(_ loaded: inout CatalogLoadedRow) throws {
        guard let digest = loaded.file.contentDigest else { return }
        loaded.shown.tags = try tags.group(for: digest)
        let people = try people.group(for: digest)
        loaded.shown.confirmedPeople = people.filter { $0.tag.kind == .confirmed && !$0.conflict }.map(\.tag)
        loaded.shown.rejectedPeople = people.filter { $0.tag.kind == .rejected && !$0.conflict }.map(\.tag.name)
        if people.contains(where: \.conflict) { loaded.shown.conflicts += [.confirmedByUserPeople, .rejectedPeople] }
        loaded.shown.backupAttestations = try attestations.group(for: digest)
        try fillDerived(&loaded, digest: digest)
    }

    /// Bound beats unverified, kind by kind.
    private mutating func fillDerived(_ loaded: inout CatalogLoadedRow, digest: String) throws {
        let bound = try self.bound.group(for: digest).compactMap { $0 }.map { LoadBoundSQL.sized($0, sizeBytes: loaded.file.sizeBytes) }
        let boundKinds = Set(bound.map(\.kind))
        let id = loaded.file.id
        let own = try unverified.group(for: digest).filter { $0.rowID == id }.compactMap(\.value)
            .filter { !boundKinds.contains($0.kind) }
        loaded.derived = bound + own
        loaded.unverifiedDerived = own.count
    }
}

// MARK: - The bound derived tables as the JSON row's derived values

/// Each bound table rendered in SQL as the `(kind, seq, value, stamp)` the
/// importer's descriptor table (CatalogRecordDTO+Derived.swift) uses, so the
/// one inverse (`rawMembers(of:)`) gives the record its keys back.
enum LoadBoundSQL {

    private static func iso(_ column: String) -> String {
        "CASE WHEN \(column) IS NULL THEN NULL ELSE strftime('%Y-%m-%dT%H:%M:%SZ', \(column), 'unixepoch') END"
    }

    static let union = arms.map(\.select).joined(separator: "\nUNION ALL\n") + "\nORDER BY 1"

    /// The same rows for ONE digest (bound by `?1`). The digest test sits
    /// INSIDE every arm (cutover B2.2): the window function in the people
    /// arm stops SQLite pushing an outer WHERE into the compound, and every
    /// arm was then a full table scan per commit read-back.
    static let unionForOne = arms.map { $0.select + ($0.filtered ? " AND digest = ?1" : " WHERE digest = ?1") }
        .joined(separator: "\nUNION ALL\n")

    /// Each arm, and whether it already ends in a WHERE clause.
    private static let arms: [(select: String, filtered: Bool)] = [
        ("SELECT digest, kind, seq, json_object('timestamp', at_s, 'text', text), '{}' FROM captions", false),
        ("""
        SELECT digest, 'captionRun', 0, json_object('sceneCaptionModel', model, 'sceneCaptionDate', \(iso("made_at"))), '{}'
          FROM caption_runs
        """, false),
        ("""
        SELECT digest, 'transcript', 0, json_quote(text),
               json_object('audioTranscriptModel', model, 'audioTranscriptDate', \(iso("made_at"))) FROM transcripts
        """, false),
        ("""
        SELECT digest, 'dossier', 0, json_object('dossierProcessedAt', \(iso("processed_at")), 'dossierProcessedBy', processed_by), '{}'
          FROM dossiers
        """, false),
        ("""
        SELECT digest, 'inferredDate', 0,
               json_object('inferredRecordDate', \(iso("date_at")), 'inferredDateConfidence', confidence,
                           'inferredDateSource', source, 'inferredDateReason', reason,
                           'inferredDateRange', json(CASE WHEN range_start IS NULL THEN NULL
                                                     ELSE json_object('startYear', range_start, 'endYear', range_end) END)),
               '{}' FROM inferred_dates
        """, false),
        ("""
        SELECT digest, CASE kind WHEN 'audio' THEN 'audioCheck' ELSE 'videoCheck' END, 0,
               CASE kind WHEN 'audio'
                 THEN json_object('audioVerifyStatus', status, 'audioVerifyNote', note, 'audioVerifyDate', \(iso("checked_at")))
                 ELSE json_object('videoVerifyStatus', status, 'videoVerifyNote', note, 'videoVerifyDate', \(iso("checked_at"))) END,
               '{}' FROM media_checks WHERE kind IN ('audio','video')
        """, true),
        ("SELECT digest, 'reportCard', 0, card, '{}' FROM media_checks WHERE kind = 'reportCard'", true),
        ("""
        SELECT digest, 'perceptualPrint', 0,
               json_object('algorithmVersion', algorithm_version, 'hashesBase64', hashes_b64, 'durationSeconds', duration_s,
                           'computedAt', \(iso("computed_at"))), '{}' FROM perceptual_prints
        """, false),
        ("SELECT digest, 'footageMembership', 0, membership, '{}' FROM footage_membership", false),
        ("""
        SELECT digest, CASE kind WHEN 'detected' THEN 'detectedPerson' ELSE 'suspectedPerson' END,
               row_number() OVER (PARTITION BY digest, kind ORDER BY name) - 1, json_quote(name), '{}'
          FROM people_tags WHERE kind IN ('detected','suspected')
        """, true),
    ]

    /// `(digest, kind, seq, value_json, stamp_json)` → the derived row; nil
    /// for a kind this build does not know (the DDL's CHECK makes that a
    /// newer schema, which `open` already refuses).
    static func derived(_ r: Row) -> CatalogRecordDTO.DerivedValueRow? {
        guard let kind = CatalogDDL.DerivedKind(rawValue: r[1]) else { return nil }
        return CatalogRecordDTO.DerivedValueRow(kind: kind, seq: r[2], valueJSON: CatalogJSONValue.parse(r[3]) ?? .null,
                                                stampJSON: CatalogJSONValue.parse(r[4]) ?? .object([:]))
    }

    /// A bound perceptual print carries no size; the file's is the one it was made for.
    static func sized(_ row: CatalogRecordDTO.DerivedValueRow, sizeBytes: Int64) -> CatalogRecordDTO.DerivedValueRow {
        guard row.kind == .perceptualPrint, var object = row.valueJSON.objectValue, object["sizeBytes"] == nil else { return row }
        object["sizeBytes"] = .int(sizeBytes)
        var sized = row
        sized.valueJSON = .object(object)
        return sized
    }
}
