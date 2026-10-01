// SurnameSpellingVariants.swift
// GH #230 Phase B: the Irish census index is searched by EXACT surname, and
// a family's name was written down by whichever enumerator or clerk was at
// the door. The same family turns up as -an, -ane and -ayne, with or without
// a "y" after the first vowel, Mc or Mac. Searching only the spelling the
// tree carries finds only the households that clerk spelled the same way.
//
// This generates the common clerk spellings GENERICALLY from rules — no
// table of real names, nothing family-specific. Pure, no I/O.
//
// Rules (each produces a candidate; up to two rules may combine):
//   1. Ending   -an ↔ -ane ↔ -ayne ↔ -aine
//   2. Vowel    first "o" before a consonant ↔ "oy"   (Doran ↔ Doyran)
//   3. Prefix   Mc ↔ Mac (only before a capital: "McAvoy", never "Mackey")
//   4. O'       "O'Dolan" ↔ "Dolan"
//   5. Ending   -ey ↔ -y after a consonant           (Daly ↔ Daley)
//   6. Doubled  "nn"/"ll" ↔ single
//
// Order: the spelling given first, then one-rule variants, then two-rule
// variants; ties alphabetical. Callers cap the list — every variant is one
// more request to a public service.

import Foundation

public enum SurnameSpellingVariants {

    /// The surname as given, then its clerk variants, at most `limit` in
    /// total. Empty input → empty output. Case follows the input's first
    /// letter (capitalised).
    public static func variants(of surname: String, limit: Int = 4) -> [String] {
        let trimmed = surname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return [] }
        var ordered: [String] = [trimmed]
        var seen: Set<String> = [trimmed.lowercased()]
        let oneRule = applyEachRule(to: trimmed)
        let twoRule = oneRule.flatMap { applyEachRule(to: $0) }
        for tier in [oneRule, twoRule] {
            for candidate in Set(tier).sorted() where seen.insert(candidate.lowercased()).inserted {
                ordered.append(candidate)
            }
        }
        return Array(ordered.prefix(limit))
    }

    /// Every candidate one rule away from `name`.
    static func applyEachRule(to name: String) -> [String] {
        var out: [String] = []
        out.append(contentsOf: endingVariants(name))
        if let v = vowelVariant(name) { out.append(v) }
        if let p = macVariant(name) { out.append(p) }
        if let o = apostropheOVariant(name) { out.append(o) }
        if let y = eyVariant(name) { out.append(y) }
        if let d = doubledVariant(name) { out.append(d) }
        return out.filter { $0.count >= 2 && $0 != name }
    }

    // MARK: Rules

    private static let anFamily = ["ayne", "aine", "ane", "an"]

    /// -an / -ane / -ayne / -aine → the other three.
    static func endingVariants(_ name: String) -> [String] {
        let lower = name.lowercased()
        // Longest ending first so "-ayne" is not read as "-ne".
        guard let ending = anFamily.first(where: { lower.hasSuffix($0) }) else { return [] }
        let stem = String(name.dropLast(ending.count))
        // A stem of one letter ("An", "Dane") is not a family of spellings.
        guard stem.count >= 2, let last = stem.last, !"aeiouy".contains(last.lowercased()) else { return [] }
        return anFamily.filter { $0 != ending }.map { stem + $0 }
    }

    /// The first vowel "o" followed by a consonant gains a "y" ("Doran" →
    /// "Doyran"); an "oy" loses it.
    static func vowelVariant(_ name: String) -> String? {
        let chars = Array(name)
        guard let first = chars.firstIndex(where: { "aeiouAEIOU".contains($0) }),
              chars[first] == "o" || chars[first] == "O" else { return nil }
        let next = first + 1
        guard next < chars.count else { return nil }
        if chars[next] == "y" {
            var copy = chars
            copy.remove(at: next)
            return String(copy)
        }
        guard !"aeiouyAEIOUY".contains(chars[next]), chars[next].isLetter else { return nil }
        var copy = chars
        copy.insert("y", at: next)
        return String(copy)
    }

    /// "McX" ↔ "MacX" — only when a capital follows, so "Mackey" and
    /// "Macken" are never touched.
    static func macVariant(_ name: String) -> String? {
        if name.hasPrefix("Mc"), name.count > 3,
           let third = name.dropFirst(2).first, third.isUppercase {
            return "Mac" + name.dropFirst(2)
        }
        if name.hasPrefix("Mac"), name.count > 4,
           let fourth = name.dropFirst(3).first, fourth.isUppercase {
            return "Mc" + name.dropFirst(3)
        }
        return nil
    }

    /// "O'Dolan" / "O Dolan" → "Dolan". (The reverse is not generated: a
    /// name without the O' gives no evidence it ever had one.)
    static func apostropheOVariant(_ name: String) -> String? {
        for prefix in ["O'", "O’", "O "] where name.hasPrefix(prefix) {
            let rest = String(name.dropFirst(prefix.count))
            return rest.count >= 2 ? rest : nil
        }
        return nil
    }

    /// "-ey" ↔ "-y" after a consonant.
    static func eyVariant(_ name: String) -> String? {
        let lower = name.lowercased()
        if lower.hasSuffix("ey"), name.count >= 4 {
            let before = lower.dropLast(2).last
            if let before, !"aeiou".contains(before) { return String(name.dropLast(2)) + "y" }
        } else if lower.hasSuffix("y"), name.count >= 3 {
            let before = lower.dropLast().last
            if let before, !"aeiouy".contains(before) { return String(name.dropLast()) + "ey" }
        }
        return nil
    }

    /// The first doubled "nn" or "ll" made single.
    static func doubledVariant(_ name: String) -> String? {
        for pair in ["nn", "ll"] {
            if let range = name.range(of: pair) {
                return name.replacingCharacters(in: range, with: String(pair.prefix(1)))
            }
        }
        return nil
    }
}
