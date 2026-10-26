// CatalogCommitter.swift
// Where the three save funnels go once catalog.sqlite is the authority
// (cutover B2, docs/design/catalog_cutover_f_prime_2026_10_17.md §3 and §10
// "B2-lite"). One sentence: when the app would have saved catalog.json, it
// commits the records that changed since the last commit into catalog.sqlite
// instead — same debounce, same synchronous save at quit.
//
// B2.2 — ONE SYNCHRONOUS TURN. Two codex rounds in a row (B2, B2.1 closing
// pass) found loss in the off-main "flight" machinery, so the commit was
// re-scoped (safety-critical rule 5): a commit runs ENTIRELY on the main
// actor, snapshot to baseline, with no `await`, no Task and no semaphore in
// between —
//   1. a `VideoRecordDTO` snapshot per record and its fingerprint
//      (CatalogChangeDetector: the hashing still spreads over the cores;
//      the main thread waits for it);
//   2. the changed rows → ONE plan → `CatalogCommit.runBlocking`
//      (`repository.writeBlocking`: GRDB's writer; the main thread waits):
//      purges, then per row insert / update / held / partial / refused,
//      then the Master Archive designation;
//   3. the baseline moves (CatalogCommitBaseline.absorb), the committed
//      curated values go onto the other copies of the same content
//      (`propagate`), held rows get Fill In Full Hashes, one line to the sink.
// So no record can change while a commit runs: an edit "during" a commit, a
// marker change during a first insert, a quit overlapping a commit — the
// whole race class codex found — can no longer be written.
// Cost (B2, M4, Debug, 14k rows): detection 45–83 ms + a one-row write
// 25–33 ms, ≈ 0.1 s of blocked UI per save — about today's JSON save.
// Pinned by CatalogCommitScaleTests.syncCommit* (1 row < 150 ms, 1,000 rows
// < 1.5 s); CatalogCommitterSyncSensorTests fails if a hop comes back.
//
// Doors: the 2 s debounce (it only decides WHEN the synchronous commit
// runs), `commitNow` (quit and every synchronous save), `commitAcknowledged`
// (the same synchronous commit; returns its truth), `commitNow(ids:)` (the
// removal markers), `purge(ids:reason:)` (a door took records out),
// `commitBeforeReplacing` (placeRecord saves the record it replaces first).
//
// Removal markers (gap 2; B2.3 veto). catalog.sqlite wants every marker
// revision with its own tombstone. The one marker writer asks BEFORE a
// change (`markerWillChange`), and the answer is binding (codex B2.2 P1: a
// pre-commit that failed used to be ignored, the change went ahead, and the
// store then refused that row — and every later save of it — for good):
//   * a person's request (`.request`: Trash, Remove, Restore, Undo, an
//     audit's mark) is REFUSED while no commit can be written now — held by
//     a job, read-only / refused, being reopened — with words saying why and
//     when to try again: "the catalog can't save (…); try again when …";
//   * any change (`.request` or `.diskFact`, a file that already left) of a
//     row whose previous marker change is not committed yet commits that one
//     NOW, synchronously; when it cannot be stored the change is REFUSED —
//     the store holds revision n before any record moves to n+1, always.
// A refused change touches nothing (no revision bump). After a change
// (`markerDidChange`) the row is remembered and one commit is asked for at
// once (zero delay), so Trash of 1,000 rows in one turn is ONE commit.
//
// Purges (gap 3; B2.3 — codex B2.2 finding (e)). A row is purged
// (tombstoned; a held row's payload KEPT, `pending_purges`) ONLY when a door
// that removes a record from the catalog says so: `purge(ids:reason:)`,
// through VideoScanModel.purgeCatalogRows, in the same turn as the removal.
// Absence proves nothing — B2.2 purged an id absent at two full commits,
// and codex showed a live file's row (and its saved curated values) could
// go that way. An id the store holds that left memory with no door's purge
// is a BUG: said once per id ("left memory without a purge — kept in the
// catalog") and kept.
//
// Held rows (gap 1): durable only at the fingerprint of the payload the
// store holds — a failed pending update leaves the row dirty and NOT durable.
//
// Outcomes and what the person sees (the console, catalog.log and
// videoscan.log through `sink`; `blockedReason` drives the Reopen item):
//   committed / nothing to write  → the baseline moves; a refused row is
//                                   named ONCE and not sent again until it
//                                   changes; a held row (no whole-file hash)
//                                   is durable and counted in one line;
//   held (MOPS-16)                → nothing written; re-checked every 2 s
//                                   until the holder lets go (only the
//                                   holder's OWN token passes);
//   refused / generation mismatch → nothing written, the records stay
//                                   changed, the store's words are shown, and
//                                   NO further commit is tried until the
//                                   person chooses Catalog ▸ Reopen SQLite
//                                   Catalog (never retried silently);
//   changed under you             → the store found a submitted row changed
//                                   by ANOTHER WRITER since this session saw
//                                   it (the per-row lock, CatalogRowLock, or
//                                   a shared scalar's per-field baseline —
//                                   codex #141 F2, closed in cycle #143):
//                                   the whole commit is refused like any
//                                   refusal, nothing written, generation kept;
//   file-stop (GH #359)           → catalog.sqlite or its latch is not the
//                                   file this session opened: refused like
//                                   any refusal, but the words say "quit and
//                                   reopen" and Catalog ▸ Reopen is REFUSED
//                                   (it would open the replacement and
//                                   commit memory into it);
//   marker change refused         → the row is left exactly as it was; the
//                                   door shows the words (once per reason
//                                   here, per row at the door).
//
// THE PROMISE of Catalog ▸ Reopen after another writer (codex #143 —
// "refuse rather than guess", CLAUDE.md rule 2): Reopen reads back, in ONE
// store snapshot, every record the next commit could submit (held and new
// records included). A row the store still holds exactly as this session
// last saw it (its lock and its shared-scalar baseline) may be saved as it
// is — every difference is ours. A row that moved is HELD: out of every
// commit, dirty in memory with the person's values untouched, named with
// the parts that differ (one HELD line per row in catalog.log, said again
// at every Reopen, counted in the OUTCOME), its marker changes refused at
// the door — until a relaunch loads the catalog's values and the person
// redoes the edit. Nothing in memory is rebuilt or swapped; nothing of the
// other writer's is ever overwritten by this session's stale copy; what
// this session cannot attribute (a footage decision missing in memory —
// theirs added, or ours removed?) is not guessed at. A failed read-back
// (an error, a missing row, a row that no longer decodes) keeps saving
// blocked with words. The read-back's set is captured before the read; a
// record that turns dirty afterwards meets the same check at the commit
// door, inside the transaction, where the generation compare-and-set still
// stands beneath it.
//
// Memory: CatalogCommitBaseline (≈ 160 B a record); a commit holds one
// snapshot per record for its length (the snapshots share their strings and
// arrays with the records).
//
// (For Rick: a write-behind flusher whose flush is now a plain blocking
// call on the UI thread — dirty bits computed by checksum, a 2-second timer
// deciding when to flush, and nothing else running while it does. The
// marker veto is a "can I take the lock?" asked before the mutation, the
// purge an explicit erase(key) from the code that erased the element.)

