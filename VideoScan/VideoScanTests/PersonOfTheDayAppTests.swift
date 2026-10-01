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

/// QA P1-A: a LIVING aunt (b. 3 Mar 1948, no death) whose infant's death
/// is recorded. LifeStatus rule 3 presumes her deceased (Hallie's tense
/// rule); a family-facing feature must not.
private let auntRecords = """
0 @I20@ INDI
1 NAME Aunt /Testperson/
1 SEX F
1 BIRT
2 DATE 3 MAR 1948
2 PLAC Sampleville, Middlecounty, Massachusetts, United States
1 FAMS @F20@
0 @I21@ INDI
1 NAME Infant /Testperson/
1 SEX M
1 BIRT
2 DATE 1972
1 DEAT
2 DATE 1972
1 FAMC @F20@
0 @F20@ FAM
1 WIFE @I20@
1 CHIL @I21@
0 TRLR
"""

private func auntGraph() -> GedcomFamilyGraph {
    GedcomFamilyGraph(gedcomText: potdGedcom.replacingOccurrences(of: "0 TRLR", with: auntRecords))
}

/// Two Mary Testpersons 148 years apart (QA P2-B).
private let namesakesGedcom = """
0 HEAD
0 @I12@ INDI
1 NAME Mary /Testperson/
1 BIRT
2 DATE 1850
0 @I99@ INDI
1 NAME Mary /Testperson/
1 BIRT
2 DATE 1702
0 TRLR
"""

