// ArchivePromoteEngine.swift
// The filesystem half of Promote to Archive — pure functions over paths
// and file descriptors, no model, no actor. PromoteToArchiveJob is the
// orchestration; everything here is what a unit test can drive against a
// temp directory (docs/archive_promotion_workflow.md §5 + codex QA round 2,
// 2026-08-15).
//
// Contracts implemented here:
//
//   TOCTOU identity (codex blocker 2 — mirrors SignatureVerification):
//     - the SOURCE is opened once with O_RDONLY|O_NOFOLLOW; fstat must say
//       regular file; dev/ino/size/mtime are captured BEFORE the copy+hash
//       and re-checked AFTER — a source replaced or rewritten mid-copy is a
//       failure, never a silently-wrong archive copy;
//     - the DESTINATION `.partial` is created with O_RDWR|O_CREAT|O_EXCL|
//       O_NOFOLLOW; written, F_FULLFSYNC'd, and read back for the verify
//       hash THROUGH THE SAME DESCRIPTOR; after `renamex_np(RENAME_EXCL)`
//       the descriptor's fstat identity must equal `stat(dest)` — the
//       finalized path IS the bytes we hashed.
//   Containment (codex blocker 3): every intermediate directory under the
//     root is lstat'd — a symlink anywhere in the chain refuses; the
//     resolved destination must be inside the root component-wise.
//   Convergence (codex blocker 1): an intent journal
//     (`00_Index/.promote_journal.jsonl`) is appended BEFORE the copy and
//     at every later step; `identityMatches` lets the job ADOPT an
//     existing identical file instead of minting `_NN`.
//
// Memory: one 1 MB chunk buffer per pass; nothing else grows with file
// size. Worst case < 4 MB per in-flight file.

import CryptoKit
import Darwin
import Foundation

enum ArchivePromoteEngine {

    static let chunkSize = 1 << 20

    // MARK: Errors

    enum Failure: Error, Equatable, CustomStringConvertible {
        case sourceUnreadable(String)
        case sourceNotRegularFile(String)
        case sourceChangedDuringCopy(String)
        case destinationEscapesRoot(String)
        case symlinkInArchivePath(String)
        case partialExists(String)
        case createFailed(String, errno: Int32)
        case writeFailed(String)
        case verifyMismatch(expected: String, actual: String)
        case renameFailed(String, errno: Int32)
        case publishedIdentityMismatch(String)
        case cancelled

        var description: String {
            switch self {
            case .sourceUnreadable(let p): return "could not open source \(p)"
            case .sourceNotRegularFile(let p): return "source is not a regular file (symlink / device / directory refused): \(p)"
            case .sourceChangedDuringCopy(let p): return "source changed while it was being copied — nothing recorded: \(p)"
            case .destinationEscapesRoot(let p): return "resolved destination escapes the archive root — refused: \(p)"
            case .symlinkInArchivePath(let p): return "a symlink sits inside the archive path — refused: \(p)"
            case .partialExists(let p): return "a partial for this destination already exists (another job?): \(p)"
            case .createFailed(let p, let e): return "could not create \(p) (errno \(e))"
            case .writeFailed(let p): return "write failed: \(p)"
            case .verifyMismatch(let e, let a): return "verification failed — copy \(a.prefix(12))… ≠ source \(e.prefix(12))…; partial removed"
            case .renameFailed(let p, let e): return "could not publish \(p) (errno \(e))"
            case .publishedIdentityMismatch(let p): return "the published file is not the file that was verified — refused: \(p)"
            case .cancelled: return "cancelled"
            }
        }
    }

    // MARK: Identity

    /// dev/ino/size/mtime — same idea as SignatureVerification's
    /// VerifiedFileIdentity, captured through an open descriptor.
    struct FileIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let mtimeSec: Int64
        let mtimeNsec: Int64

