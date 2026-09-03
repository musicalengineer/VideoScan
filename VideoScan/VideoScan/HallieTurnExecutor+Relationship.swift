// HallieTurnExecutor+Relationship.swift
// The two-person "how is A related to B?" turn, and the honest decline when
// a pronoun cannot be bound.
//
// Rick (Hallie log 2026-08-18): "how am I related to you?" — the translator
// produced a one-person kinship with a made-up relation and the strict
// decoder rejected it. With the `relationship` operation and pronoun
// binding in place, this file owns identity for BOTH slots (CyberBrain
// alias bridge first, then People profiles + GEDCOM — the same ladder every
// other graph route uses), keeps a chip choice for slot 0 pinned while slot 1
// is clarified, and hands two GEDCOM pointers to the pure graph executor.

import Foundation
import VideoScanCore

extension HallieTurnExecutor {

    /// "I don't know who 'I' is yet" — never a guess. The owner's name is a
    /// setting (right-click the archivist's portrait → "Who is talking to
    /// her…"); until it is set, first-person questions decline visibly.
    static func unboundPronounResult(
        _ pronoun: String,
        payload: ArchivistQueryAST.Graph
    ) -> Result {
        let firstPerson = firstPersonPronouns.contains(pronoun.lowercased())
        let prose = firstPerson
            ? "I don't know who “\(pronoun)” is yet — tell me your name (right-click my portrait → “Who is talking to her…”) and ask again."
            : "I don't know which family-tree person “\(pronoun)” means — my own name isn't set (right-click my portrait → “Who is talking to her…”)."
        return Result(
            route: .graph,
            outcome: .declined,
            prose: prose,
            basisLine: "Basis: pronoun “\(pronoun)” could not be bound to a person; no family source was consulted.",
            queryDescription: graphQueryDescription(payload),
            citations: [],
            catalogPersonName: nil)
    }

    /// One slot's identity outcome.
    private enum SlotResolution {
        /// A unique GEDCOM person; `note` is the bridge to spell out in the
        /// basis line ("CyberBrain identity “rick breen” → … → GEDCOM “…”").
        case gedcom(id: String, note: String?)
        /// Ask which one — chips for this slot only.
        case clarify([Candidate], ClarificationStage)
        /// A final answer (not found, conflict, stale continuation).
        case answer(Result)
    }

