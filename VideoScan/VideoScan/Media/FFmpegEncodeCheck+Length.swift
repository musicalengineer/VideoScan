// FFmpegEncodeCheck+Length.swift
// How long is this file? — asked two ways, in order, through the one
// (mockable) command runner (2026-11-21, refining GH #502):
//   1. the container's duration (`format=duration`) — the answer for almost
//      every file, and the only probe that runs for them;
//   2. the longest stream duration (`stream=duration`) — a container that
//      declares none but whose streams do.
// Nothing else. A third measure, the video packet count ÷ a frame rate, was
// removed (Codex r1 #6): a 25 fps + 50 fps MPEG-2 concatenation reads both
// rates as 25/1 and 150 packets — 6 s for a 4 s file — so even agreeing
// header fields are a guess. Refuse rather than guess: an elementary stream
// has "no readable duration".
//
// WHY. GH #502 made "a length could not be read" a failed job. For the new
// file that is right. For the SOURCE it refused to make any derivative of a
// real class of files (elementary streams, odd or damaged containers).
//
// THREE answers, and the difference between the last two is the point:
//   .measured    a positive finite length, and which measure gave it;
//   .noDuration  ffprobe RAN and the file has no readable duration — a fact
//                about the file. Callers may publish beside it with a note,
//                and must refuse to REPLACE on it;
//   .unreadable  the tool crashed, hung, could not start, or answered
//                something that is not an answer — nothing is known, and
//                every caller fails on it.
//
// Memory: two short ffprobe answers. Time: two header reads (60 s
// deadline each).
// (For Rick: `Length` ≈ std::variant<Measured, NoDuration, Unreadable>.)

import Foundation
import VideoScanCore

extension FFmpegEncodeCheck {

    enum LengthMeasure: String, Sendable, Equatable {
        case container = "container duration"
        case streams = "longest stream duration"
    }

    enum Length: Sendable, Equatable {
        case measured(Double, by: LengthMeasure)
        /// ffprobe ran and reported no duration for the container or any
        /// stream. The reason says so.
        case noDuration(String)
        /// The tool failed: nothing is known about the file.
        case unreadable(String)

        var seconds: Double? {
            if case .measured(let value, _) = self { return value }
            return nil
        }
    }

    /// True when ffprobe ran, exited 0, and said there is no duration: at
    /// least one line, and every line "N/A" — ffprobe's well-formed
    /// absence. Nothing at all is NOT absence (Codex r1 #5: an empty answer
    /// was called "no duration"); nor is a crash, a nonzero exit, a deadline
    /// or any other words. Pure.
    nonisolated static func saysNoDuration(_ result: ProcessRunner.Result) -> Bool {
        guard result.launched, result.exitCode == 0 else { return false }
        let answer = lines(result.stdout)
        return !answer.isEmpty && answer.allSatisfy(isAbsent)
    }

    nonisolated private static func isAbsent(_ line: String) -> Bool {
        line.caseInsensitiveCompare("N/A") == .orderedSame
    }

