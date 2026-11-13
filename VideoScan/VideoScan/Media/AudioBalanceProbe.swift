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
    /// Declared sample rate in Hz; nil when ffprobe reports none.
    var sampleRateHz: Int? = nil
    /// How long the HEADER says this stream's sound runs, in seconds: the
    /// stream's own `duration`, else Matroska's per-stream DURATION tag.
    /// nil when the container states none for the stream (avi, raw dv) —
    /// then there is nothing to hold the decode against (GH #470).
    var statedSeconds: Double? = nil
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
    /// ffprobe's `format_name` — the DEMUXER's name(s), comma-separated
    /// for shared demuxers ("mov,mp4,m4a,3gp,3g2,mj2"). Raw DV probes
    /// as exactly "dv" — the balance job keys its output-container rule
    /// on this (BalanceAudioFix.isRawDVContainer). "" when unknown
    /// (legacy canned JSON in tests).
    var containerFormat: String = ""
    /// `r_frame_rate` of the first video stream ("30000/1001",
    /// "25/1", …). Raw DV needs it as an input-side `-r` override:
    /// the demuxer reports a bogus avg_frame_rate (60000/1) that makes
    /// the mov muxer fail at trailer-write. nil when there is no video
    /// stream or ffprobe didn't report one.
    var videoRFrameRate: String? = nil
}

// MARK: - Analysis result

/// The complete analyzer output — what the sheet displays and what the
/// balance job consumes. The stream-selection verdict (which stream
/// carries program, which get dropped) is decided HERE, at analyze
/// time, so the sheet can promise exactly what the job will do.
extension AudioBalanceStreamShape {
    /// ffprobe's channel count for each audio stream, by audio ordinal
    /// (0 = not declared). What a complete levels pass must cover.
    var declaredChannelsPerStream: [Int] {
        (0..<audioStreams).map { $0 < audioStreamInfos.count ? audioStreamInfos[$0].channels : 0 }
    }
}

/// A levels pass that exited 0 without delivering the sound the header
/// states (GH #470).
struct AudioShortDecode: Sendable, Equatable {
    /// Seconds of stated sound that did not decode.
    var missingSeconds: Double
    /// Seconds of sound the stream's header states.
    var statedSeconds: Double

    /// Why this is not a measurement, in the words every surface shows
    /// (Verify Audio, Check Media's Sound row, Promote's refusal). Numbers
    /// only: safe for logs.
    /// The one with more sound missing (a file can carry several streams).
    static func worse(_ a: AudioShortDecode?, _ b: AudioShortDecode?) -> AudioShortDecode? {
        guard let a else { return b }
        guard let b else { return a }
        return b.missingSeconds > a.missingSeconds ? b : a
    }

    var reason: String {
        "the sound decode stopped early — "
            + String(format: "%.1f s of the %.1f s", missingSeconds, statedSeconds)
            + " the file's header states did not decode (the file may be cut short, or a read failed)"
    }
}

