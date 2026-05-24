import Testing
import Foundation
import OSLog
@testable import VideoScan

// MARK: - Log Verification Tests
//
// Proves that logging infrastructure actually works — log entries are
// captured (in-memory via LogSink DI, or on disk via PersistentLog),
// and that we can read them back programmatically.
//
// Post-refactor split:
//   - App-level session/search assertions use `InMemoryLogSink` via
//     `withAppLog(_:)` — no disk I/O, no risk of polluting the user's
//     real videoscan.log.
//   - Low-level PersistentLog tests still hit disk (in temp files) to
//     prove the file implementation works — those use uniquely-named
//     fixture logs, not the global appLog.

@Suite struct LogVerificationTests {

    // ── PersistentLog: file-based logging ──────────────────────────

    @Test func persistentLogWritesAndReadsBack() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("logverify_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let log = PersistentLog(name: "test_verify")
        // Point the log at our temp dir by using internal url directly
        // PersistentLog writes to its `url` property which is based on logDir.
        // Instead, we'll use PersistentLog as-is but with a unique name so
        // it doesn't collide with the real app log.
        log.start(append: false)
        log.write("App started — test verification")
        log.write("Searching for donna")
        log.write("Search complete — 3 results")
        log.write("App quitting — test verification")
        log.close()

        let contents = try String(contentsOf: log.url, encoding: .utf8)

        #expect(contents.contains("App started — test verification"))
        #expect(contents.contains("Searching for donna"))
        #expect(contents.contains("Search complete — 3 results"))
        #expect(contents.contains("App quitting — test verification"))
        #expect(contents.contains("Log closed."))

        // Verify timestamps are present (format: [HH:mm:ss])
        let timestampPattern = try Regex(#"\[\d{2}:\d{2}:\d{2}\]"#)
        #expect(contents.contains(timestampPattern))

        // Verify the header was written
        #expect(contents.contains("VideoScan test_verify log — started"))

        // Cleanup
        try? FileManager.default.removeItem(at: log.url)
    }

    @Test func persistentLogAppendMode() throws {
        let log = PersistentLog(name: "test_append_\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: log.url) }

        log.start(append: false)
        log.write("First launch")
        log.close()

        log.start(append: true)
        log.write("Second launch")
        log.close()

        let contents = try String(contentsOf: log.url, encoding: .utf8)
        #expect(contents.contains("First launch"))
        #expect(contents.contains("Second launch"))
    }

    @Test func persistentLogImmediateFlush() throws {
        let log = PersistentLog(name: "test_flush_\(UUID().uuidString.prefix(8))")
        defer {
            log.close()
            try? FileManager.default.removeItem(at: log.url)
        }

        log.start(append: false)
        log.write("Flushed line")

        // Read BEFORE close — line should already be on disk
        let contents = try String(contentsOf: log.url, encoding: .utf8)
        #expect(contents.contains("Flushed line"))
    }

    // ── OSLogStore: unified log verification ───────────────────────

    @Test func osLoggerWritesAndReadsBack() throws {
        let logger = Logger(subsystem: "Rick-Breen.VideoScan", category: "test.verify")
        let token = "LOGVERIFY_\(UUID().uuidString)"

        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: Date().addingTimeInterval(-1))

        logger.info("\(token, privacy: .public)")

        let allEntries = try store.getEntries(at: position)
        var matched: [OSLogEntryLog] = []
        for entry in allEntries {
            guard let logEntry = entry as? OSLogEntryLog else { continue }
            guard logEntry.subsystem == "Rick-Breen.VideoScan" else { continue }
            guard logEntry.category == "test.verify" else { continue }
            guard logEntry.composedMessage.contains(token) else { continue }
            matched.append(logEntry)
        }

        #expect(!matched.isEmpty, "Expected os.Logger entry with token \(token) in unified log")
        if let entry = matched.first {
            #expect(entry.composedMessage.contains(token))
        }
    }

    // ── BuildInfo verification ─────────────────────────────────────

    @Test func buildInfoVersionIsSet() {
        let version = BuildInfo.version
        #expect(version != "?", "BuildInfo.version should not be '?'")
        #expect(!version.isEmpty)
    }

    @Test func buildInfoSummaryContainsVersion() {
        let summary = BuildInfo.summary
        #expect(summary.contains("v"))
        #expect(summary.contains(BuildInfo.version))
        #expect(summary.contains(BuildInfo.buildMode))
    }

    // ── Integrated: search + log round-trip (via InMemoryLogSink) ──
    //
    // Post-refactor this no longer writes a fixture file. We swap the
    // global `appLog` for an InMemoryLogSink for the duration of the
    // test, exercise production code that writes via `appLog`, and
    // assert on the captured lines. This is the pattern future
    // app-logging tests should follow.

    @Test func searchWithLogVerification() throws {
        let sink = InMemoryLogSink()
        try withAppLog(sink) {
            // Simulate an app session with search — these would normally
            // be emitted by VideoScanModel / search code, exercised here
            // via direct appLog.write calls to keep the test focused on
            // log-capture mechanics, not on the search pipeline itself.
            appLog.write("app started — \(BuildInfo.summary)")

            // Create test records
            let rec1 = VideoRecord()
            rec1.filename = "donna_birthday_2005.mov"
            let rec2 = VideoRecord()
            rec2.filename = "vacation_hawaii.mp4"
            let rec3 = VideoRecord()
            rec3.filename = "donna_graduation.mov"
            let records = [rec1, rec2, rec3]

            // Run search
            let query = "donna"
            appLog.write("Searching for: \(query)")
            let results = pfRecordsMatchingQuery(records, query: query)
            appLog.write("Search complete — \(results.count) results")

            // Verify search behavior
            #expect(results.count == 2)
            #expect(results.allSatisfy { $0.filename.lowercased().contains("donna") })

            appLog.write("app quitting — \(BuildInfo.summary)")
        }

        // Verify the captured session reflects the simulated activity.
        let captured = sink.joined
        #expect(captured.contains("app started"))
        #expect(captured.contains("Searching for: donna"))
        #expect(captured.contains("Search complete — 2 results"))
        #expect(captured.contains("app quitting"))
        #expect(captured.contains(BuildInfo.version))

        // Exactly 4 lines should have been captured.
        #expect(sink.count == 4, "Expected 4 captured log lines, got \(sink.count)")
    }

    // ── InMemoryLogSink unit checks ────────────────────────────────
    //
    // Self-test on the test double — if these break, every other
    // InMemoryLogSink-based assertion is unreliable.

    @Test func inMemoryLogSinkCapturesWritesInOrder() {
        let sink = InMemoryLogSink()
        sink.write("first")
        sink.write("second")
        sink.write("third")
        #expect(sink.lines == ["first", "second", "third"])
        #expect(sink.count == 3)
        #expect(sink.fileURL == nil)
    }

    @Test func inMemoryLogSinkClearEmptiesBuffer() {
        let sink = InMemoryLogSink()
        sink.write("a")
        sink.write("b")
        sink.clear()
        #expect(sink.lines.isEmpty)
        sink.write("c")
        #expect(sink.lines == ["c"])
    }

    @Test func inMemoryLogSinkDiscardsAfterClose() {
        let sink = InMemoryLogSink()
        sink.write("before close")
        sink.close()
        sink.write("after close")
        #expect(sink.lines == ["before close"],
                "Writes after close() should be discarded")
    }

    @Test func nullLogSinkDiscardsEverything() {
        let sink = NullLogSink()
        sink.start(append: true)
        for i in 0..<1000 {
            sink.write("line \(i)")
        }
        sink.flush()
        sink.close()
        // No way to observe — the assertion is "this didn't crash and
        // didn't allocate proportional to 1000 lines". fileURL is the
        // only inspectable property.
        #expect(sink.fileURL == nil)
    }
}
