// HallieGeneralAnswerBoundary.swift
// The hard boundary on the general-knowledge lane: an answer composed
// without evidence may not assert anything about Rick's family, his media,
// or his archive.
//
// Rick's ruling 2026-09-03: general knowledge and advice, answered freely,
// yes — but "a general answer is never a channel for unverified family
// facts". This is the code that makes that true. It is deliberately NOT a
// prompt instruction: HallieSocialConversation's system prompt already asks
// the model not to do this, and a prompt is not a guarantee. Every general
// answer is inspected here before the reader sees it, and a violating
// answer is REPLACED — never edited, never partially shown, because half a
// fabricated sentence is still a fabricated sentence.
//
// Relationship to HallieCompositionVerifier: that verifier accepts a
// GROUNDED sentence when it cites a claim. This one is its mirror for the
// lane that has no claims at all — nothing about the family may appear,
// with or without a citation. The two never run on the same answer.

import Foundation

enum HallieGeneralAnswerBoundary {

    enum Violation: Equatable {
        /// The answer named someone the family knows.
        case familyName(String)
        /// "your grandmother", "his father" … followed by an assertion.
        case familyAssertion(referent: String, marker: String)
        /// A count of media: "you have 2,064 videos".
        case mediaCount(String)
        /// "in your archive", "the catalog holds", "I found …".
        case archivePossession(String)
        /// A catalog/tree-range year in the same sentence as the family.
        case familyDate(referent: String, year: String)

        var logDescription: String {
            switch self {
            case .familyName(let name):
                return "named a person the family knows (“\(name)”)"
            case .familyAssertion(let referent, let marker):
                return "asserted about “\(referent)” (“\(marker)”)"
            case .mediaCount(let phrase):
                return "claimed a media count (“\(phrase)”)"
            case .archivePossession(let phrase):
                return "spoke for the archive (“\(phrase)”)"
            case .familyDate(let referent, let year):
                return "dated “\(referent)” to \(year)"
            }
        }
    }

    /// What Hallie says instead. Warm, plain, brief — she is spoken aloud —
    /// and honest about WHY, without exposing the machinery.
    static let replacement = """
    I started to answer that, but what I had drifted into saying something about your family that I had not actually looked up. I would rather not guess there. Ask me about the family or the archive directly and I will answer from the records.
    """

    static let replacementNote = "boundary: general answer asserted a family fact"

    // MARK: - Entry point

    /// Inspect a general-lane reply and return the one that may be spoken.
    ///
    /// `isFamilyName` should be the widest oracle available (People-tab
    /// profiles, CyberBrain, GEDCOM); unlike the ROUTER, this side of the
    /// feature is allowed to over-refuse. A general answer that is wrongly
    /// declined costs a joke. A family fact invented in front of family
    /// costs the demo.
    static func enforce(
        _ reply: HallieSocialConversation.Reply,
        kind: HallieConversationKind,
        isFamilyName: (String) -> Bool,
        log: ((String) -> Void)? = nil
    ) -> HallieSocialConversation.Reply {
        // The deterministic boundaries (persona, safety) are fixed strings
        // this file wrote itself; they never need checking, and checking
        // them would be a way to break them.
        guard reply.composedByModel else { return reply }
        guard let violation = firstViolation(in: reply.text, isFamilyName: isFamilyName)
        else { return reply }

        // The refused text goes in the log. If Hallie declines during a
        // demo, Rick can see exactly what she almost said and decide
        // whether the boundary was right — a block with no evidence is
        // just as opaque as the claim it prevented.
        log?("[hallie-general] blocked: \(violation.logDescription) — replaced with the archive-boundary decline; refused: “\(reply.text.prefix(400))”")
        return HallieSocialConversation.Reply(
            text: replacement,
            composedByModel: false,
            note: replacementNote)
    }

    /// The first thing wrong with this text, or nil. Public so a test can
    /// name the exact shape it is pinning.
    static func firstViolation(
        in text: String,
        isFamilyName: (String) -> Bool
    ) -> Violation? {
        let inspected = removingBenignFormatting(from: text)
        // Whole-text checks first: a media count or an archive claim is
        // wrong wherever it appears.
        if let phrase = mediaCountPhrase(in: inspected) { return .mediaCount(phrase) }
        if let phrase = archivePossessionPhrase(in: inspected) {
            return .archivePossession(phrase)
        }
        if let name = familyNameMentioned(in: inspected, isFamilyName: isFamilyName) {
            return .familyName(name)
        }
        // Sentence-scoped checks: a family referent plus an assertion.
        for sentence in sentences(of: inspected) {
            if let violation = sentenceViolation(sentence) { return violation }
        }
        return nil
    }

