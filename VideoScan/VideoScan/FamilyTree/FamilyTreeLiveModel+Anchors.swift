// FamilyTreeLiveModel+Anchors.swift
// The "Line to…" anchors: who the reader is in the tree and how a relation
// is phrased. Pure static functions of the graph, moved here unchanged from
// FamilyTreeLiveModel.swift (2026-10-30) when that file reached its 3,000-line
// lint cap. (For Rick: a Swift `extension` in another file ≈ more member
// definitions of the same C++ class in a second .cpp.)

import Foundation
import VideoScanCore

extension FamilyTreeLiveModel {
    /// "Me" first, then each recorded spouse. "Me" is the person carrying
    /// the configured FamilySearch ID (`hallie.ownerFamilySearchID`) when
    /// the tree has it, else the tree root. A root with two marriages
    /// yields two anchors — that IS the picker.
    /// A configured ID the tree does NOT carry yields NO anchors (codex
    /// #707): the root is never silently substituted for a stale pin; the
    /// inspector shows `anchorsCaption` instead of a "Line to" row.
    nonisolated static func anchors(in graph: GedcomFamilyGraph,
                                    ownerFamilySearchID: String? = nil) -> [FamilyTreeAnchor] {
        if staleOwnerPinCaption(in: graph, ownerFamilySearchID: ownerFamilySearchID) != nil { return [] }
        // A pinned owner is THE "me" (the first-INDI assumption is not
        // consulted at all, so a tree whose first record is Sr does not
        // add him beside a pinned Jr). Without a pin, every root the tree
        // names is an anchor — a merged two-pull tree has two, Rick and
        // Donna (2026-08-27) — roots first, then each one's spouses.
        let leads: [GedcomFamilyGraph.Person] =
            graph.person(familySearchID: ownerFamilySearchID).map { [$0] } ?? graph.roots
        guard !leads.isEmpty else { return [] }
        var out: [FamilyTreeAnchor] = []
        var seen: Set<String> = []
        // "You" is the pinned owner, or the lone root of a single-root
        // tree. Two roots and no pin: nobody is assumed to be the reader.
        let pinned = graph.person(familySearchID: ownerFamilySearchID) != nil
        for root in leads where seen.insert(root.id).inserted {
            out.append(FamilyTreeAnchor(id: root.id, label: firstGivenName(root), isRoot: true,
                                        readsAsYou: pinned || leads.count == 1))
        }
        for root in leads {
            for spouse in graph.relatives(.spouse, of: root) where seen.insert(spouse.id).inserted {
                out.append(FamilyTreeAnchor(id: spouse.id, label: firstGivenName(spouse), isRoot: false))
            }
        }
        return out
    }

    /// The caption shown in place of the "Line to" row when the owner's
    /// configured FamilySearch ID is not in the tree; nil otherwise.
    nonisolated static func staleOwnerPinCaption(in graph: GedcomFamilyGraph,
                                                 ownerFamilySearchID: String?) -> String? {
        HallieOwnerResolver.stalePinLine(familySearchID: ownerFamilySearchID, graph: graph)
            .map { $0 + " No “Line to” anchors until then." }
    }

    /// "your great-grandmother" for the reader's own anchor, "Donna's …"
    /// for every other (see `FamilyTreeAnchor.readsAsYou`).
    nonisolated static func relationPhrase(anchor: FamilyTreeAnchor, generations: Int, sex: String) -> String {
        (anchor.readsAsYou ? "your" : anchor.label + "'s") + " "
            + GedcomFamilyGraph.generationLabel(generations: generations, sex: sex)
    }

    /// "Richard Harding Breen Jr" → "Richard"; a lone surname or empty
    /// name falls back to the whole (or "(unnamed)").
    nonisolated static func firstGivenName(_ person: GedcomFamilyGraph.Person) -> String {
        let tokens = person.name.split(separator: " ").map(String.init)
        if let surname = person.surname,
           let first = tokens.first(where: { $0.caseInsensitiveCompare(surname) != .orderedSame }) {
            return first
        }
        return tokens.first ?? "(unnamed)"
    }
}