    static func executeRelationship(
        payload: ArchivistQueryAST.Graph,
        request: Request,
        context: Context,
        dependencies: Dependencies
    ) async throws -> Result {
        let queryDescription = graphQueryDescription(payload)
        guard payload.people.count == 2 else {
            return Result(
                route: .graph,
                outcome: .declined,
                prose: "A relationship question needs exactly two people.",
                basisLine: "Basis: graph-query validation only; no family source was consulted.",
                queryDescription: queryDescription,
                citations: [],
                catalogPersonName: nil)
        }
        if let recompile = HallieLineageAnswer.needsRecompileResult(context, queryDescription: queryDescription) {
            return recompile
        }
        // Local-only (2026-08-29, codex #835): the People-tab overlay answers
        // without a GEDCOM — "how is Tim related to Rick?" needs no tree.
        // An empty placeholder graph carries the overlay stage; the GEDCOM
        // ladder below still requires a real tree (see the guard after it).
        let graphIsInstalled = context.graph != nil
        let graph = context.graph ?? GedcomFamilyGraph(gedcomText: "0 HEAD\n0 TRLR")

        let inputs = ArchivistGraphInputs(
            graph: graph,
            profiles: (context.profiles ?? []).map {
                ArchivistGraphProfileSnapshot(
                    stableID: $0.stableID,
                    canonicalName: $0.canonicalName,
                    aliases: $0.aliases,
                    kinships: $0.kinships,
                    sex: $0.sex,
                    birthdate: $0.birthdate,
                    deathdate: $0.deathdate,
                    uuid: $0.uuid,
                    treeIdentity: $0.treeIdentity)
            },
            ownerName: context.speakers.ownerName)
        var voices: [Int: ArchivistGraphQuery.Voice] = [:]
        for binding in request.intent.speakerBindings {
            voices[binding.index] = binding.role == .owner ? .owner : .archivist
        }
        let query = ArchivistGraphQuery(payload, voices: voices)

        var pinned = request.intent.pinnedGraphSubjects

        // People-tab relationships first (2026-08-27): "how is Timothy
        // related to Rick?" is answered from the typed overlay when it links
        // the two — the sons are not in the FamilySearch tree, so the GEDCOM
        // ladder below would only decline by name.
        var pinnedSelections: [ArchivistGraphSubjectSelection] = [.unresolved, .unresolved]
        for index in 0..<2 {
            switch pinned[index] {
            case .profileStableID(let id)?: pinnedSelections[index] = .profileStableID(id)
            case .gedcomPersonID(let id)?:  pinnedSelections[index] = .gedcomPersonID(id)
            default: break
            }
        }
        if let overlay = ArchivistGraphExecutor.overlayRelationshipResult(
            query, inputs: inputs, subjects: pinnedSelections) {
            var offers: [OfferedAction] = []
            if let other = overlay.evidence?.counterpart {
                offers.append(.ask(
                    question: "who is \(other.name)?",
                    label: "tell me about \(other.name)"))
            }
            // A bridge this turn only ASSUMED (derivable, not yet pinned)
            // is said out loud: "(taking Rick as Richard Harding Breen Jr)".
            // Carried as provenance, the same way the single-subject graph
            // route carries it, so appending it never turns the aside into
            // a claim the verifier has to prove.
            let taken = [overlay.evidence?.subjectID, overlay.evidence?.counterpart?.id]
                .compactMap { $0 }
                .compactMap { context.assumedTreeBridges[$0] }
            let aside = taken.isEmpty ? "" : " (taking \(taken.joined(separator: "; ")))"
            return Result(
                route: .graph,
                outcome: .answered,
                prose: overlay.prose,
                basisLine: overlay.basisLine,
                queryDescription: queryDescription,
                citations: [],
                catalogPersonName: nil,
                offeredActions: offers,
                answerPlan: overlay.answerPlan)
                .carryingProvenance(aside)
        }
        guard graphIsInstalled else {
            return Result(
                route: .graph,
                outcome: .declined,
                prose: "I don't have an imported family tree, so I can't work out how two people are related.",
                basisLine: "Basis: no readable GEDCOM was available; the People-tab relationships don't link them.",
                queryDescription: queryDescription,
                citations: [],
                catalogPersonName: nil)
        }
        var floating = request.selectedIdentity
        var subjects: [ArchivistGraphSubjectSelection] = [.unresolved, .unresolved]
        var notes: [String] = []

        for index in 0..<2 {
            let typed = payload.people[index]
            // The archivist's display name may not be her tree spelling
            // ("Hallie Mae" vs. "Hallie May McGill"); walk her name ladder
            // and say which rung matched.
            let spellings: [String] = voices[index] == .archivist
                ? uniqueSpellings([typed] + context.speakers.archivistNameLadder)
                : [typed]

            var resolution: SlotResolution?
            var lastAnswer: Result?
            // The owner FIRST (live 2026-08-28: "me (Rick) and Donna" reached
            // this route as "rick" and searched a 16k tree for Richards).
            // A slot that is the speaker — bound from "me"/"I", or the
            // owner's own first name or nickname typed by the owner — is
            // pinned through the shared owner chain (FamilySearch ID pin >
            // exactly one matching root > fail closed) before any name
            // search, exactly as the single-subject graph route does.
            if pinned[index] == nil, voices[index] != .archivist,
               voices[index] == .owner
                || HallieOwnerResolver.isOwnerSpelling(typed, owner: context.speakers.ownerName) {
                switch HallieOwnerResolver.resolve(
                    typed, graph: graph, familySearchID: context.speakers.ownerFamilySearchID) {
                case .one(let owner, let note):
                    // Pin, or a root/namesake that MATCHES the name. The
                    // single-root chain's last rung ("tree root; X has no
                    // tree record") is a guess this route never takes: an
                    // owner the tree does not know declines by name
                    // (HallieRelationshipTests, unknownOwnerNameDeclines…).
                    let pinned = graph.person(familySearchID: context.speakers.ownerFamilySearchID)?.id == owner.id
                    if pinned || graph.people(namedLike: typed).contains(where: { $0.id == owner.id }) {
                        resolution = .gedcom(
                            id: owner.id, note: note.replacingOccurrences(of: "Basis: ", with: ""))
                    }
                case .none(let reason?):
                    return Result(
                        route: .graph, outcome: .declined, prose: reason,
                        basisLine: "Basis: “\(typed)” is the owner's own name and could not be pinned to one family-tree record; nothing was looked up.",
                        queryDescription: queryDescription, citations: [], catalogPersonName: nil)
                case .many, .none:
                    break
                }
            }
            for spelling in spellings where resolution == nil {
                let attempt = resolveSlot(
                    spelling, selection: pinned[index], context: context,
                    inputs: inputs, query: query, graph: graph)
                switch attempt {
                case .gedcom(let id, let note):
                    var noteText = note
                    if spelling != typed {
                        let rung = "“\(typed)” matched the family tree as “\(spelling)”"
                        noteText = [rung, note].compactMap { $0 }.joined(separator: "; ")
                    }
                    resolution = .gedcom(id: id, note: noteText)
                case .clarify(let candidates, let stage):
                    // The one chip choice we were handed belongs to the first
                    // slot that turns out ambiguous; consume it here.
                    if let choice = floating,
                       stage.accepts(choice.source),
                       candidates.contains(where: { $0.id == choice }) {
                        pinned[index] = choice
                        floating = nil
                        let retry = resolveSlot(
                            spelling, selection: choice, context: context,
                            inputs: inputs, query: query, graph: graph)
                        if case .gedcom(let id, let note) = retry {
                            resolution = .gedcom(id: id, note: note)
                        } else {
                            return invalidContinuationResult(for: request.intent.ast)
                        }
                    } else {
                        resolution = .clarify(candidates, stage)
                    }
                case .answer(let result):
                    lastAnswer = result
                    continue
                }
                break
            }

            switch resolution {
            case .gedcom(let id, let note)?:
                subjects[index] = .gedcomPersonID(id)
                if let note { notes.append(note) }
            case .clarify(let candidates, let stage)?:
                let who = payload.people[index]
                // Family-tree namesakes: anchors first, capped, or the ask
                // for a surname/year (HallieWhichOne, 2026-08-29).
                if stage == .gedcomPerson {
                    let people = candidates.compactMap { candidate -> GedcomFamilyGraph.Person? in
                        if case .gedcomPersonID(let id) = candidate.id { return graph.people[id] }
                        return nil
                    }
                    let arrangement = HallieWhichOne.arrange(
                        people, graph: graph,
                        ownerFamilySearchID: context.speakers.ownerFamilySearchID)
                    let shown = arrangement.shown.map { person in
                        Candidate(
                            id: .gedcomPersonID(person.id),
                            canonicalName: person.name,
                            label: ArchivistBiographyPolicy.disambiguationCandidate(for: person).label)
                    }
                    return Result(
                        route: .graph,
                        outcome: .needsClarification,
                        prose: HallieWhichOne.prose(
                            typed: who, arrangement: arrangement, labels: shown.map(\.label)),
                        basisLine: HallieWhichOne.basis(typed: who, arrangement: arrangement),
                        queryDescription: queryDescription,
                        citations: [],
                        catalogPersonName: nil,
                        clarification: arrangement.offersChips
                            ? makeClarification(
                                intent: request.intent.replacing(pinnedGraphSubjects: pinned),
                                stage: stage,
                                candidates: shown,
                                context: context)
                            : nil)
                }
                return Result(
                    route: .graph,
                    outcome: .needsClarification,
                    prose: "Which \(HallieWhichOne.display(who)) do you mean?",
                    basisLine: "Basis: “\(who)” matches more than one stable identity; no family fact was selected.",
                    queryDescription: queryDescription,
                    citations: [],
                    catalogPersonName: nil,
                    clarification: makeClarification(
                        intent: request.intent.replacing(pinnedGraphSubjects: pinned),
                        stage: stage,
                        candidates: candidates,
                        context: context))
            case nil:
                // Every spelling failed: report the first (the typed) name's
                // not-found answer, tagged with what was tried.
                let answer = lastAnswer ?? Result(
                    route: .graph, outcome: .declined,
                    prose: "I don't find “\(typed)” in the family tree.",
                    basisLine: ArchivistBiographyPolicy.gedcomCheck,
                    queryDescription: queryDescription, citations: [],
                    catalogPersonName: nil)
                let offered = FamilyKnowledgeSupplement.notFoundOffer(
                    answer, typed: typed, graph: context.graph)
                if spellings.count > 1 {
                    return offered.prefixingBasis(
                        "tried “" + spellings.joined(separator: "”, “") + "”")
                }
                return offered
            case .answer(let result)?:
                return result
            }
        }

        // A chip choice nobody needed means the continuation is stale.
        if floating != nil {
            return invalidContinuationResult(for: request.intent.ast)
        }

        let execute = dependencies.executeRelationship
        let result = try await detached {
            execute(query, inputs, subjects, .unresolved)
        }
        var basis = result.basisLine
        if !notes.isEmpty {
            let bridge = notes.joined(separator: "; ") + "; "
            for prefix in ["Basis: ", "Checked: "] where basis.hasPrefix(prefix) {
                basis = prefix + bridge + basis.dropFirst(prefix.count)
                break
            }
        }
        var offers = familyTreeOffers(result.familyTreeFocus)
        if let other = result.evidence?.counterpart {
            offers.append(.ask(
                question: "who is \(other.name)?",
                label: "tell me about \(other.name)"))
        }
        return Result(
            route: .graph,
            outcome: result.conclusion == .answered ? .answered : .declined,
            prose: result.prose,
            basisLine: basis,
            queryDescription: queryDescription,
            citations: [],
            catalogPersonName: result.catalogPersonName,
            offeredActions: offers)
    }

