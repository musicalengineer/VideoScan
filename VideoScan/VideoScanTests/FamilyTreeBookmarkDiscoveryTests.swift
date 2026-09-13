import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// Actual model tests: bookmarks narrow the sidebar without changing its
// stable-ID navigation or hiding the selected person's family on the canvas.
// Logic/isolation/sensor coverage below; the 100k case is the scale sensor.
// No media files are opened, so the media matrix does not apply.
@Suite("Family Tree — find bookmarked people")
@MainActor
struct FamilyTreeBookmarkDiscoveryTests {
    private static let settings = FamilyTreeLaunchBundle.Settings(
        speakers: .none, ownerFamilySearchID: nil)

    private static let tree = """
    0 HEAD
    1 SOUR VideoScanTests
    1 _VS_ROOT @I1@
    0 @I1@ INDI
    1 NAME Alex /Breen/
    1 FAMS @F1@
    0 @I2@ INDI
    1 NAME Donna /Hudson/
    1 FAMS @F1@
    0 @I3@ INDI
    1 NAME Alex /Breen/
    0 @I4@ INDI
    1 NAME Élodie /Breen/
    0 @F1@ FAM
    1 HUSB @I1@
    1 WIFE @I2@
    0 TRLR
    """

    private func model(originals: URL? = nil, bookmarks: URL? = nil,
                       followSource: Bool = false) -> FamilyTreeLiveModel {
        FamilyTreeLiveModel(
            originalsDirectory: originals ?? URL(fileURLWithPath: "/nonexistent/ft-bookmark-tests"),
            noteAuthor: "Test author", bookmarksDirectory: bookmarks,
            bookmarksFollowSource: followSource, profilesProvider: { [] })
    }

    private func install(_ model: FamilyTreeLiveModel, text: String = Self.tree) {
        model.install(graph: GedcomFamilyGraph(gedcomText: text), settings: Self.settings)
    }

    private func scratch() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FTBookmarkDiscovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func bookmarksIntersectNameSurnameAndIDSearchWithoutChangingOrder() {
        let model = model()
        install(model)
        let allIDs = model.filteredPeople.map(\.id)
        model.toggleBookmark("@I2@")
        model.toggleBookmark("@I3@")
        model.toggleBookmark("@I4@")
        #expect(!model.showsBookmarkedPeopleOnly)
        #expect(model.filteredPeople.map(\.id) == allIDs)
        #expect(model.bookmarkedPeopleCount == 3)

        model.showsBookmarkedPeopleOnly = true
        #expect(model.filteredPeople.map(\.id) == allIDs.filter { $0 != "@I1@" })
        model.searchText = "  bReEn  "
        #expect(Set(model.filteredPeople.map(\.id)) == ["@I3@", "@I4@"])
        model.searchText = "ÉLODIE"
        #expect(model.filteredPeople.map(\.id) == ["@I4@"])
        model.searchText = "I2"
        #expect(model.filteredPeople.map(\.id) == ["@I2@"])
        #expect(model.bookmarkedPeopleCount == 3, "count describes this tree's bookmarks, not text matches")
        model.showsBookmarkedPeopleOnly = false
        #expect(model.searchText == "I2", "scope changes preserve the user's query")
    }

    @Test func storedBookmarkSelectsTheExactSameNamedPersonAndCentersTheirCard() throws {
        let root = try scratch()
        var marks = FamilyTreeBookmarks()
        marks.toggle("@I3@")
        try marks.save(to: root)
        let model = model(originals: root, bookmarks: root)
        install(model)
        #expect(model.selectedID == "@I1@")
        model.showsBookmarkedPeopleOnly = true
        #expect(model.filteredPeople.map(\.id) == ["@I3@"])
        #expect(model.selectFirstFiltered())
        #expect(model.selectedID == "@I3@", "same display name must never substitute the other Alex")
        #expect(model.scene.cards.first(where: \.isRoot)?.person.id == "@I3@")
    }

