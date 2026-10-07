import Foundation

extension ArchivistGraphExecutor {
    /// Living or passed on for the resolved subject (LifeStatus,
    /// 2026-09-01): the tree record's verdict, overridden by a death the
    /// People-tab profile records when the subject came through one.
    static func subjectLifeStatus(
        treePerson: GedcomFamilyGraph.Person?,
        profileStableID: String?,
        inputs: ArchivistGraphInputs
    ) -> LifeStatus? {
        let profile = profileStableID.flatMap { id in inputs.profiles.first { $0.stableID == id } }
        switch (treePerson, profile) {
        case (nil, nil):
            return nil
        case (let person?, nil):
            return LifeStatus.of(person, in: inputs.graph)
        case (let person, let profile?):
            return LifeStatus.ofProfile(deathdate: profile.deathdate, bridged: person, in: inputs.graph)
        }
    }

    static func executeResolved(
        _ query: ArchivistGraphQuery,
        person: GedcomFamilyGraph.Person,
        inputs: ArchivistGraphInputs,
        identityBridge: ArchivistGraphEvidence.IdentityBridge?,
        profileStableID: String?
    ) -> ArchivistGraphResult {
        let life = subjectLifeStatus(
            treePerson: person, profileStableID: profileStableID, inputs: inputs)
        return ResolvedSubject(
            person: person, inputs: inputs, identityBridge: identityBridge,
            profileStableID: profileStableID, lifeStatus: life)
            .execute(query)
            .withSubjectLifeStatus(life)
    }

    /// Immutable identity and inputs shared by the answer handlers after resolution succeeds.
    private struct ResolvedSubject {
        let person: GedcomFamilyGraph.Person
        let inputs: ArchivistGraphInputs
        let identityBridge: ArchivistGraphEvidence.IdentityBridge?
        let profileStableID: String?
        let lifeStatus: LifeStatus?

        func execute(_ query: ArchivistGraphQuery) -> ArchivistGraphResult {
            switch query.operation {
            case .biography, .familyTree:
                return personCard(query)
            case .birthPlace, .deathPlace:
                return lifePlace(query)
            case .birth, .death:
                return lifeDate(query)
            case .relationship:
                // Two-person operation; dispatched before single-subject
                // resolution. Reaching here means a caller misrouted it.
                return ArchivistGraphExecutor.decline(
                    .unsupportedPeopleCount(1),
                    prose: "To work out how two people are related I need both names — for example, how is Donna related to Thankful Pratt?",
                    basis: ArchivistGraphExecutor.queryValidationBasis)
            case .kinship:
                return kinship(query)
            }
        }

        private func resolvedVitalDates() -> HallieVitalDates.Resolved {
            HallieVitalDates.resolve(
                treePerson: person,
                profiles: inputs.profiles.map(HallieVitalProfile.init),
                graph: inputs.graph,
                throughProfileStableID: profileStableID)
        }

        private func personCard(_ query: ArchivistGraphQuery) -> ArchivistGraphResult {
            let graph = inputs.graph
            // ONE person card for both asks (live 2026-08-29: "tell me
            // about Matthew Rice" and "…family tree on Matthew Rice" drew
            // two different biographies). See HallieBiographyCard.
            if query.operation == .biography, query.relation != nil {
                return ArchivistGraphExecutor.declineUnexpectedRelation()
            }
            let peopleTab = ArchivistGraphExecutor.peopleTabKin(
                for: person, profileStableID: profileStableID, inputs: inputs)
            // Biography only: "tell me about Dad" is where a profile's
            // free-text note belongs. A family-tree VIEW is structure, not
            // a life, so it is deliberately left out of that one.
            // (Swift: an immediately-invoked closure ≈ a C++ IIFE lambda,
            // used here so `guard` can express the three conditions once.)
            let notedProfileStableID: String? = {
                guard query.operation == .biography,
                      let id = peopleTab?.profileStableID, !id.isEmpty else { return nil }
                return id
            }()
            // The shared vital-date seam both Hallie routes read
            // (HallieVitalDates, 2026-09-04). Rick's ruling: for a person
            // who has a People profile, the profile's birth/death dates are
            // the true ones and the tree's are wrong. `.none` — nobody's
            // profile owns this tree record, or ownership is contested —
            // leaves every date exactly as the tree records it, which is the
            // case for the ~39,237 people who are only in the tree.
            let vitals = resolvedVitalDates()
            let (answer, plan, card) = HallieBiographyCard.answer(
                for: person, in: graph, peopleTab: peopleTab, lifeStatus: lifeStatus,
                profileBirthdate: vitals.profileBirthdate,
                profileDeathdate: vitals.profileDeathdate)
            let result = ArchivistGraphExecutor.fromPolicy(
                answer,
                evidence: ArchivistGraphExecutor.biographyEvidence(
                    for: person, in: graph, identityBridge: identityBridge),
                identityBridge: identityBridge,
                unresolvedProfileRoute: nil)
            return ArchivistGraphResult(
                conclusion: result.conclusion,
                prose: result.prose,
                basisLine: result.basisLine + HallieBiographyCard.peopleTabBasis(card)
                    + HallieBiographyCard.dataQualityBasis(card)
                    + HallieBiographyCard.vitalDatesBasis(
                        profileName: vitals.profileName,
                        birth: vitals.profileBirthdate, death: vitals.profileDeathdate),
                evidence: result.evidence,
                candidates: result.candidates,
                profileCandidates: result.profileCandidates,
                ambiguityCandidates: result.ambiguityCandidates,
                catalogPersonName: result.catalogPersonName,
                familyTreeFocus: query.operation == .familyTree
                    ? .person(name: person.name) : nil,
                answerPlan: plan,
                possibleDuplicate: card.dataQualityFlags.first.map {
                    .init(personID: $0.child.id, personName: $0.child.name)
                },
                peopleTabProfileStableID: notedProfileStableID)
        }

