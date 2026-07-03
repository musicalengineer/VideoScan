// TestHostLogRoutingTests.swift
// Regression suite for the 2026-07-02 test-host log pollution: the nightly
// TestDriver run at 02:15 rotated/clobbered the REAL
// ~/Library/Logs/VideoScan logs from inside test hosts (DashboardState's
// catalogLog truncates catalog.log on resetForScan; /tmp relocate test
// runs wrote into the real relocate.log), destroying live-scan forensics.
//
// Pinned contract: PersistentLog instances constructed WITHOUT an explicit
// directory must route to a per-process temp directory whenever the binary
// is a unit-test host (TestEnvironment.isTestHost — the same gate
// CatalogStore.saveNow uses). Production behavior is unchanged. Tests that
// really want a specific destination inject one via
// PersistentLog(name:directory:).
//
// Red/green: the first two tests FAIL against the pre-fix implementation
// (PersistentLog.logDir was unconditionally ~/Library/Logs/VideoScan).

import Testing
import Foundation
@testable import VideoScan

@MainActor
struct TestHostLogRoutingTests {

    /// The default construction path must not target the real log dir.
    @Test func defaultPersistentLogRoutesAwayFromRealLogDirUnderTests() {
        let log = PersistentLog(name: "routing_probe_\(UUID().uuidString.prefix(8))")
        let realDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VideoScan").path
        #expect(!log.url.path.hasPrefix(realDir + "/"),
                "Under a test host, a default-constructed PersistentLog must NOT point into the real log dir — got \(log.url.path)")
    }

    /// start()+write() must leave no trace in the real log dir — this is
    /// the exact clobber shape (start(append:false) TRUNCATES).
    @Test func defaultPersistentLogWritesNothingIntoRealLogDir() throws {
        let name = "routing_write_probe_\(UUID().uuidString.prefix(8))"
        let realDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VideoScan")
        let realPath = realDir.appendingPathComponent("\(name).log")

        let log = PersistentLog(name: name)
        log.start(append: false)
        log.write("test-host write — must not land in the real log dir")
        log.close()
        defer { try? FileManager.default.removeItem(at: log.url) }

        #expect(!FileManager.default.fileExists(atPath: realPath.path),
                "PersistentLog under a test host created \(realPath.path) in the REAL log dir")
        // ...and the write must still work, at the routed location.
        let contents = try String(contentsOf: log.url, encoding: .utf8)
        #expect(contents.contains("must not land in the real log dir"))
    }

    /// A test that wants a file at a known location injects the directory
    /// explicitly — the routing must not override an explicit destination.
    @Test func explicitDirectoryInjectionIsHonored() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs-log-inject-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let log = PersistentLog(name: "injected", directory: tmp)
        log.start(append: false)
        log.write("explicit destination")
        log.close()

        #expect(log.url.path == tmp.appendingPathComponent("injected.log").path)
        let contents = try String(contentsOf: log.url, encoding: .utf8)
        #expect(contents.contains("explicit destination"))
    }

    /// DashboardState's catalogLog is the writer that truncated the real
    /// catalog.log from the nightly test run (resetForScan → start()).
    @Test func dashboardCatalogLogIsRoutedUnderTests() {
        let ds = DashboardState()
        let realDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VideoScan").path
        let path = ds.catalogLog.url.path
        #expect(!path.hasPrefix(realDir + "/"),
                "DashboardState.catalogLog targets the real catalog.log under a test host: \(path)")
    }
}
