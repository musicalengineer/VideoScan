// HalliePronounContinuity.swift
// "who did Rick marry" → "when did they get married" (overnight cycle 5).
// The second turn reached the family-tree route with people = ["they"],
// and the not-found path offered "tell me about They". Two rules, both
// deterministic:
//   1. Before translation, a bare third-person pronoun is rewritten to the
//      people of the LAST archive answer (conversation memory keeps them),
//      so the translator sees "when did Rick get married". The rewrite is
//      visible in the transcript's translated question.
//   2. If a pronoun still reaches the tree route as a name (no memory),
//      Hallie asks who — she never looks up "they" as a person.

import Foundation

enum HalliePronounContinuity {

    /// Pronouns that stand for the previous answer's people.
    static let plural: Set<String> = ["they", "them", "their", "theirs", "themselves"]
    static let singular: Set<String> = ["he", "him", "his", "she", "her", "hers", "himself", "herself"]

    static func isThirdPersonPronoun(_ value: String) -> Bool {
        let key = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,?!'’"))
        return plural.contains(key) || singular.contains(key)
    }

    /// Kin nouns after which "her" is possessive, not an object: "and her
    /// husband?" → "Martha Lamson's husband", never "Martha Lamson husband"
    /// (eval 2026-09-01). One-hop family words plus their everyday forms.
    static let kinNouns: Set<String> = [
        "husband", "wife", "spouse", "spouses", "partner",
        "parents", "parent", "mother", "father", "mom", "mum", "dad", "mama", "papa",
        "children", "child", "kids", "kid", "sons", "son", "daughters", "daughter",
        "siblings", "sibling", "brothers", "brother", "sisters", "sister",
        "grandparents", "grandmother", "grandfather", "grandma", "grandpa",
        "grandchildren", "grandson", "granddaughter",
        "uncle", "uncles", "aunt", "aunts", "cousin", "cousins",
        "nephew", "nephews", "niece", "nieces", "family", "relatives", "in-laws",
    ]

    /// The question with its first bare pronoun replaced by the last
    /// answer's people ("they" → "Rick and Donna"; "he"/"she" → the one
    /// person when there was exactly one). Nil when nothing applies.
    static func rewrite(_ question: String, lastPeople: [String]) -> (question: String, note: String)? {
        let people = lastPeople.filter { !$0.isEmpty && !isThirdPersonPronoun($0) }
        guard !people.isEmpty else { return nil }
        let tokens = question.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" && $0 != "-" })
            .map(String.init)
        guard let index = tokens.firstIndex(where: { token in
            let key = token.lowercased()
            return plural.contains(key) || (singular.contains(key) && people.count == 1)
        }) else { return nil }
        let pronoun = tokens[index]
        let key = pronoun.lowercased()
        // "her" is both object and possessive. Before a kin noun it is the
        // possessive ("and her husband?" → "Martha Lamson's husband"); as an
        // object the bare name reads fine either way.
        let nextWord = index + 1 < tokens.count ? tokens[index + 1].lowercased() : ""
        let herIsPossessive = key == "her" && kinNouns.contains(nextWord)
        let replacement: String
        switch key {
        case "their", "theirs", "his", "hers":
            // Possessive: "their wedding" → "Rick and Donna's wedding".
            replacement = possessive(joinNames(people))
        case "her" where herIsPossessive:
            replacement = possessive(people[0])
        case "her":
            replacement = people[0]
        default:
            replacement = joinNames(plural.contains(key) ? people : [people[0]])
        }
        // Replace only the first whole-word occurrence, case-insensitively.
        guard let range = question.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: pronoun) + #"\b"#,
                                         options: [.regularExpression, .caseInsensitive]) else { return nil }
        let rewritten = question.replacingCharacters(in: range, with: replacement)
        return (rewritten, "'\(pronoun)' = \(joinNames(people)) (from the last answer)")
    }

    /// What Hallie says when a pronoun reaches the tree route with nothing
    /// to stand for.
    static func whoDoYouMean(_ pronoun: String) -> String {
        "I'm not sure who you mean by “\(pronoun)” — ask me by name, or ask right after a question about someone and I'll take it to mean them."
    }

    private static func possessive(_ name: String) -> String {
        name.hasSuffix("s") ? name + "'" : name + "'s"
    }

    private static func joinNames(_ names: [String]) -> String {
        switch names.count {
        case 1: return names[0]
        case 2: return names[0] + " and " + names[1]
        default: return names.dropLast().joined(separator: ", ") + ", and " + names[names.count - 1]
        }
    }
}
