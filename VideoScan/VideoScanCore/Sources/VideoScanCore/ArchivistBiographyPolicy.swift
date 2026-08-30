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

        // Vitals, in Rick's order (2026-08-30): dates AND places. Places
        // were parsed, stored and used for disambiguation, but never
        // reached a stated fact — so "where was Martha Lamson born?"
        // could not be answered even though the GEDCOM carries 44,469
        // PLAC lines. Donna hit this on the web client.
        var facts: [String] = []
        switch (person.birthDate, cleanPlace(person.birthPlace)) {
        case (let date?, let place?): facts.append("born \(date) in \(place)")
        case (let date?, nil):        facts.append("born \(date)")
        case (nil, let place?):       facts.append("born in \(place)")
        case (nil, nil):              break
        }
        switch (person.deathDate, cleanPlace(person.deathPlace)) {
        case (let date?, let place?):
            facts.append("resting in peace since \(date), in \(place)")
        case (let date?, nil):
            facts.append("resting in peace since \(date)")
        case (nil, let place?):
            facts.append("died in \(place)")
        case (nil, nil):
            break
        }
        let parents = orderedPeople(
            graph.relatives(.parents, of: person)).map(\.name)
        if !parents.isEmpty {
            facts.append("child of \(parents.joined(separator: " and "))")
        }
        // Spouses WITH their marriage dates folded in. An earlier revision
        // of this change appended dates as separate facts, which named the
        // spouse twice — "married to Patrick Breen; ...; married Patrick
        // Breen 1885". The parenthetical matches the shape
        // HallieBiographyCard.marriageClause already uses.
        let spouseOrder = orderedPeople(graph.relatives(.spouse, of: person))
        var dateBySpouseID: [String: String] = [:]
        for marriage in graph.marriages(of: person) {
            if let id = marriage.spouse?.id, let date = marriage.date {
                dateBySpouseID[id] = date
            }
        }
        let spouses = spouseOrder.map { spouse -> String in
            guard let date = dateBySpouseID[spouse.id] else { return spouse.name }
            return "\(spouse.name) (married \(date))"
        }
        if !spouses.isEmpty {
            facts.append("married to \(spouses.joined(separator: ", "))")
        }
        let children = orderedPeople(
            graph.relatives(.children, of: person)).map(\.name)
        if !children.isEmpty {
            facts.append("parent of \(children.joined(separator: ", "))")
        }
        // A marriage the tree records with a date but NO spouse still says
        // something worth keeping; those cannot ride along above.
        let spouselessMarriages = graph.marriages(of: person).compactMap { marriage -> String? in
            guard marriage.spouse == nil, let date = marriage.date else { return nil }
            return "married \(date)"
        }
        facts.append(contentsOf: spouselessMarriages)

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

    /// "Where was X born / die?" — the sibling of `lifeDate`. Added
    /// 2026-08-30: the parser had no `where` pattern at all, so the
    /// question fell through before reaching any answer.
    public static func lifePlace(for typedName: String, birth: Bool,
                                 candidates: [GedcomFamilyGraph.Person],
                                 in graph: GedcomFamilyGraph)
        -> ArchivistBiographyAnswer {
        guard candidates.count == 1, let person = candidates.first else {
            return unresolved(typedName: typedName, candidates: candidates)
        }
        return lifePlace(for: person, birth: birth)
    }

    public static func lifePlace(personID: String, birth: Bool,
                                 in graph: GedcomFamilyGraph)
        -> ArchivistBiographyAnswer {
        guard let person = graph.people[personID] else {
            return ArchivistBiographyAnswer(
                state: .notFound,
                text: "That family-tree person is no longer available.",
                basis: gedcomBasis,
                catalogPersonName: nil)
        }
        return lifePlace(for: person, birth: birth)
    }

    private static func lifePlace(for person: GedcomFamilyGraph.Person,
                                  birth: Bool) -> ArchivistBiographyAnswer {
        let place = cleanPlace(birth ? person.birthPlace : person.deathPlace)
        guard let place else {
            return ArchivistBiographyAnswer(
                state: .missingFact,
                text: "The family tree doesn't record "
                    + (birth ? "a birthplace" : "a place of death")
                    + " for \(person.name).",
                basis: gedcomBasis,
                catalogPersonName: person.name)
        }
        // The date is included when the record has it: someone asking where
        // almost always wants when as well, and it costs nothing.
        let date = birth ? person.birthDate : person.deathDate
        let text: String
        if birth {
            text = date.map { "\(person.name) was born in \(place), \($0)." }
                ?? "\(person.name) was born in \(place)."
        } else {
            text = date.map { "\(person.name) died in \(place), \($0)." }
                ?? "\(person.name) died in \(place)."
        }
        return ArchivistBiographyAnswer(state: .answered, text: text,
                                        basis: gedcomBasis,
                                        catalogPersonName: person.name)
    }

    /// A place worth saying out loud.
    ///
    /// The real export carries placeholder junk — "xx" appears literally,
    /// alongside honest values from "England" to "Yorkshire, England". We
    /// deliberately do NOT normalise or geocode: Hallie says what the
    /// record says. This only suppresses values that are not places at
    /// all, so she says "doesn't record a birthplace" rather than
    /// "was born in xx".
    public static func cleanPlace(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        let placeholders: Set<String> = ["xx", "x", "?", "??", "n/a", "na",
                                         "unknown", "unk", "-", "--"]
        if placeholders.contains(trimmed.lowercased()) { return nil }
        return trimmed
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
