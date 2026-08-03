import Foundation
import Testing
@testable import VideoScan

@Suite("Find & Tag recipe scoring rules")
struct RecipeScoringTests {
    @Test("two-tier face gate pins both pixel boundaries")
    func tierGateBoundaries() {
        var p = RecipeParameters()
        p.recordPx = 25
        p.votePx = 60
        p.smallFaceMinCos = 0.55

        #expect(!RecipeMath.passesTierGate(sidePx: 24, cosine: 1.0, params: p))
        #expect(!RecipeMath.passesTierGate(sidePx: 25, cosine: 0.549, params: p))
        #expect(RecipeMath.passesTierGate(sidePx: 25, cosine: 0.55, params: p))
        #expect(RecipeMath.passesTierGate(sidePx: 59, cosine: 0.55, params: p))
        #expect(RecipeMath.passesTierGate(sidePx: 60, cosine: -1.0, params: p))
    }

    @Test("top-K aggregation is descending, bounded, and empty-safe")
    func topKMean() {
        #expect(RecipeMath.topKMean([], k: 5) == 0)
        #expect(RecipeMath.topKMean([0.9], k: 0) == 0)
        #expect(RecipeMath.topKMean([0.1, 0.9, 0.7, 0.3], k: 2) == 0.8)
        #expect(RecipeMath.topKMean([0.1, 0.9], k: 5) == 0.5)
    }

    @Test("centroid construction rejects invalid vectors and normalizes valid means")
    func centroidConstruction() {
        #expect(RecipeMath.normalizedCentroid(of: []) == nil)
        #expect(RecipeMath.normalizedCentroid(of: [[0, 0]]) == nil)
        #expect(RecipeMath.normalizedCentroid(of: [[1, 0], [1]]) == nil)

        let centroid = RecipeMath.normalizedCentroid(of: [[3, 0], [1, 0]])
        #expect(centroid == [1, 0])
    }

    @Test("clip scoring applies the gate before top-K")
    func clipScoring() {
        var p = RecipeParameters()
        p.recordPx = 25
        p.votePx = 60
        p.smallFaceMinCos = 0.55
        p.topK = 2
        let samples = [
            RecipeFaceSample(sidePx: 24, cosine: 0.99),
            RecipeFaceSample(sidePx: 30, cosine: 0.54),
            RecipeFaceSample(sidePx: 30, cosine: 0.80),
            RecipeFaceSample(sidePx: 60, cosine: 0.20),
            RecipeFaceSample(sidePx: 100, cosine: 0.70),
        ]

        let result = RecipeMath.clipScore(fromSamples: samples, params: p)
        #expect(result.gatedFaces == 3)
        #expect(abs(result.score - 0.75) < 0.000_001)
    }

    @Test("pairwise AUC handles wins, losses, ties, and missing classes")
    func pairwiseAUC() {
        #expect(RecipeMath.pairwiseAUC(positives: [], negatives: [0.1]) == nil)
        #expect(RecipeMath.pairwiseAUC(positives: [0.1], negatives: []) == nil)
        #expect(RecipeMath.pairwiseAUC(positives: [0.9], negatives: [0.1]) == 1)
        #expect(RecipeMath.pairwiseAUC(positives: [0.1], negatives: [0.9]) == 0)
        #expect(RecipeMath.pairwiseAUC(positives: [0.5], negatives: [0.5]) == 0.5)
        #expect(RecipeMath.pairwiseAUC(positives: [0.9, 0.5], negatives: [0.5]) == 0.75)
    }

    @Test("python and native recipe tiers use their own calibrated spaces")
    func engineSpecificTierBoundaries() {
        #expect(VideoScanModel.recipeTier(forScore: 0.55,
                                          recipeID: "recipe-v1-python") == .detected)
        #expect(VideoScanModel.recipeTier(forScore: 0.549,
                                          recipeID: "recipe-v1-python") == .suspected)
        #expect(VideoScanModel.recipeTier(forScore: 0.379,
                                          recipeID: "recipe-v1-python") == .none)

        #expect(VideoScanModel.recipeTier(forScore: 0.46,
                                          recipeID: "recipe-v1-native") == .detected)
        #expect(VideoScanModel.recipeTier(forScore: 0.459,
                                          recipeID: "recipe-v1-native") == .suspected)
        #expect(VideoScanModel.recipeTier(forScore: 0.299,
                                          recipeID: "recipe-v1-native") == .none)

        // Unknown recipe IDs fail closed to the stricter python-space bars.
        #expect(VideoScanModel.recipeTier(forScore: 0.50,
                                          recipeID: "recipe-unknown") == .suspected)
    }

    @Test("batch bridge parses result, readiness, heartbeat, and malformed lines")
    func bridgeProtocolParsing() {
        #expect(FindPersonJob.parseLine("not json") == nil)
        #expect(FindPersonJob.parseLine(#"{"event":"unknown"}"#) == nil)
        #expect(FindPersonJob.parseLine(#"{"event":"ready","clips":7}"#)
                == FindPersonJob.BridgeEvent(kind: .ready(clips: 7)))
        #expect(FindPersonJob.parseLine(#"{"event":"beat","path":"/x/a.mkv"}"#)
                == FindPersonJob.BridgeEvent(kind: .beat, path: "/x/a.mkv"))
        #expect(FindPersonJob.parseLine(
            #"{"event":"result","path":"/x/a.mkv","score":0.47}"#)
            == FindPersonJob.BridgeEvent(kind: .result,
                                         path: "/x/a.mkv", score: 0.47))
        #expect(FindPersonJob.parseLine(
            #"{"event":"result","path":"/x/a.mkv","error":"decode failed"}"#)
            == FindPersonJob.BridgeEvent(kind: .result,
                                         path: "/x/a.mkv", error: "decode failed"))
    }

    @Test("gallery enumeration is deterministic and drops unusable eras")
    func galleryEnumeration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recipe-gallery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let seventies = root.appendingPathComponent("Donna_70s", isDirectory: true)
        let eighties = root.appendingPathComponent("Donna_80s", isDirectory: true)
        let empty = root.appendingPathComponent("Donna_90s", isDirectory: true)
        for directory in [seventies, eighties, empty] {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
        }
        try Data().write(to: seventies.appendingPathComponent("b.jpg"))
        try Data().write(to: seventies.appendingPathComponent("a.jpg"))
        try Data().write(to: seventies.appendingPathComponent("ignored.txt"))
        try Data().write(to: eighties.appendingPathComponent("one.png"))
        try Data().write(to: empty.appendingPathComponent("unusable.jpg"))

        var visited: [String] = []
        let eras = RecipeGallery.buildEraCentroids(galleryRoot: root) { url in
            visited.append(url.lastPathComponent)
            switch url.lastPathComponent {
            case "a.jpg", "b.jpg": return [1, 0]
            case "one.png": return [0, 1]
            default: return nil
            }
        }

        #expect(visited == ["a.jpg", "b.jpg", "one.png", "unusable.jpg"])
        #expect(eras.map(\.era) == ["Donna_70s", "Donna_80s"])
        #expect(eras.map(\.centroid) == [[1, 0], [0, 1]])
    }
}
