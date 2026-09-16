// GedcomRefreshPolicyTests.swift
//
// REFRESH: re-pulling the SAME upstream, as distinct from merging two
// different people's trees.
//
// Rick, 2026-09-16, after finding his grandmother still wrong in the
// Family Tree view. The live tree holds TWO Mary O'Connors:
//
//   @I5@  Mary /O'Connor/            GNZ5-428   b.1905            (not her)
//   @I7@  Mary Catherine /O'Connor/  G89Q-34N   b.23 Dec 1904
//                                               d.16 Jul 1985     (her)
//
// The correct record is spelled "Catherine" because the tree was pulled on
// 2026-08-26 — BEFORE he corrected FamilySearch to "Christina". Her son
// confirmed the name.
//
// Under the existing `.unionKeepingFirst` policy a re-pull KEEPS the stale
// "Catherine" and files the correction as a conflict, which is backwards:
// merging two independent trees is a union of two authorities, but
// re-pulling one upstream is a refresh of the only authority, and its
// differences ARE the corrections the user went and made.
//
// Five dimensions:
//   1. Logic     — newer wins, blanks fill, the old name survives, and the
//                  union policy is untouched
//   2. Scale     — a 10k refresh stays inside a budget
//   3. Media     — n/a
//   4. Isolation — pure graphs built in memory; no files, no defaults
//   5. Sensor    — Mary's own case, by name, so the thing that prompted
//                  this cannot silently regress

import Foundation
import Testing
@testable import VideoScanCore

@Suite("GEDCOM refresh — re-pulling one upstream is not a conflict")
struct GedcomRefreshPolicyTests {

    private func ged(_ records: String) -> GedcomFamilyGraph {
        GedcomFamilyGraph(gedcomText: "0 HEAD\n" + records + "0 TRLR\n")
    }

    /// The tree as pulled 2026-08-26.
    private var asPulledInAugust: GedcomFamilyGraph {
        ged("""
        0 @I7@ INDI
        1 NAME Mary Catherine /O'Connor/
        1 SEX F
        1 _FSFTID G89Q-34N
        1 BIRT
        2 DATE 23 December 1904
        1 DEAT
        2 DATE 16 July 1985
        """ + "\n")
    }

    /// The same person, pulled again after Rick corrected FamilySearch.
    private var afterRickCorrectedFamilySearch: GedcomFamilyGraph {
        ged("""
        0 @I1@ INDI
        1 NAME Mary Christina /O'Connor/
        1 SEX F
        1 _FSFTID G89Q-34N
        1 BIRT
        2 DATE 23 December 1904
        2 PLAC County Cork, Ireland
        1 DEAT
        2 DATE 16 July 1985
        2 PLAC Brockton, Massachusetts
        """ + "\n")
    }

    // MARK: - 1 & 5. Mary's case, by name

