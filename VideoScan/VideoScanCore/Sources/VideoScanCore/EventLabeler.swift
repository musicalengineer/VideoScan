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
    var julianDay: Int? { EmbeddedDateParser.julianDayNumber(year: year, month: month, day: day) }
}

/// One person's birthday from the People tab, as the labeler needs it.
/// The caller turns the profile's `Date` into calendar components.
public struct FamilyBirthday: Sendable, Equatable {
    /// The display name ("Timmy") — what the reason line says.
    public var name: String
    public var born: EventDay
    /// Year of death when known: no birthday after it.
    public var diedYear: Int?

    public init(name: String, born: EventDay, diedYear: Int? = nil) {
        self.name = name
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
    /// "Dec 25 — Christmas", "3 days after Timmy's 12th birthday",
    /// "folder name says 'xmas'".
    public var reason: String

    public init(event: String, person: String? = nil, year: Int?, source: Source, reason: String) {
        self.event = event
        self.person = person
        self.year = year
        self.source = source
        self.reason = reason
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
        if let person { return "e:birthday:\(EventLabeler.personKey(person)):\(year)" }
        return "e:\(event):\(year)"
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
        var out: [EventLabel] = []
        if let day {
            out += calendarLabels(day)
            if !birthdays.isEmpty { out += birthdayLabels(day, birthdays: birthdays, windowDays: birthdayWindowDays) }
        }
        out += nameLabels(filename: filename, fullPath: fullPath, year: day?.year ?? year)
        return out
    }

    // MARK: Calendar

    /// The holiday (if any) this day belongs to. At most one per day
    /// today (no two windows overlap), returned as an array so a future
    /// overlap needs no signature change.
    public static func calendarLabels(_ d: EventDay) -> [EventLabel] {
        guard let jdn = d.julianDay else { return [] }
        var out: [EventLabel] = []
        func add(_ event: String, _ what: String, year: Int? = nil) {
            out.append(EventLabel(event: event, year: year ?? d.year, source: .calendar,
                                  reason: "\(shortDate(d)) — \(what)"))
        }
        // Fixed dates.
        switch (d.month, d.day) {
        case (12, 24): add("christmas", "Christmas Eve")
        case (12, 25): add("christmas", "Christmas")
        case (12, 26): add("christmas", "the day after Christmas")
        case (12, 31): add("newyear", "New Year's Eve", year: d.year + 1)
        case (1, 1): add("newyear", "New Year's Day")
        case (7, 3): add("july4", "the day before the Fourth of July")
        case (7, 4): add("july4", "the Fourth of July")
        case (7, 5): add("july4", "the day after the Fourth of July")
        case (10, 31): add("halloween", "Halloween")
        default: break
        }
        // Moveable feasts.
        if d.month == 11, let tg = nthWeekday(4, weekday: 4, month: 11, year: d.year) {
            switch d.day - tg {
            case -1: add("thanksgiving", "the day before Thanksgiving")
            case 0: add("thanksgiving", "Thanksgiving")
            case 1: add("thanksgiving", "the day after Thanksgiving")
            default: break
            }
        }
        if d.month == 3 || d.month == 4, let easter = easterSunday(year: d.year), let ej = easter.julianDay {
            switch jdn - ej {
            case -1: add("easter", "the day before Easter")
            case 0: add("easter", "Easter Sunday")
            case 1: add("easter", "the day after Easter")
            default: break
            }
        }
        if d.month == 5, nthWeekday(2, weekday: 0, month: 5, year: d.year) == d.day { add("mothersday", "Mother's Day") }
        if d.month == 6, nthWeekday(3, weekday: 0, month: 6, year: d.year) == d.day { add("fathersday", "Father's Day") }
        return out
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
        guard n >= 1, let first = EmbeddedDateParser.julianDayNumber(year: year, month: month, day: 1) else { return nil }
        let day = 1 + (weekday - dayOfWeek(first) + 7) % 7 + 7 * (n - 1)
        return EmbeddedDateParser.julianDayNumber(year: year, month: month, day: day) == nil ? nil : day
    }

    /// 0 = Sunday … 6 = Saturday, from a Julian day number.
    static func dayOfWeek(_ jdn: Int) -> Int { (jdn + 1) % 7 }

    // MARK: Birthdays

    /// Family birthdays within ±`windowDays` of `d`, nearest first (then by
    /// name). Pure, O(birthdays).
    public static func birthdayLabels(_ d: EventDay, birthdays: [FamilyBirthday], windowDays: Int) -> [EventLabel] {
        guard let jdn = d.julianDay else { return [] }
        let window = max(0, min(windowDays, maxBirthdayWindowDays))
        var hits: [(offset: Int, label: EventLabel)] = []
        for b in birthdays {
            let name = b.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            // The anniversary nearest this day — this year's, or across New
            // Year last or next year's.
            var best: (offset: Int, year: Int)?
            for y in (d.year - 1)...(d.year + 1) {
                guard y > b.born.year, b.diedYear.map({ y <= $0 }) ?? true,
                      let anniversary = anniversaryJulianDay(of: b.born, in: y) else { continue }
                let offset = jdn - anniversary
                guard abs(offset) <= window else { continue }
                if best.map({ abs(offset) < abs($0.offset) }) ?? true { best = (offset, y) }
            }
            guard let best else { continue }
            let whose = "\(name)'s \(ordinal(best.year - b.born.year)) birthday"
            let reason: String
            switch best.offset {
            case 0: reason = "on " + whose
            case 1: reason = "1 day after " + whose
            case -1: reason = "1 day before " + whose
            case let n where n > 0: reason = "\(n) days after " + whose
            default: reason = "\(-best.offset) days before " + whose
            }
            hits.append((best.offset, EventLabel(event: "birthday", person: name, year: best.year,
                                                  source: .birthday, reason: reason)))
        }
        hits.sort { abs($0.offset) != abs($1.offset) ? abs($0.offset) < abs($1.offset)
                                                     : ($0.label.person ?? "") < ($1.label.person ?? "") }
        return hits.map(\.label)
    }

    /// The birthday's Julian day in `year`; a Feb 29 birthday is kept on
    /// Feb 28 in a common year (the family convention; a Mar 1 party is
    /// still inside the default ±3 window).
    static func anniversaryJulianDay(of born: EventDay, in year: Int) -> Int? {
        if let j = EmbeddedDateParser.julianDayNumber(year: year, month: born.month, day: born.day) { return j }
        if born.month == 2, born.day == 29 { return EmbeddedDateParser.julianDayNumber(year: year, month: 2, day: 28) }
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

    /// Name labels from the file name (extension dropped) and the two
    /// nearest parent folders; one label per event, the first source wins.
    public static func nameLabels(filename: String, fullPath: String, year: Int?) -> [EventLabel] {
        var out: [EventLabel] = []
        var seen: Set<String> = []
        func scan(_ text: Substring, _ place: String) {
            for m in nameWords(in: text) where seen.insert(m.event).inserted {
                out.append(EventLabel(event: m.event, year: year, source: .name, reason: "\(place) name says '\(m.word)'"))
            }
        }
        scan(stem(filename), "file")
        for folder in parentFolders(fullPath) { scan(folder, "folder") }
        return out
    }

    /// The lexicon words in one name, in order, each event once, the weak
    /// rule applied. ASCII case folding over UTF-8 bytes (a non-ASCII byte
    /// is part of a word and never in the lexicon). O(bytes).
    public static func nameWords(in text: Substring) -> [(event: String, word: String)] {
        var found: [(event: String, word: String)] = []
        var weak: (event: String, word: String)?
        var word: [UInt8] = []
        word.reserveCapacity(16)
        func flush() {
            defer { word.removeAll(keepingCapacity: true) }
            guard wordLengths.contains(word.count) else { return }
            let w = String(decoding: word, as: UTF8.self)
            guard let event = lexicon[w] else { return }
            if weakWords.contains(w) {
                if weak == nil { weak = (event, w) }
            } else if !found.contains(where: { $0.event == event }) {
                found.append((event, w))
            }
        }
        let bytes = Array(text.utf8)
        for i in bytes.indices {
            let b = bytes[i]
            let upper = isUpper(b), lower = isLower(b)
            guard upper || lower || b >= 0x80 else { flush(); continue }   // digits, "_", "-", " ", "." break words
            if upper, i > 0, !word.isEmpty {
                // A camelCase hump: "christmasMorning", or the last capital
                // of a run before lowercase: "DVDXmas" → DVD | Xmas.
                let prev = bytes[i - 1]
                let nextLower = i + 1 < bytes.count && isLower(bytes[i + 1])
                if isLower(prev) || (isUpper(prev) && nextLower) { flush() }
            }
            word.append(upper ? b + 32 : b)
        }
        flush()
        if found.isEmpty, let weak { found.append(weak) }
        return found
    }

    @inline(__always) static func isUpper(_ b: UInt8) -> Bool { b >= 0x41 && b <= 0x5A }
    @inline(__always) static func isLower(_ b: UInt8) -> Bool { b >= 0x61 && b <= 0x7A }

    /// The file name without its extension ("xmas94.mov" → "xmas94").
    static func stem(_ filename: String) -> Substring {
        guard let dot = filename.lastIndex(of: "."), dot != filename.startIndex else { return filename[...] }
        return filename[..<dot]
    }

    /// The two nearest parent folder names, nearest first — never the
    /// "/Volumes/<drive>" or "/Users/<me>" prefix (a drive named "Cape"
    /// is not a trip).
    static func parentFolders(_ fullPath: String) -> [Substring] {
        var parts = fullPath.split(separator: "/")
        guard !parts.isEmpty else { return [] }
        parts.removeLast()                                   // the file itself
        if let first = parts.first, first == "Volumes" || first == "Users" { parts.removeFirst(min(2, parts.count)) }
        return Array(parts.suffix(2).reversed())
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
