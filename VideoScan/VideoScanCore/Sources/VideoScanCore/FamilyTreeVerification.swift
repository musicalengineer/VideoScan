// FamilyTreeVerification.swift
// "Verify Tree" (Rick, 2026-08-30): one pass over the tree that finds the
// obviously weird, badges a count, and lets the reader work through it case
// by case.
//
// WHY IT EXISTS. Rick's tree renders his grandmother twice — Mary O'Connor
// (GNZ5-428) and Mary Catherine O'Connor (G89Q-34N) are one woman, created
// by two strangers on FamilySearch a year apart, and his mother Eileen
// Latta appears under each copy. Nothing in this app looked for that:
// every "duplicate" facility here is about MEDIA FILES matched by MD5.
//
// PRECISION OVER RECALL, deliberately. In a Boston tree of this era "Mary
// O'Connor" is as common as "Mary Smith", so anything matching on names
// alone produces a page of false pairs and the reader stops looking. Every
// rule below leans on relationships or exact dates. A short list that is
// right beats a long list that is ignored.
//
// NOTHING HERE DECIDES. The analyser reports; the human resolves. One of
// Rick's candidate pairs is an unattached "Mary Latta" recorded as an
// electronic engineer — either a remarkable fact about his grandmother or
// a different woman entirely, and no rule should guess which.
//
// COST. Naive pairwise duplicate detection over 16,383 people is 268M
// comparisons. Both duplicate rules bucket first and compare only within a
// bucket, so the pass is O(people + relationships), not O(people²).

import Foundation

public enum FamilyTreeVerification {

    public enum Severity: String, Sendable, Comparable, Codable {
        /// The data contradicts itself. Someone died before they were born.
        case error
        /// A human has to look. Most duplicates land here.
        case review
        /// Worth knowing, not necessarily wrong.
        case info

        private var rank: Int {
            switch self { case .error: 0; case .review: 1; case .info: 2 }
        }
        public static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
    }

    public enum Kind: String, Sendable, Codable {
        case duplicatePerson
        case deathBeforeBirth
        case implausibleLifespan
        case parentTooYoung
        case ancestorCycle
        case unattachedPerson
        case placeholderValue
    }

    public struct Finding: Sendable, Identifiable, Codable, Equatable {
        public let kind: Kind
        public let severity: Severity
        /// Everyone involved. Two ids for a duplicate pair, one otherwise.
        public let personIDs: [String]
        public let personNames: [String]
        /// FamilySearch ids where the record has them — a duplicate is
        /// usually resolved on familysearch.org, so the report has to carry
        /// the way in.
        public let familySearchIDs: [String]
        /// The most recent year we know about among the people involved
        /// (birth or death), nil when nothing is dated. The review queue
        /// filters on it — Rick, 2026-08-31: "anything before 1800 has
        /// little chance of being fixed by me ... after 1800 or 1900,
        /// these are ones I might be able to focus on."
        ///
        /// LATEST, not earliest, and deliberately nil-tolerant. A pair
        /// spanning an 1780 parent and an 1810 child is an 1810 problem,
        /// and an undated finding is not a proof of age. A filter here
        /// may only hide what it KNOWS is out of range.
        public let year: Int?
        /// Why this was flagged, in the reader's language.
        public let detail: String

        /// Stable across runs so a "reviewed, leave it alone" decision can
        /// be keyed to it: the kind plus the people, sorted.
        public var id: String { kind.rawValue + "|" + personIDs.sorted().joined(separator: "+") }
    }

    public struct Report: Sendable {
        public let findings: [Finding]
        public let peopleChecked: Int
        public var needingReview: Int { findings.filter { $0.severity <= .review }.count }
        public func of(_ kind: Kind) -> [Finding] { findings.filter { $0.kind == kind } }
    }

    /// The oldest verified human lived 122 years. 115 is comfortably past
    /// anything real in a family tree while still catching a transposed
    /// digit.
    public static let implausibleAgeYears = 115
    /// Youngest plausible parent. Deliberately generous — the aim is to
    /// catch a wrong date, not to police history.
    public static let youngestPlausibleParentYears = 12

    private static let placeholders: Set<String> =
        ["xx", "x", "?", "??", "n/a", "na", "unknown", "unk", "-", "--", "none", "living"]