    /// Resolve one typed name to a GEDCOM pointer: a prior chip choice, then
    /// CyberBrain (nickname → pointer), then People profiles + GEDCOM through
    /// the graph executor's own resolver. Mirrors the single-subject routes.
    private static func resolveSlot(
        _ typed: String,
        selection: CandidateID?,
        context: Context,
        inputs: ArchivistGraphInputs,
        query: ArchivistGraphQuery,
        graph: GedcomFamilyGraph
    ) -> SlotResolution {
        switch selection {
        case .cyberBrainPersonID(let personID)?:
            guard let index = context.cyberBrain,
                  let person = index.person(id: personID),
                  let gedcomID = person.gedcomPersonID,
                  let gedcomPerson = graph.people[gedcomID] else {
                return .answer(invalidContinuationResult(for: .graph(.init(
                    people: query.people, operation: .relationship))))
            }
            return .gedcom(
                id: gedcomID,
                note: cyberBrainBridgeNote(typed, person: person, gedcomName: gedcomPerson.name))

        case .gedcomPersonID(let id)?:
            return graphResolution(
                typed, selection: .gedcomPersonID(id), inputs: inputs, query: query)

        case .profileStableID(let id)?:
            return graphResolution(
                typed, selection: .profileStableID(id), inputs: inputs, query: query)

        case nil:
            if let index = context.cyberBrain {
                switch index.resolve(typed) {
                case .resolved(let person):
                    if let gedcomID = person.gedcomPersonID,
                       let gedcomPerson = graph.people[gedcomID] {
                        return .gedcom(
                            id: gedcomID,
                            note: cyberBrainBridgeNote(
                                typed, person: person, gedcomName: gedcomPerson.name))
                    }
                case .ambiguous(let people):
                    let linked = people.filter {
                        $0.gedcomPersonID.flatMap { graph.people[$0] } != nil
                    }
                    if !linked.isEmpty {
                        return .clarify(linked.map { candidate in
                            Candidate(
                                id: .cyberBrainPersonID(candidate.id),
                                canonicalName: candidate.canonicalName,
                                label: bridgedLabel(candidate, among: linked, graph: graph))
                        }, .cyberBrainPerson)
                    }
                case .notFound:
                    break
                }
            }
            return graphResolution(
                typed, selection: .unresolved, inputs: inputs, query: query)
        }
    }

