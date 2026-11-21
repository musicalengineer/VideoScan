// FFmpegEncodeCheck+Length.swift
// How long is this file? — asked three ways, in order, through the one
// (mockable) command runner (2026-11-21, refining GH #502):
//   1. the container's duration (`format=duration`) — the answer for almost
//      every file, and the only probe that runs for them;
//   2. the longest stream duration (`stream=duration`) — a container that
//      declares none but whose streams do;
//   3. the video stream's packet count ÷ its frame rate (`-count_packets`)
//      — an elementary stream. Used ONLY when ffprobe reports BOTH frame
//      rates (r_frame_rate, avg_frame_rate) and they agree within 1 %: for
//      a raw H.264 stream they are 50/1 and 25/1, and picking one would be
//      a guess that is wrong by a factor of two. Refuse rather than guess.
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
// Audio-only files stop after step 2: a packet count is not a length for
// audio (packets carry varying numbers of samples).
//
// Memory: three short ffprobe answers. Time: steps 1 and 2 are header
// reads (60 s deadline each); step 3 demuxes the whole file once, without
// decoding, under a 15-minute deadline — it runs only for a file with no
// declared duration at all.
// (For Rick: `Length` ≈ std::variant<Measured, NoDuration, Unreadable>.)

import Foundation
import VideoScanCore

extension FFmpegEncodeCheck {

    enum LengthMeasure: String, Sendable, Equatable {
        case container = "container duration"
        case streams = "longest stream duration"
        case packets = "video packet count ÷ frame rate"
    }

    enum Length: Sendable, Equatable {
        case measured(Double, by: LengthMeasure)
        /// ffprobe ran and reported no duration by any measure. The reason
        /// says which measures were tried and what each lacked.
        case noDuration(String)
        /// The tool failed: nothing is known about the file.
        case unreadable(String)

        var seconds: Double? {
            if case .measured(let value, _) = self { return value }
            return nil
        }
    }

    /// The packet scan's deadline. It reads the whole file once (no
    /// decode): 15 minutes covers ~90 GB at 100 MB/s.
    nonisolated static let packetScanDeadlineSeconds: Double = 900

    /// True when ffprobe ran, exited 0, and said there is nothing to
    /// report: no lines, or only "N/A". (A crash, a nonzero exit, a
    /// deadline or any other words are NOT this.) Pure.
    nonisolated static func saysNoDuration(_ result: ProcessRunner.Result) -> Bool {
        guard result.launched, result.exitCode == 0 else { return false }
        return lines(result.stdout).allSatisfy { $0.caseInsensitiveCompare("N/A") == .orderedSame }
    }

    nonisolated private static func lines(_ text: String?) -> [String] {
        (text ?? "").split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The longest positive finite duration among `stream=duration` lines
    /// (one per stream; "N/A" for a stream that has none). Pure.
    nonisolated static func longestStreamSeconds(_ stdout: String?) -> Double? {
        lines(stdout).compactMap { Double($0) }.filter { $0.isFinite && $0 > 0 }.max()
    }

    /// "30000/1001" → 29.97; nil for "0/0", "N/A" or anything else. Pure.
    nonisolated static func rate(_ text: String?) -> Double? {
        guard let parts = text?.split(separator: "/"), parts.count == 2,
              let n = Double(parts[0]), let d = Double(parts[1]), n > 0, d > 0 else { return nil }
        return n / d
    }

    /// Seconds from a `-count_packets` answer (`key=value` lines:
    /// nb_read_packets, r_frame_rate, avg_frame_rate), or why it is not a
    /// length. Pure — every refusal is pinned by a test.
    nonisolated static func packetSeconds(_ stdout: String?) -> (seconds: Double?, why: String) {
        var fields: [String: String] = [:]
        for line in lines(stdout) {
            let pair = line.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { fields[pair[0]] = pair[1] }
        }
        guard !fields.isEmpty else { return (nil, "no video stream to count packets in") }
        guard let packets = Double(fields["nb_read_packets"] ?? ""), packets > 0 else { return (nil, "no packets were counted") }
        let r = rate(fields["r_frame_rate"]), avg = rate(fields["avg_frame_rate"])
        let shown = "r_frame_rate \(fields["r_frame_rate"] ?? "none"), avg_frame_rate \(fields["avg_frame_rate"] ?? "none")"
        switch (r, avg) {
        case (nil, nil):
            return (nil, "no frame rate to divide the packet count by (\(shown))")
        case (.some, nil), (nil, .some):
            // One rate alone cannot be cross-checked (r_frame_rate is the
            // FIELD rate for some streams): a length that may be off by a
            // factor of two is not a length to rest a Replace on.
            return (nil, "only one of its two frame rates is known (\(shown)), so a packet count is not a length")
        case (let a?, let b?):
            guard abs(a - b) / max(a, b) <= 0.01 else {
                return (nil, "its frame rate is ambiguous (\(shown)), so a packet count is not a length")
            }
            return (packets / b, "")
        }
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
        if let value = longestStreamSeconds(streams.stdout) { return said(path, value, by: .streams) }
        guard saysNoDuration(streams) else {
            return .unreadable("ffprobe exited 0 but its stream durations were not lengths (“\(lines(streams.stdout).prefix(3).joined(separator: " · ").prefix(80))”)")
        }

        // 3. The video packets. Reads the whole file once, without decoding.
        let count = await probe(path, ["-select_streams", "v:0", "-count_packets",
                                       "-show_entries", "stream=nb_read_packets,r_frame_rate,avg_frame_rate",
                                       "-of", "default=noprint_wrappers=1"],
                                deadline: packetScanDeadlineSeconds)
        let prefix = "no container duration, no stream duration, and "
        if let failure = toolFailure(count, deadline: packetScanDeadlineSeconds) {
            // A scan that ran out of time is "not measured", not "broken":
            // the two header reads above already answered.
            return count.launched && count.timedOut ? .noDuration(prefix + "the packet count did not finish: \(failure)") : .unreadable(failure)
        }
        let packets = packetSeconds(count.stdout)
        guard let value = packets.seconds, value.isFinite, value > 0 else { return .noDuration(prefix + packets.why) }
        return said(path, value, by: .packets)
    }

    /// Log a length that did not come from the container, and return it.
    nonisolated private static func said(_ path: String, _ seconds: Double, by measure: LengthMeasure) -> Length {
        appLog.write("length: \((path as NSString).lastPathComponent) has no container duration — measured \(clock(seconds)) "
            + "(\(String(format: "%.3f", seconds)) s) by its \(measure.rawValue)")
        return .measured(seconds, by: measure)
    }
}
