import Foundation

// MARK: - Repair's ffmpeg commands, the real-rate estimate and the
// stream-parity verdict (Rick 2026-10-08). Pure: argument lists, line
// parsers and verdicts. The probe (MediaRepairProbe) runs them through
// ProcessRunner; the job (MediaRepairJob) sequences them.

enum MediaRepairCommand {

    /// Lossless remux: every stream copied packet for packet into a new
    /// container of the same kind. ffmpeg's muxer interleaves sound and
    /// picture by time on its own; nothing is decoded or re-encoded.
    /// `-y` only ever overwrites our OWN reserved partial (an empty
    /// O_EXCL file), never a real name.
    static func remuxArgs(input: String, output: String) -> [String] {
        ["-hide_banner", "-nostdin", "-y",
         "-i", input,
         "-map", "0", "-c", "copy",
         "-progress", "pipe:2",
         output]
    }

    // (Every pass that decodes — removing repeated frames, rebuilding or
    // balancing the sound — is built by MediaRepairRecipe.ffmpegArgs:
    // `mpdecimate` drops each stored copy of the previous picture, `fps=`
    // lays the real frames on an even grid at the real rate — their own
    // timestamps decide the slot, so the sound stays in step — and the
    // picture is re-encoded H.264 CRF 16, preset slow.)

    /// One rate-measuring window: decode `seconds` from `start`, keep only
    /// changed pictures, print each kept frame's time (showinfo → stderr).
    static func rateSampleArgs(input: String, start: Double, seconds: Double) -> [String] {
        ["-hide_banner", "-nostdin",
         "-ss", String(format: "%.3f", start), "-t", String(format: "%.3f", seconds),
         "-i", input,
         "-map", "0:v:0", "-vf", "mpdecimate,showinfo", "-fps_mode", "vfr",
         "-f", "null", "-"]
    }

    /// The kept frame's time from a showinfo line ("… pts_time:1.2345 …").
    static func keptFrameTime(fromShowinfoLine line: String) -> Double? {
        guard line.contains("Parsed_showinfo"), let r = line.range(of: "pts_time:") else { return nil }
        let digits = line[r.upperBound...].prefix { $0.isNumber || $0 == "." || $0 == "-" }
        return Double(digits)
    }

    /// ffprobe: the streams' identity (small JSON, header only).
    static func streamHeaderArgs(input: String) -> [String] {
        ["-v", "error",
         "-show_entries", "stream=index,codec_type,codec_name,time_base,sample_rate",
         "-of", "json", input]
    }

    /// ffprobe: each stream's kind and codec, and the container's length
    /// (header only) — the proof for a pass that re-encodes.
    static func summaryArgs(input: String) -> [String] {
        ["-v", "error",
         "-show_entries", "format=duration:stream=index,codec_type,codec_name",
         "-of", "json", input]
    }

    /// ffprobe: one line per packet, "stream_index,size,duration" (no
    /// decode; the whole file is read once). Field order is the order
    /// ffprobe prints packet fields in, pinned by a test on real output.
    static func packetCensusArgs(input: String) -> [String] {
        ["-v", "error",
         "-show_entries", "packet=stream_index,size,duration",
         "-of", "csv=p=0", input]
    }
}

// MARK: - The real frame rate

/// Estimates the footage's real frame rate from the times of the frames
/// `mpdecimate` keeps. A repeated-frame file stores each real picture many
/// times; the kept frames' spacing is the real frame period — except
/// where a real picture didn't change much and was dropped too, which
/// makes some gaps 2–3× longer. So: the SHORTEST spacing that is common
/// (≥ 20 % of all gaps within ±15 % of it), its median, then snapped to a
/// camera rate when within 6 %.
enum RepeatedFrameRate {

    static let cameraRates: [Double] = [23.976, 24, 25, 29.97, 30, 48, 50, 59.94, 60]
    static let windowSeconds = 4.0
    static let minimumGaps = 8
    static let clusterShare = 0.20
    static let clusterTolerance = 0.15
    static let snapTolerance = 0.06
    static let believable: ClosedRange<Double> = 1...120

