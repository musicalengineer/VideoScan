// FrameIndexJob.swift — "Index Frames (SigLIP 2)", the Media File Operation
// that builds the Frames search's index (docs/design/file_dossier_view.md
// §II.7 item 2). Started from the Observations window's Frames mode over
// the window's scope; shown in the MFO window with N of M, the current file,
// time left, Pause and Stop; START / progress / OUTCOME through the one sink.
//
// Per file (FrameIndexEngine.outcome — the ONE engine; the smoke test drives
// it too, through `frames`): pick `framesPerFile` times evenly inside the
// clip (the captioner's own rule, `framesEvenlySpaced`, so a frame hit lines
// up with the captions' times), decode them through the captioner's frame
// door (`extractFramesForCaptioning`: AVFoundation, else ffmpeg — read-only
// on media), embed them with SigLIP 2's image tower, and add the rows to the
// builder under (whole-file SHA-256, time ms, model id).
//
// WHOSE FAULT (FrameIndexFileOutcome; Codex sweep 2026-11-09 #14). The engine
// has two stages and the stage that failed says who is to blame — no error
// text is read:
//   • decode failed, the file is still at its path on a connected drive →
//     `.unreadable`: the FILE's fault. Recorded in the index's `failures`
//     (with the decoder's words) so a resume does not grind on it again.
//   • decode failed and the drive is gone / the file is not at its path, or
//     the drive was not connected to begin with → `.deferred`: counted, left
//     for the next run, NEVER recorded.
//   • the model threw → `.deferred(.modelUnavailable)`: never the file's
//     fault, never recorded. The JOB stops taking files, saves what it has
//     and ends FAILED with the model's own words (it did not "finish").
//     One exception, by type: `SigLIPError.badImage` is the model's pixel door
//     refusing one decoded frame — that is the file's, and is recorded.
//
// Shape (three owners):
//   • FrameIndexEngine — pure per-file work, off the main actor.
//   • FrameIndexWriter (an actor) — owns the builder; loads the index on
//     disk, plans (skips what is done — restart = resume) and saves, all on
//     its own executor, never the main actor; a save returns the snapshot it
//     wrote, which `onSaved` hands to the window (no re-read from disk).
//   • FrameIndexJob (main actor) — counters, Pause/Stop, progress, WHEN to
//     save (FrameIndexSavePoint) and the first terminal cause
//     (FrameIndexRunOutcome).
//   • `concurrency` files decode at once (IO), the embedder serialises the
//     GPU work (an actor), so decoding overlaps inference.
//   • DURABILITY: the index is saved every `checkpointFiles` files or
//     `checkpointSeconds`, on Pause, on Stop, when the model fails and at the
//     end (FrameIndexStore.save: crash-safe generations). A crash loses at
//     most one checkpoint. A save that fails stops the job (FAILED, with the
//     reason and how many results are not on disk); it is not retried.
//   • PAUSE takes effect between files; nothing is held while paused.
//     STOP lets the files being decoded finish, saves, ends. QUIT = Stop
//     with the decodes cut (a cut decode is deferred, not recorded).
//
// WRITES: only the index folder (Application Support/VideoScan/observations/
// siglip2/…). Never catalog.sqlite (it is read once, through the read door),
// never media. Not a catalog writer, so no write hold applies.
//
// Memory (worst case): `concurrency` (3) files × `framesPerFile` (8) decoded
// frames in flight — 24 × 8 MB at 1080p ≈ 190 MB (4K: 24 × 33 MB ≈ 800 MB,
// released per file) — plus the builder's matrix (3 KB per frame; 160k
// frames ≈ 490 MB) and the warm model (~0.75 GB, SigLIPEmbedder.swift).
// A saved snapshot shares the builder's buffers (copy-on-write) until the
// next file is added; while the window holds the latest snapshot as its
// search index that is one more matrix (≈ 490 MB at 160k frames) — the same
// second copy the window used to make by re-reading the file, without the
// re-read's transient third. During a save: + the half-float image of the
// matrix (≈ 245 MB at 160k), released when the write returns.
//
// (For Rick: `withTaskGroup` ≈ a fixed pool of worker threads joined at the
// end; every job counter below is touched on the main actor only, so no
// mutex. `actor FrameIndexWriter` ≈ a single-owner worker object with a
// mutex-free message queue: each `await writer.x()` posts a message and
// suspends the caller — it does not block the UI thread — until the
// writer's own thread has run it. An `enum` with payloads ≈ std::variant.)

