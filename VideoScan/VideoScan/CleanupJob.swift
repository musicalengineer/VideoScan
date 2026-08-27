import Combine
import Foundation
import os

// MARK: - CleanupJob
//
// "Clean Up Video" — Rick 2026-07-07 (QA remediation pass same day).
// Applies a named CleanupRecipe (v1: "VHS Quick Clean") to one catalog
// record and writes the result NEXT TO THE ORIGINAL as
// `<stem>_cleaned.mov` (ProRes 422 LT; audio copied when playback-safe,
// modernized to PCM otherwise — see CleanupFFmpegEngine's allowlist).
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
// Atomic, NON-CLOBBERING output (B1+M3, QA 2026-07-07): the scratch
// render is copied — in 8 MB chunks, off the main actor, cancellable,
// with byte progress driving the bar AND the stall watchdog — to a
// `.vs-partial` sibling of the final name (same directory ⇒ same
// volume), then promoted with a rename that FAILS if the destination
// exists. The destination name is re-uniquified at publish time (the
// init-time name is only a plan — a multi-hour render is a wide TOCTOU
// window), so a cleanup can never overwrite an existing file, its own
// planned name included. A crash/cancel at any point leaves either
// nothing or a clearly-named partial — never a half-written
// `<stem>_cleaned.mov`. (The scan walker skips `.vs-partial.` files, so
// a concurrent scan can't catalog the transient copy.)
//
// Memory / scratch sizing: ffmpeg streams, and the publish copy holds at
// most ONE 8 MB chunk in flight (released per iteration via
// autoreleasepool) — worst case in-process RAM is ~8 MB + progress
// lines. The scratch FILE can be large — ProRes LT of a 2 h SD tape is
// ~25-30 GB — so the RAM disk is only used when `estimatedOutputBytes`
// fits in 60% of the configured RAM-disk size; otherwise scratch falls
// back to the system temp directory (SSD). Worst-case RAM footprint is
// therefore bounded by perfSettings.ramDiskGB, and only when the
// estimate says it fits.
//
// Stall watchdog: same StallMonitor contract as Reformat/Transcode —
// silence on ffmpeg's progress stream OR the publish copy's byte
// progress past the threshold kills the job with volume-drop
// attribution instead of hanging (a destination-volume drop mid-copy
// must fail loudly, not wedge).

private let cleanupLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                category: "cleanup")

@MainActor
final class CleanupJob: @MainActor MediaFileOperationJob {

    let id = UUID()
    let kind: MediaFileOperationKind = .cleanup
    let startedAt = Date()

    /// Source record being cleaned. READ ONLY on disk.
    let record: VideoRecord

    /// The recipe this job applies (id+version become provenance).
    let recipe: CleanupRecipe

    /// PLANNED destination — `<stem>_cleaned.mov` beside the original,
    /// uniquified against files existing at init. Shared with the sheet
    /// via CleanupRequest (m3) so the UI never promises a name the job
    /// doesn't plan to use. The publish step re-uniquifies (M3), so the
    /// ACTUAL destination can differ when a collision appears mid-render
    /// — see `publishedURL`.
    let outputURL: URL

    /// Where the cleaned copy actually landed. nil until publish
    /// succeeds. Equals `outputURL` unless a publish-time collision
    /// forced a bump.
    private(set) var publishedURL: URL?

    /// The rendering engine. v1 always the ffmpeg filtergraph engine;
    /// injectable so tests can stub and future dispatchers can route.
    private let engine: any CleanupRecipeEngine

    /// Weak — the model owns jobs via MediaFileOperationsCenter.
    private weak var model: VideoScanModel?

    /// No pause: same reasoning as Reformat/Transcode (no clean
    /// suspend/resume contract through ffmpeg's subprocess state).
    let canPause = false

    @Published private(set) var state: MediaFileOperationState = .running {
        didSet {
            if !state.isActive, finishedAt == nil { finishedAt = Date() }
        }
    }
    /// Terminal-transition stamp — freezes the row clock (see
    /// MediaFileOperationClock). Set exactly once by state's didSet.
    @Published private(set) var finishedAt: Date?
    @Published private(set) var subtitleText: String
    @Published private(set) var fractionValue: Double = 0
    @Published private(set) var isIndeterminateValue: Bool = true

    /// The run Task — internal so tests can `await job.task?.value`.
    private(set) var task: Task<Void, Never>?

