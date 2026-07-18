import Foundation
import os

// MARK: - Audio Balance probe (ffmpeg half)
//
// The I/O half of the Balance Audio analyzer (GH #116): one ffprobe call
// for the stream shape, then short ffmpeg passes that decode ONLY the
// audio through astats. The pure classification rules and the astats
// parser live in AudioBalanceAnalyzer.swift.
//
// MULTI-STREAM (12-bit DV) SUPPORT — fix/balance-audio-dv-multitrack:
// DV camcorders in 12-bit audio mode record TWO stereo pairs; ffprobe
// reports them as two audio streams (real case: Clip 28.dv — pair 1
// carries program on the right channel, pair 2 is the unused, silent
// second pair). v1 measured only `0:a:0` and the job refused any file
// with >1 audio stream — the sheet promised a fix the job then refused.
// Now the probe measures EVERY audio stream (one astats pass each) and
// decides at ANALYZE time:
//
//   - exactly ONE stream carries program (any channel above the −60 dBFS
//     floor) → classify from THAT stream; the silent extras are recorded
//     in `droppedStreamIndices` and dropped from the job's output;
//   - MORE than one stream carries program → the analysis is refused by
//     BalanceAudioFix.refusalReason(for:) — the same gate the sheet and
//     the job both consult;
//   - ZERO streams carry program → the existing `silent` refusal.
//
// Single-audio-stream files take exactly the v1 path (one levels pass on
// `0:a:0`, optional difference pass) — behavior is unchanged for them.
//
// Cost: audio-only decode — seconds even for a two-hour tape, per audio
// stream (no video decode ever happens; `-map 0:a:N` + `-f null -`).
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

/// One audio stream as ffprobe reported it. `absoluteIndex` is the
/// container-wide stream index (what `-map 0:N` addresses) — NOT the
/// audio-ordinal (`0:a:N`). For Clip 28.dv: video=0, pair 1=1, pair 2=2.
struct AudioBalanceStreamInfo: Sendable, Equatable {
    var absoluteIndex: Int
    var codec: String
    var channels: Int
    /// Declared bitrate in bits/s; nil when ffprobe doesn't report one
    /// (typical for PCM in MOV/MXF/DV).
    var bitRate: Int?
}

/// What ffprobe says about the file's streams — consumed by the
/// classifier gate (channel/stream counts) and by the balance job's
/// post-fix verification (video codec unchanged, stream count as
/// expected, duration within tolerance).
struct AudioBalanceStreamShape: Sendable, Equatable {
    /// Codec of the first video stream; nil when the file has none.
    var videoCodec: String?
    /// Total number of streams of every type.
    var totalStreams: Int
    /// Number of video streams (drives the multi-audio output-stream
    /// expectation: video + the one program track).
    var videoStreams: Int
    /// Number of audio streams.
    var audioStreams: Int
    /// Codec of the PROGRAM audio stream. `shape(fromProbeJSON:)` fills
    /// in the first audio stream; `analyze` rebinds to the stream that
    /// actually carries program, so the job's encoder args follow the
    /// program stream, never blindly `0:a:0`.
    var audioCodec: String
    /// Channel count of the program audio stream (same rebinding).
    var audioChannels: Int
    /// Declared bitrate of the program audio stream in bits/s; nil when
    /// ffprobe doesn't report one (typical for PCM in MOV/MXF).
    var audioBitRate: Int?
    /// Container duration in seconds (0 = unknown).
    var durationSeconds: Double
    /// Every audio stream, in ffprobe order (audio-ordinal order).
    var audioStreamInfos: [AudioBalanceStreamInfo]
}

// MARK: - Analysis result

