// HalliePropertyAsk.swift
// "what is Dad's name and his birthdate?" (live miss #19, Rick 2026-08-29)
// reached the translator, which read the possessive on a profile whose
// canonical name IS a kinship word as a relation ask — "father of Dad" —
// and Hallie declined: "can't trace father for Dad". Rule: a possessive
// SUBJECT the context knows (a People-tab profile or its alias, a tree
// person, CyberBrain) followed by a PROPERTY word (name, birthdate,
// birthday, age, where born, death) is a biography ask about that person.
// Only a relation word as the OBJECT ("Rick's dad", "my dad") is a
// relation ask, and those never match here: "dad" is not a property word.
//
// Pure text: this file extracts the subject; the caller decides whether
// the context knows that name (HallieTurnExecutor.preTranslation's
// `isKnownPerson`) before routing. Nothing here touches identity.
//
// C++ readers: a namespace of static functions over a compiled regex.

import Foundation

enum HalliePropertyAsk {

    /// The words that make a possessive a property ask. Longer phrases
    /// first so "birth date" is not read as "birth" + a stray "date".
    static let propertyPhrases = [
        "date of birth", "date of death", "place of birth", "birth date", "birth day",
        "death date", "full name", "real name", "given name", "first name", "last name",
        "maiden name", "birthplace", "birthdate", "birthday", "name", "age", "birth", "death",
    ]

    private static let pattern: Regex<AnyRegexOutput> = {
        let props = propertyPhrases.joined(separator: "|")
        // Longest lead first: "what is" must win over "what", or the
        // subject swallows "is" ("what is dad's name" → "is dad").
        let lead = #"^(?:(?:hallie|please|ok|okay|so|and),?\s+)*(?:(?:what is|what was|what are|what were|what's|whats|what|tell me|tell us|give me|do you know|do you have|remind me of|remind me|say)\s+)?"#
        let subject = #"(?:(my|our)|([a-z][a-z .-]*?(?:'[a-z]+)?)'s)\s+"#
        let qualifier = #"(?:(?:full|real|given|first|last|maiden)\s+)?"#
        let property = #"(?:"# + props + #")"#
        let more = #"(?:\s*(?:,|and|&|or|plus)\s*(?:(?:his|her|their|my|our|the)\s+)?"# + qualifier + property + #")*"#
        // The phrase list is a literal in this file; a bad pattern is a
        // programming error caught by the suite, not a runtime condition.
        return try! Regex(lead + subject + qualifier + property + more + #"\s*$"#)
    }()

    /// The possessive subject as typed ("Dad", "O'Connor"), or "me" for
    /// "my"/"our"; nil when the sentence is not a property ask. A nested
    /// possessive ("rick's dad's name") is never matched: the subject may
    /// not itself contain "'s".
    static func detect(_ question: String) -> String? {
        var text = question.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = text.last, "?!.".contains(last) { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let m = text.firstMatch(of: pattern) else { return nil }
        if m[1].substring != nil { return "me" }
        let raw = String(m[2].substring ?? "").trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, !raw.contains("'s"), raw.split(separator: " ").count <= 5 else { return nil }
        // A pronoun or a determiner is not a name ("what is his name" is a
        // follow-up the pronoun route owns; "what is the dog's name" is not
        // a family ask).
        if raw.firstMatch(of: /^(?:the|a|an|this|that|his|her|their|your|its|my|our|whose|which|what|everyone|somebody|someone)(?:\s|$)/) != nil {
            return nil
        }
        // A verb or a media word inside the subject means the possessive
        // is an object of something else ("videos of dad's birthday",
        // "is dad's name"), not a person being asked about.
        if raw.firstMatch(of: /\b(?:is|was|are|were|of|for|about|video|videos|photo|photos|picture|pictures|clip|clips|show|find|play|me|us)\b/) != nil {
            return nil
        }
        return HallieLineageQuestion.capitalizedName(raw)
    }
}
