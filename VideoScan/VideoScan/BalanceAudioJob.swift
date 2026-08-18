import Combine
import Foundation
import os

// MARK: - BalanceAudioJob
//
// "Balance Audio" — GH #116, Rick 2026-07. Fixes one-sided audio on old
// tape ingests (classically left-channel-only) that Rick previously
// repaired by hand in FCP. The job consumes an AudioBalanceAnalysis
// (produced by the analyze-first sheet) and:
//
//   - leftOnly / rightOnly → duplicates the live channel to both sides
//     (`pan=stereo|c0=cX|c1=cX`);
//   - mono (single-channel stream) → spreads it to dual-mono stereo;
//   - dualMono / trueStereo / silent / multichannel → REFUSES with a
//     clear reason. dualMono is already balanced and trueStereo is real
//     stereo — "fixing" either would destroy good audio, so the refusal
//     is the safety-critical branch (pinned by negative tests). A file
//     where MORE than one audio stream carries program is refused the
//     same way — at ANALYZE time, through the one shared gate
//     (BalanceAudioFix.refusalReason(for: analysis)), so the sheet
//     never promises what the job would refuse.
//
// MULTI-AUDIO (12-bit DV, fix/balance-audio-dv-multitrack): DV
// camcorders in 12-bit audio mode record two stereo pairs (two audio
// streams). When exactly ONE carries program, the job maps video + THE
// program stream by absolute index, applies the pan fix to it, and
// DROPS the silent extra pair(s) — logged and noted in provenance.
//
// VIDEO IS NEVER RE-ENCODED: `-c copy` stream-copies every mapped
// stream (`-map 0` for single-audio sources — v1-identical; video +
// program track for multi-audio), then `-c:a …` overrides ONLY the
// audio (which must pass through the pan filter). PCM sources re-encode
// to the same PCM codec (lossless); lossy sources stay in their codec
// family at ≥ the source bitrate. The container is preserved (same
// extension ⇒ same muxer).
//
// Safety discipline (CleanupJob's, adapted):
//   - SOURCE NEVER MODIFIED — the pipeline only reads it (hash-oracle
//     sensor in BalanceAudioJobTests).
//   - Output `<stem>_balanced.<ext>` BESIDE the source. ffmpeg writes to
//     the `.vs-partial` sibling (ReformatJob.partialURL keeps the real
//     extension last, so the muxer is still inferred; the scan walker
//     skips `.vs-partial.` names). Promotion is a NON-CLOBBERING rename
//     re-uniquified at publish time (CleanupJob's M3 TOCTOU guard).
//     Cancel/crash leaves nothing at the final path.
//   - Free-space pre-check before rendering.
//   - Stall watchdog on ffmpeg's progress stream.
//   - POST-FIX VERIFICATION before promotion: the analyzer re-runs on
//     the partial and must classify it dualMono, with the video codec
//     unchanged, stream count preserved, and duration within tolerance.
//     A verification failure deletes the partial and fails loudly.
//
// Unlike CleanupJob there is NO scratch/RAM-disk phase: this is a remux
// with an audio-only re-encode — output ≈ source size, written once,
// directly to the same volume as the final name (rename is metadata-
// only).
//
// Memory: ffmpeg streams; this process holds only progress lines
// (bounded by ProcessRunner's 256 KB stderr cap) plus the verification
// analysis (~KBs). Worst-case in-process footprint < 1 MB.

private let balanceLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                category: "balanceAudio")

// MARK: - Pure fix rules

/// PURE decision tables for the balance fix — no I/O, fully
/// unit-testable (the TrimEngine/CleanupEngine split).
enum BalanceAudioFix {

    /// The provenance tag written to `VideoRecord.derivationKind`.
    static let derivationKind = "balanceAudio"

    /// Verification tolerance on the output's duration vs the source's.
    static let durationToleranceSeconds: Double = 1.0