    /// Strip only presentation characters that Markdown may put inside a
    /// safety-significant word. This is intentionally not a Markdown
    /// parser: emphasis cannot turn `remember`, `Donna`, or `your father`
    /// into tokens the boundary cannot see.
    private static func removingBenignFormatting(from text: String) -> String {
        text.replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "~", with: "")
    }

    // MARK: - Media counts

    /// "2064 videos", "twenty-three clips", "3 photos of them".
    static let countedMediaNouns = [
        "video", "videos", "clip", "clips", "photo", "photos", "photograph",
        "photographs", "picture", "pictures", "file", "files", "record",
        "records", "recording", "recordings", "tape", "tapes", "movie",
        "movies", "film", "films", "item", "items", "entry", "entries",
        "transcript", "transcripts", "caption", "captions",
    ]

    static func mediaCountPhrase(in text: String) -> String? {
        let normalized = HallieGeneralKnowledgeLane.normalize(text)
        let numberWord = "(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|million)"
        let count = "(?:\\d+(?:,\\d{3})*(?:\\.\\d+)?\\s*[km]?|(?:a\\s+)?\(numberWord)(?:[ -]+\(numberWord))*|a\\s+couple|a\\s+few|few|several|many|dozens|hundreds|thousands|lots\\s+of|plenty\\s+of)"
        let nouns = countedMediaNouns.joined(separator: "|")
        let descriptor = "(?:family|home|old|new|short|long|personal|digital|archived|archive|historic|historical|original|duplicate|silent|favorite|favourite)"
        // Only known media descriptors may bridge the count and noun. This
        // catches "2,064 family videos" without treating "Many people enjoy
        // films" as a count belonging to Rick's archive.
        let pattern = "\\b\(count)(?:\\s+of)?(?:\\s+\(descriptor)){0,2}\\s+(?:\(nouns))\\b"
        guard let expression = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(
                in: normalized,
                range: NSRange(normalized.startIndex..., in: normalized)),
              let range = Range(match.range, in: normalized)
        else { return nil }
        return String(normalized[range])
    }

    // MARK: - Speaking for the archive

    /// Phrases in which Hallie claims to have LOOKED, or states what the
    /// archive holds. In the general lane she has looked at nothing, so
    /// these are wrong wherever they appear.
    static let archivePossessionPhrases = [
        "the archive holds", "the archive has", "the archive contains",
        "the archive includes", "the catalog holds", "the catalog has",
        "the catalog contains", "the catalog includes",
        "the collection holds", "the collection has",
        "the collection contains", "the collection includes",
        "the footage holds", "the footage has", "the footage contains",
        "the footage includes", "the recordings contain",
        "the recordings include", "i found", "i discovered", "i located",
        "i uncovered", "i came across", "i looked", "i searched",
        "i checked the", "the records show",
        "according to the archive", "according to the catalog",
        "based on the archive", "based on the catalog",
        "we have on file", "you have on file",
        // First-person-plural forms that assert CONTENTS. A methodological
        // aside ("in our archive we rely on records to anchor the facts")
        // asserts nothing checkable and is left alone; "our archive has
        // three tapes of her" is a fact she did not look up.
        "our archive has", "our archive holds", "our archive contains",
        "our catalog has", "our catalog holds", "our catalog contains",
        "our collection has", "our collection holds", "our records show",
        "your archive has", "your archive holds", "your archive contains",
        "your archive includes", "your catalog has", "your catalog holds",
        "your catalog contains", "your collection has",
        "your collection holds", "your collection contains",
    ]

    /// Phrases that merely POINT AT the archive. Wrong when Hallie states
    /// what is in it, fine when she suggests the reader go and look —
    /// "you could look at old photos in the archive together" is the
    /// family-adjacent advice this lane exists to give. Judged with the
    /// same advice-before-referent rule as a family referent, so the two
    /// halves of the boundary behave alike.
    ///
    /// Live 2026-09-03: without this split, a perfectly good rainy-day
    /// suggestion was replaced by the decline because it said "in the
    /// archive".
    static let archiveReferencePhrases = [
        "your archive", "your catalog", "your collection", "your library",
        "in your archive", "in the archive", "in the catalog",
        "in your collection", "your videos", "your clips", "your footage",
        "your recordings", "your tapes", "your family tree",
        "the family tree",
    ]

    static func archivePossessionPhrase(in text: String) -> String? {
        let normalized = HallieGeneralKnowledgeLane.normalize(text)
        if let hit = archivePossessionPhrases.first(where: normalized.contains) {
            return hit
        }
        for sentence in sentences(of: text) {
            let lowered = HallieGeneralKnowledgeLane.normalize(sentence)
            guard let hit = archiveReferencePhrases.first(where: lowered.contains),
                  let hitRange = lowered.range(of: hit) else { continue }
            if isArchiveAdvice(around: hitRange, in: lowered) {
                continue
            }
            return hit
        }
        return nil
    }

    // MARK: - Names

    /// Kin words that make the following capitalised word a person's name.
    static let namingKinWords: Set<String> = [
        "grandma", "grandmother", "grandpa", "grandfather", "grandparent",
        "mom", "mum", "mother", "dad", "father", "parent", "brother",
        "sister", "uncle", "aunt", "cousin", "niece", "nephew", "son",
        "daughter", "child", "husband", "wife", "spouse", "nana",
        "great-grandmother", "great-grandfather", "namesake",
    ]

    /// Capitalised words that carry no person in ordinary English. Kept
    /// short on purpose: this list only prevents noise, it is not the
    /// safety mechanism.
    private static let ordinaryCapitalized: Set<String> = [
        "i", "i'm", "i've", "i'd", "i'll", "ok", "okay", "monday",
        "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july",
        "august", "september", "october", "november", "december",
        "christmas", "thanksgiving", "easter", "halloween", "english",
        "earth", "moon", "sun", "god", "internet",
    ]

    /// A name from the family — anywhere in the answer, in any position.
    ///
    /// `isFamilyName` must be PRECISE, not merely wide: it answers true for
    /// an inner-circle name (a People-tab profile, its aliases, its given
    /// name, a CyberBrain person) at any length, and for the 39k-person
    /// GEDCOM only on a multi-word name. Asking the tree about lone words
    /// would block "He", "The" and "Why" — a general answer opens a
    /// sentence with a capital letter every time. The shapes that matter
    /// are covered anyway: "Donna" (inner circle), "Muriel Lamb" (a tree
    /// pair) and "your grandmother Muriel" (a name introduced by a kin
    /// word, blocked whether or not anyone has heard of her).
    static func familyNameMentioned(
        in text: String,
        isFamilyName: (String) -> Bool
    ) -> String? {
        let maxRunWords = 8
        let maxSpanWords = 4
        let maxWideOracleQueries = 64
        var wideOracleQueries = 0
        let runs = capitalizedRuns(text)
        for run in runs {
            // A normal personal name does not contain nine uninterrupted
            // capitalised words. Fail closed before a Title-Case paragraph
            // can turn the 39k GEDCOM oracle into quadratic work.
            if run.words.count > maxRunWords {
                return run.words.prefix(maxSpanWords).joined(separator: " ")
            }
            // Punctuation and honorifics often attach harmless capitalised
            // words to a real name: "Sure, Donna" / "Dr. Muriel Lamb".
            // Ask about bounded contiguous subspans, longest first.
            let longest = min(run.words.count, maxSpanWords)
            for length in stride(from: longest, through: 1, by: -1) {
                for start in 0...(run.words.count - length) {
                    let candidate = run.words[start..<(start + length)]
                        .joined(separator: " ")
                    if length == 1,
                       ordinaryCapitalized.contains(candidate.lowercased()) {
                        continue
                    }
                    guard wideOracleQueries < maxWideOracleQueries else {
                        return candidate
                    }
                    wideOracleQueries += 1
                    if isFamilyName(candidate) { return candidate }
                }
            }
            // Any capitalised name-shaped run introduced by a kin word is
            // a fabricated relative whether or not the tree knows it.
            if run.precededByKinWord { return run.words.joined(separator: " ") }
        }

        let words = nameWords(text)
        for (index, word) in words.enumerated() {
            // The production oracle handles a lone token only for the
            // curated inner circle. This catches lowercase `donna` without
            // asking the 39k GEDCOM whether `old`, `star`, or `bread` is a
            // surname.
            // The lowercase name `mark` can be an infinitive verb. Exempt it
            // only when an object determiner proves that shape; `to donna`,
            // `to mark.` and `to mark was born` remain name candidates.
            let objectDeterminers: Set<String> = [
                "the", "a", "an", "this", "that", "your", "each", "every",
            ]
            let isMarkingVerb = word == "mark"
                && index > 0
                && words[index - 1].lowercased() == "to"
                && index + 1 < words.count
                && objectDeterminers.contains(words[index + 1].lowercased())
            if word.first?.isLowercase == true,
               !isMarkingVerb,
               isFamilyName(word) {
                return word
            }
            // Dictation can lowercase a surname after a correctly-cased
            // given name ("Muriel lamb"). Keep the wide oracle constrained
            // to this two-word, proper-name-shaped candidate.
            if word.first?.isUppercase == true,
               !ordinaryCapitalized.contains(word.lowercased()),
               index + 1 < words.count,
               words[index + 1].first?.isLowercase == true {
                let candidate = "\(word) \(words[index + 1])"
                if isFamilyName(candidate) { return candidate }
            }
        }
        return nil
    }

    private struct Run {
        let words: [String]
        let precededByKinWord: Bool
    }

    private static func capitalizedRuns(_ text: String) -> [Run] {
        let raw = nameWords(text)
        var runs: [Run] = []
        var index = 0
        while index < raw.count {
            guard raw[index].first?.isUppercase == true else { index += 1; continue }
            var end = index
            while end + 1 < raw.count, raw[end + 1].first?.isUppercase == true { end += 1 }
            let previous = index > 0 ? raw[index - 1].lowercased() : ""
            runs.append(Run(
                words: Array(raw[index...end]),
                precededByKinWord: namingKinWords.contains(previous)))
            index = end + 1
        }
        return runs
    }

    private static func nameWords(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "\u{2019}" })
            .map { word -> String in
                // "Muriel Lamb's" → "Lamb", so the pair still reads as the
                // name the tree stores.
                let lowered = word.lowercased()
                if lowered.hasSuffix("'s")
                    || lowered.hasSuffix("\u{2019}s")
                    || lowered.hasSuffix("\u{02BC}s") {
                    return String(word.dropLast(2))
                }
                return String(word)
            }
            .filter { !$0.isEmpty }
    }

    // MARK: - Family referents and assertions

    /// "your grandmother", "his father", "our family" …
    static let possessives: Set<String> = ["your", "his", "her", "their", "our", "my"]

    static let familyNouns: Set<String> = [
        "family", "grandmother", "grandma", "grandfather", "grandpa",
        "grandparents", "grandparent", "mother", "mom", "mum", "father",
        "dad", "parents", "parent", "brother", "sister", "siblings",
        "sibling", "uncle", "aunt", "cousin", "cousins", "niece",
        "nieces", "nephew", "nephews", "son", "sons", "daughter",
        "daughters",
        "children", "kids", "husband", "wife", "relatives", "ancestors",
        "relative", "ancestor", "nana", "grandchildren", "grandchild",
        "grandson", "grandsons", "granddaughter", "granddaughters",
        "spouse", "spouses", "namesake", "namesakes", "in-laws",
    ]

    /// Familiar claim words retained for a more useful refusal log. They
    /// are not the safety gate: any non-advice family referent is blocked.
    static let assertionMarkers = [
        "was born", "were born", "was married", "grew up", "passed away",
        "died", "lived in", "lived on", "worked as", "worked at",
        "served in", "immigrated", "came from", "moved to", "settled in",
        "probably", "likely", "must have", "would have", "may have",
        "might have", "i imagine", "i'd guess", "i would guess",
        "no doubt", "surely", "certainly", "used to",
    ]

    private static func sentenceViolation(_ sentence: String) -> Violation? {
        let normalized = HallieGeneralKnowledgeLane.normalize(sentence)
        guard let referent = familyReferent(in: normalized) else { return nil }

        // A catalog/tree-range year beside a relative is a date belonging
        // to a family member. Blocked whatever the sentence's shape: an
        // advice sentence has no business naming a year for someone.
        let tokens = HallieGeneralKnowledgeLane.words(normalized)
        if let year = tokens.first(where: { token in
            token.count == 4 && Int(token).map { (1700...2099).contains($0) } == true
        }) {
            return .familyDate(referent: referent, year: year)
        }

        // Only an advice verb that structurally governs the family referent
        // is safe. A stray earlier phrase is not a waiver: "Ask yourself:
        // your father served …" remains an unsupported family statement.
        if let referentRange = normalized.range(of: referent),
           isFamilyAdvice(around: referentRange, in: normalized) {
            return nil
        }
        let marker = assertionMarkers.first(where: normalized.contains)
            ?? "unsupported family statement"
        return .familyAssertion(referent: referent, marker: marker)
    }

    /// "your grandmother" / "our family" as literal text, so the violation
    /// can quote what it objected to.
    static func familyReferent(in normalized: String) -> String? {
        let tokens = HallieGeneralKnowledgeLane.words(normalized)
        for (index, token) in tokens.enumerated() where possessives.contains(token) {
            guard index + 1 < tokens.count else { continue }
            var nounIndex = index + 1
            var prefix = token
            if token == "your", tokens[nounIndex] == "own" {
                prefix = "your own"
                nounIndex += 1
                guard nounIndex < tokens.count else { continue }
            }
            var next = tokens[nounIndex]
            if familyNouns.contains(next) { return "\(prefix) \(next)" }
            // "your great-grandmother" survives the word split as two
            // tokens; rejoin one hop.
            if next == "great", nounIndex + 1 < tokens.count {
                next = tokens[nounIndex + 1]
                if familyNouns.contains(next) { return "\(prefix) great \(next)" }
            }
        }
        return nil
    }

    private static func isFamilyAdvice(
        around referentRange: Range<String.Index>,
        in sentence: String
    ) -> Bool {
        let prefix = String(sentence[..<referentRange.lowerBound])
        let suffix = String(sentence[referentRange.upperBound...])
        guard !suffix.contains(where: { [",", ":", "—", "–"].contains($0) }),
              familyReferent(in: suffix) == nil
        else { return false }
        let suffixWords = HallieGeneralKnowledgeLane.words(suffix)
        let adviceComplements: Set<String> = [
            "about", "what", "where", "when", "why", "how", "whether",
            "if", "to", "for",
        ]
        guard suffixWords.first.map(adviceComplements.contains) ?? true else {
            return false
        }
        var words = HallieGeneralKnowledgeLane.words(prefix)
        if words.first == "perhaps" || words.first == "maybe" {
            words.removeFirst()
        }
        let adviceActions: Set<String> = [
            "ask", "asking", "invite", "inviting", "encourage", "encouraging",
        ]
        guard let action = words.last, adviceActions.contains(action) else {
            return false
        }

        if words.count == 1 { return true }
        if words.count == 2,
           ["consider", "try"].contains(words[0]) {
            return true
        }
        if words.count == 3,
           ["start", "begin"].contains(words[0]),
           words[1] == "by" {
            return true
        }

        let modals: Set<String> = ["could", "might", "may", "can", "should", "would"]
        guard words.count >= 3,
              words.count <= 6,
              words[0] == "you",
              modals.contains(words[1])
        else { return false }

        var bridge = Array(words.dropFirst(2).dropLast())
        let adviceAdverbs: Set<String> = [
            "gently", "kindly", "carefully", "privately", "directly",
            "simply", "first", "perhaps", "maybe", "quietly", "very",
        ]
        while bridge.first.map(adviceAdverbs.contains) == true {
            bridge.removeFirst()
        }
        return bridge.isEmpty
            || bridge == ["consider"]
            || bridge == ["try"]
            || bridge == ["start", "by"]
            || bridge == ["begin", "by"]
    }

    private static func isArchiveAdvice(
        around referenceRange: Range<String.Index>,
        in sentence: String
    ) -> Bool {
        let prefix = String(sentence[..<referenceRange.lowerBound])
        let suffix = String(sentence[referenceRange.upperBound...])
        guard !suffix.contains(where: { [",", ":", "—", "–"].contains($0) })
        else { return false }
        let words = HallieGeneralKnowledgeLane.words(prefix)
        guard words.count >= 3,
              words[0] == "you",
              ["could", "might", "may", "can", "should"].contains(words[1])
        else { return false }
        let archiveActions: Set<String> = [
            "look", "search", "browse", "check", "review", "explore",
            "label", "organize", "preserve", "share", "watch", "listen",
        ]
        return archiveActions.contains(words[2])
    }

    /// Split on sentence-final punctuation. Worst case is one composed
    /// reply — HallieSocialConversation caps it at 1,200 bytes and four
    /// sentences — so this allocates a handful of short strings and never
    /// grows with the catalog.
    static func sentences(of text: String) -> [String] {
        text.split(whereSeparator: {
            $0 == "." || $0 == "?" || $0 == "!" || $0 == ";"
                || $0 == "\u{2026}" || $0.isNewline
        })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
