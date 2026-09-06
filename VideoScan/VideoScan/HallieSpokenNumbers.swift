import Foundation

/// Numbers, said the way a person says them — decided HERE, not left to
/// whichever speech engine happens to be installed.
///
/// Rick, 2026-09-06, on hearing Hallie read his father's birth date:
/// "the way she pronounced it was '1 february 19-9'". "21 February 1929"
/// went to `kokoro-tts` as digits and came back missing both instances of
/// "twenty" — 2.35 s of audio where the same date written in words takes
/// 3.17 s. Whether that particular engine improves is beside the point: an
/// app whose main job is speaking dates should not be discovering how each
/// engine feels about numerals. This runs before synthesis on BOTH paths
/// (Kokoro and Apple), and never touches the text on screen.
enum HallieSpokenNumbers {

    private static let months = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]

    private static let ones = [
        "", "one", "two", "three", "four", "five", "six", "seven", "eight",
        "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
        "sixteen", "seventeen", "eighteen", "nineteen",
    ]
    private static let tens = [
        "", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy",
        "eighty", "ninety",
    ]

    /// 0–99 in words. "twenty-one", not "twenty one" — the hyphen is how
    /// the compound is written, and every engine we use reads it as one word.
    static func words(under100 value: Int) -> String {
        guard value > 0, value < 100 else { return value == 0 ? "zero" : "\(value)" }
        if value < 20 { return ones[value] }
        let ten = tens[value / 10]
        let one = value % 10
        return one == 0 ? ten : "\(ten)-\(ones[one])"
    }

    /// Ordinals for days of the month. Only 1–31 is ever needed here.
    static func ordinal(day value: Int) -> String {
        guard (1...31).contains(value) else { return "\(value)" }
        switch value {
        case 1: return "first"
        case 2: return "second"
        case 3: return "third"
        case 5: return "fifth"
        case 8: return "eighth"
        case 9: return "ninth"
        case 12: return "twelfth"
        case 20: return "twentieth"
        case 30: return "thirtieth"
        default: break
        }
        if value < 20 { return ones[value] + "th" }
        let one = value % 10
        if one == 0 { return "\(tens[value / 10])th" }
        return "\(tens[value / 10])-\(ordinal(day: one))"
    }

    /// A YEAR, said as a year: 1929 is "nineteen twenty-nine", not "one
    /// thousand nine hundred twenty-nine". The century-pair reading is what
    /// makes a spoken date sound like a date.
    ///
    /// The exceptions are the ones English actually makes:
    ///   1900 → "nineteen hundred"      (not "nineteen zero zero")
    ///   1905 → "nineteen oh five"      (not "nineteen five")
    ///   2000 → "two thousand"
    ///   2005 → "two thousand five"
    /// The 2000s genuinely are read differently from the 1900s, which is why
    /// this is a table of habits rather than an algorithm.
    static func words(year value: Int) -> String {
        guard (1000...2099).contains(value) else { return "\(value)" }
        let century = value / 100
        let remainder = value % 100
        if value >= 2000 {
            if remainder == 0 { return "two thousand" }
            if remainder < 10 { return "two thousand \(ones[remainder])" }
            return "two thousand \(words(under100: remainder))"
        }
        let centuryWords = words(under100: century)
        if remainder == 0 { return "\(centuryWords) hundred" }
        if remainder < 10 { return "\(centuryWords) oh \(ones[remainder])" }
        return "\(centuryWords) \(words(under100: remainder))"
    }

    /// Rewrite a sentence for speech. Two rules, both narrow:
    ///
    ///   "21 February 1929"  → "the twenty-first of February, nineteen twenty-nine"
    ///   "in 1994"           → "in nineteen ninety-four"
    ///
    /// Deliberately NOT a general number expander. Counts read fine as
    /// digits ("123 videos"), file names must never be touched
    /// ("Cape_1993.mov"), and a rule that rewrote every number would find
    /// far more ways to be wrong than right.
    static func spoken(_ text: String) -> String {
        var out = text

        // Day + month, longest first so the day is consumed before the
        // bare-year rule can reach the year beside it.
        for month in months {
            let pattern = #"\b(\d{1,2}) "# + month + #"\b(,? (1[0-9]{3}|20[0-9]{2})\b)?"#
            out = replacing(out, pattern: pattern) { groups in
                guard let day = groups[1].flatMap(Int.init), (1...31).contains(day) else { return nil }
                var said = "the \(ordinal(day: day)) of \(month)"
                if let year = groups[3].flatMap(Int.init) {
                    said += ", \(words(year: year))"
                }
                return said
            }
        }

        // Any remaining standalone year. Guarded by a boundary on both
        // sides, so "Cape_1993.mov" and "p216" are untouched — an
        // underscore and a letter are both word characters, so `\b` does
        // not fire inside them.
        out = replacing(out, pattern: #"(?<![\w.-])(1[0-9]{3}|20[0-9]{2})(?![\w.-])"#) { groups in
            groups[1].flatMap(Int.init).map { words(year: $0) }
        }
        return out
    }

    /// Regex replace with a closure over captured groups. Applied
    /// back-to-front so earlier ranges stay valid.
    private static func replacing(
        _ text: String,
        pattern: String,
        _ transform: ([String?]) -> String?
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var out = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            var groups: [String?] = []
            for index in 0..<match.numberOfRanges {
                groups.append(Range(match.range(at: index), in: text).map { String(text[$0]) })
            }
            guard let said = transform(groups),
                  let whole = Range(match.range, in: out) else { continue }
            out.replaceSubrange(whole, with: said)
        }
        return out
    }
}
