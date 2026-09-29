// EventLabeler.swift
// Event labels (Archive Angel rules v14, 2026-09-29; Rick approved steps
// a–c that day): what OCCASION a file records, derived from facts the
// catalog already has — never stored, never a background job.
//
// Rules v13 made the Angel's "event" an exact DAY ("d:1994-11-24"). That
// splits Christmas shot on the 24th and the 25th into two events, gives a
// Christmas tape with only a year no event at all, and knows nothing of
// "birthday" vs "trip". This file answers three questions, each with a
// human reason line:
//
//   calendar   a day-precise, trusted date on a holiday: Christmas (Dec
//              24–26), New Year (Dec 31–Jan 1; New Year's Eve belongs to
//              the NEW year), Thanksgiving (US, 4th Thursday of November
//              ±1 day), Easter (computus, Easter Sunday ±1), the Fourth of
//              July (Jul 3–5), Halloween (Oct 31), Mother's Day (2nd
//              Sunday of May), Father's Day (3rd Sunday of June).
//                "Dec 25 — Christmas"
//   birthday   the same trusted day within ±window days (default 3) of a
//              family birthday from the People tab, in a year after the
//              birth year (and not after a known death year). A Feb 29
//              birthday is kept on Feb 28 in common years. The nearest
//              anniversary wins, across New Year (Dec 30 is 2 days before
//              a Jan 1 birthday of the NEXT year). Several people → all.
//                "3 days after Timmy's 12th birthday"
//   name       a small curated lexicon in the file name and the two
//              nearest parent folders (not the volume, not /Users/<me>):
//              whole words only, case-insensitive, digits and punctuation
//              are word breaks ("xmas94_tape2" → xmas, tape) and so is a
//              camelCase hump ("ChristmasMorning" → christmas, morning).
//              A name word needs only a YEAR, so "xmas94_tape2.mov" whose
//              year resolved to 1994 is Christmas 1994.
//                "folder name says 'xmas'"
//
// Judgement calls (docs/archive_angel_policy.md, "Event labels"):
//   • Whole words: "capetown" and "partyline" are NOT cape / party; "Cape
//     Town" IS cape (accepted — a family archive's "Cape" is the Cape).
//   • "party" / "parties" mean birthday only when nothing else in the SAME
//     name is an event word: "xmas party" is Christmas, not a birthday.
//   • "disneyland" / "disneyworld" are listed explicitly (whole-word
//     matching would otherwise miss them); plurals likewise.
//
// PURE and O(characters): no I/O, no clock, no time zone (days are
// calendar days; the caller resolves the Date). ≈ a C++ free-function
// library over value types.

import Foundation

/// A calendar day — year, month, day in the proleptic Gregorian calendar,
/// no time zone. (≈ a POD triple.)
public struct EventDay: Sendable, Equatable, Hashable {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Julian day number; nil for an impossible date (Feb 30).
    var julianDay: Int? { EventLabeler.julianDay(year, month, day) }
}

/// One person's birthday from the People tab, as the labeler needs it.
/// The caller turns the profile's `Date` into calendar components.
public struct FamilyBirthday: Sendable, Equatable {
    /// The display name ("Timmy") — what the reason line says.
    public var name: String
    public var born: EventDay
    /// Year of death when known: no birthday after it.
    public var diedYear: Int?

    /// The name is trimmed here, once (a blank name labels nothing).
    public init(name: String, born: EventDay, diedYear: Int? = nil) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.born = born
        self.diedYear = diedYear
    }
}

/// One label on one file: which event, whose (birthdays), which year, where
/// it came from, and the sentence that says why.
public struct EventLabel: Sendable, Equatable, Hashable {
    public enum Source: String, Sendable {
        case calendar, birthday, name
    }

