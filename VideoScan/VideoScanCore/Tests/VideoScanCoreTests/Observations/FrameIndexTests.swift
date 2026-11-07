// FrameIndexTests.swift — the SigLIP 2 frame index (FrameIndex.swift,
// CatalogFrameIndexRows.swift; docs/design/file_dossier_view.md §II.7).
// Streamlined (Rick 11/06: an experiment) — the dimensions that apply:
//   LOGIC      top-k is cosine order, best first, ties by digest then time,
//              k and the per-content cap hold; the cache key carries model,
//              content and time.
//   SCOPE      a row whose content is not in scope is never a hit; the
//              reader returns exactly the scope's contents (removed files
//              only when a selection names them).
//   TRUTH      a hit's (digest, time) is the frame whose vector produced it,
//              through a save and a load.
//   ISOLATION  no folder → notBuilt; a sidecar that does not parse, a
//              truncated matrix, a different model, a non-finite value →
//              unreadable (never a partial answer); a crash between the
//              matrix and the sidecar leaves the old index loadable.
//   RESUME     a builder seeded from disk knows what is done; failures are kept.
// Synthetic digests only.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("FrameIndex")
struct FrameIndexTests {

    static let model = "test/siglip-like"

    static func digest(_ n: Int) -> String { String(format: "%064x", n) }

    /// A unit vector along axis `i` of `d` dims, optionally tilted toward axis `j`.
    static func axis(_ i: Int, _ d: Int = 8, tilt j: Int? = nil, by t: Float = 0) -> [Float] {
        var v = [Float](repeating: 0, count: d)
        v[i] = 1
        if let j { v[j] = t }
        return v
    }

