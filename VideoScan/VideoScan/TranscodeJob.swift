import Combine
import Foundation
import os

// MARK: - TranscodeJob
//
// "Transcode" — Rick 2026-06-14 (Pass C). Faithful conversion to one of
// three derivative recipes. Unlike ReformatJob (which deinterlaces +
// denoises + analyses), Transcode does NO filtering and does NOT
// auto-queue Analyze: the user clicked Transcode because they want a
// derivative for editing, access, or preservation — auto-analysis would
// just step on the workflow.
//
// Why these presets and not a generic codec picker:
//   - Editing       → drop into FCP, let FCP own the export. Big file,
//     deleted after the edit. Wants ProRes 422 HQ + PCM (FCP's preferred
//     timeline codec on Apple Silicon).
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

// MARK: - Preset

/// Which Transcode recipe to run. Drives the args list, the output suffix
/// (`.vs.edit.mov` / `.vs.archive.mov` / `.vs.preserve.mkv`), and the
/// subtitle text. (Swift's `String`-raw-value enum ≈ a C++ enum class with
/// a `to_string` member built in.)
enum TranscodePreset: String {
    case editing
    case archival
    case preservation

    /// Tag used in the derived-file naming convention.
    ///
    /// See DerivedFileNaming.swift — the convention is
    /// `<stem>.vs.<purpose>.<codec>.<timestamp>.<ext>`. We pick a single
    /// short codec token per preset so the derived files self-describe in
    /// Finder.
    var codecTag: String {
        switch self {
        case .editing:      return "prores422hq"
        case .archival:     return "hevc10bit"
        case .preservation: return "ffv1v3"
        }
    }

    /// Purpose segment in the derived-file naming convention. Used as a
    /// Finder search anchor ("show me all my archive derivatives").
    var purposeTag: String {
        switch self {
        case .editing:      return "edit"
        case .archival:     return "archive"
        case .preservation: return "preserve"
        }
    }

    /// Output container extension. Editing/Archival are QuickTime (.mov)
    /// because their codecs (ProRes / HEVC+AAC) are what FCP and
    /// AVFoundation expect in a .mov. Preservation is Matroska (.mkv):
    /// FFV1 + FLAC is the FADGI/LoC-blessed lossless combo, and Matroska
    /// is the archival container that carries them losslessly (QuickTime
    /// can't hold FFV1).
    var fileExtension: String {
        switch self {
        case .editing, .archival: return "mov"
        case .preservation:       return "mkv"
        }
    }

    /// Live subtitle in the operations window while the encode runs.
    var subtitle: String {
        switch self {
        case .editing:      return "Transcoding to ProRes 422 HQ…"
        case .archival:     return "Transcoding to HEVC 10-bit…"
        case .preservation: return "Encoding FFV1 v3 preservation master…"
        }
    }

    /// Human label used in the journey/notes stamp + success summary and
    /// in the context-menu button.
    var humanLabel: String {
        switch self {
        case .editing:      return "Editing (ProRes 422 HQ)"
        case .archival:     return "Archival (HEVC 10-bit)"
        case .preservation: return "Preservation Master (FFV1 v3, verified)"
        }
    }
}

// MARK: - Pure args builder
//
// Extracted as a static func so TranscodeTests can assert the args list
// without actually invoking ffmpeg (modeled on
// `ReformatJob.parseProgressSeconds`). The "never pass-through lossy
// audio" invariant lives here too — Editing/Archival hard-code their audio
// codec. A future regression that swaps in `-c:a copy` for those presets
// breaks the `transcodePreset_neverPassesThroughAudio` test loudly.

extension TranscodeJob {

