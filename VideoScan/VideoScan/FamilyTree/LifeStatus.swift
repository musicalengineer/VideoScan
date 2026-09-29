// LifeStatus.swift
// ONE rule for "is this person living?" — the tense Hallie speaks in.
//
// Rick, 2026-09-01: "should not speak of people in the catalog like me,
// donna, tim, beth … in the past tense like 'rick was …' — it makes it
// sound like he's passed on. Dad and Ma Breen are passed on as can be seen
// in the bio data. Anyone in the family tree above them can be assumed
// passed-on." Until now the biography card said "was the child of" and
// "was married to" for everyone, and the composer's prompt said nothing
// about tense, so the model copied the template.
//
// The rule is computed HERE and nowhere else (HallieBiographyCard,
// HallieGroundedComposer's prompt, HallieCompositionVerifier and
// ResearchEligibility all read it), so a change to what "presumed" means
// is one edit. Deterministic, no I/O, no model.
//
// Tree person (GedcomFamilyGraph.Person), first rule that fires wins:
//   1. a recorded death                      → deceased
//   2. born ≤ now − 100                      → presumedDeceased
//   3. any descendant deceased or born
//      ≤ now − 100 (Rick's "above them")     → presumedDeceased
//   4. a parent born ≤ now − 150 or died
//      ≤ now − 101 (a child cannot be born
//      more than a year after a parent dies) → presumedDeceased
//   5. a spouse born ≤ now − 150 or died
//      ≤ now − 101                           → presumedDeceased
//   6. otherwise                             → living
// Measured on the live 20-generation export (16,383 people, 611 with no
// dates at all): rules 3–5 settle 599 of the undated; the 12 left as
// "living" are isolated stubs ("? Smythe" with an undated spouse). Rick's
// own record carries his 1959 birth, so rule 6 is what keeps him living.
//
// People-tab profile: living unless the profile records a death, then
// deceased; a profile pinned to a tree record also inherits the tree's
// verdict (Dad and Ma are pinned, and both have a death recorded anyway).
//
// C++ readers: a plain enum with static factory functions; the graph walk
// is a bounded BFS with a visited set and early exit on the first hit.

import Foundation
import VideoScanCore

enum LifeStatus: String, Sendable, Equatable {
    /// A death is recorded.
    case deceased
    /// No death recorded, but the dates around this person settle it.
    case presumedDeceased
    /// Nothing says otherwise: spoken of in the present tense.
    case living

    /// How many years back a birth must be before someone with no death
    /// date is treated as deceased. The one number behind rules 2 and 3.
    static let presumedLivingYears = 100
    /// A parent or spouse born this long ago settles it (rules 4 and 5).
    static let relativeBornYearsAgo = 150
    /// A parent or spouse who died this long ago settles it (rules 4 and 5):
    /// the subject was born, or married, no later than a year after.
    static let relativeDiedYearsAgo = presumedLivingYears + 1

    var isLiving: Bool { self == .living }

    /// The line the composer is told, so the model's tense follows the fact
    /// and not the template.
    var composerInstruction: String {
        switch self {
        case .living:
            return "Subject is living: use the present tense for who they are, where they "
                + "live, whom they are married to and who their family is; never phrase "
                + "their life as finished. Only a birth is in the past (\"was born\")."
        case .deceased, .presumedDeceased:
            return "Subject has passed on: use the past tense for their life."
        }
    }

    // MARK: - Tree person

    /// The verdict for a tree record. `graph` is optional so a caller with
    /// only the record (ResearchEligibility) gets rules 1, 2 and 6; with the
    /// graph, the family around the person is consulted too.
    static func of(_ person: GedcomFamilyGraph.Person,
                   in graph: GedcomFamilyGraph?,
                   now: Date = Date(),
                   calendar: Calendar = .current) -> LifeStatus {
        if hasRecordedDeath(person) { return .deceased }
        let currentYear = calendar.component(.year, from: now)
        if bornAtOrBefore(person, year: currentYear - presumedLivingYears) { return .presumedDeceased }
        guard let graph else { return .living }
        if hasDescendant(of: person, in: graph, where: { descendant in
            hasRecordedDeath(descendant)
                || bornAtOrBefore(descendant, year: currentYear - presumedLivingYears)
        }) {
            return .presumedDeceased
        }
        let relatives = graph.relatives(.parents, of: person)
            + graph.marriages(of: person).compactMap(\.spouse)
        for relative in relatives {
            if bornAtOrBefore(relative, year: currentYear - relativeBornYearsAgo)
                || diedAtOrBefore(relative, year: currentYear - relativeDiedYearsAgo) {
                return .presumedDeceased
            }
        }
        return .living
    }

    // MARK: - People-tab profile

    /// The verdict for a People-tab profile: a recorded death wins; a pinned
    /// tree record's verdict comes next; otherwise living (the People tab is
    /// the contemporary family, deliberately absent from FamilySearch).
    static func of(profile: POIProfile,
                   bridged: GedcomFamilyGraph.Person? = nil,
                   in graph: GedcomFamilyGraph? = nil,
                   now: Date = Date(),
                   calendar: Calendar = .current) -> LifeStatus {
        ofProfile(deathdate: profile.deathdate, bridged: bridged, in: graph, now: now, calendar: calendar)
    }

    /// The same rule for the executor's snapshot of a profile (which carries
    /// only the death date, never the notes or photos).
    static func ofProfile(deathdate: Date?,
                          bridged: GedcomFamilyGraph.Person? = nil,
                          in graph: GedcomFamilyGraph? = nil,
                          now: Date = Date(),
                          calendar: Calendar = .current) -> LifeStatus {
        if deathdate != nil { return .deceased }
        if let bridged {
            let fromTree = of(bridged, in: graph, now: now, calendar: calendar)
            if fromTree != .living { return fromTree }
        }
        return .living
    }

    // MARK: - Helpers

    static func hasRecordedDeath(_ person: GedcomFamilyGraph.Person) -> Bool {
        GedcomFamilyGraph.year(in: person.deathDate) != nil
            || !(person.deathDate?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private static func bornAtOrBefore(_ person: GedcomFamilyGraph.Person, year: Int) -> Bool {
        guard let birth = GedcomFamilyGraph.year(in: person.birthDate) else { return false }
        return birth <= year
    }

    private static func diedAtOrBefore(_ person: GedcomFamilyGraph.Person, year: Int) -> Bool {
        guard let death = GedcomFamilyGraph.year(in: person.deathDate) else { return false }
        return death <= year
    }

    /// Breadth-first over the children links, visited set, early exit.
    private static func hasDescendant(of person: GedcomFamilyGraph.Person,
                                      in graph: GedcomFamilyGraph,
                                      where predicate: (GedcomFamilyGraph.Person) -> Bool) -> Bool {
        var visited: Set<String> = [person.id]
        var queue = graph.relatives(.children, of: person)
        var index = 0
        while index < queue.count {
            let next = queue[index]
            index += 1
            guard visited.insert(next.id).inserted else { continue }
            if predicate(next) { return true }
            queue.append(contentsOf: graph.relatives(.children, of: next))
        }
        return false
    }
}
