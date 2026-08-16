// EmbeddedCreationDate.swift
// Container / stream "when was this shot" tags (2026-08-16).
//
// Modern camera, phone and NLE output carries a reliable creation stamp
// in the container itself — QuickTime `creation_time` (mvhd, UTC),
// Apple's `com.apple.quicktime.creationdate` (wall clock with offset),
// Matroska DateUTC — and an ORIGIN line naming the device or program
// that wrote the file (`make` / `model` / `encoder` and their
// `com.apple.quicktime.*` spellings). Filesystem dates are useless for
// this (every copy resets them); the tag survives copies, so it is the
// signal the Master Archive resolver should prefer over a filename year.
//
// Three pure pieces, all Foundation-only, no clock unless injected:
//   - `EmbeddedDateParser`   — the string grammar (ISO-8601 variants,
//                              QuickTime offsets, EXIF colons, ffmpeg's
//                              "a;b" duplicated values).
//   - `EmbeddedDateSanity`   — rejects the well-known junk defaults
//                              (1904 QuickTime epoch, 1970 Unix epoch,
//                              2000-01-01T00:00:00 camera default, the
//                              future, anything before 1980).
//   - `EmbeddedOriginTags`   — make / model / encoder extraction and the
//                              display description ("Apple iPhone 15 Pro",
//                              "Canon EOS R6m2", "HandBrake 1.7.3").
//   - `EmbeddedCreationDate.extract(formatTags:streamTags:)` — the one
//                              entry point ScanEngine and the backfill
//                              pass call: tags in, (date, source) out.
//
// (For Rick: everything here is the C++ "free functions in a namespace"
// layer — `enum` with only statics is Swift's way to spell a namespace
// that can never be instantiated.)

import Foundation

// MARK: - Parser

/// String → Date for the creation-time tag grammar. Pure; no locale, no
/// current time.
public enum EmbeddedDateParser {

    /// Parse one tag value. Accepts, whitespace-trimmed:
    ///   "2025-06-15T22:47:45Z"             ISO-8601 UTC
    ///   "2025-06-15T22:47:45.000000Z"      ISO-8601 with fractional seconds
    ///   "2025-06-15T18:47:45-0400"         QuickTime creationdate (offset, no colon)
    ///   "2025-06-15T18:47:45-04:00"        ISO-8601 offset with colon
    ///   "2025-06-15 22:47:45"              space separator, no zone (⇒ UTC)
    ///   "2025:06:15 22:47:45"              EXIF colons (⇒ UTC)
    ///   "2025-06-15"                       date only (⇒ midnight UTC)
    ///   "a;b"                              ffmpeg joins duplicate tag values
    ///                                      with ';' — first parseable wins.
    /// Anything else → nil. A parsed value is NOT sanity-checked here;
    /// see `EmbeddedDateSanity`.
    public static func parse(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains(";") {
            for piece in trimmed.split(separator: ";") {
                if let d = parseSingle(String(piece).trimmingCharacters(in: .whitespaces)) { return d }
            }
            return nil
        }
        return parseSingle(trimmed)
    }