    /// Set by the stall watchdog; wins over the generic cancel branch
    /// (the watchdog cancels the Task, which also trips Task.isCancelled).
    /// Set-once ledger of the first terminal cause (watchdog stall vs the
    /// user's Stop) — see MFOTerminalCause. `stallReason` reads through it.
    private var terminalCause = MFOTerminalCause()
    private var stallReason: String? { terminalCause.stallReason }

    var title: String { record.filename }
    var subtitle: String { subtitleText }
    var fraction: Double { fractionValue }
    var isIndeterminate: Bool { isIndeterminateValue }

    // MARK: Init / start

    /// `plannedOutput` lets the confirmation sheet hand over the exact
    /// destination it displayed (computed once in CleanupRequest — m3).
    /// nil (programmatic callers, tests) computes it here.
    init(record: VideoRecord,
         recipe: CleanupRecipe,
         model: VideoScanModel,
         engine: any CleanupRecipeEngine = CleanupFFmpegEngine(),
         plannedOutput: URL? = nil) {
        self.record = record
        self.recipe = recipe
        self.model = model
        self.engine = engine
        self.subtitleText = "Preparing \(recipe.displayName)…"
        self.outputURL = plannedOutput
            ?? Self.cleanedOutputURL(forSourcePath: record.fullPath)
    }

