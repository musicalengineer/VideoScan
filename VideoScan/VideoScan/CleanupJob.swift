import Combine
import Foundation
import os

// MARK: - CleanupJob
//
// "Clean Up Video" — Rick 2026-07-07. Applies a named CleanupRecipe (v1:
// "VHS Quick Clean") to one catalog record and writes the result NEXT TO
// THE ORIGINAL as `<stem>_cleaned.mov` (ProRes 422 LT, audio copied).
// The original is NEVER modified — the whole pipeline only reads it.
//
// Division of labor (see CleanupEngine.swift in VideoScanCore for the
// seam rationale):
//   - the ENGINE renders into a scratch directory (RAM disk if it fits,
//     system temp otherwise) and knows nothing about destinations;
//   - THIS JOB owns output naming + collision uniquify, the atomic
//     publish next to the original, catalog registration, and the
//     provenance stamp (derivedFrom + cleanupRecipeID/Version).
//
// Atomic output: the scratch render is copied to a `.vs-partial` sibling
// of the final name (same directory ⇒ same volume), then promoted with
// ReformatJob.atomicPublish's single rename. A crash/cancel at any point
// leaves either nothing or a clearly-named partial — never a
// half-written `<stem>_cleaned.mov`.
//
// Memory / scratch sizing: ffmpeg streams (no media buffered in-process;
// worst case in RAM here is a ~200-byte progress line). The scratch FILE
// can be large — ProRes LT of a 2 h SD tape is ~25-30 GB — so the RAM
// disk is only used when `estimatedOutputBytes` fits in 60% of the
// configured RAM-disk size; otherwise scratch falls back to the system
// temp directory (SSD). Worst-case RAM footprint is therefore bounded by
// perfSettings.ramDiskGB, and only when the estimate says it fits.
//
// Stall watchdog: same StallMonitor contract as Reformat/Transcode —
// silence on ffmpeg's progress stream past the threshold kills the child
// and fails with volume-drop attribution instead of hanging.

private let cleanupLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                category: "cleanup")

@MainActor
final class CleanupJob: MediaFileOperationJob {

    let id = UUID()
    let kind: MediaFileOperationKind = .cleanup
    let startedAt = Date()

    /// Source record being cleaned. READ ONLY on disk.
    let record: VideoRecord

    /// The recipe this job applies (id+version become provenance).
    let recipe: CleanupRecipe

    /// Final destination — `<stem>_cleaned.mov` beside the original,
    /// uniquified (`<stem>_cleaned 2.mov`, …) if the name is taken.
    /// Computed once at init so the sheet can display it.
    let outputURL: URL

    /// The rendering engine. v1 always the ffmpeg filtergraph engine;
    /// injectable so tests can stub and future dispatchers can route.
    private let engine: any CleanupRecipeEngine

    /// Weak — the model owns jobs via MediaFileOperationsCenter.
    private weak var model: VideoScanModel?

    /// No pause: same reasoning as Reformat/Transcode (no clean
    /// suspend/resume contract through ffmpeg's subprocess state).
    let canPause = false

    @Published private(set) var state: MediaFileOperationState = .running
    @Published private(set) var subtitleText: String
    @Published private(set) var fractionValue: Double = 0
    @Published private(set) var isIndeterminateValue: Bool = true

    /// The run Task — internal so tests can `await job.task?.value`.
    private(set) var task: Task<Void, Never>?

    /// Set by the stall watchdog; wins over the generic cancel branch
    /// (the watchdog cancels the Task, which also trips Task.isCancelled).
    private var stallReason: String?

    var title: String { record.filename }
    var subtitle: String { subtitleText }
    var fraction: Double { fractionValue }
    var isIndeterminate: Bool { isIndeterminateValue }

    // MARK: Init / start

    init(record: VideoRecord,
         recipe: CleanupRecipe,
         model: VideoScanModel,
         engine: any CleanupRecipeEngine = CleanupFFmpegEngine()) {
        self.record = record
        self.recipe = recipe
        self.model = model
        self.engine = engine
        self.subtitleText = "Preparing \(recipe.displayName)…"
        self.outputURL = Self.cleanedOutputURL(forSourcePath: record.fullPath)
    }

