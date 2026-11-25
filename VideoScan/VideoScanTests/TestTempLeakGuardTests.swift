// TestTempLeakGuardTests.swift — a test run frees the disk it took (Rick
// 2026-11-23: "it is lazy programming to take disk space then not free it";
// DECISIONS 2026-11-23). Three leaks, one guard each:
//
//   1. per-test fixture folders: a representative leaker (the media-repair
//      fixture, 7.8 GB left by ~190 runs) is run inside a TestScratch scope
//      and nothing with its prefix may be left in the temp dir afterwards;
//   2. per-PROCESS folders the stores redirect to under a test host
//      (`VideoScanTestLogs-<pid>`, `VideoScan-tests/ledger-<pid>`, …): every
//      one lies under the test temp root, which the RUNNER deletes after the
//      run — the test host deletes none of them (one entry per store here; a
//      new store is caught by review and by the runner's leftover report);
//   3. a test's "Delete person" moved the profile into the REAL
//      ~/dev/VideoScan/.trash (51 `POI-zztestperson-*` since 11/09): under a
//      test host the POI trash must be inside the temp dir.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("Test temp folders are freed — per test, per process, never the real .trash")
struct TestTempLeakGuardTests {

    private static func entries(withPrefix prefix: String) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: TestHostScratch.testTempRoot.path)) ?? []
        return Set(names.filter { $0.hasPrefix(prefix) })
    }

    // MARK: 1 — per test

    @Test("GUARD: a media-repair fixture folder is gone when its test's scope ends (before/after listing of the temp dir)")
    func aRepairFixtureFolderIsGoneWhenTheTestEnds() throws {
        let prefix = "test_media_repair_leakguard_"
        let before = Self.entries(withPrefix: prefix)
        let scope = TestScratch.Scope()
        let dir = try TestScratch.$current.withValue(scope) { () throws -> URL in
            let made = try RepairFixtures.makeDir("leakguard")
            try Data(repeating: 7, count: 4096).write(to: made.appendingPathComponent("test_payload.bin"))
            return made
        }
        // The guard must not itself leak when it is red.
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(FileManager.default.fileExists(atPath: dir.path), "made while the test runs")
        scope.removeAll()   // what .scratchCleanup does when a test case ends
        #expect(!FileManager.default.fileExists(atPath: dir.path), "left behind: \(dir.path)")
        #expect(Self.entries(withPrefix: prefix).subtracting(before).isEmpty)
    }

    // Rick 2026-11-23 (slice 3): a full sealed run still left 815 entries in the SYSTEM temp dir from fixtures
    // that built paths on NSTemporaryDirectory() directly. The representative: the person-finder cache
    // fixture (57 `pf_cache_test_*` per run). Its database must live in test scratch and be gone when the
    // test's scope ends — nothing new in the system temp dir, nothing left in the test temp root.
    @Test("GUARD: a fixture that opens a database leaves nothing in the system temp dir or the test root once its test ends")
    func aDatabaseFixtureLeavesNothingInTheSystemTemp() throws {
        let prefix = "pf_cache_test_"
        func listing(_ dir: String) -> Set<String> {
            Set(((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix(prefix) })
        }
        let system = NSTemporaryDirectory(), root = TestHostScratch.testTempRoot.path
        let beforeSystem = listing(system), beforeRoot = listing(root)
        // The guard must not itself leak when it is red.
        defer {
            for name in listing(system).subtracting(beforeSystem) {
                try? FileManager.default.removeItem(atPath: (system as NSString).appendingPathComponent(name))
            }
        }
        let scope = TestScratch.Scope()
        TestScratch.$current.withValue(scope) {
            let cache = PersonFinderCacheTests.makeTempCache()
            _ = cache.lookup(key: PersonFinderCache.CacheKey(videoPath: "/x/test.mov", fileSize: 1,
                                                              modDate: Date(timeIntervalSince1970: 1), personName: "test",
                                                              engine: "test", threshold: 0.5, refHash: "leakguard"))
        }
        scope.removeAll()   // what .scratchCleanup does when a test case ends
        #expect(listing(system).subtracting(beforeSystem).isEmpty, "left in the system temp dir")
        #expect(listing(root).subtracting(beforeRoot).isEmpty, "left in the test temp root")
    }

    // Slice 4: the long tail — fixtures that hand a catalog store a folder named on the system temp dir
    // (DateReview-f2 ×8 per full run, and the same shape in ~40 files: CatalogStore(directory:) creates it at
    // init). The representative: DateReviewFixtures.model. Same before/after listing as above.
    @MainActor
    @Test("GUARD: a fixture whose catalog store makes its own folder leaves nothing in the system temp dir or the test root")
    func aCatalogStoreFixtureLeavesNothingInTheSystemTemp() throws {
        let prefix = "DateReview-leakguard-"
        func listing(_ dir: String) -> Set<String> {
            Set(((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix(prefix) })
        }
        let system = NSTemporaryDirectory(), root = TestHostScratch.testTempRoot.path
        let beforeSystem = listing(system), beforeRoot = listing(root)
        defer {   // the guard must not itself leak when it is red
            for name in listing(system).subtracting(beforeSystem) {
                try? FileManager.default.removeItem(atPath: (system as NSString).appendingPathComponent(name))
            }
        }
        let scope = TestScratch.Scope()
        TestScratch.$current.withValue(scope) {
            let model = DateReviewFixtures.model("leakguard")
            #expect(FileManager.default.fileExists(atPath: (model.catalogStore.fileLocation as NSString).deletingLastPathComponent))
        }
        scope.removeAll()   // what .scratchCleanup does when a test case ends
        #expect(listing(system).subtracting(beforeSystem).isEmpty, "left in the system temp dir")
        #expect(listing(root).subtracting(beforeRoot).isEmpty, "left in the test temp root")
    }

    @Test("a scope never removes anything outside the test temp root")
    func aScopeRemovesOnlyInsideTheTempRoot() throws {
        let root = TestHostScratch.testTempRoot
        let scope = TestScratch.Scope()
        let outside = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        scope.record(outside)
        scope.record(root)
        scope.removeAll()
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(FileManager.default.fileExists(atPath: root.path))
        // Only direct children of the root are made (Codex 2026-11-23 r2 #3); the Issue it records is expected.
        var refused = false
        withKnownIssue {
            do { _ = try TestScratch.directory(named: "a/b") } catch is TestScratch.NotAFlatName { refused = true }
        }
        #expect(refused)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("a").path))
    }

    @Test("the app's scratch honours the runner's VIDEOSCAN_TEST_TMP (else the user temp dir)")
    func scratchHonoursTheRunnersRoot() throws {
        let env = ProcessInfo.processInfo.environment["VIDEOSCAN_TEST_TMP"] ?? ""
        let marked = env.hasPrefix("/") && env != "/"
            && FileManager.default.fileExists(atPath: (env as NSString).appendingPathComponent(TestHostScratch.rootMarkerName))
        let expected = marked ? URL(fileURLWithPath: env).standardizedFileURL.path
            : URL(fileURLWithPath: NSTemporaryDirectory()).path
        #expect(TestScratch.tempRoot.path == expected)
        #expect(PersistentLog.testHostLogDir.deletingLastPathComponent().path == expected)
        #expect(MediaLedger.defaultDirectory.deletingLastPathComponent().deletingLastPathComponent().path == expected)
    }

    // Codex 2026-11-23 #352 P1-3: the test-host trash is EMPTIED at exit, so a real input moved there would be
    // erased. Under a test host it refuses any source that is not test scratch. The probe is a path that does not
    // exist under the home folder: nothing real is touched, and the refusal must be the guard's, not "no such file".
    @Test("under a test host, MediaTrash refuses a source outside test scratch (the test trash is emptied at exit)")
    func theTestTrashRefusesNonScratchSources() {
        // The REAL account's ~/Movies (password database), not NSHomeDirectory(): a sealed run's home is made in
        // the per-user temp dir (sealed_home.make_home, 2026-11-24), so <sealed home>/Movies IS scratch. Never
        // created; the move is refused before anything is touched.
        let realHome = String(cString: getpwuid(getuid()).pointee.pw_dir)
        let notScratch = URL(fileURLWithPath: realHome)
            .appendingPathComponent("Movies/never-a-real-file-\(UUID().uuidString).mov")
        #expect(!FileManager.default.fileExists(atPath: notScratch.path))
        #expect(throws: MediaTrash.TestHostRefusal.self) { _ = try MediaTrash.move(notScratch) }
    }

    @Test("under a test host, a scratch source still goes to the test trash")
    func theTestTrashTakesScratchSources() throws {
        let dir = TestHostScratch.testTempRoot.appendingPathComponent("trash-guard-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("a.mov")
        try Data([1, 2, 3]).write(to: f)
        let landed = try MediaTrash.move(f)
        #expect(FileManager.default.fileExists(atPath: landed.path) && !FileManager.default.fileExists(atPath: f.path))
        try? FileManager.default.removeItem(at: landed)
    }

    /// A synthetic folder OUTSIDE both scratch roots (the test temp root and the user temp dir): /private/tmp.
    /// Only the fixture the test makes there is ever at stake.
    private static func outsideScratch(_ tag: String) throws -> URL {
        let dir = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("videoscan-leakguard-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(!TestHostScratch.isScratch(dir))
        return dir
    }

    // Codex 2026-11-23 round 2 #2: isScratch folded `..` before resolving symlinks, so S/link/../victim.mov with
    // S/link → O/child was approved as S/victim.mov while the move took O/victim.mov.
    @Test("REGRESSION: MediaTrash refuses S/link/../victim.mov when the link leads out of scratch")
    func theTestTrashRefusesADotDotThroughASymlink() throws {
        let o = try Self.outsideScratch("dotdot")
        let s = TestHostScratch.testTempRoot.appendingPathComponent("leakguard-S-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: o); try? FileManager.default.removeItem(at: s) }
        try FileManager.default.createDirectory(at: o.appendingPathComponent("child"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: s, withIntermediateDirectories: true)
        let victim = o.appendingPathComponent("victim.mov")
        try Data([1, 2, 3]).write(to: victim)
        try FileManager.default.createSymbolicLink(at: s.appendingPathComponent("link"),
                                                   withDestinationURL: o.appendingPathComponent("child"))
        let source = URL(fileURLWithPath: s.path + "/link/../victim.mov")
        #expect(!TestHostScratch.isScratch(source))
        var landed: URL?
        #expect(throws: MediaTrash.TestHostRefusal.self) { landed = try MediaTrash.move(source) }
        if let landed { try? FileManager.default.removeItem(at: landed) }   // red only: the fixture was moved
        #expect(FileManager.default.fileExists(atPath: victim.path), "the outside file was moved into the test trash")
    }

    // Codex 2026-11-23 round 2 #4: passing the default test trash EXPLICITLY skipped the guard (it only ran when
    // the override was nil). The guard now follows the effective destination.
    @Test("REGRESSION: Delete person with the default test trash passed explicitly still refuses a non-scratch store")
    func explicitDefaultTrashStillRefusesANonScratchSource() throws {
        let store = try Self.outsideScratch("poi-store")
        defer { try? FileManager.default.removeItem(at: store) }
        let uuid = UUID()
        let folder = store.appendingPathComponent(POIStorage.folderName(for: uuid), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("profile.json"))
        let moved = POIStorage.trashPOIFolder(uuid: uuid, displayName: "ZZTestPerson-explicit",
                                              storeOverride: store, trashOverride: POIStorage.trashDir)
        if let moved { try? FileManager.default.removeItem(at: moved) }      // red only
        #expect(moved == nil, "moved a non-scratch folder into the test trash")
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    // The one decision behind the POI trash and the bundle importer's swap (the importer's swap needs a full
    // bundle install to reach, so its path is pinned here through the shared decision).
    @Test("the test-trash decision: under a test host every trash takes only scratch; production never refuses")
    func testTrashDecision() throws {
        let outside = try Self.outsideScratch("decision")
        defer { try? FileManager.default.removeItem(at: outside) }
        let scratchSource = TestHostScratch.testTempRoot.appendingPathComponent("decision-\(UUID().uuidString)")
        let realSource = outside.appendingPathComponent("person")
        for trash in [POIStorage.trashDir, MediaTrash.testHostTrash,
                      URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("any-temp-trash")] {
            #expect(POIStorage.testHostRefusesTrashing(source: realSource, into: trash, isTestHost: true), "\(trash.path)")
            #expect(!POIStorage.testHostRefusesTrashing(source: scratchSource, into: trash, isTestHost: true))
            #expect(!POIStorage.testHostRefusesTrashing(source: realSource, into: trash, isTestHost: false), "production")
        }
        // Codex 2026-11-23 round 3: the destination is not a safe test — the scratch ROOT itself and a sibling of it
        // (<sealed home>/trash) are inside what the runner deletes. Under a test host a non-scratch source is refused
        // whatever the destination.
        for trash in [TestHostScratch.testTempRoot,
                      TestHostScratch.testTempRoot.deletingLastPathComponent().appendingPathComponent("trash"),
                      outside.appendingPathComponent("trash")] {
            #expect(POIStorage.testHostRefusesTrashing(source: realSource, into: trash, isTestHost: true), "\(trash.path)")
        }
    }

    // Codex 2026-11-23 round 2 #3 (app copy of TestScratch).
    @Test("a scope never removes through a symlinked parent (only direct children of the root)")
    func scopeNeverRemovesThroughASymlink() throws {
        let root = TestScratch.tempRoot
        let outside = root.appendingPathComponent("leakguard-outside-\(UUID().uuidString)", isDirectory: true)
        let link = root.appendingPathComponent("leakguard-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: link); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside.appendingPathComponent("victim"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let scope = TestScratch.Scope()
        scope.record(link.appendingPathComponent("victim", isDirectory: true))
        scope.removeAll()
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("victim").path),
                "removed through a symlinked parent")
    }

    // MARK: 2 — per process

    // Codex 2026-11-23 rounds 1–2: deleting by path at exit was bypassable, so the test host deletes none of
    // these — each lies under the test temp root, which the runner deletes after the run (by hand: the user temp
    // dir, which macOS clears).
    @Test("every store's per-process test folder lies under the test temp root (so the runner frees it)")
    func everyPerProcessFolderIsUnderTheTestTempRoot() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let folders: [URL] = [
            PersistentLog.testHostLogDir,
            PersistentLog.logDir,
            POIStorage.storeDir,
            POIStorage.trashDir,
            POIStorage.defaultBackupParent(for: POIStorage.storeDir),
            MediaLedger.defaultDirectory,
            IgnoredContentStore.defaultDirectory,
            ArchiveAuditStore.defaultDirectory,
            HoldoutClearStore.defaultDirectory,
            PersonRefreshPaths.defaultRoot,
            POIProfileAudit.defaultDirectory,
            DeleteDuplicatesPlanStore.defaultRoot,
            MediaTrash.testHostTrash,
            AngelEnvironment.testHostBufferRoot,
            AngelEnvironment.testHostEvidenceDirectory,
            HallieKindWordsStore.defaultDirectory,
            DeletionReceipt.defaultDirectory,
            EventsDecisionStore.defaultDirectory,
            CatalogSearchIndex.defaultPersistenceURL(),
            ScanCheckpoint.directory,
            ScanJobsStorage.storeDir,
            URL(fileURLWithPath: MetadataCache.defaultPath),
            try #require(TestHostDetection.sandboxedApplicationSupportRoot(for: "TestTempLeakGuardTests")),
            FamilyGraphCompiledStore.production.root,
            PreviewDiskCache.productionRootURL,
        ]
        let root = TestHostScratch.testTempRoot.path
        for url in folders {
            #expect(url.path.hasPrefix(root + "/"), "\(url.path) is not under the test temp root \(root)")
            #expect(url.path.contains("\(pid)"), "\(url.path) is not per process")
        }
    }

    // MARK: 3 — the real .trash

    @Test("REGRESSION: Delete person under a test host moves the profile into the temp dir, never ~/dev/VideoScan/.trash")
    func deletingAPersonInATestNeverReachesTheRealTrash() throws {
        // Checked BEFORE any move, so this test cannot itself write the real trash.
        try #require(TestHostScratch.isScratch(POIStorage.trashDir),
                     "POI trash under a test host is \(POIStorage.trashDir.path)")
        let uuid = UUID()
        let folder = POIStorage.folder(forUUID: uuid)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("profile.json"))

        let dest = try #require(POIStorage.trashPOIFolder(uuid: uuid, displayName: "ZZTestPerson-leakguard"))
        defer { try? FileManager.default.removeItem(at: dest) }
        #expect(TestHostScratch.isScratch(dest), "\(dest.path)")
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}
