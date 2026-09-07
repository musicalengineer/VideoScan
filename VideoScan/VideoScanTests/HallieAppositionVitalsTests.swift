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

    /// Non-trapping on purpose. The first version force-unwrapped a WRONG
    /// key ("I2"; GEDCOM ids carry their at-signs, "@I2@") and the trap took
    /// the whole suite down — eight tests reported only in xcodebuild's
    /// "Failing tests:" block, which my greps were not reading. A fixture
    /// that drifts should fail one assertion, not crash the run.
    private static func eileenOrNil() -> GedcomFamilyGraph.Person? {
        tree.people["@I2@"]
    }

    /// The seam speaks the People tab's year; the raw tree speaks its own.
    /// If these ever agree the tests below stop testing anything.
    @Test func theTwoStoresGenuinelyDisagreeAboutHerYear() throws {
        #expect(HalliePersonCard.yearsText(try #require(Self.eileenOrNil())) == "b. 1931",
                "the tree's own year")
        #expect(Self.lens(bornCorrected: true).yearsText(try #require(Self.eileenOrNil())) == "b. 1930",
                "the year Rick corrected")
    }

    /// The migration itself: the aside must speak the corrected year.
    @Test func theAsideSpeaksTheCorrectedYear() throws {
        let lens = Self.lens(bornCorrected: true)
        #expect(lens.yearsText(try #require(Self.eileenOrNil())) == "b. 1930")
        #expect(lens.birthYear(try #require(Self.eileenOrNil())) == 1930)
    }

    /// With no profiles read, nothing changes — a failed read is not
    /// evidence that the tree is right, and must leave it standing.
    @Test func withNoProfilesTheTreesOwnYearStands() throws {
        #expect(HallieVitalDates.Lens.treeOnly.yearsText(try #require(Self.eileenOrNil()))
                == HalliePersonCard.yearsText(try #require(Self.eileenOrNil())))
    }

    /// Tense follows the seam too. A death the People tab records and the
    /// tree does not made Hallie say "is" about someone who had died.
    @Test func aDeathOnlyThePeopleTabKnowsMakesTheTensepast() throws {
        let died = HallieTurnExecutor.ProfileSnapshot(
            stableID: "eileen", canonicalName: "Eileen",
            birthdate: Self.date(1930, 8, 31),
            treeIdentity: .familySearchID("G2CR-R4H"),
            deathdate: Self.date(2023, 6, 1))
        let lens = HallieVitalDates.Lens.make(
            profiles: [HallieVitalProfile(died)], graph: Self.tree)
        #expect(try #require(Self.eileenOrNil()).deathDate == nil, "the tree records no death")
        #expect(lens.deathYear(try #require(Self.eileenOrNil())) == 2023, "the People tab does")
    }
    }

/// The card-versus-prose class, closed for the last two routes carrying it.
///
/// `7dfefcd6` fixed this for `ancestorLine` on 2026-09-06: the spoken
/// sentence read the vital-dates seam while the lineage card drawn beside it
/// still showed the tree's years. Two routes were left behind —
/// `HallieBirthplaceTrail.card` and `HallieLineageQuestion.trailCard` — and
/// in both, `lens` was already in scope and already spent on the prose one
/// or four lines above. Only the card defaulted to `.treeOnly`.
///
/// One turn, two stores, two different answers about the same person, is
/// worse for this product than either value being wrong on its own — the
/// rule codex held the whole vitals batch on.
@Suite("A lineage card never disagrees with the sentence beside it")
struct HallieCardProseAgreementTests {

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

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d
        c.timeZone = TimeZone(identifier: "UTC")
        return HallieVitalDates.utcCalendar.date(from: c)!
    }

    private static func eileenOrNil() -> GedcomFamilyGraph.Person? { tree.people["@I2@"] }

    private static func correctedLens() -> HallieVitalDates.Lens {
        .make(profiles: [HallieVitalProfile(
            HallieTurnExecutor.ProfileSnapshot(
                stableID: "eileen", canonicalName: "Eileen",
                birthdate: date(1930, 8, 31),
                treeIdentity: .familySearchID("G2CR-R4H"),
                surname: "Breen", maidenName: "Latta"))],
              graph: tree)
    }

    /// The precondition. If the stores stop disagreeing these tests stop
    /// testing anything.
    @Test func theStoresDisagreeAboutHerYear() throws {
        #expect(HalliePersonCard.yearsText(try #require(Self.eileenOrNil())) == "b. 1931")
        #expect(Self.correctedLens().yearsText(try #require(Self.eileenOrNil())) == "b. 1930")
    }

    /// A card BUILT WITH the lens speaks the corrected year — this is what
    /// the two fixed call sites now pass.
    @Test func aCardGivenTheLensShowsTheCorrectedYear() throws {
        let card = HalliePersonCard(try #require(Self.eileenOrNil()), lens: Self.correctedLens())
        #expect(card.years == "b. 1930", Comment(rawValue: card.years ?? "nil"))
    }

    /// And the default is still the tree, which is correct for every caller
    /// that genuinely has no profile evidence — a failed read must not
    /// silently become a claim about the tree being right.
    @Test func aCardWithNoLensStillShowsTheTree() throws {
        let card = HalliePersonCard(try #require(Self.eileenOrNil()))
        #expect(card.years == "b. 1931", Comment(rawValue: card.years ?? "nil"))
        #expect(HalliePersonCard(try #require(Self.eileenOrNil()), lens: .treeOnly).years == "b. 1931")
    }

    /// The agreement itself, stated as the invariant rather than as two
    /// separate facts: whatever the sentence says, the card says.
    @Test func theCardAndTheProseUseOneSource() throws {
        let lens = Self.correctedLens()
        let spokenYears = lens.yearsText(try #require(Self.eileenOrNil()))
        let cardYears = HalliePersonCard(try #require(Self.eileenOrNil()), lens: lens).years
        #expect(spokenYears == cardYears,
                Comment(rawValue: "prose \(spokenYears ?? "nil") vs card \(cardYears ?? "nil")"))
    }
    }