struct AudioBalanceAnalysis: Sendable, Equatable {
    var classification: AudioChannelClass
    /// True only when the levels pass measured EVERY audio stream and every
    /// declared channel with a readable RMS (`levelsComplete(perStream:…)`),
    /// and no stream's decode ended short of the length its header states
    /// (`shortDecodeSeconds`, GH #470).
    /// Defaults false: an analysis nobody proved complete is never silence
    /// evidence (Codex round 2, 2026-10-24).
    var levelsComplete: Bool = false
    /// Set when a stream's decode RAN and ended short of the length its
    /// header states (GH #470): the worst stream's numbers. A check that ran
    /// and came up short is not "could not be made" — Promote's "Archive
    /// anyway" tick does not accept it (DECISIONS 2026-11-11).
    var shortDecode: AudioShortDecode? = nil
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

extension AudioBalanceAnalysis {
    /// What the levels pass MEASURED, in one place (Check Media's sound row
    /// and Promote's sound gate both ask this): true = every channel sat at
    /// or below the program floor (−60 dBFS RMS); false = at least one
    /// carries sound; nil = not measured — the pass did not cover every
    /// declared channel of every stream, or a channel's RMS was a parse gap.
    /// `measurements` is the program stream's (the first stream when none
    /// carries program), so "true" means no stream had sound. Pure.
    var measuredSilent: Bool? {
        let channels = measurements.channels
        guard levelsComplete, !channels.isEmpty, channels.allSatisfy(\.rmsMeasured) else { return nil }
        return !channels.contains(where: AudioBalanceClassifier.carriesProgram)
    }
}

enum AudioBalanceProbeError: Error, Equatable {
    case toolUnavailable(String)
    case noAudioStream
    case probeFailed(String)
    /// The astats pass hit OUR OWN per-run time limit (GH #136) — the
    /// runner killed ffmpeg, the file said nothing about itself. A
    /// distinct case, NOT probeFailed: Verify Audio's analyze-failure
    /// classification converts a probeFailed on a still-reachable file
    /// into an "undecodable audio" DAMAGE verdict, and that verdict
    /// feeds the notes:damaged batch-delete flow. A timeout is neither
    /// unreachable nor undecodable — it must never become damage
    /// evidence. Balance Audio's own callers treat it as a plain
    /// analysis failure, exactly like probeFailed, just with an honest
    /// message.
    case timedOut(afterSeconds: Int)
}

// Family-language messages (QA m2, 2026-07-24): before this, any path
// that fell back on `error.localizedDescription` — e.g. Balance Audio's
// post-fix verify catch — showed Rick raw type soup like
// "(VideoScan.AudioBalanceProbeError error 3.)". Every case gets an
// honest sentence; the timeout mirrors VerifyAudioProbe's #136 wording.
extension AudioBalanceProbeError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .toolUnavailable(let detail):
            return "The audio tools aren't available\(detail.isEmpty ? "" : " — \(detail)"). Nothing was changed."
        case .noAudioStream:
            return "This file has no audio track to check. Nothing was changed."
        case .probeFailed(let detail):
            return "The audio couldn't be read\(detail.isEmpty ? "" : " — \(detail)"). Nothing was changed."
        case .timedOut(let afterSeconds):
            return "This file is very large — the check ran out of time after \(afterSeconds) seconds without finishing. Nothing was changed; try again when the drive is less busy."
        }
    }
}

// MARK: - Probe

enum AudioBalanceProbe {

    // MARK: Levels-pass deadline (GH #136 — pinned in ONE place)

    /// Floor for the astats-pass deadline: the historical 300 s, plenty
    /// for any normal-sized file even on a slow spinning volume.
    static let levelsDeadlineFloorSeconds: Double = 300
    /// Hard cap: even a giant archive on a struggling disk gets at most
    /// 30 minutes per pass before we give up honestly.
    static let levelsDeadlineCapSeconds: Double = 1800
    /// Demux budget: the astats passes decode ONLY the audio, but ffmpeg
    /// must still demux (read) the whole container to reach it — the
    /// dominant cost on big files. 100 MiB/s is a conservative sequential-
    /// read rate for the external HDDs the archives live on; SSDs finish
    /// far inside the budget. Proof case: a 63.7 GB / 2h03m ffv1 mkv
    /// needs > 300 s just to stream the bytes, which is exactly how a
    /// healthy file used to blow the old fixed deadline.
    static let levelsDemuxBudgetBytesPerSecond: Double = 100 * 1024 * 1024