    /// Canonical event id: "christmas", "newyear", "thanksgiving",
    /// "easter", "july4", "halloween", "mothersday", "fathersday",
    /// "birthday", "wedding", "graduation", "vacation", "beach", "cape",
    /// "disney", "camp", "recital", "game".
    public var event: String
    /// The person whose birthday it is (calendar birthdays only; a
    /// "bday" in a name knows no person).
    public var person: String?
    /// The EVENT's year: New Year's Eve 1994 → 1995; a Dec 30 day before a
    /// Jan 1 birthday → the birthday's year. nil = no year known (a name
    /// word on an undated file): the label explains, but keys nothing.
    public var year: Int?
    public var source: Source
    /// Why, as data. The sentence (`reason`) is built only when someone
    /// reads it — the catalog-wide pass reads keys, never reasons, and
    /// 100k interpolated strings were most of its cost.
    public var why: Why

    public enum Why: Sendable, Equatable, Hashable {
        /// The day and the holiday's words: "Dec 25 — Christmas".
        case holiday(EventDay, String)
        /// Days from the anniversary (+ after, − before) and the age.
        case birthday(offset: Int, age: Int)
        /// Where the word was ("file" / "folder") and the word.
        case word(place: String, word: String)
    }

    public init(event: String, person: String? = nil, year: Int?, source: Source, why: Why) {
        self.event = event
        self.person = person
        self.year = year
        self.source = source
        self.why = why
    }

    /// "Dec 25 — Christmas", "3 days after Timmy's 12th birthday",
    /// "folder name says 'xmas'".
    public var reason: String {
        switch why {
        case .holiday(let day, let what):
            return "\(EventLabeler.shortDate(day)) — \(what)"
        case .word(let place, let word):
            return "\(place) name says '\(word)'"
        case .birthday(let offset, let age):
            let whose = "\(person ?? "someone")'s \(EventLabeler.ordinal(age)) birthday"
            switch offset {
            case 0: return "on " + whose
            case 1: return "1 day after " + whose
            case -1: return "1 day before " + whose
            case let n where n > 0: return "\(n) days after " + whose
            default: return "\(-offset) days before " + whose
            }
        }
    }

    /// "Christmas 1994", "Timmy's birthday 1994", "Birthday".
    public var title: String {
        let base = person.map { "\($0)'s birthday" } ?? EventLabeler.displayName(event)
        return year.map { "\(base) \($0)" } ?? base
    }

    /// The coverage key: "e:christmas:1994", "e:birthday:timmy:1994"; nil
    /// without a year (a word alone is not an event — "Christmas" across
    /// fifty years is fifty events).
    public var key: String? {
        guard let year else { return nil }
        if let person { return "e:birthday:" + EventLabeler.personKey(person) + ":" + String(year) }
        return "e:" + event + ":" + String(year)
    }
}

public enum EventLabeler {

    public static let defaultBirthdayWindowDays = 3
    /// The most a policy may widen the birthday window (a fortnight either
    /// side would already swallow most of a month).
    public static let maxBirthdayWindowDays = 14

    // MARK: All three

    /// Every label for one file: calendar and birthday labels when `day`
    /// is given (the caller passes a day only when it is day-precise AND
    /// trusted), then name labels, which take `day`'s year, else `year`.
    /// Order: calendar, birthday (nearest first), name (file, then the
    /// nearest folder). Pure.
    public static func labels(day: EventDay?, year: Int?, filename: String, fullPath: String,
                              birthdays: [FamilyBirthday] = [],
                              birthdayWindowDays: Int = defaultBirthdayWindowDays) -> [EventLabel] {
        var cache = FolderWordCache()
        return labels(day: day, year: year, filename: filename, fullPath: fullPath, birthdays: birthdays,
                      birthdayWindowDays: birthdayWindowDays, cache: &cache)
    }

    /// `labels` with a caller-owned folder cache — what a pass over the
    /// whole catalog uses (thousands of files share a folder; each folder
    /// is scanned once).
    public static func labels(day: EventDay?, year: Int?, filename: String, fullPath: String,
                              birthdays: [FamilyBirthday], birthdayWindowDays: Int,
                              cache: inout FolderWordCache) -> [EventLabel] {
        var out: [EventLabel] = []
        if let day {
            out += calendarLabels(day)
            if !birthdays.isEmpty, day.month >= 1, day.month <= 12, day.day >= 1, day.day <= 31 {
                let near = cache.table(birthdays, window: clampWindow(birthdayWindowDays))[
                    min(365, daysBeforeMonth[day.month - 1] + day.day)]
                if !near.isEmpty {
                    out += birthdayLabels(day, birthdays: birthdays, windowDays: birthdayWindowDays, only: near)
                }
            }
        }
        out += nameLabels(filename: filename, fullPath: fullPath, year: day?.year ?? year, cache: &cache)
        return out
    }