    /// Start the cleanup. Idempotent — a second call is a no-op.
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            await self.runCleanup()
        }
    }

    /// Cancel the in-flight render/copy. Task.cancel propagates through
    /// the engine into ProcessRunner (killing the ffmpeg child) and into
    /// the publish copy's per-chunk checkCancellation.
    func cancel() {
        guard state.isActive else { return }
        // A stall recorded first owns the terminal (codex gate 2026-08-26):
        // the watchdog is already killing the Task, the row keeps
        // "Stalled — stopping…" and ends Failed with the stall reason —
        // never Cancelled. Otherwise the user's Stop is the first cause.
        if terminalCause.record(.cancel) {
            state = .cancelling
            subtitleText = "Cancelling…"
        }
        task?.cancel()
    }

    // MARK: Run

    private func runCleanup() async {
        let inputPath = record.fullPath
        let volumeLabel = VolumeReachability.displayLabel(forPath: inputPath)
        // (videoscan.log START line is written by the Center's
        // startCleanup — one choke point for every MFO verb.)
        cleanupLog.info("cleanup START: \(self.record.filename, privacy: .public) recipe=\(self.recipe.id, privacy: .public) v\(self.recipe.version, privacy: .public) on \(volumeLabel, privacy: .public) → \(self.outputURL.lastPathComponent, privacy: .public)")

        // Loud early guard (QA note): the menu already gates on a video
        // stream, but programmatic callers must not slip an audio-only /
        // unknown record into a video pipeline.
        guard record.streamType == .videoAndAudio || record.streamType == .videoOnly else {
            finish(failed: "Clean Up Video needs a video stream — \(record.filename) has none (\(record.streamTypeRaw.isEmpty ? "unknown streams" : record.streamTypeRaw))")
            return
        }
        guard FileManager.default.fileExists(atPath: inputPath) else {
            finish(failed: "Source file missing on disk")
            return
        }
        guard engine.canExecute(recipe) else {
            finish(failed: "Recipe \(recipe.displayName) has steps the \(engine.engineID) engine can't run")
            return
        }

        // Engine input, built ONLY from the record's existing ffprobe
        // metadata (no re-probe). hasAudio is videoAndAudio only — the
        // audio-only case was rejected above.
        let source = CleanupSource(
            path: inputPath,
            durationSeconds: max(0, record.durationSeconds),
            fieldOrder: record.scanType,
            hasAudio: record.streamType == .videoAndAudio,
            audioCodec: record.audioCodec
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

        // Stall watchdog: armed across BOTH long phases — the ffmpeg
        // render and the publish copy (B1). Every progress beat of either
        // phase kicks it.
        let monitor = StallMonitor(label: "cleanup \(record.filename)") { [weak self] silentFor in
            Task { @MainActor [weak self] in
                self?.handleStall(silentFor: silentFor)
            }
        }
        let progressSink: @Sendable (CleanupProgress) -> Void = { [weak self] beat in
            monitor.tick()
            guard let self, let fraction = beat.fraction else { return }
            Task { @MainActor in
                self.applyProgressFraction(fraction)
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
            failOrCancel(error, phase: "render")
            return
        }
        let renderElapsed = Date().timeIntervalSince(renderStart)

        if let stallReason {
            monitor.stop()
            finish(failed: stallReason)
            return
        }
        if Task.isCancelled || state == .cancelling {
            monitor.stop()
            finishCancelled()
            return
        }

        // ---- Publish (B1+M3): chunked off-main copy to a same-volume
        // partial, then a NON-CLOBBERING rename at a freshly-uniquified
        // name. Byte progress restarts the bar for this phase (a 30 GB
        // copy onto an HDD easily exceeds the 15-30 s progress rule) and
        // keeps the watchdog fed.
        subtitleText = "Moving cleaned copy next to the original…"
        fractionValue = 0
        isIndeterminateValue = false
        let copyProgress: @Sendable (Double) -> Void = { [weak self] fraction in
            monitor.tick()
            guard let self else { return }
            Task { @MainActor in
                self.applyProgressFraction(fraction)
            }
        }
        let published: URL
        do {
            published = try await Self.publishOffMain(renderedPath: rendered.path,
                                                      sourcePath: inputPath,
                                                      preferredOutput: outputURL,
                                                      progress: copyProgress)
        } catch {
            monitor.stop()
            failOrCancel(error, phase: "publish")
            return
        }
        monitor.stop()
        publishedURL = published

        if let stallReason {
            finish(failed: stallReason)
            return
        }
        if Task.isCancelled || state == .cancelling {
            // The publish completed before the cancel landed — the file
            // is whole and correctly named; leave it, report cancelled.
            finishCancelled()
            return
        }
        if published != outputURL {
            cleanupLog.notice("cleanup publish: planned name \(self.outputURL.lastPathComponent, privacy: .public) was taken mid-render — published as \(published.lastPathComponent, privacy: .public)")
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: published.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0

        // ---- Catalog + provenance + persistence.
        await catalogCleanupOutput(publishedURL: published)

        cleanupLog.info("cleanup DONE: \(self.record.filename, privacy: .public) → \(published.lastPathComponent, privacy: .public) (\(Self.humanBytes(size), privacy: .public)) render \(renderElapsed, format: .fixed(precision: 1), privacy: .public)s")
        // (The Center's "cleanup done:" OUTCOME line carries this same
        // summary — no separate appLog write here.)
        finish(success: "Cleaned → \(published.lastPathComponent) (\(Self.humanBytes(size))). Original untouched.")
    }

    /// Shared error terminal for the two long phases: watchdog stall wins
    /// (specific reason), then user cancel, then the described failure.
    private func failOrCancel(_ error: Error, phase: String) {
        if let stallReason {
            cleanupLog.error("cleanup FAILED (stall, \(phase, privacy: .public)): \(self.record.filename, privacy: .public) — \(stallReason, privacy: .public)")
            finish(failed: stallReason)
        } else if error is CancellationError || Task.isCancelled || state == .cancelling {
            cleanupLog.info("cleanup cancelled (\(phase, privacy: .public)): \(self.record.filename, privacy: .public)")
            finishCancelled()
        } else {
            finish(failed: Self.describe(error))
        }
    }

    /// m2: single, state-guarded write path for progress fractions. Beats
    /// arrive via unstructured Tasks and can land AFTER the job reached a
    /// terminal state — a straggler must never drag a finished bar back
    /// below 1.0. Internal so tests can pin the guard.
    func applyProgressFraction(_ fraction: Double) {
        guard state.isActive else { return }
        fractionValue = fraction
        isIndeterminateValue = false
    }

    // MARK: Off-main hops
    //
    // This repo's Approachable Concurrency configuration makes
    // `nonisolated async` run on the CALLER's actor — calling the engine
    // (or a 30 GB file copy!) straight from this @MainActor job would run
    // on main (the documented 14.5 h-crawl trap). `@concurrent` forces
    // the global executor; nested `nonisolated(nonsending)` calls inherit
    // THAT context, so subprocess supervision and the copy loop stay
    // off-main and only the progress beats hop back.
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

    // MARK: Publish (B1 + M3)

    /// Copy the finished render next to the original and promote it —
    /// entirely off the main actor.
    ///
    ///   1. Re-uniquify the destination NOW (M3): the name planned at
    ///      init/sheet time is stale after a long render. The preferred
    ///      name is kept when still free so the sheet's promise holds in
    ///      the common case. A name whose `.vs-partial` sibling exists is
    ///      treated as taken (another job is mid-publish on it).
    ///   2. Chunked copy scratch → `.vs-partial` sibling of the candidate
    ///      (cross-volume; 8 MB chunks; per-chunk cancellation; byte
    ///      progress feeds the bar + watchdog).
    ///   3. NON-CLOBBERING promote: FileManager.moveItem FAILS if the
    ///      destination exists — it never deletes. If a collision raced
    ///      in anyway, re-uniquify and retry the (same-volume, instant)
    ///      rename; the copy is not redone. Cleanup deliberately does NOT
    ///      use ReformatJob.atomicPublish — that helper replaces an
    ///      existing destination, which is correct for Reformat's
    ///      timestamped names and wrong here.
    ///
    /// Returns the URL the file actually landed at.
    #if compiler(>=6.2)
    @concurrent
    #endif
    private static func publishOffMain(
        renderedPath: String,
        sourcePath: String,
        preferredOutput: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let fm = FileManager.default
        let taken: (String) -> Bool = { path in
            fm.fileExists(atPath: path)
                || fm.fileExists(atPath: ReformatJob.partialURL(for: URL(fileURLWithPath: path)).path)
        }

        // 1. Publish-time re-uniquify (M3 TOCTOU guard).
        var candidate = preferredOutput
        if taken(candidate.path) {
            candidate = cleanedOutputURL(forSourcePath: sourcePath, fileExists: taken)
        }

        // 2. Chunked copy to the candidate's partial sibling.
        let partialPath = ReformatJob.partialURL(for: candidate).path
        do {
            try await chunkedCopy(from: renderedPath, to: partialPath, progress: progress)
        } catch {
            try? fm.removeItem(atPath: partialPath)
            throw error
        }

        // 3. Non-clobbering promote, retrying the uniquify on a raced-in
        // collision. Bounded so a pathological filesystem can't loop us.
        var attempts = 0
        while true {
            do {
                try fm.moveItem(atPath: partialPath, toPath: candidate.path)
                return candidate
            } catch {
                attempts += 1
                guard attempts < 100, fm.fileExists(atPath: candidate.path) else {
                    try? fm.removeItem(atPath: partialPath)
                    throw error
                }
                // Somebody claimed the name between uniquify and rename —
                // pick the next free one and retry (rename only; the
                // copied bytes are reused).
                candidate = cleanedOutputURL(forSourcePath: sourcePath, fileExists: taken)
            }
        }
    }

    /// Streaming file copy: 8 MB chunks, cancellation checked per chunk,
    /// byte-fraction progress, and a per-chunk `Task.yield()` so a
    /// multi-minute copy never pins one cooperative-pool thread (the same
    /// concern that puts RAMDisk's hdiutil calls on detached tasks).
    /// Memory: exactly one chunk in flight, released each iteration via
    /// autoreleasepool (worst case ~8 MB). Internal so tests can exercise
    /// it directly. Async + nonisolated: runs on the CALLER's executor —
    /// reach it through a `@concurrent` frame (publishOffMain), never
    /// directly from @MainActor.
    nonisolated static func chunkedCopy(
        from source: String,
        to destination: String,
        chunkBytes: Int = 8 << 20,
        progress: @Sendable (Double) -> Void
    ) async throws {
        let fm = FileManager.default
        try? fm.removeItem(atPath: destination)
        guard fm.createFile(atPath: destination, contents: nil) else {
            throw CocoaError(.fileWriteUnknown,
                             userInfo: [NSFilePathErrorKey: destination])
        }
        let totalBytes = ((try? fm.attributesOfItem(atPath: source))?[.size] as? NSNumber)?
            .doubleValue ?? 0

        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: source))
        let output = try FileHandle(forWritingTo: URL(fileURLWithPath: destination))
        defer {
            try? input.close()
            try? output.close()
        }

        var copied: Int64 = 0
        while true {
            // A cancel (user or watchdog) lands here within one chunk.
            try Task.checkCancellation()
            let finished = try autoreleasepool { () -> Bool in
                guard let chunk = try input.read(upToCount: chunkBytes),
                      !chunk.isEmpty else { return true }
                try output.write(contentsOf: chunk)
                copied += Int64(chunk.count)
                return false
            }
            if finished { break }
            if totalBytes > 0 {
                progress(min(1.0, Double(copied) / totalBytes))
            }
            // Give the executor a scheduling point between chunks.
            await Task.yield()
        }
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
    /// `fileExists` is injected so the uniquify loop is pure-testable (and
    /// so the publish path can fold "partial exists" into "taken").
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

    func handleStall(silentFor: Double) {
        guard state.isActive, terminalCause.first == nil else { return }
        let attribution = StallMonitor.attribution(forPaths: [record.fullPath, outputURL.path])
        let reason = "Stalled — no progress for \(Int(silentFor))s during cleanup. \(attribution)"
        terminalCause.record(.stall(reason: reason))
        subtitleText = "Stalled — stopping…"
        cleanupLog.error("cleanup WATCHDOG: killing \(self.record.filename, privacy: .public) — \(reason, privacy: .public)")
        appLog.write("cleanup watchdog: \(record.filename) stalled \(Int(silentFor))s — \(attribution); killing job")
        task?.cancel()
    }

    // MARK: Catalog + provenance

    /// Probe the cleaned file and register it in the catalog with full
    /// provenance: `derivedFrom` = source record id, the recipe
    /// id+version, File Journey notes on BOTH records (recording whether
    /// the audio was copied or modernized — M4), a search-index update so
    /// the new file is findable immediately (M1), and a catalog-mutated
    /// notification so the debounced save persists it (M2 — a crash after
    /// a multi-hour render must not orphan the output).
    private func catalogCleanupOutput(publishedURL: URL) async {
        guard let model else { return }
        let newRec = await model.probeFile(url: publishedURL)

        newRec.derivedFrom = record.id
        newRec.cleanupRecipeID = recipe.id
        newRec.cleanupRecipeVersion = recipe.version

        // M4: the journey records which audio path ran, so provenance
        // answers "why does the copy's audio codec differ".
        let audioNote: String
        if record.streamType == .videoAndAudio {
            audioNote = CleanupFFmpegEngine.audioCopyAllowed(codec: record.audioCodec)
                ? "; audio copied unchanged"
                : "; audio modernized to PCM (source \(record.audioCodec.isEmpty ? "unknown codec" : record.audioCodec) is not playback-safe)"
        } else {
            audioNote = ""
        }

        let stamp = ISO8601DateFormatter().string(from: Date())
        let sourceNote = "Cleanup \(stamp): Created cleaned copy \(publishedURL.lastPathComponent) with \(recipe.displayName) (\(recipe.id) v\(recipe.version))\(audioNote)"
        let derivedNote = "Cleanup \(stamp): Cleaned from \(record.filename) with \(recipe.displayName) (\(recipe.id) v\(recipe.version))\(audioNote)"

        record.notes = record.notes.isEmpty
            ? sourceNote
            : "\(record.notes)\n\(sourceNote)"
        newRec.notes = newRec.notes.isEmpty
            ? derivedNote
            : "\(newRec.notes)\n\(derivedNote)"

        if let existing = model.records.firstIndex(where: { $0.fullPath == publishedURL.path }) {
            model.records[existing] = newRec
        } else {
            model.records.append(newRec)
        }
        // M1: index the new record (and the source's updated notes) so
        // the cleaned file is searchable without a relaunch — same
        // pattern as VideoScanModel+LiveReload's append path.
        model.searchIndex.update(newRec)
        model.searchIndex.update(record)

        // M2: one mutation notification → debounced catalog save + cache
        // refresh (the Correlate precedent). Without this, the record —
        // and a multi-hour render's provenance — lives only in memory.
        NotificationCenter.default.post(name: .videoScanCatalogMutated, object: nil)

        cleanupLog.info("cleanup: catalogued \(publishedURL.lastPathComponent, privacy: .public) (derivedFrom=\(self.record.id.uuidString, privacy: .public), recipe=\(self.recipe.id, privacy: .public) v\(self.recipe.version, privacy: .public))")
    }

    // MARK: Finish helpers

    private func finish(success: String) {
        state = .finished(summary: success)
        subtitleText = success
        fractionValue = 1.0
        isIndeterminateValue = false
    }

    private func finish(failed: String) {
        // Rick 2026-08-26: a job whose cancel was the FIRST terminal cause
        // NEVER ends .failed — the SIGTERM'd child's non-zero exit, or any
        // typed error thrown while the Task unwinds, is the user's Stop,
        // not a failure. A stall recorded before the Stop is not diverted
        // (codex gate 2026-08-26) — see MFOTerminalCause.
        if terminalCause.isCancel { finishCancelled(); return }
        state = .failed(message: failed)
        subtitleText = failed
        isIndeterminateValue = false
        cleanupLog.warning("cleanup failed: \(failed, privacy: .public)")
    }

    private func finishCancelled() {
        // An earlier stall is the cause of THIS cancellation (the watchdog
        // cancelled the Task) — report it, not "Cancelled".
        if let reason = terminalCause.stallReason { finish(failed: reason); return }
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
        // Rick 2026-08-18: one app-wide decimal formatter (Finder / df base).
        MediaBytes.display(bytes)
    }
}
