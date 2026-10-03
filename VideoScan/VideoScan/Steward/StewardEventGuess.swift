// StewardEventGuess.swift
// The Same-footage card's EVENT GUESS (Rick 2026-10-03: the steward should
// feel event-oriented — "there are 12 copies or similar clips of someone's
// 1st birthday"). ONE pure function: a footage group's date span plus the
// People tab's birthdays in, at most one guess out.
//
// It is a GUESS and always reads as one: the card shows it with a trailing
// "?" and the caption "a guess from the date". It is never written to the
// catalog, the ledger or a log — only a name the person confirms would be a
// fact, and footage naming does not exist yet (shown as a gap on the card).
//
// Rules, in order:
//   1. The span must be day-precise and no wider than `maxSpanDays`; the
//      group's date is the span's midpoint.
//   2. Birthday: the date is within ±`windowDays` of a person's birthday
//      anniversary, on or after the day they were born → "Alex's 3rd
//      birthday" (N = 0 → "the day Alex was born"). Several people match →
//      the YOUNGEST N wins (a 1st birthday beats a 34th); two people tie
//      on that N → no guess at all.
//   3. Otherwise a calendar anchor: Christmas (Dec 24–25), New Year's
//      (Dec 31–Jan 1), Fourth of July, Thanksgiving (4th Thursday of
//      November ±1 day), Halloween (Oct 31).
//
// (For Rick: an `enum` namespace of static functions over plain value
// structs — no state, callable from any thread. `Calendar` does the date
// arithmetic the way `mktime`/`gmtime` would in C, time zone included.)

import Foundation

struct StewardEventGuess: Sendable, Equatable {

    enum Kind: String, Sendable, Equatable {
        case birthday, bornDay, christmas, newYear, fourthOfJuly, thanksgiving, halloween
    }

    /// One People-tab person with a birthdate, as plain calendar parts
    /// (a `Date` would drag a time zone along — see AngelFamilyBirthdays).
    struct Person: Sendable, Equatable {
        var displayName: String
        var birthYear: Int
        var birthMonth: Int
        var birthDay: Int

        init(displayName: String, birthYear: Int, birthMonth: Int, birthDay: Int) {
            self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            self.birthYear = birthYear
            self.birthMonth = birthMonth
            self.birthDay = birthDay
        }

        /// From a stored birthdate, read in `calendar`.
        init(displayName: String, birthDate: Date, calendar: Calendar) {
            let c = calendar.dateComponents([.year, .month, .day], from: birthDate)
            self.init(displayName: displayName, birthYear: c.year ?? 0, birthMonth: c.month ?? 1, birthDay: c.day ?? 1)
        }
    }

    /// The earliest and latest DAY-PRECISE dates among a group's members.
    struct DateSpan: Sendable, Equatable {
        var earliest: Date
        var latest: Date

        init(earliest: Date, latest: Date) {
            self.earliest = min(earliest, latest)
            self.latest = max(earliest, latest)
        }

        var midpoint: Date { earliest.addingTimeInterval(latest.timeIntervalSince(earliest) / 2) }
    }

    var kind: Kind
    /// "Alex's 1st birthday" · "the day Alex was born" · "Christmas 2006".
    var text: String

    /// The card title: always phrased as a question.
    var title: String { "Around \(text)?" }

    /// The line under the title.
    static let caption = "a guess from the date"

    /// A birthday counts within this many days either side.
    static let windowDays = 3
    /// A span wider than this is too coarse to guess from.
    static let maxSpanDays = 14
    /// No "147th birthday".
    static let maxAge = 110

    // MARK: The guess (pure)

    nonisolated static func guess(groupDateSpan span: DateSpan?, people: [Person],
                                  calendar: Calendar) -> StewardEventGuess? {
        guard let span else { return nil }
        let firstDay = calendar.startOfDay(for: span.earliest)
        let lastDay = calendar.startOfDay(for: span.latest)
        guard let width = calendar.dateComponents([.day], from: firstDay, to: lastDay).day,
              width <= maxSpanDays else { return nil }
        let day = calendar.startOfDay(for: span.midpoint)
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day else { return nil }

        // 2. Birthdays — the youngest N wins; a tie on it means no guess.
        switch birthdayMatch(people: people, day: day, year: year, month: month, calendar: calendar) {
        case .tie: return nil
        case .person(let name, let n):
            return n == 0
                ? StewardEventGuess(kind: .bornDay, text: "the day \(name) was born")
                : StewardEventGuess(kind: .birthday, text: "\(name)'s \(ordinal(n)) birthday")
        case .nobody: break
        }

        // 3. Calendar anchors.
        switch (month, dayOfMonth) {
        case (12, 24), (12, 25): return StewardEventGuess(kind: .christmas, text: "Christmas \(year)")
        case (12, 31): return StewardEventGuess(kind: .newYear, text: "New Year's \(year + 1)")
        case (1, 1): return StewardEventGuess(kind: .newYear, text: "New Year's \(year)")
        case (7, 4): return StewardEventGuess(kind: .fourthOfJuly, text: "Fourth of July \(year)")
        case (10, 31): return StewardEventGuess(kind: .halloween, text: "Halloween \(year)")
        default: break
        }
        if month == 11, let turkey = thanksgivingDay(year: year, calendar: calendar),
           abs(dayOfMonth - turkey) <= 1 {
            return StewardEventGuess(kind: .thanksgiving, text: "Thanksgiving \(year)")
        }
        return nil
    }

