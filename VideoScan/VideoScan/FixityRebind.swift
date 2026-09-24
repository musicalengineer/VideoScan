// FixityRebind.swift
// One full re-read that binds a record's whole-file digest to a stamp that
// carries the volume's persistent UUID (2026-09-23; codex #1707). The
// engine of the "Bind Fixity to Volume" job (BindFixityToVolumeJob).
//
// Why a READ and not a stat: a pre-UUID stamp records no proof of which
// volume produced its digest (st_dev is per-mount and reused across disks),
// so today's UUID plus a matching inode/size/mtime/ctime cannot prove the
// old digest describes these bytes. Only hashing the bytes again can
// (ContentFixity.swift header).
//
// Per file, everything through ONE opened descriptor:
//   interrupted? → return before any I/O (codex #1721)
//   open(path, O_NONBLOCK) → fstat: regular file only (a FIFO/device
//                is refused, never waited on), then blocking reads
//              → before = fstat + fgetattrlist(ATTR_VOL_UUID) on the fd,
//                and stat(path) must still name the same device+inode
//   SHA-256 of every byte through that fd (ArchivePromoteEngine.sha256 —
//                the app's one hasher), counting the bytes
//   after  = the same capture again; after == before EXACTLY (device,
//                inode, size, mtime ns, ctime ns, volume UUID), and the
//                bytes hashed == size
//   → a new ContentFixity(stamp: after). Anything else refuses: nothing
//     is written, the old fixity stays as it was (untrusted).
// A remount/eject during the read makes the fd calls fail or the UUID
// change → refused. A retargeted symlink / renamed-over path fails the
// stat(path) check → refused.
//
// Read-only on media. The catalog write is the job's, on the main actor,
// compare-and-set (VideoScanModel.applyFixityRebind).
//
// (For Rick: `Control` is a tiny mutex-guarded flag block shared between
// the main-actor job and the hashing thread — ≈ a struct of
// std::atomic<bool>s. The hasher polls it once per 1 MB chunk.)

import Darwin
import Foundation
import VideoScanCore
import os

enum FixityRebind {

    /// Flags the job sets and the hashing thread polls.
    final class Control: @unchecked Sendable {
        private let lock = NSLock()
        private var stop = false
        private var paused = false
        private var bytes: Int64 = 0

        var isStopped: Bool { lock.withLock { stop } }
        var isPaused: Bool { lock.withLock { paused } }
        /// Bytes hashed so far in the CURRENT file (for the progress bar).
        var bytesRead: Int64 { lock.withLock { bytes } }
        func requestStop() { lock.withLock { stop = true } }
        func setPaused(_ p: Bool) { lock.withLock { paused = p } }
        func resetBytes() { lock.withLock { bytes = 0 } }
        func noteBytes(_ n: Int64) { lock.withLock { bytes = n } }
        /// Pause ALSO interrupts the current file (its slot on the disk is
        /// given back; the file restarts from byte 0 on resume).
        var shouldInterrupt: Bool { lock.withLock { stop || paused } }
    }

    enum Outcome: Equatable, Sendable {
        /// Read in full, identity held: the new fixity to store.
        case bound(ContentFixity)
        /// Stopped or paused mid-read — nothing learned, retry later.
        case interrupted
        /// The file is not there (ENOENT) — or its volume is away.
        case offline
        /// Cannot be opened or read (permissions, I/O error).
        case unreadable(String)
        /// The volume reports no persistent UUID — cannot be bound.
        case noVolumeIdentity
        /// Identity changed between the before and after captures (a
        /// write, a replace, a retarget, a remount) — refused.
        case changedDuringRead(String)
    }