import Combine
import CoreGraphics
import Foundation
import VideoScanCore
import os

private let frameIndexLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "frameIndex")

// MARK: - What happened to one file

/// Why a file was left for the next run. A deferral is never written to the index.
enum FrameIndexDeferral: Sendable, Equatable {
    case driveNotConnected
    case notAtPath
    /// The model threw (weights missing, load failed, no MLX) — its own words.
    case modelUnavailable(String)
    /// The decode or the inference was cut by Stop / Quit.
    case stopped

    var words: String {
        switch self {
        case .driveNotConnected: return "its drive is not connected"
        case .notAtPath: return "it is not at its path"
        case .modelUnavailable(let why): return why
        case .stopped: return "stopped before it was read"
        }
    }
}

/// One file's result. Only `.indexed` and `.unreadable` are written to the index.
enum FrameIndexFileOutcome: Sendable {
    case indexed([(seconds: Double, vector: [Float])])
    /// The FILE's fault (it is there and the decoder could not read it) — the reason in words.
    case unreadable(String)
    /// Not the file's fault — try again next run.
    case deferred(FrameIndexDeferral)
}

/// `FrameIndexEngine.frames` throws these (the smoke test's door; the job reads the outcome itself).
enum FrameIndexFailure: LocalizedError {
    case unreadable(String)
    case deferred(FrameIndexDeferral)

    var errorDescription: String? {
        switch self {
        case .unreadable(let why): return why
        case .deferred(let deferral): return deferral.words
        }
    }
}

// MARK: - The one per-file engine

enum FrameIndexEngine {

    /// Decodes `timestamps` of the file at `path`; one slot per time, in order (tests inject synthetic frames).
    typealias Extract = @Sendable (_ path: String, _ timestamps: [Double]) async throws -> [(Double, CGImage?)]
    /// Nil when the file is at its path on a connected drive; else why it cannot be tried now.
    typealias Whereabouts = @Sendable (_ path: String) -> FrameIndexDeferral?

    static let framesPerFile = 8

    /// The captioner's frame door: AVFoundation first, ffmpeg for what AVFoundation cannot open.
    static let productionExtract: Extract = { path, timestamps in
        let frames = try await extractFramesForCaptioning(from: URL(fileURLWithPath: path), atTimestamps: timestamps)
        return frames.map { item in
            if case .success(let image) = item.frame { return (item.timestamp, Self.thumbnail(image, maxEdge: 336)) }
            return (item.timestamp, nil)
        }
    }

    /// The one rule for "can this file be tried now": the drive first, then the path.
    static func whereabouts(volumeOnline: @escaping @Sendable (String) -> Bool,
                            fileExists: @escaping @Sendable (String) -> Bool) -> Whereabouts {
        { path in
            if !volumeOnline(path) { return .driveNotConnected }
            if !fileExists(path) { return .notAtPath }
            return nil
        }
    }

    /// The times to look at: evenly inside the clip, avoiding the first and last 5% (the captioner's rule).
    static func timestamps(durationSeconds: Double, framesPerFile: Int = framesPerFile) -> [Double] {
        framesEvenlySpaced(framesPerFile: framesPerFile, durationSec: max(0.5, durationSeconds))
    }

