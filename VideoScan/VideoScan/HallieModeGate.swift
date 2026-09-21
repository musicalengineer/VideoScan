// HallieModeGate.swift
// The post-translation check that never existed (docs/hallie_two_mode_design.md
// §1.3, §3.4 B): whether the AST the model returned belongs to the FAMILY the
// sentence asked for. Every strict miss went through this hole — a pronoun
// kin question came back as `presence … keyword=marry` and was executed
// as-is. Pure; shared by the app coordinator, the shell and (through the
// coordinator) the web bridge.
//
//   tree mode  + catalog AST → when the words ask for MEDIA — a media noun,
//                or a retrieval verb ("show me", "find", "play") with no
//                word of the sentence naming the tree — the turn switches
//                to catalog mode and runs there; a photo ask stays (the
//                portrait road is a tree answer); else a one-person AST is
//                rewritten to the graph operation the field guards choose,
//                and anything else is an honest decline. Tree mode itself
//                never executes a catalog search.
//   catalog mode + graph AST → a media cue rewrites it to a presence
//                search for the same people; else a decline with a chip
//                that re-asks under the tree. Catalog mode never opens a
//                biography by accident.
//   unknown    → keep (today's behaviour).
//
// 2026-09-20 (Rick: "show me Donna down the cape in the early 90s" ×3,
// "show me videos of donna down the cape", "show me ellen ronan"): the
// only media escape was a NOUN, so a "show me <person> <place> <era>" with
// no noun was read as a biography, and an `event` AST was refused outright.
// The retrieval-verb tier and `.switchToCatalog` are that fix.

import Foundation

enum HallieModeGate {
    typealias Exec = HallieTurnExecutor

    enum Outcome: Equatable {
        case keep
        /// The AST to execute instead, and the basis note that says so.
        case rewrite(ArchivistQueryAST, note: String)
        /// The AST is right, the MODE was wrong: the words asked for
        /// media, so the client runs the AST as translated in catalog
        /// mode (its context and its `[hallie-mode]` line say so) and the
        /// session follows. The note goes on the basis line.
        case switchToCatalog(note: String)
        case decline(Exec.Result)
    }

    static func reconcile(
        ast: ArchivistQueryAST,
        mode: HallieMode,
        question: String,
        memory: Exec.ConversationMemory,
        playAfterAnswer: Bool = false
    ) -> Outcome {
        switch mode {
        case .unknown: return .keep
        case .tree: return reconcileTree(ast, question: question)
        case .catalog: return reconcileCatalog(ast, question: question, playAfterAnswer: playAfterAnswer)
        }
    }

    // MARK: - Tree mode

    private static func reconcileTree(_ ast: ArchivistQueryAST, question: String) -> Outcome {
        let people: [String]
        switch ast {
        case .presence(let p): people = p.people ?? []
        case .cross(let p): people = p.people ?? []
        case .event(let p): people = p.people ?? []
        case .aggregate(let p): people = p.anchorPeople
        case .graph, .temporal, .record: return .keep
        }
        // The words overruled the classifier: "the Christmas tape" and
        // "show me Donna down the cape" are catalog asks whatever the
        // session was doing — so the turn moves to the catalog and runs.
        if let cue = catalogIntentCue(in: question) {
            return .switchToCatalog(
                note: "read “\(question)” as a catalog search (“\(cue)”), not a family-tree question")
        }
        // A photo word alone: "any pictures of donna" is the portrait road
        // for a tree person (+PhotoAsk), which answers under the tree.
        if HallieMediaVocabulary.containsMediaWord(question) { return .keep }
        let named = people.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // A question about the WHOLE family names nobody by design: "how
        // many grandchildren are there", "list everyone in the family",
        // "what do you know about the Breen family", "when did the latta
        // family come to america?". It is the family-tree overview (or
        // the surname roll-up) the translator returns as `familyTree`
        // when it reads the sentence right — the road that answered these
        // at the 2026-09-18 baseline — never the who-is-it-about decline.
        if named.isEmpty, let family = familyWideAsk(in: question) {
            return .rewrite(
                .graph(.init(people: [], operation: .familyTree, surname: family.surname)),
                note: "read “\(question)” as a question about the whole family (“\(family.cue)”), not a catalog search")
        }
        guard named.count == 1, let person = named.first else {
            let description = Exec.description(of: ast)
            return .decline(Exec.Result(
                route: .graph, outcome: .declined,
                prose: "I read that as a family-tree question, but I couldn't tell who it is about — name the person, "
                    + "or say “in the catalog” and I'll search the videos instead.",
                basisLine: "Basis: tree mode; the translator returned a catalog search (\(description)) naming no one person, so nothing was searched.",
                queryDescription: "mode gate: tree refused \(description)",
                citations: [], catalogPersonName: nil,
                mode: .tree))
        }
        let graph = graphQuery(for: person, question: question)
        return .rewrite(
            .graph(graph),
            note: "read “\(question)” as a family-tree question about \(person), not a catalog search")
    }

