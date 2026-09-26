import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// The Family Tree tab's search through the live model (2026-09-26, Rick:
// "Mary O'Connor finds nothing… a kinda page-rank search for family
// trees"). The pure ranking lives in VideoScanCore (FamilyTreeNameSearch,
// FamilyTreeNameSearchTests); this suite pins what the TAB does with it.
// Dimensions per the feature-test checklist:
//   Logic     — partial / any-order / apostrophe / nickname / fuzzy /
//               ranking through `searchText`, caption, empty query
//   Isolation — poisoned or absent People profiles leave the bias neutral
//   Sensor    — bookmark scope + identity suppression still apply after
//               ranking; the demo tree keeps its substring filter
//   Scale     — 100k people through the bundle: keystroke ceilings
// No media is opened, so no media-matrix dimension.

private let fixtureGedcom = """
0 HEAD
1 SOUR VideoScanTests
0 @I1@ INDI
1 NAME Mary Christina /O'Connor/
1 SEX F
1 BIRT
2 DATE 12 MAY 1904
1 _FSFTID MRYA-904
0 @I2@ INDI
1 NAME Mary /O'Connor/
1 SEX F
1 BIRT
2 DATE ABT 1650
1 _FSFTID MRYA-650
0 @I3@ INDI
1 NAME Gruffudd ap /Einion/
1 SEX M
1 BIRT
2 DATE 1420
0 @I4@ INDI
1 NAME Richard Harding /Breen/
1 SEX M
1 BIRT
2 DATE 21 FEB 1929
0 @I5@ INDI
1 NAME Richard /Breen/
1 SEX M
1 BIRT
2 DATE 1959
0 @I6@ INDI
1 NAME John /Smith/
1 SEX M
1 BIRT
2 DATE 1950
0 @I7@ INDI
1 NAME Ann Mc Gill
1 SEX F
0 @I8@ INDI
1 NAME Mary /Lamb/
1 SEX F
0 TRLR
"""

@Suite("Family tree — ranked name search")
@MainActor
struct FamilyTreeSearchTests {
    private static let settings = FamilyTreeLaunchBundle.Settings(speakers: .none, ownerFamilySearchID: nil)

    private func model(profiles: @escaping () -> [POIProfile] = { [] },
                       originals: URL? = nil,
                       text: String = fixtureGedcom) -> FamilyTreeLiveModel {
        let model = FamilyTreeLiveModel(
            originalsDirectory: originals ?? URL(fileURLWithPath: "/nonexistent/ft-search-tests"),
            noteAuthor: "Test author", profilesProvider: profiles)
        model.install(graph: GedcomFamilyGraph(gedcomText: text), settings: Self.settings)
        return model
    }

    private func ids(_ model: FamilyTreeLiveModel) -> [String] { model.filteredPeople.map(\.id) }

    // MARK: Logic

    @Test func partialNameInAnyOrderWithOrWithoutApostropheFindsMaryChristina() {
        let model = model()
        for query in ["Mary O'Connor", "mary oconnor", "o'connor mary", "connor mary", "Mary Chris O'C"] {
            model.searchText = query
            #expect(ids(model).contains("@I1@"), "\(query) → \(ids(model))")
            #expect(model.searchCaption == nil, "\(query) is an exact hit")
        }
        model.searchText = "Mary Christina O'Connor"
        #expect(ids(model).first == "@I1@")
    }

    @Test func misspelledNameShowsCloseMatchesWithTheCaption() {
        let model = model()
        model.searchText = "Grufudd ap Einon"
        #expect(ids(model) == ["@I3@"])
        #expect(model.searchCaption == "Close matches")
        model.searchText = "Gruffudd ap Einion"
        #expect(ids(model) == ["@I3@"])
        #expect(model.searchCaption == nil)
        // A mix: the exact rows lead, close ones follow, and the caption says so.
        model.searchText = "richard"
        #expect(Set(ids(model)) == ["@I4@", "@I5@"])
        #expect(model.searchCaption == nil)
        model.searchText = "rick"
        #expect(Set(ids(model)) == ["@I4@", "@I5@"])
        #expect(model.searchCaption == "Close matches")
    }

    @Test func unrelatedNamesNeverAppearAndEveryTokenMustMatch() {
        let model = model()
        model.searchText = "Mary O'Connor"
        #expect(!ids(model).contains("@I6@"))
        #expect(!ids(model).contains("@I3@"))
        model.searchText = "mary smith"
        #expect(model.filteredPeople.isEmpty)
        model.searchText = "nobody-by-this-name"
        #expect(model.filteredPeople.isEmpty)
        #expect(model.searchCaption == nil)
    }

