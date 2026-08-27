// FamilyTreePronunciation.swift
// The "Said as" row of the Family Tree inspector's Archivist Notes pane
// (Rick, 2026-08-26: "a pronunciation key somewhere next to aliases").
// One chip per word of the selected person's name; a chip shows the
// person-level respelling from their CyberBrain record when there is one,
// and otherwise what the file/shipped layer would say. Pure value logic —
// the view only renders these and calls the model to save.

import Foundation
import VideoScanCore

struct FamilyTreePronunciationChip: Identifiable, Equatable, Sendable {
    var id: String { word }
    /// A word of the name, tree spelling ("Nathaniel").
    let word: String
    /// The respelling on this person's own CyberBrain record, if any.
    let saidAs: String?
    /// What the voice would say from pronunciations.json / the shipped
    /// table when the person has no entry; nil when it would just read the
    /// word.
    let inherited: String?

    var isSet: Bool { saidAs != nil }
    /// The best current answer to "how will she say it?", for pre-filling
    /// the editor.
    var effective: String? { saidAs ?? inherited }
}

enum FamilyTreePronunciationChips {
    /// Name parts that are never pronounced on their own.
    static let suffixes: Set<String> = ["jr", "sr", "ii", "iii", "iv", "esq"]

    /// "Richard Harding Breen Jr" → ["Richard", "Harding", "Breen"]. Drops
    /// suffixes, initials and duplicates; keeps the tree's spelling.
    static func nameWords(_ name: String) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for raw in name.split(whereSeparator: { $0.isWhitespace }) {
            let word = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,()\"'“”‘’/[]"))
            let key = FamilyIdentityText.normalized(word)
            guard word.count > 1, !suffixes.contains(key), !key.isEmpty,
                  word.contains(where: \.isLetter), seen.insert(key).inserted else { continue }
            out.append(word)
        }
        return out
    }

    /// Chips for one tree person. `people` are the CyberBrain records that
    /// stand for them (linked or name-matched, per FamilyTreeNotesResolver);
    /// the first record carrying a word wins, as in the voice merge.
    static func make(
        name: String,
        people: [CyberBrainPerson],
        fallback: HalliePronunciationLexicon
    ) -> [FamilyTreePronunciationChip] {
        nameWords(name).map { word in
            let key = FamilyIdentityText.normalized(word)
            let own = people.lazy.compactMap { person -> String? in
                person.pronunciations?.first {
                    FamilyIdentityText.normalized($0.key) == key
                }?.value
            }.first
            let inherited = fallback.entries.first {
                FamilyIdentityText.normalized($0.written) == key && $0.spoken != $0.written
            }?.spoken
            return FamilyTreePronunciationChip(word: word, saidAs: own, inherited: inherited)
        }
    }
}