    /// `windows`: the kept frames' times, one array per sampled window.
    /// nil = no believable rate (too few frames, or an absurd answer).
    static func estimate(windows: [[Double]]) -> Double? {
        let gaps = windows.flatMap { times -> [Double] in
            let t = times.sorted()
            return zip(t, t.dropFirst()).map { $1 - $0 }.filter { $0 > 1e-6 }
        }.sorted()
        guard gaps.count >= minimumGaps, let period = commonShortestGap(gaps) else { return nil }
        let raw = 1 / period
        guard believable.contains(raw) else { return nil }
        return snapped(raw)
    }

    /// The shortest gap that at least `clusterShare` of all gaps sit near;
    /// the median of that cluster.
    static func commonShortestGap(_ sortedGaps: [Double]) -> Double? {
        let needed = max(2, Int((Double(sortedGaps.count) * clusterShare).rounded(.up)))
        for g in sortedGaps {
            let cluster = sortedGaps.filter { abs($0 - g) <= g * clusterTolerance }
            if cluster.count >= needed { return cluster[cluster.count / 2] }
        }
        return nil
    }

    static func snapped(_ raw: Double) -> Double {
        let nearest = cameraRates.min { abs($0 - raw) < abs($1 - raw) } ?? raw
        if abs(nearest - raw) / nearest <= snapTolerance { return nearest }
        return (raw * 1000).rounded() / 1000
    }

    /// ffmpeg's spelling: NTSC rates as exact fractions.
    static func ffmpegText(_ rate: Double) -> String {
        switch rate {
        case 23.976: return "24000/1001"
        case 29.97: return "30000/1001"
        case 59.94: return "60000/1001"
        default:
            return rate == rate.rounded() ? String(Int(rate)) : String(format: "%.3f", rate)
        }
    }
}

// MARK: - Stream parity (the remux's proof)

/// One stream's packets, counted: what a lossless remux must preserve.
struct MediaStreamTally: Equatable, Sendable {
    var index: Int
    var codecType: String
    var codec: String
    /// Seconds per duration tick (the stream's time base).
    var secondsPerTick: Double
    var sampleRate: Int?
    var packets = 0
    var bytes: Int64 = 0
    var durationTicks: Int64 = 0

    var seconds: Double { Double(durationTicks) * secondsPerTick }
    /// Sound samples (duration × sample rate), when it has a rate.
    var samples: Int64? { sampleRate.map { Int64((seconds * Double($0)).rounded()) } }

    /// "1/48000" → 1/48000. Malformed → 0 (durations then compare as 0).
    static func secondsPerTick(timeBase: String) -> Double {
        let parts = timeBase.split(separator: "/")
        guard parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d > 0 else { return 0 }
        return n / d
    }

    /// Adds one census line ("stream_index,size,duration"). Returns the
    /// stream index it counted, nil for a line it can't read.
    static func parseCensusLine(_ line: String) -> (index: Int, size: Int64, duration: Int64)? {
        let f = line.split(separator: ",", omittingEmptySubsequences: false)
        guard f.count >= 3, let i = Int(f[0]), let size = Int64(f[1]) else { return nil }
        return (i, size, Int64(f[2]) ?? 0)
    }
}

/// One file's streams and length, from the header (no decode).
struct MediaRepairStreamSummary: Equatable, Sendable {
    struct Stream: Equatable, Sendable {
        var codecType: String
        var codec: String
    }
    var streams: [Stream]
    var durationSeconds: Double

    /// The codecs of one kind ("video" / "audio"), in stream order.
    func codecs(_ type: String) -> [String] {
        streams.filter { $0.codecType == type }.map(\.codec)
    }
}

enum MediaRepairParity: Equatable {
    case identical(detail: String)
    case different(reason: String)

    /// Every source stream must reappear, in order, with the same codec,
    /// the same bytes, the same length (± one packet or 50 ms) and — except
    /// raw PCM sound, which a muxer may cut into different-sized packets —
    /// the same packet count.
    static func compare(source: [MediaStreamTally], output: [MediaStreamTally]) -> MediaRepairParity {
        guard source.count == output.count else {
            return .different(reason: "the copy has \(output.count) stream(s), the original \(source.count)")
        }
        for (s, o) in zip(source, output) {
            if let why = difference(s, o) { return .different(reason: "stream \(s.index) (\(s.codecType)): \(why)") }
        }
        return .identical(detail: source.map(describe).joined(separator: " · "))
    }

