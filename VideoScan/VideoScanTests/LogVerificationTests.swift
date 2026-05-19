import Testing
import Foundation
import OSLog
@testable import VideoScan

// MARK: - Log Verification Tests
//
// Proves that logging infrastructure actually works — log entries are
// written to disk (PersistentLog) and to the unified log (os.Logger),
// and that we can read them back programmatically.

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

    @Test func buildInfoModeIsDebugInTests() {
        #expect(BuildInfo.buildMode == "debug")
    }

    // ── Integrated: search + log round-trip ────────────────────────

    @Test func searchWithLogVerification() throws {
        let log = PersistentLog(name: "test_search_\(UUID().uuidString.prefix(8))")
        defer {
            log.close()
            try? FileManager.default.removeItem(at: log.url)
        }

        // Simulate an app session with search
        log.start(append: false)
        log.write("app started — \(BuildInfo.summary)")

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
        log.write("Searching for: \(query)")
        let results = pfRecordsMatchingQuery(records, query: query)
        log.write("Search complete — \(results.count) results")

        // Verify search behavior
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.filename.lowercased().contains("donna") })

        log.write("app quitting — \(BuildInfo.summary)")
        log.close()

        // Verify the ENTIRE session is in the log file
        let contents = try String(contentsOf: log.url, encoding: .utf8)
        #expect(contents.contains("app started"))
        #expect(contents.contains("Searching for: donna"))
        #expect(contents.contains("Search complete — 2 results"))
        #expect(contents.contains("app quitting"))
        #expect(contents.contains(BuildInfo.version))
        #expect(contents.contains("Log closed."))

        // Count log lines (excluding header/footer)
        let logLines = contents.components(separatedBy: "\n")
            .filter { $0.hasPrefix("[") }
        #expect(logLines.count == 4, "Expected 4 timestamped log lines, got \(logLines.count)")
    }
}
