import Combine
import Foundation
import os

// MARK: - TranscodeJob
//
// "Transcode" — Rick 2026-06-14 (Pass C). Two-preset faithful conversion
// to either FCP-editable ProRes 422 HQ or archival HEVC 10-bit. Unlike
// ReformatJob (which deinterlaces + denoises + analyses), Transcode does
// NO filtering and does NOT auto-queue Analyze: the user clicked
// Transcode because they want a derivative for editing or long-term
// storage — auto-analysis would just step on the workflow.
//
// Why TWO presets and not a generic codec picker:
//   - Editing  → drop into FCP, let FCP own the export. Big file, deleted
//     after the edit. Wants ProRes 422 HQ + PCM (FCP's preferred timeline
//     codec on Apple Silicon).
//   - Archival → long-term storage, plays everywhere. Wants HEVC 10-bit
//     (5-10× smaller than ProRes for the same perceptual quality) +
//     AAC. Universal AVFoundation playback.
//
// Both presets HARD-CODE the audio codec — never `-c:a copy`. Some 1990s
// captures carry QDM2/MP3 audio that AVFoundation can't decode; copying
// it through would silently produce a file FCP can't play. PCM (Editing)
// and AAC (Archival) are both AVFoundation-native — the TranscodeTests
// suite asserts this guarantee so a future regression breaks loudly.
//
// Memory: ffmpeg streams; we hold no media in-process beyond the
// progress lines (worst case ~200 bytes per stderr write).
//
// Cancellation: Task.cancel → ProcessRunner kills ffmpeg → partial
// output is deleted in the cleanup path. Same idiom as ReformatJob.

private let transcodeLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                  category: "fileOps")

// MARK: - Preset

/// Which Transcode recipe to run. Drives the args list, the output
/// suffix (`.vs.edit.mov` / `.vs.archive.mov`), and the subtitle text.
/// (Swift's `String`-raw-value enum ≈ a C++ enum class with a
/// `to_string` member built in.)
enum TranscodePreset: String {
    case editing
    case archival

    /// Tag used in the derived-file naming convention.
    ///
    /// See DerivedFileNaming.swift — the convention is
    /// `<stem>.vs.<purpose>.<codec>.<timestamp>.<ext>`. We pick a single
    /// short codec token per preset so the derived files self-describe
    /// in Finder.
    var codecTag: String {
        switch self {
        case .editing:  return "prores422hq"
        case .archival: return "hevc10bit"
        }
    }

    /// Purpose segment in the derived-file naming convention.
    /// Used as a Finder search anchor ("show me all my archive
    /// derivatives").
    var purposeTag: String {
        switch self {
        case .editing:  return "edit"
        case .archival: return "archive"
        }
    }

    /// Live subtitle in the operations window while the encode runs.
    var subtitle: String {
        switch self {
        case .editing:  return "Transcoding to ProRes 422 HQ…"
        case .archival: return "Transcoding to HEVC 10-bit…"
        }
    }

    /// Human label used in the journey/notes stamp + success summary.
    var humanLabel: String {
        switch self {
        case .editing:  return "Editing (ProRes 422 HQ)"
        case .archival: return "Archival (HEVC 10-bit)"
        }
    }
}

// MARK: - Pure args builder
//
// Extracted as a static func so TranscodeTests can assert the args list
// without actually invoking ffmpeg (modeled on
// `ReformatJob.parseProgressSeconds`). The "never pass-through audio"
// invariant lives here too — both presets hard-code their audio codec.
// A future regression that swaps in `-c:a copy` will break the
// `transcodePreset_neverPassesThroughAudio` test loudly.

extension TranscodeJob {

    /// Build the ffmpeg argument vector for a given preset, input path,
    /// and output path. Pure — no I/O, no Process spawn. Testable.
    nonisolated static func transcodeArgs(preset: TranscodePreset,
                                          input: String,
                                          output: String) -> [String] {
        switch preset {
        case .editing:
            // ProRes 422 HQ via Apple Silicon hardware encoder.
            //   - prores_videotoolbox profile 3 = 422 HQ (the FCP
            //     timeline default).
            //   - yuv422p10le matches the profile's chroma + bit depth.
            //   - pcm_s24le is the lossless audio FCP expects in a
            //     ProRes timeline source.
            //   - prores_metadata bitstream filter pins BT.709 color
            //     tags so FCP doesn't second-guess the color space.
            //   - +write_colr writes the QuickTime 'colr' atom so
            //     AVFoundation reads the tags back correctly.
            return [
                "-hide_banner",
                "-nostdin",
                "-y",
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
            //   - -q:v 60 is VBR quality mode — 60 = high-quality
            //     archive (≈ CRF 20 visually). Lower numbers = bigger.
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
        }
    }
}

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

    /// Where the new .mov will land. Computed once at init using the
    /// project-wide DerivedFileNaming convention, then patched to
    /// guarantee the suffix invariants the TranscodeTests assert
    /// (`.vs.edit.mov` for editing, `.vs.archive.mov` for archival).
    let outputURL: URL

    /// Weak refs — the model holds Jobs via MediaFileOperationsCenter,
    /// the orchestrator isn't actually used by Transcode (we don't
    /// auto-queue Analyze) but we keep the parameter for parity with
    /// startReformat's call shape.
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
        // overlay the simple-suffix form (`.vs.edit.mov`,
        // `.vs.archive.mov`) the Pass C spec requires. We keep the
        // convention helper for the directory + stem extraction so the
        // file lands beside the source, with the source's stem.
        let srcURL = URL(fileURLWithPath: record.fullPath)
        let stem = srcURL.deletingPathExtension().lastPathComponent
        let dir = srcURL.deletingLastPathComponent()
        let suffix: String
        switch preset {
        case .editing:  suffix = "\(stem).vs.edit.mov"
        case .archival: suffix = "\(stem).vs.archive.mov"
        }
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

        let args = Self.transcodeArgs(preset: preset,
                                      input: inputPath,
                                      output: outputPath)

        subtitleText = preset.subtitle
        isIndeterminateValue = (totalDurationSeconds == 0)

        transcodeLog.info("transcode (\(self.preset.rawValue, privacy: .public)): ffmpeg \(args.joined(separator: " "), privacy: .public)")

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

        let _ = await ProcessRunner.runStreaming(
            executable: ffmpeg,
            arguments: args,
            environment: nil,
            stderrLine: progressUpdater
        )

        // Cancelled mid-run?
        if Task.isCancelled || state == .cancelling {
            try? FileManager.default.removeItem(atPath: outputPath)
            await finish(cancelled: true)
            return
        }

        // Verify output is non-trivial (ffmpeg occasionally returns 0
        // but writes a header-only file when a codec library is missing
        // or the input has an unrecoverable stream).
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

        await catalogTranscodeOutput()

        await finish(success: "Transcoded → \(outputURL.lastPathComponent) (\(Self.humanBytes(size))).")
    }

    /// Probe the new file and append to the catalog. Unlike
    /// ReformatJob, we DO NOT auto-queue Analyze — the user transcoded
    /// for FCP/archive, they don't want auto-analysis stepping on the
    /// workflow. They can right-click → Analyze later if they want it.
    ///
    /// Sets workspaceActive = true on the new record (it's in active
    /// editing/archival workflow) so the mint tint follows the
    /// derivative; sets derivedFrom = record.id so the catalog can
    /// surface the lineage; stamps a journey note on BOTH records.
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
}