    static func difference(_ s: MediaStreamTally, _ o: MediaStreamTally) -> String? {
        if s.codecType != o.codecType || s.codec != o.codec { return "\(s.codec) became \(o.codec)" }
        if s.bytes != o.bytes { return "\(s.bytes) bytes became \(o.bytes)" }
        if !s.codec.hasPrefix("pcm_"), s.packets != o.packets { return "\(s.packets) packets became \(o.packets)" }
        let onePacket = s.packets > 0 ? s.seconds / Double(s.packets) : 0
        if abs(s.seconds - o.seconds) > max(0.05, onePacket) {
            return String(format: "%.3f s became %.3f s", s.seconds, o.seconds)
        }
        return nil
    }

    /// The proof for a pass that decodes (repeated frames removed, sound
    /// rebuilt or balanced): nothing packet-identical is expected, so the
    /// copy must keep the picture (H.264 when re-encoded, else the same
    /// codec), keep the sound (all tracks unchanged when copied; the first
    /// one, rewritten, otherwise — PCM for a rebuild) and keep its length
    /// (± 1 s or 1 %).
    static func compareRewritten(source: MediaRepairStreamSummary, output: MediaRepairStreamSummary,
                                 recipe: MediaRepairRecipe) -> MediaRepairParity {
        if let why = pictureDifference(source, output, recipe) ?? soundDifference(source, output, recipe) {
            return .different(reason: why)
        }
        let tolerance = max(1.0, source.durationSeconds * 0.01)
        if source.durationSeconds > 0, abs(output.durationSeconds - source.durationSeconds) > tolerance {
            return .different(reason: String(format: "the copy runs %.1f s, the original %.1f s",
                                             output.durationSeconds, source.durationSeconds))
        }
        let parts = output.streams.map { "\($0.codecType) \($0.codec)" }
        return .identical(detail: parts.joined(separator: " · ")
                          + String(format: " · %.1f s, same length as the original", output.durationSeconds))
    }

    private static func pictureDifference(_ s: MediaRepairStreamSummary, _ o: MediaRepairStreamSummary,
                                          _ recipe: MediaRepairRecipe) -> String? {
        guard let srcVideo = s.codecs("video").first else { return nil }
        let outVideo = o.codecs("video")
        guard outVideo.count == 1 else { return "the copy has \(outVideo.count) picture streams, expected 1" }
        let expected = recipe.picture == .removeRepeatedFrames ? "h264" : srcVideo
        return outVideo[0] == expected ? nil : "the picture is \(outVideo[0]), expected \(expected)"
    }

    private static func soundDifference(_ s: MediaRepairStreamSummary, _ o: MediaRepairStreamSummary,
                                        _ recipe: MediaRepairRecipe) -> String? {
        let src = s.codecs("audio"), out = o.codecs("audio")
        switch recipe.sound {
        case .copy:
            return src == out ? nil : "the sound tracks changed (\(src.joined(separator: ", ")) became \(out.joined(separator: ", ")))"
        case .rebuild, .balance:
            let expectedCount = min(src.count, 1)
            guard out.count == expectedCount else { return "the copy has \(out.count) sound tracks, expected \(expectedCount)" }
            if recipe.sound == .rebuild, let codec = out.first, codec != RebuildAudioFix.outputAudioCodec {
                return "the rebuilt sound is \(codec), expected \(RebuildAudioFix.outputAudioCodec)"
            }
            return nil
        }
    }

    static func describe(_ t: MediaStreamTally) -> String {
        if t.codecType == "video" { return "\(t.codec) \(VerifyVideoRules.groupedInt(t.packets)) frames" }
        if let samples = t.samples, t.codecType == "audio" {
            return "\(t.codec) \(VerifyVideoRules.groupedInt(Int(samples))) samples"
        }
        return "\(t.codec) \(VerifyVideoRules.groupedInt(t.packets)) packets"
    }
}
