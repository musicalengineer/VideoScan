import Foundation
import os

private let ramLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "ramloader")

/// Serialized disk feeder for page cache warming.
///
/// The core insight: a single sequential reader gets 50-100 MB/s from a slow
/// USB/HDD drive. Multiple concurrent readers thrash the disk to 0.1-3 MB/s each.
/// This actor reads one file at a time (full sequential bandwidth), warming the
/// OS page cache so parallel scan workers hit memory-speed pages.
///
/// Usage: create with the full file list, call `start()`, then each worker calls
/// `waitForWarm(idx)` before opening its file. The feeder stays ahead of workers.
actor DiskFeeder {

    private let files: [String]
    private let budgetBytes: UInt64
    private var warmedSet: Set<Int> = []
    private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var feedTask: Task<Void, Never>?
    private var totalBytesWarmed: UInt64 = 0
    private var filesSkippedCache: Int = 0
    private let headroomBytes: UInt64 = 4 * 1024 * 1024 * 1024
    private let shouldSkip: (@Sendable (String) -> Bool)?

    init(files: [String], budgetBytes: UInt64 = 16 * 1024 * 1024 * 1024, shouldSkip: (@Sendable (String) -> Bool)? = nil) {
        self.files = files
        self.budgetBytes = budgetBytes
        self.shouldSkip = shouldSkip
    }

    /// Start the sequential feeder. Call once after creation.
    func start() {
        guard feedTask == nil else { return }
        feedTask = Task.detached(priority: .userInitiated) { [files, budgetBytes, headroomBytes, shouldSkip] in
            for idx in 0..<files.count {
                if Task.isCancelled { break }

                let filePath = files[idx]

                // Skip files that will be cache hits — no point warming them
                if let shouldSkip = shouldSkip, shouldSkip(filePath) {
                    await self.markWarmed(idx)
                    await self.incrementSkipped()
                    continue
                }

                let url = URL(fileURLWithPath: filePath)
                let filename = url.lastPathComponent

                guard let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
                      let fileSize = attrs[.size] as? Int64 else {
                    await self.markWarmed(idx)
                    continue
                }

                // Skip files too large for budget
                if UInt64(fileSize) > budgetBytes {
                    ramLog.notice("Feeder skip (too large): \(filename, privacy: .public) \(fileSize / (1024*1024))MB")
                    await self.markWarmed(idx)
                    continue
                }

                // Memory pressure check
                let available = MemoryPressureMonitor.shared.availableMemory()
                if available < UInt64(fileSize) + headroomBytes {
                    ramLog.notice("Feeder skip (low mem, \(available / (1024*1024*1024))GB free): \(filename, privacy: .public)")
                    await self.markWarmed(idx)
                    continue
                }

                // Sequential read — one file at a time, full disk bandwidth
                let warmStart = CFAbsoluteTimeGetCurrent()
                let bytes = Self.warmFile(path: filePath, fileSize: fileSize)
                let warmMs = (CFAbsoluteTimeGetCurrent() - warmStart) * 1000

                if let bytes = bytes {
                    let mbPerSec = Double(bytes) / (1024*1024) / max(warmMs / 1000, 0.001)
                    ramLog.notice("Feeder[\(idx, privacy: .public)]: \(filename, privacy: .public) \(bytes / (1024*1024))MB in \(String(format: "%.0f", warmMs))ms (\(String(format: "%.0f", mbPerSec)) MB/s)")
                    await self.addBytesWarmed(UInt64(bytes))
                }

                await self.markWarmed(idx)
            }
            let skipped = await self.filesSkippedCache
            ramLog.notice("Feeder complete: \(files.count) files (\(skipped) cache-skipped)")
        }
    }

    /// Workers call this before opening their file. Returns immediately if
    /// the file is already warmed, otherwise suspends until the feeder catches up.
    func waitForWarm(_ idx: Int) async {
        if warmedSet.contains(idx) { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if warmedSet.contains(idx) {
                cont.resume()
            } else {
                waiters[idx, default: []].append(cont)
            }
        }
    }

    /// Cancel the feeder (e.g. when scan is cancelled).
    func cancel() {
        feedTask?.cancel()
        feedTask = nil
        // Wake all waiters so they don't hang
        for (_, conts) in waiters {
            for cont in conts { cont.resume() }
        }
        waiters.removeAll()
    }

    var bytesWarmed: UInt64 { totalBytesWarmed }

    // MARK: - Private

    private func markWarmed(_ idx: Int) {
        warmedSet.insert(idx)
        if let conts = waiters.removeValue(forKey: idx) {
            for cont in conts { cont.resume() }
        }
    }

    private func addBytesWarmed(_ bytes: UInt64) {
        totalBytesWarmed += bytes
    }

    private func incrementSkipped() {
        filesSkippedCache += 1
    }

    var skippedCount: Int { filesSkippedCache }

    /// Read file sequentially to warm the OS page cache. Single-threaded,
    /// so the disk gets full sequential bandwidth.
    private static func warmFile(path: String, fileSize: Int64) -> Int? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }

        let fd = fh.fileDescriptor
        _ = fcntl(fd, F_RDAHEAD, 1)

        let chunkSize = 4 * 1024 * 1024  // 4MB chunks
        var bytesRead = 0
        var ioError = false
        while bytesRead < Int(fileSize) && !ioError {
            if Task.isCancelled { break }
            autoreleasepool {
                do {
                    // Use the throwing API — the legacy readData(ofLength:) calls
                    // through to ObjC -[NSConcreteFileHandle readDataOfLength:]
                    // which throws NSException on I/O errors (disconnected volume,
                    // bad fd, etc.). Swift cannot catch NSException; SIGABRT results.
                    // read(upToCount:) uses the error-returning ObjC variant instead.
                    guard let chunk = try fh.read(upToCount: chunkSize) else {
                        bytesRead = Int(fileSize)  // EOF
                        return
                    }
                    bytesRead += chunk.count
                    if chunk.isEmpty { bytesRead = Int(fileSize) }
                } catch {
                    let filename = URL(fileURLWithPath: path).lastPathComponent
                    ramLog.error("Feeder I/O error reading \(filename, privacy: .public) at offset \(bytesRead): \(error.localizedDescription, privacy: .public)")
                    ioError = true
                }
            }
        }
        return ioError ? nil : bytesRead
    }
}

