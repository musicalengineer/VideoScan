// TechnicalReading.swift (VideoScanCore/Dossier) — layer 1 of the file
// dossier (docs/design/file_dossier_view.md §4): what the stored probe facts
// SUGGEST, one line each, ported from tools/dossier-demo/dossier_demo.py's
// `interpret`, `one_liner` and `classify_creation_time` so the script and the
// app say the same thing.
//
// Only the rules whose inputs the catalog stores are ported. The demo reads
// ffprobe and mediainfo live; the catalog keeps container, codecs, frame size,
// frame rate, field order, the first audio stream's rate and channels, the
// encoder / make / model tags, the sane embedded creation date, duration, the
// total bit rate and the file-system dates (`files` columns + `probe_extra`).
// Not stored, so not read (the demo's rows for them are absent here): pixel
// and display aspect, average frame rate (VFR), codec profile, audio bit
// depth, mediainfo's measured scan / standard / recorded date, GPS.
//
// Rule 1 (a partial field is never the whole): the scan keeps ONE video
// stream (the first that is not cover art) and ONE audio stream (the first);
// a consumer DV tape's second stereo pair is not in the catalog. So every
// line read from a stream names it — source "ffprobe (first video stream)" /
// "(first audio stream)", and the audio value starts "first audio stream:" —
// and the 32 kHz DV rule names a MODE, never a counted 4 channels.
//
// Pure: facts in, lines out; `now` is injected so every date rule is
// table-testable. Never reads a file, never runs a tool.
//
// (For Rick: the demo's `static const std::map`s and free functions, in one
// namespace; `TechnicalFacts` is the POD the rules read.)

import Foundation

/// The stored facts layer 1 reads, in the demo's vocabulary.
public struct TechnicalFacts: Sendable, Equatable {
    /// The demo's container key ("mov", "mp4", "dv", "avi", "mxf", "matroska", …), nil when unknown.
    public var container: String?
    /// The container as the catalog stores it (ffprobe's long name), for the line's value.
    public var containerName: String?
    public var hasVideo: Bool
    /// ffprobe codec_name, lowercased ("dvvideo", "prores", "h264").
    public var codec: String?
    public var width: Int?
    public var height: Int?
    public var fps: Double?
    /// ffprobe field_order: "tt" / "bb" / "tb" / "bt" / "progressive" / "unknown".
    public var fieldOrder: String?
    public var audioCodec: String?
    public var audioRate: Int?
    /// The FIRST audio stream's channels — the catalog keeps one stream, so
    /// this is never the file's total (a DV tape's second pair is not here).
    public var audioChannels: Int?
    public var encoder: String?
    public var make: String?
    public var model: String?
    /// The embedded creation date the scan accepted (EmbeddedDateSanity).
    public var creationTime: Date?
    /// Which tag it came from ("format:creation_time", "quicktime:com.apple.quicktime.creationdate", …).
    public var creationSource: String?
    public var duration: Double?
    /// Bits per second.
    public var bitRate: Double?
    /// The file system's modification date.
    public var modified: Date?

    public init(container: String? = nil, containerName: String? = nil, hasVideo: Bool = true, codec: String? = nil,
                width: Int? = nil, height: Int? = nil, fps: Double? = nil, fieldOrder: String? = nil,
                audioCodec: String? = nil, audioRate: Int? = nil, audioChannels: Int? = nil,
                encoder: String? = nil, make: String? = nil, model: String? = nil,
                creationTime: Date? = nil, creationSource: String? = nil,
                duration: Double? = nil, bitRate: Double? = nil, modified: Date? = nil) {
        self.container = container
        self.containerName = containerName
        self.hasVideo = hasVideo
        self.codec = codec?.lowercased()
        self.width = width
        self.height = height
        self.fps = fps
        self.fieldOrder = fieldOrder
        self.audioCodec = audioCodec
        self.audioRate = audioRate
        self.audioChannels = audioChannels
        self.encoder = encoder
        self.make = make
        self.model = model
        self.creationTime = creationTime
        self.creationSource = creationSource
        self.duration = duration
        self.bitRate = bitRate
        self.modified = modified
    }

