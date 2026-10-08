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
         "-map", "0", "-c", "copy", "-map_metadata", "0", "-map_chapters", "0",
         "-progress", "pipe:2",
         output]
    }

    // (Every pass that decodes — removing repeated frames, rebuilding or
    // balancing the sound — is built by MediaRepairRecipe.ffmpegArgs, the
    // picture's encoder half by MediaRepairPicturePlan.encodeArgs.)

    /// Where the sampled decode looks: the start, 25 / 50 / 75 %, the end.
    static func sampleWindowStarts(durationSeconds d: Double) -> [Double] {
        guard d > sampleWindowSeconds * 2 else { return [0] }
        let last = max(0, d - sampleWindowSeconds)
        return [0, d * 0.25, d * 0.5, d * 0.75, last]
    }

    static let sampleWindowSeconds = 2.0

    /// Decode one window of every stream, report only errors.
    static func sampledDecodeArgs(input: String, start: Double) -> [String] {
        ["-hide_banner", "-nostdin", "-v", "error",
         "-ss", String(format: "%.3f", start), "-t", String(format: "%.3f", sampleWindowSeconds),
         "-i", input, "-map", "0:v?", "-map", "0:a?", "-f", "null", "-"]
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
         "-show_entries", "format=duration:stream=index,codec_type,codec_name,pix_fmt,r_frame_rate,avg_frame_rate,"
         + "color_primaries,color_transfer,color_space,color_range,sample_aspect_ratio,field_order",
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
    /// The first picture stream's facts (nil = no picture).
    var picture: MediaRepairPictureFacts?

    init(streams: [Stream], durationSeconds: Double, picture: MediaRepairPictureFacts? = nil) {
        self.streams = streams
        self.durationSeconds = durationSeconds
        self.picture = picture
    }

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
                                 recipe: MediaRepairRecipe, picture plan: MediaRepairPicturePlan?) -> MediaRepairParity {
        if let why = pictureDifference(source, output, recipe, plan) ?? soundDifference(source, output, recipe) {
            return .different(reason: why)
        }
        if let why = lengthDifference(source, output, retimed: recipe.picture == .removeRepeatedFrames) {
            return .different(reason: why)
        }
        let parts = output.streams.map { "\($0.codecType) \($0.codec)" }
        let length = recipe.picture == .removeRepeatedFrames
            ? String(format: " · %.1f s (shorter by design: repeats removed)", output.durationSeconds)
            : String(format: " · %.1f s, same length as the original", output.durationSeconds)
        return .identical(detail: parts.joined(separator: " · ") + length)
    }

    /// Same length (± 1 s or 1 %) — or, when the picture was re-timed on
    /// purpose, a real length no longer than the original's.
    private static func lengthDifference(_ s: MediaRepairStreamSummary, _ o: MediaRepairStreamSummary,
                                         retimed: Bool) -> String? {
        let tolerance = max(1.0, s.durationSeconds * 0.01)
        guard o.durationSeconds > 0 else { return "the copy has no length" }
        guard s.durationSeconds > 0 else { return nil }
        let off = retimed ? o.durationSeconds - s.durationSeconds : abs(o.durationSeconds - s.durationSeconds)
        guard off > tolerance else { return nil }
        return String(format: "the copy runs %.1f s, the original %.1f s", o.durationSeconds, s.durationSeconds)
    }

    private static func pictureDifference(_ s: MediaRepairStreamSummary, _ o: MediaRepairStreamSummary,
                                          _ recipe: MediaRepairRecipe, _ plan: MediaRepairPicturePlan?) -> String? {
        guard let srcVideo = s.codecs("video").first else { return nil }
        let outVideo = o.codecs("video")
        guard outVideo.count == 1 else { return "the copy has \(outVideo.count) picture streams, expected 1" }
        guard recipe.picture == .removeRepeatedFrames else {
            return outVideo[0] == srcVideo ? nil : "the picture is \(outVideo[0]), expected \(srcVideo)"
        }
        guard let plan, let facts = o.picture else { return "the re-encoded picture couldn't be checked" }
        return plan.mismatch(output: facts)
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
            if recipe.sound == .rebuild, let codec = out.first, codec != MediaRepairRecipe.rebuiltSoundCodec {
                return "the rebuilt sound is \(codec), expected \(MediaRepairRecipe.rebuiltSoundCodec)"
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
