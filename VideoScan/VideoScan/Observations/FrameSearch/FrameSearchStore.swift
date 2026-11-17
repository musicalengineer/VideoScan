// FrameSearchStore.swift — the Observations window's Frames mode: type what
// you are looking for ("a birthday cake with candles") and see the frames
// SigLIP 2 thinks look like it (docs/design/file_dossier_view.md §II.7).
//
// One sentence: `FrameSearchLoader.production(model:)` is the only way the
// app reads the frame index, embeds a query and maps a hit to a catalog
// file; each Observations window owns one FrameSearchStore that runs it off
// the main actor and publishes the hits.
//
// Shape: a feature store behind a seam (rule 12) — the window owns it,
// nothing extends VideoScanModel. The loader is a value of closures a test
// replaces (a stub embedder, a temp index folder, a fixture catalog).
//
// Truth (§II.0, machine observations only): a hit is (content, frame time,
// cosine similarity) straight from the index row that produced it, shown
// with its source in words — "SigLIP 2 (google/siglip2-base-patch16-224),
// similarity 0.17" — and the file it came from (the link, nothing else).
// The scope is the window's: a row whose content is not in scope is never a
// hit. A missing or unreadable index is "index not built" with the reason,
// never stale or partial hits. A search publishes only while its request
// (scope, words) is still the current one — `LatestWins`
// (ObservationsStore.swift), the same rule the Words search follows. The
// index follows it too: the newest read of the disk or the newest save the
// job handed over is the one shown and searched; an older one finishing late
// is dropped. A window that opens while Index Frames is already running joins
// that job (`joinIndex`) and is handed its saves like the window that
// started it. Similarity is SigLIP's raw cosine (−1…1; matching captions
// land around 0.10–0.20); it is a ranking, not a probability, and the words
// say so.
//
// Memory (worst case): the index in RAM (FrameIndex.swift: 3 KB per frame;
// 160k frames ≈ 490 MB; after a save it is the job's snapshot, handed over,
// not a second read of the file), the scope's file rows (~250 B per content), one
// page of hits (≤ 60), the thumbnail cache (≤ 240 frames × ~130 KB ≈ 31 MB).
//
// (For Rick: `@MainActor final class … ObservableObject` ≈ a UI-thread
// controller whose `@Published` members repaint the view when assigned.)

import AppKit
import Combine
import CoreGraphics
import Foundation
import VideoScanCore

/// One frame hit as the view shows it.
struct FrameHit: Identifiable, Equatable, Sendable {
    var id: String { FrameIndex.cacheKey(model: model, digest: digest, seconds: seconds) }
    let model: String
    let digest: String
    let seconds: Double
    let score: Float
    let recordID: UUID?
    let filename: String
    let path: String
    let removed: Bool

    /// The source, in words, with the similarity (shown under every thumbnail).
    var sourceWords: String { "SigLIP 2 (\(model)), similarity " + String(format: "%.2f", score) }
}

/// THE door: how the app reads the frame index and searches it.
struct FrameSearchLoader {
    typealias Files = @Sendable (_ scope: ObservationsScope) async throws -> [CatalogRow.FrameIndexFile]

    let id = UUID()
    let modelID: String
    let loadIndex: @Sendable () async -> FrameIndexStatus
    let files: Files
    let embedText: @Sendable (String) async throws -> [Float]
    let prewarm: @Sendable () async throws -> Void
    let thumbnail: @Sendable (_ path: String, _ seconds: Double) async -> CGImage?
    /// Start (or find) the index job over the scope; nil when no MFO center is reachable.
    /// `onSaved` is given the index exactly as each save wrote it.
    let startIndex: @MainActor (_ scope: ObservationsScope, _ onSaved: @escaping @MainActor (FrameIndex) -> Void) -> FrameIndexWatch?
    /// The Index Frames job that is ALREADY running for THIS index (the folder this loader reads, its model), if
    /// one is — joined: `onSaved` is given every save from now on. For a window that opens mid-run.
    /// (Default: nothing to join — tests and mockups that start no job.)
    var joinIndex: @MainActor (_ onSaved: @escaping @MainActor (FrameIndex) -> Void) -> FrameIndexWatch? = { _ in nil }
    let reveal: @MainActor (UUID) -> Bool
    let note: @MainActor (String) -> Void

    @MainActor private static var built: [ObjectIdentifier: (model: WeakModel, loader: FrameSearchLoader)] = [:]

    private final class WeakModel {
        weak var model: VideoScanModel?
        init(_ model: VideoScanModel) { self.model = model }
    }

    /// One loader per model, built once.
    @MainActor
    static func production(model: VideoScanModel) -> FrameSearchLoader {
        let key = ObjectIdentifier(model)
        if let entry = built[key], entry.model.model === model { return entry.loader }
        let loader = make(model: model)
        built = built.filter { $0.value.model.model != nil }
        built[key] = (WeakModel(model), loader)
        return loader
    }

