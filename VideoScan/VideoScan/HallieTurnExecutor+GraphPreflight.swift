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
//
//   0. (eval bi013, 2026-09-01, ahead of everything) "what's the story
//      behind the Westford house": the translator made "westford house" a
//      person and the surname roster fuzzed "house" into Goushill. A
//      question about the <X> house / trip / place whose X is nobody in
//      the tree, the People tab or the CyberBrain is a catalog search for
//      X, never a family-tree lookup.

import Foundation

extension HallieTurnExecutor {

    static func graphPreflight(
        _ rawPayload: ArchivistQueryAST.Graph,
        request: Request,
        context: Context,
        dependencies: Dependencies
    ) async throws -> Result? {
        if let place = try await placeQuestionAsCatalogSearch(
            rawPayload, request: request, context: context, dependencies: dependencies) {
            return place
        }
        // Live miss #8 (2026-08-29): a tree on disk whose compiled
        // generation this version refused is not "no tree" — every graph
        // ask gets the recompile offer before any binding or lookup.
        if let recompile = HallieLineageAnswer.needsRecompileResult(
            context, queryDescription: graphQueryDescription(rawPayload)) {
            return recompile
        }
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
                cyberBrain: context.cyberBrain,
                kinshipOverlay: kinshipOverlay(context: context))
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

    /// Nouns that make "the <X> …" a thing or a place, not a person.
    static let placeNouns: Set<String> = [
        "house", "home", "trip", "vacation", "place", "story", "farm",
        "cottage", "cabin", "camp", "visit", "holiday",
    ]

    private static let placeArticles: Set<String> = [
        "the", "a", "an", "our", "my", "your", "old", "new", "that", "this",
    ]

    /// The catalog cross search for a place question that reached the
    /// graph route as a person — or nil when the "person" IS someone.
    static func placeQuestionAsCatalogSearch(
        _ payload: ArchivistQueryAST.Graph,
        request: Request,
        context: Context,
        dependencies: Dependencies
    ) async throws -> Result? {
        guard payload.people.count == 1, let typed = payload.people.first else { return nil }
        let questionWords = Set(request.intent.originalQuestion.lowercased()
            .split(whereSeparator: { !$0.isLetter }).map(String.init))
        guard !questionWords.isDisjoint(with: placeNouns) else { return nil }
        let tokens = typed.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map(String.init)
        let nameTokens = tokens.filter {
            !placeNouns.contains($0.lowercased()) && !placeArticles.contains($0.lowercased())
        }
        guard nameTokens.count == 1, let name = nameTokens.first else { return nil }
        // Someone by that name (or by the whole typed string) → a real
        // person question; leave it to the tree.
        guard !isKnownPerson(name, context: context, acceptSurname: true),
              !isKnownPerson(typed, context: context, acceptSurname: true) else { return nil }
        let cross = ArchivistQueryAST.cross(.init(people: [], keywords: [name]))
        let result = try await execute(
            Request(intent: request.intent.replacing(ast: cross)),
            context: context, dependencies: dependencies)
        return result.prefixingBasis(
            "“\(typed)” is a place or a thing, not a person I know, so I searched the catalog for “\(name)”")
    }
}
