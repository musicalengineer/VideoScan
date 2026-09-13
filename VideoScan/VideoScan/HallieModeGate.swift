// HallieModeGate.swift
// The post-translation check that never existed (docs/hallie_two_mode_design.md
// §1.3, §3.4 B): whether the AST the model returned belongs to the FAMILY the
// sentence asked for. Every strict miss went through this hole — a pronoun
// kin question came back as `presence … keyword=marry` and was executed
// as-is. Pure; shared by the app coordinator, the shell and (through the
// coordinator) the web bridge.
//
//   tree mode  + catalog AST → keep only when the words name media; else a
//                one-person AST is rewritten to the graph operation the
//                field guards choose, and anything else is an honest
//                decline. Tree mode never executes a catalog search.
//   catalog mode + graph AST → a media cue rewrites it to a presence
//                search for the same people; else a decline with a chip
//                that re-asks under the tree. Catalog mode never opens a
//                biography by accident.
//   unknown    → keep (today's behaviour).

import Foundation

enum HallieModeGate {
    typealias Exec = HallieTurnExecutor

    enum Outcome: Equatable {
        case keep
        /// The AST to execute instead, and the basis note that says so.
        case rewrite(ArchivistQueryAST, note: String)
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
        // The words overruled the classifier: "the Christmas tape" is a
        // catalog ask whatever the session was doing.
        if HallieMediaVocabulary.containsMediaWord(question) { return .keep }
        let named = people.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
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
