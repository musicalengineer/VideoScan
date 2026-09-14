// RescueFileCopier.swift
// One-file copy primitive for the DRIVE RESCUE path (VolumeCompare's
// "Fast" mode). Extracted 2026-09-13 from VolumeRescueOperation.fastCopy,
// which had two data-integrity defects the /Volumes check-then-act ratchet
// found (scripts/check_volume_check_then_act.py):
//
//   1. `try fm.copyItem(atPath:toPath:)` wrote to the FINAL name. An
//      interrupted rescue — drive drops off the bus, app quits, user
//      cancels — left a truncated file sitting at the final name. The next
//      run's `fileExists` saw it, called it "copied", and moved on. A
//      partial rescue copy was silently reported as a good one.
//   2. `bytesWritten += sizeBytes` accrued the CATALOG's idea of the source
//      size. Nothing measured what actually reached the destination, so the
//      number in the UI was a claim, not a measurement.
//
// The fix follows the pattern ArchivePromoteEngine already uses: open the
// destination ONCE, write through that descriptor into a `.partial`
// sidecar, fsync it, then rename it into place and fsync the parent
// directory. The descriptor is the reservation — if the volume goes away
// mid-file the syscall fails loudly instead of half-succeeding, and a torn
// `.partial` can never be mistaken for a finished file.
//
// Deliberate differences from ArchivePromoteEngine:
//   - No SHA-256 copy+verify pass. This is the mode the user picked when
//     they chose "Fast (no verification)"; the Verified mode is rsync
//     --checksum. We never claim verification we did not do.
//   - `fsync(2)`, not `F_FULLFSYNC`. F_FULLFSYNC asks the drive to flush
//     its write cache — on an external spinner it can cost tens of
//     milliseconds PER FILE, and a whole-drive rescue is tens of thousands
//     of files. What this path must guarantee is ORDER (bytes before the
//     name), which fsync gives. Archive promotion, which issues a durable
//     attestation, keeps F_FULLFSYNC.
//   - The `.partial` is opened O_EXCL, but a pre-existing one is unlinked
//     and re-created rather than refused: a leftover `.partial` is the
//     EXPECTED residue of a yanked drive, and it is always re-copied,
//     never counted.
//
// Memory: one reusable `chunkSize` buffer per file, freed when the copy
// ends. Nothing here grows with file size or with the number of files.
//
// (For Rick: this is the C idiom — open(2)/read(2)/write(2)/fsync(2)/
// rename(2) — wrapped so Swift's error handling and Task cancellation can
// see it. `@TaskLocal` below is thread-local storage that follows
// structured concurrency instead of OS threads.)

import Darwin
import Foundation

enum RescueFileCopier {

    /// Read/write chunk. 4 MiB is the same order as the promote engine's
    /// 8 MiB pipeline chunk and halves the per-file buffer; this path is
    /// not pipelined, so a bigger buffer buys nothing.
    static let chunkSize = 4 << 20

    /// Sidecar suffix. Same spelling as ArchivePromoteEngine's so anything
    /// that sweeps stale partials recognises both.
    static let partialSuffix = ".partial"

    // MARK: - Result

    /// What happened to ONE file. `bytesWritten` is always measured from
    /// the return values of write(2) — never inferred from a catalog row.
    enum Outcome: Equatable, Sendable {
        /// Fresh copy; destination did not exist.
        case copied(bytesWritten: Int64)
        /// Destination already existed with the SAME size as the source.
        /// This is the resumed-rescue case the old `fileExists` check was
        /// written for, and it is the only case that legitimately skips.
        /// `bytes` is the measured size of the file that is already there.
        case alreadyPresent(bytes: Int64)
        /// Destination existed with a DIFFERENT size — i.e. it was
        /// incomplete (or otherwise not this source's file). It was
        /// re-copied through the `.partial` path and replaced.
        case recopiedIncomplete(bytesWritten: Int64, previousSize: Int64)
    }

    // MARK: - Errors

    enum Failure: Error, Equatable, CustomStringConvertible, LocalizedError {
        case sourceUnreadable(String, errno: Int32)
        case sourceNotRegularFile(String)
        case sourceReadFailed(String, errno: Int32)
        case sourceChangedDuringCopy(String)
        case destinationNotRegularFile(String)
        case destinationUnreadable(String, errno: Int32)
        case partialCreateFailed(String, errno: Int32)
        case partialContended(String)
        case writeFailed(String, errno: Int32)
        case renameFailed(String, errno: Int32)
        case destinationAppearedDuringCopy(String)
        case durabilityBarrierFailed(String, errno: Int32)
        case cancelled

