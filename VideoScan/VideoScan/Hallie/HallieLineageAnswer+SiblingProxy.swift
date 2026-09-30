// HallieLineageAnswer+SiblingProxy.swift
// "How is Beth related to Donna?" when Beth is not in the family tree.
//
// Rick, 2026-09-08 (lineage queries are sibling-equivalent): full siblings
// share every ancestral line, so a question about Beth, Tim or Ellen is the
// same question about Rick for anything ABOVE them. Rick, 2026-09-18: family
// members will ask these ("how are we related?"), and his siblings are in
// the People tab — with kinship links to Rick and to both parents — but not
// in the FamilySearch tree, so "Beth" asked which of 2,190 Elizabeths.
//
// A People-tab person with no tree pin stands on a FULL sibling's record —
// full meaning attested full, or both parents linked in the People tab
// (half-siblings share one line only, so they never stand in). Only what is
// above the record transfers: ancestors, and cousin arithmetic through
// ancestors. The sibling's spouse, children and in-laws are NOT the proxy's,
// so marriage asides are dropped and direct relations are used only when the
// other person is an ancestor of the record.

import Foundation
import VideoScanCore

extension HallieLineageAnswer {

    /// A People-tab person standing on a full sibling's tree record.
    struct SiblingProxy: Equatable {
        /// What to call them: the name or alias the question used.
        let displayName: String
        /// "sister" / "brother" / "sibling", from the People-tab sex.
        let kinWord: String
        /// The full sibling whose record they stand on.
        let sibling: HallieTurnExecutor.ProfileSnapshot
        let siblingIsOwner: Bool
        /// The sibling's record: every ancestor on it is theirs too.
        let record: GedcomFamilyGraph.Person
    }

    /// The proxy for a typed name, or nil when the name is not one People
    /// profile, the profile is pinned to the tree, or no full sibling of
    /// theirs resolves to a record.
    static func siblingProxy(_ typed: String, context: HallieTurnExecutor.Context,
                             graph: GedcomFamilyGraph) -> SiblingProxy? {
        let profiles = HallieTurnExecutor.PeopleTab.merged(context.profiles ?? [])
        guard !profiles.isEmpty,
              case .one(let person) = HallieTurnExecutor.PeopleTab.exactClaim(typed, in: profiles),
              person.treeIdentity == nil, !person.treeIdentityUnreadable,
              !isOwnerProfile(person, context: context) else { return nil }

        let siblings = profiles
            .filter { $0.stableID != person.stableID && areFullSiblings(person, $0, among: profiles) }
            .sorted { lhs, rhs in
                let lo = isOwnerProfile(lhs, context: context), ro = isOwnerProfile(rhs, context: context)
                return lo != ro ? lo : lhs.canonicalName < rhs.canonicalName
            }
        for sibling in siblings {
            let owner = isOwnerProfile(sibling, context: context)
            let resolved = owner
                ? resolveDetailed(nil, context: context, graph: graph)
                : sibling.treeIdentity == nil
                    ? resolveDetailed(sibling.fullNameForms.first ?? sibling.canonicalName, context: context, graph: graph)
                    : .failure(nil)
            guard case .success(let record, _) = resolved else { continue }
            let typedForm = ([person.canonicalName] + person.aliases)
                .first { $0.caseInsensitiveCompare(typed.trimmingCharacters(in: .whitespaces)) == .orderedSame }
            let display = (typedForm ?? person.canonicalName)
            let kinWord: String
            switch person.sex {
            case .female?: kinWord = "sister"
            case .male?: kinWord = "brother"
            default: kinWord = "sibling"
            }
            return SiblingProxy(displayName: display.prefix(1).uppercased() + display.dropFirst(),
                                kinWord: kinWord, sibling: sibling, siblingIsOwner: owner, record: record)
        }
        return nil
    }

