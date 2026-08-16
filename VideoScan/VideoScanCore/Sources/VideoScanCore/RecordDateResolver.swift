// RecordDateResolver.swift
// THE one place "when was this footage shot?" is answered for placement
// (2026-08-16). Master Archive path resolution and the archive
// readiness date state both read this; nothing else should re-derive
// the ranking. Pure + nonisolated: (record fields) → resolution.
//
// Rank order — first signal that yields wins:
//   1. Rick's hand-entered `userDate`, at its entered precision. His
//      date outranks EVERY machine date (the "2026 on a VHS transfer"
//      case). A year-only / month-only user date is REFINED — never
//      overruled — by a finer machine date that agrees with it
//      (user "1992" + camera 1992-06-15 → 1992-06-15).
//   2. `embeddedCreationDate` — the container's creation stamp
//      (day precision). Confidence by ORIGIN: a named camera/phone
//      make/model 0.95, a transcoder encoder string only 0.80 (it may
//      be the re-encode date), neither 0.85.
//   3. `inferredRecordDate` (dossier OCR / speech) at ≥ 0.6 confidence.
//   4. A date pattern in the FILENAME: YYYY-MM-DD, MM-DD-YYYY (US;
//      DD-MM-YYYY when the first number cannot be a month), YYYYMMDD,
//      "Month YYYY", YYYY-MM, or a bare 19xx/20xx year (year precision).
//      Confidence 0.5 — placed, but flagged low-confidence.
//   5. Nothing. Filesystem dates are NEVER used — every copy resets them.
//
// Precision is carried explicitly ("1992" and "1992-06-14" are different
// facts and the archive filename must say which); confidence is what
// the readiness assessment thresholds.
//
// (For Rick: a `struct` with `let`s + a static function ≈ a POD result
// returned by value from a pure function; `enum Precision: Int,
// Comparable` ≈ an ordered enum class you can `<` on.)

import Foundation

public struct RecordDateResolution: Equatable, Sendable {

    /// Ordered finest → coarsest so `precision <= .month` reads naturally.
    public enum Precision: Int, Comparable, Sendable {
        case day = 0, month, year, decade, unknown
        public static func < (a: Precision, b: Precision) -> Bool { a.rawValue < b.rawValue }
    }

    public enum Source: String, Sendable {
        case userDate, embedded, inferred, filename, none
    }

    public let year: Int?
    public let month: Int?
    public let day: Int?
    public let precision: Precision
    /// 0…1. Meaningless (0) when `precision == .unknown`.
    public let confidence: Float
    public let source: Source
    /// True when a machine signal EXISTED but was rejected (an inferred
    /// date under the confidence floor). Lets the caller say "low-
    /// confidence guess" rather than "undated".
    public let hadRejectedSignal: Bool

    public init(year: Int?, month: Int?, day: Int?, precision: Precision,
                confidence: Float, source: Source, hadRejectedSignal: Bool = false) {
        self.year = year; self.month = month; self.day = day
        self.precision = precision; self.confidence = confidence
        self.source = source; self.hadRejectedSignal = hadRejectedSignal
    }

    public static func unknown(hadRejectedSignal: Bool = false) -> RecordDateResolution {
        RecordDateResolution(year: nil, month: nil, day: nil, precision: .unknown,
                             confidence: 0, source: .none, hadRejectedSignal: hadRejectedSignal)
    }

    /// The START of the resolved period as a UTC instant ("1992" →
    /// 1992-01-01T00:00Z). nil when unknown.
    public var date: Date? {
        guard let y = year else { return nil }
        guard let jdn = EmbeddedDateParser.julianDayNumber(year: y, month: month ?? 1, day: day ?? 1) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(jdn - 2440588) * 86_400)
    }

    /// Reduced-precision ISO, same shape as `VideoRecord.userDate`:
    /// "1992" | "1992-06" | "1992-06-14"; "" when unknown.
    public var isoString: String {
        guard let y = year else { return "" }
        if let m = month, let d = day { return String(format: "%04d-%02d-%02d", y, m, d) }
        if let m = month { return String(format: "%04d-%02d", y, m) }
        return String(format: "%04d", y)
    }
}