    /// One file, two stages; the stage that failed names whose fault it was. Never throws.
    static func outcome(path: String, durationSeconds: Double, framesPerFile: Int = framesPerFile,
                        extract: Extract, embedder: any FrameEmbedding, whereabouts: Whereabouts) async -> FrameIndexFileOutcome {
        let times = timestamps(durationSeconds: durationSeconds, framesPerFile: framesPerFile)

        // Stage 1 — decode. A failure is the file's, unless the run was cut or the file's drive / path has gone.
        func decodeFailed(_ why: String) -> FrameIndexFileOutcome {
            if Task.isCancelled { return .deferred(.stopped) }
            if let away = whereabouts(path) { return .deferred(away) }
            return .unreadable(why)
        }
        let decoded: [(Double, CGImage)]
        do {
            decoded = try await extract(path, times).compactMap { slot -> (Double, CGImage)? in
                guard let image = slot.1 else { return nil }
                return (slot.0, image)
            }
        } catch is CancellationError {
            return .deferred(.stopped)
        } catch {
            return decodeFailed(error.localizedDescription)
        }
        guard !decoded.isEmpty else { return decodeFailed("no frame of \(times.count) could be decoded") }

        // Stage 2 — the model. A failure is never the file's (the frames decoded), bar the pixel door refusing one.
        do {
            let vectors = try await embedder.embed(images: decoded.map(\.1))
            guard vectors.count == decoded.count, vectors.allSatisfy({ $0.count == embedder.dims }) else {
                return .deferred(.modelUnavailable("the model returned \(vectors.count) vectors for \(decoded.count) frames, or not \(embedder.dims) wide"))
            }
            return .indexed(zip(decoded, vectors).map { ($0.0, $1) })
        } catch is CancellationError {
            return .deferred(.stopped)
        } catch SigLIPError.badImage {
            return .unreadable(SigLIPError.badImage.localizedDescription)
        } catch {
            return Task.isCancelled ? .deferred(.stopped) : .deferred(.modelUnavailable(error.localizedDescription))
        }
    }

    /// One file's frames as (time, vector), for a caller that has the file in hand (the smoke test). Throws `FrameIndexFailure`.
    static func frames(path: String, durationSeconds: Double, framesPerFile: Int = framesPerFile,
                       extract: Extract, embedder: any FrameEmbedding) async throws -> [(seconds: Double, vector: [Float])] {
        switch await outcome(path: path, durationSeconds: durationSeconds, framesPerFile: framesPerFile,
                             extract: extract, embedder: embedder, whereabouts: { _ in nil }) {
        case .indexed(let frames): return frames
        case .unreadable(let why): throw FrameIndexFailure.unreadable(why)
        case .deferred(let deferral): throw FrameIndexFailure.deferred(deferral)
        }
    }

    /// Downscale right after decoding so a 4K frame is not held while it waits for the GPU.
    static func thumbnail(_ image: CGImage, maxEdge: Int) -> CGImage {
        let w = image.width, h = image.height
        guard max(w, h) > maxEdge else { return image }
        let scale = Double(maxEdge) / Double(max(w, h))
        let tw = max(1, Int(Double(w) * scale)), th = max(1, Int(Double(h) * scale))
        guard let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
        return ctx.makeImage() ?? image
    }
}

// MARK: - The writer (owns the builder; all index IO, off the main actor)

/// The index's one owner during a run. Every method runs on the actor's own executor, so the load
/// (hundreds of MB at scale), the plan and each save never hold the main actor.
actor FrameIndexWriter {

    /// What `open` found: the work to do and what the index already holds.
    struct Opened: Sendable {
        let todo: [CatalogRow.FrameIndexFile]
        let alreadyDone: Int
        let noPicture: Int
        /// Frames in the index as loaded.
        let frames: Int
        /// Set when something is on disk that cannot be trusted (a new index is started; the reason in words).
        let unreadableIndex: String?
    }

    private let root: URL
    private var builder: FrameIndexBuilder

    init(root: URL, model: String, dims: Int) {
        self.root = root
        builder = FrameIndexBuilder(model: model, dims: dims)
    }

    /// Load the index on disk (it seeds the builder) and plan `rows` against it:
    /// to do = has a picture, not removed, neither indexed nor recorded as unreadable.
    func open(_ rows: [CatalogRow.FrameIndexFile]) -> Opened {
        let existing = FrameIndexStore.load(root: root, model: builder.model)
        builder = FrameIndexBuilder(model: builder.model, dims: builder.dims, seed: existing.index)
        var todo: [CatalogRow.FrameIndexFile] = []
        var already = 0, noPicture = 0
        for row in rows {
            if !row.hasVideo || row.removed { noPicture += 1 } else if builder.isDone(row.digest) { already += 1 } else { todo.append(row) }
        }
        var unreadable: String?
        if case .unreadable(let why) = existing { unreadable = why }
        return Opened(todo: todo, alreadyDone: already, noPicture: noPicture, frames: builder.frameCount, unreadableIndex: unreadable)
    }

    /// Add one content's frames; returns the frames the index now holds.
    func add(digest: String, frames: [(seconds: Double, vector: [Float])]) -> Int {
        builder.add(digest: digest, frames: frames)
        return builder.frameCount
    }

    /// Record a file the decoder could not read (the FILE's fault only — a deferral never comes here).
    func recordUnreadable(digest: String, reason: String) {
        builder.fail(digest: digest, reason: reason)
    }

    /// Write the index (crash-safe generations) and return exactly what was written.
    func save() throws -> FrameIndex {
        let snapshot = builder.snapshot()
        try FrameIndexStore.save(snapshot, root: root)
        return snapshot
    }
}

