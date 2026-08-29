// HalliePronunciationPicker.swift
// The variations picker (Rick, 2026-08-29, no microphone connected): "maybe
// we need her to say Latta a few different ways until she gets it right and
// I click on the correct one". Hallie offers a few ways to say a name —
// chips in the chat window, a numbered list in the shell and on the web —
// each spoken with misaki's inline phoneme override; Rick clicks (or says
// the number), and the chosen phonemes are kept as taught
// (`source: picked`). "None of these" turns the next page; when the pages
// run out she asks for a respelling or a hint.
//
// Pure and client-agnostic like HalliePronunciationDrillMode: the offer
// rides in the Response / shell Session turn to turn; this file decides
// what a reply means and what Hallie says. No I/O, no model. Candidate
// generation is PronunciationVariations; the write-through and the drill
// bookkeeping are the coordinator's and the shell's (their +Picker files).

import Foundation
import VideoScanCore

enum HalliePronunciationPicker {

    // MARK: - The offer

    /// One page of candidates put to Rick, carried turn to turn.
    struct Offer: Equatable, Sendable {
        /// The archive's spelling of the name.
        let word: String
        /// This page, in offered order; numbers are 1-based positions.
        let candidates: [PronunciationVariations.Candidate]
        /// 0 = first page; "none of these" turns to the next.
        let round: Int
        /// The cues the list was built from (kept for regeneration).
        let hint: HalliePronunciationHint?
        let respellings: [String]
        /// True when the drill put the name up: a pick advances the sheet.
        let fromDrill: Bool
        /// The number last spoken by a chip click, so "that's it" can mean
        /// "the one I just heard" (chat only).
        var heard: Int?

        static let pageSize = 5

        init(word: String, candidates: [PronunciationVariations.Candidate], round: Int = 0,
             hint: HalliePronunciationHint? = nil, respellings: [String] = [], fromDrill: Bool = false, heard: Int? = nil) {
            self.word = word
            self.candidates = candidates
            self.round = round
            self.hint = hint
            self.respellings = respellings
            self.fromDrill = fromDrill
            self.heard = heard
        }

        /// 1-based lookup.
        func candidate(_ number: Int) -> PronunciationVariations.Candidate? {
            candidates.indices.contains(number - 1) ? candidates[number - 1] : nil
        }
    }

    /// Page `round` of the ranked list for `word`, or nil when that page is
    /// empty (nothing left to offer).
    static func makeOffer(
        word: String, hint: HalliePronunciationHint? = nil, respellings: [String] = [],
        round: Int = 0, fromDrill: Bool = false, gold: MisakiGoldLexicon = .shared
    ) -> Offer? {
        let all = PronunciationVariations.allCandidates(for: word, hint: hint, respellings: respellings, gold: gold)
        let start = round * Offer.pageSize
        guard start < all.count else { return nil }
        let page = Array(all[start..<min(all.count, start + Offer.pageSize)])
        return Offer(word: word, candidates: page, round: round, hint: hint, respellings: respellings, fromDrill: fromDrill)
    }

    // MARK: - What a reply means

    enum Reply: Equatable, Sendable {
        /// "2", "number 2", "the second one", "two is right".
        case pick(Int)
        /// A number the page does not have.
        case outOfRange(Int)
        /// "say 2 again", "play 3" (chat speaks it; the shell shows it).
        case hear(Int)
        /// "that's it" / "yes" after a chip was heard.
        case confirmHeard
        /// "that's it" with nothing heard yet: which one?
        case needsNumber
        /// "none of these" / "no" / "more": turn the page.
        case none
        /// Anything else: the offer steps aside (a respelling, a hint, a
        /// drill word, a question — the caller handles it).
        case leave
    }