import Foundation
import VideoScanCore

/// What a removal-marker change is, for the veto (B2.3).
enum CatalogMarkerChange: Sendable {
    /// A person's request or an audit's mark: refused while no commit can
    /// be written now.
    case request
    /// The disk already changed (the file is in the Trash): refused only
    /// when the row's previous marker change cannot be stored first.
    case diskFact
}

@MainActor
final class CatalogCommitter {

    /// What the funnels hand over at the moment of a commit.
    struct Input {
        var records: [VideoRecord]
        var designation: MasterArchiveDesignation?
        /// `Clear Master Archive` authorised the designation's removal.
        var clearAuthorized: Bool
        /// MOPS-16: the job holding catalog writes, if any, and its token.
        var holdReason: String?
        var holdOwner: CatalogWriteHoldOwner?
        /// Codex cycle #112: why this session may not write at all (a viewer,
        /// a read-only launch, a Switch freeze — `CatalogReadOnlyFacts
        /// .readOnlyWords`). Non-nil refuses EVERY commit at admission.
        var readOnlyReason: String? = nil
    }

    static let debounce: Duration = .seconds(2)
    /// Lines naming records that left memory without a purge, per commit.
    static let unpurgedLinesPerCommit = 10

    let repository: any CatalogRepository
    private let input: () -> Input
    private let sink: (String) -> Void
    /// After curated fields were copied onto other copies of a content.
    var onCopiesUpdated: () -> Void = {}
    /// The blocked state changed (the Reopen item follows it).
    var onBlockedChanged: (String?) -> Void = { _ in }
    /// New rows with no whole-file hash are held: queue Fill In Full Hashes.
    var onNeedDigest: (Set<UUID>) -> Void = { _ in }
    /// The held set changed (a held row was stored or left the catalog).
    var onHeldChanged: (Set<UUID>) -> Void = { _ in }
    /// A reopen or an adopt made the store writable again.
    var onWritableAgain: () -> Void = {}
    /// True when `record` is THIS session's live record (not a detached
    /// snapshot, not another session's): only those can be vetoed.
    var owns: (VideoRecord) -> Bool = { _ in true }

    private var baseline = CatalogCommitBaseline()
    /// The designation catalog_state holds as far as this session knows.
    private var storedDesignationJSON: String?
    private var debounceTask: Task<Void, Never>?
    /// Rows whose removal marker changed since their last commit.
    private var markerDirty: Set<UUID> = []
    /// Codex #143: rows Reopen found changed by another writer — HELD out
    /// of every commit (id → the words), dirty in memory, until a relaunch
    /// (`adoptBaseline`) or a later Reopen that finds them unchanged.
    private(set) var conflicts: [UUID: String] = [:]
    /// Ids a door removed from the catalog, not yet purged (id → why).
    private var purgeRequested: [UUID: String] = [:]
    /// Of `purgeRequested`: purged id → the record that replaces it
    /// (P0 2026-10-22, codex #123 F4 — kept while the store keeps the row).
    private var replacedBy: [UUID: UUID] = [:]
    /// Of `replacedBy`: kept purges already named as waiting on a
    /// replacement that is gone (said once each, codex #124 F2).
    private var notedUnresolved: Set<UUID> = []
    /// Reopen / Adopt is closing and opening the store: no commit runs.
    private var reopening = false
    private var heldBy: String?
    private var lastRefusalNote: String?
    private var lastMarkerRefusal: String?
    private(set) var blockedReason: String? {
        didSet { if blockedReason != oldValue { onBlockedChanged(blockedReason) } }
    }
    private(set) var lastOutcome: CatalogCommit.Outcome?
    /// catalog.sqlite's generation as this session last knew it: the
    /// launch's read, then every commit's, a reopen's and an adopt's. What
    /// a synchronous stamp (the quit copy's header) records — never the
    /// frozen JSON store's (QA r1 F3, 2026-10-21). Async callers may read
    /// the repository itself (`generationNow()`).
    private(set) var knownGeneration = 0
    /// Writes attempted (tests and the status line).
    private(set) var commitCount = 0
    /// The last commit's snapshot + fingerprint cost.
    private(set) var lastDetection: Duration = .zero

    /// A commit is waiting on the timer (tests wait on this).
    var isBusy: Bool { debounceTask != nil }
    /// Ids held in `pending_rows` (no whole-file hash yet).
    var heldIDs: Set<UUID> { Set(baseline.held.keys) }

    init(repository: any CatalogRepository, storedDesignationJSON: String?,
         input: @escaping () -> Input, sink: @escaping (String) -> Void) {
        self.repository = repository
        self.storedDesignationJSON = storedDesignationJSON
        self.input = input
        self.sink = sink
    }

    // MARK: - Baseline

    /// The store holds exactly these records (right after a load, before
    /// the launch-time migrations run — what they change is then committed).
    /// `held`: records that came from `pending_rows` (still no row).
    /// `locks`: each loaded row's per-row lock from the store (codex #143).
    func adoptBaseline(_ records: [VideoRecord], held: Set<UUID> = [], generation: Int? = nil,
                       locks: [UUID: CatalogRowLock.Value] = [:]) {
        if let generation { knownGeneration = generation }
        baseline.adopt(records, held: held, locks: locks)
        conflicts = [:]
        markerDirty = []
        purgeRequested = [:]
        replacedBy = [:]
        notedUnresolved = []
    }

