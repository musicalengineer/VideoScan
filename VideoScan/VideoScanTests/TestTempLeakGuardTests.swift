// TestTempLeakGuardTests.swift — a test run frees the disk it took (Rick
// 2026-11-23: "it is lazy programming to take disk space then not free it";
// DECISIONS 2026-11-23). Three leaks, one guard each:
//
//   1. per-test fixture folders: a representative leaker (the media-repair
//      fixture, 7.8 GB left by ~190 runs) is run inside a TestScratch scope
//      and nothing with its prefix may be left in the temp dir afterwards;
//   2. per-PROCESS folders the stores redirect to under a test host
//      (`VideoScanTestLogs-<pid>`, `VideoScan-tests/ledger-<pid>`, …): every
//      one must be recorded with TestHostScratch, whose exit handler removes
//      them (one entry per store here — a new store that names its own
//      per-process folder without TestHostScratch is caught by review, and
//      by the temp-dir count, not by this list);
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
        #expect(!TestScratch.isInsideTemp(root))
        #expect(!TestScratch.isInsideTemp(root.appendingPathComponent("..")))
        #expect(TestScratch.isInsideTemp(root.appendingPathComponent("x")))
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
        let notScratch = URL(fileURLWithPath: NSHomeDirectory())
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

    // MARK: 2 — per process

    /// The per-process folders, named here by hand (not through
    /// TestHostScratch, which would record them and make this pass by itself).
    private static func perProcess(_ name: String) -> URL {
        TestHostScratch.testTempRoot
            .appendingPathComponent("\(name)-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }

    @Test("every store's per-process test folder is recorded for removal when the test host exits")
    func everyPerProcessFolderIsFreedAtExit() {
        // Touch each accessor first: a folder is recorded when it is named.
        _ = PersistentLog.testHostLogDir
        _ = PersistentLog.logDir
        _ = POIStorage.storeDir
        _ = POIStorage.trashDir
        _ = POIStorage.defaultBackupParent(for: POIStorage.storeDir)
        _ = MediaLedger.defaultDirectory
        _ = IgnoredContentStore.defaultDirectory
        _ = ArchiveAuditStore.defaultDirectory
        _ = HoldoutClearStore.defaultDirectory
        _ = PersonRefreshPaths.defaultRoot
        _ = POIProfileAudit.defaultDirectory
        _ = DeleteDuplicatesPlanStore.defaultRoot
        _ = MediaTrash.testHostTrash
        _ = AngelEnvironment.testHostBufferRoot
        _ = AngelEnvironment.testHostEvidenceDirectory
        _ = HallieKindWordsStore.defaultDirectory
        _ = DeletionReceipt.defaultDirectory
        _ = EventsDecisionStore.defaultDirectory
        _ = CatalogSearchIndex.defaultPersistenceURL()
        _ = ScanCheckpoint.directory
        _ = ScanJobsStorage.storeDir
        _ = MetadataCache.defaultPath
        _ = TestHostDetection.sandboxedApplicationSupportRoot(for: "TestTempLeakGuardTests")
        _ = FamilyGraphCompiledStore.production
        _ = PreviewDiskCache.productionRootURL

        let expected: [URL] = [
            Self.perProcess("VideoScanTestLogs"),
            Self.perProcess("VideoScanTestPOI"),
            Self.perProcess("VideoScanTestPOI").deletingLastPathComponent()
                .appendingPathComponent("VideoScanTestPOI-\(ProcessInfo.processInfo.processIdentifier)-backups", isDirectory: true),
            Self.perProcess("VideoScan-tests/poi-trash"),
            Self.perProcess("VideoScan-tests/ledger"),
            Self.perProcess("VideoScan-tests/ignored-content"),
            Self.perProcess("VideoScan-tests/archive-audit"),
            Self.perProcess("VideoScan-tests/holdout-clears"),
            Self.perProcess("VideoScan-tests/person-refresh"),
            Self.perProcess("VideoScan-tests/people-audit"),
            Self.perProcess("VideoScan-tests/delete-duplicates"),
            Self.perProcess("VideoScan-tests/trash"),
            TestHostScratch.testTempRoot.appendingPathComponent(   // its historical spelling
                "test_angel_buffer_pid\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true),
            Self.perProcess("VideoScan-tests/archive-angel"),
            Self.perProcess("VideoScan-tests/hallie-kind"),
            Self.perProcess("VideoScan-tests/deletions"),
            Self.perProcess("VideoScan-tests/events"),
            Self.perProcess("VideoScanTestSearchIndex"),
            Self.perProcess("VideoScanTests"),
            Self.perProcess("VideoScan-test-appsupport"),
            Self.perProcess("VideoScan-test-compiled"),
        ]
        for url in expected {
            #expect(TestHostScratch.shared.isRegistered(url),
                    "\(url.lastPathComponent) is never removed: name it with TestHostScratch.perProcess")
        }
    }

    // MARK: 3 — the real .trash

    @Test("REGRESSION: Delete person under a test host moves the profile into the temp dir, never ~/dev/VideoScan/.trash")
    func deletingAPersonInATestNeverReachesTheRealTrash() throws {
        // Checked BEFORE any move, so this test cannot itself write the real trash.
        try #require(TestScratch.isInsideTemp(POIStorage.trashDir),
                     "POI trash under a test host is \(POIStorage.trashDir.path)")
        let uuid = UUID()
        let folder = POIStorage.folder(forUUID: uuid)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("profile.json"))

        let dest = try #require(POIStorage.trashPOIFolder(uuid: uuid, displayName: "ZZTestPerson-leakguard"))
        defer { try? FileManager.default.removeItem(at: dest) }
        #expect(TestScratch.isInsideTemp(dest), "\(dest.path)")
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}
