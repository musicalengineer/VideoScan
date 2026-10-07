// CaptionOrchestrator+Dossier.swift
// The "steroids mode" dossier pipeline: per-volume and catalog-wide entry
// points plus the pipelined (VLM+Whisper overlap) and serial batch loops —
// extracted verbatim from CaptionOrchestrator.swift (refactor 2026-06-24).
// A cross-file `extension` can't see `private` members, so the orchestrator
// members this code shares with the other split files (activeTask, the
// pendingWhisper handles, userSkippedLaneIDs, the active-volume persistence
// helpers, publishProgress) were widened to internal in the main file.
// (Swift extension ≈ C++ partial class via free member functions: no new
// stored state allowed, methods share the same `self`.)

import Foundation
import Combine
import os

extension CaptionOrchestrator {

    /// Start dossier processing for files under a single volume.
    /// Rick 2026-06-13: replaces the global "Analyze Local Media"
    /// button with per-volume Analyze actions. The orchestrator filters
    /// the candidate list by `fullPath.hasPrefix(volumePrefix)` and
    /// otherwise behaves like `startCatalogWideDossier` — same
    /// idempotent skip, same DRM gate, same indicator pipeline.
    ///
    /// Phase 1 (today): only one volume can be ANALYZING at a time,
    /// but intent is never blocked — the dashboard enqueues further
    /// volumes via `enqueueAnalyze` (CaptionOrchestrator+Queue) and
    /// this method hands off to the queue head when the batch settles.
    /// Calling directly while busy is still a no-op (logged).
    ///
    /// Persisted to `DossierActiveVolumes` so auto-resume can pick up
    /// where we left off across launches.
    ///
    /// `ignoringScope`: the Analysis Scope gate applies to volume
    /// batches; a single-file AnalyzeJob (user right-clicked THIS
    /// file) passes true so explicit per-file intent always wins —
    /// e.g. "Transcribe Audio" on one mp3 must work with audio scoped
    /// out.
    ///
    /// Returns `true` when a batch actually ran (including the
    /// "nothing to do" empty-candidates outcome), `false` on refusal
    /// (shutting down / another batch active / empty prefix). AnalyzeJob
    /// uses the distinction to wait its turn instead of reporting a
    /// spurious failure when N single-file jobs start together.
    @discardableResult
    func startAnalyzing(
        volumePrefix: String,
        model: VideoScanModel,
        transcriber: AudioTranscriber? = nil,
        force: Bool = false,
        stages: Set<AnalyzeStage> = AnalyzeStage.all,
        ignoringScope: Bool = false
    ) async -> Bool {
        startAnalyzingAttempts += 1
        guard !isShuttingDown else {
            captionOrchLog.notice("startAnalyzing refused — app is shutting down")
            return false
        }
        // Queue hand-off on EVERY settle path (finished, stopped,
        // nothing-to-do). The busy-refusal return below is covered
        // too — scheduleQueueAdvance no-ops while a batch is active.
        defer { scheduleQueueAdvance(model: model) }
        guard !currentStatus.isActive else {
            captionOrchLog.warning("startAnalyzing(\(volumePrefix, privacy: .public)) refused — already \(String(describing: self.currentStatus))")
            return false
        }
        guard !volumePrefix.isEmpty else {
            captionOrchLog.warning("startAnalyzing refused — empty volumePrefix")
            return false
        }

        let resolvedTranscriber: AudioTranscriber? = transcriber ?? {
            // Test-host guard: a dev box with venv-mlx installed would
            // silently upgrade a unit test that reaches this entry
            // point (e.g. via the analyze queue) to a REAL Python
            // whisper subprocess. Tests that want a transcriber pass
            // a stub explicitly.
            guard !TestEnvironment.isTestHost else { return nil }
            let py = ToolLocator.mlxPythonPath
            guard !py.isEmpty else { return nil }
            // Persistent worker preferred (perf item 1, 2026-07-14):
            // ONE model load per batch instead of one per file — a
            // nightly batch of 888 files paid ~5 s × 888 ≈ 1.18 h in
            // pure whisper-medium reload with the per-file spawner.
            // The per-file script remains the automatic fallback when
            // the worker script isn't on disk.
            let worker = ToolLocator.whisperWorkerScriptPath
            if !worker.isEmpty {
                return WhisperWorkerTranscriber(pythonPath: py, scriptPath: worker)
            }
            let sc = ToolLocator.whisperScriptPath
            guard !sc.isEmpty else { return nil }
            return PythonSubprocessAudioTranscriber(pythonPath: py, scriptPath: sc)
        }()

        // Filter candidates to this volume only. We still go through
        // pfCatalogWideMetadataCandidates because that's where junk /
        // DRM / purge / reachability filtering lives. The Analysis
        // Scope gate sits right beside those gates — pure catalog
        // metadata, ZERO disk I/O, so out-of-scope files (music, camera
        // raws) never reach the per-file AVAsset DRM probe below.
        //
        // Single-file fast path (ride-along 2026-07-14): an AnalyzeJob
        // keys its batch by the record's EXACT fullPath. The old code
        // still ran the candidate predicate over ALL records per job —
        // an N-file multi-select paid N full ~103k-record passes on
        // the MainActor. When the prefix resolves to a cataloged file
        // via the O(1) path index, gate just that ONE record through
        // the SAME predicate (junk/purge/DRM/lifecycle semantics
        // unchanged). Volume prefixes don't match a record's exact
        // fullPath, so they fall through to the full pass as before.
        let base: [VideoRecord]
        if let exact = model.record(forPath: volumePrefix) {
            base = pfCatalogWideMetadataCandidates(
                records: [exact],
                reachableVolumePaths: [volumePrefix]
            )
        } else {
            base = pfCatalogWideMetadataCandidates(
                records: model.records,
                reachableVolumePaths: [volumePrefix]
            )
        }
        let candidates = ignoringScope
            ? base
            : pfAnalysisScopeCandidates(base, scope: analysisScope)
        if !ignoringScope, candidates.count != base.count {
            let tally = pfAnalysisScopeExclusionTally(base, scope: analysisScope)
            appLog.write("Dossier: scope set aside \(base.count - candidates.count) file(s) under \(VolumeReachability.displayLabel(forPath: volumePrefix)) — \(tally.audio) audio, \(tally.photos) photos (Analysis Scope on the dashboard re-includes audio)")
        }

        captionOrchLog.info("Per-volume dossier: \(candidates.count) candidate(s) under \(volumePrefix, privacy: .public); transcriber=\(resolvedTranscriber?.modelID ?? "none", privacy: .public)")
        appLog.write("Dossier: starting volume pass — \(candidates.count) eligible under \(VolumeReachability.displayLabel(forPath: volumePrefix))")

        guard !candidates.isEmpty else {
            captionOrchLog.info("Per-volume dossier: nothing to do under \(volumePrefix, privacy: .public)")
            currentStatus = .finished(captioned: 0, skipped: 0, failed: 0)
            return true
        }

        currentTarget = nil
        currentVolumePrefix = volumePrefix
        rememberActiveVolume(volumePrefix)
        currentStatus = .running(progress: 0.0, currentFile: "(loading model…)", etaSec: nil)
        self.force = force

        // Keep-alive (perf item 3, 2026-07-14): cached-or-fresh. N
        // multi-selected single-file AnalyzeJobs and every queued-
        // volume hand-off used to pay a fresh ~30s model load HERE.
        let runner = acquireRunner()
        let frames = self.framesPerFile
        let trans = resolvedTranscriber

        activeTask = Task { [weak self] in
            await self?.runDossierBatch(
                runner: runner,
                transcriber: trans,
                candidates: candidates,
                framesPerFile: frames,
                force: force,
                model: model,
                stages: stages
            )
        }
        await activeTask?.value
        currentVolumePrefix = nil
        forgetActiveVolume(volumePrefix)
        // Batch settled (finished OR cancelled) — keep the runner warm
        // and start the idle-release clock. The deferred
        // scheduleQueueAdvance below runs AFTER this; a dispatched
        // queue head re-acquires (and un-times) the same runner.
        armRunnerIdleTimer()
        return true
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
            // Same test-host guard as startAnalyzing — never spawn the
            // real whisper subprocess from a unit-test host.
            guard !TestEnvironment.isTestHost else { return nil }
            let py = ToolLocator.mlxPythonPath
            // Persistent worker preferred — same rationale + fallback
            // order as startAnalyzing above.
            let worker = ToolLocator.whisperWorkerScriptPath
            if !py.isEmpty, !worker.isEmpty {
                return WhisperWorkerTranscriber(pythonPath: py, scriptPath: worker)
            }
            let sc = ToolLocator.whisperScriptPath
            guard !py.isEmpty, !sc.isEmpty else {
                captionOrchLog.notice("Dossier: no MLX Python / whisper script — running VLM-only (mlxPython='\(py, privacy: .public)', script='\(sc, privacy: .public)')")
                return nil
            }
            return PythonSubprocessAudioTranscriber(pythonPath: py, scriptPath: sc)
        }()

