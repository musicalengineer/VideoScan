// FamilyTreeDuplicates.swift
// Finding the SAME person recorded twice in the tree, so the Family Tree
// view can show one card instead of three (Rick, 2026-09-17).
//
// WHY THIS EXISTS. FamilySearch is a shared tree: two contributors can
// create two records for one ancestor and nobody notices for years. Rick's
// grandmother is in his tree twice — G89Q-34N carries her vitals and the
// married name, GNZ5-428 carries her parents and all her siblings, and they
// share the same parent family. He is merging them upstream on
// familysearch.org, but that takes time and a re-pull, and in the meantime
// his uncle asks about his mother and gets two answers.
//
// SCOPED TO RECENT GENERATIONS ON PURPOSE. Rick: "in the case of recent
// generations, since I know them better I can say which record is correct."
// Ten generations back, two Thomas Rices born four years apart in the same
// parish may well be two men, and nobody alive can say. Near the root the
// reader has real knowledge, so that is the only place this offers a
// judgement. `generations` is the reach from a root; beyond it we say
// nothing.
//
// CONSERVATIVE BY CONSTRUCTION. A false positive here hides a real person
// from their own family — far worse than showing a duplicate. So a name
// match alone is never enough: a pair must ALSO agree on something a
// coincidence would not (the same parents, a shared spouse family, or
// near-identical birth years). Two brothers named for their father are a
// name match; they do not share a spouse and are not born the same year.
//
// This file only FINDS groups. It never chooses and never hides — the
// reader does that, and their decisions live in `FamilyTreeDuplicateChoices`
// keyed by FamilySearch ID so they survive the re-pull that renumbers every
// GEDCOM xref.

import Foundation

public enum FamilyTreeDuplicates {

    /// One set of records that look like the same human being.
    public struct Group: Equatable, Sendable, Identifiable {
        /// Stable across re-pulls: the sorted FamilySearch IDs of the
        /// members, joined. A group keeps its identity when the tree is
        /// pulled again, so a decision made today still applies tomorrow.
        public let id: String
        /// Member person IDs (GEDCOM xrefs), in the graph's own order.
        public let personIDs: [String]
        /// The display name they agree on, for a one-line explanation.
        public let displayName: String
        /// Why we think these are one person — shown to the reader, because
        /// a hidden relative demands a reason, not just a verdict.
        public let evidence: [String]

        public init(id: String, personIDs: [String], displayName: String, evidence: [String]) {
            self.id = id
            self.personIDs = personIDs
            self.displayName = displayName
            self.evidence = evidence
        }
    }

    /// Corroboration beyond the name. One of these must hold.
    enum Signal: String {
        case sameParents = "the same parents"
        case sharedSpouseFamily = "a shared marriage"
        case sameBirthYear = "the same birth year"
        case nearBirthYear = "birth years a year or two apart"
    }

    /// Groups of probable duplicates within `generations` of `rootIDs`.
    ///
    /// Pure: same graph in, same groups out, no I/O and no globals.
    /// Cost is O(people in reach) plus a bucket pass; on Rick's 39,250-person
    /// tree at four generations it touches a few hundred records.
    public static func groups(in graph: GedcomFamilyGraph,
                              rootIDs: [String],
                              generations: Int) -> [Group] {
        guard generations > 0, !rootIDs.isEmpty else { return [] }
        let reachable = withinReach(of: rootIDs, in: graph, generations: generations)
        guard reachable.count > 1 else { return [] }

        // Bucket by (first given name, surname). Cheap, and it is only a
        // candidate filter — every bucket still has to earn a signal.
        var buckets: [String: [GedcomFamilyGraph.Person]] = [:]
        for id in reachable {
            guard let person = graph.people[id] else { continue }
            guard let key = nameKey(person) else { continue }
            buckets[key, default: []].append(person)
        }

        var found: [Group] = []
        for (_, candidates) in buckets where candidates.count > 1 {
            for cluster in cluster(candidates) where cluster.members.count > 1 {
                // Only records that CARRY a FamilySearch ID can be decided
                // about, because the decision has to outlive the xrefs.
                let identified = cluster.members.filter { $0.familySearchID != nil }
                guard identified.count > 1 else { continue }
                let fsids = identified.compactMap(\.familySearchID).sorted()
                found.append(Group(id: fsids.joined(separator: "+"),
                                   personIDs: identified.map(\.id),
                                   displayName: identified[0].name,
                                   evidence: cluster.signals.map(\.rawValue).sorted()))
            }
        }
        return found.sorted { $0.displayName < $1.displayName }
    }

    // MARK: - Pieces

