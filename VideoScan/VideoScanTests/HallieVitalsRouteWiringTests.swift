import Foundation
import Testing
@testable import VideoScan

/// ROUTE-LEVEL wiring regressions for the HallieVitalDates migration.
///
/// WHY THESE EXIST AND WHY THEY ARE NOT LENS TESTS.
/// The first pass of this migration (6e01da6a) converted `deepAncestors` and
/// `originTrail`, reported "lineage maternal / both -> profile" as fact, and
/// had NOT converted `ancestorLine` — the route the live logs actually
/// implicated. Every `HallieVitalDatesLensTests` case passed throughout,
/// because a unit test of the Lens cannot see a CALL SITE that never calls
/// it. Codex caught it by reading the route.
///
/// So each test here drives the PUBLIC executor with a fixture whose profile
/// and tree deliberately disagree BY YEAR, and asserts the prose, the
/// evidence and the source basis together. Delete any call-site wiring and
/// these go red; that is the whole point of them.
@MainActor
@Suite("Hallie vitals — every route is actually wired to the seam", .serialized)
struct HallieVitalsRouteWiringTests {

    /// `@P1@` is pinned and the stores disagree by three years on birth and
    /// by a month on death — the shape of the live Eileen failure.
    private static let treeText = """
    0 HEAD
    1 _VS_ROOT @P1@
    0 @P1@ INDI
    1 NAME Vera /Stone/
    1 SEX F
    1 BIRT
    2 DATE 31 AUG 1930
    2 PLAC Chelsea, Suffolk, Massachusetts
    1 DEAT
    2 DATE 3 MAR 2023
    1 FAMS @FF1@
    1 _FSFTID VERA-001
    0 @C1@ INDI
    1 NAME Sam /Stone/
    1 SEX M
    1 BIRT
    2 DATE 4 MAR 1959
    1 FAMC @FF1@
    0 @FF1@ FAM
    1 WIFE @P1@
    1 CHIL @C1@
    0 TRLR
    """