    /// Deadline for one astats pass, scaled to the file's size:
    /// max(300 s, ceil(bytes / 100 MiB-per-s)), capped at 1800 s.
    /// Unknown/zero size falls back to the floor. Pure — unit-tested in
    /// BalanceAudioProbeTests.
    static func levelsDeadlineSeconds(forFileSizeBytes bytes: Int64) -> Double {
        guard bytes > 0 else { return levelsDeadlineFloorSeconds }
        let scaled = (Double(bytes) / levelsDemuxBudgetBytesPerSecond).rounded(.up)
        return min(max(levelsDeadlineFloorSeconds, scaled), levelsDeadlineCapSeconds)
    }

    /// Did the levels pass measure every audio stream ffprobe declared,
    /// every declared channel of each (0 = channel count unknown), each
    /// with a readable RMS? Pure.
    static func levelsComplete(perStream: [[AudioChannelLevels]], declaredChannels: [Int]) -> Bool {
        guard !perStream.isEmpty, perStream.count == declaredChannels.count else { return false }
        for (channels, declared) in zip(perStream, declaredChannels) {
            guard !channels.isEmpty, declared <= 0 || channels.count >= declared,
                  channels.allSatisfy(\.rmsMeasured) else { return false }
        }
        return true
    }

    /// The whole completeness answer: every stream and channel was read
    /// (above) AND no stream's decode ended early (GH #470). Pure.
    static func levelsComplete(perStream: [[AudioChannelLevels]], declaredChannels: [Int],
                               shortDecode: AudioShortDecode?) -> Bool {
        shortDecode == nil && levelsComplete(perStream: perStream, declaredChannels: declaredChannels)
    }

    // MARK: A decode that ended early (GH #470)
    //
    // ffmpeg exits 0 when the file's tail is missing or a read fails partway:
    // it decodes what it reached and stops (measured 2026-11-11, ffmpeg 9.0:
    // mp4/aac, mov/pcm, mkv/pcm, mxf/pcm, wav, mp3 cut to 60 % of their bytes
    // all exit 0). The levels then describe only the part that decoded. So a
    // pass is complete only if the samples astats counted cover the length the
    // header states for that stream.
    //
    // Tolerance: short means MORE than 1 s AND more than 2 % is missing. It is
    // the tolerance Check Media's sample-count row already uses for the same
    // comparison (CheckMediaRules.sampleCountTolerance + avToleranceSeconds),
    // and 1 s is the repo's duration tolerance everywhere else (Verify Video,
    // Balance / Rebuild output checks). On whole synthetic files the two
    // numbers agree to the sample (mp4/aac, mov, mkv, mxf, avi/mp3: 0 missing),
    // so the margin is for real headers that round or estimate a length, not
    // for the decoder. What it does not catch: a decode that stops inside the
    // last 2 % (or last second) of the track.

    /// Missing sound under this many seconds is never "short".
    static let shortDecodeToleranceSeconds: Double = 1.0
    /// Missing sound under this fraction of the stated length is never "short".
    static let shortDecodeToleranceFraction: Double = 0.02

    /// Seconds of sound the header states that the decode did not deliver,
    /// when that is beyond the tolerance; nil when the decode covered the
    /// stream, or the header states no length / rate to compare against (an
    /// unknown length never makes a finding). A stated length with NO sample
    /// count is short by all of it: a count we asked for and could not read
    /// is not evidence the decode finished. Pure.
    static func shortDecodeSeconds(decodedSamples: Int64?, sampleRateHz: Int?, statedSeconds: Double?) -> Double? {
        guard let statedSeconds, statedSeconds > 0, let sampleRateHz, sampleRateHz > 0 else { return nil }
        guard let decodedSamples else { return statedSeconds }
        let missing = statedSeconds - Double(decodedSamples) / Double(sampleRateHz)
        return missing > max(shortDecodeToleranceSeconds, shortDecodeToleranceFraction * statedSeconds) ? missing : nil
    }

