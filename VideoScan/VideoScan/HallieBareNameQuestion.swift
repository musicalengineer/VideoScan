// HallieBareNameQuestion.swift
// A bare name IS a question (GH #184 item 4, live 2026-09-11 22:05Z).
//
// "hallie mae mcgill" went to the translator, which read a lone name as a
// presence search and surfaced a video whose caption mentioned "Mae
// Mcgill". "tell me about hallie mae mcgill" a minute later gave the
// biography. A person typing nothing but a name wants the person, not a
// catalog sweep for the words — the same way "tell me about <name>" does.
//
// The rule is deliberately EXACT, because the question is one bare token
// run with no verb to help: the whole utterance must be
//   • a People-tab canonical name, alias, or derived full-name form
//     (exact-name-wins already holds there, 2026-08-22), or
//   • the whole of a family-tree person's NAME record — case, diacritic,
//     period and generational-suffix tolerant, like the biography road
//     ("richard harding breen" finds BOTH Jr and Sr; the graph route's
//     which-one chips take it from there).
// A name plus anything else ("videos of donna", "rick's family tree",
// "tim's brother", "mae mcgill") is not this shape and keeps its road.
// `HallieTurnExecutor.NameIdentity` carries the oracle, built by both
// clients from the same Context the rest of the executor reads.

import Foundation
import VideoScanCore

enum HallieBareNameQuestion {

    /// Words no bare name contains. Name particles ("of", "de", "van", "a"
    /// as a middle initial) are deliberately absent.
    static let sentenceWords: Set<String> = [
        "what", "where", "who", "whom", "whose", "when", "why", "how", "which",
        "is", "are", "was", "were", "be", "been", "am", "do", "does", "did",
        "can", "could", "would", "should", "will", "shall", "have", "has", "had",
        "the", "an", "this", "that", "these", "those", "it", "its",
        "i", "me", "my", "mine", "you", "your", "yours", "we", "our", "us",
        "they", "them", "their", "he", "him", "his", "she", "her", "hers",
        "and", "or", "but", "not", "no", "yes", "with", "for", "about", "from",
        "in", "on", "at", "to", "into", "by", "as", "if", "then", "than",
        "please", "show", "find", "play", "list", "tell", "ask", "give", "get",
        "open", "reveal", "search", "count", "any", "all", "some", "more",
    ]

    /// The typed text, trimmed of surrounding whitespace and terminal
    /// punctuation, when the WHOLE of it is exactly a known person's name.
    /// Nil for anything else — the question continues as typed. There is
    /// deliberately no kin-word veto: "Mom" and "Ma" ARE People-tab aliases
    /// (GH #180) and the alias wins exactly as it does for any known name;
    /// a kin phrase ("rick's family tree", "tim's brother") is never an
    /// exact name, and the possessive is refused outright.
    static func detect(_ question: String, isExactPersonName: (String) -> Bool) -> String? {
        guard question.count <= 80 else { return nil }
        let text = question
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "?.!,;:"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard !text.contains(where: \.isNumber) else { return nil }
        let lowered = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        // A possessive is never a bare name ("rick's family tree").
        guard !lowered.contains("'s "), !lowered.hasSuffix("'s") else { return nil }
        let tokens = lowered.split(whereSeparator: \.isWhitespace).map(String.init)
        guard (1...6).contains(tokens.count) else { return nil }
        // A sentence word ("is", "what", "and", "tell") settles it without
        // asking anyone: the identity sources are loaded lazily, and only a
        // string that could be a name is worth the load.
        guard tokens.allSatisfy({ !sentenceWords.contains($0) }) else { return nil }
        // Pronouns and the speakers themselves are bound elsewhere.
        if tokens.count == 1,
           HalliePronounContinuity.isThirdPersonPronoun(tokens[0])
            || HallieTurnExecutor.isSpeakerPronoun(tokens[0]) {
            return nil
        }
        guard isExactPersonName(text) else { return nil }
        return text
    }
}

extension HallieTurnExecutor {

    /// The model-free identity checks the bare-name and persona steps of
    /// `preTranslation` need (GH #184 items 4 and 5). Closures, so the
    /// clients keep loading the identity sources lazily and off-main.
    struct NameIdentity {
        /// The whole string is exactly one known person's name (People tab
        /// or family tree). See `HallieTurnExecutor.isExactPersonName`.
        let isExactPersonName: (String) -> Bool
        /// The archivist's display name ("Hallie Mae"), for the persona reply.
        let archivistName: () -> String?
        /// The family-tree (or People-tab) person the archivist is named
        /// after, by her name ladder, when exactly one person answers to it.
        let archivistNamesake: () -> String?
    }