    nonisolated private static func lines(_ text: String?) -> [String] {
        (text ?? "").split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// What a `stream=duration` answer says: one line per stream, each
    /// "N/A" (that stream has none) or a positive finite number of seconds.
    enum StreamDurations: Sendable, Equatable {
        case longest(Double)
        /// Every line was "N/A" (and there was at least one).
        case absent
        /// Not that shape: nothing, or a line that is neither — the answer
        /// as shown in the failure (clipped).
        case malformed(String)
    }

    /// A positive finite number of seconds written as ffprobe writes one —
    /// decimal digits and at most one point ("12.000000") — or nil.
    /// (`Double()` alone also takes "0x1p3", "1e3", "inf".) Pure.
    nonisolated static func decimalSeconds(_ text: String) -> Double? {
        guard !text.isEmpty, text.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || $0 == 46 }),
              text.utf8.filter({ $0 == 46 }).count <= 1,
              let value = Double(text), value.isFinite, value > 0 else { return nil }
        return value
    }

    /// Reads a `stream=duration` answer strictly. THE BUG (Codex r1 #5,
    /// P0): `12\nbroken` was read as 12 — the line that was not a number
    /// was dropped. A reply is well-formed absence, or well-formed numbers,
    /// or it is not an answer. Pure.
    nonisolated static func streamDurations(_ stdout: String?) -> StreamDurations {
        let answer = lines(stdout)
        var longest: Double?
        for line in answer where !isAbsent(line) {
            guard let value = decimalSeconds(line) else {
                let shown = answer.prefix(3).joined(separator: " · ")
                return .malformed(shown.count > 80 ? String(shown.prefix(80)) + "…" : shown)
            }
            longest = max(longest ?? 0, value)
        }
        if let longest { return .longest(longest) }
        return answer.isEmpty ? .malformed("") : .absent
    }

    /// Why a finished ffprobe run is not an answer (it did not launch,
    /// stopped nonzero, or hit its deadline) — nil when it exited 0.
    nonisolated private static func toolFailure(_ result: ProcessRunner.Result, deadline: Double) -> String? {
        guard !result.launched || result.exitCode != 0 else { return nil }
        let words = stderrHead(result.stderr)
        let said = words.isEmpty ? "" : " — \(words)"
        if !result.launched { return "ffprobe could not be started (exit code \(result.exitCode))\(said)" }
        if result.timedOut { return "ffprobe did not answer within \(Int(deadline)) s and was stopped (exit code \(result.exitCode))\(said)" }
        return "ffprobe stopped with exit code \(result.exitCode)\(said)"
    }

    nonisolated private static func probe(_ path: String, _ arguments: [String], deadline: Double) async -> ProcessRunner.Result {
        await ProcessRunner.runProcess(executable: ToolLocator.ffprobePath, arguments: ["-v", "error"] + arguments + [path],
                                       deadlineSeconds: deadline)
    }

    /// The file's length by the first measure that gives one. Off the
    /// caller's actor. A measure other than the container's is said in the
    /// app log, with the file and the measure used.
    @concurrent
    nonisolated static func measureLength(_ path: String) async -> Length {
        let ffprobe = ToolLocator.ffprobePath
        guard !ffprobe.isEmpty, FileManager.default.fileExists(atPath: ffprobe) else { return .unreadable("ffprobe was not found") }

        // 1. The container.
        let container = await probe(path, ["-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1"],
                                    deadline: probeDeadlineSeconds)
        switch measurement(from: container) {
        case .seconds(let value):
            return .measured(value, by: .container)
        case .unreadable(let why):
            guard saysNoDuration(container) else { return .unreadable(why) }
        }

        // 2. The streams.
        let streams = await probe(path, ["-show_entries", "stream=duration", "-of", "default=noprint_wrappers=1:nokey=1"],
                                  deadline: probeDeadlineSeconds)
        if let failure = toolFailure(streams, deadline: probeDeadlineSeconds) { return .unreadable(failure) }
        switch streamDurations(streams.stdout) {
        case .longest(let value):
            return said(path, value, by: .streams)
        case .absent:
            return .noDuration(noDurationReason)
        case .malformed(let shown):
            return .unreadable(shown.isEmpty ? "ffprobe exited 0 but reported no stream durations"
                                             : "ffprobe exited 0 but its stream durations were not lengths (“\(shown)”)")
        }
    }

    /// Why a file has no readable duration (both measures asked).
    nonisolated static let noDurationReason = "no container duration and no stream duration"

    /// Log a length that did not come from the container, and return it.
    nonisolated private static func said(_ path: String, _ seconds: Double, by measure: LengthMeasure) -> Length {
        appLog.write("length: \((path as NSString).lastPathComponent) has no container duration — measured \(clock(seconds)) "
            + "(\(String(format: "%.3f", seconds)) s) by its \(measure.rawValue)")
        return .measured(seconds, by: measure)
    }
}
