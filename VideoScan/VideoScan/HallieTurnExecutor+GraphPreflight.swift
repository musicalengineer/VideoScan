// HallieTurnExecutor+GraphPreflight.swift
// The deterministic steps that run BEFORE a family-tree lookup on a fresh
// turn, in order (overnight cycle 7 — extracted verbatim from the `.graph`
// case of `execute`, which had grown past the complexity budget):
//   1. wedding-date questions (cycle 6): answer from FAM/MARR or decline —
//      never a birth date;
//   2. a bare "they"/"he"/"she" that nothing stood for (cycle 5): ask who;
//   3. "my dad" / "my mom" (cycle 4): rebind to the relative BEFORE "my" is
//      bound to the owner — unless the translator already made the phrase
//      the query's own relation;
//   4. "I"/"me"/"my" → owner, "you"/"Hallie" → archivist (2026-08-18),
//      recorded on the Intent so continuations read them the same way.
// Returns nil when none applies and the ordinary lookup should run.

import Foundation

extension HallieTurnExecutor {

    static func graphPreflight(
        _ rawPayload: ArchivistQueryAST.Graph,
        request: Request,
        context: Context,
        dependencies: Dependencies
    ) async throws -> Result? {
        if let wedding = HallieMarriageDate.answer(
            question: request.intent.originalQuestion,
            payload: rawPayload, context: context) {
            return wedding
        }
        if let pronoun = rawPayload.people.first(where: HalliePronounContinuity.isThirdPersonPronoun) {
            return Result(
                route: .graph, outcome: .declined,
                prose: HalliePronounContinuity.whoDoYouMean(pronoun),
                basisLine: "Basis: a pronoun with no previous answer to refer to; no family fact was looked up.",
                queryDescription: graphQueryDescription(rawPayload),
                citations: [], catalogPersonName: nil)
        }
        let phrase = SpeakerKinship.kinshipPhrase(in: request.intent.originalQuestion)
        let alreadyTheRelation = phrase.map { $0.relation.rawValue == rawPayload.relation?.rawValue } ?? true
        let kin = alreadyTheRelation
            ? SpeakerKinship.Rebinding(people: rawPayload.people)
            : SpeakerKinship.rebind(
                people: rawPayload.people,
                question: request.intent.originalQuestion,
                speakers: context.speakers,
                graph: context.graph,
                cyberBrain: context.cyberBrain)
        if let failure = kin.failure {
            return Result(
                route: .graph, outcome: .declined, prose: failure,
                basisLine: "Basis: the question names a relative of the speaker that the family tree could not resolve; no family fact was looked up.",
                queryDescription: graphQueryDescription(rawPayload),
                citations: [], catalogPersonName: nil)
        }
        if !kin.notes.isEmpty {
            var rebound = rawPayload
            rebound.people = kin.people
            let inner = try await execute(
                Request(intent: request.intent.replacing(
                    ast: .graph(rebound),
                    speakerBindings: [SpeakerBinding(
                        index: 0, pronoun: "my", role: .owner,
                        boundName: context.speakers.ownerName ?? "")])),
                context: context, dependencies: dependencies)
            return inner.prefixingBasis(kin.notes.joined(separator: "; "))
        }
        let binding = bindPronouns(
            rawPayload.people, speakers: context.speakers,
            isKnownPerson: { isKnownPerson($0, context: context) })
        if let unbound = binding.unbound.first {
            return unboundPronounResult(unbound, payload: rawPayload)
        }
        if !binding.bindings.isEmpty {
            var bound = rawPayload
            bound.people = binding.people
            return try await execute(
                Request(intent: request.intent.replacing(
                    ast: .graph(bound), speakerBindings: binding.bindings)),
                context: context, dependencies: dependencies)
        }
        return nil
    }
}
