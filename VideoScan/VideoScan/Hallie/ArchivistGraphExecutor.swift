import Foundation

/// Pure executor for QueryAST's family-graph shape. The LLM supplies only the
/// validated AST; family evidence and factual prose never cross back through
/// the model. Multi-subject semantics are intentionally not invented: the
/// current wire format permits a list but does not define conjunction or
/// per-person output, so anything except one subject fails closed (the
/// `familyTree` surname / whole-tree forms are the one defined exception).
enum ArchivistGraphExecutor {
    static let queryValidationBasis =
        "Checked: graph-query validation only; no family source was consulted."

    static func execute(
        _ query: ArchivistGraphQuery,
        inputs: ArchivistGraphInputs
    ) -> ArchivistGraphResult {
        execute(query, inputs: inputs, subject: .unresolved)
    }

    static func execute(
        _ query: ArchivistGraphQuery,
        inputs: ArchivistGraphInputs,
        subject selection: ArchivistGraphSubjectSelection
    ) -> ArchivistGraphResult {
        if query.operation == .familyTree, query.people.isEmpty {
            guard query.relation == nil, query.side == nil else {
                return declineUnexpectedRelation()
            }
            return executeFamilyTreeWithoutPerson(query, graph: inputs.graph)
        }
        if query.operation == .relationship {
            // Two people; a single selection floats to whichever of them
            // turns out ambiguous (see executeRelationship).
            return executeRelationship(
                query, inputs: inputs, subjects: [.unresolved, .unresolved],
                floatingSelection: selection)
        }
        guard query.people.count == 1 else {
            // Honest, user-facing (live 2026-08-26: the old "must identify
            // exactly one person" guard sentence reached the chat).
            let names = query.people.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let prose = names.count >= 2
                ? "I wasn't sure which person you meant — " + names.joined(separator: " or ") + "? Ask about one of them and I'll look them up."
                : "Who would you like to know about? Give me one name and I'll look in the family tree."
            return decline(
                .unsupportedPeopleCount(query.people.count),
                prose: prose,
                basis: queryValidationBasis)
        }

        let typedName = query.people[0].trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !typedName.isEmpty else {
            return decline(
                .invalidPerson,
                prose: "Who would you like to know about? Give me a name and I'll look in the family tree.",
                basis: queryValidationBasis)
        }

        if query.operation == .kinship, query.relation == nil {
            return decline(
                .missingRelation,
                prose: "Which relationship do you mean — for example Rick's mother, or Donna's grandfather?",
                basis: queryValidationBasis)
        }
        if query.operation != .kinship, query.relation != nil || query.side != nil {
            return declineUnexpectedRelation()
        }

        // People-tab relationships first (2026-08-27): the contemporary
        // family is deliberately absent from the FamilySearch tree, so
        // "who is Rick's brother" is answered from the typed overlay when
        // it knows; otherwise the GEDCOM walk below proceeds unchanged.
        if query.operation == .kinship,
           let overlay = overlayKinshipResult(query, inputs: inputs, selection: selection) {
            return overlay
        }

        switch resolveSubject(typedName, selection: selection,
                              inputs: inputs, query: query) {
        case .result(let result):
            return result
        case .person(let person, let bridge, let correction, let profileStableID):
            let result = executeResolved(
                query, person: person, inputs: inputs,
                identityBridge: bridge, profileStableID: profileStableID)
            return applyingMarriedName(
                typed: typedName, person: person, graph: inputs.graph,
                to: applyingSpellingCorrection(
                    correction, canonicalName: person.name, to: result))
        }
    }

    /// "muriel lamb breen" / "muriel breen" found Muriel /Lamb/ through her
    /// husband's surname (FamilySearch records women under the maiden name
    /// only, live 2026-08-26). Say so: the prose names her "Muriel Lamb
    /// (Breen)" and the basis line says which marriage supplied the name.
    static func applyingMarriedName(
        typed: String,
        person: GedcomFamilyGraph.Person,
        graph: GedcomFamilyGraph,
        to result: ArchivistGraphResult
    ) -> ArchivistGraphResult {
        guard let tokens = GedcomFamilyGraph.namedLikeTokens(typed),
              let married = graph.marriedSurname(of: person, satisfying: tokens),
              let range = result.prose.range(of: person.name) else { return result }
        let shown = "\(person.name) (\(married))"
        let husbands = graph.relatives(.husband, of: person)
            .filter { ($0.surname.map(FamilyIdentityText.normalized) == married.lowercased())
                || $0.alternateSurnames.contains { FamilyIdentityText.normalized($0) == married.lowercased() } }
            .map(\.name)
        let note = "“\(typed)” is \(person.name) by her married name"
            + (husbands.isEmpty ? "." : " (married \(husbands.joined(separator: ", "))).")
        return ArchivistGraphResult(
            conclusion: result.conclusion,
            prose: result.prose.replacingCharacters(in: range, with: shown),
            basisLine: note + " " + result.basisLine,
            evidence: result.evidence,
            candidates: result.candidates,
            profileCandidates: result.profileCandidates,
            ambiguityCandidates: result.ambiguityCandidates,
            catalogPersonName: result.catalogPersonName,
            familyTreeFocus: result.familyTreeFocus,
            subjectIndex: result.subjectIndex,
            // The plan is deliberately NOT carried: its claims say the
            // maiden name, and the composer would follow the plan over
            // the prose. Deriving from the prose keeps "(Breen)" (as before).
            possibleDuplicate: result.possibleDuplicate)
    }

    static func declineUnexpectedRelation() -> ArchivistGraphResult {
        decline(
            .unexpectedRelation,
            prose: "Let me do that one person at a time — try \u{201C}show my paternal line back 5 generations\u{201D}, \u{201C}trace the family back to Ireland\u{201D}, or name the person you're curious about.",
            basis: queryValidationBasis)
    }

    static func decline(
        _ conclusion: ArchivistGraphConclusion,
        prose: String,
        basis: String
    ) -> ArchivistGraphResult {
        ArchivistGraphResult(
            conclusion: conclusion,
            prose: prose,
            basisLine: basis,
            evidence: nil,
            candidates: [],
            profileCandidates: [],
            ambiguityCandidates: [],
            catalogPersonName: nil)
    }

    static func applyingSpellingCorrection(
        _ correction: String?,
        canonicalName: String,
        to result: ArchivistGraphResult
    ) -> ArchivistGraphResult {
        guard let correction else { return result }
        return ArchivistGraphResult(
            conclusion: result.conclusion,
            prose: "I took that spelling to mean \(canonicalName). "
                + result.prose,
            basisLine: "Spelling recovery: uniquely matched “\(correction)” "
                + "to GEDCOM “\(canonicalName)”. " + result.basisLine,
            evidence: result.evidence,
            candidates: result.candidates,
            profileCandidates: result.profileCandidates,
            ambiguityCandidates: result.ambiguityCandidates,
            catalogPersonName: result.catalogPersonName,
            familyTreeFocus: result.familyTreeFocus,
            subjectIndex: result.subjectIndex,
            // The plan is deliberately NOT carried (as before): the
            // "I took that spelling to mean …" sentence lives in the prose
            // only, and the composer follows a plan over the prose.
            possibleDuplicate: result.possibleDuplicate)
    }

}
