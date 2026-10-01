// PersonOfTheDayAppTests.swift
// The APP side of Person of the Day and Roll Call (2026-10-01). Core's
// selection and list logic is covered in VideoScanCoreTests
// (PersonOfTheDayTests, RollCallTests: logic, 100k scale, poisoned store);
// this suite pins what only the app knows:
//   Logic     — the inner circle (home people + spouses + children) and the
//               life rule over a real graph: a living cousin is never
//               featured, a living inner-circle member only on a birthday,
//               with no years or place.
//   Isolation — the center runs on an injected in-memory store and clock;
//               no App Support file, no defaults, no archive (assets nil).
//   Sensor    — no view file builds candidates or the roll list, and the
//               roll list is built only inside the detached `prepare`.
// Synthetic people only (public repo).

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

/// Home person @I1@ (living, b. 1 Oct 1960) with spouse @I2@ and child
/// @I3@; father @I4@ (b. 1 Oct 1930, d. 2008); father's mother @I7@ (b.
/// 1900, d. 1980, Ireland); sibling @I6@ and the sibling's child @I5@ — a
/// living cousin OUTSIDE the inner circle, also born on 1 October.
private let potdGedcom = """
0 HEAD
1 _VS_ROOT @I1@
0 @I1@ INDI
1 NAME Home /Testowner/
1 SEX M
1 BIRT
2 DATE 1 OCT 1960
2 PLAC Sampleville, Middlecounty, Massachusetts, United States
1 FAMC @F1@
1 FAMS @F2@
0 @I2@ INDI
1 NAME Partner /Testowner/
1 SEX F
1 BIRT
2 DATE 5 MAY 1962
1 FAMS @F2@
0 @I3@ INDI
1 NAME Kid /Testowner/
1 SEX M
1 BIRT
2 DATE 9 JUN 1990
1 FAMC @F2@
0 @I4@ INDI
1 NAME Father /Testowner/
1 SEX M
1 BIRT
2 DATE 1 OCT 1930
2 PLAC Exampletown, Samplecounty, Ireland
1 DEAT
2 DATE 2008
1 FAMC @F4@
1 FAMS @F1@
0 @I5@ INDI
1 NAME Cousin /Testowner/
1 SEX F
1 BIRT
2 DATE 1 OCT 1985
1 FAMC @F3@
0 @I6@ INDI
1 NAME Sibling /Testowner/
1 SEX M
1 BIRT
2 DATE 1958
1 FAMC @F1@
1 FAMS @F3@
0 @I7@ INDI
1 NAME Grandma /Testowner/
1 SEX F
1 BIRT
2 DATE 1900
2 PLAC Exampletown, Samplecounty, Ireland
1 DEAT
2 DATE 1980
1 FAMS @F4@
0 @F1@ FAM
1 HUSB @I4@
1 CHIL @I1@
1 CHIL @I6@
0 @F2@ FAM
1 HUSB @I1@
1 WIFE @I2@
1 CHIL @I3@
0 @F3@ FAM
1 HUSB @I6@
1 CHIL @I5@
0 @F4@ FAM
1 WIFE @I7@
1 CHIL @I4@
0 TRLR
"""

private func potdGraph() -> GedcomFamilyGraph { GedcomFamilyGraph(gedcomText: potdGedcom) }

private func utc() -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}

private func noon(_ y: Int, _ m: Int, _ d: Int) -> Date {
    utc().date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
}

private func context(_ graph: GedcomFamilyGraph, now: Date = noon(2026, 10, 1)) -> FamilyTreeFeatureContext {
    FamilyTreeFeatureContext(graph: graph, decorations: [:], displayNames: ["Home"], knowledge: nil,
                             hints: .none, starts: ["@I1@"], now: now)
}

@Suite("PersonOfTheDayApp")
@MainActor
struct PersonOfTheDayAppTests {

    @Test func innerCircleIsHomeSpouseAndChildren() {
        let c = context(potdGraph())
        #expect(c.innerCircle == ["@I1@", "@I2@", "@I3@"])
    }

    @Test func lifeRuleKeepsLivingCousinsPrivate() {
        let c = context(potdGraph())
        #expect(c.life(id: "@I5@", quick: .livingPrivate) == .livingPrivate)
        #expect(c.life(id: "@I6@", quick: .livingPrivate) == .livingPrivate)
        #expect(c.life(id: "@I3@", quick: .livingInnerCircle) == .livingInnerCircle)
        #expect(c.life(id: "@I4@", quick: .deceased) == .deceased)
        #expect(c.life(id: "@nobody@", quick: .livingPrivate) == .livingPrivate)
    }

