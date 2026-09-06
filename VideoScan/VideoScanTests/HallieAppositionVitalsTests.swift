import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

/// codex finding #1114-1, open since 2026-09-05 and closed here.
///
/// Every other Hallie route migrated to the vital-dates seam so that a
/// person Rick corrected in the People tab is spoken with HIS dates.
/// `HallieKinshipApposition.treeAppositionAnswer` did not — it read the
/// tree's own years, and decided is/was tense from the tree's death date.
/// The visible harm is not just a stale year: it is one answer disagreeing
/// with the answer beside it about the same person, which for this product
/// is worse than either value being wrong.
@Suite("The kinship aside reads the vital-dates seam")
struct HallieAppositionVitalsTests {

    /// Ma as Rick actually has her: the tree says one thing, the People tab
    /// is authoritative and says another.
    private static let tree = GedcomFamilyGraph(gedcomText: """
    0 HEAD
    0 @I1@ INDI
    1 NAME Rick /Breen/
    1 FAMC @F1@
    0 @I2@ INDI
    1 NAME Eileen /Latta/
    1 _FSFTID G2CR-R4H
    1 BIRT
    2 DATE 1 JAN 1931
    1 FAMS @F1@
    0 @F1@ FAM
    1 WIFE @I2@
    1 CHIL @I1@
    0 TRLR
    """)

    private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        c.timeZone = TimeZone(identifier: "UTC")
        return HallieVitalDates.utcCalendar.date(from: c)!
    }

    /// The lens the turn builds, with Ma's corrected birth date on a profile
    /// pinned to her tree record.
    private static func lens(bornCorrected: Bool) -> HallieVitalDates.Lens {
        guard bornCorrected else { return .treeOnly }
        let eileen = HallieTurnExecutor.ProfileSnapshot(
            stableID: "eileen", canonicalName: "Eileen",
            birthdate: date(1930, 8, 31),
            treeIdentity: .familySearchID("G2CR-R4H"),
            surname: "Breen", maidenName: "Latta")
        return .make(profiles: [HallieVitalProfile(eileen)], graph: tree)
    }

    private static var eileen: GedcomFamilyGraph.Person {
        tree.people["I2"]!
    }

    /// The seam speaks the People tab's year; the raw tree speaks its own.
    /// If these ever agree the tests below stop testing anything.
    @Test func theTwoStoresGenuinelyDisagreeAboutHerYear() {
        #expect(HalliePersonCard.yearsText(Self.eileen) == "b. 1931",
                "the tree's own year")
        #expect(Self.lens(bornCorrected: true).yearsText(Self.eileen) == "b. 1930",
                "the year Rick corrected")
    }

    /// The migration itself: the aside must speak the corrected year.
    @Test func theAsideSpeaksTheCorrectedYear() {
        let lens = Self.lens(bornCorrected: true)
        #expect(lens.yearsText(Self.eileen) == "b. 1930")
        #expect(lens.birthYear(Self.eileen) == 1930)
    }

    /// With no profiles read, nothing changes — a failed read is not
    /// evidence that the tree is right, and must leave it standing.
    @Test func withNoProfilesTheTreesOwnYearStands() {
        #expect(HallieVitalDates.Lens.treeOnly.yearsText(Self.eileen)
                == HalliePersonCard.yearsText(Self.eileen))
    }

    /// Tense follows the seam too. A death the People tab records and the
    /// tree does not made Hallie say "is" about someone who had died.
    @Test func aDeathOnlyThePeopleTabKnowsMakesTheTensepast() {
        let died = HallieTurnExecutor.ProfileSnapshot(
            stableID: "eileen", canonicalName: "Eileen",
            birthdate: Self.date(1930, 8, 31),
            treeIdentity: .familySearchID("G2CR-R4H"),
            deathdate: Self.date(2023, 6, 1))
        let lens = HallieVitalDates.Lens.make(
            profiles: [HallieVitalProfile(died)], graph: Self.tree)
        #expect(Self.eileen.deathDate == nil, "the tree records no death")
        #expect(lens.deathYear(Self.eileen) == 2023, "the People tab does")
    }
}
