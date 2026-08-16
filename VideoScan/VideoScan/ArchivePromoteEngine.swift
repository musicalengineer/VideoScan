// ArchivePromoteEngine.swift
// The filesystem half of Promote to Archive — pure functions over file
// descriptors, no model, no actor. PromoteToArchiveJob is the
// orchestration; everything here is what a unit test can drive against a
// temp directory (docs/archive_promotion_workflow.md §5 + codex QA rounds
// 2–3, 2026-08-15/16).
//
// Contracts implemented here:
//
//   Descriptor-relative tree walk (codex R3 blocker 3): NOTHING under the
//     archive root is opened by absolute path. The root is opened
//     O_DIRECTORY|O_NOFOLLOW, every component below it is mkdirat/openat
//     (O_DIRECTORY|O_NOFOLLOW) relative to its parent descriptor, the
//     partial is openat(dirfd, …, O_EXCL|O_NOFOLLOW), publish is
//     renameatx_np(dirfd, …, RENAME_EXCL), and the manifest/journal are
//     openat(indexfd, …, O_NOFOLLOW). A symlink swapped in at any depth,
//     at any moment, fails with ELOOP/ENOTDIR instead of being followed.
//   TOCTOU identity (codex R2 blocker 2 — mirrors SignatureVerification):
//     source opened O_RDONLY|O_NOFOLLOW, regular file only, dev/ino/size/
//     mtime captured before the copy and re-checked after; the partial is
//     written, hashed and fsynced THROUGH THE SAME DESCRIPTOR; after publish
//     fstat(fd) must equal fstatat(dirfd, name).
//   Durability ORDER + errors (codex R3 blocker 4): copy → verify (fd) →
//     futimens → F_FULLFSYNC(final data+meta) → renameatx_np → fsync(parent
//     dirfd). Then manifest append + F_FULLFSYNC, journal append + fsync.
//     EVERY barrier is checked; a failed barrier throws (the step is not
//     durable, nothing downstream is claimed). `barriers` is the test seam.
//   Manifest during promote is opened O_RDWR|O_APPEND|O_NOFOLLOW with NO
//     O_CREAT: it must already be a regular file carrying the header;
//     missing/replaced ⇒ refuse (Initialize owns creation).
//
// Memory: one 1 MB chunk buffer per pass; nothing grows with file size.

import CryptoKit
import Darwin
import Foundation

enum ArchivePromoteEngine {

    static let chunkSize = 1 << 20

    // MARK: Barrier seam

    /// The durability primitives, injectable so a test can make a barrier
    /// fail and prove the step is NOT claimed. Production = the real
    /// syscalls. TASK-LOCAL (codex R5 major 4): a test injects with
    /// `ArchivePromoteEngine.$barriers.withValue(...) { … }`, which is
    /// visible only inside that task tree (the job's `Task {}` and the
    /// `@concurrent` hops inherit it) — never process-global, so parallel
    /// suites cannot be poisoned. (For Rick: ≈ thread-local storage that
    /// follows structured concurrency instead of OS threads.)
    struct Barriers: Sendable {
        var fullFsync: @Sendable (Int32) -> Int32
        var fsync: @Sendable (Int32) -> Int32
        static let live = Barriers(
            fullFsync: { fd in fcntl(fd, F_FULLFSYNC) == 0 ? 0 : Darwin.fsync(fd) },
            fsync: { fd in Darwin.fsync(fd) })
    }
    @TaskLocal static var barriers = Barriers.live

    // MARK: Errors

    enum Failure: Error, Equatable, CustomStringConvertible {
        case sourceUnreadable(String)
        case sourceNotRegularFile(String)
        case sourceChangedDuringCopy(String)
        case destinationEscapesRoot(String)
        case symlinkInArchivePath(String)
        case notADirectory(String)
        case partialExists(String)
        case createFailed(String, errno: Int32)
        case writeFailed(String)
        case verifyMismatch(expected: String, actual: String)
        case renameFailed(String, errno: Int32)
        case publishedIdentityMismatch(String)
        case durabilityBarrierFailed(String)
        case manifestInvalid(String)
        case cancelled