    // MARK: - The pass

    public static func verify(_ graph: GedcomFamilyGraph) -> Report {
        var findings: [Finding] = []
        let people = Array(graph.people.values)

        findings += dateContradictions(people)
        findings += placeholderValues(people)
        findings += unattached(people, in: graph)
        findings += parentAgeProblems(people, in: graph)
        findings += duplicatesByIdenticalVitals(people)
        findings += duplicatesBySharedParents(people, in: graph)
        findings += ancestorCycles(people, in: graph)

        // Errors first, then review, then info; stable by id inside a band
        // so the queue does not reshuffle between runs.
        findings.sort {
            $0.severity == $1.severity ? $0.id < $1.id : $0.severity < $1.severity
        }
        return Report(findings: findings, peopleChecked: people.count)
    }

    // MARK: - Rules

    private static func dateContradictions(_ people: [GedcomFamilyGraph.Person]) -> [Finding] {
        people.compactMap { person in
            guard let birth = person.birthYear, let death = person.deathYear else { return nil }
            if death < birth {
                return finding(.deathBeforeBirth, .error, [person],
                               "Died \(death), born \(birth) — the death year is before the birth year.")
            }
            if death - birth > implausibleAgeYears {
                return finding(.implausibleLifespan, .review, [person],
                               "Born \(birth), died \(death) — \(death - birth) years. Likely a wrong date on one of the two.")
            }
            return nil
        }
    }

    private static func placeholderValues(_ people: [GedcomFamilyGraph.Person]) -> [Finding] {
        people.compactMap { person in
            var bad: [String] = []
            if isPlaceholder(person.birthPlace) { bad.append("birthplace") }
            if isPlaceholder(person.deathPlace) { bad.append("place of death") }
            if isPlaceholder(person.name) { bad.append("name") }
            guard !bad.isEmpty else { return nil }
            return finding(.placeholderValue, .info, [person],
                           "Recorded \(bad.joined(separator: " and ")) is a placeholder, not a real value.")
        }
    }

    /// No parents, no spouse, no children. Usually a record someone created
    /// and never linked — Rick's floating "Mary Latta".
    private static func unattached(_ people: [GedcomFamilyGraph.Person],
                                   in graph: GedcomFamilyGraph) -> [Finding] {
        people.compactMap { person in
            guard person.childOfFamilies.isEmpty, person.childOfFamily == nil,
                  person.spouseOfFamilies.isEmpty else { return nil }
            return finding(.unattachedPerson, .info, [person],
                           "Connected to nobody in the tree — no parents, spouse or children recorded.")
        }
    }

    private static func parentAgeProblems(_ people: [GedcomFamilyGraph.Person],
                                          in graph: GedcomFamilyGraph) -> [Finding] {
        var out: [Finding] = []
        for person in people {
            guard let childBirth = person.birthYear else { continue }
            for parent in graph.relatives(.parents, of: person) {
                guard let parentBirth = parent.birthYear else { continue }
                let gap = childBirth - parentBirth
                guard gap < youngestPlausibleParentYears else { continue }
                let why = gap < 0
                    ? "\(parent.name) is recorded as born \(-gap) years AFTER their child."
                    : "\(parent.name) would have been \(gap) at the birth."
                out.append(finding(.parentTooYoung, .review, [parent, person], why))
            }
        }
        return out
    }

    /// Rule A — the same person entered twice outright: same normalised
    /// name, same birth year, same death year. Rick's two Eileen Lattas,
    /// both 1930-2023.
    private static func duplicatesByIdenticalVitals(
        _ people: [GedcomFamilyGraph.Person]) -> [Finding] {
        var buckets: [String: [GedcomFamilyGraph.Person]] = [:]
        for person in people {
            guard let birth = person.birthYear, let death = person.deathYear else { continue }
            let key = "\(normalized(person.name))|\(birth)|\(death)"
            buckets[key, default: []].append(person)
        }
        return buckets.values.filter { $0.count > 1 }.flatMap { group in
            pairs(of: group).map { a, b in
                finding(.duplicatePerson, .review, [a, b],
                        "Same name and the same birth and death years (\(a.birthYear.map(String.init) ?? "?")–\(a.deathYear.map(String.init) ?? "?")).")
            }
        }
    }

