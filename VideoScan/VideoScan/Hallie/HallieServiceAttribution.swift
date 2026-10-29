// HallieServiceAttribution.swift
// Whose service a sentence speaks of. The one rule behind
// HallieTurnExecutor.ServiceAnswer.serviceSentences.
//
// strict-052 (nightly 2026-10-28): "anyone in the American Revolution"
// listed a soldier's wife as having served. Her note reads "Wife of <her
// husband>, a … Revolutionary War soldier"; her only alias was her married
// surname, one token, and the old rule accepted a sentence that shared ANY
// name token with the person. A shared surname is the family, not the
// person.
//
// A sentence is about THIS person's service when a service word (the
// HallieServiceQuestion vocabulary) and the person, as the one who served,
// are in it:
//   - the person is named by a FULL name — the canonical name, or an alias
//     of two or more words (titles such as "Capt" dropped): the whole name,
//     given + surname, or the record form "Surname, Given". A one-word
//     alias (a married or maiden surname, a nickname) never names anyone;
//   - or the sentence opens with "he"/"she" and nothing since the person
//     was last named has introduced a relative (a marriage, "her husband");
//   - the name is not the object of a relation ("wife of X", "son of X",
//     "married X"): that sentence is about someone else;
//   - no relation stands between the person and the service word ("X's
//     husband served", "X married Y, a soldier", "the widow of a soldier").
//     A kin word owned by SOMEONE ELSE ("Harold, Rick's father, served") is
//     an apposition describing the person and does not count;
//   - a generational suffix that differs ("Sr" for a "Jr") is another man.
// When in doubt the sentence is not attributed: Hallie says less rather
// than list someone who did not serve (hard rule 1). Known residual: "X and
// Y, a soldier, married" (a comma appositive on a compound subject) still
// reads as both; parsing it needs a grammar, not a word list.
//
// Cost: O(tokens × names) per sentence, no allocation beyond the token
// arrays; passages are capped upstream (≤ 50 evidence items per person).

import Foundation
import VideoScanCore

enum HallieServiceAttribution {

    /// One way the family writes the person's name, as lowercase tokens.
    struct Name: Equatable, Sendable {
        /// Given … surname, leading titles dropped.
        let core: [String]
        /// "jr", "sr", "ii"… when the name carries one.
        let suffix: String?
    }

    // MARK: Vocabulary

    static let titles: Set<String> = [
        "capt", "captain", "sgt", "sergeant", "lt", "lieut", "lieutenant", "col", "colonel",
        "gen", "general", "maj", "major", "cpl", "corporal", "pvt", "private", "ens", "ensign",
        "dr", "mr", "mrs", "miss", "ms", "rev", "reverend", "deacon",
    ]
    static let suffixes: Set<String> = ["jr", "sr", "ii", "iii", "iv"]
    static let kinWords: Set<String> = [
        "wife", "husband", "widow", "widower", "spouse", "bride", "groom", "fiance", "fiancee",
        "son", "daughter", "child", "children", "father", "mother", "dad", "mom", "mum", "parent", "parents",
        "brother", "sister", "sibling", "grandfather", "grandmother", "grandson", "granddaughter",
        "grandchild", "uncle", "aunt", "nephew", "niece", "cousin",
        "stepson", "stepdaughter", "stepfather", "stepmother", "stepbrother", "stepsister",
    ]
    static let marriageWords: Set<String> = ["married", "marry", "marries", "wed", "wedded", "marriage"]
    static let pronouns: Set<String> = ["he", "she"]

    // MARK: Names

    /// The person's names that can identify them: the canonical name always;
    /// an alias only when it has a given name AND a surname.
    static func names(canonicalName: String, aliases: [String]) -> [Name] {
        var out: [Name] = []
        for (offset, raw) in ([canonicalName] + aliases).enumerated() {
            var tokens = FamilyIdentityText.tokens(raw)
            while let first = tokens.first, titles.contains(first), tokens.count > 1 { tokens.removeFirst() }
            var suffix: String?
            if tokens.count > 1, let last = tokens.last, suffixes.contains(last) { suffix = tokens.removeLast() }
            guard !tokens.isEmpty, offset == 0 || tokens.count >= 2 else { continue }
            let name = Name(core: tokens, suffix: suffix)
            if !out.contains(name) { out.append(name) }
        }
        return out
    }

    // MARK: Sentences

    /// The sentences (already split) that speak of the service of the
    /// person whose names are `names`, in order.
    static func serviceSentences(_ sentences: [String], about names: [Name]) -> [String] {
        // The passage is filed under the person: until a relative is
        // introduced, an opening "he"/"she" is them.
        var antecedentIsPerson = true
        var picked: [String] = []
        for sentence in sentences {
            let tokens = FamilyIdentityText.tokens(sentence)
            let subjects = occurrences(of: names, in: tokens).filter { !isObjectOfRelation($0, in: tokens) }
            var candidates = subjects
            if antecedentIsPerson, let first = tokens.first, pronouns.contains(first) { candidates.append(0..<1) }
            let terms = serviceTerms(in: tokens)
            if candidates.contains(where: { attributes(terms, to: $0, in: tokens) }) { picked.append(sentence) }
            if let last = subjects.last {
                antecedentIsPerson = !relationBetween(tokens, last.upperBound, tokens.count, owner: last)
            } else if relationBetween(tokens, 0, tokens.count, owner: nil) {
                antecedentIsPerson = false
            }
        }
        return picked
    }

