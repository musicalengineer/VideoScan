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
            /// A composed filename was shortened, embellished, or invented.
            /// File identity is exact evidence and may never be paraphrased.
            case alteredFilename
            case sentenceFragment
            case overSentenceBudget
            /// A sentence asserting she has no evidence/knowledge, inside a
            /// composition for an ANSWERED turn. Declines never reach the
            /// composer (HallieAnswerPlan.derive returns .fixed for them), so
            /// such a sentence is always noise — and it was landing in real
            /// answers: "I found 5877 catalog items matching that [c1]. I
            /// don't have evidence for that [c10]." (eval 2026-08-21).
            case falseNoEvidence
            /// A kept sentence that opens the answer but reads as the middle
            /// of one ("The other is …", "It was filmed in …") because the
            /// sentence it continued was dropped (eval 2026-08-21).
            case orphanedContinuation
            /// A sentence about the conversation rather than the claims —
            /// the model summarizing earlier turns from the history block:
            /// "I do not have evidence for how many videos you have or if you
            /// had cars when you were young [c1]." (eval 2026-08-21).
            case metaConversation
            /// "Two examples are Item 1 and Item 2" — the model echoed the
            /// plan's scaffolding instead of naming the files.
            case scaffoldLabel
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
        // "Two examples are …" citing two item claims: a count of the
        // claims the sentence itself rests on is vouched by construction
        // (the old "Item 2:" labels supplied that digit; sentence-shaped
        // item claims don't).
        if claims.count >= 2 {
            for n in 2...min(claims.count, 20) {
                allowed.insert(String(n))
                if let word = numberWords.first(where: { $0.value == String(n) })?.key {
                    allowed.insert(word)
                }
            }
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
            guard !isSentenceFragment(display) else {
                dropped.append(Dropped(text: raw, reason: .sentenceFragment))
                continue
            }
            // Composition only ever runs on ANSWERED turns, so a sentence
            // pleading ignorance cannot be a phrasing of an approved claim —
            // it is the model padding, or narrating the history block. Both
            // were observed corrupting good answers (eval 2026-08-21).
            if assertsNoEvidence(display), !planClaimsAssertNoEvidence(plan) {
                dropped.append(Dropped(text: raw, reason: .falseNoEvidence))
                continue
            }
            if isAboutTheConversation(display) {
                dropped.append(Dropped(text: raw, reason: .metaConversation))
                continue
            }
            if namesScaffoldLabel(display) {
                dropped.append(Dropped(text: raw, reason: .scaffoldLabel))
                continue
            }
            // An answer may not OPEN mid-thought. When sentence one is
            // dropped, sentence two ("The other is videocomplement…") is
            // left as the whole answer and reads as a non-sequitur
            // (eval 2026-08-21). Only the first kept sentence is checked;
            // later ones are legitimate continuations.
            if kept.isEmpty, isOrphanedContinuation(display) {
                dropped.append(Dropped(text: raw, reason: .orphanedContinuation))
                continue
            }
            if containsUnvouchedFilename(display, claims: claims) {
                dropped.append(Dropped(text: raw, reason: .alteredFilename))
                continue
            }
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

    /// Remove every exact item filename vouched for by this sentence's
    /// claims, then reject any file-looking token left behind. This catches
    /// omission as well as invention: `2006-xx-xx_Rick.mov` may not become
    /// `Rick.mov`, even though all remaining word tokens were present.
    private static func containsUnvouchedFilename(
        _ display: String,
        claims: [HallieAnswerPlan.Claim]
    ) -> Bool {
        var remainder = display.lowercased()
        for claim in claims {
            guard let filename = itemFilename(in: claim.text) else { continue }
            remainder = remainder.replacingOccurrences(
                of: filename.lowercased(), with: "")
        }
        return remainder.range(
            of: mediaFilenamePattern,
            options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The filename an item claim vouches for. Two claim shapes are
    /// recognised: the older label form "Item 1: file — why" (still used
    /// by tests and older plans) and the sentence form "One of them is
    /// file — why." (HallieAnswerPlan since overnight cycle 3).
    static func itemFilename(in claimText: String) -> String? {
        let prefixes = #"^(?:Item \d+:\s*|(?:One|Another|A third|A fourth|A fifth|A sixth|A seventh|An eighth) of them is\s+)"#
        guard let lead = claimText.range(of: prefixes, options: .regularExpression) else { return nil }
        var tail = String(claimText[lead.upperBound...]).trimmingCharacters(in: .whitespaces)
        if let separator = tail.range(of: " — ") {
            tail = String(tail[..<separator.lowerBound])
        }
        if let time = tail.range(of: #" at [0-9]+(?:\.[0-9]+)?s\.?$"#, options: .regularExpression) {
            tail = String(tail[..<time.lowerBound])
        }
        while tail.hasSuffix(".") { tail.removeLast() }
        return tail.isEmpty ? nil : tail
    }

    /// Keep this aligned with VideoScanModel's cataloged video and optional
    /// standalone-audio extensions. A shortened M2TS/MTS filename is just as
    /// much an invented evidence label as a shortened MOV filename.
    private static let mediaFilenamePattern: String = {
        let extensions = [
            "mov", "mp4", "m4v", "avi", "mkv", "mxf", "mts", "m2ts",
            "ts", "mpg", "mpeg", "m2v", "vob", "wmv", "asf", "webm",
            "ogv", "ogg", "rm", "rmvb", "divx", "flv", "f4v", "3gp",
            "3g2", "dv", "dif", "braw", "r3d", "vro", "mod", "tod",
            "wav", "aif", "aiff", "mp3", "mp2", "m4a", "aac", "flac",
            "caf", "wma", "ac3", "oga", "opus", "alac", "amr", "au",
            "snd",
        ]
        return "\\b[^\\s,;()]+\\.(?:"
            + extensions.joined(separator: "|") + ")\\b"
    }()

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

    /// A composed answer must be usable prose, not merely a fact-token
    /// subset. The verifier already blocks invented facts; this catches the
    /// complementary live failure where the model omitted the subject and
    /// returned "s father was …". Falling back to the complete deterministic
    /// sentence is safer than displaying a grammatically broken fragment.
    /// "Item 1", "item 2", "claim c3", "c1" as a word: plan scaffolding
    /// that must never reach the reader as if it were a name.
    static func namesScaffoldLabel(_ text: String) -> Bool {
        let pattern = #"(?i)\b(item|items|claim|claims|example)\s+#?\d+\b|\b(c|claim)\d+\b"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    static func isSentenceFragment(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return true }
        if trimmed.hasPrefix("'s ") || trimmed.hasPrefix("’s ") { return true }
        return first.isLowercase
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

    // MARK: - Noise checks (eval 2026-08-21)

    /// "I don't have evidence for that", "I do not know", "I couldn't find
    /// anything" — an assertion that she lacks knowledge.
    static let noEvidencePatterns = [
        "don't have evidence", "do not have evidence", "dont have evidence",
        "have no evidence", "don't know", "do not know", "dont know",
        "couldn't find", "could not find", "don't have any", "do not have any",
        "no information", "not sure about that", "cannot answer",
    ]

    static func assertsNoEvidence(_ sentence: String) -> Bool {
        let s = sentence.lowercased()
        return noEvidencePatterns.contains { s.contains($0) }
    }

    /// True when the PLAN itself is voicing an absence (a legitimate "I have
    /// nothing on that" claim the composer may faithfully phrase).
    static func planClaimsAssertNoEvidence(_ plan: HallieAnswerPlan) -> Bool {
        plan.claims.contains { assertsNoEvidence($0.text) }
    }

    /// Sentences that talk ABOUT the exchange instead of answering it —
    /// history narration ("earlier you asked", "your question", "as I said").
    static let metaConversationPatterns = [
        "you asked", "your question", "as i said", "as i mentioned",
        "earlier you", "you mentioned earlier", "in your previous",
        "the previous question", "you just asked", "going back to",
    ]

    static func isAboutTheConversation(_ sentence: String) -> Bool {
        let s = sentence.lowercased()
        return metaConversationPatterns.contains { s.contains($0) }
    }

    /// Openings that only make sense after a preceding sentence.
    static let continuationOpenings = [
        "the other", "the second", "the third", "the last", "the first is",
        "another", "also,", "it is", "it was", "they are", "they were",
        "these are from", "both", "the rest",
    ]

    static func isOrphanedContinuation(_ sentence: String) -> Bool {
        let s = sentence.lowercased().trimmingCharacters(in: .whitespaces)
        return continuationOpenings.contains { s.hasPrefix($0) }
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
