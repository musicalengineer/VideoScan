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
// removal markers).
//
// Removal markers (gap 2). catalog.sqlite wants every marker revision with
// its own tombstone. The one marker writer tells the relay BEFORE a change
// (`markerWillChange`): rows whose previous marker change is not committed
// yet are committed NOW, synchronously — so the store holds revision n
// before a record moves to n+1, by construction. After a change
// (`markerDidChange`) the row is remembered and one commit is asked for at
// once (zero delay), so Trash of 1,000 rows in one turn is ONE commit.
//
// Purges (gap 3). An id the app no longer holds is purged (tombstoned; a
// held row's payload is KEPT, `pending_purges`) only when it was absent at
// two full commits in a row, or at a synchronous save (`commitNow`: quit,
// Delete All — the caller says "this is the catalog"). Two looks, not the
// scan's completion signal: the scan merge swaps its records in ONE
// main-actor turn (VideoScanModel+ScanMerge), so no commit sees half of it,
// and the second look covers every other door that removes and re-adds a
// record across turns — with no coupling to any one job.
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
//                                   Catalog (never retried silently).
//
// Memory: CatalogCommitBaseline (≈ 150 B a record); a commit holds one
// snapshot per record for its length (the snapshots share their strings and
// arrays with the records).
//
// (For Rick: a write-behind flusher whose flush is now a plain blocking
// call on the UI thread — dirty bits computed by checksum, a 2-second timer
// deciding when to flush, and nothing else running while it does.)

import Foundation
import VideoScanCore

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
    }

    static let debounce: Duration = .seconds(2)

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

    private var baseline = CatalogCommitBaseline()
    /// The designation catalog_state holds as far as this session knows.
    private var storedDesignationJSON: String?
    private var debounceTask: Task<Void, Never>?
    /// Rows whose removal marker changed since their last commit.
    private var markerDirty: Set<UUID> = []
    /// Reopen / Adopt is closing and opening the store: no commit runs.
    private var reopening = false
    private var heldBy: String?
    private var lastRefusalNote: String?
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

    /// The marker of `id` is about to change. Rows whose previous marker
    /// change is not committed yet are committed now, in one synchronous
    /// commit, so the store holds revision n before any moves to n+1.
    func markerWillChange(id: UUID) {
        guard markerDirty.contains(id) else { return }
        commitNow(ids: markerDirty)
    }

    /// The marker of `id` changed (its revision already bumped): commit it
    /// as soon as this turn ends — one commit for a whole batch.
    func markerDidChange(id: UUID) {
        guard baseline.prints[id] != nil else { return }
        markerDirty.insert(id)
        scheduleCommit(after: .zero)
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
        return commit(.quit, owner: nil, scope: .everything(final: true))
    }

    /// `saveCatalogAcknowledged`: the same synchronous commit; its truth is
    /// returned. `owner`: the MOPS-16 token the caller presents — only the
    /// holder's own passes.
    func commitAcknowledged(owner: CatalogWriteHoldOwner?) async -> Bool {
        cancelTimer()
        return commit(.acknowledged, owner: owner, scope: .everything(final: false))
    }

    /// The removal-marker door: only these rows, now.
    @discardableResult
    func commitNow(ids: Set<UUID>) -> Bool {
        commit(.save, owner: nil, scope: .only(ids))
    }

    private func commitFromTimer() {
        debounceTask = nil
        commit(.save, owner: nil, scope: .everything(final: false))
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
        baseline.forgetWaiting()
        onWritableAgain()
        scheduleCommit()
    }

    // MARK: - One commit (synchronous: snapshot → write → baseline, one turn)

    /// Which records a commit looks at.
    private enum Scope {
        /// Every record; purges due; `final` = a synchronous save.
        case everything(final: Bool)
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
        guard case .everything(let final) = scope else {
            return detected.items.isEmpty ? nil : Prepared(plan: CatalogCommit.Plan(door: door, items: detected.items), designationJSON: nil)
        }
        let purges = baseline.purges(present: Set(now.records.map(\.id)), final: final)
        let json = Self.json(now.designation)
        let designation: CatalogCommit.Designation = Self.sameJSON(json, storedDesignationJSON)
            ? .leave : .current(json: json, clearAuthorized: now.clearAuthorized)
        guard !detected.items.isEmpty || designation != .leave || !purges.isEmpty else { return nil }
        return Prepared(plan: CatalogCommit.Plan(door: door, items: detected.items, designation: designation, purges: purges),
                        designationJSON: json)
    }

    private func absorb(_ outcome: CatalogCommit.Outcome, _ prepared: Prepared) -> Bool {
        let door = prepared.plan.door.rawValue
        switch outcome {
        case .committed(let generation, let rows):
            adoptDesignation(prepared)
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