        static func of(fd: Int32) -> (FileIdentity, mode: mode_t)? {
            var sb = stat()
            guard fstat(fd, &sb) == 0 else { return nil }
            return (FileIdentity(device: UInt64(sb.st_dev), inode: UInt64(sb.st_ino),
                                 size: Int64(sb.st_size),
                                 mtimeSec: Int64(sb.st_mtimespec.tv_sec),
                                 mtimeNsec: Int64(sb.st_mtimespec.tv_nsec)),
                    sb.st_mode & S_IFMT)
        }

        static func of(path: String) -> FileIdentity? {
            var sb = stat()
            guard stat(path, &sb) == 0 else { return nil }
            return FileIdentity(device: UInt64(sb.st_dev), inode: UInt64(sb.st_ino),
                                size: Int64(sb.st_size),
                                mtimeSec: Int64(sb.st_mtimespec.tv_sec),
                                mtimeNsec: Int64(sb.st_mtimespec.tv_nsec))
        }
    }

    /// An opened, validated source. Closed by `close()`; the job holds it
    /// for the whole per-file operation so the identity check is against
    /// the descriptor, not a re-opened path.
    final class SourceHandle {
        let path: String
        let fd: Int32
        let identity: FileIdentity
        private var closed = false
        fileprivate init(path: String, fd: Int32, identity: FileIdentity) {
            self.path = path; self.fd = fd; self.identity = identity
        }
        func close() { if !closed { Darwin.close(fd); closed = true } }
        deinit { close() }
    }

    /// Open the source: O_NOFOLLOW (a symlink at the leaf is refused by
    /// the kernel), regular file only.
    static func openSource(path: String) throws -> SourceHandle {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ELOOP { throw Failure.sourceNotRegularFile(path) }
            throw Failure.sourceUnreadable(path)
        }
        guard let (identity, mode) = FileIdentity.of(fd: fd), mode == S_IFREG else {
            Darwin.close(fd)
            throw Failure.sourceNotRegularFile(path)
        }
        return SourceHandle(path: path, fd: fd, identity: identity)
    }

    /// Streamed SHA-256 through an already-open descriptor, from offset 0.
    /// `shouldCancel` is polled per chunk. Returns nil on cancel.
    static func sha256(fd: Int32, shouldCancel: () -> Bool = { false }) throws -> String? {
        guard lseek(fd, 0, SEEK_SET) == 0 else { throw Failure.writeFailed("lseek") }
        var hasher = SHA256()
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            if shouldCancel() { return nil }
            let n = read(fd, buffer, chunkSize)
            if n > 0 {
                hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: n))
            } else if n == 0 {
                break
            } else if errno != EINTR {
                throw Failure.writeFailed("read errno \(errno)")
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Streamed SHA-256 of a path (O_NOFOLLOW, regular file only).
    static func sha256(path: String, shouldCancel: () -> Bool = { false }) throws -> String? {
        let h = try openSource(path: path)
        defer { h.close() }
        return try sha256(fd: h.fd, shouldCancel: shouldCancel)
    }

    // MARK: Containment

    /// Every path component from `root` down to (and including) `path`'s
    /// parent must be a real directory — no symlinks (lstat, not stat).
    /// Non-existent components are fine (they will be created).
    static func assertNoSymlinks(root: String, relativePath: String) throws {
        var url = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
        // The root itself may not be a symlink either.
        try assertNotSymlink(url.path)
        let comps = (relativePath as NSString).pathComponents.dropLast()
        for comp in comps {
            url.appendPathComponent(comp, isDirectory: true)
            try assertNotSymlink(url.path)
        }
    }

    private static func assertNotSymlink(_ path: String) throws {
        var sb = stat()
        guard lstat(path, &sb) == 0 else { return }   // absent = will be created
        if (sb.st_mode & S_IFMT) == S_IFLNK { throw Failure.symlinkInArchivePath(path) }
    }

    // MARK: Copy → verify → publish

    struct PublishResult: Equatable, Sendable {
        let sha256: String
        let sizeBytes: Int64
    }

    /// Steps 2–4 of the spec with the TOCTOU contract. `destinationURL`
    /// must not exist; its `.partial` sibling must not exist (O_EXCL).
    /// On ANY failure or cancel the partial is removed. Returns the digest
    /// (identical for source and published copy by construction).
    static func copyVerifyPublish(source: SourceHandle,
                                  root: String,
                                  relativePath: String,
                                  progress: (Int64) -> Void = { _ in },
                                  shouldCancel: () -> Bool = { false }) throws -> PublishResult {
        let destURL = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(relativePath).standardizedFileURL
        guard ArchivePathResolver.isInside(path: destURL.path, root: root),
              destURL.path != PathScope.normalize(root) else {
            throw Failure.destinationEscapesRoot(destURL.path)
        }
        try assertNoSymlinks(root: root, relativePath: relativePath)
        try? FileManager.default.createDirectory(at: destURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // Re-check after mkdir — a component could have been swapped for a
        // symlink between the check and the create.
        try assertNoSymlinks(root: root, relativePath: relativePath)

        let partialPath = destURL.path + ".partial"
        let dfd = open(partialPath, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard dfd >= 0 else {
            if errno == EEXIST { throw Failure.partialExists(partialPath) }
            throw Failure.createFailed(partialPath, errno: errno)
        }
        var published = false
        defer {
            Darwin.close(dfd)
            if !published { unlink(partialPath) }
        }

        // ---- Copy pass (source fd → dest fd, hashing source bytes).
        let (sourceSHA, copied) = try copyPass(source: source, dfd: dfd, partialPath: partialPath,
                                               progress: progress, shouldCancel: shouldCancel)

        // ---- Source unchanged? (dev/ino/size/mtime re-sampled on the SAME fd)
        guard let (after, _) = FileIdentity.of(fd: source.fd), after == source.identity,
              copied == source.identity.size else {
            throw Failure.sourceChangedDuringCopy(source.path)
        }

        // ---- Durability BEFORE the name becomes visible.
        if fcntl(dfd, F_FULLFSYNC) != 0 { fsync(dfd) }

        // ---- Verify pass through the SAME descriptor.
        guard let destSHA = try sha256(fd: dfd, shouldCancel: shouldCancel) else {
            throw Failure.cancelled
        }
        guard destSHA == sourceSHA else {
            throw Failure.verifyMismatch(expected: sourceSHA, actual: destSHA)
        }
        // Keep the original's mtime on the archive copy (via the fd).
        let ts = timespec(tv_sec: Int(source.identity.mtimeSec), tv_nsec: Int(source.identity.mtimeNsec))
        var times = [ts, ts]
        _ = futimens(dfd, &times)

        // ---- Publish: atomic, NO-CLOBBER rename + directory fsync + identity proof.
        try publish(dfd: dfd, partialPath: partialPath, destURL: destURL)
        published = true
        return PublishResult(sha256: sourceSHA, sizeBytes: copied)
    }

    /// The chunked read/write loop. Returns (sha256 of the bytes read,
    /// bytes copied). Throws `.cancelled` when `shouldCancel` fires.
    private static func copyPass(source: SourceHandle,
                                 dfd: Int32,
                                 partialPath: String,
                                 progress: (Int64) -> Void,
                                 shouldCancel: () -> Bool) throws -> (String, Int64) {
        guard lseek(source.fd, 0, SEEK_SET) == 0 else { throw Failure.sourceUnreadable(source.path) }
        var hasher = SHA256()
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16)
        defer { buffer.deallocate() }
        var copied: Int64 = 0
        while true {
            if shouldCancel() { throw Failure.cancelled }
            let n = read(source.fd, buffer, chunkSize)
            if n > 0 {
                hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: n))
                try writeAll(dfd, buffer, n, partialPath: partialPath)
                copied += Int64(n)
                progress(copied)
            } else if n == 0 {
                break
            } else if errno != EINTR {
                throw Failure.sourceUnreadable(source.path)
            }
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), copied)
    }

    /// write(2) until every byte of the buffer is out (EINTR-safe).
    private static func writeAll(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int,
                                 partialPath: String) throws {
        var offset = 0
        while offset < count {
            let w = write(fd, buffer.advanced(by: offset), count - offset)
            if w < 0 {
                if errno == EINTR { continue }
                throw Failure.writeFailed("\(partialPath) errno \(errno)")
            }
            offset += w
        }
    }

    /// renamex_np(RENAME_EXCL) → fsync(dir) → prove `stat(dest)` is the
    /// descriptor we wrote and hashed.
    private static func publish(dfd: Int32, partialPath: String, destURL: URL) throws {
        let rc = renamex_np(partialPath, destURL.path, UInt32(RENAME_EXCL))
        guard rc == 0 else { throw Failure.renameFailed(destURL.path, errno: errno) }
        let dirFD = open(destURL.deletingLastPathComponent().path, O_RDONLY | O_NOFOLLOW)
        if dirFD >= 0 { fsync(dirFD); Darwin.close(dirFD) }
        guard let (fdIdentity, _) = FileIdentity.of(fd: dfd),
              let pathIdentity = FileIdentity.of(path: destURL.path),
              fdIdentity.device == pathIdentity.device, fdIdentity.inode == pathIdentity.inode,
              fdIdentity.size == pathIdentity.size else {
            throw Failure.publishedIdentityMismatch(destURL.path)
        }
    }

    // MARK: Adopt-if-identical

    /// Does the file at `existingPath` hold exactly the source's bytes?
    /// Cheap size gate first, then a full hash of the existing file
    /// against `sourceSHA()` (lazily computed by the caller — one extra
    /// source read, only on a name collision). nil ⇒ "not identical or
    /// unreadable"; the digest ⇒ identical.
    static func identicalDigest(existingPath: String,
                                sourceSize: Int64,
                                sourceSHA: () throws -> String?,
                                shouldCancel: () -> Bool = { false }) throws -> String? {
        guard let existing = FileIdentity.of(path: existingPath), existing.size == sourceSize else { return nil }
        guard let theirs = try sha256(path: existingPath, shouldCancel: shouldCancel),
              let ours = try sourceSHA(), theirs == ours else { return nil }
        return ours
    }
}

