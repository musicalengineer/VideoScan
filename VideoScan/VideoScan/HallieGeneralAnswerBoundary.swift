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
        // Whole-text checks first: a media count or an archive claim is
        // wrong wherever it appears.
        if let phrase = mediaCountPhrase(in: text) { return .mediaCount(phrase) }
        if let phrase = archivePossessionPhrase(in: text) {
            return .archivePossession(phrase)
        }
        if let name = familyNameMentioned(in: text, isFamilyName: isFamilyName) {
            return .familyName(name)
        }
        // Sentence-scoped checks: a family referent plus an assertion.
        for sentence in sentences(of: text) {
            if let violation = sentenceViolation(sentence) { return violation }
        }
        return nil
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

    private static let writtenNumbers = [
        "one", "two", "three", "four", "five", "six", "seven", "eight",
        "nine", "ten", "eleven", "twelve", "dozens", "hundreds",
        "thousands", "several", "many", "a few", "lots of", "plenty of",
    ]

    static func mediaCountPhrase(in text: String) -> String? {
        let tokens = HallieGeneralKnowledgeLane.words(
            HallieGeneralKnowledgeLane.normalize(text))
        for (index, token) in tokens.enumerated() where index + 1 < tokens.count {
            let isCount = token.allSatisfy(\.isNumber) || writtenNumbers.contains(token)
            guard isCount else { continue }
            // "23 clips" and "dozens of files" are the same claim.
            let next = tokens[index + 1]
            if countedMediaNouns.contains(next) { return "\(token) \(next)" }
            if next == "of", index + 2 < tokens.count,
               countedMediaNouns.contains(tokens[index + 2]) {
                return "\(token) of \(tokens[index + 2])"
            }
        }
        return nil
    }

    // MARK: - Speaking for the archive

    /// Phrases in which Hallie claims to have LOOKED, or states what the
    /// archive holds. In the general lane she has looked at nothing, so
    /// these are wrong wherever they appear.
    static let archivePossessionPhrases = [
        "the archive holds", "the archive has", "the catalog holds",
        "the catalog has", "i found", "i looked", "i searched",
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
            let hitOffset = lowered.distance(from: lowered.startIndex,
                                             to: hitRange.lowerBound)
            if let adviceOffset = earliestIndex(of: adviceMarkers, in: lowered),
               adviceOffset <= hitOffset {
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
        let runs = capitalizedRuns(text)
        for run in runs {
            let joined = run.words.joined(separator: " ")
            if run.words.count > 1 {
                if isFamilyName(joined) { return joined }
                if run.words.count > 2 {
                    let pair = run.words.prefix(2).joined(separator: " ")
                    if isFamilyName(pair) { return pair }
                }
                // Any capitalised pair introduced by a kin word is a
                // fabricated relative whether or not the tree knows it:
                // "your grandmother Muriel Lamb".
                if run.precededByKinWord { return joined }
                continue
            }
            let lone = joined
            if run.precededByKinWord { return lone }
            if ordinaryCapitalized.contains(lone.lowercased()) { continue }
            if isFamilyName(lone) { return lone }
        }
        return nil
    }

    private struct Run {
        let words: [String]
        let precededByKinWord: Bool
    }

    private static func capitalizedRuns(_ text: String) -> [Run] {
        let raw = text.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "\u{2019}" })
            .map { word -> String in
                // "Muriel Lamb's" → "Lamb", so the pair still reads as the
                // name the tree stores.
                let lowered = word.lowercased()
                if lowered.hasSuffix("'s") || lowered.hasSuffix("\u{2019}s") {
                    return String(word.dropLast(2))
                }
                return String(word)
            }
            .filter { !$0.isEmpty }
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

    // MARK: - Family referents and assertions

    /// "your grandmother", "his father", "our family" …
    static let possessives = ["your", "his", "her", "their", "our", "my", "your own"]

    static let familyNouns: Set<String> = [
        "family", "grandmother", "grandma", "grandfather", "grandpa",
        "grandparents", "grandparent", "mother", "mom", "mum", "father",
        "dad", "parents", "parent", "brother", "sister", "siblings",
        "uncle", "aunt", "cousin", "cousins", "son", "daughter",
        "children", "kids", "husband", "wife", "relatives", "ancestors",
        "ancestor", "nana", "grandchildren", "in-laws",
    ]

    /// Words that turn a mention of a relative into a CLAIM about them —
    /// a finished-life verb, a speculation, or a life event.
    static let assertionMarkers = [
        "was born", "were born", "was married", "grew up", "passed away",
        "died", "lived in", "lived on", "worked as", "worked at",
        "served in", "immigrated", "came from", "moved to", "settled in",
        "probably", "likely", "must have", "would have", "may have",
        "might have", "i imagine", "i'd guess", "i would guess",
        "no doubt", "surely", "certainly", "used to",
    ]

    /// Second-person advice is safe: it instructs the READER, it does not
    /// assert. "You might ask your grandmother what her childhood was
    /// like" is exactly the answer Rick asked for.
    static let adviceMarkers = [
        "you could", "you might", "you may", "you can", "you should",
        "you would", "you'd", "try ", "consider ", "ask ", "asking ",
        "invite ", "inviting ", "encourage ", "encouraging ",
        "start by", "begin by",
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

        // Advice that comes BEFORE the relative is instruction, not
        // assertion. `ask your grandmother …` / `you might ask your aunt …`
        if let adviceIndex = earliestIndex(of: adviceMarkers, in: normalized),
           let referentIndex = normalized.range(of: referent)?.lowerBound,
           adviceIndex <= normalized.distance(from: normalized.startIndex, to: referentIndex) {
            return nil
        }
        if let marker = assertionMarkers.first(where: normalized.contains) {
            return .familyAssertion(referent: referent, marker: marker)
        }
        return nil
    }

    /// "your grandmother" / "our family" as literal text, so the violation
    /// can quote what it objected to.
    static func familyReferent(in normalized: String) -> String? {
        let tokens = HallieGeneralKnowledgeLane.words(normalized)
        for (index, token) in tokens.enumerated() where possessives.contains(token) {
            guard index + 1 < tokens.count else { continue }
            var next = tokens[index + 1]
            if familyNouns.contains(next) { return "\(token) \(next)" }
            // "your great-grandmother" survives the word split as two
            // tokens; rejoin one hop.
            if next == "great", index + 2 < tokens.count {
                next = tokens[index + 2]
                if familyNouns.contains(next) { return "\(token) great \(next)" }
            }
        }
        return nil
    }

    private static func earliestIndex(of needles: [String], in text: String) -> Int? {
        var best: Int?
        for needle in needles {
            guard let range = text.range(of: needle) else { continue }
            let offset = text.distance(from: text.startIndex, to: range.lowerBound)
            best = min(best ?? offset, offset)
        }
        return best
    }

    /// Split on sentence-final punctuation. Worst case is one composed
    /// reply — HallieSocialConversation caps it at 1,200 bytes and four
    /// sentences — so this allocates a handful of short strings and never
    /// grows with the catalog.
    static func sentences(of text: String) -> [String] {
        text.split(whereSeparator: { $0 == "." || $0 == "?" || $0 == "!" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
