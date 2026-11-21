import Combine
import Foundation
import os

// MARK: - TranscodeJob
//
// "Transcode" — Rick 2026-06-14 (Pass C). Faithful conversion to an
// editing, access, or preservation derivative. Unlike ReformatJob (which deinterlaces +
// denoises + analyses), Transcode does NO filtering and does NOT
// auto-queue Analyze: the user clicked Transcode because they want a
// derivative for editing, access, or preservation — auto-analysis would
// just step on the workflow.
//
// Why these presets and not a generic codec picker:
//   - Editing       → drop into FCP, let FCP own the export. ProRes 422 LT
//     is the default for VHS; HQ remains available for demanding sources.
//   - Archival      → "access copy" for everyday viewing / sharing.
//     Wants HEVC 10-bit (5-10× smaller than ProRes for the same
//     perceptual quality) + AAC. Universal AVFoundation playback.
//   - Preservation  → the actual master we hand to an archive (possible
//     Library of Congress deposit). FFV1 v3 in Matroska, MATHEMATICALLY
//     LOSSLESS, then PROVEN bit-exact against the source with a frame
//     MD5 pass. Correctness > speed. See the .preservation branch below.
//
// Audio-codec invariant — the lossy/undecodable rule:
//   Editing + Archival HARD-CODE the audio codec; they never `-c:a copy`.
//   Some 1990s captures carry QDM2/MP3 audio that AVFoundation can't
//   decode; copying it through would silently produce a file FCP/QuickTime
//   can't play. PCM (Editing) and AAC (Archival) are both
//   AVFoundation-native — the TranscodeTests suite asserts this guarantee
//   so a future regression breaks loudly.
//
//   The Preservation preset is the ONE sanctioned exception, and only for
//   already-lossless PCM source audio (see "match source" in the
//   .preservation branch). That is NOT a violation of the invariant: the
//   invariant exists to stop lossy/undecodable audio leaking into a
//   playback derivative; a PCM-verbatim copy into a preservation master is
//   the exact opposite intent — it's the most faithful thing we can do.
//
// Memory: ffmpeg streams; we hold no media in-process beyond the progress
// lines (worst case ~200 bytes per stderr write). The Preservation
// verification step captures framemd5 stdout in memory: ~70 bytes per
// frame, two streams held for the compare — ~4 MB for a 30-minute tape,
// worst case ~60 MB for a 4-hour tape at 30 fps (432k frames × 2), freed
// immediately after the compare. No intermediate media files.
//
// Cancellation: Task.cancel → ProcessRunner kills ffmpeg → partial output
// is deleted in the cleanup path. The lossless proof runs on the partial,
// BEFORE the publish (GH #501), so a Stop or a stall during it ends the
// same way: the new master is removed and nothing was published.

private let transcodeLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                  category: "fileOps")

// MARK: - Job

@MainActor
final class TranscodeJob: @MainActor MediaFileOperationJob {

    let id = UUID()
    let kind: MediaFileOperationKind = .transcode
    let startedAt = Date()

    /// Source record being transcoded.
    let record: VideoRecord

    /// Which preset's args + suffix this job runs.
    let preset: TranscodePreset

    /// User-selected destination for the derivative. Transcode output is
    /// intentionally not derived from the source directory: large ProRes
    /// writes should be able to target a fast SSD while reading from a slow
    /// source volume.
    let outputURL: URL

    /// True when the user answered "Replace" to "Replace Existing
    /// Transcode?". Even then the existing file is never deleted: it goes
    /// to the Trash, only after the new output exists AND was verified
    /// (FFmpegEncodeCheck `.verified`, GH #500), and only when the
    /// Master Archive rule allows it — otherwise the new file is published
    /// beside it (DerivativeOutputPublish.swift, 2026-09-22).
    let replaceExisting: Bool

    /// Where the derivative actually landed — `outputURL`, or a free name
    /// beside it when that name was taken and kept. The
    /// catalog and the summary all use THIS after the publish.
    private(set) var publishedURL: URL

    /// Weak refs — the model holds Jobs via MediaFileOperationsCenter, the
    /// orchestrator isn't actually used by Transcode (we don't auto-queue
    /// Analyze) but we keep the parameter for parity with startReformat's
    /// call shape.
    private weak var model: VideoScanModel?

    /// Pause via SIGSTOP/SIGCONT on the live ffmpeg child (GH #150).
    /// JobPauseCoordinator also parks the stall watchdog so the paused
    /// child's silence is never read as the 14 h-hang class.
    let canPause = true
    var isPaused: Bool { isPausedValue }
    @Published private(set) var isPausedValue = false
    private let pauser = JobPauseCoordinator()

    func pause() {
        guard state == .running, pauser.pause() else { return }
        isPausedValue = true
    }

    func resume() {
        guard pauser.resume() else { return }
        isPausedValue = false
    }

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

    /// Total source duration in seconds, used for the fraction.
    private var totalDurationSeconds: Double = 0

    /// Set by the stall watchdog when an ffmpeg phase (encode OR verify
    /// decode) flatlines. Distinguishes a watchdog kill (→ `.failed` with a
    /// specific reason, incl. volume-drop attribution) from a user cancel
    /// (→ `.cancelled`). Checked before every generic cancel branch because
    /// the watchdog cancels the Task, which also trips `Task.isCancelled`.
    /// This is exactly the 14 h `framemd5` hang the punch-list targets.
    /// Set-once ledger of the first terminal cause (watchdog stall vs the
    /// user's Stop) — see MFOTerminalCause. `stallReason` reads through it.
    private var terminalCause = MFOTerminalCause()
    /// True once the publish moved the previous file to the Trash.
    private var replacedPrevious = false
    private var stallReason: String? { terminalCause.stallReason }

