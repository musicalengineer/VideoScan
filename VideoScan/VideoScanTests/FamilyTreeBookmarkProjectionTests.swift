import Foundation
import Testing
@testable import VideoScan

/// Pure production projection used to build the model's cached bookmark rows.
/// These run without an app host; discovery model wiring is tested separately.
@Suite("Family Tree — bookmark row projection")
struct FamilyTreeBookmarkProjectionTests {
    private struct Person: Equatable {
        let id: String
        let name: String
    }

    @Test func storedIDsSelectExactPeopleAndPreserveSidebarOrder() {
        let rows = [Person(id: "first", name: "Alex"), Person(id: "second", name: "Alex"),
                    Person(id: "third", name: "Donna")]
        var marks = FamilyTreeBookmarks()
        marks.toggle("third")
        marks.toggle("second")
        marks.toggle("missing")
        // #expect is Swift Testing's equivalent of an equality assertion;
        // compare the complete ordered result, not just the count.
        #expect(marks.matchingPeople(in: rows, id: \.id) == [rows[1], rows[2]])
        #expect(marks.ids == ["third", "second", "missing"])
    }

    @Test func bookmarkProjectionIntersectsSearchCandidatesAndReactsToToggles() {
        let rows = [Person(id: "first", name: "Alex"), Person(id: "second", name: "Alex"),
                    Person(id: "third", name: "Donna")]
        var marks = FamilyTreeBookmarks()
        marks.toggle("second")
        marks.toggle("third")
        let searchCandidates = rows.filter { $0.name == "Alex" }
        #expect(marks.matchingPeople(in: searchCandidates, id: \.id) == [rows[1]])
        marks.toggle("second")
        #expect(marks.matchingPeople(in: searchCandidates, id: \.id).isEmpty)
        marks.toggle("first")
        #expect(marks.matchingPeople(in: searchCandidates, id: \.id) == [rows[0]])
        #expect(marks.matchingPeople(in: [Person](), id: \.id).isEmpty)
    }

    @Test func replacementPeopleExcludeStaleIDsWithoutMutatingStoredMarks() {
        var marks = FamilyTreeBookmarks()
        marks.toggle("old")
        let replacement = [Person(id: "new", name: "Alex")]
        #expect(marks.matchingPeople(in: replacement, id: \.id).isEmpty)
        #expect(marks.contains("old"))
        #expect(FamilyTreeBookmarks().matchingPeople(in: replacement, id: \.id).isEmpty)
    }

    @Test func projectionUsesOnlyTheExplicitBookmarkStoreDespitePoisonedNeighbour() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FTBookmarkProjection-\(UUID().uuidString)")
        let selected = root.appendingPathComponent("selected")
        let neighbour = root.appendingPathComponent("poison")
        let rows = [Person(id: "selected", name: "Alex"), Person(id: "poison", name: "Donna")]
        var wanted = FamilyTreeBookmarks(), poison = FamilyTreeBookmarks()
        wanted.toggle("selected")
        poison.toggle("poison")
        try wanted.save(to: selected)
        try poison.save(to: neighbour)
        let loaded = FamilyTreeBookmarks.load(from: selected)
        #expect(loaded.matchingPeople(in: rows, id: \.id) == [rows[0]])
        #expect(FamilyTreeBookmarks.load(from: root.appendingPathComponent("missing"))
            .matchingPeople(in: rows, id: \.id).isEmpty)
        #expect(FamilyTreeBookmarks.load(from: neighbour).ids == ["poison"])
    }

    /// Production-scale sensor; run Release for the recorded performance result.
    @Test func hundredThousandRowsProjectWithinHalfASecond() {
        let rows = (0..<100_000).map { Person(id: "I\($0)", name: "Person \($0)") }
        let expected = stride(from: 0, to: 100_000, by: 100).map { rows[$0] }
        var marks = FamilyTreeBookmarks()
        for person in expected.reversed() { marks.toggle(person.id) }
        marks.toggle("orphan")
        let clock = ContinuousClock()
        let start = clock.now
        let projected = marks.matchingPeople(in: rows, id: \.id)
        let elapsed = clock.now - start
        #expect(projected == expected)
        #expect(elapsed < .milliseconds(500), "100k-person bookmark projection took \(elapsed)")
    }
}
