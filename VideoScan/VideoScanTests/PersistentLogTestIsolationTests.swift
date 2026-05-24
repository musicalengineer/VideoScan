import Testing
import Foundation
@testable import VideoScan

// MARK: - appLog Test Isolation
//
// Locks down the DI default that keeps the test suite from polluting
// the user's real ~/Library/Logs/VideoScan/videoscan.log. Catches the
// failure mode where someone removes the test-host fallback in
// VideoScanApp.makeDefaultAppLog (intentionally or via a bad merge)
// and tests start silently leaking log lines into production.
//
// Mechanism (post-refactor): the global `appLog` is a `var: LogSink`,
// initialized to `NullLogSink` when the binary is launched under
// XCTest / Swift Testing. The previous narrow gate inside
// PersistentLog.init has been removed — now the gate is "the default
// sink is a discarder" instead of "the file sink skips start()".
//
// IMPORTANT: only the global `appLog` is replaced. Other PersistentLog
// instances (per-job facedetect_*.log, LogVerificationTests fixtures
// like test_search_*.log) keep working under tests — they're scoped
// to whatever creates them. The InMemoryLogSink test double (see
// LogSinks+Test.swift) is the way to assert on appLog contents
// without writing to disk.

@MainActor
struct PersistentLogTestIsolationTests {

    /// Writing to `appLog` under a test host must not change the size
    /// of ~/Library/Logs/VideoScan/videoscan.log on disk. If this fails,
    /// the appLog DI default has regressed and every future test run
    /// will pollute the user's real log.
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
        // unambiguous — if the default sink weren't a NullLogSink, the
        // file would grow by at least the length of these lines + timestamps.
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
                "videoscan.log grew from \(beforeSize) to \(afterSize) bytes during the test — appLog DI default has regressed")
    }

    /// The default global `appLog` under a test host must be a
    /// non-file-backed sink. This is a stronger structural assertion
    /// than the byte-size check: even if the file *happened* not to
    /// grow (e.g. because the FileHandle was buffered), the sink type
    /// itself is wrong if it's pointing at a real file.
    @Test func defaultAppLogUnderTestsIsNotFileBacked() {
        // No swap — read whatever the global initializer produced.
        #expect(appLog.fileURL == nil,
                "appLog default under tests is file-backed (\(appLog.fileURL?.path ?? "nil")) — DI default regressed; should be NullLogSink")
    }

    /// Other PersistentLog instances (the kind LogVerificationTests
    /// builds for its fixtures) must still work under tests — only
    /// the global `appLog` defaults to NullLogSink. Regression guard
    /// against over-broad gating (e.g. someone makes PersistentLog
    /// itself refuse to open under tests and breaks every other log
    /// fixture).
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

    /// withAppLog must restore the previous sink even if `body` throws.
    /// Tests that crash mid-flight should not leave the global appLog
    /// pointing at a freed InMemoryLogSink.
    @Test func withAppLogRestoresPreviousSinkOnThrow() {
        let originalIsFileBacked = appLog.fileURL != nil
        let inMemory = InMemoryLogSink()

        struct DummyError: Error {}
        #expect(throws: DummyError.self) {
            try withAppLog(inMemory) {
                appLog.write("captured")
                throw DummyError()
            }
        }

        // After throw, appLog must be back to whatever it was before.
        #expect((appLog.fileURL != nil) == originalIsFileBacked,
                "withAppLog failed to restore the previous sink after a throw")
        // And the in-memory sink should have captured the line that
        // ran before the throw — proves the swap took effect.
        #expect(inMemory.lines.contains("captured"))
    }
}
