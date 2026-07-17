import Foundation
import os

// MARK: - Audio Balance probe (ffmpeg half)
//
// The I/O half of the Balance Audio analyzer (GH #116): one ffprobe call
// for the stream shape, then one or two short ffmpeg passes that decode
// ONLY the audio through astats. The pure classification rules and the
// astats parser live in AudioBalanceAnalyzer.swift.
//
// Cost: audio-only decode — seconds even for a two-hour tape (no video
// decode ever happens; `-map 0:a:0` + `-f null -`).
//
// Memory: ffmpeg streams; this process retains only ffprobe's JSON
// (KBs) and astats' stderr, capped by ProcessRunner's default 256 KB
// stderr limit. Worst-case in-process footprint ≈ 0.5 MB per analysis.
//
// Concurrency: `analyze` is `@concurrent` — this repo's Approachable
// Concurrency configuration runs `nonisolated async` on the CALLER's
// actor, so a plain async func called from a @MainActor sheet would
// decode audio on the UI thread (the documented trap). `@concurrent`
// forces the global executor. (For Rick: ≈ explicitly punting the work
// to a background thread pool instead of inheriting the caller's.)

private let balanceLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                category: "balanceAudio")

// MARK: - Stream shape

/// What ffprobe says about the file's streams — consumed by the
/// classifier gate (channel/stream counts) and by the balance job's
/// post-fix verification (video codec unchanged, stream count
/// preserved, duration within tolerance).
struct AudioBalanceStreamShape: Sendable, Equatable {
    /// Codec of the first video stream; nil when the file has none.
    var videoCodec: String?
    /// Total number of streams of every type.
    var totalStreams: Int
    /// Number of audio streams (v1 balance requires exactly 1).
    var audioStreams: Int
    /// Codec of the first audio stream ("" when unknown).
    var audioCodec: String
    /// Channel count of the first audio stream.
    var audioChannels: Int
    /// Declared bitrate of the first audio stream in bits/s; nil when
    /// ffprobe doesn't report one (typical for PCM in MOV/MXF).
    var audioBitRate: Int?
    /// Container duration in seconds (0 = unknown).
    var durationSeconds: Double
}

// MARK: - Analysis result

/// The complete analyzer output — what the sheet displays and what the
/// balance job consumes.
struct AudioBalanceAnalysis: Sendable, Equatable {
    var classification: AudioChannelClass
    var measurements: AudioBalanceMeasurements
    var shape: AudioBalanceStreamShape
}

enum AudioBalanceProbeError: Error, Equatable {
    case toolUnavailable(String)
    case noAudioStream
    case probeFailed(String)
}

// MARK: - Probe

enum AudioBalanceProbe {

    // MARK: Pure argument builders (unit-tested, no I/O)

    /// astats measurement shared by both passes: per-channel RMS + peak
    /// only (keeps the stderr output tiny and the parse surface small).
    static let astatsFilter =
        "astats=measure_perchannel=Peak_level+RMS_level:measure_overall=none"

    /// Pass 1 — per-channel levels of the first audio stream.
    static func levelsArgs(input: String) -> [String] {
        [
            "-hide_banner", "-nostdin",
            "-i", input,
            "-map", "0:a:0",
            "-af", astatsFilter,
            "-f", "null", "-"
        ]
    }

    /// Pass 2 — RMS of the sample-difference signal (L−R), run only for
    /// 2-channel streams whose channels BOTH carry program (the
    /// dual-mono vs true-stereo decision).
    static func differenceArgs(input: String) -> [String] {
        [
            "-hide_banner", "-nostdin",
            "-i", input,
            "-map", "0:a:0",
            "-af", "aeval=val(0)-val(1):c=mono,\(astatsFilter)",
            "-f", "null", "-"
        ]
    }

    /// ffprobe JSON request for the stream shape.
    static func shapeArgs(input: String) -> [String] {
        [
            "-v", "error",
            "-show_entries", "stream=index,codec_type,codec_name,channels,bit_rate",
            "-show_entries", "format=duration",
            "-of", "json",
            input
        ]
    }

    // MARK: ffprobe JSON decoding (pure)

    private struct ProbedStream: Decodable {
        let codec_type: String?
        let codec_name: String?
        let channels: Int?
        let bit_rate: String?
    }
    private struct ProbedFormat: Decodable { let duration: String? }
    private struct ProbeReport: Decodable {
        let streams: [ProbedStream]?
        let format: ProbedFormat?
    }