        let reachablePaths = CatalogScanTarget.analyzeCandidates(model.scanTargets)
            .map { $0.searchPath }
        let base = pfCatalogWideMetadataCandidates(
            records: model.records,
            reachableVolumePaths: reachablePaths
        )
        // Analysis Scope gate — same placement rationale as
        // startAnalyzing: pure metadata, zero disk I/O, BEFORE the
        // per-file loop so out-of-scope files never hit the DRM probe.
        let candidates = pfAnalysisScopeCandidates(base, scope: analysisScope)
        if candidates.count != base.count {
            let tally = pfAnalysisScopeExclusionTally(base, scope: analysisScope)
            appLog.write("Dossier: scope set aside \(base.count - candidates.count) file(s) catalog-wide — \(tally.audio) audio, \(tally.photos) photos")
        }

        captionOrchLog.info("Catalog-wide dossier: \(candidates.count) candidate(s) across \(reachablePaths.count) volume(s); transcriber=\(resolvedTranscriber?.modelID ?? "none", privacy: .public)")
        appLog.write("Dossier: starting catalog-wide pass — \(candidates.count) eligible video(s), VLM=\(MLXVLMCaptionRunner().modelID), transcriber=\(resolvedTranscriber?.modelID ?? "none"), force=\(force)")

        guard !candidates.isEmpty else {
            currentStatus = .finished(captioned: 0, skipped: 0, failed: 0)
            return
        }