    @Test func removingAndAddingBookmarksRefreshesTheActiveFilterAndKeyboardRows() {
        let model = model()
        install(model)
        model.toggleBookmark("@I2@")
        model.toggleBookmark("@I3@")
        model.showsBookmarkedPeopleOnly = true
        model.select("@I3@")
        #expect(!model.toggleBookmark("@I3@"))
        #expect(model.filteredPeople.map(\.id) == ["@I2@"])
        #expect(model.bookmarkedPeopleCount == 1)
        #expect(model.selectedID == "@I3@", "unmarking must not jump the canvas to a different relative")
        #expect(model.selectFirstFiltered())
        #expect(model.selectedID == "@I2@")
        model.searchText = "Breen"
        #expect(model.filteredPeople.isEmpty)
        #expect(model.toggleBookmark("@I4@"))
        #expect(model.filteredPeople.map(\.id) == ["@I4@"])
        #expect(model.selectFirstFiltered())
        #expect(model.selectedID == "@I4@")
    }

    @Test func emptyBookmarksAndNoSearchMatchesNeverFallBackToAllPeople() {
        let model = model()
        install(model)
        model.showsBookmarkedPeopleOnly = true
        #expect(model.filteredPeople.isEmpty)
        #expect(model.bookmarkedPeopleCount == 0)
        #expect(!model.selectFirstFiltered())
        #expect(model.selectedID == "@I1@")
        model.toggleBookmark("@I2@")
        model.searchText = "missing relative"
        #expect(model.filteredPeople.isEmpty)
        #expect(!model.selectFirstFiltered())
        model.searchText = ""
        #expect(model.filteredPeople.map(\.id) == ["@I2@"])
    }

