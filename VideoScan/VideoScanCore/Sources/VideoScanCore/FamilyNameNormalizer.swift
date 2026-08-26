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

    private static func fuse(_ text: String, leadingMacFuses: Bool) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count > 1 else { return text }
        var out: [String] = []
        var index = 0
        while index < words.count {
            let word = words[index]
            let key = word.lowercased()
            let isParticle = alwaysFused.contains(key)
                || (fusedWhenNotLeading.contains(key) && (leadingMacFuses || index > 0))
            if isParticle, index + 1 < words.count,
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
