// ArchivePromoteJournal.swift
// The Promote intent journal (`00_Index/.promote_journal.jsonl`): append,
// retractable append + retract (codex 2026-10-02 #4), and the per-source
// reader. Moved verbatim out of ArchivePromoteEngine.swift (file length);
// the engine's descriptor-relative primitives are still what it uses.

import Darwin
import Foundation

// MARK: - Intent journal (convergence)

/// `00_Index/.promote_journal.jsonl` — one JSON line per step per source
/// so a crash at ANY point can be reconciled on the next run
/// (codex QA rounds 2–3). Append-only, O_APPEND single writes + fsync,
/// like the manifest. States, in order:
///   intent    — dest resolved, copy about to start (partial may exist)
///   renamed   — file published + durable (sha known)
///   published — manifest row appended + durable (file + index agree)
///   done      — the catalog link was written by a DURABLE catalog save
///               (`saveCatalogNow()` returned true) — the ONLY state that
///               reconcile trusts without re-checking the catalog
///   abandoned — never published; partial dropped
/// (`manifest` is the pre-R3 name of `published`, still decoded.)
enum ArchivePromoteJournal {
    static let filename = ".promote_journal.jsonl"

    struct Entry: Codable, Equatable, Sendable {
        enum State: String, Codable, Sendable {
            case intent, renamed, published, done, abandoned
            /// Legacy alias (pre-R3 writers) — treated as `.published`.
            case manifest
            var isPublished: Bool { self == .published || self == .manifest }
        }
        let sourceRecordID: UUID
        let sourcePath: String
        let destRelPath: String
        let state: State
        var sha256: String?
        var copyRecordID: UUID?
        let at: Date
    }

    static func url(rootPath: String) -> URL {
        URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent(MasterArchiveLayout.indexFolder, isDirectory: true)
            .appendingPathComponent(filename)
    }

    /// Append one entry (descriptor-relative open, O_NOFOLLOW, single
    /// O_APPEND write + fsync). Throws on any failure — a promotion whose
    /// intent cannot be journaled durably must not start.
    nonisolated static func append(_ entry: Entry, rootPath: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(entry)
        data.append(0x0A)
        try ArchiveIndexLock.withExclusive(root: rootPath, holder: "Promote journal append") {
            let fd = try ArchivePromoteEngine.openIndexFile(root: rootPath, name: filename, mustExist: false)
            defer { close(fd) }
            try ArchivePromoteEngine.appendDurable(fd: fd, data: data, full: false, label: "journal append")
        }
    }

    /// What `appendRetractable` wrote: enough to take exactly those bytes
    /// back out — and nothing else.
    struct AppendReceipt: Equatable, Sendable {
        /// Journal size before the append = where our line starts.
        let offset: Int64
        /// The exact bytes appended (one JSON line + newline).
        let bytes: Data
        /// True when this append CREATED the journal file.
        let createdFile: Bool
    }

    /// `append`, returning a receipt for `retract`. Used for the Promote
    /// INTENT, the one entry a refusal may need to take back (codex
    /// 2026-10-02 #4). Same lock, same O_APPEND single write + fsync.
    nonisolated static func appendRetractable(_ entry: Entry, rootPath: String) throws -> AppendReceipt {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(entry)
        data.append(0x0A)
        return try ArchiveIndexLock.withExclusive(root: rootPath, holder: "Promote journal append") {
            let indexFD = try ArchivePromoteEngine.openIndexDirectory(root: rootPath)
            defer { close(indexFD) }
            let existed = ArchivePromoteEngine.FileIdentity.at(dirfd: indexFD, name: filename) != nil
            let fd = try ArchivePromoteEngine.openIndexFile(root: rootPath, name: filename, mustExist: false)
            defer { close(fd) }
            guard let (before, _) = ArchivePromoteEngine.FileIdentity.of(fd: fd) else {
                throw ArchivePromoteEngine.Failure.writeFailed("journal fstat")
            }
            try ArchivePromoteEngine.appendDurable(fd: fd, data: data, full: false, label: "journal append")
            return AppendReceipt(offset: before.size, bytes: data, createdFile: !existed)
        }
    }

    /// Take back exactly the line `receipt` describes — ONLY when it is
    /// still the journal's last line, byte for byte (nobody appended after
    /// it). Truncates to the receipt's offset + fsync; when the append had
    /// created the file and it is now empty, removes the file and fsyncs
    /// 00_Index. Returns false — and changes NOTHING — in every other case;
    /// the caller then appends an `abandoned` line instead (the ordinary
    /// convergence record). Pre-existing journal bytes are never altered.
    @discardableResult
    nonisolated static func retract(_ receipt: AppendReceipt, rootPath: String) -> Bool {
        (try? ArchiveIndexLock.withExclusive(root: rootPath, holder: "Promote journal retract") { () -> Bool in
            let indexFD = try ArchivePromoteEngine.openIndexDirectory(root: rootPath)
            defer { close(indexFD) }
            let fd = try ArchivePromoteEngine.openIndexFile(root: rootPath, name: filename, mustExist: true)
            defer { close(fd) }
            guard let (now, _) = ArchivePromoteEngine.FileIdentity.of(fd: fd),
                  now.size == receipt.offset + Int64(receipt.bytes.count) else { return false }
            var tail = Data(count: receipt.bytes.count)
            let n = tail.withUnsafeMutableBytes { pread(fd, $0.baseAddress, receipt.bytes.count, off_t(receipt.offset)) }
            guard n == receipt.bytes.count, tail == receipt.bytes else { return false }
            guard ftruncate(fd, off_t(receipt.offset)) == 0,
                  ArchivePromoteEngine.barriers.fsync(fd) == 0 else { return false }
            if receipt.createdFile, receipt.offset == 0 {
                guard unlinkat(indexFD, filename, 0) == 0 else { return false }
                _ = ArchivePromoteEngine.barriers.fsync(indexFD)
            }
            return true
        }) ?? false
    }

    /// Latest entry per source id (a source can be journaled several
    /// times — retries, later Refile). Unparseable lines are skipped.
    /// Read THROUGH the validated index descriptor (openat O_NOFOLLOW,
    /// regular file) — never re-opened by path (codex R5 major 3). A
    /// missing journal is simply empty.
    nonisolated static func latestBySource(rootPath: String) -> [UUID: Entry] {
        let fd: Int32
        do {
            fd = try ArchivePromoteEngine.openIndexFile(root: rootPath, name: filename, mustExist: true)
        } catch {
            return [:]
        }
        defer { close(fd) }
        guard let data = try? ArchivePromoteEngine.readAll(fd: fd),
              let text = String(data: data, encoding: .utf8) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [UUID: Entry] = [:]
        for line in ArchiveIndexText.lines(text) {   // CRLF-safe
            guard let d = line.data(using: .utf8),
                  let e = try? decoder.decode(Entry.self, from: d) else { continue }
            out[e.sourceRecordID] = e
        }
        return out
    }
}
