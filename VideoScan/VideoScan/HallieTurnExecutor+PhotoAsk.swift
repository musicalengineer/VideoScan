// HallieTurnExecutor+PhotoAsk.swift
// "photos of X" as a presence intent with mediaKind photo (the model lane,
// and the deterministic shape when the name is a which-one). Nothing in the
// catalog is a photograph, so a photo ask about a FAMILY-TREE person is
// answered from the tree: the stored portrait, the photography-floor line
// (WorldKnowledge: died before 1838), or the folder card — and when the
// name fits several people, the same which-one chips as a biography, with
// the photo ask carried through the clarification so the chip finishes it
// (live 2026-08-27: "are there are photos of Nathaniel Parker").

import Foundation
import VideoScanCore

extension HallieTurnExecutor {

    /// A one-person presence ask for photos.
    static func isPhotoAsk(_ ast: ArchivistQueryAST) -> Bool {
        guard case .presence(let payload) = ast else { return false }
        return payload.mediaKind == .photo && payload.people?.count == 1
    }

    /// The tree's answer to a photo ask, or nil to let the ordinary presence
    /// search run (not a photo ask, no tree, or a name the tree does not
    /// know at all).
    static func photoAsk(
        _ payload: ArchivistQueryAST.Presence,
        request: Request,
        context: Context
    ) -> Result? {
        guard payload.mediaKind == .photo, let graph = context.graph,
              let people = payload.people, people.count == 1 else { return nil }
        let typed = people[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return nil }

        // A chip tapped on this very ask: the pointer is the answer.
        switch request.selectedIdentity {
        case .gedcomPersonID(let id)?:
            guard let person = graph.people[id] else {
                return invalidContinuationResult(for: request.intent.ast)
            }
            return HallieLineageAnswer.personPhoto(person: person)
        case .some:
            return invalidContinuationResult(for: request.intent.ast)
        case nil:
            break
        }
        if HalliePronounContinuity.isThirdPersonPronoun(typed) {
            return HallieLineageAnswer.pronounAsk(typed)
        }
        let name = typed
        switch HallieLineageAnswer.resolveDetailed(name, context: context, graph: graph) {
        case .success(let person, _):
            return HallieLineageAnswer.personPhoto(person: person)
        case .ambiguous(let people):
            return namesakeClarification(name, among: people, request: request, context: context)
        case .failure(let result):
            // A qualified name that matched nobody gets its honest years
            // line; a plain unknown name is not the tree's to answer — the
            // presence search says what the catalog has (nothing, for photos).
            if HallieNameQualifier.parse(name) != nil, let result { return result }
            return nil
        }
    }

    /// "Which Nathaniel Parker do you mean — Sr (b. …) or Caleb (b. …)?" with
    /// one chip per namesake; the intent rides through so the chip resumes
    /// THIS ask (photo, biography, …) for the chosen person.
    static func namesakeClarification(
        _ typed: String,
        among people: [GedcomFamilyGraph.Person],
        request: Request,
        context: Context
    ) -> Result {
        let shown = HallieNameQualifier.parse(typed)?.name ?? typed
        let candidates = people.map { person -> Candidate in
            guard let graph = context.graph else {
                let label = ArchivistBiographyPolicy.disambiguationCandidate(for: person).label
                return Candidate(id: .gedcomPersonID(person.id), canonicalName: person.name, label: label)
            }
            return gedcomCandidate(person, graph: graph)
        }
        let asked = HallieLineageAnswer.whichOne(shown, among: people)
        return Result(
            route: route(request.intent.ast),
            outcome: .needsClarification,
            prose: asked.prose,
            basisLine: asked.basisLine,
            queryDescription: description(of: request.intent.ast),
            citations: [],
            catalogPersonName: nil,
            clarification: makeClarification(
                intent: request.intent, stage: .gedcomPerson,
                candidates: candidates, context: context))
    }
}
