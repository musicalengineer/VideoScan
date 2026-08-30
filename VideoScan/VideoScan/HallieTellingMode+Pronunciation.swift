// HallieTellingMode+Pronunciation.swift
// "Nathaniel is pronounced nuh-THAN-yul" / "say Edith as EE-dith" /
// "you're mispronouncing McGill, it's muh-GILL" (Rick, 2026-08-26) /
// "pronounce McGill like MahGill or MicGill" (Rick, 2026-08-29: two
// acceptable respellings; the first is spoken, both are kept).
//
// A pronunciation is the smallest thing a family member can tell Hallie:
// one word, one respelling (or two alternatives). It is detected here
// beside the other told-me openers, worded here, and written by the
// coordinator through the same CyberBrain writer as testimony (person-level
// when the word is one person's name, else the pronunciations.json file).
// Pure text work: no I/O, no model.

import Foundation
import VideoScanCore

extension HallieTellingMode {

    /// One word and how to say it, as told.
    struct PronunciationTelling: Equatable, Sendable {
        /// The written name word, caller's capitalisation ("Nathaniel").
        let word: String
        /// The respelling as stored: exactly as typed ("nuh-THAN-yul"), or
        /// two alternatives joined ("MahGill | MicGill").
        let saidAs: String

        init(word: String, saidAs: String) {
            self.word = word
            self.saidAs = saidAs
        }

        init(word: String, alternatives: [String]) {
            self.word = word
            self.saidAs = HalliePronunciationLexicon.joinedAlternatives(alternatives)
        }

        /// Every respelling given, first = the one spoken.
        var alternatives: [String] { HalliePronunciationLexicon.alternatives(saidAs) }
        /// The respelling the voice uses.
        var spoken: String { alternatives.first ?? saidAs }
    }

    /// Where the coordinator kept it, for the confirmation.
    enum PronunciationScope: Equatable, Sendable {
        case person(name: String)
        case file
    }

    // Whole-turn forms, case-insensitive, evaluated on the ORIGINAL text so
    // the respelling keeps its capital-stress spelling ("EE-dith"). Group 1
    // is the word, group 2 the respelling. Questions ("how is Nathaniel
    // pronounced?") never match: the word must be followed directly by the
    // verb, and a trailing "?" is rejected below.
    private static let pronunciationPatterns: [String] = [
        // "Nathaniel is pronounced nah-thahn-yul", "McGill should be said muh-GILL"
        #"^(?:hallie[,]?\s+)?(?:the (?:name|word) )?["']?([\p{L}'’-]+)["']?(?:,)? (?:is|should be|gets|is to be|has to be|must be|ought to be) (?:pronounced|said|spoken|read)(?: as| like)?[,:]? ["']?(.+?)["']?[.!]?$"#,
        // "say Edith as EE-dith", "please pronounce Latta like LAT-uh"
        #"^(?:hallie[,]?\s+)?(?:please |could you |can you |would you )?(?:say|pronounce) ["']?([\p{L}'’-]+)["']? (?:as|like)[,:]? ["']?(.+?)["']?[.!]?$"#,
        // "you're mispronouncing McGill, it's muh-GILL", "you keep saying Latta wrong — it's LAT-uh"
        #"^(?:hallie[,]?\s+)?you(?:'re| are| keep| were|'ve been| have been)? (?:mispronouncing|mis-pronouncing|saying|pronouncing) ["']?([\p{L}'’-]+)["']?(?: wrong| wrongly| incorrectly| badly)?[,.;:!]?\s*(?:—|–|-)?\s*(?:it's|it is|its|it should be|it's said|it's pronounced|it goes|say it as|say it like|say|try|should be)[,:]? ["']?(.+?)["']?[.!]?$"#,
    ]

    /// Compiled once (≈ a function-local `static const std::regex`): the
    /// patterns are literals, so a compile failure is a programmer error.
    private static let compiledPatterns: [NSRegularExpression] = pronunciationPatterns.map {
        try! NSRegularExpression(pattern: $0, options: [.caseInsensitive])
    }

    /// Words that can never be a name being respelled.
    private static let notNames: Set<String> = [
        "it", "that", "this", "he", "she", "they", "his", "her", "their", "the", "my", "name", "word",
    ]

    /// A respelling never opens with a function word: "to cook", "a story",
    /// "of fondly", "in Boston" are predicates the loose `(.+?)` tail of
    /// pattern 1 can capture from ordinary sentences (QA 2026-08-26).
    private static let notRespellingOpeners: Set<String> = [
        "to", "a", "an", "the", "as", "of", "in", "that",
    ]

