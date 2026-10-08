// MediaFacts.swift (VideoScanCore)
// Everything ffprobe's header pass knows about a media file, per stream —
// the one facts model Get Media Info shows and Check Media's rules read
// (Rick 2026-10-07). PURE: built from ffprobe JSON by `MediaFacts.parse`;
// no I/O here, so every number is table-testable with canned JSON.
//
// Unknowns stay unknown: nil / "" mean "ffprobe didn't say", never zero
// pretending to be a measurement.
//
// Design: docs/design/check_media_and_menu_cleanup_2026_10_07.md

import Foundation

/// One stream's facts.
public struct MediaStreamFacts: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        case video, audio, subtitle, data, attachment, other
    }

    public var index: Int
    public var kind: Kind
    public var codec: String = ""
    public var codecLongName: String = ""
    public var profile: String = ""
    /// Cover art / thumbnail — an mp3's album art is not a picture track.
    public var isAttachedPicture = false
    public var timeBase: String = ""
    public var startTimeSeconds: Double?
    public var durationSeconds: Double?
    /// Duration in `timeBase` ticks (for audio = the sample count when the
    /// time base is 1/sample_rate).
    public var durationTicks: Int64?
    public var bitRate: Int64?
    /// nb_frames — nil when the container doesn't record it (Matroska).
    public var frameCount: Int?
    public var creationTime: String = ""

    // Picture
    public var width: Int?
    public var height: Int?
    public var sampleAspectRatio: String = ""
    public var displayAspectRatio: String = ""
    public var pixelFormat: String = ""
    public var fieldOrder: String = ""
    /// Raw "90000/1" strings plus their parsed values (0 = unknown).
    public var rFrameRateText: String = ""
    public var avgFrameRateText: String = ""
    public var bitsPerRawSample: Int?

    // Sound
    public var sampleRate: Int?
    public var channels: Int?
    public var channelLayout: String = ""
    public var sampleFormat: String = ""
    public var bitsPerSample: Int?
    /// Start timecode tag (tmcd tracks, some video streams); "" when none.
    public var timecode: String = ""
    /// The picture's colour labels (2026-10-07; all "" when unlabelled).
    public var colour = MediaColourLabels()

    public var id: Int { index }

    public init(index: Int, kind: Kind) {
        self.index = index
        self.kind = kind
    }

    public var rFrameRate: Double { MediaFacts.parseRate(rFrameRateText) }
    public var avgFrameRate: Double { MediaFacts.parseRate(avgFrameRateText) }

    /// Sample count when ffprobe gives one: duration ticks in a 1/rate
    /// time base. nil otherwise (never guessed).
    public var sampleCount: Int64? {
        guard kind == .audio, let rate = sampleRate, rate > 0,
              let ticks = durationTicks, timeBase == "1/\(rate)" else { return nil }
        return ticks
    }

    /// Bit depth in plain terms: the raw sample size when known, else the
    /// sample format's size (s16 → 16, s32/flt → 32), else nil.
    public var bitDepth: Int? {
        if let b = bitsPerRawSample, b > 0 { return b }
        if let b = bitsPerSample, b > 0 { return b }
        switch sampleFormat.replacingOccurrences(of: "p", with: "") {
        case "u8": return 8
        case "s16": return 16
        case "s32", "flt": return 32
        case "s64", "dbl": return 64
        default: return nil
        }
    }
}

/// The container plus its streams.
public struct MediaFacts: Sendable, Equatable {
    public var formatName: String = ""
    public var formatLongName: String = ""
    public var durationSeconds: Double?
    public var startTimeSeconds: Double?
    public var sizeBytes: Int64?
    /// The container's own bit_rate field (bits/s).
    public var bitRate: Int64?
    public var encoder: String = ""
    public var creationTime: String = ""
    /// The container's start timecode tag ("01:00:00:00"), "" when none.
    public var timecode: String = ""
    public var streams: [MediaStreamFacts] = []

    public init() {}

    /// First real picture stream (attached pictures excluded).
    public var video: MediaStreamFacts? {
        streams.first { $0.kind == .video && !$0.isAttachedPicture }
    }
    public var audio: MediaStreamFacts? {
        streams.first { $0.kind == .audio }
    }
    public var audioStreams: [MediaStreamFacts] { streams.filter { $0.kind == .audio } }

    /// size × 8 ÷ duration — what the file actually spends per second.
    public var impliedBitRate: Int64? {
        guard let size = sizeBytes, size > 0, let d = durationSeconds, d > 0 else { return nil }
        return Int64(Double(size) * 8 / d)
    }

    // MARK: Parsing (pure)

    /// "30000/1001" → 29.97; "0/0" → 0; "25" → 25; garbage → 0.
    public static func parseRate(_ s: String) -> Double {
        let parts = s.split(separator: "/")
        if parts.count == 2 {
            guard let n = Double(parts[0]), let d = Double(parts[1]), d != 0 else { return 0 }
            return n / d
        }
        return Double(s) ?? 0
    }

