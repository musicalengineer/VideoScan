// CatalogCommitBody.swift
// The body of one commit's write (cutover B2; CatalogCommit.swift says what
// a commit is). Runs on the store's queue inside `repository.write`; talks
// to the store only through `CatalogTransaction`'s doors, so no SQL and no
// GRDB type appears here.
//
// First the purges (B2.1 gap 3), each in its own savepoint. Then per record
// (its own savepoint): no whole-file digest → held in `pending_rows`
// (B2.1 gap 1); else insert or update the `files` row (an insert drops the
// record's pending row), the tombstone FIRST when the removal marker moved
// (the DDL refuses the marker change without it), the row's archive copy /
// backups / footage decisions / duplicate member / sound print when they
// differ, the display rows + one `row_knowledge` row per curated field —
// a SHARED curated field only when this record changed it since its own
// baseline (codex P1-1), the shared SETS (people — codex P1-6 — tags and
// backup attestations — B2.4) as this copy's delta against its own
// baseline — the row-scoped values and the pair link, and the bound rows of each derived kind that
// differs (each kind in a nested savepoint: a kind the bound table cannot
// hold is left out and the row is PARTIAL — codex P2-7 — so the app keeps
// it changed and sends it again).
//
// After every row: each content whose sets were written is read back once
// and its rows report the sets the store ENDS with (B2.4,
// CatalogSetDelta.swift) — the app shows them on every copy.
//
// A record whose stored row carries the purge marker comes back (it is in
// the app's records again): its marker moves on by one revision with its
// own tombstone, and the app is told the revision.
//
// (For Rick: the unit of work's apply loop; each `try` that throws inside a
// savepoint rolls back that one record and becomes its `.refused` words.)

import Foundation

struct CatalogCommitBody {
    let plan: CatalogCommit.Plan
    let tx: any CatalogTransaction
    let ledger: CatalogCommitLedger
    /// Copies of one content that changed the same field differently in
    /// this commit (B2.3, regression F2 — CatalogCommitConflicts.swift).
    let conflicts: CatalogCommitConflicts

    init(plan: CatalogCommit.Plan, tx: any CatalogTransaction, ledger: CatalogCommitLedger) {
        self.plan = plan
        self.tx = tx
        self.ledger = ledger
        conflicts = CatalogCommitConflicts(plan.items)
    }

    private var source: String { CatalogRow.RowKnowledge.appSource(plan.door) }

    /// Thrown when nothing landed, so no empty generation is committed.
    struct NothingLanded: Error, CustomStringConvertible {
        var description: String { "nothing in this commit differed from catalog.sqlite or could be stored" }
    }

    /// The designation guard (GH #167), carried over from catalog.json.
    struct DesignationLossRefused: Error, CustomStringConvertible {
        var description: String {
            "the Master Archive designation would be removed without Clear Master Archive — refused; catalog.sqlite keeps it (GH #167)"
        }
    }

    /// Order (P0 2026-10-22): lone purges first (they free the live paths
    /// as before); then each REPLACED row together with the record that
    /// replaces it at the same path, in ONE savepoint — when the
    /// replacement is not stored (refused, or not held for a hash), the
    /// purge is undone with it and the old row stays live; then every
    /// other record in plan order. The ledger still lists purges first,
    /// then items, each in plan order (the app's baseline zips by order).
    ///
    /// Before this, every purge landed first and on its own: a rescan of
    /// FamilyArchive purged 641 replaced rows while the store refused 95
    /// of their replacements (archive copies whose source row it did not
    /// hold) — 95 archived Masters left the catalog with their files on
    /// disk (generation 681).
    func run() throws {
        var landed = 0
        let successors = try replacementPairs()
        var purgeRows = [CatalogCommit.RowResult?](repeating: nil, count: plan.purges.count)
        var itemRows = [(CatalogCommit.RowResult, Bool)?](repeating: nil, count: plan.items.count)
        for (index, id) in plan.purges.enumerated() where successors[index] == nil {
            purgeRows[index] = purge(id)
        }
        for (purgeIndex, itemIndex) in successors.sorted(by: { $0.key < $1.key }) {
            let pair = replace(plan.purges[purgeIndex], with: plan.items[itemIndex])
            purgeRows[purgeIndex] = pair.purge
            itemRows[itemIndex] = pair.item
        }
        for (index, item) in plan.items.enumerated() where itemRows[index] == nil {
            itemRows[index] = commit(item)
        }
        for row in purgeRows.compactMap({ $0 }) {
            if row.landing.landed { landed += 1 }
            ledger.record(row)
        }
        for (row, wrote) in itemRows.compactMap({ $0 }) {
            if wrote { landed += 1 }
            ledger.record(row)
        }
        try settleSets()
        let designationLanded = try writeDesignation()
        guard landed > 0 || designationLanded else {
            ledger.noteNothingLanded()
            throw NothingLanded()
        }
    }

