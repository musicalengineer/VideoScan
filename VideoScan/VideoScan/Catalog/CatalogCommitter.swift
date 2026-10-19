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
//   marker change refused         → the row is left exactly as it was; the
//                                   door shows the words (once per reason
//                                   here, per row at the door).
//
// Memory: CatalogCommitBaseline (≈ 150 B a record); a commit holds one
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
    /// Ids a door removed from the catalog, not yet purged (id → why).
    private var purgeRequested: [UUID: String] = [:]
    /// Reopen / Adopt is closing and opening the store: no commit runs.
    private var reopening = false
    private var heldBy: String?
    private var lastRefusalNote: String?
    private var lastMarkerRefusal: String?
    private(set) var blockedReason: String? {
        didSet { if blockedReason != oldValue { onBlockedChanged(blockedReason) } }
    }
    private(set) var lastOutcome: CatalogCommit.Outcome?
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
    func adoptBaseline(_ records: [VideoRecord], held: Set<UUID> = []) {
        baseline.adopt(records, held: held)
        markerDirty = []
        purgeRequested = [:]
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
    /// when one can.
    private func saveRefusal() -> String? {
        if reopening { return Self.cantSave("it is being reopened", until: "the reopen finishes") }
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
        return saveRefusal() ?? baseline.waiting[id]?.words ?? "its current values could not be stored"
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
            sink("Catalog store: safety copy — \(baseline.waiting.count) row(s) the store would not take are in it at their last stored values")
        }
        return nil
    }

    /// A door took these records out of the catalog (VideoScanModel
    /// .purgeCatalogRows): their rows are purged in one synchronous commit
    /// now — or, while the store is held or blocked, at the first commit
    /// that can run. The ONLY way a row is purged (B2.3).
    func purge(ids: Set<UUID>, reason: String) {
        let known = ids.filter { baseline.holds($0) }
        guard !known.isEmpty else { return }
        for id in known { purgeRequested[id] = reason }
        sink("Catalog store: START purge of \(known.count) row(s) — \(reason)")
        commit(.save, owner: nil, scope: .everything)
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
        reopening = true
        cancelTimer()
        await repository.close()
        let opened = await repository.open(at: url)
        reopening = false
        switch opened {
        case .readWrite:
            sink("Catalog store: OUTCOME reopened catalog.sqlite — writes allowed again; committing what is still changed")
            becameWritable()
        case .readOnly(let reason), .refused(let reason):
            blockedReason = "read-only: \(reason)"
            sink("Catalog store: OUTCOME reopened catalog.sqlite READ-ONLY — \(reason)")
        }
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
            sink("Catalog store: OUTCOME adopted catalog.sqlite at generation \(from) as generation \(to) — writes allowed again; "
                 + "committing what changed while it was read-only")
            becameWritable()
        case .refused(let words):
            sink("Catalog store: REFUSED Adopt This SQLite Catalog — \(words). Nothing changed.")
        }
        return outcome
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
    }

    /// The plan, and the designation text it carries.
    private struct Prepared {
        let plan: CatalogCommit.Plan
        let designationJSON: String?
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
        let durableWaiting = baseline.notDurable(detected.waiting) == 0
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
            noteOnce("Catalog store: NOT SAVED — \(blockedReason) (Catalog ▸ Reopen SQLite Catalog)")
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
        for index in CatalogChangeDetector.changed(ids, fingerprints: prints, baseline: baseline.prints) {
            let id = ids[index]
            if baseline.waiting[id]?.print == prints[index] {
                found.waiting.append((id, prints[index]))
            } else {
                found.items.append(CatalogCommit.Item(id: id, snapshot: snapshots[index], fingerprint: prints[index],
                                                      sharedBaseline: baseline.shared[id]))
            }
        }
        return found
    }

    /// The plan, or nil when there is nothing to write.
    private func prepare(_ door: CatalogWriter, _ detected: Detection, now: Input, scope: Scope) -> Prepared? {
        guard case .everything = scope else {
            return detected.items.isEmpty ? nil : Prepared(plan: CatalogCommit.Plan(door: door, items: detected.items), designationJSON: nil)
        }
        let purges = duePurges(present: Set(now.records.map(\.id)))
        let json = Self.json(now.designation)
        let designation: CatalogCommit.Designation = Self.sameJSON(json, storedDesignationJSON)
            ? .leave : .current(json: json, clearAuthorized: now.clearAuthorized)
        guard !detected.items.isEmpty || designation != .leave || !purges.isEmpty else { return nil }
        return Prepared(plan: CatalogCommit.Plan(door: door, items: detected.items, designation: designation, purges: purges),
                        designationJSON: json)
    }

    /// The purges the doors asked for that are due now (the store holds the
    /// row, memory does not). A request whose record came back under the
    /// same id, or that the store does not hold, is dropped. Every other
    /// absence is named once and KEPT.
    private func duePurges(present: Set<UUID>) -> [UUID] {
        for id in purgeRequested.keys.filter({ present.contains($0) || !baseline.holds($0) }) {
            purgeRequested[id] = nil
        }
        let requested = Set(purgeRequested.keys)
        noteUnpurged(baseline.unpurgedAbsences(present: present, requested: requested))
        return baseline.purges(requested: requested, present: present)
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
            adoptDesignation(prepared)
            lastMarkerRefusal = nil
            let durable = apply(rows, prepared.plan)
            sink("Catalog store: OUTCOME commit generation \(generation) via \(door) — " + Self.counts(rows))
            return durable
        case .nothingWritten(let rows):
            // The designation, if sent, already matched catalog_state.
            adoptDesignation(prepared)
            return apply(rows, prepared.plan)
        case .refused(let words, _):
            blockedReason = words
            sink("Catalog store: REFUSED via \(door) — \(words). Nothing was written; the changes stay in memory "
                 + "until Catalog ▸ Reopen SQLite Catalog.")
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
        for id in plan.purges where !baseline.holds(id) { purgeRequested[id] = nil }
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