    /// Build the ffmpeg argument vector for a given preset, input path, and
    /// output path. Pure — no I/O, no Process spawn. Testable.
    ///
    /// `sourceAudioIsPCM` is consulted ONLY by the `.preservation` branch
    /// (match-source audio: PCM → verbatim copy, anything else → FLAC). The
    /// editing/archival call sites keep working unchanged via the default.
    nonisolated static func transcodeArgs(preset: TranscodePreset,
                                          input: String,
                                          output: String,
                                          sourceAudioIsPCM: Bool = false) -> [String] {
        switch preset {
        case .editing:
            // ProRes 422 HQ via Apple Silicon hardware encoder.
            //   - prores_videotoolbox profile 3 = 422 HQ (the FCP timeline
            //     default).
            //   - yuv422p10le matches the profile's chroma + bit depth.
            //   - pcm_s24le is the lossless audio FCP expects in a ProRes
            //     timeline source.
            //   - prores_metadata bitstream filter pins BT.709 color tags
            //     so FCP doesn't second-guess the color space.
            //   - +write_colr writes the QuickTime 'colr' atom so
            //     AVFoundation reads the tags back correctly.
            return [
                "-hide_banner",
                "-nostdin",
                "-y",
                "-hwaccel", "videotoolbox",
                "-i", input,
                "-c:v", "prores_videotoolbox",
                "-profile:v", "3",
                "-pix_fmt", "yuv422p10le",
                "-c:a", "pcm_s24le",
                "-ar", "48000",
                "-bsf:v", "prores_metadata=color_primaries=bt709:color_trc=bt709:colorspace=bt709",
                "-movflags", "+write_colr",
                "-progress", "pipe:2",
                output
            ]

        case .archival:
            // HEVC 10-bit via Apple Silicon hardware encoder.
            //   - hevc_videotoolbox + p010le = 10-bit 4:2:0 (matches
            //     VideoToolbox's preferred input layout on M-series).
            //   - -q:v 60 is VBR quality mode — 60 = high-quality archive
            //     (≈ CRF 20 visually). Lower numbers = bigger.
            //   - -tag:v hvc1 so QuickTime/AVFoundation decode natively
            //     (without this, default 'hev1' tag forces software
            //     fallback on some Apple players).
            //   - Explicit BT.709 color tags so playback matches the
            //     source's intended color space.
            //   - aac_at = Apple AudioToolbox AAC — best-quality AAC
            //     encoder on macOS, offloads to the audio coprocessor.
            //   - +faststart moves the moov atom to the front so
            //     streaming/web-browser playback starts immediately.
            return [
                "-hide_banner",
                "-nostdin",
                "-y",
                "-hwaccel", "videotoolbox",
                "-i", input,
                "-c:v", "hevc_videotoolbox",
                "-q:v", "60",
                "-pix_fmt", "p010le",
                "-tag:v", "hvc1",
                "-color_primaries", "bt709",
                "-color_trc", "bt709",
                "-colorspace", "bt709",
                "-c:a", "aac_at",
                "-b:a", "256k",
                "-movflags", "+faststart",
                "-progress", "pipe:2",
                output
            ]

        case .preservation:
            // FFV1 v3 lossless preservation master (FADGI / Library of
            // Congress archival recipe). Software encode — there is no
            // hardware FFV1 path, and we WANT the deterministic software
            // codec for an archive deposit anyway.
            //
            // Video flags (the "why" for each, for the archive record):
            //   - ffv1 -level 3      : FFV1 version 3, the only level FADGI
            //                          and the LoC accept (self-describing
            //                          header, CRC support).
            //   - -coder 1           : range coder (better compression than
            //                          the legacy Golomb-Rice -coder 0).
            //   - -context 1         : large context model — slightly
            //                          smaller files, standard for archive.
            //   - -g 1               : GOP size 1 → every frame is an
            //                          intra frame. Mandatory for archival
            //                          so any single frame is independently
            //                          decodable / recoverable.
            //   - -slices 24         : split each frame into 24 slices.
            //                          Parallelises encode/decode AND
            //                          localises corruption to one slice.
            //   - -slicecrc 1        : per-slice CRC. This is what lets a
            //                          future reader DETECT bit rot at the
            //                          slice level — central to the
            //                          preservation use case.
            //   - NO -pix_fmt        : deliberately omitted. FFV1 supports
            //                          the source chroma + bit depth
            //                          natively; forcing a pix_fmt would
            //                          resample and DESTROY losslessness.
            //                          We preserve the source pixels exactly.
            //   - NO color flags     : VideoRecord only carries a single
            //                          coarse `colorSpace` string, not the
            //                          full primaries/trc/range triplet, so
            //                          we let ffmpeg PROPAGATE the source
            //                          color metadata rather than risk
            //                          MISLABELLING SD home video (bt601 /
            //                          smpte170m) as bt709. If/when
            //                          VideoRecord exposes the full triplet
            //                          we can emit -color_primaries /
            //                          -color_trc / -colorspace /
            //                          -color_range here to make the file
            //                          self-describing.
            //
            // Audio — "match source" (the sanctioned PCM-copy exception,
            // see the file header):
            //   - PCM source  → `-c:a copy`. The source audio is already
            //                   uncompressed; copying the verbatim bytes is
            //                   the most faithful possible preservation. This
            //                   is the ONE place -c:a copy is allowed.
            //   - everything  → `-c:a flac`. FLAC is lossless; ffmpeg can
            //     else            DECODE legacy/undecodable codecs (QDM2,
            //                     MP3, AAC, …) even when AVFoundation can't,
            //                     then re-encode losslessly. We capture the
            //                     decoded audio with zero generation loss
            //                     rather than copy a codec a future reader
            //                     might not be able to open.
            //
            //   - -map_metadata 0    : carry all source metadata into the
            //                          master (timecode, tape name, etc.).
            var args: [String] = [
                "-hide_banner",
                "-nostdin",
                "-y",
                "-i", input,
                "-map", "0:v:0",
                "-map", "0:a:0",
                "-c:v", "ffv1",
                "-level", "3",
                "-coder", "1",
                "-context", "1",
                "-g", "1",
                "-slices", "24",
                "-slicecrc", "1"
            ]
            if sourceAudioIsPCM {
                args += ["-c:a", "copy"]
            } else {
                args += ["-c:a", "flac"]
            }
            args += [
                "-map_metadata", "0",
                "-progress", "pipe:2",
                output
            ]
            return args
        }
    }
}