    // Archive-grade telemetry for the preservation summary (videoscan.log).
    // Populated as the job runs; emitted in one consolidated block at the
    // end. Infrequent operation — we log generously. Rick 2026-06-18.
    private var encodeElapsed: TimeInterval = 0
    private var verifyElapsed: TimeInterval = 0
    private var verifiedVideoFrames: Int = 0
    /// Whole-stream MD5 of the decoded audio (empty ⇒ no audio / failed).
    /// Audio is verified by hashing the entire decoded PCM blob, not
    /// per-frame — see verifyLossless's audio branch for why.
    private var audioStreamMD5: String = ""
    /// Human detail for the audio line of the summary — distinguishes
    /// "(no audio stream)" from a real mismatch (audioStreamMD5 is empty
    /// in both cases).
    private var audioVerifyDetail: String = ""

    var title: String { record.filename }
    var subtitle: String { subtitleText }
    var fraction: Double { fractionValue }
    var isIndeterminate: Bool { isIndeterminateValue }

    // MARK: Init / start

    init(
        record: VideoRecord,
        preset: TranscodePreset,
        outputURL: URL,
        model: VideoScanModel,
        replaceExisting: Bool = false
    ) {
        self.record = record
        self.preset = preset
        self.outputURL = outputURL.standardizedFileURL
        self.publishedURL = outputURL.standardizedFileURL
        self.replaceExisting = replaceExisting
        self.model = model
        self.subtitleText = preset.subtitle
    }