    /// The single-value grammar. Hand-rolled rather than DateFormatter /
    /// ISO8601DateFormatter: neither accepts the "-0400" QuickTime offset
    /// or the EXIF colon form, and both are not Sendable — a static
    /// cached instance would trip strict concurrency in this package.
    private static func parseSingle(_ s: String) -> Date? {
        let scalars = Array(s.unicodeScalars)
        var i = 0

        func digits(_ n: Int) -> Int? {
            guard i + n <= scalars.count else { return nil }
            var v = 0
            for k in 0..<n {
                let c = scalars[i + k].value
                guard c >= 0x30 && c <= 0x39 else { return nil }
                v = v * 10 + Int(c - 0x30)
            }
            i += n
            return v
        }
        func accept(_ set: String) -> Bool {
            guard i < scalars.count, set.unicodeScalars.contains(scalars[i]) else { return false }
            i += 1
            return true
        }

        guard let year = digits(4) else { return nil }
        guard accept("-:") else { return nil }
        guard let month = digits(2) else { return nil }
        guard accept("-:") else { return nil }
        guard let day = digits(2) else { return nil }

        var hour = 0, minute = 0, second = 0
        var nanos = 0
        var offsetSeconds = 0

        if i < scalars.count {
            // Optional time part.
            guard accept("T ") else { return nil }
            guard let h = digits(2), accept(":"), let m = digits(2) else { return nil }
            hour = h; minute = m
            if accept(":") {
                guard let sec = digits(2) else { return nil }
                second = sec
                if accept(".,") {
                    // Fractional seconds: any number of digits, keep ≤ 9.
                    var frac = 0, count = 0
                    while i < scalars.count, scalars[i].value >= 0x30, scalars[i].value <= 0x39 {
                        if count < 9 { frac = frac * 10 + Int(scalars[i].value - 0x30); count += 1 }
                        i += 1
                    }
                    guard count > 0 else { return nil }
                    while count < 9 { frac *= 10; count += 1 }
                    nanos = frac
                }
            }
            // Optional whitespace before the zone.
            while i < scalars.count, scalars[i] == " " { i += 1 }
            if i < scalars.count {
                if accept("Zz") {
                    // UTC
                } else if let signScalar = scalars[safe: i], signScalar == "+" || signScalar == "-" {
                    i += 1
                    guard let oh = digits(2) else { return nil }
                    _ = accept(":")
                    let om = digits(2) ?? 0
                    let mag = oh * 3600 + om * 60
                    offsetSeconds = signScalar == "+" ? mag : -mag
                } else {
                    return nil
                }
            }
            guard i == scalars.count else { return nil }
        }

        guard (1...12).contains(month), (1...31).contains(day),
              hour < 24, minute < 60, second < 61 else { return nil }
        guard let jdn = julianDayNumber(year: year, month: month, day: day) else { return nil }
        let unixEpochJDN = 2440588   // 1970-01-01
        var t = TimeInterval(jdn - unixEpochJDN) * 86_400
        t += TimeInterval(hour * 3600 + minute * 60 + second)
        t += TimeInterval(nanos) / 1_000_000_000
        // A wall-clock reading at UTC-4 is 4 hours LATER in UTC.
        t -= TimeInterval(offsetSeconds)
        return Date(timeIntervalSince1970: t)
    }

    /// Fliegel & Van Flandern (1968) — same integer-only Julian day math
    /// as `UserDateEntry.date(from:)`. Validates the day against the
    /// month (Feb 30 → nil) via a round-trip check.
    static func julianDayNumber(year y: Int, month m: Int, day d: Int) -> Int? {
        let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
        let dim: [Int] = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...12).contains(m), d >= 1, d <= dim[m - 1] else { return nil }
        let a = (m - 14) / 12
        var jdn = (1461 * (y + 4800 + a)) / 4
        jdn += (367 * (m - 2 - 12 * a)) / 12
        jdn -= (3 * ((y + 4900 + a) / 100)) / 4
        jdn += d - 32075
        return jdn
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - Sanity filter

/// Rejects the placeholder values firmware and muxers write when they
/// have no clock: the QuickTime epoch (1904-01-01), the Unix epoch
/// (1970-01-01), the camera-default 2000-01-01T00:00:00, anything before
/// 1980 (no consumer camcorder wrote container dates before then), and
/// anything in the future (a wrong-clock camera; > now + 1 day).
public enum EmbeddedDateSanity {

    /// The earliest year a container creation date can be believed.
    public static let earliestPlausibleYear = 1980

    /// Slack for a camera clock a little ahead of the machine's.
    public static let futureSlack: TimeInterval = 86_400

    /// `date` if it passes, nil if it is a known junk default. `now` is
    /// injectable so the "future" rule is table-testable.
    public static func accept(_ date: Date, now: Date = Date()) -> Date? {
        let t = date.timeIntervalSince1970
        // Exact epoch defaults.
        if t == 0 { return nil }                        // 1970-01-01T00:00:00Z
        if t == -2_082_844_800 { return nil }           // 1904-01-01T00:00:00Z (QuickTime epoch)
        if t == 946_684_800 { return nil }              // 2000-01-01T00:00:00Z (camera default)
        // Same defaults expressed in a local zone land within a day of the
        // exact instant; the calendar-day check below catches those.
        let cal = utcGregorian
        let dc = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard let y = dc.year, let m = dc.month, let d = dc.day else { return nil }
        if y < earliestPlausibleYear { return nil }     // also covers 1904 / 1970 in any zone
        if (y == 2000 || y == 1970 || y == 1904) && m == 1 && d == 1 { return nil }
        if date.timeIntervalSince(now) > futureSlack { return nil }
        return date
    }

