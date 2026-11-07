// FrameIndexJob.swift — "Index Frames (SigLIP 2)", the Media File Operation
// that builds the Frames search's index (docs/design/file_dossier_view.md
// §II.7 item 2). Started from the Observations window's Frames mode over
// the window's scope; shown in the MFO window with N of M, the current file,
// time left, Pause and Stop; START / progress / OUTCOME through the one sink.
//
// Per file (FrameIndexEngine.frames — the ONE engine; the smoke test drives
// it too): pick `framesPerFile` times evenly inside the clip (the captioner's
// own rule, `framesEvenlySpaced`, so a frame hit lines up with the captions'
// times), decode them through the captioner's frame door
// (`extractFramesForCaptioning`: AVFoundation, else ffmpeg — read-only on
// media), embed them with SigLIP 2's image tower, and add the rows to the
// builder under (whole-file SHA-256, time ms, model id).
//
// Shape:
//   • The plan is one catalog READ (CatalogFrameIndexReading) of the scope:
//     contents with a picture, not removed. A content already in the index
//     (or recorded as unreadable) is skipped — restart = resume.
//   • `concurrency` files decode at once (IO), the embedder serialises the
//     GPU work (an actor), so decoding overlaps inference.
//   • Not a try: a drive that is not connected, a file not at its path —
//     counted and left for the next run, never recorded. A file the decoder
//     could not read at all is recorded in the index's `failures` (with the
//     decoder's words) so a resume does not grind on it again.
//   • DURABILITY: the index is saved every `checkpointFiles` files or
//     `checkpointSeconds`, on Pause, on Stop and at the end (FrameIndexStore
//     .save: crash-safe generations). A crash loses at most one checkpoint.
//   • PAUSE takes effect between files; nothing is held while paused.
//     STOP lets the files being decoded finish, saves, ends. QUIT = Stop
//     with the decodes cut.
//
// WRITES: only the index folder (Application Support/VideoScan/observations/
// siglip2/…). Never catalog.sqlite (it is read once, through the read door),
// never media. Not a catalog writer, so no write hold applies.
//
// Memory (worst case): `concurrency` (3) files × `framesPerFile` (8) decoded
// frames in flight — 24 × 8 MB at 1080p ≈ 190 MB (4K: 24 × 33 MB ≈ 800 MB,
// released per file) — plus the builder's matrix (3 KB per frame; 160k
// frames ≈ 490 MB) and the warm model (~0.75 GB, SigLIPEmbedder.swift).
//
// (For Rick: `withTaskGroup` ≈ a fixed pool of worker threads joined at the
// end; every counter below is touched on the main actor only, so no mutex.)

import Combine
import CoreGraphics
import Foundation
import VideoScanCore
import os

private let frameIndexLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "frameIndex")

// MARK: - The one per-file engine

enum FrameIndexEngine {

    /// Decodes `timestamps` of the file at `path`; one slot per time, in order (tests inject synthetic frames).
    typealias Extract = @Sendable (_ path: String, _ timestamps: [Double]) async throws -> [(Double, CGImage?)]

    static let framesPerFile = 8

    /// The captioner's frame door: AVFoundation first, ffmpeg for what AVFoundation cannot open.
    static let productionExtract: Extract = { path, timestamps in
        let frames = try await extractFramesForCaptioning(from: URL(fileURLWithPath: path), atTimestamps: timestamps)
        return frames.map { item in
            if case .success(let image) = item.frame { return (item.timestamp, Self.thumbnail(image, maxEdge: 336)) }
            return (item.timestamp, nil)
        }
    }

    /// The times to look at: evenly inside the clip, avoiding the first and last 5% (the captioner's rule).
    static func timestamps(durationSeconds: Double, framesPerFile: Int = framesPerFile) -> [Double] {
        framesEvenlySpaced(framesPerFile: framesPerFile, durationSec: max(0.5, durationSeconds))
    }

