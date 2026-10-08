import Foundation

// MARK: - Check Media — the sound-continuity pass (I/O half)
//
// One ffmpeg run, through ProcessRunner (never a bare Process()):
//   ffmpeg -i <file> -map 0:a:0 -af asettb=1/sr,ashowinfo
//          -c:a pcm_s32le -f s32le pipe:1
// stdout = every decoded sample as raw s32le (exact for 16/24-bit sources;
// deterministic for float codecs), streamed chunk by chunk into
// SoundContinuityAnalyzer — never collected (`stdoutLimitBytes: 0`).
// stderr = one `ashowinfo` line per decoded frame (pts in samples), the
// timing check and the progress bar.
//
// Read-only on the media. Reads only the sound for mov/mp4 (the demuxer
// skips discarded picture samples by index); for mxf/mkv/avi it reads the
// whole file once.
//
// Memory: the analyzer's bound (≈ 0.4 MB, see SoundContinuity.swift) + one
// pipe chunk (≈ 64 KB) + ≤ 16 KB of collected stderr. The pipe gives
// back-pressure: ffmpeg blocks while a chunk is being analysed.

extension CheckMediaProbe {

    static func continuityArgs(input: String) -> [String] {
        ["-nostdin", "-hide_banner", "-v", "info", "-nostats",
         "-i", input,
         "-map", "0:a:0", "-vn", "-sn", "-dn",
         "-af", "asettb=1/sr,ashowinfo",
         "-c:a", "pcm_s32le", "-f", "s32le", "pipe:1"]
    }

    /// Decodes every sound sample once. A failure is that row's "not run"
    /// reason; only cancellation throws.
    #if compiler(>=6.2)
    @concurrent
    #endif
    static func soundContinuity(path: String, facts: MediaFacts, control: ProcessControl? = nil,
                                progress: (@Sendable (Double) -> Void)? = nil) async throws
        -> Result<SoundContinuityReport, CheckMediaSkip> {
        let ffmpeg = ToolLocator.ffmpegPath
        guard FileManager.default.isExecutableFile(atPath: ffmpeg) else {
            return .failure(CheckMediaSkip(reason: "ffmpeg not found"))
        }
        guard let audio = facts.audio, let channels = audio.channels, let rate = audio.sampleRate,
              channels > 0, rate > 0 else {
            return .failure(CheckMediaSkip(reason: "the sound's channel count or sample rate is unknown"))
        }
        guard channels <= SoundContinuityAnalyzer.maxChannels else {
            return .failure(CheckMediaSkip(reason: "more than \(SoundContinuityAnalyzer.maxChannels) sound channels"))
        }
        let tally = SoundContinuityTally(channels: channels, sampleRate: rate)
        let meter = ProgressMeter(totalSeconds: audio.durationSeconds ?? facts.durationSeconds ?? 0, report: progress)
        let r = await ProcessRunner.runProcess(
            executable: ffmpeg, arguments: continuityArgs(input: path),
            stderrLine: { line in
                if let t = tally.consume(showInfoLine: line) { meter.note(t) }
            },
            stdoutData: { tally.consume($0) },
            stdoutLimitBytes: 0, stderrLimitBytes: 16 * 1024, control: control)
        try Task.checkCancellation()
        guard r.exitCode == 0 else {
            return .failure(CheckMediaSkip(reason: "ffmpeg could not decode the sound (exit \(r.exitCode))"))
        }
        return .success(tally.finish())
    }

    /// Throttled progress: reports only when the fraction moves ≥ 0.5 %.
    /// (Lines arrive on one reader thread; the lock is belt and braces.)
    final class ProgressMeter: @unchecked Sendable {
        private let lock = NSLock()
        private let totalSeconds: Double
        private let report: (@Sendable (Double) -> Void)?
        private var last = -1.0

        init(totalSeconds: Double, report: (@Sendable (Double) -> Void)?) {
            self.totalSeconds = totalSeconds
            self.report = report
        }

        func note(_ seconds: Double) {
            guard let report, totalSeconds > 0 else { return }
            let f = min(1, max(0, seconds / totalSeconds))
            lock.lock()
            let due = f - last >= 0.005
            if due { last = f }
            lock.unlock()
            if due { report(f) }
        }
    }
}