    // MARK: - A replaced row and its replacement (P0 2026-10-22)

    /// purge index → the index of the item that replaces it: the first
    /// item, under another id, at the purged row's live path (compared
    /// NFC + case-folded, the store's own path identity). An item sent
    /// more than once in this plan is not paired (its snapshots must run
    /// in order, gap 2). A purge of a held (pending) row has no live path
    /// and stays a lone purge — its payload is kept in `pending_purges`.
    private func replacementPairs() throws -> [Int: Int] {
        guard !plan.purges.isEmpty, !plan.items.isEmpty else { return [:] }
        var sent: [UUID: Int] = [:]
        for item in plan.items { sent[item.id, default: 0] += 1 }
        let purged = Set(plan.purges)
        var byPath: [String: Int] = [:]
        for (index, item) in plan.items.enumerated()
        where sent[item.id] == 1 && !purged.contains(item.id) {
            let key = Self.pathKey(item.snapshot.fullPath)
            if byPath[key] == nil { byPath[key] = index }
        }
        var pairs: [Int: Int] = [:]
        var taken = Set<Int>()
        for (index, id) in plan.purges.enumerated() {
            guard let path = try tx.storedLivePath(id: id.uuidString),
                  let itemIndex = byPath[Self.pathKey(path)], taken.insert(itemIndex).inserted else { continue }
            pairs[index] = itemIndex
        }
        return pairs
    }

