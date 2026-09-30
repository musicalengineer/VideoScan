import Foundation
import Testing
@testable import VideoScanCore

/// Walk Tree highlight (Donna 2026-09-29): surname / place checkmarks pick
/// out people on the fan — OR within a group, AND across groups.
@Suite("Tree walk highlight — surnames and places")
struct TreeWalkHighlightTests {
    typealias R = BirthplaceClassifier.BirthRegion

    // Ordinals 0…5; 5 is not visited.
    let surnames = ["Breen", "BREEN ", "McGill", "", "McGill", "Breen"]
    let regions: [R] = [.newEngland, .england, .scotland, .unknown, .newEngland, .ireland]
    let visited = [0, 1, 2, 3, 4]

    @Test func facetsCountOnlyVisitedPeopleAndFoldSpellings() {
        let f = TreeWalkHighlight.facets(visited: visited, surnames: surnames, regions: regions)
        #expect(f.surnames.map(\.key) == ["breen", "mcgill"])
        #expect(f.surnames.map(\.count) == [2, 2], "the unvisited Breen (ordinal 5) is not counted")
        #expect(f.distinctSurnames == 2)
        #expect(!f.surnames.contains { $0.key.isEmpty }, "a blank surname is not a surname")
        #expect(f.regions.first?.key == R.newEngland.rawValue)
        #expect(f.regions.last?.key == R.unknown.rawValue, "Unknown is listed, and listed last")
        #expect(!f.regions.contains { $0.key == R.ireland.rawValue }, "only regions on screen")
    }

    @Test func labelIsTheMostCommonSpelling() {
        let f = TreeWalkHighlight.facets(visited: [0, 1, 2], surnames: ["Breen", "BREEN", "Breen"],
                                         regions: [.england, .england, .england])
        #expect(f.surnames.first?.label == "Breen")
    }

    @Test func surnameLimitCapsTheListButNotTheDistinctCount() {
        let names = (0..<100).map { "Name\($0)" }
        let f = TreeWalkHighlight.facets(visited: Array(0..<100), surnames: names,
                                         regions: Array(repeating: .england, count: 100), surnameLimit: 10)
        #expect(f.surnames.count == 10)
        #expect(f.distinctSurnames == 100)
    }

    @Test func orWithinAGroupAndAcrossGroups() {
        let keys = TreeWalkHighlight.surnameKeys(surnames)
        func lit(_ s: TreeWalkHighlight.Selection) -> [Int] {
            let m = TreeWalkHighlight.mask(visited: visited, selection: s, surnameKeys: keys, regions: regions)
            return zip(visited, m).filter(\.1).map(\.0)
        }
        #expect(lit(.init()) == [], "no checks = no highlight, not everyone lit")
        #expect(lit(.init(surnames: ["breen"])) == [0, 1], "case and spacing fold")
        #expect(lit(.init(surnames: ["breen", "mcgill"])) == [0, 1, 2, 4], "OR within surnames")
        #expect(lit(.init(regions: [R.newEngland.rawValue])) == [0, 4])
        #expect(lit(.init(surnames: ["mcgill"], regions: [R.newEngland.rawValue])) == [4],
                "AND across groups: a McGill born in New England")
        #expect(lit(.init(regions: [R.unknown.rawValue])) == [3], "Unknown place is selectable")
    }

    @Test func outOfRangeOrdinalsNeverMatchOrCrash() {
        let keys = TreeWalkHighlight.surnameKeys(surnames)
        #expect(!TreeWalkHighlight.matches(ordinal: 99, selection: .init(surnames: ["breen"]),
                                           surnameKeys: keys, regions: regions))
        #expect(!TreeWalkHighlight.matches(ordinal: -1, selection: .init(surnames: ["breen"]),
                                           surnameKeys: keys, regions: regions))
    }

    @Test func scaleHundredThousandPeopleWellUnderBudget() {
        let n = 100_000
        let names = (0..<n).map { "Surname\($0 % 3_000)" }
        let regs: [R] = (0..<n).map { R.allCases[$0 % R.allCases.count] }
        let visited = Array(0..<n)
        let clock = ContinuousClock()
        let t = clock.measure {
            let keys = TreeWalkHighlight.surnameKeys(names)
            let f = TreeWalkHighlight.facets(visited: visited, surnames: names, regions: regs)
            let m = TreeWalkHighlight.mask(visited: visited,
                                           selection: .init(surnames: [f.surnames[0].key], regions: [R.england.rawValue]),
                                           surnameKeys: keys, regions: regs)
            #expect(m.count == n)
        }
        // Debug build, loaded CI machine: generous; typical is ~0.2 s.
        #expect(t < .seconds(2), "\(t)")
    }
}
