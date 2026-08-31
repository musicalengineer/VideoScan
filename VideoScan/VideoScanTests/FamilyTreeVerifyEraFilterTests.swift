import Testing
import Foundation
import VideoScanCore
@testable import VideoScan

// MARK: - The era filter on the Verify Tree review queue
//
// Rick, 2026-08-31: "anything before 1800 has little chance of being fixed
// by me ... but if we have one after 1800 or 1900, these are ones I might
// be able to focus on."
//
// The whole risk of this feature is a filter that QUIETLY HIDES fixable
// work. Two properties carry that risk and both are pinned here:
//
//   1. Finding.year is the LATEST year among the people involved, not the
//      earliest. A pair spanning an 1780 parent and an 1810 child is an
//      1810 problem; keying on the earliest would drop it out of "1800
//      onward" and Rick would never see a defect he could have fixed.
//   2. An UNDATED finding passes every era. A missing date is not evidence
//      of age — most of Rick's unattached-person and placeholder findings
//      have no dates at all, and they are among the most fixable.

struct FamilyTreeVerifyEraFilterTests {

    // MARK: Fixtures

    /// A parent born 1780 whose child is born 1810 — the straddling case.
    /// The parent is 12 at the child's birth only if we lie about dates, so
    /// this fixture uses the lifespan rule instead: an impossible age puts
    /// one finding on a person with a known late death year.
    private func straddlingTree() -> GedcomFamilyGraph {
        GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Colonial /Straddler/
        1 BIRT
        2 DATE 1780
        1 DEAT
        2 DATE 1930
        0 TRLR
        """)
    }

    /// Nothing dated at all, and unattached to anyone.
    private func undatedTree() -> GedcomFamilyGraph {
        GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Floating /Nobody/
        0 @I2@ INDI
        1 NAME Another /Nobody/
        0 TRLR
        """)
    }

    /// Squarely pre-1800 and fully dated: born 1700, died 1900 is a 200
    /// year lifespan, so it is flagged, and its latest year is 1900.
    private func deepColonialTree() -> GedcomFamilyGraph {
        GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Early /Settler/
        1 BIRT
        2 DATE 1650
        1 DEAT
        2 DATE 1600
        0 TRLR
        """)
    }

    // MARK: Finding.year

    @Test func yearIsTheLatestKnownYearNotTheEarliest() {
        let findings = FamilyTreeVerification.verify(straddlingTree()).findings
        let lifespan = findings.first { $0.kind == .implausibleLifespan }
        #expect(lifespan != nil, "1780–1930 is 150 years and must be flagged")
        #expect(lifespan?.year == 1930,
                "keying on the earliest year would bury an 1810-era problem under a 1780 birth: got \(String(describing: lifespan?.year))")
    }

    @Test func yearIsNilWhenNothingIsDated() {
        let findings = FamilyTreeVerification.verify(undatedTree()).findings
        #expect(!findings.isEmpty, "two unattached people must produce findings")
        #expect(findings.allSatisfy { $0.year == nil })
    }

    @Test func aDeathBeforeBirthKeysOnTheLaterOfTheTwo() {
        let findings = FamilyTreeVerification.verify(deepColonialTree()).findings
        let contradiction = findings.first { $0.kind == .deathBeforeBirth }
        #expect(contradiction != nil)
        #expect(contradiction?.year == 1650,
                "born 1650 / died 1600 — the latest year we know is 1650")
    }

    // MARK: The filter itself

    private func finding(year: Int?) -> FamilyTreeVerification.Finding {
        // Build through the analyser so the test cannot drift from the
        // real construction path.
        let text: String
        if let year {
            text = """
            0 HEAD
            0 @I1@ INDI
            1 NAME Dated /Person/
            1 BIRT
            2 DATE \(year)
            1 DEAT
            2 DATE \(year - 200)
            0 TRLR
            """
        } else {
            text = """
            0 HEAD
            0 @I1@ INDI
            1 NAME Undated /Person/
            0 TRLR
            """
        }
        let all = FamilyTreeVerification.verify(GedcomFamilyGraph(gedcomText: text)).findings
        return all.first { $0.severity <= .review } ?? all[0]
    }

    @Test func allYearsAdmitsEverything() {
        let era = FamilyTreeVerifyReportView.Era.all
        #expect(era.admits(finding(year: 1650)))
        #expect(era.admits(finding(year: 1950)))
        #expect(era.admits(finding(year: nil)))
    }

    @Test func eighteenHundredOnwardExcludesOnlyWhatItKnowsIsOlder() {
        let era = FamilyTreeVerifyReportView.Era.since1800
        #expect(!era.admits(finding(year: 1799)), "1799 is out of range")
        #expect(era.admits(finding(year: 1800)), "the boundary year is inclusive")
        #expect(era.admits(finding(year: 1801)))
        #expect(era.admits(finding(year: nil)),
                "an undated finding must NEVER be hidden by an era filter: a missing date is not evidence of age")
    }

    @Test func nineteenHundredOnwardIsTheNarrowestBand() {
        let era = FamilyTreeVerifyReportView.Era.since1900
        #expect(!era.admits(finding(year: 1899)))
        #expect(era.admits(finding(year: 1900)))
        #expect(era.admits(finding(year: nil)))
    }

    /// The bands must nest: anything 1900 admits, 1800 admits too, and
    /// anything 1800 admits, "all years" admits. A reader narrowing the
    /// filter must never see a finding APPEAR.
    @Test func theBandsNestSoNarrowingNeverRevealsSomethingNew() {
        for year in [nil, 1650, 1799, 1800, 1899, 1900, 2020] as [Int?] {
            let f = finding(year: year)
            if FamilyTreeVerifyReportView.Era.since1900.admits(f) {
                #expect(FamilyTreeVerifyReportView.Era.since1800.admits(f),
                        "year \(String(describing: year)) passed 1900+ but not 1800+")
            }
            if FamilyTreeVerifyReportView.Era.since1800.admits(f) {
                #expect(FamilyTreeVerifyReportView.Era.all.admits(f),
                        "year \(String(describing: year)) passed 1800+ but not All")
            }
        }
    }

    // MARK: Scale — the filter runs on every keystroke of the picker

    /// Rick's real tree returns 442 entries needing review and the tree
    /// itself is 39,250 people. Filtering is O(findings) and must stay far
    /// below anything a human notices, because it re-runs on every era
    /// change and every chip tap. Budget is deliberately loose; the point
    /// is to catch an accidental O(n²) rewrite, not to time the machine.
    @Test func filteringTenThousandFindingsIsInstant() {
        let sample = [finding(year: 1650), finding(year: 1850),
                      finding(year: 1950), finding(year: nil)]
        let many = (0..<2_500).flatMap { _ in sample }
        #expect(many.count == 10_000)

        let start = ContinuousClock().now
        let kept = many.filter(FamilyTreeVerifyReportView.Era.since1800.admits)
        let elapsed = ContinuousClock().now - start

        #expect(kept.count == 7_500, "1650 is the only band excluded")
        #expect(elapsed < .milliseconds(100), "filtering took \(elapsed)")
    }
}