        var description: String {
            switch self {
            case .sourceUnreadable(let p, let e): return "could not open source \(p) (errno \(e))"
            case .sourceNotRegularFile(let p): return "source is not a regular file (symlink / device / directory refused): \(p)"
            case .sourceReadFailed(let p, let e): return "read failed on source \(p) (errno \(e)) — nothing published"
            case .sourceChangedDuringCopy(let p): return "source changed while it was being copied — nothing published: \(p)"
            case .destinationNotRegularFile(let p): return "destination exists but is not a regular file (symlink?) — refused: \(p)"
            case .destinationUnreadable(let p, let e): return "destination exists but could not be examined \(p) (errno \(e))"
            case .partialCreateFailed(let p, let e): return "could not create \(p) (errno \(e))"
            case .partialContended(let p): return "another copy is writing \(p) right now — skipped"
            case .writeFailed(let p, let e): return "write failed on \(p) (errno \(e)) — partial removed, nothing published"
            case .renameFailed(let p, let e): return "could not publish \(p) (errno \(e)) — partial removed, nothing published"
            case .destinationAppearedDuringCopy(let p): return "something else created \(p) while it was being copied — nothing published"
            case .durabilityBarrierFailed(let what, let e): return "durability barrier failed (\(what), errno \(e)) — nothing published"
            case .cancelled: return "cancelled"
            }
        }

        var errorDescription: String? { description }
    }

    // MARK: - Test seam

    /// Injectable syscall edges so a test can prove the failure paths
    /// without needing a real drive to fall off the bus. Task-local (same
    /// reasoning as `ArchivePromoteEngine.barriers`): visible only inside
    /// the injecting task tree, so parallel suites cannot poison each
    /// other.
    struct Hooks: Sendable {
        /// Data + metadata barrier on the `.partial` before it is renamed,
        /// and on the parent directory after.
        var fsync: @Sendable (Int32) -> Int32
        /// Called after each chunk reaches the destination with the running
        /// byte count. Returns an errno to INJECT (simulating the volume
        /// vanishing mid-file), or 0 to continue.
        var afterChunk: @Sendable (Int64) -> Int32
        static let live = Hooks(fsync: { Darwin.fsync($0) }, afterChunk: { _ in 0 })
    }
    @TaskLocal static var hooks = Hooks.live

    // MARK: - Copy

