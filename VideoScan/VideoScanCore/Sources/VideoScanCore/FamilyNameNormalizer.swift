// FamilyNameNormalizer.swift
// FamilySearch exports spell some surnames with a space after the particle
// ("Mc Gill", "Mac Donald", "O' Brien", "Fitz Gerald"). Read aloud or set
// in prose that becomes "Mic Gill" — a first name that was an ethnic slur
// in the 1800s (Rick, 2026-08-26). The fused spelling is applied at the
// display/surname layer when a GEDCOM record is parsed; the raw NAME line
// is never rewritten. Lowercase nobiliary particles ("de", "van", "von",
// "ap", "ab", "ferch") are left exactly as written.

import Foundation

public enum FamilyNameNormalizer {
    /// Particles that are always half of a surname, never a given name.
    static let alwaysFused: Set<String> = ["mc", "fitz", "o'", "o’"]
    /// "Mac" is also a nickname/given name ("Mac Breen"), so in a full name
    /// it fuses only when it is not the first word. In a bare surname it
    /// always fuses.
    static let fusedWhenNotLeading: Set<String> = ["mac"]

    /// A GEDCOM surname field ("Mc Gill" → "McGill", "Mac Donald" →
    /// "MacDonald", "De Hendour" unchanged).
    public static func normalizeSurname(_ surname: String) -> String {
        fuse(surname, leadingMacFuses: true)
    }

    /// A full display name ("Ann Mc Gill" → "Ann McGill", "Mac Breen"
    /// unchanged, "John Mac Donald" → "John MacDonald").
    public static func normalizeName(_ name: String) -> String {
        fuse(name, leadingMacFuses: false)
    }

    /// The display name and surname of a GEDCOM NAME split at its slashes
    /// ("given /surname/ after"), fused as ONE run of words (2026-10-21).
    ///
    /// The invariant: `normalizeName(display) == display`. Every lookup
    /// runs typed text through `normalizeName`, so a display that is not a
    /// fixed point cannot find its own person. The nightly found
    /// "John Fitz /Roger/" displayed as "John Fitz Roger" (the given part
    /// and the surname were fused separately, so the particle on the given
    /// side never met the word it belongs to); QA r1 added
    /// "John Mc Fitz /Roger/" and "John /Fitz/ Roger".
    ///
    /// How: the surname is first fused on its own with the bare-surname
    /// rule (a leading "Mac" fuses there — "/Mac Donald/"), then given,
    /// surname and after words are fused together with the full-name rule
    /// — the same loop `normalizeName` runs. Each word carries an
    /// "is surname" flag; a fused word is surname if either half was, so
    /// "John Fitz /Roger/" → display "John FitzRoger", surname "FitzRoger"
    /// — the same person "John /Fitz Roger/" describes. A leading "Mac" is
    /// still a given name ("Mac /Breen/"), and a particle only fuses with
    /// a capitalised word ("Fitz /de Wyndon/" is left alone).
    public static func normalizeNameParts(given: String, surname: String, after: String)
        -> (display: String, surname: String?) {
        func words(_ text: String, surname flag: Bool) -> [(String, Bool)] {
            text.split(separator: " ", omittingEmptySubsequences: true).map { (String($0), flag) }
        }
        let fusedSurname = surname.isEmpty ? surname : normalizeSurname(surname)
        let out = fuseWords(words(given, surname: false) + words(fusedSurname, surname: true)
                                + words(after, surname: false),
                            leadingMacFuses: false)
        let surnameWords = out.filter(\.1).map(\.0)
        return (out.map(\.0).joined(separator: " "),
                surnameWords.isEmpty ? nil : surnameWords.joined(separator: " "))
    }

    private static func isParticle(_ word: String, atIndex index: Int, leadingMacFuses: Bool) -> Bool {
        let key = word.lowercased()
        return alwaysFused.contains(key)
            || (fusedWhenNotLeading.contains(key) && (leadingMacFuses || index > 0))
    }

    private static func fuse(_ text: String, leadingMacFuses: Bool) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map { (String($0), false) }
        guard words.count > 1 else { return text }
        return fuseWords(words, leadingMacFuses: leadingMacFuses).map(\.0).joined(separator: " ")
    }

    /// The one fusion loop, shared by `normalizeName`, `normalizeSurname`
    /// and `normalizeNameParts` so the parser and every lookup cannot
    /// drift apart. Words are (text, flag); a fused word's flag is the OR
    /// of its halves (C++: a pair<string,bool> carried through the merge).
    private static func fuseWords(_ words: [(String, Bool)], leadingMacFuses: Bool) -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        var index = 0
        while index < words.count {
            let (word, flag) = words[index]
            if isParticle(word, atIndex: index, leadingMacFuses: leadingMacFuses), index + 1 < words.count,
               let next = words[index + 1].0.first, next.isLetter, next.isUppercase {
                out.append((word + words[index + 1].0, flag || words[index + 1].1))
                index += 2
            } else {
                out.append((word, flag))
                index += 1
            }
        }
        return out
    }
}