    /// The store's path identity (files.path_fold): NFC, then case folding.
    static func pathKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
    }

    private struct ReplacementNotStored: Error {
        let words: String
    }

    /// The purge and its replacement in ONE savepoint: both land, or the
    /// purge is undone and the old row stays live (the replacement's own
    /// refusal is reported on it, as before).
    private func replace(_ id: UUID, with item: CatalogCommit.Item)
        -> (purge: CatalogCommit.RowResult, item: (CatalogCommit.RowResult, Bool)) {
        var purgeRow = CatalogCommit.RowResult(id: id, fingerprint: 0, digest: nil, landing: .removed(.absent))
        var itemRow = (CatalogCommit.RowResult(id: item.id, fingerprint: item.fingerprint, digest: nil,
                                               landing: .refused("not attempted")), false)
        do {
            try tx.inSavepoint {
                purgeRow = purge(id)
                itemRow = commit(item)
                if !Self.keepsRecord(itemRow.0) {
                    throw ReplacementNotStored(words: Self.refusalWords(itemRow.0.landing))
                }
            }
        } catch let kept as ReplacementNotStored {
            purgeRow.landing = .refused(CatalogCommitWords.replacementNotStored(kept.words))
            purgeRow.keptForReplacement = true
            itemRow.0.heldPending = false
            itemRow.1 = false
        } catch {
            let words = CatalogCommitWords.engine(error)
            purgeRow.landing = .refused(words)
            itemRow = (CatalogCommit.RowResult(id: item.id, fingerprint: item.fingerprint, digest: nil,
                                               landing: .refused(words)), false)
        }
        return (purgeRow, itemRow)
    }

    /// The replacement now holds the record in the store: written (whole or
    /// partial), already there, or held in `pending_rows` for its hash.
    static func keepsRecord(_ row: CatalogCommit.RowResult) -> Bool {
        switch row.landing {
        case .written, .partial, .unchanged: return true
        case .deferred: return row.heldPending
        case .refused, .removed: return false
        }
    }

    private static func refusalWords(_ landing: CatalogCommit.Landing) -> String {
        switch landing {
        case .refused(let words), .deferred(let words): return words
        default: return "it was not stored"
        }
    }

    // MARK: - A purge (gap 3)

    private func purge(_ id: UUID) -> CatalogCommit.RowResult {
        var result = CatalogCommit.RowResult(id: id, fingerprint: 0, digest: nil, landing: .removed(.absent))
        do {
            var landing = CatalogRow.PurgeLanding.absent
            try tx.inSavepoint {
                landing = try tx.purgeFile(id: id.uuidString, since: plan.now, writtenAt: plan.now, door: source)
            }
            result.landing = .removed(landing)
        } catch {
            result.landing = .refused(CatalogCommitWords.engine(error))
        }
        return result
    }

    // MARK: - One record

    /// The row's result, and whether anything was written for it.
    private func commit(_ item: CatalogCommit.Item) -> (CatalogCommit.RowResult, Bool) {
        var result = CatalogCommit.RowResult(id: item.id, fingerprint: item.fingerprint, digest: nil, landing: .unchanged)
        let current: CatalogRecordDTO
        do {
            current = try CatalogRecordDTO(snapshot: item.snapshot, migrationLoadedAt: plan.now)
        } catch {
            result.landing = .refused("the record could not be mapped to catalog rows: \(error)")
            return (result, false)
        }
        switch current.digestState {
        case .none:
            return hold(item, result)
        case .disagree(let digests):
            result.landing = .refused("its two whole-file hashes disagree (\(digests.joined(separator: " vs "))) — Verify the file before it can be stored")
            return (result, false)
        case .known(let digest, _):
            result.digest = digest
            result = land(current, digest: digest, item: item, into: result)
            return (result, result.landing.landed)
        }
    }

    /// No whole-file digest yet: deferred, and held in `pending_rows` so a
    /// relaunch keeps the record.
    private func hold(_ item: CatalogCommit.Item, _ result: CatalogCommit.RowResult) -> (CatalogCommit.RowResult, Bool) {
        var result = result
        result.landing = .deferred(CatalogCommitWords.noDigest)
        do {
            let row = CatalogRow.PendingRow(id: item.id.uuidString, json: try CatalogPendingRecord.json(item.snapshot),
                                            queuedAt: plan.now)
            var wrote = false
            try tx.inSavepoint { wrote = try tx.putPendingRow(row) }
            result.heldPending = true
            return (result, wrote)
        } catch {
            result.landing = .deferred(CatalogCommitWords.notHeld(CatalogCommitWords.engine(error)))
            return (result, false)
        }
    }

    private func land(_ mapped: CatalogRecordDTO, digest: String, item: CatalogCommit.Item,
                      into result: CatalogCommit.RowResult) -> CatalogCommit.RowResult {
        var result = result
        do {
            let stored = try storedDTO(id: mapped.file.id)
            if let was = stored?.digestState.digest, was != digest {
                result.landing = .refused(CatalogCommitWords.digestChanged(from: was, to: digest))
                return result
            }
            var current = mapped
            if let stored, CatalogCommitWords.isPurged(stored.file), !CatalogCommitWords.isPurged(current.file) {
                current.file.removalRevision = stored.file.removalRevision + 1
                result.adoptedRevision = current.file.removalRevision
            }
            var diff = CatalogRecordDiff(stored: stored, current: current)
            if stored != nil, let baseline = item.sharedBaseline {
                diff.restrictShared(to: CatalogSharedCurated(item.snapshot).edited(since: baseline))
            }
            guard !diff.isEmpty else {
                result.landing = .unchanged
                return result
            }
            var written = Written()
            try tx.inSavepoint {
                written = try write(current, digest: digest, stored: stored, diff: diff, baseline: item.sharedBaseline)
            }
            // A field in conflict is not shared: each copy keeps its own value (F2).
            let inConflict = conflicts.fields(of: digest)
            let curated = diff.knowledge.filter { CatalogCommitWords.sharedByCopies.contains($0) && !inConflict.contains($0) }
            result.landing = written.missing.isEmpty
                ? .written(curated: curated, notes: written.notes) : .partial(curated: curated, words: written.missing)
        } catch {
            result.landing = .refused(CatalogCommitWords.engine(error))
            result.adoptedRevision = nil
        }
        return result
    }

    /// The stored row as the DTO a record loaded from it would give.
    private func storedDTO(id: String) throws -> CatalogRecordDTO? {
        guard let row = try tx.storedRow(id: id) else { return nil }
        let record = try VideoRecord(loaded: row)
        // A live record's partner is an object; the encoder writes its id.
        if let partner = record.pendingPairedWithID { record.pairedWith = VideoRecord(id: partner) }
        return try CatalogRecordDTO(record: record, migrationLoadedAt: plan.now)
    }

    /// What one row's write left out: rebuildable analysis (notes) and
    /// derived kinds the store refused (the row is partial).
    private struct Written {
        var notes: [String] = []
        var missing: [String] = []
    }

    private func write(_ current: CatalogRecordDTO, digest: String, stored: CatalogRecordDTO?,
                       diff: CatalogRecordDiff, baseline: CatalogSharedCurated?) throws -> Written {
        let id = current.file.id
        if let stored {
            if diff.file || diff.marker { try updateRow(current, stored: stored, diff: diff) }
        } else {
            try insertRow(current)
            _ = try tx.removePendingRow(id: id)
        }
        var written = Written()
        if diff.archiveCopy { try tx.replaceArchiveCopy(fileID: id, current.archiveCopy) }
        if diff.backups { try tx.replaceBackupDestinations(fileID: id, current.backupDestinations) }
        if diff.footageDecisions { try tx.replaceFootageDecisions(rowID: id, digest: digest, current.curated.footageDecisions) }
        if diff.duplicate, let words = try tx.replaceDuplicateMember(fileID: id, current.duplicateMember) { written.notes.append(words) }
        if diff.soundPrint { try tx.replaceSoundPrint(digest: digest, current.soundPrint) }
        try writeKnowledge(current, digest: digest, fields: diff.knowledge, baseline: baseline)
        if diff.pair {
            try tx.appendRowKnowledge(CatalogRow.RowKnowledge(fileID: id, digest: digest, field: CatalogLiveWritesSchema.pairField,
                                                              value: current.pairLink?.linkValue ?? .object([:]),
                                                              setAt: plan.now, source: source))
        }
        written.missing = writeDerived(current, digest: digest, kinds: diff.derived)
        return written
    }

    private func insertRow(_ current: CatalogRecordDTO) throws {
        guard let content = current.content else { throw CatalogCommitWords.Refusal(CatalogCommitWords.noDigest) }
        var fresh = content
        fresh.firstSeenHow = .job          // first seen by the app after the port, not by the import
        try tx.upsertVolume(current.volume)
        try tx.ensureContent(fresh)
        let caseSensitive = try tx.volumeCaseSensitive(current.volume.volumeUUID)
        try tx.insertFile(OccurrenceWriter.storable(current.file), volumeCaseSensitive: caseSensitive)
    }

    /// The tombstone FIRST when the marker moved (the DDL checks it names
    /// the new revision and the new marker), then the columns.
    private func updateRow(_ current: CatalogRecordDTO, stored: CatalogRecordDTO, diff: CatalogRecordDiff) throws {
        if diff.marker {
            try appendTombstone(current.file, storedRevision: stored.file.removalRevision)
        }
        try tx.upsertVolume(current.volume)
        try tx.updateFile(OccurrenceWriter.storable(current.file), markerChanged: diff.marker)
    }

    private func appendTombstone(_ file: CatalogRecordDTO.FileRow, storedRevision: Int) throws {
        guard file.removalRevision == storedRevision + 1 else {
            throw CatalogCommitWords.Refusal(CatalogCommitWords.markerJump(stored: storedRevision, now: file.removalRevision))
        }
        try tx.insertTombstone(CatalogRow.Tombstone(
            fileID: file.id, revision: file.removalRevision,
            state: file.removalState.flatMap(CatalogDDL.RemovalState.init(rawValue:)), since: file.removalSince,
            reason: file.removalReason, trashPath: file.removalTrashPath, trashEmptiedAt: file.removalTrashEmptiedAt,
            lastSeen: file.removalLastSeen, writtenAt: plan.now, door: source))
    }

    /// The shared sets, written as deltas (never a whole-set replace).
    static let deltaFields: Set<CatalogDDL.KnowledgeField> = [.tags, .backupAttestations, .confirmedByUserPeople, .rejectedPeople]

    /// Display rows for the content (per-content fields), then one
    /// `row_knowledge` row per field that differs (JSON null = cleared).
    /// The sets go as a delta against the record's own baseline.
    private func writeKnowledge(_ current: CatalogRecordDTO, digest: String, fields: [CatalogDDL.KnowledgeField],
                                baseline: CatalogSharedCurated?) throws {
        try writeSetDeltas(current, digest: digest, fields: Set(fields), baseline: baseline)
        let inConflict = conflicts.fields(of: digest)
        for field in fields {
            if inConflict.contains(field) {
                try tx.writeDisplayConflict(digest: digest, field: field)   // F2: shown empty, counted as a conflict
            } else if !Self.deltaFields.contains(field) {
                try tx.writeDisplayValue(digest: digest, field: field, current.curated, setAt: plan.now)
            }
            try tx.appendRowKnowledge(CatalogRow.RowKnowledge(
                fileID: current.file.id, digest: digest, field: field.rawValue,
                value: CatalogRecordDTO.knowledgeValue(field, raw: current.raw) ?? .null, setAt: plan.now, source: source))
        }
    }

    /// People (codex P1-6), tags and attestations (B2.4): only what THIS
    /// copy added or removed since its own baseline — so two copies edited
    /// differently in one commit both land, whatever their order.
    private func writeSetDeltas(_ current: CatalogRecordDTO, digest: String, fields: Set<CatalogDDL.KnowledgeField>,
                                baseline: CatalogSharedCurated?) throws {
        if !fields.isDisjoint(with: CatalogSharedCurated.Group.people.fields) {
            let delta = CatalogPeopleDelta(now: current.curated.people, baseline: baseline)
            try tx.writePeopleDelta(digest: digest, added: delta.added, removed: delta.removed)
        }
        if fields.contains(.tags) {
            let delta = CatalogSetDelta(now: current.curated.tags, was: baseline?.tags ?? [])
            try tx.writeTagsDelta(digest: digest, added: delta.added, removed: delta.removed)
        }
        if fields.contains(.backupAttestations) {
            let was = try CatalogRecordDTO.attestationRows(baseline?.backupAttestations ?? [])
            let delta = CatalogSetDelta(now: current.curated.backupAttestations, was: was)
            try tx.writeAttestationsDelta(digest: digest, added: delta.added, removed: delta.removed)
        }
    }

    /// Each content whose sets this commit wrote, read back once as a load
    /// gives it: its rows report the sets the store ends with (B2.4).
    private func settleSets() throws {
        for writer in ledger.setWriters(Self.deltaFields) {
            guard let row = try tx.storedRow(id: writer.id.uuidString) else { continue }
            ledger.settle(digest: writer.digest, CatalogCommit.SettledSets(try VideoRecord(loaded: row)))
        }
    }

    /// Each differing kind in its own savepoint; a kind the bound table
    /// cannot hold is left as it was and named (the row is then partial).
    private func writeDerived(_ current: CatalogRecordDTO, digest: String, kinds: [CatalogDDL.DerivedKind]) -> [String] {
        var missing: [String] = []
        for kind in kinds {
            do {
                try tx.inSavepoint {
                    try tx.replaceDerived(digest: digest, kind: kind, current.derivedUnverified.filter { $0.kind == kind })
                }
            } catch {
                missing.append("derived \(kind.rawValue) not stored: \(CatalogCommitWords.engine(error))")
            }
        }
        return missing
    }

    // MARK: - The designation

    private func writeDesignation() throws -> Bool {
        guard case .current(let json, let clearAuthorized) = plan.designation else { return false }
        let stored = try tx.masterArchiveJSON()
        guard !Self.sameJSON(stored, json) else { return false }
        if stored != nil, json == nil, !clearAuthorized { throw DesignationLossRefused() }
        try tx.setMasterArchive(json: json)
        return true
    }

    static func sameJSON(_ a: String?, _ b: String?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let x?, let y?): return CatalogJSONValue.parse(x) == CatalogJSONValue.parse(y)
        default: return false
        }
    }
}