    @Test func emptyQueryShowsEveryoneInSidebarOrderWithoutACaption() {
        let model = model()
        model.searchText = "mary"
        #expect(!model.filteredPeople.isEmpty)
        model.searchText = ""
        #expect(model.filteredPeople.count == 8)
        #expect(model.filteredPeople.first?.surname == "Breen")
        #expect(model.searchCaption == nil)
        model.searchText = "   "
        #expect(model.filteredPeople.count == 8)
    }

    @Test func recentBeatsAncientExactBeatsFuzzy() {
        let model = model()
        model.searchText = "richard breen"
        #expect(ids(model) == ["@I5@", "@I4@"], "1959 above 1929, and the shorter name")
        model.searchText = "Mary O'Connor"
        #expect(ids(model).prefix(2).map { $0 } == ["@I2@", "@I1@"], "the whole name typed → that record first, even at 1650")
        model.searchText = "Mary Chris"
        #expect(ids(model) == ["@I1@"])
        model.searchText = "Mc Gill"
        #expect(ids(model) == ["@I7@"])
    }

    // MARK: People tab

    @Test func peopleTabNicknameFindsTheBridgedPersonAndRanksHimFirst() {
        // Fixture has Richard Breen AND Richard Harding Breen; the alias is
        // a complete name, so the bridge resolves exactly one (same rule
        // as `focus(onName:profiles:)`).
        let profiles = [POIProfile(name: "Rick", referencePath: "/synthetic", aliases: ["Richard Breen"])]
        let model = model(profiles: { profiles })
        model.searchText = "rick"
        #expect(ids(model).first == "@I5@")
        #expect(model.searchCaption == "Includes close matches", "Richard Harding Breen fuzzes in below the nickname hit")
        model.searchText = "rick breen"
        #expect(ids(model).first == "@I5@")
    }

    @Test func peopleTabProfileBeatsA1600sNamesake() {
        // "Mary O'Connor" is the 1650 record's whole name (she leads
        // unaided); the People-tab profile on Mary Christina wins anyway.
        var pinned = POIProfile(name: "Mary", referencePath: "/synthetic")
        pinned.treeIdentity = .familySearchID("MRYA-904")
        let model = model(profiles: { [pinned] })
        model.searchText = "Mary O'Connor"
        #expect(ids(model).prefix(2).map { $0 } == ["@I1@", "@I2@"], "the profile's Mary leads: \(ids(model))")
        // Slightly: an exact hit still beats her when she only prefixes.
        model.searchText = "mary lamb"
        #expect(ids(model).first == "@I8@")
    }

    @Test func profileChangesAreSeenOnTheNextKeystroke() {
        var current: [POIProfile] = []
        let model = model(profiles: { current })
        model.searchText = "Mary O'Connor"
        #expect(ids(model).prefix(2).map { $0 } == ["@I2@", "@I1@"])
        var pinned = POIProfile(name: "Mary", referencePath: "/synthetic")
        pinned.treeIdentity = .familySearchID("MRYA-904")
        current = [pinned]
        model.searchText = "Mary O'Connor "
        #expect(ids(model).prefix(2).map { $0 } == ["@I1@", "@I2@"])
    }

    // MARK: Isolation

    @Test func poisonedOrAbsentProfilesLeaveTheBiasNeutral() {
        let neutral = model()
        neutral.searchText = "Mary O'Connor"
        let expected = ids(neutral)

        var stalePin = POIProfile(name: "Mary", referencePath: "/synthetic")
        stalePin.treeIdentity = .familySearchID("ZZZZ-999")          // not in this tree
        var stalePointer = POIProfile(name: "Mary O'Connor", referencePath: "/synthetic")
        stalePointer.treeIdentity = .pointer(pointer: "@I2@", sourceFingerprint: "another-export")
        let empty = POIProfile(name: "", referencePath: "/synthetic", aliases: ["mary"])
        let ambiguous = POIProfile(name: "Mary", referencePath: "/synthetic") // three records carry it
        let poisoned = model(profiles: { [stalePin, stalePointer, empty, ambiguous] })
        poisoned.searchText = "Mary O'Connor"
        #expect(ids(poisoned) == expected, "no profile bridged anyone, so nothing moved: \(ids(poisoned))")
        #expect(poisoned.searchCaption == neutral.searchCaption)
    }

