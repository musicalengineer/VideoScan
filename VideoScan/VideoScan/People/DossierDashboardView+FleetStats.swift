// DossierDashboardView+FleetStats.swift
// The worker-fleet JSONL parsing machinery — extracted verbatim from
// DossierDashboardView.swift (refactor 2026-06-25): WorkerHost and
// FleetStats. No longer rendered by the dashboard (the "Participating
// Computers" panel was replaced by the live pipeline activity
// sections, 2026-06-12), but kept because the byte-level parsing has
// unit tests (FleetStatsTailTests) and the multi-machine fleet may
// return. Both types were already `internal`, so the move is purely
// mechanical with no access changes.
// (Swift file split ≈ C++ splitting a translation unit.)

import SwiftUI

// MARK: - Fleet stats
//
// No longer rendered by the dashboard (the "Participating Computers"
// panel was replaced by the live pipeline activity sections,
// 2026-06-12). Kept because the JSONL parsing logic has unit tests
// (FleetStatsTailTests) and the multi-machine fleet may return.

/// Known worker hosts. Add an entry here when expanding the fleet
/// (e.g. add Intel one day).
enum WorkerHost: String, CaseIterable {
    case m4 = "RicksM4"
    case m5 = "RicksM5"
    case m1 = "RicksM1"

    var displayName: String {
        switch self {
        case .m4: return "M4 Mac Studio"
        case .m5: return "M5 MacBook Pro"
        case .m1: return "M1 MacBook Pro"
        }
    }

    var jsonlBasename: String {
        switch self {
        case .m4: return "m4.jsonl"
        case .m5: return "m5.jsonl"
        case .m1: return "m1.jsonl"
        }
    }

    var color: Color {
        switch self {
        case .m4: return .blue
        case .m5: return .green
        case .m1: return .orange
        }
    }
}

struct FleetStats {
    struct HostStat {
        let recordCount: Int
        let lastWrite: Date?
        let fileBytes: Int64
        /// Closure sentinel — present when the worker wrote a `_status`
        /// line as its final JSONL entry. Absent for a crashed/killed
        /// worker (the honest signal: we don't know if it finished).
        let sentinel: Sentinel?

        struct Sentinel: Equatable {
            /// "done" = paths file exhausted cleanly.
            /// "interrupted" = SIGINT mid-run (Ctrl-C).
            let status: String
            let processedOk: Int
            let processedFailed: Int
            let targetsTotal: Int
            let exitedAt: Date?
        }

        /// Four-state user-facing label, ranked by certainty.
        ///   sentinel present                → "done" or "stopped"  (factual)
        ///   wrote in last 2 min             → "running"            (factual)
        ///   wrote 2 min – 1 hr ago          → "stale"              (factual)
        ///   quiet >1 hr AND has records     → "done?"              (heuristic)
        ///   never wrote / no records        → "idle"               (factual)
        var aliveLabel: String {
            if let s = sentinel {
                return s.status == "done" ? "done" : "stopped"
            }
            guard let lastWrite else {
                return recordCount > 0 ? "done?" : "idle"
            }
            let age = Date().timeIntervalSince(lastWrite)
            if age < 120 { return "running" }
            if age < 3600 { return "stale" }
            return recordCount > 0 ? "done?" : "idle"
        }

        /// Color map keyed to the label above. Green is reserved for
        /// "done" (factual or heuristic). Cyan = active processing.
        /// Orange = stale (alive but quiet). Gray = idle / not yet
        /// touched. This separates "currently working" from "finished
        /// working" visually — a request from Rick 2026-06-07.
        var aliveColor: Color {
            if let s = sentinel {
                return s.status == "done" ? .green : .orange
            }
            guard let lastWrite else {
                return recordCount > 0 ? .green.opacity(0.65) : .gray
            }
            let age = Date().timeIntervalSince(lastWrite)
            if age < 120 { return .cyan }
            if age < 3600 { return .orange }
            return recordCount > 0 ? .green.opacity(0.65) : .gray
        }

        static let empty = HostStat(recordCount: 0, lastWrite: nil,
                                    fileBytes: 0, sentinel: nil)
    }

    /// Parsed result from a previous tick, keyed by the file's stat()
    /// identity (mtime + size). If neither changed, the bytes didn't
    /// either — workers only ever append — so the previous line count
    /// and sentinel are still valid and we skip the read entirely.
    struct CachedEntry: Equatable {
        let mtime: Date?
        let size: Int64
        let recordCount: Int
        let sentinel: HostStat.Sentinel?
    }

    var byHost: [WorkerHost: HostStat]

    subscript(host: WorkerHost) -> HostStat {
        byHost[host] ?? .empty
    }

    var isEmpty: Bool {
        byHost.values.allSatisfy { $0.recordCount == 0 && $0.lastWrite == nil }
    }

    static let empty = FleetStats(byHost: [:])

    /// Convenience overload — uncached load. Kept for existing callers
    /// and tests; the dashboard tick uses the cached variant below.
    static func load(from dir: URL) -> FleetStats {
        load(from: dir, cache: [:]).stats
    }