    @Test func filterPreservesUnbookmarkedRelativesOnTheSelectedPersonsCanvas() {
        let model = model()
        install(model)
        model.toggleBookmark("@I2@")
        model.showsBookmarkedPeopleOnly = true
        model.select("@I2@")
        #expect(model.filteredPeople.map(\.id) == ["@I2@"])
        #expect(model.scene.cards.contains { $0.person.id == "@I1@" },
                "bookmarks filter the people list, not the selected person's family relationships")
    }

    @Test func orphanBookmarksStayStoredButCannotBecomeRowsAfterGraphReplacement() {
        let model = model()
        model.toggleBookmark("@missing@")
        model.toggleBookmark("@I2@")
        install(model)
        model.showsBookmarkedPeopleOnly = true
        #expect(model.bookmarkedPeopleCount == 1)
        #expect(model.filteredPeople.map(\.id) == ["@I2@"])
        install(model, text: "0 HEAD\n1 _VS_ROOT @new@\n0 @new@ INDI\n1 NAME New /Tree/\n0 TRLR")
        #expect(model.bookmarkedPeopleCount == 0)
        #expect(model.filteredPeople.isEmpty)
        #expect(model.bookmarks.ids == ["@missing@", "@I2@"], "discovery must not delete orphaned stored bookmarks")
    }

    @Test func externalFocusRevealsUnbookmarkedTargetsAndMissSuggestions() {
        let model = model()
        install(model)
        model.toggleBookmark("@I2@")
        model.showsBookmarkedPeopleOnly = true
        #expect(model.focus(onID: "@I2@"))
        #expect(model.showsBookmarkedPeopleOnly)
        #expect(model.focus(onID: "@I4@"))
        #expect(!model.showsBookmarkedPeopleOnly)
        #expect(model.selectedID == "@I4@")
        model.showsBookmarkedPeopleOnly = true
        #expect(!model.focus(onName: "Absent Relative", profiles: []))
        #expect(!model.showsBookmarkedPeopleOnly)
        #expect(model.filteredPeople.isEmpty)
        model.showsBookmarkedPeopleOnly = true
        model.reportMissingRecord(id: "@old-alex@", displayName: "Alex Breen")
        #expect(!model.showsBookmarkedPeopleOnly)
        #expect(Set(model.filteredPeople.map(\.id)) == ["@I1@", "@I3@"])
        #expect(model.selectedID == nil, "a missing record must not silently select a same-named person")
    }

    @Test func sourceSwitchCannotProjectNewBookmarksOntoTheOldTree() throws {
        let root = try scratch()
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        let poison = root.appendingPathComponent("poison")
        var firstMarks = FamilyTreeBookmarks(), secondMarks = FamilyTreeBookmarks()
        firstMarks.toggle("@I2@")
        secondMarks.toggle("@I3@")
        try firstMarks.save(to: first)
        try secondMarks.save(to: second)
        // A legacy directory is selected only when it contains a GEDCOM.
        try Self.tree.write(to: first.appendingPathComponent("family.ged"),
                            atomically: true, encoding: .utf8)
        try Self.tree.write(to: second.appendingPathComponent("family.ged"),
                            atomically: true, encoding: .utf8)
        var unrelated = FamilyTreeBookmarks()
        unrelated.toggle("@I1@")
        try unrelated.save(to: poison)
        let model = model(originals: first, bookmarks: first, followSource: true)
        #expect(!model.bookmarkListIsAvailable)
        install(model)
        #expect(model.bookmarkListIsAvailable)
        model.showsBookmarkedPeopleOnly = true
        #expect(model.filteredPeople.map(\.id) == ["@I2@"])
        model.configure(source: FamilyAssetConfiguration(
            roots: FamilyAssetStore.Roots(assets: root.appendingPathComponent("assets"),
                                          thumbnailCache: root.appendingPathComponent("cache")),
            access: .readWrite, legacyGEDCOMDirectory: second))
        #expect(!model.bookmarkListIsAvailable)
        #expect(model.filteredPeople.isEmpty, "until replacement installs, old pointers belong to the old source")
        #expect(model.bookmarkedPeopleCount == 0)
        model.toggleBookmark("@I1@")
        #expect(FamilyTreeBookmarks.load(from: second).ids == secondMarks.ids)
        install(model)
        #expect(model.bookmarkListIsAvailable)
        #expect(model.filteredPeople.map(\.id) == ["@I3@"])
        #expect(model.bookmarkedPeopleCount == 1)
        #expect(model.bookmarks.ids == ["@I3@"], "neighbouring stores must not contaminate the selected source")
        #expect(FamilyTreeBookmarks.load(from: first).ids == firstMarks.ids)
        #expect(FamilyTreeBookmarks.load(from: poison).ids == unrelated.ids)
        model.configure(source: FamilyAssetConfiguration(
            roots: FamilyAssetStore.Roots(assets: root.appendingPathComponent("assets"),
                                          thumbnailCache: root.appendingPathComponent("cache")),
            access: .unavailable, legacyGEDCOMDirectory: second))
        model.loadNow()
        #expect(!model.bookmarkListIsAvailable)
        #expect(model.filteredPeople.isEmpty)
        #expect(model.bookmarkedPeopleCount == 0)
    }

    /// Run in Release for a production performance baseline. The bounded
    /// workload measures scope/search updates, excluding GEDCOM construction.
    @Test func hundredThousandPeopleKeepBookmarkFilteringWithinTwoSeconds() {
        var lines = ["0 HEAD", "1 _VS_ROOT @I0@"]
        lines.reserveCapacity(200_003)
        for index in 0..<100_000 {
            lines.append("0 @I\(index)@ INDI")
            lines.append("1 NAME Person\(index) /Synthetic/")
        }
        lines.append("0 TRLR")
        let model = model()
        for index in stride(from: 0, to: 100_000, by: 1_000) {
            model.toggleBookmark("@I\(index)@")
        }
        install(model, text: lines.joined(separator: "\n"))
        #expect(model.peopleCount == 100_000)
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<25 {
            model.showsBookmarkedPeopleOnly = true
            #expect(model.filteredPeople.count == 100)
            model.searchText = "Person99000"
            #expect(model.filteredPeople.map(\.id) == ["@I99000@"])
            model.searchText = ""
            model.showsBookmarkedPeopleOnly = false
            #expect(model.filteredPeople.count == 100_000)
        }
        let elapsed = clock.now - start
        #expect(elapsed < .seconds(2), "100k-person scope/search updates took \(elapsed)")
    }
}
