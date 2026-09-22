import Testing
import Foundation
@testable import VideoScan

// MARK: - CombineOutputPublishTests
//
// Logic + scale tests for the no-clobber publish Combine uses (see
// CombineOutputPublish.swift and CombineNeverOverwritesTests for the
// end-to-end ffmpeg cases). All files are `test_` prefixed in a per-test
// temp dir.

@Suite(.serialized) @MainActor
struct CombineOutputPublishTests {

    static func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_combine_publish_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func names(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    // MARK: partial naming

    @Test func partial_isBesideDestination_keepsExtension_andIsRecognised() {
        let final = URL(fileURLWithPath: "/Volumes/X/out/test_clip_combined.mov")
        let a = CombineOutputPublish.uniquePartialURL(for: final)
        let b = CombineOutputPublish.uniquePartialURL(for: final)
        #expect(a != b)
        #expect(a.deletingLastPathComponent() == final.deletingLastPathComponent())
        #expect(a.pathExtension == "mov")
        #expect(a.lastPathComponent.hasPrefix("test_clip_combined."))
        #expect(CombineOutputPublish.isPartialName(a.lastPathComponent))
        // A final name — or a lookalike — is never a partial.
        #expect(!CombineOutputPublish.isPartialName("test_clip_combined.mov"))
        #expect(!CombineOutputPublish.isPartialName("test_clip_combined 2.mov"))
        #expect(!CombineOutputPublish.isPartialName("vs-partial.mov"))
        #expect(!CombineOutputPublish.isPartialName("test.notahex!.vs-partial.mov"))
    }

    @Test func reservePartial_createsAnEmptyExclusiveFile() throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let final = dir.appendingPathComponent("test_clip_combined.mov")
        let reserved = try (0..<50).map { _ in try CombineOutputPublish.reservePartial(for: final) }
        #expect(Set(reserved).count == 50, "two reservations shared a name")
        for url in reserved {
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
            #expect(size == 0)
        }
        #expect(!FileManager.default.fileExists(atPath: final.path))
    }

    @Test func removePartial_refusesAFinalName() throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let final = dir.appendingPathComponent("test_clip_combined.mov")
        try Data("keep me".utf8).write(to: final)
        #expect(throws: CombineOutputPublish.Failure.self) {
            try CombineOutputPublish.removePartial(final)
        }
        #expect(FileManager.default.fileExists(atPath: final.path))

        let partial = try CombineOutputPublish.reservePartial(for: final)
        try CombineOutputPublish.removePartial(partial)
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        try CombineOutputPublish.removePartial(partial)   // already gone = fine
    }

    // MARK: publish

    @Test func publish_freeName_takesIt() throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let final = dir.appendingPathComponent("test_clip_combined.mov")
        let partial = try CombineOutputPublish.reservePartial(for: final)
        try Data("new".utf8).write(to: partial)
        let outcome = try CombineOutputPublish.publish(partial: partial.path, as: final)
        #expect(outcome == .published(final))
        #expect(try Data(contentsOf: final) == Data("new".utf8))
        #expect(Self.names(in: dir) == ["test_clip_combined.mov"])
    }

    @Test func publish_takenNames_goBeside_andNeverTouchExisting() throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let final = dir.appendingPathComponent("test_clip_combined.mov")
        let two = dir.appendingPathComponent("test_clip_combined 2.mov")
        try Data("original".utf8).write(to: final)
        try Data("second".utf8).write(to: two)

        let partial = try CombineOutputPublish.reservePartial(for: final)
        try Data("new".utf8).write(to: partial)
        let outcome = try CombineOutputPublish.publish(partial: partial.path, as: final)
        let three = dir.appendingPathComponent("test_clip_combined 3.mov")
        guard case .publishedBeside(let url, let kept, _) = outcome else {
            Issue.record("expected publishedBeside, got \(outcome)"); return
        }
        #expect(url == three)
        #expect(kept == final)
        #expect(try Data(contentsOf: final) == Data("original".utf8))
        #expect(try Data(contentsOf: two) == Data("second".utf8))
        #expect(try Data(contentsOf: three) == Data("new".utf8))
    }

    @Test func publish_missingPartial_throws_andTouchesNothing() throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let final = dir.appendingPathComponent("test_clip_combined.mov")
        try Data("original".utf8).write(to: final)
        let ghost = CombineOutputPublish.uniquePartialURL(for: final)
        #expect(throws: CombineOutputPublish.Failure.self) {
            _ = try CombineOutputPublish.publish(partial: ghost.path, as: final)
        }
        #expect(try Data(contentsOf: final) == Data("original".utf8))
    }

    @Test func publish_concurrentPartials_neverShareAFinalName() async throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let final = dir.appendingPathComponent("test_clip_combined.mov")
        let n = 24
        var partials: [URL] = []
        for i in 0..<n {
            let p = try CombineOutputPublish.reservePartial(for: final)
            try Data("payload \(i)".utf8).write(to: p)
            partials.append(p)
        }
        let urls = await withTaskGroup(of: URL?.self) { group in
            for p in partials {
                group.addTask { try? CombineOutputPublish.publish(partial: p.path, as: final).url }
            }
            var out: [URL] = []
            for await u in group { if let u { out.append(u) } }
            return out
        }
        #expect(urls.count == n)
        #expect(Set(urls).count == n, "two publishes landed on one name")
        #expect(Self.names(in: dir).count == n)
        #expect(!Self.names(in: dir).contains { $0.contains("vs-partial") })
    }

    // MARK: prior-output map (the only valid "already done" signal)

    static func combined(dir: String, name: String, group: UUID?) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.directory = dir
        r.fullPath = (dir as NSString).appendingPathComponent(name)
        r.combinedFromPairID = group
        return r
    }

    @Test func priorCombinedOutputs_matchesOnlyThisFolderAndPairGroup() {
        let g1 = UUID(), g2 = UUID()
        let out = URL(fileURLWithPath: "/Volumes/X/out")
        let recs = [
            Self.combined(dir: "/Volumes/X/out", name: "test_a_combined.mov", group: g1),
            Self.combined(dir: "/Volumes/X/elsewhere", name: "test_b_combined.mov", group: g2),
            Self.combined(dir: "/Volumes/X/out", name: "test_c_combined.mov", group: nil),
        ]
        let map = VideoScanModel.priorCombinedOutputs(records: recs, outputFolder: out)
        #expect(map == [g1: "/Volumes/X/out/test_a_combined.mov"])
    }

    /// Scale: one pass per batch over a 100k catalog stays well inside a
    /// click's budget (it runs on the main actor when Combine starts).
    @Test func priorCombinedOutputs_100kRecords_underBudget() {
        let out = URL(fileURLWithPath: "/Volumes/X/out")
        var recs: [VideoRecord] = []
        recs.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let inOut = i % 10 == 0
            recs.append(Self.combined(dir: inOut ? "/Volumes/X/out" : "/Volumes/X/src\(i % 7)",
                                      name: "test_\(i)_combined.mov",
                                      group: i % 3 == 0 ? UUID() : nil))
        }
        let start = Date()
        let map = VideoScanModel.priorCombinedOutputs(records: recs, outputFolder: out)
        let elapsed = Date().timeIntervalSince(start)
        #expect(map.count == (0..<100_000).filter { $0 % 10 == 0 && $0 % 3 == 0 }.count)
        #expect(elapsed < 1.0, "priorCombinedOutputs took \(elapsed)s for 100k records")
    }
}
