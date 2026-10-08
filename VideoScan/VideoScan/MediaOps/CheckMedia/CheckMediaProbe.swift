import Foundation
import os

// MARK: - Check Media — the I/O half (Rick 2026-10-07)
//
// Every pass goes through ProcessRunner (the one shell-out module — never
// a bare Process() here) and is READ-ONLY on the media.
//
// Quick tier (seconds, any file size):
//   1. Header probe (ffprobe JSON) → MediaFacts + VideoVerifyFacts (the
//      same JSON, so Check Media and Verify Video read identical numbers).
//      A content complaint on a still-readable file ("moov atom not
//      found") is a verdict; an I/O failure is not — it throws.
//   2. Packet windows: ≤ 300 packets at the start and the middle (the
//      Verify Video windows), ≤ 200 at the end (where the file stops).
//   3. Up to three `mpdecimate` windows of ≤ 300 frames each: how many
//      decoded frames are really a new picture.
//   3b. Layout windows (start / middle / end): ≤ 300 picture packets
//      (≈ 5 s) then the sound packets for the same time span, with their
//      byte positions — where sound and picture sit in the file. Reads
//      ≈ 3 × 5 s of the file (≈ 0.4 GB for DNxHD 220; 0.2 s per window
//      on Rick's RAID).
// Full tier (reads the whole file up to three times):
//   4. VerifyVideoProbe.diagnose with the signal filters riding along.
//   5. VerifyAudioProbe.diagnose (astats per channel).
//   6. The sound-continuity decode (CheckMediaProbe+SoundContinuity).
//
// Memory (worst case, per file): header JSON ≤ 1 MB (stdout cap); packet
// text ≤ 3 × 96 KB; layout text ≤ 3 × (96 + 128) KB; mpdecimate windows keep ≤ 16 KB of -progress text
// each; the full tier's own bounds are documented in VerifyVideoProbe
// (≈ 1.2 MB) and VerifyAudioProbe (KBs); the signal tally is O(1).
// ≈ 1.6 MB in all, independent of the file's size.
//
// Concurrency: the entry points are `@concurrent` (the Approachable
// Concurrency trap — a plain `nonisolated async` would run on the calling
// @MainActor job). ≈ explicitly punting the work to the thread pool.

private let checkMediaLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "checkMedia")

enum CheckMediaProbe {

    /// What the quick tier came back with.
    enum QuickOutcome: Sendable {
        case measured(CheckMediaQuickInputs)
        /// ffprobe can't open it and blames the content; the file is there.
        case unopenable(detail: String, sizeBytes: Int64)
    }

    enum ProbeError: Error, Equatable {
        case toolUnavailable(String)
        /// I/O, not content — no verdict, nothing persisted.
        case couldNotRead(String)
    }

    // MARK: Argument builders (pure — pinned by tests)

    static func headerArgs(input: String) -> [String] {
        ["-hide_banner", "-v", "error", "-show_entries", MediaFacts.probeEntries, "-of", "json", input]
    }

    static func packetArgs(input: String, startSeconds: Double?, maxPackets: Int) -> [String] {
        let start = startSeconds.map { String(format: "%.3f", $0) } ?? ""
        return ["-hide_banner", "-v", "error", "-select_streams", "v:0",
                "-read_intervals", "\(start)%+#\(maxPackets)",
                "-show_entries", "packet=pts_time,dts_time,duration_time,size,pos",
                "-of", "compact=p=0", input]
    }

    /// One stream's packets with byte positions, for the layout windows.
    /// `interval` is ffprobe's -read_intervals syntax.
    static func layoutArgs(input: String, stream: String, interval: String) -> [String] {
        ["-hide_banner", "-v", "error", "-select_streams", stream,
         "-read_intervals", interval,
         "-show_entries", "packet=pts_time,size,pos",
         "-of", "compact=p=0", input]
    }

    /// Picture packets per layout window: ≈ 5 s, 30…300.
    static func layoutVideoPackets(fps: Double) -> Int {
        guard fps.isFinite, fps > 0 else { return 150 }
        return min(300, max(30, Int((5 * fps).rounded())))
    }