    /// Decode ffprobe's JSON into a shape. Pure — tested with canned
    /// JSON. Throws `.noAudioStream` when the file has no audio.
    static func shape(fromProbeJSON data: Data) throws -> AudioBalanceStreamShape {
        let report: ProbeReport
        do {
            report = try JSONDecoder().decode(ProbeReport.self, from: data)
        } catch {
            throw AudioBalanceProbeError.probeFailed(
                "ffprobe output was not readable JSON")
        }
        let streams = report.streams ?? []
        let audio = streams.filter { $0.codec_type == "audio" }
        guard let firstAudio = audio.first else {
            throw AudioBalanceProbeError.noAudioStream
        }
        let video = streams.first { $0.codec_type == "video" }
        return AudioBalanceStreamShape(
            videoCodec: video?.codec_name,
            totalStreams: streams.count,
            audioStreams: audio.count,
            audioCodec: firstAudio.codec_name ?? "",
            audioChannels: firstAudio.channels ?? 0,
            audioBitRate: firstAudio.bit_rate.flatMap { Int($0) },
            durationSeconds: Double(report.format?.duration ?? "") ?? 0
        )
    }

    // MARK: Full analysis (I/O)

    /// Analyze one media file's first audio stream: ffprobe shape, then
    /// astats levels, then (only when needed) the difference pass.
    ///
    /// `@concurrent`: runs on the global executor — safe to call from
    /// the @MainActor sheet/job without pinning the UI thread. See the
    /// file-header concurrency note.
    #if compiler(>=6.2)
    @concurrent
    #endif
    static func analyze(path: String) async throws -> AudioBalanceAnalysis {
        let ffprobe = ToolLocator.ffprobePath
        let ffmpeg = ToolLocator.ffmpegPath
        guard FileManager.default.isExecutableFile(atPath: ffprobe),
              FileManager.default.isExecutableFile(atPath: ffmpeg) else {
            throw AudioBalanceProbeError.toolUnavailable(
                "ffmpeg/ffprobe not found (set VS_FFMPEG_PATH / VS_FFPROBE_PATH or install via Homebrew)")
        }

        // ---- Shape (ffprobe, sub-second).
        let probeResult = await ProcessRunner.runProcess(
            executable: ffprobe,
            arguments: shapeArgs(input: path),
            stdoutLimitBytes: 1 << 20,
            deadlineSeconds: 60)
        guard probeResult.exitCode == 0, let stdout = probeResult.stdout,
              let data = stdout.data(using: .utf8) else {
            throw AudioBalanceProbeError.probeFailed(
                "ffprobe exited with status \(probeResult.exitCode)")
        }
        let shape = try Self.shape(fromProbeJSON: data)
        try Task.checkCancellation()

        // ---- Per-channel levels (audio-only decode).
        let levelsResult = await ProcessRunner.runProcess(
            executable: ffmpeg,
            arguments: levelsArgs(input: path),
            deadlineSeconds: 300)
        guard levelsResult.exitCode == 0 else {
            throw AudioBalanceProbeError.probeFailed(
                "ffmpeg astats pass exited with status \(levelsResult.exitCode)")
        }
        let channels = AstatsOutputParser.perChannelLevels(
            fromStderr: levelsResult.stderr)
        guard !channels.isEmpty else {
            throw AudioBalanceProbeError.probeFailed(
                "astats produced no per-channel measurements")
        }
        try Task.checkCancellation()

        // ---- Difference pass, only when the dual-mono question is live
        // (2 channels, both above the program floor).
        var difference: Double?
        if channels.count == 2,
           AudioBalanceClassifier.carriesProgram(channels[0]),
           AudioBalanceClassifier.carriesProgram(channels[1]) {
            let diffResult = await ProcessRunner.runProcess(
                executable: ffmpeg,
                arguments: differenceArgs(input: path),
                deadlineSeconds: 300)
            guard diffResult.exitCode == 0 else {
                throw AudioBalanceProbeError.probeFailed(
                    "ffmpeg difference pass exited with status \(diffResult.exitCode)")
            }
            let diffChannels = AstatsOutputParser.perChannelLevels(
                fromStderr: diffResult.stderr)
            // Unparseable difference stays nil → conservative trueStereo.
            difference = diffChannels.first?.rmsDBFS
        }

        let measurements = AudioBalanceMeasurements(
            channels: channels, differenceRMSDBFS: difference)
        let classification = AudioBalanceClassifier.classify(measurements)
        balanceLog.info("analyze: \((path as NSString).lastPathComponent, privacy: .public) → \(classification.rawValue, privacy: .public) (channels=\(channels.count), diff=\(difference.map { String(format: "%.1f", $0) } ?? "n/a", privacy: .public) dBFS)")
        return AudioBalanceAnalysis(
            classification: classification,
            measurements: measurements,
            shape: shape)
    }
}