    /// Rule B — the same child entered twice under one set of parents, with
    /// the name written differently. Rick's "Mary O'Connor" b.1905 and
    /// "Mary Catherine O'Connor" 1904-1985, both daughters of Ellen Ronan
    /// and Christopher O'Connor.
    ///
    /// Shared parents is what makes this safe on a common name: two Mary
    /// O'Connors in Boston prove nothing, two Mary O'Connors with the SAME
    /// mother and father are almost certainly one girl.
    private static func duplicatesBySharedParents(
        _ people: [GedcomFamilyGraph.Person],
        in graph: GedcomFamilyGraph) -> [Finding] {
        var buckets: [String: [GedcomFamilyGraph.Person]] = [:]
        for person in people {
            let parentIDs = graph.relatives(.parents, of: person).map(\.id).sorted()
            guard !parentIDs.isEmpty, let given = firstGivenName(person.name) else { continue }
            buckets["\(parentIDs.joined(separator: "+"))|\(given)", default: []].append(person)
        }
        return buckets.values.filter { $0.count > 1 }.flatMap { group in
            pairs(of: group).compactMap { a, b in
                // Same parents and same given name is suggestive; close
                // birth years make it a duplicate rather than two children
                // genuinely given the same first name, which families did.
                switch (a.birthYear, b.birthYear) {
                case let (ya?, yb?) where abs(ya - yb) <= 2:
                    return finding(.duplicatePerson, .review, [a, b],
                                   "Same parents and the same first name, born \(ya) and \(yb).")
                case (nil, _), (_, nil):
                    return finding(.duplicatePerson, .review, [a, b],
                                   "Same parents and the same first name; at least one has no birth year to tell them apart.")
                default:
                    return nil   // same parents, same name, years far apart: two children
                }
            }
        }
    }

    /// Someone who is their own ancestor. Rare, and worth its own rule
    /// because it is not merely wrong data — a cycle can send an ancestor
    /// walk round forever.
    private static func ancestorCycles(_ people: [GedcomFamilyGraph.Person],
                                       in graph: GedcomFamilyGraph) -> [Finding] {
        var colour: [String: Int] = [:]   // 0 unvisited, 1 on stack, 2 done
        var found: [Finding] = []
        var reported: Set<String> = []

        func walk(_ person: GedcomFamilyGraph.Person) {
            colour[person.id] = 1
            for parent in graph.relatives(.parents, of: person) {
                switch colour[parent.id] ?? 0 {
                case 0: walk(parent)
                case 1:
                    if reported.insert(parent.id).inserted {
                        found.append(finding(.ancestorCycle, .error, [parent],
                                             "Appears among their own ancestors — the tree loops through \(person.name)."))
                    }
                default: break
                }
            }
            colour[person.id] = 2
        }

        for person in people where (colour[person.id] ?? 0) == 0 { walk(person) }
        return found
    }

    // MARK: - Helpers

    private static func finding(_ kind: Kind, _ severity: Severity,
                                _ people: [GedcomFamilyGraph.Person],
                                _ detail: String) -> Finding {
        Finding(kind: kind, severity: severity,
                personIDs: people.map(\.id),
                personNames: people.map(\.name),
                familySearchIDs: people.compactMap(\.familySearchID),
                year: people.flatMap { [$0.birthYear, $0.deathYear] }
                    .compactMap { $0 }.max(),
                detail: detail)
    }

    private static func pairs(of group: [GedcomFamilyGraph.Person])
        -> [(GedcomFamilyGraph.Person, GedcomFamilyGraph.Person)] {
        let ordered = group.sorted { $0.id < $1.id }
        var out: [(GedcomFamilyGraph.Person, GedcomFamilyGraph.Person)] = []
        for i in ordered.indices {
            for j in ordered.index(after: i)..<ordered.endIndex {
                out.append((ordered[i], ordered[j]))
            }
        }
        return out
    }

    static func isPlaceholder(_ raw: String?) -> Bool {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return false }   // absent is not a placeholder
        return placeholders.contains(trimmed.lowercased())
    }

    static func normalized(_ name: String) -> String {
        name.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func firstGivenName(_ name: String) -> String? {
        normalized(name).split(separator: " ").first.map(String.init)
    }
}