    /// Everyone within `generations` steps of a root, walking parents,
    /// children and spouses. Breadth-first with an explicit queue — no
    /// recursion, so the depth of Rick's tree cannot put this on the stack.
    static func withinReach(of rootIDs: [String],
                            in graph: GedcomFamilyGraph,
                            generations: Int) -> Set<String> {
        var seen = Set(rootIDs)
        var frontier = rootIDs
        var depth = 0
        while depth < generations, !frontier.isEmpty {
            var next: [String] = []
            for id in frontier {
                for neighbour in relatives(of: id, in: graph) where !seen.contains(neighbour) {
                    seen.insert(neighbour)
                    next.append(neighbour)
                }
            }
            frontier = next
            depth += 1
        }
        return seen
    }

    private static func relatives(of id: String, in graph: GedcomFamilyGraph) -> [String] {
        guard let person = graph.people[id] else { return [] }
        var out: [String] = []
        for familyID in person.childOfFamilies + [person.childOfFamily].compactMap({ $0 }) {
            guard let family = graph.families[familyID] else { continue }
            out += [family.husband, family.wife].compactMap { $0 } + family.children
        }
        for familyID in person.spouseOfFamilies {
            guard let family = graph.families[familyID] else { continue }
            out += [family.husband, family.wife].compactMap { $0 } + family.children
        }
        return out.filter { $0 != id }
    }

    /// Single-link clustering inside one name bucket: a record joins a
    /// cluster when it corroborates with ANY member already in it. Three
    /// records for one Mary therefore become one group of three rather than
    /// three pairs the reader has to reconcile by hand.
    private static func cluster(_ candidates: [GedcomFamilyGraph.Person])
        -> [(members: [GedcomFamilyGraph.Person], signals: Set<Signal>)] {
        var clusters: [(members: [GedcomFamilyGraph.Person], signals: Set<Signal>)] = []
        for person in candidates {
            var joined = false
            for index in clusters.indices {
                let signals = clusters[index].members.reduce(into: Set<Signal>()) {
                    $0.formUnion(corroboration(between: $1, and: person))
                }
                if !signals.isEmpty {
                    clusters[index].members.append(person)
                    clusters[index].signals.formUnion(signals)
                    joined = true
                    break
                }
            }
            if !joined { clusters.append((members: [person], signals: [])) }
        }
        return clusters
    }

    /// What two same-named records agree on beyond the name. Empty means
    /// "no reason to believe these are one person", and the pair is left
    /// alone.
    static func corroboration(between a: GedcomFamilyGraph.Person,
                              and b: GedcomFamilyGraph.Person) -> Set<Signal> {
        guard a.id != b.id else { return [] }
        // A recorded sex disagreement is a veto, not a missing signal: two
        // records that disagree about that are not one person, whatever
        // else matches.
        if !a.sex.isEmpty, !b.sex.isEmpty, a.sex != b.sex { return [] }

        // Birth years far apart are a VETO, not a missing signal. Families
        // reused a name when a child died young, so two "John Breen"
        // records under the same parents born a decade apart are two sons,
        // not one man recorded twice. Without this, sharing parents would
        // be enough to hide a brother who died as a baby — the cruellest
        // possible false positive in a family archive.
        if let yearA = birthYear(a), let yearB = birthYear(b), abs(yearA - yearB) > 2 { return [] }

        var signals: Set<Signal> = []
        let parentsA = Set(a.childOfFamilies + [a.childOfFamily].compactMap { $0 })
        let parentsB = Set(b.childOfFamilies + [b.childOfFamily].compactMap { $0 })
        if !parentsA.isDisjoint(with: parentsB) { signals.insert(.sameParents) }
        if !Set(a.spouseOfFamilies).isDisjoint(with: Set(b.spouseOfFamilies)) {
            signals.insert(.sharedSpouseFamily)
        }
        if let yearA = birthYear(a), let yearB = birthYear(b) {
            if yearA == yearB { signals.insert(.sameBirthYear) }
            else if abs(yearA - yearB) <= 2 { signals.insert(.nearBirthYear) }
        }
        return signals
    }

    /// `(first given name, surname)`, lower-cased and stripped of
    /// punctuation. Nil when either half is missing — a record with no
    /// surname cannot be matched safely.
    static func nameKey(_ person: GedcomFamilyGraph.Person) -> String? {
        let surname = normalise(person.surname ?? "")
        guard !surname.isEmpty else { return nil }
        let given = normalise(person.name)
            .replacingOccurrences(of: surname, with: " ")
            .split(separator: " ")
            .first
            .map(String.init) ?? ""
        guard !given.isEmpty else { return nil }
        return given + "\u{0}" + surname
    }

    static func normalise(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "/", with: " ")
            .split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "-" })
            .joined(separator: " ")
    }

    /// The first four-digit year in a GEDCOM date string. "23 December
    /// 1904" and "about 1905" both answer; an empty or undated record does
    /// not, and then the year signal simply does not fire.
    static func birthYear(_ person: GedcomFamilyGraph.Person) -> Int? {
        guard let date = person.birthDate else { return nil }
        var digits = ""
        for character in date {
            if character.isNumber {
                digits.append(character)
                if digits.count == 4, let year = Int(digits), year > 1000, year < 2200 { return year }
            } else {
                digits = ""
            }
        }
        return nil
    }
}
