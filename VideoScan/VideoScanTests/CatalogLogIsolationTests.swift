// CatalogLogIsolationTests.swift
// GH #211 (2026-09-27). Under a test host every VideoScanModel wrote the
// same VideoScanTestLogs-<pid>/catalog.log, and DashboardState.resetForScan()
// re-creates that file with an overwrite-mode start() — 295 times in one
// wide run. A test that writes a line and reads it back
// (InferredDatePropagationTests.unwindIsIdempotent) could read the file
// just after another suite truncated it: red in wide parallel runs, green
// alone and on CI.
//
// The fix is a per-model log directory (VideoScanModel(logDirectory:)).
// The sensor below reproduces the race on purpose: a poisoner thread
// hammers overwrite-mode start() on the SHARED catalog.log path — exactly
// what another suite's resetForScan() does — while the test writes and
// reads back its own lines. With the shared path (the pre-fix model) the
// reader misses lines; with an injected directory it never can.

import Foundation
import Testing
@testable import VideoScan

@MainActor
@Suite("Catalog log isolation — GH #211")
struct CatalogLogIsolationTests {

    private func scratchDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatalogLogIsolationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Production default unchanged: no argument → the routed default
    /// directory (the per-process test dir here, ~/Library/Logs/VideoScan
    /// in the app). An injected directory is honoured exactly.
    @Test func defaultStaysRoutedAndInjectionIsHonoured() throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(DashboardState().catalogLog.url
                == PersistentLog.logDir.appendingPathComponent("catalog.log"))
        let model = VideoScanModel(logDirectory: dir)
        #expect(model.dashboard.catalogLog.url == dir.appendingPathComponent("catalog.log"))
        model.dashboard.log("gh211-injected-line")
        let text = try String(contentsOf: model.dashboard.catalogLog.url, encoding: .utf8)
        #expect(text.contains("gh211-injected-line"))
    }

    /// The race itself. 400 write-then-read rounds against a thread that
    /// truncates the shared catalog.log as fast as it can. Every round must
    /// read back its own line. Red with `VideoScanModel()` (shared file —
    /// verified 2026-09-27 before the fix), green with an injected dir.
    @Test func ownLinesSurviveAConcurrentOverwriteStartOnTheSharedLog() throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = VideoScanModel(logDirectory: dir)

        // The poisoner: what any other suite's resetForScan() does to the
        // shared test-host catalog.log. Plain Thread + lock-guarded flag —
        // think std::thread with a std::atomic<bool> stop flag.
        let poisoner = SharedLogPoisoner()
        poisoner.start()
        defer { poisoner.stopAndJoin() }

        let marker = "gh211-\(UUID().uuidString.prefix(8))"
        var misses = 0
        for i in 0..<400 {
            let line = "\(marker) round \(i)"
            model.dashboard.log(line)       // synchronous write + fsync
            let text = (try? String(contentsOf: model.dashboard.catalogLog.url, encoding: .utf8)) ?? ""
            if !text.contains(line) { misses += 1 }
        }
        #expect(poisoner.truncations > 0, "the poisoner must actually have run")
        #expect(misses == 0, "\(misses) of 400 read-backs lost their own line to a concurrent overwrite start()")
    }
}

/// Truncates the shared (default-routed) catalog.log in a tight loop on a
/// background thread until stopped.
private final class SharedLogPoisoner: @unchecked Sendable {
    private let lock = NSLock()
    private var stop = false
    private var count = 0
    private let done = DispatchSemaphore(value: 0)

    var truncations: Int { lock.lock(); defer { lock.unlock() }; return count }

    func start() {
        let thread = Thread { [self] in
            let shared = PersistentLog(name: "catalog")   // the routed default path
            while true {
                lock.lock(); let halt = stop; lock.unlock()
                if halt { break }
                shared.start()                            // overwrite mode = resetForScan()
                lock.lock(); count += 1; lock.unlock()
            }
            shared.close()
            done.signal()
        }
        thread.start()
    }

    func stopAndJoin() {
        lock.lock(); stop = true; lock.unlock()
        done.wait()
    }
}
