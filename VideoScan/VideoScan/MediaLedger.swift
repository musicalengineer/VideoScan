// MediaLedger.swift
// The Media Ledger's file half (Rick's amendment 2, 2026-09-12 — promote-
// and-prune stage 2; the pure line model is VideoScanCore's
// MediaLedgerEvent, the sentences are LedgerNarrator):
//
//   - ONE append-only JSONL file: App Support/VideoScan/ledger/
//     media-ledger.jsonl. A unit-test host gets a per-process scratch
//     folder instead (the IgnoredContentStore discipline) so ~200 tests
//     that construct a VideoScanModel can never touch the real file.
//   - WRITES go through ONE ordered off-main worker, the shape
//     `recordAttestation` uses (cd801d16): the caller encodes the batch
//     (cheap), a Task chained after the previous one hops to the
//     cooperative pool (`@concurrent`) and does the open / one O_APPEND
//     write / one fsync there. Never on main, never blocking the UI,
//     batched per operation. The first successful write logs the ledger
//     path once.
//   - MIRROR: after every successful Promote batch the whole file is
//     copied into the archive's `00_Index/media-ledger.jsonl` (write a
//     `.partial` beside it through the O_NOFOLLOW index descriptor, fsync,
//     renameat over the final name, fsync the directory) so the ledger
//     travels with the archive (GH #170). Chained on the same worker, so
//     the mirror always includes the batch's own lines.
//   - READERS are synchronous and `nonisolated`: they read the whole file
//     (bounded — see `readLimit`) and filter. `narrated(...)` is the
//     inspector's entry: off-main, cached per record (bounded cache,
//     invalidated on every append).
//
// Memory: a read holds the file's bytes once (a 100k-line ledger is
// ~30 MB) plus the decoded events for the query; nothing is retained
// beyond the call except the small narrated-sentence cache (≤ 64 records).
// The read limit (256 MB) caps the worst case.
//
// (For Rick: `final class … @unchecked Sendable` with an NSLock around
// its mutable members ≈ a C++ class with a mutex; `Task { await
// previous?.value … }` is how the appends are serialized without a
// queue object.)

import Foundation
import os

let mediaLedgerLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "ledger")

final class MediaLedger: @unchecked Sendable {

    static let filename = "media-ledger.jsonl"
    /// The copy inside the archive's 00_Index/.
    static let mirrorFilename = "media-ledger.jsonl"
    /// The in-flight name (never `.partial` — that suffix is Promote's
    /// own in-flight marker and its cancel sensor sweeps for it).
    static let mirrorPartialName = ".media-ledger.jsonl.tmp"
    /// A runaway file cannot exhaust memory: reads stop here.
    static let readLimit = 256 << 20
    /// Narrated-sentence cache bound (records).
    static let cacheLimit = 64

    /// The append seam: production writes the bytes; a test can count
    /// calls, record the thread, or refuse.
    typealias Writer = @Sendable (Data, URL) throws -> Void
    static let liveWriter: Writer = { data, url in try appendDurable(data, to: url) }