    /// The lexicon words of each parent directory and each file name seen
    /// in one pass, so each is scanned once: a catalog has thousands of
    /// files per folder and many same-named copies ("clip.mov", the same
    /// tape on three drives), and a hash lookup is far cheaper than the
    /// byte scan in a Debug build. Memory: one short array per DISTINCT
    /// directory and file name (the strings are shared, not copied) — at
    /// 100k files a few MB; the caller drops it with the pass. (≈ a
    /// std::unordered_map memo owned by the loop.)
    ///
    /// It also holds the pass's birthday table: day of the year → the
    /// birthdays within the window of it (366 short arrays), built on first
    /// use, so a dated file looks at the two or three people near its day
    /// instead of the whole family. One cache per pass, one birthday list.
    public struct FolderWordCache {
        var memo: [Substring: [(event: String, word: String)]] = [:]
        var stems: [String: [(event: String, word: String)]] = [:]
        var birthdayTable: [[Int]] = []
        var birthdayTableFor: (count: Int, window: Int) = (-1, -1)
        public init() {}
        public var directories: Int { memo.count }

        /// The birthday table for this list and window (rebuilt if either changed).
        mutating func table(_ birthdays: [FamilyBirthday], window: Int) -> [[Int]] {
            if birthdayTableFor.count == birthdays.count, birthdayTableFor.window == window { return birthdayTable }
            var t = [[Int]](repeating: [], count: 366)
            for (i, b) in birthdays.enumerated() where b.born.month >= 1 && b.born.month <= 12 && !b.name.isEmpty {
                let doy = EventLabeler.daysBeforeMonth[b.born.month - 1] + b.born.day
                for k in -(window + 1)...(window + 1) {
                    var d = doy + k
                    if d < 1 { d += 365 }
                    if d > 365 { d -= 365 }
                    if d >= 1, d <= 365, t[d].last != i { t[d].append(i) }
                }
            }
            birthdayTable = t
            birthdayTableFor = (birthdays.count, window)
            return t
        }
    }

    // MARK: Calendar

    /// The holiday (if any) this day belongs to. At most one per day
    /// today (no two windows overlap), returned as an array so a future
    /// overlap needs no signature change.
    public static func calendarLabels(_ d: EventDay) -> [EventLabel] {
        // Runs once per dated file in a 100k-record pass: a day with no
        // holiday allocates nothing.
        guard (1...12).contains(d.month), (1...31).contains(d.day) else { return [] }
        let hits = (fixedHoliday(d), moveableFeast(d))
        guard hits.0 != nil || hits.1 != nil, d.julianDay != nil else { return [] }
        var out: [EventLabel] = []
        if let hit = hits.0 { out.append(label(hit, d)) }
        if let hit = hits.1 { out.append(label(hit, d)) }
        return out
    }

    static func label(_ hit: Holiday, _ d: EventDay) -> EventLabel {
        EventLabel(event: hit.event, year: hit.year ?? d.year, source: .calendar, why: .holiday(d, hit.what))
    }

    /// (event, words, event year when not the day's own).
    typealias Holiday = (event: String, what: String, year: Int?)

    /// The fixed-date windows. New Year's Eve belongs to the NEW year.
    static func fixedHoliday(_ d: EventDay) -> Holiday? {
        switch (d.month, d.day) {
        case (12, 24): return ("christmas", "Christmas Eve", nil)
        case (12, 25): return ("christmas", "Christmas", nil)
        case (12, 26): return ("christmas", "the day after Christmas", nil)
        case (12, 31): return ("newyear", "New Year's Eve", d.year + 1)
        case (1, 1): return ("newyear", "New Year's Day", nil)
        case (7, 3): return ("july4", "the day before the Fourth of July", nil)
        case (7, 4): return ("july4", "the Fourth of July", nil)
        case (7, 5): return ("july4", "the day after the Fourth of July", nil)
        case (10, 31): return ("halloween", "Halloween", nil)
        default: return nil
        }
    }

