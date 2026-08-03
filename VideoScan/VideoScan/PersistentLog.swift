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

    // MARK: Rotation policy (Rick 2026-08-02)
    //
    // Append-mode logs (videoscan.log) rotate instead of growing forever
    // (the main log hit 411 MB with no cap). Policy: when the file
    // exceeds `rotationThresholdBytes` — checked at start() and
    // periodically during long sessions — it is renamed to
    // `<name>-yyyyMMdd-HHmmss.log` beside itself, gzip'd ASYNCHRONOUSLY
    // (a detached /usr/bin/gzip; rename+reopen stays fast under the
    // write lock), and a fresh log begins. Archives are KEPT FOREVER —
    // they are the "what happened to file X last month" forensics; Rick
    // deletes manually if ever needed. Overwrite-mode logs (per-job)
    // are self-capping and never rotate.

    /// 64 MB — a month-ish of heavy RD use per archive, gzips to ~5 MB.
    static let defaultRotationThresholdBytes: Int = 64 * 1024 * 1024

    /// Instance override seam so tests exercise rotation with a few KB
    /// instead of writing 64 MB. Production never changes it.
    var rotationThresholdBytes: Int = PersistentLog.defaultRotationThresholdBytes

    /// Re-check the live file size every N writes (size check is a
    /// stat; the counter keeps it off the per-line hot path).
    private static let rotationCheckEvery = 2048
    private var writesSinceRotationCheck = 0
    private var rotating = false

    /// If the file at `url` exceeds the threshold, archive it and leave
    /// no file at `url`. Caller reopens. MUST hold `lock`.
    private func rotateIfOversized() {
        guard !rotating else { return }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        guard bytes > rotationThresholdBytes else { return }
        rotating = true
        defer { rotating = false }

        try? handle?.close()
        handle = nil
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let archiveURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(name)-\(fmt.string(from: Date())).log")
        do {
            try FileManager.default.moveItem(at: url, to: archiveURL)
        } catch {
            return   // rename failed — keep appending to the old file
        }
        // Compress detached — never blocks a writer. gzip replaces the
        // .log with .log.gz on success; on failure the plain .log
        // archive remains (worse disk, same forensics).
        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gzip.arguments = [archiveURL.path]
        try? gzip.run()
    }

    /// Open the log file.
    /// - Parameter append: if false (default), overwrites previous content (per-job logs).
    ///   If true, opens in append mode so launches accumulate (used by `videoscan.log`),
    ///   rotating to a gzip'd dated archive first when oversized (see Rotation policy).
    /// Writes a header with timestamp and app version.
    func start(append: Bool = false) {
        lock.lock()
        defer { lock.unlock() }

        // The parent dir may not exist yet (injected directories, or the
        // routed temp dir on first use).
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)

        if append {
            rotateIfOversized()
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
    /// Every `rotationCheckEvery` writes, an append-mode log re-checks
    /// its size so a marathon session can't regrow an unbounded file.
    func write(_ line: String) {
        lock.lock()
        defer { lock.unlock() }

        writesSinceRotationCheck += 1
        if writesSinceRotationCheck >= Self.rotationCheckEvery {
            writesSinceRotationCheck = 0
            let hadHandle = handle != nil
            rotateIfOversized()
            if hadHandle, handle == nil {
                // Rotated mid-session: reopen fresh and stamp continuity.
                FileManager.default.createFile(atPath: url.path, contents: nil)
                handle = try? FileHandle(forWritingTo: url)
                let fmt = DateFormatter()
                fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
                let header = "VideoScan \(name) log — rotated \(fmt.string(from: Date())) (previous archived beside this file)\n"
                    + "─────────────────────────────────────────────\n"
                if let data = header.data(using: .utf8) { handle?.write(data) }
            }
        }

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
