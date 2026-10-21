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

    /// A GEDCOM NAME split at its slashes, with a particle that sits on the
    /// GIVEN side of the slash moved into the surname (2026-10-21):
    /// "John Fitz /Roger/" → given "John", surname "FitzRoger" — the same
    /// person "John /Fitz Roger/" describes. Without this the display read
    /// "John Fitz Roger" while every lookup fuses typed text to
    /// "john fitzroger", so the person could not be found by their own
    /// displayed name. Same fusion rule as `normalizeName`: a leading "Mac"
    /// is a given name ("Mac /Breen/"), and a particle only fuses with a
    /// capitalised word ("Fitz /de Wyndon/" is left alone).
    public static func normalizeNameParts(given: String, surname: String) -> (given: String, surname: String) {
        var words = given.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let particle = words.last,
              isParticle(particle, atIndex: words.count - 1, leadingMacFuses: false),
              let next = surname.first, next.isLetter, next.isUppercase else {
            return (normalizeName(words.joined(separator: " ")),
                    surname.isEmpty ? surname : normalizeSurname(surname))
        }
        words.removeLast()
        return (normalizeName(words.joined(separator: " ")), normalizeSurname(particle + " " + surname))
    }

    private static func isParticle(_ word: String, atIndex index: Int, leadingMacFuses: Bool) -> Bool {
        let key = word.lowercased()
        return alwaysFused.contains(key)
            || (fusedWhenNotLeading.contains(key) && (leadingMacFuses || index > 0))
    }

    private static func fuse(_ text: String, leadingMacFuses: Bool) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count > 1 else { return text }
        var out: [String] = []
        var index = 0
        while index < words.count {
            let word = words[index]
            if isParticle(word, atIndex: index, leadingMacFuses: leadingMacFuses), index + 1 < words.count,
               let next = words[index + 1].first, next.isLetter, next.isUppercase {
                out.append(word + words[index + 1])
                index += 2
            } else {
                out.append(word)
                index += 1
            }
        }
        return out.joined(separator: " ")
    }
}
