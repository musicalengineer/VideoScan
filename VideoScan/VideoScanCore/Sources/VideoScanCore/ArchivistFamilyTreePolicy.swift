// ArchivistFamilyTreePolicy.swift (VideoScanCore)
// Deterministic "show X's family tree" summaries over the GEDCOM graph.
// The chat answer is a paragraph; the app can additionally offer to open
// the Family Tree tab focused on the person (or filtered to the surname).
// Everything here is knowledge-in-data — no model, no prose invention.

import Foundation

public enum ArchivistFamilyTreePolicy {

    /// Bounded structured view of one person's neighbourhood in the tree.
    public struct PersonSummary: Sendable, Equatable {
        public let subject: GedcomFamilyGraph.Person
        public let parents: [GedcomFamilyGraph.Person]
        public let grandparents: [GedcomFamilyGraph.Person]
        public let spouses: [GedcomFamilyGraph.Person]
        public let children: [GedcomFamilyGraph.Person]
        public let siblings: [GedcomFamilyGraph.Person]
        /// Distinct ancestors reachable through parent links, and how many
        /// generations up the deepest recorded chain goes.
        public let ancestorCount: Int
        public let ancestorGenerations: Int
        public let descendantCount: Int
        public let descendantGenerations: Int
    }

    public struct SurnameSummary: Sendable, Equatable {
        public let surname: String
        public let people: [GedcomFamilyGraph.Person]
        public let earliestBorn: GedcomFamilyGraph.Person?
        public let latestBorn: GedcomFamilyGraph.Person?
        public let generations: Int
    }

    /// Hard ceiling on the breadth-first walks. A malformed GEDCOM with a
    /// parent cycle must terminate; family trees this app reads are a few
    /// hundred people, so 10k is comfortably "everything".
    static let traversalLimit = 10_000

    // MARK: Person

    public static func summary(
        personID: String,
        in graph: GedcomFamilyGraph
    ) -> ArchivistBiographyAnswer {
        guard let person = graph.people[personID] else {
            return ArchivistBiographyAnswer(
                state: .notFound,
                text: "That family-tree person is no longer available.",
                basis: ArchivistBiographyPolicy.gedcomCheck)
        }
        return answer(for: summary(of: person, in: graph))
    }

    public static func summary(
        of person: GedcomFamilyGraph.Person,
        in graph: GedcomFamilyGraph
    ) -> PersonSummary {
        let parents = ArchivistBiographyPolicy.orderedPeople(
            graph.relatives(.parents, of: person))
        let grandparents = ArchivistBiographyPolicy.orderedPeople(
            parents.flatMap { graph.relatives(.parents, of: $0) })
        let (ancestors, upDepth) = walk(from: person, in: graph, relation: .parents)
        let (descendants, downDepth) = walk(from: person, in: graph, relation: .children)
        return PersonSummary(
            subject: person,
            parents: parents,
            grandparents: grandparents,
            spouses: ArchivistBiographyPolicy.orderedPeople(
                graph.relatives(.spouse, of: person)),
            children: ArchivistBiographyPolicy.orderedPeople(
                graph.relatives(.children, of: person)),
            siblings: ArchivistBiographyPolicy.orderedPeople(
                graph.relatives(.siblings, of: person)),
            ancestorCount: ancestors,
            ancestorGenerations: upDepth,
            descendantCount: descendants,
            descendantGenerations: downDepth)
    }

    public static func answer(for summary: PersonSummary) -> ArchivistBiographyAnswer {
        var facts: [String] = []
        func names(_ people: [GedcomFamilyGraph.Person]) -> String {
            people.map(\.name).joined(separator: ", ")
        }
        if !summary.parents.isEmpty {
            facts.append("parents: " + summary.parents.map(\.name)
                .joined(separator: " and "))
        }
        if !summary.grandparents.isEmpty {
            facts.append("grandparents: " + names(summary.grandparents))
        }
        if !summary.spouses.isEmpty {
            facts.append("married to " + names(summary.spouses))
        }
        if !summary.children.isEmpty {
            let noun = summary.children.count == 1 ? "child" : "children"
            facts.append("\(summary.children.count) \(noun): " + names(summary.children))
        }
        if !summary.siblings.isEmpty {
            let noun = summary.siblings.count == 1 ? "sibling" : "siblings"
            facts.append("\(summary.siblings.count) \(noun): " + names(summary.siblings))
        }
        var counts: [String] = []
        if summary.ancestorCount > 0 {
            counts.append("\(summary.ancestorCount) recorded ancestor"
                + (summary.ancestorCount == 1 ? "" : "s")
                + " across \(summary.ancestorGenerations) generation"
                + (summary.ancestorGenerations == 1 ? "" : "s"))
        }
        if summary.descendantCount > 0 {
            counts.append("\(summary.descendantCount) recorded descendant"
                + (summary.descendantCount == 1 ? "" : "s")
                + " across \(summary.descendantGenerations) generation"
                + (summary.descendantGenerations == 1 ? "" : "s"))
        }
        if !counts.isEmpty { facts.append(counts.joined(separator: " and ")) }

        let name = summary.subject.name
        guard !facts.isEmpty else {
            return ArchivistBiographyAnswer(
                state: .missingFact,
                text: "\(name) is in the family tree, but it records no parents, spouse, children, or siblings for them.",
                basis: ArchivistBiographyPolicy.gedcomBasis,
                catalogPersonName: name)
        }
        return ArchivistBiographyAnswer(
            state: .answered,
            text: "\(name)'s family tree — " + facts.joined(separator: "; ") + ".",
            basis: ArchivistBiographyPolicy.gedcomBasis,
            catalogPersonName: name)
    }

