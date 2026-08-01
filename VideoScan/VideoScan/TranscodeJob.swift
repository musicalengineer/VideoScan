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
// verification step captures framemd5 stdout in memory — worst case for a
// long file is ~30k frames × ~50 bytes ≈ 1.5 MB per stream, bounded and
// freed immediately after the compare. No intermediate media files.
//
// Cancellation: Task.cancel → ProcessRunner kills ffmpeg → partial output
// is deleted in the cleanup path. The verify phase honors cancellation the
// same way (the output master is left in place so the user can re-verify).

private let transcodeLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                  category: "fileOps")

// MARK: - Job

@MainActor
final class TranscodeJob: MediaFileOperationJob {

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
    private var stallReason: String?

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
        model: VideoScanModel
    ) {
        self.record = record
        self.preset = preset
        self.outputURL = outputURL.standardizedFileURL
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
        state = .cancelling
        subtitleText = "Cancelling…"
        task?.cancel()
    }

    // MARK: Transcode run

    private func runTranscode() async {
        totalDurationSeconds = max(0, record.durationSeconds)

        let inputPath = record.fullPath
        let outputPath = outputURL.path
        // ffmpeg encodes here; we atomic-rename to outputPath only after a
        // COMPLETE, non-trivial encode (#6.3). A killed/stalled encode leaves
        // only this partial, which we delete — never a truncated master at
        // the real output path. The verify phase (preservation) runs against
        // the promoted FINAL file, and only ever reads it.
        let partialPath = ReformatJob.partialURL(for: outputURL).path

        let volumeLabel = VolumeReachability.displayLabel(forPath: inputPath)
        transcodeLog.info("transcode START: \(self.record.filename, privacy: .public) preset=\(self.preset.rawValue, privacy: .public) on \(volumeLabel, privacy: .public) → \(self.outputURL.lastPathComponent, privacy: .public)")

        if preset == .preservation {
            transcodeLog.info("preservation: starting FFV1 v3 master for \(self.record.filename, privacy: .public) → \(self.outputURL.lastPathComponent, privacy: .public)")
        }

        // Clean up any prior derivative + stale partial (resumed from a cancel).
        try? FileManager.default.removeItem(atPath: outputPath)
        try? FileManager.default.removeItem(atPath: partialPath)

        guard FileManager.default.fileExists(atPath: inputPath) else {
            await finish(failed: "Source file missing on disk")
            return
        }

        let ffmpeg = ToolLocator.ffmpegPath
        guard !ffmpeg.isEmpty, FileManager.default.fileExists(atPath: ffmpeg) else {
            await finish(failed: "ffmpeg not found (set VS_FFMPEG_PATH or install via Homebrew)")
            return
        }

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
        let _ = await ProcessRunner.runStreaming(
            executable: ffmpeg,
            arguments: args,
            environment: nil,
            control: pauser.control,
            stderrLine: progressUpdater
        )
        encodeMonitor.stop()
        encodeElapsed = Date().timeIntervalSince(encodeStart)

        // Watchdog stall wins over a generic cancel (the watchdog cancels
        // the Task) — surface the specific cause, not "Cancelled".
        if let stallReason {
            try? FileManager.default.removeItem(atPath: partialPath)
            transcodeLog.error("transcode FAILED (stall, encode): \(self.record.filename, privacy: .public) — \(stallReason, privacy: .public)")
            await finish(failed: stallReason)
            return
        }

        // Cancelled mid-run?
        if Task.isCancelled || state == .cancelling {
            try? FileManager.default.removeItem(atPath: partialPath)
            await finish(cancelled: true)
            return
        }

        // Verify output is non-trivial (ffmpeg occasionally returns 0 but
        // writes a header-only file when a codec library is missing or the
        // input has an unrecoverable stream).
        guard FileManager.default.fileExists(atPath: partialPath) else {
            await finish(failed: "ffmpeg finished but no output file was produced")
            return
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: partialPath)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        if size < 10_000 {
            try? FileManager.default.removeItem(atPath: partialPath)
            await finish(failed: "ffmpeg output too small (\(size) bytes) — likely a codec failure")
            return
        }

        // Atomic publish: a complete, non-trivial encode — promote the
        // partial to the real output name in one rename (#6.3). Verify (if
        // any) then reads the FINAL file, which it only ever reads.
        do {
            try ReformatJob.atomicPublish(from: partialPath, to: outputPath)
        } catch {
            try? FileManager.default.removeItem(atPath: partialPath)
            await finish(failed: "Could not finalize output file: \(error.localizedDescription)")
            return
        }

        // Preservation: PROVE the master is bit-exact before we declare
        // success. Any non-match keeps the file and fails loudly. For
        // editing/archival there's nothing to verify (they're intentionally
        // lossy/transformed), so we go straight to cataloguing.
        if preset == .preservation {
            let verdict = await verifyLossless(ffmpeg: ffmpeg,
                                               source: inputPath,
                                               output: outputPath)
            // A stall DURING verify (the literal 14 h framemd5 incident) must
            // fail loudly with attribution — not masquerade as a clean
            // cancel. The master is left on disk; the user can re-verify.
            if let stallReason {
                transcodeLog.error("transcode FAILED (stall, verify): \(self.record.filename, privacy: .public) — \(stallReason, privacy: .public)")
                await finish(failed: stallReason)
                return
            }
            if Task.isCancelled || state == .cancelling {
                // Leave the master in place — the user can re-run verify
                // later rather than re-encode an expensive FFV1 file.
                await finish(cancelled: true)
                return
            }
            switch verdict {
            case .verified:
                logPreservationSummary(outputSize: size, verified: true, sidecarName: nil)
                await catalogTranscodeOutput()
                await finish(success: "✓ Verified bit-exact lossless (frame MD5) → \(outputURL.lastPathComponent) (\(Self.humanBytes(size)))")
                return
            case .failed(let sidecarName):
                // Output kept on disk; sidecar written; loud failure.
                logPreservationSummary(outputSize: size, verified: false, sidecarName: sidecarName)
                await finish(failed: "Lossless verification FAILED — see \(sidecarName)")
                return
            }
        }

        await catalogTranscodeOutput()
        transcodeLog.info("transcode DONE: \(self.record.filename, privacy: .public) preset=\(self.preset.rawValue, privacy: .public) → \(self.outputURL.lastPathComponent, privacy: .public) (\(Self.humanBytes(size), privacy: .public)) encode \(self.encodeElapsed, format: .fixed(precision: 1), privacy: .public)s")
        await finish(success: "Transcoded → \(outputURL.lastPathComponent) (\(Self.humanBytes(size))).")
    }

    // MARK: Preservation verification

    /// Outcome of the preservation verify phase.
    private enum VerifyOutcome {
        case verified
        case failed(sidecarName: String)
    }

    /// Decode source + output to per-frame MD5 (video AND audio) and prove
    /// they match. Drives the progress bar off the verify decode's
    /// `-progress` output so a long file doesn't show a stuck bar. On any
    /// mismatch/malformed verdict, writes a `<output>.framemd5-MISMATCH.log`
    /// sidecar and returns `.failed`.
    private func verifyLossless(ffmpeg: String,
                                source: String,
                                output: String) async -> VerifyOutcome {
        transcodeLog.info("preservation verify: starting frame-MD5 comparison for \(self.outputURL.lastPathComponent, privacy: .public)")
        let verifyStart = Date()
        defer { verifyElapsed = Date().timeIntervalSince(verifyStart) }

        // ---- Video stream ----
        subtitleText = "Verifying lossless — video frame MD5…"
        fractionValue = 0
        isIndeterminateValue = (totalDurationSeconds == 0)

        let srcVideoMD5 = await framemd5(ffmpeg: ffmpeg, file: source)
        if Task.isCancelled || state == .cancelling { return .verified /* caller re-checks cancel */ }
        let outVideoMD5 = await framemd5(ffmpeg: ffmpeg, file: output)
        if Task.isCancelled || state == .cancelling { return .verified }

        let videoVerdict = Self.compareFrameMD5(source: srcVideoMD5, output: outVideoMD5)
        if videoVerdict != .match {
            let name = writeMismatchSidecar(stream: "video",
                                            verdict: videoVerdict,
                                            sourceStream: srcVideoMD5,
                                            outputStream: outVideoMD5)
            transcodeLog.error("preservation verify: VIDEO mismatch (\(String(describing: videoVerdict), privacy: .public)) → wrote \(name, privacy: .public)")
            return .failed(sidecarName: name)
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

            let srcAudioMD5 = await streamMD5(ffmpeg: ffmpeg, file: source, pcmCodec: pcmCodec)
            if Task.isCancelled || state == .cancelling { return .verified }
            let outAudioMD5 = await streamMD5(ffmpeg: ffmpeg, file: output, pcmCodec: pcmCodec)
            if Task.isCancelled || state == .cancelling { return .verified }

            if srcAudioMD5.isEmpty || outAudioMD5.isEmpty || srcAudioMD5 != outAudioMD5 {
                let name = writeAudioMismatchSidecar(source: srcAudioMD5,
                                                     output: outAudioMD5,
                                                     pcmCodec: pcmCodec)
                audioStreamMD5 = ""   // distinguishes failure from no-audio in the summary
                audioVerifyDetail = "MISMATCH at \(pcmCodec) — see sidecar"
                transcodeLog.error("preservation verify: AUDIO whole-stream MD5 mismatch @\(pcmCodec, privacy: .public) (src=\(srcAudioMD5, privacy: .public) out=\(outAudioMD5, privacy: .public)) → wrote \(name, privacy: .public)")
                return .failed(sidecarName: name)
            }
            audioStreamMD5 = srcAudioMD5
            audioVerifyDetail = "whole-stream MD5 \(srcAudioMD5) @\(pcmCodec)"
            transcodeLog.info("preservation verify: audio stream bit-exact (whole-stream MD5 \(srcAudioMD5, privacy: .public) @\(pcmCodec, privacy: .public), \(self.outputURL.lastPathComponent, privacy: .public))")
        } else {
            audioVerifyDetail = "(no audio stream)"
        }

        transcodeLog.info("preservation verify: PASS — \(self.outputURL.lastPathComponent, privacy: .public) is bit-exact lossless")
        return .verified
    }

    /// Decode the VIDEO stream to per-frame MD5 (`-f framemd5`) and return
    /// the captured stdout. Per-frame on video is reliable — the frame
    /// count is fixed by the coded pictures, independent of container — and
    /// the localization (which frame diverged) is worth keeping. Progress
    /// (`-progress pipe:2`) streams to stderr and drives the bar so a long
    /// decode never shows a stuck bar.
    private func framemd5(ffmpeg: String, file: String) async -> String {
        let args = ["-hide_banner", "-nostdin", "-i", file,
                    "-map", "0:v:0", "-an",
                    "-f", "framemd5", "-progress", "pipe:2", "-"]
        return await runDecodeCapture(ffmpeg: ffmpeg, args: args, phase: "verify (video framemd5)")
    }

    /// Decode the AUDIO stream to a single WHOLE-STREAM MD5 and return just
    /// the hex hash (`MD5=…` parsed off). `pcmCodec` forces an explicit
    /// integer PCM format (e.g. "pcm_s24le") so source and master are hashed
    /// in the SAME representation — without it, `-f md5` would hash each side
    /// in its own native format (float for AAC/MP3, int for FLAC/PCM) and
    /// always mismatch. Whole-stream (not per-frame) so a MOV→MKV PCM
    /// re-block can't false-fail byte-identical audio. Returns "" on failure
    /// so the caller fails loudly.
    private func streamMD5(ffmpeg: String, file: String, pcmCodec: String) async -> String {
        let args = ["-hide_banner", "-nostdin", "-i", file,
                    "-map", "0:a:0", "-vn",
                    "-c:a", pcmCodec,
                    "-f", "md5", "-progress", "pipe:2", "-"]
        let out = await runDecodeCapture(ffmpeg: ffmpeg, args: args, phase: "verify (audio md5)")
        return Self.parseStreamMD5(out)
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
    /// `-progress pipe:2` stderr, and returns captured stdout (the md5
    /// lines). Bounded output; see the file-header memory note.
    ///
    /// Guarded by a StallMonitor (#6): the framemd5 decode of an archival
    /// master is the EXACT op that wedged for 14 h. Each progress line kicks
    /// the watchdog; silence past the threshold cancels the run (killing the
    /// ffmpeg child via ProcessRunner) and records a specific stall reason
    /// that the verify branch surfaces as a loud failure.
    private func runDecodeCapture(ffmpeg: String, args: [String], phase: String) async -> String {
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
        let stdout = await ProcessRunner.runStreaming(
            executable: ffmpeg,
            arguments: args,
            environment: nil,
            control: pauser.control,
            stderrLine: progressUpdater
        )
        monitor.stop()
        return stdout ?? ""
    }

    // MARK: Stall handling

    /// Invoked (on the main actor) by a StallMonitor when an ffmpeg phase
    /// flatlines. Records a SPECIFIC reason with volume-drop vs file-error
    /// attribution (#6.4) and cancels the run — killing the ffmpeg child via
    /// ProcessRunner's SIGTERM→SIGKILL escalation. Idempotent across the
    /// encode + the (possibly several) verify decodes: the first stall wins.
    private func handleStall(phase: String, silentFor: Double) {
        guard state.isActive, stallReason == nil else { return }
        let attribution = StallMonitor.attribution(forPaths: [record.fullPath, outputURL.path])
        let reason = "Stalled — no ffmpeg progress for \(Int(silentFor))s during \(phase). \(attribution)"
        stallReason = reason
        subtitleText = "Stalled — stopping…"
        transcodeLog.error("transcode WATCHDOG: killing \(self.record.filename, privacy: .public) (\(phase, privacy: .public)) — \(reason, privacy: .public)")
        appLog.write("transcode watchdog: \(record.filename) stalled \(Int(silentFor))s during \(phase) — \(attribution); killing ffmpeg")
        task?.cancel()
    }

    /// Write `<output>.framemd5-MISMATCH.log` next to the master with the
    /// verdict details and enough of both framemd5 streams to investigate.
    /// Returns the sidecar's last-path-component for the failure message.
    private func writeMismatchSidecar(stream: String,
                                      verdict: FrameMD5Verdict,
                                      sourceStream: String,
                                      outputStream: String) -> String {
        let sidecarURL = URL(fileURLWithPath: outputURL.path + ".framemd5-MISMATCH.log")

        var body = ""
        body += "VideoScan — Preservation master lossless verification FAILED\n"
        body += "Generated: \(ISO8601DateFormatter().string(from: Date()))\n"
        body += "Source:  \(record.fullPath)\n"
        body += "Master:  \(outputURL.path)\n"
        body += "Stream:  \(stream)\n"
        switch verdict {
        case .match:
            body += "Verdict: (match — unexpected in a mismatch sidecar)\n"
        case .mismatch(let frameIndex, let src, let out):
            body += "Verdict: MISMATCH at frame \(frameIndex) (0-based)\n"
            body += "  source hash: \(src)\n"
            body += "  master hash: \(out)\n"
        case .malformed(let why):
            body += "Verdict: MALFORMED — \(why)\n"
        }
        body += "\n----- source framemd5 (\(stream)) -----\n"
        body += truncateForSidecar(sourceStream)
        body += "\n----- master framemd5 (\(stream)) -----\n"
        body += truncateForSidecar(outputStream)
        body += "\n"

        do {
            try body.write(to: sidecarURL, atomically: true, encoding: .utf8)
            transcodeLog.error("preservation verify: wrote mismatch sidecar \(sidecarURL.lastPathComponent, privacy: .public)")
        } catch {
            transcodeLog.error("preservation verify: FAILED to write mismatch sidecar: \(String(describing: error), privacy: .public)")
        }
        return sidecarURL.lastPathComponent
    }

    /// Audio counterpart to writeMismatchSidecar — audio is verified by a
    /// single whole-stream md5, so there's nothing to localize; we just
    /// record the two hashes. An empty hash means ffmpeg failed to decode
    /// that side at all (called out explicitly).
    private func writeAudioMismatchSidecar(source: String, output: String, pcmCodec: String) -> String {
        let sidecarURL = URL(fileURLWithPath: outputURL.path + ".framemd5-MISMATCH.log")

        var body = ""
        body += "VideoScan — Preservation master lossless verification FAILED\n"
        body += "Generated: \(ISO8601DateFormatter().string(from: Date()))\n"
        body += "Source:  \(record.fullPath)  (audio \(record.audioCodec))\n"
        body += "Master:  \(outputURL.path)\n"
        body += "Stream:  audio (whole-stream MD5)\n"
        body += "Compared as: \(pcmCodec) — both sides decoded to this integer PCM format\n"
        body += "Verdict: MISMATCH\n"
        body += "  source MD5: \(source.isEmpty ? "(ffmpeg produced no hash — decode failed)" : source)\n"
        body += "  master MD5: \(output.isEmpty ? "(ffmpeg produced no hash — decode failed)" : output)\n"
        body += "\n"
        body += "Note: both streams were decoded to \(pcmCodec) before hashing, so a\n"
        body += "mismatch here means the decoded samples genuinely differ — not a\n"
        body += "float-vs-int representation artifact. Reproduce with:\n"
        body += "  ffmpeg -i <file> -map 0:a:0 -vn -c:a \(pcmCodec) -f md5 -\n"

        do {
            try body.write(to: sidecarURL, atomically: true, encoding: .utf8)
            transcodeLog.error("preservation verify: wrote audio mismatch sidecar \(sidecarURL.lastPathComponent, privacy: .public)")
        } catch {
            transcodeLog.error("preservation verify: FAILED to write audio mismatch sidecar: \(String(describing: error), privacy: .public)")
        }
        return sidecarURL.lastPathComponent
    }

    /// Cap each framemd5 dump in the sidecar so a 30k-frame file doesn't
    /// produce a multi-MB log. We keep the head (where divergence almost
    /// always is) plus a tail marker.
    private func truncateForSidecar(_ stream: String, maxLines: Int = 400) -> String {
        let lines = stream.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maxLines else { return stream }
        let head = lines.prefix(maxLines).joined(separator: "\n")
        return head + "\n… (truncated, \(lines.count - maxLines) more lines)\n"
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
        let newURL = outputURL
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

            if let existing = model.records.firstIndex(where: { $0.fullPath == newURL.path }) {
                model.records[existing] = newRec
            } else {
                model.records.append(newRec)
            }
            transcodeLog.info("transcode: catalogued \(newURL.lastPathComponent, privacy: .public) as \(self.preset.rawValue, privacy: .public) derivative (workspaceActive=true, derivedFrom=\(self.record.id.uuidString, privacy: .public))")
        }
    }

    // MARK: Finish helpers

    private func finish(success: String) async {
        state = .finished(summary: success)
        subtitleText = success
        fractionValue = 1.0
        isIndeterminateValue = false
    }

    private func finish(failed: String) async {
        state = .failed(message: failed)
        subtitleText = failed
        isIndeterminateValue = false
        transcodeLog.warning("transcode failed: \(failed, privacy: .public)")
    }

    private func finish(cancelled: Bool) async {
        state = .cancelled
        subtitleText = "Cancelled"
        isIndeterminateValue = false
    }

    private static func humanBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
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

    /// SUMMARY record — emitted once the verify phase resolves (pass or fail).
    private func logPreservationSummary(outputSize: Int64, verified: Bool, sidecarName: String?) {
        let src = record.sizeBytes
        let ratio = src > 0 ? Double(outputSize) / Double(src) : 0
        let encodeSpeed = (encodeElapsed > 0 && record.durationSeconds > 0)
            ? record.durationSeconds / encodeElapsed : 0

        appLog.write("──────── PRESERVATION MASTER — SUMMARY ────────")
        logField("Result:", verified
            ? "✓ VERIFIED bit-exact lossless (frame MD5)"
            : "✗ VERIFICATION FAILED — master kept, see sidecar")
        logField("Master:", outputURL.path)
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
        if let sidecarName { logField("Mismatch log:", sidecarName) }
        appLog.write("───────────────────────────────────────────────")

        // Mirror the headline to the unified log too.
        if verified {
            transcodeLog.info("preservation SUMMARY: VERIFIED \(self.outputURL.lastPathComponent, privacy: .public) — \(Self.humanBytes(outputSize), privacy: .public), \(String(format: "%.2f", ratio), privacy: .public)× source, encode \(String(format: "%.1f", self.encodeElapsed), privacy: .public)s, verify \(String(format: "%.1f", self.verifyElapsed), privacy: .public)s")
        } else {
            transcodeLog.error("preservation SUMMARY: FAILED \(self.outputURL.lastPathComponent, privacy: .public) — see \(sidecarName ?? "sidecar", privacy: .public)")
        }
    }
}