    /// The loader over `model`'s session. The app calls this through `production(model:)` with the defaults —
    /// SigLIP 2, the index folder in Application Support, the app's MFO center. A test names all three (a stub
    /// model, a temp folder, its own center), so everything the window does through this door is tested as built.
    /// The job is started over the SAME `root` the window reads, by construction.
    @MainActor
    static func make(model: VideoScanModel, embedder: any FrameEmbedding = SigLIPEmbedder.shared,
                     root: URL = FrameIndexStore.productionRoot,
                     center: @escaping @MainActor () -> MediaFileOperationsCenter? = { FrameIndexHost.center }) -> FrameSearchLoader {
        let read = SessionCatalogRead(model: model)   // the module's one read door (ObservationsStore.swift)
        let files: Files = { scope in try await read { try $0.frameIndexFiles(scope) } }
        let note: @MainActor (String) -> Void = { [weak model] line in
            model?.log("Frames: " + line)
            appLog.write("[frames] " + line)
        }
        return FrameSearchLoader(
            modelID: embedder.modelID,
            loadIndex: { FrameIndexStore.load(root: root, model: embedder.modelID) },
            files: files,
            embedText: { try await embedder.embed(text: $0) },
            prewarm: { try await embedder.prewarm() },
            thumbnail: { path, seconds in await FrameThumbnails.shared.image(path: path, seconds: seconds) },
            startIndex: { scope, onSaved in
                guard let center = center() else { return nil }
                return center.startedByUser {
                    $0.watchFrameIndex(scope: scope, loadFiles: files, embedder: embedder, root: root, note: note, onSaved: onSaved)
                }
            },
            joinIndex: { onSaved in center()?.joinFrameIndex(root: root, model: embedder.modelID, onSaved: onSaved) },
            reveal: { [weak model] id in
                guard let model, model.canNavigateToRecord(id: id) else { return false }
                model.showInCatalog(recordID: id)
                return true
            },
            note: note)
    }
}

/// The MFO center, handed over once at launch (VideoScanApp) — the Observations window is an
/// NSWindow outside the SwiftUI environment, and `NSApp.delegate` is SwiftUI's proxy, not ours.
@MainActor
enum FrameIndexHost {
    static weak var center: MediaFileOperationsCenter?
}

/// Frame thumbnails for the hit grid: the captioner's frame door, downscaled, a bounded cache.
actor FrameThumbnails {
    static let shared = FrameThumbnails()
    private let cache = NSCache<NSString, CGImage>()
    init() { cache.countLimit = 240 }

    func image(path: String, seconds: Double) async -> CGImage? {
        let key = "\(path)|\(FrameIndex.millis(seconds))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard FileManager.default.fileExists(atPath: path),
              let frames = try? await extractFramesForCaptioning(from: URL(fileURLWithPath: path), atTimestamps: [seconds]),
              case .success(let image)? = frames.first?.frame else { return nil }
        let small = FrameIndexEngine.thumbnail(image, maxEdge: 320)
        cache.setObject(small, forKey: key)
        return small
    }
}

@MainActor
final class FrameSearchStore: ObservableObject {

    enum IndexState: Equatable {
        case loading
        /// No usable index; the words say why ("index not built" + the reason).
        case notBuilt(String)
        case ready(frames: Int, contents: Int)
    }

    /// One search request: the words, and the scope they are asked of.
    struct Request: Equatable, Sendable {
        let scope: ObservationsScope
        let query: String
    }

    /// What one search found. `rows` is the scope's files as that search read them (nil: nothing was read).
    struct Found: Sendable {
        var hits: [FrameHit] = []
        /// "query 0.21 s (text tower 0.18 s, search 0.03 s) over 12,345 frames in scope"
        var timing: String?
        var rows: [String: CatalogRow.FrameIndexFile]?
    }

    /// What one look at the index found — read from disk, or handed over by a save.
    struct IndexRead: Sendable {
        let status: FrameIndexStatus
        /// The videos with a frame in it. O(frames) to count, so it is counted where the read is made (off the main actor).
        let contents: Int

        init(_ status: FrameIndexStatus) {
            self.status = status
            contents = status.index?.indexedDigests.count ?? 0
        }
    }

    static let pageSize = 48
    static let perContent = 2

    @Published private(set) var scope: ObservationsScope
    /// The index, latest wins. One index per model, so the key is the model id: it never changes, which keeps
    /// the index on screen (and searchable) while a newer one is on its way.
    @Published private var indexRun = LatestWins<String, IndexRead>()
    @Published private var searchRun = LatestWins<Request, Found>()
    @Published private(set) var revealProblem: String?
    @Published private(set) var job: FrameIndexJob?
    @Published private(set) var jobLine: String?