    /// Verbs that fetch something from the catalog. Deliberately NOT in
    /// the classifier's cue sets: "show me Donna's family tree" is a tree
    /// ask, which is why this tier yields to any tree word in the sentence.
    static let retrievalVerbs: Set<String> = [
        "show", "find", "play", "watch", "reveal", "count", "list", "search",
        "pull", "look", "browse",
    ]

    /// The word that makes a catalog-shaped AST a catalog ask in tree mode,
    /// or nil. Two tiers:
    ///   1. a media item noun or a collection word ("videos", "tape",
    ///      "archive") — the escape that always existed, photo nouns
    ///      excluded (the portrait road);
    ///   2. a retrieval verb ("show me", "find", "play") when NO word or
    ///      phrase of the sentence names the tree — so "show me videos of
    ///      donna down the cape", "show me Donna down the cape in the early
    ///      90s" and "show me ellen ronan" switch, while "show me ellen
    ///      ronan in the family tree" and "find my grandmother" stay.
    static func catalogIntentCue(in question: String) -> String? {
        let words = HallieMediaVocabulary.words(question)
        if let noun = words.first(where: {
            HallieMediaVocabulary.nouns.contains($0) || HallieMediaVocabulary.scopeWords.contains($0)
        }) {
            return noun
        }
        let padded = " " + words.joined(separator: " ") + " "
        let namesTheTree = HallieModeClassifier.treeCuePhrases.contains { padded.contains(" " + $0 + " ") }
            || words.contains { HallieModeClassifier.treeCues.contains($0) }
        if namesTheTree { return nil }
        if HallieMediaVocabulary.containsPhotoNoun(question) { return nil }
        return words.first { retrievalVerbs.contains($0) }
    }

    /// Words that ask about the family as a whole rather than one person.
    static let familyWideWords: Set<String> = [
        "family", "families", "everyone", "everybody", "grandchildren",
        "grandkids", "relatives", "ancestors", "descendants", "generations",
        "kin", "clan", "surname",
    ]

    /// Phrases with the same meaning ("when did the lattas come to
    /// america" is a question about the line, not a person).
    static let familyWidePhrases: [String] = [
        "the whole tree", "the entire tree",
        "come to america", "came to america", "come over", "came over",
        "came here", "come here", "get here", "got here",
    ]

    /// Scope phrases name WHERE to look, not WHAT is asked: "who is the
    /// highest royalty in my family tree" is about a title, not about the
    /// family, and it keeps the honest decline (HallieTwoModeReplayTests
    /// row 6). Removed from the sentence before the cue words are read.
    private static let scopePhrases: [String] =
        ["family tree", "family history"] + HallieModeClassifier.treeScopePhrases

    /// Adjectives that sit between "the" and "family" without being a
    /// surname: "the whole family", "our immediate family".
    private static let familyAdjectives: Set<String> = [
        "whole", "entire", "immediate", "extended", "own", "big", "large",
        "small", "little", "this", "that", "same", "other", "close",
        "nuclear", "wider", "greater",
    ]

    /// The word or phrase that makes the sentence a whole-family ask, and
    /// the surname it names ("the Breen family" → "breen", "the Lattas" →
    /// "latta"), or nil when the sentence is about no family at all.
    static func familyWideAsk(in question: String) -> (cue: String, surname: String?)? {
        var padded = " " + HallieMediaVocabulary.words(question).joined(separator: " ") + " "
        for phrase in scopePhrases.sorted(by: { $0.count > $1.count }) {
            padded = padded.replacingOccurrences(of: " " + phrase + " ", with: " ")
        }
        let words = padded.split(separator: " ").map(String.init)
        let cue = words.first(where: familyWideWords.contains)
            ?? familyWidePhrases.first(where: { padded.contains(" " + $0 + " ") })
        let surname = surnameOfFamily(in: question)
        if let cue { return (cue, surname) }
        if let surname { return ("the \(surname)s", surname) }
        return nil
    }

