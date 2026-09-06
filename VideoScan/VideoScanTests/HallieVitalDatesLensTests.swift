import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

/// Sensors for `HallieVitalDates.Lens`, the value the lineage, birth-place,
/// birthplace-trail and life-date routes were converted onto 2026-09-06.
///
/// WHY THIS EXISTS. `8f505d38` made the People tab the source of truth for a
/// contemporary person's birth and death dates, and `1575bc83` converted a
/// third route. Four more routes were never converted and went on speaking
/// the family tree. On 2026-09-05, after Rick corrected his mother's profile,
/// the SAME session answered her birth year two ways:
///
///   biography, kinship                     -> the profile   (correct)
///   lineage maternal, lineage both,
///   birth-place, birthplace trail          -> the tree      (wrong)
///
/// DO NOT write a sensor for this against Eileen Latta. Rick re-verified his
/// parents' dates with his brothers and sisters and their obituaries on
/// 2026-09-06 and corrected her profile to match what the tree already said,
/// so the two stores now AGREE about her and any test built on her passes
/// for the wrong reason. Every case below uses a fixture person whose stores
/// genuinely differ.
@Suite("Hallie vital-date lens — the People tab wins on every route")
struct HallieVitalDatesLensTests {

    /// `@I2@` is pinned (`_FSFTID G2S4-JF4`) and the two stores disagree by
    /// one day on birth. `@I9@` is in the tree only, with a deliberately
    /// imprecise birth date. `@I8@` is pinned but its profile records only a
    /// death, so its birth must still come from the tree.
    private static let treeText = """
    0 HEAD
    1 _VS_ROOT @I1@
    0 @I1@ INDI
    1 NAME Richard Harding /Breen/ Jr
    1 SEX M
    1 BIRT
    2 DATE 4 MAR 1959
    1 FAMC @F1@
    1 _FSFTID GVQV-NW3
    0 @I2@ INDI
    1 NAME Richard Harding /Breen/ Sr
    1 SEX M
    1 BIRT
    2 DATE 22 FEB 1929
    1 DEAT
    2 DATE 1 JUL 2008
    1 FAMS @F1@
    1 _FSFTID G2S4-JF4
    0 @I8@ INDI
    1 NAME Partial /Record/
    1 SEX F
    1 BIRT
    2 DATE 3 APR 1901
    1 DEAT
    2 DATE 9 SEP 1980
    1 _FSFTID PART-I01
    0 @I7@ INDI
    1 NAME Yearly /Disagreement/
    1 SEX F
    1 BIRT
    2 DATE 31 AUG 1930
    1 DEAT
    2 DATE 3 MAR 2023
    1 _FSFTID YEAR-D01
    0 @I9@ INDI
    1 NAME Vague /Ancestor/
    1 SEX M
    1 BIRT
    2 DATE ABT 1900
    0 @F1@ FAM
    1 HUSB @I2@
    1 CHIL @I1@
    0 TRLR
    """

