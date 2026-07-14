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
            let py = ToolLocator.mlxPythonPath
            let sc = ToolLocator.whisperScriptPath
            guard !py.isEmpty, !sc.isEmpty else { return nil }
            return PythonSubprocessAudioTranscriber(pythonPath: py, scriptPath: sc)
        }()

        // Filter candidates to this volume only. We still go through
        // pfCatalogWideMetadataCandidates because that's where junk /
        // DRM / purge / reachability filtering lives. The Analysis
        // Scope gate sits right beside those gates — pure catalog
        // metadata, ZERO disk I/O, so out-of-scope files (music, camera
        // raws) never reach the per-file AVAsset DRM probe below.
        let base = pfCatalogWideMetadataCandidates(
            records: model.records,
            reachableVolumePaths: [volumePrefix]
        )
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
                model: model,
                stages: stages
            )
        }
        await activeTask?.value
        currentVolumePrefix = nil
        forgetActiveVolume(volumePrefix)
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
            let py = ToolLocator.mlxPythonPath
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
                liveSkipAlreadyAnalyzed += 1
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
                liveSkipMissing += 1
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
            // candidate filter excludes on subsequent runs. Note the
            // Analysis Scope gate already ran at candidate-filter time —
            // out-of-scope files (music, camera raws) never get here, so
            // this probe only spends I/O on genuinely analyzable files.
            if record.drmProtected {
                liveSkipped += 1
                liveSkipProtected += 1
                captionOrchLog.notice("Dossier: skip DRM-protected (cached): \(filename, privacy: .public)")
                appLog.write("Dossier: skip protected (can't read): \(filename)")
                publishProgress(idx: idx + 1, total: total, currentFile: filename, started: started)
                continue
            }
            if await Self.isDRMProtected(path: path) {
                Self.flagDRMSuspectJunk(record)
                liveSkipped += 1
                liveSkipProtected += 1
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

            // Symmetric gate for audio-classified records (in a batch
            // only when Analysis Scope includes audio, or via a
            // single-file AnalyzeJob): NO frame extraction / VLM.
            // Extension-aware — an mp3 with embedded cover art probes
            // as Video+Audio, and feeding it to the frame extractor is
            // the exact waste the 2026-07-14 diagnosis caught.
            let hasNoVideo = {
                if case .audio = AnalysisScope.classify(
                    streamTypeRaw: record.streamTypeRaw,
                    filename: filename) { return true }
                return false
            }()

            // Open this file's dashboard lane. ONE lane per file across
            // both stages — VLM and Whisper transitions mutate it in
            // place so the user sees one row tick through the pipeline
            // with the per-channel ✓/✗/— indicators lighting up.
            // Audio-class files open directly on the Whisper stage.
            let laneID = beginLane(
                path: path,
                filename: filename,
                isVideoOnly: hasNoAudio,
                stage: hasNoVideo
                    ? Self.stageDisplayName(forModelID: whisperModelID)
                    : Self.stageDisplayName(forModelID: vlmModelID),
                verb: hasNoVideo ? "transcribing audio…" : "extracting scenes…"
            )

            do {
                let vlmStart = CFAbsoluteTimeGetCurrent()
                let extraction: DossierExtraction = hasNoVideo
                    ? .empty
                    : try await runner.dossier(
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
                // their failure signature. Audio-class records skipped
                // VLM by design — "0 scenes instantly" is expected, not
                // a decode failure, so they must not be flagged.
                if !hasNoVideo && !didExtractCaptions && vlmSec < 1.0 && !record.needsReformat {
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
                // One visible line per failure — the 2026-07-14 perf
                // diagnosis found 1,097 failed extraction attempts that
                // produced ~1 log line total, which is what kept 3.1 h
                // of nightly waste invisible.
                appLog.write("Dossier: failed (extraction error): \(filename) — \(error.localizedDescription)")
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
        appLog.write(String(format: "Dossier: done — %d processed, %d skipped (%d already analyzed, %d missing, %d protected), %d failed in %.1fs (%@)",
                            captioned, skipped,
                            liveSkipAlreadyAnalyzed, liveSkipMissing, liveSkipProtected,
                            failed, elapsed, stackID))
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
                liveSkipAlreadyAnalyzed += 1
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
                liveSkipMissing += 1
                captionOrchLog.notice("Dossier: missing on disk → auto-purged: \(path, privacy: .public)")
                appLog.write("Dossier: auto-purged missing on disk: \(filename)")
                publishProgress(idx: idx + 1, total: total, currentFile: filename, started: started)
                continue
            }

            // DRM gate — same semantics as the pipelined path.
            if record.drmProtected {
                liveSkipped += 1
                liveSkipProtected += 1
                captionOrchLog.notice("Dossier: skip DRM-protected (cached): \(filename, privacy: .public)")
                appLog.write("Dossier: skip protected (can't read): \(filename)")
                publishProgress(idx: idx + 1, total: total, currentFile: filename, started: started)
                continue
            }
            if await Self.isDRMProtected(path: path) {
                Self.flagDRMSuspectJunk(record)
                liveSkipped += 1
                liveSkipProtected += 1
                captionOrchLog.notice("Dossier: skip DRM-protected (probed, → suspectedJunk): \(filename, privacy: .public)")
                appLog.write("Dossier: skip DRM-protected: \(filename) (flagged suspectedJunk)")
                publishProgress(idx: idx + 1, total: total, currentFile: filename, started: started)
                continue
            }

            publishProgress(idx: idx, total: total, currentFile: filename, started: started)

            let dur = max(0.5, record.durationSeconds)
            let timestamps = framesEvenlySpaced(framesPerFile: framesPerFile, durationSec: dur)

            let hasNoAudio = (record.streamType == .videoOnly)

            // Symmetric no-video gate — same rationale as the pipelined
            // path: audio-classified records (mp3 cover art probes as a
            // video stream; here via single-file AnalyzeJob or scope-ON
            // batches) must never reach frame extraction / VLM.
            let hasNoVideo = {
                if case .audio = AnalysisScope.classify(
                    streamTypeRaw: record.streamTypeRaw,
                    filename: filename) { return true }
                return false
            }()

            // One lane per file. Stage transitions VLM → Whisper happen
            // in place via updateLane so the dashboard shows a single
            // row per file with the per-channel indicators lighting up.
            // Audio-class files open directly on the transcribe stage.
            let laneStage: String = {
                if hasNoVideo, let transcriber {
                    return Self.stageDisplayName(forModelID: transcriber.modelID)
                }
                return Self.stageDisplayName(forModelID: runner.modelID)
            }()
            let laneID = beginLane(
                path: path,
                filename: filename,
                isVideoOnly: hasNoAudio,
                stage: laneStage,
                verb: hasNoVideo ? "transcribing audio…" : "extracting scenes…"
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
                if runCaptions && !hasNoVideo {
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
                // One visible line per failure — same observability rule
                // as the pipelined path (2026-07-14: 1,097 silent fails).
                appLog.write("Dossier: failed (extraction error): \(filename) — \(error.localizedDescription)")
            }

            publishProgress(idx: idx + 1, total: total, currentFile: filename, started: started)
        }

        clearActiveLanes()

        let elapsed = CFAbsoluteTimeGetCurrent() - started
        let c = self.liveCaptioned, s = self.liveSkipped, f = self.liveFailed
        captionOrchLog.info("Dossier batch done: captioned=\(c), skipped=\(s), failed=\(f) in \(String(format: "%.1f", elapsed))s")
        appLog.write(String(format: "Dossier: done — %d processed, %d skipped (%d already analyzed, %d missing, %d protected), %d failed in %.1fs (%@)",
                            c, s,
                            liveSkipAlreadyAnalyzed, liveSkipMissing, liveSkipProtected,
                            f, elapsed, stackID))
        currentStatus = .finished(captioned: c, skipped: s, failed: f)
    }
}