// MARK: - The job

/// Why a save is being made (the job decides WHEN; the writer does it).
enum FrameIndexSavePoint: String, Sendable, Equatable {
    case checkpoint
    case paused
    case stopped
    case modelFailed = "the model failed"
    case finished

    /// Only the end of a complete run writes with nothing new in hand (once, so the window gets the index).
    var writesWithNothingNew: Bool { self == .finished }
}

/// How a run ended. A failure is the FIRST terminal cause the run saw (set once).
enum FrameIndexRunOutcome: Sendable, Equatable {
    case finished
    case stopped
    /// Nothing was read or written (viewer Mac, catalog unreadable).
    case refused(String)
    /// The model threw; no file is blamed. What was indexed before is saved.
    case modelUnavailable(String)
    case saveFailed(at: FrameIndexSavePoint, why: String)
}

@MainActor
final class FrameIndexJob: @MainActor MediaFileOperationJob {

    static let verbTitle = "Index frames (SigLIP 2)"

    typealias LoadFiles = @Sendable (_ scope: ObservationsScope) async throws -> [CatalogRow.FrameIndexFile]

    let id = UUID()
    let kind: MediaFileOperationKind = .indexFrames
    let startedAt = Date()
    let scope: ObservationsScope

    // Seams (tests replace them).
    var loadFiles: LoadFiles
    var embedder: any FrameEmbedding
    var extract: FrameIndexEngine.Extract = FrameIndexEngine.productionExtract
    var volumeOnline: @Sendable (String) -> Bool = { VolumeReachability.isVolumeReachable(path: $0) }
    var fileExists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    var root: URL = FrameIndexStore.productionRoot
    var framesPerFile = FrameIndexEngine.framesPerFile
    var concurrency = 3
    var checkpointFiles = 100
    var checkpointSeconds: TimeInterval = 60
    var progressLogSeconds: TimeInterval = 60
    /// The one log sink (console + videoscan.log); the Center writes the OUTCOME line.
    var note: @MainActor (String) -> Void = { appLog.write("[frame index] " + $0) }
    /// Called after every save with the index exactly as written (the window shows it; no re-read).
    var onSaved: (@MainActor (FrameIndex) -> Void)?

    @Published private(set) var state: MediaFileOperationState = .running {
        didSet { if !state.isActive, finishedAt == nil { finishedAt = Date() } }
    }
    @Published private(set) var finishedAt: Date?
    @Published private(set) var subtitleText = "Reading the catalog…"
    @Published private(set) var fractionValue: Double = 0
    @Published private(set) var isPausedValue = false
    private(set) var wasRefused = false
    private(set) var task: Task<Void, Never>?
    /// How the run ended; nil while it is active.
    private(set) var outcome: FrameIndexRunOutcome?

