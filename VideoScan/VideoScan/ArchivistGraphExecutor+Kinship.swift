// ArchivistGraphExecutor+Kinship.swift
// Kinship (one-hop and multi-hop) and family-tree roll-up answers for the
// graph executor. Split from ArchivistGraphExecutor.swift for file length.

import Foundation

extension ArchivistGraphExecutor {

    static func executeSingleHop(
        _ graphRelation: GedcomFamilyGraph.Relation,
        person: GedcomFamilyGraph.Person,
        graph: GedcomFamilyGraph,
        identityBridge: ArchivistGraphEvidence.IdentityBridge?
    ) -> ArchivistGraphResult {
        let relatives = graph.relatives(graphRelation, of: person)
            .sorted(by: personOrder)
        let evidence = kinshipEvidence(
            for: person, relation: graphRelation, relatives: relatives,
            identityBridge: identityBridge)
        guard !relatives.isEmpty else {
            let relation = graphRelation.rawValue
            let quantifier = ["parents", "siblings", "children"].contains(relation)
                ? "any" : "a"
            return ArchivistGraphResult(
                conclusion: .missingFact,
                prose: "The family tree doesn't record \(quantifier) \(relation) for \(person.name). "
                    + "You can try another relationship or ask for the family tree.",
                basisLine: factualBasis(identityBridge),
                evidence: evidence,
                candidates: [],
                profileCandidates: [],
                ambiguityCandidates: [],
                catalogPersonName: nil)
        }
        let prose = "\(person.name)'s \(graphRelation.rawValue): "
            + relatives.map(\.name).joined(separator: ", ") + "."
        let plan = HallieAnswerPlan(
            route: .graph, shape: .fact,
            claims: [.init(
                id: "c1", text: prose,
                evidenceIDs: [person.id] + relatives.map(\.id),
                requiredPersonNames: relatives.map(\.name),
                requiresCoverage: true)],
            fallbackText: prose)
        // A parent question names the PRIMARY family's parent only (Rick,
        // 2026-09-02); a second recorded parent family is said in the
        // basis, in the graph's one short note.
        let parentNote: String
        switch graphRelation {
        case .father, .mother, .parents:
            parentNote = graph.parentFamilyBasisNote(for: person).map { " " + $0 } ?? ""
        default:
            parentNote = ""
        }
        return ArchivistGraphResult(
            conclusion: .answered,
            prose: prose,
            basisLine: factualBasis(identityBridge) + parentNote,
            evidence: evidence,
            candidates: [],
            profileCandidates: [],
            ambiguityCandidates: [],
            catalogPersonName: nil,
            answerPlan: plan)
    }

