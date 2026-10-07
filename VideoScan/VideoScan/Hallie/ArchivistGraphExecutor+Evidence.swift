import Foundation

extension ArchivistGraphExecutor {
    static func fromPolicy(
        _ answer: ArchivistBiographyAnswer,
        evidence: ArchivistGraphEvidence?,
        identityBridge: ArchivistGraphEvidence.IdentityBridge?,
        unresolvedProfileRoute: ProfileRoute?,
        // The People profile that supplied the spoken DATE, when one did.
        // An identity bridge outranks `answer.basis` below, so a policy
        // basis naming the People tab was being discarded and the answer
        // spoke a profile date over a basis line crediting the tree
        // (codex HOLD on 6e01da6a, 2026-09-06). Appended, not substituted:
        // the bridge and the tree provenance are both still true.
        dateSourceName: String? = nil
    ) -> ArchivistGraphResult {
        let conclusion: ArchivistGraphConclusion
        switch answer.state {
        case .answered: conclusion = .answered
        case .missingFact: conclusion = .missingFact
        case .notFound: conclusion = .personNotFound
        case .ambiguous: conclusion = .personAmbiguous
        }
        return ArchivistGraphResult(
            conclusion: conclusion,
            prose: answer.text,
            basisLine: {
                let base = identityBridgeBasis(
                    identityBridge, answered: answer.state == .answered
                        || answer.state == .missingFact)
                    ?? unresolvedProfileRouteBasis(unresolvedProfileRoute)
                    ?? answer.basis
                guard let dateSourceName else { return base }
                return base + " Date from the People tab profile \u{201C}\(dateSourceName)\u{201D}."
            }(),
            evidence: answer.state == .answered || answer.state == .missingFact
                ? evidence : nil,
            candidates: answer.candidates,
            profileCandidates: [],
            ambiguityCandidates: answer.candidates.map {
                ArchivistGraphAmbiguityCandidate(
                    id: .gedcomPersonID($0.id),
                    canonicalName: $0.name,
                    label: $0.label)
            },
            catalogPersonName: answer.catalogPersonName)
    }

    static func biographyEvidence(
        for person: GedcomFamilyGraph.Person,
        in graph: GedcomFamilyGraph,
        identityBridge: ArchivistGraphEvidence.IdentityBridge?
    ) -> ArchivistGraphEvidence {
        // Relation groups and their members use the policy's exact order so
        // evidence stays aligned with its deterministic biography prose.
        let relationships: [ArchivistGraphEvidence.Relationship] = [
            relationship(
                .parents,
                people: ArchivistBiographyPolicy.orderedPeople(
                    graph.relatives(.parents, of: person))),
            relationship(
                .spouse,
                people: ArchivistBiographyPolicy.orderedPeople(
                    graph.relatives(.spouse, of: person))),
            relationship(
                .children,
                people: ArchivistBiographyPolicy.orderedPeople(
                    graph.relatives(.children, of: person))),
        ].filter { !$0.people.isEmpty }
        return ArchivistGraphEvidence(
            subjectID: person.id,
            subjectName: person.name,
            birthDate: person.birthDate,
            deathDate: person.deathDate,
            relationships: relationships,
            identityBridge: identityBridge)
    }

    /// `resolvedDateText` is the date the ANSWER actually speaks. The
    /// evidence must carry the same value: an answer citing evidence that
    /// contradicts it is worse for this product than either value being
    /// wrong on its own (codex HOLD on 6e01da6a, 2026-09-06).
    static func lifeDateEvidence(
        for person: GedcomFamilyGraph.Person,
        birth: Bool,
        identityBridge: ArchivistGraphEvidence.IdentityBridge?,
        resolvedDateText: String? = nil
    ) -> ArchivistGraphEvidence {
        ArchivistGraphEvidence(
            subjectID: person.id,
            subjectName: person.name,
            birthDate: birth ? (resolvedDateText ?? person.birthDate) : nil,
            deathDate: birth ? nil : (resolvedDateText ?? person.deathDate),
            relationships: [],
            identityBridge: identityBridge)
    }

    static func kinshipEvidence(
        for person: GedcomFamilyGraph.Person,
        relation: GedcomFamilyGraph.Relation,
        relatives: [GedcomFamilyGraph.Person],
        identityBridge: ArchivistGraphEvidence.IdentityBridge?
    ) -> ArchivistGraphEvidence {
        ArchivistGraphEvidence(
            subjectID: person.id,
            subjectName: person.name,
            birthDate: nil,
            deathDate: nil,
            relationships: [relationship(relation, people: relatives)],
            identityBridge: identityBridge)
    }

    private static func relationship(
        _ relation: GedcomFamilyGraph.Relation,
        people: [GedcomFamilyGraph.Person]
    ) -> ArchivistGraphEvidence.Relationship {
        ArchivistGraphEvidence.Relationship(
            relation: relation,
            people: people.map {
                .init(id: $0.id, name: $0.name)
            })
    }