    // Counters (main actor only).
    private(set) var planned = 0
    private(set) var done = 0
    private(set) var indexed = 0
    private(set) var framesAdded = 0
    private(set) var unreadable = 0
    private(set) var offline = 0
    private(set) var missing = 0
    private(set) var alreadyDone = 0
    /// The saves that reached the disk, in order (bounded: one per checkpoint + one per pause + the last).
    private(set) var savePoints: [FrameIndexSavePoint] = []
    var saves: Int { savePoints.count }
    private var writer: FrameIndexWriter?
    /// The first terminal cause other than Stop (model, save); set once. Stops the pool.
    private var failure: FrameIndexRunOutcome?
    private var saveProblem: String?
    private var heldFrames = 0
    private var stopRequested = false
    private var unsaved = 0
    private var lastSave = Date()
    private var lastProgress = Date()
    private var runStart = Date()
    private var current: Set<String> = []
    private var pending: ArraySlice<CatalogRow.FrameIndexFile> = []

    private var whereabouts: FrameIndexEngine.Whereabouts {
        FrameIndexEngine.whereabouts(volumeOnline: volumeOnline, fileExists: fileExists)
    }

    /// The next file to decode; one that cannot be tried now (drive not connected, not at its path) is counted and skipped.
    private func nextRow(_ whereabouts: FrameIndexEngine.Whereabouts) -> CatalogRow.FrameIndexFile? {
        while let row = pending.popFirst() {
            if let away = whereabouts(row.path) { count(away); continue }
            current.insert(row.path)
            return row
        }
        return nil
    }

    /// A file left for the next run because of where it is: counted as looked at, never recorded.
    private func count(_ away: FrameIndexDeferral) {
        switch away {
        case .driveNotConnected: offline += 1; done += 1
        case .notAtPath: missing += 1; done += 1
        case .modelUnavailable, .stopped: break
        }
    }

    var title: String { Self.verbTitle + " — " + scope.words }
    var subtitle: String { subtitleText }
    var fraction: Double { fractionValue }
    var isIndeterminate: Bool { planned == 0 }
    var canPause: Bool { state == .running }
    var isPaused: Bool { isPausedValue }

    init(scope: ObservationsScope, loadFiles: @escaping LoadFiles, embedder: any FrameEmbedding) {
        self.scope = scope
        self.loadFiles = loadFiles
        self.embedder = embedder
    }

    // MARK: Lifecycle

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    func refuseToStart(reason: String) {
        guard task == nil, state.isActive else { return }
        wasRefused = true
        outcome = .refused(reason)
        state = .failed(message: reason)
        task = Task {}
    }

    func cancel() {
        guard state.isActive else { return }
        state = .cancelling
        isPausedValue = false
        stopRequested = true
        subtitleText = current.isEmpty ? "Stopping — saving the index…" : "Stopping — finishing \(current.count) file\(current.count == 1 ? "" : "s"), then saving…"
    }

    func stopForQuit() {
        cancel()
        task?.cancel()
    }

    func pause() {
        guard state == .running, !isPausedValue else { return }
        isPausedValue = true
        subtitleText = "Pausing after the files in hand — \(done.formatted()) of \(planned.formatted()) done"
    }

    func resume() {
        guard isPausedValue else { return }
        isPausedValue = false
        subtitleText = "Resuming…"
    }

    private var stopped: Bool { stopRequested || failure != nil || Task.isCancelled || !state.isActive }

    // MARK: Run

    private func run() async {
        let rows: [CatalogRow.FrameIndexFile]
        do {
            rows = try await loadFiles(scope)
        } catch {
            wasRefused = true
            note("refused — the catalog could not be read (\(error.localizedDescription)). Nothing was read or written.")
            let message = "Refused — the catalog could not be read: \(error.localizedDescription)"
            outcome = .refused(message)
            state = .failed(message: message)
            return
        }
        let model = embedder.modelID
        let writer = FrameIndexWriter(root: root, model: model, dims: embedder.dims)
        let opened = await writer.open(rows)   // the load and the plan, on the writer's executor
        if let why = opened.unreadableIndex {
            note("the index on disk could not be read (\(why)) — starting a new one beside the catalog; nothing in the catalog changes")
        }
        self.writer = writer
        alreadyDone = opened.alreadyDone
        heldFrames = opened.frames
        let todo = opened.todo
        planned = todo.count
        let startLine = MediaFileOperationsCenter.startSummaryLine(
            verb: kind.logVerb, title: title,
            plan: "\(todo.count.formatted()) file\(todo.count == 1 ? "" : "s") to index, \(framesPerFile) frames each with \(model) "
                + "(\(alreadyDone.formatted()) already indexed, \(opened.noPicture.formatted()) without a picture) → \(FrameIndexStore.directory(root: root, model: model).path)")
        note(startLine)
        frameIndexLog.info("\(startLine, privacy: .public)")
        runStart = Date(); lastSave = Date(); lastProgress = Date()
        subtitleText = todo.isEmpty ? "Nothing to index" : "Loading SigLIP 2…"

        pending = todo[...]
        await drain()
        if let point = closingSavePoint { await save(point) }
        conclude()
    }

