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
//
// UNKNOWN IS NOT VERIFIED (Rick 2026-11-20, GH #500). "Skipped" above means
// only "not failed": the output may be published beside what is there. It
// never meant "proven", yet Transcode with Replace read the nil verdict as
// leave to send the file already at the output name to the Trash — so an
// output ffprobe could not read (it crashed, could not start, answered
// garbage, or said "Invalid data") replaced a good file and was catalogued
// as "Transcoded". `verification` therefore has THREE answers, and a caller
// that is about to remove something asks for `.verified`, nothing less.
// "Verified" here is what it always was on the success path: ffmpeg exited
// 0 and BOTH container lengths were read and agree within max(3 s, 3 %).
// It is not a decode proof (Preservation's frame-MD5 pass is that).
// (For Rick: `Verification` ≈ a tri-state enum where the old code had a
// nullable error string; nil could not tell "checked, fine" from "could
// not check".)

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

    /// One length reading: the seconds, or the specific reason there are
    /// none (which tool answer, its exit code, its own first words) — kept
    /// so a refusal can be investigated from the log line alone.
    enum Measurement: Sendable, Equatable {
        case seconds(Double)
        case unreadable(String)

        var seconds: Double? {
            if case .seconds(let value) = self { return value }
            return nil
        }
    }

    /// The whole answer for one finished encode.
    enum Verification: Sendable, Equatable {
        /// ffmpeg failed, or the output is shorter than the source.
        case failed(String)
        /// ffmpeg exited 0 and both lengths were read and agree.
        case verified
        /// ffmpeg exited 0 but a length could not be read: nothing was
        /// proven either way. The reason names the file and the cause.
        case unmeasured(String)
    }

    /// The probe's deadline. 60 s: a length read is a header read.
    nonisolated static let probeDeadlineSeconds: Double = 60

    /// The first `lines` non-blank lines of a tool's stderr, bounded to
    /// 240 characters — enough to say why, never a log flood.
    nonisolated static func stderrHead(_ stderr: String, lines: Int = 2) -> String {
        let head = stderr.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(lines)
            .joined(separator: " · ")
        return head.count > 240 ? String(head.prefix(240)) + "…" : head
    }

    /// Why a finished ffprobe length read gave no length, or the length.
    /// Pure — every refusal wording is pinned by a test.
    nonisolated static func measurement(from result: ProcessRunner.Result) -> Measurement {
        let words = stderrHead(result.stderr)
        let said = words.isEmpty ? "" : " — \(words)"
        guard result.launched else {
            return .unreadable("ffprobe could not be started (exit code \(result.exitCode))\(said)")
        }
        guard result.exitCode == 0 else {
            // Nonzero first, then the deadline flag (ProcessRunner's race note).
            if result.timedOut {
                return .unreadable("ffprobe did not answer within \(Int(probeDeadlineSeconds)) s and was stopped (exit code \(result.exitCode))\(said)")
            }
            return .unreadable("ffprobe stopped with exit code \(result.exitCode)\(said)")
        }
        let answer = (result.stdout ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(answer), value.isFinite, value > 0 else {
            let shown = answer.count > 80 ? String(answer.prefix(80)) + "…" : answer
            return .unreadable(answer.isEmpty
                ? "ffprobe exited 0 but reported no length\(said)"
                : "ffprobe exited 0 but its answer was not a length (“\(shown)”)\(said)")
        }
        return .seconds(value)
    }

    /// Container duration via ffprobe, or why it cannot be read. Off the
    /// caller's actor; 60 s deadline. Memory: ffprobe's one-line answer.
    @concurrent
    nonisolated static func measureDuration(_ path: String) async -> Measurement {
        let ffprobe = ToolLocator.ffprobePath
        guard !ffprobe.isEmpty, FileManager.default.fileExists(atPath: ffprobe) else {
            return .unreadable("ffprobe was not found")
        }
        let result = await ProcessRunner.runProcess(
            executable: ffprobe,
            arguments: ["-v", "error", "-show_entries", "format=duration",
                        "-of", "default=noprint_wrappers=1:nokey=1", path],
            deadlineSeconds: probeDeadlineSeconds)
        return measurement(from: result)
    }

    /// Container duration in seconds via ffprobe, or nil when it cannot be
    /// read. Off the caller's actor; 60 s deadline.
    nonisolated static func probeDurationSeconds(_ path: String) async -> Double? {
        await measureDuration(path).seconds
    }

    /// Exit code first, then both lengths. `.verified` only when both were
    /// read and agree; a length that could not be read is `.unmeasured`,
    /// never a pass (GH #500).
    nonisolated static func verification(for result: ProcessRunner.Result, sourcePath: String,
                                         outputPath: String) async -> Verification {
        if let failure = exitFailure(exitCode: result.exitCode, stderr: result.stderr) { return .failed(failure) }
        async let source = measureDuration(sourcePath)
        async let output = measureDuration(outputPath)
        switch (await source, await output) {
        case (_, .unreadable(let why)):
            return .unmeasured("the new file's length could not be read: \(why)")
        case (.unreadable(let why), _):
            return .unmeasured("the source's length could not be read to compare against: \(why)")
        case (.seconds(let sourceSeconds), .seconds(let outputSeconds)):
            if let shortfall = durationShortfall(sourceSeconds: sourceSeconds, outputSeconds: outputSeconds) {
                return .failed(shortfall)
            }
            return .verified
        }
    }

    /// The failure reason for one encode, or nil = may be PUBLISHED BESIDE
    /// what is there. Nil is "not failed", NOT "verified": a caller that
    /// will remove or replace a file must ask `verification` for
    /// `.verified` (GH #500).
    nonisolated static func verdict(for result: ProcessRunner.Result, sourcePath: String, outputPath: String) async -> String? {
        if case .failed(let failure) = await verification(for: result, sourcePath: sourcePath, outputPath: outputPath) {
            return failure
        }
        return nil
    }
}