/// People as a delta against the record's own baseline (codex B2 P1-6), on
/// FULL rows — name, kind and confirmation date (cutover B2.6, the class of
/// codex B2.4 F2): a removal is the exact row the baseline held, and a
/// re-dated confirmation is remove-old-row + add-new-row, so one copy
/// un-confirming a name never takes another copy's re-dating of it. A name
/// absent from both — an unresolved conflict the loaded record shows
/// empty — is not touched.
struct CatalogPeopleDelta {
    let added: [CatalogRecordDTO.PeopleTagRow]
    let removed: [CatalogRecordDTO.PeopleTagRow]

    init(now: [CatalogRecordDTO.PeopleTagRow], baseline: CatalogSharedCurated?) {
        let delta = CatalogSetDelta(now: now, was: baseline?.peopleRows ?? [])
        added = delta.added
        removed = delta.removed
    }
}

/// The words a commit speaks (one place, so tests and the app quote them).
enum CatalogCommitWords {

    struct Refusal: Error, CustomStringConvertible {
        let description: String
        init(_ words: String) { description = words }
    }

    static let noDigest = "no whole-file hash yet — catalog.sqlite keeps a row only for content it can name; "
        + "it is held until Fill In Full Hashes (queued for it) gives it one, then stored"

    static func notHeld(_ engine: String) -> String {
        noDigest + " — and it could NOT be held for the next launch (\(engine)); it is in memory only"
    }