    // MARK: Surname

    public static func summary(
        surname typed: String,
        in graph: GedcomFamilyGraph
    ) -> SurnameSummary? {
        let people = graph.people(withSurname: typed)
        guard !people.isEmpty else { return nil }
        let dated = people.filter { $0.birthYear != nil }
            .sorted { ($0.birthYear ?? 0, $0.id) < ($1.birthYear ?? 0, $1.id) }
        let display = people.first?.surname ?? typed
        return SurnameSummary(
            surname: display,
            people: people,
            earliestBorn: dated.first,
            latestBorn: dated.last,
            generations: generationCount(of: people, in: graph))
    }

    public static func answer(for summary: SurnameSummary) -> ArchivistBiographyAnswer {
        let count = summary.people.count
        var text = "The family tree records \(count) "
            + (count == 1 ? "person" : "people")
            + " with the surname \(summary.surname)"
        var details: [String] = []
        if summary.generations > 1 {
            details.append("spanning \(summary.generations) generations")
        }
        if let earliest = summary.earliestBorn, let year = earliest.birthYear {
            details.append("earliest born \(year) (\(earliest.name))")
        }
        if let latest = summary.latestBorn, let year = latest.birthYear,
           latest.id != summary.earliestBorn?.id {
            details.append("latest born \(year) (\(latest.name))")
        }
        if !details.isEmpty {
            text += " — " + details.joined(separator: "; ")
        }
        text += "."
        if count <= 12 {
            text += " They are: " + summary.people.map(\.name)
                .joined(separator: ", ") + "."
        }
        return ArchivistBiographyAnswer(
            state: .answered,
            text: text,
            basis: ArchivistBiographyPolicy.gedcomBasis)
    }

    // MARK: Whole tree

    /// "show family tree" with nobody named: an honest overview plus the
    /// offer to open the tab. Never picks a person for the user.
    public static func overview(in graph: GedcomFamilyGraph) -> ArchivistBiographyAnswer {
        let people = graph.people.values
        let count = people.count
        guard count > 0 else {
            return ArchivistBiographyAnswer(
                state: .missingFact,
                text: "The imported family tree has no people in it.",
                basis: ArchivistBiographyPolicy.gedcomBasis)
        }
        var surnameCounts: [String: Int] = [:]
        for person in people {
            guard let surname = person.surname, !surname.isEmpty else { continue }
            surnameCounts[surname, default: 0] += 1
        }
        let topSurnames = surnameCounts.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }.prefix(5).map { "\($0.key) (\($0.value))" }
        let years = people.compactMap(\.birthYear)
        var text = "The family tree records \(count) "
            + (count == 1 ? "person" : "people")
        if let earliest = years.min(), let latest = years.max() {
            text += ", with birth years from \(earliest) to \(latest)"
        }
        if !topSurnames.isEmpty {
            text += "; most common surnames: " + topSurnames.joined(separator: ", ")
        }
        text += ". Tell me whose tree you want (\"show Donna's family tree\") or a surname (\"the Breens\")."
        return ArchivistBiographyAnswer(
            state: .answered,
            text: text,
            basis: ArchivistBiographyPolicy.gedcomBasis)
    }

    // MARK: Walks

    /// Distinct people reachable by repeatedly following `relation`, and the
    /// depth of the longest chain. Bounded and cycle-safe.
    private static func walk(
        from start: GedcomFamilyGraph.Person,
        in graph: GedcomFamilyGraph,
        relation: GedcomFamilyGraph.Relation
    ) -> (count: Int, depth: Int) {
        var seen: Set<String> = [start.id]
        var frontier = [start]
        var depth = 0
        while !frontier.isEmpty, seen.count < traversalLimit {
            var next: [GedcomFamilyGraph.Person] = []
            for person in frontier {
                for related in graph.relatives(relation, of: person)
                where seen.insert(related.id).inserted {
                    next.append(related)
                }
            }
            if next.isEmpty { break }
            depth += 1
            frontier = next
        }
        return (seen.count - 1, depth)
    }

    /// Number of distinct generation layers among `people` (parent links
    /// within the set only). A single unlinked person is one generation.
    private static func generationCount(
        of people: [GedcomFamilyGraph.Person],
        in graph: GedcomFamilyGraph
    ) -> Int {
        let ids = Set(people.map(\.id))
        var memo: [String: Int] = [:]
        var visiting: Set<String> = []
        func depth(_ person: GedcomFamilyGraph.Person) -> Int {
            if let known = memo[person.id] { return known }
            guard visiting.insert(person.id).inserted else { return 1 }
            defer { visiting.remove(person.id) }
            let parentDepth = graph.relatives(.parents, of: person)
                .filter { ids.contains($0.id) }
                .map(depth)
                .max() ?? 0
            memo[person.id] = parentDepth + 1
            return parentDepth + 1
        }
        return people.map(depth).max() ?? 0
    }
}
