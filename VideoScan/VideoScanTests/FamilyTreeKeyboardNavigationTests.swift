import Foundation
import Testing
@testable import VideoScan

// Sidebar ↑ / ↓ / Return (feature/family-tree-notes-and-nav, 2026-08-26).
// Dimensions per the feature-test checklist:
//   Logic — next/previous/first, top+bottom boundaries, empty list,
//           selection filtered out from under the keys
//   Scale — 20,000-person list: 1,000 keypresses well inside 1.5 s (incl.
//           the per-press scene relayout); a linear scan per press would not be.

private let fixtureGedcom = """
0 HEAD
1 SOUR VideoScanTests
0 @I1@ INDI
1 NAME Amy /Breen/
1 SEX F
0 @I2@ INDI
1 NAME Zed /Breen/
1 SEX M
0 @I3@ INDI
1 NAME Adam /Latta/
1 SEX M
0 @I4@ INDI
1 NAME Nora /Latta/
1 SEX F
0 TRLR
"""

@Suite("Family tree — keyboard navigation")
@MainActor
struct FamilyTreeKeyboardNavigationTests {

    private func liveModel(_ text: String = fixtureGedcom) -> FamilyTreeLiveModel {
        let model = FamilyTreeLiveModel(
            originalsDirectory: URL(fileURLWithPath: "/nonexistent/never-read"))
        model.install(graph: GedcomFamilyGraph(gedcomText: text))
        return model
    }

    @Test func nextAndPreviousWalkTheSortedListWithoutWrapping() {
        let model = liveModel()
        // Sorted: Amy Breen, Zed Breen, Adam Latta, Nora Latta.
        #expect(model.filteredPeople.map(\.name) == ["Amy Breen", "Zed Breen", "Adam Latta", "Nora Latta"])
        #expect(model.selectedID == "@I1@")
        #expect(model.selectedFilteredIndex == 0)

        model.selectPrevious()                       // top boundary: no-op
        #expect(model.selectedID == "@I1@")

        model.selectNext()
        #expect(model.selectedID == "@I2@")
        model.selectNext()
        model.selectNext()
        #expect(model.selectedID == "@I4@")
        #expect(model.selectedFilteredIndex == 3)

        model.selectNext()                           // bottom boundary: no-op
        #expect(model.selectedID == "@I4@")

        model.selectPrevious()
        #expect(model.selectedID == "@I3@")
        #expect(model.selectedPerson?.name == "Adam Latta")
    }

    @Test func returnSelectsTheFirstMatchAndArrowsStayInsideTheFilter() {
        let model = liveModel()
        model.searchText = "latta"
        #expect(model.filteredPeople.map(\.id) == ["@I3@", "@I4@"])
        // Amy is still selected but no longer listed.
        #expect(model.selectedID == "@I1@")
        #expect(model.selectedFilteredIndex == nil)

        #expect(model.selectFirstFiltered())
        #expect(model.selectedID == "@I3@")
        model.selectNext()
        #expect(model.selectedID == "@I4@")
        model.selectNext()
        #expect(model.selectedID == "@I4@")
        model.selectPrevious()
        model.selectPrevious()
        #expect(model.selectedID == "@I3@")
    }

    @Test func arrowKeysLandOnTheFirstRowWhenTheSelectionIsFilteredOut() {
        let model = liveModel()
        model.select("@I2@")
        model.searchText = "latta"
        #expect(model.selectedFilteredIndex == nil)
        model.selectNext()
        #expect(model.selectedID == "@I3@")

        model.select("@I2@")
        model.searchText = "latta"
        model.selectPrevious()
        #expect(model.selectedID == "@I3@")
    }

    @Test func emptyListIsANoOpEverywhere() {
        let model = liveModel()
        model.searchText = "nobody-by-this-name"
        #expect(model.filteredPeople.isEmpty)
        let before = model.selectedID
        model.selectNext()
        model.selectPrevious()
        #expect(!model.selectFirstFiltered())
        #expect(model.selectedID == before)

        // A model that never loaded anything.
        let empty = FamilyTreeLiveModel(
            originalsDirectory: URL(fileURLWithPath: "/nonexistent/never-read"))
        empty.selectNext()
        empty.selectPrevious()
        #expect(!empty.selectFirstFiltered())
        #expect(empty.selectedID == nil)
    }

    @Test func demoTreeNavigatesToo() {
        let model = FamilyTreeLiveModel(
            originalsDirectory: URL(fileURLWithPath: "/nonexistent/never-read"))
        model.install(graph: nil)
        #expect(!model.isLive)
        #expect(model.selectedID == FamilyTreeDemoData.rootID)
        let rootIndex = model.selectedFilteredIndex
        model.selectNext()
        #expect(model.selectedFilteredIndex == rootIndex.map { $0 + 1 })
        model.selectPrevious()
        #expect(model.selectedID == FamilyTreeDemoData.rootID)
    }

    // MARK: Scale — the O(1) guarantee

    @Test func aThousandKeypressesOnTwentyThousandPeopleIsInstant() {
        var text = "0 HEAD\n"
        for i in 1...20_000 {
            text += "0 @I\(i)@ INDI\n1 NAME P\(String(format: "%05d", i)) /Scale/\n1 SEX M\n"
        }
        text += "0 TRLR\n"
        let model = liveModel(text)
        #expect(model.filteredPeople.count == 20_000)
        // Park the selection in the middle so both directions have room.
        model.select("@I10000@")

        let start = ContinuousClock.now
        for _ in 0..<500 { model.selectNext() }
        for _ in 0..<500 { model.selectPrevious() }
        let elapsed = ContinuousClock.now - start
        #expect(model.selectedID == "@I10000@")
        // Each keypress also relayouts the scene (a handful of cards), so
        // the budget is generous; a linear scan of 20k rows per press
        // would be ~20M comparisons and blow well past it.
        #expect(elapsed < .milliseconds(1_500), "1,000 keypresses took \(elapsed)")
    }
}
