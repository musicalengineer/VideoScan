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
        if let normalized = normalizingSingleDate(text) { return normalized }
        let words = text.split(separator: " ").map { word -> String in
            let lower = word.lowercased()
            if let month = monthByToken[lower] { return month }
            if let qualifier = qualifierWords[word.uppercased()] { return qualifier }
            return String(word)
        }
        return words.joined(separator: " ")
    }

    /// Qualifiers that may lead a SINGLE date. "BET"/"AND"/"FROM"/"TO" are
    /// deliberately absent: they introduce a RANGE, which is two dates and
    /// must be left to the word-by-word path above.
    private static let singleDateQualifiers: [String: String] = [
        "bef": "before", "before": "before",
        "aft": "after", "after": "after",
        "abt": "about", "about": "about", "cal": "about", "est": "about",
        "int": "about", "cir": "about", "circa": "about",
    ]

    /// One free-text date, re-stated in the house format — or nil when the
    /// text is not unambiguously a single date, in which case the caller
    /// leaves it alone.
    ///
    /// WHY THIS EXISTS (live 2026-09-03, and the visible half of the demo
    /// bug). Hallie was reading Rick's late father's card as
    ///
    ///     "was born feberuary 22 1929 … and died june 22 2008"
    ///
    /// and that was NOT the model. The compiled tree stores those strings
    /// literally — `@I2@Richard Harding Breen Sr@F2@feberuary 22 1929june
    /// 22 2008` — and this function used to hand anything it could not
    /// recognise straight through. The transcript records the turn as
    /// `composedBy: template`, so no model and no verifier was ever in that
    /// sentence's path. Eileen Latta's card is stored as "Aug 31 1930" and
    /// "March 3, 2023", which is exactly why one answer showed four dates
    /// in four different shapes.
    ///
    /// WHAT IS AND IS NOT CHANGED. Day, month and year values are never
    /// altered, and a date that is not a single unambiguous date is not
    /// touched at all. Only PRESENTATION is normalised: word order, the
    /// comma, and the month's spelling — and a month is only re-spelled
    /// when exactly one month name is within a two-character slip of it,
    /// which is the same kind of expansion "FEB" → "February" already was.
    /// The underlying record is not corrected; that is Rick's to fix, and
    /// it should be surfaced to him rather than silently papered over.
    static func normalizingSingleDate(_ text: String) -> String? {
        var qualifier: String?
        var tokens = text.split(whereSeparator: { $0 == " " || $0 == "," })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        // "Abt. 10 Aug 1898" — Ancestry writes the qualifier with a full
        // stop, and Rick's tree carries both spellings.
        let lead = tokens[0].lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if let named = singleDateQualifiers[lead] {
            qualifier = named
            tokens.removeFirst()
        }
        guard !tokens.isEmpty, tokens.count <= 3 else { return nil }

        var day: Int?
        var month: String?
        var year: Int?
        for token in tokens {
            let bare = token.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            let ordinal = bare.replacingOccurrences(
                of: #"(st|nd|rd|th)$"#, with: "", options: .regularExpression)
            if let number = Int(ordinal), ordinal.allSatisfy(\.isNumber) {
                if ordinal.count >= 3 {
                    guard year == nil else { return nil }
                    year = number
                } else {
                    guard day == nil, number >= 1, number <= 31 else { return nil }
                    day = number
                }
                continue
            }
            guard month == nil, let named = monthNamed(bare) else { return nil }
            month = named
        }
        // A year is the one part a date cannot do without, and a bare day
        // with no month is not a date at all.
        guard let year, day == nil || month != nil else { return nil }

        var out = ""
        if let day { out += "\(day) " }
        if let month { out += month + " " }
        out += String(year)
        return qualifier.map { $0 + " " + out } ?? out
    }

    /// The month a lowercased word names: exactly, or — for a word no
    /// further than two characters from exactly one month — that month.
    /// "feberuary" → February. "march"/"mar"/"sept" → themselves. A word
    /// near two months, or near none, is not a month.
    static func monthNamed(_ lowercased: String) -> String? {
        if let exact = monthByToken[lowercased] { return exact }
        guard lowercased.count >= 4, lowercased.allSatisfy(\.isLetter) else { return nil }
        var best: (name: String, distance: Int)?
        var tied = false
        for name in longMonths {
            let distance = editDistance(lowercased, name.lowercased(), cap: 2)
            guard distance <= 2 else { continue }
            if let current = best {
                if distance < current.distance { best = (name, distance); tied = false }
                else if distance == current.distance, name != current.name { tied = true }
            } else {
                best = (name, distance)
            }
        }
        guard let best, !tied else { return nil }
        return best.name
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