    static func isOwnerProfile(_ profile: HallieTurnExecutor.ProfileSnapshot,
                               context: HallieTurnExecutor.Context) -> Bool {
        guard let owner = context.speakers.ownerName else { return false }
        return ([profile.canonicalName] + profile.aliases + profile.fullNameForms)
            .contains { HallieOwnerResolver.isOwnerSpelling($0, owner: owner) }
    }

    /// "X is `relation` of Y", recorded on either profile (the People tab
    /// stores each link once, on one side).
    private static func linked(_ x: HallieTurnExecutor.ProfileSnapshot, _ relation: KinshipRelation,
                               _ y: HallieTurnExecutor.ProfileSnapshot) -> Kinship? {
        x.kinships.first { $0.relation == relation && anchors($0.relativeTo, y) }
            ?? y.kinships.first { $0.relation == relation.inverse && anchors($0.relativeTo, x) }
    }

    private static func anchors(_ anchor: KinshipAnchor, _ profile: HallieTurnExecutor.ProfileSnapshot) -> Bool {
        switch anchor {
        case .profile(let id): return profile.uuid == id
        case .profileName(let name): return name.caseInsensitiveCompare(profile.canonicalName) == .orderedSame
        case .treePerson, .treePointer: return false
        }
    }

    private static func parents(of child: HallieTurnExecutor.ProfileSnapshot,
                                among profiles: [HallieTurnExecutor.ProfileSnapshot]) -> Set<String> {
        Set(profiles.filter { linked($0, .parent, child) != nil }.map(\.stableID))
    }

    /// Attested full, or both parents shared in the People tab.
    static func areFullSiblings(_ a: HallieTurnExecutor.ProfileSnapshot, _ b: HallieTurnExecutor.ProfileSnapshot,
                                among profiles: [HallieTurnExecutor.ProfileSnapshot]) -> Bool {
        if let link = linked(a, .sibling, b), case .attestedHalf = link.basis { return false }
        if let link = linked(a, .sibling, b), link.basis == .attestedFull { return true }
        return parents(of: a, among: profiles).intersection(parents(of: b, among: profiles)).count >= 2
    }

    /// The sentence that says whose record a proxy stands on.
    static func proxySentence(_ proxy: SiblingProxy, siblingName: String) -> String {
        let whose = proxy.siblingIsOwner ? "your" : HallieLineageQuestion.possessive(siblingName)
        let pronoun = proxy.kinWord == "sister" ? "her" : proxy.kinWord == "brother" ? "his" : "their"
        return "\(proxy.displayName) isn’t in the family tree \(pronoun == "their" ? "themself" : pronoun == "her" ? "herself" : "himself"), but the People tab records \(pronoun == "their" ? "them" : pronoun == "her" ? "her" : "him") as \(whose) full \(proxy.kinWord), so \(whose) ancestors are \(pronoun == "their" ? "theirs" : pronoun == "her" ? "hers" : "his") too."
    }