        private func lifePlace(_ query: ArchivistGraphQuery) -> ArchivistGraphResult {
            let graph = inputs.graph
            guard query.relation == nil else {
                return ArchivistGraphExecutor.declineUnexpectedRelation()
            }
            // The place, not the date. lifePlace fails closed with its own
            // wording when the record simply has no place recorded, which
            // is common in this tree — that is a better answer than
            // silently handing back the birthday, which is what "where was
            // Eileen Latta born" used to do.
            // The DATE this sentence carries obeys the same seam as every
            // other route (HallieVitalDates migration, 2026-09-06): this
            // route had never read it, so "where was Eileen Latta born"
            // kept speaking the tree's year after Rick corrected her
            // profile. The place itself is still the tree's, per rule 4.
            let placeVitals = resolvedVitalDates()
            let placeDate = query.operation == .birthPlace
                ? placeVitals.profileBirthdate : placeVitals.profileDeathdate
            let placeAnswer = ArchivistBiographyPolicy.lifePlace(
                personID: person.id,
                birth: query.operation == .birthPlace,
                in: graph,
                dateTextOverride: placeDate.map {
                    HallieDateStyle.spoken($0, calendar: HallieVitalDates.utcCalendar)
                },
                dateSourceName: placeDate == nil ? nil : placeVitals.profileName)
            return ArchivistGraphExecutor.fromPolicy(
                placeAnswer,
                evidence: ArchivistGraphExecutor.lifeDateEvidence(
                    for: person, birth: query.operation == .birthPlace,
                    identityBridge: identityBridge,
                    resolvedDateText: placeDate.map {
                        HallieDateStyle.spoken($0, calendar: HallieVitalDates.utcCalendar)
                    }),
                identityBridge: identityBridge,
                unresolvedProfileRoute: nil,
                dateSourceName: placeDate == nil ? nil : placeVitals.profileName)
        }

        private func lifeDate(_ query: ArchivistGraphQuery) -> ArchivistGraphResult {
            let graph = inputs.graph
            guard query.relation == nil else {
                return ArchivistGraphExecutor.declineUnexpectedRelation()
            }
            // Fourth route found during the migration, 2026-09-06: "when
            // was Ma born" read the tree directly, one case away from the
            // birth-place route above. Same seam, same rule.
            let dateVitals = resolvedVitalDates()
            let resolvedLifeDate = query.operation == .birth
                ? dateVitals.profileBirthdate : dateVitals.profileDeathdate
            let answer = ArchivistBiographyPolicy.lifeDate(
                personID: person.id,
                birth: query.operation == .birth,
                in: graph,
                dateTextOverride: resolvedLifeDate.map {
                    HallieDateStyle.spoken($0, calendar: HallieVitalDates.utcCalendar)
                },
                dateSourceName: resolvedLifeDate == nil ? nil : dateVitals.profileName)
            return ArchivistGraphExecutor.fromPolicy(
                answer,
                evidence: ArchivistGraphExecutor.lifeDateEvidence(
                    for: person, birth: query.operation == .birth,
                    identityBridge: identityBridge,
                    resolvedDateText: resolvedLifeDate.map {
                        HallieDateStyle.spoken($0, calendar: HallieVitalDates.utcCalendar)
                    }),
                identityBridge: identityBridge,
                unresolvedProfileRoute: nil,
                dateSourceName: resolvedLifeDate == nil ? nil : dateVitals.profileName)
        }

        private func kinship(_ query: ArchivistGraphQuery) -> ArchivistGraphResult {
            let graph = inputs.graph
            guard let relation = query.relation else {
                return ArchivistGraphExecutor.decline(
                    .missingRelation,
                    prose: "Which relationship do you mean — for example Rick's mother, or Donna's grandfather?",
                    basis: ArchivistGraphExecutor.queryValidationBasis)
            }
            if let graphRelation = relation.singleHop {
                if query.side != nil {
                    // "maternal father" has no meaning; refuse rather than
                    // silently drop the side.
                    return ArchivistGraphExecutor.declineUnexpectedRelation()
                }
                return ArchivistGraphExecutor.executeSingleHop(
                    graphRelation, person: person, graph: graph,
                    identityBridge: identityBridge)
            }
            guard let extended = relation.extended else {
                return ArchivistGraphExecutor.decline(
                    .missingRelation,
                    prose: "Which relationship do you mean — for example Rick's mother, or Donna's grandfather?",
                    basis: ArchivistGraphExecutor.queryValidationBasis)
            }
            return ArchivistGraphExecutor.executeExtended(
                extended, side: query.side?.graphSide, person: person,
                graph: graph, identityBridge: identityBridge)
        }
    }
}
