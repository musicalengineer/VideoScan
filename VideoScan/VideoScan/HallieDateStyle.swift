// HallieDateStyle.swift
// The one place that RENDERS a family date, and the one place that knows
// what a date LOOKS LIKE in Hallie's prose. Both halves live together on
// purpose: the verifier must recognise exactly the shapes the renderers
// emit, and a second opinion about either would reopen the bug this file
// closes.
//
// Live 2026-09-03, Release build, "who are Tim's parents":
//
//   "… born feberuary 22 1929 in Boston …, died june 22 2008 in Brockton
//    …, Eileen Latta …, born August 31 1930 in Chelsea …, died March 3,
//    2023 in Stoughton …"
//
// Four dates, four formats, one misspelled month — inside a single
// sentence. The claim Swift handed the model was correct and uniform
// ("born 22 February 1929 in Boston, …"); the model re-typed the dates and
// the verifier had no rule that noticed. Structured output is unavailable
// on this ollama build (HTTP 501), so the model has latitude; the answer is
// to take dates out of the range of that latitude, not to ask for it back.
//
// Nothing here calls a model, touches the network, or reads global state.

import Foundation

enum HallieDateStyle {

    // MARK: - The house format

    /// "22 February 1929" — day first, month spelled out in full, no comma.
    ///
    /// Chosen, not invented. It is what the golden answers already pin
    /// (`HallieCrossWorldFamilyCardTests`, `LifeStatusTests`,
    /// `HallieAssumedBridgeProvenanceTests`) and what
    /// `ArchivistTemporalExecutor` and `ArchivistSelectionDateQuestion`
    /// already emit. Across the test tree and scripts it outnumbers
    /// "February 22, 1929" 74 to 11, and every one of those 11 is a
    /// simulated MODEL reply being fed to the verifier — never a rendering
    /// Swift is expected to produce.
    static let houseFormat = "d MMMM yyyy"

