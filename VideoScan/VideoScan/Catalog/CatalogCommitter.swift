// CatalogCommitter.swift
// Where the three save funnels go once catalog.sqlite is the authority
// (cutover B2, docs/design/catalog_cutover_f_prime_2026_10_17.md §3 and §10
// "B2-lite"). One sentence: when the app would have saved catalog.json, it
// commits the records that changed since the last commit into catalog.sqlite
// instead — same debounce, same synchronous save at quit.
//
// Shape. `@MainActor final class`, owned by the model's `catalogCutover`
// state, holding the open repository and the baseline (CatalogCommitBaseline:
// what the store holds, per record). Per commit:
//   1. on the main actor: a `VideoRecordDTO` snapshot per record (≈ 2 µs
//      each — the records live here), the ids that left the records (gap 3:
//      purged, never deleted), the marker journal (gap 2) and a copy of the
//      baseline;
//   2. off it: the fingerprints (CatalogChangeDetector) → the changed rows →
//      ONE write (CatalogCommit.run): purges, then per row insert / update /
//      held / partial / refused, then the Master Archive designation;
//   3. back here: the baseline moves (CatalogCommitBaseline.absorb), the
//      COMMITTED curated values go onto the other copies of the same content
//      that still hold their own baseline, rows with no whole-file hash get
//      Fill In Full Hashes queued, and one line goes to the sink.
//
// ONE SERIAL PATH (B2.1, codex P1-3). At most one commit is in flight. Every
// door — the 2 s timer, `commitAcknowledged`, `commitNow` (quit) — first
// waits for the in-flight commit AND absorbs its result, and only then takes
// its snapshot. So snapshot → write → baseline move never overlap, and a
// quit during an in-flight commit commits what changed since. `commitNow`
// waits on a semaphore (the quit path, where the main thread has nothing
// else to do): the in-flight write runs off the main actor and needs nothing
// from it (CatalogLaunchWait), and the quit absorbs that result itself.
//
// Outcomes and what the person sees (the console, catalog.log and
// videoscan.log through `sink`; `blockedReason` drives the Reopen item):
//   committed / nothing to write  → the baseline moves; a refused row is
//                                   named ONCE and not sent again until it
//                                   changes; a held row (no whole-file hash)
//                                   is durable and counted in one line;
//   held (MOPS-16)                → nothing written; re-checked every 2 s
//                                   until the holder lets go (only the
//                                   holder's OWN token passes — codex gap 4);
//   refused / generation mismatch → nothing written, the records stay
//                                   changed, the store's words are shown, and
//                                   NO further commit is tried until the
//                                   person chooses Catalog ▸ Reopen SQLite
//                                   Catalog (never retried silently).
//
// Memory: CatalogCommitBaseline (≈ 150 B a record); a commit holds one
// snapshot per record for the length of the detection (the snapshots share
// their strings and arrays with the records).
//
// (For Rick: a write-behind flusher — dirty bits computed by checksum, a
// 2-second timer, and a single-slot queue so only one flush is ever in
// flight; `await` on it ≈ joining the flusher thread before the next one.)

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
    /// The one commit in flight (nil when none).
    private var flight: Flight?
    private var heldBy: String?
    private var lastRefusalNote: String?
    private(set) var blockedReason: String? {
        didSet { if blockedReason != oldValue { onBlockedChanged(blockedReason) } }
    }
    private(set) var lastOutcome: CatalogCommit.Outcome?
    /// Writes attempted (tests and the status line).
    private(set) var commitCount = 0
    /// The last detection's cost (snapshot on the main actor + fingerprints).
    private(set) var lastDetection: Duration = .zero

    /// A commit is in flight or waiting on the timer (tests wait on this).
    var isBusy: Bool { flight != nil || debounceTask != nil }
    /// Ids held in `pending_rows` (no whole-file hash yet).
    var heldIDs: Set<UUID> { baseline.held }
    // Test seams (nil in production): right after a commit's snapshot, and
    // right before its result is absorbed.
    var afterSnapshotForTesting: (@MainActor () -> Void)?
    var beforeAbsorbForTesting: (@MainActor () async -> Void)?

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

    /// One removal-marker change (the one marker writer calls this through
    /// CatalogMarkerRelay — gap 2): the snapshot of THIS revision is kept
    /// so it lands with its own tombstone, and a commit is asked for now.
    func noteMarkerChange(id: UUID, instance: ObjectIdentifier, snapshot: VideoRecordDTO) {
        guard baseline.noteMarker(id: id, instance: instance, snapshot: snapshot) else { return }
        scheduleCommit(after: .zero)
    }

    // MARK: - The three funnels

    /// `saveCatalogDebounced`: 2 s after the last call, one commit.
    func scheduleCommit(after delay: Duration = CatalogCommitter.debounce) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.commitFromTimer()
        }
    }

    /// `saveCatalogNow`: synchronous (quit). Waits for the in-flight commit,
    /// then commits what changed since. True when every changed record is
    /// now in catalog.sqlite (held rows count as durable).
    @discardableResult
    func commitNow() -> Bool {
        cancelTimer()
        while let current = flight {
            let task = current.task
            settle(current, CatalogLaunchWait.run { await task.value })
        }
        guard let request = prepare(door: .quit, owner: nil) else { return false }
        let started = launch(request)
        let task = started.task
        settle(started, CatalogLaunchWait.run { await task.value })
        return started.durable ?? false
    }

    /// `saveCatalogAcknowledged`: awaited by the caller. `owner`: the
    /// MOPS-16 token the caller presents — only the holder's own passes.
    func commitAcknowledged(owner: CatalogWriteHoldOwner?) async -> Bool {
        cancelTimer()
        await drain()
        guard let request = prepare(door: .acknowledged, owner: owner) else { return false }
        let started = launch(request)
        afterSnapshotForTesting?()
        let result = await started.task.value
        await beforeAbsorbForTesting?()
        settle(started, result)
        return started.durable ?? false
    }

    private func commitFromTimer() async {
        debounceTask = nil
        await drain()
        guard let request = prepare(door: .save, owner: nil) else { return }
        let started = launch(request)
        settle(started, await started.task.value)
    }

    private func cancelTimer() {
        debounceTask?.cancel()
        debounceTask = nil
    }

    // MARK: - The serial path

    /// One commit in flight: its request, its off-main write, and — once
    /// absorbed, by whichever door got there first — whether it was durable.
    private final class Flight {
        let request: Request
        let task: Task<Result, Never>
        var durable: Bool?

        init(request: Request, task: Task<Result, Never>) {
            self.request = request
            self.task = task
        }
    }

    /// Wait for every in-flight commit and absorb it.
    private func drain() async {
        while let current = flight {
            settle(current, await current.task.value)
        }
    }

    private func launch(_ request: Request) -> Flight {
        let repository = repository
        let task = Task.detached(priority: .userInitiated) { await Self.run(request, on: repository) }
        let started = Flight(request: request, task: task)
        flight = started
        return started
    }

    /// Absorb a flight's result exactly once.
    private func settle(_ done: Flight, _ result: Result) {
        if flight === done { flight = nil }
        guard done.durable == nil else { return }
        done.durable = absorb(result, request: done.request)
    }

    // MARK: - Reopen / adopt

    /// Catalog ▸ Reopen SQLite Catalog: close, open again, and — when the
    /// store is writable — commit what is still changed.
    func reopen(at url: URL) async {
        await drain()
        await repository.close()
        switch await repository.open(at: url) {
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
        await drain()
        let outcome = await repository.adopt(toHighWater: highWater)
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

    // MARK: - One commit

    /// Everything a commit needs, taken on the main actor. Sendable values only.
    struct Request: Sendable {
        let door: CatalogWriter
        let snapshots: [VideoRecordDTO]
        let ids: [UUID]
        let prints: [UUID: CatalogChangeDetector.Fingerprint]
        let waiting: [UUID: CatalogChangeDetector.Fingerprint]
        let shared: [UUID: CatalogSharedCurated]
        let journal: [UUID: [VideoRecordDTO]]
        let purges: [UUID]
        let designation: CatalogCommit.Designation
        let designationJSON: String?
        let snapshotCost: Duration
    }

    /// What the off-main hop came back with.
    enum Result: Sendable {
        /// Nothing differs from what the store holds; `notDurable` ids wait.
        case clean(notDurable: [UUID], detection: Duration)
        /// `sent`: the items the plan carried, in order (purges come first in the rows).
        case ran(CatalogCommit.Outcome, sent: [CatalogCommit.Item], notDurable: [UUID], detection: Duration)
    }

    /// nil = nothing may be written now (blocked or held — said once).
    private func prepare(door: CatalogWriter, owner: CatalogWriteHoldOwner?) -> Request? {
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
        let clock = ContinuousClock()
        let start = clock.now
        let snapshots = now.records.map(VideoRecordDTO.init)
        let ids = now.records.map(\.id)
        let present = Self.byID(now.records)
        let journal = baseline.takeJournal(present: present)
        let purges = baseline.purges(present: Set(present.keys))
        let cost = clock.now - start
        let json = Self.json(now.designation)
        let designation: CatalogCommit.Designation = Self.sameJSON(json, storedDesignationJSON)
            ? .leave : .current(json: json, clearAuthorized: now.clearAuthorized)
        return Request(door: door, snapshots: snapshots, ids: ids, prints: baseline.prints,
                       waiting: baseline.waiting.mapValues(\.print), shared: baseline.shared, journal: journal,
                       purges: purges, designation: designation, designationJSON: json, snapshotCost: cost)
    }

    /// Off the main actor: fingerprints, the changed rows, then ONE write.
    nonisolated static func run(_ request: Request, on repository: any CatalogRepository) async -> Result {
        let clock = ContinuousClock()
        let start = clock.now
        let prints = await Task.detached(priority: .userInitiated) {
            CatalogChangeDetector.fingerprints(of: request.snapshots)
        }.value
        let changed = CatalogChangeDetector.changed(request.ids, fingerprints: prints, baseline: request.prints)
        let fresh = changed.filter { request.waiting[request.ids[$0]] != prints[$0] }
        let waitingIDs = changed.filter { request.waiting[request.ids[$0]] == prints[$0] }.map { request.ids[$0] }
        let detection = request.snapshotCost + (clock.now - start)
        let items = fresh.flatMap { items(for: $0, request, prints) }
        guard !items.isEmpty || request.designation != .leave || !request.purges.isEmpty else {
            return .clean(notDurable: waitingIDs, detection: detection)
        }
        let plan = CatalogCommit.Plan(door: request.door, items: items, designation: request.designation, purges: request.purges)
        return .ran(await CatalogCommit.run(plan, on: repository), sent: items, notDurable: waitingIDs, detection: detection)
    }

    /// The items for one changed record: each journal snapshot of an
    /// EARLIER marker revision, in order (gap 2), then the record itself.
    nonisolated static func items(for index: Int, _ request: Request,
                                  _ prints: [CatalogChangeDetector.Fingerprint]) -> [CatalogCommit.Item] {
        let id = request.ids[index]
        let snapshot = request.snapshots[index]
        let shared = request.shared[id]
        let finalRevision = snapshot.removalRevision ?? 0
        var out = (request.journal[id] ?? []).filter { ($0.removalRevision ?? 0) < finalRevision }.map {
            CatalogCommit.Item(id: id, snapshot: $0, fingerprint: CatalogChangeDetector.fingerprint($0), sharedBaseline: shared)
        }
        out.append(CatalogCommit.Item(id: id, snapshot: snapshot, fingerprint: prints[index], sharedBaseline: shared))
        return out
    }

    /// Back on the main actor. True when every changed record is now stored
    /// (as a row, or held in `pending_rows`).
    private func absorb(_ result: Result, request: Request) -> Bool {
        switch result {
        case .clean(let notDurable, let detection):
            lastDetection = detection
            restoreJournal(request.journal)
            return baseline.notDurable(notDurable) == 0
        case .ran(let outcome, let sent, let notDurable, let detection):
            lastDetection = detection
            commitCount += 1
            lastOutcome = outcome
            return absorb(outcome, request: request, sent: sent) && baseline.notDurable(notDurable) == 0
        }
    }

    private func absorb(_ outcome: CatalogCommit.Outcome, request: Request, sent: [CatalogCommit.Item]) -> Bool {
        switch outcome {
        case .committed(let generation, let rows):
            if case .current = request.designation { storedDesignationJSON = request.designationJSON }
            let durable = apply(rows, request: request, sent: sent)
            sink("Catalog store: OUTCOME commit generation \(generation) via \(request.door.rawValue) — " + Self.counts(rows))
            return durable
        case .nothingWritten(let rows):
            // The designation, if sent, already matched catalog_state.
            if case .current = request.designation { storedDesignationJSON = request.designationJSON }
            return apply(rows, request: request, sent: sent)
        case .refused(let words, _):
            restoreJournal(request.journal)
            blockedReason = words
            sink("Catalog store: REFUSED via \(request.door.rawValue) — \(words). Nothing was written; the changes stay in memory "
                 + "until Catalog ▸ Reopen SQLite Catalog.")
            return false
        case .generationMismatch(let expected, let found):
            restoreJournal(request.journal)
            let words = "another writer committed generation \(found) (this session expected \(expected)) — reopen the catalog"
            blockedReason = words
            sink("Catalog store: REFUSED via \(request.door.rawValue) — \(words). Nothing was written.")
            return false
        }
    }

    /// The baseline moves for the rows the store now holds; then the
    /// copies, the revisions, the hash job. True = every row durable.
    private func apply(_ rows: [CatalogCommit.RowResult], request: Request, sent: [CatalogCommit.Item]) -> Bool {
        let heldBefore = baseline.held
        let report = baseline.absorb(purgeRows: rows.prefix(request.purges.count),
                                     itemRows: rows.dropFirst(request.purges.count), sent: sent)
        for line in report.lines { sink(line) }
        let records = input().records
        if !report.revisions.isEmpty { adoptRevisions(report.revisions, records: records) }
        if !report.shared.isEmpty, baseline.propagate(report.shared, records: records) { onCopiesUpdated() }
        if baseline.held != heldBefore { onHeldChanged(baseline.held) }
        if !report.needDigest.isEmpty { onNeedDigest(report.needDigest) }
        if report.purged > 0 { sink("Catalog store: REMOVED \(report.purged) row(s) the catalog no longer holds (tombstoned, never deleted)") }
        let landed = Set(rows.filter(\.landing.landed).map(\.id))
        restoreJournal(request.journal.filter { !landed.contains($0.key) })
        return report.allStored
    }

    /// A purged row came back: the record carries the revision the store gave it.
    private func adoptRevisions(_ revisions: [(id: UUID, revision: Int)], records: [VideoRecord]) {
        let byID = Self.byID(records)
        for entry in revisions {
            guard let record = byID[entry.id] else { continue }
            VideoScanModel.adoptStoredRemovalRevision(record, entry.revision)   // the one marker writer's file
        }
    }

    private func restoreJournal(_ journal: [UUID: [VideoRecordDTO]]) {
        guard !journal.isEmpty else { return }
        baseline.restoreJournal(journal, present: Self.byID(input().records))
    }

    private static func byID(_ records: [VideoRecord]) -> [UUID: VideoRecord] {
        Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
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