    /// The Apple camera tag (`com.apple.quicktime.creationdate`) wrote the date.
    public var appleCreationDate: Bool { creationSource?.contains("com.apple.quicktime.creationdate") == true }
}

/// One layer-1 line: what was read, and what it suggests.
public struct TechnicalReadingLine: Sendable, Equatable {
    public var label: String
    public var value: String
    public var suggests: String
    /// Who read it, in words ("ffprobe", "file system", "embedded tag").
    public var source: String
    /// The line's value is itself an inference (a camera tag's date read as
    /// the recording date), never a stored fact.
    public var isInference: Bool

    public init(label: String, value: String, suggests: String, source: String, isInference: Bool = false) {
        self.label = label
        self.value = value
        self.suggests = suggests
        self.source = source
        self.isInference = isInference
    }
}

public enum TechnicalReading {

    /// Sources for lines read from one stream (rule 1: say which).
    public static let firstVideoStream = "ffprobe (first video stream)"
    public static let firstAudioStream = "ffprobe (first audio stream)"

    // MARK: Vocabulary (the demo's tables, verbatim)

    public static let transferCodecs: [String: String] = [
        "prores": "ProRes", "ffv1": "FFV1", "dnxhd": "DNxHD", "v210": "uncompressed 10-bit",
        "rawvideo": "uncompressed", "huffyuv": "HuffYUV", "utvideo": "Ut Video", "qtrle": "QuickTime Animation",
    ]

    static let codecWords: [String: String] = [
        "dvvideo": "DV: a MiniDV/Digital8 camcorder tape, or an analog tape through a DV bridge; carrier floor 1995",
        "mjpeg": "Motion JPEG: a late-1990s/2000s digital still camera's movie mode, or an analog capture card",
        "mpeg2video": "MPEG-2: DVD, a DVD camcorder or HDV (1996 onward)",
        "mpeg4": "MPEG-4 Part 2 (DivX/XviD, early digicams): 2000s",
        "h263": "H.263: early phone / web video, late 1990s–2000s",
        "svq3": "Sorenson Video 3: an early QuickTime export (2001–2006)",
        "svq1": "Sorenson Video 1: an early QuickTime export (late 1990s)",
        "h264": "H.264/AVC: 2004 onward (cameras, phones, exports); alone it does not date the footage",
        "hevc": "HEVC/H.265: 2013 onward; on an iPhone, 2017 onward",
        "wmv3": "Windows Media 9: a 2000s Windows export", "wmv2": "Windows Media 8: a 2000s Windows export",
        "vp6f": "VP6 Flash video: a 2000s web download", "msmpeg4v3": "DivX ;-) era MPEG-4: late 1990s–2000s",
        "rpza": "Apple Video (road pizza): early-1990s QuickTime", "cinepak": "Cinepak: early-1990s CD-ROM video",
        "gif": "an animated GIF, not a camera video",
    ]

    static let containerWords: [String: String] = [
        "dv": "raw DV stream: a direct FireWire capture from a camcorder or deck",
        "mov": "QuickTime wrapper: names the tool family (Apple, Final Cut, iMovie, a capture app), not the footage's age",
        "mp4": "MP4: a camera, a phone or an export (2001 onward)",
        "avi": "AVI: Windows-era capture or export (1990s–2000s tools)",
        "mxf": "MXF: a broadcast/NLE (Avid) wrapper: an edit-suite capture",
        "matroska": "Matroska: a modern archival transfer (usually FFV1)",
        "mpeg": "MPEG program stream: a DVD rip or a DVD camcorder",
        "mpegts": "MPEG transport stream: AVCHD or HDV camcorder",
        "3gp": "3GP: an early mobile phone (2003–2010)",
        "asf": "ASF/WMV: a 2000s Windows export",
        "flv": "Flash video: a 2000s web download",
    ]

    // MARK: Facts from the stored columns