    /// The months in order, spelled the one way Hallie spells them.
    static let longMonths = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]

    /// Every spelling that names a month — full, GEDCOM three-letter, and
    /// the one four-letter variant ("SEPT") — mapped to the house spelling.
    /// Keys are lowercased.
    static let monthByToken: [String: String] = {
        var table: [String: String] = [:]
        for month in longMonths {
            table[month.lowercased()] = month
            table[String(month.prefix(3)).lowercased()] = month
        }
        table["sept"] = "September"
        return table
    }()

    /// A `Date` in the house format, in the given calendar. `en_US_POSIX`
    /// so a reader with a non-English system locale still gets the family's
    /// own wording rather than a localized month name that would not match
    /// the claims (isolation: this must not read global state).
    static func spoken(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = houseFormat
        return formatter.string(from: date)
    }

    /// The recorded GEDCOM date read aloud at its own precision and with
    /// its own qualifier: "28 FEB 1629" → "28 February 1629", "BEF 29 NOV
    /// 1717" → "before 29 November 1717", "ABT 1633" → "about 1633",
    /// "BET 1700 AND 1710" → "between 1700 and 1710". Anything else with a
    /// four-digit year passes through as written; no year → nil (a date we
    /// cannot read is not a date we can state).
    ///
    /// Moved here from `HallieBiographyCard` 2026-09-03 so the renderer and
    /// the verifier share one definition; that type now delegates.
    static func spoken(_ raw: String?) -> String? {
        guard let raw, GedcomYearInterval.parse(raw) != nil else { return nil }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop a calendar escape ("@#DJULIAN@ 1700").
        if text.hasPrefix("@#"), let close = text.firstIndex(of: " ") {
            text = String(text[text.index(after: close)...])
        }
        let words = text.split(separator: " ").map { word -> String in
            let lower = word.lowercased()
            if let month = monthByToken[lower] { return month }
            if let qualifier = qualifierWords[word.uppercased()] { return qualifier }
            return String(word)
        }
        return words.joined(separator: " ")
    }

    private static let qualifierWords: [String: String] = [
        "BEF": "before", "AFT": "after", "ABT": "about", "CAL": "about",
        "EST": "about", "INT": "about", "BET": "between", "AND": "and",
        "FROM": "from", "TO": "to",
    ]

    // MARK: - Dates as they appear in prose

    /// One date-shaped run of text found in a sentence or a claim.
    struct Occurrence: Sendable, Equatable {
        /// The exact substring, as written.
        let text: String
        /// True when every part of it is spelled the way a date is spelled
        /// (a real month name, or an all-numeric form). False when the
        /// month slot holds a word that is not a month — "feberuary".
        let namesARealMonth: Bool
    }

    /// Alternation of every month spelling, longest first so "sept" is not
    /// eaten by "sep" and "march" is not eaten by "mar".
    private static let monthAlternation: String =
        monthByToken.keys.sorted { $0.count > $1.count || ($0.count == $1.count && $0 < $1) }
            .joined(separator: "|")

    /// Patterns whose month slot is a genuine month name, longest shape
    /// first. Order matters: "22 February 1929" must be consumed before the
    /// bare "February 1929" pattern can claim its tail.
    private static var wellFormedPatterns: [String] {
        let month = "(?:\(monthAlternation))"
        return [
            // 22 February 1929   |   12 MAR 1920
            #"\b\d{1,2}(?:st|nd|rd|th)?\.?,?\s+"# + month + #"\.?,?\s+\d{3,4}\b"#,
            // February 22, 1929   |   Feb. 22 1929
            month + #"\.?,?\s+\d{1,2}(?:st|nd|rd|th)?\.?,?\s+\d{3,4}\b"#,
            // February 1929
            month + #"\.?,?\s+\d{3,4}\b"#,
            // 1929-02-22
            #"\b\d{4}-\d{2}-\d{2}\b"#,
            // 2/22/1929   |   22-2-1929
            #"\b\d{1,2}[/\-]\d{1,2}[/\-]\d{2,4}\b"#,
        ]
    }

    /// The month slot filled by a word that is NOT a month. Only ever
    /// consulted on text the well-formed patterns have already been
    /// removed from, so a correctly spelled date can never land here.
    private static let malformedMonthPatterns = [
        // feberuary 22 1929   |   Boston 22 1929
        #"\b([A-Za-z]{3,})\.?,?\s+(\d{1,2})(?:st|nd|rd|th)?\.?,?\s+(\d{3,4})\b"#,
        // 22 feberuary 1929
        #"\b(\d{1,2})(?:st|nd|rd|th)?\.?,?\s+([A-Za-z]{3,})\.?,?\s+(\d{3,4})\b"#,
    ]

    /// Every date-shaped run in `text`, in the order they appear.
    ///
    /// A bare year is deliberately NOT a date here: "died in 1906 in
    /// Chattanooga" is one fact the existing `leakedYear` rule already
    /// guards, and treating it as a date would drop honest sentences.
    static func occurrences(in text: String) -> [Occurrence] {
        var found: [(at: Int, occurrence: Occurrence)] = []
        // Mutable copy whose matched ranges are blanked as they are taken,
        // so no run of text is reported twice and the malformed pass never
        // re-reads a month it already recognised. NUL is not a word
        // character, so `\b` treats a blanked run as a separator.
        var scratch = Array(text)

        func take(_ pattern: String, namesARealMonth: Bool, accept: ((String) -> Bool)? = nil) {
            let current = String(scratch)
            guard let regex = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive]) else { return }
            let whole = NSRange(current.startIndex..., in: current)
            for match in regex.matches(in: current, range: whole) {
                guard let range = Range(match.range, in: current) else { continue }
                let piece = String(current[range])
                if let accept, !accept(piece) { continue }
                let start = current.distance(from: current.startIndex, to: range.lowerBound)
                let end = current.distance(from: current.startIndex, to: range.upperBound)
                guard start >= 0, end <= scratch.count, start < end else { continue }
                // A run glued to a filename or an identifier is not a date
                // the reader sees ("Cape_12_1994.mov"); the filename rule
                // owns those.
                if start > 0, "_-/".contains(scratch[start - 1]) { continue }
                if end < scratch.count, "_/".contains(scratch[end]) { continue }
                found.append((start, Occurrence(text: piece, namesARealMonth: namesARealMonth)))
                for index in start..<end { scratch[index] = "\u{0000}" }
            }
        }

        for pattern in wellFormedPatterns { take(pattern, namesARealMonth: true) }
        for pattern in malformedMonthPatterns {
            take(pattern, namesARealMonth: false, accept: isMonthLikeMisspelling)
        }
        return found.sorted { $0.at < $1.at }.map(\.occurrence)
    }

    /// True when the word sitting in a malformed date's month slot is
    /// plausibly a MONTH the model mistyped, rather than an ordinary word
    /// that happens to sit between two numbers.
    ///
    /// Two admissions, either of which suffices:
    ///   • it is within edit distance 2 of a month name ("feberuary",
    ///     "Feburary", "septmber"), or
    ///   • it is capitalized, so it reads to a person as a proper noun in
    ///     the month position ("born Boston 22 1929").
    /// A lowercase ordinary word is refused, so "born 22 1929" — where the
    /// model dropped the month entirely — is left to the year rule rather
    /// than mislabelled as a corrupted date.
    private static func isMonthLikeMisspelling(_ piece: String) -> Bool {
        let words = piece.split(whereSeparator: { !$0.isLetter })
        guard let word = words.first(where: { $0.count >= 3 }) else { return false }
        let lower = word.lowercased()
        if monthByToken[lower] != nil { return false }   // spelled correctly
        if word.first?.isUppercase == true { return true }
        return longMonths.contains { editDistance(lower, $0.lowercased(), cap: 2) <= 2 }
    }

    /// Levenshtein distance, abandoned once it exceeds `cap` (returns
    /// `cap + 1`). The C++ analogue is a banded DP over two rows.
    static func editDistance(_ lhs: String, _ rhs: String, cap: Int) -> Int {
        let a = Array(lhs), b = Array(rhs)
        if abs(a.count - b.count) > cap { return cap + 1 }
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var rowBest = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                rowBest = min(rowBest, current[j])
            }
            if rowBest > cap { return cap + 1 }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    // MARK: - What a claim vouches for

    /// The exact date strings a claim entitles a sentence to contain: each
    /// date as the claim writes it, plus — when the claim still carries a
    /// raw GEDCOM date — its house rendering, so "12 MAR 1920" may honestly
    /// become "12 March 1920" and nothing else.
    ///
    /// Deliberately NOT "any rendering of the same day". A date is exact
    /// evidence, like a filename: `HallieCompositionVerifier` may not
    /// paraphrase a filename and may not reformat a date, because the
    /// reader's eye is what this is protecting and four spellings of four
    /// dates in one sentence is what it looked like when nothing did.
    static func vouchedRenderings(in claimText: String) -> [String] {
        var out: [String] = []
        for occurrence in occurrences(in: claimText) where occurrence.namesARealMonth {
            out.append(occurrence.text)
            if let house = spoken(occurrence.text), house != occurrence.text {
                out.append(house)
            }
        }
        // Longest first: removing "22 February 1929" before "February 1929"
        // stops a short form from carving a hole in a long one.
        return out.sorted { $0.count > $1.count }
    }
}
