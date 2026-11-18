// BalancedCopyProofReadLog.swift
// The decode pass's LOG, read back (pure parse; no file, no subprocess):
// ffmpeg's own account of what it read of each stream, what it muxed, and
// every channel's peak — and the refusal of any log that does not vouch for
// a whole, quiet read. Moved out of BalancedCopyProofMeasure.swift unchanged
// (2026-11-18, file length); the rules it serves are in that file's header.

import Foundation
import VideoScanCore

extension BalancedCopyProof {

    // MARK: - The decode pass's log (pure parse)

    /// One ffmpeg log line under `-v level+…`:
    /// "[in#0/mov @ 0x…] [verbose] payload" → components, level, payload.
    struct LogRecord: Equatable {
        var components: [Substring]
        var level: Substring
        var payload: Substring
    }

    /// Levels `-v error` would have kept quiet.
    static let quietLogLevels: Set<Substring> = ["warning", "info", "verbose", "debug", "trace"]
    /// Levels `-v error` prints. One line at any of them refuses the pass.
    static let loudLogLevels: Set<Substring> = ["error", "fatal", "panic"]
    /// What ffmpeg logs, at info, when a stream's frames change size or format.
    static let reconfiguredPayload = "Reconfiguring filter graph"
    /// What ffmpeg logs last, at verbose, when it finished in order.
    static let cleanExitPayload = "Exiting with exit code 0"