// MARK: - Frame MD5 verification (preservation only)
//
// The safety-critical core of the Preservation preset. We decode BOTH the
// source and the freshly-written FFV1 master to per-frame MD5 hashes
// (ffmpeg's `-f framemd5` muxer) and compare them element-wise. If every
// frame hash matches, the FFV1 file is PROVABLY bit-exact with the source
// at the decoded-pixel / decoded-sample level — exactly the guarantee an
// archive deposit needs.
//
// The COMPARE is extracted as a pure function (`compareFrameMD5`) so it can
// be unit-tested against string fixtures with zero subprocess plumbing.

/// Result of comparing two framemd5 streams. `Equatable` so tests can
/// assert exact verdicts. (≈ a C++ tagged union / std::variant.)
enum FrameMD5Verdict: Equatable {
    /// Every per-frame hash matched, in order. Bit-exact.
    case match
    /// The first frame whose hashes diverged (0-based), with both hashes.
    case mismatch(frameIndex: Int, source: String, output: String)
    /// The streams couldn't be meaningfully compared (empty input, no hash
    /// tokens, differing frame counts, …). The associated string explains.
    case malformed(String)
}

extension TranscodeJob {

    /// Compare two `framemd5`-format strings, frame by frame. PURE — no
    /// I/O. The input is the literal stdout ffmpeg's framemd5 muxer
    /// produces:
    ///
    ///     # software: ...
    ///     # tb 0: 1/30
    ///     0,          0,          0,     1,   152064, d41d8c...<hash>
    ///     0,          1,          1,     1,   152064, 9e107d...<hash>
    ///
    /// We:
    ///   - drop comment/header lines (those starting with `#`),
    ///   - take the LAST whitespace/comma-separated token of each remaining
    ///     line as that frame's hash,
    ///   - compare the two hash arrays element-wise,
    ///   - on the first divergence return `.mismatch` with the 0-based
    ///     frame index and both hashes,
    ///   - empty input or differing frame counts → a sensible verdict.
    nonisolated static func compareFrameMD5(source: String,
                                            output: String) -> FrameMD5Verdict {
        let srcHashes = frameMD5Hashes(from: source)
        let outHashes = frameMD5Hashes(from: output)

        if srcHashes.isEmpty && outHashes.isEmpty {
            return .malformed("both framemd5 streams were empty — no frame hashes parsed")
        }
        if srcHashes.isEmpty {
            return .malformed("source framemd5 stream had no frame hashes")
        }
        if outHashes.isEmpty {
            return .malformed("output framemd5 stream had no frame hashes")
        }

        // Compare the overlapping prefix first so we report the EARLIEST
        // real divergence even when the counts also differ.
        let n = min(srcHashes.count, outHashes.count)
        var i = 0
        while i < n {
            if srcHashes[i] != outHashes[i] {
                return .mismatch(frameIndex: i,
                                 source: srcHashes[i],
                                 output: outHashes[i])
            }
            i += 1
        }

        if srcHashes.count != outHashes.count {
            return .malformed("frame count mismatch — source has \(srcHashes.count) frames, output has \(outHashes.count)")
        }

        return .match
    }