    /// Does `saidAs` look like a respelling rather than a predicate? One
    /// spoken token ("EE-dith"), a hyphenated one ("nuh-THAN-yul"), or a
    /// token carrying an all-caps stressed syllable ("LAT uh"). "to cook"
    /// is none of those.
    static func looksLikeRespelling(_ saidAs: String) -> Bool {
        let tokens = saidAs.split(separator: " ")
        guard let first = tokens.first, tokens.count <= 2,
              !notRespellingOpeners.contains(first.lowercased()) else { return false }
        if tokens.count == 1 { return true }
        if saidAs.contains("-") { return true }
        // An all-caps syllable of two or more letters ("LAT", "GILL").
        return tokens.contains { token in
            token.count >= 2 && token.allSatisfy { $0.isLetter && $0.isUppercase }
        }
    }

    /// "MahGill or MicGill" / "MahGill | MicGill" / "either MahGill or
    /// MicGill" → ["MahGill", "MicGill"]; a single respelling → [it]. Nil
    /// when any part is not a respelling ("to cook or to bake").
    static func respellingAlternatives(_ saidAs: String) -> [String]? {
        var text = saidAs.trimmingCharacters(in: CharacterSet(charactersIn: " \"'.,;:!"))
        if text.lowercased().hasPrefix("either ") { text = String(text.dropFirst(7)) }
        let parts = text
            .replacingOccurrences(of: #"\s*\|\s*|\s*,?\s+or\s+|\s*/\s*"#, with: "|", options: [.regularExpression, .caseInsensitive])
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'.,;:!")) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ !$0.isEmpty && $0.count <= 40 && looksLikeRespelling($0) }) else {
            return nil
        }
        return parts
    }

    static func detectPronunciation(_ text: String) -> PronunciationTelling? {
        // "prounounced" / "pronunced" read as "pronounced" (live miss #17).
        let cleaned = HalliePronounceWords.normalize(text)
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard !cleaned.isEmpty, !cleaned.hasSuffix("?") else { return nil }
        for regex in compiledPatterns {
            guard let match = regex.firstMatch(
                    in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)),
                  match.numberOfRanges == 3,
                  let wordRange = Range(match.range(at: 1), in: cleaned),
                  let saidRange = Range(match.range(at: 2), in: cleaned) else { continue }
            let word = String(cleaned[wordRange]).trimmingCharacters(in: CharacterSet(charactersIn: "'\"-"))
            let saidAs = String(cleaned[saidRange])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \"'.,;:!"))
            guard !word.isEmpty, !notNames.contains(word.lowercased()),
                  !saidAs.isEmpty, saidAs.count <= 90,
                  // "nuh-THAN-yul" and "EE-dith" are respellings; "to cook",
                  // "as a boy" and "wrong all the time" are not. "MahGill or
                  // MicGill" is two respellings.
                  let alternatives = respellingAlternatives(saidAs) else { continue }
            return PronunciationTelling(word: word, alternatives: alternatives)
        }
        return nil
    }

    // MARK: - Wording

    /// The read-back Rick asked for (2026-08-29): "OK, noted — McGill." The
    /// name in this sentence is the proof — the voice lexicon is re-read on
    /// the very next utterance, so Bella says it the new way while noting it.
    static func pronunciationReadBack(_ word: String) -> String {
        "OK, noted — \(word)."
    }

    /// "OK, noted — Nathaniel. I'll say Nathaniel as nuh-THAN-yul from now
    /// on." plus where it was kept. With alternatives: "… as MahGill (or
    /// MicGill) …".
    static func pronunciationReply(_ telling: PronunciationTelling, scope: PronunciationScope) -> String {
        let alternatives = telling.alternatives
        let said = alternatives.count > 1
            ? "\(alternatives[0]) (or \(alternatives.dropFirst().joined(separator: " or ")))"
            : telling.spoken
        let lead = pronunciationReadBack(telling.word) + " I'll say \(telling.word) as \(said) from now on."
        switch scope {
        case .person(let name) where FamilyIdentityText.normalized(name) != FamilyIdentityText.normalized(telling.word):
            return lead + " I've kept that with \(name)."
        case .person:
            return lead + " I've kept that on \(telling.word)'s record."
        case .file:
            return lead + " I've kept that in the pronunciation list, since more than one person carries that name."
        }
    }

    /// No "OK, noted": nothing was kept. The reason is the error's own words.
    static func pronunciationFailureReply(_ telling: PronunciationTelling, error: String) -> String {
        let prefix = "could not save: "
        let detail = error.lowercased().hasPrefix(prefix)
            ? String(error.dropFirst(prefix.count)) : error
        return "I couldn't save that — \(detail). Saying \(telling.word) as \(telling.spoken) won't stick past this answer, sorry."
    }
}