    /// Both clients build it from their (lazily loaded) Context.
    static func nameIdentity(context: @escaping () -> Context) -> NameIdentity {
        NameIdentity(
            isExactPersonName: { isExactPersonName($0, context: context()) },
            archivistName: { context().speakers.archivistName },
            archivistNamesake: { archivistNamesake(context: context()) })
    }

    /// EXACT identity: the whole of `name` is a People-tab canonical name /
    /// alias / derived full-name form, or the whole of a family-tree NAME
    /// record (two tokens or more). Never a subset, a diminutive, a
    /// spelling recovery or a surname alone — those are the loose oracles
    /// (`isKnownPerson`), which in a 39,250-person tree accept "english".
    static func isExactPersonName(_ name: String, context: Context) -> Bool {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return false }
        if let profiles = context.profiles {
            // Every profile is walked per ask, so the walk uses the
            // byte-level fold (same case/diacritic semantics) and only a
            // hit is confirmed by the authoritative exact-name-wins rule —
            // the locale fold alone made 20k profiles cost a second per ask.
            let key = FamilyIdentityText.normalized(typed)
            let claimed = profiles.contains { profile in
                let quick = FamilyIdentityText.normalized(profile.canonicalName) == key
                    || profile.aliases.contains { FamilyIdentityText.normalized($0) == key }
                    || profile.fullNameForms.contains { FamilyIdentityText.normalized($0) == key }
                guard quick else { return false }
                return PersonNameClaim.strength(
                    of: typed, name: profile.canonicalName,
                    aliases: profile.aliases + profile.fullNameForms) != nil
            }
            if claimed { return true }
        }
        if let graph = context.graph, !exactTreePeople(typed, graph: graph).isEmpty {
            return true
        }
        return false
    }

    /// Everyone whose NAME record (preferred or alternate) is, whole, the
    /// typed full name. Suffix rule as the owner-style match: a record
    /// suffix is ignored unless the typed name carries one — "richard
    /// harding breen" finds Jr AND Sr, "richard harding breen jr." only Jr.
    /// One typed token is never a full name here (a given name alone is
    /// the People tab's business).
    static func exactTreePeople(_ typed: String, graph: GedcomFamilyGraph) -> [GedcomFamilyGraph.Person] {
        let wanted = fullNameTokens(typed)
        guard wanted.core.count >= 2 else { return [] }
        // `people(matching:)` narrows through the token index on the name
        // proper ("junior" is not a record token); the whole-name predicate
        // below is what makes the match exact.
        return graph.people(matching: wanted.core.joined(separator: " ")).filter { person in
            ([person.name] + person.alternateNames).contains { recorded in
                let have = fullNameTokens(recorded)
                guard have.core == wanted.core else { return false }
                return wanted.suffix.isEmpty || wanted.suffix == have.suffix
            }
        }
    }

    /// Name tokens split into the name proper and its generational suffix
    /// ("jr." / "junior" → "jr"), case- and diacritic-folded, periods gone.
    static func fullNameTokens(_ text: String) -> (core: [String], suffix: [String]) {
        let tokens = FamilyIdentityText.tokens(FamilyNameNormalizer.normalizeName(text))
        var core: [String] = []
        var suffix: [String] = []
        for token in tokens {
            guard GedcomFamilyGraph.nameSuffixes.contains(token) else { core.append(token); continue }
            switch token {
            case "junior": suffix.append("jr")
            case "senior": suffix.append("sr")
            default: suffix.append(token)
            }
        }
        return (core, suffix)
    }

    /// The person the archivist is named after, by her name ladder (the
    /// pinned tree spelling, the display name, then her first name alone),
    /// accepted at each rung only when it names exactly ONE person — the
    /// same rule `bindPronouns` documents for the biography road. Nil when
    /// nobody in the People tab or the tree answers to any rung.
    static func archivistNamesake(context: Context) -> String? {
        for rung in context.speakers.archivistNameLadder {
            if let profiles = context.profiles,
               let profile = PeopleTab.profile(claiming: rung, in: profiles) {
                return profile.canonicalName
            }
            guard let graph = context.graph else { continue }
            let exact = exactTreePeople(rung, graph: graph)
            if exact.count == 1 { return exact[0].name }
            if exact.isEmpty {
                let loose = graph.people(matching: rung)
                if loose.count == 1 { return loose[0].name }
            }
        }
        return nil
    }
}