    static let utcGregorian: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }()
}

// MARK: - Origin tags (make / model / encoder)

/// What wrote the file: device make + model when a camera or phone did,
/// the encoder string when a transcoder did. Pure tag → value functions
/// plus the display description the inspector shows.
public enum EmbeddedOriginTags {

    public struct Origin: Equatable, Sendable {
        public var make: String?
        public var model: String?
        public var encoder: String?
        public init(make: String? = nil, model: String? = nil, encoder: String? = nil) {
            self.make = make; self.model = model; self.encoder = encoder
        }
        public var isEmpty: Bool { make == nil && model == nil && encoder == nil }
        /// True when a device (not just a program) is named.
        public var namesDevice: Bool { make != nil || model != nil }
    }

    /// Device makers whose name in a `handler_name` / vendor tag is a
    /// reliable origin even when no `make` tag exists (GoPro writes
    /// "GoPro AVC" as its video handler; DJI likewise).
    static let knownMakers: [String] = [
        "Apple", "Canon", "Sony", "Panasonic", "Nikon", "GoPro", "DJI", "Fujifilm",
        "Olympus", "OM Digital", "Blackmagic", "RED", "ARRI", "Insta360", "Garmin",
        "Samsung", "Google", "JVC", "Hitachi", "Sanyo", "Kodak", "Leica", "Sigma", "Ricoh", "Pentax",
    ]

    /// Extract the origin from format-level + per-stream tags. Format
    /// tags win; stream tags fill gaps. Keys are matched case-
    /// insensitively (Matroska upper-cases everything).
    public static func extract(formatTags: [String: String],
                               streamTags: [[String: String]]) -> Origin {
        var o = Origin()
        let fmt = lowered(formatTags)
        o.make = clean(fmt["com.apple.quicktime.make"] ?? fmt["make"] ?? fmt["manufacturer"])
        o.model = clean(fmt["com.apple.quicktime.model"] ?? fmt["model"])
        o.encoder = clean(fmt["encoder"] ?? fmt["encoding_tool"] ?? fmt["com.apple.quicktime.software"]
                          ?? fmt["software"] ?? fmt["writing_application"])
        for tags in streamTags {
            let st = lowered(tags)
            if o.make == nil { o.make = clean(st["make"]) }
            if o.model == nil { o.model = clean(st["model"]) }
            if o.encoder == nil { o.encoder = clean(st["encoder"]) }
            // A handler that names a device maker ("GoPro AVC", "DJI…").
            if o.make == nil, let handler = clean(st["handler_name"]),
               let maker = makerNamed(in: handler) {
                o.make = maker
            }
        }
        // com.apple.quicktime.software is an OS version ("17.2") when a
        // make/model is present — that is not an encoder worth showing.
        if o.namesDevice, let enc = o.encoder, enc.allSatisfy({ $0.isNumber || $0 == "." }) {
            o.encoder = nil
        }
        return o
    }

    /// "Apple iPhone 15 Pro", "Canon EOS R6m2" (model already carries the
    /// make → not repeated), "HandBrake 1.7.3" (build stamp dropped),
    /// "Lavf63.1.101" (ffmpeg, left as written), or nil when nothing is
    /// known.
    public static func description(_ o: Origin) -> String? {
        if let model = o.model {
            if let make = o.make, model.range(of: make, options: [.caseInsensitive, .anchored]) == nil {
                return "\(make) \(model)"
            }
            return model
        }
        if let make = o.make { return make }
        if let enc = o.encoder { return shortEncoder(enc) }
        return nil
    }

    /// The word the inspector puts in parentheses when only an encoder
    /// is known: "HandBrake", "Lavf63.1.101" → "ffmpeg", "Final Cut Pro".
    public static func encoderFamily(_ encoder: String) -> String {
        let e = encoder.trimmingCharacters(in: .whitespaces)
        let lower = e.lowercased()
        if lower.hasPrefix("lavf") || lower.hasPrefix("lavc") { return "ffmpeg" }
        if lower.hasPrefix("handbrake") { return "HandBrake" }
        // The leading words up to the first version-like token:
        // "Final Cut Pro 10.7" → "Final Cut Pro".
        var words: [String] = []
        for token in e.split(separator: " ") {
            if let first = token.first, first.isNumber { break }
            words.append(String(token))
        }
        return words.isEmpty ? e : words.joined(separator: " ")
    }