    /// Load per-host stats from JSONL files in `dir`. Each file's line
    /// count is the worker's record count; the file's mtime is its
    /// last-write time.
    ///
    /// Cost discipline (these files are now ~tens of MB — the old
    /// "kilobytes-to-low-MB" assumption is dead):
    ///   - stat() every tick (cheap)
    ///   - if (mtime, size) match the previous tick's cache → reuse the
    ///     parsed result, zero reads
    ///   - if changed → count 0x0A over raw bytes in chunked reads
    ///     (never via String — grapheme-aware splitting of a 28 MB file
    ///     was the measured beachball), and parse the sentinel from a
    ///     small FileHandle tail read instead of the whole file.
    static func load(from dir: URL,
                     cache: [WorkerHost: CachedEntry])
        -> (stats: FleetStats, cache: [WorkerHost: CachedEntry]) {
        var out: [WorkerHost: HostStat] = [:]
        var newCache: [WorkerHost: CachedEntry] = [:]
        let fm = FileManager.default
        for host in WorkerHost.allCases {
            let file = dir.appendingPathComponent(host.jsonlBasename)
            guard fm.fileExists(atPath: file.path) else {
                out[host] = .empty
                continue
            }
            let attrs = (try? fm.attributesOfItem(atPath: file.path)) ?? [:]
            let mtime = attrs[FileAttributeKey.modificationDate] as? Date
            let size = (attrs[FileAttributeKey.size] as? NSNumber)?.int64Value ?? 0

            let recordCount: Int
            let sentinel: HostStat.Sentinel?
            if let hit = cache[host], hit.mtime == mtime, hit.size == size {
                // Unchanged since last tick — no I/O beyond the stat.
                recordCount = hit.recordCount
                sentinel = hit.sentinel
            } else {
                let lineCount = Self.countNewlines(at: file)
                // The `_status` sentinel, when present, is the file's
                // LAST line (workers append it on clean exit). A small
                // tail read finds it without touching the rest.
                sentinel = Self.readTail(of: file)
                    .flatMap(Self.lastLine(ofTail:))
                    .flatMap(Self.parseSentinel(line:))
                // Don't count the sentinel line as a record — it's not a delta.
                recordCount = sentinel != nil ? max(0, lineCount - 1) : lineCount
            }
            newCache[host] = CachedEntry(mtime: mtime, size: size,
                                         recordCount: recordCount,
                                         sentinel: sentinel)
            out[host] = HostStat(recordCount: recordCount,
                                 lastWrite: mtime,
                                 fileBytes: size,
                                 sentinel: sentinel)
        }
        return (FleetStats(byHost: out), newCache)
    }

    // MARK: - Byte-level helpers (pure pieces are unit-tested)

    /// How many bytes of file tail to read when hunting the sentinel.
    /// Sentinel lines are a few hundred bytes; 4 KB is generous slack.
    static let tailWindowBytes = 4096

    /// Read up to `maxBytes` from the END of `url` via seek — never the
    /// whole file. Returns nil if the file can't be opened/read.
    static func readTail(of url: URL, maxBytes: Int = FleetStats.tailWindowBytes) -> Data? {
        guard maxBytes > 0, let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let end = try? fh.seekToEnd() else { return nil }
        let offset = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        guard (try? fh.seek(toOffset: offset)) != nil else { return nil }
        return (try? fh.readToEnd()) ?? Data()
    }

    /// Extract the last complete line from a tail-of-file byte window.
    /// Pure function over Data so it's testable without I/O.
    ///
    /// Trailing newlines are stripped, then everything after the last
    /// remaining 0x0A is the candidate line. Because 0x0A never occurs
    /// inside a multi-byte UTF-8 sequence, any slice that starts right
    /// after a newline is valid UTF-8 (if the file is). If the window
    /// contains NO newline before the candidate (seek landed mid-line,
    /// possibly mid-character), UTF-8 decoding may fail — we return nil
    /// rather than a garbled partial line.
    static func lastLine(ofTail tail: Data) -> String? {
        var bytes = tail[...]
        while bytes.last == 0x0A { bytes = bytes.dropLast() }
        guard !bytes.isEmpty else { return nil }
        let start: Data.Index
        if let nl = bytes.lastIndex(of: 0x0A) {
            start = bytes.index(after: nl)
        } else {
            start = bytes.startIndex
        }
        return String(data: bytes[start...], encoding: .utf8)
    }

    /// Count 0x0A bytes in a Data chunk. Pure, raw-byte — deliberately
    /// NOT String-based: Swift's Character is a grapheme cluster, so
    /// String splitting walks Unicode segmentation over every byte.
    /// (C++ analogy: this is memchr-in-a-loop, not std::getline.)
    static func newlineCount(in data: Data) -> Int {
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Int in
            var n = 0
            for byte in buf where byte == 0x0A { n += 1 }
            return n
        }
    }

    /// Streamed newline count over a file in `chunkSize` reads, each
    /// inside an autoreleasepool so Foundation's transient buffers
    /// don't accumulate (memory-pressure discipline for media-size files).
    static func countNewlines(at url: URL, chunkSize: Int = 1 << 20) -> Int {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? fh.close() }
        var total = 0
        var done = false
        while !done {
            autoreleasepool {
                guard let chunk = try? fh.read(upToCount: chunkSize), !chunk.isEmpty else {
                    done = true
                    return
                }
                total += newlineCount(in: chunk)
            }
        }
        return total
    }

    /// Decode a single JSONL line as a `_status` sentinel. Returns nil
    /// for ordinary delta lines (the steady state for a running worker)
    /// or for truncated/partial lines that don't parse.
    static func parseSentinel(line: String) -> HostStat.Sentinel? {
        guard line.contains("\"_status\""),
              let lineData = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let status = obj["_status"] as? String else { return nil }
        let exitDate = (obj["exitedAt"] as? String).flatMap {
            ISO8601DateFormatter().date(from: $0)
        }
        return HostStat.Sentinel(
            status: status,
            processedOk: obj["processedOk"] as? Int ?? 0,
            processedFailed: obj["processedFailed"] as? Int ?? 0,
            targetsTotal: obj["targetsTotal"] as? Int ?? 0,
            exitedAt: exitDate
        )
    }
}