    // MARK: Raw-DV container rule (fix/balance-dv-output-container)
    //
    // Diagnosed on Clip 28.dv (consumer 12-bit DV, 32 kHz): a raw `.dv`
    // OUTPUT container is a dead end — ffmpeg's dv muxer rejects 32 kHz
    // PCM ("must be 48000") and forcing `-ar 48000` crashes it outright
    // (fifo.c assertion, a genuine muxer bug). The fix: raw-DV sources
    // publish as QuickTime (.mov — the native iMovie wrapper these
    // clips came from) with the DV video stream-copied. That mux needs
    // one more thing: raw DV metadata reports a bogus avg_frame_rate
    // (60000/1; r_frame_rate is the true 30000/1001) and the mov muxer
    // fails at trailer-write ("fps 60000 is too large") unless the
    // PROBED r_frame_rate is fed back as an input-side `-r` override.

    /// True when ffprobe's `format_name` says the file is a raw DV
    /// stream. Raw DV probes as exactly "dv"; comma-splitting guards
    /// against shared-demuxer lists ("mov,mp4,m4a,3gp,3g2,mj2" — DV
    /// video INSIDE QuickTime is NOT raw DV and keeps its container).
    static func isRawDVContainer(_ containerFormat: String) -> Bool {
        containerFormat
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .contains("dv")
    }

    /// Input-side ffmpeg args for a raw-DV source: `-r <r_frame_rate>`
    /// with the PROBED rate — never hardcoded (NTSC DV is 30000/1001,
    /// PAL DV is 25/1). Empty for every other container, and empty when
    /// the probed rate is missing/degenerate ("0/0") — better to let
    /// ffmpeg guess than to force nonsense. Pure.
    static func rawDVInputArgs(shape: AudioBalanceStreamShape) -> [String] {
        guard isRawDVContainer(shape.containerFormat),
              let rate = shape.videoRFrameRate,
              let numerator = rate.split(separator: "/").first.flatMap({ Int($0) }),
              numerator > 0
        else { return [] }
        return ["-r", rate]
    }

    /// Stream-level refusal, decided at ANALYZE time: more than one
    /// audio stream carrying program is out of scope — Balance Audio
    /// fixes a single program track. (The 12-bit DV case with ONE
    /// program pair + a silent pair is NOT refused; the silent pair is
    /// dropped instead.) nil when at most one stream carries program.
    static func streamRefusalReason(programStreamCount: Int) -> String? {
        guard programStreamCount > 1 else { return nil }
        let quantifier = programStreamCount == 2 ? "both" : "all"
        return "\(programStreamCount) audio tracks \(quantifier) carry sound — Balance Audio handles a single program track."
    }

    /// THE one gate — the sheet's Balance button and the job's refusal
    /// branch BOTH call this, so what the sheet promises the job never
    /// refuses (the sensor in BalanceAudioMultiTrackTests pins this
    /// agreement). Stream-level refusal first, then the per-class table.
    static func refusalReason(for analysis: AudioBalanceAnalysis) -> String? {
        streamRefusalReason(programStreamCount: analysis.programStreamCount)
            ?? refusalReason(for: analysis.classification)
    }

    /// nil = actionable. Non-nil = the plain-language reason the job
    /// refuses (surfaced verbatim in the sheet and the job row).
    static func refusalReason(for c: AudioChannelClass) -> String? {
        switch c {
        case .leftOnly, .rightOnly, .mono:
            return nil
        case .dualMono:
            return "Already balanced — both channels carry the same sound."
        case .trueStereo:
            return "True stereo — nothing to fix."
        case .silent:
            return "No audio program — there is no sound to balance."
        case .multichannel:
            return "Surround (more than 2 channels) sound isn't supported by Balance Audio yet."
        }
    }

    /// The ffmpeg pan filter for an actionable class; nil otherwise.
    /// Duplicating the live channel (rather than a −3 dB split) keeps
    /// per-speaker loudness identical to what the one live channel had.
    static func panFilter(for c: AudioChannelClass) -> String? {
        switch c {
        case .leftOnly: return "pan=stereo|c0=c0|c1=c0"
        case .rightOnly: return "pan=stereo|c0=c1|c1=c1"
        case .mono: return "pan=stereo|c0=c0|c1=c0"
        case .trueStereo, .dualMono, .silent, .multichannel: return nil
        }
    }