    /// One file's frames as (time, vector). Throws when no frame decodes (the reason in words).
    static func frames(path: String, durationSeconds: Double, framesPerFile: Int = framesPerFile,
                       extract: Extract, embedder: any FrameEmbedding) async throws -> [(seconds: Double, vector: [Float])] {
        let times = timestamps(durationSeconds: durationSeconds, framesPerFile: framesPerFile)
        let decoded = try await extract(path, times).compactMap { slot -> (Double, CGImage)? in
            guard let image = slot.1 else { return nil }
            return (slot.0, image)
        }
        guard !decoded.isEmpty else { throw FrameIndexFailure.noFrame("no frame of \(times.count) could be decoded") }
        let vectors = try await embedder.embed(images: decoded.map(\.1))
        return zip(decoded, vectors).map { ($0.0, $1) }
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

enum FrameIndexFailure: LocalizedError {
    case noFrame(String)
    var errorDescription: String? { if case .noFrame(let why) = self { return why } else { return nil } }
}

// MARK: - The job

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
    /// Called after every save (the window reloads the index).
    var onSaved: (@MainActor () -> Void)?

    @Published private(set) var state: MediaFileOperationState = .running {
        didSet { if !state.isActive, finishedAt == nil { finishedAt = Date() } }
    }
    @Published private(set) var finishedAt: Date?
    @Published private(set) var subtitleText = "Reading the catalog…"
    @Published private(set) var fractionValue: Double = 0
    @Published private(set) var isPausedValue = false
    private(set) var wasRefused = false
    private(set) var task: Task<Void, Never>?

    // Counters (main actor only).
    private(set) var planned = 0
    private(set) var done = 0
    private(set) var indexed = 0
    private(set) var framesAdded = 0
    private(set) var unreadable = 0
    private(set) var offline = 0
    private(set) var missing = 0
    private(set) var alreadyDone = 0
    private(set) var saves = 0
    private var builder: FrameIndexBuilder?
    private var stopRequested = false
    private var unsaved = 0
    private var lastSave = Date()
    private var lastProgress = Date()
    private var runStart = Date()
    private var current: Set<String> = []
    private var pending: ArraySlice<CatalogRow.FrameIndexFile> = []

    /// The next file to decode; a file on a drive that is not connected, or not at its path, is counted and skipped (not a try).
    private func nextRow() -> CatalogRow.FrameIndexFile? {
        while let row = pending.popFirst() {
            if !volumeOnline(row.path) { offline += 1; done += 1; continue }
            if !fileExists(row.path) { missing += 1; done += 1; continue }
            current.insert(row.path)
            return row
        }
        return nil
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

    private var stopped: Bool { stopRequested || Task.isCancelled || !state.isActive }

    // MARK: Run

    private func run() async {
        let rows: [CatalogRow.FrameIndexFile]
        do {
            rows = try await loadFiles(scope)
        } catch {
            wasRefused = true
            note("refused — the catalog could not be read (\(error.localizedDescription)). Nothing was read or written.")
            state = .failed(message: "Refused — the catalog could not be read: \(error.localizedDescription)")
            return
        }
        let model = embedder.modelID
        let existing = FrameIndexStore.load(root: root, model: model)
        if case .unreadable(let why) = existing {
            note("the index on disk could not be read (\(why)) — starting a new one beside the catalog; nothing in the catalog changes")
        }
        let b = FrameIndexBuilder(model: model, dims: embedder.dims, seed: existing.index)
        let plan = Self.plan(rows, done: b)
        alreadyDone = plan.alreadyDone
        let todo = plan.todo, noPicture = plan.noPicture
        builder = b
        planned = todo.count
        let startLine = MediaFileOperationsCenter.startSummaryLine(
            verb: kind.logVerb, title: title,
            plan: "\(todo.count.formatted()) file\(todo.count == 1 ? "" : "s") to index, \(framesPerFile) frames each with \(model) "
                + "(\(alreadyDone.formatted()) already indexed, \(noPicture.formatted()) without a picture) → \(FrameIndexStore.directory(root: root, model: model).path)")
        note(startLine)
        frameIndexLog.info("\(startLine, privacy: .public)")
        runStart = Date(); lastSave = Date(); lastProgress = Date()
        subtitleText = todo.isEmpty ? "Nothing to index" : "Loading SigLIP 2…"

        pending = todo[...]
        await drain()
        save(reason: stopped ? "stopped" : "finished")
        conclude()
    }

    /// What a run must do: the contents with a picture, not removed, not already in the index (a pure plan).
    static func plan(_ rows: [CatalogRow.FrameIndexFile], done: FrameIndexBuilder)
        -> (todo: [CatalogRow.FrameIndexFile], alreadyDone: Int, noPicture: Int) {
        var todo: [CatalogRow.FrameIndexFile] = []
        var already = 0, noPicture = 0
        for row in rows {
            if !row.hasVideo || row.removed { noPicture += 1 } else if done.isDone(row.digest) { already += 1 } else { todo.append(row) }
        }
        return (todo, already, noPicture)
    }

    /// The worker pool over `pending`: `concurrency` files in flight, Pause between files, Stop drains.
    private func drain() async {
        await withTaskGroup(of: (CatalogRow.FrameIndexFile, Result<[(seconds: Double, vector: [Float])], Error>).self) { group in
            var running = 0
            while true {
                // Fill the pool (the closure runs on the main actor: withTaskGroup inherits the caller's isolation).
                while running < concurrency, !stopped, !isPausedValue, let row = nextRow() {
                    let extract = self.extract, embedder = self.embedder, n = framesPerFile
                    group.addTask {
                        do {
                            return (row, .success(try await FrameIndexEngine.frames(path: row.path, durationSeconds: row.durationSeconds,
                                                                                    framesPerFile: n, extract: extract, embedder: embedder)))
                        } catch {
                            return (row, .failure(error))
                        }
                    }
                    running += 1
                }
                if running == 0 {
                    // Paused with nothing in hand: save, hold nothing, wait for Resume or Stop.
                    guard isPausedValue, !stopped else { break }
                    if unsaved > 0 { save(reason: "paused") }
                    subtitleText = "Paused — \(done.formatted()) of \(planned.formatted()) done; the index is saved"
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                guard let (row, result) = await group.next() else { break }
                running -= 1
                record(row, result)
                await checkpointIfDue()
            }
        }
    }

    private func record(_ row: CatalogRow.FrameIndexFile, _ result: Result<[(seconds: Double, vector: [Float])], Error>) {
        current.remove(row.path)
        done += 1
        switch result {
        case .success(let frames):
            builder?.add(digest: row.digest, frames: frames)
            indexed += 1
            framesAdded += frames.count
            unsaved += 1
        case .failure(let error):
            if error is CancellationError || Task.isCancelled { done -= 1; return }
            let why = error.localizedDescription
            builder?.fail(digest: row.digest, reason: why)
            unreadable += 1
            unsaved += 1
            note("could not index \(row.filename): \(why)")
        }
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
        guard unsaved > 0 else { return }
        if unsaved >= checkpointFiles || Date().timeIntervalSince(lastSave) >= checkpointSeconds { save(reason: "checkpoint") }
    }

    private func save(reason: String) {
        guard let builder, unsaved > 0 || (reason == "finished" && saves == 0 && builder.frameCount > 0) else { return }
        do {
            try FrameIndexStore.save(builder.snapshot(), root: root)
            saves += 1
            unsaved = 0
            lastSave = Date()
            onSaved?()
        } catch {
            note("could not save the frame index (\(reason)): \(error.localizedDescription)")
            if state.isActive { state = .failed(message: "The frame index could not be saved: \(error.localizedDescription)") }
        }
    }

    private func conclude() {
        guard state.isActive else { return }
        let elapsed = Date().timeIntervalSince(runStart)
        let rate = elapsed > 0 ? Double(framesAdded) / elapsed : 0
        let total = builder?.frameCount ?? 0
        let summary = "\(indexed.formatted()) file\(indexed == 1 ? "" : "s") indexed (\(framesAdded.formatted()) frames, \(String(format: "%.1f", rate)) frames/s); "
            + "\(unreadable) unreadable, \(offline) on drives not connected, \(missing) not at their path; the index holds \(total.formatted()) frames"
        if stopRequested || Task.isCancelled {
            note("stopped after " + summary)
            state = .cancelled
        } else {
            state = .finished(summary: summary)
        }
    }
}

// MARK: - Center dispatch

extension MediaFileOperationsCenter {

    /// Start "Index frames (SigLIP 2)" over `scope`. One job at a time: a second request while one runs returns the running one.
    @discardableResult
    func startFrameIndex(scope: ObservationsScope, loadFiles: @escaping FrameIndexJob.LoadFiles, embedder: any FrameEmbedding,
                         note: @escaping @MainActor (String) -> Void, onSaved: (@MainActor () -> Void)?) -> FrameIndexJob {
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