    /// Re-read `path` in full and bind the digest (see the header). Blocking
    /// I/O — call it off the main actor.
    static func rehash(path: String, control: Control) -> Outcome {
        control.resetBytes()
        // codex #1721 P2-1: a stopped/paused job does no I/O at all.
        guard !control.shouldInterrupt else { return .interrupted }
        // O_NONBLOCK: a FIFO (or device) put where a media file was must
        // never block open(2) waiting for a writer — it would hold the
        // volume gate with no cancellation point. A path pre-check would
        // be racy; the type is checked on the OPENED descriptor below.
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            let e = errno
            return e == ENOENT ? .offline : .unreadable("open: \(String(cString: strerror(e)))")
        }
        defer { close(fd) }
        var kind = stat()
        guard fstat(fd, &kind) == 0 else { return .unreadable("fstat: \(String(cString: strerror(errno)))") }
        guard (kind.st_mode & S_IFMT) == S_IFREG else { return .unreadable("not a regular file") }
        // A regular file: ordinary blocking reads from here on.
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }
        guard !control.shouldInterrupt else { return .interrupted }
        guard let before = FileIdentityStamp.capture(fd: fd, path: path) else {
            return .changedDuringRead("the path no longer names the opened file")
        }
        guard before.isBoundToVolume else { return .noVolumeIdentity }
        var seen: Int64 = 0
        let digest: String?
        do {
            digest = try ArchivePromoteEngine.sha256(fd: fd, shouldCancel: { control.shouldInterrupt },
                                                     progress: { n in seen = n; control.noteBytes(n) })
        } catch {
            return .unreadable("read: \(error)")
        }
        guard let digest else { return .interrupted }
        guard let after = FileIdentityStamp.capture(fd: fd, path: path) else {
            return .changedDuringRead("the path no longer names the file that was read")
        }
        guard after == before else {
            return .changedDuringRead(Self.difference(before, after))
        }
        guard seen == after.size else {
            return .changedDuringRead("read \(seen) bytes, the file has \(after.size)")
        }
        return .bound(ContentFixity(digest: digest, byteCount: after.size, stamp: after))
    }

    /// Which identity field moved — for the log line.
    static func difference(_ a: FileIdentityStamp, _ b: FileIdentityStamp) -> String {
        var parts: [String] = []
        if a.volumeUUID != b.volumeUUID { parts.append("volume") }
        if a.device != b.device { parts.append("device") }
        if a.inode != b.inode { parts.append("inode") }
        if a.size != b.size { parts.append("size") }
        if a.mtimeNs != b.mtimeNs { parts.append("mtime") }
        if a.ctimeNs != b.ctimeNs { parts.append("ctime") }
        return "changed during the read (" + parts.joined(separator: ", ") + ")"
    }
}

// MARK: - Catalog side (main actor)

/// One record whose fixity is not bound to a volume — a value, so it can
/// cross to the hashing hop.
struct FixityRebindItem: Sendable, Equatable {
    let id: UUID
    let path: String
    /// The fixity as it was when the plan was made (compare-and-set key).
    let fixity: ContentFixity
    var bytes: Int64 { fixity.byteCount }
}

extension VideoScanModel {

    /// Records under `prefix` whose stored fixity has no volume UUID
    /// (pre-2026-09-23 stamps, or pre-ctime ones) — the work of one run.
    /// O(records), main actor, never in a view body. Path-sorted so a run
    /// walks the disk roughly in directory order.
    func fixityRebindCandidates(prefix: String) -> [FixityRebindItem] {
        var out: [FixityRebindItem] = []
        for r in records {
            guard let f = r.contentFixity, !f.stamp.isBoundToVolume,
                  PathScope.contains(r.fullPath, within: prefix) else { continue }
            out.append(FixityRebindItem(id: r.id, path: r.fullPath, fixity: f))
        }
        return out.sorted { $0.path < $1.path }
    }

    enum FixityRebindWrite: Equatable { case written, digestChanged, recordChanged }

    /// Store a freshly bound fixity — compare-and-set: the same record, at
    /// the same path, still holding exactly the fixity the plan saw. A
    /// record rescanned, moved or re-verified meanwhile is left alone.
    func applyFixityRebind(_ item: FixityRebindItem, fixity: ContentFixity) -> FixityRebindWrite {
        guard !isReadOnly, let rec = record(forID: item.id), rec.fullPath == item.path,
              rec.contentFixity == item.fixity else { return .recordChanged }
        rec.contentFixity = fixity
        return fixity.digest == item.fixity.digest ? .written : .digestChanged
    }
}
