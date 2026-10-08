import Foundation
import os

// MARK: - Repair's measurements — ffprobe / ffmpeg through ProcessRunner
//
// Read-only on media. Two measurements:
//   - `streamTallies`: per stream, packets / bytes / length — the remux's
//     before-and-after proof. Streams one line per packet into counters
//     (O(streams) memory, nothing collected; the whole file is read once,
//     no decode).
//   - `summary`: streams, length and the picture's facts (header only).
//   - `sampledDecodeFailure`: ≤ 5 short windows of the COPY decoded
//     ("structural checks + sampled decode" — never "fully verified").
//
// `@concurrent` so the work never runs on the caller's actor (this repo's
// Approachable Concurrency trap: a plain `nonisolated async` func runs ON
// the caller's actor — the main thread when the job calls it).

private let repairProbeLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "repair")

enum MediaRepairProbe {

    struct ProbeFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Thread-safe counters fed from ProcessRunner's line callback (it
    /// runs on a pipe-reader thread). (≈ C++: a struct behind a mutex.)
    private final class TallyBox: @unchecked Sendable {
        private let lock = NSLock()
        private var tallies: [Int: MediaStreamTally]
        private var lines = 0

        init(_ streams: [MediaStreamTally]) {
            tallies = Dictionary(uniqueKeysWithValues: streams.map { ($0.index, $0) })
        }

        /// Counts one census line; returns how many lines so far.
        @discardableResult
        func note(_ line: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            lines += 1
            guard let p = MediaStreamTally.parseCensusLine(line) else { return lines }
            tallies[p.index]?.packets += 1
            tallies[p.index]?.bytes += p.size
            tallies[p.index]?.durationTicks += p.duration
            return lines
        }

        var result: [MediaStreamTally] {
            lock.lock(); defer { lock.unlock() }
            return tallies.values.sorted { $0.index < $1.index }
        }
    }

    private struct HeaderJSON: Decodable {
        struct Stream: Decodable {
            let index: Int
            let codec_type: String?
            let codec_name: String?
            let time_base: String?
            let sample_rate: String?
        }
        let streams: [Stream]?
    }

    /// Every stream's packet tally.
    /// `heartbeat` is called every 10,000 packets (the stall watchdog's tick).
    @concurrent
    static func streamTallies(path: String, control: ProcessControl?,
                              heartbeat: (@Sendable () -> Void)? = nil) async throws -> [MediaStreamTally] {
        let ffprobe = try tool(ToolLocator.ffprobePath, "ffprobe")
        let header = await ProcessRunner.runProcess(
            executable: ffprobe, arguments: MediaRepairCommand.streamHeaderArgs(input: path),
            stdoutLimitBytes: 1_000_000, deadlineSeconds: 120, control: control)
        try Task.checkCancellation()
        guard header.exitCode == 0, let json = header.stdout,
              let parsed = try? JSONDecoder().decode(HeaderJSON.self, from: Data(json.utf8)),
              let streams = parsed.streams, !streams.isEmpty else {
            throw ProbeFailure(message: "ffprobe could not list the streams of \((path as NSString).lastPathComponent)")
        }
        let box = TallyBox(streams.map {
            MediaStreamTally(index: $0.index, codecType: $0.codec_type ?? "", codec: $0.codec_name ?? "",
                             secondsPerTick: MediaStreamTally.secondsPerTick(timeBase: $0.time_base ?? ""),
                             sampleRate: $0.sample_rate.flatMap { Int($0) })
        })
        let census = await ProcessRunner.runProcess(
            executable: ffprobe, arguments: MediaRepairCommand.packetCensusArgs(input: path),
            stdoutLine: { line in
                if box.note(line) % 10_000 == 0 { heartbeat?() }
            },
            stdoutLimitBytes: 0, stderrLimitBytes: 16 * 1024, control: control)
        try Task.checkCancellation()
        guard census.exitCode == 0 else {
            throw ProbeFailure(message: "ffprobe could not read every packet (exit \(census.exitCode))")
        }
        return box.result
    }

