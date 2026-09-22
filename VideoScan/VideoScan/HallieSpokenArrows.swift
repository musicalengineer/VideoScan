// HallieSpokenArrows.swift
// Arrows are for the eye, not the ear (Rick 2026-09-21: "These → signs can
// be spoken as begat or whatever, not x-x or whatever she tries to say").
//
// Hallie's lineage answers draw a chain from the DESCENDANT up to the
// ancestor, in two shapes (live transcript, 2026-09-21):
//   A) plain names:   "Line: Richard Harding Breen Jr → Richard Harding
//                      Breen Sr → Muriel Lamb → Edith Lucy Parker → …"
//   B) relation-led:  "(Richard Harding Breen Jr → mother Eileen Latta →
//                      her father David McGill Latta Sr)"
// "Begat" would read the chain backwards, so in the SPOKEN text only:
//   A → ", child of "   (no sex is plumbed here; "child of" everywhere)
//   B → ", whose <relation> is "   ("her father" → "whose father is")
// Any other arrow ("1990 → 1995", "Boston → Chicago" outside a lineage)
// is spoken "to". ASCII "->", "=>" and "⇒" (and the heavier Unicode
// arrows) are treated the same, so no arrow ever reaches the voice as a
// symbol. The displayed answer keeps its arrows — HallieSpeaker.spokenText
// is the only caller.
//
// Pure text work; think of it as a static helper over std::regex.

import Foundation

enum HallieSpokenArrows {

    /// Every arrow spelling, with the spaces around it.
    private static let arrow = try! NSRegularExpression(
        pattern: #"\s*(?:→|⟶|⇒|➔|➜|➝|->|=>)\s*"#)

    /// A relation word opening the segment after an arrow, with an optional
    /// possessive in front ("her father", "his great-grandmother",
    /// "half-brother", "mother-in-law"). Group 1 = the relation itself.
    private static let relation = try! NSRegularExpression(
        pattern: #"^(?:(?:her|his|their|your|my|its)\s+)?((?:(?:great-)*grand|step-?|half-)?(?:mother|father|parent|son|daughter|child|brother|sister|sibling)(?:-in-law)?|wife|husband|spouse|partner|aunt|uncle|niece|nephew|cousin)\b\s*"#,
        options: [.caseInsensitive])

    /// Words that say the arrows on this line are a line of descent even
    /// when there is only one of them ("The recorded line: A → B.").
    private static let lineageCue = try! NSRegularExpression(
        pattern: #"\b(?:line|lineage|descent|descends?|descended|ancestors?|ancestry|pedigree|generations?|path|chain)\b"#,
        options: [.caseInsensitive])

    /// The spoken form of `text`; unchanged when it has no arrow.
    static func spoken(_ text: String) -> String {
        guard text.range(of: #"→|⟶|⇒|➔|➜|➝|->|=>"#, options: .regularExpression) != nil else { return text }
        return text.components(separatedBy: "\n").map(spokenLine).joined(separator: "\n")
    }

    private static func spokenLine(_ line: String) -> String {
        let whole = NSRange(line.startIndex..., in: line)
        let matches = arrow.matches(in: line, range: whole)
        guard !matches.isEmpty else { return line }

        // Split into segments between arrows: seg0 → seg1 → … → segN.
        var segments: [String] = []
        var cursor = line.startIndex
        for match in matches {
            guard let range = Range(match.range, in: line) else { continue }
            segments.append(String(line[cursor..<range.lowerBound]))
            cursor = range.upperBound
        }
        segments.append(String(line[cursor...]))

        let isLineage = matches.count >= 2
            || lineageCue.firstMatch(in: line, range: whole) != nil

        var out = segments[0]
        for index in 1..<segments.count {
            let previous = segments[index - 1]
            let segment = segments[index]
            out += connector(after: previous, before: segment, isLineage: isLineage, isFirst: index == 1)
        }
        return out
    }

    /// The words that replace one arrow, followed by the (possibly
    /// rewritten) segment after it.
    private static func connector(after previous: String, before segment: String,
                                  isLineage: Bool, isFirst: Bool) -> String {
        // Shape B: "→ her father David …" → ", whose father is David …".
        let range = NSRange(segment.startIndex..., in: segment)
        if let match = relation.firstMatch(in: segment, range: range),
           let whole = Range(match.range, in: segment),
           let word = Range(match.range(at: 1), in: segment) {
            var rest = String(segment[whole.upperBound...])
            // Kinship prose writes "father (David Latta)": drop the parens.
            if rest.hasPrefix("("), let close = rest.firstIndex(of: ")") {
                rest.remove(at: close)
                rest.removeFirst()
            }
            if !rest.trimmingCharacters(in: .whitespaces).isEmpty {
                return ", whose \(segment[word].lowercased()) is " + rest
            }
        }
        // A leading arrow with nothing before it: just drop the symbol.
        if isFirst, previous.trimmingCharacters(in: .whitespaces).isEmpty {
            return segment
        }
        let before = previous.trimmingCharacters(in: .whitespaces)
        let after = segment.trimmingCharacters(in: .whitespaces)
        // A chain that trails off ("… → …") trails off in speech too.
        if isLineage, after.hasPrefix("…") || after.hasPrefix("...") {
            return " " + segment
        }
        // Numbers either side are a range: "1990 → 1995".
        if before.last?.isNumber == true, after.first?.isNumber == true {
            return " to " + segment
        }
        // Shape A: name → name on a line of descent.
        if isLineage, after.first?.isUppercase == true,
           let last = before.last, last.isLetter || last == "." || last == ")" {
            return ", child of " + segment
        }
        return " to " + segment
    }
}
