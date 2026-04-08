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
final class PersistentLog: @unchecked Sendable {
    static let logDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VideoScan")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    let name: String
    let url: URL
    private var handle: FileHandle?
    private let lock = NSLock()

    init(name: String) {
        self.name = name
        self.url = Self.logDir.appendingPathComponent("\(name).log")
    }

    /// Open the log file, overwriting any previous content.
    /// Writes a header with timestamp and app version.
    func start() {
        lock.lock()
        defer { lock.unlock() }

        // Create or truncate the file
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)

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