    /// Thanksgiving ±1, Easter ±1, Mother's Day, Father's Day.
    static func moveableFeast(_ d: EventDay) -> Holiday? {
        func window(_ offset: Int, _ event: String, _ name: String, _ theDay: String) -> Holiday? {
            switch offset {
            case -1: return (event, "the day before \(name)", nil)
            case 0: return (event, theDay, nil)
            case 1: return (event, "the day after \(name)", nil)
            default: return nil
            }
        }
        switch d.month {
        case 11:
            guard let tg = nthWeekday(4, weekday: 4, month: 11, year: d.year) else { return nil }
            return window(d.day - tg, "thanksgiving", "Thanksgiving", "Thanksgiving")
        case 3, 4:
            guard let ej = easterSunday(year: d.year)?.julianDay, let jdn = d.julianDay else { return nil }
            return window(jdn - ej, "easter", "Easter", "Easter Sunday")
        case 5:
            return nthWeekday(2, weekday: 0, month: 5, year: d.year) == d.day ? ("mothersday", "Mother's Day", nil) : nil
        case 6:
            return nthWeekday(3, weekday: 0, month: 6, year: d.year) == d.day ? ("fathersday", "Father's Day", nil) : nil
        default:
            return nil
        }
    }

    /// Easter Sunday (Western, Gregorian) — the "Anonymous Gregorian
    /// algorithm" (Meeus/Jones/Butcher). Integer-only, valid for any
    /// Gregorian year. nil before 1583.
    public static func easterSunday(year y: Int) -> EventDay? {
        guard y >= 1583 else { return nil }
        let a = y % 19
        let b = y / 100, c = y % 100
        let d = b / 4, e = b % 4
        let f = (b + 8) / 25
        let g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4, k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let day = (h + l - 7 * m + 114) % 31 + 1
        return EventDay(year: y, month: month, day: day)
    }

    /// Day of the month of the `n`th `weekday` (0 = Sunday … 6 = Saturday)
    /// in that month; nil when the month has none (a 5th Monday).
    public static func nthWeekday(_ n: Int, weekday: Int, month: Int, year: Int) -> Int? {
        guard n >= 1, let first = julianDay(year, month, 1) else { return nil }
        let day = 1 + (weekday - dayOfWeek(first) + 7) % 7 + 7 * (n - 1)
        return julianDay(year, month, day) == nil ? nil : day
    }

    /// 0 = Sunday … 6 = Saturday, from a Julian day number.
    static func dayOfWeek(_ jdn: Int) -> Int { (jdn + 1) % 7 }

