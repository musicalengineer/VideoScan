// test: AdvRollCallUndatedLivingParentTests/anUndatedLivingMotherIsNeverInTheCredits
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite @MainActor struct AdvRollCallUndatedLivingParentTests {
    static let gedcom = """
    0 HEAD
    1 _VS_ROOT @I1@
    0 @I1@ INDI
    1 NAME Home /Synthcase/
    1 SEX M
    1 BIRT
    2 DATE 1 OCT 1960
    1 FAMC @F1@
    0 @I2@ INDI
    1 NAME Mother /Synthcase/
    1 SEX F
    1 BIRT
    2 PLAC Exampletown, Samplecounty, Ireland
    1 FAMS @F1@
    0 @I3@ INDI
    1 NAME Infant /Synthcase/
    1 SEX F
    1 BIRT
    2 DATE 1962
    1 DEAT
    2 DATE 1962
    1 FAMC @F1@
    0 @F1@ FAM
    1 WIFE @I2@
    1 CHIL @I1@
    1 CHIL @I3@
    0 TRLR
    """

    @Test func anUndatedLivingMotherIsNeverInTheCredits() async throws {
        let graph = GedcomFamilyGraph(gedcomText: Self.gedcom)
        let mother = try #require(graph.people["@I2@"])
        // Fixture: no death recorded and no birth year — plausibly alive
        // (her son, born 1960, is living).
        #expect(mother.deathDate == nil)
        #expect(GedcomFamilyGraph.year(in: mother.birthDate) == nil)
        let result = try TreeWalk.walk(graph, options: .init(starts: ["@I1@"]))
        let visited = result.layers.flatMap { $0 }.map { Int($0.ordinal) }
        #expect(visited.contains { result.ids[$0] == "@I2@" }, "fixture: the walk visits the mother")
        let seeds: [UInt64?] = [nil, 1, 2, 3]
        for seed in seeds {
            let playback = await RollCallPlayback.prepare(result: result, graph: graph, visited: visited,
                                                          knowledge: nil, displayNames: ["Home"],
                                                          birthCountries: .empty, assets: nil,
                                                          shuffleSeed: seed)
            #expect(!playback.entries.contains { $0.id == "@I2@" },
                    "seed \(String(describing: seed)): a living mother with no dates was named in the credits")
        }
    }
}
