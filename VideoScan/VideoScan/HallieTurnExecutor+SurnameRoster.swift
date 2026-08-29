// HallieTurnExecutor+SurnameRoster.swift
// The turn executor's side of LIVE MISS #11 (Rick, 2026-08-29: "tell me
// about pa oc'connor" → bare decline). When the graph says "person not
// found" for a two-token name whose SURNAME is in the tree (exactly or by
// spelling recovery — HallieSurnameRoster), one of three things happens,
// in this order:
//
//   1. a People-tab profile or a CyberBrain person goes by the given token
//      ("Pa", "Nana", "Grampa") and bridges to ONE member of that surname
//      family → the graph is re-run pinned to that person (answered
//      biography, the bridge said in the basis line);
//   2. the given token IS a member's given or middle name (diminutives
//      allowed) → one member answers, several ask which one — the normal
//      which-one (HallieWhichOne), the spelling recovery said in the basis;
//   3. otherwise the honest roster which-one: "I don't know a “Pa”
//      O'Connor. The O'Connors in the tree are … — which one?" with chips
//      (capped, home people first) and the "let me tell you about…" offer.
//      Offered only after the People-tab and near-miss ("did you mean…")
//      checks, which are closer answers when they apply.
//
// Never a catalog search: no catalogPersonName, no media action.

import Foundation
import VideoScanCore

extension HallieTurnExecutor {

    enum SurnameRosterStep {
        /// Re-run the graph pinned to this selection; `note` goes in front
        /// of the basis line ("“Pa” = Christopher Dennis O'Connor (People
        /// tab alias); took “oc'connor” as O'Connor").
        case resolved(ArchivistGraphSubjectSelection, note: String)
        /// A which-one among members who DO carry the given name — return
        /// at once.
        case replyNow(Result)
        /// The surname roster — return unless the People tab or a near-miss
        /// suggestion answers first.
        case roster(Result)
    }

    static func surnameRosterStep(
        typed: String,
        request: Request,
        context: Context,
        graph: GedcomFamilyGraph,
        queryDescription: String
    ) -> SurnameRosterStep? {
        guard let split = HallieSurnameRoster.split(typed),
              let family = HallieSurnameRoster.family(forSurname: split.surname, in: graph)
        else { return nil }
        let familyIDs = Set(family.people.map(\.id))

        func note(_ bridge: String?) -> String {
            [bridge, family.recoveryNote].compactMap { $0 }.joined(separator: "; ")
        }

        // 1. An alias for the given token, bridged into this family.
        if let profile = PeopleTab.profile(claiming: split.given, in: context.profiles ?? []) {
            let bridged = bridge(profile: profile, into: family, graph: graph)
            if bridged.count == 1 {
                let person = bridged[0]
                return .resolved(
                    .gedcomPersonID(person.id),
                    note: note("“\(HallieSurnameRoster.titleCased(split.given))” = \(person.name) (People tab: \(profile.canonicalName))"))
            }
        }
        if let brain = context.cyberBrain,
           case .resolved(let known) = brain.resolve(split.given),
           let gedcomID = known.gedcomPersonID, familyIDs.contains(gedcomID),
           let person = graph.people[gedcomID] {
            return .resolved(
                .gedcomPersonID(person.id),
                note: note("“\(HallieSurnameRoster.titleCased(split.given))” = \(person.name) (family knowledge: \(known.canonicalName))"))
        }

        // 2. The given token is a member's own name.
        let named = HallieSurnameRoster.members(named: split.givenKey, in: family)
        if named.count == 1 {
            return .resolved(.gedcomPersonID(named[0].id), note: note(nil))
        }
        if named.count > 1 {
            let arrangement = HallieWhichOne.arrange(
                named, graph: graph, ownerFamilySearchID: context.speakers.ownerFamilySearchID)
            let shown = chips(arrangement.shown)
            let echo = "\(split.given) \(family.surname)"
            var reply = Result(
                route: .graph,
                outcome: .needsClarification,
                prose: HallieWhichOne.prose(typed: echo, arrangement: arrangement, labels: shown.map(\.label)),
                basisLine: HallieWhichOne.basis(typed: echo, arrangement: arrangement),
                queryDescription: queryDescription,
                citations: [],
                catalogPersonName: nil,
                clarification: arrangement.offersChips
                    ? makeClarification(intent: request.intent, stage: .gedcomPerson,
                                        candidates: shown, context: context)
                    : nil)
            if let recovery = family.recoveryNote { reply = reply.prefixingBasis(recovery) }
            return .replyNow(reply)
        }

        // 3. The roster.
        let arrangement = HallieWhichOne.arrange(
            family.people, graph: graph, ownerFamilySearchID: context.speakers.ownerFamilySearchID)
        let shown = chips(arrangement.shown)
        return .roster(Result(
            route: .graph,
            outcome: .needsClarification,
            prose: HallieSurnameRoster.prose(
                given: split.given, family: family, arrangement: arrangement, labels: shown.map(\.label)),
            basisLine: HallieSurnameRoster.basis(given: split.given, family: family, arrangement: arrangement),
            queryDescription: queryDescription,
            citations: [],
            catalogPersonName: nil,
            clarification: makeClarification(
                intent: request.intent, stage: .gedcomPerson, candidates: shown, context: context),
            // Fixed text: the roster and the offer must not be re-phrased
            // by the composer into a claim about who "Pa" is.
            answerPlan: nil))
    }

    private static func chips(_ people: [GedcomFamilyGraph.Person]) -> [Candidate] {
        people.map { person in
            Candidate(
                id: .gedcomPersonID(person.id),
                canonicalName: person.name,
                label: ArchivistBiographyPolicy.disambiguationCandidate(for: person).label)
        }
    }

    /// The family members a People profile's spellings name: a one-word
    /// spelling ("Christopher", "Chris") is a given name within the family;
    /// a fuller one must equal a member's name (or match it the way the
    /// tree's exact lookup does). Distinct by GEDCOM pointer, name order.
    private static func bridge(
        profile: ProfileSnapshot,
        into family: HallieSurnameRoster.Family,
        graph: GedcomFamilyGraph
    ) -> [GedcomFamilyGraph.Person] {
        let familyIDs = Set(family.people.map(\.id))
        var byID: [String: GedcomFamilyGraph.Person] = [:]
        for spelling in [profile.canonicalName] + profile.aliases {
            let tokens = FamilyIdentityText.tokens(FamilyNameNormalizer.normalizeName(spelling))
            guard !tokens.isEmpty else { continue }
            if tokens.count == 1 {
                for person in HallieSurnameRoster.members(named: tokens[0], in: family) {
                    byID[person.id] = person
                }
            } else {
                for person in graph.people(matching: spelling) where familyIDs.contains(person.id) {
                    byID[person.id] = person
                }
            }
        }
        return ArchivistBiographyPolicy.orderedPeople(Array(byID.values))
    }
}