    @Test func centerPicksTheDeceasedAnniversaryNeverTheLivingCousin() async throws {
        let store = PersonOfTheDayMemoryStore()
        let service = PersonOfTheDayService(store: store, calendar: utc(), now: { noon(2026, 10, 1) })
        let center = PersonOfTheDayCenter(service: service)
        center.debounce = .zero
        center.assetConfiguration = { nil }
        center.refresh(graph: potdGraph(), decorations: nil, knowledge: nil, displayNames: ["Home"],
                       ownerFamilySearchID: nil)
        await center.waitForPick()
        let pick = try #require(center.pick)
        // Three people were born on 1 October: the deceased father wins;
        // the living home person (inner circle) and the living cousin
        // (private) do not.
        #expect(pick.personID == "@I4@")
        #expect(pick.reason == .bornOnThisDay(yearsAgo: 96))
        #expect(pick.whyToday == "Born 96 years ago today in Exampletown, Ireland")
        #expect(store.load().entry(on: PersonOfTheDay.Day(key: "2026-10-01")!)?.personID == "@I4@")
        #expect(center.opener?.hasPrefix("Today's person is Father Testowner (1930–2008)") == true)
        // The same inputs again: no recomputation, the same pick.
        center.refresh(graph: potdGraph(), decorations: nil, knowledge: nil, displayNames: ["Home"],
                       ownerFamilySearchID: nil)
        await center.waitForPick()
        #expect(center.pick == pick)
        #expect(store.saveCount == 1)
    }

    @Test func noLivingPersonIsFeaturedOnAnOrdinaryDay() async throws {
        for d in 2...20 {
            let service = PersonOfTheDayService(store: PersonOfTheDayMemoryStore(), calendar: utc(),
                                                now: { noon(2026, 10, d) })
            let center = PersonOfTheDayCenter(service: service)
            center.debounce = .zero
            center.assetConfiguration = { nil }
            center.refresh(graph: potdGraph(), decorations: nil, knowledge: nil, displayNames: [],
                           ownerFamilySearchID: nil)
            await center.waitForPick()
            let pick = try #require(center.pick)
            #expect(["@I4@", "@I7@"].contains(pick.personID), "day \(d) featured \(pick.personID)")
            #expect(!pick.isLiving)
        }
    }

    @Test func emptyGraphClearsThePick() async {
        let center = PersonOfTheDayCenter(service: PersonOfTheDayService(store: PersonOfTheDayMemoryStore()))
        center.refresh(graph: nil, decorations: nil, knowledge: nil, displayNames: [], ownerFamilySearchID: nil)
        await center.waitForPick()
        #expect(center.pick == nil)
    }

    @Test func testHostCenterNeverUsesTheRealFile() {
        // The default initialiser in the test host is the in-memory store.
        let center = PersonOfTheDayCenter()
        #expect(center.service.store is PersonOfTheDayMemoryStore)
    }
}

@Suite("RollCallApp")
@MainActor
struct RollCallAppTests {

    @Test func preparedCreditsKeepPrivacyAndOrder() async throws {
        let graph = potdGraph()
        let result = try TreeWalk.walk(graph, options: .init(starts: ["@I1@"]))
        let visited = result.layers.flatMap { $0 }.map { Int($0.ordinal) }
        let playback = await RollCallPlayback.prepare(result: result, graph: graph, visited: visited,
                                                      knowledge: nil, displayNames: ["Home"],
                                                      birthCountries: .empty, assets: nil)
        // Walked: the home person and two ancestors. Oldest first; the
        // living home person has no year, so comes last, with no details.
        #expect(playback.entries.map(\.id) == ["@I7@", "@I4@", "@I1@"])
        let home = try #require(playback.entries.last)
        #expect(home.isLiving && home.years == nil && home.place == nil)
        #expect(playback.entries.first?.place == "Exampletown, Ireland")
        #expect(playback.portraits.isEmpty)
        #expect(playback.duration == 20)
        #expect(playback.replay().id != playback.id)
    }

    @Test func viewsNeverBuildCandidatesOrTheRollList() throws {
        let card = try SourceTree.appSource(named: "PersonOfTheDayCard.swift")
        for forbidden in ["candidates(", "RollCall.build", "LifeStatus", "portraitHints("] {
            #expect(!card.contains(forbidden), "PersonOfTheDayCard must not call \(forbidden)")
        }
        let rollCall = try SourceTree.appSource(named: "FamilyTreeRollCall.swift")
        let builds = rollCall.components(separatedBy: "RollCall.build(").count - 1
        #expect(builds == 1, "the roll list is built once, in prepare")
        let detached = try #require(rollCall.range(of: "Task.detached"))
        let build = try #require(rollCall.range(of: "RollCall.build("))
        #expect(detached.lowerBound < build.lowerBound, "built inside the detached task")
        let map = try SourceTree.appSource(named: "FamilyTreeMapView.swift")
        #expect(!map.contains("RollCall.build"))
    }
}
