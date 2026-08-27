// HallieOwnerResolver.swift
// The signed-in owner's fallback chain over the family tree, shared by
// every route that has to pin "me" / "Rick" / "Rick Breen" to a GEDCOM
// record (lineage, graph kinship, "my dad" rebinding).
//
// Live 2026-08-26: FamilySearch spells the owner "Richard Harding /Breen/
// Jr" with NO birth date (living people are stripped) and puts him first in
// the file. The settings say "Rick Breen"; the People tab says "Rick"
// (aliases Dicky, Dad). Three routes each had their own, weaker, lookup —
// `people(matching:)` refuses a diminutive that hits several Richards, so
// every one of them declined by name. One chain now, in order:
//   (i)   `people(namedLike:)` — diminutive- and suffix-tolerant. One hit
//         → it.
//   (ii)  Several hits → the tree root if it is among them (never silently
//         Sr over Jr); otherwise the caller asks which one.
//   (iii) No hit → the tree root (first INDI; getmyancestors/FamilySearch
//         put the home person first — an assumption, so the note says
//         "tree root").
// Step 0 (codex #707, 2026-08-26): an EXPLICIT FamilySearch ID pin fails
// closed. Configured but not in the installed tree → `.none(reason:)` with
// an honest line, never a silent fall-through to name/root that could bind
// the wrong "me". Only an ABSENT pin enters the chain above.
// C++ readers: `Match` is a tagged union (std::variant) — the compiler
// makes every caller handle all three arms. `.none` carries an optional
// payload with a default, so `case .none:` and `.none` still compile for
// callers that don't care why.

import Foundation
import OSLog
import VideoScanCore

private let ownerLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "hallie.owner")

enum HallieOwnerResolver {

    enum Match: Equatable {
        /// `note` is the basis-line sentence saying HOW "you" was pinned.
        case one(GedcomFamilyGraph.Person, note: String)
        /// Several candidates and no root to prefer — ask which one.
        case many([GedcomFamilyGraph.Person])
        /// Nothing at all, not even a root person — or (with `reason`) an
        /// explicit FamilySearch ID pin that the installed tree does not
        /// carry, in which case `reason` is the honest line to show.
        case none(reason: String? = nil)
    }

    /// The honest line for a configured-but-stale FamilySearch ID; nil when
    /// no ID is configured or the tree carries it. Callers that short-cut
    /// `resolve` (identity directory, speaker kinship, tree anchors) use
    /// this so every route fails closed the same way.
    static func stalePinLine(familySearchID: String?, graph: GedcomFamilyGraph) -> String? {
        guard let id = familySearchID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty, graph.person(familySearchID: id) == nil else { return nil }
        ownerLog.warning("Owner FamilySearch ID \(id, privacy: .public) is configured but not in the installed tree (\(graph.people.count) people); owner left unresolved.")
        return "Your FamilySearch ID \(id.uppercased()) isn't in the installed tree — check Hallie's settings or re-download the tree."
    }

    static func resolve(_ name: String, graph: GedcomFamilyGraph,
                        familySearchID: String? = nil) -> Match {
        if let pinned = graph.person(familySearchID: familySearchID) {
            return .one(pinned, note: "Basis: “you” = \(pinned.name) (FamilySearch ID \(pinned.familySearchID ?? "")).")
        }
        if let stale = stalePinLine(familySearchID: familySearchID, graph: graph) {
            return .none(reason: stale)
        }
        let like = graph.people(namedLike: name)
        if like.count == 1 {
            return .one(like[0], note: "Basis: “you” = \(like[0].name) (matched \(name) by name).")
        }
        if like.count > 1 {
            if let root = graph.rootPerson, like.contains(where: { $0.id == root.id }) {
                return .one(root, note: "Basis: “you” = \(root.name) (tree root).")
            }
            return .many(like)
        }
        if let root = graph.rootPerson {
            return .one(root, note: "Basis: “you” = \(root.name) (tree root; \(name) has no tree record).")
        }
        return .none()
    }

    /// True when `typed` is one of the ways the owner refers to themself:
    /// the first token is the owner's first token AS CONFIGURED ("rick") or
    /// its formal expansion ("richard"), and every typed token appears in
    /// the owner's name. "rick", "Rick Breen", "richard breen jr" → yes for
    /// owner "Rick Breen"; "breen" alone, "rick lamb" → no. "dick" → no:
    /// two diminutives of one formal name are two people (Rick's father is
    /// Dick), so a typed nickname is never expanded on this side.
    static func isOwnerSpelling(_ typed: String, owner: String?) -> Bool {
        guard let owner else { return false }
        let suffixes = GedcomFamilyGraph.nameSuffixes
        let t = FamilyIdentityText.tokens(typed).filter { !suffixes.contains($0) }
        let o = FamilyIdentityText.tokens(owner).filter { !suffixes.contains($0) }
        guard let first = t.first, let ownerFirst = o.first,
              first == ownerFirst || first == GedcomFamilyGraph.diminutives[ownerFirst]
        else { return false }
        let ownerExpanded = Set(o.map { GedcomFamilyGraph.diminutives[$0] ?? $0 })
        return t.allSatisfy { o.contains($0) || ownerExpanded.contains($0) }
    }
}