        currentTarget = nil
        currentStatus = .running(progress: 0.0, currentFile: "(loading model…)", etaSec: nil)
        self.force = force

        // Keep-alive: same cached-or-fresh hand-off as startAnalyzing.
        let runner = acquireRunner()
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
        // Batch settled — arm the idle-release clock (no-op once
        // shutdown began).
        armRunnerIdleTimer()
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
    ///
    /// Shape (2026-10-07 split): this function is only the driver. Each
    /// file goes preflight (`preflightDossierFile`, shared with the serial
    /// loop) → `runPipelinedDossierFile` (scenes, hand-off) → the Whisper
    /// task (`transcribeAndBankDossier`); the batch ends in
    /// `finishDossierBatch`, also shared.
    func runDossierBatch(
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

        // Register the persistent Whisper worker (if that's what the
        // transcriber is) so cancel()/drainForShutdown() can kill its
        // subprocess immediately. Registered BEFORE the serial-path
        // guard so both loops are covered; cleared on every settle
        // path via settleWhisperWorker.
        activeWhisperWorker = transcriber as? WhisperWorkerTranscriber

        let stackID: String = transcriber.map { "\(runner.modelID)+\($0.modelID)" } ?? runner.modelID

        // Stage gating (Rick 2026-06-14): "Transcribe Audio" and "Generate
        // Scene Captions" do ONLY that thing. The pipelined overlap only
        // pays when BOTH stages run with a transcriber, so anything else
        // takes the serial path, which is honest and simpler.
        guard let transcriber, stages.contains(.captions), stages.contains(.transcript) else {
            await runDossierBatchSerial(
                runner: runner, transcriber: transcriber,
                candidates: candidates, framesPerFile: framesPerFile,
                force: force, model: model, stackID: stackID, started: started,
                stages: stages
            )
            return
        }

        // Whisper task for the previous file. Awaited before the next
        // Whisper dispatch (backpressure) and once after the loop so the
        // summary sees final counts. Mirrored into `self.pendingWhisperTask`
        // / `self.pendingWhisperLaneID` so `skipLane(_:)` can cancel exactly
        // the right task from the UI.
        var pendingWhisper: Task<Void, Never>?

        for (idx, record) in candidates.enumerated() {
            if Task.isCancelled {
                captionOrchLog.notice("Dossier: VLM cancelled at file \(idx) of \(total)")
                break
            }
            // The in-flight Whisper task (file N-1) keeps running while
            // paused; only the next file's VLM waits.
            await waitWhileDossierPaused()
            if Task.isCancelled { break }

            guard let plan = await preflightDossierFile(
                record, index: idx, total: total, force: force,
                framesPerFile: framesPerFile, started: started
            ) else { continue }

            let control = await runPipelinedDossierFile(
                plan, runner: runner, transcriber: transcriber, model: model,
                total: total, started: started, pendingWhisper: &pendingWhisper
            )
            if control == .stop { break }
        }

        // pendingWhisper is unstructured, so cancellation of the batch
        // task doesn't propagate automatically — forward it explicitly
        // so a cancelled batch doesn't block shutdown on a long
        // transcription (the task's CancellationError path still applies
        // the VLM result).
        if Task.isCancelled { pendingWhisper?.cancel() }
        await pendingWhisper?.value
        // Batch fully drained — a late skipLane(_:) (e.g. a UI race
        // during shutdown) is then a clean no-op.
        self.pendingWhisperTask = nil
        self.pendingWhisperLaneID = nil

        await finishDossierBatch(model: model, transcriber: transcriber, stackID: stackID,
                                 started: started, reportCancellation: true)
    }