    private static let graph = GedcomFamilyGraph(gedcomText: treeText)

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }

    private func profile(
        _ stableID: String, _ name: String, pin: String?,
        birth: Date? = nil, death: Date? = nil
    ) -> HallieVitalProfile {
        HallieVitalProfile(
            stableID: stableID, canonicalName: name,
            treeIdentity: pin.map { .familySearchID($0) },
            birthdate: birth, deathdate: death)
    }

    private func lens(_ profiles: [HallieVitalProfile]?) -> HallieVitalDates.Lens {
        .make(profiles: profiles, graph: Self.graph)
    }

    private func person(_ id: String) -> GedcomFamilyGraph.Person {
        Self.graph.people[id]!
    }

    // MARK: The rule

    /// THE SENSOR, at YEAR granularity — which is the granularity the
    /// lineage and trail routes actually speak.
    ///
    /// The stores disagree by three years, deliberately: `@I7@` reproduces
    /// the shape of the live failure (profile 1933, tree 1930) that Rick's
    /// mother had before he corrected her. An earlier draft of this test used
    /// Dad, whose two stores differ by ONE DAY — and it did not fail when the
    /// lens was regressed to read the tree, because both stores say 1929 and
    /// a year comparison cannot see a day. A sensor that cannot fail is not a
    /// sensor. Verified red by regressing `Lens.birthYear` to `person.birthYear`.
    @Test func profileYearBeatsTheTreeForAPinnedPerson() {
        let l = lens([profile("yearly", "Yearly", pin: "YEAR-D01",
                              birth: day(1933, 8, 31), death: day(2023, 6, 1))])
        let p = person("@I7@")
        #expect(p.birthDate == "31 AUG 1930", "fixture sanity: the tree says 1930")
        #expect(l.birthYear(p) == 1933, "the People tab's year must win")
        #expect(l.deathYear(p) == 2023)
        #expect(l.yearsText(p) == "1933–2023",
                "this is the exact string the lineage route renders")
    }

    /// Day precision survives too: profile 21 February 1929 against the
    /// tree's 22 February 1929, one day apart.
    @Test func profileDayBeatsTheTreeForAPinnedPerson() {
        let l = lens([profile("dad", "Dad", pin: "G2S4-JF4",
                              birth: day(1929, 2, 21))])
        #expect(l.resolved(person("@I2@")).profileBirthdate == day(1929, 2, 21),
                "the People tab's day must win, not the tree's 22 February")
    }

    /// Precedence is PER FIELD. This profile records a death and no birth,
    /// so the death is the profile's and the birth is still the tree's.
    @Test func precedenceIsPerFieldNotPerPerson() {
        let l = lens([profile("partial", "Partial", pin: "PART-I01",
                              death: day(1981, 1, 2))])
        let p = person("@I8@")
        #expect(l.deathYear(p) == 1981, "profile death wins")
        #expect(l.birthYear(p) == 1901, "tree birth stands — profile has none")
        #expect(l.yearsText(p) == "1901–1981")
    }

    // MARK: Never fabricate precision

    /// An imprecise tree date stays imprecise. "ABT 1900" yields the year
    /// 1900 and never a manufactured day — the seam reads the tree's own
    /// recorded STRING, and nothing in this path invents a calendar day the
    /// way the old `date(_ y:)` test helper did.
    @Test func impreciseTreeDateIsNeverGivenAFabricatedDay() {
        let l = lens([profile("dad", "Dad", pin: "G2S4-JF4",
                              birth: day(1929, 2, 21))])
        let vague = person("@I9@")
        #expect(vague.birthDate == "ABT 1900", "fixture sanity")
        #expect(l.birthYear(vague) == 1900)
        #expect(l.resolved(vague).profileBirthdate == nil,
                "no profile owns this person, so no profile date may appear")
        #expect(l.yearsText(vague) == "b. 1900")
    }

    // MARK: Failing closed

    /// `Context.profiles == nil` means profile evidence could not be READ.
    /// That must leave every date exactly as the tree records it. A failed
    /// read is not evidence that the tree is authoritative.
    @Test func unreadableProfilesLeaveTheTreeStanding() {
        let l = lens(nil)
        #expect(l.birthYear(person("@I2@")) == 1929)
        #expect(l.resolved(person("@I2@")) == .none)
        #expect(HallieVitalDates.Lens.treeOnly.resolved(person("@I2@")) == .none)
    }

    /// An ancestor in a rendered line is NOT the subject the question came
    /// through, so an unpinned tree person must never inherit some other
    /// profile's dates just because that profile exists this turn.
    @Test func anUnpinnedAncestorNeverInheritsAnotherProfilesDates() {
        let l = lens([profile("dad", "Dad", pin: "G2S4-JF4",
                              birth: day(1929, 2, 21))])
        let vague = person("@I9@")
        #expect(l.birthYear(vague) == 1900,
                "Dad's 1929 must not leak onto an unrelated ancestor")
        #expect(l.yearsText(vague) != l.yearsText(person("@I2@")))
    }

    /// Two profiles pinning ONE tree person is contested ownership: neither
    /// wins and the tree stands, the same rule `PinOwnership` enforces for
    /// the routes converted earlier.
    @Test func contestedPinLeavesTheTreeStanding() {
        let l = lens([
            profile("dad", "Dad", pin: "G2S4-JF4", birth: day(1929, 2, 21)),
            profile("imposter", "Imposter", pin: "G2S4-JF4", birth: day(1900, 1, 1)),
        ])
        #expect(l.resolved(person("@I2@")).profileBirthdate == nil)
        #expect(l.birthYear(person("@I2@")) == 1929, "the tree's own year")
    }

    // MARK: Shapes

    @Test func yearsTextMatchesTheShapesItReplaced() {
        let l = lens([])
        #expect(l.yearsText(person("@I2@")) == "1929–2008")
        #expect(l.yearsText(person("@I9@")) == "b. 1900")
        #expect(l.yearsText(person("@I1@")) == "b. 1959")
    }
}
