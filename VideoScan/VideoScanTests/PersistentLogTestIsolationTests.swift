import Testing
import Foundation
@testable import VideoScan

// MARK: - appLog Test Isolation
//
// Locks down the test-host short-circuit on the global `appLog` so
// running the test suite never appends to the user's real
// ~/Library/Logs/VideoScan/videoscan.log. Catches the failure mode where
// someone removes the gate (intentionally or via a bad merge) and tests
// start silently leaking log lines into production.
//
// IMPORTANT: only the global `appLog` is gated. Other PersistentLog
// instances (per-job facedetect_*.log, LogVerificationTests fixtures
// like test_search_*.log) keep working under tests — they're scoped
// to whatever creates them. The blanket gate that broke
// LogVerificationTests was reverted in favour of this narrow gate.

@MainActor
struct PersistentLogTestIsolationTests {

    /// Writing to `appLog` under a test host must not change the size
    /// of ~/Library/Logs/VideoScan/videoscan.log on disk. If this fails,
    /// the appLog gate has regressed and every future test run will
    /// pollute the user's real log.
    @Test func writingToAppLogDoesNotGrowVideoscanLog() throws {
        let videoscanLog = PersistentLog.logDir.appendingPathComponent("videoscan.log")
        let fm = FileManager.default

        let beforeSize: Int = {
            guard fm.fileExists(atPath: videoscanLog.path),
                  let attrs = try? fm.attributesOfItem(atPath: videoscanLog.path),
                  let size = attrs[.size] as? Int
            else { return 0 }
            return size
        }()

        // Hammer the global appLog. A 10-line burst is small but
        // unambiguous — if the gate weren't in place, the file would
        // grow by at least the length of these lines + timestamps.
        for i in 0..<10 {
            appLog.write("PersistentLogTestIsolationTests sentinel \(i)")
        }

        let afterSize: Int = {
            guard fm.fileExists(atPath: videoscanLog.path),
                  let attrs = try? fm.attributesOfItem(atPath: videoscanLog.path),
                  let size = attrs[.size] as? Int
            else { return 0 }
            return size
        }()

        #expect(afterSize == beforeSize,
                "videoscan.log grew from \(beforeSize) to \(afterSize) bytes during the test — appLog gate has regressed")
    }

    /// Other PersistentLog instances (the kind LogVerificationTests
    /// builds for its fixtures) must still work under tests — only
    /// the global `appLog` is gated. Regression guard against
    /// over-broad gating (e.g. someone moves isRunningTests into
    /// PersistentLog itself and breaks every test that writes a log).
    @Test func otherPersistentLogInstancesStillWorkUnderTests() throws {
        let uniqueName = "ephemeral_writable_log_\(UUID().uuidString.prefix(8))"
        let path = PersistentLog.logDir.appendingPathComponent("\(uniqueName).log")
        try? FileManager.default.removeItem(at: path)
        defer { try? FileManager.default.removeItem(at: path) }

        let log = PersistentLog(name: uniqueName)
        log.start(append: false)
        log.write("This SHOULD be written — non-appLog instances aren't gated.")
        log.close()

        #expect(FileManager.default.fileExists(atPath: path.path),
                "Non-appLog PersistentLog instances should still write under tests")

        let contents = try String(contentsOf: path, encoding: .utf8)
        #expect(contents.contains("SHOULD be written"))
    }
}