    /// A service word the person stands to with nothing relational between.
    private static func attributes(_ terms: [Range<Int>], to person: Range<Int>, in tokens: [String]) -> Bool {
        terms.contains { term in
            if term.lowerBound >= person.upperBound {
                return !relationBetween(tokens, person.upperBound, term.lowerBound, owner: person)
            }
            if term.upperBound <= person.lowerBound {
                // The service word first ("a soldier's widow, X"): any kin
                // word between them is a relation.
                return !relationBetween(tokens, term.upperBound, person.lowerBound, owner: person, appositive: false)
            }
            return false
        }
    }

    /// Token ranges where one of `names` appears.
    static func occurrences(of names: [Name], in tokens: [String]) -> [Range<Int>] {
        var found: [Range<Int>] = []
        for start in tokens.indices {
            for name in names {
                guard let end = matchEnd(name, in: tokens, at: start) else { continue }
                found.append(start..<end)
                break
            }
        }
        return found
    }

    /// Where `name` ends when it starts at `start`, or nil. The whole name,
    /// given + surname, or "surname given" (a record transcription); a
    /// different generational suffix right after it is someone else.
    private static func matchEnd(_ name: Name, in tokens: [String], at start: Int) -> Int? {
        let core = name.core
        func matches(_ words: [String]) -> Bool {
            start + words.count <= tokens.count && Array(tokens[start..<start + words.count]) == words
        }
        var end: Int?
        if matches(core) {
            end = start + core.count
        } else if core.count >= 2, let given = core.first, let surname = core.last {
            if matches([given, surname]) || matches([surname, given]) { end = start + 2 }
        }
        guard var stop = end else { return nil }
        if stop < tokens.count, suffixes.contains(tokens[stop]) {
            guard tokens[stop] == name.suffix else { return nil }
            stop += 1
        }
        return stop
    }

    /// "wife of X", "son of X", "married X", "married to X": X is named as
    /// someone's relation, not as the subject of the sentence.
    private static func isObjectOfRelation(_ occurrence: Range<Int>, in tokens: [String]) -> Bool {
        var index = occurrence.lowerBound - 1
        var linked = false
        if index >= 0, tokens[index] == "of" || tokens[index] == "to" { linked = true; index -= 1 }
        guard index >= 0 else { return false }
        return marriageWords.contains(tokens[index]) || (linked && kinWords.contains(tokens[index]))
    }

    /// A marriage word, or a kin word introducing a relative, in
    /// tokens[lo..<hi]. With `appositive`, "<someone else>'s father" (the
    /// possessive owned by a word inside the span, not by the person) is
    /// a description of the person, not a relative.
    private static func relationBetween(_ tokens: [String], _ lo: Int, _ hi: Int,
                                        owner: Range<Int>?, appositive: Bool = true) -> Bool {
        guard lo < hi else { return false }
        for index in lo..<hi {
            let word = tokens[index]
            if marriageWords.contains(word) { return true }
            guard kinWords.contains(word) else { continue }
            let ownedByAnother = appositive && index - 2 >= lo && tokens[index - 1] == "s"
                && !(owner?.contains(index - 2) ?? false) && !pronouns.contains(tokens[index - 2])
            if !ownedByAnother { return true }
        }
        return false
    }

    /// Token ranges of the service words in a sentence's tokens. The regex
    /// runs on the tokens joined by single spaces (every pattern is letters,
    /// digits and spaces), so a match maps straight back to token indices.
    static func serviceTerms(in tokens: [String]) -> [Range<Int>] {
        guard let regex = HallieServiceQuestion.serviceTermRegex, !tokens.isEmpty else { return [] }
        var starts: [Int] = []   // UTF-16 offset of each token in `joined`
        var offset = 0
        for token in tokens {
            starts.append(offset)
            offset += token.utf16.count + 1
        }
        let joined = tokens.joined(separator: " ")
        func tokenIndex(at location: Int) -> Int {
            // Last token starting at or before `location` (C++: std::upper_bound - 1).
            var lo = 0, hi = starts.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if starts[mid] <= location { lo = mid + 1 } else { hi = mid }
            }
            return max(lo - 1, 0)
        }
        return regex.matches(in: joined, range: NSRange(location: 0, length: joined.utf16.count)).map { match in
            tokenIndex(at: match.range.location)..<(tokenIndex(at: match.range.location + match.range.length - 1) + 1)
        }
    }
}