    /// One stream's levels pass held against the length its header states:
    /// the short decode, logged, or nil when the decode covered the stream
    /// (or the header states nothing to compare against).
    ///
    /// Known and accepted: Matroska states a stream's END timestamp, so a
    /// whole track that starts late (or has a gap) states more sound than it
    /// holds and reads "not checked". A correction from the first packet's
    /// timestamp was tried and removed (Codex #287 F2): a wrong timestamp
    /// could erase a real short decode. Refuse rather than guess.
    static func shortDecodeOfStream(_ ordinal: Int, levelsStderr: String, runTag: String,
                                    shape: AudioBalanceStreamShape, path: String) -> AudioShortDecode? {
        guard ordinal < shape.audioStreamInfos.count else { return nil }
        let info = shape.audioStreamInfos[ordinal]
        let decoded = AstatsOutputParser.samplesPerChannel(fromStderr: levelsStderr, runTag: runTag)
        guard let missing = shortDecodeSeconds(decodedSamples: decoded, sampleRateHz: info.sampleRateHz,
                                               statedSeconds: info.statedSeconds) else { return nil }
        let stated = info.statedSeconds ?? 0
        balanceLog.notice("analyze: \((path as NSString).lastPathComponent, privacy: .public) audio stream \(ordinal) — ffmpeg exited 0 but the decode ended early: \(decoded.map(String.init) ?? "no", privacy: .public) samples counted, \(String(format: "%.1f", missing), privacy: .public) s short of the \(String(format: "%.1f", stated), privacy: .public) s the header states; the levels are not a complete measurement")
        return AudioShortDecode(missingSeconds: missing, statedSeconds: stated)
    }

    /// Matroska's per-stream DURATION tag ("00:00:12.000000000") in seconds;
    /// nil for anything else. Pure.
    static func seconds(fromDurationTag tag: String?) -> Double? {
        MediaFacts.seconds(fromDurationTag: tag)
    }

    // MARK: Pure argument builders (unit-tested, no I/O)

    /// astats measurement shared by all passes: per-channel RMS + peak
    /// only (keeps the stderr output tiny and the parse surface small).
    /// `measure_overall=Number_of_samples` adds ONE line — how many samples
    /// per channel the filter was fed — which is the only evidence that the
    /// decode reached the end of the track (GH #470).
    static let astatsFilter =
        "astats=measure_perchannel=Peak_level+RMS_level:measure_overall=Number_of_samples"

    /// The same filter, its instance named for one run (`astats@<tag>=…`)
    /// so the lines it logs can be told from anything the file itself puts
    /// on stderr (AstatsOutputParser.newRunTag). nil = unnamed.
    static func astatsFilter(runTag: String?) -> String {
        guard let runTag else { return astatsFilter }
        return "astats@\(runTag)" + astatsFilter.dropFirst("astats".count)
    }

    /// Levels pass — per-channel levels of ONE audio stream, selected
    /// by audio-ordinal (`0:a:N`, N = position among audio streams).
    static func levelsArgs(input: String, audioStreamOrdinal: Int = 0, runTag: String? = nil) -> [String] {
        [
            "-hide_banner", "-nostdin",
            "-i", input,
            "-map", "0:a:\(audioStreamOrdinal)",
            "-af", astatsFilter(runTag: runTag),
            "-f", "null", "-"
        ]
    }

    /// Difference pass — RMS of the sample-difference signal (L−R), run
    /// only for a 2-channel program stream whose channels BOTH carry
    /// program (the dual-mono vs true-stereo decision).
    static func differenceArgs(input: String, audioStreamOrdinal: Int = 0, runTag: String? = nil) -> [String] {
        [
            "-hide_banner", "-nostdin",
            "-i", input,
            "-map", "0:a:\(audioStreamOrdinal)",
            "-af", "aeval=val(0)-val(1):c=mono,\(astatsFilter(runTag: runTag))",
            "-f", "null", "-"
        ]
    }