    @Test func aRefreshTakesTheCorrectedNameAndKeepsTheOldOneFindable() throws {
        let out = asPulledInAugust.merge(with: afterRickCorrectedFamilySearch,
                                         policy: .refreshFromNewer)
        let mary = try #require(out.graph.people.values.first { $0.familySearchID == "G89Q-34N" })

        #expect(mary.name.contains("Christina"),
                "the corrected name must win, got \(mary.name)")
        #expect(!mary.name.contains("Catherine"))
        // Still findable under what the tree used to call her.
        #expect(mary.alternateNames.contains { $0.contains("Catherine") },
                "the old spelling must survive as an alternate: \(mary.alternateNames)")
        #expect(out.sharedPeopleCount == 1, "matched by FamilySearch ID, not added twice")
        #expect(out.graph.people.count == 1)
    }

    /// Blanks fill from the newer pull — that is not a disagreement, and
    /// it is how the places she was born and died finally arrive.
    @Test func aRefreshFillsInFactsTheOldPullNeverHad() throws {
        let out = asPulledInAugust.merge(with: afterRickCorrectedFamilySearch,
                                         policy: .refreshFromNewer)
        let mary = try #require(out.graph.people.values.first { $0.familySearchID == "G89Q-34N" })
        #expect(mary.birthPlace?.contains("Cork") == true)
        #expect(mary.deathPlace?.contains("Brockton") == true)
        #expect(mary.birthDate == "23 December 1904")
        #expect(mary.deathDate == "16 July 1985")
    }

    /// A refresh reports what it CHANGED, so the user can see it — but as
    /// an update, never as a conflict needing a ruling.
    @Test func aRefreshReportsUpdatesNotConflicts() {
        let out = asPulledInAugust.merge(with: afterRickCorrectedFamilySearch,
                                         policy: .refreshFromNewer)
        let refreshed = out.conflicts.filter { $0.kind == .fieldRefreshed }
        #expect(!refreshed.isEmpty, "a silent refresh is not auditable")
        #expect(refreshed.contains { $0.resolution.contains("Christina") },
                "\(refreshed.map(\.resolution))")
        #expect(out.conflicts.allSatisfy { $0.kind != .fieldDisagreement },
                "one upstream refreshing itself is not a conflict")
    }

    // MARK: - 1. The union policy must be untouched

    /// THE GUARD. Two different trees still behave exactly as before:
    /// first wins, and the difference is a real conflict for a human.
    @Test func mergingTwoDifferentTreesStillKeepsTheFirstAndReportsAConflict() throws {
        let out = asPulledInAugust.merge(with: afterRickCorrectedFamilySearch)   // default policy
        let mary = try #require(out.graph.people.values.first { $0.familySearchID == "G89Q-34N" })

        #expect(mary.name.contains("Catherine"), "union keeps the first source")
        #expect(mary.alternateNames.contains { $0.contains("Christina") })
        #expect(out.conflicts.contains { $0.kind == .fieldDisagreement })
        #expect(out.conflicts.allSatisfy { $0.kind != .fieldRefreshed })
    }

    /// A refresh must not drop people the newer, SHALLOWER pull does not
    /// mention — three generations must never delete seventeen.
    @Test func aShallowRefreshKeepsTheDeepAncestryItDoesNotMention() throws {
        // The deep tree: her, plus an ancestor the shallow pull never
        // reaches. Built as one GEDCOM because `people` is read-only.
        let deep = ged("""
        0 @I7@ INDI
        1 NAME Mary Catherine /O'Connor/
        1 SEX F
        1 _FSFTID G89Q-34N
        1 BIRT
        2 DATE 23 December 1904
        0 @I99@ INDI
        1 NAME Christopher Dennis /O'Connor/
        1 SEX M
        1 _FSFTID ABCD-123
        """ + "\n")

        let out = deep.merge(with: afterRickCorrectedFamilySearch, policy: .refreshFromNewer)
        #expect(out.graph.people.values.contains { $0.familySearchID == "ABCD-123" },
                "a 3-generation refresh deleted someone it simply did not cover")
        #expect(out.graph.people.count == 2)
    }

    // MARK: - 2. Scale

    @Test func aTenThousandPersonRefreshStaysInsideABudget() {
        func tree(_ nameSuffix: String) -> GedcomFamilyGraph {
            var text = "0 HEAD\n"
            for i in 0..<10_000 {
                // FamilySearch IDs are 4 alphanumerics, a dash, then 3.
                // "FS0-AAA" is not that shape and matched nothing, which is
                // what an earlier version of this test actually measured.
                let fsid = String(format: "%04d-AAA", i)
                text += "0 @I\(i)@ INDI\n1 NAME Person\(i) \(nameSuffix) /Test/\n1 SEX M\n1 _FSFTID \(fsid)\n"
            }
            return GedcomFamilyGraph(gedcomText: text + "0 TRLR\n")
        }
        let old = tree("Old"), new = tree("New")
        let start = Date()
        let out = old.merge(with: new, policy: .refreshFromNewer)
        let elapsed = -start.timeIntervalSinceNow
        #expect(out.sharedPeopleCount == 10_000)
        #expect(elapsed < 5.0, "10k refresh took \(String(format: "%.2f", elapsed))s")
    }
}