    // MARK: Pieces (pure; tested directly)

    enum BirthdayMatch: Equatable {
        case nobody
        case person(name: String, number: Int)
        /// Two different people on the same, youngest number.
        case tie
    }

    nonisolated static func birthdayMatch(people: [Person], day: Date, year: Int, month: Int,
                                          calendar: Calendar) -> BirthdayMatch {
        var best: (n: Int, name: String)?
        var tied = false
        for person in people where !person.displayName.isEmpty {
            // Cheap first cut before any calendar arithmetic: a birthday
            // more than a month away (December and January are neighbours)
            // cannot be within three days.
            let monthsApart = abs(person.birthMonth - month)
            guard monthsApart <= 1 || monthsApart == 11 else { continue }
            guard let n = birthdayNumber(of: person, near: day, year: year, calendar: calendar) else { continue }
            if let current = best {
                if n < current.n {
                    best = (n, person.displayName)
                    tied = false
                } else if n == current.n, person.displayName != current.name {
                    tied = true
                }
            } else {
                best = (n, person.displayName)
            }
        }
        guard let best else { return .nobody }
        return tied ? .tie : .person(name: best.name, number: best.n)
    }

    /// N when `day` is within ±`windowDays` of the person's Nth birthday
    /// (0 = the day they were born; the date must not precede the birth).
    nonisolated static func birthdayNumber(of person: Person, near day: Date, year: Int,
                                           calendar: Calendar) -> Int? {
        var found: Int?
        // The anniversary nearest a late-December / early-January date can
        // sit in the neighbouring year.
        for candidateYear in [year - 1, year, year + 1] {
            let n = candidateYear - person.birthYear
            guard n >= 0, n <= maxAge,
                  let anniversary = calendar.date(from: DateComponents(year: candidateYear, month: person.birthMonth,
                                                                       day: person.birthDay)),
                  let apart = calendar.dateComponents([.day], from: calendar.startOfDay(for: anniversary), to: day).day,
                  abs(apart) <= windowDays else { continue }
            // Never "the day Alex was born" for footage dated before it.
            if n == 0, apart < 0 { continue }
            if found.map({ n < $0 }) ?? true { found = n }
        }
        return found
    }

    /// The day of November the 4th Thursday falls on (22…28).
    nonisolated static func thanksgivingDay(year: Int, calendar: Calendar) -> Int? {
        guard let first = calendar.date(from: DateComponents(year: year, month: 11, day: 1)) else { return nil }
        // Calendar weekdays: 1 = Sunday … 5 = Thursday.
        let weekday = calendar.component(.weekday, from: first)
        let firstThursday = 1 + (5 - weekday + 7) % 7
        return firstThursday + 21
    }

    /// 1 → "1st", 2 → "2nd", 11 → "11th", 23 → "23rd".
    nonisolated static func ordinal(_ n: Int) -> String {
        let lastTwo = n % 100
        if (11...13).contains(lastTwo) { return "\(n)th" }
        switch n % 10 {
        case 1: return "\(n)st"
        case 2: return "\(n)nd"
        case 3: return "\(n)rd"
        default: return "\(n)th"
        }
    }
}

// MARK: - The Same-footage card's title

/// Title precedence (Rick 2026-10-03): the person's NAME for the footage
/// when there is one, else the event guess (as a question), else the plain
/// description. `name` is always nil today — footage groups have nowhere to
/// keep a name yet — but the precedence is pinned so a name wins the day it
/// exists.
enum StewardFootageTitle {
    struct Lines: Sendable, Equatable {
        var title: String
        /// Under the title: the guess caption plus the plain description,
        /// or nil when the title IS the plain description.
        var caption: String?
        var isGuess: Bool
    }

    nonisolated static func lines(name: String?, guess: StewardEventGuess?, description: String) -> Lines {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return Lines(title: trimmed, caption: description, isGuess: false)
        }
        if let guess {
            return Lines(title: guess.title, caption: "\(StewardEventGuess.caption) · \(description)", isGuess: true)
        }
        return Lines(title: description, caption: nil, isGuess: false)
    }
}