// MARK: - Intent journal (convergence)

/// `00_Index/.promote_journal.jsonl` — one JSON line per step per source
/// so a crash at ANY point can be reconciled on the next run
/// (codex QA round 2, blocker 1). Append-only, O_APPEND single writes,
/// like the manifest. States, in order:
///   intent   — dest resolved, copy about to start (partial may exist)
///   renamed  — file published + fsynced (sha known)
///   manifest — manifest row appended
///   done     — catalog record created + source stamped
enum ArchivePromoteJournal {
    static let filename = ".promote_journal.jsonl"

    struct Entry: Codable, Equatable, Sendable {
        enum State: String, Codable, Sendable { case intent, renamed, manifest, done, abandoned }
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

    /// Append one entry (single O_APPEND write + fsync). Throws on failure
    /// — a promotion whose intent cannot be journaled must not start.
    nonisolated static func append(_ entry: Entry, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(entry)
        data.append(0x0A)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o644)
        guard fd >= 0 else { throw ArchiveManifestCSV.ManifestError.openFailed(path: url.path, errno: errno) }
        defer { close(fd) }
        let written = data.withUnsafeBytes { buf -> Int in
            guard let base = buf.baseAddress else { return 0 }
            return write(fd, base, buf.count)
        }
        guard written == data.count else {
            throw ArchiveManifestCSV.ManifestError.shortWrite(path: url.path, expected: data.count, wrote: written)
        }
        fsync(fd)
    }

    /// Latest entry per source id (a source can be journaled several
    /// times — retries, later Refile). Unparseable lines are skipped.
    nonisolated static func latestBySource(in url: URL) -> [UUID: Entry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [UUID: Entry] = [:]
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let e = try? decoder.decode(Entry.self, from: d) else { continue }
            out[e.sourceRecordID] = e
        }
        return out
    }
}