    /// "the breen family" / "our latta family" → "breen" / "latta";
    /// "the Breens" (typed as a name) → "breen". Nil for "the whole
    /// family" and for any plural that is not capitalised.
    static func surnameOfFamily(in question: String) -> String? {
        let text = question.replacingOccurrences(of: "\u{2019}", with: "'")
        if let match = text.range(
            of: #"\b(?:the|our|my|your)\s+([A-Za-z][A-Za-z'-]+)\s+famil(?:y|ies)\b"#,
            options: [.regularExpression, .caseInsensitive]) {
            let phrase = text[match].split(separator: " ").map(String.init)
            if phrase.count >= 3 {
                let candidate = phrase[1].lowercased()
                if !familyAdjectives.contains(candidate), !HallieModeClassifier.treeCues.contains(candidate) {
                    return candidate
                }
            }
        }
        // Only at the end of the sentence and after "about / of / on", so
        // "the Christmas party" is never read as the Christma family.
        if let match = text.range(
            of: #"\b(?:about|of|on)\s+the\s+([A-Z][a-z'-]{2,})s\s*[?.!]*\s*$"#,
            options: .regularExpression) {
            let word = String(text[match])
                .trimmingCharacters(in: CharacterSet(charactersIn: " ?.!"))
                .split(separator: " ").last.map(String.init) ?? ""
            let singular = String(word.dropLast()).lowercased()
            if !singular.isEmpty, !HallieMediaVocabulary.all.contains(word.lowercased()),
               !HallieModeClassifier.treeCues.contains(word.lowercased()) {
                return singular
            }
        }
        return nil
    }

    /// The graph operation the field guards read off the sentence
    /// (ArchivistGraphQuery+FieldGuards): a relation, a place, a life
    /// event, else the whole person.
    static func graphQuery(for person: String, question: String) -> ArchivistQueryAST.Graph {
        if let relation = ArchivistGraphQuery.asksForRelation(question, subject: [person]),
           let typed = ArchivistQueryAST.Graph.Relation(rawValue: relation.rawValue) {
            return .init(people: [person], operation: .kinship, relation: typed)
        }
        if ArchivistGraphQuery.asksForAPlace(question) {
            return .init(people: [person],
                         operation: ArchivistGraphQuery.asksAboutDeath(question) ? .deathPlace : .birthPlace)
        }
        if ArchivistGraphQuery.asksForABiography(question) {
            return .init(people: [person], operation: .biography)
        }
        let death = ArchivistGraphQuery.mentionsDeath(question)
        let birth = ArchivistGraphQuery.mentionsBirth(question)
        if death, !birth { return .init(people: [person], operation: .death) }
        if birth, !death { return .init(people: [person], operation: .birth) }
        return .init(people: [person], operation: .biography)
    }

    // MARK: - Catalog mode

    private static func reconcileCatalog(_ ast: ArchivistQueryAST, question: String, playAfterAnswer: Bool) -> Outcome {
        guard case .graph(let payload) = ast else { return .keep }
        let words = HallieMediaVocabulary.words(question)
        let mediaCue = playAfterAnswer
            || HallieMediaVocabulary.containsMediaWord(question)
            || words.contains { HallieModeClassifier.catalogCues.contains($0) }
        let people = payload.people.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if mediaCue {
            guard !people.isEmpty else { return .keep }
            return .rewrite(
                .presence(.init(people: people)),
                note: "read “\(question)” as a catalog search for \(people.joined(separator: " and ")), not a family-tree lookup")
        }
        let description = Exec.description(of: ast)
        return .decline(Exec.Result(
            route: .followUp, outcome: .declined,
            prose: "I'm looking in the catalog right now — did you mean the family tree?",
            basisLine: "Basis: catalog mode; the translator returned a family-tree lookup (\(description)) and the words asked for no media, so nothing was looked up.",
            queryDescription: "mode gate: catalog refused \(description)",
            citations: [], catalogPersonName: nil,
            offeredActions: [.ask(question: "in the family tree, \(question)", label: "Ask the family tree")],
            mode: .catalog))
    }
}
