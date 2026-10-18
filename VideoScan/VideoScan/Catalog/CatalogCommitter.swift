// CatalogCommitter.swift
// Where the three save funnels go once catalog.sqlite is the authority
// (cutover B2, docs/design/catalog_cutover_f_prime_2026_10_17.md §3 and §10
// "B2-lite"). One sentence: when the app would have saved catalog.json, it
// commits the records that changed since the last commit into catalog.sqlite
// instead — same debounce, same coalescing, same synchronous save at quit.
//
// Shape. `@MainActor final class`, owned by the model's `catalogCutover`
// state, holding the open repository and the baseline (id → fingerprint of
// what the store holds). Per commit:
//   1. on the main actor: a `VideoRecordDTO` snapshot per record (≈ 2 µs
//      each — the records live here) and a copy of the baseline;
//   2. off it: the fingerprints (CatalogChangeDetector) → the changed rows →
//      ONE write (CatalogCommit.run): per row insert / update / deferred /
//      refused, then the Master Archive designation (GH #167's guard);
//   3. back here: the baseline moves for every row the store now matches,
//      the curated fields a row wrote are copied onto the other in-memory
//      copies of the same content, and one line goes to the sink.
//
// Outcomes and what the person sees (the console, catalog.log and
// videoscan.log through `sink`; `blockedReason` drives the Reopen item):
//   committed / nothing to write  → the baseline moves; a deferred or
//                                   refused row is named ONCE and not sent
//                                   again until it changes;
//   held (MOPS-16)                → nothing written; re-checked every 2 s
//                                   until the holder lets go;
//   refused / generation mismatch → nothing written, the records stay
//                                   changed, the store's words are shown, and
//                                   NO further commit is tried until the
//                                   person chooses Catalog ▸ Reopen SQLite
//                                   Catalog (never retried silently).
//
// `commitNow` (quit) waits for its off-main hop on a semaphore — the quit
// path, where the main thread has nothing else to do; the hop never needs
// the main actor (CatalogLaunchWait, the launch's own wait).
//
// Memory: the baseline is one Int per record (14k → 112 KB); a commit holds
// one snapshot per record for the length of the detection (the snapshots
// share their strings and arrays with the records).
//
// (For Rick: a write-behind flusher — dirty bits computed by checksum, a
// 2-second timer, one writer behind an actor.)

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
        /// MOPS-16: the job holding catalog writes, if any.
        var holdReason: String?
    }

    static let debounce: Duration = .seconds(2)

    let repository: any CatalogRepository
    private let input: () -> Input
    private let sink: (String) -> Void
    /// After curated fields were copied onto other copies of a content.
    var onCopiesUpdated: () -> Void = {}
    /// The blocked state changed (the Reopen item follows it).
    var onBlockedChanged: (String?) -> Void = { _ in }

    private var baseline: [UUID: CatalogChangeDetector.Fingerprint] = [:]
    /// Rows the store deferred or refused, at the fingerprint it saw: not
    /// sent again until they change (they would only be refused again).
    private var pending: [UUID: (print: CatalogChangeDetector.Fingerprint, words: String)] = [:]
    /// The designation catalog_state holds as far as this session knows.
    private var storedDesignationJSON: String?
    private var debounceTask: Task<Void, Never>?
    private var inFlight = false
    private var followUp = false
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
    var isBusy: Bool { inFlight }
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
    func adoptBaseline(_ records: [VideoRecord]) {
        let prints = CatalogChangeDetector.fingerprints(of: records.map(VideoRecordDTO.init))
        baseline = Dictionary(zip(records.map(\.id), prints), uniquingKeysWith: { first, _ in first })
    }

    /// Refuse every commit until a person reopens (a read-only open).
    func block(_ reason: String) {
        blockedReason = reason
    }

    /// Records whose state is not in catalog.sqlite (tests; the status line).
    func changedRecordCount() -> Int {
        let records = input().records
        let prints = CatalogChangeDetector.fingerprints(of: records.map(VideoRecordDTO.init))
        return CatalogChangeDetector.changed(records.map(\.id), fingerprints: prints, baseline: baseline).count
    }

    // MARK: - The three funnels

    /// `saveCatalogDebounced`: 2 s after the last call, one commit.
    func scheduleCommit() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await self?.commitFromTimer()
        }
    }

    /// `saveCatalogNow`: synchronous (quit). True when every changed record
    /// is now in catalog.sqlite.
    @discardableResult
    func commitNow() -> Bool {
        debounceTask?.cancel()
        guard let request = prepare(door: .quit, holder: false) else { return false }
        let repository = repository
        let result = CatalogLaunchWait.run { await Self.run(request, on: repository) }
        return absorb(result, request: request)
    }

    /// `saveCatalogAcknowledged`: awaited by the caller. `holder`: the caller
    /// presents the MOPS-16 holder's token (the holder's own writer passes).
    func commitAcknowledged(holder: Bool) async -> Bool {
        debounceTask?.cancel()
        guard let request = prepare(door: .acknowledged, holder: holder) else { return false }
        inFlight = true
        afterSnapshotForTesting?()
        let result = await Self.run(request, on: repository)
        await beforeAbsorbForTesting?()
        inFlight = false
        let durable = absorb(result, request: request)
        startFollowUpIfMarked()
        return durable
    }

    private func commitFromTimer() async {
        guard !inFlight else {
            followUp = true
            return
        }
        guard let request = prepare(door: .save, holder: false) else { return }
        inFlight = true
        let result = await Self.run(request, on: repository)
        inFlight = false
        _ = absorb(result, request: request)
        startFollowUpIfMarked()
    }

    /// A funnel call during an in-flight commit: one more commit right after.
    private func startFollowUpIfMarked() {
        guard followUp else { return }
        followUp = false
        Task { [weak self] in await self?.commitFromTimer() }
    }

    // MARK: - Reopen

    /// Catalog ▸ Reopen SQLite Catalog: close, open again, and — when the
    /// store is writable — commit what is still changed.
    func reopen(at url: URL) async {
        await repository.close()
        switch await repository.open(at: url) {
        case .readWrite:
            sink("Catalog store: OUTCOME reopened catalog.sqlite — writes allowed again; committing what is still changed")
            blockedReason = nil
            lastRefusalNote = nil
            pending = [:]
            scheduleCommit()
        case .readOnly(let reason), .refused(let reason):
            blockedReason = "read-only: \(reason)"
            sink("Catalog store: OUTCOME reopened catalog.sqlite READ-ONLY — \(reason)")
        }
    }

    // MARK: - One commit

    /// Everything a commit needs, taken on the main actor. Sendable values only.
    struct Request: Sendable {
        let door: CatalogWriter
        let snapshots: [VideoRecordDTO]
        let ids: [UUID]
        let baseline: [UUID: CatalogChangeDetector.Fingerprint]
        let pending: [UUID: CatalogChangeDetector.Fingerprint]
        let designation: CatalogCommit.Designation
        let designationJSON: String?
        let snapshotCost: Duration
    }

    /// What the off-main hop came back with.
    enum Result: Sendable {
        /// Nothing differs from what the store holds; `stillPending` rows wait.
        case clean(stillPending: Int, detection: Duration)
        case ran(CatalogCommit.Outcome, stillPending: Int, detection: Duration)
    }

    /// nil = nothing may be written now (blocked or held — said once).
    private func prepare(door: CatalogWriter, holder: Bool) -> Request? {
        if let blockedReason {
            noteOnce("Catalog store: NOT SAVED — \(blockedReason) (Catalog ▸ Reopen SQLite Catalog)")
            return nil
        }
        let now = input()
        if let hold = now.holdReason, !holder {
            if heldBy != hold { sink("Catalog store: HELD — \(hold); the commit waits until it finishes") }
            heldBy = hold
            scheduleCommit()
            return nil
        }
        heldBy = nil
        let clock = ContinuousClock()
        let start = clock.now
        let snapshots = now.records.map(VideoRecordDTO.init)
        let cost = clock.now - start
        let json = Self.json(now.designation)
        let designation: CatalogCommit.Designation = Self.sameJSON(json, storedDesignationJSON)
            ? .leave : .current(json: json, clearAuthorized: now.clearAuthorized)
        return Request(door: door, snapshots: snapshots, ids: now.records.map(\.id), baseline: baseline,
                       pending: pending.mapValues(\.print), designation: designation, designationJSON: json,
                       snapshotCost: cost)
    }

    /// Off the main actor: fingerprints, the changed rows, then ONE write.
    nonisolated static func run(_ request: Request, on repository: any CatalogRepository) async -> Result {
        let clock = ContinuousClock()
        let start = clock.now
        let prints = await Task.detached(priority: .userInitiated) {
            CatalogChangeDetector.fingerprints(of: request.snapshots)
        }.value
        let changed = CatalogChangeDetector.changed(request.ids, fingerprints: prints, baseline: request.baseline)
        let fresh = changed.filter { request.pending[request.ids[$0]] != prints[$0] }
        let detection = request.snapshotCost + (clock.now - start)
        let stillPending = changed.count - fresh.count
        let items = fresh.map { CatalogCommit.Item(id: request.ids[$0], snapshot: request.snapshots[$0], fingerprint: prints[$0]) }
        guard !items.isEmpty || request.designation != .leave else {
            return .clean(stillPending: stillPending, detection: detection)
        }
        let plan = CatalogCommit.Plan(door: request.door, items: items, designation: request.designation)
        return .ran(await CatalogCommit.run(plan, on: repository), stillPending: stillPending, detection: detection)
    }

    /// Back on the main actor. True when every changed record is now stored.
    private func absorb(_ result: Result, request: Request) -> Bool {
        switch result {
        case .clean(let stillPending, let detection):
            lastDetection = detection
            return stillPending == 0
        case .ran(let outcome, let stillPending, let detection):
            lastDetection = detection
            commitCount += 1
            lastOutcome = outcome
            return absorb(outcome, request: request) && stillPending == 0
        }
    }

    private func absorb(_ outcome: CatalogCommit.Outcome, request: Request) -> Bool {
        switch outcome {
        case .committed(let generation, let rows):
            if case .current = request.designation { storedDesignationJSON = request.designationJSON }
            let stored = apply(rows)
            sink("Catalog store: OUTCOME commit generation \(generation) via \(request.door.rawValue) — " + Self.counts(rows))
            return stored
        case .nothingWritten(let rows):
            // The designation, if sent, already matched catalog_state.
            if case .current = request.designation { storedDesignationJSON = request.designationJSON }
            let stored = apply(rows)
            if !stored { sink("Catalog store: OUTCOME nothing written via \(request.door.rawValue) — " + Self.counts(rows)) }
            return stored
        case .refused(let words, _):
            blockedReason = words
            sink("Catalog store: REFUSED via \(request.door.rawValue) — \(words). Nothing was written; the changes stay in memory "
                 + "until Catalog ▸ Reopen SQLite Catalog.")
            return false
        case .generationMismatch(let expected, let found):
            let words = "another writer committed generation \(found) (this session expected \(expected)) — reopen the catalog"
            blockedReason = words
            sink("Catalog store: REFUSED via \(request.door.rawValue) — \(words). Nothing was written.")
            return false
        }
    }

    /// The baseline moves for every row the store now holds; a row the store
    /// could not take is named once. Then the copies. True = every row stored.
    private func apply(_ rows: [CatalogCommit.RowResult]) -> Bool {
        var allStored = true
        var shared: [(source: UUID, digest: String, fields: [CatalogDDL.KnowledgeField])] = []
        for row in rows {
            switch row.landing {
            case .written(let curated, let notes):
                baseline[row.id] = row.fingerprint
                pending[row.id] = nil
                if let digest = row.digest, !curated.isEmpty { shared.append((row.id, digest, curated)) }
                for note in notes { sink("Catalog store: NOTE \(row.id.uuidString) — \(note)") }
            case .unchanged:
                baseline[row.id] = row.fingerprint
                pending[row.id] = nil
            case .deferred(let words), .refused(let words):
                allStored = false
                if pending[row.id]?.words != words {
                    sink("Catalog store: NOT SAVED \(row.id.uuidString) — \(words)")
                }
                pending[row.id] = (row.fingerprint, words)
            }
        }
        if !shared.isEmpty { shareWithCopies(shared) }
        return allStored
    }

    /// Copies of one content show the same curated values (the display
    /// tables are keyed by digest): copy what was written onto the others,
    /// and move their baseline when that was their only difference.
    private func shareWithCopies(_ shared: [(source: UUID, digest: String, fields: [CatalogDDL.KnowledgeField])]) {
        let records = input().records
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let wanted = Set(shared.map(\.digest))
        var byDigest: [String: [VideoRecord]] = [:]
        for record in records {
            guard let digest = CatalogCommit.digest(of: record), wanted.contains(digest) else { continue }
            byDigest[digest, default: []].append(record)
        }
        var touched = false
        for entry in shared {
            guard let source = byID[entry.source] else { continue }
            for copy in byDigest[entry.digest] ?? [] where copy.id != entry.source {
                let before = CatalogChangeDetector.fingerprint(VideoRecordDTO(copy))
                CatalogCommit.shareCurated(entry.fields, from: source, to: copy)
                let after = CatalogChangeDetector.fingerprint(VideoRecordDTO(copy))
                guard after != before else { continue }
                touched = true
                if baseline[copy.id] == before { baseline[copy.id] = after }
            }
        }
        if touched { onCopiesUpdated() }
    }

    private func noteOnce(_ line: String) {
        guard lastRefusalNote != line else { return }
        lastRefusalNote = line
        sink(line)
    }

    // MARK: - Words

    static func counts(_ rows: [CatalogCommit.RowResult]) -> String {
        var written = 0, unchanged = 0, deferred = 0, refused = 0
        for row in rows {
            switch row.landing {
            case .written: written += 1
            case .unchanged: unchanged += 1
            case .deferred: deferred += 1
            case .refused: refused += 1
            }
        }
        return "written \(written) · unchanged \(unchanged) · deferred \(deferred) · refused \(refused)"
    }

    /// The designation as catalog_state stores it (sorted keys, ISO dates).
    static func json(_ designation: MasterArchiveDesignation?) -> String? {
        guard let designation else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(designation)).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func designation(fromJSON json: String?) -> MasterArchiveDesignation? {
        guard let data = json?.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MasterArchiveDesignation.self, from: data)
    }

    static func sameJSON(_ a: String?, _ b: String?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let x?, let y?): return CatalogJSONValue.parse(x) == CatalogJSONValue.parse(y)
        default: return false
        }
    }
}