    static let daysInMonth = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    /// Days before each month in a common year (day-of-year = this + day).
    static let daysBeforeMonth = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]

    /// Julian day number (Fliegel & Van Flandern, the same integer math as
    /// `EmbeddedDateParser.julianDayNumber`) without its per-call month
    /// table — this runs a few times per dated file in a 100k pass. nil for
    /// an impossible date.
    static func julianDay(_ y: Int, _ m: Int, _ d: Int) -> Int? {
        guard m >= 1, m <= 12, d >= 1 else { return nil }
        let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
        guard d <= (m == 2 && leap ? 29 : daysInMonth[m - 1]) else { return nil }
        let a = (m - 14) / 12
        var jdn = (1461 * (y + 4800 + a)) / 4
        jdn += (367 * (m - 2 - 12 * a)) / 12
        jdn -= (3 * ((y + 4900 + a) / 100)) / 4
        return jdn + d - 32075
    }

    // MARK: Birthdays

    /// Family birthdays within ±`windowDays` of `d`, nearest first (then by
    /// name). Pure, O(birthdays); a birthday nowhere near the day costs
    /// two table reads (the day-of-year pre-check).
    public static func birthdayLabels(_ d: EventDay, birthdays: [FamilyBirthday], windowDays: Int) -> [EventLabel] {
        birthdayLabels(d, birthdays: birthdays, windowDays: windowDays, only: nil)
    }

    static func clampWindow(_ days: Int) -> Int { days < 0 ? 0 : (days > maxBirthdayWindowDays ? maxBirthdayWindowDays : days) }

    /// `only` = the indices worth checking (the pass's day-of-year table);
    /// nil = every birthday.
    static func birthdayLabels(_ d: EventDay, birthdays: [FamilyBirthday], windowDays: Int, only: [Int]?) -> [EventLabel] {
        guard d.month >= 1, d.month <= 12, let jdn = d.julianDay else { return [] }
        let window = clampWindow(windowDays)
        let doy = daysBeforeMonth[d.month - 1] + d.day
        var hits: [(offset: Int, label: EventLabel)] = []
        let n = only?.count ?? birthdays.count
        var k = 0
        while k < n {
            let b = birthdays[only?[k] ?? k]
            k += 1
            guard b.born.month >= 1, b.born.month <= 12, !b.name.isEmpty else { continue }
            // Pre-check on the day of the year (common-year table, so allow
            // one day of slack for Feb 29), circular across New Year. Plain
            // comparisons: this runs birthdays × dated files per pass.
            var apart = doy - (daysBeforeMonth[b.born.month - 1] + b.born.day)
            if apart < 0 { apart = -apart }
            if 365 - apart < apart { apart = 365 - apart }
            guard apart <= window + 1 else { continue }
            // The anniversary nearest this day — this year's, or across New
            // Year last or next year's.
            var bestOffset = 0, bestYear = 0, found = false
            for y in (d.year - 1)...(d.year + 1) {
                guard y > b.born.year, y <= (b.diedYear ?? Int.max),
                      let anniversary = anniversaryJulianDay(of: b.born, in: y) else { continue }
                let offset = jdn - anniversary
                let distance = offset < 0 ? -offset : offset
                guard distance <= window else { continue }
                if !found || distance < (bestOffset < 0 ? -bestOffset : bestOffset) {
                    bestOffset = offset
                    bestYear = y
                    found = true
                }
            }
            guard found else { continue }
            let name = b.name
            let best = (offset: bestOffset, year: bestYear)
            hits.append((best.offset, EventLabel(event: "birthday", person: name, year: best.year, source: .birthday,
                                                  why: .birthday(offset: best.offset, age: best.year - b.born.year))))
        }
        if hits.count == 1 { return [hits[0].label] }
        hits.sort { abs($0.offset) != abs($1.offset) ? abs($0.offset) < abs($1.offset)
                                                     : ($0.label.person ?? "") < ($1.label.person ?? "") }
        return hits.map(\.label)
    }

    /// The birthday's Julian day in `year`; a Feb 29 birthday is kept on
    /// Feb 28 in a common year (the family convention; a Mar 1 party is
    /// still inside the default ±3 window).
    static func anniversaryJulianDay(of born: EventDay, in year: Int) -> Int? {
        if let j = julianDay(year, born.month, born.day) { return j }
        if born.month == 2, born.day == 29 { return julianDay(year, 2, 28) }
        return nil
    }

    /// 1st, 2nd, 3rd, 4th … 11th, 12th, 13th … 21st, 101st, 111th.
    public static func ordinal(_ n: Int) -> String {
        let tens = n % 100
        if (11...13).contains(tens) { return "\(n)th" }
        switch n % 10 {
        case 1: return "\(n)st"
        case 2: return "\(n)nd"
        case 3: return "\(n)rd"
        default: return "\(n)th"
        }
    }

    /// The person part of a key: lowercased, spaces → "-", and never a key
    /// delimiter (":" or "|").
    static func personKey(_ name: String) -> String {
        String(name.lowercased().map { $0 == " " || $0 == ":" || $0 == "|" ? "-" : $0 })
    }

    // MARK: Names

    /// word → canonical event. Curated; every word ≥ 4 letters. The weak
    /// words ("party") count only when nothing else in the same name does.
    public static let lexicon: [String: String] = [
        "christmas": "christmas", "xmas": "christmas",
        "birthday": "birthday", "birthdays": "birthday", "bday": "birthday", "bdays": "birthday",
        "party": "birthday", "parties": "birthday",
        "thanksgiving": "thanksgiving",
        "easter": "easter",
        "halloween": "halloween",
        "wedding": "wedding", "weddings": "wedding",
        "graduation": "graduation",
        "vacation": "vacation", "vacations": "vacation", "trip": "vacation", "trips": "vacation",
        "beach": "beach",
        "cape": "cape",
        "disney": "disney", "disneyland": "disney", "disneyworld": "disney",
        "camp": "camp",
        "recital": "recital", "recitals": "recital",
        "game": "game", "games": "game",
    ]
    static let weakWords: Set<String> = ["party", "parties"]
    static let wordLengths: ClosedRange<Int> = {
        let counts = lexicon.keys.map(\.utf8.count)
        return (counts.min() ?? 1)...(counts.max() ?? 1)
    }()
    /// Bit (letter − 'a') set for every letter a lexicon word starts with —
    /// most words in a name are rejected on this and their length before
    /// any String is made (the pass runs over every file in the catalog).
    static let firstLetters: UInt32 = lexicon.keys.reduce(0) { mask, w in
        guard let f = w.utf8.first, isLower(f) else { return mask }
        return mask | (1 << UInt32(f - 0x61))
    }

    /// Name labels from the file name (extension dropped) and the two
    /// nearest parent folders; one label per event, the first source wins.
    public static func nameLabels(filename: String, fullPath: String, year: Int?) -> [EventLabel] {
        var cache = FolderWordCache()
        return nameLabels(filename: filename, fullPath: fullPath, year: year, cache: &cache)
    }

    public static func nameLabels(filename: String, fullPath: String, year: Int?,
                                  cache: inout FolderWordCache) -> [EventLabel] {
        var out: [EventLabel] = []
        let stemHits: [(event: String, word: String)]
        if let known = cache.stems[filename] {
            stemHits = known
        } else {
            stemHits = stemWords(filename)
            cache.stems[filename] = stemHits
        }
        for m in stemHits {
            out.append(EventLabel(event: m.event, year: year, source: .name, why: .word(place: "file", word: m.word)))
        }
        for m in folderWords(fullPath, cache: &cache) where !out.contains(where: { $0.event == m.event }) {
            out.append(EventLabel(event: m.event, year: year, source: .name, why: .word(place: "folder", word: m.word)))
        }
        return out
    }

    /// The two nearest folders' words (nearest first, each event once),
    /// scanned once per directory per cache.
    static func folderWords(_ fullPath: String, cache: inout FolderWordCache) -> [(event: String, word: String)] {
        guard let dirEnd = withBytes(fullPath, { lastSlash($0) }), dirEnd >= 0 else { return [] }
        let dir = fullPath[..<fullPath.utf8.index(fullPath.utf8.startIndex, offsetBy: dirEnd)]
        if let known = cache.memo[dir] { return known }
        let words: [(event: String, word: String)] = withBytes(fullPath) { bytes in
            var words: [(event: String, word: String)] = []
            let ranges = folderRanges(bytes, dirEnd: dirEnd)
            for range in [ranges.0, ranges.1] {
                guard let range else { continue }
                for m in scanWords(UnsafeBufferPointer(rebasing: bytes[range]))
                where !words.contains(where: { $0.event == m.event }) { words.append(m) }
            }
            return words
        }
        cache.memo[dir] = words
        return words
    }

    /// The file name's words, its extension dropped ("xmas94.mov" → xmas94).
    static func stemWords(_ filename: String) -> [(event: String, word: String)] {
        withBytes(filename) { bytes in
            var end = bytes.count
            var i = bytes.count - 1
            while i > 0 {                                   // a leading dot is not an extension
                if bytes[i] == 0x2E { end = i; break }
                i -= 1
            }
            return scanWords(UnsafeBufferPointer(rebasing: bytes[0..<end]))
        }
    }

    /// The lexicon words in one name, in order, each event once, the weak
    /// rule applied. ASCII case folding over UTF-8 bytes (a non-ASCII byte
    /// is part of a word and never in the lexicon). O(bytes), and no
    /// allocation for a name with no lexicon word in it.
    public static func nameWords(in text: Substring) -> [(event: String, word: String)] {
        if let found = text.utf8.withContiguousStorageIfAvailable({ scanWords($0) }) { return found }
        return Array(text.utf8).withUnsafeBufferPointer { scanWords($0) }
    }

    /// The scanner over raw bytes (≈ a C loop over a `const uint8_t *`).
    /// A word is a run of letters; digits, "_", "-", " ", "." end it, and
    /// so does a camelCase hump ("christmasMorning") or the last capital of
    /// a run before lowercase ("DVDXmas" → DVD | Xmas).
    static func scanWords(_ bytes: UnsafeBufferPointer<UInt8>) -> [(event: String, word: String)] {
        // Written as a plain loop with no captured state: in a Debug build a
        // nested closure boxes every variable it touches, and this loop runs
        // over every byte of every name in the catalog.
        var found: [(event: String, word: String)] = []
        var weak: (event: String, word: String)?
        var start = -1
        let count = bytes.count
        var i = 0
        while i <= count {
            // Byte class: 1 = upper, 2 = lower, 3 = other letter byte, 0 = break (or the end).
            let b: UInt8 = i < count ? bytes[i] : 0
            let kind: UInt8 = b >= 0x41 && b <= 0x5A ? 1 : (b >= 0x61 && b <= 0x7A ? 2 : (b >= 0x80 ? 3 : 0))
            var endsWord = kind == 0
            if kind == 1, start >= 0 {
                let prev = bytes[i - 1]
                let prevLower = prev >= 0x61 && prev <= 0x7A
                let prevUpper = prev >= 0x41 && prev <= 0x5A
                let nextLower = i + 1 < count && bytes[i + 1] >= 0x61 && bytes[i + 1] <= 0x7A
                endsWord = prevLower || (prevUpper && nextLower)
            }
            if endsWord, start >= 0 {
                if let hit = lexiconWord(bytes, from: start, to: i) {
                    if weakWords.contains(hit.word) {
                        if weak == nil { weak = hit }
                    } else if !found.contains(where: { $0.event == hit.event }) {
                        found.append(hit)
                    }
                }
                start = -1
            }
            if kind != 0, start < 0 { start = i }
            i += 1
        }
        if found.isEmpty, let weak { found.append(weak) }
        return found
    }

    /// The lexicon entry for bytes[from..<to], case-folded; nil (without
    /// making a String) unless the length and first letter could match.
    static func lexiconWord(_ bytes: UnsafeBufferPointer<UInt8>, from: Int, to: Int) -> (event: String, word: String)? {
        let n = to - from
        guard n >= wordLengths.lowerBound, n <= wordLengths.upperBound else { return nil }
        let first = bytes[from] | 0x20
        guard first >= 0x61, first <= 0x7A, firstLetters & (1 << UInt32(first - 0x61)) != 0 else { return nil }
        let w = String(unsafeUninitializedCapacity: n) { out in
            for k in 0..<n {
                let b = bytes[from + k]
                out[k] = b >= 0x41 && b <= 0x5A ? b + 32 : b
            }
            return n
        }
        guard let event = lexicon[w] else { return nil }
        return (event, w)
    }

    /// The string's UTF-8 bytes, in place when it is a native string (the
    /// usual case), copied otherwise. (≈ `s.c_str()`.)
    static func withBytes<R>(_ s: String, _ body: (UnsafeBufferPointer<UInt8>) -> R) -> R {
        if let r = s.utf8.withContiguousStorageIfAvailable(body) { return r }
        return Array(s.utf8).withUnsafeBufferPointer(body)
    }

    /// Byte offset of the last "/", or nil.
    static func lastSlash(_ bytes: UnsafeBufferPointer<UInt8>) -> Int? {
        var i = bytes.count - 1
        while i >= 0 {
            if bytes[i] == 0x2F { return i }
            i -= 1
        }
        return nil
    }

    static let volumesRoot: [UInt8] = Array("Volumes".utf8)
    static let usersRoot: [UInt8] = Array("Users".utf8)

    /// Does `bytes[at…]` spell `word` and stop there (end of the directory
    /// or a "/")?
    static func spells(_ bytes: UnsafeBufferPointer<UInt8>, at: Int, _ word: [UInt8], dirEnd: Int) -> Bool {
        guard at + word.count <= dirEnd else { return false }
        for k in 0..<word.count where bytes[at + k] != word[k] { return false }
        return at + word.count == dirEnd || bytes[at + word.count] == 0x2F
    }

    /// The byte ranges of the two nearest non-empty folder names in
    /// bytes[0..<dirEnd], nearest first — never the "/Volumes/<drive>" or
    /// "/Users/<me>" prefix (a drive named "Cape" is not a trip).
    static func folderRanges(_ bytes: UnsafeBufferPointer<UInt8>, dirEnd: Int) -> (Range<Int>?, Range<Int>?) {
        var floor = 0
        var p = 0
        if p < dirEnd, bytes[p] == 0x2F { p += 1 }
        let root = spells(bytes, at: p, volumesRoot, dirEnd: dirEnd) ? volumesRoot.count
            : (spells(bytes, at: p, usersRoot, dirEnd: dirEnd) ? usersRoot.count : 0)
        if root > 0 {
            var r = p + root + 1                             // past "Volumes/"
            while r < dirEnd, bytes[r] != 0x2F { r += 1 }    // past the drive (or user) name
            guard r < dirEnd else { return (nil, nil) }
            floor = r + 1
        }
        var found: [Range<Int>] = []
        var end = dirEnd
        while found.count < 2, end > floor {
            var s = end
            while s > floor, bytes[s - 1] != 0x2F { s -= 1 }
            if s < end { found.append(s..<end) }
            guard s > floor else { break }
            end = s - 1
        }
        return (found.first, found.count > 1 ? found[1] : nil)
    }

    @inline(__always) static func isUpper(_ b: UInt8) -> Bool { b >= 0x41 && b <= 0x5A }
    @inline(__always) static func isLower(_ b: UInt8) -> Bool { b >= 0x61 && b <= 0x7A }

    /// The two nearest parent folder names, nearest first — never the
    /// "/Volumes/<drive>" or "/Users/<me>" prefix. (Tests and callers
    /// that want the names; the pass uses `folderRanges` directly.)
    static func parentFolders(_ fullPath: String) -> [Substring] {
        withBytes(fullPath) { bytes -> [Substring] in
            guard let dirEnd = lastSlash(bytes) else { return [] }
            let ranges = folderRanges(bytes, dirEnd: dirEnd)
            let utf8 = fullPath.utf8
            return [ranges.0, ranges.1].compactMap { r -> Substring? in
                guard let r else { return nil }
                let lo = utf8.index(utf8.startIndex, offsetBy: r.lowerBound)
                let hi = utf8.index(utf8.startIndex, offsetBy: r.upperBound)
                return fullPath[lo..<hi]
            }
        }
    }

    // MARK: Words

    /// "Christmas", "New Year", "Fourth of July", "Birthday", …
    public static func displayName(_ event: String) -> String {
        switch event {
        case "christmas": return "Christmas"
        case "newyear": return "New Year"
        case "thanksgiving": return "Thanksgiving"
        case "easter": return "Easter"
        case "july4": return "Fourth of July"
        case "halloween": return "Halloween"
        case "mothersday": return "Mother's Day"
        case "fathersday": return "Father's Day"
        case "birthday": return "Birthday"
        default: return event.prefix(1).uppercased() + event.dropFirst()
        }
    }

    static let monthAbbreviations = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                     "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// "Dec 25".
    static func shortDate(_ d: EventDay) -> String {
        let m = (1...12).contains(d.month) ? monthAbbreviations[d.month - 1] : "?"
        return "\(m) \(d.day)"
    }
}