        var description: String {
            switch self {
            case .sourceUnreadable(let p): return "could not open source \(p)"
            case .sourceNotRegularFile(let p): return "source is not a regular file (symlink / device / directory refused): \(p)"
            case .sourceChangedDuringCopy(let p): return "source changed while it was being copied — nothing recorded: \(p)"
            case .destinationEscapesRoot(let p): return "resolved destination escapes the archive root — refused: \(p)"
            case .symlinkInArchivePath(let p): return "a symlink sits inside the archive path — refused: \(p)"
            case .notADirectory(let p): return "expected a directory inside the archive tree: \(p)"
            case .partialExists(let p): return "a partial for this destination already exists (another job?): \(p)"
            case .createFailed(let p, let e): return "could not create \(p) (errno \(e))"
            case .writeFailed(let p): return "write failed: \(p)"
            case .verifyMismatch(let e, let a): return "verification failed — copy \(a.prefix(12))… ≠ source \(e.prefix(12))…; partial removed"
            case .renameFailed(let p, let e): return "could not publish \(p) (errno \(e))"
            case .publishedIdentityMismatch(let p): return "the published file is not the file that was verified — refused: \(p)"
            case .durabilityBarrierFailed(let what): return "durability barrier failed (\(what)) — the step was not made durable and is not recorded"
            case .manifestInvalid(let why): return "archive manifest refused: \(why) — run Initialize Master Archive again"
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

        fileprivate init(_ sb: stat) {
            device = UInt64(sb.st_dev); inode = UInt64(sb.st_ino); size = Int64(sb.st_size)
            mtimeSec = Int64(sb.st_mtimespec.tv_sec); mtimeNsec = Int64(sb.st_mtimespec.tv_nsec)
        }

        static func of(fd: Int32) -> (FileIdentity, mode: mode_t)? {
            var sb = stat()
            guard fstat(fd, &sb) == 0 else { return nil }
            return (FileIdentity(sb), sb.st_mode & S_IFMT)
        }

        static func of(path: String) -> FileIdentity? {
            var sb = stat()
            guard stat(path, &sb) == 0 else { return nil }
            return FileIdentity(sb)
        }

        /// lstat-style identity of `name` relative to `dirfd` (no follow).
        static func at(dirfd: Int32, name: String) -> (FileIdentity, mode: mode_t)? {
            var sb = stat()
            guard fstatat(dirfd, name, &sb, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
            return (FileIdentity(sb), sb.st_mode & S_IFMT)
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

    // MARK: Descriptor-relative tree walk

    /// Open `path` as a directory, refusing a symlink at the leaf.
    static func openDirectory(_ path: String) throws -> Int32 {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            let e = errno
            var sb = stat()
            let isLink = lstat(path, &sb) == 0 && (sb.st_mode & S_IFMT) == S_IFLNK
            if isLink || e == ELOOP { throw Failure.symlinkInArchivePath(path) }
            if e == ENOTDIR { throw Failure.notADirectory(path) }
            throw Failure.createFailed(path, errno: e)
        }
        return fd
    }

    /// Walk (and optionally create) `components` below an already-open
    /// directory descriptor, each step `mkdirat` + `openat(O_DIRECTORY|
    /// O_NOFOLLOW)` relative to its parent. Returns the LEAF descriptor
    /// (caller closes; the parent is never closed). A symlink at any depth
    /// is refused by the kernel (ELOOP) — no lstat/mkdir race.
    static func descend(from parentFD: Int32, components: [String], create: Bool,
                        displayRoot: String) throws -> Int32 {
        var current = dup(parentFD)
        guard current >= 0 else { throw Failure.createFailed(displayRoot, errno: errno) }
        var trail = displayRoot
        for comp in components {
            guard !comp.isEmpty, comp != ".", comp != "..", !comp.contains("/") else {
                Darwin.close(current)
                throw Failure.destinationEscapesRoot(trail + "/" + comp)
            }
            trail += "/" + comp
            if create, mkdirat(current, comp, 0o755) != 0, errno != EEXIST {
                let e = errno
                Darwin.close(current)
                throw Failure.createFailed(trail, errno: e)
            }
            let next = openat(current, comp, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let e = errno
            // Whatever errno the kernel chose (ELOOP vs ENOTDIR differs by
            // filesystem), a symlink at this name is reported as such.
            let isLink = next < 0 && FileIdentity.at(dirfd: current, name: comp)?.mode == S_IFLNK
            Darwin.close(current)
            guard next >= 0 else {
                if isLink || e == ELOOP { throw Failure.symlinkInArchivePath(trail) }
                if e == ENOTDIR { throw Failure.notADirectory(trail) }
                throw Failure.createFailed(trail, errno: e)
            }
            current = next
        }
        return current
    }

    /// Open the archive root, then descend to the directory that will hold
    /// `relativePath` (creating it when `create`). Returns the leaf dirfd.
    static func openDestinationDirectory(root: String, relativePath: String, create: Bool) throws -> Int32 {
        let comps = (relativePath as NSString).pathComponents.dropLast()
        let rootFD = try openDirectory(root)
        defer { Darwin.close(rootFD) }
        return try descend(from: rootFD, components: Array(comps), create: create, displayRoot: root)
    }

    /// `00_Index/` descriptor under the root (never created here).
    static func openIndexDirectory(root: String) throws -> Int32 {
        let rootFD = try openDirectory(root)
        defer { Darwin.close(rootFD) }
        return try descend(from: rootFD, components: [MasterArchiveLayout.indexFolder],
                           create: false, displayRoot: root)
    }

    // MARK: Contained lookups for journal / manifest relpaths (codex R4-A)

    /// True when `relativePath` is a safe archive-relative path: canonical
    /// component-wise containment under `root`, no empty/`.`/`..` parts,
    /// at least one directory below the root, and a non-empty leaf.
    static func isContainedRelPath(_ relativePath: String, root: String) -> Bool {
        let comps = (relativePath as NSString).pathComponents
        guard comps.count >= 2, !relativePath.hasPrefix("/") else { return false }
        for c in comps where c.isEmpty || c == "." || c == ".." || c.contains("/") { return false }
        let full = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(relativePath).standardizedFileURL.path
        return ArchivePathResolver.isInside(path: full, root: root) && full != PathScope.normalize(root)
    }

    /// Open the archive-relative regular file `relativePath` for reading
    /// THROUGH the dirfd chain (every component O_NOFOLLOW; leaf O_NOFOLLOW).
    /// nil ⇒ absent (a missing directory or leaf). Throws for a non-contained
    /// relpath, a symlink at any depth, or a non-regular leaf — callers log
    /// and skip such entries, never act on them. Caller closes the fd.
    static func openContainedFile(root: String, relativePath: String) throws -> Int32? {
        guard isContainedRelPath(relativePath, root: root) else {
            throw Failure.destinationEscapesRoot(relativePath)
        }
        let dirfd: Int32
        do {
            dirfd = try openDestinationDirectory(root: root, relativePath: relativePath, create: false)
        } catch Failure.createFailed(_, let e) where e == ENOENT {
            return nil
        }
        defer { Darwin.close(dirfd) }
        let name = (relativePath as NSString).lastPathComponent
        let fd = openat(dirfd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            let e = errno
            if e == ENOENT { return nil }
            if e == ELOOP || FileIdentity.at(dirfd: dirfd, name: name)?.mode == S_IFLNK {
                throw Failure.symlinkInArchivePath(relativePath)
            }
            throw Failure.createFailed(relativePath, errno: e)
        }
        guard let (_, mode) = FileIdentity.of(fd: fd), mode == S_IFREG else {
            Darwin.close(fd)
            throw Failure.sourceNotRegularFile(relativePath)
        }
        return fd
    }

    /// Streamed digest of a contained archive file (see openContainedFile).
    /// nil ⇒ absent.
    static func sha256(root: String, relativePath: String, shouldCancel: () -> Bool = { false }) throws -> String? {
        guard let fd = try openContainedFile(root: root, relativePath: relativePath) else { return nil }
        defer { Darwin.close(fd) }
        return try sha256(fd: fd, shouldCancel: shouldCancel)
    }

    /// Remove `<relativePath>.partial` if present — via the dirfd chain,
    /// unlinkat, never through a symlink. Non-contained ⇒ throws (nothing
    /// removed). Returns true when something was removed.
    @discardableResult
    static func removeContainedPartial(root: String, relativePath: String) throws -> Bool {
        guard isContainedRelPath(relativePath, root: root) else {
            throw Failure.destinationEscapesRoot(relativePath)
        }
        let dirfd: Int32
        do {
            dirfd = try openDestinationDirectory(root: root, relativePath: relativePath, create: false)
        } catch Failure.createFailed(_, let e) where e == ENOENT {
            return false
        }
        defer { Darwin.close(dirfd) }
        let name = (relativePath as NSString).lastPathComponent + ".partial"
        guard let (_, mode) = FileIdentity.at(dirfd: dirfd, name: name) else { return false }
        guard mode == S_IFREG else { throw Failure.symlinkInArchivePath(relativePath + ".partial") }
        return unlinkat(dirfd, name, 0) == 0
    }

    // MARK: Copy → verify → publish

    struct PublishResult: Equatable, Sendable {
        let sha256: String
        let sizeBytes: Int64
    }

    /// Steps 2–4 of the spec with the TOCTOU + durability contracts.
    /// `relativePath` must not exist; its `.partial` sibling must not exist
    /// (O_EXCL). On ANY failure or cancel the partial is removed. Returns
    /// the digest (identical for source and published copy by construction).
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
        let name = (relativePath as NSString).lastPathComponent
        let partialName = name + ".partial"
        let dirfd = try openDestinationDirectory(root: root, relativePath: relativePath, create: true)
        defer { Darwin.close(dirfd) }

        let dfd = openat(dirfd, partialName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard dfd >= 0 else {
            if errno == EEXIST { throw Failure.partialExists(destURL.path + ".partial") }
            throw Failure.createFailed(destURL.path + ".partial", errno: errno)
        }
        var published = false
        defer {
            Darwin.close(dfd)
            if !published { unlinkat(dirfd, partialName, 0) }
        }

        // ---- 1. Copy pass (source fd → dest fd, hashing source bytes).
        let (sourceSHA, copied) = try copyPass(source: source, dfd: dfd, partialPath: destURL.path,
                                               progress: progress, shouldCancel: shouldCancel)
        // ---- Source unchanged? (dev/ino/size/mtime re-sampled on the SAME fd)
        guard let (after, _) = FileIdentity.of(fd: source.fd), after == source.identity,
              copied == source.identity.size else {
            throw Failure.sourceChangedDuringCopy(source.path)
        }
        // ---- 2. Verify pass through the SAME descriptor.
        guard let destSHA = try sha256(fd: dfd, shouldCancel: shouldCancel) else {
            throw Failure.cancelled
        }
        guard destSHA == sourceSHA else {
            throw Failure.verifyMismatch(expected: sourceSHA, actual: destSHA)
        }
        // ---- 3. Final metadata (original mtime), THEN the barrier covers it.
        let ts = timespec(tv_sec: Int(source.identity.mtimeSec), tv_nsec: Int(source.identity.mtimeNsec))
        var times = [ts, ts]
        _ = futimens(dfd, &times)
        // ---- 4. F_FULLFSYNC the final data + metadata BEFORE the name is visible.
        guard barriers.fullFsync(dfd) == 0 else {
            throw Failure.durabilityBarrierFailed("F_FULLFSYNC on \(partialName)")
        }
        // ---- 5. Publish: atomic, NO-CLOBBER rename relative to the dirfd.
        guard renameatx_np(dirfd, partialName, dirfd, name, UInt32(RENAME_EXCL)) == 0 else {
            throw Failure.renameFailed(destURL.path, errno: errno)
        }
        published = true
        // ---- 6. fsync the parent directory so the rename itself is durable.
        // A failed barrier here means the NAME may not survive a crash: the
        // verified bytes are withdrawn again (source untouched) and the
        // step reports failure rather than claiming a published copy.
        guard barriers.fsync(dirfd) == 0 else {
            unlinkat(dirfd, name, 0)
            throw Failure.durabilityBarrierFailed("fsync on the archive folder for \(name)")
        }
        // ---- 7. The finalized name IS the file we hashed (fd identity == dirfd/name identity).
        guard let (fdIdentity, _) = FileIdentity.of(fd: dfd),
              let (nameIdentity, mode) = FileIdentity.at(dirfd: dirfd, name: name),
              mode == S_IFREG,
              fdIdentity.device == nameIdentity.device, fdIdentity.inode == nameIdentity.inode,
              fdIdentity.size == nameIdentity.size else {
            throw Failure.publishedIdentityMismatch(destURL.path)
        }
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
                try writeAll(dfd, UnsafeRawPointer(buffer), n, label: partialPath)
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
    static func writeAll(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int, label: String) throws {
        var offset = 0
        while offset < count {
            let w = write(fd, buffer.advanced(by: offset), count - offset)
            if w < 0 {
                if errno == EINTR { continue }
                throw Failure.writeFailed("\(label) errno \(errno)")
            }
            offset += w
        }
    }

    // MARK: Index files (manifest / journal) — descriptor-relative, no follow

    /// Open `00_Index/<name>` for appending. `mustExist` (the manifest
    /// during promote): NO O_CREAT — a missing file is a refusal, and the
    /// opened file must be a regular file whose first bytes are
    /// `expectedHeader` (when given). Otherwise (the journal) O_CREAT is
    /// allowed but never through a symlink. Returns the fd (caller closes).
    static func openIndexFile(root: String, name: String, mustExist: Bool,
                              expectedHeader: String? = nil) throws -> Int32 {
        let indexFD = try openIndexDirectory(root: root)
        defer { Darwin.close(indexFD) }
        var flags = O_RDWR | O_APPEND | O_NOFOLLOW | O_CLOEXEC
        if !mustExist { flags |= O_CREAT }
        let fd = openat(indexFD, name, flags, 0o644)
        guard fd >= 0 else {
            let e = errno
            if e == ELOOP { throw Failure.symlinkInArchivePath("\(MasterArchiveLayout.indexFolder)/\(name)") }
            if e == ENOENT { throw Failure.manifestInvalid("\(name) is missing") }
            throw Failure.createFailed("\(MasterArchiveLayout.indexFolder)/\(name)", errno: e)
        }
        guard let (_, mode) = FileIdentity.of(fd: fd), mode == S_IFREG else {
            Darwin.close(fd)
            throw Failure.manifestInvalid("\(name) is not a regular file")
        }
        if let expectedHeader {
            let want = Data(expectedHeader.utf8)
            var head = [UInt8](repeating: 0, count: want.count)
            let n = pread(fd, &head, want.count, 0)
            guard n == want.count, Data(head) == want else {
                Darwin.close(fd)
                throw Failure.manifestInvalid("\(name) does not start with the expected header")
            }
        }
        return fd
    }

    /// One O_APPEND write of `data` + the requested barrier; a short write
    /// or a failed barrier throws (the row is not claimed durable).
    static func appendDurable(fd: Int32, data: Data, full: Bool, label: String) throws {
        let written = data.withUnsafeBytes { buf -> Int in
            guard let base = buf.baseAddress else { return 0 }
            return write(fd, base, buf.count)
        }
        guard written == data.count else {
            throw Failure.writeFailed("\(label): short write (\(written) of \(data.count) bytes)")
        }
        let rc = full ? barriers.fullFsync(fd) : barriers.fsync(fd)
        guard rc == 0 else { throw Failure.durabilityBarrierFailed(label) }
    }

    /// Create `00_Index/<name>` with `contents` if it does not exist
    /// (O_EXCL|O_NOFOLLOW relative to the index dirfd), F_FULLFSYNC it and
    /// fsync the index directory. Returns true when created. A symlink or
    /// non-regular entry at that name is refused, never followed.
    static func createIndexFileIfMissing(indexFD: Int32, name: String, contents: Data) throws -> Bool {
        if let (_, mode) = FileIdentity.at(dirfd: indexFD, name: name) {
            guard mode == S_IFREG else {
                throw Failure.symlinkInArchivePath("\(MasterArchiveLayout.indexFolder)/\(name)")
            }
            return false
        }
        let fd = openat(indexFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            if errno == EEXIST { return false }   // raced another creator — fine
            throw Failure.createFailed(name, errno: errno)
        }
        defer { Darwin.close(fd) }
        try contents.withUnsafeBytes { buf in
            if let base = buf.baseAddress { try writeAll(fd, base, buf.count, label: name) }
        }
        guard barriers.fullFsync(fd) == 0, barriers.fsync(indexFD) == 0 else {
            throw Failure.durabilityBarrierFailed("creating \(name)")
        }
        return true
    }

    // MARK: Adopt-if-identical

    /// Does the already-open, contained file `fd` hold exactly the
    /// source's bytes? Cheap size gate first (fstat), then a full hash
    /// against `sourceSHA()` (lazily computed by the caller — one extra
    /// source read, only on a same-size collision). nil ⇒ not identical.
    /// Descriptor-based on purpose (codex R5 blocker 2): the caller
    /// obtained `fd` through the dirfd O_NOFOLLOW chain, so a symlinked
    /// intermediate can never make an outside file look adoptable.
    static func identicalDigest(fd: Int32,
                                sourceSize: Int64,
                                sourceSHA: () throws -> String?,
                                shouldCancel: () -> Bool = { false }) throws -> String? {
        guard let (existing, _) = FileIdentity.of(fd: fd), existing.size == sourceSize else { return nil }
        guard let theirs = try sha256(fd: fd, shouldCancel: shouldCancel),
              let ours = try sourceSHA(), theirs == ours else { return nil }
        return ours
    }

    /// Whole contents of an already-open (validated) descriptor via pread
    /// from offset 0 — the manifest/journal are parsed from the SAME fd
    /// that was validated (codex R5 major 3), never re-opened by path.
    /// Bounded by `limit` (default 256 MB) so a runaway file cannot
    /// exhaust memory.
    static func readAll(fd: Int32, limit: Int = 256 << 20) throws -> Data {
        var out = Data()
        var offset: off_t = 0
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16)
        defer { buffer.deallocate() }
        while out.count < limit {
            let n = pread(fd, buffer, chunkSize, offset)
            if n > 0 {
                out.append(UnsafeRawBufferPointer(start: buffer, count: n).bindMemory(to: UInt8.self))
                offset += off_t(n)
            } else if n == 0 {
                break
            } else if errno != EINTR {
                throw Failure.writeFailed("pread errno \(errno)")
            }
        }
        return out
    }
}

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
        let fd = try ArchivePromoteEngine.openIndexFile(root: rootPath, name: filename, mustExist: false)
        defer { close(fd) }
        try ArchivePromoteEngine.appendDurable(fd: fd, data: data, full: false, label: "journal append")
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
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let e = try? decoder.decode(Entry.self, from: d) else { continue }
            out[e.sourceRecordID] = e
        }
        return out
    }
}