    /// "HandBrake 1.7.3 2023121300" → "HandBrake 1.7.3": drop a trailing
    /// all-digit build stamp of 8+ digits. Everything else verbatim.
    static func shortEncoder(_ encoder: String) -> String {
        var parts = encoder.split(separator: " ").map(String.init)
        if parts.count >= 2, let last = parts.last, last.count >= 8, last.allSatisfy(\.isNumber) {
            parts.removeLast()
        }
        return parts.joined(separator: " ")
    }

    /// A known maker appearing as a whole WORD in `text` ("GoPro AVC" →
    /// "GoPro"; "Rendered" does NOT match "RED"). Case-insensitive.
    static func makerNamed(in text: String) -> String? {
        let words = Set(text.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init))
        for maker in knownMakers {
            let parts = maker.lowercased().split(separator: " ").map(String.init)
            if parts.allSatisfy({ words.contains($0) }) { return maker }
        }
        return nil
    }

    private static func lowered(_ tags: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        out.reserveCapacity(tags.count)
        for (k, v) in tags { out[k.lowercased()] = v }
        return out
    }

    private static func clean(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        // Some cameras pad with NULs; a "value" of only punctuation is noise.
        guard !t.isEmpty, t.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return t.count > 80 ? String(t.prefix(80)) : t
    }
}

// MARK: - Entry point

/// The one call ScanEngine / the backfill make: ffprobe tags in, a
/// sane creation date + provenance string out.
public enum EmbeddedCreationDate {

    public struct Capture: Equatable, Sendable {
        public let date: Date
        /// "format:creation_time" | "quicktime:com.apple.quicktime.creationdate"
        /// | "stream:creation_time" — which tag the date came from.
        public let source: String
        public init(date: Date, source: String) { self.date = date; self.source = source }
    }

    /// Precedence: format `creation_time` (mvhd, what every writer sets),
    /// then Apple's `com.apple.quicktime.creationdate`, then the first
    /// stream carrying `creation_time`. Each candidate must parse AND
    /// pass the sanity filter; a junk format-level stamp does not hide a
    /// good stream-level one.
    public static func extract(formatTags: [String: String],
                               streamTags: [[String: String]],
                               now: Date = Date()) -> Capture? {
        func lowered(_ tags: [String: String]) -> [String: String] {
            var out: [String: String] = [:]
            for (k, v) in tags { out[k.lowercased()] = v }
            return out
        }
        let fmt = lowered(formatTags)
        var candidates: [(String, String)] = []
        if let v = fmt["creation_time"] { candidates.append((v, "format:creation_time")) }
        if let v = fmt["com.apple.quicktime.creationdate"] {
            candidates.append((v, "quicktime:com.apple.quicktime.creationdate"))
        }
        for tags in streamTags {
            let st = lowered(tags)
            if let v = st["creation_time"] { candidates.append((v, "stream:creation_time")) }
        }
        for (raw, source) in candidates {
            if let d = EmbeddedDateParser.parse(raw), let ok = EmbeddedDateSanity.accept(d, now: now) {
                return Capture(date: ok, source: source)
            }
        }
        return nil
    }
}

// MARK: - VideoRecord conveniences

extension VideoRecord {
    /// The origin line for display: "Apple iPhone 15 Pro", "Canon EOS
    /// R6m2", "HandBrake 1.7.3", or nil when the file names no origin.
    public var originDescription: String? {
        EmbeddedOriginTags.description(
            EmbeddedOriginTags.Origin(make: originMake, model: originModel, encoder: originEncoder))
    }

    /// The short parenthetical the inspector shows beside the embedded
    /// date: the device when one is named, else the encoder family
    /// ("HandBrake", "ffmpeg"), else "container tag".
    public var embeddedDateOriginLabel: String {
        if originMake != nil || originModel != nil, let d = originDescription { return d }
        if let enc = originEncoder { return EmbeddedOriginTags.encoderFamily(enc) }
        return "container tag"
    }
}