    /// Multi-hop kinship: the answer names every relative reached AND the
    /// route ("Donna → mother Elaine → her mother Ann"), so a wrong link in
    /// the tree is visible rather than laundered into a bare name. A missing
    /// hop is reported at the exact place the tree stops.
    static func executeExtended(
        _ relation: GedcomFamilyGraph.ExtendedRelation,
        side: GedcomFamilyGraph.KinshipSide?,
        person: GedcomFamilyGraph.Person,
        graph: GedcomFamilyGraph,
        identityBridge: ArchivistGraphEvidence.IdentityBridge?
    ) -> ArchivistGraphResult {
        let sideWord = side.map { "\($0.rawValue) " } ?? ""
        let relationWord = sideWord + relation.rawValue
        switch graph.relatives(relation, side: side, of: person) {
        case .found(let paths):
            let noun = paths.count == 1
                ? relationWord
                : pluralize(relationWord)
            let lines = paths.map { path in
                "\(path.relative.name) (\(path.describe(from: person)))"
            }
            let evidence = ArchivistGraphEvidence(
                subjectID: person.id,
                subjectName: person.name,
                birthDate: nil,
                deathDate: nil,
                relationships: [],
                identityBridge: identityBridge,
                kinshipPaths: paths.map { path in
                    .init(hops: path.hops.map {
                        .init(label: $0.label,
                              person: .init(id: $0.person.id, name: $0.person.name))
                    })
                })
            let prose = "\(person.name)'s \(noun): "
                + lines.joined(separator: "; ") + "."
            // Only the requested endpoints are answer obligations. The
            // intermediate hops support each route but are not blindly
            // promoted from evidence into required prose.
            let required = paths.map(\.relative.name)
            let plan = HallieAnswerPlan(
                route: .graph, shape: .fact,
                claims: [.init(
                    id: "c1", text: prose,
                    evidenceIDs: [person.id] + paths.flatMap { $0.hops.map(\.person.id) },
                    requiredPersonNames: required,
                    requiresCoverage: true)],
                fallbackText: prose)
            return ArchivistGraphResult(
                conclusion: .answered,
                prose: prose,
                basisLine: factualBasis(identityBridge),
                evidence: evidence,
                candidates: [],
                profileCandidates: [],
                ambiguityCandidates: [],
                catalogPersonName: nil,
                answerPlan: plan)

        case .missingHop(let reached, let missing):
            let prose: String
            if reached.isEmpty {
                prose = "The family tree doesn't record \(missing) for "
                    + "\(person.name), so I can't reach a \(relationWord)."
            } else {
                let recorded = reached.map { "\($0.label) (\($0.person.name))" }
                    .joined(separator: " → ")
                prose = "The family tree records \(person.name)'s \(recorded), "
                    + "but not \(missing) — so I can't name a \(relationWord)."
            }
            let evidence = ArchivistGraphEvidence(
                subjectID: person.id,
                subjectName: person.name,
                birthDate: nil,
                deathDate: nil,
                relationships: [],
                identityBridge: identityBridge,
                kinshipPaths: reached.isEmpty ? [] : [
                    .init(hops: reached.map {
                        .init(label: $0.label,
                              person: .init(id: $0.person.id, name: $0.person.name))
                    }),
                ])
            return ArchivistGraphResult(
                conclusion: .missingFact,
                prose: prose,
                basisLine: factualBasis(identityBridge),
                evidence: evidence,
                candidates: [],
                profileCandidates: [],
                ambiguityCandidates: [],
                catalogPersonName: nil)
        }
    }

    static func pluralize(_ word: String) -> String {
        if word.hasSuffix("s") { return word }
        if word.hasSuffix("-in-law") {
            return word.replacingOccurrences(of: "-in-law", with: "s-in-law")
        }
        return word + "s"
    }

    /// `familyTree` with no person: a surname roll-up ("the Breens") or an
    /// honest whole-tree overview. Never picks a person on the user's behalf.
    static func executeFamilyTreeWithoutPerson(
        _ query: ArchivistGraphQuery,
        graph: GedcomFamilyGraph
    ) -> ArchivistGraphResult {
        if let surname = query.surname?.trimmingCharacters(in: .whitespacesAndNewlines),
           !surname.isEmpty {
            guard let summary = ArchivistFamilyTreePolicy.summary(
                surname: surname, in: graph) else {
                return ArchivistGraphResult(
                    conclusion: .personNotFound,
                    prose: "I don't find anyone with the surname “\(surname)” in the family tree.",
                    basisLine: ArchivistBiographyPolicy.gedcomCheck,
                    evidence: nil,
                    candidates: [],
                    profileCandidates: [],
                    ambiguityCandidates: [],
                    catalogPersonName: nil)
            }
            return familyTreeSurnameResult(summary)
        }
        let answer = ArchivistFamilyTreePolicy.overview(in: graph)
        return ArchivistGraphResult(
            conclusion: answer.state == .answered ? .answered : .missingFact,
            prose: answer.text,
            basisLine: answer.basis,
            evidence: nil,
            candidates: [],
            profileCandidates: [],
            ambiguityCandidates: [],
            catalogPersonName: nil,
            familyTreeFocus: nil)
    }

    static func familyTreeSurnameResult(
        _ summary: ArchivistFamilyTreePolicy.SurnameSummary
    ) -> ArchivistGraphResult {
        let answer = ArchivistFamilyTreePolicy.answer(for: summary)
        return ArchivistGraphResult(
            conclusion: .answered,
            prose: answer.text,
            basisLine: answer.basis,
            evidence: nil,
            candidates: [],
            profileCandidates: [],
            ambiguityCandidates: [],
            catalogPersonName: nil,
            familyTreeFocus: .surname(summary.surname))
    }
}