    let loader: FrameSearchLoader
    /// The current scope's files, kept between searches — dropped with the scope, and whenever a newer index is
    /// shown: a video catalogued and indexed since these rows were read is in that index and must be findable.
    private var scopeFiles: [String: CatalogRow.FrameIndexFile]?
    private var warming: Task<Void, Never>?
    private var jobWatch: AnyCancellable?
    /// Takes this window's entry out of the job's listeners (set while a job is watched).
    private var stopTelling: (@MainActor () -> Void)?
    /// The window went away. A closed store publishes nothing, ever again — whatever still holds it.
    private var closed = false

    init(scope: ObservationsScope, loader: FrameSearchLoader) {
        self.scope = scope
        self.loader = loader
    }

    // What the view reads — each one a reading of the request's phase, never a flag of its own.
    var hits: [FrameHit] { searchRun.value?.hits ?? [] }
    var query: String? { searchRun.key?.query }
    var searching: Bool { searchRun.isLoading }
    var failure: String? { searchRun.failure.map(FailureWords.of) }
    var timing: String? { searchRun.value?.timing }

    /// The standing line: a reading of the newest index, never a field of its own. (O(1): the counts are already made.)
    var indexState: IndexState {
        guard let read = indexRun.value else { return .loading }
        switch read.status {
        case .notBuilt:
            return .notBuilt("Index not built — no frames have been indexed with \(loader.modelID) yet.")
        case .unreadable(let why):
            return .notBuilt("Index not built — the index on disk cannot be used (\(why)). Index Frames builds a new one.")
        case .ready(let index):
            return .ready(frames: index.count, contents: read.contents)
        }
    }

    /// The index a search runs over: the one the standing line describes.
    private var index: FrameIndex? { indexRun.value?.status.index }

    var modelID: String { loader.modelID }

    /// Read the index from disk — the window's first look, the one place there is no snapshot to be handed —
    /// and warm the model in the background so the first query is fast. A job already running is joined FIRST,
    /// so no save can fall between the read and the join: a save that lands during the read is the newer look.
    func loadIndex() async {
        guard !closed else { return }
        joinRunningJob()
        let load = loader.loadIndex
        guard await show({ IndexRead(await load()) }) else { return }
        let warm = loader.prewarm
        warming?.cancel()
        warming = Task.detached(priority: .utility) { try? await warm() }
    }

    /// The ONE way the index on screen changes: `look` runs off the main actor and is shown only if no newer
    /// look (a read, a save) began meanwhile. False: superseded, or the window closed — nothing was shown.
    ///
    /// Nothing computed against the index it replaces outlives it (latest wins): the scope's rows are dropped, a
    /// search still in flight is cancelled and can no longer publish, the hits on screen go at once, and the
    /// words in the field are asked again of the index now shown (one text-tower pass and one scoring — cheap).
    @discardableResult
    private func show(_ look: @escaping @Sendable () async -> IndexRead) async -> Bool {
        guard !closed else { return false }
        let ticket = indexRun.begin(loader.modelID, look)
        let result = await ticket.result
        guard indexRun.finish(ticket, result) else { return false }
        scopeFiles = nil
        if case .success(let read) = result, case .unreadable(let why) = read.status {
            loader.note("the frame index cannot be used: \(why)")
        }
        if let asked = query {
            searchRun.reset()
            await search(asked)
        }
        return true
    }

    /// A new scope: the old scope's hits and files go at once (a search still in flight for it is cancelled
    /// and can no longer publish); the words in the field are asked again of the new one.
    func set(scope: ObservationsScope) async {
        guard !closed, scope != self.scope else { return }
        let asked = query
        self.scope = scope
        scopeFiles = nil
        searchRun.reset()
        if let asked { await search(asked) }
    }

