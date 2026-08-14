//
//  CatalogLock.swift
//  VideoScan
//
//  Cross-process ownership lock for catalog.json.
//
//  WHY THIS EXISTS
//  ---------------
//  catalog.json is single-writer, but nothing enforced it. On 2026-08-14 an
//  external maintenance script reduced the catalog from 18,142 to 8,760
//  records; the app was launched during that window, loaded the pre-reduction
//  file into memory, and saved its stale copy back over the reduction a
//  couple of minutes later. The whole operation vanished with no error, no
//  warning, and no torn file — then the app wrote the stale copy AGAIN on
//  quit. Last-writer-wins with no detection.
//
//  TWO DISTINCT FAILURES, TWO DEFENCES
//  -----------------------------------
//  1. CONCURRENT writes  — two writers interleaving. Solved here, by an
//     advisory `flock(2)` held for the owning process's lifetime.
//  2. LOST UPDATES       — writer A loads, writer B writes, writer A writes
//     its stale copy. A lock does NOT solve this: both writes are individually
//     well-formed and correctly serialised. This needs a staleness check
//     (see `CatalogStore` generation/mtime guard). The 8/14 incident was
//     this second kind, which is why the lock alone would not have saved it.
//
//  WHY flock AND NOT A PID FILE
//  ----------------------------
//  `flock` locks are owned by the file descriptor and released by the kernel
//  when the process exits — including on crash, SIGKILL, or force-quit. A
//  PID file left behind by a crashed app blocks every later run until someone
//  deletes it by hand, and "is PID 4711 still my app or is it now someone
//  else's process?" is unanswerable in general. The lock file here carries
//  owner metadata for humans, but the *authority* is always the flock.
//

import Darwin
import Foundation
import os

private let lockLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "CatalogLock")

/// Who currently holds the catalog, for diagnostics and error messages.
/// Advisory only — never trusted for correctness, which rests on `flock`.
struct CatalogLockOwner: Codable, Sendable, Equatable {
    var pid: Int32
    var processName: String
    var hostname: String
    var acquiredAt: Date

    var describedBriefly: String {
        "\(processName) (pid \(pid)) on \(hostname)"
    }
}

/// Result of trying to take the catalog lock.
enum CatalogLockResult: Sendable, Equatable {
    /// We own it. Ownership lasts until `release()` or process exit.
    case acquired
    /// Someone else owns it. `owner` is best-effort — the metadata file may
    /// be absent or stale even though the flock itself is genuinely held.
    case heldByAnother(owner: CatalogLockOwner?)
    /// The lock file could not be opened at all (permissions, missing dir).
    case unavailable(reason: String)
}

/// An advisory, cross-process, auto-releasing lock over catalog.json.
///
/// Intended lifetime is the owning process: acquire at launch, hold until
/// exit. That gives "one writer per catalog" semantics and lets external
/// tooling (maintenance scripts, MFO jobs) detect that the app owns the file
/// and refuse to write rather than clobber it.
final class CatalogLock: @unchecked Sendable {

    /// Sidecar next to catalog.json. Never the catalog itself — the catalog
    /// is replaced by `rename(2)` on every atomic write, which would detach
    /// the lock from the file every writer is racing over.
    let lockURL: URL

    private let queue = DispatchQueue(label: "Rick-Breen.VideoScan.CatalogLock")
    private var fd: Int32 = -1

    init(lockURL: URL) {
        self.lockURL = lockURL
    }

    /// Standard location: catalog.json's directory, `catalog.lock`.
    convenience init(besideCatalogAt catalogURL: URL) {
        self.init(lockURL: catalogURL.deletingLastPathComponent()
                                     .appendingPathComponent("catalog.lock"))
    }

    var isHeldByUs: Bool {
        queue.sync { fd >= 0 }
    }