    private var graph: GedcomFamilyGraph {
        GedcomFamilyGraph(gedcomText: Self.treeText)
    }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }

    /// Profile says 1933 / 1 June 2023. The tree says 1930 / 3 March 2023.
    private var veraProfile: ArchivistGraphProfileSnapshot {
        ArchivistGraphProfileSnapshot(
            stableID: "vera", canonicalName: "Vera",
            birthdate: day(1933, 8, 31), deathdate: day(2023, 6, 1),
            treeIdentity: .familySearchID("VERA-001"))
    }

    private func execute(
        people: [String],
        operation: ArchivistGraphQuery.Operation,
        profiles: [ArchivistGraphProfileSnapshot]
    ) -> ArchivistGraphResult {
        ArchivistGraphExecutor.execute(
            .init(people: people, operation: operation, relation: nil),
            inputs: .init(graph: graph, profiles: profiles))
    }

    // MARK: operation = birth  ("when was Vera born")

    /// Prose, EVIDENCE and BASIS must agree. Before the 2026-09-06 fix the
    /// prose was wired to the profile while `lifeDateEvidence` still carried
    /// raw GEDCOM and the basis still claimed GEDCOM — an answer citing
    /// evidence that contradicted it.
    @Test func birthRouteSpeaksTheProfileAndItsEvidenceAgrees() throws {
        let r = execute(people: ["Vera"], operation: .birth,
                        profiles: [veraProfile])

        #expect(r.prose.contains("1933"), Comment(rawValue: r.prose))
        #expect(!r.prose.contains("1930"),
                "the tree's year must not be spoken: \(r.prose)")

        let evidence = try #require(r.evidence)
        #expect(evidence.birthDate?.contains("1933") == true,
                "evidence still on raw GEDCOM: \(evidence.birthDate ?? "nil")")

        #expect(r.basisLine.contains("People tab"),
                "the basis must name the store the date came from: \(r.basisLine)")
        #expect(r.basisLine != ArchivistBiographyPolicy.gedcomBasis)
    }

    /// With no profile, nothing changes: the tree stands and the basis is
    /// the plain GEDCOM one. Proves the new path is not always-on.
    @Test func birthRouteIsUnchangedForATreeOnlyPerson() throws {
        let r = execute(people: ["Vera"], operation: .birth, profiles: [])

        #expect(r.prose.contains("1930"), Comment(rawValue: r.prose))
        let evidence = try #require(r.evidence)
        #expect(evidence.birthDate == "31 AUG 1930")
        #expect(r.basisLine == ArchivistBiographyPolicy.gedcomBasis)
    }

    // MARK: operation = death

    @Test func deathRouteSpeaksTheProfileAndItsEvidenceAgrees() throws {
        let r = execute(people: ["Vera"], operation: .death,
                        profiles: [veraProfile])

        #expect(r.prose.contains("June") || r.prose.contains("1 June 2023"),
                Comment(rawValue: r.prose))
        #expect(!r.prose.contains("3 MAR 2023"), Comment(rawValue: r.prose))

        let evidence = try #require(r.evidence)
        #expect(evidence.deathDate?.contains("2023") == true)
        #expect(evidence.deathDate != "3 MAR 2023",
                "evidence still on raw GEDCOM: \(evidence.deathDate ?? "nil")")
        #expect(r.basisLine.contains("People tab"), Comment(rawValue: r.basisLine))
    }

    // MARK: operation = birth-place  ("where was Vera born")

    /// The PLACE stays the tree's (seam rule 4 — only dates are in scope)
    /// while the DATE in the same sentence becomes the profile's, and the
    /// basis says both.
    @Test func birthPlaceRouteKeepsTheTreePlaceAndTakesTheProfileDate() {
        let r = execute(people: ["Vera"], operation: .birthPlace,
                        profiles: [veraProfile])

        #expect(r.prose.contains("Chelsea"), Comment(rawValue: r.prose))
        #expect(r.prose.contains("1933"), Comment(rawValue: r.prose))
        #expect(!r.prose.contains("1930"), Comment(rawValue: r.prose))
        #expect(r.basisLine.contains("People tab"), Comment(rawValue: r.basisLine))
        #expect(r.basisLine.contains("GEDCOM"),
                "the place is still the tree's and the basis must say so")
    }

    // MARK: The lineage card and its prose

    /// `HalliePersonCard` is what BOTH the lineage card and the lineage
    /// sentence read, so wiring the lens here is what keeps them from
    /// disagreeing about one person. This is the surface `ancestorLine`
    /// renders through — the route the first pass missed.
    @Test func personCardYearsFollowTheLensNotTheTree() throws {
        let g = graph
        let person = try #require(g.people["@P1@"])

        let treeCard = HalliePersonCard(person)
        #expect(treeCard.years == "1930–2023", "unlensed card stays on the tree")

        let lens = HallieVitalDates.Lens.make(
            profiles: [HallieVitalProfile(veraProfile)], graph: g)
        let lensed = HalliePersonCard(person, lens: lens)
        #expect(lensed.years == "1933–2023",
                "the lineage card and its sentence both read this value")
        #expect(lensed.years != treeCard.years,
                "if these ever match, the fixture stopped disagreeing and every assertion here passes for the wrong reason")
    }

    // MARK: The ancestorLine ROUTE, end to end

    /// THE TEST THAT WOULD HAVE CAUGHT THE MISS. Drives the lineage route
    /// through `HallieLineageAnswer.answer` with a Context, so a dropped
    /// `lens:` at the `ancestorLine` call site goes red. Verified by
    /// deleting that argument: this fails, and all eight Lens unit tests
    /// still pass — which is exactly how the first pass shipped broken.
    @Test func ancestorLineRouteSpeaksTheProfileYears() throws {
        let ctx = HallieTurnExecutor.Context(
            profiles: [HallieTurnExecutor.ProfileSnapshot(
                stableID: "vera", canonicalName: "Vera",
                birthdate: day(1933, 8, 31),
                treeIdentity: .familySearchID("VERA-001"),
                deathdate: day(2023, 6, 1))],
            graph: graph,
            speakers: .init(ownerName: "Vera", archivistName: "Hallie Mae"))

        // Vera is the ANCESTOR here, not the root: `ancestorLine` renders
        // years for the generations it walks up to, so the pinned person has
        // to be one of them for this to exercise anything.
        let r = try #require(HallieLineageAnswer.answer(
            .ancestorLine(person: "Sam Stone", line: .maternal,
                          generations: 2, untilYear: nil),
            context: ctx))

        #expect(r.prose.contains("1933"), Comment(rawValue: r.prose))
        #expect(!r.prose.contains("1930"), Comment(rawValue: r.prose))
    }

    /// The lineage CARD built by the attachment builder — the exact value
    /// `ancestorLine` renders its prose from.
    @Test func lineageCardRootFollowsTheLens() throws {
        let g = graph
        let person = try #require(g.people["@P1@"])
        let lens = HallieVitalDates.Lens.make(
            profiles: [HallieVitalProfile(veraProfile)], graph: g)

        let card = HallieAttachmentBuilder.lineage(
            of: person, line: .both, generations: 2, in: g, lens: lens)
        #expect(card.root.years == "1933–2023",
                "ancestorLine speaks this: \(card.root.years ?? "nil")")

        let unlensed = HallieAttachmentBuilder.lineage(
            of: person, line: .both, generations: 2, in: g)
        #expect(unlensed.root.years == "1930–2023")
    }
}