    /// Split a log line into its "[component @ 0x…]" prefixes, its level and
    /// its payload. nil = the line does not START that way.
    static func logRecord(_ line: Substring) -> LogRecord? {
        var rest = line
        var components: [Substring] = []
        while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            let inner = rest[rest.index(after: rest.startIndex)..<close]
            let after = rest[rest.index(after: close)...]
            let tail = after.hasPrefix(" ") ? after.dropFirst() : after
            if quietLogLevels.contains(inner) || loudLogLevels.contains(inner) {
                return LogRecord(components: components, level: inner, payload: tail)
            }
            guard inner.contains(" @ 0x") else { return nil }
            components.append(inner)
            rest = tail
        }
        return nil
    }

    /// A line with no level of its own that ffmpeg legitimately prints: the
    /// continuation of a multi-line METADATA value, which its dump indents.
    /// Tolerated only straight after an info-level line, and never parsed.
    static func isMetadataContinuation(_ line: Substring) -> Bool {
        let blanks = line.prefix(while: { $0 == " " }).count
        return blanks >= 16 && line.dropFirst(blanks).hasPrefix(": ")
    }

    /// The digits straight before `marker` in `text` ("94 packets read").
    static func count(before marker: String, in text: Substring) -> Int64? {
        guard let found = text.range(of: marker) else { return nil }
        let digits = text[..<found.lowerBound].reversed().prefix(while: { $0.isASCII && $0.isNumber })
        return digits.isEmpty ? nil : Int64(String(digits.reversed()))
    }

    /// "Input stream #0:1 (audio): 94 packets read (…); 94 frames decoded; 0
    /// decode errors (…);" → (1, "packets read" count, decode errors), or
    /// "Output stream #0:0 (video): 50 frames encoded; 50 packets muxed (…);"
    /// → (0, "packets muxed" count, nil). nil = not such a line.
    static func streamCount(fromPayload payload: Substring, side: String, counting marker: String)
        -> (index: Int, count: Int, decodeErrors: Int?)? {
        let text = payload.drop(while: { $0 == " " })
        let opening = "\(side) stream #0:"
        guard text.hasPrefix(opening) else { return nil }
        let rest = text.dropFirst(opening.count)
        guard let index = Int(rest.prefix(while: { $0.isASCII && $0.isNumber })),
              let found = count(before: marker, in: rest) else { return nil }
        return (index, Int(found), count(before: " decode errors", in: rest).map { Int($0) })
    }

    /// What to quote from the log of a pass that FAILED: ffmpeg's first line
    /// at error level — under verbose logging its last lines are only its
    /// exit chatter — else its last two lines.
    static func failureLines(fromStderr text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline)
        for line in lines {
            if let record = logRecord(line), loudLogLevels.contains(record.level) { return String(record.payload) }
        }
        return lines.suffix(2).joined(separator: " · ")
    }

    /// Why a decode pass's log does not vouch for the read; `line` is quoted.
    struct ReadFault: Error, Equatable {
        var line: String
    }

    /// Read one decode pass's whole log into the log's half of a
    /// `ReadReport`. Success = every line was one `-v error` would have kept
    /// quiet, the log ends with ffmpeg's own clean exit line, and no stream
    /// is accounted for twice. `runTag` names this run's astats instances.
    static func readReport(fromStderr text: String, runTag: String) -> Result<ReadReport, ReadFault> {
        var report = ReadReport()
        var announced: [Int: Int] = [:]
        var last: LogRecord?
        for line in text.split(whereSeparator: \.isNewline) where !line.allSatisfy(\.isWhitespace) {
            guard let record = logRecord(line) else {
                if last?.level == "info", isMetadataContinuation(line) { continue }
                return .failure(ReadFault(line: String(line)))
            }
            guard quietLogLevels.contains(record.level) else { return .failure(ReadFault(line: String(line))) }
            // A picture or sound that changes shape mid-stream restarts the
            // filter graph. framehash states a stream's size once, and two
            // shapes can have one byte count, so nothing after the change
            // can be held: the pass is refused (Codex #308-1).
            guard !record.payload.hasPrefix(reconfiguredPayload) else { return .failure(ReadFault(line: String(line))) }
            last = record
            let peaks = "astats@\(runTag)s"
            if !runTag.isEmpty, let component = record.components.first, component.hasPrefix(peaks) {
                guard let stream = Int(component.dropFirst(peaks.count).prefix(while: { $0.isASCII && $0.isNumber })),
                      notePeak(record.payload, stream: stream, announced: &announced, in: &report) else {
                    return .failure(ReadFault(line: String(line)))
                }
            } else if let read = streamCount(fromPayload: record.payload, side: "Input", counting: " packets read") {
                let entry = StreamRead(packets: read.count, decodeErrors: read.decodeErrors)
                guard report.streams.updateValue(entry, forKey: read.index) == nil else {
                    return .failure(ReadFault(line: String(line)))
                }
            } else if let wrote = streamCount(fromPayload: record.payload, side: "Output", counting: " packets muxed") {
                guard report.muxed.updateValue(wrote.count, forKey: wrote.index) == nil else {
                    return .failure(ReadFault(line: String(line)))
                }
            }
        }
        guard let last, last.payload == cleanExitPayload else {
            return .failure(ReadFault(line: text.split(whereSeparator: \.isNewline).last.map(String.init)
                                        ?? "ffmpeg reported nothing about what it read"))
        }
        return .success(report)
    }

    /// One line of a run's astats for one sound stream: "Channel: N" opens
    /// channel N (they come 1, 2, … in order), "Peak level dB: v" is its
    /// peak. false = not exactly one peak per channel, in order.
    private static func notePeak(_ payload: Substring, stream: Int, announced: inout [Int: Int],
                                 in report: inout ReadReport) -> Bool {
        let measured = report.peaksDBFS[stream]?.count ?? 0
        if payload.hasPrefix("Channel:") {
            let number = Int(payload.dropFirst("Channel:".count).trimmingCharacters(in: .whitespaces))
            announced[stream, default: 0] += 1
            return number == announced[stream] && measured == (announced[stream] ?? 0) - 1
        }
        if payload.hasPrefix("Peak level dB:") {
            guard let peak = AstatsOutputParser.parsedDB(String(payload.dropFirst("Peak level dB:".count))),
                  measured == (announced[stream] ?? 0) - 1 else { return false }
            report.peaksDBFS[stream, default: []].append(peak)
        }
        return true
    }
}