    /// ffprobe JSON request for the stream shape. `r_frame_rate` +
    /// `format_name` feed the raw-DV output-container rule
    /// (fix/balance-dv-output-container).
    static func shapeArgs(input: String) -> [String] {
        [
            "-v", "error",
            "-show_entries",
            "stream=index,codec_type,codec_name,channels,bit_rate,r_frame_rate,sample_rate,duration,nb_frames:stream_tags=DURATION",
            "-show_entries", "format=format_name,duration",
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
        let r_frame_rate: String?
        let sample_rate: String?
        let duration: String?
        let nb_frames: String?
        let tags: [String: String]?
    }
    private struct ProbedFormat: Decodable {
        let format_name: String?
        let duration: String?
    }
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
                bitRate: s.bit_rate.flatMap { Int($0) },
                sampleRateHz: s.sample_rate.flatMap { Int($0) },
                statedSeconds: s.duration.flatMap { Double($0) }
                    ?? seconds(fromDurationTag: s.tags?["DURATION"])
                    ?? MediaFacts.countedPCMSeconds(formatName: report.format?.format_name ?? "",
                                                    codec: s.codec_name ?? "",
                                                    frameCount: s.nb_frames.flatMap { Int($0) },
                                                    sampleRate: s.sample_rate.flatMap { Int($0) })))
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
            audioStreamInfos: audioInfos,
            containerFormat: report.format?.format_name ?? "",
            videoRFrameRate: video?.r_frame_rate)
    }

    // MARK: Levels of every stream (I/O)

    /// Why one stream's levels pass gave no measurement, else nil. Pure.
    static func levelsFailure(exitCode: Int32, timedOut: Bool, channels: [AudioChannelLevels], ordinal: Int,
                              deadline: TimeInterval) -> AudioBalanceProbeError? {
        guard exitCode == 0 else {
            // OUR deadline killed ffmpeg — says nothing about the file.
            // Distinct case so callers can never mistake it for decode
            // failure (GH #136).
            return timedOut
                ? .timedOut(afterSeconds: Int(deadline))
                : .probeFailed("ffmpeg astats pass on audio stream \(ordinal) exited with status \(exitCode)")
        }
        return channels.isEmpty
            ? .probeFailed("astats produced no per-channel measurements for audio stream \(ordinal)") : nil
    }

    /// One astats levels pass per audio stream. Exit 0 is not "decoded to
    /// the end" (GH #470): each pass is held against its stream's stated
    /// length, and the worst short decode is returned beside the levels.
    ///
    /// Once a stream came up short, a LATER stream's failure does not throw
    /// (Codex #286 F2): the answer is already "the decode ended early", and
    /// throwing would turn it into "could not be decoded" — which Promote's
    /// "Archive anyway" tick may accept. The loop stops there; the streams
    /// measured so far are returned and the pass is incomplete.
    static func measureLevels(path: String, shape: AudioBalanceStreamShape, ffmpeg: String,
                              deadline: TimeInterval, control: ProcessControl?) async throws
        -> (perStream: [[AudioChannelLevels]], shortDecode: AudioShortDecode?) {
        var perStream: [[AudioChannelLevels]] = []
        var shortDecode: AudioShortDecode?
        for ordinal in 0..<shape.audioStreams {
            let runTag = AstatsOutputParser.newRunTag()
            let result = await ProcessRunner.runProcess(
                executable: ffmpeg,
                arguments: levelsArgs(input: path, audioStreamOrdinal: ordinal, runTag: runTag),
                deadlineSeconds: deadline,
                control: control)
            let channels = result.exitCode == 0
                ? AstatsOutputParser.perChannelLevels(fromStderr: result.stderr, runTag: runTag) : []
            if let failure = levelsFailure(exitCode: result.exitCode, timedOut: result.timedOut, channels: channels,
                                           ordinal: ordinal, deadline: deadline) {
                guard shortDecode != nil else { throw failure }
                balanceLog.notice("analyze: \((path as NSString).lastPathComponent, privacy: .public) audio stream \(ordinal) gave no measurement after an earlier stream's decode ended early; the short decode stands")
                break
            }
            perStream.append(channels)
            shortDecode = AudioShortDecode.worse(shortDecode, shortDecodeOfStream(
                ordinal, levelsStderr: result.stderr, runTag: runTag, shape: shape, path: path))
            try Task.checkCancellation()
        }
        return (perStream, shortDecode)
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
    static func analyze(path: String,
                        control: ProcessControl? = nil) async throws -> AudioBalanceAnalysis {
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
            deadlineSeconds: 60,
            control: control)
        guard probeResult.exitCode == 0, let stdout = probeResult.stdout,
              let data = stdout.data(using: .utf8) else {
            // Same GH #136 rule as the astats passes below: a deadline
            // kill is OUR timeout, never file evidence. Without this, a
            // shape-probe kill (stalled mount) surfaced as a generic
            // probeFailed, which Verify Audio's analyze-failure path
            // arbitrates with the reachability recheck — and a mount
            // that recovers inside the 15 s recheck window would mint a
            // damage verdict from a runner kill. Gate on nonzero exit
            // first (see Result.timedOut race note).
            if probeResult.timedOut, probeResult.exitCode != 0 {
                throw AudioBalanceProbeError.timedOut(afterSeconds: 60)
            }
            throw AudioBalanceProbeError.probeFailed(
                "ffprobe exited with status \(probeResult.exitCode)")
        }
        var shape = try Self.shape(fromProbeJSON: data)
        try Task.checkCancellation()

        // ---- Scaled deadline for the full-decode passes (GH #136):
        // both astats passes demux the whole container, so their time
        // budget must follow the file's size. Repo-standard attributes
        // read; unknown size → the 300 s floor.
        let fileSizeBytes = ((try? FileManager.default
            .attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
        let passDeadline = levelsDeadlineSeconds(forFileSizeBytes: fileSizeBytes)

        // ---- Per-channel levels of EVERY audio stream (audio-only
        // decode, one pass each — 12-bit DV tapes carry two pairs).
        let (perStream, shortDecode) = try await measureLevels(
            path: path, shape: shape, ffmpeg: ffmpeg, deadline: passDeadline, control: control)

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
        // Not after a short decode (Codex #286 F2): the class of a partial
        // measurement is never used, and a failure here must not replace
        // "the decode ended early" with "could not be decoded".
        if shortDecode == nil, programOrdinals.count == 1, channels.count == 2,
           AudioBalanceClassifier.carriesProgram(channels[0]),
           AudioBalanceClassifier.carriesProgram(channels[1]) {
            let differenceTag = AstatsOutputParser.newRunTag()
            let diffResult = await ProcessRunner.runProcess(
                executable: ffmpeg,
                arguments: differenceArgs(input: path, audioStreamOrdinal: chosenOrdinal, runTag: differenceTag),
                deadlineSeconds: passDeadline,
                control: control)
            guard diffResult.exitCode == 0 else {
                if diffResult.timedOut {
                    throw AudioBalanceProbeError.timedOut(afterSeconds: Int(passDeadline))
                }
                throw AudioBalanceProbeError.probeFailed(
                    "ffmpeg difference pass exited with status \(diffResult.exitCode)")
            }
            let diffChannels = AstatsOutputParser.perChannelLevels(
                fromStderr: diffResult.stderr, runTag: differenceTag)
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
        var analysis = AudioBalanceAnalysis(
            classification: classification,
            measurements: measurements,
            shape: shape,
            programStreamCount: programOrdinals.count,
            programStreamIndex: absoluteIndex(chosenOrdinal),
            droppedStreamIndices: dropped)
        analysis.shortDecode = shortDecode
        analysis.levelsComplete = levelsComplete(
            perStream: perStream,
            declaredChannels: shape.declaredChannelsPerStream,
            shortDecode: shortDecode)
        return analysis
    }
}