// MARK: - Volume Speed Detection

enum VolumeSpeed {
    case fast   // internal SSD — no warming needed
    case slow   // external HDD, USB, SMB — warming helps

    static func detect(path: String) -> VolumeSpeed {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.volumeIsInternalKey, .volumeIsLocalKey]
        guard let values = try? url.resourceValues(forKeys: keys) else {
            return .slow  // assume slow if we can't determine
        }

        // Network volumes — slow
        if values.volumeIsLocal == false { return .slow }

        // Internal volumes — fast (SSD on Apple Silicon)
        if values.volumeIsInternal == true { return .fast }

        // External but local — likely USB HDD or SSD
        return .slow
    }
}

// MARK: - PageCacheWarmer (legacy single-file API, kept for optional manual use)

enum PageCacheWarmer {

    static var isEnabled: Bool = false
    static var maxFileSizeBytes: Int64 = 16 * 1024 * 1024 * 1024
    static var budgetBytes: UInt64 = 16 * 1024 * 1024 * 1024

    @discardableResult
    static func warm(fileURL: URL) -> Int? {
        let resourceValues = try? fileURL.resourceValues(forKeys: [.volumeIsLocalKey])
        if resourceValues?.volumeIsLocal == false {
            return nil
        }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = attrs[.size] as? Int64 else { return nil }

        if fileSize > maxFileSizeBytes {
            ramLog.notice("Skip warm (>\(maxFileSizeBytes / (1024*1024))MB): \(fileURL.lastPathComponent, privacy: .public) (\(fileSize / (1024*1024))MB)")
            return nil
        }

        let available = MemoryPressureMonitor.shared.availableMemory()
        let headroom: UInt64 = 4 * 1024 * 1024 * 1024
        guard available > UInt64(fileSize) + headroom else {
            ramLog.notice("Skip warm (low mem, \(available / (1024*1024*1024))GB avail): \(fileURL.lastPathComponent, privacy: .public)")
            return nil
        }

        guard let fh = FileHandle(forReadingAtPath: fileURL.path) else { return nil }
        defer { try? fh.close() }

        let fd = fh.fileDescriptor
        _ = fcntl(fd, F_RDAHEAD, 1)

        let chunkSize = 4 * 1024 * 1024
        var bytesRead = 0
        while true {
            var hitEOF = false
            var hitError = false
            autoreleasepool {
                do {
                    guard let chunk = try fh.read(upToCount: chunkSize) else {
                        hitEOF = true
                        return
                    }
                    bytesRead += chunk.count
                    if chunk.isEmpty { hitEOF = true }
                } catch {
                    ramLog.error("PageCacheWarmer I/O error reading \(fileURL.lastPathComponent, privacy: .public) at offset \(bytesRead): \(error.localizedDescription, privacy: .public)")
                    hitError = true
                }
            }
            if hitEOF || hitError { break }
            if bytesRead >= Int(fileSize) { break }
        }

        return bytesRead
    }
}
