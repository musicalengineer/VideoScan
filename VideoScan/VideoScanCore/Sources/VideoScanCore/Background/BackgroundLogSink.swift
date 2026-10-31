// BackgroundLogSink.swift — VideoScanCore/Background
//
// The log seam the supervisor writes START/OUTCOME through (hard rule 5:
// nothing runs silently), and the file sink the helper gives it for
// ~/Library/Logs/VideoScan/background.log (design §3.4: same line format as
// videoscan.log, its OWN file — two processes never append to one file).
//
// Why not the app's `LogSink`/`PersistentLog`: those live in the app target,
// which the helper does not link. `BackgroundFileLog` mirrors PersistentLog's
// line shape ("[HH:mm:ss] line", fsync per write, append mode) so the two logs
// read alike; moving PersistentLog itself into the shared engine target is a
// step-1 move (design §3.1), not tonight's.
//
// C++ reading: `BackgroundLogSink` is a pure-virtual logger interface; the
// supervisor holds it by reference and never knows which concrete one it is.

import Foundation

public protocol BackgroundLogSink: AnyObject, Sendable {
    func write(_ line: String)
}

/// Append-mode file log, one fsync per line (crash-safe: the last line
/// written is on disk). Rotation is PersistentLog's job and comes with it
/// in step 1; the helper writes a few lines per job, not per file.
public final class BackgroundFileLog: BackgroundLogSink, @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var handle: FileHandle?
    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    public init(url: URL) { self.url = url }

    /// The production file: ~/Library/Logs/VideoScan/background.log.
    public static func production() -> BackgroundFileLog {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VideoScan", isDirectory: true)
        return BackgroundFileLog(url: dir.appendingPathComponent("background.log"))
    }

    public func start() {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let header = "VideoScan background log — started \(f.string(from: Date())) (pid \(ProcessInfo.processInfo.processIdentifier))\n"
            + "─────────────────────────────────────────────\n"
        if let data = header.data(using: .utf8) { handle?.write(data) }
    }

    public func write(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return }
        if let data = "[\(stamp.string(from: Date()))] \(line)\n".data(using: .utf8) {
            handle.write(data)
            try? handle.synchronize()
        }
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        try? handle?.close()
        handle = nil
    }

    deinit { try? handle?.close() }
}

/// Collects lines in memory — for tests and for the CLI's one-shot output.
/// Bounded: keeps the last `capacity` lines (default 10k ≈ 1 MB worst case).
public final class InMemoryBackgroundLog: BackgroundLogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    private let capacity: Int

    public init(capacity: Int = 10_000) { self.capacity = capacity }

    public func write(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        storage.append(line)
        if storage.count > capacity { storage.removeFirst(storage.count - capacity) }
    }

    public var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
