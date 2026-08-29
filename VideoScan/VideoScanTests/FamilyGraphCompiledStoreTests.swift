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
            root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
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

    // One-time ingest (2026-08-28): a generation compiled from TWO pulls by
    // the CLI is what the loader hands out, even though the folder's
    // "newest .ged" rule would name only one of them. Touching either
    // source makes it stale and the loader falls back to the newest file.
    @Test func multiSourceGenerationWinsUntilASourceChanges() throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let old = Date(timeIntervalSinceNow: -3600)
        let a = try box.write(GedcomSyntheticPedigree.gedcom(people: 120, generations: 5), as: "a.ged", mtime: old)
        // Distinct FamilySearch IDs so the two pulls are different families (synthetic FSIDs are index-based).
        let b = try box.write(GedcomSyntheticPedigree.gedcom(people: 80, generations: 4).replacingOccurrences(of: "_FSFTID ", with: "_FSFTID D"), as: "b.ged", mtime: old)
        let store = box.store()
        let ga = try #require(GedcomFamilyGraph(fileURL: a)), gb = try #require(GedcomFamilyGraph(fileURL: b))
        let merged = ga.merged(with: gb)
        #expect(store.ingest(graph: merged, sources: [a, b]) != nil)

        let loaded = box.loader(store).loadNewestOutcome()
        #expect(loaded.compiled == true)
        #expect(loaded.graph?.people.count == merged.people.count)
        #expect(loaded.graph?.rootPersonIDs.count == 2)
        #expect(loaded.graph?.sourceFileNames == ["a.ged", "b.ged"])
        #expect(loaded.candidateCount == 2)

        // Re-pull b: the two-source generation is stale; newest single file wins.
        _ = try box.write(GedcomSyntheticPedigree.gedcom(people: 90, generations: 4), as: "b.ged")
        let after = box.loader(store).loadNewestOutcome()
        #expect(after.graph?.people.count == 90)
        #expect(after.selectedURL?.lastPathComponent == "b.ged")
        #expect(box.logLines.contains("b.ged missing or changed"))
    }

    /// codex #789: `loadCurrent()` rolls back like `load(sources:)`. A
    /// corrupt current whose previous generation was built from the SAME
    /// (still unchanged) sources is served from previous and repointed.
    @Test func corruptMultiSourceCurrentRollsBackToPreviousGeneration() throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let old = Date(timeIntervalSinceNow: -3600)
        let a = try box.write(GedcomSyntheticPedigree.gedcom(people: 120, generations: 5), as: "a.ged", mtime: old)
        let b = try box.write(GedcomSyntheticPedigree.gedcom(people: 80, generations: 4).replacingOccurrences(of: "_FSFTID ", with: "_FSFTID D"), as: "b.ged", mtime: old)
        let store = box.store()
        let merged = try #require(GedcomFamilyGraph(fileURL: a)).merged(with: try #require(GedcomFamilyGraph(fileURL: b)))
        #expect(store.ingest(graph: merged, sources: [a, b]) != nil)
        #expect(store.ingest(graph: merged, sources: [a, b]) != nil)   // same sources → previous has same keys
        let pointer = try #require(store.readPointer())
        let previous = try #require(pointer.previous)
        try Data("garbage".utf8).write(to: store.artifactURL(pointer.current))

        let outcome = box.loader(store).loadNewestOutcome()
        #expect(outcome.compiled == true)
        #expect(outcome.graph?.people.count == merged.people.count)
        #expect(outcome.graph?.rootPersonIDs.count == 2)
        #expect(outcome.candidateCount == 2)
        #expect(box.logLines.contains("rolled back to \(previous)"))
        let repointed = try #require(store.readPointer())
        #expect(repointed.current == previous)
        #expect(repointed.previous == nil)
        #expect(repointed.sourceKeys == store.readManifest(previous)?.sources.map(\.key))
    }

    /// …but a previous generation whose sources have since changed is not
    /// a rollback target: nil, then the loader's newest-file path.
    @Test func corruptCurrentWithStalePreviousFallsBackToNewestFile() throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let old = Date(timeIntervalSinceNow: -3600)
        let a = try box.write(GedcomSyntheticPedigree.gedcom(people: 120, generations: 5), as: "a.ged", mtime: old)
        let b = try box.write(GedcomSyntheticPedigree.gedcom(people: 80, generations: 4).replacingOccurrences(of: "_FSFTID ", with: "_FSFTID D"), as: "b.ged", mtime: old)
        let store = box.store()
        let ga = try #require(GedcomFamilyGraph(fileURL: a))
        #expect(store.ingest(graph: ga.merged(with: try #require(GedcomFamilyGraph(fileURL: b))), sources: [a, b]) != nil)
        // Re-pull b, ingest again: previous (gen1) now records a b.ged that no longer matches disk.
        let b2 = try box.write(GedcomSyntheticPedigree.gedcom(people: 90, generations: 4).replacingOccurrences(of: "_FSFTID ", with: "_FSFTID D"), as: "b.ged")
        #expect(store.ingest(graph: ga.merged(with: try #require(GedcomFamilyGraph(fileURL: b2))), sources: [a, b2]) != nil)
        let pointer = try #require(store.readPointer())
        let gen1 = try #require(pointer.previous)
        try Data("garbage".utf8).write(to: store.artifactURL(pointer.current))

        #expect(store.loadCurrent() == nil)
        #expect(box.logLines.contains("generation \(gen1) source b.ged missing or changed"))
        #expect(box.logLines.contains("no usable previous"))
        #expect(store.readPointer() == pointer, "no repoint to a stale previous")

        let outcome = box.loader(store).loadNewestOutcome()
        #expect(outcome.selectedURL?.lastPathComponent == "b.ged")
        #expect(outcome.graph?.people.count == 90)
        #expect(outcome.compiled == true, "newest file re-ingested as a single-source generation")
        #expect(store.readPointer()?.current != pointer.current)
    }

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

    /// codex #792: the key is the full content hash. A `touch` (same
    /// bytes, new mtime) stays a hit; edited bytes are a miss.
    @Test func sameBytesNewMtimeStaysAHitEditedBytesRecompile() throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let source = try box.write(Self.tree, mtime: Date(timeIntervalSince1970: 1_000))
        let store = box.store()
        _ = box.loader(store).loadNewestOutcome()
        let gen1 = try #require(store.readPointer()).current

        // Same bytes, new mtime → still a hit; no new generation.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: source.path)
        #expect(store.load(sources: [source]) != nil)
        _ = box.loader(store).loadNewestOutcome()
        #expect(store.readPointer()?.current == gen1)
        #expect(store.generations().count == 1)

        // Edited content → miss → new generation; previous retained.
        _ = try box.write(GedcomSyntheticPedigree.gedcom(people: 401, generations: 8), mtime: Date(timeIntervalSince1970: 3_000))
        #expect(store.load(sources: [source]) == nil)
        let second = box.loader(store).loadNewestOutcome()
        #expect(second.graph?.people.count == 401)
        let pointer = try #require(store.readPointer())
        #expect(pointer.current != gen1)
        #expect(pointer.previous == gen1)
        #expect(store.generations().count == 2)

        // Edited again → oldest generation pruned (N = 2).
        _ = try box.write(GedcomSyntheticPedigree.gedcom(people: 402, generations: 8), mtime: Date(timeIntervalSince1970: 3_000))
        let third = box.loader(store).loadNewestOutcome()
        #expect(third.graph?.people.count == 402)
        #expect(store.generations().count == 2)
        #expect(!store.generations().contains(gen1))
    }

    /// codex #792: a same-size edit in the middle of the file with the
    /// mtime put back is a miss (app-side twin of the Core sensor).
    @Test func middleEditWithPreservedSizeAndMtimeIsAMiss() throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let mtime = Date(timeIntervalSince1970: 1_000)
        let source = try box.write(Self.tree, mtime: mtime)
        let store = box.store()
        _ = box.loader(store).loadNewestOutcome()
        let gen1 = try #require(store.readPointer()).current
        let bytes = Array(Self.tree.utf8)
        var at = bytes.count / 2
        while !(bytes[at] >= 0x30 && bytes[at] <= 0x39) { at += 1 }
        let handle = try FileHandle(forWritingTo: source)
        try handle.seek(toOffset: UInt64(at))
        try handle.write(contentsOf: Data([bytes[at] == 0x39 ? 0x38 : bytes[at] + 1]))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: source.path)
        #expect(try GedcomCompiledTree.sourceStat(source).size == bytes.count)

        #expect(store.load(sources: [source]) == nil)
        let outcome = box.loader(store).loadNewestOutcome()
        #expect(outcome.compiled == true)
        #expect(store.readPointer()?.current != gen1, "recompiled from the edited bytes")
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
        // Simulate a pointer written by an older build: store schema 1
        // (pre full-SHA source keys), current schema is 2 (codex #805).
        #expect(FamilyGraphCompiledStore.schemaVersion > 1)
        pointer.schema = 1
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
        let treeB = GedcomSyntheticPedigree.gedcom(people: 401, generations: 8)
        let source = try box.write(Self.tree)
        let store = box.store()
        _ = box.loader(store).loadNewestOutcome()
        let gen1 = try #require(store.readPointer()).current
        _ = try box.write(treeB)
        _ = box.loader(store).loadNewestOutcome()
        let gen2 = try #require(store.readPointer()).current
        #expect(gen1 != gen2)

        #expect(store.rollback())
        let pointer = try #require(store.readPointer())
        #expect(pointer.current == gen1)
        #expect(pointer.previous == gen2)
        // The rolled-back pointer answers for the bytes it was built from
        // (tree A), not the current file (tree B).
        #expect(store.load(sources: [source]) == nil)
        _ = try box.write(Self.tree)
        #expect(store.load(sources: [source])?.people.count == 400)
        // Nothing to roll back to twice in a row? There is (gen2), then no more.
        #expect(store.rollback())
        #expect(store.readPointer()?.current == gen2)
    }

    /// codex #797-6: rollback refuses a previous whose artifact is corrupt.
    @Test func rollbackRefusesCorruptPrevious() throws {
        let box = try Sandbox(); defer { box.tearDown() }
        _ = try box.write(Self.tree)
        let store = box.store()
        _ = box.loader(store).loadNewestOutcome()
        _ = try box.write(GedcomSyntheticPedigree.gedcom(people: 401, generations: 8))
        _ = box.loader(store).loadNewestOutcome()
        let before = try #require(store.readPointer())
        let previous = try #require(before.previous)
        try Data("garbage".utf8).write(to: store.artifactURL(previous))
        #expect(!store.rollback())
        #expect(store.readPointer() == before, "pointer untouched")
        #expect(box.logLines.contains("rollback refused"))
    }

    /// codex #792: two overlapping `loadFromDisk` calls never run two loads
    /// at once — one generation on disk, and the second caller's load
    /// starts after the first finishes (a hit).
    @Test @MainActor func overlappingLoadFromDiskCallsAreSerialized() async throws {
        let box = try Sandbox(); defer { box.tearDown() }
        _ = try box.write(Self.tree)
        let model = FamilyTreeLiveModel(originalsDirectory: box.originals, compiledStore: box.store())
        async let first: Void = model.loadFromDisk()
        async let second: Void = model.loadFromDisk()
        async let third: Void = model.loadFromDisk()
        _ = await (first, second, third)
        #expect(model.loadState == .loaded(live: true))
        #expect(model.peopleCount == 400)
        #expect(box.store().generations().count == 1, "one compile, never two concurrent ingests")
        #expect(box.logLines.all.filter { $0.contains("promoted") }.count == 1)
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

    /// codex #812 (codec 3 → 4) and 2026-08-29 (codec 4 → 5, index 1 → 2):
    /// a pointer written by an older build is "schema changed" → miss →
    /// recompile through the loader; the new pointer carries the current
    /// codec and its manifest the loss figures.
    @Test(arguments: [(codec: UInt32(3), index: UInt32(1)), (codec: 4, index: 1), (codec: 5, index: 1), (codec: 4, index: 2)])
    func olderCodecPointerRecompiles(older: (codec: UInt32, index: UInt32)) throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let source = try box.write(Self.tree)
        let store = box.store()
        _ = box.loader(store).loadNewestOutcome()
        var pointer = try #require(store.readPointer())
        let gen1 = pointer.current
        #expect(pointer.codec == 5)
        #expect(pointer.index == 2)
        pointer.codec = older.codec
        pointer.index = older.index
        try JSONEncoder().encode(pointer).write(to: store.pointerURL)
        #expect(!FamilyGraphCompiledStore.versionsMatch(pointer))
        #expect(store.load(sources: [source]) == nil)
        #expect(store.loadCurrent() == nil)
        #expect(box.logLines.contains("schema changed"))

        let outcome = box.loader(store).loadNewestOutcome()
        #expect(outcome.compiled == true)
        let after = try #require(store.readPointer())
        #expect(after.current != gen1)
        #expect(after.codec == GedcomCompiledTree.codecVersion)
        let manifest = try #require(store.readManifest(after.current))
        #expect(manifest.sources.map(\.droppedLineCount) == [outcome.graph?.totalDroppedLineCount])
        #expect(manifest.localDroppedLineCount == 0)
        #expect(manifest.totalDroppedLineCount == outcome.graph?.totalDroppedLineCount)
        #expect(outcome.graph?.sourceProvenance.map(\.sha256) == [try GedcomCompiledTree.fullSHA256(of: source)])
    }

    /// codex #816/#817 through the app's loader: the graph the loader
    /// parses carries the file's digest, so a rewrite between parse and
    /// ingest is refused and the previous generation stays current.
    @Test func loaderParsedGraphIsRefusedWhenTheFileChangedUnderneath() throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let source = try box.write(Self.tree)
        let store = box.store()
        _ = box.loader(store).loadNewestOutcome()
        let before = try #require(store.readPointer())
        let graph = try #require(GedcomFamilyGraph(fileURL: source))
        #expect(graph.sourceFingerprint == before.sourceKeys[0])
        _ = try box.write(GedcomSyntheticPedigree.gedcom(people: 401, generations: 8))
        #expect(store.ingest(graph: graph, sources: [source]) == nil)
        #expect(box.logLines.contains("REFUSED"))
        #expect(store.readPointer() == before)
        // Reordered / wrong URL for a merged pair: refused as well.
        let b = try box.write(GedcomSyntheticPedigree.gedcom(people: 80, generations: 4)
            .replacingOccurrences(of: "_FSFTID ", with: "_FSFTID D"), as: "b.ged")
        let merged = try #require(GedcomFamilyGraph(fileURL: source)).merged(with: try #require(GedcomFamilyGraph(fileURL: b)))
        #expect(store.ingest(graph: merged, sources: [b, source]) == nil)
        #expect(store.readPointer() == before)
        #expect(store.ingest(graph: merged, sources: [source, b]) != nil)
        let pointer = try #require(store.readPointer())
        let manifest = try #require(store.readManifest(pointer.current))
        #expect(manifest.sources.map(\.fileName) == ["family.ged", "b.ged"])
        #expect(store.loadCurrent()?.graph.sourceProvenance.map(\.sha256) == manifest.sources.map(\.sha256))
    }

    // MARK: codex #822 — app merge artifact vs. CLI generation (loader precedence)

    /// The app's "Add to current tree" output, as the coordinator writes it:
    /// ONE .ged whose HEAD lists the two pulls it was merged from.
    private static func mergedArtifactText(_ a: URL, _ b: URL) throws -> (text: String, people: Int) {
        let merged = try #require(GedcomFamilyGraph(fileURL: a)).merged(with: try #require(GedcomFamilyGraph(fileURL: b)))
        return (merged.gedcomText(provenance: "test artifact"), merged.people.count)
    }
    private static let pullB = GedcomSyntheticPedigree.gedcom(people: 80, generations: 4)
        .replacingOccurrences(of: "_FSFTID ", with: "_FSFTID D")

    /// (a) A valid two-source CLI generation exists; then an app Add
    /// installs merged.ged (newer than the generation). Next load promotes
    /// the artifact as ONE physical source: compiled == true, the decoded
    /// graph still says it was merged from [A, B], and the manifest keeps
    /// both lists. A further load is a hit with no parse.
    @Test func appMergeArtifactInstalledAfterCLIGenerationSupersedesIt() throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let old = Date(timeIntervalSinceNow: -3600)
        let a = try box.write(GedcomSyntheticPedigree.gedcom(people: 120, generations: 5), as: "a.ged", mtime: old)
        let b = try box.write(Self.pullB, as: "b.ged", mtime: old)
        let store = box.store()
        let cli = try #require(GedcomFamilyGraph(fileURL: a)).merged(with: try #require(GedcomFamilyGraph(fileURL: b)))
        #expect(store.ingest(graph: cli, sources: [a, b]) != nil)
        let gen1 = try #require(store.readPointer()).current
        #expect(box.loader(store).loadNewestOutcome().compiled == true)
        #expect(store.readPointer()?.current == gen1, "unchanged sources, no newer file: generation wins")

        // The app Add lands a merged artifact, newer than the generation.
        let artifact = try Self.mergedArtifactText(a, b)
        let merged = try box.write(artifact.text, as: "familysearch-merged-20260828-120000.ged",
                                   mtime: Date(timeIntervalSinceNow: 60))
        let outcome = box.loader(store).loadNewestOutcome()
        #expect(outcome.compiled == true)
        #expect(outcome.selectedURL?.resolvingSymlinksInPath() == merged.resolvingSymlinksInPath())
        #expect(outcome.rejectedURLs.isEmpty)
        let graph = try #require(outcome.graph)
        #expect(graph.people.count == artifact.people)
        #expect(graph.isMergedArtifact == true)
        #expect(graph.sourceProvenance.map(\.name) == ["a.ged", "b.ged"])
        #expect(graph.sourceProvenance.map(\.sha256) == [try GedcomCompiledTree.fullSHA256(of: a), try GedcomCompiledTree.fullSHA256(of: b)])
        #expect(graph.physicalSources.map(\.name) == [merged.lastPathComponent])
        #expect(graph.rootPersonIDs.count == 2)
        let pointer = try #require(store.readPointer())
        #expect(pointer.current != gen1)
        #expect(pointer.previous == gen1)
        #expect(pointer.sourceKeys == [try GedcomCompiledTree.fullSHA256(of: merged)])
        let manifest = try #require(store.readManifest(pointer.current))
        #expect(manifest.sources.map(\.fileName) == [merged.lastPathComponent])
        #expect(manifest.logicalSources.map(\.fileName) == ["a.ged", "b.ged"])
        #expect(box.logLines.contains("promoted"))

        // Third load: hit, no parse, no new generation.
        var phases: [String] = []
        var loader = box.loader(store)
        loader.progress = { phases.append($0) }
        let again = loader.loadNewestOutcome()
        #expect(again.compiled == true)
        #expect(again.graph?.people.count == artifact.people)
        #expect(phases.isEmpty, "a hit must not read or compile: \(phases)")
        #expect(store.readPointer()?.current == pointer.current)
        #expect(store.generations().count == 2)
    }

    /// (b) No prior generation, only the merged artifact on disk: the
    /// first load parses and promotes it (one physical source, logical
    /// [A, B]); the second load is served from the artifact with no parse.
    @Test func mergedArtifactWithNoPriorGenerationIsPromotedOnceThenHit() throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let scratch = box.root.appendingPathComponent("pulls", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let a = scratch.appendingPathComponent("a.ged"), b = scratch.appendingPathComponent("b.ged")
        try GedcomSyntheticPedigree.gedcom(people: 120, generations: 5).write(to: a, atomically: true, encoding: .utf8)
        try Self.pullB.write(to: b, atomically: true, encoding: .utf8)
        let artifact = try Self.mergedArtifactText(a, b)
        let merged = try box.write(artifact.text, as: "familysearch-merged-20260828-120000.ged")
        let store = box.store()

        var phases: [String] = []
        var loader = box.loader(store)
        loader.progress = { phases.append($0) }
        let first = loader.loadNewestOutcome()
        #expect(first.compiled == true)
        #expect(first.selectedURL?.resolvingSymlinksInPath() == merged.resolvingSymlinksInPath())
        #expect(first.graph?.people.count == artifact.people)
        #expect(first.graph?.sourceProvenance.map(\.name) == ["a.ged", "b.ged"])
        #expect(phases.contains { $0.hasPrefix("Reading") })
        let pointer = try #require(store.readPointer())
        #expect(pointer.previous == nil)
        #expect(pointer.sourceKeys == [try GedcomCompiledTree.fullSHA256(of: merged)])
        #expect(store.readManifest(pointer.current)?.logicalSources.map(\.fileName) == ["a.ged", "b.ged"])

        phases.removeAll()
        let second = loader.loadNewestOutcome()
        #expect(second.compiled == true)
        #expect(second.graph?.people.count == artifact.people)
        #expect(second.graph?.isMergedArtifact == true)
        #expect(phases.isEmpty, "second load must not parse: \(phases)")
        #expect(store.generations().count == 1)
        #expect(store.readPointer() == pointer)
    }

    /// (c) Unchanged raw sources, a valid multi-source generation, and no
    /// newer .ged (older siblings and same-age files do not count): the
    /// generation wins, and nothing is parsed or compiled.
    @Test func validMultiSourceGenerationWinsWhenNoNewerFileExists() throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let old = Date(timeIntervalSinceNow: -3600)
        let a = try box.write(GedcomSyntheticPedigree.gedcom(people: 120, generations: 5), as: "a.ged", mtime: old)
        let b = try box.write(Self.pullB, as: "b.ged", mtime: old)
        // An OLDER stray export (a previous app merge, say) sits beside them.
        _ = try box.write(GedcomSyntheticPedigree.gedcom(people: 10, generations: 2), as: "familysearch-merged-20260801-000000.ged",
                          mtime: Date(timeIntervalSinceNow: -7200))
        let store = box.store()
        let cli = try #require(GedcomFamilyGraph(fileURL: a)).merged(with: try #require(GedcomFamilyGraph(fileURL: b)))
        #expect(store.ingest(graph: cli, sources: [a, b]) != nil)
        let pointer = try #require(store.readPointer())

        var phases: [String] = []
        var loader = box.loader(store)
        loader.progress = { phases.append($0) }
        let outcome = loader.loadNewestOutcome()
        #expect(outcome.compiled == true)
        #expect(outcome.graph?.people.count == cli.people.count)
        #expect(outcome.graph?.rootPersonIDs.count == 2)
        #expect(outcome.candidateCount == 3)
        #expect(phases.isEmpty, "generation hit must not parse: \(phases)")
        #expect(store.readPointer() == pointer)
        #expect(store.generations() == [pointer.current])

        // A newer file that does NOT parse is reported, and the generation still wins.
        let bad = try box.write("not a gedcom", as: "broken.ged", mtime: Date(timeIntervalSinceNow: 60))
        let withBad = box.loader(store).loadNewestOutcome()
        #expect(withBad.compiled == true)
        #expect(withBad.graph?.people.count == cli.people.count)
        #expect(withBad.rejectedURLs.map { $0.resolvingSymlinksInPath() } == [bad.resolvingSymlinksInPath()])
        #expect(store.readPointer() == pointer)
        #expect(box.logLines.contains("did not parse; keeping compiled generation"))
    }

    // MARK: codex #826 — never silently demote multi-source → single-source

    /// (a) A two-source generation whose pointer carries an old codec:
    /// the loader returns graph nil + needsRecompile == [a, b]; no
    /// single-source generation is promoted and the pointer is untouched.
    /// The model's Recompile then rebuilds the two-pull tree.
    @Test func versionRefusedMultiSourceGenerationIsNotDemotedToNewestFile() async throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let old = Date(timeIntervalSinceNow: -3600)
        let a = try box.write(GedcomSyntheticPedigree.gedcom(people: 120, generations: 5), as: "a.ged", mtime: old)
        let b = try box.write(Self.pullB, as: "b.ged", mtime: old)
        let store = box.store()
        let cli = try #require(GedcomFamilyGraph(fileURL: a)).merged(with: try #require(GedcomFamilyGraph(fileURL: b)))
        #expect(store.ingest(graph: cli, sources: [a, b]) != nil)
        var pointer = try #require(store.readPointer())
        pointer.codec = 3
        try JSONEncoder().encode(pointer).write(to: store.pointerURL)

        let outcome = box.loader(store).loadNewestOutcome()
        #expect(outcome.graph == nil)
        #expect(outcome.compiled == false)
        #expect(outcome.needsRecompile == [a, b])
        #expect(store.readPointer() == pointer, "pointer untouched")
        #expect(store.generations() == [pointer.current], "no single-source generation")
        #expect(box.logLines.contains("needs recompile for 2 sources (codec/schema) — not demoting to b.ged"))

        // The model surfaces it, installs no tree, and Recompile fixes it.
        let model = await MainActor.run { FamilyTreeLiveModel(originalsDirectory: box.originals, compiledStore: store) }
        await model.loadFromDisk()
        await MainActor.run {
            #expect(model.needsRecompile == [a, b])
            #expect(model.loadState == .loaded(live: false))
        }
        await model.recompile()
        await MainActor.run {
            #expect(model.needsRecompile.isEmpty)
            #expect(model.loadState == .loaded(live: true))
            #expect(model.peopleCount == cli.people.count)
            #expect(model.isRecompiling == false)
        }
        let after = try #require(store.readPointer())
        #expect(after.codec == GedcomCompiledTree.codecVersion)
        #expect(after.current != pointer.current)
        #expect(store.readManifest(after.current)?.sources.map(\.fileName) == ["a.ged", "b.ged"])
        #expect(box.loader(store).loadNewestOutcome().compiled == true)
    }

    /// (b) Same, but one of the two sources was deleted: the generation
    /// cannot be recompiled as it was, so the newest-file path is allowed
    /// and the log says which source is missing.
    @Test func versionRefusedGenerationWithAMissingSourceFallsBackToNewestFile() throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let old = Date(timeIntervalSinceNow: -3600)
        let a = try box.write(GedcomSyntheticPedigree.gedcom(people: 120, generations: 5), as: "a.ged", mtime: old)
        let b = try box.write(Self.pullB, as: "b.ged", mtime: old)
        let store = box.store()
        let cli = try #require(GedcomFamilyGraph(fileURL: a)).merged(with: try #require(GedcomFamilyGraph(fileURL: b)))
        #expect(store.ingest(graph: cli, sources: [a, b]) != nil)
        var pointer = try #require(store.readPointer())
        pointer.codec = 3
        try JSONEncoder().encode(pointer).write(to: store.pointerURL)
        try FileManager.default.removeItem(at: b)

        let outcome = box.loader(store).loadNewestOutcome()
        #expect(outcome.needsRecompile.isEmpty)
        #expect(outcome.compiled == true)
        #expect(outcome.selectedURL?.resolvingSymlinksInPath() == a.resolvingSymlinksInPath())
        #expect(outcome.graph?.people.count == 120)
        #expect(box.logLines.contains("b.ged missing or changed"))
        #expect(!box.logLines.contains("not demoting"))
        #expect(store.readPointer()?.current != pointer.current)
    }
}
