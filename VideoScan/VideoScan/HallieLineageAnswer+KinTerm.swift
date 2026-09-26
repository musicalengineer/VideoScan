// HallieLineageAnswer+KinTerm.swift
// A kin term — "dad", "my dad", "our mother", "daddy" — names the OWNER's
// relative, and is never looked up as a tree NAME.
//
// Live 2026-09-26 14:14 ET (Rick, app): "find videos of dad" → "Dafydd ab
// Einion "Y Giwn Llwyd" was born about 1360, more than five centuries
// before motion pictures …". Not a fuzzy match: the merged FamilySearch
// tree's @IB21341@ carries fifteen NAME records and the seventh is "Dad ab
// Giwn", so GedcomFamilyGraph.people(matching:) — token-exact over EVERY
// NAME record of every person — returned him for "Dad", and every rung
// that guards fuzzy recovery (the ≤4-letter rule, the bare-given-name
// rule) was never reached. The lineage shapes ("videos of X", "photo of
// X", "X's line", "center on X") all resolve their person through
// `resolveDetailed`, and none of them asked whether X was a kin word
// first. The person-fact lane (GH #180, 2026-09-11) and the temporal lane
// (2026-09-21) had each fixed this for their own road; this is the shared
// resolver's turn, so every lineage shape gets it at once.
//
// The ladder, first rung that settles wins — the same one
// SpeakerKinship.rebind climbs for "videos of my dad" on the presence route:
//   0. a BARE kin word that a CURATED name already claims ("Ma" is Eileen's
//      People-tab alias) is that alias, exactly as GH #180 ruled: the kin
//      rule yields to the People tab and the CyberBrain, and to nothing
//      else. A possessive ("my ma") never yields.
//   1. the People tab: the owner's profile's relationship rows ("Rick:
//      child of Dad") → the relative → their pinned tree record.
//   2. the owner's OWN tree record (pinned by FamilySearch ID, else
//      HallieOwnerResolver) → GedcomFamilyGraph.relatives, or the extended
//      walk for grandparents and beyond.
//   3. an honest decline that names the gap. Never a name lookup.
//
// C++ readers: think of this as a guard clause hoisted to the top of the
// shared resolver — `if (isKinTerm(x)) return bindRelative(x);` — instead
// of one more special case in each caller.

import Foundation
import VideoScanCore

extension HallieLineageAnswer {

    /// Nil = `typed` is not a kin term (or a curated name claims it), so the
    /// ordinary name resolution runs. Anything else is the resolver's
    /// verdict for the OWNER's relative: the person, a which-one, or an
    /// honest decline.
    static func ownerRelative(_ typed: String,
                              context: HallieTurnExecutor.Context,
                              graph: GedcomFamilyGraph) -> Detailed? {
        typealias Exec = HallieTurnExecutor
        let term = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let relative = Exec.RelativeFactSubject.parse(term) else { return nil }
        // Rung 0: GH #180 — a curated name keeps the ordinary road.
        if !Exec.RelativeFactSubject.hasPossessive(term),
           Exec.isCuratedPerson(term, context: context) {
            return nil
        }
        let ask = KinAsk(term: term, relative: relative)
        guard let ownerName = context.speakers.ownerName, !ownerName.isEmpty else {
            return ask.decline(
                "I can't tell whose \(ask.sideWord)\(ask.word) “\(term)” means — set your name in Hallie's settings and I'll look \(ask.them) up.",
                basis: "Basis: a kin term names the owner's relative, and no owner is signed in; the family tree's names were not searched.")
        }
        if let fromPeopleTab = peopleTabRelative(ask, ownerName: ownerName, context: context, graph: graph) {
            return fromPeopleTab
        }
        return treeRelative(ask, ownerName: ownerName, context: context, graph: graph)
    }

    /// The parsed term and the words its prose uses.
    private struct KinAsk {
        let term: String
        let relative: HallieTurnExecutor.RelativeFactSubject
        var word: String { relative.relation.rawValue.replacingOccurrences(of: "-", with: " ") }
        var sideWord: String { relative.side.map { $0.rawValue + " " } ?? "" }
        var them: String { HallieLineageAnswer.objectPronoun(for: relative.relation) }

        func decline(_ prose: String, basis: String) -> Detailed {
            .failure(Result(
                route: .graph, outcome: .declined, prose: prose, basisLine: basis,
                queryDescription: "lineage: resolve \(term) (kin term, unbound)",
                citations: [], catalogPersonName: nil))
        }
    }