    /// `trim` ends the graph after `frames` decoded frames, so ffmpeg stops
    /// reading there; `passthrough` keeps the null muxer from inventing
    /// frames, so the written count IS what mpdecimate kept.
    static func distinctArgs(input: String, offsetSeconds: Double, frames: Int) -> [String] {
        ["-nostdin", "-hide_banner", "-v", "error",
         "-ss", String(format: "%.3f", offsetSeconds), "-i", input,
         "-map", "0:v:0", "-an",
         "-vf", "trim=end_frame=\(frames),mpdecimate",
         "-fps_mode", "passthrough",
         "-f", "null", "-",
         "-progress", "pipe:1", "-nostats"]
    }

    /// Window starts at 10 %, 50 % and 85 % of the picture, each pulled
    /// back so all `frames` fit before the end. One window from the top
    /// for short clips. Pure.
    static func distinctOffsets(durationSeconds d: Double, fps: Double, frames: Int) -> [Double] {
        guard d > 0, fps > 0 else { return [0] }
        let windowSeconds = Double(frames) / fps
        let latest = max(0, d - windowSeconds - 0.5)
        guard latest > 0, d > 30 else { return [0] }
        return [0.10, 0.50, 0.85].map { min(d * $0, latest) }
    }

    /// Frames a window really fed mpdecimate: the full ask, unless the
    /// file runs out first; never fewer than it kept. Pure.
    static func framesIn(offset: Double, durationSeconds d: Double, fps: Double,
                         asked: Int, kept: Int) -> Int {
        guard d > 0, fps > 0 else { return max(asked, kept) }
        let available = Int(((d - offset) * fps).rounded(.down))
        return max(min(asked, available), kept)
    }

    // MARK: Facts only (Get Media Info)

    /// The header probe alone — sub-second; what Get Media Info shows.
    #if compiler(>=6.2)
    @concurrent
    #endif
    static func facts(path: String) async -> Result<MediaFacts, CheckMediaSkip> {
        let ffprobe = ToolLocator.ffprobePath
        guard FileManager.default.isExecutableFile(atPath: ffprobe) else {
            return .failure(CheckMediaSkip(reason: "ffprobe not found"))
        }
        let r = await ProcessRunner.runProcess(executable: ffprobe, arguments: headerArgs(input: path),
                                               stdoutLimitBytes: 1 << 20, deadlineSeconds: 30)
        guard r.exitCode == 0, let data = r.stdout?.data(using: .utf8),
              let facts = try? MediaFacts.parse(probeJSON: data) else {
            return .failure(CheckMediaSkip(reason: r.timedOut
                ? "the drive did not answer in time"
                : VerifyVideoRules.unopenableDetail(fromProbeStderr: r.stderr)))
        }
        return .success(facts)
    }

    // MARK: Quick tier

    #if compiler(>=6.2)
    @concurrent
    #endif
    static func quick(path: String, control: ProcessControl? = nil) async throws -> QuickOutcome {
        let ffprobe = ToolLocator.ffprobePath, ffmpeg = ToolLocator.ffmpegPath
        guard FileManager.default.isExecutableFile(atPath: ffprobe),
              FileManager.default.isExecutableFile(atPath: ffmpeg) else {
            throw ProbeError.toolUnavailable(
                "ffmpeg/ffprobe not found (set VS_FFMPEG_PATH / VS_FFPROBE_PATH or install via Homebrew)")
        }
        let header = await ProcessRunner.runProcess(
            executable: ffprobe, arguments: headerArgs(input: path),
            stdoutLimitBytes: 1 << 20, deadlineSeconds: 60, control: control)
        try Task.checkCancellation()
        guard header.exitCode == 0, let text = header.stdout, let data = text.data(using: .utf8) else {
            return try await headerFailure(header, path: path)
        }
        let facts: MediaFacts, videoFacts: VideoVerifyFacts
        do {
            facts = try MediaFacts.parse(probeJSON: data)
            videoFacts = try VerifyVideoRules.facts(fromProbeJSON: data)
        } catch {
            throw ProbeError.couldNotRead("ffprobe's answer was not readable")
        }
        var inputs = CheckMediaQuickInputs(facts: facts, videoFacts: videoFacts)
        if videoFacts.hasVideo {
            inputs.packets = await packetScan(path: path, ffprobe: ffprobe, facts: videoFacts, control: control)
            try Task.checkCancellation()
            let fps = CheckMediaRules.storedFPS(inputs) ?? VerifyVideoRules.referenceFPS(videoFacts)
            inputs.distinct = await distinctSample(path: path, ffmpeg: ffmpeg, facts: videoFacts,
                                                   fps: fps, control: control)
            try Task.checkCancellation()
            if facts.audio != nil {
                inputs.layout = await layoutSample(path: path, ffprobe: ffprobe, facts: videoFacts,
                                                   fps: fps, control: control)
                try Task.checkCancellation()
            }
        }
        return .measured(inputs)
    }