    /// The answer when either side stands on a sibling's record. Only what
    /// is above the record transfers: same record → the People-tab sibling
    /// relation; an ancestor of the record → that ancestor, named for the
    /// proxy; otherwise the cousin arithmetic through shared ancestors,
    /// with no marriage aside (the sibling's spouse is not the proxy's).
    static func proxyAnswer(_ pa: GedcomFamilyGraph.Person, _ pb: GedcomFamilyGraph.Person,
                            proxies: [Int: SiblingProxy], context: HallieTurnExecutor.Context,
                            graph: GedcomFamilyGraph, basis: String, query: String,
                            chips: [HallieTurnExecutor.OfferedAction]) -> Result {
        let ownerID: String? = {
            if case .success(let owner, _) = resolveDetailed(nil, context: context, graph: graph) { return owner.id }
            return nil
        }()
        let people = [pa, pb]
        func speaker(_ slot: Int) -> Speaker {
            if let proxy = proxies[slot] { return .named(proxy.displayName) }
            return people[slot].id == ownerID ? .owner : .named(people[slot].name)
        }
        func siblingName(_ proxy: SiblingProxy) -> String {
            proxy.sibling.aliases.first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? proxy.sibling.canonicalName
        }
        let notes = proxies.keys.sorted().compactMap { proxies[$0] }
            .map { proxySentence($0, siblingName: siblingName($0)) }
        let proxyBasis = basis + " " + proxies.keys.sorted().compactMap { proxies[$0] }.map {
            "People tab: \($0.displayName) is a full sibling of \($0.sibling.canonicalName) (both parents linked, or attested full); the ancestry is read from \($0.record.name) (\($0.record.id))."
        }.joined(separator: " ")
        func answered(_ prose: String, focus: GedcomFamilyGraph.Person?) -> Result {
            Result(route: .graph, outcome: .answered, prose: prose, basisLine: proxyBasis,
                   queryDescription: query + " (People-tab sibling)", citations: [],
                   catalogPersonName: focus?.name,
                   offeredActions: focus.map { [.openFamilyTreePerson(personID: $0.id, personName: $0.name)] } ?? chips)
        }

        // Same record: the two are siblings (or one stands on the other).
        if pa.id == pb.id {
            let a = speaker(0), b = speaker(1)
            if let proxy = proxies[1] ?? proxies[0], proxies.count == 1 {
                let other = proxies[1] == nil ? b : a
                return answered("\(proxy.displayName) is \(other.possessive) \(proxy.kinWord) — the People tab records the same two parents for both, so every ancestor in the family tree is shared.", focus: nil)
            }
            return answered("\(a.name) and \(b.name) are full siblings in the People tab — the same two parents, so the same ancestors.", focus: nil)
        }

        // An ancestor of a proxy's record is that proxy's ancestor too.
        for (slot, proxy) in proxies.sorted(by: { $0.key < $1.key }) {
            let other = people[1 - slot]
            let up = GedcomFamilyGraph.AncestorIndex(graph: graph, descendantID: proxy.record.id)
            guard proxies[1 - slot] == nil, let generations = up.generations(from: other.id),
                  let path = up.path(from: other.id) else { continue }
            let label = GedcomFamilyGraph.generationLabel(generations: generations, sex: other.sex)
            let chain = ([proxy.displayName] + path.reversed().dropFirst().map(\.name)).joined(separator: " → ")
            let term = "\(other.name) is \(HallieLineageQuestion.possessive(proxy.displayName)) \(label)."
            return answered(term + (generations > 1 ? " Line: " + chain + "." : "") + " " + notes.joined(separator: " "),
                            focus: other)
        }

        // Cousin arithmetic through the shared ancestors. The owner first.
        let ownerSlot = [0, 1].first { speaker($0) == .owner }
        let (x, y) = ownerSlot == 1 ? (1, 0) : (0, 1)
        guard let ancestry = graph.commonAncestry(of: people[x].id, and: people[y].id),
              let nearest = ancestry.nearest else {
            return Result(route: .graph, outcome: .declined,
                          prose: "\(speaker(x).name.prefix(1).uppercased() + speaker(x).name.dropFirst()) and \(speaker(y).name) share no recorded ancestor in the family tree. " + notes.joined(separator: " "),
                          basisLine: proxyBasis, queryDescription: query, citations: [], catalogPersonName: nil,
                          offeredActions: chips)
        }
        let prose = commonAncestryProse(ancestry, nearest: nearest, a: speaker(x), b: speaker(y),
                                        ownerRecordName: nil, affinalTerm: nil)
        return Result(route: .graph, outcome: .answered,
                      prose: notes.joined(separator: " ") + " " + prose,
                      basisLine: proxyBasis + " Cousin term from the two depths; separate lines = shared ancestors none of whose children are shared.",
                      queryDescription: query + " (People-tab sibling) → " + nearest.ancestors.map(\.name).joined(separator: " and "),
                      citations: [], catalogPersonName: nearest.ancestors[0].name,
                      offeredActions: nearest.ancestors.map { .openFamilyTreePerson(personID: $0.id, personName: $0.name) })
    }
}