    /// Start the cleanup. Idempotent — a second call is a no-op.
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            await self.runCleanup()
        }
    }

    /// Cancel the in-flight render. Task.cancel propagates through the
    /// engine into ProcessRunner, which terminates the ffmpeg child.
    func cancel() {
        guard state.isActive else { return }
        state = .cancelling
        subtitleText = "Cancelling…"
        task?.cancel()
    }

    // MARK: Run

    private func runCleanup() async {
        let inputPath = record.fullPath
        let volumeLabel = VolumeReachability.displayLabel(forPath: inputPath)
        cleanupLog.info("cleanup START: \(self.record.filename, privacy: .public) recipe=\(self.recipe.id, privacy: .public) v\(self.recipe.version, privacy: .public) on \(volumeLabel, privacy: .public) → \(self.outputURL.lastPathComponent, privacy: .public)")
        appLog.write("cleanup: \(record.filename) — \(recipe.displayName) (\(recipe.id) v\(recipe.version)) → \(outputURL.lastPathComponent)")

        guard FileManager.default.fileExists(atPath: inputPath) else {
            finish(failed: "Source file missing on disk")
            return
        }
        guard engine.canExecute(recipe) else {
            finish(failed: "Recipe \(recipe.displayName) has steps the \(engine.engineID) engine can't run")
            return
        }

        // Engine input, built ONLY from the record's existing ffprobe
        // metadata (no re-probe).
        let source = CleanupSource(
            path: inputPath,
            durationSeconds: max(0, record.durationSeconds),
            fieldOrder: record.scanType,
            hasAudio: record.streamType == .videoAndAudio || record.streamType == .audioOnly
        )

        // ---- Scratch: RAM disk when the estimate fits, temp dir otherwise.
        let estimate = Self.estimatedOutputBytes(
            durationSeconds: source.durationSeconds,
            resolution: record.resolution)
        let (scratchBase, usedRAMDisk) = await acquireScratch(estimateBytes: estimate)
        let scratchDir = scratchBase.appendingPathComponent("VS_Cleanup_\(id.uuidString)")
        do {
            try FileManager.default.createDirectory(at: scratchDir,
                                                    withIntermediateDirectories: true)
        } catch {
            if usedRAMDisk { await model?.ramDisk.unmount() }
            finish(failed: "Could not create scratch directory: \(error.localizedDescription)")
            return
        }
        cleanupLog.info("cleanup scratch: \(scratchDir.path, privacy: .public) (ramDisk=\(usedRAMDisk, privacy: .public), estimate=\(estimate, privacy: .public) bytes)")

        // Everything from here on must release the scratch dir + RAM disk.
        defer {
            try? FileManager.default.removeItem(at: scratchDir)
            if usedRAMDisk {
                let disk = model?.ramDisk
                Task { await disk?.unmount() }
            }
        }

        subtitleText = "Cleaning up — \(recipe.displayName)…"
        isIndeterminateValue = (source.durationSeconds == 0)

        // Stall watchdog: every engine progress beat kicks it.
        let monitor = StallMonitor(label: "cleanup \(record.filename)") { [weak self] silentFor in
            Task { @MainActor [weak self] in
                self?.handleStall(silentFor: silentFor)
            }
        }
        let progressSink: @Sendable (CleanupProgress) -> Void = { [weak self] beat in
            monitor.tick()
            guard let self else { return }
            Task { @MainActor in
                if let fraction = beat.fraction {
                    self.fractionValue = fraction
                    self.isIndeterminateValue = false
                }
            }
        }

        // ---- Render (fully off-main — see renderOffMain).
        let renderStart = Date()
        monitor.start()
        let rendered: URL
        do {
            rendered = try await Self.renderOffMain(engine: engine,
                                                    recipe: recipe,
                                                    source: source,
                                                    scratchDirectory: scratchDir,
                                                    progress: progressSink)
        } catch {
            monitor.stop()
            if let stallReason {
                cleanupLog.error("cleanup FAILED (stall): \(self.record.filename, privacy: .public) — \(stallReason, privacy: .public)")
                finish(failed: stallReason)
            } else if error is CancellationError || Task.isCancelled || state == .cancelling {
                cleanupLog.info("cleanup cancelled: \(self.record.filename, privacy: .public)")
                finish(cancelled: true)
            } else {
                finish(failed: Self.describe(error))
            }
            return
        }
        monitor.stop()
        let renderElapsed = Date().timeIntervalSince(renderStart)

        if let stallReason {
            finish(failed: stallReason)
            return
        }
        if Task.isCancelled || state == .cancelling {
            finish(cancelled: true)
            return
        }

        // ---- Atomic publish: scratch → same-volume partial → rename.
        subtitleText = "Moving cleaned copy next to the original…"
        isIndeterminateValue = true
        let partialPath = ReformatJob.partialURL(for: outputURL).path
        do {
            try? FileManager.default.removeItem(atPath: partialPath)
            // Cross-volume copy (RAM disk / tmp → the original's volume)…
            try FileManager.default.copyItem(atPath: rendered.path, toPath: partialPath)
            // …then a same-volume metadata-only rename: atomic.
            try ReformatJob.atomicPublish(from: partialPath, to: outputURL.path)
        } catch {
            try? FileManager.default.removeItem(atPath: partialPath)
            finish(failed: "Could not place the cleaned copy: \(error.localizedDescription)")
            return
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0

        // ---- Catalog + provenance.
        await catalogCleanupOutput()

        cleanupLog.info("cleanup DONE: \(self.record.filename, privacy: .public) → \(self.outputURL.lastPathComponent, privacy: .public) (\(Self.humanBytes(size), privacy: .public)) render \(renderElapsed, format: .fixed(precision: 1), privacy: .public)s")
        appLog.write("cleanup done: \(outputURL.lastPathComponent) (\(Self.humanBytes(size))) — original untouched")
        finish(success: "Cleaned → \(outputURL.lastPathComponent) (\(Self.humanBytes(size))). Original untouched.")
    }

    // MARK: Off-main render hop
    //
    // This repo's Approachable Concurrency configuration makes
    // `nonisolated async` run on the CALLER's actor — calling the engine
    // straight from this @MainActor job would run its body on main (the
    // documented 14.5 h-crawl trap). `@concurrent` forces the global
    // executor; the engine's own `nonisolated(nonsending)` render then
    // inherits THAT context, so argument building + subprocess supervision
    // stay off-main and only the progress beats hop back.
    // #if guard: the nightly CI's older Xcode (Swift 6.1) knows
    // `@concurrent` only as a deprecated alias and warns; pre-6.2 a
    // nonisolated async static already runs off-actor. Same idiom as
    // CorrelationScorer+Snaps.
    #if compiler(>=6.2)
    @concurrent
    #endif
    private static func renderOffMain(
        engine: any CleanupRecipeEngine,
        recipe: CleanupRecipe,
        source: CleanupSource,
        scratchDirectory: URL,
        progress: @escaping @Sendable (CleanupProgress) -> Void
    ) async throws -> URL {
        try await engine.render(recipe: recipe,
                                source: source,
                                scratchDirectory: scratchDirectory,
                                progress: progress)
    }

    // MARK: Scratch acquisition

    /// RAM disk when the estimated render fits comfortably (≤ 60% of the
    /// configured size), system temp otherwise. Mount is refcounted
    /// (model.ramDisk) — a concurrent combine/scan sharing the disk is
    /// safe, and our unmount only ejects when we're the last user. We
    /// deliberately do NOT call RAMDisk.cleanupStaleMounts() here — it
    /// force-detaches EVERY VideoScan_Temp* mount, including one another
    /// operation is actively using.
    private func acquireScratch(estimateBytes: Int64) async -> (base: URL, usedRAMDisk: Bool) {
        guard let model else {
            return (FileManager.default.temporaryDirectory, false)
        }
        let capacityBytes = Int64(model.perfSettings.ramDiskGB) * 1_073_741_824
        guard estimateBytes > 0, estimateBytes <= (capacityBytes * 6) / 10 else {
            cleanupLog.info("cleanup scratch: estimate \(estimateBytes, privacy: .public) B exceeds RAM budget — using system temp")
            return (FileManager.default.temporaryDirectory, false)
        }
        let mounted = await model.ramDisk.mount(sizeMB: model.perfSettings.ramDiskGB * 1024)
        if mounted, let mp = await model.ramDisk.mountPoint {
            return (URL(fileURLWithPath: mp), true)
        }
        return (FileManager.default.temporaryDirectory, false)
    }

    /// Rough ProRes 422 LT output size: ~1.7 bits/pixel/frame at a
    /// worst-case 60 frames/s (send_field doubles 29.97i to 59.94p),
    /// plus PCM-ish audio headroom. Floor of 4 MB/s so tiny resolutions
    /// don't under-budget. Pure — unit-tested against sane bounds.
    nonisolated static func estimatedOutputBytes(durationSeconds: Double,
                                                 resolution: String) -> Int64 {
        let dims = resolution.lowercased()
            .split(separator: "x")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let pixels = dims.count == 2 ? dims[0] * dims[1] : 720 * 576
        let bytesPerSecond = max(Double(pixels) * 60.0 * 1.7 / 8.0 + 300_000, 4_000_000)
        return Int64(max(0, durationSeconds) * bytesPerSecond)
    }

    // MARK: Output naming

    /// `<stem>_cleaned.mov` beside the original; on collision, Finder-style
    /// counters: `<stem>_cleaned 2.mov`, `<stem>_cleaned 3.mov`, …
    /// `fileExists` is injected so the uniquify loop is pure-testable.
    nonisolated static func cleanedOutputURL(
        forSourcePath path: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL {
        let src = URL(fileURLWithPath: path)
        let dir = src.deletingLastPathComponent()
        let stem = src.deletingPathExtension().lastPathComponent
        var candidate = dir.appendingPathComponent("\(stem)_cleaned.mov")
        var n = 2
        while fileExists(candidate.path) {
            candidate = dir.appendingPathComponent("\(stem)_cleaned \(n).mov")
            n += 1
        }
        return candidate
    }

    // MARK: Stall handling

    private func handleStall(silentFor: Double) {
        guard state.isActive, stallReason == nil else { return }
        let attribution = StallMonitor.attribution(forPaths: [record.fullPath, outputURL.path])
        let reason = "Stalled — no ffmpeg progress for \(Int(silentFor))s during cleanup. \(attribution)"
        stallReason = reason
        subtitleText = "Stalled — stopping…"
        cleanupLog.error("cleanup WATCHDOG: killing \(self.record.filename, privacy: .public) — \(reason, privacy: .public)")
        appLog.write("cleanup watchdog: \(record.filename) stalled \(Int(silentFor))s — \(attribution); killing ffmpeg")
        task?.cancel()
    }

    // MARK: Catalog + provenance

    /// Probe the cleaned file and append it to the catalog with full
    /// provenance: `derivedFrom` = source record id, plus the recipe
    /// id+version — and File Journey notes on BOTH records (the same
    /// convention Reformat/Transcode established).
    private func catalogCleanupOutput() async {
        guard let model else { return }
        let newURL = outputURL
        let newRec = await model.probeFile(url: newURL)

        newRec.derivedFrom = record.id
        newRec.cleanupRecipeID = recipe.id
        newRec.cleanupRecipeVersion = recipe.version

        let stamp = ISO8601DateFormatter().string(from: Date())
        let sourceNote = "Cleanup \(stamp): Created cleaned copy \(newURL.lastPathComponent) with \(recipe.displayName) (\(recipe.id) v\(recipe.version))"
        let derivedNote = "Cleanup \(stamp): Cleaned from \(record.filename) with \(recipe.displayName) (\(recipe.id) v\(recipe.version))"

        record.notes = record.notes.isEmpty
            ? sourceNote
            : "\(record.notes)\n\(sourceNote)"
        newRec.notes = newRec.notes.isEmpty
            ? derivedNote
            : "\(newRec.notes)\n\(derivedNote)"

        if let existing = model.records.firstIndex(where: { $0.fullPath == newURL.path }) {
            model.records[existing] = newRec
        } else {
            model.records.append(newRec)
        }
        cleanupLog.info("cleanup: catalogued \(newURL.lastPathComponent, privacy: .public) (derivedFrom=\(self.record.id.uuidString, privacy: .public), recipe=\(self.recipe.id, privacy: .public) v\(self.recipe.version, privacy: .public))")
    }

    // MARK: Finish helpers

    private func finish(success: String) {
        state = .finished(summary: success)
        subtitleText = success
        fractionValue = 1.0
        isIndeterminateValue = false
    }

    private func finish(failed: String) {
        state = .failed(message: failed)
        subtitleText = failed
        isIndeterminateValue = false
        cleanupLog.warning("cleanup failed: \(failed, privacy: .public)")
    }

    private func finish(cancelled: Bool) {
        state = .cancelled
        subtitleText = "Cancelled"
        isIndeterminateValue = false
    }

    /// Friendly failure text for the engine's typed errors.
    nonisolated private static func describe(_ error: Error) -> String {
        switch error {
        case CleanupEngineError.toolUnavailable(let detail):
            return detail
        case CleanupEngineError.unsupportedStep(let kind):
            return "This recipe includes a step (\(kind.rawValue)) the current engine can't run"
        case CleanupEngineError.renderFailed(let detail):
            return detail
        default:
            return error.localizedDescription
        }
    }

    private static func humanBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}
