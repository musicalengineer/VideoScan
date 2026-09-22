// HallieEnglishWords.swift
// "Is this a real English word?" for the typo front door
// (HallieTypoNormalizer): a real word is never "corrected" into one of
// Hallie's words — "taking" is not "talking", "island" is not "is land".
//
// Source: the system word list (/usr/share/dict/words, Webster's Second,
// ~236k words), read once, lazily, on the first question that needs it.
// It carries no inflections, so a token also counts when a plain suffix
// comes off (-s, -es, -ies, -ed, -ied, -ing, -er, -est, -ly). If the file is
// missing the set is empty and the normalizer falls back to its own
// common-word table — fewer protections, never a crash.
//
// Memory: ~236k short strings in one Set — roughly 10–15 MB resident, held
// for the life of the process (one copy, shared by every turn). Load
// time: tens of milliseconds, off the main actor in the app (the front
// door runs in a detached task).
//
// C++ analogy: a function-local `static const std::unordered_set<std::string>`
// initialised on first use — Swift's `static let` is lazy and thread-safe
// the same way.

import Foundation

enum HallieEnglishWords {
    static let path = "/usr/share/dict/words"

    static let words: Set<String> = {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var set = Set<String>(minimumCapacity: 240_000)
        for line in text.split(separator: "\n") where !line.isEmpty {
            // Proper names are capitalised in the list; only common words
            // count (a name must never protect a typo, or vice versa).
            guard line.first?.isLowercase == true else { continue }
            set.insert(String(line))
        }
        return set
    }()

    /// True when `lower` (lower-case) is a word, or a word plus a plain
    /// inflection.
    static func contains(_ lower: String) -> Bool {
        let words = self.words
        if words.contains(lower) { return true }
        // The stem must be long enough to mean something: "famly" is not
        // "fam" + "ly", "maried" is not "mar" + "ied" (→ "mary").
        func stem(_ suffix: String, _ replacement: String = "") -> Bool {
            let minimum = ["s", "es", "ed", "ing"].contains(suffix) ? 3 : 4
            guard lower.hasSuffix(suffix), lower.count - suffix.count >= minimum else { return false }
            return words.contains(String(lower.dropLast(suffix.count)) + replacement)
        }
        return stem("s") || stem("es") || stem("ies", "y") || stem("ed") || stem("ed", "e")
            || stem("ied", "y") || stem("ing") || stem("ing", "e") || stem("er") || stem("er", "e")
            || stem("est") || stem("ly")
            // "running", "stopped": a doubled final consonant.
            || (lower.count > 5 && (lower.hasSuffix("ing") || lower.hasSuffix("ed")) && {
                let base = lower.hasSuffix("ing") ? lower.dropLast(3) : lower.dropLast(2)
                guard let last = base.last, base.dropLast().last == last else { return false }
                return words.contains(String(base.dropLast()))
            }())
    }
}