    /// Try to take exclusive ownership without blocking.
    ///
    /// Non-blocking on purpose: a writer that blocks on the main actor would
    /// beachball for as long as the other process lives, which for an app
    /// holding the lock for its whole session is "forever".
    @discardableResult
    func acquire() -> CatalogLockResult {
        queue.sync {
            if fd >= 0 { return .acquired }   // re-entrant for the same process

            // O_CLOEXEC is essential, not hygiene. This app spawns ffmpeg and
            // ffprobe constantly; without it every child inherits this fd and
            // therefore the flock, so a long-running transcode would keep the
            // catalog locked after the app itself had quit -- reintroducing
            // exactly the stale-lock failure flock is supposed to prevent.
            let opened = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
            guard opened >= 0 else {
                let reason = String(cString: strerror(errno))
                lockLog.error("could not open lock file: \(reason, privacy: .public)")
                return .unavailable(reason: reason)
            }

            if flock(opened, LOCK_EX | LOCK_NB) != 0 {
                let err = errno
                close(opened)
                if err == EWOULDBLOCK {
                    let owner = Self.readOwner(at: lockURL)
                    lockLog.notice("catalog lock held by \(owner?.describedBriefly ?? "another process", privacy: .public)")
                    return .heldByAnother(owner: owner)
                }
                let reason = String(cString: strerror(err))
                lockLog.error("flock failed: \(reason, privacy: .public)")
                return .unavailable(reason: reason)
            }

            fd = opened
            writeOwnerMetadata()
            lockLog.notice("catalog lock acquired by pid \(getpid())")
            return .acquired
        }
    }

    /// Acquire, waiting up to `timeout` for the current owner to finish.
    ///
    /// Polls rather than using a blocking `flock(LOCK_EX)` because a blocking
    /// flock cannot be cancelled or bounded — if the holder is a long-lived
    /// app session, a blocked caller waits forever with no way out. Polling
    /// costs a few syscalls and keeps the timeout honest.
    ///
    /// NOT for the main actor. A waiter on the main thread is a beachball
    /// with extra steps; call this from a background queue.
    func acquire(waitingUpTo timeout: TimeInterval,
                 pollInterval: TimeInterval = 0.25) -> CatalogLockResult {
        let deadline = Date().addingTimeInterval(timeout)
        var last: CatalogLockResult = .heldByAnother(owner: nil)
        while Date() < deadline {
            last = acquire()
            switch last {
            case .acquired, .unavailable:
                return last          // success, or a failure waiting cannot fix
            case .heldByAnother:
                Thread.sleep(forTimeInterval: pollInterval)
            }
        }
        return last
    }

    /// Release ownership. Called on orderly shutdown; the kernel does the
    /// same thing for us if the process dies without getting here.
    func release() {
        queue.sync {
            guard fd >= 0 else { return }
            // Truncate the metadata first so a reader never sees a stale
            // owner for a lock nobody holds.
            ftruncate(fd, 0)
            flock(fd, LOCK_UN)
            close(fd)
            fd = -1
            lockLog.notice("catalog lock released by pid \(getpid())")
        }
    }

    deinit {
        if fd >= 0 {
            flock(fd, LOCK_UN)
            close(fd)
        }
    }

    /// Best-effort read of who holds it. Returns nil when the metadata is
    /// missing or unreadable — which does NOT mean the lock is free.
    static func readOwner(at url: URL) -> CatalogLockOwner? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(CatalogLockOwner.self, from: data)
    }

    // MARK: - Private

    private func writeOwnerMetadata() {
        let owner = CatalogLockOwner(
            pid: getpid(),
            processName: ProcessInfo.processInfo.processName,
            hostname: ProcessInfo.processInfo.hostName,
            acquiredAt: Date()
        )
        guard let data = try? JSONEncoder().encode(owner) else { return }
        ftruncate(fd, 0)
        lseek(fd, 0, SEEK_SET)
        _ = data.withUnsafeBytes { buf in
            write(fd, buf.baseAddress, buf.count)
        }
        fsync(fd)
    }
}