    private static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "last": -1,
    ]

    private static let pickPattern = try! NSRegularExpression(
        pattern: #"^(?:ok[,]?\s+|okay[,]?\s+|yes[,]?\s+|yep[,]?\s+)?(?:(?:it's|its|it is|that's|thats|i pick|i'll pick|i choose|i'll take|i like|pick|choose|take|go with|use|let's go with|lets go with|try)\s+)?(?:the\s+)?(?:number\s+|#|no\.?\s*|option\s+)?(\d{1,2}|one|two|three|four|five|six|first|second|third|fourth|fifth|sixth|last)(?:\s+one)?(?:\s+(?:is|was|sounds|is the|was the)\s+(?:right|it|correct|the one|one|good|best|closest|closer))?(?:\s+please)?[.!]?$"#,
        options: [.caseInsensitive])

    private static let hearPattern = try! NSRegularExpression(
        pattern: #"^(?:(?:say|play|hear|repeat|let me hear|can i hear|do)\s+)?(?:the\s+)?(?:number\s+|#)?(\d{1,2}|one|two|three|four|five|six|first|second|third|fourth|fifth|sixth|last)(?:\s+one)?\s+(?:again|once more|one more time)[.!?]?$|^(?:say|play|hear|repeat|let me hear|can i hear)\s+(?:the\s+)?(?:number\s+|#)?(\d{1,2}|one|two|three|four|five|six|first|second|third|fourth|fifth|sixth|last)(?:\s+one)?(?:\s+please)?[.!?]?$"#,
        options: [.caseInsensitive])

    private static let confirmPattern = try! NSRegularExpression(
        pattern: #"^(?:ok[,]?\s+|okay[,]?\s+|yes[,]?\s+)?(?:that's it|thats it|that one|that's the one|thats the one|that's right|thats right|yes|yep|yup|right|correct|perfect|exactly|that's correct|thats correct|sounds right|good|that's good|thats good|nailed it|spot on)(?:[,!.]?\s*(?:hallie|thanks|thank you))?[.!]?$"#,
        options: [.caseInsensitive])

    private static let nonePattern = try! NSRegularExpression(
        pattern: #"^(?:no[,.]?\s*)?(?:none|none of these|none of those|none of them|neither|neither of those|not any of those|not any of these|not those|not these|nope|no|nah|no good|none are right|none of them are right|none sound right|try again|try some more|more|others|other ways|some others|give me more|give me others|show me more|a few more|different ones|keep going|next batch)(?:[,!.]?\s*(?:please|hallie))?[.!]?$"#,
        options: [.caseInsensitive])

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"^(?:hallie|hey hallie|ok hallie|okay hallie)[,!]?\s+"#, with: "",
                                  options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func number(_ token: String, in offer: Offer) -> Int? {
        if let value = Int(token) { return value }
        guard let value = numberWords[token.lowercased()] else { return nil }
        return value == -1 ? offer.candidates.count : value
    }

    private static func capture(_ regex: NSRegularExpression, _ text: String) -> String? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        for group in 1..<match.numberOfRanges {
            if let range = Range(match.range(at: group), in: text) { return String(text[range]) }
        }
        return nil
    }

    /// What a turn means while an offer is up. Pure; the caller applies it.
    static func classify(_ text: String, offer: Offer) -> Reply {
        let cleaned = clean(text)
        guard !cleaned.isEmpty else { return .leave }
        if let token = capture(hearPattern, cleaned), let value = number(token, in: offer) {
            return offer.candidate(value) != nil ? .hear(value) : .outOfRange(value)
        }
        if let token = capture(pickPattern, cleaned), let value = number(token, in: offer) {
            return offer.candidate(value) != nil ? .pick(value) : .outOfRange(value)
        }
        if nonePattern.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)) != nil {
            return .none
        }
        if confirmPattern.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)) != nil {
            return offer.heard != nil ? .confirmHeard : .needsNumber
        }
        return .leave
    }

    // MARK: - Asking for the picker

    /// "say Latta a few ways", "let me pick", "which sounds right".
    struct Request: Equatable, Sendable {
        /// The name as typed, nil for "it" / none given (the drill's
        /// current name, if any).
        let word: String?
    }

    private static let name = #"([\p{L}'’-]{2,})"#
    private static let requestPatterns: [NSRegularExpression] = [
        // "say Latta a few (different) ways (until I pick)", "pronounce it several ways", "say Latta 4 ways"
        #"^(?:please\s+|can you\s+|could you\s+)?(?:say|pronounce|try|read)\s+"# + name + #"\s+(?:in\s+)?(?:a few|a couple of|a couple|some|several|three|four|five|\d)\s+(?:different\s+|other\s+)?ways(?:\s+.*)?[.!]?$"#,
        // "let me pick (Latta)", "let me choose how to say Latta", "I want to pick"
        #"^(?:let me|lemme|i want to|i'd like to|i would like to|can i)\s+(?:pick|choose)(?:\s+(?:one|the right one|the best one|how to say|how you say|how to pronounce|the pronunciation)(?:\s+(?:for|of)\s+"# + name + #")?|\s+"# + name + #")?[.!?]?$"#,
        // "which sounds right (for Latta)?", "which one sounds right"
        #"^(?:which|what)\s+(?:one\s+|way\s+)?sounds\s+(?:right|best|closest)(?:\s+(?:for|to you for)\s+"# + name + #")?\??$"#,
        // "give me a few ways to say Latta", "offer me some options for Latta", "show me the options"
        #"^(?:give|offer|show|let me hear)\s+(?:me\s+)?(?:a few|a couple of|some|several|the|your)\s+(?:ways|options|choices|pronunciations|versions|variations)(?:\s+(?:to say|to pronounce|for|of)\s+"# + name + #")?[.!?]?$"#,
        // "how else could you say Latta", "what other ways are there to say Latta"
        #"^(?:how else|what other ways)\s+(?:can|could|would|are there to|might)\s+(?:you\s+)?(?:say|pronounce)\s+"# + name + #"\??$"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    private static let notNames: Set<String> = ["it", "that", "this", "them", "the", "name", "word", "one", "me", "hallie"]

    static func detectRequest(_ text: String) -> Request? {
        let cleaned = clean(text)
        guard !cleaned.isEmpty else { return nil }
        for regex in requestPatterns {
            guard let match = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)) else { continue }
            var word: String?
            for group in 1..<match.numberOfRanges {
                guard let range = Range(match.range(at: group), in: cleaned) else { continue }
                let typed = String(cleaned[range]).trimmingCharacters(in: CharacterSet(charactersIn: "'\"-"))
                if !notNames.contains(typed.lowercased()) { word = typed }
                break
            }
            return Request(word: word)
        }
        return nil
    }

    private static let bareNoPattern = try! NSRegularExpression(
        pattern: #"^(?:no|nope|nah|wrong|not right|not quite|incorrect|that's wrong|thats wrong|that's not it|thats not it|that's not right|thats not right|not like that|no that's wrong|no that's not right|no,? not right|no,? that's not it|not that|still wrong|still not right|nope,? not it)(?:[,!.]?\s*(?:hallie|sorry))?[.!]?$"#,
        options: [.caseInsensitive])

    /// A bare "no" / "not right" with no respelling — in the drill this
    /// opens the picker instead of asking for a spelling.
    static func isBareNo(_ text: String) -> Bool {
        let cleaned = clean(text)
        return bareNoPattern.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)) != nil
    }

    // MARK: - Wording

    static let numberNames = ["One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight"]

    /// Chat: Rick's sentence; the chips carry the choices.
    static func offerReply(_ offer: Offer) -> String {
        let lead = offer.round == 0
            ? "Here are a few ways to say \(offer.word) — click the one that's right:"
            : "None of those — here are a few more ways to say \(offer.word); click the one that's right:"
        return lead
    }

    /// "1. LAT-uh /lˈætə/ — short a, stress on the 1st" per line.
    static func numberedList(_ offer: Offer) -> String {
        offer.candidates.enumerated().map { index, candidate in
            "\(index + 1). \(candidate.respelling) /\(candidate.phonemes)/ — \(candidate.label)"
        }.joined(separator: "\n")
    }

    /// Shell and web: the list in the prose, reply by number.
    static func shellOfferReply(_ offer: Offer) -> String {
        let lead = offer.round == 0
            ? "Here are a few ways to say \(offer.word) — reply with the number that's right, or \"none of these\":"
            : "None of those — a few more ways to say \(offer.word); reply with the number, or \"none of these\":"
        return lead + "\n" + numberedList(offer)
    }

    /// What the voice says when the offer is made: every candidate in turn
    /// with its number, each as misaki's override, so Rick hears them all
    /// before clicking. The chips then repeat any one on demand.
    static func spokenOffer(_ offer: Offer) -> String {
        var text = "Here are a few ways to say \(offer.word). "
        for (index, candidate) in offer.candidates.enumerated() {
            let number = numberNames.indices.contains(index) ? numberNames[index] : "\(index + 1)"
            text += "\(number): \(candidate.spokenForm(word: offer.word)). "
        }
        return text + "Click the one that's right."
    }

    /// The Apple-voice version of `spokenOffer` (no override syntax).
    static func spokenOfferFallback(_ offer: Offer) -> String {
        var text = "Here are a few ways to say \(offer.word). "
        for (index, candidate) in offer.candidates.enumerated() {
            let number = numberNames.indices.contains(index) ? numberNames[index] : "\(index + 1)"
            text += "\(number): \(candidate.respelling). "
        }
        return text + "Click the one that's right."
    }

    /// "Number 2 — LAD-uh." (spoken with the override on the Kokoro path).
    static func hearReply(_ offer: Offer, number: Int) -> String {
        guard let candidate = offer.candidate(number) else { return outOfRangeReply(offer, number: number) }
        return "Number \(number) — \(candidate.respelling)."
    }

    static func hearSpeech(_ offer: Offer, number: Int) -> String? {
        offer.candidate(number).map { "Number \(number): \($0.spokenForm(word: offer.word))." }
    }

    static func hearSpeechFallback(_ offer: Offer, number: Int) -> String? {
        offer.candidate(number).map { "Number \(number): \($0.respelling)." }
    }

    /// "OK, noted — Latta. I'll say Latta as LAT-uh from now on. I've kept
    /// that …" — the read-back is spoken with the new entry in force.
    static func pickedReply(word: String, candidate: PronunciationVariations.Candidate, number: Int,
                            scope: HallieTellingMode.PronunciationScope) -> String {
        let telling = HallieTellingMode.PronunciationTelling(word: word, alternatives: [candidate.respelling])
        return HallieTellingMode.pronunciationReply(telling, scope: scope)
            .replacingOccurrences(of: " from now on.", with: " (number \(number)) from now on.")
    }

    static func outOfRangeReply(_ offer: Offer, number: Int) -> String {
        "I offered \(offer.candidates.count) way\(offer.candidates.count == 1 ? "" : "s") to say \(offer.word) — tell me a number from 1 to \(offer.candidates.count), or \"none of these\"."
    }

    static func needsNumberReply(_ offer: Offer) -> String {
        "Which one? Click it, or tell me the number (1 to \(offer.candidates.count))."
    }

    /// Every page shown and nothing fit: ask for a spelling or a hint.
    static func exhaustedReply(word: String) -> String {
        "That's every way I can think of for \(word). Spell it out for me like \u{201C}LAT-uh\u{201D}, or give me a hint — \u{201C}short a on the La\u{201D}, \u{201C}stress on the second syllable\u{201D}, \u{201C}rhymes with data\u{201D} — and I'll try again."
    }

    /// No syllable the generator can read and no usable cue.
    static func cannotOfferReply(word: String) -> String {
        "I can't work out ways to say \(word) on my own — spell it out for me like \u{201C}LAT-uh\u{201D}."
    }

    static func whichNameReply() -> String {
        "Which name? Say, for example, \u{201C}say Latta a few ways\u{201D}."
    }

    /// A chip pressed after the offer has already passed.
    static func offerPassedReply(word: String) -> String {
        "That offer has passed — say \u{201C}say \(word) a few ways\u{201D} and I'll put them up again."
    }

    /// Chip label: "1 LAT-uh"; the one last heard is marked.
    static func chipLabel(number: Int, candidate: PronunciationVariations.Candidate, heard: Bool) -> String {
        (heard ? "\u{25B6}\u{FE0E} " : "") + "\(number) \(candidate.respelling)"
    }

    static func thatsItLabel(number: Int) -> String { "That's it (\(number))" }
    static let noneLabel = "None of these"
    static let noneReplyText = "none of these"

    static let basisLine = "Basis: pronunciation picker — a few ways to say the name, chosen by you; no model call, no catalog query."

    /// Private-log line (counts only, no names — codex #861).
    static func logLine(offered offer: Offer) -> String {
        "[hallie-voice] picker: offered \(offer.candidates.count) (page \(offer.round + 1))\(offer.fromDrill ? " in the drill" : "")"
    }
}
