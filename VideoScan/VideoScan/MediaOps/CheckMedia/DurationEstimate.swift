import Foundation
import VideoScanCore

// MARK: - Check Media — how long a file with no recorded length runs (Rick 2026-10-21)
//
// Raw elementary streams — .m2v, recovered "raw MPEG video" fragments with
// numbered extensions (.023, .995), raw ADTS AAC — have no container header,
// so ffprobe reports no duration and the catalog says 0. Rick decides
// whether such a file is worth rescuing by its length: under a minute or two
// is of dubious value; forty minutes of possibly unique footage is worth it.
//
// The full check's packet census already lists EVERY packet of the picture
// and of the sound (CheckMediaProbe+Census), so counting costs no extra read
// of the file:
//   picture: packets ÷ r_frame_rate (avg_frame_rate when r is 0/0)
//   sound:   packets × samples per packet (by codec) ÷ sample_rate
//
// Pure (no I/O): MediaFacts + the census report in, a value out. The job
// keeps it on the job's item and shows it right under the card's headline.
// Display only — never written to the catalog.
//
// Known limits, both of which make the estimate SHORT, never long (hence
// "about"): MPEG-2 film content with 3:2 pulldown stores 24 pictures per
// 30 labelled frames; HE-AAC (SBR) plays 2,048 samples per packet where
// plain AAC plays 1,024.
//
// Memory: a few words per file.

/// How long a file whose header records no duration really runs.
/// (An enum with associated values ≈ a C++ std::variant<Counted, Unknown>.)
enum DurationEstimate: Sendable, Equatable {

    /// What was counted.
    enum Source: Sendable, Equatable {
        /// Picture packets ÷ frame rate.
        case frames
        /// Sound packets × samples per packet ÷ sample rate.
        case audioPackets
    }

    case counted(seconds: Double, source: Source)
    /// Nothing usable could be counted (the listing failed, no rate, an
    /// unknown sound codec) — said plainly, never a guessed number.
    case unknown

    /// nil when the header records a length (there is nothing to
    /// estimate). Otherwise the count, or `.unknown` — a failed or missing
    /// census is "unknown", never a crash and never zero.
    static func make(facts: MediaFacts,
                     census: Result<PacketCensusReport, CheckMediaSkip>?) -> DurationEstimate? {
        guard !hasRecordedDuration(facts) else { return nil }
        // `guard case` ≈ C++ early-return unless the variant holds this alternative.
        guard case .success(let c)? = census else { return .unknown }
        if let s = pictureSeconds(packets: c.picturePackets, stream: facts.video) {
            return .counted(seconds: s, source: .frames)
        }
        if let s = soundSeconds(packets: c.soundPackets, stream: facts.audio) {
            return .counted(seconds: s, source: .audioPackets)
        }
        return .unknown
    }

    /// The container or any stream records a positive duration.
    static func hasRecordedDuration(_ facts: MediaFacts) -> Bool {
        ([facts.durationSeconds] + facts.streams.map(\.durationSeconds))
            .contains { ($0 ?? 0) > 0 }
    }

    /// r_frame_rate, else avg_frame_rate; nil when both are 0/0. (A raw
    /// .m2v can report avg 25/1 beside the true r 30000/1001 — r first.)
    static func framesPerSecond(_ stream: MediaStreamFacts) -> Double? {
        [stream.rFrameRate, stream.avgFrameRate].first { $0.isFinite && $0 > 0 }
    }

    static func pictureSeconds(packets: Int, stream: MediaStreamFacts?) -> Double? {
        guard packets > 0, let stream, let fps = framesPerSecond(stream) else { return nil }
        return Double(packets) / fps
    }

    /// Samples one packet plays, by ffprobe codec name. Data, not a switch:
    /// a new codec is one line.
    static let samplesPerPacket: [String: Int] = [
        "aac": 1_024, "mp2": 1_152, "mp3": 1_152, "ac3": 1_536, "eac3": 1_536,
    ]

    static func soundSeconds(packets: Int, stream: MediaStreamFacts?) -> Double? {
        guard packets > 0, let stream, let rate = stream.sampleRate, rate > 0,
              let perPacket = samplesPerPacket[stream.codec] else { return nil }
        return Double(packets) * Double(perPacket) / Double(rate)
    }

    /// "about 1 h 5 min" / "about 45 min 55 s" / "about 42 s" /
    /// "under a second".
    static func aboutText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "an unknown length" }
        let total = Int(seconds.rounded())
        guard total >= 1 else { return "under a second" }
        let (h, m, s) = (total / 3_600, (total % 3_600) / 60, total % 60)
        if h > 0 { return "about \(h) h \(m) min" }
        if m > 0 { return "about \(m) min \(s) s" }
        return "about \(s) s"
    }

    static let unknownSentence = "duration unknown — no header to read it from"

    /// The line under the headline:
    /// "about 45 min 55 s of video (counted from frames)".
    var sentence: String {
        switch self {
        case .counted(let seconds, .frames):
            return "\(Self.aboutText(seconds)) of video (counted from frames)"
        case .counted(let seconds, .audioPackets):
            return "\(Self.aboutText(seconds)) of sound (counted from audio packets)"
        case .unknown:
            return Self.unknownSentence
        }
    }
}