    /// The ffprobe `-show_entries` list that fills every field here (the
    /// probe passes it verbatim; pinned by tests).
    public static let probeEntries =
        "stream=index,codec_type,codec_name,codec_long_name,profile,width,height,"
        + "sample_aspect_ratio,display_aspect_ratio,pix_fmt,field_order,r_frame_rate,"
        + "avg_frame_rate,nb_frames,time_base,start_time,duration,duration_ts,bit_rate,"
        + "sample_rate,channels,channel_layout,sample_fmt,bits_per_sample,bits_per_raw_sample,"
        + "color_range,color_space,color_transfer,color_primaries"
        + ":stream_disposition=attached_pic:stream_tags=creation_time,timecode"
        + ":format=format_name,format_long_name,duration,size,bit_rate,start_time"
        + ":format_tags=encoder,creation_time,timecode"

    public enum ParseError: Error, Equatable { case unreadable }

    /// ffprobe JSON → facts. Throws only when the JSON itself is unreadable.
    public static func parse(probeJSON data: Data) throws -> MediaFacts {
        guard let report = try? JSONDecoder().decode(Report.self, from: data) else {
            throw ParseError.unreadable
        }
        var f = MediaFacts()
        if let fmt = report.format {
            f.formatName = fmt.format_name ?? ""
            f.formatLongName = fmt.format_long_name ?? ""
            f.durationSeconds = fmt.duration.flatMap(Double.init)
            f.startTimeSeconds = fmt.start_time.flatMap(Double.init)
            f.sizeBytes = fmt.size.flatMap { Int64($0) }
            f.bitRate = fmt.bit_rate.flatMap { Int64($0) }
            f.encoder = fmt.tags?["encoder"] ?? ""
            f.creationTime = fmt.tags?["creation_time"] ?? ""
            f.timecode = fmt.tags?["timecode"] ?? ""
        }
        f.streams = (report.streams ?? []).enumerated().map { offset, s in
            stream(from: s, fallbackIndex: offset)
        }
        return f
    }

    private static func stream(from s: Report.Stream, fallbackIndex: Int) -> MediaStreamFacts {
        let kind = MediaStreamFacts.Kind(rawValue: s.codec_type ?? "") ?? .other
        var m = MediaStreamFacts(index: s.index ?? fallbackIndex, kind: kind)
        m.codec = s.codec_name ?? ""
        m.codecLongName = s.codec_long_name ?? ""
        m.profile = s.profile ?? ""
        m.isAttachedPicture = (s.disposition?.attached_pic ?? 0) != 0
        m.timeBase = s.time_base ?? ""
        m.startTimeSeconds = s.start_time.flatMap(Double.init)
        m.durationSeconds = s.duration.flatMap(Double.init)
        m.durationTicks = s.duration_ts
        m.bitRate = s.bit_rate.flatMap { Int64($0) }
        m.frameCount = s.nb_frames.flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil }
        m.creationTime = s.tags?["creation_time"] ?? ""
        m.timecode = s.tags?["timecode"] ?? ""
        m.colour = MediaColourLabels(range: s.color_range, matrix: s.color_space,
                                     transfer: s.color_transfer, primaries: s.color_primaries)
        m.width = s.width
        m.height = s.height
        m.sampleAspectRatio = s.sample_aspect_ratio ?? ""
        m.displayAspectRatio = s.display_aspect_ratio ?? ""
        m.pixelFormat = s.pix_fmt ?? ""
        m.fieldOrder = s.field_order ?? ""
        m.rFrameRateText = s.r_frame_rate ?? ""
        m.avgFrameRateText = s.avg_frame_rate ?? ""
        m.bitsPerRawSample = s.bits_per_raw_sample.flatMap { Int($0) }
        m.sampleRate = s.sample_rate.flatMap { Int($0) }
        m.channels = s.channels
        m.channelLayout = s.channel_layout ?? ""
        m.sampleFormat = s.sample_fmt ?? ""
        m.bitsPerSample = s.bits_per_sample
        return m
    }

    /// ffprobe's JSON shape (strings where ffprobe writes strings).
    private struct Report: Decodable {
        struct Disposition: Decodable { let attached_pic: Int? }
        struct Stream: Decodable {
            let index: Int?
            let codec_type: String?
            let codec_name: String?
            let codec_long_name: String?
            let profile: String?
            let width: Int?
            let height: Int?
            let sample_aspect_ratio: String?
            let display_aspect_ratio: String?
            let pix_fmt: String?
            let field_order: String?
            let r_frame_rate: String?
            let avg_frame_rate: String?
            let nb_frames: String?
            let time_base: String?
            let start_time: String?
            let duration: String?
            let duration_ts: Int64?
            let bit_rate: String?
            let sample_rate: String?
            let channels: Int?
            let channel_layout: String?
            let sample_fmt: String?
            let bits_per_sample: Int?
            let bits_per_raw_sample: String?
            let color_range: String?
            let color_space: String?
            let color_transfer: String?
            let color_primaries: String?
            let disposition: Disposition?
            let tags: [String: String]?
        }
        struct Format: Decodable {
            let format_name: String?
            let format_long_name: String?
            let duration: String?
            let start_time: String?
            let size: String?
            let bit_rate: String?
            let tags: [String: String]?
        }
        let streams: [Stream]?
        let format: Format?
    }
}