    /// Start the transcode. Idempotent — a second call is a no-op.
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            await self.runTranscode()
        }
    }

    /// Cancel the in-flight ffmpeg. Task.cancel propagates into
    /// ProcessRunner.runStreaming which terminates the subprocess.
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

    // MARK: Transcode run

    private func runTranscode() async {
        totalDurationSeconds = max(0, record.durationSeconds)

        let inputPath = record.fullPath
        // ffmpeg encodes here — a partial with a UNIQUE name beside the
        // destination — and it is published only after a COMPLETE,
        // non-trivial encode (#6.3). A killed/stalled encode leaves only
        // this partial, which we delete — never a truncated master at the
        // real output path. The lossless proof (preservation) runs against
        // this partial too, BEFORE the publish (GH #501), and only reads it.
        //
        // NOTHING at the output name is touched before the publish
        // (2026-09-22): this used to remove it here, before the source
        // check and before any encode, which permanently deleted a
        // catalogued file on FamilyArchive when "Replace" was answered.
        //
        // Crash / force-quit leftovers of THIS output name (>24 h old, our
        // own incomplete encodes only, never one a running job reserved) —
        // swept off-main, logged.
        await Self.sweepStalePartialsOffMain(beside: outputURL)

        let volumeLabel = VolumeReachability.displayLabel(forPath: inputPath)
        transcodeLog.info("transcode START: \(self.record.filename, privacy: .public) preset=\(self.preset.rawValue, privacy: .public) on \(volumeLabel, privacy: .public) → \(self.outputURL.lastPathComponent, privacy: .public)")

        if preset == .preservation {
            transcodeLog.info("preservation: starting FFV1 v3 master for \(self.record.filename, privacy: .public) → \(self.outputURL.lastPathComponent, privacy: .public)")
        }

        guard FileManager.default.fileExists(atPath: inputPath) else {
            await finish(failed: "Source file missing on disk")
            return
        }

        let ffmpeg = ToolLocator.ffmpegPath
        guard !ffmpeg.isEmpty, FileManager.default.fileExists(atPath: ffmpeg) else {
            await finish(failed: "ffmpeg not found (set VS_FFMPEG_PATH or install via Homebrew)")
            return
        }

        // Reserve this run's partial (O_EXCL + registered live in the ONE
        // registry Combine uses too — PartialFileNaming): no sweep, either
        // job's, can remove it while this run lives, however long it is
        // paused (fix/one-partial-registry, 2026-09-22). Every exit of this
        // run releases it; removals go through PartialFileNaming.remove.
        let partialURL: URL
        do {
            partialURL = try DerivativeOutputPublish.reservePartial(for: outputURL)
        } catch {
            transcodeLog.error("transcode FAILED (reserve partial): \(self.record.filename, privacy: .public) — \(error.localizedDescription, privacy: .public)")
            await finish(failed: "Could not create the output file: \(error.localizedDescription)")
            return
        }
        defer { PartialFileNaming.unregisterLive(partialURL) }
        let partialPath = partialURL.path

        // Match-source audio decision (preservation only): PCM source →
        // verbatim copy, anything else → FLAC. ffprobe codec names for
        // uncompressed audio all start with `pcm_` (pcm_s16le, pcm_s24le,
        // pcm_s24be, pcm_f32le, …).
        let audioIsPCM = record.audioCodec
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
            .hasPrefix("pcm_")

        let args = Self.transcodeArgs(preset: preset,
                                      input: inputPath,
                                      output: partialPath,
                                      sourceAudioIsPCM: audioIsPCM)

        subtitleText = preset.subtitle
        isIndeterminateValue = (totalDurationSeconds == 0)

        transcodeLog.info("transcode (\(self.preset.rawValue, privacy: .public)): ffmpeg \(args.joined(separator: " "), privacy: .public)")

        // Archive-grade BEGIN record → videoscan.log. Captures the full
        // source provenance, the chosen audio policy, and the exact ffmpeg
        // command so a preservation master is reproducible from the log
        // alone. Preservation only — editing/archival stay quiet here.
        if preset == .preservation {
            logPreservationBegin(args: args, audioIsPCM: audioIsPCM)
        }

        // Reuse ReformatJob's progress parser — same `-progress pipe:2`
        // output format. Out of scope for this pass to hoist the helper
        // into a shared file.
        let totalDur = totalDurationSeconds
        // Stall watchdog for the encode (#6). Every ffmpeg progress line
        // kicks it; silence past the threshold ⇒ volume stalled ⇒ kill+fail.
        let encodeMonitor = StallMonitor(label: "transcode encode \(record.filename)") { [weak self] silentFor in
            Task { @MainActor [weak self] in
                self?.handleStall(phase: "transcode encode", silentFor: silentFor)
            }
        }
        let progressUpdater: @Sendable (String) -> Void = { [weak self] line in
            encodeMonitor.tick()
            guard let self else { return }
            let sec = ReformatJob.parseProgressSeconds(line: line)
            guard let sec, totalDur > 0 else { return }
            Task { @MainActor in
                self.fractionValue = min(1.0, sec / totalDur)
                self.isIndeterminateValue = false
            }
        }

        let encodeStart = Date()
        encodeMonitor.start()
        pauser.register(encodeMonitor)
        // The exit status is the verdict's first half (2026-09-19): it
        // used to be thrown away, so a failed encode could be published.
        let encodeResult = await ProcessRunner.runProcess(
            executable: ffmpeg,
            arguments: args,
            environment: nil,
            stderrLine: progressUpdater,
            control: pauser.control
        )
        encodeMonitor.stop()
        encodeElapsed = Date().timeIntervalSince(encodeStart)

        // Stalled (the watchdog cancels the Task — the specific cause wins
        // over "Cancelled") or cancelled mid-run?
        if await stoppedBeforePublish(partialURL) { return }

        // The gate between the encode and the publish (TranscodeJob+
        // EncodeGate.swift): exit code, length, a non-trivial file — and,
        // with Replace, VERIFIED (GH #500, Rick 2026-11-20: "verify the
        // temp, only when verified could it replace anything"). It only
        // reads; nothing has been trashed or renamed yet. A new file that
        // fails it is removed (discardPartial: this run's own reserved
        // partial, nothing else) and the file at the output name is never
        // touched.
        let size: Int64
        let verified: PartialFileNaming.FileStamp?
        switch await Self.encodeGate(encodeResult, inputPath: inputPath, partialPath: partialPath,
                                     replace: replaceExisting) {
        case .failed(let failure, let stage):
            await failEncode(failure, stage: stage, partial: partialURL)
            return
        case .unverified(let cause):
            await refuseUnverifiedReplace(cause: cause, partial: partialURL)
            return
        case .passed(let bytes, let stamp):
            size = bytes
            verified = stamp
        }

        // A Stop that landed while the gate was out is still a Stop (codex
        // r1 F3): the probes' good answers do not publish over it.
        if await stoppedBeforePublish(partialURL) { return }

        // Preservation: PROVE the new master bit-exact BEFORE anything is
        // published (GH #501; DECISIONS 2026-11-20 "a Replace happens only
        // after the new file is verified" — for a master, verified includes
        // the lossless proof). THE BUG: the proof ran against the published
        // file, so with Replace the previous master was already in the Trash
        // and the name held a master that then failed its proof. It now
        // reads the partial; a master that fails — a mismatch, or a proof
        // that could not be computed — FAILS the job, is removed
        // (discardPartial: this run's own reserved file), and nothing is
        // trashed, renamed or catalogued. A Stop or a stall during the proof
        // ends through stoppedBeforePublish like one during the encode. The
        // partial's stamp taken by the gate is checked again by
        // publishVerified, so the file published is the file proven.
        if preset == .preservation {
            let proof = await verifyLossless(ffmpeg: ffmpeg, source: inputPath, output: partialPath)
            if await stoppedBeforePublish(partialURL) { return }
            switch proof {
            case .verified:
                break
            case .interrupted:
                // Unknown is not verified: fail closed.
                await failLosslessProof("the proof was interrupted before it finished", size: size, partial: partialURL)
                return
            case .failed(let evidence):
                await failLosslessProof(evidence, size: size, partial: partialURL)
                return
            }
        }

        // Publish: a complete, non-trivial encode takes the output name in
        // one no-clobber rename (#6.3) — or, when the name is taken, the
        // existing file is kept (or, with Replace allowed, Trashed first)
        // and the job says which.
        guard let publishNote = await publish(partialURL, verified: verified) else { return }

        if preset == .preservation {
            logPreservationSummary(outputSize: size, verified: true, evidence: nil)
            await catalogTranscodeOutput()
            await finish(success: "✓ Verified bit-exact lossless (frame MD5) → \(publishedURL.lastPathComponent) (\(Self.humanBytes(size)))\(publishNote)")
            return
        }

        await catalogTranscodeOutput()
        transcodeLog.info("transcode DONE: \(self.record.filename, privacy: .public) preset=\(self.preset.rawValue, privacy: .public) → \(self.publishedURL.lastPathComponent, privacy: .public) (\(Self.humanBytes(size), privacy: .public)) encode \(self.encodeElapsed, format: .fixed(precision: 1), privacy: .public)s")
        await finish(success: "Transcoded → \(publishedURL.lastPathComponent) (\(Self.humanBytes(size))).\(publishNote)")
    }

    // MARK: Publish (2026-09-22 — never delete first)

    /// What happens to a file already at the output name. Replace must
    /// have been chosen AND the Master Archive rule must allow removing
    /// that file (a catalogued record is asked as a record — archive
    /// copies included — anything else by its path); otherwise it is kept
    /// and the new derivative is published beside it.
    private func existingFilePolicy() -> DerivativeOutputPublish.ExistingFilePolicy {
        guard replaceExisting else {
            return .keep(reason: "a file already has that name and Replace was not chosen")
        }
        guard let model else { return .keep(reason: "the catalog is not available to check the Master Archive rule") }
        let path = outputURL.path
        let refusal = model.records.first(where: { $0.fullPath == path && !$0.isPurged })
            .map { model.bulkDeleteRefusal($0) } ?? model.bulkDeleteRefusal(forPath: path)
        if let refusal {
            let label = model.archiveVolumeProtection()?.label ?? "the archive volume"
            return .keep(reason: VideoScanModel.bulkDeleteRefusalNote(refusal, volume: label))
        }
        return .replaceViaTrash
    }

    /// Remove this run's own partial after a stall / cancel / failed
    /// encode (name- AND identity-guarded: only the file this run reserved;
    /// releases the reservation). Returns what actually happened; a failure
    /// is logged, never swallowed; a leftover is a later sweep's to remove.
    @discardableResult
    private func discardPartial(_ partial: URL) -> PartialCleanup {
        do {
            return try PartialFileNaming.remove(partial) == .removed ? .removed : .alreadyGone
        } catch {
            transcodeLog.error("transcode: could not remove partial \(partial.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .notRemoved(error.localizedDescription)
        }
    }

    /// Stop, or a watchdog stall, seen before anything is published: the
    /// partial is discarded and the job ends Cancelled — or Failed with the
    /// stall that caused it, which with Replace also says the original was
    /// not replaced and what the cleanup did (codex r2 F4). True = the run
    /// is over.
    private func stoppedBeforePublish(_ partial: URL) async -> Bool {
        guard stallReason != nil || Task.isCancelled || state == .cancelling else { return false }
        let cleanup = discardPartial(partial)
        guard let stallReason else {
            await finish(cancelled: true)
            return true
        }
        let message = replaceExisting
            ? Self.failedReplaceMessage(failure: stallReason, original: outputURL.lastPathComponent, cleanup: cleanup)
            : stallReason
        transcodeLog.error("transcode FAILED (stall): \(self.record.filename, privacy: .public) — \(message, privacy: .public)")
        await finish(failed: message)
        return true
    }

    /// The encode failed the gate: remove the new file, say why — and, with
    /// Replace, that the original was not replaced and what became of the
    /// new file (codex r1 F5).
    private func failEncode(_ failure: String, stage: String, partial: URL) async {
        let cleanup = discardPartial(partial)
        let message = replaceExisting
            ? Self.failedReplaceMessage(failure: failure, original: outputURL.lastPathComponent, cleanup: cleanup)
            : failure
        transcodeLog.error("transcode FAILED (\(stage, privacy: .public)): \(self.record.filename, privacy: .public) — \(message, privacy: .public)")
        await finish(failed: message)
    }

    /// Replace refused: the new file is not verified. Removed through the
    /// failed-encode path; the message reports the cleanup's own result.
    private func refuseUnverifiedReplace(cause: String, partial: URL) async {
        let cleanup = discardPartial(partial)
        let message = Self.unverifiedReplaceMessage(cause: cause, original: outputURL.lastPathComponent, cleanup: cleanup)
        transcodeLog.error("transcode FAILED (verify, Replace refused): \(self.record.filename, privacy: .public) — \(message, privacy: .public)")
        await finish(failed: message)
    }

    /// The lossless proof failed (GH #501): remove the new master, record
    /// the evidence (the row, the Center's OUTCOME line and the summary
    /// block in videoscan.log all carry it — no sidecar file is written),
    /// and say what became of the original and of the new file.
    private func failLosslessProof(_ evidence: String, size: Int64, partial: URL) async {
        let cleanup = discardPartial(partial)
        let failure = Self.losslessProofFailed + " — " + evidence
        let message = replaceExisting
            ? Self.failedReplaceMessage(failure: failure, original: outputURL.lastPathComponent, cleanup: cleanup)
            : Self.notPublishedMessage(failure: failure, cleanup: cleanup)
        logPreservationSummary(outputSize: size, verified: false, evidence: message)
        transcodeLog.error("transcode FAILED (lossless proof): \(self.record.filename, privacy: .public) — \(message, privacy: .public)")
        await finish(failed: message)
    }

    /// Publish the partial; returns the summary's note, or nil when the
    /// job has been finished as failed here.
    private func publish(_ partialURL: URL, verified: PartialFileNaming.FileStamp?) async -> String? {
        do {
            let outcome = try await Self.publishVerified(
                partial: partialURL.path, final: outputURL, policy: existingFilePolicy(),
                archiveCheck: model?.archiveRemovalCheck(), trash: DerivativeOutputPublish.trashItem,
                verified: verified)
            publishedURL = outcome.url
            return logPublishOutcome(outcome)
        } catch is CancellationError {
            // Stop (or a stall) before the commit point: nothing moved.
            _ = await stoppedBeforePublish(partialURL)
            return nil
        } catch is ChangedSinceVerified {
            // Not the file that was verified: nothing was trashed or renamed.
            await refuseUnverifiedReplace(cause: Self.changedAfterVerification, partial: partialURL)
            return nil
        } catch {
            // The partial is our own complete encode: kept, named, so the
            // work is not lost. Nothing else was changed by a failed publish.
            // Moved OFF the partial pattern (`.vs-kept.`, no-clobber) so no
            // stale sweep can remove it once this run releases it.
            let kept = await Self.keepUnpublishedOffMain(partialURL)
            transcodeLog.error("transcode FAILED (publish): \(self.record.filename, privacy: .public) — \(error.localizedDescription, privacy: .public) — encode kept at \(kept.path, privacy: .public)")
            appLog.write("transcode: \(self.record.filename) finished but not published (\(error.localizedDescription)) — encode kept at \(kept.path)")
            // MIXED STATE (codex r3): the previous file is already in the
            // Trash. Say where both files are and how to restore.
            let mixed = (error as? DerivativeOutputPublish.Failure).flatMap { failure in
                failure.previousFileTrashedAt.map {
                    Self.replaceNotCompletedMessage(cause: failure.cause ?? failure.message, original: outputURL,
                                                    trashedAt: $0, keptAt: kept.path)
                }
            }
            // A failed publish leaves a finished encode on disk (and maybe
            // the original in the Trash): it is a FAILURE that must be
            // read, never a "Cancelled" row over it, whenever Stop came.
            await finish(failed: mixed ?? "Could not finalize output file: \(error.localizedDescription) — the encode is kept at \(kept.path)",
                         evenIfStopped: true)
            return nil
        }
    }

    @concurrent
    nonisolated private static func keepUnpublishedOffMain(_ partial: URL) async -> URL {
        DerivativeOutputPublish.keepUnpublished(partial)
    }

    @concurrent
    nonisolated private static func sweepStalePartialsOffMain(beside output: URL) async {
        DerivativeOutputPublish.sweepStalePartials(beside: output)
    }

    /// Log where the derivative went; returns the sentence the job's
    /// summary appends ("" for the plain case).
    private func logPublishOutcome(_ outcome: DerivativeOutputPublish.Outcome) -> String {
        switch outcome {
        case .published:
            return ""
        case .publishedBeside(let url, let kept, let reason):
            let line = "transcode: \(kept.lastPathComponent) kept (\(reason)) — new \(preset.rawValue) derivative published beside it as \(url.lastPathComponent)"
            transcodeLog.notice("\(line, privacy: .public)")
            appLog.write(line)
            return " Kept the existing \(kept.lastPathComponent) — \(reason)."
        case .replaced(let url, let trashedTo):
            let whereTo = trashedTo?.path ?? "the Trash"
            let line = "transcode: new \(preset.rawValue) derivative took the name \(url.lastPathComponent); the previous file is at \(whereTo)"
            transcodeLog.notice("\(line, privacy: .public)")
            appLog.write(line)
            replacedPrevious = true
            return " The previous file is in the Trash."
        }
    }

    // MARK: Preservation verification

    /// Outcome of the preservation proof. Three answers, as the encode
    /// check has: proven, NOT proven (with the evidence), and "the proof
    /// did not finish" — which is never read as proven (GH #501).
    /// (For Rick: ≈ std::variant<Verified, Interrupted, Failed>.)
    private enum VerifyOutcome {
        case verified
        /// Stop or a stall landed during the proof. The caller ends the
        /// job through stoppedBeforePublish; nothing is published.
        case interrupted
        /// A mismatch, or a hash that could not be computed. The evidence
        /// is one bounded sentence: which stream, which frame, both hashes
        /// (or the tool, its exit code and its words).
        case failed(evidence: String)
    }

    /// True when the user's Stop or the stall watchdog has ended this run.
    private var proofInterrupted: Bool { stallReason != nil || Task.isCancelled || state == .cancelling }

    /// Decode the source and the NEW master (`output`: this run's partial,
    /// not yet published) to per-frame MD5 (video) and a whole-stream MD5
    /// (audio) and prove they match. Reads only. Drives the progress bar
    /// off the decode's `-progress` output. A mismatch, an empty or garbled
    /// hash stream, or an ffmpeg that crashed / could not start is
    /// `.failed` with the evidence — recorded in the row, the OUTCOME line
    /// and the summary block (the `<output>.framemd5-MISMATCH.log` sidecar
    /// this used to write beside the master is gone: the master it sat
    /// beside is no longer kept, and the line carries the same facts).
    private func verifyLossless(ffmpeg: String,
                                source: String,
                                output: String) async -> VerifyOutcome {
        transcodeLog.info("preservation verify: starting frame-MD5 comparison for the new \(self.outputURL.lastPathComponent, privacy: .public)")
        let verifyStart = Date()
        defer { verifyElapsed = Date().timeIntervalSince(verifyStart) }

        // ---- Video stream ----
        subtitleText = "Verifying lossless — video frame MD5…"
        fractionValue = 0
        isIndeterminateValue = (totalDurationSeconds == 0)

        let srcVideo = await framemd5(ffmpeg: ffmpeg, file: source)
        if proofInterrupted { return .interrupted }
        if let failure = Self.proofToolFailure(srcVideo, what: "the source's video frame MD5") {
            return failedProof(failure)
        }
        let outVideo = await framemd5(ffmpeg: ffmpeg, file: output)
        if proofInterrupted { return .interrupted }
        if let failure = Self.proofToolFailure(outVideo, what: "the new master's video frame MD5") {
            return failedProof(failure)
        }

        let srcVideoMD5 = srcVideo.stdout ?? "", outVideoMD5 = outVideo.stdout ?? ""
        if let evidence = Self.frameMD5Evidence(source: srcVideoMD5, output: outVideoMD5) {
            return failedProof(evidence)
        }
        verifiedVideoFrames = Self.frameCount(srcVideoMD5)
        transcodeLog.info("preservation verify: video stream bit-exact (\(self.verifiedVideoFrames, privacy: .public) frames, \(self.outputURL.lastPathComponent, privacy: .public))")

        // ---- Audio stream ----
        // Skip cleanly if the source has no audio (video-only master).
        //
        // Audio uses a WHOLE-STREAM md5 (`-f md5`), not per-frame framemd5.
        // framemd5 hashes each decoded audio frame separately, and frame
        // boundaries follow packet sizes — so remuxing MOV lpcm → Matroska
        // PCM (even with `-c:a copy`) can re-block byte-identical samples
        // into different-sized frames, producing a spurious per-frame
        // mismatch on audio that is in fact bit-exact. Hashing the entire
        // decoded PCM blob as one unit is invariant to that re-blocking.
        //
        // CRITICAL: we must decode BOTH sides to the SAME explicit integer
        // PCM format before hashing. A bare `-f md5` hashes each side in its
        // own NATIVE decoded format — and those differ by codec: AAC/MP3
        // decode to float (fltp), FLAC/PCM decode to int (s32/s16). Hashing
        // float-source vs int-master always mismatches even when the samples
        // are identical (verified: forcing pcm_s24le on both makes the two
        // md5s equal). So we pin a common format == the MASTER's stored bit
        // depth: the PCM-copy path then gets a full-depth verbatim check,
        // and the FLAC path compares at its actual capture depth. The
        // source's float→int conversion here is byte-identical to the one
        // the FLAC encoder already did, so a faithful master matches exactly.
        // Rick 2026-06-18.
        let hasAudio = (record.streamType == .videoAndAudio || record.streamType == .audioOnly)
        if hasAudio {
            subtitleText = "Verifying lossless — audio stream MD5…"
            fractionValue = 0
            isIndeterminateValue = (totalDurationSeconds == 0)

            // Match the comparison depth to the master so we compare like
            // for like (see the CRITICAL note above).
            let pcmCodec = await audioComparisonPCMCodec(master: output)
            if proofInterrupted { return .interrupted }

            let srcAudio = await streamMD5(ffmpeg: ffmpeg, file: source, pcmCodec: pcmCodec)
            if proofInterrupted { return .interrupted }
            let outAudio = await streamMD5(ffmpeg: ffmpeg, file: output, pcmCodec: pcmCodec)
            if proofInterrupted { return .interrupted }

            let failure = Self.proofToolFailure(srcAudio, what: "the source's audio MD5")
                ?? Self.proofToolFailure(outAudio, what: "the new master's audio MD5")
                ?? Self.audioMD5Evidence(source: Self.parseStreamMD5(srcAudio.stdout ?? ""),
                                         output: Self.parseStreamMD5(outAudio.stdout ?? ""), pcmCodec: pcmCodec)
            if let failure {
                audioStreamMD5 = ""   // distinguishes failure from no-audio in the summary
                audioVerifyDetail = "NOT PROVEN at \(pcmCodec)"
                return failedProof(failure)
            }
            audioStreamMD5 = Self.parseStreamMD5(srcAudio.stdout ?? "")
            audioVerifyDetail = "whole-stream MD5 \(audioStreamMD5) @\(pcmCodec)"
            transcodeLog.info("preservation verify: audio stream bit-exact (whole-stream MD5 \(self.audioStreamMD5, privacy: .public) @\(pcmCodec, privacy: .public), \(self.outputURL.lastPathComponent, privacy: .public))")
        } else {
            audioVerifyDetail = "(no audio stream)"
        }

        transcodeLog.info("preservation verify: PASS — the new \(self.outputURL.lastPathComponent, privacy: .public) is bit-exact lossless")
        return .verified
    }

    private func failedProof(_ evidence: String) -> VerifyOutcome {
        transcodeLog.error("preservation verify: NOT PROVEN — \(evidence, privacy: .public)")
        return .failed(evidence: evidence)
    }

    /// Decode the VIDEO stream to per-frame MD5 (`-f framemd5`); stdout is
    /// the hash stream. Per-frame on video is reliable — the frame count
    /// is fixed by the coded pictures, independent of container — and the
    /// localization (which frame diverged) is worth keeping. Progress
    /// (`-progress pipe:2`) streams to stderr and drives the bar so a long
    /// decode never shows a stuck bar.
    private func framemd5(ffmpeg: String, file: String) async -> ProcessRunner.Result {
        let args = ["-hide_banner", "-nostdin", "-i", file,
                    "-map", "0:v:0", "-an",
                    "-f", "framemd5", "-progress", "pipe:2", "-"]
        return await runDecodeCapture(ffmpeg: ffmpeg, args: args, phase: "verify (video framemd5)")
    }

    /// Decode the AUDIO stream to a single WHOLE-STREAM MD5 (stdout carries
    /// one `MD5=…` line; `parseStreamMD5` reads it). `pcmCodec` forces an
    /// explicit integer PCM format (e.g. "pcm_s24le") so source and master
    /// are hashed in the SAME representation — without it, `-f md5` would
    /// hash each side in its own native format (float for AAC/MP3, int for
    /// FLAC/PCM) and always mismatch. Whole-stream (not per-frame) so a
    /// MOV→MKV PCM re-block can't false-fail byte-identical audio.
    private func streamMD5(ffmpeg: String, file: String, pcmCodec: String) async -> ProcessRunner.Result {
        let args = ["-hide_banner", "-nostdin", "-i", file,
                    "-map", "0:a:0", "-vn",
                    "-c:a", pcmCodec,
                    "-f", "md5", "-progress", "pipe:2", "-"]
        return await runDecodeCapture(ffmpeg: ffmpeg, args: args, phase: "verify (audio md5)")
    }

    /// Pick the integer PCM codec to hash both audio streams in, matched to
    /// the MASTER's stored bit depth (ffprobe `bits_per_raw_sample`, falling
    /// back to `sample_fmt`). PCM-copy masters report their true depth → a
    /// full-depth verbatim check; FLAC masters report their capture depth
    /// (typically 24) → a like-for-like check against the source's
    /// float→int conversion. Defaults to pcm_s24le when the probe is
    /// inconclusive (the FLAC capture depth, and the common case).
    private func audioComparisonPCMCodec(master: String) async -> String {
        let ffprobe = ToolLocator.ffprobePath
        guard !ffprobe.isEmpty, FileManager.default.fileExists(atPath: ffprobe) else {
            return "pcm_s24le"
        }
        let out = await ProcessRunner.runStreaming(
            executable: ffprobe,
            arguments: ["-v", "error", "-select_streams", "a:0",
                        "-show_entries", "stream=bits_per_raw_sample,sample_fmt",
                        "-of", "default=noprint_wrappers=1", master],
            environment: nil,
            stderrLine: { _ in }
        ) ?? ""
        return Self.pcmCodecForProbe(out)
    }

    /// Pure mapping from an ffprobe "bits_per_raw_sample=…\nsample_fmt=…"
    /// dump to the comparison PCM codec. Bit depth wins; sample_fmt is the
    /// fallback; pcm_s24le is the default. Fixture-testable. Rick 2026-06-18.
    nonisolated static func pcmCodecForProbe(_ probe: String) -> String {
        var bits = 0
        var fmt = ""
        for raw in probe.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("bits_per_raw_sample=") {
                bits = Int(line.dropFirst("bits_per_raw_sample=".count)) ?? 0
            } else if line.hasPrefix("sample_fmt=") {
                fmt = String(line.dropFirst("sample_fmt=".count))
            }
        }
        if bits > 0 {
            if bits <= 16 { return "pcm_s16le" }
            if bits <= 24 { return "pcm_s24le" }
            return "pcm_s32le"
        }
        switch fmt {
        case "u8", "u8p":   return "pcm_s16le"
        case "s16", "s16p": return "pcm_s16le"
        case "s32", "s32p": return "pcm_s32le"
        default:            return "pcm_s24le"   // float/unknown → FLAC capture depth
        }
    }

    /// Parse the hex digest out of ffmpeg's md5-muxer output. The muxer
    /// prints a single `MD5=<hex>` line; we scan for it case-insensitively,
    /// lower-case the digest, and return "" when absent (decode failure) so
    /// the verify fails loudly rather than silently "matching" two empties.
    /// Pure — fixture-testable, no subprocess. Rick 2026-06-18.
    nonisolated static func parseStreamMD5(_ output: String) -> String {
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.uppercased().hasPrefix("MD5=") {
                return String(line.dropFirst(4)).lowercased()
            }
        }
        return ""
    }

    /// Shared decode runner: spawns ffmpeg, drives the progress bar off its
    /// `-progress pipe:2` stderr, and returns the run (stdout = the md5
    /// lines). Memory: see the file-header note.
    ///
    /// Guarded by a StallMonitor (#6): the framemd5 decode of an archival
    /// master is the EXACT op that wedged for 14 h. Each progress line kicks
    /// the watchdog; silence past the threshold cancels the run (killing the
    /// ffmpeg child via ProcessRunner) and records a specific stall reason
    /// that the verify branch surfaces as a loud failure.
    private func runDecodeCapture(ffmpeg: String, args: [String], phase: String) async -> ProcessRunner.Result {
        let totalDur = totalDurationSeconds
        let monitor = StallMonitor(label: "transcode \(phase) \(record.filename)") { [weak self] silentFor in
            Task { @MainActor [weak self] in
                self?.handleStall(phase: "transcode \(phase)", silentFor: silentFor)
            }
        }
        let progressUpdater: @Sendable (String) -> Void = { [weak self] line in
            monitor.tick()
            guard let self else { return }
            let sec = ReformatJob.parseProgressSeconds(line: line)
            guard let sec, totalDur > 0 else { return }
            Task { @MainActor in
                self.fractionValue = min(1.0, sec / totalDur)
                self.isIndeterminateValue = false
            }
        }

        monitor.start()
        pauser.register(monitor)
        // The exit status is kept (it was thrown away): a decoder that
        // crashed or could not start is "could not be computed", with its
        // exit code and words — not a bare mismatch against an empty hash.
        let result = await ProcessRunner.runProcess(
            executable: ffmpeg,
            arguments: args,
            environment: nil,
            stderrLine: progressUpdater,
            control: pauser.control
        )
        monitor.stop()
        return result
    }

    // MARK: Stall handling

    /// Invoked (on the main actor) by a StallMonitor when an ffmpeg phase
    /// flatlines. Records a SPECIFIC reason with volume-drop vs file-error
    /// attribution (#6.4) and cancels the run — killing the ffmpeg child via
    /// ProcessRunner's SIGTERM→SIGKILL escalation. Idempotent across the
    /// encode + the (possibly several) verify decodes: the first stall wins.
    func handleStall(phase: String, silentFor: Double) {
        guard state.isActive, terminalCause.first == nil else { return }
        let attribution = StallMonitor.attribution(forPaths: [record.fullPath, outputURL.path])
        let reason = "Stalled — no ffmpeg progress for \(Int(silentFor))s during \(phase). \(attribution)"
        terminalCause.record(.stall(reason: reason))
        subtitleText = "Stalled — stopping…"
        transcodeLog.error("transcode WATCHDOG: killing \(self.record.filename, privacy: .public) (\(phase, privacy: .public)) — \(reason, privacy: .public)")
        appLog.write("transcode watchdog: \(record.filename) stalled \(Int(silentFor))s during \(phase) — \(attribution); killing ffmpeg")
        task?.cancel()
    }

    /// Probe the new file and append to the catalog. Unlike ReformatJob, we
    /// DO NOT auto-queue Analyze — the user transcoded for a specific
    /// workflow, they don't want auto-analysis stepping on it. probeFile
    /// handles .mkv so the preservation master catalogs the same way.
    ///
    /// Sets workspaceActive = true on the new record; sets derivedFrom =
    /// record.id so the catalog can surface the lineage; stamps a journey
    /// note on BOTH records.
    private func catalogTranscodeOutput() async {
        guard let model = model else { return }
        let newURL = publishedURL
        let newRec = await model.probeFile(url: newURL)

        // Lineage + workspace state.
        newRec.derivedFrom = record.id
        newRec.workspaceActive = true

        // File Journey events on BOTH records — matches the convention
        // ReformatJob established (Rick 2026-06-14).
        let stamp = ISO8601DateFormatter().string(from: Date())
        let sourceNote = "Transcode \(stamp): Created \(self.preset.rawValue) derivative \(newURL.lastPathComponent)"
        let derivedNote = "Transcode \(stamp): \(self.preset.rawValue) derivative of \(record.filename)"

        await MainActor.run {
            record.notes = record.notes.isEmpty
                ? sourceNote
                : "\(record.notes)\n\(sourceNote)"
            newRec.notes = newRec.notes.isEmpty
                ? derivedNote
                : "\(newRec.notes)\n\(derivedNote)"

            // The one door into the catalog for a derivative (replace at
            // the path, else append) — it also tells the Catalog pane to
            // open the source's folder and select the new row
            // (FootageFoldersSnapshot.swift, Rick 2026-10-16).
            model.adoptDerivative(newRec, at: newURL.path, from: record.id)
            transcodeLog.info("transcode: catalogued \(newURL.lastPathComponent, privacy: .public) as \(self.preset.rawValue, privacy: .public) derivative (workspaceActive=true, derivedFrom=\(self.record.id.uuidString, privacy: .public))")
        }
    }

    // MARK: Finish helpers

    private func finish(success base: String) async {
        // A Stop pressed after the publish's commit point could not stop
        // it: the job finished, and its one line says so (codex r2 F3).
        let success = terminalCause.isCancel ? base + Self.lateStopNote(replaced: replacedPrevious) : base
        state = .finished(summary: success)
        subtitleText = success
        fractionValue = 1.0
        isIndeterminateValue = false
    }

    private func finish(failed: String, evenIfStopped: Bool = false) async {
        // Rick 2026-08-26: a job whose cancel was the FIRST terminal cause
        // NEVER ends .failed — the SIGTERM'd child's non-zero exit, or any
        // typed error thrown while the Task unwinds, is the user's Stop,
        // not a failure. A stall recorded before the Stop is not diverted
        // (codex gate 2026-08-26) — see MFOTerminalCause.
        // `evenIfStopped`: the publish failed after the encode was done —
        // files were left that the row must name (codex r3).
        if terminalCause.isCancel, !evenIfStopped { await finish(cancelled: true); return }
        state = .failed(message: failed)
        subtitleText = failed
        isIndeterminateValue = false
        transcodeLog.warning("transcode failed: \(failed, privacy: .public)")
    }

    private func finish(cancelled: Bool) async {
        // An earlier stall is the cause of THIS cancellation (the watchdog
        // cancelled the Task) — report it, not "Cancelled".
        if let reason = terminalCause.stallReason { await finish(failed: reason); return }
        state = .cancelled
        subtitleText = "Cancelled"
        isIndeterminateValue = false
    }

    private static func humanBytes(_ bytes: Int64) -> String {
        // Rick 2026-08-18: one app-wide decimal formatter (Finder / df base).
        MediaBytes.display(bytes)
    }

    // MARK: - Archive-grade logging (preservation only) → videoscan.log
    //
    // These write to the global `appLog` (the flat ~/Library/Logs/VideoScan/
    // videoscan.log Rick reads), NOT just the unified system log. A
    // preservation export is an infrequent, high-stakes operation destined
    // for long-term archival — so we record full provenance: every source
    // spec, the exact ffmpeg command (reproducible from the log alone), and
    // an end-of-run summary with sizes, compression ratio, timings, frames
    // verified, and the lossless verdict. Rick 2026-06-18.

    /// One field per line, dash-bulleted, with a blank-padded label so the
    /// block reads as a table in the flat log.
    private func logField(_ label: String, _ value: String) {
        let padded = label.padding(toLength: 18, withPad: " ", startingAt: 0)
        appLog.write("    \(padded) \(value)")
    }

    /// BEGIN record — emitted just before the FFV1 encode starts.
    private func logPreservationBegin(args: [String], audioIsPCM: Bool) {
        let r = record
        let audioPolicy = audioIsPCM
            ? "verbatim PCM copy (-c:a copy) — source is uncompressed \(r.audioCodec)"
            : "FLAC re-encode (-c:a flac) — source \(r.audioCodec.isEmpty ? "n/a" : r.audioCodec) is not uncompressed PCM"

        appLog.write("════════ PRESERVATION MASTER (FFV1 v3) — BEGIN ════════")
        logField("Source:", r.fullPath)
        logField("Source size:", "\(Self.humanBytes(r.sizeBytes)) (\(r.sizeBytes) bytes)")
        logField("Duration:", "\(String(format: "%.3f", r.durationSeconds))s")
        logField("Container:", r.container.isEmpty ? "—" : r.container)
        logField("Video:", "\(r.videoCodec)  \(r.resolution)  \(r.frameRate)  \(r.colorSpace.isEmpty ? "" : r.colorSpace + "  ")\(r.bitDepth.isEmpty ? "" : r.bitDepth + "-bit ")\(r.scanType)".trimmingCharacters(in: .whitespaces))
        logField("Video bitrate:", r.videoBitrate.isEmpty ? "—" : r.videoBitrate)
        logField("Audio:", r.audioCodec.isEmpty ? "(none)" : "\(r.audioCodec)  \(r.audioChannels)ch  \(r.audioSampleRate)")
        logField("Audio policy:", audioPolicy)
        logField("Timecode:", r.timecode.isEmpty ? "—" : r.timecode)
        logField("Output:", outputURL.path)
        logField("ffmpeg:", "ffmpeg \(args.joined(separator: " "))")
        appLog.write("═══════════════════════════════════════════════════════")
    }

    /// SUMMARY record — emitted once the proof resolves. On a pass the
    /// master is published; on a failure `evidence` is the job's whole
    /// failure sentence (what disagreed, and what became of both files).
    private func logPreservationSummary(outputSize: Int64, verified: Bool, evidence: String?) {
        let src = record.sizeBytes
        let ratio = src > 0 ? Double(outputSize) / Double(src) : 0
        let encodeSpeed = (encodeElapsed > 0 && record.durationSeconds > 0)
            ? record.durationSeconds / encodeElapsed : 0

        appLog.write("──────── PRESERVATION MASTER — SUMMARY ────────")
        logField("Result:", verified
            ? "✓ VERIFIED bit-exact lossless (frame MD5)"
            : "✗ VERIFICATION FAILED — the new master was not published")
        logField("Master:", verified ? publishedURL.path : "(not published) \(outputURL.path)")
        logField("Master size:", "\(Self.humanBytes(outputSize)) (\(outputSize) bytes)")
        logField("Source size:", "\(Self.humanBytes(src)) (\(src) bytes)")
        let delta = "\(outputSize >= src ? "+" : "−")\(Self.humanBytes(abs(outputSize - src)))"
        logField("Size vs source:", src > 0 ? "\(String(format: "%.2f", ratio))× (\(delta))" : "—")
        logField("Encode time:", String(format: "%.1fs (%.2f× realtime)", encodeElapsed, encodeSpeed))
        logField("Verify time:", String(format: "%.1fs", verifyElapsed))
        logField("Video verified:", "\(verifiedVideoFrames) frames (per-frame MD5)")
        logField("Audio verified:", audioVerifyDetail.isEmpty
            ? (audioStreamMD5.isEmpty ? "(not reached)" : "whole-stream MD5 \(audioStreamMD5)")
            : audioVerifyDetail)
        if let evidence { logField("Evidence:", evidence) }
        appLog.write("───────────────────────────────────────────────")

        // Mirror the headline to the unified log too.
        if verified {
            transcodeLog.info("preservation SUMMARY: VERIFIED \(self.publishedURL.lastPathComponent, privacy: .public) — \(Self.humanBytes(outputSize), privacy: .public), \(String(format: "%.2f", ratio), privacy: .public)× source, encode \(String(format: "%.1f", self.encodeElapsed), privacy: .public)s, verify \(String(format: "%.1f", self.verifyElapsed), privacy: .public)s")
        } else {
            transcodeLog.error("preservation SUMMARY: FAILED \(self.outputURL.lastPathComponent, privacy: .public) — \(evidence ?? "not proven", privacy: .public)")
        }
    }
}
