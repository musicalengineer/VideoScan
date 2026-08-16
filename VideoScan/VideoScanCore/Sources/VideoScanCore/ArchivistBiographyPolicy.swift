import Foundation

/// A deterministic, provenance-carrying answer from the Family Archivist.
///
/// The language model is deliberately absent from this type. Family facts
/// are composed only from the imported GEDCOM graph, and every outcome —
/// including ambiguity and missing evidence — states what source was used.
public struct ArchivistBiographyAnswer: Sendable, Equatable {
    public struct Candidate: Sendable, Equatable {
        public let id: String
        public let name: String
        public let label: String

        public init(id: String, name: String, label: String) {
            self.id = id
            self.name = name
            self.label = label
        }
    }

    public enum State: Sendable, Equatable {
        case answered
        case ambiguous
        case notFound
        case missingFact
    }

    public let state: State
    public let text: String
    public let basis: String
    public let candidates: [Candidate]
    /// Canonical identity suitable for an optional catalog-search action.
    public let catalogPersonName: String?

    public init(state: State, text: String, basis: String,
                candidates: [Candidate] = [], catalogPersonName: String? = nil) {
        self.state = state
        self.text = text
        self.basis = basis
        self.candidates = candidates
        self.catalogPersonName = catalogPersonName
    }
}

public enum ArchivistBiographyPolicy {
    public static let gedcomBasis = "Basis: imported family tree (GEDCOM)."
    public static let gedcomCheck = "Checked: imported family tree (GEDCOM)."

    /// Stable family-fact order, independent of equivalent GEDCOM record
    /// ordering: normalized display name first, then the GEDCOM pointer.
    /// Evidence composers call this same function so prose and citations
    /// cannot silently disagree about ordering.
    public static func orderedPeople(
        _ people: [GedcomFamilyGraph.Person]
    ) -> [GedcomFamilyGraph.Person] {
        people.sorted { lhs, rhs in
            let left = FamilyIdentityText.normalized(lhs.name)
            let right = FamilyIdentityText.normalized(rhs.name)
            if left != right { return left < right }
            return lhs.id < rhs.id
        }
    }

    public static func disambiguationCandidate(
        for person: GedcomFamilyGraph.Person
    ) -> ArchivistBiographyAnswer.Candidate {
        var details: [String] = []
        if let birth = person.birthDate { details.append("b. \(birth)") }
        if let death = person.deathDate { details.append("d. \(death)") }
        let label = details.isEmpty
            ? "\(person.name) (\(person.id))"
            : "\(person.name) (\(details.joined(separator: ", ")))"
        return ArchivistBiographyAnswer.Candidate(
            id: person.id, name: person.name, label: label)
    }

    public static func biography(for typedName: String,
                                 in graph: GedcomFamilyGraph)
        -> ArchivistBiographyAnswer {
        biography(for: typedName,
                  candidates: graph.people(matching: typedName),
                  in: graph)
    }

    public static func biography(
        for typedName: String,
        candidates: [GedcomFamilyGraph.Person],
        in graph: GedcomFamilyGraph
    ) -> ArchivistBiographyAnswer {
        guard candidates.count == 1 else {
            return unresolved(typedName: typedName, candidates: candidates)
        }

        return biography(for: candidates[0], in: graph)
    }

    /// Stable-ID entry point used after an ambiguity chip is selected.
    /// Repeating display names cannot safely be resolved by asking the same
    /// name again, so the UI carries the GEDCOM pointer selected by the user.
    public static func biography(personID: String,
                                 in graph: GedcomFamilyGraph)
        -> ArchivistBiographyAnswer {
        guard let person = graph.people[personID] else {
            return ArchivistBiographyAnswer(
                state: .notFound,
                text: "That family-tree person is no longer available.",
                basis: gedcomCheck)
        }
        return biography(for: person, in: graph)
    }