    /// Refuse every commit until a person reopens (a read-only open).
    func block(_ reason: String) {
        blockedReason = reason
    }

    /// Records whose state is not in catalog.sqlite (tests; the status
    /// line). Held rows count: they are not rows yet.
    func changedRecordCount() -> Int {
        let records = input().records
        let prints = CatalogChangeDetector.fingerprints(of: records.map(VideoRecordDTO.init))
        return CatalogChangeDetector.changed(records.map(\.id), fingerprints: prints, baseline: baseline.prints).count
    }

    // MARK: - Removal markers (through CatalogMarkerRelay)

    /// The marker of `record` is about to change. nil = it may; else the
    /// words ("the catalog can't save (…); try again when …") and the
    /// writer must leave the row exactly as it is. See the header.
    func markerWillChange(_ record: VideoRecord, kind: CatalogMarkerChange) -> String? {
        guard owns(record) else { return nil }
        let id = record.id
        if kind == .request, let why = saveRefusal() { return refuseMarker(why) }
        // Codex #143: a row held because another writer changed it cannot
        // take a person's marker change — it would never be saved. A disk
        // fact (the file already moved) is recorded in memory and stays held.
        if kind == .request, let words = conflicts[id] {
            return refuseMarker(Self.cantSave(words, until: "you relaunch and redo the change"))
        }
        guard markerDirty.contains(id) else { return nil }
        commitNow(ids: markerDirty)
        guard markerDirty.contains(id) else { return nil }
        let words = baseline.waiting[id]?.words ?? "its previous removal-marker change is not saved yet"
        return refuseMarker(saveRefusal() ?? Self.cantSave(words, until: "that change is saved"))
    }

    /// The marker of `id` changed (its revision already bumped): commit it
    /// as soon as this turn ends — one commit for a whole batch.
    func markerDidChange(id: UUID) {
        guard baseline.prints[id] != nil else { return }
        markerDirty.insert(id)
        scheduleCommit(after: .zero)
    }

    /// Why no commit can be written right now, in the person's words; nil
    /// when one can. (Internal: the quit's recovery-copy words use it.)
    func saveRefusal() -> String? {
        if reopening { return Self.cantSave("it is being reopened", until: "the reopen finishes") }
        // GH #359: catalog.sqlite (or its latch) is not the file this session
        // opened. The words end "quit and reopen" — never Catalog ▸ Reopen,
        // which would open the replacement and commit memory into it.
        if let stop = fileStop { return Self.cantSaveUntilQuit(stop) }
        if let blockedReason { return Self.cantSave(blockedReason, until: "you choose Catalog ▸ Reopen SQLite Catalog") }
        let now = input()
        if let readOnly = now.readOnlyReason { return Self.readOnlyWords(readOnly) }
        if let hold = now.holdReason { return Self.cantSave("held — \(hold)", until: "that job finishes") }
        return nil
    }

    /// Said once per reason (a batch of 1,000 refusals is one line here;
    /// the door names its rows).
    private func refuseMarker(_ why: String) -> String {
        if lastMarkerRefusal != why {
            lastMarkerRefusal = why
            sink("Catalog store: REFUSED a removal-marker change — \(why). The row is left as it was.")
        }
        return why
    }

    static func cantSave(_ words: String, until: String) -> String {
        "the catalog can't save (\(words)); try again when \(until)"
    }

    /// GH #359: no "try again when" — the stop's own words say quit and reopen.
    static func cantSaveUntilQuit(_ stop: String) -> String {
        "the catalog can't save (\(stop))"
    }

    /// GH #359: the store's file-stop words while saving stopped because
    /// catalog.sqlite or its latch was replaced or moved. Only read while
    /// commits are already blocked, so a working session pays no `stat`.
    private var fileStop: String? {
        blockedReason == nil ? nil : repository.fileStopWords
    }

    /// Catalog ▸ Reopen SQLite Catalog is refused after a file-stop.
    var canReopen: Bool { blockedReason != nil && fileStop == nil }

    /// A read-only session never saves; there is no "try again when".
    static func readOnlyWords(_ why: String) -> String {
        "the catalog is read-only in this session (\(why)) — nothing is saved"
    }

    // MARK: - The doors

