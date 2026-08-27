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

    /// Words that can never be a name being respelled.
    private static let notNames: Set<String> = [
        "it", "that", "this", "he", "she", "they", "his", "her", "their", "the", "my", "name", "word",
    ]

    static func detectPronunciation(_ text: String) -> PronunciationTelling? {
        let cleaned = text
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard !cleaned.isEmpty, !cleaned.hasSuffix("?") else { return nil }
        for pattern in pronunciationPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(
                    in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)),
                  match.numberOfRanges == 3,
                  let wordRange = Range(match.range(at: 1), in: cleaned),
                  let saidRange = Range(match.range(at: 2), in: cleaned) else { continue }
            let word = String(cleaned[wordRange]).trimmingCharacters(in: CharacterSet(charactersIn: "'\"-"))
            let saidAs = String(cleaned[saidRange])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \"'.,;:!"))
            guard !word.isEmpty, !notNames.contains(word.lowercased()),
                  !saidAs.isEmpty, saidAs.count <= 40,
                  // A respelling is one spoken token: "nuh-THAN-yul", "EE-dith".
                  // "as a boy" or "wrong all the time" are not respellings.
                  saidAs.split(separator: " ").count <= 2 else { continue }
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