    /// App Support/VideoScan/ledger — the production home. Under a test
    /// host: a per-process scratch folder (never the real file).
    nonisolated static var defaultDirectory: URL {
        if TestEnvironment.isTestHost {
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("VideoScan-tests/ledger-\(ProcessInfo.processInfo.processIdentifier)",
                                        isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("VideoScan", isDirectory: true)
            .appendingPathComponent("ledger", isDirectory: true)
    }

    let directory: URL
    nonisolated var fileURL: URL { directory.appendingPathComponent(Self.filename) }

    private let writer: Writer
    private let lock = NSLock()
    /// The tail of the ordered worker chain.
    private var tail: Task<Void, Never>?
    private var announcedPath = false
    /// Bumped per append; the narrated cache is keyed on it.
    private var revision = 0
    private var narratedCache: [UUID: (revision: Int, lines: [String])] = [:]
    /// Counters for tests / diagnostics.
    private(set) var appendCount = 0
    private(set) var lineCount = 0

    init(directory: URL = MediaLedger.defaultDirectory, writer: @escaping Writer = MediaLedger.liveWriter) {
        self.directory = directory
        self.writer = writer
    }

    // MARK: Write

    /// Append a batch. Encodes on the caller's thread (microseconds),
    /// then ONE ordered off-main worker does the file work. Returns the
    /// flush task (awaitable by tests / the Promote mirror); nil when
    /// there was nothing to write.
    @discardableResult
    func append(_ events: [MediaLedgerEvent]) -> Task<Void, Never>? {
        guard !events.isEmpty else { return nil }
        let data: Data
        do {
            data = try MediaLedgerEvent.encodeLines(events)
        } catch {
            mediaLedgerLog.error("ledger: could not encode \(events.count) event(s): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let previous: Task<Void, Never>? = lock.withLock {
            revision &+= 1
            narratedCache.removeAll(keepingCapacity: true)
            appendCount += 1
            lineCount += events.count
            return tail
        }
        let url = fileURL
        let writer = self.writer
        let count = events.count
        let task = Task(priority: .utility) { [self] in
            await previous?.value
            await self.writeOffMain(data, count: count, url: url, writer: writer)
        }
        lock.withLock { tail = task }
        return task
    }

    /// Wait for every append / mirror issued so far to land.
    func waitForPendingWrites() async {
        let t: Task<Void, Never>? = lock.withLock { tail }
        await t?.value
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated private func writeOffMain(_ data: Data, count: Int, url: URL, writer: Writer) async {
        do {
            try writer(data, url)
            announceIfFirst(url)
        } catch {
            let text = (error as? Failure)?.description ?? error.localizedDescription
            appLog.write("ledger: \(count) line(s) not written to \(url.path) — \(text)")
            mediaLedgerLog.error("ledger append failed: \(text, privacy: .public)")
        }
    }

    /// The ledger path goes to catalog.log once per process, on the first
    /// successful write (Rick: "log the ledger path on first write").
    nonisolated private func announceIfFirst(_ url: URL) {
        let first: Bool = lock.withLock {
            let first = !announcedPath
            announcedPath = true
            return first
        }
        if first {
            appLog.write("ledger: media ledger at \(url.path)")
            mediaLedgerLog.info("media ledger at \(url.path, privacy: .public)")
        }
    }

    // MARK: Mirror into the archive

    /// Copy the whole ledger into `<root>/00_Index/media-ledger.jsonl`
    /// (atomic replace). Chained after pending appends. Best effort: a
    /// missing or offline archive logs and moves on — the App Support
    /// file is the truth, the mirror is the traveller.
    @discardableResult
    func mirror(intoArchiveRoot root: String) -> Task<Void, Never> {
        let previous: Task<Void, Never>? = lock.withLock { tail }
        let source = fileURL
        let task = Task(priority: .utility) {
            await previous?.value
            await Self.mirrorOffMain(source: source, root: root)
        }
        lock.withLock { tail = task }
        return task
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func mirrorOffMain(source: URL, root: String) async {
        do {
            try mirrorFile(source: source, root: root)
        } catch {
            let text = (error as? ArchivePromoteEngine.Failure)?.description
                ?? (error as? Failure)?.description ?? error.localizedDescription
            appLog.write("ledger: mirror into \(root)/\(MasterArchiveLayout.indexFolder) not written — \(text)")
            mediaLedgerLog.error("ledger mirror failed: \(text, privacy: .public)")
        }
    }

    /// Synchronous mirror — descriptor-relative under 00_Index (O_NOFOLLOW
    /// throughout), `.partial` → fsync → renameat → fsync(dir). A missing
    /// source ledger writes an EMPTY mirror (the archive still learns the
    /// file exists). Throws on any failure.
    nonisolated static func mirrorFile(source: URL, root: String) throws {
        let data = (try? Data(contentsOf: source, options: [.mappedIfSafe])) ?? Data()
        let indexFD = try ArchivePromoteEngine.openIndexDirectory(root: root)
        defer { close(indexFD) }
        let fd = openat(indexFD, mirrorPartialName, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw Failure.io("open \(mirrorPartialName)", errno: errno) }
        var closed = false
        defer { if !closed { close(fd) } }
        try writeAll(data, to: fd, label: mirrorPartialName)
        guard fsync(fd) == 0 else { throw Failure.io("fsync \(mirrorPartialName)", errno: errno) }
        close(fd); closed = true
        guard renameat(indexFD, mirrorPartialName, indexFD, mirrorFilename) == 0 else {
            throw Failure.io("rename \(mirrorPartialName) → \(mirrorFilename)", errno: errno)
        }
        guard fsync(indexFD) == 0 else { throw Failure.io("fsync \(MasterArchiveLayout.indexFolder)", errno: errno) }
    }

    static func mirrorURL(rootPath: String) -> URL {
        URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent(MasterArchiveLayout.indexFolder, isDirectory: true)
            .appendingPathComponent(mirrorFilename)
    }

    // MARK: Read

    /// Every parseable line, file order. Bounded by `readLimit`.
    nonisolated func allEvents() -> [MediaLedgerEvent] {
        Self.events(at: fileURL)
    }

    nonisolated static func events(at url: URL) -> [MediaLedgerEvent] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        var data = Data()
        while data.count < readLimit {
            let chunk = handle.readData(ofLength: 4 << 20)
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return MediaLedgerEvent.decodeLines(text)
    }

    /// Dated events for a filename (exact match), file order.
    nonisolated func events(forFilename name: String) -> [MediaLedgerEvent] {
        guard !name.isEmpty else { return [] }
        return allEvents().filter { $0.filename == name }
    }

    /// Dated events for a content key (every copy of that footage).
    nonisolated func events(forContentKey key: String) -> [MediaLedgerEvent] {
        guard !key.isEmpty else { return [] }
        return allEvents().filter { $0.contentKey == key }
    }

    nonisolated func events(forRecordID id: UUID) -> [MediaLedgerEvent] {
        allEvents().filter { $0.recordID == id }
    }

    /// The lines that belong to ONE catalog record: its id, plus every
    /// copy of its content, plus (only when the content is unknown) its
    /// filename. One read, one pass.
    nonisolated func events(recordID: UUID, contentKey: String, filename: String) -> [MediaLedgerEvent] {
        allEvents().filter { e in
            e.recordID == recordID
                || (!contentKey.isEmpty && e.contentKey == contentKey)
                || (contentKey.isEmpty && !filename.isEmpty && e.filename == filename)
        }
    }

    /// The inspector's History: sentences, newest first, computed OFF
    /// MAIN and cached per record until the next append. Cache bounded.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated func narrated(recordID: UUID, contentKey: String, filename: String,
                              timeZone: TimeZone = .current) async -> [String] {
        let (rev, cached): (Int, [String]?) = lock.withLock {
            let rev = revision
            if let hit = narratedCache[recordID], hit.revision == rev { return (rev, hit.lines) }
            return (rev, nil)
        }
        if let cached { return cached }
        let events = events(recordID: recordID, contentKey: contentKey, filename: filename)
        let lines = LedgerNarrator.sentences(for: events, newestFirst: true, timeZone: timeZone)
        lock.withLock {
            if narratedCache.count >= Self.cacheLimit { narratedCache.removeAll(keepingCapacity: true) }
            narratedCache[recordID] = (rev, lines)
        }
        return lines
    }

    /// Test / diagnostics: how many records are cached right now.
    var narratedCacheCount: Int { lock.withLock { narratedCache.count } }

    // MARK: Durable append (POSIX)

    struct Failure: Error, CustomStringConvertible {
        let what: String
        let errno: Int32
        static func io(_ what: String, errno: Int32) -> Failure { Failure(what: what, errno: errno) }
        var description: String { "\(what): \(String(cString: strerror(errno))) (errno \(errno))" }
    }

    /// mkdir -p the folder, open O_APPEND|O_CREAT|O_NOFOLLOW, ONE write
    /// loop, ONE fsync. Throws with errno on any failure.
    nonisolated static func appendDurable(_ data: Data, to url: URL) throws {
        guard !data.isEmpty else { return }
        let dir = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw Failure.io("open \(url.lastPathComponent)", errno: errno) }
        defer { close(fd) }
        try writeAll(data, to: fd, label: url.lastPathComponent)
        guard fsync(fd) == 0 else { throw Failure.io("fsync \(url.lastPathComponent)", errno: errno) }
    }

    /// One write loop (EINTR-tolerant, short writes continued). An empty
    /// buffer is a no-op.
    nonisolated static func writeAll(_ data: Data, to fd: Int32, label: String) throws {
        try data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            var offset = 0
            while offset < buf.count {
                let n = write(fd, base + offset, buf.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw Failure.io("write \(label)", errno: errno)
                }
                offset += n
            }
        }
    }
}