    /// One file of the pipelined batch: extract scenes, then either bank
    /// them alone (cancelled / skipped / video-only) or hand off to a
    /// Whisper task once the previous file's Whisper has finished.
    /// ONE dashboard lane per file across both stages.
    func runPipelinedDossierFile(
        _ plan: DossierFilePlan,
        runner: CaptionRunner,
        transcriber: AudioTranscriber,
        model: VideoScanModel,
        total: Int,
        started: CFAbsoluteTime,
        pendingWhisper: inout Task<Void, Never>?
    ) async -> DossierLoopControl {
        let vlmModelID = runner.modelID
        let whisperStage = Self.stageDisplayName(forModelID: transcriber.modelID)
        // Audio-class files open directly on the Whisper stage.
        let laneID = beginLane(
            path: plan.path,
            filename: plan.filename,
            isVideoOnly: plan.hasNoAudio,
            stage: plan.hasNoVideo ? whisperStage : Self.stageDisplayName(forModelID: vlmModelID),
            verb: plan.hasNoVideo ? "transcribing audio…" : "extracting scenes…"
        )

        do {
            let (extraction, vlmSec) = try await extractDossierScenes(plan, runner: runner)
            // hasCaptions reflects banked content: green only when scenes
            // is non-empty (Rick 2026-06-13: music videos with "0 scenes"
            // were lighting up ✓).
            let hasCaptions = !extraction.scenes.isEmpty
            if plan.hasNoAudio {
                updateLane(laneID, hasCaptions: hasCaptions)
            } else {
                updateLane(
                    laneID,
                    stage: whisperStage,
                    verb: pendingWhisper == nil ? "transcribing audio…" : "waiting for prior transcript…",
                    hasCaptions: hasCaptions
                )
            }
            appLog.write(String(format: "Pipeline VLM done: %@ — %.1fs (%d scene(s))", plan.filename, vlmSec, extraction.scenes.count))

            // Backpressure: at most one Whisper outstanding; every VLM
            // result is handed off, never dropped.
            await pendingWhisper?.value
            pendingWhisper = nil
            self.pendingWhisperTask = nil
            self.pendingWhisperLaneID = nil
            if !plan.hasNoAudio {
                updateLane(laneID, verb: "transcribing audio…")
            }

            if let reason = vlmOnlyReason(laneID: laneID, plan: plan) {
                bankVLMOnly(extraction, plan, model: model, vlmModelID: vlmModelID)
                completeDossierLane(laneID, vlmSeconds: vlmSec, whisperSeconds: nil,
                                    note: reason.note(hasNoAudio: plan.hasNoAudio))
                // Cancelled while waiting on the previous Whisper: stop
                // the batch (no progress tick). Skip / video-only: next.
                if reason == .cancelledWhileWaiting { return .stop }
                publishProgress(idx: plan.index + 1, total: total, currentFile: plan.filename, started: started)
                return .next
            }

            // Publish the lane ID BEFORE the task exists so a simultaneous
            // skipLane(_:) finds its target the moment the task is mirrored.
            self.pendingWhisperLaneID = laneID
            // Per-file deadline: max(60 s floor, 2× clip). Whisper runs at
            // 5–15× realtime on the M4 Max, so anything past 2× is hung
            // (a music video once wedged the pipeline for 26+ minutes).
            let deadline = max(60.0, 2.0 * plan.record.durationSeconds)
            pendingWhisper = Task { @MainActor [weak self] in
                await self?.transcribeAndBankDossier(
                    plan, extraction: extraction, vlmSeconds: vlmSec, laneID: laneID,
                    deadlineSeconds: deadline, transcriber: transcriber, model: model,
                    vlmModelID: vlmModelID, total: total, started: started)
            }
            // Mirrored outside the closure (a Task's closure can't capture
            // the var it's being assigned to).
            self.pendingWhisperTask = pendingWhisper
            return .next
        } catch is CancellationError {
            endLane(laneID)
            captionOrchLog.notice("Dossier: VLM cancellation at \(plan.filename, privacy: .public)")
            return .stop
        } catch {
            countDossierExtractionFailure(laneID, filename: plan.filename, error: error, label: "VLM error")
            publishProgress(idx: plan.index + 1, total: total, currentFile: plan.filename, started: started)
            return .next
        }
    }

