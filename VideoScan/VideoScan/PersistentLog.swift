import Foundation

/// Write-through log file for crash-resilient logging.
/// Each line is flushed to disk immediately via FileHandle — no buffering.
/// If the app crashes, the log contains everything up to the last written line.
///
/// Usage:
///   let log = PersistentLog(name: "catalog")   // ~/Library/Logs/VideoScan/catalog.log
///   log.start()                                  // opens file, overwrites previous run
///   log.write("Starting scan...")                // immediate disk write
///   log.close()                                  // flushes and closes
///
/// Conforms to `LogSink` so the global `appLog` symbol can be swapped to
/// a Null or in-memory sink under tests without touching call sites.
/// See `LogSink.swift` for the DI rationale.
final class PersistentLog: LogSink, @unchecked Sendable {

    /// The REAL production log directory. Only production code paths (and
    /// tests asserting non-pollution) should reference this directly —
    /// writers go through `logDir`.
    static let productionLogDir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/VideoScan")

    /// Per-process scratch directory used when the binary is a unit-test
    /// host. Process-unique so parallel test hosts never clobber each other.
    static let testHostLogDir: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("VideoScanTestLogs-\(ProcessInfo.processInfo.processIdentifier)")

    /// Routing default for every log-dir consumer (PersistentLog itself,
    /// discovery-audit sidecars, dossier smear quarantine, bundle import
    /// logs). Test hosts are diverted to `testHostLogDir` — the nightly
    /// TestDriver run used to truncate the REAL catalog.log / relocate.log
    /// from inside test hosts (2026-07-02), destroying live-scan forensics.
    /// Same gate as CatalogStore.saveNow (TestEnvironment.isTestHost).
    /// Ensures the directory exists on every access (the old `static let`
    /// created it exactly once as a side effect).
    static var logDir: URL {
        let dir = TestEnvironment.isTestHost ? testHostLogDir : productionLogDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    let name: String
    let url: URL
    private var handle: FileHandle?
    private let lock = NSLock()

    /// - Parameter directory: explicit destination override. Nil (the
    ///   default) routes through `logDir` — production dir normally, the
    ///   per-process temp dir under a test host. Tests that genuinely want
    ///   a file at a known location inject their own directory.
    init(name: String, directory: URL? = nil) {
        self.name = name
        let dir = directory ?? Self.logDir
        self.url = dir.appendingPathComponent("\(name).log")
    }

    /// LogSink conformance — file sinks always have a URL.
    var fileURL: URL? { url }

    /// Open the log file.
    /// - Parameter append: if false (default), overwrites previous content (per-job logs).
    ///   If true, opens in append mode so launches accumulate (used by `videoscan.log`).
    /// Writes a header with timestamp and app version.
    func start(append: Bool = false) {
        lock.lock()
        defer { lock.unlock() }

        // The parent dir may not exist yet (injected directories, or the
        // routed temp dir on first use).
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)

        if append {
            // Create the file if it doesn't exist; otherwise open at EOF.
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
        } else {
            // Create or truncate the file
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try? FileHandle(forWritingTo: url)
        }

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let header = "VideoScan \(name) log — started \(fmt.string(from: Date()))\n"
            + "─────────────────────────────────────────────\n"
        if let data = header.data(using: .utf8) {
            handle?.write(data)
        }
    }

    /// Write a line to the log file. Immediate flush — crash-safe.
    func write(_ line: String) {
        lock.lock()
        defer { lock.unlock() }

        guard let handle else { return }
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        let stamped = "[\(fmt.string(from: Date()))] \(line)\n"
        if let data = stamped.data(using: .utf8) {
            handle.write(data)
            // Sync to disk immediately — no OS buffering
            try? handle.synchronize()
        }
    }

    /// LogSink conformance — PersistentLog flushes on every write(), so
    /// this is a no-op except as a safety net in case future buffering
    /// is introduced. Cheap to call.
    func flush() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.synchronize()
    }

    /// Close the log file.
    func close() {
        lock.lock()
        defer { lock.unlock() }

        if let handle {
            let footer = "─────────────────────────────────────────────\n"
                + "Log closed.\n"
            if let data = footer.data(using: .utf8) {
                handle.write(data)
            }
            try? handle.close()
        }
        handle = nil
    }

    deinit {
        try? handle?.close()
    }
}