public enum RecordDateResolver {

    /// The confidence floor for trusting a dossier-inferred date.
    public static let inferredConfidenceFloor: Float = 0.6

    // Embedded-date confidence tiers by origin (Rick 2026-08-16).
    public static let embeddedConfidenceDevice: Float = 0.95      // make/model names a camera/phone
    public static let embeddedConfidenceUnknownOrigin: Float = 0.85
    public static let embeddedConfidenceEncoderOnly: Float = 0.80 // a transcoder stamped it
    /// Filename patterns are a hint, not a fact.
    public static let filenameConfidence: Float = 0.5

    /// User-date confidence as a number: "I'm sure" vs "best guess".
    public static let userKnownConfidence: Float = 1.0
    public static let userEstimatedConfidence: Float = 0.8

    /// Confidence to assign an embedded date given its origin.
    public static func embeddedConfidence(originMake: String?, originModel: String?, originEncoder: String?) -> Float {
        if originMake != nil || originModel != nil { return embeddedConfidenceDevice }
        if originEncoder != nil { return embeddedConfidenceEncoderOnly }
        return embeddedConfidenceUnknownOrigin
    }

    /// The resolver. Every argument is a plain value lifted off the
    /// record; `now` bounds the filename-year search (a bare "2031" in a
    /// name is a serial number, not a year).
    public static func resolve(userDate: String?,
                               userDateConfidence: String? = nil,
                               embeddedCreationDate: Date?,
                               originMake: String? = nil,
                               originModel: String? = nil,
                               originEncoder: String? = nil,
                               inferredRecordDate: Date?,
                               inferredDateConfidence: Float?,
                               filename: String?,
                               now: Date = Date()) -> RecordDateResolution {

        // ---- Machine candidates, in rank order (computed lazily below).
        func embedded() -> RecordDateResolution? {
            guard let d = embeddedCreationDate else { return nil }
            let dc = utcGregorian.dateComponents([.year, .month, .day], from: d)
            guard let y = dc.year, let m = dc.month, let dd = dc.day else { return nil }
            return RecordDateResolution(year: y, month: m, day: dd, precision: .day,
                                        confidence: embeddedConfidence(originMake: originMake,
                                                                       originModel: originModel,
                                                                       originEncoder: originEncoder),
                                        source: .embedded)
        }
        var rejectedInferred = false
        func inferred() -> RecordDateResolution? {
            guard let d = inferredRecordDate else { return nil }
            let conf = inferredDateConfidence ?? 0
            guard conf >= inferredConfidenceFloor else { rejectedInferred = true; return nil }
            let dc = utcGregorian.dateComponents([.year, .month, .day], from: d)
            guard let y = dc.year, let m = dc.month, let dd = dc.day else { return nil }
            return RecordDateResolution(year: y, month: m, day: dd, precision: .day,
                                        confidence: conf, source: .inferred)
        }
        func fromFilename() -> RecordDateResolution? {
            guard let name = filename, let f = FilenameDatePattern.match(name, now: now) else { return nil }
            return RecordDateResolution(year: f.year, month: f.month, day: f.day, precision: f.precision,
                                        confidence: filenameConfidence, source: .filename)
        }

        // ---- 1. Rick's date, refined (never overruled) by an agreeing finer machine date.
        if let ud = userDate, let parts = UserDateEntry.components(of: ud) {
            let conf: Float = userDateConfidence == UserDateConfidence.known.rawValue
                ? userKnownConfidence : userEstimatedConfidence
            let userPrecision: RecordDateResolution.Precision =
                parts.day != nil ? .day : (parts.month != nil ? .month : .year)
            let user = RecordDateResolution(year: parts.year, month: parts.month, day: parts.day,
                                            precision: userPrecision, confidence: conf, source: .userDate)
            guard userPrecision != .day else { return user }
            for candidate in [embedded(), inferred(), fromFilename()] {
                guard let c = candidate, c.precision < userPrecision, c.year == parts.year else { continue }
                if let um = parts.month, c.month != um { continue }
                // Same year (and month, when the user gave one): the
                // machine date is a sharper reading of the user's fact.
                return RecordDateResolution(year: c.year, month: c.month, day: c.day, precision: c.precision,
                                            confidence: max(conf, c.confidence), source: c.source)
            }
            return user
        }

        // ---- 2–4. Machine signals.
        if let e = embedded() { return e }
        if let i = inferred() { return i }
        if let f = fromFilename() {
            return RecordDateResolution(year: f.year, month: f.month, day: f.day, precision: f.precision,
                                        confidence: f.confidence, source: f.source,
                                        hadRejectedSignal: rejectedInferred)
        }
        // ---- 5. Nothing.
        return .unknown(hadRejectedSignal: rejectedInferred)
    }