    /// Why a file's scenes are banked WITHOUT a transcript; nil when
    /// Whisper should run. Checked in this order: cancelled while waiting
    /// for the previous Whisper; the user's Skip (wins over the video-only
    /// bypass so the note is attributed right); a video-only file.
    enum VLMOnlyReason {
        case cancelledWhileWaiting, userSkipped, videoOnly

        func note(hasNoAudio: Bool) -> String {
            switch self {
            case .cancelledWhileWaiting: return hasNoAudio ? "no audio" : "transcript failed"
            case .userSkipped: return "user skipped"
            case .videoOnly: return "no audio"
            }
        }
    }

    func vlmOnlyReason(laneID: UUID, plan: DossierFilePlan) -> VLMOnlyReason? {
        if Task.isCancelled { return .cancelledWhileWaiting }
        if userSkippedLaneIDs.contains(laneID) { return .userSkipped }
        if plan.hasNoAudio { return .videoOnly }
        return nil
    }

    /// Run the scene extractor (skipped for audio-class files) and flag
    /// files whose codec it evidently couldn't decode.
    func extractDossierScenes(_ plan: DossierFilePlan, runner: CaptionRunner) async throws -> (DossierExtraction, Double) {
        let vlmStart = CFAbsoluteTimeGetCurrent()
        let extraction: DossierExtraction = plan.hasNoVideo
            ? .empty
            : try await runner.dossier(videoPath: plan.path, atTimestamps: plan.timestamps)
        let vlmSec = CFAbsoluteTimeGetCurrent() - vlmStart
        flagUndecodableIfExtractorBailed(plan, extraction: extraction, vlmSeconds: vlmSec)
        return (extraction, vlmSec)
    }

