import Foundation

// MARK: - Balance Audio: a lossless copy must PLAY all the sound it STORES
//
// GH #482. The pure half of the job's post-render check (the job runs the
// one ffprobe header read and refuses on a breach: BalanceAudioJob's
// `verifySoundIsAllPlayed`). Why the two can differ at all, and the fix that
// stops the job producing such a copy: "Raw-DV sound timestamps" in
// BalanceAudioJob.swift.

extension BalanceAudioFix {

    /// How many samples a lossless copy may store beyond what its header
    /// says it plays: one, plus ffprobe's six-decimal rounding.
    static let unplayedSoundToleranceSamples = 1.5

    /// Post-render rule: a LOSSLESS balanced copy in the QuickTime family
    /// must play all the sound it stores. `storedSamples` = the samples the
    /// track's own sample table holds (ffprobe `nb_frames`: for PCM in
    /// QuickTime every sample is one entry) — NOT the track's stated
    /// length, which the muxer writes from the same timestamps as the edit
    /// list; `playedSeconds` = the length its header states with the edit
    /// list applied. nil = acceptable, or not this rule's (lossy codecs keep
    /// encoder priming outside the edit list by design; a container with no
    /// sample table to count); non-nil = the breach, in plain words. Pure.
    static func unplayedSoundMismatch(codec: String, sampleRateHz: Int,
                                      storedSamples: Int64?, playedSeconds: Double?) -> String? {
        guard codec.lowercased().hasPrefix("pcm_"), let storedSamples, let playedSeconds else { return nil }
        let hidden = Double(storedSamples) - playedSeconds * Double(sampleRateHz)
        guard sampleRateHz > 0, storedSamples >= 0, hidden.isFinite else {
            return "the balanced copy's stored and played sound lengths could not be read"
        }
        guard hidden > unplayedSoundToleranceSamples else { return nil }
        let samples = hidden < 1e15 ? String(Int64(hidden.rounded())) : "more than 10^15"
        return "the balanced copy would not play all the sound it stores (\(samples) samples, "
            + String(format: "%.1f ms", hidden / Double(sampleRateHz) * 1000) + ", are outside its edit list)"
    }

    /// ffprobe request for `unplayedSoundMismatch`: each sound track's
    /// codec, rate, stated length and sample-table count, and the container.
    static func soundLengthArgs(input: String) -> [String] {
        ["-v", "error", "-select_streams", "a",
         "-show_entries", "stream=codec_name,sample_rate,duration,nb_frames:format=format_name", "-of", "json", input]
    }

    /// One sound track as `soundLengthArgs` reports it.
    struct SoundLength: Equatable {
        var codec: String
        var sampleRateHz: Int
        /// nil = the container states none.
        var playedSeconds: Double?
        /// nil = no sample table to count (not the QuickTime family), or unstated.
        var storedSamples: Int64?
    }

    /// Parse `soundLengthArgs`' JSON. nil = not that document. The stored
    /// count is read only for the QuickTime family ("mov" among the
    /// container's names): elsewhere `nb_frames` counts packets, not samples.
    static func soundLengths(fromProbeJSON data: Data) -> [SoundLength]? {
        struct Stream: Decodable {
            let codec_name: String?
            let sample_rate: String?
            let duration: String?
            let nb_frames: String?
        }
        struct Format: Decodable { let format_name: String? }
        struct Report: Decodable {
            let streams: [Stream]?
            let format: Format?
        }
        guard let report = try? JSONDecoder().decode(Report.self, from: data), let streams = report.streams else { return nil }
        let quickTime = (report.format?.format_name ?? "").split(separator: ",").contains("mov")
        return streams.map {
            SoundLength(codec: $0.codec_name ?? "", sampleRateHz: $0.sample_rate.flatMap { Int($0) } ?? 0,
                        playedSeconds: $0.duration.flatMap { Double($0) },
                        storedSamples: quickTime ? $0.nb_frames.flatMap { Int64($0) } : nil)
        }
    }
}
