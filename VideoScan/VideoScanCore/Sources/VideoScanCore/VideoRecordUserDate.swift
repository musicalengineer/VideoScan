// VideoRecordUserDate.swift
// Estimated date (GH #117, v1 — 2026-07-19): the pure logic behind
// Rick's hand-entered dates.
//
//   - `UserDateEntry.canonicalize(_:)` — lenient entry parser. Accepts
//     "1992", "6/1992", "6/14/1992" (US order) and the ISO forms
//     "1992-06" / "1992-06-14" (zero-padding optional) and normalizes
//     them to REDUCED-PRECISION ISO: "1992" | "1992-06" | "1992-06-14".
//     The partial date IS the precision signal — year-only vs month vs
//     day — so there is no separate precision enum. Canonical strings
//     sort lexically and read cleanly in catalog.json.
//   - `UserDateStatus` — the DERIVED (never stored) known / estimated /
//     unconfirmed state, computed from the two stored fields so it can
//     never disagree with them.
//   - `VideoRecord.resolvedDateSortKey` / `.resolvedDateDisplay` — the
//     "best date" resolution: Rick's date (either confidence) OUTRANKS
//     any machine date (the 2026-on-a-VHS-conversion case proves the
//     ordering), then the container's embedded creation date, then the
//     dossier's inferred date, then the file's creation date. O(1) per record — these back a catalog table
//     column, so no allocation-heavy work here (NO DateFormatter on
//     the sort path; see the Julian-day math below).
//
// Foundation-only on purpose so it lives in the VideoScanCore package
// beside VideoRecord+Derived.swift.

import Foundation

// MARK: - Confidence (stored as a raw string on VideoRecord)

/// Typed view of `VideoRecord.userDateConfidence`. Stored as a plain
/// `String?` per the schema ("estimated" | "known") so catalog.json
/// stays readable and future values don't break old decoders; this enum
/// is the app-side vocabulary.
/// (`enum ... : String` ≈ a C++ enum class plus a to/from-string pair
/// the compiler writes for you.)
public enum UserDateConfidence: String, Sendable {
    /// Rick's best guess — the DEFAULT. Off-by-months is fine on a
    /// 35-year-old tape; dates get refined by talking with family.
    case estimated
    /// Certain AT THE PRECISION ENTERED: "1992" + known means "the
    /// year is certain", not "January 1st is certain".
    case known
}

// MARK: - Derived status (computed, never stored)

/// Where a record stands on the "when was this?" question. Derived from
/// the two stored fields on every read so it can never disagree with
/// them — no backfill migration, no scan-time default to forget.
public enum UserDateStatus: String, Sendable {
    /// Rick entered a date and marked it certain (at its precision).
    case known
    /// Rick entered a date as a best guess (the default).
    case estimated
    /// No hand-entered date yet — the record lives on machine dates
    /// (inferred / file metadata) or nothing. This is the triage queue
    /// for family review sessions (search facet lands in v2).
    case unconfirmed
}

// MARK: - Lenient entry parser

/// Namespace for the user-date entry grammar. Pure functions only —
/// no clock, no locale, no globals — so the whole grammar is testable
/// as a table. (`enum` with only statics ≈ a C++ namespace; an enum
/// with no cases can never be instantiated.)
public enum UserDateEntry {

    /// Parse a hand-typed date into canonical reduced-precision ISO.
    ///
    /// Accepted forms (whitespace-trimmed):
    ///   "1992"          → "1992"
    ///   "6/1992"        → "1992-06"     (US month/year)
    ///   "6/14/1992"     → "1992-06-14"  (US month/day/year)
    ///   "1992-6"        → "1992-06"     (ISO, padding optional)
    ///   "1992-06-14"    → "1992-06-14"
    ///
    /// Returns nil for anything else — garbage, 2-digit years, month 13,
    /// Feb 30, day/month order swapped ("14/6/1992"), etc. Rejection is
    /// the parser's job; "did the user mean to clear the field" (empty
    /// input) is the UI's job and should be decided before calling this.
    public static func canonicalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Split on exactly one separator kind. A string containing both
        // "/" and "-" (or neither, when it isn't a bare year) is garbage.
        if trimmed.contains("/") && trimmed.contains("-") { return nil }

