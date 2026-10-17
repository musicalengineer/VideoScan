// CatalogHighWaterLedger.swift (VideoScanCore/Store)
// The SECOND witness of the generation high-water: `catalog.highwater.log`,
// an APPEND-ONLY text file beside the database, one line per generation
// this Mac published as its mark — `<generation> <ISO 8601 UTC> <host>`.
//
// Why a second witness (codex C′ #3, 2026-10-17): the sidecar
// `catalog.highwater` is REPLACED on every write, so a backup that carries
// the database and the sidecar together restores both to the same older
// moment and the restore goes unnoticed. An appended line is never
// replaced: a copy of this file from any later moment still ends at the
// newest generation, so restoring the database and the sidecar without it
// is caught at open (`restoredBelowHighWater`).
//
// The limit, by construction: a restore of ALL THREE files from one moment
// is undetectable here — nothing beside the database remembers a later
// moment. The contract (§e.9) names the app-level media ledger
// (ledger/media-ledger.jsonl, written by the app, not by this store) as the
// further witness; GRDBCatalogRepositoryTests pins the limit so it stays
// explicit rather than assumed away.
//
// Reading: the LAST line that parses is the value. A torn final line (a
// crash during an append) is tolerated because the sidecar, written first,
// already carries that generation; a non-empty file with NO parseable line
// is `unreadable`, and the store opens read-only until a person adopts
// (adoption appends a parseable line). An empty file counts as `missing`.
// Only the file's tail is read, so a catalog with 100k generations does
// not re-read a megabyte per write.
//
// No JSON (Rick's rule): one line, three space-separated fields, the host
// LAST so it may contain spaces ("Rick's Mac Studio").
//
// For Rick: a namespace of static functions over one file. The append is
// open(O_APPEND) + write(2) + F_FULLFSYNC — the POSIX way to add a line
// that a reader never sees half-written and a reboot does not lose.

import Foundation

public enum CatalogHighWaterLedger {

    public static let fileName = "catalog.highwater.log"

    /// What the log says. Same three shapes as the sidecar's reading, on
    /// purpose: the store treats the two witnesses alike.
    public enum Reading: Sendable, Equatable {
        case value(Int)
        case missing
        case unreadable(String)
    }

    /// Bytes read from the end of the file per attempt: a line is ~50
    /// bytes, so the first attempt sees about ten lines; only a tail with
    /// no readable line widens to the second size, then the whole file.
    /// Kept small on purpose — every write reads this, and 100k writes
    /// against a 64 KB tail read 6.4 GB (measured 2026-10-17).
    static let tailSizes = [512, 64 * 1024]

    public static func url(besideDatabaseAt databaseURL: URL) -> URL {
        databaseURL.deletingLastPathComponent().appendingPathComponent(fileName)
    }

    // MARK: - Read

    public static func read(besideDatabaseAt databaseURL: URL) -> Reading {
        let path = url(besideDatabaseAt: databaseURL).path
        let fd = Darwin.open(path, O_RDONLY)
        guard fd >= 0 else {
            return errno == ENOENT ? .missing : .unreadable("\(fileName) could not be opened for reading")
        }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return .unreadable("\(fileName) could not be examined") }
        let size = Int(info.st_size)
        guard size > 0 else { return .missing }
        var tried = 0
        for bytes in (tailSizes + [size]).map({ min($0, size) }) where bytes > tried {
            tried = bytes
            if let value = lastParseableLine(in: tail(fd: fd, size: size, bytes: bytes), partialHead: bytes < size) {
                return .value(value)
            }
        }
        let glimpse = String(data: tail(fd: fd, size: size, bytes: min(40, size)), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "binary"
        return .unreadable("\(fileName) holds no readable line ('\(glimpse)')")
    }

    /// The last `bytes` of the file, by one pread(2).
    private static func tail(fd: Int32, size: Int, bytes: Int) -> Data {
        var data = Data(count: bytes)
        let got = data.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            return Darwin.pread(fd, base, bytes, off_t(size - bytes))
        }
        return got > 0 ? data.prefix(got) : Data()
    }

    /// `partialHead`: the data starts mid-file, so its first line is a
    /// fragment ("3 2026-… host" cut from "123 2026-… host") and is skipped.
    /// Lines are split as bytes and decoded one by one, so a line of binary
    /// noise is simply "not a line" and never hides a readable neighbour.
    static func lastParseableLine(in data: Data, partialHead: Bool = false) -> Int? {
        var lines = data.split(separator: UInt8(ascii: "\n"))
        if partialHead, !lines.isEmpty { lines.removeFirst() }
        return lines.reversed().lazy.compactMap(parse).first
    }

    /// `<generation> <stamp> <host…>`: valid UTF-8, a non-negative integer,
    /// a stamp, and at least one word of host. Anything else is not a line
    /// of this log.
    static func parse(_ line: Data) -> Int? {
        guard let text = String(data: line, encoding: .utf8) else { return nil }
        let fields = text.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 3, let generation = Int(fields[0]), generation >= 0 else { return nil }
        return generation
    }

    // MARK: - Append

    /// One line for `generation`, as the file stores it.
    static func line(_ generation: Int, host: String, at date: Date = Date()) -> String {
        let stamp = ISO8601DateFormatter().string(from: date)
        let safeHost = host.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        return "\(generation) \(stamp) \(safeHost.isEmpty ? "unknown" : safeHost)\n"
    }

    /// Appends one line with O_APPEND (the kernel places it after whatever
    /// is there, so two processes cannot interleave inside a line) and,
    /// with `.fullFsync`, asks the drive to flush before returning: the
    /// witness must survive the reboot that loses the commit it precedes.
    /// A file whose last byte is not a newline (a torn append, a hand-made
    /// file) gets one first, so the new line never merges into the old.
    public static func append(_ generation: Int,
                              host: String,
                              besideDatabaseAt databaseURL: URL,
                              durability: AtomicFilePublish.Durability) throws {
        let path = url(besideDatabaseAt: databaseURL).path
        let fd = Darwin.open(path, O_RDWR | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else {
            throw AtomicFilePublish.Failure(operation: "open (append)", path: path, errnoValue: errno)
        }
        defer { Darwin.close(fd) }
        let prefix = endsWithNewline(fd: fd) ? "" : "\n"
        try writeFully(Data((prefix + line(generation, host: host)).utf8), to: fd, path: path)
        if durability == .fullFsync, fcntl(fd, F_FULLFSYNC) == -1 {
            throw AtomicFilePublish.Failure(operation: "F_FULLFSYNC", path: path, errnoValue: errno)
        }
    }

    /// True for an empty file too (nothing to separate from).
    private static func endsWithNewline(fd: Int32) -> Bool {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > 0 else { return true }
        var last: UInt8 = 0
        return Darwin.pread(fd, &last, 1, off_t(info.st_size - 1)) == 1 && last == UInt8(ascii: "\n")
    }

    private static func writeFully(_ data: Data, to fd: Int32, path: String) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw AtomicFilePublish.Failure(operation: "write (append)", path: path, errnoValue: errno)
                }
                offset += written
            }
        }
    }
}
