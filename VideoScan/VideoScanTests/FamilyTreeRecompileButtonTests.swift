// FamilyTreeRecompileButtonTests.swift
// The 2026-09-03 demo blocker: the Family Tree tab's orange "Recompile"
// banner button did nothing visible and the app log said nothing at all —
// no line when a compile started, none when one ended without promoting.
// Rick lost a day to a button that looked dead.
//
// The existing coverage (HallieNeedsRecompileTests) exercises the
// STANDALONE FamilyTreeRecompileCenter path only. The tab's own
// FamilyTreeLiveModel.recompile() — the button the banner actually calls —
// had no test whatsoever, and that is where all three defects lived:
//
//   1. three early exits sharing one silent `return`;
//   2. no log line when a recompile started, so a 25-second compile on the
//      real pulls left no trace while it ran;
//   3. `guard generation == loadGeneration` compared the load generation
//      AFTER the compile and discarded a generation that was already
//      durable on disk if anything had reloaded meanwhile — banner still
//      up, tree actually compiled, nothing logged.
//
// Dimensions per CLAUDE.md: Logic, Scale (39,250-person tree), Isolation
// (a poisoned shared-cache memo), Sensor (the two log prefixes). "Media
// matrix" does not apply — this path opens no media files, only GEDCOM
// text.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Family Tree — the tab's Recompile button")
struct FamilyTreeRecompileButtonTests {