    static func tempRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("frameindex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 3 contents × 2 frames; content 1's second frame points straight at axis 0.
    static func sample() -> FrameIndex {
        var b = FrameIndexBuilder(model: model, dims: 8)
        b.add(digest: digest(1), frames: [(1.0, axis(1)), (2.5, axis(0))])
        b.add(digest: digest(2), frames: [(0.5, axis(0, tilt: 1, by: 0.5)), (3.0, axis(2))])
        b.add(digest: digest(3), frames: [(10.0, axis(0, tilt: 2, by: 1.0)), (11.0, axis(3))])
        return b.snapshot()
    }

    // MARK: Logic

    @Test func topKIsCosineOrderBestFirstAndHonoursKAndThePerContentCap() {
        let index = Self.sample()
        let hits = FrameSearch.topK(query: Self.axis(0), in: index, k: 4)
        #expect(hits.map(\.entry) == [FrameIndexEntry(digest: Self.digest(1), seconds: 2.5),
                                     FrameIndexEntry(digest: Self.digest(2), seconds: 0.5),
                                     FrameIndexEntry(digest: Self.digest(3), seconds: 10.0),
                                     hits[3].entry])
        #expect(abs(hits[0].score - 1) < 1e-5)
        #expect(abs(hits[1].score - 1 / Float(1.25).squareRoot()) < 1e-5, "cosine of (1, 0.5) with (1, 0)")
        #expect(abs(hits[2].score - 1 / Float(2).squareRoot()) < 1e-5)
        #expect(zip(hits, hits.dropFirst()).allSatisfy { $0.score >= $1.score })
        // The query's length does not matter (cosine, not dot).
        #expect(FrameSearch.topK(query: Self.axis(0).map { $0 * 7 }, in: index, k: 4).map(\.entry) == hits.map(\.entry))
        // k and the cap.
        #expect(FrameSearch.topK(query: Self.axis(0), in: index, k: 1).count == 1)
        let capped = FrameSearch.topK(query: Self.axis(0), in: index, k: 6, perContent: 1)
        #expect(capped.count == 3 && Set(capped.map(\.entry.digest)).count == 3, "one frame per content")
        // A query of the wrong size is no hits, never a crash.
        #expect(FrameSearch.topK(query: [1, 0], in: index, k: 3).isEmpty)
        #expect(FrameSearch.topK(query: Self.axis(0), in: .empty(model: Self.model, dims: 8), k: 3).isEmpty)
    }

    @Test func tiesOrderByDigestThenTime() {
        var b = FrameIndexBuilder(model: Self.model, dims: 8)
        b.add(digest: Self.digest(9), frames: [(4, Self.axis(0)), (2, Self.axis(0))])
        b.add(digest: Self.digest(5), frames: [(7, Self.axis(0))])
        let hits = FrameSearch.topK(query: Self.axis(0), in: b.snapshot(), k: 3)
        #expect(hits.map(\.entry) == [FrameIndexEntry(digest: Self.digest(5), millis: 7000),
                                     FrameIndexEntry(digest: Self.digest(9), millis: 2000),
                                     FrameIndexEntry(digest: Self.digest(9), millis: 4000)])
    }

    @Test func theCacheKeyIsModelContentAndMilliseconds() {
        let d = Self.digest(1)
        #expect(FrameIndex.cacheKey(model: "m", digest: d, seconds: 1.2344) == "m|\(d)|1234")
        #expect(FrameIndex.cacheKey(model: "m", digest: d, seconds: 1.2346) == "m|\(d)|1235")
        #expect(FrameIndex.cacheKey(model: "m", digest: d, seconds: 1) != FrameIndex.cacheKey(model: "n", digest: d, seconds: 1), "another model, another vector")
        #expect(FrameIndex.cacheKey(model: "m", digest: d, seconds: 1) != FrameIndex.cacheKey(model: "m", digest: Self.digest(2), seconds: 1))
        #expect(FrameIndex.millis(-3) == 0 && FrameIndex.millis(.nan) == 0)
        #expect(FrameIndexEntry(digest: d, seconds: 2.5).seconds == 2.5)
    }

    // MARK: Scope

    @Test func aRowOutsideTheScopeIsNeverAHit() {
        let index = Self.sample()
        let hits = FrameSearch.topK(query: Self.axis(0), in: index, k: 6, allowed: [Self.digest(2), Self.digest(3)])
        #expect(!hits.isEmpty && hits.allSatisfy { $0.entry.digest != Self.digest(1) }, "content 1 is out of scope")
        #expect(FrameSearch.topK(query: Self.axis(0), in: index, k: 6, allowed: []).isEmpty, "an empty scope finds nothing")
    }

    @Test func theReaderReturnsExactlyTheScopesContents() async throws {
        let (fixture, repository) = try await ObservationsReportTests.scene()
        defer { fixture.remove() }
        let everything = try await repository.read { try $0.frameIndexFiles(.everything) }
        #expect(Set(everything.map(\.digest)) == Set((1...7).map(DossierFixture.hex)), "every live content; the removed one is not the collection")
        #expect(everything.map(\.path) == everything.map(\.path).sorted())
        let folder = try await repository.read { try $0.frameIndexFiles(.folder("/V/tapes")) }
        #expect(Set(folder.map(\.digest)) == Set([1, 2, 3, 6].map(DossierFixture.hex)))
        let picked = try await repository.read { try $0.frameIndexFiles(.files([DossierFixture.fileID(8), DossierFixture.fileID(4)])) }
        #expect(Set(picked.map(\.digest)) == [DossierFixture.hex(4), DossierFixture.hex(8)])
        #expect(picked.first { $0.digest == DossierFixture.hex(8) }?.removed == true, "a selection that names a removed file still shows it, marked")
        let audio = try #require(everything.first { $0.digest == DossierFixture.hex(5) })
        #expect(!audio.hasVideo, "an audio-only file has no frames to index")
        #expect(everything.first { $0.digest == DossierFixture.hex(4) }?.hasVideo == true)
    }

    // MARK: Truth

    @Test func aHitMapsBackToTheFrameThatProducedIt() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // 50 contents × 4 frames, random unit vectors in 64 dims.
        var rng = SystemRandomNumberGenerator()
        var b = FrameIndexBuilder(model: Self.model, dims: 64)
        var made: [(FrameIndexEntry, [Float])] = []
        for n in 0..<50 {
            var frames: [(seconds: Double, vector: [Float])] = []
            for f in 0..<4 {
                let v = (0..<64).map { _ in Float.random(in: -1...1, using: &rng) }
                frames.append((Double(f) * 1.5 + 0.25, v))
                made.append((FrameIndexEntry(digest: Self.digest(n), seconds: Double(f) * 1.5 + 0.25), FrameIndex.normalized(v)))
            }
            b.add(digest: Self.digest(n), frames: frames)
        }
        try FrameIndexStore.save(b.snapshot(), root: root)
        let loaded = try #require(FrameIndexStore.load(root: root, model: Self.model).index)
        #expect(loaded.count == 200)
        for (entry, vector) in made.shuffled().prefix(25) {
            let top = try #require(FrameSearch.topK(query: vector, in: loaded, k: 1).first)
            #expect(top.entry == entry, "the hit names the frame whose vector it is")
            #expect(loaded.entries[top.row] == entry)
            // Float16 on disk: the stored row equals the made one to half precision.
            let stored = Array(loaded.vector(at: top.row))
            #expect(zip(stored, vector).allSatisfy { abs($0 - $1) < 2e-3 })
            #expect(top.score > 0.999)
        }
    }

    // MARK: Isolation

    @Test func aMissingOrBrokenIndexIsNotBuiltOrUnreadableNeverAPartialAnswer() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(FrameIndexStore.load(root: root, model: Self.model) == .notBuilt)
        try FrameIndexStore.save(Self.sample(), root: root)
        #expect(FrameIndexStore.load(root: root, model: Self.model).index?.count == 6)
        #expect(FrameIndexStore.load(root: root, model: "another/model") == .notBuilt, "another model has its own folder")

        let dir = FrameIndexStore.directory(root: root, model: Self.model)
        let sidecar = dir.appendingPathComponent("index.json")
        let good = try Data(contentsOf: sidecar)
        let matrixName = try #require(try JSONSerialization.jsonObject(with: good) as? [String: Any])["vectorsFile"] as? String ?? ""
        let matrix = dir.appendingPathComponent(matrixName)
        let goodMatrix = try Data(contentsOf: matrix)

        // Truncated matrix.
        try goodMatrix.prefix(goodMatrix.count - 2).write(to: matrix)
        guard case .unreadable = FrameIndexStore.load(root: root, model: Self.model) else { Issue.record("a short matrix must be unreadable"); return }
        // A non-finite value (half-float 0x7C00 = +inf).
        var poisoned = goodMatrix
        poisoned[0] = 0x00; poisoned[1] = 0x7C
        try poisoned.write(to: matrix)
        guard case .unreadable = FrameIndexStore.load(root: root, model: Self.model) else { Issue.record("inf must be unreadable"); return }
        try goodMatrix.write(to: matrix)
        // A sidecar that does not parse.
        try Data("{not json".utf8).write(to: sidecar)
        guard case .unreadable = FrameIndexStore.load(root: root, model: Self.model) else { Issue.record("bad JSON must be unreadable"); return }
        // A sidecar from another model in this model's folder.
        let foreign = String(decoding: good, as: UTF8.self).replacingOccurrences(of: Self.model.replacingOccurrences(of: "/", with: "\\/"), with: "other\\/model")
        try Data(foreign.utf8).write(to: sidecar)
        guard case .unreadable = FrameIndexStore.load(root: root, model: Self.model) else { Issue.record("a foreign model must be unreadable"); return }
        try good.write(to: sidecar)
        #expect(FrameIndexStore.load(root: root, model: Self.model).index == Self.sample().roundTripped())
    }

    @Test func aCrashBetweenTheMatrixAndTheSidecarLeavesTheOldIndex() throws {
        let root = try Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FrameIndexStore.save(Self.sample(), root: root)
        let dir = FrameIndexStore.directory(root: root, model: Self.model)
        // The next save writes the OTHER generation first; simulate it dying there with garbage.
        for name in ["vectors-a.f16", "vectors-b.f16"] where !FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
            try Data(repeating: 0xFF, count: 7).write(to: dir.appendingPathComponent(name))
        }
        #expect(FrameIndexStore.load(root: root, model: Self.model).index?.count == 6, "the sidecar still names the intact matrix")
        // And a real second save flips generations and loads.
        var b = FrameIndexBuilder(model: Self.model, dims: 8, seed: FrameIndexStore.load(root: root, model: Self.model).index)
        b.add(digest: Self.digest(4), frames: [(1, Self.axis(4))])
        try FrameIndexStore.save(b.snapshot(), root: root)
        #expect(FrameIndexStore.load(root: root, model: Self.model).index?.count == 7)
    }

    // MARK: Resume

    @Test func aSeededBuilderKnowsWhatIsDoneAndKeepsFailures() throws {
        var b = FrameIndexBuilder(model: Self.model, dims: 8, seed: Self.sample())
        b.fail(digest: Self.digest(7), reason: "ffmpeg decoded 0 of 8 frames")
        #expect(b.isDone(Self.digest(1)) && b.isDone(Self.digest(7)) && !b.isDone(Self.digest(8)))
        b.add(digest: Self.digest(1), frames: [(99, Self.axis(5))])
        #expect(b.frameCount == 6, "a content already indexed is not added twice")
        b.add(digest: Self.digest(8), frames: [(1, Self.axis(5)), (1.0001, Self.axis(6)), (2, [1, 2])])
        #expect(b.frameCount == 7, "same millisecond kept once; a vector of the wrong size is dropped")
        let snap = b.snapshot()
        #expect(snap.failures[Self.digest(7)] == "ffmpeg decoded 0 of 8 frames")
        // A seed from another model is ignored (the vectors would not compare).
        #expect(FrameIndexBuilder(model: "other", dims: 8, seed: snap).frameCount == 0)
    }
}

private extension FrameIndex {
    /// The index as a save/load would return it (vectors rounded to half precision).
    func roundTripped() -> FrameIndex {
        FrameIndex(model: model, dims: dims, entries: entries,
                   vectors: FrameIndexStore.halfToFloat(FrameIndexStore.floatToHalf(vectors), count: vectors.count), failures: failures)
    }
}