    /// `saveCatalogDebounced`: 2 s after the last call, one commit.
    func scheduleCommit(after delay: Duration = CatalogCommitter.debounce) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.commitFromTimer()
        }
    }

    /// `saveCatalogNow` (quit, Delete All, every synchronous save): one
    /// synchronous commit. True when every changed record is now in
    /// catalog.sqlite (held rows count as durable at their payload).
    @discardableResult
    func commitNow() -> Bool {
        cancelTimer()
        return commit(.quit, owner: nil, scope: .everything)
    }

    /// `saveCatalogAcknowledged`: the same synchronous commit; its truth is
    /// returned. `owner`: the MOPS-16 token the caller presents — only the
    /// holder's own passes.
    func commitAcknowledged(owner: CatalogWriteHoldOwner?) async -> Bool {
        cancelTimer()
        return commit(.acknowledged, owner: owner, scope: .everything)
    }

    /// The removal-marker door: only these rows, now.
    @discardableResult
    func commitNow(ids: Set<UUID>) -> Bool {
        commit(.save, owner: nil, scope: .only(ids))
    }

    /// `placeRecord` is about to replace `id` at its path (B2.5, codex
    /// B2.4 F1): the record's CURRENT values are committed now, so an edit
    /// made inside the debounce is in files / the display rows /
    /// row_knowledge before anything is inherited, purged or retired.
    /// nil = durable; else the words why not (held, blocked, being
    /// reopened, refused) — and the caller must replace nothing.
    func commitBeforeReplacing(_ id: UUID) -> String? {
        if commitNow(ids: [id]) { return nil }
        return saveRefusal() ?? conflicts[id] ?? baseline.waiting[id]?.words ?? "its current values could not be stored"
    }

    /// A safety copy of catalog.sqlite is about to be sealed (`VACUUM INTO`,
    /// B2.3): what is in memory is committed FIRST, so the copy holds what
    /// the person sees — including an edit typed inside the 2 s debounce
    /// (adversarial review 2026-10-18 #3; the catalog.json snapshot was
    /// written from memory for the same reason, QA #7). nil = the commit ran
    /// (the copy may be sealed); else the words why no commit can be written
    /// now — held, blocked, being reopened, refused — and the caller must
    /// not seal a copy that lags memory. A row the store itself refuses
    /// (named once at its commit) does not stop the copy: it is said here
    /// and the copy carries that row's last stored values.
    func commitBeforeSafetyCopy() -> String? {
        cancelTimer()
        let stored = commit(.save, owner: nil, scope: .everything)
        if let why = saveRefusal() { return why }
        if !stored {
            sink("Catalog store: safety copy — \(baseline.waiting.count) row(s) the store would not take"
                 + (conflicts.isEmpty ? "" : " and \(conflicts.count) row(s) held (changed under you)")
                 + " are in it at their last stored values")
        }
        return nil
    }

    /// Catalog folders (2026-10-19, EventsCatalogBacking.swift): why a
    /// folder change cannot be written now — the same refusals as a
    /// person's marker request (read-only session, held, blocked, being
    /// reopened) — nil when it can.
    var folderWriteRefusal: String? { saveRefusal() }

    /// Catalog folders: ONE synchronous write of a folder change (its
    /// `events` rows, its decisions, its membership folds), on the main
    /// actor like every commit here. nil = committed; else the words, and
    /// nothing was written. Records are not touched: their baseline is
    /// unaffected (the store tracks the generation itself).
    func commitFolders(_ what: String, _ body: (any CatalogTransaction) throws -> Void) -> String? {
        commitSideTables(what, via: .folders, body)
    }

    /// The side tables a person's decision writes outside the records:
    /// Catalog folders (2026-10-19), the footage likeness the split records
    /// and the ignore list (schema v1.11). Each says which in the log line.
    enum SideTable: String, Sendable {
        case folders
        case footageLikeness = "footage likeness"
        case ignoredContent = "ignored content"

        var change: String { self == .folders ? "a folder change" : "a \(rawValue) change" }
    }

    /// Why a side-table change cannot be written now (the same refusals
    /// as a person's marker request) — nil when it can.
    var sideTableWriteRefusal: String? { saveRefusal() }

    /// ONE synchronous write of a side-table change, on the main actor like
    /// every commit here. nil = committed; else the words, and nothing was
    /// written. Records are not touched: their baseline is unaffected (the
    /// store tracks the generation itself).
    func commitSideTables(_ what: String, via table: SideTable, _ body: (any CatalogTransaction) throws -> Void) -> String? {
        if let why = saveRefusal() { return why }
        switch repository.writeBlocking(as: .ui, body) {
        case .committed(let generation):
            knownGeneration = generation   // codex cycle #116 F3: the quit copy's header stamp
            sink("Catalog store: OUTCOME commit generation \(generation) via \(table.rawValue) — \(what)")
            return nil
        case .refused(let words):
            sink("Catalog store: REFUSED \(table.change) (\(what)) — \(words). Nothing was written.")
            return words
        case .generationMismatch(let expected, let found):
            let words = "another writer committed generation \(found) (this session expected \(expected)) — reopen the catalog"
            blockedReason = words
            sink("Catalog store: REFUSED \(table.change) (\(what)) — \(words). Nothing was written.")
            return words
        }
    }

    /// A door took these records out of the catalog (VideoScanModel
    /// .purgeCatalogRows): their rows are purged in one synchronous commit
    /// now — or, while the store is held or blocked, at the first commit
    /// that can run. The ONLY way a row is purged (B2.3).
    /// `replacements`: purged id → the record that replaces it (a rescan's
    /// fresh instance), from the door that made the swap — the store then
    /// purges the old row only together with a stored or held replacement
    /// (P0 2026-10-22, codex #123). Absent = a plain removal.
    ///
    /// The kept relations are reconciled FIRST, over every id the door
    /// names — stored or not (codex #124 F2): a kept purge waiting on a
    /// replacement the store never took follows what happens to that
    /// replacement (`reconcileKept`).
    func purge(ids: Set<UUID>, reason: String, replacements: [UUID: UUID] = [:]) {
        let reconciled = reconcileKept(removed: ids, replacements: replacements)
        let known = ids.filter { baseline.holds($0) }
        guard !known.isEmpty || reconciled else { return }
        for id in known {
            purgeRequested[id] = reason
            if let r = replacements[id], r != id { replacedBy[id] = r }
        }
        if !known.isEmpty { sink("Catalog store: START purge of \(known.count) row(s) — \(reason)") }
        commit(.save, owner: nil, scope: .everything)
    }

    /// A kept purge (A, waiting on B) when a door removes B before the
    /// store took it (codex #124 F2). True when a relation changed.
    ///   * B is swapped for C (`replacements[B] = C`): A now waits on C and
    ///     goes with it — so C never meets A's live row at the same path.
    ///   * B is removed outright (no replacement — gone from disk, Delete
    ///     All): A's dependency is RELEASED, and so is its purge request.
    ///     A is NOT purged on B's account: nothing proved A's own file
    ///     gone, and the old row may go only beside a stored replacement.
    ///     A stays in the catalog, named here (and once more as a record
    ///     that left memory without a purge); after a reload its own
    ///     evidence decides it.
    /// A relation to a replacement the store DOES hold is left alone: that
    /// dependency is already met (`duePurges` sends A).
    private func reconcileKept(removed ids: Set<UUID>, replacements: [UUID: UUID]) -> Bool {
        let waiting = replacedBy.filter { ids.contains($0.value) && !baseline.holds($0.value) }
        for (old, gone) in waiting.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            if let next = replacements[gone], next != gone, next != old {
                replacedBy[old] = next
                sink("Catalog store: row \(old.uuidString) now waits for \(next.uuidString), "
                     + "which replaced \(gone.uuidString) before it was stored")
            } else {
                replacedBy[old] = nil
                purgeRequested[old] = nil
                sink("Catalog store: KEPT \(old.uuidString) — the record that was to replace it (\(gone.uuidString)) "
                     + "left the catalog before it was stored; the row stays and is not purged on its account")
            }
        }
        return !waiting.isEmpty
    }

    private func commitFromTimer() {
        debounceTask = nil
        commit(.save, owner: nil, scope: .everything)
    }

    private func cancelTimer() {
        debounceTask?.cancel()
        debounceTask = nil
    }

    // MARK: - Reopen / adopt

    /// Catalog ▸ Reopen SQLite Catalog: close, open again, and — when the
    /// store is writable — commit what is still changed.
    func reopen(at url: URL) async {
        // GH #359: the file at `url` is not the one this session opened —
        // reopening it would commit memory into the replacement. Refused,
        // the store left as it is, the same words as every refused save.
        if let stop = fileStop ?? repository.fileStopWords {
            blockedReason = stop
            sink("Catalog store: REFUSED Catalog ▸ Reopen SQLite Catalog — \(stop). Nothing was opened or written.")
            return
        }
        reopening = true
        cancelTimer()
        await repository.close()
        for line in repository.lastCloseNotes { sink(line) }        // GH #359 QA r2-2
        // codex #117 F4: a swap while close was pending is a stop too —
        // re-checked AFTER close and BEFORE opening; a stop opens nothing.
        if let stop = repository.fileStopWords {
            reopening = false
            blockedReason = stop
            sink("Catalog store: REFUSED Catalog ▸ Reopen SQLite Catalog — \(stop). Nothing was opened or written.")
            return
        }
        let opened = await repository.open(at: url, requiringLatch: true)   // QA r1 D (#359): no latch, no reopen
        switch opened {
        case .readWrite:
            // Codex #143: ALWAYS the read-back (a door's "changed under you"
            // refusal leaves the generation equal, so the generation alone
            // cannot say whether another writer was here).
            switch await readBack() {
            case .failed(let words):
                reopening = false
                blockedReason = words
                sink("Catalog store: REFUSED Reopen's read-back — \(words). Nothing was written; saving stays blocked.")
            case .checked(let found, let checked, let held):
                reopening = false
                knownGeneration = found
                conflicts = held
                for (id, words) in held.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                    sink("Catalog store: HELD \(id.uuidString) — \(words)")
                }
                sink("Catalog store: OUTCOME reopened catalog.sqlite at generation \(found) — \(checked) changed record(s) checked "
                     + "against the catalog: \(checked - held.count) may be saved, \(held.count) held (changed under you); "
                     + "writes allowed again; committing what is still changed")
                becameWritable()
            }
        case .readOnly(let reason), .refused(let reason):
            reopening = false
            blockedReason = "read-only: \(reason)"
            sink("Catalog store: OUTCOME reopened catalog.sqlite READ-ONLY — \(reason)")
        }
    }

    // MARK: - Reopen after another writer (codex #141 F2 → #143: refuse and name)

    /// What Reopen's read-back found.
    private enum ReadBack {
        /// The store's generation, how many records were checked, and the
        /// rows that moved under this session (id → the words).
        case checked(generation: Int, checked: Int, conflicts: [UUID: String])
        /// No comparison, no commit: the words, and saving stays blocked.
        case failed(String)
    }

    /// Every record the next commit could submit — the commit's own rule
    /// (fingerprint ≠ baseline: edited, held and new records alike; rows
    /// waiting on a refusal too, since Reopen forgets it) — checked against
    /// the store in ONE read snapshot with the generation. A record this
    /// session created has no expectation; when its content is already
    /// stored, its shared scalars meet the door's new-copy check against a
    /// stored sibling (codex #145 F2) — otherwise there is nothing to check. The
    /// comparison is of the STORE against the BASELINE (CatalogRowCheck, the
    /// same check the commit door makes), so an edit made during the read
    /// changes nothing here; a record that turns dirty after the read meets
    /// the door's check.
    /// Memory: one loaded row per changed record for the length of the
    /// read — worst case (every record changed) one copy of the catalog's
    /// rows, what a launch holds; dropped before this returns.
    private func readBack() async -> ReadBack {
        let wanted = readBackSet()
        let read: ReadFindings
        do {
            read = try await repository.read { reader in try Self.find(wanted, in: reader) }
        } catch {
            return .failed("this session's \(wanted.count) changed record(s) could not be compared with the catalog (\(error)) — "
                           + "quit and relaunch, then redo the change(s)")
        }
        let byID = Dictionary(input().records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var held: [UUID: String] = [:]
        for entry in wanted {
            guard let record = byID[entry.id] else { continue }
            switch verdict(entry, record: record, read: read) {
            case .saveable: continue
            case .failed(let words): return .failed(words)
            case .held(let words): held[entry.id] = words
            }
        }
        return .checked(generation: read.generation, checked: wanted.count, conflicts: held)
    }

    /// One record the read-back checks: its expectation, or — a record this
    /// session created — the content its shared scalars meet (codex #145 F2).
    private struct Wanted: Sendable {
        let id: UUID
        let expected: CatalogCommit.Expectation?
        let newCopy: CatalogCommitBaseline.NewCopy?
    }

    /// What one read snapshot found for the wanted records.
    private struct ReadFindings: Sendable {
        let generation: Int
        var found: [UUID: CatalogRowCheck.Found] = [:]
        var content: [UUID: CatalogLoadedRow] = [:]
    }

    /// One record's outcome on Reopen.
    private enum Verdict {
        case saveable
        case held(String)
        case failed(String)
    }

    /// The records the next commit could submit that have something to
    /// check: a row or held payload (its expectation), or a new copy of a
    /// content the store already holds (F2).
    private func readBackSet() -> [Wanted] {
        let records = input().records
        let changed = changedSinceBaseline(records)
        let fresh = baseline.newCopies(changed, among: records)
        return changed.compactMap { record in
            if let expected = baseline.expectation(of: record.id) { return Wanted(id: record.id, expected: expected, newCopy: nil) }
            return fresh[record.id].map { Wanted(id: record.id, expected: nil, newCopy: $0) }
        }
    }

    /// Inside the one read snapshot (off the main actor).
    private nonisolated static func find(_ wanted: [Wanted], in reader: any CatalogReader) throws -> ReadFindings {
        var out = ReadFindings(generation: reader.generation)
        for entry in wanted {
            if entry.expected != nil { out.found[entry.id] = try CatalogRowCheck.find(id: entry.id.uuidString, in: reader) }
            if let copy = entry.newCopy {
                out.content[entry.id] = try reader.storedContentRow(digest: copy.digest, excluding: entry.id.uuidString)
            }
        }
        return out
    }

    /// The commit door's own comparison (CatalogRowCheck), in Reopen words.
    private func verdict(_ entry: Wanted, record: VideoRecord, read: ReadFindings) -> Verdict {
        let snapshot = VideoRecordDTO(record)
        let found = read.found[entry.id] ?? .nothing
        let mismatch: CatalogRowCheck.Mismatch?
        if let expected = entry.expected {
            mismatch = CatalogRowCheck.check(expected, snapshot: snapshot, sharedBaseline: baseline.shared[entry.id], found: found)
        } else {
            mismatch = CatalogRowCheck.checkNewCopy(snapshot: snapshot, sharedBaseline: entry.newCopy?.baseline,
                                                    content: read.content[entry.id])
        }
        guard let mismatch else { return .saveable }
        switch mismatch {
        case .rowGone, .undecodable:
            return .failed("record \(entry.id.uuidString) (\(record.filename)): \(mismatch.words) — quit and relaunch, then redo the change(s)")
        case .rowChanged, .materialised, .pendingGone, .pendingChanged, .sharedChanged:
            return .held(Self.heldWords(record, mismatch: mismatch, stored: found, newCopy: entry.newCopy != nil))
        }
    }

    /// The records whose fingerprint is not the baseline's (none included):
    /// exactly what `detect` would send or hold.
    private func changedSinceBaseline(_ records: [VideoRecord]) -> [VideoRecord] {
        let prints = CatalogChangeDetector.fingerprints(of: records.map(VideoRecordDTO.init))
        return CatalogChangeDetector.changed(records.map(\.id), fingerprints: prints, baseline: baseline.prints).map { records[$0] }
    }

    /// The words for a row held out of every commit: why, and which parts
    /// differ between the catalog and this session (the commit's own
    /// comparison, CatalogRecordDiff) — theirs and ours together, since a
    /// part the baseline cannot attribute is not guessed at.
    private static func heldWords(_ record: VideoRecord, mismatch: CatalogRowCheck.Mismatch, stored: CatalogRowCheck.Found,
                                  newCopy: Bool = false) -> String {
        if newCopy {
            // Codex #145 F2: a record this session created is not in the catalog at all.
            return "the catalog changed under you: \(record.filename) — a new copy of a content in the catalog: \(mismatch.words); "
                + "this new record is NOT in the catalog and is not saved; relaunch, then rescan its folder to add it again"
        }
        var parts = "(not compared)"
        if case .row(let row) = stored, let fresh = try? VideoRecord(loaded: row) {
            parts = differingParts(stored: fresh, current: record)
        }
        return "the catalog changed under you: \(record.filename) — \(mismatch.words); it differs from this session in: \(parts); "
            + "this session's edit of it was not saved; relaunch to see the catalog's values, then redo the edit"
    }

    /// The parts of the record that differ between the store and memory,
    /// in words — the commit's own comparison (CatalogRecordDiff).
    private static func differingParts(stored: VideoRecord, current: VideoRecord) -> String {
        guard let s = try? CatalogRecordDTO(record: stored, migrationLoadedAt: 0),
              let c = try? CatalogRecordDTO(record: current, migrationLoadedAt: 0) else { return "(could not be compared)" }
        let diff = CatalogRecordDiff(stored: s, current: c)
        let flags: [(Bool, String)] = [(diff.file, "file facts"), (diff.marker, "removal marker"), (diff.archiveCopy, "archive copy"),
                                       (diff.backups, "backups"), (diff.footageDecisions, "footage decisions"),
                                       (diff.duplicate, "duplicate analysis"), (diff.soundPrint, "sound print"), (diff.pair, "pair")]
        var names = flags.filter(\.0).map(\.1)
        names += diff.knowledge.map(\.rawValue)
        names += diff.derived.map { "derived \($0.rawValue)" }
        return names.isEmpty ? "nothing the store compares" : names.joined(separator: ", ")
    }

    /// Catalog ▸ Adopt This SQLite Catalog… (gap 5): the person accepted a
    /// restored catalog.sqlite below the high-water this Mac already wrote.
    func adopt(toHighWater highWater: Int) async -> CatalogAdoptOutcome {
        reopening = true
        cancelTimer()
        let outcome = await repository.adopt(toHighWater: highWater)
        reopening = false
        switch outcome {
        case .adopted(let from, let to):
            knownGeneration = to
            sink("Catalog store: OUTCOME adopted catalog.sqlite at generation \(from) as generation \(to) — writes allowed again; "
                 + "committing what changed while it was read-only")
            becameWritable()
        case .refused(let words):
            sink("Catalog store: REFUSED Adopt This SQLite Catalog — \(words). Nothing changed.")
        }
        return outcome
    }

    /// catalog.sqlite's generation read now from the store (one small read);
    /// `knownGeneration` when the read fails.
    func generationNow() async -> Int {
        (try? await repository.read { $0.generation }) ?? knownGeneration
    }

    private func becameWritable() {
        blockedReason = nil
        lastRefusalNote = nil
        lastMarkerRefusal = nil
        baseline.forgetWaiting()
        onWritableAgain()
        scheduleCommit()
    }

    // MARK: - One commit (synchronous: snapshot → write → baseline, one turn)

    /// Which records a commit looks at.
    private enum Scope {
        /// Every record; the purges the doors asked for; the designation.
        case everything
        /// Only these rows (the marker door): no purges, no designation.
        case only(Set<UUID>)
    }

    /// The changed records of one commit: what is sent, and what waits
    /// (the store took nothing from it at this fingerprint).
    private struct Detection {
        var items: [CatalogCommit.Item] = []
        var waiting: [(id: UUID, print: CatalogChangeDetector.Fingerprint)] = []
        /// Changed rows held out of this commit (changed under you, #143).
        var heldBack = 0
    }

    /// The plan, the designation text it carries, and the held-back count.
    private struct Prepared {
        let plan: CatalogCommit.Plan
        let designationJSON: String?
        var heldBack = 0
    }

    /// One synchronous commit. True when every changed record is stored
    /// (as a row, or held in `pending_rows` at its current state).
    @discardableResult
    private func commit(_ door: CatalogWriter, owner: CatalogWriteHoldOwner?, scope: Scope) -> Bool {
        guard let now = admit(owner: owner) else { return false }
        let clock = ContinuousClock()
        let start = clock.now
        let detected = detect(now.records, scope: scope)
        lastDetection = clock.now - start
        // A row held back (changed under you) is changed and NOT stored.
        let durableWaiting = baseline.notDurable(detected.waiting) == 0 && detected.heldBack == 0
        guard let prepared = prepare(door, detected, now: now, scope: scope) else { return durableWaiting }
        let outcome = CatalogCommit.runBlocking(prepared.plan, on: repository)
        commitCount += 1
        lastOutcome = outcome
        return absorb(outcome, prepared) && durableWaiting
    }

    /// nil = nothing may be written now (reopening, blocked, or held —
    /// said once). Otherwise the records, designation and hold as they are.
    private func admit(owner: CatalogWriteHoldOwner?) -> Input? {
        guard !reopening else { return nil }
        if let blockedReason {
            if let stop = fileStop {
                noteOnce("Catalog store: NOT SAVED — \(stop)")       // GH #359: quit and reopen, not Reopen
            } else {
                noteOnce("Catalog store: NOT SAVED — \(blockedReason) (Catalog ▸ Reopen SQLite Catalog)")
            }
            return nil
        }
        let now = input()
        // Codex cycle #112: the session's read-only facts gate EVERY commit —
        // the timer's, saveNow / acknowledged, the marker door and the safety
        // copy's commit-first all come through here. Not re-armed: a
        // read-only session has nothing to wait for.
        if let readOnly = now.readOnlyReason {
            noteOnce("Catalog store: NOT SAVED — \(Self.readOnlyWords(readOnly))")
            return nil
        }
        if let hold = now.holdReason, owner == nil || owner != now.holdOwner {
            if heldBy != hold { sink("Catalog store: HELD — \(hold); the commit waits until it finishes") }
            heldBy = hold
            scheduleCommit()
            return nil
        }
        heldBy = nil
        return now
    }

    /// Snapshots, fingerprints, the changed rows.
    private func detect(_ all: [VideoRecord], scope: Scope) -> Detection {
        let records: [VideoRecord]
        switch scope {
        case .everything: records = all
        case .only(let ids): records = all.filter { ids.contains($0.id) }
        }
        let snapshots = records.map(VideoRecordDTO.init)
        let prints = CatalogChangeDetector.fingerprints(of: snapshots)
        let ids = records.map(\.id)
        var found = Detection()
        let changed = CatalogChangeDetector.changed(ids, fingerprints: prints, baseline: baseline.prints)
        let fresh = baseline.newCopies(changed.map { records[$0] }, among: all)     // codex #145 F2
        for index in changed {
            let id = ids[index]
            if conflicts[id] != nil {
                found.heldBack += 1               // codex #143: never sent until a relaunch
            } else if baseline.waiting[id]?.print == prints[index] {
                found.waiting.append((id, prints[index]))
            } else {
                found.items.append(CatalogCommit.Item(id: id, snapshot: snapshots[index], fingerprint: prints[index],
                                                      sharedBaseline: baseline.shared[id] ?? fresh[id]?.baseline,
                                                      expected: baseline.expectation(of: id)))
            }
        }
        return found
    }

    /// The plan, or nil when there is nothing to write.
    private func prepare(_ door: CatalogWriter, _ detected: Detection, now: Input, scope: Scope) -> Prepared? {
        guard case .everything = scope else {
            return detected.items.isEmpty ? nil : Prepared(plan: CatalogCommit.Plan(door: door, items: detected.items), designationJSON: nil,
                                                           heldBack: detected.heldBack)
        }
        let purges = duePurges(present: Set(now.records.map(\.id)), sent: Set(detected.items.map(\.id)))
        let json = Self.json(now.designation)
        let designation: CatalogCommit.Designation = Self.sameJSON(json, storedDesignationJSON)
            ? .leave : .current(json: json, clearAuthorized: now.clearAuthorized)
        guard !detected.items.isEmpty || designation != .leave || !purges.isEmpty else { return nil }
        var replacements: [UUID: UUID] = [:]
        for id in purges { if let r = replacedBy[id] { replacements[id] = r } }
        return Prepared(plan: CatalogCommit.Plan(door: door, items: detected.items, designation: designation, purges: purges,
                                                 replacements: replacements),
                        designationJSON: json, heldBack: detected.heldBack)
    }

    /// The purges the doors asked for that are due now (the store holds the
    /// row, memory does not). A request whose record came back under the
    /// same id, or that the store does not hold, is dropped. Every other
    /// absence is named once and KEPT.
    ///
    /// A purge with a replacement (P0 2026-10-22, codex #123) is due only
    /// when the replacement is sent in this commit or the store already
    /// holds it — never alone while the replacement waits (refused). If a
    /// door removed a replacement the store HOLDS, the dependency was met
    /// and the purge is a plain one again; one the store never took was
    /// already reconciled at the door (`reconcileKept`, codex #124 F2).
    private func duePurges(present: Set<UUID>, sent: Set<UUID>) -> [UUID] {
        let doomed = Set(purgeRequested.keys)
        for id in purgeRequested.keys.filter({ present.contains($0) || !baseline.holds($0) }) {
            purgeRequested[id] = nil
            replacedBy[id] = nil
        }
        let requested = Set(purgeRequested.keys)
        noteUnpurged(baseline.unpurgedAbsences(present: present, requested: requested))
        let due = baseline.purges(requested: requested, present: present).filter { id in
            guard let replacement = replacedBy[id] else { return true }
            if doomed.contains(replacement) {
                replacedBy[id] = nil
                return true
            }
            return sent.contains(replacement) || baseline.holds(replacement)
        }
        noteUnresolved(present: present)
        return due
    }

    /// Kept purges whose replacement is neither in memory nor in the store
    /// (it left memory without a door's purge): each named ONCE — the row
    /// stays, waiting (codex #124 F2: visible, never silent).
    private func noteUnresolved(present: Set<UUID>) {
        let unresolved = replacedBy.filter { !present.contains($0.value) && !baseline.holds($0.value) }
        notedUnresolved.formIntersection(unresolved.keys)
        let fresh = unresolved.keys.filter { !notedUnresolved.contains($0) }.sorted { $0.uuidString < $1.uuidString }
        notedUnresolved.formUnion(fresh)
        for id in fresh.prefix(Self.unpurgedLinesPerCommit) {
            sink("Catalog store: KEPT \(id.uuidString) — waiting for \(unresolved[id]?.uuidString ?? "?"), "
                 + "which is no longer in memory and was never stored")
        }
        if fresh.count > Self.unpurgedLinesPerCommit {
            sink("Catalog store: … and \(fresh.count - Self.unpurgedLinesPerCommit) more row(s) KEPT waiting for a replacement that is gone")
        }
    }

    private func noteUnpurged(_ ids: [UUID]) {
        for id in ids.prefix(Self.unpurgedLinesPerCommit) {
            sink("Catalog store: record \(id.uuidString) left memory without a purge — kept in the catalog")
        }
        if ids.count > Self.unpurgedLinesPerCommit {
            sink("Catalog store: … and \(ids.count - Self.unpurgedLinesPerCommit) more record(s) left memory without a purge — kept in the catalog")
        }
    }

    private func absorb(_ outcome: CatalogCommit.Outcome, _ prepared: Prepared) -> Bool {
        let door = prepared.plan.door.rawValue
        switch outcome {
        case .committed(let generation, let rows):
            knownGeneration = generation
            adoptDesignation(prepared)
            lastMarkerRefusal = nil
            let durable = apply(rows, prepared.plan)
            sink("Catalog store: OUTCOME commit generation \(generation) via \(door) — " + Self.counts(rows)
                 + (prepared.heldBack > 0 ? " · held back \(prepared.heldBack) (changed under you; relaunch, then redo)" : ""))
            return durable
        case .nothingWritten(let rows):
            // The designation, if sent, already matched catalog_state.
            adoptDesignation(prepared)
            return apply(rows, prepared.plan)
        case .refused(let words, _):
            blockedReason = words
            if fileStop != nil {
                // GH #359: the words already say "quit and reopen".
                sink("Catalog store: REFUSED via \(door) — \(words). Nothing was written.")
            } else {
                sink("Catalog store: REFUSED via \(door) — \(words). Nothing was written; the changes stay in memory "
                     + "until Catalog ▸ Reopen SQLite Catalog.")
            }
            return false
        case .generationMismatch(let expected, let found):
            let words = "another writer committed generation \(found) (this session expected \(expected)) — reopen the catalog"
            blockedReason = words
            sink("Catalog store: REFUSED via \(door) — \(words). Nothing was written.")
            return false
        }
    }

    private func adoptDesignation(_ prepared: Prepared) {
        if case .current = prepared.plan.designation { storedDesignationJSON = prepared.designationJSON }
    }

    /// The baseline moves for the rows the store now holds; then the
    /// copies, the revisions, the hash job — all in this same turn.
    /// True = every row durable.
    private func apply(_ rows: [CatalogCommit.RowResult], _ plan: CatalogCommit.Plan) -> Bool {
        let heldBefore = heldIDs
        let report = baseline.absorb(purgeRows: rows.prefix(plan.purges.count),
                                     itemRows: rows.dropFirst(plan.purges.count), sent: plan.items)
        for line in report.lines { sink(line) }
        markerDirty.subtract(rows.filter { $0.landing.landed || $0.landing == .unchanged }.map(\.id))
        markerDirty.subtract(plan.purges)
        for id in plan.purges where !baseline.holds(id) {
            purgeRequested[id] = nil
            replacedBy[id] = nil
            conflicts[id] = nil              // a door removed it; the row is tombstoned, never silently rewritten
        }
        // A purge kept for its replacement (P0 2026-10-22, codex #123 F4)
        // stays requested WITH its relation: `duePurges` sends it again
        // only together with the replacement (or once the store holds it).
        let records = input().records
        if !report.revisions.isEmpty { adoptRevisions(report.revisions, records: records) }
        if !report.shared.isEmpty, baseline.propagate(report.shared, records: records) { onCopiesUpdated() }
        if heldIDs != heldBefore { onHeldChanged(heldIDs) }
        if !report.needDigest.isEmpty { onNeedDigest(report.needDigest) }
        if report.purged > 0 { sink("Catalog store: REMOVED \(report.purged) row(s) the catalog no longer holds (tombstoned, never deleted)") }
        return report.allStored
    }

    /// A purged row came back: the record carries the revision the store gave it.
    private func adoptRevisions(_ revisions: [(id: UUID, revision: Int)], records: [VideoRecord]) {
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for entry in revisions {
            guard let record = byID[entry.id] else { continue }
            VideoScanModel.adoptStoredRemovalRevision(record, entry.revision)   // the one marker writer's file
        }
    }

    private func noteOnce(_ line: String) {
        guard lastRefusalNote != line else { return }
        lastRefusalNote = line
        sink(line)
    }

    // MARK: - Words

    static func counts(_ rows: [CatalogCommit.RowResult]) -> String {
        var tally: [String: Int] = [:]
        for row in rows { tally[word(row.landing), default: 0] += 1 }
        return ["written", "unchanged", "held", "partial", "refused", "removed"]
            .map { "\($0) \(tally[$0] ?? 0)" }.joined(separator: " · ")
    }

    private static func word(_ landing: CatalogCommit.Landing) -> String {
        switch landing {
        case .written: return "written"
        case .unchanged: return "unchanged"
        case .deferred: return "held"
        case .partial: return "partial"
        case .refused: return "refused"
        case .removed: return "removed"
        }
    }

    /// The designation as catalog_state stores it (sorted keys, ISO dates).
    nonisolated static func json(_ designation: MasterArchiveDesignation?) -> String? {
        guard let designation else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(designation)).flatMap { String(data: $0, encoding: .utf8) }
    }

    nonisolated static func designation(fromJSON json: String?) -> MasterArchiveDesignation? {
        guard let data = json?.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MasterArchiveDesignation.self, from: data)
    }

    nonisolated static func sameJSON(_ a: String?, _ b: String?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let x?, let y?): return CatalogJSONValue.parse(x) == CatalogJSONValue.parse(y)
        default: return false
        }
    }
}