    /// Extract the per-frame hash tokens from a framemd5 stream. Comment /
    /// header lines (leading `#`) and blank lines are dropped; for every
    /// remaining line the hash is the LAST comma-or-whitespace token.
    nonisolated private static func frameMD5Hashes(from stream: String) -> [String] {
        var hashes: [String] = []
        hashes.reserveCapacity(1024)
        for rawLine in stream.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            // framemd5 columns are comma-separated, but be liberal and also
            // split on whitespace so a hand-written fixture still parses.
            let tokens = line.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" })
            guard let last = tokens.last else { continue }
            hashes.append(String(last))
        }
        return hashes
    }

    /// Number of per-frame MD5 rows in a framemd5 dump (ignores `#` headers).
    /// Used only for the archive-grade summary's "frames verified" count.
    nonisolated static func frameCount(_ stream: String) -> Int {
        frameMD5Hashes(from: stream).count
    }
}

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

    /// Where the derivative lands. Computed once at init using the
    /// project-wide DerivedFileNaming convention, then patched to guarantee
    /// the suffix invariants the TranscodeTests assert (`.vs.edit.mov` for
    /// editing, `.vs.archive.mov` for archival, `.vs.preserve.mkv` for
    /// preservation). The extension is preset-driven via
    /// `TranscodePreset.fileExtension`.
    let outputURL: URL

    /// Weak refs — the model holds Jobs via MediaFileOperationsCenter, the
    /// orchestrator isn't actually used by Transcode (we don't auto-queue
    /// Analyze) but we keep the parameter for parity with startReformat's
    /// call shape.
    private weak var model: VideoScanModel?

    /// Pause is OFF — same reasoning as ReformatJob (no clean
    /// suspend/resume contract through ffmpeg's subprocess state).
    let canPause = false

    @Published private(set) var state: MediaFileOperationState = .running
    @Published private(set) var subtitleText: String
    @Published private(set) var fractionValue: Double = 0
    @Published private(set) var isIndeterminateValue: Bool = true

    /// The run Task — internal so tests can `await job.task?.value`.
    private(set) var task: Task<Void, Never>?

    /// Total source duration in seconds, used for the fraction.
    private var totalDurationSeconds: Double = 0

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

    init(record: VideoRecord, preset: TranscodePreset, model: VideoScanModel) {
        self.record = record
        self.preset = preset
        self.model = model
        self.subtitleText = preset.subtitle

        // Build a derived URL using the project-wide convention, then
        // overlay the simple-suffix form the Pass C spec requires. The
        // extension is preset-driven (`fileExtension`) so the suffix is
        // `.vs.edit.mov`, `.vs.archive.mov`, or `.vs.preserve.mkv`. We keep
        // the convention helper for the directory + stem extraction so the
        // file lands beside the source, with the source's stem.
        let srcURL = URL(fileURLWithPath: record.fullPath)
        let stem = srcURL.deletingPathExtension().lastPathComponent
        let dir = srcURL.deletingLastPathComponent()
        let suffix = "\(stem).vs.\(preset.purposeTag).\(preset.fileExtension)"
        self.outputURL = dir.appendingPathComponent(suffix)
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

        if preset == .preservation {
            transcodeLog.info("preservation: starting FFV1 v3 master for \(self.record.filename, privacy: .public) → \(self.outputURL.lastPathComponent, privacy: .public)")
        }

        // Clean up any prior derivative (resumed from a cancel).
        try? FileManager.default.removeItem(atPath: outputPath)

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
                                      output: outputPath,
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
        let progressUpdater: @Sendable (String) -> Void = { [weak self] line in
            guard let self else { return }
            let sec = ReformatJob.parseProgressSeconds(line: line)
            guard let sec, totalDur > 0 else { return }
            Task { @MainActor in
                self.fractionValue = min(1.0, sec / totalDur)
                self.isIndeterminateValue = false
            }
        }

        let encodeStart = Date()
        let _ = await ProcessRunner.runStreaming(
            executable: ffmpeg,
            arguments: args,
            environment: nil,
            stderrLine: progressUpdater
        )
        encodeElapsed = Date().timeIntervalSince(encodeStart)

        // Cancelled mid-run?
        if Task.isCancelled || state == .cancelling {
            try? FileManager.default.removeItem(atPath: outputPath)
            await finish(cancelled: true)
            return
        }

        // Verify output is non-trivial (ffmpeg occasionally returns 0 but
        // writes a header-only file when a codec library is missing or the
        // input has an unrecoverable stream).
        guard FileManager.default.fileExists(atPath: outputPath) else {
            await finish(failed: "ffmpeg finished but no output file was produced")
            return
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: outputPath)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        if size < 10_000 {
            try? FileManager.default.removeItem(atPath: outputPath)
            await finish(failed: "ffmpeg output too small (\(size) bytes) — likely a codec failure")
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
        return await runDecodeCapture(ffmpeg: ffmpeg, args: args)
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
        let out = await runDecodeCapture(ffmpeg: ffmpeg, args: args)
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
    private func runDecodeCapture(ffmpeg: String, args: [String]) async -> String {
        let totalDur = totalDurationSeconds
        let progressUpdater: @Sendable (String) -> Void = { [weak self] line in
            guard let self else { return }
            let sec = ReformatJob.parseProgressSeconds(line: line)
            guard let sec, totalDur > 0 else { return }
            Task { @MainActor in
                self.fractionValue = min(1.0, sec / totalDur)
                self.isIndeterminateValue = false
            }
        }

        let stdout = await ProcessRunner.runStreaming(
            executable: ffmpeg,
            arguments: args,
            environment: nil,
            stderrLine: progressUpdater
        )
        return stdout ?? ""
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
