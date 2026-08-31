import Testing
import Foundation
import VideoScanCore

// MARK: - FamilyTreeVerificationTests
//
// The fixtures are Rick's ACTUAL defects, reproduced (2026-08-30):
//
//   * Mary O'Connor b.1905 and Mary Catherine O'Connor 1904-1985 — one
//     woman, two FamilySearch records (GNZ5-428, G89Q-34N) created by two
//     strangers a year apart. Same parents, same first name.
//   * Eileen Latta 1930-2023, appearing twice, once beneath each Mary.
//   * An unattached "Mary Latta" connected to nobody.
//
// Precision is the thing under test as much as detection. In a Boston tree
// "Mary O'Connor" is as common as "Mary Smith", so the negative cases —
// two genuinely distinct people who must NOT be flagged — matter more than
// the positive ones.

struct FamilyTreeVerificationTests {

    /// Rick's shape: Ellen + Christopher, their daughter recorded twice,
    /// her daughter therefore recorded twice, and a floating Mary Latta.
    private func rickShapedTree() -> GedcomFamilyGraph {
        GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Ellen /Ronan/
        1 SEX F
        1 BIRT
        2 DATE 1883
        1 FAMS @F1@
        0 @I2@ INDI
        1 NAME Christopher Dennis /O'Connor/
        1 SEX M
        1 BIRT
        2 DATE 1883
        1 FAMS @F1@
        0 @I3@ INDI
        1 NAME Mary /O'Connor/
        1 SEX F
        1 BIRT
        2 DATE 1905
        1 FAMC @F1@
        1 FAMS @F2@
        0 @I4@ INDI
        1 NAME Mary Catherine /O'Connor/
        1 SEX F
        1 BIRT
        2 DATE 1904
        1 DEAT
        2 DATE 1985
        1 FAMC @F1@
        1 FAMS @F3@
        0 @I5@ INDI
        1 NAME Eileen /Latta/
        1 SEX F
        1 BIRT
        2 DATE 1930
        1 DEAT
        2 DATE 2023
        1 FAMC @F2@
        0 @I6@ INDI
        1 NAME Eileen /Latta/
        1 SEX F
        1 BIRT
        2 DATE 1930
        1 DEAT
        2 DATE 2023
        1 FAMC @F3@
        0 @I7@ INDI
        1 NAME Mary /Latta/
        1 SEX F
        0 @F1@ FAM
        1 HUSB @I2@
        1 WIFE @I1@
        1 CHIL @I3@
        1 CHIL @I4@
        0 @F2@ FAM
        1 WIFE @I3@
        1 CHIL @I5@
        0 @F3@ FAM
        1 WIFE @I4@
        1 CHIL @I6@
        0 TRLR
        """)
    }

    private func report() -> FamilyTreeVerification.Report {
        FamilyTreeVerification.verify(rickShapedTree())
    }

    // MARK: The two real duplicates

    @Test func theTwoEileensAreFlaggedAsOnePerson() {
        let dupes = report().of(.duplicatePerson)
        let eileen = dupes.first { $0.personNames.allSatisfy { $0 == "Eileen Latta" } }
        #expect(eileen != nil, "identical name and identical 1930–2023 must be caught")
        #expect(eileen?.personIDs.sorted() == ["@I5@", "@I6@"])
    }

    @Test func theTwoMarysAreFlaggedViaTheirSharedParents() {
        let dupes = report().of(.duplicatePerson)
        let mary = dupes.first { $0.personIDs.sorted() == ["@I3@", "@I4@"] }
        #expect(mary != nil,
                "same parents + same first name + one year apart is the Mary O'Connor case")
        #expect(mary?.detail.contains("Same parents") == true)
    }

    /// This is the one that makes the report usable: the reader has to get
    /// to familysearch.org to resolve it.
    @Test func findingsCarryFamilySearchIDsWhenTheRecordHasThem() {
        let graph = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Mary /O'Connor/
        1 BIRT
        2 DATE 1905
        1 DEAT
        2 DATE 1985
        1 _FSFTID GNZ5-428
        0 @I2@ INDI
        1 NAME Mary /O'Connor/
        1 BIRT
        2 DATE 1905
        1 DEAT
        2 DATE 1985
        1 _FSFTID G89Q-34N
        0 TRLR
        """)
        let dupes = FamilyTreeVerification.verify(graph).of(.duplicatePerson)
        #expect(dupes.count == 1)
        #expect(dupes.first?.familySearchIDs.sorted() == ["G89Q-34N", "GNZ5-428"])
    }

    // MARK: Precision — the cases that must NOT be flagged

    /// "Mary O'Connor" is as common as "Mary Smith" in this tree. Two of
    /// them with no shared parents and different dates are two women.
    @Test func twoUnrelatedPeopleWithTheSameCommonNameAreNotFlagged() {
        let graph = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Mary /O'Connor/
        1 BIRT
        2 DATE 1905
        0 @I2@ INDI
        1 NAME Mary /O'Connor/
        1 BIRT
        2 DATE 1948
        0 TRLR
        """)
        #expect(FamilyTreeVerification.verify(graph).of(.duplicatePerson).isEmpty,
                "a common name alone must never be enough")
    }

    /// Families really did reuse a first name across children born years
    /// apart, often after one died young.
    @Test func siblingsSharingAFirstNameYearsApartAreNotFlagged() {
        let graph = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Patrick /Breen/
        1 FAMS @F1@
        0 @I2@ INDI
        1 NAME John /Breen/
        1 BIRT
        2 DATE 1880
        1 FAMC @F1@
        0 @I3@ INDI
        1 NAME John /Breen/
        1 BIRT
        2 DATE 1889
        1 FAMC @F1@
        0 @F1@ FAM
        1 HUSB @I1@
        1 CHIL @I2@
        1 CHIL @I3@
        0 TRLR
        """)
        #expect(FamilyTreeVerification.verify(graph).of(.duplicatePerson).isEmpty,
                "nine years apart is two boys, not one record twice")
    }

    // MARK: Contradictions

    @Test func deathBeforeBirthIsAnError() {
        let graph = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Backwards /Person/
        1 BIRT
        2 DATE 1950
        1 DEAT
        2 DATE 1910
        0 TRLR
        """)
        let f = FamilyTreeVerification.verify(graph).of(.deathBeforeBirth)
        #expect(f.count == 1)
        #expect(f.first?.severity == .error)
    }

    @Test func aParentBornAfterTheirChildIsFlagged() {
        let graph = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Young /Parent/
        1 BIRT
        2 DATE 1960
        1 FAMS @F1@
        0 @I2@ INDI
        1 NAME Older /Child/
        1 BIRT
        2 DATE 1940
        1 FAMC @F1@
        0 @F1@ FAM
        1 HUSB @I1@
        1 CHIL @I2@
        0 TRLR
        """)
        let f = FamilyTreeVerification.verify(graph).of(.parentTooYoung)
        #expect(f.count == 1)
        #expect(f.first?.detail.contains("AFTER their child") == true)
    }

    @Test func anImplausibleLifespanIsFlaggedButAnOldAgeIsNot() {
        func lifespan(_ born: Int, _ died: Int) -> Int {
            FamilyTreeVerification.verify(GedcomFamilyGraph(gedcomText: """
            0 HEAD
            0 @I1@ INDI
            1 NAME Long /Life/
            1 BIRT
            2 DATE \(born)
            1 DEAT
            2 DATE \(died)
            0 TRLR
            """)).of(.implausibleLifespan).count
        }
        #expect(lifespan(1850, 1953) == 0, "103 is old, not impossible")
        #expect(lifespan(1850, 1999) == 1, "149 is a wrong date")
    }

    // MARK: Structure

    @Test func theFloatingPersonIsReportedAsUnattached() {
        let unattached = report().of(.unattachedPerson)
        #expect(unattached.contains { $0.personNames == ["Mary Latta"] },
                "a record connected to nobody is Rick's floating Mary Latta")
    }

    /// Not merely bad data — an ancestor walk can loop on it.
    @Test func anAncestorCycleIsAnError() {
        let graph = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME A /Loop/
        1 FAMC @F2@
        1 FAMS @F1@
        0 @I2@ INDI
        1 NAME B /Loop/
        1 FAMC @F1@
        1 FAMS @F2@
        0 @F1@ FAM
        1 HUSB @I1@
        1 CHIL @I2@
        0 @F2@ FAM
        1 HUSB @I2@
        1 CHIL @I1@
        0 TRLR
        """)
        let f = FamilyTreeVerification.verify(graph).of(.ancestorCycle)
        #expect(!f.isEmpty, "a person who is their own ancestor must be caught")
        #expect(f.first?.severity == .error)
    }

    // MARK: The queue

    @Test func theReportSortsErrorsFirstAndCountsWhatNeedsReview() {
        let r = report()
        let severities = r.findings.map(\.severity)
        #expect(severities == severities.sorted(), "errors before review before info")
        #expect(r.needingReview == r.findings.filter { $0.severity <= .review }.count)
        #expect(r.peopleChecked == 7)
    }

    /// The badge count and each row's identity have to be stable, or a
    /// "reviewed, leave it alone" decision cannot be keyed to a finding.
    @Test func findingIDsAreStableAcrossRuns() {
        let first = report().findings.map(\.id)
        let second = report().findings.map(\.id)
        #expect(first == second)
        #expect(Set(first).count == first.count, "ids must be unique within a report")
    }
}