    /// Content complaint on a readable file → a verdict; anything else
    /// (drive gone, timed out) → no verdict.
    private static func headerFailure(_ header: ProcessRunner.Result, path: String) async throws -> QuickOutcome {
        if !header.timedOut, VerifyVideoRules.stderrBlamesContent(header.stderr),
           await VerifyVideoProbe.sourceStillReadable(path: path) {
            return .unopenable(detail: VerifyVideoRules.unopenableDetail(fromProbeStderr: header.stderr),
                               sizeBytes: VerifyVideoProbe.fileSize(path))
        }
        throw ProbeError.couldNotRead(header.timedOut
            ? "the drive did not answer in time — try again when it is less busy"
            : "ffprobe could not read the file (exit \(header.exitCode)) and the drive may be unavailable")
    }

    /// Start + middle (the Verify Video windows) and the tail. A window
    /// that fails is just fewer facts, never a finding.
    private static func packetScan(path: String, ffprobe: String, facts: VideoVerifyFacts,
                                   control: ProcessControl?) async -> MediaPacketScan {
        let d = facts.videoDurationSeconds
        var starts: [Double?] = [nil]
        if d > 20 { starts.append(d / 2) }
        var windows: [[MediaPacketRow]] = []
        for start in starts {
            windows.append(await packetRows(path: path, ffprobe: ffprobe, start: start,
                                            maxPackets: 300, control: control))
        }
        let tail = d > 2
            ? await packetRows(path: path, ffprobe: ffprobe, start: d - 2, maxPackets: 200, control: control)
            : []
        return MediaPacketScan.summarize(windows: windows.filter { !$0.isEmpty }, tail: tail)
    }

    private static func packetRows(path: String, ffprobe: String, start: Double?, maxPackets: Int,
                                   control: ProcessControl?) async -> [MediaPacketRow] {
        let r = await ProcessRunner.runProcess(
            executable: ffprobe,
            arguments: packetArgs(input: path, startSeconds: start, maxPackets: maxPackets),
            stdoutLimitBytes: 96 * 1024, deadlineSeconds: 60, control: control)
        guard r.exitCode == 0, let text = r.stdout else { return [] }
        return MediaPacketRow.rows(fromCompact: text)
    }

    /// Start, middle and end windows: the picture packets first (a packet
    /// count, so a 60,000 fps file can't make it read gigabytes), then the
    /// sound for the same time span. A window that fails is just missing.
    private static func layoutSample(path: String, ffprobe: String, facts: VideoVerifyFacts,
                                     fps: Double, control: ProcessControl?) async -> MediaLayoutSample {
        let d = facts.videoDurationSeconds
        var starts: [Double?] = [nil]
        if d > 20 { starts += [d / 2, d - 8] }
        var windows: [MediaLayoutMeasure] = []
        for start in starts {
            let from = start.map { String(format: "%.3f", $0) } ?? ""
            let video = await layoutRows(path: path, ffprobe: ffprobe, stream: "v:0",
                                         interval: "\(from)%+#\(layoutVideoPackets(fps: fps))",
                                         limit: 96 * 1024, control: control)
            let times = video.compactMap(\.pts)
            guard let lo = times.min(), let hi = times.max(), hi > lo else { continue }
            let audio = await layoutRows(path: path, ffprobe: ffprobe, stream: "a:0",
                                         interval: String(format: "%.3f%%+%.3f", lo, hi - lo),
                                         limit: 128 * 1024, control: control)
            if let m = MediaLayoutMeasure.measure(video: video, audio: audio) { windows.append(m) }
        }
        return MediaLayoutSample(windows: windows)
    }