    /// Audio encoder arguments: PCM in → SAME PCM codec out (lossless);
    /// lossy in → same codec family at ≥ the source bitrate (floor
    /// 192 kb/s so an unknown/low source bitrate never downgrades);
    /// unknown/unencodable codec → AAC 256 kb/s (documented fallback).
    static func audioEncodeArgs(sourceCodec: String,
                                bitRateBitsPerSec: Int?) -> [String] {
        let codec = sourceCodec.trimmingCharacters(in: .whitespaces).lowercased()
        if codec.hasPrefix("pcm_") {
            return ["-c:a", codec]                       // lossless, no bitrate
        }
        let lossyBitrate = max(bitRateBitsPerSec ?? 0, 192_000)
        switch codec {
        case "aac":  return ["-c:a", "aac", "-b:a", "\(lossyBitrate)"]
        case "mp3":  return ["-c:a", "libmp3lame", "-b:a", "\(min(lossyBitrate, 320_000))"]
        case "mp2":  return ["-c:a", "mp2", "-b:a", "\(min(lossyBitrate, 384_000))"]
        case "ac3":  return ["-c:a", "ac3", "-b:a", "\(min(lossyBitrate, 640_000))"]
        case "eac3": return ["-c:a", "eac3", "-b:a", "\(lossyBitrate)"]
        case "alac": return ["-c:a", "alac"]             // lossless
        default:
            // Legacy/unencodable codec family (qdm2, mace, cook, …):
            // modernize to AAC at a generous bitrate. The original is
            // untouched beside the output, so nothing is lost.
            return ["-c:a", "aac", "-b:a", "\(max(lossyBitrate, 256_000))"]
        }
    }

    /// Output mapping. Single-audio-stream files keep the historical
    /// `-map 0` (every stream carried — byte-identical behavior to v1).
    /// Multi-audio files (the 12-bit DV shape) map the video stream(s)
    /// plus THE program audio stream by ABSOLUTE container index —
    /// `0:\(index)`, never an assumed `0:a:0` — so the silent extra
    /// pair(s) are dropped. `0:v?` is the optional-map form: it matches
    /// zero video streams without erroring (audio-only files). Pure.
    static func mapArgs(audioStreams: Int, programStreamIndex: Int) -> [String] {
        audioStreams <= 1
            ? ["-map", "0"]
            : ["-map", "0:v?", "-map", "0:\(programStreamIndex)"]
    }

    /// Streams expected in the verified output: everything (single-
    /// audio `-map 0`), or video + the one program track (multi-audio
    /// drops the silent extras). Pure — verification compares against
    /// this, not against the source's raw total.
    static func expectedOutputStreams(source: AudioBalanceStreamShape) -> Int {
        source.audioStreams <= 1 ? source.totalStreams : source.videoStreams + 1
    }

    /// Output stream-shape verification. nil = acceptable; non-nil = the
    /// contract breach message. The HARD contract: exactly ONE audio
    /// stream (the balanced program track) and the video stream count
    /// unchanged. Non-A/V tracks are tolerated up to the source's own
    /// non-A/V count PLUS ONE: the mov muxer materializes DV timecode
    /// metadata as a `tmcd` data track (probes as codec "unknown") —
    /// desirable provenance, observed on Clip 28.dv → .mov 2026-07-18.
    /// Pure — supersedes the raw total-stream equality check, which the
    /// timecode track would have tripped.
    static func outputStreamMismatch(observed: AudioBalanceStreamShape,
                                     source: AudioBalanceStreamShape) -> String? {
        guard observed.audioStreams == 1 else {
            return "output carries \(observed.audioStreams) audio stream(s), expected exactly 1"
        }
        guard observed.videoStreams == source.videoStreams else {
            return "video stream count changed (\(source.videoStreams) → \(observed.videoStreams))"
        }
        let observedExtras = observed.totalStreams - observed.videoStreams - observed.audioStreams
        let sourceExtras = source.totalStreams - source.videoStreams - source.audioStreams
        guard observedExtras <= sourceExtras + 1 else {
            return "output gained \(observedExtras - sourceExtras) non-A/V track(s), expected at most 1 (timecode)"
        }
        return nil
    }

    /// Full ffmpeg argument vector. `inputArgs` land BEFORE `-i` (they
    /// are demuxer options — the raw-DV `-r` override); `mapArgs`
    /// selects the carried streams (see
    /// `mapArgs(audioStreams:programStreamIndex:)`); `-c copy`
    /// stream-copies them verbatim; the audio override + pan filter
    /// re-encode only the audio. Pure — tested as strings.
    static func ffmpegArgs(input: String,
                           output: String,
                           mapArgs: [String],
                           panFilter: String,
                           audioArgs: [String],
                           inputArgs: [String] = []) -> [String] {
        var args: [String] = ["-hide_banner", "-nostdin", "-y"]
        args += inputArgs
        args += ["-i", input]
        args += mapArgs
        args += [
            "-c", "copy",
            "-af", panFilter
        ]
        args += audioArgs
        args += [
            "-map_metadata", "0",
            "-progress", "pipe:2",
            output
        ]
        return args
    }