    /// The save that closes the run; none after a save has already failed (it is not retried).
    private var closingSavePoint: FrameIndexSavePoint? {
        switch failure {
        case .saveFailed: return nil
        case .modelUnavailable: return .modelFailed
        default: return stopRequested || Task.isCancelled ? .stopped : .finished
        }
    }

    /// The worker pool over `pending`: `concurrency` files in flight, Pause between files, Stop drains.
    private func drain() async {
        let whereabouts = self.whereabouts
        await withTaskGroup(of: (CatalogRow.FrameIndexFile, FrameIndexFileOutcome).self) { group in
            var running = 0
            while true {
                // Fill the pool (the closure runs on the main actor: withTaskGroup inherits the caller's isolation).
                while running < concurrency, !stopped, !isPausedValue, let row = nextRow(whereabouts) {
                    let extract = self.extract, embedder = self.embedder, n = framesPerFile
                    group.addTask {
                        (row, await FrameIndexEngine.outcome(path: row.path, durationSeconds: row.durationSeconds, framesPerFile: n,
                                                             extract: extract, embedder: embedder, whereabouts: whereabouts))
                    }
                    running += 1
                }
                if running == 0 {
                    // Paused with nothing in hand: save, hold nothing, wait for Resume or Stop.
                    guard isPausedValue, !stopped else { break }
                    if unsaved > 0 { await save(.paused) }
                    guard failure == nil else { continue }
                    subtitleText = "Paused — \(done.formatted()) of \(planned.formatted()) done; the index is saved"
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                guard let (row, outcome) = await group.next() else { break }
                running -= 1
                await record(row, outcome)
                await checkpointIfDue()
            }
        }
    }

    private func record(_ row: CatalogRow.FrameIndexFile, _ outcome: FrameIndexFileOutcome) async {
        current.remove(row.path)
        switch outcome {
        case .indexed(let frames):
            heldFrames = await writer?.add(digest: row.digest, frames: frames) ?? heldFrames
            done += 1
            indexed += 1
            framesAdded += frames.count
            unsaved += 1
        case .unreadable(let why):
            await writer?.recordUnreadable(digest: row.digest, reason: why)
            done += 1
            unreadable += 1
            unsaved += 1
            note("could not index \(row.filename): \(why)")
        case .deferred(.stopped):
            return
        case .deferred(.modelUnavailable(let why)):
            modelFailed(why, at: row)
            return
        case .deferred(let away):
            count(away)
            note("left for the next run — \(row.filename): \(away.words)")
        }
        showProgress(after: row)
    }

    /// The model threw: no file is blamed; the pool takes no more files and the run ends FAILED (first cause wins).
    private func modelFailed(_ why: String, at row: CatalogRow.FrameIndexFile) {
        guard failure == nil else { return }
        failure = .modelUnavailable(why)
        subtitleText = "Stopping — the model is not available; saving the index…"
        note("the model (\(embedder.modelID)) is not available: \(why) — stopping at \(row.filename); "
            + "it and the files after it are left for the next run, nothing is recorded against them")
    }

    private func showProgress(after row: CatalogRow.FrameIndexFile) {
        fractionValue = planned > 0 ? Double(done) / Double(planned) : 1
        let elapsed = Date().timeIntervalSince(runStart)
        let rate = elapsed > 0 ? Double(framesAdded) / elapsed : 0
        let left = done > 0 && planned > done ? elapsed / Double(done) * Double(planned - done) : 0
        subtitleText = "\(done.formatted()) of \(planned.formatted()) · \(row.filename) · \(String(format: "%.0f", rate)) frames/s"
            + (left > 0 ? " · about \(Duration.seconds(left).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))) left" : "")
        if Date().timeIntervalSince(lastProgress) >= progressLogSeconds {
            lastProgress = Date()
            note("progress: \(done.formatted()) of \(planned.formatted()) files, \(framesAdded.formatted()) frames (\(String(format: "%.1f", rate)) frames/s), \(unreadable) unreadable, \(offline) on drives not connected")
        }
    }

    private func checkpointIfDue() async {
        guard unsaved > 0, failure == nil else { return }
        if unsaved >= checkpointFiles || Date().timeIntervalSince(lastSave) >= checkpointSeconds { await save(.checkpoint) }
    }

    /// One save, on the writer's executor. A failure is the run's terminal cause unless one is already set.
    private func save(_ point: FrameIndexSavePoint) async {
        guard let writer, unsaved > 0 || (point.writesWithNothingNew && savePoints.isEmpty && heldFrames > 0) else { return }
        do {
            let written = try await writer.save()
            savePoints.append(point)
            unsaved = 0
            lastSave = Date()
            onSaved?(written)
        } catch {
            let why = error.localizedDescription
            note("could not save the frame index (\(point.rawValue)): \(why)")
            saveProblem = why
            if failure == nil { failure = .saveFailed(at: point, why: why) }
        }
    }

    private func conclude() {
        guard state.isActive else { return }
        let elapsed = Date().timeIntervalSince(runStart)
        let rate = elapsed > 0 ? Double(framesAdded) / elapsed : 0
        let summary = "\(indexed.formatted()) file\(indexed == 1 ? "" : "s") indexed (\(framesAdded.formatted()) frames, \(String(format: "%.1f", rate)) frames/s); "
            + "\(unreadable) unreadable, \(offline) on drives not connected, \(missing) not at their path; the index holds \(heldFrames.formatted()) frames"
        let left = max(0, planned - done)
        // What is true of the disk: results taken since the last save that did not get there.
        let notOnDisk = unsaved > 0 ? " \(unsaved) result\(unsaved == 1 ? "" : "s") since the last save \(unsaved == 1 ? "is" : "are") not on disk"
            + (saveProblem.map { " (\($0))" } ?? "") + " and will be done again." : ""
        switch failure {
        case .modelUnavailable(let why):
            outcome = failure
            state = .failed(message: "The model (\(embedder.modelID)) is not available: \(why). \(left.formatted()) file\(left == 1 ? "" : "s") left for the next run, "
                + "nothing recorded against them; " + summary + "." + notOnDisk)
        case .saveFailed(let point, let why):
            outcome = failure
            state = .failed(message: "The frame index could not be saved: \(why) (\(point.rawValue)); " + summary + "." + notOnDisk)
        default:
            if stopRequested || Task.isCancelled {
                note("stopped after " + summary)
                outcome = .stopped
                state = .cancelled
            } else {
                outcome = .finished
                state = .finished(summary: summary)
            }
        }
    }
}

// MARK: - Center dispatch

extension MediaFileOperationsCenter {

    /// Start "Index frames (SigLIP 2)" over `scope`. One job at a time: a second request while one runs returns the running one.
    /// `onSaved` is given the index exactly as each save wrote it (a job already running keeps the `onSaved` it started with).
    @discardableResult
    func startFrameIndex(scope: ObservationsScope, loadFiles: @escaping FrameIndexJob.LoadFiles, embedder: any FrameEmbedding,
                         note: @escaping @MainActor (String) -> Void, onSaved: (@MainActor (FrameIndex) -> Void)?) -> FrameIndexJob {
        if let running = jobs.lazy.compactMap({ $0 as? FrameIndexJob }).first(where: { $0.state.isActive }) { return running }
        let job = FrameIndexJob(scope: scope, loadFiles: loadFiles, embedder: embedder)
        job.note = note
        job.onSaved = onSaved
        guard add(job) else {
            job.refuseToStart(reason: "Index Frames runs on the Mac that holds the catalog — this one is a viewer.")
            return job
        }
        job.start()
        return job
    }
}
