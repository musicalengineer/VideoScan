import Foundation
import Testing
@testable import VideoScan

struct LoaderRecoveryRegressionTests {
    @Test func malformedNewerPullMustNotBypassIntactMultiSourceRecovery() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let good = try #require(fixture.store.readPointer()?.current)
        try fixture.breakPointer()
        let malformed = fixture.originals.appendingPathComponent("fresh-but-broken.ged")
        try Data([0xff, 0xfe, 0xfd]).write(to: malformed)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(3600)],
                                              ofItemAtPath: malformed.path)
        let outcome = fixture.loader.loadNewestOutcome()
        let graph = try #require(outcome.graph)
        print("RECOVERY_MALFORMED people=\(graph.people.count) pointerRecovered=\(fixture.store.readPointer()?.current == good)")
        #expect(graph.people.count == 3, "An invalid superseder must not discard the intact two-source tree")
        #expect(!graph.people(matching: "Donna").isEmpty, "The nested source must remain represented")
        #expect(fixture.store.readPointer()?.current == good, "Recover the intact generation after rejecting the malformed pull")
        #expect(outcome.rejectedURLs.contains { $0.standardizedFileURL == malformed.standardizedFileURL })
    }

    @Test func corruptNewestCandidateMustNotHideOlderDecodableMultiSourceGeneration() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let good = try #require(fixture.store.readPointer()?.current)
        _ = try #require(fixture.loader.recompile(sources: fixture.sources))
        let corrupt = try #require(fixture.store.readPointer()?.current)
        try #require(corrupt != good)
        // Make ordering explicit, independent of generation suffix and clock precision.
        var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.store.manifestURL(corrupt))) as? [String: Any])
        manifest["createdAt"] = "2099-01-01T00:00:00.000Z"
        try JSONSerialization.data(withJSONObject: manifest).write(to: fixture.store.manifestURL(corrupt))
        try Data("corrupt artifact".utf8).write(to: fixture.store.artifactURL(corrupt))
        try fixture.breakPointer()
        let outcome = fixture.loader.loadNewestOutcome()
        let graph = try #require(outcome.graph)
        print("RECOVERY_CORRUPT people=\(graph.people.count) olderRecovered=\(fixture.store.readPointer()?.current == good)")
        #expect(graph.people.count == 3, "A corrupt candidate must not hide an older intact two-source artifact")
        #expect(!graph.people(matching: "Donna").isEmpty)
        #expect(fixture.store.readPointer()?.current == good, "Recovery must continue to the older decodable candidate")
    }

    private struct Fixture {
        let root: URL
        let originals: URL
        let sources: [URL]
        let store: FamilyGraphCompiledStore
        var loader: FamilyGraphFileLoader {
            var value = FamilyGraphFileLoader(originalsDirectory: originals)
            value.compiledStore = store
            value.readOnly = false
            return value
        }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("LoaderRecovery-\(UUID().uuidString)")
            originals = root.appendingPathComponent("originals")
            let pulls = originals.appendingPathComponent("pulls")
            try FileManager.default.createDirectory(at: pulls, withIntermediateDirectories: true)
            let mine = originals.appendingPathComponent("mine.ged")
            let hers = pulls.appendingPathComponent("hers.ged")
            sources = [mine, hers]
            try "0 HEAD\n0 @I1@ INDI\n1 NAME Rick /Fixture/\n0 TRLR".write(to: mine, atomically: true, encoding: .utf8)
            try "0 HEAD\n0 @I2@ INDI\n1 NAME Donna /Fixture/\n0 @I3@ INDI\n1 NAME Eileen /Fixture/\n0 TRLR".write(to: hers, atomically: true, encoding: .utf8)
            var value = FamilyGraphCompiledStore(root: root.appendingPathComponent("compiled"))
            value.log = { _ in }
            store = value
            // #require is the fatal precondition assertion, like ASSERT_TRUE in C++.
            let built = try #require(loader.recompile(sources: sources))
            try #require(built.people.count == 3)
        }
        func breakPointer() throws {
            var pointer = try #require(store.readPointer())
            pointer.current = "gen-00000000T000000-dead"
            pointer.previous = nil
            try JSONEncoder().encode(pointer).write(to: store.pointerURL)
            try #require(store.loadCurrent() == nil)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}