    /// Copy `source` to `destination`, publishing only a complete file.
    ///
    /// Contract:
    ///   - A destination that already exists with the source's size is left
    ///     alone and reported `.alreadyPresent` (resumed rescue).
    ///   - A destination whose size DIFFERS is incomplete; it is re-copied
    ///     and replaced, and reported `.recopiedIncomplete` so the caller
    ///     can say so loudly.
    ///     SAFETY ASSUMPTION, stated because the whole decision rests on
    ///     it: `destination` is inside the rescue folder THIS FLOW created
    ///     under the user's chosen destination (VolumeRescueOperation
    ///     builds it as destPath/<folderName>/<relative source path>).
    ///     Nothing but a previous rescue of this same source file can
    ///     legitimately occupy that name, so replacing it cannot destroy
    ///     unrelated data. The replacement is not destructive in the
    ///     interim either: the new bytes land in a `.partial`, and the old
    ///     file is only unlinked by the atomic rename that publishes the
    ///     new one. If this function is ever reused for a destination the
    ///     app did not create, this policy must be revisited.
    ///   - A leftover `.partial` from an earlier run is always discarded
    ///     and re-copied from zero; it is never counted as progress.
    ///   - On ANY error or cancellation the `.partial` is removed and the
    ///     final name is left exactly as it was found.
    ///
    /// `progress` reports bytes written so far for this file (for a caller
    /// that wants intra-file progress); it is called at most once per
    /// chunk.
    @discardableResult
    static func copy(source: String,
                     destination: String,
                     shouldCancel: () -> Bool = { false },
                     progress: (Int64) -> Void = { _ in }) throws -> Outcome {

        // ---- 1. Source, through a descriptor we keep for the whole copy.
        let sfd = openRetryingEINTR(source, O_RDONLY | O_CLOEXEC)
        guard sfd >= 0 else { throw Failure.sourceUnreadable(source, errno: errno) }
        defer { Darwin.close(sfd) }

        var sourceStat = stat()
        guard fstat(sfd, &sourceStat) == 0 else {
            throw Failure.sourceUnreadable(source, errno: errno)
        }
        guard (sourceStat.st_mode & S_IFMT) == S_IFREG else {
            throw Failure.sourceNotRegularFile(source)
        }
        let sourceSize = Int64(sourceStat.st_size)

        // ---- 2. Does a destination already exist, and is it complete?
        // Answered THROUGH a descriptor (fstat on what we actually opened),
        // not by asking the filesystem a question about a name.
        var previousSize: Int64?
        let existingFD = openRetryingEINTR(destination, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if existingFD >= 0 {
            defer { Darwin.close(existingFD) }
            var destStat = stat()
            guard fstat(existingFD, &destStat) == 0 else {
                throw Failure.destinationUnreadable(destination, errno: errno)
            }
            guard (destStat.st_mode & S_IFMT) == S_IFREG else {
                throw Failure.destinationNotRegularFile(destination)
            }
            if Int64(destStat.st_size) == sourceSize {
                // Resumed rescue: the file is already there, whole. Sweep
                // any stale `.partial` beside it — residue of the run that
                // was interrupted before this file was finished on a later
                // attempt. Best effort: if another process is mid-copy on
                // that partial, unlinking it costs that process its
                // publish (its rename fails) but can never make it report
                // a false success.
                unlink(destination + partialSuffix)
                return .alreadyPresent(bytes: Int64(destStat.st_size))
            }
            // Short (or long) — incomplete. Fall through and re-copy.
            previousSize = Int64(destStat.st_size)
        } else {
            let openErrno = errno
            switch openErrno {
            case ENOENT:
                break                                   // the normal, fresh case
            case ELOOP:
                throw Failure.destinationNotRegularFile(destination)
            default:
                throw Failure.destinationUnreadable(destination, errno: openErrno)
            }
        }

        // ---- 3. The `.partial` sidecar. O_EXCL so a pre-existing one is
        // noticed rather than silently appended to; a leftover from an
        // interrupted run is then unlinked and re-created from zero.
        let partialPath = destination + partialSuffix
        var dfd = openRetryingEINTR(partialPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        if dfd < 0 && errno == EEXIST {
            unlink(partialPath)
            dfd = openRetryingEINTR(partialPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            if dfd < 0 && errno == EEXIST { throw Failure.partialContended(partialPath) }
        }
        guard dfd >= 0 else { throw Failure.partialCreateFailed(partialPath, errno: errno) }

        var published = false
        defer {
            Darwin.close(dfd)
            // Nothing was published ⇒ leave no residue and, crucially,
            // leave the final name exactly as it was.
            if !published { unlink(partialPath) }
        }

        // ---- 4. Copy the bytes. Cancellation is checked per chunk, so a
        // multi-GB MXF stops within one chunk of the user clicking Cancel
        // (copyItem could not be interrupted at all).
        let written = try copyData(sfd: sfd, dfd: dfd,
                                   sourcePath: source, partialPath: partialPath,
                                   shouldCancel: shouldCancel, progress: progress)

        // ---- 5. Did the source hold still? Re-sampled on the SAME fd.
        var afterStat = stat()
        guard fstat(sfd, &afterStat) == 0,
              afterStat.st_size == sourceStat.st_size,
              afterStat.st_mtimespec.tv_sec == sourceStat.st_mtimespec.tv_sec,
              afterStat.st_mtimespec.tv_nsec == sourceStat.st_mtimespec.tv_nsec,
              written == sourceSize else {
            throw Failure.sourceChangedDuringCopy(source)
        }

        // ---- 6. Metadata (extended attributes — where a resource fork
        // lives — then ACLs, then mode/mtime). copyItem preserved these,
        // so a hand-rolled loop that dropped them would be a silent
        // regression on 1990s QuickTime files and would stamp every
        // rescued file with today's date, which the catalog reads as the
        // media's date.
        //
        // Three separate best-effort calls rather than one
        // COPYFILE_METADATA so that a destination filesystem which can't
        // hold an ACL doesn't also cost us the mtime. Failures are
        // ignored by design: metadata must never cost us the DATA.
        // COPYFILE_STAT is last so the mtime it sets is the final word.
        _ = fcopyfile(sfd, dfd, nil, copyfile_flags_t(COPYFILE_XATTR))
        _ = fcopyfile(sfd, dfd, nil, copyfile_flags_t(COPYFILE_ACL))
        _ = fcopyfile(sfd, dfd, nil, copyfile_flags_t(COPYFILE_STAT))

        // ---- 7. Bytes durable before the name exists.
        guard hooks.fsync(dfd) == 0 else {
            throw Failure.durabilityBarrierFailed("fsync on \(partialPath)", errno: errno)
        }

        // ---- 8. Publish atomically. Fresh destination ⇒ RENAME_EXCL, so
        // we never clobber something that appeared behind our back.
        // Replacing a known-incomplete file ⇒ plain rename, which is the
        // atomic swap that makes the repair safe.
        if previousSize == nil {
            guard renamex_np(partialPath, destination, UInt32(RENAME_EXCL)) == 0 else {
                let renameErrno = errno
                if renameErrno == EEXIST { throw Failure.destinationAppearedDuringCopy(destination) }
                throw Failure.renameFailed(destination, errno: renameErrno)
            }
        } else {
            guard rename(partialPath, destination) == 0 else {
                throw Failure.renameFailed(destination, errno: errno)
            }
        }
        published = true

        // ---- 9. Make the NAME durable too. Unlike ArchivePromoteEngine,
        // a failure here does NOT withdraw the file: the bytes are in
        // place and correct, and this mode issues no durability
        // attestation that a crash could falsify. Deleting a good rescue
        // copy because of a directory-fsync error would be the worse
        // outcome on a drive we are racing to empty.
        let parent = (destination as NSString).deletingLastPathComponent
        let pfd = openRetryingEINTR(parent, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if pfd >= 0 {
            _ = hooks.fsync(pfd)
            Darwin.close(pfd)
        }

        if let previousSize {
            return .recopiedIncomplete(bytesWritten: written, previousSize: previousSize)
        }
        return .copied(bytesWritten: written)
    }

    // MARK: - Internals

    /// The read/write loop. Returns bytes ACTUALLY written (sum of the
    /// return values of write(2)), which is the only number this file is
    /// willing to report.
    private static func copyData(sfd: Int32, dfd: Int32,
                                 sourcePath: String, partialPath: String,
                                 shouldCancel: () -> Bool,
                                 progress: (Int64) -> Void) throws -> Int64 {
        guard lseek(sfd, 0, SEEK_SET) == 0 else {
            throw Failure.sourceReadFailed(sourcePath, errno: errno)
        }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 4096)
        defer { buf.deallocate() }

        var written: Int64 = 0
        while true {
            if shouldCancel() { throw Failure.cancelled }

            var n = 0
            repeat {
                n = read(sfd, buf, chunkSize)
            } while n < 0 && errno == EINTR
            if n < 0 { throw Failure.sourceReadFailed(sourcePath, errno: errno) }
            if n == 0 { break }

            try writeAll(dfd, buf, n, path: partialPath)
            written += Int64(n)

            let injected = hooks.afterChunk(written)
            if injected != 0 { throw Failure.writeFailed(partialPath, errno: injected) }

            progress(written)
        }
        return written
    }

    /// write(2) does not promise to take the whole buffer. Loop until it
    /// has, retrying EINTR. (The classic C write-all; Foundation's
    /// `FileHandle.write` hides this and throws the count away.)
    private static func writeAll(_ fd: Int32, _ buf: UnsafeMutableRawPointer, _ count: Int, path: String) throws {
        var offset = 0
        while offset < count {
            let n = write(fd, buf.advanced(by: offset), count - offset)
            if n < 0 {
                if errno == EINTR { continue }
                throw Failure.writeFailed(path, errno: errno)
            }
            if n == 0 { throw Failure.writeFailed(path, errno: EIO) }
            offset += n
        }
    }

    private static func openRetryingEINTR(_ path: String, _ flags: Int32, _ mode: mode_t = 0) -> Int32 {
        var fd: Int32 = -1
        repeat {
            fd = Darwin.open(path, flags, mode)
        } while fd < 0 && errno == EINTR
        return fd
    }
}
