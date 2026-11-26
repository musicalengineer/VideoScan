// HallieTurnExecutor+GraphSubject.swift
// WHO a single-person graph question is about, once a family tree is
// installed: the selection the tree is queried with, and the basis notes that
// say how Hallie settled on it. Split out of `executeGraphCase` (complexity
// gate, 2026-11-25) along the one concept its middle third carried:
//
//   1. the starting selection — a chip the user chose, or the owner's own
//      spelling pinned to the configured FamilySearch record (step 0 of the
//      owner chain, 2026-08-26);
//   2. the owner chain — the owner's spelling the tree could not settle,
//      re-run pinned to the owner's record (root tie-break);
//   3. a stale owner pin, said in the basis line (codex #707);
//   4. the surname roster (LIVE MISS #11, +SurnameRoster).
//
// Every step is the code that stood inline before, in the same order, under
// the same guards; GraphSubjectBinding only carries what the steps learned to
// the answer that follows.

import Foundation
import VideoScanCore

extension HallieTurnExecutor {

    /// What the subject steps learned: the graph's answer for the settled
    /// selection, and the notes that go in front of its basis line.
    /// (C++: a plain aggregate struct returned by value.)
    struct GraphSubjectBinding {
        var result: ArchivistGraphResult
        var ownerNote: String?
        var rosterNote: String?
        /// The surname roster which-one: returned only when neither the
        /// People tab nor a near-miss suggestion answers first.
        var rosterReply: Result?

        /// `r` with the roster note, then the owner note, prefixed to its
        /// basis line (owner note outermost), as the answers that name the
        /// settled subject carry them.
        func noted(_ r: Result) -> Result {
            var out = r
            if let rosterNote { out = out.prefixingBasis(rosterNote) }
            if let ownerNote { out = out.prefixingBasis(ownerNote) }
            return out
        }
    }

    /// The subject steps' outcome: a binding to answer from, or a reply that
    /// ends the turn now (an invalid continuation, a which-one among members
    /// who carry the given name).
    enum GraphSubjectStep {
        case bound(GraphSubjectBinding)
        case reply(Result)
    }