/// The complete analyzer output — what the sheet displays and what the
/// balance job consumes. The stream-selection verdict (which stream
/// carries program, which get dropped) is decided HERE, at analyze
/// time, so the sheet can promise exactly what the job will do.
struct AudioBalanceAnalysis: Sendable, Equatable {
    var classification: AudioChannelClass
    /// Levels of the PROGRAM stream (the first stream when none, or
    /// more than one, carries program).
    var measurements: AudioBalanceMeasurements
    var shape: AudioBalanceStreamShape
    /// How many audio streams carry program (any channel above the
    /// classifier's −60 dBFS floor). >1 refuses at analyze time via
    /// BalanceAudioFix.refusalReason(for:).
    var programStreamCount: Int
    /// ABSOLUTE container index of the stream the fix reads (what
    /// `-map 0:N` addresses). For single-audio files this is simply the
    /// one audio stream.
    var programStreamIndex: Int
    /// Absolute indices of silent audio streams the job will DROP from
    /// the output (the unused second DV pair). Empty unless exactly one
    /// stream carries program and others exist.
    var droppedStreamIndices: [Int]
}

enum AudioBalanceProbeError: Error, Equatable {
    case toolUnavailable(String)
    case noAudioStream
    case probeFailed(String)
}

// MARK: - Probe

enum AudioBalanceProbe {

    // MARK: Pure argument builders (unit-tested, no I/O)

    /// astats measurement shared by all passes: per-channel RMS + peak
    /// only (keeps the stderr output tiny and the parse surface small).
    static let astatsFilter =
        "astats=measure_perchannel=Peak_level+RMS_level:measure_overall=none"

    /// Levels pass — per-channel levels of ONE audio stream, selected
    /// by audio-ordinal (`0:a:N`, N = position among audio streams).
    static func levelsArgs(input: String, audioStreamOrdinal: Int = 0) -> [String] {
        [
            "-hide_banner", "-nostdin",
            "-i", input,
            "-map", "0:a:\(audioStreamOrdinal)",
            "-af", astatsFilter,
            "-f", "null", "-"
        ]
    }

