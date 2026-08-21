// HallieCompositionVerifier.swift
// The deterministic leash on model phrasing. A composed answer is accepted
// sentence by sentence: each sentence must carry at least one bracket tag
// naming an existing claim, and may not introduce a year, number, or
// capitalized name that is absent from the claims it cites. Anything else is
// dropped and logged. Nothing here calls a model.

import Foundation

enum HallieCompositionVerifier {

    /// One sentence that survived: display text (tags stripped), transcript
    /// text (tags kept), and the claims it rests on.
    struct Sentence: Sendable, Equatable {
        let display: String
        let tagged: String
        let claimIDs: [String]
    }

    struct Dropped: Sendable, Equatable {
        enum Reason: String, Sendable, Equatable {
            case untagged
            case unknownClaimID
            case leakedYear
            case leakedNumber
            case leakedName
            case overSentenceBudget
        }
        let text: String
        let reason: Reason
    }

    struct Verification: Sendable, Equatable {
        let kept: [Sentence]
        let dropped: [Dropped]

        var displayText: String {
            kept.map(\.display).joined(separator: " ")
        }

        var transcriptText: String {
            kept.map(\.tagged).joined(separator: " ")
        }
    }

    /// Words that are capitalized in ordinary English without naming anyone.
    /// Anything else capitalized mid-sentence must come from a cited claim.
    private static let allowedCapitalized: Set<String> = [
        "i", "i'm", "i've", "i'd", "i'll", "ok", "okay",
    ]

    /// GEDCOM dates come as "12 MAR 1920"; a warm voice says "March 12,
    /// 1920". A month named in a cited claim vouches for both spellings —
    /// nothing new is asserted, only the abbreviation expanded.
    private static let monthPairs: [(short: String, long: String)] = [
        ("jan", "january"), ("feb", "february"), ("mar", "march"),
        ("apr", "april"), ("may", "may"), ("jun", "june"), ("jul", "july"),
        ("aug", "august"), ("sep", "september"), ("sept", "september"),
        ("oct", "october"), ("nov", "november"), ("dec", "december"),
    ]

    /// Spelled-out numbers are numbers: "seven children" must be vouched
    /// for by a "7" or "seven" in the cited claims. "one" is exempt — it is
    /// far more often a pronoun ("one of them") than a count.
    private static let numberWords: [String: String] = [
        "two": "2", "three": "3", "four": "4", "five": "5", "six": "6",
        "seven": "7", "eight": "8", "nine": "9", "ten": "10", "eleven": "11",
        "twelve": "12", "thirteen": "13", "fourteen": "14", "fifteen": "15",
        "sixteen": "16", "seventeen": "17", "eighteen": "18", "nineteen": "19",
        "twenty": "20", "thirty": "30", "forty": "40", "fifty": "50",
        "sixty": "60", "seventy": "70", "eighty": "80", "ninety": "90",
        "hundred": "100", "thousand": "1000", "million": "1000000",
    ]

    /// The vouched-for token set for a sentence: every token of its cited
    /// claims, plus month spellings and digit/word forms those tokens imply.
    static func allowedTokens(claims: [HallieAnswerPlan.Claim], personaName: String) -> Set<String> {
        var allowed = Set(claims.flatMap { tokens(of: $0.text) })
        allowed.formUnion(tokens(of: personaName))
        for pair in monthPairs {
            if allowed.contains(pair.short) { allowed.insert(pair.long) }
            if allowed.contains(pair.long) { allowed.insert(pair.short) }
        }
        for (word, digits) in numberWords where allowed.contains(digits) {
            allowed.insert(word)
        }
        return allowed
    }

    static func verify(
        _ composed: String,
        plan: HallieAnswerPlan,
        personaName: String
    ) -> Verification {
        let known = Dictionary(uniqueKeysWithValues: plan.claims.map { ($0.id, $0) })
        var kept: [Sentence] = []
        var dropped: [Dropped] = []

        for raw in splitSentences(composed) {
            let ids = claimTags(in: raw)
            guard !ids.isEmpty else {
                dropped.append(Dropped(text: raw, reason: .untagged))
                continue
            }
            let claims = ids.compactMap { known[$0] }
            guard claims.count == ids.count else {
                dropped.append(Dropped(text: raw, reason: .unknownClaimID))
                continue
            }
            let display = stripTags(raw)
            let allowedTokens = allowedTokens(claims: claims, personaName: personaName)
            if let reason = leak(in: display, allowed: allowedTokens) {
                dropped.append(Dropped(text: raw, reason: reason))
                continue
            }
            guard kept.count < plan.maxSentences else {
                dropped.append(Dropped(text: raw, reason: .overSentenceBudget))
                continue
            }
            kept.append(Sentence(display: display, tagged: raw, claimIDs: ids))
        }
        return Verification(kept: kept, dropped: dropped)
    }

    // MARK: - Sentences

