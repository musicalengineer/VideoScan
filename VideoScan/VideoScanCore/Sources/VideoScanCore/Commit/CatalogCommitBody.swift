// CatalogCommitBody.swift
// The body of one commit's write (cutover B2; CatalogCommit.swift says what
// a commit is). Runs on the store's queue inside `repository.write`; talks
// to the store only through `CatalogTransaction`'s doors, so no SQL and no
// GRDB type appears here.
//
// First the plain purges (B2.1 gap 3), each in its own savepoint; then each
// replaced row together with its replacement (`run`, P0 2026-10-22). Then per record
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
// BEFORE any of that (codex #143, the per-row lock): every submitted row's
// EXPECTATION — the lock of the row the committer last saw stored
// (CatalogRowLock), or "still held in pending_rows" — is checked against
// the store (CatalogRowCheck, the same check Reopen's read-back makes). One
// row another writer changed since this session saw it refuses the WHOLE
// commit: nothing is written, the generation is untouched, the words name
// the rows. The rows read for the check are the ones `land` compares
// against, so the check costs no extra read; a landed row is read back once
// more inside the transaction so the committer learns the lock the store
// holds now (`RowResult.storedLock`) — ≈ 0.7 ms a written row.
//
// (For Rick: the unit of work's apply loop; each `try` that throws inside a
// savepoint rolls back that one record and becomes its `.refused` words.
// The expectation pass is `WHERE rowversion = @expected` for every row,
// asked first, with one failure aborting the batch.)

import Foundation

struct CatalogCommitBody {
    let plan: CatalogCommit.Plan
    let tx: any CatalogTransaction
    let ledger: CatalogCommitLedger
    /// Copies of one content that changed the same field differently in
    /// this commit (B2.3, regression F2 — CatalogCommitConflicts.swift).
    let conflicts: CatalogCommitConflicts
    /// The rows the expectation pass read, handed to `land` once per id
    /// (a second snapshot of the same id reads the row the first one left).
    /// Bounded by the plan's items; dropped with the body.
    private let readRows = CommitRowCache()

    init(plan: CatalogCommit.Plan, tx: any CatalogTransaction, ledger: CatalogCommitLedger) {
        self.plan = plan
        self.tx = tx
        self.ledger = ledger
        conflicts = CatalogCommitConflicts(plan.items)
    }

    /// Codex #143: a row the store holds differently from what the
    /// committer expects. Thrown out of `run` BEFORE any write, so the whole
    /// commit is refused with these words and the generation stays.
    struct ChangedUnderYou: Error, CustomStringConvertible {
        let rows: [(id: UUID, mismatch: CatalogRowCheck.Mismatch)]
        var description: String { CatalogCommitWords.changedUnderYou(rows.map { ($0.id, $0.mismatch.words) }) }
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