    private static func layoutRows(path: String, ffprobe: String, stream: String, interval: String,
                                   limit: Int, control: ProcessControl?) async -> [MediaPacketRow] {
        let r = await ProcessRunner.runProcess(
            executable: ffprobe, arguments: layoutArgs(input: path, stream: stream, interval: interval),
            stdoutLimitBytes: limit, deadlineSeconds: 60, control: control)
        guard r.exitCode == 0, let text = r.stdout else { return [] }
        return MediaPacketRow.rows(fromCompact: text)
    }

    private static func distinctSample(path: String, ffmpeg: String, facts: VideoVerifyFacts,
                                       fps: Double, control: ProcessControl?) async -> DistinctFrameSample {
        let asked = DistinctFrameSample.framesPerWindow
        var windows: [DistinctFrameSample.Window] = []
        for offset in distinctOffsets(durationSeconds: facts.videoDurationSeconds, fps: fps, frames: asked) {
            let r = await ProcessRunner.runProcess(
                executable: ffmpeg,
                arguments: distinctArgs(input: path, offsetSeconds: offset, frames: asked),
                stdoutLimitBytes: 16 * 1024, deadlineSeconds: 120, control: control)
            guard r.exitCode == 0, let text = r.stdout,
                  let kept = DistinctFrameSample.framesWritten(fromProgress: text) else { continue }
            windows.append(.init(offsetSeconds: offset,
                                 framesIn: framesIn(offset: offset, durationSeconds: facts.videoDurationSeconds,
                                                    fps: fps, asked: asked, kept: kept),
                                 framesKept: kept))
        }
        return DistinctFrameSample(windows: windows)
    }

    // MARK: Full tier

    /// Which full-tier pass is running — the MFO row names it.
    enum FullPhase: Sendable {
        case picture
        case sound

        var step: String {
            switch self {
            case .picture: return "decoding every frame"
            case .sound: return "listening to every sample"
            }
        }
    }

    /// Progress of the full tier: the phase and its own 0…1 fraction.
    typealias FullProgress = @Sendable (FullPhase, Double) -> Void

    /// Runs both existing engines. Each failure becomes that row's "not
    /// run" reason; only cancellation is thrown.
    #if compiler(>=6.2)
    @concurrent
    #endif
    static func full(path: String, facts: MediaFacts, control: ProcessControl? = nil,
                     progress: FullProgress? = nil) async throws -> CheckMediaFullInputs {
        var out = CheckMediaFullInputs()
        if facts.video != nil {
            let tally = MediaSignalTally()
            do {
                let d = try await VerifyVideoProbe.diagnose(path: path, control: control,
                                                            progress: { progress?(.picture, $0) },
                                                            signalLine: { tally.note($0) })
                out.video = .success(d)
                if case .skipped = d.decode?.coverage {} else { out.signals = tally.snapshot }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                out.video = .failure(CheckMediaSkip(reason: reason(for: error)))
            }
        }
        if facts.audio != nil {
            do {
                out.audio = .success(try await VerifyAudioProbe.diagnose(path: path, control: control))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                out.audio = .failure(CheckMediaSkip(reason: reason(for: error)))
            }
            progress?(.sound, 0)
            out.continuity = try await soundContinuity(path: path, facts: facts, control: control,
                                                       progress: { progress?(.sound, $0) })
        }
        checkMediaLog.info("checkMedia full: \((path as NSString).lastPathComponent, privacy: .public) video=\(String(describing: out.video.map { (try? $0.get())?.verdict.rawValue ?? "skipped" }), privacy: .public)")
        return out
    }

    static func reason(for error: Error) -> String {
        switch error {
        case VideoVerifyProbeError.toolUnavailable(let s), AudioVerifyProbeError.toolUnavailable(let s):
            return s
        case VideoVerifyProbeError.probeFailed(let s), AudioVerifyProbeError.probeFailed(let s):
            return s
        case VideoVerifyProbeError.noVideoStream:
            return "the file has no picture"
        default:
            return error.localizedDescription
        }
    }
}