    /// "0 scenes in <1 s" is the signature of the AVFoundation frame
    /// extractor bailing on a codec it can't decode (svq3, qdm2, cinepak…);
    /// a real VLM run on a black video takes 5–15 s. Flag the record so the
    /// catalog shows a red "!" and offers Reformat and Analyze (Rick
    /// 2026-06-14). Dynamic backstop to the static codec heuristic
    /// (`isLikelyUnanalyzable`). Audio-class files skip VLM by design.
    func flagUndecodableIfExtractorBailed(_ plan: DossierFilePlan, extraction: DossierExtraction, vlmSeconds: Double) {
        let record = plan.record
        guard !plan.hasNoVideo, extraction.scenes.isEmpty, vlmSeconds < 1.0, !record.needsReformat else { return }
        record.needsReformat = true
        captionOrchLog.notice("Dossier: VLM bailed in \(vlmSeconds, format: .fixed(precision: 2), privacy: .public)s with 0 scenes — flagging \(plan.filename, privacy: .public) needsReformat")
        appLog.write(String(format: "Dossier: flagged needsReformat (codec couldn't be decoded): %@", plan.filename))
    }

    /// The Whisper stage of one pipelined file: transcribe, bank the full
    /// dossier, close the lane. Runs as the unstructured `pendingWhisper`
    /// task so the next file's VLM can overlap it.
    func transcribeAndBankDossier(
        _ plan: DossierFilePlan,
        extraction: DossierExtraction,
        vlmSeconds vlmSec: Double,
        laneID: UUID,
        deadlineSeconds: Double,
        transcriber: AudioTranscriber,
        model: VideoScanModel,
        vlmModelID: String,
        total: Int,
        started: CFAbsoluteTime
    ) async {
        let filename = plan.filename
        appLog.write(String(format: "Pipeline Whisper start: %@ (deadline %.0fs)", filename, deadlineSeconds))
        let whisperStart = CFAbsoluteTimeGetCurrent()
        var transcript: String?
        do {
            transcript = try await transcriber.transcribe(videoPath: plan.path, deadlineSeconds: deadlineSeconds)
        } catch is CancellationError {
            // Cancelled mid-transcription: the scenes still bank. The note
            // says who pulled the cord: the user's Skip, or a batch cancel.
            bankVLMOnly(extraction, plan, model: model, vlmModelID: vlmModelID)
            let userSkipped = userSkippedLaneIDs.contains(laneID)
            updateLane(laneID, transcriptFailed: !userSkipped)
            completeDossierLane(laneID, vlmSeconds: vlmSec, whisperSeconds: nil,
                                note: userSkipped ? "user skipped" : "transcript failed")
            return
        } catch AudioTranscriberError.deadlineExceeded(let secs) {
            // Auto-kill past the deadline. Captions are still valid; the
            // distinct note lets chronically stuck files be triaged.
            captionOrchLog.warning("Dossier: whisper deadline (\(secs, format: .fixed(precision: 0), privacy: .public)s) exceeded on \(filename, privacy: .public)")
            bankVLMOnly(extraction, plan, model: model, vlmModelID: vlmModelID)
            updateLane(laneID, transcriptFailed: true)
            completeDossierLane(laneID, vlmSeconds: vlmSec, whisperSeconds: nil, note: "whisper timed out")
            transcriptFailures += 1
            return
        } catch {
            captionOrchLog.warning("Dossier: whisper failed on \(filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
            transcript = nil
            transcriptFailures += 1
        }

        _ = model.applyDossier(
            extraction, to: plan.path,
            vlmModel: vlmModelID,
            transcript: transcript,
            whisperModel: transcript != nil ? transcriber.modelID : nil
        )
        let whisperSec = CFAbsoluteTimeGetCurrent() - whisperStart
        appLog.write(String(format: "Pipeline Whisper done: %@ — %.1fs", filename, whisperSec))
        // ✓ follows banked truth: an empty / whitespace-only transcript
        // is "transcript failed", not a checkmark.
        let usable = Self.isUsableTranscript(transcript)
        if usable {
            updateLane(laneID, hasTranscript: true)
        } else {
            updateLane(laneID, transcriptFailed: true)
        }
        completeDossierLane(laneID, vlmSeconds: vlmSec,
                            whisperSeconds: usable ? whisperSec : nil,
                            note: usable ? nil : "transcript failed")
        publishProgress(idx: plan.index + 1, total: total, currentFile: filename, started: started)
    }

    /// Serial batch: one file at a time, both stages inline. Used when no
    /// transcriber is configured or only one stage was asked for.
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

        // Same worker registration as the pipelined loop (idempotent
        // when we arrived via runDossierBatch's serial-path guard).
        activeWhisperWorker = transcriber as? WhisperWorkerTranscriber

        for (idx, record) in candidates.enumerated() {
            if Task.isCancelled {
                captionOrchLog.notice("Dossier: cancelled at file \(idx) of \(total)")
                appLog.write("Dossier: cancelled at file \(idx) of \(total) (done \(liveCaptioned), skipped \(liveSkipped), failed \(liveFailed))")
                await settleCancelledDossierBatch(transcriber)
                return
            }
            await waitWhileDossierPaused()
            if Task.isCancelled {
                await settleCancelledDossierBatch(transcriber)
                return
            }

            guard let plan = await preflightDossierFile(
                record, index: idx, total: total, force: force,
                framesPerFile: framesPerFile, started: started
            ) else { continue }

            if await runSerialDossierFile(plan, runner: runner, transcriber: transcriber,
                                          model: model, stages: stages) == .stop {
                await settleCancelledDossierBatch(transcriber)
                return
            }
            publishProgress(idx: idx + 1, total: total, currentFile: plan.filename, started: started)
        }

        await finishDossierBatch(model: model, transcriber: transcriber, stackID: stackID,
                                 started: started, reportCancellation: false)
    }