        let parts: [Substring]
        let isSlashForm: Bool
        if trimmed.contains("/") {
            parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
            isSlashForm = true
        } else if trimmed.contains("-") {
            parts = trimmed.split(separator: "-", omittingEmptySubsequences: false)
            isSlashForm = false
        } else {
            // Bare year.
            guard let y = strictInt(trimmed[...]), isValidYear(y) else { return nil }
            return String(format: "%04d", y)
        }

        // Every component must be purely numeric (strictInt rejects "",
        // "+6", " 6", "6a", …).
        let nums = parts.compactMap(strictInt)
        guard nums.count == parts.count else { return nil }

        switch (isSlashForm, nums.count) {
        case (true, 2):   // M/yyyy
            let (m, y) = (nums[0], nums[1])
            guard isValidYear(y), isValidMonth(m) else { return nil }
            return String(format: "%04d-%02d", y, m)
        case (true, 3):   // M/d/yyyy
            let (m, d, y) = (nums[0], nums[1], nums[2])
            guard isValidYear(y), isValidMonth(m), isValidDay(d, month: m, year: y) else { return nil }
            return String(format: "%04d-%02d-%02d", y, m, d)
        case (false, 2):  // yyyy-M
            let (y, m) = (nums[0], nums[1])
            guard isValidYear(y), yearDigitCount(parts[0]) == 4, isValidMonth(m) else { return nil }
            return String(format: "%04d-%02d", y, m)
        case (false, 3):  // yyyy-M-d
            let (y, m, d) = (nums[0], nums[1], nums[2])
            guard isValidYear(y), yearDigitCount(parts[0]) == 4,
                  isValidMonth(m), isValidDay(d, month: m, year: y) else { return nil }
            return String(format: "%04d-%02d-%02d", y, m, d)
        default:
            return nil
        }
    }

    /// Break a CANONICAL reduced-ISO string back into numeric parts.
    /// nil for anything that isn't canonical (defensive — the stored
    /// field should only ever hold canonicalize() output).
    public static func components(of canonical: String) -> (year: Int, month: Int?, day: Int?)? {
        let parts = canonical.split(separator: "-", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count),
              let y = strictInt(parts[0]), isValidYear(y), parts[0].count == 4
        else { return nil }
        var month: Int?
        var day: Int?
        if parts.count >= 2 {
            guard let m = strictInt(parts[1]), isValidMonth(m), parts[1].count == 2 else { return nil }
            month = m
        }
        if parts.count == 3 {
            guard let m = month, let d = strictInt(parts[2]),
                  isValidDay(d, month: m, year: y), parts[2].count == 2 else { return nil }
            day = d
        }
        return (y, month, day)
    }

    /// The START of the period a canonical user date names, as a UTC
    /// Date — "1992" → 1992-01-01T00:00Z, "1992-06" → 1992-06-01T00:00Z.
    /// Used as the table sort key, so it must be CHEAP: this is the
    /// classic Fliegel–Van Flandern Julian-day-number computation (pure
    /// integer math, the same trick every C date library uses) rather
    /// than a Calendar/DateComponents round trip — sort comparators call
    /// it O(n log n) times across a 100k-row catalog.
    public static func date(from canonical: String) -> Date? {
        guard let (y, month, day) = components(of: canonical) else { return nil }
        let m = month ?? 1
        let d = day ?? 1
        // Fliegel & Van Flandern (1968), valid for all Gregorian dates
        // we care about. Integer division truncates toward zero in both
        // C and Swift, which the algorithm relies on for y ≥ 1000.
        let a = (m - 14) / 12
        var jdn = (1461 * (y + 4800 + a)) / 4
        jdn += (367 * (m - 2 - 12 * a)) / 12
        jdn -= (3 * ((y + 4900 + a) / 100)) / 4
        jdn += d - 32075
        let unixEpochJDN = 2440588   // 1970-01-01
        return Date(timeIntervalSince1970: TimeInterval(jdn - unixEpochJDN) * 86_400)
    }

    // MARK: Validation primitives

    /// Whole-string base-10 parse: nil for empty, signs, spaces, or any
    /// non-digit. `Int(Substring)` alone would accept "+6" and "-6".
    private static func strictInt(_ s: Substring) -> Int? {
        guard !s.isEmpty, s.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(s)
    }

    /// 4-digit years only. Deliberately NO plausibility window here —
    /// "is 2026 believable for a VHS capture" is issue #118's job, not
    /// the parser's. The parser only rejects impossible calendar dates.
    private static func isValidYear(_ y: Int) -> Bool { (1000...9999).contains(y) }

    private static func isValidMonth(_ m: Int) -> Bool { (1...12).contains(m) }

    private static func isValidDay(_ d: Int, month: Int, year: Int) -> Bool {
        guard d >= 1 else { return false }
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let daysInMonth: Int
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: daysInMonth = 31
        case 4, 6, 9, 11:           daysInMonth = 30
        case 2:                     daysInMonth = leap ? 29 : 28
        default:                    return false
        }
        return d <= daysInMonth
    }

    /// Digit count of the year component — used to insist the ISO forms
    /// really lead with a 4-digit year ("06-1992" must not parse).
    private static func yearDigitCount(_ s: Substring) -> Int { s.count }
}

