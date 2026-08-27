// HallieTellingMode+Pronunciation.swift
// "Nathaniel is pronounced nuh-THAN-yul" / "say Edith as EE-dith" /
// "you're mispronouncing McGill, it's muh-GILL" (Rick, 2026-08-26).
//
// A pronunciation is the smallest thing a family member can tell Hallie:
// one word, one respelling. It is detected here beside the other told-me
// openers, worded here, and written by the coordinator through the same
// CyberBrain writer as testimony (person-level when the word is one
// person's name, else the pronunciations.json file). Pure text work: no
// I/O, no model.

import Foundation
import VideoScanCore

extension HallieTellingMode {

    /// One word and how to say it, as told.
    struct PronunciationTelling: Equatable, Sendable {
        /// The written name word, caller's capitalisation ("Nathaniel").
        let word: String
        /// The respelling exactly as typed ("nuh-THAN-yul").
        let saidAs: String
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

    static func detectPronunciation(_ text: String) -> PronunciationTelling? {
        let cleaned = text
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
                  !saidAs.isEmpty, saidAs.count <= 40,
                  // "nuh-THAN-yul" and "EE-dith" are respellings; "to cook",
                  // "as a boy" and "wrong all the time" are not.
                  looksLikeRespelling(saidAs) else { continue }
            return PronunciationTelling(word: word, saidAs: saidAs)
        }
        return nil
    }

    // MARK: - Wording

    /// "Got it — I'll say Nathaniel as nuh-THAN-yul from now on." plus where
    /// it was kept. The spoken form of this reply is itself the proof: the
    /// voice lexicon is re-read on the next utterance, so Bella says the
    /// name the new way while confirming it.
    static func pronunciationReply(_ telling: PronunciationTelling, scope: PronunciationScope) -> String {
        let lead = "Got it — I'll say \(telling.word) as \(telling.saidAs) from now on."
        switch scope {
        case .person(let name) where FamilyIdentityText.normalized(name) != FamilyIdentityText.normalized(telling.word):
            return lead + " I've kept that with \(name)."
        case .person:
            return lead + " I've kept that on \(telling.word)'s record."
        case .file:
            return lead + " I've kept that in the pronunciation list, since more than one person carries that name."
        }
    }

    static func pronunciationFailureReply(_ telling: PronunciationTelling, error: String) -> String {
        "I couldn't save how to say \(telling.word) (\(error)), so it won't stick past this answer — sorry."
    }
}