    /// Split prose into sentences. A sentence ends at `.`, `!`, or `?`
    /// followed by whitespace, a tag, a closing quote, or the end of text
    /// (so "12.5s" and "donna_cape.mov" survive) or at a line break, and any
    /// bracket tags that immediately follow the terminator belong to the
    /// sentence they close ("… born in 1920. [c1]").
    static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        let scalars = Array(text)
        var index = 0
        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { sentences.append(trimmed) }
            current = ""
        }
        while index < scalars.count {
            let character = scalars[index]
            if character == "\n" {
                flush()
                index += 1
                continue
            }
            current.append(character)
            if character == "." || character == "!" || character == "?" {
                // Consume run-on terminators ("?!", "...").
                var lookahead = index + 1
                while lookahead < scalars.count,
                      [".", "!", "?"].contains(scalars[lookahead]) {
                    current.append(scalars[lookahead])
                    lookahead += 1
                }
                // Decimal / filename / abbreviation guard: "12.5s",
                // "donna_cape.mov", "b.1920" — a terminator glued to the next
                // word does not end a sentence.
                if lookahead < scalars.count,
                   scalars[lookahead].isLetter || scalars[lookahead].isNumber
                    || scalars[lookahead] == "_" {
                    index = lookahead
                    continue
                }
                // Closing quotes / parentheses stay with the sentence.
                while lookahead < scalars.count,
                      ["\"", "”", "’", "'", ")"].contains(scalars[lookahead]) {
                    current.append(scalars[lookahead])
                    lookahead += 1
                }
                // Consume trailing tags: whitespace then "[...]" groups.
                var probe = lookahead
                while true {
                    var spaces = probe
                    while spaces < scalars.count, scalars[spaces] == " " { spaces += 1 }
                    guard spaces < scalars.count, scalars[spaces] == "[",
                          let close = scalars[spaces...].firstIndex(of: "]") else { break }
                    current.append(contentsOf: scalars[probe...close])
                    probe = close + 1
                }
                flush()
                index = probe
                continue
            }
            index += 1
        }
        flush()
        return sentences
    }

    /// Claim IDs named by bracket tags: "[c1]", "[c1][c2]", "[c1, c3]".
    static func claimTags(in sentence: String) -> [String] {
        var ids: [String] = []
        var remainder = Substring(sentence)
        while let open = remainder.firstIndex(of: "["),
              let close = remainder[open...].firstIndex(of: "]") {
            let inner = remainder[remainder.index(after: open)..<close]
            for part in inner.split(whereSeparator: { $0 == "," || $0 == " " }) {
                let token = part.trimmingCharacters(in: .whitespaces)
                if isClaimID(token), !ids.contains(token) { ids.append(token) }
            }
            remainder = remainder[remainder.index(after: close)...]
        }
        return ids
    }

    private static func isClaimID(_ token: String) -> Bool {
        guard token.hasPrefix("c"), token.count > 1 else { return false }
        return token.dropFirst().allSatisfy(\.isNumber)
    }

    /// Remove every "[…]" group and tidy the spacing left behind.
    static func stripTags(_ text: String) -> String {
        var out = ""
        var depth = 0
        for character in text {
            if character == "[" { depth += 1; continue }
            if character == "]" { if depth > 0 { depth -= 1 }; continue }
            if depth == 0 { out.append(character) }
        }
        // Collapse doubled spaces and space-before-punctuation left by tags.
        var collapsed = ""
        var previousWasSpace = false
        for character in out {
            if character == " " {
                if previousWasSpace { continue }
                previousWasSpace = true
            } else {
                if [".", ",", "!", "?", ";", ":"].contains(character),
                   collapsed.last == " " {
                    collapsed.removeLast()
                }
                previousWasSpace = false
            }
            collapsed.append(character)
        }
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Fact leak check

    /// Lowercased alphanumeric tokens with possessives folded ("Donna's" →
    /// "donna"). Shared by the claim side and the sentence side so the two
    /// cannot tokenize differently.
    static func tokens(of text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "’s", with: "")
            .replacingOccurrences(of: "'s", with: "")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// The first leak found in a display sentence, or nil when every year,
    /// number, and mid-sentence capitalized word is vouched for by `allowed`.
    static func leak(in sentence: String, allowed: Set<String>) -> Dropped.Reason? {
        let words = sentence
            .replacingOccurrences(of: "’s", with: "")
            .replacingOccurrences(of: "'s", with: "")
            .split(whereSeparator: { $0 == " " || $0 == "\n" })
        for (position, word) in words.enumerated() {
            let pieces = word.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            for piece in pieces {
                let piece = String(piece)
                let lowered = piece.lowercased()
                if piece.allSatisfy(\.isNumber) {
                    if allowed.contains(lowered) { continue }
                    return piece.count == 4 ? .leakedYear : .leakedNumber
                }
                if numberWords[lowered] != nil, !allowed.contains(lowered) {
                    return .leakedNumber
                }
                guard let first = piece.first, first.isUppercase else { continue }
                if position == 0 { continue }          // sentence-initial word
                if allowedCapitalized.contains(lowered) { continue }
                if allowed.contains(lowered) { continue }
                return .leakedName
            }
        }
        return nil
    }
}