    /// Rung 1: the People tab's own relationship rows. Nil when the tab
    /// cannot say (no rows, no unique owner, a relation the overlay cannot
    /// express, a side-qualified ask) — the tree gets its turn.
    private static func peopleTabRelative(_ ask: KinAsk, ownerName: String,
                                          context: HallieTurnExecutor.Context,
                                          graph: GedcomFamilyGraph) -> Detailed? {
        guard ask.relative.side == nil,
              let overlay = HallieTurnExecutor.kinshipOverlay(context: context), !overlay.isEmpty,
              let wanted = KinshipRelation.parse(term: ask.relative.relation.rawValue) else { return nil }
        let owners = overlay.nodes(claiming: ownerName, ownerName: ownerName)
        guard owners.count == 1 else { return nil }
        let hits = overlay.relatives(of: owners[0], relation: wanted.relation, sex: wanted.sex)
        guard let hit = hits.first else { return nil }
        if hits.count > 1 {
            let linked = hits.compactMap { $0.member.gedcomID.flatMap { graph.people[$0] } }
            if linked.count == hits.count { return .ambiguous(linked) }
            return ask.decline(
                "The People tab lists more than one \(ask.word) for \(ownerName): "
                    + hits.map(\.member.displayName).joined(separator: ", ")
                    + ". Which one do you mean?",
                basis: "Basis: People tab relationships; the family tree's names were not searched.")
        }
        if let id = hit.member.gedcomID, let person = graph.people[id] {
            return .success(
                person,
                note: "“\(ask.term)” taken as \(person.name), \(ask.word) of \(ownerName) on the People tab.")
        }
        return ask.decline(
            "“\(ask.term)” is \(hit.member.displayName) on the People tab, but that profile isn't linked to a family-tree record yet, so I can't look \(ask.them) up in the tree.",
            basis: "Basis: People tab relationships; the profile carries no family-tree pin; the tree's names were not searched.")
    }

    /// Rungs 2 and 3: the owner's own tree record, then a walk — never a
    /// name — and the honest decline when the walk finds nobody.
    private static func treeRelative(_ ask: KinAsk, ownerName: String,
                                     context: HallieTurnExecutor.Context,
                                     graph: GedcomFamilyGraph) -> Detailed {
        let owner: GedcomFamilyGraph.Person
        let ownerNote: String
        switch HallieOwnerResolver.resolve(
            ownerName, graph: graph, familySearchID: context.speakers.ownerFamilySearchID) {
        case .one(let person, let note):
            owner = person
            ownerNote = note
        case .many:
            return ask.decline(
                "More than one person in the family tree matches your name (\(ownerName)), so I can't tell who “\(ask.term)” is. Set your FamilySearch ID in Hallie's settings and I will.",
                basis: "Basis: the owner's name matches several tree records; the tree's names were not searched for the kin term.")
        case .none(let reason):
            return ask.decline(
                reason ?? "I don't find you (\(ownerName)) in the family tree, so I can't tell who “\(ask.term)” is.",
                basis: "Basis: the owner is not in the family tree; the tree's names were not searched for the kin term.")
        }
        let people = relatives(of: owner, ask: ask, graph: graph)
        switch people.count {
        case 1:
            return .success(
                people[0],
                note: "“\(ask.term)” taken as \(people[0].name), \(ask.sideWord)\(ask.word) of \(owner.name) in the family tree.")
        case 0:
            // Rung 3: the honest decline. The tree's 39k names stay unread.
            return ask.decline(
                "The family tree doesn't record a \(ask.sideWord)\(ask.word) for \(owner.name), so I can't tell who “\(ask.term)” is. Add \(ask.them) on the People tab, or tell me — “let me tell you about \(ask.term)” — and I'll remember.",
                basis: ownerNote + " The tree records no \(ask.sideWord)\(ask.word) for that person; its names were not searched for the kin term.")
        default:
            return .ambiguous(people)
        }
    }

    /// One hop (father, sister …) or the extended walk (grandmother,
    /// great-great-grandfather, aunt …) from the owner's own record.
    private static func relatives(of owner: GedcomFamilyGraph.Person, ask: KinAsk,
                                  graph: GedcomFamilyGraph) -> [GedcomFamilyGraph.Person] {
        let raw = ask.relative.relation.rawValue
        if let relation = GedcomFamilyGraph.Relation(rawValue: raw) {
            return graph.relatives(relation, of: owner)
        }
        guard let extended = GedcomFamilyGraph.ExtendedRelation(rawValue: raw),
              case .found(let paths) = graph.relatives(
                extended,
                side: ask.relative.side.flatMap { GedcomFamilyGraph.KinshipSide(rawValue: $0.rawValue) },
                of: owner) else { return [] }
        var seen = Set<String>()
        return paths.map(\.relative).filter { seen.insert($0.id).inserted }
    }

    /// "him" / "her" / "them" for the relation word, for the prose above.
    private static func objectPronoun(for relation: ArchivistQueryAST.Graph.Relation) -> String {
        switch relation {
        case .father, .brother, .son, .husband, .grandfather, .greatGrandfather,
             .greatGreatGrandfather, .uncle, .nephew, .fatherInLaw, .brotherInLaw, .sonInLaw:
            return "him"
        case .mother, .sister, .daughter, .wife, .grandmother, .greatGrandmother,
             .greatGreatGrandmother, .aunt, .niece, .motherInLaw, .sisterInLaw, .daughterInLaw:
            return "her"
        default:
            return "them"
        }
    }
}
