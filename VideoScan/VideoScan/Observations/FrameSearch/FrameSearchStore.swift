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
// never stale or partial hits. Similarity is SigLIP's raw cosine (−1…1;
// matching captions land around 0.10–0.20); it is a ranking, not a
// probability, and the words say so.
//
// Memory (worst case): the index in RAM (FrameIndex.swift: 3 KB per frame;
// 160k frames ≈ 490 MB), the scope's file rows (~250 B per content), one
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
    let startIndex: @MainActor (_ scope: ObservationsScope, _ onSaved: @escaping @MainActor () -> Void) -> FrameIndexJob?
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

    @MainActor
    private static func make(model: VideoScanModel) -> FrameSearchLoader {
        let notOpen = Refusal("catalog.sqlite is not open in this session — there is nothing to read")
        let embedder = SigLIPEmbedder.shared
        let root = FrameIndexStore.productionRoot
        let files: Files = { [weak model] scope in
            let repository = await MainActor.run { model?.catalogCutover.committer?.repository }
            guard let repository else { throw notOpen }
            return try await repository.read { try $0.frameIndexFiles(scope) }
        }
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
                guard let center = FrameIndexHost.center else { return nil }
                return center.startedByUser {
                    $0.startFrameIndex(scope: scope, loadFiles: files, embedder: embedder, note: note, onSaved: onSaved)
                }
            },
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

    static let pageSize = 48
    static let perContent = 2

    @Published private(set) var scope: ObservationsScope
    @Published private(set) var indexState: IndexState = .loading
    @Published private(set) var hits: [FrameHit] = []
    @Published private(set) var query: String?
    @Published private(set) var searching = false
    @Published private(set) var failure: String?
    /// "query 0.21 s (text tower 0.18 s, search 0.03 s) over 12,345 frames in scope"
    @Published private(set) var timing: String?
    @Published private(set) var revealProblem: String?
    @Published private(set) var job: FrameIndexJob?
    @Published private(set) var jobLine: String?

    let loader: FrameSearchLoader
    private var index: FrameIndex?
    private var scopeFiles: [String: CatalogRow.FrameIndexFile]?
    private var searchIssued = 0
    private var jobWatch: AnyCancellable?

    init(scope: ObservationsScope, loader: FrameSearchLoader) {
        self.scope = scope
        self.loader = loader
    }

    var modelID: String { loader.modelID }

    /// Read the index from disk (and warm the model in the background so the first query is fast).
    func loadIndex() async {
        indexState = .loading
        let load = loader.loadIndex
        let (status, contents) = await Task.detached(priority: .userInitiated) { () -> (FrameIndexStatus, Int) in
            let s = await load()
            return (s, s.index?.indexedDigests.count ?? 0)   // O(frames): off the main actor
        }.value
        apply(status, contents: contents)
        let warm = loader.prewarm
        Task.detached(priority: .utility) { try? await warm() }
    }

    private func apply(_ status: FrameIndexStatus, contents: Int) {
        switch status {
        case .notBuilt:
            index = nil
            indexState = .notBuilt("Index not built — no frames have been indexed with \(loader.modelID) yet.")
        case .unreadable(let why):
            index = nil
            indexState = .notBuilt("Index not built — the index on disk cannot be used (\(why)). Index Frames builds a new one.")
            loader.note("the frame index cannot be used: \(why)")
        case .ready(let i):
            index = i
            indexState = .ready(frames: i.count, contents: contents)
        }
    }

    func set(scope: ObservationsScope) async {
        guard scope != self.scope else { return }
        self.scope = scope
        scopeFiles = nil
        hits = []
        if let q = query { await search(q) }
    }

    /// Embed the words, score every frame in scope, publish the best page.
    func search(_ raw: String) async {
        searchIssued += 1
        let mine = searchIssued
        revealProblem = nil
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else { hits = []; query = nil; failure = nil; timing = nil; return }
        query = text
        guard let index else {
            hits = []
            failure = nil
            return
        }
        searching = true
        let scope = scope
        let embed = loader.embedText, files = loader.files
        let known = scopeFiles
        let started = ContinuousClock.now
        let k = Self.pageSize, cap = Self.perContent
        do {
            let result = try await Task.detached(priority: .userInitiated) { () -> ([FrameSearch.Scored], [String: CatalogRow.FrameIndexFile], Duration, Duration, Int) in
                let t0 = ContinuousClock.now
                let vector = try await embed(text)
                let t1 = ContinuousClock.now
                let rows: [String: CatalogRow.FrameIndexFile]
                if let known { rows = known } else {
                    let fetched = try await files(scope)
                    rows = Dictionary(fetched.map { ($0.digest, $0) }, uniquingKeysWith: { a, _ in a })
                }
                let top = FrameSearch.topK(query: vector, in: index, k: k, allowed: Set(rows.keys), perContent: cap)
                let inScope = index.entries.reduce(0) { $0 + (rows[$1.digest] != nil ? 1 : 0) }
                return (top, rows, t1 - t0, ContinuousClock.now - t1, inScope)
            }.value
            guard mine == searchIssued else { return }
            scopeFiles = result.1
            hits = result.0.compactMap { scored in
                guard let row = result.1[scored.entry.digest] else { return nil }
                return FrameHit(model: index.model, digest: scored.entry.digest, seconds: scored.entry.seconds, score: scored.score,
                                recordID: UUID(uuidString: row.fileID), filename: row.filename, path: row.path, removed: row.removed)
            }
            failure = nil
            searching = false
            let total = ContinuousClock.now - started
            timing = "query \(Self.seconds(total)) (text tower \(Self.seconds(result.2)), search \(Self.seconds(result.3))) over \(result.4.formatted()) frames in scope"
            loader.note("searched \"\(text)\" in \(scope.words): \(hits.count) frame hit\(hits.count == 1 ? "" : "s"), best \(hits.first.map { String(format: "%.3f", $0.score) } ?? "—"); \(timing ?? "")")
        } catch {
            guard mine == searchIssued, !(error is CancellationError) else { return }
            searching = false
            failure = "\(error.localizedDescription)"
        }
    }

    static func seconds(_ d: Duration) -> String {
        String(format: "%.2f s", Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
    }

    /// Start (or show) the index job over the window's scope.
    func buildIndex() {
        guard let job = loader.startIndex(scope, { [weak self] in Task { await self?.reloadAfterSave() } }) else {
            jobLine = "The Media File Operations center is not available in this window."
            return
        }
        watch(job)
    }

    private func watch(_ job: FrameIndexJob) {
        self.job = job
        jobLine = job.subtitle
        jobWatch = job.objectWillChange
            .throttle(for: .milliseconds(500), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self, weak job] _ in
                guard let self, let job else { return }
                self.jobLine = job.state.isActive ? job.subtitle : nil
                if !job.state.isActive { self.job = nil }
            }
    }

    private func reloadAfterSave() async {
        let (status, contents) = await Task.detached(priority: .utility) { [load = loader.loadIndex] () -> (FrameIndexStatus, Int) in
            let s = await load()
            return (s, s.index?.indexedDigests.count ?? 0)
        }.value
        apply(status, contents: contents)
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

    func cancel() {
        searchIssued += 1
        jobWatch = nil
    }
}
