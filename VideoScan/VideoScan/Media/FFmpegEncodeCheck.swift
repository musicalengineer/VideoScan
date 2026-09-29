// FFmpegEncodeCheck.swift
// The one post-encode verdict every ffmpeg encode goes through before its
// output is published (Rick 2026-09-19, Archive Angel robustness pass).
//
// THE BUG: TranscodeJob and ReformatJob called `runStreaming`, which
// returns stdout only, and threw it away — ffmpeg's exit status was never
// seen. The only gate was "the partial file exists and is ≥ 10 KB", so a
// disk that filled mid-encode, or a source drive that dropped out, left a
// valid-but-short (or corrupt) file that was published and reported
// "done" — and an Archive Angel access copy made that way could be
// promoted into the archive. (The lossless master is protected by its
// frame-MD5 verify; the lossy access copy had nothing.)
//
// Two checks, in order:
//   1. ffmpeg's exit code — non-zero is a failure, with ffmpeg's own last
//      words as the reason.
//   2. length — ffmpeg can exit 0 on a truncated input. The output must
//      run as long as the source (probed fresh, never the catalog value,
//      which can be wrong for MXF/MTS), within max(3 s, 3 %). Skipped —
//      never failed — when either duration cannot be read (no ffprobe, or
//      a stream with no container duration), because a check that cannot
//      measure must not invent a verdict.

import Foundation
import VideoScanCore

enum FFmpegEncodeCheck {

    /// The failure reason for a finished ffmpeg run, or nil when it exited 0.
    nonisolated static func exitFailure(exitCode: Int32, stderr: String) -> String? {
        guard exitCode != 0 else { return nil }
        let tail = stderrTail(stderr)
        return "ffmpeg stopped with exit code \(exitCode)" + (tail.isEmpty ? "" : " — \(tail)")
    }

    /// ffmpeg's last meaningful stderr line: progress lines ("frame= …",
    /// "size= …") and blank lines are not reasons.
    nonisolated static func stderrTail(_ stderr: String) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("frame=") && !$0.hasPrefix("size=") && !$0.hasPrefix("progress=") }
        guard let last = lines.last else { return "" }
        return last.count > 240 ? String(last.prefix(240)) + "…" : last
    }

    /// Allowed shortfall: max(3 s, 3 % of the source).
    nonisolated static func tolerance(forSourceSeconds source: Double) -> Double {
        max(3, source * 0.03)
    }

    /// The failure reason when the output is shorter than the source, or
    /// nil when it is long enough (or either length is unknown / zero).
    nonisolated static func durationShortfall(sourceSeconds: Double?, outputSeconds: Double?) -> String? {
        guard let source = sourceSeconds, let output = outputSeconds, source > 0 else { return nil }
        guard output + tolerance(forSourceSeconds: source) < source else { return nil }
        return "the output runs \(clock(output)) but the source runs \(clock(source)) — the encode stopped early"
    }

    nonisolated static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Container duration in seconds via ffprobe, or nil when it cannot be
    /// read. Off the caller's actor; 60 s deadline.
    @concurrent
    nonisolated static func probeDurationSeconds(_ path: String) async -> Double? {
        let ffprobe = ToolLocator.ffprobePath
        guard !ffprobe.isEmpty, FileManager.default.fileExists(atPath: ffprobe) else { return nil }
        let result = await ProcessRunner.runProcess(
            executable: ffprobe,
            arguments: ["-v", "error", "-show_entries", "format=duration",
                        "-of", "default=noprint_wrappers=1:nokey=1", path],
            deadlineSeconds: 60)
        guard result.exitCode == 0, let out = result.stdout,
              let value = Double(out.trimmingCharacters(in: .whitespacesAndNewlines)),
              value.isFinite, value > 0 else { return nil }
        return value
    }

    /// The whole verdict for one encode: exit code first, then length.
    /// Nil = publish it.
    nonisolated static func verdict(for result: ProcessRunner.Result, sourcePath: String, outputPath: String) async -> String? {
        if let failure = exitFailure(exitCode: result.exitCode, stderr: result.stderr) { return failure }
        async let source = probeDurationSeconds(sourcePath)
        async let output = probeDurationSeconds(outputPath)
        return durationShortfall(sourceSeconds: await source, outputSeconds: await output)
    }
}
