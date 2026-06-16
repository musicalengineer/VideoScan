import Foundation
import AVFoundation
import Combine
import os

// MARK: - CaptionOrchestrator
//
// Stage 6b. Owns the per-target captioning batch: discover the files in
// the catalog that need captions, drive `CaptionRunner.caption(...)`
// once per file, write back results immediately at each file boundary,
// surface progress + ETA + current-file UI state, and honor cancel.
//
// Shape mirrors PersonFinderModel's per-job state machine (ScanJobStatus
// + runScan / processOneVideo) but at a lower complexity: there is no
// reference-photo loading, no per-frame face matching, no clip
// extraction. The orchestrator is mostly plumbing around the engine.
//
// Critical design choice: session-scoped model container.
//
// MLXVLMCaptionRunner.caption (S6a) currently calls
// VLMModelFactory.shared.loadContainer ONCE per call — wasted ~30s on
// every file after the first. The orchestrator builds and reuses a
// CaptionSession that holds the loaded container across files in the
// same batch. Frames serialize through it; the session goes away when
// the batch ends (or is cancelled), and a fresh session is built for
// the next batch.
//
// Worst-case memory footprint: one ModelContainer (~3 GB for the 4-bit
// Qwen2.5-VL-3B weights) + transient CIImage per frame (decoded video
// frame, typically <50 MB) + KV cache (<100 MB). Total ceiling ~3.5 GB.
// Released when the session is torn down at batch end. No per-file
// accumulation — captions are flushed to the catalog and dropped from
// the orchestrator's working set at each boundary.

private let captionOrchLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "caption-orchestrator")
private let shutdownLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "shutdown")


// MARK: - Orchestrator

/// `@MainActor` so all status mutations cross the UI boundary safely
/// without explicit hops. The captioning work itself runs in a detached
/// Task — only the status writebacks return to the main actor.
@MainActor
final class CaptionOrchestrator: ObservableObject {

    // MARK: Published state

    /// Current batch status. Drives the progress sheet visibility.
    @Published var currentStatus: CaptionJobStatus = .idle

    /// Target the running batch is operating on. nil when idle.
    @Published var currentTarget: CatalogScanTarget?

    /// Volume-prefix the active per-volume batch is processing
    /// (`startAnalyzing(volumePrefix:)`). nil for legacy
    /// catalog-wide batches and when idle. The dashboard reads this
    /// to render which volume row shows the "analyzing" status dot.
    /// Rick 2026-06-13: dossier is now driven per-volume from the
    /// dashboard's volume row.
    @Published var currentVolumePrefix: String?

    /// True while the user has the pipeline paused via the volume
    /// row's Pause button. The batch loop checks before dispatching
    /// each next file and awaits until cleared. The currently
    /// in-flight VLM/Whisper task is NOT signaled — it runs to
    /// completion. So Pause prevents NEW work; in-flight work
    /// drains.
    @Published var paused: Bool = false

    /// Number of frames per file to caption. Default 3 matches S6a's
    /// fixture pattern. Tunable later by the UI; constant for now.
    let framesPerFile: Int

    /// Force-recaption even when the record's `sceneCaptionModel`
    /// matches the current engine's `modelID`. Idempotent skip is the
    /// default; this is the "re-caption all" escape hatch the UI may
    /// pass for the future "Re-caption" action.
    var force: Bool = false

    // MARK: Internal state

    /// Active captioning task. Holding the reference lets cancel()
    /// actually cancel; `Task.checkCancellation()` inside the loop
    /// flips the runner out promptly.
    private var activeTask: Task<Void, Never>?

    /// In-flight Whisper task (pipelined path only — at most one
    /// outstanding by design). Lifted from a loop-local in
    /// `runDossierBatchPipelined` to instance state so `skipLane(_:)`
    /// can cancel it from the UI when the user clicks Skip on a stuck
    /// transcription. Always set together with `pendingWhisperLaneID`.
    private var pendingWhisperTask: Task<Void, Never>?
    private var pendingWhisperLaneID: UUID?

    /// Lane IDs the user explicitly skipped (right-click → Skip). The
    /// pipelined loop checks this set BEFORE dispatching Whisper (so a
    /// skip during the VLM phase short-circuits Whisper) and the
    /// Whisper task's CancellationError branch checks it to use the
    /// "user skipped" note instead of "transcript failed". Cleared at
    /// the start of every batch — skips don't persist across runs.
    private var userSkippedLaneIDs: Set<UUID> = []

    /// Injectable engine. Default builds an MLXVLMCaptionRunner. Tests
    /// can swap in a stub runner that returns deterministic captions
    /// without touching MLX.
    var runnerFactory: () -> CaptionRunner

    /// Latched true by `drainForShutdown()` when the app is quitting.
    /// Every start* entry point bails when set. Without this latch the
    /// catalog-wide sweep loops (startCatalogWideCaptioning /
    /// startCatalogWideDossier) would start the NEXT volume's batch
    /// after the quit-time cancel kills the current one — those loops
    /// run in view-owned Tasks that `cancel()` cannot reach, and fresh
    /// VLM inference dispatching GPU work during app teardown is
    /// exactly the mid-inference exit crash
    /// (VideoScan-2026-06-11-232946.ips).
    private(set) var isShuttingDown = false

    init(runnerFactory: (() -> CaptionRunner)? = nil) {
        self.framesPerFile = 3
        self.runnerFactory = runnerFactory ?? { MLXVLMCaptionRunner() }
    }

    // MARK: - Public API

    /// Kick off captioning for every video record under `target` in the
    /// catalog. Returns when the batch finishes (status transitions to
    /// `.finished`) or is cancelled. Safe to call from a SwiftUI
    /// `.task { ... }` modifier or a button action.
    ///
    /// Idempotent on skip: records with `sceneCaptions` non-empty AND
    /// `sceneCaptionModel == runner.modelID` are skipped unless `force`
    /// is true.
    func startCaptioning(target: CatalogScanTarget, model: VideoScanModel) async {
        // App is quitting — refuse to start a new batch. See
        // isShuttingDown's doc comment for why this matters for the
        // catalog-wide sweep loops.
        guard !isShuttingDown else {
            captionOrchLog.notice("startCaptioning refused — app is shutting down")
            return
        }
        // Guard against double-start. Mirrors PersonFinderModel.startJob's
        // `guard !job.status.isActive` pattern.
        guard !currentStatus.isActive else {
            captionOrchLog.warning("startCaptioning called while already \(String(describing: self.currentStatus))")
            return
        }

        currentTarget = target
        currentStatus = .running(progress: 0.0, currentFile: "(loading model…)", etaSec: nil)

        // Capture refs we need inside the detached task — orchestrator
        // mutations happen back on MainActor via `await MainActor.run`.
        let runner = runnerFactory()
        let force = self.force
        let frames = self.framesPerFile

        // Filter the catalog records to this target's volume. We
        // include videoAndAudio + videoOnly (the latter is correlated
        // / orphan media that often DOES carry video essence — and the
        // user may want captions there too). Audio-only and no-stream
        // records are skipped — no video frames to caption.
        let allRecords = model.records
        let targetPrefix = target.searchPath
        let candidates: [VideoRecord] = allRecords.filter { r in
            r.fullPath.hasPrefix(targetPrefix) &&
            (r.streamType == .videoAndAudio || r.streamType == .videoOnly)
        }

        captionOrchLog.info("CaptionOrchestrator starting: target=\(targetPrefix, privacy: .public), candidates=\(candidates.count), engine=\(runner.modelID, privacy: .public), force=\(force)")
        appLog.write("Analyzing volume: starting \(candidates.count) candidate(s) on \(VolumeReachability.displayLabel(forPath: targetPrefix)) with \(runner.modelID)")

        activeTask = Task { [weak self] in
            await self?.runBatch(
                runner: runner,
                candidates: candidates,
                framesPerFile: frames,
                force: force,
                model: model
            )
        }

        // Await the task so callers can `await startCaptioning(...)`
        // and get back when the batch settles.
        await activeTask?.value
    }