    static let utcGregorian: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }()
}

// MARK: - Filename date patterns

/// Dates people put in filenames. Pure scanner over the NAME (never the
/// directory). Returns the first, most specific match.
public enum FilenameDatePattern {

    public struct Match: Equatable, Sendable {
        public let year: Int
        public let month: Int?
        public let day: Int?
        public let precision: RecordDateResolution.Precision
    }

    /// Camera / phone sequence prefixes: "IMG_1995.MOV" is frame 1995,
    /// not the year 1995. A bare year right after one of these is ignored.
    static let sequencePrefixes: Set<String> = [
        "img", "dsc", "dscn", "dscf", "mvi", "pict", "gopr", "gp", "gx", "cimg", "sany", "mov", "vid",
        "clip", "dcim", "mah", "sdv", "hdv", "m2u", "vts", "movi", "pxl", "trim", "p", "c", "a", "m", "v",
    ]

    static let monthNames: [(String, Int)] = [
        ("january", 1), ("february", 2), ("march", 3), ("april", 4), ("may", 5), ("june", 6),
        ("july", 7), ("august", 8), ("september", 9), ("october", 10), ("november", 11), ("december", 12),
        ("jan", 1), ("feb", 2), ("mar", 3), ("apr", 4), ("jun", 6), ("jul", 7), ("aug", 8),
        ("sep", 9), ("sept", 9), ("oct", 10), ("nov", 11), ("dec", 12),
    ]