    /// Embed the words, score every frame in scope, publish the best page. Words too short to ask (the field
    /// was cleared) end any search in flight and clear the hits.
    func search(_ raw: String) async {
        guard !closed else { return }
        revealProblem = nil
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else {
            searchRun.reset()
            return
        }
        let request = Request(scope: scope, query: text)
        let embed = loader.embedText, files = loader.files
        let index = index, known = scopeFiles
        let k = Self.pageSize, cap = Self.perContent
        let ticket = searchRun.begin(request) {
            guard let index else { return Found() }   // no usable index: nothing to ask; the standing line says why
            let t0 = ContinuousClock.now
            let vector = try await embed(text)
            let t1 = ContinuousClock.now
            let rows: [String: CatalogRow.FrameIndexFile]
            if let known { rows = known } else {
                let fetched = try await files(request.scope)
                rows = Dictionary(fetched.map { ($0.digest, $0) }, uniquingKeysWith: { a, _ in a })
            }
            let top = FrameSearch.topK(query: vector, in: index, k: k, allowed: Set(rows.keys), perContent: cap)
            let inScope = index.entries.reduce(0) { $0 + (rows[$1.digest] != nil ? 1 : 0) }
            let hits = top.compactMap { scored -> FrameHit? in
                guard let row = rows[scored.entry.digest] else { return nil }
                return FrameHit(model: index.model, digest: scored.entry.digest, seconds: scored.entry.seconds, score: scored.score,
                                recordID: UUID(uuidString: row.fileID), filename: row.filename, path: row.path, removed: row.removed)
            }
            let t2 = ContinuousClock.now
            let timing = "query \(FrameSearchStore.seconds(t2 - t0)) (text tower \(FrameSearchStore.seconds(t1 - t0)), search \(FrameSearchStore.seconds(t2 - t1))) over \(inScope.formatted()) frames in scope"
            return Found(hits: hits, timing: timing, rows: rows)
        }
        let result = await ticket.result
        guard searchRun.finish(ticket, result) else { return }
        switch result {
        case .success(let found):
            guard let rows = found.rows else { return }
            scopeFiles = rows   // still the current request, so read under the index on screen: a newer index resets the search
            loader.note("searched \"\(text)\" in \(request.scope.words): \(found.hits.count) frame hit\(found.hits.count == 1 ? "" : "s"), best \(found.hits.first.map { String(format: "%.3f", $0.score) } ?? "—"); \(found.timing ?? "")")
        case .failure(let error):
            loader.note("the search for \"\(text)\" in \(request.scope.words) could not run — \(FailureWords.of(error))")
        }
    }

    nonisolated static func seconds(_ d: Duration) -> String {
        String(format: "%.2f s", Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
    }

    /// What a job is given to tell this window of a save. Weak: a window that is gone keeps nothing alive; a
    /// window that is closed but still held by something is told nothing (`closed`), and its entry is out of
    /// the job's list anyway (`stopTelling`).
    private var whenSaved: @MainActor (FrameIndex) -> Void {
        { [weak self] saved in
            guard let self, !self.closed else { return }
            Task { [weak self] in await self?.show(saved: saved) }
        }
    }

    /// The window opened while Index Frames runs for THIS index: show that job and be handed its saves from now on.
    private func joinRunningJob() {
        guard job == nil, let running = loader.joinIndex(whenSaved) else { return }
        watch(running)
    }

    /// Start (or show) the index job over the window's scope. Each save hands back the index it wrote.
    func buildIndex() {
        guard !closed else { return }
        guard let started = loader.startIndex(scope, whenSaved) else {
            jobLine = "The Media File Operations center is not available in this window."
            return
        }
        guard started.job.state.isActive else {
            // Already over — refused before it started (a viewer Mac, another index's job running). It will
            // never change again, so there is nothing to watch: say why and leave the button as it was.
            job = nil
            jobLine = Self.refusalWords(started.job)
            return
        }
        watch(started)
    }

    /// Why a job that refused did so (the words its own FAILED state carries); nil for any other ending.
    private static func refusalWords(_ job: FrameIndexJob) -> String? {
        guard job.wasRefused, case .failed(let message) = job.state else { return nil }
        return message
    }

    private func watch(_ watch: FrameIndexWatch) {
        stopTelling?()
        stopTelling = watch.stopTelling
        job = watch.job
        jobLine = watch.job.subtitle
        jobWatch = watch.job.objectWillChange
            .throttle(for: .milliseconds(500), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self, weak job = watch.job] _ in
                guard let self, let job else { return }
                guard !job.state.isActive else { self.jobLine = job.subtitle; return }
                // Over. A refusal that came AFTER the watch began (the catalog could not be read) keeps its
                // reason beside the button until the next action, in the same words as one that came at once.
                self.jobLine = Self.refusalWords(job)
                self.job = nil
                self.stopTelling = nil
            }
    }

    /// The job saved the index: show exactly what it wrote. The snapshot is the job's own (handed over, sharing
    /// the builder's buffers until the job adds a file) — the disk is not read again; only `loadIndex()` reads it.
    private func show(saved index: FrameIndex) async {
        await show { IndexRead(.ready(index)) }
    }

    @discardableResult
    func reveal(_ hit: FrameHit) -> Bool {
        guard let id = hit.recordID, loader.reveal(id) else {
            revealProblem = "\(hit.filename) is not in this session's catalog — nothing to show"
            return false
        }
        revealProblem = nil
        return true
    }

    /// The window went away, for good: stop the search in flight and the model warm-up, take this window out of
    /// the job's listeners, and publish nothing from here on — an index read still running, a save still on its
    /// way and anything asked of the store afterwards show nothing.
    func cancel() {
        closed = true
        stopTelling?()
        stopTelling = nil
        indexRun.reset()
        searchRun.reset()
        warming?.cancel()
        warming = nil
        jobWatch = nil
    }
}