    /// The demo's container key from the stored long name and the file's
    /// extension (ffprobe names the whole ISO-BMFF family "QuickTime / MOV").
    public static func containerKey(container: String, ext: String) -> String? {
        let c = container.lowercased(), e = ext.lowercased()
        if ["mp4", "m4v"].contains(e) { return "mp4" }
        if e == "3gp" { return "3gp" }
        let table: [(String, String)] = [("quicktime", "mov"), ("dv (", "dv"), ("mxf", "mxf"), ("avi", "avi"), ("matroska", "matroska"),
                                         ("mpeg-ts", "mpegts"), ("mpegts", "mpegts"), ("mpeg-ps", "mpeg"), ("raw mpeg", "mpeg"),
                                         ("asf", "asf"), ("flv", "flv")]
        for (needle, key) in table where c.contains(needle) { return key }
        if c == "dv" || c.hasPrefix("dv ") { return "dv" }
        return c.isEmpty ? nil : c
    }

    /// "720x480" → (720, 480); nil unless two positive integers.
    public static func frameSize(_ text: String) -> (Int, Int)? {
        let parts = text.lowercased().split(separator: "x")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 else { return nil }
        return (w, h)
    }

    /// "29.97", "30000/1001" → 29.97; nil for junk, "0/0" or an absurd rate.
    public static func rate(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces)
        let value: Double?
        if let slash = t.firstIndex(of: "/") {
            guard let n = Double(t[..<slash]), let d = Double(t[t.index(after: slash)...]), d != 0 else { return nil }
            value = n / d
        } else {
            value = Double(t)
        }
        guard let v = value, v > 0, v < 1000 else { return nil }
        return (v * 1000).rounded() / 1000
    }

    /// The leading integer of "48000 Hz", "2", "12345 kbps"; nil otherwise.
    public static func leadingInt(_ text: String) -> Int? {
        Int(text.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber })
    }

    // MARK: The rules

    /// interlaced / progressive from the flagged field order; nil when unknown.
    public static func scan(_ f: TechnicalFacts) -> String? {
        switch f.fieldOrder {
        case "tt", "bb", "tb", "bt": return "interlaced"
        case "progressive": return "progressive"
        default: return nil
        }
    }

    static func fieldOrderWords(_ f: TechnicalFacts) -> String {
        switch f.fieldOrder {
        case "tt", "tb": return "top field first"
        case "bb", "bt": return "bottom field first"
        default: return ""
        }
    }

    public enum CreationKind: String, Sendable, Equatable {
        case none, rejected, transfer, capture, camera, weak
    }

    /// The embedded creation date's meaning, with why. Only `.camera` is a
    /// recording date (a hard date); a transfer codec's stamp is when the
    /// carrier was digitised; a DV stamp is when the DV was copied.
    public static func classifyCreationTime(_ f: TechnicalFacts, now: Date) -> (kind: CreationKind, why: String) {
        guard let raw = f.creationTime else { return (.none, "no embedded creation date") }
        guard let when = EmbeddedDateSanity.accept(raw, now: now) else {
            return (.rejected, "\(day(raw, in: utc)) is a sentinel or impossible date (1904/1970/2000-01-01, pre-1980 or future): not evidence")
        }
        let codec = f.codec ?? ""
        if let name = transferCodecs[codec] {
            return (.transfer, "\(name) files are transfers: \(day(when, in: utc)) is when the carrier was digitised, not when it was shot")
        }
        if codec == "dvvideo" {
            return (.capture, "\(day(when, in: utc)) is when the DV was copied to a computer; the DV clock (below) is the recording date")
        }
        if f.appleCreationDate || f.make != nil || f.model != nil {
            // A make/model tag survives a re-wrap, so this is an inference, never a stated fact.
            return (.camera, "almost certainly the recording date (device tags present); a re-wrap can carry the tags over")
        }
        return (.weak, "\(day(when, in: utc)) could be the camera's clock or an export; no device tag says which, so it is a weak date")
    }

    /// Layer-1 facts → lines, in the demo's order. Pure.
    public static func interpret(_ f: TechnicalFacts, now: Date) -> [TechnicalReadingLine] {
        var rows: [TechnicalReadingLine] = []
        func add(_ label: String, _ value: String, _ suggests: String, _ source: String = "ffprobe") {
            rows.append(TechnicalReadingLine(label: label, value: value, suggests: suggests, source: source))
        }
        if let key = f.container {
            add("Container", f.containerName ?? key, containerWords[key] ?? "a wrapper: bounds the file's era, never the footage's")
        }
        let codec = f.codec ?? ""
        if !codec.isEmpty {
            add("Video codec", codec, transferCodecs[codec].map { "\($0): a lossless/master TRANSFER codec; says nothing about when the footage was shot" }
                ?? codecWords[codec] ?? "camera-native or export codec", firstVideoStream)
        } else if !f.hasVideo {
            add("Video", "none", "no playable video stream: a reference movie, an essence-less MXF or audio only")
        }
        if let w = f.width, let h = f.height { add("Frame size", "\(w)×\(h)", frameSizeWords(w, h, codec: codec), firstVideoStream) }
        if let fps = f.fps { add("Frame rate", fpsText(fps), frameRateWords(fps), firstVideoStream) }
        if let scan = scan(f) {
            let order = fieldOrderWords(f)
            add("Scan", scan + (order.isEmpty ? "" : ", " + order) + " (as flagged)", scanWords(scan, f, codec: codec), firstVideoStream)
        }
        rows += audioRows(f, codec: codec)
        if let enc = f.encoder { add("Encoder / muxer", String(enc.prefix(60)), encoderWords(enc), "embedded tag") }
        if f.make != nil || f.model != nil {
            add("Make / model", [f.make, f.model].compactMap { $0 }.joined(separator: " "),
                "the physical camera: a hardware lineage across years", "embedded tag")
        }
        let (kind, why) = classifyCreationTime(f, now: now)
        if kind != .none, let when = f.creationTime {
            // UTC, labelled — as the inspector's Timestamps ▸ Embedded row shows it.
            rows.append(TechnicalReadingLine(label: "Creation time", value: day(when, in: utc) + " UTC", suggests: why,
                                             source: "embedded tag" + (f.creationSource.map { " (\($0))" } ?? ""),
                                             isInference: kind == .camera))
        }
        if let d = f.duration, d > 0 {
            // An unknown total bit rate is "not recorded", never 0.0 Mb/s.
            let rate = f.bitRate.flatMap { $0 > 0 ? $0 / 1e6 : nil }
            add("Duration / rate", durationWords(d) + (rate.map { String(format: ", %.1f Mb/s", $0) } ?? ", bit rate not recorded"),
                durationRateWords(f, codec: codec, mbps: rate ?? 0))
        }
        if let m = f.modified {
            // A wall-clock event on Rick's Mac: the local day, as the inspector's Modified row.
            add("File modified", day(m), "file-system date: the transfer/copy history only, never the shoot", "file system")
        }
        return rows
    }

    private static func frameSizeWords(_ w: Int, _ h: Int, codec: String) -> String {
        switch (w, h) {
        case (720, 480), (720, 486), (704, 480): return "NTSC standard definition: analog or DV era (North America / Japan)"
        case (720, 576), (704, 576): return "PAL standard definition: a European/PAL-country source"
        case (352, 240), (352, 288): return "VCD resolution: a 1990s Video CD or a low-bit-rate copy"
        case (640, 480), (320, 240), (160, 120): return "VGA-class: a digital still camera / webcam movie mode (late 1990s–2000s)"
        default: break
        }
        if h == 720 || h == 1080 {
            return transferCodecs[codec] != nil ? "HD frame holding a transfer: an SD tape upscaled at capture"
                : "HD: born-digital 2005 onward (AVCHD, HDV, phone)"
        }
        if h >= 2160 { return "4K/UHD: a 2014-onward phone or camera, or a modern film scan" }
        return "an uncommon size: an edit or web export"
    }

    private static func frameRateWords(_ fps: Double) -> String {
        if abs(fps - 29.97) < 0.02 || abs(fps - 59.94) < 0.03 { return "NTSC timing (29.97): North American video" }
        if abs(fps - 25) < 0.01 || abs(fps - 50) < 0.01 { return "PAL timing (25): a PAL-country source" }
        if abs(fps - 23.976) < 0.01 || abs(fps - 24) < 0.01 { return "24 fps: a film scan or a modern cinema mode" }
        if fps == 18 || fps == 16 { return "16/18 fps: a native-rate film scan (8 mm / Super 8)" }
        if fps <= 15 { return "≤ 15 fps: an early webcam, digicam or phone" }
        if fps == 30 { return "30 fps exactly: a digicam, webcam or phone" }
        return "an uncommon rate"
    }

    private static func scanWords(_ scan: String, _ f: TechnicalFacts, codec: String) -> String {
        if scan == "interlaced" { return "interlaced: analog tape or DV-era video (a camcorder, not a computer)" }
        if let h = f.height, h <= 576, codec != "mjpeg" {
            return "progressive SD: a later re-encode or deinterlaced transfer (flags can lie after a re-encode)"
        }
        return "progressive: a digital camera, phone, film scan or export"
    }

    private static func audioRows(_ f: TechnicalFacts, codec: String) -> [TechnicalReadingLine] {
        let acodec = (f.audioCodec ?? "").lowercased()
        guard !acodec.isEmpty else {
            return f.hasVideo ? [TechnicalReadingLine(label: "Audio", value: "none",
                                                     suggests: "silent file: a film scan, a video-only essence (its audio may be a sibling file)",
                                                     source: "ffprobe")] : []      // stream_type: no audio stream at all (a whole-file fact)
        }
        let rate = f.audioRate
        var value = "first audio stream: " + acodec
        if let rate { value += " \(rate) Hz" }
        if let ch = f.audioChannels { value += " \(ch) ch" }
        let s: String
        if rate == 32000 && codec == "dvvideo" {
            s = "32 kHz in DV: the camcorder's 12-bit 4-channel mode: a consumer DV/Digital8 camcorder"
        } else if rate == 32000 {
            s = "32 kHz: a DV 12-bit mode carried through a transfer"
        } else if rate == 48000 && acodec.hasPrefix("pcm") {
            s = "48 kHz PCM: DV 16-bit mode or any modern capture"
        } else if rate == 44100 {
            s = "44.1 kHz: a CD-era computer capture card or export"
        } else if let rate, rate <= 22050 {
            s = "≤ 22 kHz: a web export, an early digicam or a phone"
        } else if acodec == "aac" {
            s = "AAC: a phone, a camera or an export"
        } else if acodec == "ac3" {
            s = "AC-3: DVD audio"
        } else {
            s = "audio present"
        }
        return [TechnicalReadingLine(label: "Audio", value: value, suggests: s, source: firstAudioStream)]
    }

    private static func encoderWords(_ enc: String) -> String {
        let e = enc.lowercased()
        if e.hasPrefix("lavf") || e.contains("ffmpeg") { return "ffmpeg (libavformat): a transfer or remux tool; one capture setup" }
        if e.contains("handbrake") { return "HandBrake: a re-encode (a DVD rip or a downsized copy)" }
        if e.contains("imovie") || e.contains("final cut") || e.contains("quicktime") { return "Apple editing/capture software: the file was made on a Mac" }
        if e.contains("avid") || e.contains("media composer") { return "Avid: an edit-suite capture" }
        return "the tool that wrote the file: one capture setup"
    }

    private static func durationRateWords(_ f: TechnicalFacts, codec: String, mbps: Double) -> String {
        if codec == "dvvideo" || transferCodecs[codec] != nil { return "high constant rate: a capture or master, not a distribution copy" }
        if mbps > 0, let h = f.height, f.width != nil, h <= 576, mbps < 4 { return "low bit rate SD: a distribution or web copy (a later generation)" }
        return "duration and rate"
    }

    // MARK: The one-line verdict

    /// The layer-1 verdict in one line (the demo's `one_liner`).
    public static func oneLiner(_ f: TechnicalFacts) -> String {
        let codec = f.codec ?? ""
        let size = f.width.flatMap { w in f.height.map { "\(w)×\($0)" } } ?? "?"
        if !f.hasVideo { return "no playable video (reference movie / essence-less MXF / audio)" }
        if codec == "dvvideo" {
            let standard = f.height == 576 ? "PAL" : "NTSC"
            // The MODE the 32 kHz rate implies, never a counted 4 channels (rule 1).
            let mode = f.audioRate == 32000 ? ", 32 kHz audio (the 12-bit 4-ch camcorder mode)" : ""
            return "DV camcorder/deck capture, \(standard) \(size)\(mode)"
        }
        if let name = transferCodecs[codec] {
            return "\(name) transfer master \(size)\(scan(f) == "interlaced" ? " interlaced" : ""): carrier unknown"
        }
        if f.make != nil || f.model != nil {
            return "camera-native \(codec) \(size) from \([f.make, f.model].compactMap { $0 }.joined(separator: " "))"
        }
        if codec == "mjpeg", let h = f.height, h <= 480 { return "digital still camera movie mode (Motion JPEG \(size))" }
        if codec == "mpeg2video", let h = f.height, h <= 576 { return "DVD / DVD-camcorder MPEG-2 \(size)" }
        // An unknown frame rate is left out, never "0 fps".
        return "\(codec.isEmpty ? "?" : codec) \(size)" + (f.fps.map { " \(fpsText($0)) fps" } ?? "") + " in \(f.container ?? "?")"
    }

    // MARK: Words

    /// "2 h 39 m", "4 m 12 s", "38 s".
    public static func durationWords(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 { return "\(s / 3600) h \((s % 3600) / 60) m" }
        if s >= 60 { return "\(s / 60) m \(s % 60) s" }
        return "\(s) s"
    }

    static func fpsText(_ fps: Double) -> String {
        fps == fps.rounded() ? String(Int(fps)) : String(format: "%g", fps)
    }

    static let utc = TimeZone(identifier: "UTC") ?? .gmt

    /// "2003-02-11" in `zone` — the local zone for wall-clock events on this
    /// Mac (file dates, when a pass ran), as the inspector's Timestamps show
    /// them; UTC (labelled by the caller) for an embedded tag's instant.
    public static func day(_ date: Date, in zone: TimeZone = .current) -> String {
        format(date, "%04d-%02d-%02d", [.year, .month, .day], zone)
    }

    /// "2026-06-09 18:40" in the local zone — when a pass ran (the old view's time of day).
    public static func dayAndTime(_ date: Date, in zone: TimeZone = .current) -> String {
        format(date, "%04d-%02d-%02d %02d:%02d", [.year, .month, .day, .hour, .minute], zone)
    }

    private static func format(_ date: Date, _ pattern: String, _ units: Set<Calendar.Component>, _ zone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let c = cal.dateComponents(units, from: date)
        let values = [c.year, c.month, c.day, c.hour, c.minute].compactMap { $0 }.prefix(units.count)
        return String(format: pattern, arguments: values.map { $0 as CVarArg })
    }
}