    private static func biography(for person: GedcomFamilyGraph.Person,
                                  in graph: GedcomFamilyGraph)
        -> ArchivistBiographyAnswer {

        var facts: [String] = []
        if let born = person.birthDate { facts.append("born \(born)") }
        if let died = person.deathDate {
            facts.append("resting in peace since \(died)")
        }
        let parents = orderedPeople(
            graph.relatives(.parents, of: person)).map(\.name)
        if !parents.isEmpty {
            facts.append("child of \(parents.joined(separator: " and "))")
        }
        let spouses = orderedPeople(
            graph.relatives(.spouse, of: person)).map(\.name)
        if !spouses.isEmpty {
            facts.append("married to \(spouses.joined(separator: ", "))")
        }
        let children = orderedPeople(
            graph.relatives(.children, of: person)).map(\.name)
        if !children.isEmpty {
            facts.append("parent of \(children.joined(separator: ", "))")
        }

        let hasDetails = !facts.isEmpty
        let text = hasDetails
            ? "\(person.name) — \(facts.joined(separator: "; "))."
            : "\(person.name) is in the family tree, but it records no further details."
        return ArchivistBiographyAnswer(
            state: hasDetails ? .answered : .missingFact,
            text: text,
            basis: gedcomBasis,
            catalogPersonName: person.name)
    }

    public static func lifeDate(for typedName: String, birth: Bool,
                                in graph: GedcomFamilyGraph)
        -> ArchivistBiographyAnswer {
        lifeDate(for: typedName, birth: birth,
                 candidates: graph.people(matching: typedName),
                 in: graph)
    }

    public static func lifeDate(
        for typedName: String,
        birth: Bool,
        candidates: [GedcomFamilyGraph.Person],
        in graph: GedcomFamilyGraph
    ) -> ArchivistBiographyAnswer {
        guard candidates.count == 1 else {
            return unresolved(typedName: typedName, candidates: candidates)
        }

        return lifeDate(for: candidates[0], birth: birth)
    }

    public static func lifeDate(personID: String, birth: Bool,
                                in graph: GedcomFamilyGraph)
        -> ArchivistBiographyAnswer {
        guard let person = graph.people[personID] else {
            return ArchivistBiographyAnswer(
                state: .notFound,
                text: "That family-tree person is no longer available.",
                basis: gedcomCheck)
        }
        return lifeDate(for: person, birth: birth)
    }

    private static func lifeDate(for person: GedcomFamilyGraph.Person,
                                 birth: Bool) -> ArchivistBiographyAnswer {

        let date = birth ? person.birthDate : person.deathDate
        guard let date else {
            return ArchivistBiographyAnswer(
                state: .missingFact,
                text: "The family tree doesn't record "
                    + (birth ? "a birth date" : "a death date")
                    + " for \(person.name).",
                basis: gedcomBasis,
                catalogPersonName: person.name)
        }

        let text: String
        if birth {
            text = "\(person.name) was born \(date)."
        } else {
            let pronoun = person.sex == "M" ? "he"
                : person.sex == "F" ? "she" : "they"
            let has = pronoun == "they" ? "have" : "has"
            text = "\(person.name) is no longer with us — \(pronoun) \(has) "
                + "been resting in peace since \(date)."
        }
        return ArchivistBiographyAnswer(
            state: .answered,
            text: text,
            basis: gedcomBasis,
            catalogPersonName: person.name)
    }

    private static func unresolved(typedName: String,
                                   candidates: [GedcomFamilyGraph.Person])
        -> ArchivistBiographyAnswer {
        if candidates.isEmpty {
            return ArchivistBiographyAnswer(
                state: .notFound,
                text: "I don't find “\(typedName)” in the family tree — try a fuller name.",
                basis: gedcomCheck)
        }
        return ArchivistBiographyAnswer(
            state: .ambiguous,
            text: "Which \(typedName) do you mean?",
            basis: gedcomCheck,
            candidates: candidates.map(disambiguationCandidate))
    }
}