    /// One file of the serial batch: scenes (unless transcript-only or
    /// audio-class), then the transcript (unless captions-only, video-only
    /// or skipped), then bank and close the lane.
    func runSerialDossierFile(
        _ plan: DossierFilePlan,
        runner: CaptionRunner,
        transcriber: AudioTranscriber?,
        model: VideoScanModel,
        stages: Set<AnalyzeStage>
    ) async -> DossierLoopControl {
        // Audio-class files open directly on the transcribe stage.
        let laneStage: String = {
            if plan.hasNoVideo, let transcriber {
                return Self.stageDisplayName(forModelID: transcriber.modelID)
            }
            return Self.stageDisplayName(forModelID: runner.modelID)
        }()
        let laneID = beginLane(
            path: plan.path,
            filename: plan.filename,
            isVideoOnly: plan.hasNoAudio,
            stage: laneStage,
            verb: plan.hasNoVideo ? "transcribing audio…" : "extracting scenes…"
        )

        do {
            // Stage gating (Rick 2026-06-14): transcript-only skips VLM;
            // the empty extraction propagates "no captions" cleanly.
            let vlmStart = CFAbsoluteTimeGetCurrent()
            let extraction: DossierExtraction = stages.contains(.captions) && !plan.hasNoVideo
                ? try await runner.dossier(videoPath: plan.path, atTimestamps: plan.timestamps)
                : DossierExtraction.empty
            let vlmSec = CFAbsoluteTimeGetCurrent() - vlmStart

            let hasCaptions = !extraction.scenes.isEmpty
            let userSkipped = userSkippedLaneIDs.contains(laneID)
            // The transcriber to run for this file, if any.
            let whisper = stages.contains(.transcript) && !plan.hasNoAudio && !userSkipped ? transcriber : nil
            if let whisper {
                updateLane(laneID, stage: Self.stageDisplayName(forModelID: whisper.modelID),
                           verb: "transcribing audio…", hasCaptions: hasCaptions)
            } else {
                updateLane(laneID, hasCaptions: hasCaptions)
            }

            let outcome = try await serialTranscribe(plan, with: whisper)

            _ = model.applyDossier(
                extraction, to: plan.path,
                vlmModel: runner.modelID,
                transcript: outcome.transcript,
                whisperModel: outcome.transcript != nil ? transcriber?.modelID : nil
            )
            let usable = Self.isUsableTranscript(outcome.transcript)
            if usable {
                updateLane(laneID, hasTranscript: true)
            } else if outcome.failed || outcome.timedOut {
                updateLane(laneID, transcriptFailed: true)
            }
            // The serial path awaits Whisper inline and doesn't time it
            // separately: whisperSeconds stays nil (historical behaviour).
            completeDossierLane(laneID, vlmSeconds: vlmSec, whisperSeconds: nil,
                                note: Self.serialDossierNote(
                                    usableTranscript: usable, userSkipped: userSkipped,
                                    hasNoAudio: plan.hasNoAudio, timedOut: outcome.timedOut,
                                    failed: outcome.failed, hasTranscriber: transcriber != nil))
            return .next
        } catch is CancellationError {
            captionOrchLog.notice("Dossier: cancelled at \(plan.filename, privacy: .public)")
            appLog.write("Dossier: cancelled mid-file \(plan.filename) (done \(liveCaptioned), skipped \(liveSkipped), failed \(liveFailed))")
            return .stop
        } catch {
            countDossierExtractionFailure(laneID, filename: plan.filename, error: error, label: "error")
            return .next
        }
    }