/// A one-person tree whose pick differs from potdGraph's.
private let otherGedcom = """
0 HEAD
0 @I50@ INDI
1 NAME Other /Testperson/
1 SEX M
1 BIRT
2 DATE 1801
1 DEAT
2 DATE 1870
0 TRLR
"""

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

    // QA P1-A (privacy): a living person with a deceased descendant.
    @Test func livingPersonWithADeceasedChildIsNeverFeatured() async throws {
        let graph = auntGraph()
        let c = context(graph, now: noon(2027, 3, 3))
        #expect(c.life(id: "@I20@", quick: .livingPrivate) == .livingPrivate)
        let service = PersonOfTheDayService(store: PersonOfTheDayMemoryStore(), calendar: utc(),
                                            now: { noon(2027, 3, 3) })
        let center = PersonOfTheDayCenter(service: service)
        center.debounce = .zero
        center.assetConfiguration = { nil }
        center.refresh(graph: graph, decorations: nil, knowledge: nil, displayNames: [], ownerFamilySearchID: nil)
        await center.waitForPick()
        #expect(center.pick?.personID != "@I20@")
        #expect(center.pick.map { !$0.isLiving } ?? true)
    }

    // QA P3-2: going back to the inputs already computed cancels the
    // pending recompute for the other inputs.
    @Test func revertingToComputedInputsCancelsThePendingRecompute() async throws {
        let service = PersonOfTheDayService(store: PersonOfTheDayMemoryStore(), calendar: utc(),
                                            now: { noon(2026, 10, 2) })
        let center = PersonOfTheDayCenter(service: service)
        center.assetConfiguration = { nil }
        center.debounce = .zero
        center.refresh(graph: potdGraph(), decorations: nil, knowledge: nil, displayNames: [], ownerFamilySearchID: nil)
        await center.waitForPick()
        let first = try #require(center.pick)
        let keyA = center.computedKey
        center.debounce = .milliseconds(200)
        center.refresh(graph: GedcomFamilyGraph(gedcomText: otherGedcom), decorations: nil, knowledge: nil,
                       displayNames: [], ownerFamilySearchID: nil)
        center.refresh(graph: potdGraph(), decorations: nil, knowledge: nil, displayNames: [], ownerFamilySearchID: nil)
        try await Task.sleep(for: .milliseconds(700))
        #expect(center.pick == first, "the superseded recompute must not land")
        #expect(center.computedKey == keyA)
    }

    // QA P3-4: the backstop timer is armed for the next day boundary, and
    // the card keys its refresh on the published day.
    @Test func midnightTimerAimsAtTheNextDayBoundary() throws {
        let late = utc().date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 23, minute: 59, second: 30))!
        #expect(PersonOfTheDayCenter.secondsUntilNextDay(after: late, calendar: utc()) == 31)
        let center = PersonOfTheDayCenter(service: PersonOfTheDayService(store: PersonOfTheDayMemoryStore(),
                                                                         calendar: utc(), now: { late }))
        #expect(center.dayKey == "2026-10-01")
        center.service = PersonOfTheDayService(store: PersonOfTheDayMemoryStore(), calendar: utc(),
                                               now: { noon(2026, 10, 2) })
        center.dayMayHaveChanged()
        #expect(center.dayKey == "2026-10-02")
        let card = try SourceTree.appSource(named: "PersonOfTheDayCard.swift")
        #expect(card.contains("day: center.dayKey"))
        #expect(card.contains("pick.isLiving ? nil"), "no birth flag for a living pick (QA P3-1)")
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
        // living home person is NOT in the credits (Rick 2026-10-01: no
        // living people in Roll Call, not even the inner circle).
        #expect(playback.entries.map(\.id) == ["@I7@", "@I4@"])
        #expect(playback.entries.first?.place == "Exampletown, Ireland")
        #expect(playback.portraits.isEmpty)
        #expect(playback.duration == 20)
        #expect(playback.replay().id != playback.id)
    }

    // QA P2-A: a walk from a selected LIVING relative must not name them
    // (the inner circle is the home people's, not the walk's starts).
    @Test func rollCallFromASelectedLivingRelativeDoesNotNameThem() async throws {
        let graph = potdGraph()
        let result = try TreeWalk.walk(graph, options: .init(starts: ["@I6@"]))
        let visited = result.layers.flatMap { $0 }.map { Int($0.ordinal) }
        let playback = await RollCallPlayback.prepare(result: result, graph: graph, visited: visited,
                                                      knowledge: nil, displayNames: [],
                                                      birthCountries: .empty, assets: nil)
        #expect(!playback.entries.map(\.id).contains("@I6@"))
        #expect(playback.entries.map(\.id).contains("@I4@"))
    }

    // QA P3-1: no birth flag for a living person in the credits.
    @Test func rollCallCarriesNoFlagForALivingPerson() async throws {
        let graph = potdGraph()
        let result = try TreeWalk.walk(graph, options: .init(starts: ["@I1@"]))
        let visited = result.layers.flatMap { $0 }.map { Int($0.ordinal) }
        let ids = ["@I1@", "@I4@", "@I7@"]
        let countries = FamilyTreeBirthCountries.build(ids: ids, treePlaces: ids.map { graph.people[$0]?.birthPlace })
        #expect(countries["@I1@"] != nil, "fixture: the living home person HAS a resolvable birthplace")
        let playback = await RollCallPlayback.prepare(result: result, graph: graph, visited: visited,
                                                      knowledge: nil, displayNames: [],
                                                      birthCountries: countries, assets: nil)
        #expect(!playback.entries.contains { $0.id == "@I1@" })
        #expect(playback.flags["@I1@"] == nil)
        #expect(playback.flags["@I4@"] != nil)
    }

    // Pin (Rick 2026-10-01): no living person appears in the credits — the
    // home person, the spouse, the child (inner circle) and the living
    // cousin alike — whichever living relative the walk starts from.
    @Test func pinNoLivingPersonAppearsInTheCredits() async throws {
        let graph = potdGraph()
        let living = graph.people.values
            .filter { LifeStatus.privacyVerdict($0, in: graph) == .living }
            .map(\.id)
        #expect(Set(living).isSuperset(of: ["@I1@", "@I2@", "@I3@", "@I5@"]), "fixture: four living people")
        for start in ["@I1@", "@I2@", "@I3@", "@I5@", "@I6@"] where graph.people[start] != nil {
            let result = try TreeWalk.walk(graph, options: .init(starts: [start]))
            let visited = result.layers.flatMap { $0 }.map { Int($0.ordinal) }
            for order in RollCall.Order.allCases {
                let playback = await RollCallPlayback.prepare(result: result, graph: graph, visited: visited,
                                                              knowledge: nil, displayNames: ["Home"],
                                                              birthCountries: .empty, assets: nil, order: order)
                #expect(playback.entries.allSatisfy { !$0.isLiving }, "walk from \(start): a living row")
                #expect(Set(playback.entries.map(\.id)).isDisjoint(with: living),
                        "walk from \(start), \(order): a living person was named")
            }
        }
    }

    // QA P2-B: a folder pinned to one record never lends its portrait to
    // a namesake by name.
    @Test func portraitHintNeverLendsAPinnedFolderToANamesake() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("potd-hints-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("People/Mary_Testperson_I12", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF]).write(to: folder.appendingPathComponent("portrait.jpg"))
        let store = FamilyAssetStore(root: root, cacheRoot: root.appendingPathComponent("thumbs"))
        let hints = store.portraitHints()
        let graph = GedcomFamilyGraph(gedcomText: namesakesGedcom)
        #expect(hints.mayHavePortrait(try #require(graph.people["@I12@"])))
        #expect(!hints.mayHavePortrait(try #require(graph.people["@I99@"])))
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
