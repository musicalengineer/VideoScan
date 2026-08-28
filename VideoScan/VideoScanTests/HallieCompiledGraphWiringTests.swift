// HallieCompiledGraphWiringTests.swift
// Codex #792 blocker 4: Hallie's runtime paths must read ONLY the promoted
// compiled artifact (Rick 2026-08-28: one-time ingest; launch and queries
// never parse), and one in-process graph must be shared across turns
// rather than decoded per call.
//
// Sensors here:
//   1. the shared cache, given a promoted multi-source generation, reports
//      compiled == true and emits no "Reading <file>" parse phase;
//   2. two consecutive loads run the loader ONCE and return the same token;
//   3. a new promoted generation (pointer change) and a revoked authority
//      (.unavailable) both invalidate;
//   4. source-level wiring: the three Hallie entry points call the shared
//      cache with a store, not the bare parse-every-time `loadFamilyGraph()`.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Hallie compiled-graph wiring")
struct HallieCompiledGraphWiringTests {

    final class LogCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [String] { lock.withLock { lines } }
        func contains(_ needle: String) -> Bool { all.contains { $0.contains(needle) } }
    }

    struct Sandbox {
        let root: URL
        let assets: URL
        let gedcom: URL
        let compiled: URL
        let log = LogCapture()
        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("HallieCompiledWiring-\(UUID().uuidString)")
            assets = root.appendingPathComponent("assets", isDirectory: true)
            gedcom = assets.appendingPathComponent("GEDCOM", isDirectory: true)
            compiled = root.appendingPathComponent("compiled", isDirectory: true)
            try FileManager.default.createDirectory(at: gedcom, withIntermediateDirectories: true)
        }
        func configuration(access: FamilyAssetStore.Access = .readOnly) -> FamilyAssetConfiguration {
            FamilyAssetConfiguration(
                roots: FamilyAssetStore.Roots(assets: assets,
                                              thumbnailCache: root.appendingPathComponent("cache")),
                access: access, legacyGEDCOMDirectory: nil)
        }
        func store() -> FamilyGraphCompiledStore {
            var store = FamilyGraphCompiledStore(root: compiled)
            store.log = { log.append($0) }
            return store
        }
        func write(_ text: String, as name: String) throws -> URL {
            let url = gedcom.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)],
                                                  ofItemAtPath: url.path)
            return url
        }
        /// Two pulls compiled into ONE promoted generation, the way
        /// videoscan-tree-ingest does it.
        func promoteTwoPulls() throws -> (store: FamilyGraphCompiledStore, people: Int) {
            let a = try write(GedcomSyntheticPedigree.gedcom(people: 120, generations: 5), as: "a.ged")
            let b = try write(GedcomSyntheticPedigree.gedcom(people: 80, generations: 4)
                                .replacingOccurrences(of: "_FSFTID ", with: "_FSFTID D"), as: "b.ged")
            let store = store()
            let ga = try #require(GedcomFamilyGraph(fileURL: a)), gb = try #require(GedcomFamilyGraph(fileURL: b))
            let merged = ga.merged(with: gb)
            #expect(store.ingest(graph: merged, sources: [a, b]) != nil)
            return (store, merged.people.count)
        }
        func tearDown() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func promotedGenerationServesHallieWithoutParsingAndIsReused() throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let (store, people) = try box.promoteTwoPulls()
        let cache = FamilyGraphSharedCache(log: { box.log.append($0) })

        let first = try #require(cache.load(for: box.configuration(), store: store))
        #expect(first.compiled == true)
        #expect(first.reused == false)
        #expect(first.graph.people.count == people)
        #expect(cache.loaderRuns == 1)
        #expect(box.log.contains("family graph loaded (compiled: true"))
        // The loader announces a parse as "Reading <file>…"; none may occur.
        #expect(!box.log.contains("Reading "), "Hallie load parsed a GEDCOM: \(box.log.all)")

        let second = try #require(cache.load(for: box.configuration(), store: store))
        #expect(second.reused == true)
        #expect(second.token == first.token, "second turn must reuse the first decode")
        #expect(cache.loaderRuns == 1)
        #expect(second.graph.people.count == people)

        // The plain configuration API with a store also reports compiled.
        let outcome = try #require(box.configuration().loadFamilyGraphOutcome(compiledStore: store))
        #expect(outcome.compiled == true)
    }

    @Test func newGenerationAndRevokedAuthorityInvalidate() throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let (store, _) = try box.promoteTwoPulls()
        let cache = FamilyGraphSharedCache(log: { box.log.append($0) })
        let first = try #require(cache.load(for: box.configuration(), store: store))

        // Re-ingest → new generation → pointer changes → one more decode.
        let sources = [box.gedcom.appendingPathComponent("a.ged"), box.gedcom.appendingPathComponent("b.ged")]
        let merged = try #require(GedcomFamilyGraph(fileURL: sources[0]))
            .merged(with: try #require(GedcomFamilyGraph(fileURL: sources[1])))
        #expect(store.ingest(graph: merged, sources: sources) != nil)
        let afterIngest = try #require(cache.load(for: box.configuration(), store: store))
        #expect(afterIngest.reused == false)
        #expect(afterIngest.token != first.token)
        #expect(afterIngest.compiled == true)
        #expect(cache.loaderRuns == 2)

        // Designated Master offline: nil, and the cached tree is dropped so
        // a republish cannot hand out the pre-disconnect graph.
        #expect(cache.load(for: box.configuration(access: .unavailable), store: store) == nil)
        let afterRevoke = try #require(cache.load(for: box.configuration(), store: store))
        #expect(afterRevoke.reused == false)
        #expect(cache.loaderRuns == 3)
        #expect(!box.log.contains("Reading "), "no parse anywhere on the compiled path")
    }

    /// Source-level wiring sensor: the three Hallie entry points go through
    /// the shared cache with a store. Skipped when the sources are not
    /// beside the test (e.g. a bundle-only run).
    @Test func hallieEntryPointsUseTheSharedCacheWithAStore() throws {
        let appSources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan", isDirectory: true)
        let files: [(String, String)] = [
            ("HallieAppTurnCoordinator.swift", "store: .app"),
            ("ArchivistChatWindow.swift", "store: .app"),
            ("HallieShellCLI.swift", "store: .production"),
        ]
        for (name, storeArgument) in files {
            let url = appSources.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                throw SkipTestError(reason: "\(name) not beside the test sources")
            }
            #expect(!text.contains(".snapshot().loadFamilyGraph()"),
                    "\(name) still calls the bare parse-every-time loader")
            #expect(text.contains("FamilyGraphSharedCache.shared.graph(") && text.contains(storeArgument),
                    "\(name) must load through FamilyGraphSharedCache with \(storeArgument)")
        }
    }

    struct SkipTestError: Error { let reason: String }
}
