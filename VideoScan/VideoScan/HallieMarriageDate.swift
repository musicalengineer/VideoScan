// HallieMarriageDate.swift
// "When did Rick get married?" (overnight cycle 6, 2026-08-22).
//
// The family-tree query shape has birth/death/kinship/biography, but no
// marriage operation, so the translator maps a wedding-date question to
// the nearest thing it has — birth — and Hallie answered "Richard Harding
// Breen Jr was born on March 4, 1959" to a question about his wedding. A
// relative would never do that. This guard recognises the question
// deterministically and answers from the tree's own FAM/MARR record, or
// declines honestly. It never lets a birth date stand in.

import Foundation
import VideoScanCore

enum HallieMarriageDate {

    /// Whole-question recognition: asks WHEN, and is about marrying /
    /// a wedding / an anniversary.
    static func isWeddingDateQuestion(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let asksWhen = lowered.contains("when ") || lowered.hasPrefix("when")
            || lowered.contains("what year") || lowered.contains("what date")
            || lowered.contains("how long ago") || lowered.contains("anniversary")
        let aboutMarriage = ["married", "marry", "wedding", "wed ", "anniversary", "marriage"]
            .contains { lowered.contains($0) }
        return asksWhen && aboutMarriage
    }

    /// A Result for a wedding-date question, or nil when the question is
    /// not one (or names nobody resolvable — then the ordinary path, with
    /// its clarifications, takes over).
    static func answer(
        question: String,
        payload: ArchivistQueryAST.Graph,
        context: HallieTurnExecutor.Context
    ) -> HallieTurnExecutor.Result? {
        guard isWeddingDateQuestion(question),
              let typed = payload.people.first,
              !HalliePronounContinuity.isThirdPersonPronoun(typed) else { return nil }
        guard let graph = context.graph else {
            return decline("I don't have an imported family tree, so I can't look up a wedding date.",
                           basis: "Basis: no readable GEDCOM was available.", payload: payload)
        }
        // Resolve the person: CyberBrain alias → GEDCOM pointer first (how
        // "rick" becomes Richard Harding Breen Jr), then the tree's own
        // name match. Ambiguity falls through to the ordinary path.
        var person: GedcomFamilyGraph.Person?
        if let index = context.cyberBrain, case .resolved(let known) = index.resolve(typed),
           let id = known.gedcomPersonID, let tree = graph.people[id] {
            person = tree
        } else {
            let matches = graph.people(matching: typed)
            guard matches.count <= 1 else { return nil }
            person = matches.first
        }
        guard let person else { return nil }

        let marriages = graph.marriages(of: person)
        let dated = marriages.filter { $0.date != nil }
        if dated.isEmpty {
            let spouses = marriages.compactMap(\.spouse?.name)
            let who = spouses.isEmpty
                ? "The family tree doesn't record a marriage for \(person.name)."
                : "I can tell you who \(person.name) married — \(spouses.joined(separator: ", ")) — but the family tree I have doesn't record the wedding date."
            return decline(who + " If you tell me — “let me tell you about \(person.name)” — I'll remember it.",
                           basis: "Basis: imported family tree (GEDCOM) has no MARR date for \(person.id).",
                           payload: payload)
        }
        let sentences = dated.map { marriage -> String in
            if let spouse = marriage.spouse {
                return "\(person.name) and \(spouse.name) were married on \(marriage.date ?? "an unrecorded date")."
            }
            return "\(person.name) was married on \(marriage.date ?? "an unrecorded date")."
        }
        let prose = sentences.joined(separator: " ")
        return HallieTurnExecutor.Result(
            route: .graph,
            outcome: .answered,
            prose: prose,
            basisLine: "Basis: imported family tree (GEDCOM) MARR date for \(person.id); the date is shown exactly as recorded.",
            queryDescription: "shape=graph operation=marriage person=\(typed)",
            citations: [],
            catalogPersonName: nil,
            answerPlan: HallieAnswerPlan(route: .graph, shape: .fixed, fallbackText: prose))
    }

    private static func decline(_ prose: String, basis: String,
                                payload: ArchivistQueryAST.Graph) -> HallieTurnExecutor.Result {
        HallieTurnExecutor.Result(
            route: .graph, outcome: .declined, prose: prose, basisLine: basis,
            queryDescription: "shape=graph operation=marriage person=\(payload.people.first ?? "")",
            citations: [], catalogPersonName: nil)
    }
}
