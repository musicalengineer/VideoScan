import Testing
@testable import VideoScanCore

@Suite("FamilyMap blank birthplace regressions")
struct FamilyMapWhitespaceAdversarialTests {
    @Test(arguments: ["\u{00A0}", "\u{2003}"])
    func unicodeWhitespaceIsNotARecordedBirthplace(_ blank: String) throws {
        let people = FamilyMapTally.People(
            ids: ["I1"], names: ["Mary"], surnames: ["Breen"],
            birthYears: [nil], generations: [1], lines: [.first],
            unitKeys: [nil], recordedPlaces: [blank])
        let result = try FamilyMapTally.counts(people: people, visited: [0])
        #expect(result.totals.unsupported == 0)
        #expect(result.totals.noRecordedPlace == 1)
    }
}