    private struct SummaryJSON: Decodable {
        struct Stream: Decodable {
            let codec_type: String?
            let codec_name: String?
            let pix_fmt: String?
            let r_frame_rate: String?
            let avg_frame_rate: String?
            let color_primaries: String?
            let color_transfer: String?
            let color_space: String?
            let color_range: String?
            let sample_aspect_ratio: String?
            let field_order: String?
        }
        struct Format: Decodable {
            let duration: String?
        }
        let streams: [Stream]?
        let format: Format?
    }

    /// Streams, container length and the first picture stream's facts,
    /// from the header (no decode).
    @concurrent
    static func summary(path: String, control: ProcessControl?) async throws -> MediaRepairStreamSummary {
        let ffprobe = try tool(ToolLocator.ffprobePath, "ffprobe")
        let r = await ProcessRunner.runProcess(
            executable: ffprobe, arguments: MediaRepairCommand.summaryArgs(input: path),
            stdoutLimitBytes: 1_000_000, deadlineSeconds: 120, control: control)
        try Task.checkCancellation()
        guard r.exitCode == 0, let json = r.stdout,
              let parsed = try? JSONDecoder().decode(SummaryJSON.self, from: Data(json.utf8)) else {
            throw ProbeFailure(message: "ffprobe could not read \((path as NSString).lastPathComponent)")
        }
        let streams = parsed.streams ?? []
        let picture = streams.first { $0.codec_type == "video" }.map {
            MediaRepairPictureFacts(codec: $0.codec_name ?? "", pixelFormat: $0.pix_fmt ?? "",
                                    rFrameRate: $0.r_frame_rate ?? "", avgFrameRate: $0.avg_frame_rate ?? "",
                                    colorPrimaries: $0.color_primaries ?? "", colorTransfer: $0.color_transfer ?? "",
                                    colorSpace: $0.color_space ?? "", colorRange: $0.color_range ?? "",
                                    sampleAspectRatio: $0.sample_aspect_ratio ?? "", fieldOrder: $0.field_order ?? "")
        }
        return MediaRepairStreamSummary(
            streams: streams.map {
                MediaRepairStreamSummary.Stream(codecType: $0.codec_type ?? "", codec: $0.codec_name ?? "")
            },
            durationSeconds: parsed.format?.duration.flatMap(Double.init) ?? 0,
            picture: picture)
    }

    /// The sampled decode (codex consult #6): decode a short window at the
    /// start, three spread through, and the end; any decode error fails.
    /// nil = every window decoded. Bounded: ≤ 5 × 2 s decoded, stderr capped.
    @concurrent
    static func sampledDecodeFailure(path: String, durationSeconds: Double,
                                     control: ProcessControl?) async throws -> String? {
        let ffmpeg = try tool(ToolLocator.ffmpegPath, "ffmpeg")
        for start in MediaRepairCommand.sampleWindowStarts(durationSeconds: durationSeconds) {
            let r = await ProcessRunner.runProcess(
                executable: ffmpeg,
                arguments: MediaRepairCommand.sampledDecodeArgs(input: path, start: start),
                stdoutLimitBytes: 0, stderrLimitBytes: 16 * 1024, deadlineSeconds: 300, control: control)
            try Task.checkCancellation()
            let errors = r.stderr.split(separator: "\n").filter { !$0.isEmpty }
            if r.exitCode != 0 || !errors.isEmpty {
                let at = String(format: "%.1f s", start)
                return "the copy didn't decode cleanly at \(at)\(errors.first.map { " (\($0))" } ?? "")"
            }
        }
        repairProbeLog.info("repair sampled decode OK: \((path as NSString).lastPathComponent, privacy: .public)")
        return nil
    }

    private static func tool(_ path: String, _ name: String) throws -> String {
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            throw ProbeFailure(message: "\(name) not found (install it with Homebrew)")
        }
        return path
    }
}
