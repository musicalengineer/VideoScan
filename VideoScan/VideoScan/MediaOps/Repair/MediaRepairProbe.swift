import Foundation
import os

// MARK: - Repair's measurements — ffprobe / ffmpeg through ProcessRunner
//
// Read-only on media. Two measurements:
//   - `streamTallies`: per stream, packets / bytes / length — the remux's
//     before-and-after proof. Streams one line per packet into counters
//     (O(streams) memory, nothing collected; the whole file is read once,
//     no decode).
//   - `keptFrameTimes`: a short window decoded through `mpdecimate`; the
//     kept frames' times (≤ 4 s of real frames — a few hundred doubles).
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

        init(_ streams: [MediaStreamTally]) {
            tallies = Dictionary(uniqueKeysWithValues: streams.map { ($0.index, $0) })
        }

        func note(_ line: String) {
            guard let p = MediaStreamTally.parseCensusLine(line) else { return }
            lock.lock(); defer { lock.unlock() }
            tallies[p.index]?.packets += 1
            tallies[p.index]?.bytes += p.size
            tallies[p.index]?.durationTicks += p.duration
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
    @concurrent
    static func streamTallies(path: String, control: ProcessControl?) async throws -> [MediaStreamTally] {
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
            stdoutLine: { box.note($0) },
            stdoutLimitBytes: 0, stderrLimitBytes: 16 * 1024, control: control)
        try Task.checkCancellation()
        guard census.exitCode == 0 else {
            throw ProbeFailure(message: "ffprobe could not read every packet (exit \(census.exitCode))")
        }
        return box.result
    }

    /// Times of the frames `mpdecimate` keeps in one window.
    @concurrent
    static func keptFrameTimes(path: String, start: Double, seconds: Double,
                               control: ProcessControl?) async throws -> [Double] {
        let ffmpeg = try tool(ToolLocator.ffmpegPath, "ffmpeg")
        let times = TimesBox()
        let r = await ProcessRunner.runProcess(
            executable: ffmpeg,
            arguments: MediaRepairCommand.rateSampleArgs(input: path, start: start, seconds: seconds),
            stderrLine: { line in
                if let t = MediaRepairCommand.keptFrameTime(fromShowinfoLine: line) { times.append(t) }
            },
            stdoutLimitBytes: 0, stderrLimitBytes: 16 * 1024, control: control)
        try Task.checkCancellation()
        guard r.exitCode == 0 else {
            throw ProbeFailure(message: "ffmpeg could not decode a sample of the picture (exit \(r.exitCode))")
        }
        repairProbeLog.info("repair rate sample: \((path as NSString).lastPathComponent, privacy: .public) @\(start, format: .fixed(precision: 1))s kept \(times.count) frame(s)")
        return times.values
    }

    /// Kept-frame times, appended from the stderr reader thread. Bounded:
    /// a window keeps at most a few hundred real frames; capped anyway.
    private final class TimesBox: @unchecked Sendable {
        private let lock = NSLock()
        private var times: [Double] = []
        static let cap = 20_000

        func append(_ t: Double) {
            lock.lock(); defer { lock.unlock() }
            if times.count < Self.cap { times.append(t) }
        }
        var values: [Double] { lock.lock(); defer { lock.unlock() }; return times }
        var count: Int { lock.lock(); defer { lock.unlock() }; return times.count }
    }

    private static func tool(_ path: String, _ name: String) throws -> String {
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            throw ProbeFailure(message: "\(name) not found (install it with Homebrew)")
        }
        return path
    }
}