    /// Catalog-wide captioning: iterate every reachable scan target in
    /// sequence, captioning every eligible video. Idempotent: records
    /// already captioned with the current engine's modelID are skipped
    /// by the existing per-target loop (the same skip predicate that
    /// drives `startCaptioning(target:)`). That property gives us "free"
    /// pause/resume — if the user quits mid-batch, the next invocation
    /// picks up where we left off because the completed records are
    /// already persisted with their captions.
    ///
    /// Sequential by design (v1): the VLM is GPU-heavy; running
    /// multiple targets in parallel would just contend for the same
    /// MLX compute. Per-target progress lights up through the existing
    /// currentStatus / currentTarget published state.
    ///
    /// Roadmap item #4 (2026-06-04). See
    /// docs/family-tagging-and-search-roadmap.md and
    /// `pfCatalogWideMetadataCandidates`.
    func startCatalogWideCaptioning(model: VideoScanModel) async {
        guard !isShuttingDown else {
            captionOrchLog.notice("startCatalogWideCaptioning refused — app is shutting down")
            return
        }
        guard !currentStatus.isActive else {
            captionOrchLog.warning("startCatalogWideCaptioning called while already \(String(describing: self.currentStatus))")
            return
        }

        let reachable = model.scanTargets.filter { $0.isReachable && !$0.searchPath.isEmpty && !$0.isRetired }
        captionOrchLog.info("Catalog-wide caption: \(reachable.count) reachable target(s)")
        appLog.write("Analyzing catalog: starting across \(reachable.count) reachable volume(s)")

        guard !reachable.isEmpty else {
            currentStatus = .finished(captioned: 0, skipped: 0, failed: 0)
            return
        }

        for target in reachable {
            if Task.isCancelled { break }
            // Per-target invocation reuses the existing batch loop,
            // including idempotent skip + per-file cancellation. Status
            // publishing already happens inside.
            await startCaptioning(target: target, model: model)
            // After each target settles, currentStatus is .finished —
            // reset to idle before the next target's startCaptioning
            // call so its guard doesn't bail.
            if !Task.isCancelled {
                currentStatus = .idle
            }
        }

        appLog.write("Analyzing catalog: completed sweep across \(reachable.count) volume(s)")
        currentStatus = .finished(captioned: 0, skipped: 0, failed: 0)
    }

    /// Request cancellation. Flips status to `.cancelling`. The active
    /// task observes `Task.isCancelled` / `Task.checkCancellation()` in
    /// the per-file loop (and inside the runner's per-frame loop, see
    /// CaptionRunner.swift) and exits promptly.
    func cancel() {
        guard currentStatus.isActive else { return }
        captionOrchLog.notice("CaptionOrchestrator cancel requested")
        currentStatus = .cancelling
        activeTask?.cancel()
    }

    /// Start dossier processing for files under a single volume.
    /// Rick 2026-06-13: replaces the global "Analyze Local Media"
    /// button with per-volume Analyze actions. The orchestrator filters
    /// the candidate list by `fullPath.hasPrefix(volumePrefix)` and
    /// otherwise behaves like `startCatalogWideDossier` — same
    /// idempotent skip, same DRM gate, same indicator pipeline.
    ///
    /// Phase 1 (today): only one volume can be analyzing at a time.
    /// Calling while busy is a no-op (logged). Phase 2 will allow
    /// concurrent per-volume batches with proper subprocess pooling.
    ///
    /// Persisted to `DossierActiveVolumes` so auto-resume can pick up
    /// where we left off across launches.
    func startAnalyzing(
        volumePrefix: String,
        model: VideoScanModel,
        transcriber: AudioTranscriber? = nil,
        force: Bool = false,
        stages: Set<AnalyzeStage> = AnalyzeStage.all
    ) async {
        guard !isShuttingDown else {
            captionOrchLog.notice("startAnalyzing refused — app is shutting down")
            return
        }
        guard !currentStatus.isActive else {
            captionOrchLog.warning("startAnalyzing(\(volumePrefix, privacy: .public)) refused — already \(String(describing: self.currentStatus))")
            return
        }
        guard !volumePrefix.isEmpty else {
            captionOrchLog.warning("startAnalyzing refused — empty volumePrefix")
            return
        }

        let resolvedTranscriber: AudioTranscriber? = transcriber ?? {
            let py = ToolLocator.mlxPythonPath
            let sc = ToolLocator.whisperScriptPath
            guard !py.isEmpty, !sc.isEmpty else { return nil }
            return PythonSubprocessAudioTranscriber(pythonPath: py, scriptPath: sc)
        }()

        // Filter candidates to this volume only. We still go through
        // pfCatalogWideMetadataCandidates because that's where junk /
        // DRM / purge / reachability filtering lives.
        let base = pfCatalogWideMetadataCandidates(
            records: model.records,
            reachableVolumePaths: [volumePrefix]
        )
        let candidates = pfCatalogWideCaptionCandidates(base)

        captionOrchLog.info("Per-volume dossier: \(candidates.count) candidate(s) under \(volumePrefix, privacy: .public); transcriber=\(resolvedTranscriber?.modelID ?? "none", privacy: .public)")
        appLog.write("Dossier: starting volume pass — \(candidates.count) eligible under \(VolumeReachability.displayLabel(forPath: volumePrefix))")

        guard !candidates.isEmpty else {
            captionOrchLog.info("Per-volume dossier: nothing to do under \(volumePrefix, privacy: .public)")
            currentStatus = .finished(captioned: 0, skipped: 0, failed: 0)
            return
        }

        currentTarget = nil
        currentVolumePrefix = volumePrefix
        rememberActiveVolume(volumePrefix)
        currentStatus = .running(progress: 0.0, currentFile: "(loading model…)", etaSec: nil)
        self.force = force

        let runner = runnerFactory()
        let frames = self.framesPerFile
        let trans = resolvedTranscriber

        activeTask = Task { [weak self] in
            await self?.runDossierBatch(
                runner: runner,
                transcriber: trans,
                candidates: candidates,
                framesPerFile: frames,
                force: force,
                model: model
            )
        }
        await activeTask?.value
        currentVolumePrefix = nil
        forgetActiveVolume(volumePrefix)
    }

    /// Halt new work without cancelling in-flight tasks. The loop
    /// checks `paused` before dispatching the next file and awaits
    /// until cleared (200ms poll — cheap enough for a UI gesture).
    /// The currently-running VLM/Whisper task is NOT signaled so it
    /// runs to completion, then the loop pauses before the next.
    ///
    /// Setting paused while idle is legal: the next batch start will
    /// trip the gate on its first iteration. (Useful for tests and
    /// for a "pause before resuming on launch" UX if we add it.)
    func pause() {
        guard !paused else { return }
        captionOrchLog.notice("CaptionOrchestrator pause requested")
        paused = true
    }

    /// Resume after `pause()`. The loop's await-while-paused exits and
    /// the next file dispatches. No-op if not paused.
    func resume() {
        guard paused else { return }
        captionOrchLog.notice("CaptionOrchestrator resume requested")
        paused = false
    }

    // MARK: - Auto-resume persistence

    /// UserDefaults key for the list of volume prefixes that had an
    /// active dossier batch when the app last ran. On launch, the
    /// VideoScanApp wiring reads this and (if DossierAutoResume is on)
    /// queues them for sequential processing.
    static let activeVolumesPrefsKey = "DossierActiveVolumes"

    /// Volume prefixes currently registered as "in progress" for
    /// auto-resume purposes. @Published so the UI can echo it; the
    /// authoritative store is UserDefaults so it survives crash.
    @Published private(set) var activeVolumePrefixes: Set<String> = {
        let list = UserDefaults.standard.stringArray(forKey: CaptionOrchestrator.activeVolumesPrefsKey) ?? []
        return Set(list)
    }()

    private func rememberActiveVolume(_ prefix: String) {
        activeVolumePrefixes.insert(prefix)
        UserDefaults.standard.set(Array(activeVolumePrefixes), forKey: Self.activeVolumesPrefsKey)
    }

    private func forgetActiveVolume(_ prefix: String) {
        activeVolumePrefixes.remove(prefix)
        UserDefaults.standard.set(Array(activeVolumePrefixes), forKey: Self.activeVolumesPrefsKey)
    }

    /// Quit-time drain. Latches `isShuttingDown` (so no new batch can
    /// start — including the next volume in a catalog-wide sweep),
    /// cancels the active batch, and waits for the in-flight task to
    /// settle, bounded by `deadline`.
    ///
    /// Returns `true` if the batch fully drained (or nothing was
    /// running), `false` if the deadline expired with inference still
    /// in flight. On `false` the caller must NOT touch MLX (no stream
    /// synchronize — it could block behind the running generation);
    /// the `_exit` backstop in applicationWillTerminate covers teardown.
    ///
    /// Unfinished captions are simply not written back — per-file
    /// writeback means everything completed before the cancel is
    /// already persisted, and the idempotent skip resumes the batch on
    /// next launch exactly where it left off.
    ///
    /// Must be awaited off the main thread's *blocking* path: the batch
    /// task hops through the MainActor for status writes, so a
    /// synchronous wait on the main thread would deadlock. AppDelegate
    /// uses `.terminateLater` + `NSApp.reply` to keep the runloop alive
    /// while this awaits.
    /// Synchronously latch `isShuttingDown` WITHOUT draining. For quit
    /// paths where no batch is active yet — most importantly a fast
    /// Cmd-Q during the DossierAutoResume launch delay (VideoScanApp
    /// schedules startCatalogWideDossier ~3s after launch): with
    /// nothing active, applicationShouldTerminate skips the drain, so
    /// without this latch the deferred auto-resume task could still
    /// start fresh VLM inference while AppKit tears down. ≈ C++
    /// `std::atomic<bool> g_shutting_down` set in the quit handler;
    /// here MainActor isolation replaces the atomic.
    func beginShutdown() {
        isShuttingDown = true
    }