    // MARK: Sensors — scope and suppression still apply after ranking

    @Test func bookmarkScopeIntersectsTheRankedList() {
        let model = model()
        model.toggleBookmark("@I2@")
        model.showsBookmarkedPeopleOnly = true
        model.searchText = "Mary O'Connor"
        #expect(ids(model) == ["@I2@"])
        model.searchText = "Grufudd"
        #expect(model.filteredPeople.isEmpty)
        model.showsBookmarkedPeopleOnly = false
        #expect(ids(model) == ["@I3@"])
    }

    @Test func hiddenDuplicateStaysOutOfTheRankedList() throws {
        // A ruling saves beside the GEDCOM first, so give this model a
        // writable scratch directory (nothing else is read from it).
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FTSearchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let model = model(originals: scratch)
        model.searchText = "Mary O'Connor"
        #expect(ids(model).contains("@I2@"))
        #expect(model.setRecordHidden(true, personID: "@I2@"))
        model.searchText = "Mary O'Connor "
        #expect(!ids(model).contains("@I2@"))
        #expect(ids(model).contains("@I1@"))
    }

    @Test func demoTreeKeepsItsSubstringFilter() {
        let model = FamilyTreeLiveModel(
            originalsDirectory: URL(fileURLWithPath: "/nonexistent/ft-search-tests"),
            noteAuthor: "Test author", profilesProvider: { [] })
        model.install(graph: nil, settings: Self.settings)
        #expect(!model.isLive)
        let someone = FamilyTreeDemoData.people[0]
        model.searchText = String(someone.name.dropFirst().prefix(3))
        #expect(model.filteredPeople.contains { $0.id == someone.id })
        #expect(model.searchCaption == nil)
    }

    @Test func returnPicksTheTopRankedRow() {
        let model = model()
        model.searchText = "richard breen"
        #expect(model.selectFirstFiltered())
        #expect(model.selectedID == "@I5@")
    }

    // MARK: Scale — through the bundle, as production installs

    @Test func hundredThousandPeopleKeystrokesStayUnderTheCeiling() {
        let graph = GedcomFamilyGraph(gedcomText: GedcomSyntheticPedigree.gedcom(people: 100_000))
        let bundle = FamilyTreeLaunchBundle.build(graph: graph, settings: Self.settings)
        let model = FamilyTreeLiveModel(
            originalsDirectory: URL(fileURLWithPath: "/nonexistent/ft-search-tests"),
            noteAuthor: "Test author", profilesProvider: { [] })
        model.install(graph: graph, bundle: bundle, settings: Self.settings)
        #expect(model.peopleCount == 100_000)
        let clock = ContinuousClock()
        func medianMS(_ body: () -> Void) -> Double {
            var samples: [Double] = []
            for _ in 0..<5 {
                let start = clock.now
                body()
                samples.append(TimingBudget.seconds(clock.now - start) * 1_000)
            }
            return samples.sorted()[2]
        }
        let exact = medianMS { model.searchText = "mary breen"; model.searchText = "mary bree" } / 2
        #expect(model.filteredPeople.count > 10)
        #expect(model.searchCaption == nil)
        let fuzzy = medianMS { model.searchText = "Elizabth Bradfrod"; model.searchText = "Elizabth Bradfro" } / 2
        #expect(model.searchCaption == "Close matches")
        #expect(!model.filteredPeople.isEmpty)
        print("SCALE[\(PerformanceLane.configurationName)] 100k tab search: exact keystroke \(exact) ms, fuzzy keystroke \(fuzzy) ms")
        let exactCeiling = PerformanceLane.loadAwareDebugCeiling(PerformanceLane.isDebugBuild ? .milliseconds(400) : .milliseconds(30))
        let fuzzyCeiling = PerformanceLane.loadAwareDebugCeiling(PerformanceLane.isDebugBuild ? .milliseconds(1_500) : .milliseconds(150))
        #expect(exact < TimingBudget.seconds(exactCeiling) * 1_000, "exact keystroke \(exact) ms (\(PerformanceLane.loadDescription()))")
        #expect(fuzzy < TimingBudget.seconds(fuzzyCeiling) * 1_000, "fuzzy keystroke \(fuzzy) ms (\(PerformanceLane.loadDescription()))")
        model.searchText = ""
        #expect(model.filteredPeople.count == 100_000)
    }
}