    /// `<stem>_balanced.<ext>` beside the source — SAME extension, so
    /// the container is preserved, EXCEPT raw DV sources
    /// (`containerFormat` probes as "dv"), which publish as `.mov`: the
    /// dv muxer can't take the balanced audio back (see the raw-DV
    /// container rule above). Finder-style counters on collision
    /// (`<stem>_balanced 2.<ext>`, …). `fileExists` injected so the
    /// uniquify loop is pure-testable and the publish path can fold
    /// "partial exists" into "taken" (CleanupJob's convention).
    /// `containerFormat` defaults to "" (unknown → same-extension) so
    /// pre-analysis callers keep the historical behavior.
    static func balancedOutputURL(
        forSourcePath path: String,
        containerFormat: String = "",
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL {
        let src = URL(fileURLWithPath: path)
        let dir = src.deletingLastPathComponent()
        let stem = src.deletingPathExtension().lastPathComponent
        let ext: String
        if isRawDVContainer(containerFormat) {
            ext = "mov"
        } else {
            ext = src.pathExtension.isEmpty ? "mov" : src.pathExtension
        }
        var candidate = dir.appendingPathComponent("\(stem)_balanced.\(ext)")
        var n = 2
        while fileExists(candidate.path) {
            candidate = dir.appendingPathComponent("\(stem)_balanced \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    /// Free-space requirement: output ≈ source size (streams copied)
    /// plus worst-case audio growth (lossy → 48 kHz stereo PCM is
    /// ~192 KB/s) plus a 64 MB muxer/headroom cushion. Pure.
    static func requiredFreeBytes(sourceBytes: Int64,
                                  durationSeconds: Double) -> Int64 {
        let audioGrowth = Int64(max(0, durationSeconds) * 200_000)
        return sourceBytes + audioGrowth + (64 << 20)
    }
}

// MARK: - Job

@MainActor
final class BalanceAudioJob: @MainActor MediaFileOperationJob {

    let id = UUID()
    let kind: MediaFileOperationKind = .balanceAudio
    let startedAt = Date()

    /// Source record. READ ONLY on disk.
    let record: VideoRecord

    /// The analyze-first verdict the sheet displayed — classification,
    /// per-channel levels, and the stream shape verification compares
    /// against.
    let analysis: AudioBalanceAnalysis

    /// PLANNED `<stem>_balanced.<ext>` beside the source (shared with
    /// the sheet so it never promises a name the job doesn't plan to
    /// use). Publish re-uniquifies — see `publishedURL`.
    let outputURL: URL

    /// Where the balanced copy actually landed; nil until promotion.
    private(set) var publishedURL: URL?

    /// Test seam: overrides ToolLocator's ffmpeg (failure injection —
    /// point it at /usr/bin/false to exercise the render-failed path).
    private let ffmpegPathOverride: String?

    private weak var model: VideoScanModel?

    /// Pause via SIGSTOP/SIGCONT on the live ffmpeg child (GH #150) —
    /// JobPauseCoordinator parks the stall watchdog while suspended.
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
    @Published private(set) var finishedAt: Date?
    @Published private(set) var subtitleText: String
    @Published private(set) var fractionValue: Double = 0
    @Published private(set) var isIndeterminateValue: Bool = true

    /// The run Task — internal so tests can `await job.task?.value`.
    private(set) var task: Task<Void, Never>?

    /// Set by the stall watchdog; wins over the generic cancel branch.
    private var stallReason: String?

    /// True when the safety gate refused the fix (dualMono/trueStereo/
    /// silent/multi-program are never "fixed") — flips the file-log
    /// OUTCOME line from "balance audio FAILED:" to "balance audio
    /// refused:" (see MediaFileOperationJob.wasRefused).
    private(set) var wasRefused = false

    var title: String { record.filename }
    var subtitle: String { subtitleText }
    var fraction: Double { fractionValue }
    var isIndeterminate: Bool { isIndeterminateValue }

    // MARK: Init / start

    init(record: VideoRecord,
         analysis: AudioBalanceAnalysis,
         model: VideoScanModel,
         plannedOutput: URL? = nil,
         ffmpegPathOverride: String? = nil) {
        self.record = record
        self.analysis = analysis
        self.model = model
        self.ffmpegPathOverride = ffmpegPathOverride
        self.subtitleText = "Preparing to balance audio…"
        self.outputURL = plannedOutput
            ?? BalanceAudioFix.balancedOutputURL(
                forSourcePath: record.fullPath,
                containerFormat: analysis.shape.containerFormat)
    }

    /// Idempotent — a second call is a no-op.
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            await self.runBalance()
        }
    }

    func cancel() {
        guard state.isActive else { return }
        state = .cancelling
        subtitleText = "Cancelling…"
        task?.cancel()
    }

    // MARK: Run

    private func runBalance() async {
        guard state != .cancelling else {
            finishCancelled()
            return
        }
        let inputPath = record.fullPath
        let classification = analysis.classification
        // (videoscan.log START line is written by the Center's
        // startBalanceAudio — one choke point for every MFO verb.)
        balanceLog.info("balance START: \(self.record.filename, privacy: .public) class=\(classification.rawValue, privacy: .public) → \(self.outputURL.lastPathComponent, privacy: .public)")

        // ---- Refusals (the safety-critical branch): dualMono /
        // trueStereo / silent / multichannel are never "fixed", and
        // neither is a file where MORE than one audio stream carries
        // program. This is the SAME gate the sheet consulted before
        // offering the button — sheet and job can never disagree.
        if let reason = BalanceAudioFix.refusalReason(for: analysis) {
            balanceLog.notice("balance REFUSED: \(self.record.filename, privacy: .public) — \(reason, privacy: .public)")
            wasRefused = true
            finish(failed: reason)
            return
        }
        guard let pan = BalanceAudioFix.panFilter(for: classification) else {
            finish(failed: "No balance fix applies to \(classification.rawValue)")
            return
        }
        guard FileManager.default.fileExists(atPath: inputPath) else {
            finish(failed: "Source file missing on disk")
            return
        }
        // Multi-audio (12-bit DV): only the program stream is carried;
        // the unused silent pair(s) are dropped, and we say so.
        if !analysis.droppedStreamIndices.isEmpty {
            let list = analysis.droppedStreamIndices.map(String.init).joined(separator: ", ")
            balanceLog.notice("balance: dropped silent track(s) \(list, privacy: .public) — output carries video + program track \(self.analysis.programStreamIndex, privacy: .public) only")
            appLog.write("balance audio: \(record.filename) — dropping silent audio track(s) \(list) (no sound on them)")
        }
        // Raw DV source → QuickTime output (the container decision — see
        // BalanceAudioFix's raw-DV container rule).
        let isRawDV = BalanceAudioFix.isRawDVContainer(analysis.shape.containerFormat)
        if isRawDV {
            balanceLog.notice("balance: raw DV source — writing QuickTime (.mov) container, DV video stream-copied (input rate override \(BalanceAudioFix.rawDVInputArgs(shape: self.analysis.shape).joined(separator: " "), privacy: .public))")
            appLog.write("balance: raw DV source — writing QuickTime (.mov) container, DV video stream-copied")
        }
        let ffmpeg = ffmpegPathOverride ?? ToolLocator.ffmpegPath
        guard FileManager.default.isExecutableFile(atPath: ffmpeg) else {
            finish(failed: "ffmpeg not found (set VS_FFMPEG_PATH or install via Homebrew)")
            return
        }

        // ---- Free-space pre-check on the destination volume.
        let required = BalanceAudioFix.requiredFreeBytes(
            sourceBytes: record.sizeBytes,
            durationSeconds: analysis.shape.durationSeconds)
        let destDir = outputURL.deletingLastPathComponent()
        if let free = Self.freeBytes(forDirectory: destDir), free < required {
            finish(failed: "Not enough free space next to the original — need about \(Self.humanBytes(required)), only \(Self.humanBytes(free)) available")
            return
        }

        // ---- Publish-time re-uniquify (M3 pattern): the planned name
        // is only a plan. A name whose partial exists is treated as
        // taken (another job mid-publish on it).
        let fm = FileManager.default
        let taken: (String) -> Bool = { path in
            fm.fileExists(atPath: path)
                || fm.fileExists(atPath: ReformatJob.partialURL(for: URL(fileURLWithPath: path)).path)
        }
        var candidate = outputURL
        if taken(candidate.path) {
            candidate = BalanceAudioFix.balancedOutputURL(
                forSourcePath: inputPath,
                containerFormat: analysis.shape.containerFormat,
                fileExists: taken)
        }
        let partialURL = ReformatJob.partialURL(for: candidate)

        // Any exit before promotion must leave no partial behind.
        var promoted = false
        defer {
            if !promoted { try? fm.removeItem(at: partialURL) }
        }

        let durationSeconds = analysis.shape.durationSeconds > 0
            ? analysis.shape.durationSeconds
            : max(0, record.durationSeconds)
        subtitleText = "Balancing audio — video is copied unchanged…"
        isIndeterminateValue = (durationSeconds == 0)

        // ---- Stall watchdog fed by ffmpeg's -progress stream.
        let monitor = StallMonitor(label: "balance \(record.filename)") { [weak self] silentFor in
            Task { @MainActor [weak self] in
                self?.handleStall(silentFor: silentFor)
            }
        }
        let progressSink: @Sendable (Double) -> Void = { [weak self] fraction in
            monitor.tick()
            // Negative fraction = watchdog-only heartbeat (progress line
            // without a parseable time, or unknown duration).
            guard fraction >= 0, let self else { return }
            Task { @MainActor in
                self.applyProgressFraction(fraction)
            }
        }

        let args = BalanceAudioFix.ffmpegArgs(
            input: inputPath,
            output: partialURL.path,
            mapArgs: BalanceAudioFix.mapArgs(
                audioStreams: analysis.shape.audioStreams,
                programStreamIndex: analysis.programStreamIndex),
            panFilter: pan,
            audioArgs: BalanceAudioFix.audioEncodeArgs(
                sourceCodec: analysis.shape.audioCodec,
                bitRateBitsPerSec: analysis.shape.audioBitRate),
            inputArgs: BalanceAudioFix.rawDVInputArgs(shape: analysis.shape))
        balanceLog.info("balance render: ffmpeg \(args.joined(separator: " "), privacy: .public)")

        monitor.start()
        pauser.register(monitor)
        let renderError = await Self.renderOffMain(ffmpeg: ffmpeg,
                                                   arguments: args,
                                                   durationSeconds: durationSeconds,
                                                   control: pauser.control,
                                                   progress: progressSink)
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
        if let renderError {
            monitor.stop()
            finish(failed: renderError)
            return
        }

        // ---- POST-FIX VERIFICATION on the partial, before promotion.
        subtitleText = "Verifying the balanced copy…"
        monitor.tick()
        do {
            try await Self.verifyOffMain(partialPath: partialURL.path,
                                         source: analysis.shape,
                                         sourceDuration: durationSeconds)
        } catch {
            monitor.stop()
            if error is CancellationError || Task.isCancelled || state == .cancelling {
                finishCancelled()
            } else {
                let msg = (error as? BalanceVerificationError)?.message
                    ?? error.localizedDescription
                balanceLog.error("balance VERIFY FAILED: \(self.record.filename, privacy: .public) — \(msg, privacy: .public)")
                finish(failed: "Verification failed — the balanced copy was discarded. \(msg)")
            }
            return
        }
        monitor.stop()
        if Task.isCancelled || state == .cancelling {
            finishCancelled()
            return
        }

        // ---- NON-CLOBBERING promote (rename only; retry the uniquify
        // on a raced-in collision, bounded).
        var attempts = 0
        while true {
            do {
                try fm.moveItem(at: partialURL, to: candidate)
                promoted = true
                break
            } catch {
                attempts += 1
                guard attempts < 100, fm.fileExists(atPath: candidate.path) else {
                    finish(failed: "Could not place the balanced copy next to the original: \(error.localizedDescription)")
                    return
                }
                candidate = BalanceAudioFix.balancedOutputURL(
                    forSourcePath: inputPath,
                    containerFormat: analysis.shape.containerFormat,
                    fileExists: taken)
            }
        }
        publishedURL = candidate
        if candidate != outputURL {
            balanceLog.notice("balance publish: planned name \(self.outputURL.lastPathComponent, privacy: .public) was taken — published as \(candidate.lastPathComponent, privacy: .public)")
        }

        let attrs = try? fm.attributesOfItem(atPath: candidate.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0

        // ---- Catalog + provenance + persistence.
        await catalogBalanceOutput(publishedURL: candidate)

        balanceLog.info("balance DONE: \(self.record.filename, privacy: .public) → \(candidate.lastPathComponent, privacy: .public) (\(Self.humanBytes(size), privacy: .public))")
        // (The Center's "balance audio done:" OUTCOME line carries this
        // same summary — no separate appLog write here.)
        finish(success: "Balanced → \(candidate.lastPathComponent) (\(Self.humanBytes(size))). Original untouched.")
    }

    /// m2 guard (CleanupJob precedent): progress beats arrive via
    /// unstructured Tasks and can land after a terminal state — a
    /// straggler must never drag a finished bar backwards.
    func applyProgressFraction(_ fraction: Double) {
        guard state.isActive else { return }
        fractionValue = fraction
        isIndeterminateValue = false
    }

    // MARK: Off-main hops
    //
    // Same `@concurrent` idiom as CleanupJob.renderOffMain: this repo's
    // Approachable Concurrency runs `nonisolated async` on the CALLER's
    // actor — calling ffmpeg supervision from this @MainActor job
    // without `@concurrent` would run it on main (the documented trap).

    /// Run the ffmpeg remux. Returns nil on success, or a
    /// user-presentable failure message.
    #if compiler(>=6.2)
    @concurrent
    #endif
    private static func renderOffMain(
        ffmpeg: String,
        arguments: [String],
        durationSeconds: Double,
        control: ProcessControl? = nil,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> String? {
        let result = await ProcessRunner.runProcess(
            executable: ffmpeg,
            arguments: arguments,
            stderrLine: { line in
                guard let sec = ReformatJob.parseProgressSeconds(line: line),
                      durationSeconds > 0 else {
                    // Still a sign of life for the watchdog.
                    progress(-1)
                    return
                }
                progress(min(1.0, sec / durationSeconds))
            },
            control: control
        )
        if Task.isCancelled { return nil }   // caller handles cancel
        guard result.exitCode == 0 else {
            let tail = result.stderr.split(separator: "\n").suffix(4).joined(separator: " · ")
            return "ffmpeg exited with status \(result.exitCode)\(tail.isEmpty ? "" : " — \(tail)")"
        }
        return nil
    }

    /// Re-analyze the rendered partial and enforce the post-fix
    /// contract: balanced classification, video codec unchanged, stream
    /// count as planned (everything for single-audio sources; video +
    /// the one program track when silent extras were dropped), duration
    /// within tolerance.
    #if compiler(>=6.2)
    @concurrent
    #endif
    private static func verifyOffMain(
        partialPath: String,
        source: AudioBalanceStreamShape,
        sourceDuration: Double
    ) async throws {
        let check = try await AudioBalanceProbe.analyze(path: partialPath)
        guard check.classification == .dualMono else {
            throw BalanceVerificationError(
                message: "output classified as \(check.classification.rawValue), expected dualMono")
        }
        guard check.shape.videoCodec == source.videoCodec else {
            throw BalanceVerificationError(
                message: "video codec changed (\(source.videoCodec ?? "none") → \(check.shape.videoCodec ?? "none"))")
        }
        // Stream shape: exactly one audio stream, video stream count
        // unchanged, and at most ONE gained non-A/V track (the mov muxer
        // materializes DV timecode metadata as a tmcd data track —
        // desirable provenance). The pure rule replaces the old raw
        // total-stream equality, which the timecode track would trip;
        // it also retires the .dv-output fixed-audio-slot tolerance —
        // raw DV sources publish as QuickTime now, so no muxer path
        // re-materializes a dropped silent pair.
        if let mismatch = BalanceAudioFix.outputStreamMismatch(
            observed: check.shape, source: source) {
            throw BalanceVerificationError(message: mismatch)
        }
        // Exactly ONE stream may carry program — the balanced one. A
        // second live stream in the output means the mapping went wrong.
        guard check.programStreamCount == 1 else {
            throw BalanceVerificationError(
                message: "output carries \(check.programStreamCount) program stream(s), expected exactly 1")
        }
        if sourceDuration > 0, check.shape.durationSeconds > 0 {
            let delta = abs(check.shape.durationSeconds - sourceDuration)
            guard delta <= BalanceAudioFix.durationToleranceSeconds else {
                throw BalanceVerificationError(
                    message: String(format: "duration drifted %.2fs", delta))
            }
        }
    }

    // MARK: Stall handling

    private func handleStall(silentFor: Double) {
        guard state.isActive, stallReason == nil else { return }
        let attribution = StallMonitor.attribution(forPaths: [record.fullPath, outputURL.path])
        let reason = "Stalled — no progress for \(Int(silentFor))s while balancing audio. \(attribution)"
        stallReason = reason
        subtitleText = "Stalled — stopping…"
        balanceLog.error("balance WATCHDOG: killing \(self.record.filename, privacy: .public) — \(reason, privacy: .public)")
        appLog.write("balance watchdog: \(record.filename) stalled \(Int(silentFor))s — \(attribution); killing job")
        task?.cancel()
    }

    // MARK: Catalog + provenance

    /// Probe the balanced file and register it with full provenance:
    /// `derivedFrom` = source id, `derivationKind` = "balanceAudio",
    /// File Journey notes on both records, search-index update, and the
    /// catalog-mutated notification (debounced save) — the same M1/M2
    /// pattern CleanupJob documents.
    private func catalogBalanceOutput(publishedURL: URL) async {
        guard let model else { return }
        let newRec = await model.probeFile(url: publishedURL)

        newRec.derivedFrom = record.id
        newRec.derivationKind = BalanceAudioFix.derivationKind
        // Estimated date (GH #117): a balanced copy is the same footage,
        // so Rick's hand-entered date carries over with its confidence.
        newRec.userDate = record.userDate
        newRec.userDateConfidence = record.userDateConfidence

        var fixNote: String
        switch analysis.classification {
        case .leftOnly: fixNote = "left channel copied to both sides"
        case .rightOnly: fixNote = "right channel copied to both sides"
        case .mono: fixNote = "mono sound spread to both speakers"
        default: fixNote = analysis.classification.rawValue
        }
        if !analysis.droppedStreamIndices.isEmpty {
            let list = analysis.droppedStreamIndices.map(String.init).joined(separator: ", ")
            fixNote += "; unused silent track(s) \(list) left out"
        }
        if BalanceAudioFix.isRawDVContainer(analysis.shape.containerFormat) {
            fixNote += "; packaged as QuickTime (.mov) — raw DV can't carry the balanced audio, DV video bits untouched"
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let sourceNote = "Balance Audio \(stamp): Created balanced copy \(publishedURL.lastPathComponent) (\(fixNote); video copied unchanged)"
        let derivedNote = "Balance Audio \(stamp): Balanced from \(record.filename) (\(fixNote); video copied unchanged)"

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
        model.searchIndex.update(newRec)
        model.searchIndex.update(record)
        NotificationCenter.default.post(name: .videoScanCatalogMutated, object: nil)

        balanceLog.info("balance: catalogued \(publishedURL.lastPathComponent, privacy: .public) (derivedFrom=\(self.record.id.uuidString, privacy: .public), kind=\(BalanceAudioFix.derivationKind, privacy: .public))")
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
        balanceLog.warning("balance failed: \(failed, privacy: .public)")
    }

    private func finishCancelled() {
        state = .cancelled
        subtitleText = "Cancelled"
        isIndeterminateValue = false
    }

    // MARK: Small utilities

    /// Free bytes on the volume containing `dir` (CombineSheet's
    /// resource-values approach).
    nonisolated static func freeBytes(forDirectory dir: URL) -> Int64? {
        if let values = try? dir.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = values.volumeAvailableCapacityForImportantUsage {
            return free
        }
        let fallback = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return fallback?.volumeAvailableCapacity.map { Int64($0) }
    }

    private static func humanBytes(_ bytes: Int64) -> String {
        // Rick 2026-08-18: one app-wide decimal formatter (Finder / df base).
        MediaBytes.display(bytes)
    }
}

/// Typed verification failure so the job can surface the exact contract
/// breach.
private struct BalanceVerificationError: Error {
    let message: String
}