    static func digestChanged(from was: String, to now: String) -> String {
        "its whole-file hash changed (\(was.prefix(12))… → \(now.prefix(12))…): a replaced file is a new row, "
            + "and the rescan (batch B3) records it — the stored row is unchanged"
    }

    static func markerJump(stored: Int, now: Int) -> String {
        "its removal marker changed \(now - stored) times within one save (revision \(stored) → \(now)); "
            + "catalog.sqlite records each change with its own tombstone and cannot invent the one in between, "
            + "so this row is not saved (its file is untouched; the other rows are saved)"
    }

    static func engine(_ error: Error) -> String {
        String(describing: error)
    }

    /// A replaced row kept live because its replacement was not stored (P0 2026-10-22).
    static func replacementNotStored(_ why: String) -> String {
        "kept in the catalog — the record that replaces it at the same path could not be stored (\(why)); "
            + "the row stays live, so its file is never left without a catalog row"
    }

    /// The row carries the purge marker (gap 3).
    static func isPurged(_ file: CatalogRecordDTO.FileRow) -> Bool {
        file.removalState == CatalogDDL.RemovalState.removedFromCatalog.rawValue && file.removalReason == CatalogRow.purgeReason
    }

    /// The curated fields every copy of one content shows (the display
    /// tables are keyed by digest).
    static let sharedByCopies: Set<CatalogDDL.KnowledgeField> = [
        .userNotes, .tags, .mediaDisposition, .starRating, .confirmedByUserPeople, .rejectedPeople,
        .userDate, .userDateConfidence, .userPlace, .userPlaceConfidence, .backupAttestations, .familyMusic,
    ]
}
