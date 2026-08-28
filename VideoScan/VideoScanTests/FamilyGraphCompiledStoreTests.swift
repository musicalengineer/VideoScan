// FamilyGraphCompiledStoreTests.swift
// The compiled-artifact store's contract (Rick 2026-08-28 via codex #771):
// hit skips the parse; touching the source invalidates; a corrupt artifact
// falls back with a log line; a generation that fails verification is
// never promoted and the previous stays current; a schema bump
// recompiles; rollback swaps generations; on-disk generations are
// bounded; raw pulls are never written, sidecars land in the store.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Compiled family-tree store")
struct FamilyGraphCompiledStoreTests {

    struct Sandbox {
        let root: URL
        let originals: URL
        let compiled: URL
        var logLines: LogCapture
        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("CompiledStore-\(UUID().uuidString)")
            originals = root.appendingPathComponent("originals")
            compiled = root.appendingPathComponent("compiled")
            try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
            logLines = LogCapture()
        }
        func store(verify: ((GedcomFamilyGraph, GedcomFamilyGraph) -> [String])? = nil) -> FamilyGraphCompiledStore {
            var store = FamilyGraphCompiledStore(root: compiled)
            store.log = { logLines.append($0) }
            if let verify { store.verify = verify }
            return store
        }
        func loader(_ store: FamilyGraphCompiledStore?) -> FamilyGraphFileLoader {
            var loader = FamilyGraphFileLoader(originalsDirectory: originals)
            loader.compiledStore = store
            return loader
        }
        func write(_ text: String, as name: String = "family.ged", mtime: Date? = nil) throws -> URL {
            let url = originals.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            if let mtime {
                try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
            }
            return url
        }
        func tearDown() { try? FileManager.default.removeItem(at: root) }
    }

    final class LogCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [String] { lock.withLock { lines } }
        func contains(_ needle: String) -> Bool { all.contains { $0.contains(needle) } }
    }

    static let tree = GedcomSyntheticPedigree.gedcom(people: 400, generations: 8)

    @Test func firstLoadCompilesAndPromotesSecondLoadSkipsTheParse() throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let source = try box.write(Self.tree)
        let store = box.store()

        let first = box.loader(store).loadNewestOutcome()
        #expect(first.compiled == true)
        #expect(first.graph?.people.count == 400)
        #expect(first.graph?.hasBuiltIndex == true)
        let pointer = try #require(store.readPointer())
        #expect(pointer.sourceKeys == [try GedcomCompiledTree.sourceKey(for: source)])
        #expect(pointer.previous == nil)
        #expect(store.generations().count == 1)
        let manifest = try #require(store.readManifest(pointer.current))
        #expect(manifest.verification.isEmpty)
        #expect(manifest.peopleCount == 400)
        #expect(manifest.sources.first?.sha256 == (try GedcomCompiledTree.fullSHA256(of: source)))
        #expect(box.logLines.contains("promoted"))
        // Sidecar in the store, raw directory untouched.
        let sidecar = box.compiled.appendingPathComponent("sources")
            .appendingPathComponent(pointer.sourceKeys[0] + ".sha256")
        #expect(try String(contentsOf: sidecar, encoding: .utf8).hasSuffix("  family.ged\n"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.originals.path) == ["family.ged"])

        // Second load: the artifact, not the file.
        let compiledOnly = try #require(store.load(sources: [source]))
        #expect(compiledOnly.people.count == 400)
        #expect(compiledOnly.people(withSurname: "Breen").count == first.graph?.people(withSurname: "Breen").count)
        let second = box.loader(store).loadNewestOutcome()
        #expect(second.compiled == true)
        #expect(store.generations().count == 1, "a hit must not compile again")
    }

    @Test func touchingTheSourceInvalidatesAndRecompiles() throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let source = try box.write(Self.tree, mtime: Date(timeIntervalSince1970: 1_000))
        let store = box.store()
        _ = box.loader(store).loadNewestOutcome()
        let gen1 = try #require(store.readPointer()).current

        // Same bytes, new mtime → miss → new generation; previous retained.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: source.path)
        #expect(store.load(sources: [source]) == nil)
        _ = box.loader(store).loadNewestOutcome()
        let pointer = try #require(store.readPointer())
        #expect(pointer.current != gen1)
        #expect(pointer.previous == gen1)
        #expect(store.generations().count == 2)

        // Edited content → miss again; oldest generation pruned (N = 2).
        _ = try box.write(GedcomSyntheticPedigree.gedcom(people: 401, generations: 8), mtime: Date(timeIntervalSince1970: 3_000))
        let third = box.loader(store).loadNewestOutcome()
        #expect(third.graph?.people.count == 401)
        #expect(store.generations().count == 2)
        #expect(!store.generations().contains(gen1))
    }

    @Test func corruptCurrentFallsBackToParseWithALogLine() throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let source = try box.write(Self.tree)
        let store = box.store()
        _ = box.loader(store).loadNewestOutcome()
        let pointer = try #require(store.readPointer())
        try Data("garbage".utf8).write(to: store.artifactURL(pointer.current))

        #expect(store.load(sources: [source]) == nil)
        #expect(box.logLines.contains("corrupt"))
        // The loader still answers (parse), and re-ingests a good generation.
        let outcome = box.loader(store).loadNewestOutcome()
        #expect(outcome.graph?.people.count == 400)
        #expect(outcome.compiled == true)
        #expect(try #require(store.readPointer()).current != pointer.current)
    }

    @Test func corruptCurrentRollsBackToPreviousBuiltFromTheSameSource() throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let source = try box.write(Self.tree)
        let store = box.store()
        let graph = try #require(GedcomFamilyGraph(fileURL: source))
        _ = store.ingest(graph: graph, sources: [source])
        _ = store.ingest(graph: graph, sources: [source])   // same source twice → previous has same keys
        let pointer = try #require(store.readPointer())
        let previous = try #require(pointer.previous)
        try Data("garbage".utf8).write(to: store.artifactURL(pointer.current))

        let recovered = try #require(store.load(sources: [source]))
        #expect(recovered.people.count == 400)
        #expect(box.logLines.contains("rolled back"))
        #expect(store.readPointer()?.current == previous)
    }

    @Test func verificationFailureIsNeverPromotedAndPreviousStaysCurrent() throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let source = try box.write(Self.tree)
        let good = box.store()
        _ = box.loader(good).loadNewestOutcome()
        let before = try #require(good.readPointer())

        let failing = box.store(verify: { _, _ in ["forced failure"] })
        let graph = try #require(GedcomFamilyGraph(fileURL: source))
        #expect(failing.ingest(graph: graph, sources: [source]) == nil)
        #expect(box.logLines.contains("FAILED verification"))
        #expect(good.readPointer() == before, "pointer untouched")
        #expect(good.generations() == [before.current], "failed generation pruned, current kept")

        // The loader falls back to the parsed graph and still answers.
        let outcome = box.loader(failing).loadNewestOutcome()
        #expect(outcome.graph?.people.count == 400)
        // (a hit for the unchanged source is served from the good generation)
        #expect(outcome.compiled == true)
    }

    @Test func schemaBumpRecompiles() throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let source = try box.write(Self.tree)
        let store = box.store()
        _ = box.loader(store).loadNewestOutcome()
        var pointer = try #require(store.readPointer())
        let gen1 = pointer.current
        // Simulate an artifact written by an older build.
        pointer.index = pointer.index &+ 1
        try JSONEncoder().encode(pointer).write(to: store.pointerURL)

        #expect(store.load(sources: [source]) == nil)
        #expect(box.logLines.contains("schema changed"))
        let outcome = box.loader(store).loadNewestOutcome()
        #expect(outcome.compiled == true)
        let after = try #require(store.readPointer())
        #expect(after.current != gen1)
        #expect(FamilyGraphCompiledStore.versionsMatch(after))
    }

    @Test func rollbackSwapsGenerations() throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let source = try box.write(Self.tree, mtime: Date(timeIntervalSince1970: 1_000))
        let store = box.store()
        _ = box.loader(store).loadNewestOutcome()
        let gen1 = try #require(store.readPointer()).current
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: source.path)
        _ = box.loader(store).loadNewestOutcome()
        let gen2 = try #require(store.readPointer()).current
        #expect(gen1 != gen2)

        #expect(store.rollback())
        let pointer = try #require(store.readPointer())
        #expect(pointer.current == gen1)
        #expect(pointer.previous == gen2)
        // The rolled-back pointer answers for the source it was built from
        // (mtime 1000), not the current file (mtime 2000).
        #expect(store.load(sources: [source]) == nil)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: source.path)
        #expect(store.load(sources: [source])?.people.count == 400)
        // Nothing to roll back to twice in a row? There is (gen2), then no more.
        #expect(store.rollback())
        #expect(store.readPointer()?.current == gen2)
    }

    @Test func noStoreMeansParseEveryTimeAndNothingWritten() throws {
        let box = try Sandbox(); defer { box.tearDown() }
        _ = try box.write(Self.tree)
        let outcome = box.loader(nil).loadNewestOutcome()
        #expect(outcome.compiled == false)
        #expect(outcome.graph?.hasBuiltIndex == true, "loader builds the index off the caller's thread")
        #expect(!FileManager.default.fileExists(atPath: box.compiled.path))
    }

    @Test func modelWithInjectedDirectoryTouchesNoProductionStore() async throws {
        let box = try Sandbox(); defer { box.tearDown() }
        _ = try box.write(Self.tree)
        let model = await MainActor.run { FamilyTreeLiveModel(originalsDirectory: box.originals) }
        await model.loadFromDisk()
        await MainActor.run {
            #expect(model.loadState == .loaded(live: true))
            #expect(model.peopleCount == 400)
            #expect(model.loadPhase == nil)
        }
        #expect(!FileManager.default.fileExists(atPath: box.compiled.path))
    }

    @Test @MainActor func modelWithInjectedStoreCompilesOnceAndFiltersFromTheIndex() async throws {
        let box = try Sandbox(); defer { box.tearDown() }
        _ = try box.write(Self.tree)
        let model = FamilyTreeLiveModel(originalsDirectory: box.originals, compiledStore: box.store())
        await model.loadFromDisk()
        #expect(model.loadState == .loaded(live: true))
        #expect(model.peopleCount == 400)
        #expect(box.logLines.contains("promoted"))
        let all = model.filteredPeople.count
        model.searchText = "breen"
        #expect(!model.filteredPeople.isEmpty && model.filteredPeople.count < all)
        #expect(model.filteredPeople.allSatisfy { $0.name.localizedCaseInsensitiveContains("breen") || $0.reference.localizedCaseInsensitiveContains("breen") })
        model.searchText = ""
        #expect(model.filteredPeople.count == all)
        // Reload: served from the artifact.
        await model.loadFromDisk()
        #expect(box.store().generations().count == 1)
    }
}