extension TechnicalFacts {
    /// The facts the catalog stores for `record` (the `files` columns and
    /// `probe_extra`, as the loader put them back). Empty strings are unknown.
    public init(record r: VideoRecord) {
        func text(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
            return t
        }
        let size = TechnicalReading.frameSize(r.resolution)
        let stream = r.streamTypeRaw
        self.init(container: TechnicalReading.containerKey(container: r.container, ext: r.ext),
                  containerName: text(r.container),
                  hasVideo: stream == "Video+Audio" || stream == "Video only",
                  codec: text(r.videoCodec),
                  width: size?.0, height: size?.1,
                  fps: TechnicalReading.rate(r.frameRate),
                  fieldOrder: text(r.scanType)?.lowercased(),
                  audioCodec: text(r.audioCodec),
                  audioRate: TechnicalReading.leadingInt(r.audioSampleRate),
                  audioChannels: TechnicalReading.leadingInt(r.audioChannels),
                  encoder: text(r.originEncoder), make: text(r.originMake), model: text(r.originModel),
                  creationTime: r.embeddedCreationDate, creationSource: text(r.embeddedCreationSource),
                  duration: r.durationSeconds > 0 ? r.durationSeconds : nil,
                  bitRate: TechnicalReading.leadingInt(r.totalBitrate).map { Double($0) * 1000 },
                  modified: r.dateModifiedRaw)
    }
}