    /// Order (P0 2026-10-22, codex #123): first the plain purges (no
    /// replacement — "gone from disk", Delete All; they also free live
    /// paths); then each REPLACEMENT GROUP in one savepoint — every purge
    /// the plan says this record replaces, then every snapshot of the
    /// record, in plan order. The purges stand only when the group leaves
    /// the record stored or held — read back from the store after the
    /// group (codex #124 F1); otherwise the savepoint is undone and the
    /// old rows (live or pending) stay. A group whose record is not in this
    /// commit purges only when the store already holds the record. Then
    /// every other record in plan order. The ledger lists purges first,
    /// then items, each in plan order (the app's baseline zips by order).
    ///
    /// The relation comes from the door that made the swap (the scan merge
    /// knows which old id each fresh record replaces) — never inferred from
    /// paths: a path match missed pending predecessors, folded case on
    /// case-sensitive volumes and skipped repeated snapshots (codex #123
    /// F1–F3). Before any of this, a FamilyArchive rescan purged 641 rows
    /// while 95 replacements were refused (generation 681).
    func run() throws {
        try verifyExpectations()
        var landed = 0
        var purgeRows = [CatalogCommit.RowResult?](repeating: nil, count: plan.purges.count)
        var itemRows = [(CatalogCommit.RowResult, Bool)?](repeating: nil, count: plan.items.count)
        let groups = replacementGroups()
        for (index, id) in plan.purges.enumerated() where plan.replacements[id] == nil || plan.replacements[id] == id {
            purgeRows[index] = purge(id)
        }
        for group in groups {
            let result = try replace(group)
            for (index, row) in zip(group.purgeIndices, result.purges) { purgeRows[index] = row }
            for (index, row) in zip(group.itemIndices, result.items) { itemRows[index] = row }
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

    // MARK: - The per-row lock (codex #143)

    /// Every submitted row's expectation against the store, FIRST — the
    /// first snapshot of each id (later snapshots follow from it). The rows
    /// read here are the ones `land` compares against. Any mismatch refuses
    /// the whole commit before a byte is written: refuse, never guess.
    private func verifyExpectations() throws {
        var seen = Set<UUID>()
        var mismatched: [(id: UUID, mismatch: CatalogRowCheck.Mismatch)] = []
        for item in plan.items where seen.insert(item.id).inserted {
            guard let expected = item.expected else { continue }
            let found = try CatalogRowCheck.find(id: item.id.uuidString, in: tx)
            if case .row(let row) = found { readRows.rows[item.id.uuidString] = row }
            if let mismatch = CatalogRowCheck.check(expected, snapshot: item.snapshot, sharedBaseline: item.sharedBaseline,
                                                    found: found) {
                mismatched.append((item.id, mismatch))
            }
        }
        guard mismatched.isEmpty else { throw ChangedUnderYou(rows: mismatched) }
    }

    /// The stored row for `id`: the expectation pass's read when it has
    /// one (consumed), else read now.
    private func loadedRow(id: String) throws -> CatalogLoadedRow? {
        if let row = readRows.rows.removeValue(forKey: id) { return row }
        return try tx.storedRow(id: id)
    }

    /// The row's lock as the store holds it after this row's write — read
    /// back inside the transaction; a row that cannot be read back is
    /// refused (its savepoint undone) rather than left unlocked.
    private func lockAfterWrite(id: String) throws -> CatalogRowLock.Value {
        guard let after = try tx.storedRow(id: id) else { throw CatalogCommitWords.Refusal(CatalogCommitWords.notReadBack) }
        return CatalogRowLock.of(after)
    }

    // MARK: - A replaced row and its replacement (P0 2026-10-22, codex #123)

    /// One replacement: the record, the purges it replaces, its snapshots.
    struct ReplacementGroup {
        let replacement: UUID
        var purgeIndices: [Int] = []
        var itemIndices: [Int] = []
    }

    /// The plan's replacement relation, grouped by the replacing record, in
    /// the order of each group's first purge. Every snapshot of the record
    /// joins its group (ordered snapshots are part of the contract, gap 2).
    func replacementGroups() -> [ReplacementGroup] {
        var order: [UUID] = []
        var byReplacement: [UUID: ReplacementGroup] = [:]
        for (index, id) in plan.purges.enumerated() {
            guard let replacement = plan.replacements[id], replacement != id else { continue }
            if byReplacement[replacement] == nil {
                order.append(replacement)
                byReplacement[replacement] = ReplacementGroup(replacement: replacement)
            }
            byReplacement[replacement]?.purgeIndices.append(index)
        }
        guard !order.isEmpty else { return [] }
        for (index, item) in plan.items.enumerated() where byReplacement[item.id] != nil {
            byReplacement[item.id]?.itemIndices.append(index)
        }
        return order.compactMap { byReplacement[$0] }
    }

    private struct ReplacementNotStored: Error {
        let words: String
    }

    /// The group in ONE savepoint: its purges stand only when the record
    /// ENDS the group stored or held — checked in the store after every
    /// snapshot ran, not read off the snapshots' results (codex #124 F1: a
    /// live snapshot followed by the record's purge snapshot, or a record
    /// already purged sent unchanged, both "landed" while the record ended
    /// purged). Otherwise everything in it is undone: the old rows stay
    /// (live or pending), the purges say why (`keptForReplacement`), and a
    /// snapshot that had landed is reported refused — the savepoint took it
    /// back, so the app keeps the record changed. A snapshot refused on its
    /// own keeps its own words.
    private func replace(_ group: ReplacementGroup)
        throws -> (purges: [CatalogCommit.RowResult], items: [(CatalogCommit.RowResult, Bool)]) {
        let ids = group.purgeIndices.map { plan.purges[$0] }
        var purgeRows = ids.map { CatalogCommit.RowResult(id: $0, fingerprint: 0, digest: nil, landing: .removed(.absent)) }
        var itemRows: [(CatalogCommit.RowResult, Bool)] = []
        do {
            try tx.inSavepoint {
                purgeRows = ids.map { purge($0) }
                itemRows = group.itemIndices.map { commit(plan.items[$0], replacing: ids) }
                if !itemRows.isEmpty, !itemRows.contains(where: { Self.keepsRecord($0.0) }) {
                    throw ReplacementNotStored(words: Self.refusalWords(itemRows.last?.0.landing))
                }
                // The record is not in this commit (an earlier commit stored
                // it), or its snapshots ran: either way it must be in the
                // store NOW, not carrying the purge marker.
                guard try tx.storedRecordPresent(id: group.replacement.uuidString) else {
                    throw ReplacementNotStored(words: itemRows.isEmpty
                        ? "it is not stored or held yet" : CatalogCommitWords.replacementEndsRemoved)
                }
            }
        } catch let kept as ReplacementNotStored {
            let words = CatalogCommitWords.replacementNotStored(group.replacement, kept.words)
            for index in purgeRows.indices {
                purgeRows[index].landing = .refused(words)
                purgeRows[index].keptForReplacement = true
            }
            for index in itemRows.indices {
                if Self.keepsRecord(itemRows[index].0) {
                    itemRows[index].0.landing = .refused(CatalogCommitWords.replacementUndone(ids, kept.words))
                    itemRows[index].0.adoptedRevision = nil
                }
                itemRows[index].0.heldPending = false
                itemRows[index].0.storedLock = nil          // the savepoint took the write back
                itemRows[index].1 = false
            }
        }
        return (purgeRows, itemRows)
    }

    /// The record is now in the store: written (whole or partial), already
    /// there, or held in `pending_rows` for its hash (the pending row
    /// carries the whole record across a relaunch).
    static func keepsRecord(_ row: CatalogCommit.RowResult) -> Bool {
        switch row.landing {
        case .written, .partial, .unchanged: return true
        case .deferred: return row.heldPending
        case .refused, .removed: return false
        }
    }

    private static func refusalWords(_ landing: CatalogCommit.Landing?) -> String {
        switch landing {
        case .refused(let words)?, .deferred(let words)?: return words
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
    /// `replacing`: the ids this record replaces (its replacement group's
    /// purges) — a NEW archive copy takes their provenance (P0 2026-10-22).
    private func commit(_ item: CatalogCommit.Item, replacing: [UUID] = []) -> (CatalogCommit.RowResult, Bool) {
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
            result = land(current, digest: digest, item: item, replacing: replacing, into: result)
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

    private func land(_ mapped: CatalogRecordDTO, digest: String, item: CatalogCommit.Item, replacing: [UUID],
                      into result: CatalogCommit.RowResult) -> CatalogCommit.RowResult {
        var result = result
        do {
            let row = try loadedRow(id: mapped.file.id)
            let stored = try row.map(storedDTO)
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
                result.storedLock = row.map(CatalogRowLock.of)
                return result
            }
            var written = Written()
            var lock: CatalogRowLock.Value?
            try tx.inSavepoint {
                written = try write(current, digest: digest, stored: stored, diff: diff, baseline: item.sharedBaseline,
                                    replacing: replacing)
                lock = try lockAfterWrite(id: mapped.file.id)
            }
            result.storedLock = lock
            // A field in conflict is not shared: each copy keeps its own value (F2).
            let inConflict = conflicts.fields(of: digest)
            let curated = diff.knowledge.filter { CatalogCommitWords.sharedByCopies.contains($0) && !inConflict.contains($0) }
            result.landing = written.missing.isEmpty
                ? .written(curated: curated, notes: written.notes) : .partial(curated: curated, words: written.missing)
        } catch {
            result.landing = .refused(CatalogCommitWords.engine(error))
            result.adoptedRevision = nil
            result.storedLock = nil
        }
        return result
    }

    /// The stored row as the DTO a record loaded from it would give.
    private func storedDTO(_ row: CatalogLoadedRow) throws -> CatalogRecordDTO {
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
                       diff: CatalogRecordDiff, baseline: CatalogSharedCurated?, replacing: [UUID]) throws -> Written {
        let id = current.file.id
        if let stored {
            if diff.file || diff.marker { try updateRow(current, stored: stored, diff: diff) }
        } else {
            try insertRow(current)
            _ = try tx.removePendingRow(id: id)
        }
        var written = Written()
        // A new archive copy keeps the provenance of the row it replaces (an
        // import-era copy stays 'import'); the app's record never carries it.
        if diff.archiveCopy {
            try tx.replaceArchiveCopy(fileID: id, current.archiveCopy, replacing: replacing.map(\.uuidString))
        }
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

/// The rows one commit's expectation pass read (codex #143), by id. Lives
/// and dies with the body on the store's queue — nothing else sees it.
/// (For Rick: a scratch map, not a cache: filled once, drained by `land`.)
final class CommitRowCache {
    var rows: [String: CatalogLoadedRow] = [:]
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

    /// Codex #143: a submitted row the store holds differently from what
    /// this session last saw (the per-row lock). The whole commit is refused.
    static func changedUnderYou(_ rows: [(id: UUID, why: String)]) -> String {
        let named = rows.prefix(5).map { "\($0.id.uuidString) (\($0.why))" }.joined(separator: "; ")
        let more = rows.count > 5 ? "; … and \(rows.count - 5) more" : ""
        return "the catalog changed under this session — \(rows.count) row(s) in this save were changed by another writer "
            + "since this session last read them: \(named)\(more); nothing was written — choose Catalog ▸ Reopen SQLite Catalog, "
            + "which holds the rows that changed, names them, and saves the rest"
    }

    /// A landed row that could not be read back inside its own transaction.
    static let notReadBack = "its row could not be read back after the write — not saved (refused rather than left unchecked)"

    /// A replaced row kept because its replacement is not stored (P0 2026-10-22, codex #123).
    static func replacementNotStored(_ replacement: UUID, _ why: String) -> String {
        "kept in the catalog — the record that replaces it (\(replacement.uuidString)) is not stored: \(why); "
            + "the row stays, so its file is never left without a catalog row"
    }

    /// The replacement's snapshots ran but it ends the save purged (codex #124 F1).
    static let replacementEndsRemoved = "it ends this save removed from the catalog (purged) — "
        + "a later snapshot took it out, or it was already purged"

    /// A replacement's snapshot that had landed, undone with the purges it
    /// would have let stand (codex #124 F1): the app keeps it changed.
    static func replacementUndone(_ replaced: [UUID], _ why: String) -> String {
        "not saved — it replaces \(replaced.map(\.uuidString).joined(separator: ", ")) and \(why); "
            + "the old row stays and this save of it is undone with the purge"
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