    @discardableResult
    func drainForShutdown(deadline: TimeInterval = 5.0) async -> Bool {
        isShuttingDown = true
        guard currentStatus.isActive, let task = activeTask else { return true }
        shutdownLog.notice("drainForShutdown: cancelling active VLM batch, waiting up to \(String(format: "%.1f", deadline))s")
        currentStatus = .cancelling
        task.cancel()

        // Race batch completion against the deadline with two
        // unstructured tasks + a once-latch. Deliberately NOT a
        // `withTaskGroup` race: the group awaits ALL children before
        // returning, and `await task.value` on a non-throwing Task is
        // not cancellation-responsive — so a group would block until
        // the batch actually finished, defeating the bound (caught by
        // CaptionOrchestratorShutdownTests' stubborn-engine test).
        // If the deadline wins, the orphaned waiter just finishes
        // silently whenever the batch does; the latch makes its
        // continuation-resume a no-op.
        let drained = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let once = DrainOnceLatch()
            let timer = Task {
                try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                if once.tryClaim() { cont.resume(returning: false) }
            }
            Task {
                await task.value
                timer.cancel()  // stop the deadline clock; sleep throws out
                if once.tryClaim() { cont.resume(returning: true) }
            }
        }
        if drained {
            shutdownLog.notice("drainForShutdown: batch drained cleanly")
        } else {
            shutdownLog.error("drainForShutdown: deadline expired — inference may still be dispatching GPU work")
        }
        return drained
    }

    // MARK: - Catalog-wide dossier
    //
    // Steroids mode (Rick's word, 2026-06-04). Instead of the single-prompt
    // caption pass, run the three-prompt dossier (date / scene / text) plus
    // Whisper audio transcription, and flush all signals + the triangulated
    // record date into the catalog per file. Mirrors
    // startCatalogWideCaptioning's shape but talks to runner.dossier()
    // and AudioTranscriber.
    //
    // Idempotent skip key is `dossierProcessedAt != nil` — a record that
    // already has a dossier of ANY stack is not re-run unless force=true.
    // The dossierProcessedBy field stays around as pure provenance (which
    // stack produced this dossier) but is not part of the skip predicate.
    // Earlier code required `dossierProcessedBy == currentStackID` too,
    // which broke when the external worker fleet's stackID didn't match
    // the in-app stackID exactly — thousands of records re-ran every
    // launch, the dashboard "Analyzed" count never moved, and the user
    // saw Whisper firing on already-dossiered files. Deliberate
    // re-dossier-with-a-new-stack is what force=true is for.

    /// Catalog-wide dossier extraction. Iterates every reachable
    /// caption candidate, runs the 3-prompt VLM dossier + Whisper
    /// transcript per record, and writes the merged result via
    /// `VideoScanModel.applyDossier`. Pause/resume falls out of the
    /// idempotent skip — the next invocation picks up where this one
    /// left off because completed records carry their `dossierProcessedAt`.
    ///
    /// `transcriber` is optional: when nil (or missing tools at
    /// resolution time), the dossier still runs scene + OCR channels
    /// but no audio transcript. The triangulator's audio branch is
    /// a no-op today (DateTriangulation.swift line 62-66) so a nil
    /// transcriber doesn't degrade date inference today, just disables
    /// the searchable transcript text.
    func startCatalogWideDossier(
        model: VideoScanModel,
        transcriber: AudioTranscriber? = nil,
        force: Bool = false
    ) async {
        guard !isShuttingDown else {
            captionOrchLog.notice("startCatalogWideDossier refused — app is shutting down")
            return
        }
        guard !currentStatus.isActive else {
            captionOrchLog.warning("startCatalogWideDossier called while already \(String(describing: self.currentStatus))")
            return
        }

        // Default transcriber: PythonSubprocessAudioTranscriber against
        // the mlx venv + scripts/whisper_transcribe.py. Skipped if
        // either tool is missing — operator can install via
        // INSTALL.md's venv-mlx instructions to enable.
        let resolvedTranscriber: AudioTranscriber? = transcriber ?? {
            let py = ToolLocator.mlxPythonPath
            let sc = ToolLocator.whisperScriptPath
            guard !py.isEmpty, !sc.isEmpty else {
                captionOrchLog.notice("Dossier: no MLX Python / whisper script — running VLM-only (mlxPython='\(py, privacy: .public)', script='\(sc, privacy: .public)')")
                return nil
            }
            return PythonSubprocessAudioTranscriber(pythonPath: py, scriptPath: sc)
        }()

        let reachablePaths = model.scanTargets
            .filter { $0.isReachable && !$0.searchPath.isEmpty && !$0.isRetired }
            .map { $0.searchPath }
        let base = pfCatalogWideMetadataCandidates(
            records: model.records,
            reachableVolumePaths: reachablePaths
        )
        let candidates = pfCatalogWideCaptionCandidates(base)

        captionOrchLog.info("Catalog-wide dossier: \(candidates.count) candidate(s) across \(reachablePaths.count) volume(s); transcriber=\(resolvedTranscriber?.modelID ?? "none", privacy: .public)")
        appLog.write("Dossier: starting catalog-wide pass — \(candidates.count) eligible video(s), VLM=\(MLXVLMCaptionRunner().modelID), transcriber=\(resolvedTranscriber?.modelID ?? "none"), force=\(force)")

        guard !candidates.isEmpty else {
            currentStatus = .finished(captioned: 0, skipped: 0, failed: 0)
            return
        }

        currentTarget = nil
        currentStatus = .running(progress: 0.0, currentFile: "(loading model…)", etaSec: nil)
        self.force = force

        let runner = runnerFactory()
        let frames = self.framesPerFile
        let trans = resolvedTranscriber

        activeTask = Task { [weak self] in
            await self?.runDossierBatch(
                runner: runner,
                transcriber: trans,
                candidates: candidates,
                framesPerFile: frames,
                force: force,
                model: model
            )
        }
        await activeTask?.value
    }

    /// Pipelined dossier batch: VLM and Whisper overlap across files.
    ///
    /// While the Whisper subprocess transcribes file N-1, the VLM
    /// runs dossier extraction on file N. Backpressure comes from a
    /// chained task: before dispatching Whisper for file N we
    /// `await pendingWhisper?.value` for file N-1, so at most one
    /// Whisper task is ever outstanding (at most two files in flight)
    /// and no VLM result can be dropped.
    ///
    /// (The previous implementation connected the stages with an
    /// AsyncStream using .bufferingOldest(1), on the mistaken belief
    /// that yield suspends when the buffer is full. It does not —
    /// AsyncStream.Continuation.yield never suspends — so whenever
    /// Whisper was mid-transcription with one result already buffered,
    /// further VLM results were silently discarded and never reached
    /// applyDossier. C++ analogy: it was a lossy ring buffer of size 1,
    /// not a blocking bounded queue.)
    private func runDossierBatch(
        runner: CaptionRunner,
        transcriber: AudioTranscriber?,
        candidates: [VideoRecord],
        framesPerFile: Int,
        force: Bool,
        model: VideoScanModel,
        stages: Set<AnalyzeStage> = AnalyzeStage.all
    ) async {
        let started = CFAbsoluteTimeGetCurrent()
        let total = candidates.count
        resetLiveCounts()
        liveTotal = total

        let stackID: String = transcriber.map { "\(runner.modelID)+\($0.modelID)" } ?? runner.modelID
        let vlmModelID = runner.modelID

        // Stage gating (Rick 2026-06-14): the menu items "Transcribe
        // Audio" and "Generate Scene Captions" promised to do ONLY
        // that thing. Honor the promise by skipping the irrelevant
        // stage instead of running both and pretending. The pipelined
        // path's overlap is only valuable when BOTH stages run; for
        // single-stage batches the serial path is honest and simpler.
        let runCaptions = stages.contains(.captions)
        let runTranscript = stages.contains(.transcript)

        // No transcriber, OR transcript-stage disabled, OR captions-
        // stage disabled → serial path. The pipelined path is the
        // VLM+Whisper backpressure optimization; it only beats serial
        // when both stages run for every file.
        guard transcriber != nil, runCaptions, runTranscript else {
            await runDossierBatchSerial(
                runner: runner, transcriber: transcriber,
                candidates: candidates, framesPerFile: framesPerFile,
                force: force, model: model, stackID: stackID, started: started,
                stages: stages
            )
            return
        }
        let transcriber = transcriber!
        let whisperModelID = transcriber.modelID

        // Whisper task for the previous file. Awaited before the next
        // Whisper dispatch (backpressure) and once after the loop so
        // the summary below sees final counts. Always assigned together
        // with `self.pendingWhisperTask` / `self.pendingWhisperLaneID`
        // so `skipLane(_:)` can cancel exactly the right task from the
        // UI — local-variable observers aren't a thing in Swift, so we
        // mirror by hand at each assignment site.
        var pendingWhisper: Task<Void, Never>?

        for (idx, record) in candidates.enumerated() {
            if Task.isCancelled {
                captionOrchLog.notice("Dossier: VLM cancelled at file \(idx) of \(total)")
                break
            }
            // Pause gate: while paused, poll every 200ms. The
            // currently-in-flight Whisper task (file N-1) keeps
            // running — we only block dispatching the NEXT file's
            // VLM. Honors Task.isCancelled so Stop still breaks
            // through a paused state cleanly.
            while paused && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
            }
            if Task.isCancelled { break }

            let path = record.fullPath
            let filename = record.filename

            // Idempotent skip: any record that already carries a dossier
            // timestamp is left alone. The previous predicate also
            // required dossierProcessedBy == stackID, which silently
            // re-ran thousands of records whenever the external fleet
            // and in-app stackIDs differed (e.g. "...whisper-medium-mlx-q4"
            // vs "...python-whisper-medium-mlx-q4"). force=true is the
            // explicit escape hatch for re-dossier-with-current-stack.
            if !force, record.dossierProcessedAt != nil {
                liveSkipped += 1
                publishProgress(idx: idx + 1, total: total, currentFile: filename, started: started)
                continue
            }

            if !FileManager.default.fileExists(atPath: path) {
                // Auto-purge: candidate filter only passed records whose
                // volume IS reachable. So if the file is missing, the
                // volume is mounted but the entry is stale (Combine
                // engine output that moved, prior cleanup didn't update
                // the catalog, etc.). Soft-purge so the row's eligible
                // count drops by one and "Analyze Complete" can finally
                // become true. Reversible via the catalog's restore
                // action. Rick 2026-06-13.
                Self.flagMissingOnDisk(record)
                liveSkipped += 1
                captionOrchLog.notice("Dossier: missing on disk → auto-purged: \(path, privacy: .public)")
                appLog.write("Dossier: auto-purged missing on disk: \(filename)")
                publishProgress(idx: idx + 1, total: total, currentFile: filename, started: started)
                continue
            }

            // DRM gate. Cached short-circuit; otherwise inline probe via
            // AVAsset.hasProtectedContent (fast — metadata only, no decode).
            // Encrypted m4v/m4p files (vintage iTunes purchases from
            // forgotten user accounts) would otherwise eat hours of
            // Whisper time grinding ciphertext. We mark + skip; the
            // candidate filter excludes on subsequent runs.
            if record.drmProtected {
                liveSkipped += 1
                captionOrchLog.notice("Dossier: skip DRM-protected (cached): \(filename, privacy: .public)")
                publishProgress(idx: idx + 1, total: total, currentFile: filename, started: started)
                continue
            }
            if await Self.isDRMProtected(path: path) {
                Self.flagDRMSuspectJunk(record)
                liveSkipped += 1
                captionOrchLog.notice("Dossier: skip DRM-protected (probed, → suspectedJunk): \(filename, privacy: .public)")
                appLog.write("Dossier: skip DRM-protected: \(filename) (flagged suspectedJunk)")
                publishProgress(idx: idx + 1, total: total, currentFile: filename, started: started)
                continue
            }

            publishProgress(idx: idx, total: total, currentFile: filename, started: started)

            let dur = max(0.5, record.durationSeconds)
            let timestamps = framesEvenlySpaced(framesPerFile: framesPerFile, durationSec: dur)

            // Capture the file's stream type up-front: videoOnly records
            // cannot have audio, so the pipeline must NOT dispatch
            // Whisper for them. We still preserve chronological completion
            // order by awaiting the previous file's pendingWhisper before
            // banking the no-audio VLM-only result (see below).
            let hasNoAudio = (record.streamType == .videoOnly)

            // Open this file's dashboard lane. ONE lane per file across
            // both stages — VLM and Whisper transitions mutate it in
            // place so the user sees one row tick through the pipeline
            // with the per-channel ✓/✗/— indicators lighting up.
            let laneID = beginLane(
                path: path,
                filename: filename,
                isVideoOnly: hasNoAudio,
                stage: Self.stageDisplayName(forModelID: vlmModelID),
                verb: "extracting scenes…"
            )

            do {
                let vlmStart = CFAbsoluteTimeGetCurrent()
                let extraction = try await runner.dossier(
                    videoPath: path,
                    atTimestamps: timestamps
                )
                let vlmSec = CFAbsoluteTimeGetCurrent() - vlmStart
                // hasCaptions reflects whether we actually got usable
                // scene captions, NOT just that VLM completed without
                // error. Rick 2026-06-13: music videos returning
                // "0 scenes, 0 dates, 0 text" were lighting up green ✓
                // on the dashboard even though applyDossier would write
                // an empty sceneCaptions array. Indicator now matches
                // banked content — green only when scenes is non-empty.
                let didExtractCaptions = !extraction.scenes.isEmpty
                // "0 scenes in <1s" is the unmistakable signature of
                // the AVFoundation frame extractor bailing out because
                // it can't decode the source codec (svq3, qdm2,
                // cinepak, etc.). A real VLM run on a featureless or
                // black video takes 5–15s because it actually
                // processes frames. Flag the record so the catalog
                // surfaces a red "!" and the user can right-click →
                // Reformat and Analyze (Rick 2026-06-14).
                //
                // Static codec heuristic already catches known-bad
                // codecs at catalog-read time via record.isLikelyUnanalyzable;
                // this dynamic backstop catches unfamiliar codecs by
                // their failure signature.
                if !didExtractCaptions && vlmSec < 1.0 && !record.needsReformat {
                    record.needsReformat = true
                    captionOrchLog.notice("Dossier: VLM bailed in \(vlmSec, format: .fixed(precision: 2), privacy: .public)s with 0 scenes — flagging \(filename, privacy: .public) needsReformat")
                    appLog.write(String(format: "Dossier: flagged needsReformat (codec couldn't be decoded): %@", filename))
                }
                if hasNoAudio {
                    updateLane(laneID, hasCaptions: didExtractCaptions)
                } else {
                    updateLane(
                        laneID,
                        stage: Self.stageDisplayName(forModelID: whisperModelID),
                        verb: pendingWhisper == nil ? "transcribing audio…" : "waiting for prior transcript…",
                        hasCaptions: didExtractCaptions
                    )
                }
                appLog.write(String(format: "Pipeline VLM done: %@ — %.1fs (%d scene(s))", filename, vlmSec, extraction.scenes.count))

                // Backpressure: wait for the previous file's Whisper to
                // finish before dispatching this one. At most one Whisper
                // outstanding; every VLM result is handed off, never dropped.
                await pendingWhisper?.value
                pendingWhisper = nil
                self.pendingWhisperTask = nil
                self.pendingWhisperLaneID = nil
                // Whisper slot just freed — flip the verb so the user
                // sees the lane move from "waiting" to "transcribing"
                // even before the subprocess actually starts.
                if !hasNoAudio {
                    updateLane(laneID, verb: "transcribing audio…")
                }

                if Task.isCancelled {
                    // Cancelled while waiting on the previous Whisper:
                    // still bank this file's VLM result, sans transcript.
                    _ = model.applyDossier(
                        extraction, to: path,
                        vlmModel: vlmModelID,
                        transcript: nil,
                        whisperModel: nil
                    )
                    // Snapshot indicator state BEFORE endLane so the
                    // completion row reflects what VLM banked. Order
                    // matters: recordCompletion(fromLane:) reads the
                    // lane out of activeLanes; endLane removes it.
                    recordCompletion(fromLane: laneID, vlmSeconds: vlmSec,
                                     whisperSeconds: nil,
                                     note: hasNoAudio ? "no audio" : "transcript failed")
                    endLane(laneID)
                    liveCaptioned += 1
                    break
                }

                // User-initiated skip during the VLM phase: don't
                // dispatch Whisper, bank VLM-only, tag "user skipped".
                // We catch this BEFORE the video-only bypass so the
                // user's intent wins over the auto-bypass and the note
                // is correctly attributed.
                if userSkippedLaneIDs.contains(laneID) {
                    _ = model.applyDossier(
                        extraction, to: path,
                        vlmModel: vlmModelID,
                        transcript: nil,
                        whisperModel: nil
                    )
                    recordCompletion(fromLane: laneID, vlmSeconds: vlmSec,
                                     whisperSeconds: nil, note: "user skipped")
                    endLane(laneID)
                    liveCaptioned += 1
                    publishProgress(idx: idx + 1, total: total, currentFile: filename, started: started)
                    continue
                }

                // Video-only record: skip Whisper entirely. Apply the
                // dossier inline VLM-only so banking still happens in
                // VLM-stage order. pendingWhisper stays nil — the NEXT
                // file's loop iteration will await it as a no-op.
                if hasNoAudio {
                    _ = model.applyDossier(
                        extraction, to: path,
                        vlmModel: vlmModelID,
                        transcript: nil,
                        whisperModel: nil
                    )
                    recordCompletion(fromLane: laneID, vlmSeconds: vlmSec,
                                     whisperSeconds: nil, note: "no audio")
                    endLane(laneID)
                    liveCaptioned += 1
                    publishProgress(idx: idx + 1, total: total, currentFile: filename, started: started)
                    continue
                }

                // Publish the lane ID BEFORE the task is created so a
                // simultaneous skipLane(_:) call from the UI sees a
                // matching pendingWhisperLaneID and finds the cancel
                // target the moment we mirror pendingWhisperTask below.
                self.pendingWhisperLaneID = laneID
                // Per-file Whisper deadline. max(60s floor, 2× clip
                // duration) so a 30s clip gets 60s, a 5-min clip gets
                // 10min, a 30-min clip gets 60min. Whisper-medium-mlx-q4
                // realistically runs at 5–15× realtime on M4 Max, so 2×
                // is generous slack; anything past it is almost
                // certainly hung (the symptom Rick hit on the BT music
                // video that wedged the pipeline for 26+ minutes).
                let whisperDeadlineSeconds = max(60.0, 2.0 * record.durationSeconds)
                pendingWhisper = Task { @MainActor [weak self] in
                    guard let self else { return }
                    appLog.write(String(format: "Pipeline Whisper start: %@ (deadline %.0fs)", filename, whisperDeadlineSeconds))
                    let whisperStart = CFAbsoluteTimeGetCurrent()
                    var transcript: String?
                    do {
                        transcript = try await transcriber.transcribe(
                            videoPath: path,
                            deadlineSeconds: whisperDeadlineSeconds
                        )
                    } catch is CancellationError {
                        // Cancelled mid-transcription: apply VLM-only so
                        // the extraction isn't lost. Note depends on who
                        // pulled the cord — user via skipLane vs an
                        // upstream task cancel (batch cancel / shutdown).
                        _ = model.applyDossier(
                            extraction, to: path,
                            vlmModel: vlmModelID,
                            transcript: nil,
                            whisperModel: nil
                        )
                        let userSkipped = self.userSkippedLaneIDs.contains(laneID)
                        self.updateLane(laneID, transcriptFailed: !userSkipped)
                        self.recordCompletion(fromLane: laneID, vlmSeconds: vlmSec,
                                              whisperSeconds: nil,
                                              note: userSkipped ? "user skipped" : "transcript failed")
                        self.endLane(laneID)
                        liveCaptioned += 1
                        return
                    } catch AudioTranscriberError.deadlineExceeded(let secs) {
                        // Auto-kill: subprocess exceeded its deadline.
                        // VLM result still banks — captions are valid
                        // even when the transcript path failed. Note
                        // is distinct from "transcript failed" so the
                        // dashboard can show "whisper timed out" and
                        // we can later flag chronically-stuck files
                        // (probably junk) for triage.
                        captionOrchLog.warning("Dossier: whisper deadline (\(secs, format: .fixed(precision: 0), privacy: .public)s) exceeded on \(filename, privacy: .public)")
                        _ = model.applyDossier(
                            extraction, to: path,
                            vlmModel: vlmModelID,
                            transcript: nil,
                            whisperModel: nil
                        )
                        self.updateLane(laneID, transcriptFailed: true)
                        self.recordCompletion(fromLane: laneID, vlmSeconds: vlmSec,
                                              whisperSeconds: nil, note: "whisper timed out")
                        self.endLane(laneID)
                        self.transcriptFailures += 1
                        liveCaptioned += 1
                        return
                    } catch {
                        captionOrchLog.warning("Dossier: whisper failed on \(filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        transcript = nil
                        self.transcriptFailures += 1
                    }

                    _ = model.applyDossier(
                        extraction, to: path,
                        vlmModel: vlmModelID,
                        transcript: transcript,
                        whisperModel: transcript != nil ? whisperModelID : nil
                    )
                    let whisperSec = CFAbsoluteTimeGetCurrent() - whisperStart
                    appLog.write(String(format: "Pipeline Whisper done: %@ — %.1fs", filename, whisperSec))
                    // hasTranscript reflects banked content. Empty /
                    // whitespace-only transcripts (Whisper ran on
                    // silent audio, found nothing) get filtered by
                    // applyDossier — record.audioTranscript stays nil
                    // — so the dashboard's ✓ must follow the same
                    // truth. Otherwise the user sees a checkmark for
                    // a file whose catalog row has no transcript.
                    let bankedTranscript = transcript?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let didExtractTranscript = (bankedTranscript?.isEmpty == false)
                    if didExtractTranscript {
                        self.updateLane(laneID, hasTranscript: true)
                    } else {
                        self.updateLane(laneID, transcriptFailed: true)
                    }
                    // Snapshot indicators FROM the lane via the fromLane
                    // overload — order matters: read before endLane.
                    //
                    // Note semantics in the pipelined path:
                    //   nil                → transcript obtained AND non-empty
                    //   "transcript failed" → whisper threw OR returned only
                    //                         whitespace (cancellation
                    //                         returned early above, and
                    //                         "no audio" bypasses Whisper
                    //                         before this task is ever
                    //                         created).
                    let note: String? = didExtractTranscript ? nil : "transcript failed"
                    self.recordCompletion(
                        fromLane: laneID,
                        vlmSeconds: vlmSec,
                        whisperSeconds: didExtractTranscript ? whisperSec : nil,
                        note: note
                    )
                    self.endLane(laneID)
                    liveCaptioned += 1
                    publishProgress(idx: idx + 1, total: total, currentFile: filename, started: started)
                }
                // Mirror the just-created task into instance state so
                // skipLane(_:) can target it. Done OUTSIDE the closure
                // so the reference is resolved (Swift forbids a Task's
                // closure capturing the var being assigned to).
                self.pendingWhisperTask = pendingWhisper
            } catch is CancellationError {
                endLane(laneID)
                captionOrchLog.notice("Dossier: VLM cancellation at \(filename, privacy: .public)")
                break
            } catch {
                endLane(laneID)
                liveFailed += 1
                captionOrchLog.warning("Dossier: VLM error on \(filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
                publishProgress(idx: idx + 1, total: total, currentFile: filename, started: started)
            }
        }

        // pendingWhisper is unstructured, so cancellation of the batch
        // task doesn't propagate automatically — forward it explicitly
        // so a cancelled batch doesn't block shutdown on a long
        // transcription (the task's CancellationError path still applies
        // the VLM result).
        if Task.isCancelled { pendingWhisper?.cancel() }
        await pendingWhisper?.value
        // Batch fully drained — clear the in-flight Whisper handles so
        // a late skipLane(_:) call (e.g. UI race during shutdown) is a
        // clean no-op rather than poking at a finished task.
        self.pendingWhisperTask = nil
        self.pendingWhisperLaneID = nil

        // Batch settled — nothing is in flight. History stays.
        clearActiveLanes()

        let elapsed = CFAbsoluteTimeGetCurrent() - started
        let captioned = liveCaptioned
        let skipped = liveSkipped
        let failed = liveFailed
        captionOrchLog.info("Dossier batch done: captioned=\(captioned), skipped=\(skipped), failed=\(failed) in \(String(format: "%.1f", elapsed))s")
        appLog.write(String(format: "Dossier: done — %d processed, %d skipped, %d failed in %.1fs (%@)",
                            captioned, skipped, failed, elapsed, stackID))
        if Task.isCancelled {
            appLog.write("Dossier: cancelled (done \(captioned), skipped \(skipped), failed \(failed))")
        }
        currentStatus = .finished(captioned: captioned, skipped: skipped, failed: failed)
    }

    /// Serial fallback when no transcriber is configured (no overlap benefit).
    ///
    /// `internal` (not `private`) so CaptionOrchestratorActivityTests can
    /// drive this path deterministically — the public entry point's
    /// nil-transcriber fallback resolves ToolLocator, which on a dev box
    /// with venv-mlx installed silently upgrades the run to the
    /// pipelined path with a REAL Whisper subprocess.
    func runDossierBatchSerial(
        runner: CaptionRunner,
        transcriber: AudioTranscriber?,
        candidates: [VideoRecord],
        framesPerFile: Int,
        force: Bool,
        model: VideoScanModel,
        stackID: String,
        started: CFAbsoluteTime,
        stages: Set<AnalyzeStage> = AnalyzeStage.all
    ) async {
        let total = candidates.count

        for (idx, record) in candidates.enumerated() {
            if Task.isCancelled {
                captionOrchLog.notice("Dossier: cancelled at file \(idx) of \(total)")
                appLog.write("Dossier: cancelled at file \(idx) of \(total) (done \(liveCaptioned), skipped \(liveSkipped), failed \(liveFailed))")
                clearActiveLanes()
                currentStatus = .finished(captioned: liveCaptioned, skipped: liveSkipped, failed: liveFailed)
                return
            }
            while paused && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
            }
            if Task.isCancelled {
                clearActiveLanes()
                currentStatus = .finished(captioned: liveCaptioned, skipped: liveSkipped, failed: liveFailed)
                return
            }

            let path = record.fullPath
            let filename = record.filename

            // Idempotent skip: a record that already has a dossier
            // timestamp is left alone, regardless of which stack
            // produced it. See the doc comment on
            // startCatalogWideDossier for why dossierProcessedBy is
            // no longer part of this predicate.
            if !force, record.dossierProcessedAt != nil {
                liveSkipped += 1
                publishProgress(idx: idx + 1, total: total, currentFile: filename, started: started)
                continue
            }

            if !FileManager.default.fileExists(atPath: path) {
                // Auto-purge: candidate filter only passed records whose
                // volume IS reachable. So if the file is missing, the
                // volume is mounted but the entry is stale (Combine
                // engine output that moved, prior cleanup didn't update
                // the catalog, etc.). Soft-purge so the row's eligible
                // count drops by one and "Analyze Complete" can finally
                // become true. Reversible via the catalog's restore
                // action. Rick 2026-06-13.
                Self.flagMissingOnDisk(record)
                liveSkipped += 1
                captionOrchLog.notice("Dossier: missing on disk → auto-purged: \(path, privacy: .public)")
                appLog.write("Dossier: auto-purged missing on disk: \(filename)")
                publishProgress(idx: idx + 1, total: total, currentFile: filename, started: started)
                continue
            }

            // DRM gate — same semantics as the pipelined path.
            if record.drmProtected {
                liveSkipped += 1
                captionOrchLog.notice("Dossier: skip DRM-protected (cached): \(filename, privacy: .public)")
                publishProgress(idx: idx + 1, total: total, currentFile: filename, started: started)
                continue
            }
            if await Self.isDRMProtected(path: path) {
                Self.flagDRMSuspectJunk(record)
                liveSkipped += 1
                captionOrchLog.notice("Dossier: skip DRM-protected (probed, → suspectedJunk): \(filename, privacy: .public)")
                appLog.write("Dossier: skip DRM-protected: \(filename) (flagged suspectedJunk)")
                publishProgress(idx: idx + 1, total: total, currentFile: filename, started: started)
                continue
            }

            publishProgress(idx: idx, total: total, currentFile: filename, started: started)

            let dur = max(0.5, record.durationSeconds)
            let timestamps = framesEvenlySpaced(framesPerFile: framesPerFile, durationSec: dur)

            let hasNoAudio = (record.streamType == .videoOnly)

            // One lane per file. Stage transitions VLM → Whisper happen
            // in place via updateLane so the dashboard shows a single
            // row per file with the per-channel indicators lighting up.
            let laneID = beginLane(
                path: path,
                filename: filename,
                isVideoOnly: hasNoAudio,
                stage: Self.stageDisplayName(forModelID: runner.modelID),
                verb: "extracting scenes…"
            )

            do {
                // Stage gating (Rick 2026-06-14): skip VLM entirely
                // when the caller asked for transcript-only. Empty
                // extraction propagates "no captions" cleanly through
                // applyDossier; vlmModel passed as nil so the record's
                // provenance reflects what actually ran.
                let runCaptions = stages.contains(.captions)
                let runTranscript = stages.contains(.transcript)

                let vlmStart = CFAbsoluteTimeGetCurrent()
                let extraction: DossierExtraction
                if runCaptions {
                    extraction = try await runner.dossier(
                        videoPath: path, atTimestamps: timestamps
                    )
                } else {
                    extraction = DossierExtraction.empty
                }
                let vlmSec = CFAbsoluteTimeGetCurrent() - vlmStart

                let didExtractCaptions = !extraction.scenes.isEmpty
                let userSkipped = userSkippedLaneIDs.contains(laneID)
                if let transcriber, runTranscript, !hasNoAudio, !userSkipped {
                    updateLane(
                        laneID,
                        stage: Self.stageDisplayName(forModelID: transcriber.modelID),
                        verb: "transcribing audio…",
                        hasCaptions: didExtractCaptions
                    )
                } else {
                    updateLane(laneID, hasCaptions: didExtractCaptions)
                }

                var transcript: String?
                var transcriptFailed = false
                var transcriptTimedOut = false
                if let transcriber, runTranscript, !hasNoAudio, !userSkipped {
                    let whisperDeadlineSeconds = max(60.0, 2.0 * record.durationSeconds)
                    do {
                        transcript = try await transcriber.transcribe(
                            videoPath: path,
                            deadlineSeconds: whisperDeadlineSeconds
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch AudioTranscriberError.deadlineExceeded(let secs) {
                        captionOrchLog.warning("Dossier: whisper deadline (\(secs, format: .fixed(precision: 0), privacy: .public)s) exceeded on \(filename, privacy: .public)")
                        transcriptTimedOut = true
                        transcriptFailures += 1
                    } catch {
                        captionOrchLog.warning("Dossier: whisper failed on \(filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        transcriptFailed = true
                        transcriptFailures += 1
                    }
                }

                _ = model.applyDossier(
                    extraction, to: path,
                    vlmModel: runner.modelID,
                    transcript: transcript,
                    whisperModel: transcript != nil ? transcriber?.modelID : nil
                )
                // didExtractTranscript matches what applyDossier banks
                // (empty / whitespace-only transcripts get filtered).
                // hasTranscript ✓ must follow banked truth, not "we
                // called Whisper" — same rationale as the captions
                // gate above. Empty transcripts on audio files are
                // common: Whisper on silent/music-only audio
                // legitimately returns "" — the dashboard should mark
                // that as "no useful content" (red ✗), not "got it ✓".
                let didExtractTranscript = (transcript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                if didExtractTranscript {
                    updateLane(laneID, hasTranscript: true)
                } else if transcriptFailed || transcriptTimedOut {
                    updateLane(laneID, transcriptFailed: true)
                }
                // Disambiguate the note:
                //   nil                → transcript obtained AND non-empty
                //   "no audio"         → file has no audio stream by design
                //   "user skipped"     → user right-clicked Skip on the lane
                //   "whisper timed out"→ subprocess exceeded deadline
                //   "transcript failed"→ whisper threw OR returned empty
                //   "no transcriber"   → serial path, no transcriber wired
                let note: String?
                if didExtractTranscript {
                    note = nil
                } else if userSkipped {
                    note = "user skipped"
                } else if hasNoAudio {
                    note = "no audio"
                } else if transcriptTimedOut {
                    note = "whisper timed out"
                } else if transcriptFailed {
                    note = "transcript failed"
                } else if transcriber != nil {
                    note = "transcript failed"   // whisper returned empty
                } else {
                    note = "no transcriber"
                }
                // Snapshot indicators via fromLane BEFORE endLane.
                // Serial path doesn't track Whisper duration separately
                // (it's inline awaited), so whisperSeconds stays nil
                // — matches historical behavior.
                recordCompletion(
                    fromLane: laneID,
                    vlmSeconds: vlmSec,
                    whisperSeconds: nil,
                    note: note
                )
                endLane(laneID)
                liveCaptioned += 1
            } catch is CancellationError {
                captionOrchLog.notice("Dossier: cancelled at \(filename, privacy: .public)")
                appLog.write("Dossier: cancelled mid-file \(filename) (done \(liveCaptioned), skipped \(liveSkipped), failed \(liveFailed))")
                clearActiveLanes()
                currentStatus = .finished(captioned: liveCaptioned, skipped: liveSkipped, failed: liveFailed)
                return
            } catch {
                endLane(laneID)
                liveFailed += 1
                captionOrchLog.warning("Dossier: error on \(filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }

            publishProgress(idx: idx + 1, total: total, currentFile: filename, started: started)
        }

        clearActiveLanes()

        let elapsed = CFAbsoluteTimeGetCurrent() - started
        let c = self.liveCaptioned, s = self.liveSkipped, f = self.liveFailed
        captionOrchLog.info("Dossier batch done: captioned=\(c), skipped=\(s), failed=\(f) in \(String(format: "%.1f", elapsed))s")
        appLog.write(String(format: "Dossier: done — %d processed, %d skipped, %d failed in %.1fs (%@)",
                            c, s, f, elapsed, stackID))
        currentStatus = .finished(captioned: c, skipped: s, failed: f)
    }

    // MARK: - Batch loop

    /// The heart of the orchestrator. Runs on the active task; calls
    /// back to MainActor for every status write and for the catalog
    /// writeback.
    ///
    /// nonisolated note: this function is on the MainActor (the class
    /// is @MainActor); the per-file work happens by stepping out via
    /// `await runner.caption(...)` which is `nonisolated` already.
    private func runBatch(
        runner: CaptionRunner,
        candidates: [VideoRecord],
        framesPerFile: Int,
        force: Bool,
        model: VideoScanModel
    ) async {
        let started = CFAbsoluteTimeGetCurrent()
        let total = candidates.count
        resetLiveCounts()
        liveTotal = total

        // Empty-batch fast path. Still surface a .finished status so
        // the progress sheet closes cleanly.
        guard total > 0 else {
            captionOrchLog.info("CaptionOrchestrator: zero candidates, nothing to do")
            appLog.write("Analyzing volume: no eligible videos under target")
            currentStatus = .finished(captioned: 0, skipped: 0, failed: 0)
            return
        }

        var captioned = 0
        var skipped = 0
        var failed = 0

        for (idx, record) in candidates.enumerated() {
            // Cancellation checkpoint #1: between files. Cheapest place
            // to stop — we haven't paid frame extraction or VLM cost
            // for the next file yet.
            if Task.isCancelled {
                captionOrchLog.notice("CaptionOrchestrator: cancelled at file \(idx) of \(total)")
                appLog.write("Analyzing volume: cancelled at file \(idx) of \(total) (analyzed \(captioned), skipped \(skipped), failed \(failed))")
                currentStatus = .finished(captioned: captioned, skipped: skipped, failed: failed)
                return
            }

            let path = record.fullPath
            let filename = record.filename

            // Idempotent skip: already captioned with this exact model.
            // The force flag bypasses for re-caption flows. Mirrors
            // applyCaptions's "replace wholesale" contract.
            if !force,
               !record.sceneCaptions.isEmpty,
               record.sceneCaptionModel == runner.modelID {
                skipped += 1
                liveSkipped = skipped
                captionOrchLog.debug("Skip already-captioned: \(filename, privacy: .public)")
                publishProgress(idx: idx + 1, total: total, currentFile: filename, started: started)
                continue
            }

            // File-existence check before extraction. AVAsset will
            // happily fail later, but bailing here avoids the runner's
            // throw path for the common "the file is gone" case.
            if !FileManager.default.fileExists(atPath: path) {
                failed += 1
                liveFailed = failed
                captionOrchLog.warning("File missing on disk: \(path, privacy: .public)")
                publishProgress(idx: idx + 1, total: total, currentFile: filename, started: started)
                continue
            }

            // Surface "now working on X" BEFORE the runner call so the
            // progress sheet's current-file label reflects the active
            // file while it's in flight.
            publishProgress(idx: idx, total: total, currentFile: filename, started: started)

            // Compute frame timestamps. Evenly-spaced inside the clip,
            // avoiding the first/last 5% the way the test fixture and
            // Python prototype do — those frames are often black or
            // partial.
            let dur = max(0.5, record.durationSeconds)
            let timestamps = framesEvenlySpaced(framesPerFile: framesPerFile, durationSec: dur)

            do {
                let captions = try await runner.caption(
                    videoPath: path,
                    atTimestamps: timestamps
                )

                // Writeback IMMEDIATELY at the file boundary. If the
                // user cancels the next file, this file's work is
                // already saved. saveCatalogDebounced batches the
                // actual disk write so we're not paying I/O per file.
                _ = model.applyCaptions(captions, to: path, model: runner.modelID)
                captioned += 1
                liveCaptioned = captioned
            } catch is CancellationError {
                // Cancellation surfaced from inside the runner's
                // frame loop. Don't count this file — just exit.
                captionOrchLog.notice("CaptionOrchestrator: runner observed cancellation at \(filename, privacy: .public)")
                appLog.write("Analyzing volume: cancelled mid-file \(filename) (analyzed \(captioned), skipped \(skipped), failed \(failed))")
                currentStatus = .finished(captioned: captioned, skipped: skipped, failed: failed)
                return
            } catch let err as CaptionRunnerError {
                // Typed engine failure: log + count + keep going. A
                // bad file shouldn't kill the batch.
                failed += 1
                liveFailed = failed
                captionOrchLog.warning("CaptionRunnerError on \(filename, privacy: .public): \(String(describing: err), privacy: .public)")
            } catch {
                // Unknown failure: same treatment, but log the raw
                // type so we can diagnose if a new failure mode shows
                // up.
                failed += 1
                liveFailed = failed
                captionOrchLog.warning("Unknown error on \(filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }

            publishProgress(idx: idx + 1, total: total, currentFile: filename, started: started)
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - started
        captionOrchLog.info("CaptionOrchestrator finished: captioned=\(captioned), skipped=\(skipped), failed=\(failed) in \(String(format: "%.1f", elapsed))s")
        appLog.write(String(format: "Caption Videos: done — captioned %d, skipped %d, failed %d in %.1fs",
                            captioned, skipped, failed, elapsed))
        currentStatus = .finished(captioned: captioned, skipped: skipped, failed: failed)
    }

    /// Publish a progress update with an ETA estimate. Runs on the
    /// MainActor (the class is @MainActor) so the @Published write is
    /// already on the UI thread.
    private func publishProgress(
        idx: Int, total: Int, currentFile: String, started: CFAbsoluteTime
    ) {
        liveCurrentIndex = idx
        // If we were asked to cancel, hold the status as .cancelling
        // even mid-progress — the loop will tear down on the next
        // cancellation check. Don't overwrite the cancelling state with
        // a stale "running" update.
        if case .cancelling = currentStatus { return }

        let done = idx
        let progress = total > 0 ? Double(done) / Double(total) : 0.0

        // ETA: only meaningful once we've finished at least one file.
        // Pure linear extrapolation — captioning time is roughly flat
        // per file once the model is loaded, so this is good enough.
        // Stage 6c may refine if Rick wants a better estimator.
        let etaSec: Int?
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        if done > 0, done < total, elapsed > 1.0 {
            let perFile = elapsed / Double(done)
            let remaining = perFile * Double(total - done)
            etaSec = Int(remaining)
        } else {
            etaSec = nil
        }

        currentStatus = .running(progress: progress, currentFile: currentFile, etaSec: etaSec)
    }

    // MARK: - In-flight counts
    //
    // The progress sheet needs to show captioned/skipped/failed counts
    // *during* the run, not just at the end. The batch loop updates
    // these as it goes; the sheet observes them via @Published.

    @Published var liveCaptioned: Int = 0
    @Published var liveSkipped: Int = 0
    @Published var liveFailed: Int = 0
    @Published var liveCurrentIndex: Int = 0
    @Published var liveTotal: Int = 0

    /// Whisper-stage failures during the current batch. A whisper
    /// failure still produces a valid VLM-only dossier — the file IS
    /// captioned, not failed — so we deliberately do NOT roll this
    /// into `liveFailed` (which is reserved for files that couldn't
    /// be dossiered at all). Separate counter so the dashboard can
    /// surface "transcribed N/M" honesty later. Reset alongside the
    /// other live counts at the top of each batch.
    @Published var transcriptFailures: Int = 0

    /// Reset for a fresh batch. Called from runBatch's start; tests
    /// can also call directly.
    func resetLiveCounts() {
        liveCaptioned = 0
        liveSkipped = 0
        liveFailed = 0
        liveCurrentIndex = 0
        liveTotal = 0
        transcriptFailures = 0
        // Stale user-skip flags from a prior batch must not leak into
        // a fresh run — a lane ID is per-batch and never reused, but
        // clearing the set keeps `userSkippedLaneIDs.contains(id)`
        // semantics honest under repeated batches.
        userSkippedLaneIDs.removeAll()
    }

    /// User-initiated skip on an in-flight file. Called from the
    /// dashboard's right-click → Skip on an active lane row.
    ///
    /// Behavior depends on which stage the lane is currently in:
    ///   - **Whisper stage** (most common — long subprocess): cancels
    ///     the in-flight `pendingWhisperTask`. The existing
    ///     CancellationError branch in the Whisper task banks VLM-only
    ///     and tags the completion `"user skipped"`. The Swift Task
    ///     cancellation propagates into AudioTranscriber's cancelTask
    ///     poll, which calls `proc.terminate()` on the Python whisper
    ///     subprocess.
    ///   - **VLM stage**: VLM inference is GPU work that doesn't
    ///     observe Swift cancellation cleanly, so we don't try to
    ///     cancel mid-VLM. Instead we mark the lane as user-skipped;
    ///     when the VLM finishes naturally the loop checks the set,
    ///     skips Whisper dispatch entirely, banks VLM-only, and tags
    ///     `"user skipped"`. Worst-case wait is one VLM duration —
    ///     usually <30s on M4 Max.
    ///
    /// Idempotent: re-skipping a lane that already finished is a no-op.
    func skipLane(_ id: UUID) {
        userSkippedLaneIDs.insert(id)
        // Whisper is the stuck case — if THIS lane is the one whose
        // Whisper is in flight, kill it now. Cancelling a nil task is
        // a no-op so the bookkeeping is safe even after the lane has
        // moved on.
        if pendingWhisperLaneID == id {
            pendingWhisperTask?.cancel()
        }
        captionOrchLog.notice("skipLane: user skipped lane \(id, privacy: .public)")
    }

    // MARK: - Live pipeline activity state
    //
    // Drives the dashboard's "Now Analyzing" / "Recently Completed"
    // panels. All mutation happens on the MainActor (the class is
    // @MainActor — including the chained Whisper tasks, which are
    // declared `Task { @MainActor in ... }`), so plain array writes
    // are safe without locking.

    /// In-flight stage lanes ("Now Analyzing"). Cleared when a batch
    /// settles — finished OR cancelled.
    @Published var activeLanes: [PipelineLane] = []

    /// Completed-file history ("Recently Completed") — newest first,
    /// capped at `recentActivityCap`. Deliberately NOT cleared at
    /// batch end: history persists until the next app run.
    @Published var recentActivity: [CompletedActivity] = []

    /// Hard cap on the history list. 8 rows fit the dashboard without
    /// scrolling; also the memory bound (a handful of small structs —
    /// worst case well under 8 KB).
    static let recentActivityCap = 8

    /// Cheap DRM probe via AVAsset. Loads only protected-content
    /// metadata (no decode, no audio extraction) — typically tens of
    /// milliseconds even on a slow disk. On any error (file gone,
    /// permission denied, AVFoundation choke) we return false so a
    /// transient miss falls through to the regular VLM/Whisper path
    /// instead of incorrectly marking the record drmProtected forever.
    ///
    /// Static + nonisolated so it doesn't pull the MainActor while
    /// AVAsset's metadata work runs on its own queue.
    nonisolated static func isDRMProtected(path: String) async -> Bool {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        do {
            return try await asset.load(.hasProtectedContent)
        } catch {
            return false
        }
    }

    /// Marker that goes into junkReasons when DRM detection flags a
    /// record. Constant so tests and any future UI surface can match
    /// on it without duplicating the string. Keep "DRM" capitalized
    /// so a future per-reason filter / chip can group on it.
    static let drmSuspectJunkReason = "DRM-protected (no decryption key)"

    /// Mark a record as drm-protected and propose suspectedJunk so it
    /// lands in Rick's triage flow for confirmation. Preserves any
    /// stronger pre-existing disposition — once the user has decided
    /// (important / recoverable / confirmedJunk) we don't second-guess
    /// them. Idempotent on junkReasons so re-flagging across multiple
    /// runs doesn't multiply the entry.
    ///
    /// Rick 2026-06-13: "auto-detect any DRM and skip it and even
    /// flag it as suspected Junk, and later I can confirm it as junk."
    static func flagDRMSuspectJunk(_ record: VideoRecord) {
        record.drmProtected = true
        if record.mediaDisposition == .unreviewed {
            record.mediaDisposition = .suspectedJunk
        }
        if !record.junkReasons.contains(drmSuspectJunkReason) {
            record.junkReasons.append(drmSuspectJunkReason)
        }
    }

    /// Marker that goes into junkReasons when the orchestrator
    /// auto-purges a record because the file isn't on disk anymore.
    /// Distinct from the DRM marker so the user (and future filters)
    /// can tell them apart at triage time.
    static let missingOnDiskReason = "auto-purged: missing on disk"

    /// Soft-purge a record whose underlying file went missing while
    /// the volume IS mounted. `purgedAt` excludes it from the
    /// candidate filter and the eligible coverage count; the row's
    /// "Analyze Complete" can then become true. junkReasons logs
    /// WHY so a future un-purge UI can show context. Idempotent.
    ///
    /// Rick 2026-06-13: "4228/5883 give the impression it is not done."
    /// Auto-purging missing-on-disk drops the denominator so it does.
    static func flagMissingOnDisk(_ record: VideoRecord) {
        if record.purgedAt == nil {
            record.purgedAt = Date()
        }
        if !record.junkReasons.contains(missingOnDiskReason) {
            record.junkReasons.append(missingOnDiskReason)
        }
    }

    /// Map an engine modelID to a short stage family name for the lane
    /// header. Unknown engines fall through to their raw modelID, so a
    /// new stage appears on the dashboard with zero UI changes.
    static func stageDisplayName(forModelID id: String) -> String {
        let lower = id.lowercased()
        if lower.contains("whisper") { return "Whisper" }
        if lower.contains("vlm") || lower.contains("qwen") { return "MLXVLM" }
        return id
    }

    /// Open a lane for a file entering the pipeline. Returns the lane
    /// id so the caller can target it from `updateLane` / `endLane`.
    /// Deduplicates by `path`: a stale lane for the same file (e.g.
    /// from a previous abandoned attempt) is replaced.
    @discardableResult
    func beginLane(
        path: String,
        filename: String,
        isVideoOnly: Bool,
        stage: String,
        verb: String
    ) -> UUID {
        let lane = PipelineLane(
            id: UUID(),
            path: path,
            filename: filename,
            stageName: stage,
            verb: verb,
            startedAt: Date(),
            isVideoOnly: isVideoOnly,
            hasCaptions: false,
            hasTranscript: false,
            transcriptFailed: false
        )
        activeLanes.removeAll { $0.path == path }
        activeLanes.append(lane)
        return lane.id
    }

    /// Patch fields on an active lane in place. Nil arguments leave the
    /// field unchanged — call with only the bits that actually changed
    /// (e.g. just `stage` + `verb` on a stage transition, or just
    /// `hasCaptions: true` when VLM banks its result). No-op if the
    /// lane has already ended.
    func updateLane(
        _ id: UUID,
        stage: String? = nil,
        verb: String? = nil,
        hasCaptions: Bool? = nil,
        hasTranscript: Bool? = nil,
        transcriptFailed: Bool? = nil
    ) {
        guard let i = activeLanes.firstIndex(where: { $0.id == id }) else { return }
        if let stage { activeLanes[i].stageName = stage }
        if let verb { activeLanes[i].verb = verb }
        if let hasCaptions { activeLanes[i].hasCaptions = hasCaptions }
        if let hasTranscript { activeLanes[i].hasTranscript = hasTranscript }
        if let transcriptFailed { activeLanes[i].transcriptFailed = transcriptFailed }
    }

    /// Close a lane. No-op if it was already cleared.
    func endLane(_ id: UUID) {
        activeLanes.removeAll { $0.id == id }
    }

    /// Batch settled (finished or cancelled) — nothing is in flight.
    func clearActiveLanes() {
        activeLanes.removeAll()
    }

    /// Prepend a completed file to the history, enforcing the cap.
    /// Indicator state is mirrored from the lane's final values; the
    /// dashboard's "Recently Completed" rows render ✓/✗/— from these
    /// (Rick 2026-06-13 — indicators moved off the in-flight lane).
    func recordCompletion(
        filename: String,
        path: String,
        vlmSeconds: Double?,
        whisperSeconds: Double?,
        note: String?,
        isVideoOnly: Bool = false,
        hasCaptions: Bool = false,
        hasTranscript: Bool = false,
        transcriptFailed: Bool = false
    ) {
        let entry = CompletedActivity(
            id: UUID(), filename: filename, path: path,
            vlmSeconds: vlmSeconds, whisperSeconds: whisperSeconds,
            note: note, syncedAt: Date(),
            isVideoOnly: isVideoOnly,
            hasCaptions: hasCaptions,
            hasTranscript: hasTranscript,
            transcriptFailed: transcriptFailed
        )
        recentActivity.insert(entry, at: 0)
        if recentActivity.count > Self.recentActivityCap {
            recentActivity.removeLast(recentActivity.count - Self.recentActivityCap)
        }
    }

    /// Snapshot the lane's indicator state and forward to recordCompletion.
    /// Callers should invoke BEFORE endLane(_:) so the lane is still in
    /// activeLanes when we read it. No-op if the lane has already been
    /// closed — the completion still records, just without indicators.
    func recordCompletion(
        fromLane laneID: UUID,
        vlmSeconds: Double?,
        whisperSeconds: Double?,
        note: String?
    ) {
        guard let lane = activeLanes.first(where: { $0.id == laneID }) else {
            // Defensive: lane already ended. Record without indicators
            // or path — the completion still shows in the history but
            // Show in Catalog won't have a target.
            recordCompletion(filename: "?", path: "",
                             vlmSeconds: vlmSeconds,
                             whisperSeconds: whisperSeconds, note: note)
            return
        }
        recordCompletion(
            filename: lane.filename,
            path: lane.path,
            vlmSeconds: vlmSeconds,
            whisperSeconds: whisperSeconds,
            note: note,
            isVideoOnly: lane.isVideoOnly,
            hasCaptions: lane.hasCaptions,
            hasTranscript: lane.hasTranscript,
            transcriptFailed: lane.transcriptFailed
        )
    }
}

// MARK: - Drain race latch

/// Thread-safe claim-once flag for the drain's completion-vs-deadline
/// race — whichever side claims first resumes the continuation; the
/// loser's claim fails and it does nothing. ≈ C++ `std::call_once`
/// guarding a promise's set_value.
private final class DrainOnceLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func tryClaim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}

// MARK: - Frame-timestamp helper
//
// `internal` so the test target can exercise it directly. Free
// function (not orchestrator method) so it stays pure and side-effect
// free — easy to unit-test without an orchestrator instance.

/// Returns N timestamps evenly spaced across the clip, skipping the
/// first and last 5%. Always returns exactly `framesPerFile` entries
/// (or fewer if the duration is unusably short).
func framesEvenlySpaced(framesPerFile: Int, durationSec: Double) -> [Double] {
    guard framesPerFile > 0, durationSec > 0 else { return [] }
    let safe = max(0.1, durationSec)
    // Avoid the first/last 5%. For a 3-second clip this is
    // 0.15s..2.85s — comfortably away from the leader/trailer.
    let lo = safe * 0.05
    let hi = safe * 0.95

    if framesPerFile == 1 {
        return [(lo + hi) / 2.0]
    }
    let stride = (hi - lo) / Double(framesPerFile - 1)
    return (0..<framesPerFile).map { i in lo + Double(i) * stride }
}