    /// The graph executor's inputs: the tree, the People-tab profiles as
    /// snapshots, and the owner's name. One builder for the single-person and
    /// the relationship routes.
    static func graphInputs(graph: GedcomFamilyGraph, context: Context) -> ArchivistGraphInputs {
        ArchivistGraphInputs(
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
    }

    /// Runs the graph query for the subject the steps above settle on.
    static func bindGraphSubject(
        _ payload: ArchivistQueryAST.Graph,
        query: ArchivistGraphQuery,
        inputs: ArchivistGraphInputs,
        graph: GedcomFamilyGraph,
        queryDescription: String,
        request: Request,
        context: Context,
        dependencies: Dependencies
    ) async throws -> GraphSubjectStep {
        guard let initial = initialGraphSelection(payload, graph: graph, request: request, context: context) else {
            return .reply(invalidContinuationResult(for: request.intent.ast))
        }
        let execute = dependencies.executeGraph
        var binding = GraphSubjectBinding(
            result: try await detached { execute(query, inputs, initial.selection) },
            ownerNote: initial.ownerNote)
        if binding.ownerNote == nil,
           let owner = ownerChainPin(payload, result: binding.result, graph: graph, request: request, context: context) {
            binding.result = try await detached {
                execute(query, inputs, .gedcomPersonID(owner.id))
            }
            binding.ownerNote = owner.note
        }
        if binding.ownerNote == nil {
            binding.ownerNote = staleOwnerPinNote(payload, graph: graph, request: request, context: context)
        }
        // LIVE MISS #11 (2026-08-29): "pa oc'connor" — the SURNAME is in
        // the tree (by spelling recovery) and the given token is a family
        // nickname. An alias bridges it to one person, a member's own name
        // answers or asks which one, and otherwise the surname roster is
        // offered after the People tab and near-miss checks — never the bare
        // decline. See +SurnameRoster.
        if request.selectedIdentity == nil, binding.ownerNote == nil,
           binding.result.conclusion == .personNotFound,
           let typed = payload.people.first,
           let step = surnameRosterStep(
               typed: typed, request: request, context: context,
               graph: graph, queryDescription: queryDescription) {
            switch step {
            case .resolved(let selection, let note):
                binding.result = try await detached {
                    execute(query, inputs, selection)
                }
                binding.rosterNote = note
            case .replyNow(let reply):
                return .reply(reply)
            case .roster(let reply):
                binding.rosterReply = reply
            }
        }
        return .bound(binding)
    }

    /// The selection the tree is first queried with, and the owner note when
    /// the configured FamilySearch ID pinned it. `nil`: a CyberBrain
    /// continuation, which this route cannot take.
    private static func initialGraphSelection(
        _ payload: ArchivistQueryAST.Graph,
        graph: GedcomFamilyGraph,
        request: Request,
        context: Context
    ) -> (selection: ArchivistGraphSubjectSelection, ownerNote: String?)? {
        switch request.selectedIdentity {
        case nil:
            // Step 0 of the owner chain (2026-08-26): a configured
            // FamilySearch ID pins the owner's own spelling to one record
            // before any name matching — never applied to anyone else's name.
            //
            // The pinned record is bound FIRST so its name can settle the
            // generation (2026-09-06). "Richard Breen Sr" used to satisfy
            // isOwnerSpelling for owner "Rick Breen" — rick expands to
            // richard, the suffix was discarded — and this line then
            // overwrote a father the kinship rebind had already resolved
            // correctly with Rick's own record.
            if let typed = payload.people.first,
               let pinned = graph.person(familySearchID: context.speakers.ownerFamilySearchID),
               HallieOwnerResolver.isOwnerSpelling(
                   typed, owner: context.speakers.ownerName, ownerTreeName: pinned.name) {
                return (.gedcomPersonID(pinned.id),
                        "“you” = \(pinned.name) (FamilySearch ID \(pinned.familySearchID ?? "")).")
            }
            return (.unresolved, nil)
        case .profileStableID(let id): return (.profileStableID(id), nil)
        case .gedcomPersonID(let id): return (.gedcomPersonID(id), nil)
        case .cyberBrainPersonID: return nil
        }
    }

    /// The owner chain (2026-08-26): the subject is one of the owner's own
    /// spellings ("rick", "Rick Breen") and the tree could not settle on one
    /// record — several Richards, or none under that spelling — so the
    /// owner's record (root tie-break) is pinned and the query runs again.
    /// Said in the basis line; never applied to anyone else's name. Only
    /// asked when no owner note is set yet.
    private static func ownerChainPin(
        _ payload: ArchivistQueryAST.Graph,
        result: ArchivistGraphResult,
        graph: GedcomFamilyGraph,
        request: Request,
        context: Context
    ) -> (id: String, note: String)? {
        guard request.selectedIdentity == nil,
              result.conclusion == .personNotFound || !result.ambiguityCandidates.isEmpty,
              let typed = payload.people.first,
              HallieOwnerResolver.isOwnerSpelling(typed, owner: context.speakers.ownerName),
              case .one(let owner, let note) = HallieOwnerResolver.resolve(
                  typed, graph: graph, familySearchID: context.speakers.ownerFamilySearchID)
        else { return nil }
        return (owner.id, note.replacingOccurrences(of: "Basis: ", with: ""))
    }

    /// The pinned owner ID is stale (codex #707): say so in the basis line
    /// rather than letting the name/root chain guess at "me". Only asked
    /// when no owner note is set yet.
    private static func staleOwnerPinNote(
        _ payload: ArchivistQueryAST.Graph,
        graph: GedcomFamilyGraph,
        request: Request,
        context: Context
    ) -> String? {
        guard request.selectedIdentity == nil,
              let typed = payload.people.first,
              HallieOwnerResolver.isOwnerSpelling(typed, owner: context.speakers.ownerName)
        else { return nil }
        return HallieOwnerResolver.stalePinLine(
            familySearchID: context.speakers.ownerFamilySearchID, graph: graph)
    }
}