    /// Difference pass — RMS of the sample-difference signal (L−R), run
    /// only for a 2-channel program stream whose channels BOTH carry
    /// program (the dual-mono vs true-stereo decision).
    static func differenceArgs(input: String, audioStreamOrdinal: Int = 0) -> [String] {
        [
            "-hide_banner", "-nostdin",
            "-i", input,
            "-map", "0:a:\(audioStreamOrdinal)",
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
        let index: Int?
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
    /// JSON. Throws `.noAudioStream` when the file has no audio. The
    /// audio summary fields are the FIRST audio stream's here; `analyze`
    /// rebinds them to the program stream once levels are measured.
    static func shape(fromProbeJSON data: Data) throws -> AudioBalanceStreamShape {
        let report: ProbeReport
        do {
            report = try JSONDecoder().decode(ProbeReport.self, from: data)
        } catch {
            throw AudioBalanceProbeError.probeFailed(
                "ffprobe output was not readable JSON")
        }
        let streams = report.streams ?? []
        var audioInfos: [AudioBalanceStreamInfo] = []
        for (position, s) in streams.enumerated() where s.codec_type == "audio" {
            audioInfos.append(AudioBalanceStreamInfo(
                absoluteIndex: s.index ?? position,
                codec: s.codec_name ?? "",
                channels: s.channels ?? 0,
                bitRate: s.bit_rate.flatMap { Int($0) }))
        }
        guard let firstAudio = audioInfos.first else {
            throw AudioBalanceProbeError.noAudioStream
        }
        let video = streams.first { $0.codec_type == "video" }
        return AudioBalanceStreamShape(
            videoCodec: video?.codec_name,
            totalStreams: streams.count,
            videoStreams: streams.filter { $0.codec_type == "video" }.count,
            audioStreams: audioInfos.count,
            audioCodec: firstAudio.codec,
            audioChannels: firstAudio.channels,
            audioBitRate: firstAudio.bitRate,
            durationSeconds: Double(report.format?.duration ?? "") ?? 0,
            audioStreamInfos: audioInfos)
    }

    // MARK: Full analysis (I/O)

    /// Analyze one media file's audio: ffprobe shape, one astats levels
    /// pass PER audio stream, program-stream selection, then (only when
    /// needed) the difference pass on the program stream.
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
        var shape = try Self.shape(fromProbeJSON: data)
        try Task.checkCancellation()

        // ---- Per-channel levels of EVERY audio stream (audio-only
        // decode, one pass each — 12-bit DV tapes carry two pairs).
        var perStream: [[AudioChannelLevels]] = []
        for ordinal in 0..<shape.audioStreams {
            let levelsResult = await ProcessRunner.runProcess(
                executable: ffmpeg,
                arguments: levelsArgs(input: path, audioStreamOrdinal: ordinal),
                deadlineSeconds: 300)
            guard levelsResult.exitCode == 0 else {
                throw AudioBalanceProbeError.probeFailed(
                    "ffmpeg astats pass on audio stream \(ordinal) exited with status \(levelsResult.exitCode)")
            }
            let channels = AstatsOutputParser.perChannelLevels(
                fromStderr: levelsResult.stderr)
            guard !channels.isEmpty else {
                throw AudioBalanceProbeError.probeFailed(
                    "astats produced no per-channel measurements for audio stream \(ordinal)")
            }
            perStream.append(channels)
            try Task.checkCancellation()
        }

        // ---- Program-stream selection (the analyze-time decision).
        // A stream "carries program" when ANY of its channels clears the
        // classifier's −60 dBFS floor.
        let programOrdinals = perStream.indices.filter { i in
            perStream[i].contains(where: AudioBalanceClassifier.carriesProgram)
        }
        // The stream the fix would read: the single program stream, or
        // the first audio stream when none (all-silent) / several
        // (refused at analyze time) carry program.
        let chosenOrdinal = programOrdinals.first ?? 0
        let channels = perStream[chosenOrdinal]

        // Rebind the shape's audio summary to the CHOSEN stream so the
        // job's encoder args (codec/bitrate) follow the program stream.
        let absoluteIndex: (Int) -> Int = { ordinal in
            ordinal < shape.audioStreamInfos.count
                ? shape.audioStreamInfos[ordinal].absoluteIndex
                : ordinal
        }
        if chosenOrdinal < shape.audioStreamInfos.count {
            let info = shape.audioStreamInfos[chosenOrdinal]
            shape.audioCodec = info.codec
            shape.audioChannels = info.channels
            shape.audioBitRate = info.bitRate
        }

        // ---- Difference pass, only when the dual-mono question is live
        // (single program stream, 2 channels, both above the floor).
        var difference: Double?
        if programOrdinals.count == 1, channels.count == 2,
           AudioBalanceClassifier.carriesProgram(channels[0]),
           AudioBalanceClassifier.carriesProgram(channels[1]) {
            let diffResult = await ProcessRunner.runProcess(
                executable: ffmpeg,
                arguments: differenceArgs(input: path, audioStreamOrdinal: chosenOrdinal),
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

        // Silent extras are dropped ONLY in the actionable single-
        // program case; refusals (0 or >1 program streams) drop nothing
        // because the job never runs.
        let dropped = programOrdinals.count == 1
            ? perStream.indices.filter { $0 != chosenOrdinal }.map(absoluteIndex)
            : []

        let measurements = AudioBalanceMeasurements(
            channels: channels, differenceRMSDBFS: difference)
        let classification = AudioBalanceClassifier.classify(measurements)
        balanceLog.info("analyze: \((path as NSString).lastPathComponent, privacy: .public) → \(classification.rawValue, privacy: .public) (audioStreams=\(shape.audioStreams), programStreams=\(programOrdinals.count), program=#\(absoluteIndex(chosenOrdinal)), drop=[\(dropped.map(String.init).joined(separator: ","), privacy: .public)], channels=\(channels.count), diff=\(difference.map { String(format: "%.1f", $0) } ?? "n/a", privacy: .public) dBFS)")
        return AudioBalanceAnalysis(
            classification: classification,
            measurements: measurements,
            shape: shape,
            programStreamCount: programOrdinals.count,
            programStreamIndex: absoluteIndex(chosenOrdinal),
            droppedStreamIndices: dropped)
    }
}