    final class LogCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [String] { lock.withLock { lines } }
        func contains(_ needle: String) -> Bool { all.contains { $0.contains(needle) } }
        func count(_ needle: String) -> Int { all.filter { $0.contains(needle) }.count }
    }

    static let pullNames = ["familysearch-tree-20generations.ged", "familysearch-donna-20generations.ged"]

    struct Sandbox {
        let root: URL
        let assets: URL
        let gedcom: URL
        let compiled: URL
        let log = LogCapture()
        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
                .appendingPathComponent("FTRecompileButton-\(UUID().uuidString)")
            assets = root.appendingPathComponent("assets", isDirectory: true)
            gedcom = assets.appendingPathComponent("GEDCOM", isDirectory: true)
            compiled = root.appendingPathComponent("compiled", isDirectory: true)
            try FileManager.default.createDirectory(at: gedcom, withIntermediateDirectories: true)
        }
        func configuration() -> FamilyAssetConfiguration {
            FamilyAssetConfiguration(
                roots: FamilyAssetStore.Roots(assets: assets,
                                              thumbnailCache: root.appendingPathComponent("cache")),
                access: .readOnly, legacyGEDCOMDirectory: nil)
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
        /// Rick's live state: two pulls compiled into one generation by an
        /// OLDER codec — refused by this build, sources unchanged on disk.
        func promoteTwoPullsWithAnOldCodec(
            peopleA: Int = 120, generationsA: Int = 5,
            peopleB: Int = 80, generationsB: Int = 4
        ) throws -> (store: FamilyGraphCompiledStore, sources: [URL], people: Int) {
            let a = try write(GedcomSyntheticPedigree.gedcom(people: peopleA, generations: generationsA),
                              as: pullNames[0])
            let b = try write(GedcomSyntheticPedigree.gedcom(people: peopleB, generations: generationsB)
                                .replacingOccurrences(of: "_FSFTID ", with: "_FSFTID D"),
                              as: pullNames[1])
            let store = store()
            let ga = try #require(GedcomFamilyGraph(fileURL: a)), gb = try #require(GedcomFamilyGraph(fileURL: b))
            let merged = ga.merged(with: gb)
            #expect(store.ingest(graph: merged, sources: [a, b]) != nil)
            var pointer = try #require(store.readPointer())
            pointer.codec = 4
            pointer.index = 1
            try JSONEncoder().encode(pointer).write(to: store.pointerURL)
            #expect(!FamilyGraphCompiledStore.versionsMatch(pointer))
            return (store, [a, b], merged.people.count)
        }
        func tearDown() { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - Logic

    /// The whole banner: load → the banner lists the pulls → press →
    /// a generation this build accepts is promoted AND installed.
    @Test @MainActor func pressingRecompilePromotesAndInstalls() async throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let (store, sources, people) = try box.promoteTwoPullsWithAnOldCodec()

        let model = FamilyTreeLiveModel(originalsDirectory: box.gedcom, compiledStore: store)
        await model.loadFromDisk()
        #expect(model.needsRecompile == sources, "the banner must list the two pulls")

        await model.recompile()

        let pointer = try #require(store.readPointer())
        #expect(FamilyGraphCompiledStore.versionsMatch(pointer),
                "the recompile must promote a generation this build accepts: \(box.log.all)")
        #expect(pointer.codec == GedcomCompiledTree.codecVersion)
        #expect(model.needsRecompile.isEmpty, "the banner must clear")
        #expect(model.peopleCount == people, "the promoted tree must install: \(box.log.all)")
        #expect(model.loadWarning == nil, "a successful recompile shows no warning")
    }

    /// Defect 3, the one that made a SUCCESSFUL compile look like a dead
    /// button: anything that reloads while the compile is in flight moved
    /// `loadGeneration`, and the old code then returned without installing
    /// — discarding a generation that was already durable on disk.
    @Test @MainActor func aConcurrentLoadDoesNotDiscardThePromotedGeneration() async throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let (store, sources, people) = try box.promoteTwoPullsWithAnOldCodec()

        let model = FamilyTreeLiveModel(originalsDirectory: box.gedcom, compiledStore: store)
        await model.loadFromDisk()
        #expect(model.needsRecompile == sources)

        // A tab switch / Hallie turn / People-tab probe, racing the compile.
        async let recompiled: Void = model.recompile()
        async let reloaded: Void = model.loadFromDisk()
        _ = await (recompiled, reloaded)

        let pointer = try #require(store.readPointer())
        #expect(FamilyGraphCompiledStore.versionsMatch(pointer),
                "a concurrent reload must not lose the promoted generation: \(box.log.all)")
        #expect(model.needsRecompile.isEmpty,
                "the banner must clear even when a reload raced the compile: \(box.log.all)")
        #expect(model.peopleCount == people)
    }

    /// While the compile runs the tab must be `.loading`, because that is
    /// the only state in which FamilyTreeDemoView renders `loadPhase`.
    /// Without this the whole 25-second operation is invisible.
    @Test @MainActor func theCompileIsVisibleWhileItRuns() async throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let (store, _, _) = try box.promoteTwoPullsWithAnOldCodec()
        let model = FamilyTreeLiveModel(originalsDirectory: box.gedcom, compiledStore: store)
        await model.loadFromDisk()
        #expect(model.loadState != .loading)

        var sawLoading = false
        var sawCaption = false
        let watcher = Task { @MainActor in
            // Poll the published state while the compile runs.
            for _ in 0..<2_000 {
                if model.loadState == .loading { sawLoading = true }
                if model.loadPhase != nil { sawCaption = true }
                if sawLoading && sawCaption { return }
                await Task.yield()
            }
        }
        await model.recompile()
        watcher.cancel()
        #expect(sawLoading, "the tab must be .loading during a recompile or no caption is drawn")
        #expect(sawCaption, "a phase caption must be published during a recompile")
    }

    // MARK: - Sensor: every silent exit now speaks

    /// The regression the Manager asked for by name: a compile that yields
    /// no generation must report an ERROR, not a success-shaped line — and
    /// it must put something on screen.
    @Test @MainActor func aRecompileThatPromotesNothingReportsAnError() async throws {
        let box = try Sandbox(); defer { box.tearDown() }
        var (store, sources, _) = try box.promoteTwoPullsWithAnOldCodec()
        // Force the ingest to refuse, exactly as a failed verification does.
        store.verify = { _, _ in ["forced verification failure (test)"] }

        let model = FamilyTreeLiveModel(originalsDirectory: box.gedcom, compiledStore: store)
        await model.loadFromDisk()
        #expect(model.needsRecompile == sources)

        await model.recompile()

        #expect(box.log.contains(FamilyTreeLiveModel.recompileStartedPrefix),
                "the start of a compile must be logged: \(box.log.all)")
        #expect(box.log.contains(FamilyGraphFileLoader.noGenerationPrefix),
                "the loader must mark the failure at error level: \(box.log.all)")
        #expect(box.log.contains(FamilyTreeLiveModel.recompileFailedPrefix),
                "the tab must mark the failure at error level: \(box.log.all)")
        #expect(model.loadWarning != nil, "the user must see that it failed")
        #expect(model.needsRecompile == sources, "the pulls stay pending after a refused ingest")
        let pointer = try #require(store.readPointer())
        #expect(!FamilyGraphCompiledStore.versionsMatch(pointer), "nothing was promoted")
    }

    /// A successful compile must NEVER emit the error marker — otherwise
    /// the sensor above is worthless.
    @Test @MainActor func aSuccessfulRecompileEmitsNoErrorMarker() async throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let (store, _, _) = try box.promoteTwoPullsWithAnOldCodec()
        let model = FamilyTreeLiveModel(originalsDirectory: box.gedcom, compiledStore: store)
        await model.loadFromDisk()
        await model.recompile()
        #expect(box.log.contains(FamilyTreeLiveModel.recompileStartedPrefix))
        #expect(!box.log.contains(FamilyTreeLiveModel.recompileFailedPrefix), "\(box.log.all)")
        #expect(!box.log.contains(FamilyGraphFileLoader.noGenerationPrefix), "\(box.log.all)")
    }

    /// Pressing the button with nothing pending used to be a bare `return`.
    @Test @MainActor func recompilingWithNothingPendingSaysSo() async throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let (store, _, _) = try box.promoteTwoPullsWithAnOldCodec()
        let model = FamilyTreeLiveModel(originalsDirectory: box.gedcom, compiledStore: store)
        await model.loadFromDisk()
        await model.recompile()                      // clears the banner
        #expect(model.needsRecompile.isEmpty)

        await model.recompile()                      // the second press
        #expect(box.log.contains(FamilyTreeLiveModel.recompileFailedPrefix),
                "a press with nothing pending must not be silent: \(box.log.all)")
        #expect(model.loadWarning != nil)
    }

    /// A model with no compiled store cannot promote anything. It used to
    /// share the same silent `return` as the two cases above.
    @Test @MainActor func aModelWithNoStoreSaysWhyItCannotRecompile() async throws {
        let box = try Sandbox(); defer { box.tearDown() }
        _ = try box.promoteTwoPullsWithAnOldCodec()
        var loader = FamilyGraphFileLoader(originalsDirectory: box.gedcom)
        loader.compiledStore = nil
        let captured = LogCapture()
        loader.log = { captured.append($0) }
        #expect(loader.recompile(sources: [box.gedcom.appendingPathComponent(Self.pullNames[0])]) == nil)
        #expect(captured.contains(FamilyGraphFileLoader.noGenerationPrefix),
                "a storeless loader must say it cannot promote: \(captured.all)")
    }

    /// A second request while one is running must not read as "already
    /// compiled — nothing to do". Order-independent by construction: which
    /// of the two calls wins the race is a scheduling detail, but exactly
    /// one must promote, and a call that was refused BECAUSE one was
    /// running must say `.alreadyRunning` — never `.nothingPending`.
    @Test @MainActor func anOverlappingRequestIsNeverReportedAsNothingToDo() async throws {
        let box = try Sandbox(); defer { box.tearDown() }
        // Big enough that the in-flight window is real (seconds, not µs).
        let (store, _, _) = try box.promoteTwoPullsWithAnOldCodec(
            peopleA: 20_000, generationsA: 16, peopleB: 20_000, generationsB: 16)
        let cache = FamilyGraphSharedCache(log: { box.log.append($0) })
        let center = FamilyTreeRecompileCenter()

        async let first = center.recompile(configuration: box.configuration(), store: store,
                                           cache: cache, progress: { _ in })
        // Let the first call reach its first suspension point, which is
        // after it has taken `isRunning`.
        for _ in 0..<8 { await Task.yield() }
        let second = await center.recompile(configuration: box.configuration(), store: store,
                                            cache: cache, progress: { _ in })
        let outcomes = [await first, second]

        #expect(outcomes.filter { $0 == .promoted }.count == 1,
                "exactly one of two overlapping requests promotes: \(outcomes)")
        #expect(!outcomes.contains(.failed), "neither call may fail: \(outcomes) \(box.log.all)")
        if box.log.contains("already running; ignored") {
            #expect(outcomes.contains(.alreadyRunning),
                    "a request refused because one was running must say so, not 'nothing to do': \(outcomes)")
        }
        #expect(FamilyGraphCompiledStore.versionsMatch(try #require(store.readPointer())))
    }

    // MARK: - Isolation: a poisoned shared-cache memo

    /// The production tab loads through `FamilyGraphSharedCache`. A memo
    /// taken BEFORE the recompile must not survive it — otherwise the tree
    /// is compiled and every consumer still says "needs recompiling".
    @Test @MainActor func aStaleSharedCacheMemoDoesNotSurviveTheRecompile() async throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let (store, sources, _) = try box.promoteTwoPullsWithAnOldCodec()
        let cache = FamilyGraphSharedCache(log: { box.log.append($0) })

        // Poison: take the memo while the tree is still refused.
        #expect(cache.needsRecompile(for: box.configuration(), store: store) == sources)
        let runsBefore = cache.loaderRuns

        let outcome = await FamilyTreeRecompileCenter().recompile(
            configuration: box.configuration(), store: store, cache: cache, progress: { _ in })
        #expect(outcome == .promoted, "\(box.log.all)")
        #expect(cache.needsRecompile(for: box.configuration(), store: store).isEmpty,
                "the cache must not keep serving the pre-recompile answer: \(box.log.all)")
        #expect(cache.loaderRuns > runsBefore)
        let loaded = try #require(cache.load(for: box.configuration(), store: store))
        #expect(loaded.compiled)
    }

    // MARK: - Scale

    /// Rick's real tree is 39,250 people. A recompile that is fine on a
    /// 200-person fixture and hopeless at production size is not a fix.
    /// Budget is deliberately generous (the real 193 MB of GEDCOM text
    /// parses in ~21 s in Debug); this guards the ORDER OF MAGNITUDE and
    /// pins that nothing here is accidentally O(people²).
    @Test @MainActor func recompilesAProductionSizedTreeWithinBudget() async throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let (store, sources, people) = try box.promoteTwoPullsWithAnOldCodec(
            peopleA: 20_000, generationsA: 16, peopleB: 20_000, generationsB: 16)
        #expect(people >= 39_000, "the fixture must be production-sized: \(people)")

        let model = FamilyTreeLiveModel(originalsDirectory: box.gedcom, compiledStore: store)
        await model.loadFromDisk()
        #expect(model.needsRecompile == sources)

        let clock = ContinuousClock()
        let began = clock.now
        await model.recompile()
        let elapsed = clock.now - began

        #expect(model.needsRecompile.isEmpty, "\(box.log.all)")
        #expect(model.peopleCount == people)
        let pointer = try #require(store.readPointer())
        #expect(pointer.codec == GedcomCompiledTree.codecVersion)
        #expect(elapsed < .seconds(180),
                "a production-sized recompile must stay in the tens of seconds, took \(elapsed)")
    }

    // MARK: - Rick's actual tree (opt-in, never in CI)

    /// The real 66 MB + 126 MB FamilySearch pulls, recompiled through the
    /// SAME code path the banner button uses, into a scratch compiled root
    /// under /private/tmp. Never touches Application Support.
    ///
    /// Opt in by writing the marker file below:
    ///   {"compiledRoot": "...", "gedcomDirectory": "...", "expectedPeople": 39250}
    /// Absent (every other machine, and CI) the test is SKIPPED, visibly —
    /// not silently passed.
    struct RealTree: Codable {
        let compiledRoot: String
        let gedcomDirectory: String
        let expectedPeople: Int
        static let markerURL = URL(fileURLWithPath: "/private/tmp/videoscan-real-tree-recompile.json")
        static var marker: RealTree? {
            guard let data = try? Data(contentsOf: markerURL) else { return nil }
            return try? JSONDecoder().decode(RealTree.self, from: data)
        }
    }

    @Test(.enabled(if: RealTree.marker != nil,
                   "no /private/tmp/videoscan-real-tree-recompile.json marker on this machine"))
    @MainActor func recompilesRicksRealTree() async throws {
        let marker = try #require(RealTree.marker)
        let compiledRoot = URL(fileURLWithPath: marker.compiledRoot, isDirectory: true)
        #expect(compiledRoot.path.hasPrefix("/private/tmp"),
                "the real-tree run must never write into Application Support")

        let capture = LogCapture()
        var store = FamilyGraphCompiledStore(root: compiledRoot)
        store.log = { capture.append($0) }
        let pointerBefore = try #require(store.readPointer())
        #expect(!FamilyGraphCompiledStore.versionsMatch(pointerBefore),
                "the seeded pointer must be the refused one Rick had (3/5/2)")

        let model = FamilyTreeLiveModel(
            originalsDirectory: URL(fileURLWithPath: marker.gedcomDirectory, isDirectory: true),
            compiledStore: store)
        await model.loadFromDisk()
        #expect(model.needsRecompile.count == 2,
                "the two real pulls must be reported as pending: \(capture.all)")

        let clock = ContinuousClock()
        let began = clock.now
        await model.recompile()
        let elapsed = clock.now - began

        let pointer = try #require(store.readPointer())
        #expect(FamilyGraphCompiledStore.versionsMatch(pointer), "\(capture.all)")
        #expect(pointer.codec == GedcomCompiledTree.codecVersion)
        #expect(model.needsRecompile.isEmpty, "the banner must clear: \(capture.all)")
        #expect(model.peopleCount == marker.expectedPeople,
                "expected \(marker.expectedPeople), got \(model.peopleCount)")
        #expect(!capture.contains(FamilyTreeLiveModel.recompileFailedPrefix), "\(capture.all)")
        let manifest = try #require(store.readManifest(pointer.current))
        #expect(manifest.verification.isEmpty)
        print("REAL TREE: \(model.peopleCount) people, \(manifest.familyCount) families, "
              + "codec \(manifest.codec), schema \(manifest.schema), index \(manifest.index), "
              + "generation \(manifest.generation), \(elapsed)")
    }
}