    /// What the serial path's inline Whisper call produced.
    struct SerialTranscriptOutcome {
        var transcript: String?
        var failed = false
        var timedOut = false
    }

    /// Transcribe inline (nil `whisper` = this file gets no transcript).
    /// Cancellation propagates; a deadline or any other error is recorded
    /// and the file still banks its scenes.
    func serialTranscribe(_ plan: DossierFilePlan, with whisper: AudioTranscriber?) async throws -> SerialTranscriptOutcome {
        var outcome = SerialTranscriptOutcome()
        guard let whisper else { return outcome }
        let deadline = max(60.0, 2.0 * plan.record.durationSeconds)
        do {
            outcome.transcript = try await whisper.transcribe(videoPath: plan.path, deadlineSeconds: deadline)
        } catch is CancellationError {
            throw CancellationError()
        } catch AudioTranscriberError.deadlineExceeded(let secs) {
            captionOrchLog.warning("Dossier: whisper deadline (\(secs, format: .fixed(precision: 0), privacy: .public)s) exceeded on \(plan.filename, privacy: .public)")
            outcome.timedOut = true
            transcriptFailures += 1
        } catch {
            captionOrchLog.warning("Dossier: whisper failed on \(plan.filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
            outcome.failed = true
            transcriptFailures += 1
        }
        return outcome
    }

    /// The activity-feed note for a serial-path file:
    ///   nil                 → transcript obtained and non-empty
    ///   "user skipped"      → the user right-clicked Skip on the lane
    ///   "no audio"          → the file has no audio stream by design
    ///   "whisper timed out" → the subprocess exceeded its deadline
    ///   "transcript failed" → Whisper threw, or returned only whitespace
    ///   "no transcriber"    → no transcriber wired
    static func serialDossierNote(
        usableTranscript: Bool, userSkipped: Bool, hasNoAudio: Bool,
        timedOut: Bool, failed: Bool, hasTranscriber: Bool
    ) -> String? {
        if usableTranscript { return nil }
        if userSkipped { return "user skipped" }
        if hasNoAudio { return "no audio" }
        if timedOut { return "whisper timed out" }
        if failed { return "transcript failed" }
        return hasTranscriber ? "transcript failed" : "no transcriber"
    }

    /// Batch-settle hook for the persistent Whisper worker (perf item
    /// 1, 2026-07-14): terminate the worker subprocess so a settled
    /// batch never leaves a model-loaded Python process behind, and
    /// drop the lifecycle reference so late cancel()/drain calls are
    /// clean no-ops. Called on EVERY settle path of both batch loops
    /// (finish, cancel, pause-then-cancel). No-op for stub / per-file
    /// transcribers. The worker's own 120 s idle timeout is the
    /// backstop for any path that slips past this.
    func settleWhisperWorker(_ transcriber: AudioTranscriber?) async {
        activeWhisperWorker = nil
        guard let worker = transcriber as? WhisperWorkerTranscriber else { return }
        await worker.shutdown()
    }
}