    static func factualBasis(
        _ bridge: ArchivistGraphEvidence.IdentityBridge?
    ) -> String {
        identityBridgeBasis(bridge, answered: true)
            ?? ArchivistBiographyPolicy.gedcomBasis
    }

    private static func identityBridgeBasis(
        _ bridge: ArchivistGraphEvidence.IdentityBridge?,
        answered: Bool
    ) -> String? {
        guard let bridge else { return nil }
        let prefix = answered ? "Basis" : "Checked"
        return "\(prefix): People profile identity bridge “"
            + bridge.requestedName + "” → “"
            + bridge.profileCanonicalName
            + "” → GEDCOM “" + bridge.effectiveGEDCOMName
            + "”; family facts from imported family tree (GEDCOM)."
    }

    private static func unresolvedProfileRouteBasis(
        _ route: ProfileRoute?
    ) -> String? {
        guard let route else { return nil }
        let prefix = "Checked: People profile identity route “"
            + route.requestedName + "” → “"
            + route.profileCanonicalName + "”"
        if let problem = route.pinProblem {
            return prefix + "; " + problem
                + ". No name-based GEDCOM bridge was attempted."
        }
        return prefix + "; imported family tree (GEDCOM), but no unique GEDCOM "
            + "identity was resolved."
    }

    static func identityBridge(
        _ route: ProfileRoute?,
        effectivePerson: GedcomFamilyGraph.Person
    ) -> ArchivistGraphEvidence.IdentityBridge? {
        guard let route else { return nil }
        let requested = normalize(route.requestedName)
        let profile = normalize(route.profileCanonicalName)
        let effective = normalize(effectivePerson.name)
        guard requested != profile || profile != effective else { return nil }
        return ArchivistGraphEvidence.IdentityBridge(
            requestedName: route.requestedName,
            profileCanonicalName: route.profileCanonicalName,
            effectiveGEDCOMPersonID: effectivePerson.id,
            effectiveGEDCOMName: effectivePerson.name)
    }

    /// The People-tab relatives of a tree person, when that person IS a
    /// People-tab profile: through the profile the typed name went
    /// through (`profileStableID`), or through a profile pinned / assumed
    /// onto this tree record (the overlay put that profile on the record's
    /// own vertex). One hop only — a stored row, or a parent/child edge the
    /// overlay derived from sibling rows (2026-09-02, marked in the basis);
    /// never a composed route. Nil when nobody in the People tab is this
    /// person, so an unbridged card stays exactly as it was.
    static func peopleTabKin(
        for person: GedcomFamilyGraph.Person,
        profileStableID: String?,
        inputs: ArchivistGraphInputs
    ) -> HallieBiographyCard.PeopleTabKin? {
        let overlay = inputs.kinshipOverlay
        var node: FamilyKinshipOverlay.Node?
        if let profileStableID, let known = overlay.node(profileStableID: profileStableID) {
            node = known
        } else if overlay.member(.tree(gedcomID: person.id))?.profileStableID != nil {
            node = .tree(gedcomID: person.id)
        }
        guard let node, let member = overlay.member(node) else { return nil }
        var storedOn = Set<String>()
        func relatives(_ relation: KinshipRelation) -> [HallieBiographyCard.PeopleTabKin.Relative] {
            overlay.relatives(of: node, relation: relation)
                .filter { $0.hops.count == 1 }
                .map { hit in
                    hit.hops.forEach { storedOn.insert($0.storedOn) }
                    // Evidence for a stored row: the relative's own profile
                    // (the row names them). Evidence for a DERIVED edge:
                    // the profile whose row was copied — never the relative
                    // or the parent the inference points at (codex #984
                    // item 4).
                    let hop = hit.hops[0]
                    let evidence = hop.isDerived
                        ? (hop.storedOnIdentity.isEmpty ? hop.storedOn : hop.storedOnIdentity)
                        : (hit.member.identity.isEmpty ? hit.member.node.auditID : hit.member.identity)
                    // A stored sibling row takes the pair's ONE verdict
                    // (codex #1019 item 2): "half-brother", or the neutral
                    // "sibling" for a conflict the warning explains.
                    let term = relation == .sibling && !hop.isDerived
                        ? FamilyKinshipOverlay.siblingTerm(overlay.siblingVerdict(node, hit.member.node), sex: hit.member.sex)
                        : relation.term(sex: hit.member.sex)
                    return .init(
                        name: hit.member.name,
                        term: term,
                        evidenceID: evidence,
                        gedcomID: hit.member.gedcomID,
                        derivation: overlay.derivationNote(for: hit.hops))
                }
        }
        let siblings = relatives(.sibling)
        let children = relatives(.child)
        let spouses = relatives(.spouse)
        // A sibling set of this person's that failed closed: said in the
        // basis even when no row was usable.
        return .init(profileName: member.name,
                     profileStableID: member.profileStableID ?? "",
                     siblings: siblings, children: children,
                     spouses: spouses, storedOn: storedOn.sorted(),
                     warnings: overlay.derivationWarnings(touching: [node]))
    }
}