// MARK: - VideoRecord: derived status + best-date resolution

extension VideoRecord {

    /// Typed read of the stored confidence string. nil when the record
    /// has no user date (the stored confidence is meaningless then, per
    /// the schema contract) or the string is unrecognized.
    public var userDateConfidenceValue: UserDateConfidence? {
        guard userDate != nil else { return nil }
        return userDateConfidence.flatMap(UserDateConfidence.init(rawValue:))
    }

    /// Derived — NEVER stored — date status. A user date with a missing
    /// or unrecognized confidence string counts as "estimated": that is
    /// the conservative default and matches the entry UI's default.
    public var userDateStatus: UserDateStatus {
        guard userDate != nil else { return .unconfirmed }
        return userDateConfidenceValue == .known ? .known : .estimated
    }

    /// Best-date SORT key for the catalog table's Date column.
    /// Ranking: user date (either confidence) > inferred date (OCR /
    /// transcript consensus) > file creation date > distant past.
    /// O(1) per record, pure integer math on the user-date path — safe
    /// for sort comparators over a 100k-row catalog.
    public var resolvedDateSortKey: Date {
        if let ud = userDate, let d = UserDateEntry.date(from: ud) { return d }
        // The container's own creation stamp (2026-08-16) outranks the
        // dossier's inference and the filesystem date — same order the
        // Master Archive resolver uses (RecordDateResolver).
        if let embedded = embeddedCreationDate { return embedded }
        if let inferred = inferredRecordDate { return inferred }
        return dateCreatedRaw ?? .distantPast
    }

    /// Best-date DISPLAY string for the catalog table's Date column.
    /// User dates render at their entered precision ("1992", "1992-06",
    /// "1992-06-14") with an " (est.)" suffix when they're a best guess;
    /// a known date renders bare. Falls back to the inferred date
    /// (yyyy-MM-dd), then the raw file-creation string. Empty when the
    /// record has no date signal at all (the cell shows "—").
    public var resolvedDateDisplay: String {
        if let ud = userDate {
            return userDateStatus == .known ? ud : ud + " (est.)"
        }
        if let embedded = embeddedCreationDate {
            return Self.isoDayString(from: embedded)
        }
        if let inferred = inferredRecordDate {
            return Self.isoDayString(from: inferred)
        }
        return dateCreated
    }

    /// Tooltip explaining WHERE the displayed date came from — the
    /// "small source indicator" from the issue, v1 form.
    public var resolvedDateHelp: String {
        switch userDateStatus {
        case .known:
            return "Your date — marked as known (certain at the precision you entered)"
        case .estimated:
            return "Your date — best guess. It outranks any machine date; refine it any time."
        case .unconfirmed:
            if embeddedCreationDate != nil {
                return "Creation date written inside the file by the camera or app that made it (\(embeddedDateOriginLabel)). Survives copies; enter your own in the inspector to override it."
            }
            if inferredRecordDate != nil {
                return "Date figured out from the video (on-screen dates / speech). Enter your own in the inspector to override it."
            }
            return "File creation date from filesystem metadata — often the transfer date, not when it was filmed. Enter the real date in the inspector."
        }
    }

    /// yyyy-MM-dd without a DateFormatter (DateFormatter is not
    /// Sendable, so a cached `static let` would trip strict concurrency
    /// in this package; Calendar IS Sendable and cheap to reuse).
    private static let utcGregorian: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }()

    private static func isoDayString(from date: Date) -> String {
        let dc = utcGregorian.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", dc.year ?? 0, dc.month ?? 0, dc.day ?? 0)
    }
}