    private static func graphResolution(
        _ typed: String,
        selection: ArchivistGraphSubjectSelection,
        inputs: ArchivistGraphInputs,
        query: ArchivistGraphQuery
    ) -> SlotResolution {
        switch ArchivistGraphExecutor.resolveSubject(
            typed, selection: selection, inputs: inputs, query: query) {
        case .person(let person, let bridge, let correction, _):
            var notes = bridge.map {
                "People profile identity bridge “\($0.requestedName)” → “\($0.profileCanonicalName)” → GEDCOM “\($0.effectiveGEDCOMName)”"
            }.map { [$0] } ?? []
            if let correction {
                notes.append(
                    "spelling recovery “\(correction)” → GEDCOM “\(person.name)”")
            }
            return .gedcom(
                id: person.id,
                note: notes.isEmpty ? nil : notes.joined(separator: "; "))
        case .result(let result):
            if !result.ambiguityCandidates.isEmpty {
                let choices = result.ambiguityCandidates.map { candidate -> Candidate in
                    switch candidate.id {
                    case .profileStableID(let id):
                        return Candidate(
                            id: .profileStableID(id),
                            canonicalName: candidate.canonicalName,
                            label: candidate.label)
                    case .gedcomPersonID(let id):
                        if let person = inputs.graph.people[id] {
                            return gedcomCandidate(person, graph: inputs.graph)
                        }
                        return Candidate(
                            id: .gedcomPersonID(id),
                            canonicalName: candidate.canonicalName,
                            label: candidate.label)
                    }
                }
                let stage: ClarificationStage = choices[0].source == .peopleProfile
                    ? .profileIdentity : .gedcomPerson
                return .clarify(choices, stage)
            }
            return .answer(Result(
                route: .graph,
                outcome: .declined,
                prose: result.prose,
                basisLine: result.basisLine,
                queryDescription: "shape=graph operation=relationship person=\(query.people.joined(separator: ","))",
                citations: [],
                catalogPersonName: result.catalogPersonName))
        }
    }

    private static func cyberBrainBridgeNote(
        _ typed: String,
        person: CyberBrainPerson,
        gedcomName: String
    ) -> String {
        "Breen Family CyberBrain identity “\(typed)” → “\(person.canonicalName)” → GEDCOM “\(gedcomName)”"
    }

    private static func uniqueSpellings(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert(PersonResolver.normalize($0)).inserted }
    }
}
