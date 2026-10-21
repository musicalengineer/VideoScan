// CatalogSnapshotPublisher.swift
// The master's side of CatalogSync phase 2 (2026-10-19): keeps
// viewer-catalog/catalog.sqlite (CatalogViewerSnapshot) current for the
// viewer Macs, then asks CatalogSync to refresh manifest.sha256.
//
// When: once shortly after launch, then every `interval`, and only when
// the store's generation moved since the last publish. That bounds the
// cost — one `VACUUM INTO` plus one manifest hash per changed interval,
// never one per save — while a viewer polling every 90 s lags the master
// by at most about `interval` + 90 s. (Under catalog.json the manifest was
// refreshed after every save; with a whole-database seal that would hold
// the store's writer for a full copy on every 2 s commit.)
//
// Not while a job or a scan writes to the catalog (GH #350, `Source.busy`):
// its commits move the generation on every tick, so the whole copy was
// sealed and integrity-checked again every interval for the length of the
// run. The tick is skipped (said once, same sink), looked at again every
// `busyRecheck`, and the copy is published once on the first tick after
// the writer ends. What a publish contains and how it is validated are
// unchanged. Viewers lag a running job by its length — Rick's call.
//
// Each publish:
//   1. commits what is in memory FIRST (`CatalogCommitter
//      .commitBeforeSafetyCopy`, main actor) — so the snapshot holds what
//      the person sees, not the last debounced commit; a refusal (held by
//      a job, read-only, being reopened) skips this tick and says why once;
//   2. seals, validates and publishes OFF the main actor
//      (CatalogViewerSnapshot.publish — VACUUM INTO blocks its thread);
//   3. on success, `onPublished` (CatalogSync.scheduleManifestRefresh).
// START / OUTCOME / REFUSED lines go through the injected sink (console,
// catalog.log, videoscan.log — the one sink).
//
// No-op unless catalog.sqlite is this Mac's authority (`source.store()`
// answers nil under catalog.json). The publisher never opens the store
// itself; it borrows the session's repository and committer.
//
// (For Rick: `@MainActor final class` ≈ an object whose methods all run
// on the UI thread; the `Task.detached` hop is a worker thread, like
// std::async(std::launch::async, …) with the result awaited.)

import Foundation
import VideoScanCore

@MainActor
final class CatalogSnapshotPublisher {

    /// What the session lends the publisher: the open store and its
    /// commit-first door. nil while catalog.json is the authority.
    struct Store {
        let repository: any CatalogRepository
        /// nil = what is in memory is committed (the copy may be sealed);
        /// else the words why no commit can be written now.
        let commitFirst: () -> String?
    }

    /// Where the session's store and latch are found, read on every tick
    /// so a mid-session Switch Catalog to SQLite is picked up.
    struct Source {
        let store: () -> Store?
        /// The master's `catalog.cutover`, beside its catalog.sqlite.
        let latchURL: URL
        /// Who is writing to the catalog right now, in words ("Fill In
        /// Full Hashes is running"); nil = nobody (GH #350). While someone
        /// is, a tick seals nothing — the generation moves on every commit,
        /// so each tick would `VACUUM INTO` and integrity-check the whole
        /// copy again (and commit first on the main actor) for the whole
        /// run. The copy is published once the writer is done.
        var busy: () -> String? = { nil }
    }

    enum Outcome: Equatable {
        case published(CatalogViewerSnapshot.Published)
        case unchanged(generation: Int)
        case skipped(String)
        case failed(String)
    }

    static let interval: Duration = .seconds(120)
    static let firstDelay: Duration = .seconds(15)
    /// While a writer holds the publish back, look again this often, so the
    /// viewers get the job's result soon after it ends (not up to `interval`
    /// later). A look is one closure call — nothing is opened or sealed.
    static let busyRecheck: Duration = .seconds(15)

    private let liveDir: URL
    private let source: Source
    private let log: (String) -> Void
    private let onPublished: () -> Void
    private var loop: Task<Void, Never>?
    private var publishing = false
    private var lastSkipWords: String?
    private(set) var lastPublishedGeneration: Int?
    private(set) var lastOutcome: Outcome?
    /// The last tick was held back for a writer (`Source.busy`).
    private(set) var isHeldForWriter = false

    init(liveDir: URL, source: Source, log: @escaping (String) -> Void, onPublished: @escaping () -> Void) {
        self.liveDir = liveDir
        self.source = source
        self.log = log
        self.onPublished = onPublished
    }

    /// Start the periodic publish. Idempotent.
    func start(firstDelay: Duration = CatalogSnapshotPublisher.firstDelay,
               interval: Duration = CatalogSnapshotPublisher.interval,
               busyRecheck: Duration = CatalogSnapshotPublisher.busyRecheck) {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: firstDelay)
            while !Task.isCancelled {
                await self?.publishIfChanged()
                let held = self?.isHeldForWriter ?? false
                try? await Task.sleep(for: held ? min(busyRecheck, interval) : interval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// One tick: commit first, then publish when the generation moved (or
    /// nothing is published yet). Returns what happened (tests).
    @discardableResult
    func publishIfChanged() async -> Outcome {
        guard !publishing else { return .skipped("a publish is already running") }
        guard let store = source.store() else {
            return skip("catalog.json is this Mac's catalog — there is no catalog.sqlite to publish for viewers")
        }
        // Before commit-first: nothing touches the store while a writer runs.
        if let writer = source.busy() {
            isHeldForWriter = true
            return skip("\(writer) and writing to the catalog — the viewer copy is published once it ends")
        }
        if isHeldForWriter {
            isHeldForWriter = false
            lastSkipWords = nil   // the next hold says why again
        }
        if let why = store.commitFirst() {
            return skip("what is in memory could not be committed first: \(why)")
        }
        let generation = await store.repository.generation
        let alreadyThere = FileManager.default.fileExists(atPath: CatalogViewerSnapshot.databaseURL(in: liveDir).path)
        if generation == lastPublishedGeneration, alreadyThere {
            return finish(.unchanged(generation: generation))
        }
        publishing = true
        defer { publishing = false }
        log("CatalogSync: START publishing catalog.sqlite (generation \(generation)) for viewer Macs")
        let repository = store.repository
        let latch = source.latchURL
        let liveDir = liveDir
        let result: Result<CatalogViewerSnapshot.Published, Error> = await Task.detached(priority: .utility) {
            do {
                return .success(try await CatalogViewerSnapshot.publish(from: repository, latch: latch, into: liveDir))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(let published):
            lastPublishedGeneration = published.generation
            lastSkipWords = nil
            log("CatalogSync: OUTCOME published \(CatalogViewerSnapshot.databaseRelativePath) — generation \(published.generation), "
                + "\(published.files) file rows, \(ByteCountFormatter.string(fromByteCount: published.bytes, countStyle: .file))")
            onPublished()
            return finish(.published(published))
        case .failure(let error):
            let words = error.localizedDescription
            log("CatalogSync: REFUSED publishing catalog.sqlite for viewers — \(words). Viewers keep the last published copy.")
            return finish(.failed(words))
        }
    }

    /// A skip is said once per reason, not every two minutes.
    private func skip(_ words: String) -> Outcome {
        if lastSkipWords != words {
            lastSkipWords = words
            log("CatalogSync: not publishing catalog.sqlite for viewers — \(words)")
        }
        return finish(.skipped(words))
    }

    private func finish(_ outcome: Outcome) -> Outcome {
        lastOutcome = outcome
        return outcome
    }
}