    public static func match(_ filename: String, now: Date = Date()) -> Match? {
        let stem = (filename as NSString).deletingPathExtension
        let maxYear = (RecordDateResolver.utcGregorian.component(.year, from: now)) + 1
        let minYear = 1900
        func plausible(_ y: Int) -> Bool { y >= minYear && y <= maxYear }

        // Tokenize into runs of digits with their separators kept, so the
        // patterns can be matched positionally without regex (NSRegular-
        // Expression is fine but this runs 100k× in the scale test).
        let chars = Array(stem)
        // Digit runs: (start index, text)
        var runs: [(start: Int, end: Int, value: Int, count: Int)] = []
        var i = 0
        while i < chars.count {
            if chars[i].isASCII && chars[i].isNumber {
                var j = i; var v = 0; var n = 0
                while j < chars.count, chars[j].isASCII, chars[j].isNumber {
                    if n < 9 { v = v * 10 + Int(String(chars[j]))! }
                    n += 1; j += 1
                }
                runs.append((i, j, v, n))
                i = j
            } else { i += 1 }
        }
        func sepBetween(_ a: (start: Int, end: Int, value: Int, count: Int),
                        _ b: (start: Int, end: Int, value: Int, count: Int)) -> Character? {
            guard b.start == a.end + 1 else { return nil }
            let c = chars[a.end]
            return (c == "-" || c == "_" || c == "." || c == " ") ? c : nil
        }
        func validDay(_ d: Int, _ m: Int, _ y: Int) -> Bool {
            EmbeddedDateParser.julianDayNumber(year: y, month: m, day: d) != nil
        }

        // ---- 1. YYYY-MM-DD / YYYY_MM_DD / YYYY.MM.DD (3 runs, same separator)
        if runs.count >= 3 {
            for k in 0..<(runs.count - 2) {
                let a = runs[k], b = runs[k + 1], c = runs[k + 2]
                guard a.count == 4, b.count == 2, c.count == 2,
                      let s1 = sepBetween(a, b), let s2 = sepBetween(b, c), s1 == s2 else { continue }
                if plausible(a.value), (1...12).contains(b.value), validDay(c.value, b.value, a.value) {
                    return Match(year: a.value, month: b.value, day: c.value, precision: .day)
                }
            }
            // ---- 2. MM-DD-YYYY (US) or DD-MM-YYYY when the first cannot be a month
            for k in 0..<(runs.count - 2) {
                let a = runs[k], b = runs[k + 1], c = runs[k + 2]
                guard (1...2).contains(a.count), (1...2).contains(b.count), c.count == 4,
                      let s1 = sepBetween(a, b), let s2 = sepBetween(b, c), s1 == s2,
                      plausible(c.value) else { continue }
                if (1...12).contains(a.value), validDay(b.value, a.value, c.value) {
                    return Match(year: c.value, month: a.value, day: b.value, precision: .day)
                }
                if (1...12).contains(b.value), validDay(a.value, b.value, c.value) {
                    return Match(year: c.value, month: b.value, day: a.value, precision: .day)
                }
            }
        }
        // ---- 3. YYYYMMDD (one 8-digit run)
        for r in runs where r.count == 8 {
            let y = r.value / 10_000, m = (r.value / 100) % 100, d = r.value % 100
            if plausible(y), (1...12).contains(m), validDay(d, m, y) {
                return Match(year: y, month: m, day: d, precision: .day)
            }
        }
        // ---- 4. "Month YYYY" / "MonthYYYY" / "Month-YYYY" (month precision)
        for r in runs where r.count == 4 && plausible(r.value) {
            // Look back over an optional separator for a month name.
            var e = r.start
            while e > 0, [" ", "_", "-", "."].contains(chars[e - 1]) { e -= 1 }
            let prefix = String(chars[..<e]).lowercased()
            for (name, m) in monthNames where prefix.hasSuffix(name) {
                // Word boundary: the character before the name must not be a letter.
                let before = prefix.dropLast(name.count).last
                if before == nil || !(before!.isLetter) {
                    return Match(year: r.value, month: m, day: nil, precision: .month)
                }
            }
        }
        // ---- 5. YYYY-MM (month precision), only when not part of a YYYY-YYYY range
        if runs.count >= 2 {
            for k in 0..<(runs.count - 1) {
                let a = runs[k], b = runs[k + 1]
                guard a.count == 4, b.count == 2, sepBetween(a, b) != nil,
                      plausible(a.value), (1...12).contains(b.value) else { continue }
                return Match(year: a.value, month: b.value, day: nil, precision: .month)
            }
        }
        // ---- 6. Bare 19xx / 20xx year (year precision)
        for r in runs where r.count == 4 && plausible(r.value) {
            // Camera counters, not years: "IMG_1995", "DSC2001", "100_2005"
            // (Kodak folder_frame). Look at what sits just before the
            // digits, through at most one "_" / "-".
            var e = r.start
            if e > 0, chars[e - 1] == "_" || chars[e - 1] == "-" { e -= 1 }
            if e > 0, chars[e - 1].isNumber { continue }
            var s = e
            while s > 0, chars[s - 1].isLetter { s -= 1 }
            let word = String(chars[s..<e]).lowercased()
            if !word.isEmpty, word.count <= 4, sequencePrefixes.contains(word) { continue }
            return Match(year: r.value, month: nil, day: nil, precision: .year)
        }
        return nil
    }
}
