import Foundation
import os

private let publishLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                category: "atomic-publish")

/// Publishing a file at its final name, atomically, without `RENAME_SWAP`.
///
/// ## Why this type exists
///
/// On APFS `FileManager.replaceItemAt(_:withItemAt:)` is implemented with
/// `renameatx_np(… RENAME_SWAP)`. `Sandbox.kext` hooks that syscall in
/// `hook_vnode_notify_will_rename_swap`, where it takes an `IORWLock`
/// **exclusively and keeps holding it** for the duration of the VFS rename.
/// The holding thread then sleeps in `vfs_subr.c` waiting on a vnode whose
/// iocount belongs to a second thread — which is itself parked in the same
/// hook waiting for that rwlock. ABBA deadlock, inside the kernel.
///
/// The consequences are not recoverable from user space: the threads never
/// return, so the process becomes an unkillable `?E` zombie (`kill -9` cannot
/// touch a thread blocked in the kernel), and only a reboot clears it. This
/// cost Rick a live demo on 2026-09-14.
///
/// Measured that day (M1, macOS 26.6.2, plain unsandboxed Python — nothing
/// app-specific about it), onto ONE destination:
///
/// | workload                                        | result              |
/// |-------------------------------------------------|---------------------|
/// | 2 threads, `RENAME_SWAP`, **same** path pair     | wedged after 26 ops |
/// | 8 threads, `RENAME_SWAP`, disjoint pairs, 1 dir  | 40,000 ops, 4.9 s   |
/// | 8 threads, `rename(2)`, **same** destination     | 32,000 ops, 12.7 s  |
/// | `Data.write(options: .atomic)`, same destination | 12,000 ops, 2.0 s   |
///
/// So the trigger is precisely *two concurrent rename-swaps touching one
/// destination* — which is exactly what an "atomic save" store does when two
/// saves race (an apply and its immediate undo, say). Plain `rename(2)` is
/// just as atomic on APFS, takes a different Sandbox hook, and is immune.
///
/// ## Why the whole publish lives here, not just the rename
///
/// The first pass at this fix wrapped only the rename and left each store to
/// hand-roll the rest. Seven call sites then carried five different
/// conventions, and **two of them used a fixed temp name** — so two concurrent
/// saves stomped each other's temp and could publish a torn file. That class
/// of bug is what a copy-pasted pattern produces. One entry point that owns
/// the temp name, the write, the publish, the cleanup and the logging cannot
/// drift that way.
///
/// Full evidence, both spindumps, the symbolicated kernel stacks and every
/// harness: `docs/incident_2026_09_14_sandbox_rename_wedge.md`.
///
/// - Important: Do not reintroduce `FileManager.replaceItemAt` — or its other
///   spelling, `FileManager.replaceItem(at:withItemAt:backupItemName:options:
///   resultingItemURL:)` — anywhere in this project. Both are `RENAME_SWAP`.
///   `AtomicFilePublishSensorTests` fails if either reappears.
public enum AtomicFilePublish {

    // MARK: - Errors

    public struct Failure: LocalizedError, CustomStringConvertible {
        public let operation: String
        public let path: String
        public let errnoValue: Int32

        public var description: String {
            "\(operation) failed for \(path): "
            + String(cString: strerror(errnoValue)) + " (errno \(errnoValue))"
        }
        /// Without this, `localizedDescription` bridges to the useless
        /// "The operation couldn't be completed. (… error 1.)" and the errno
        /// this type went to the trouble of capturing never reaches the user.
        public var errorDescription: String? { description }
    }

    // MARK: - Durability

    public enum Durability: Sendable {
        /// Write, then `rename(2)`. Atomic for any live reader — nobody ever
        /// sees a partial file. Does NOT survive a power loss or a hard
        /// reboot: APFS may surface the rename ahead of the data.
        case fast
        /// `F_FULLFSYNC` the payload before publishing it, and fsync the
        /// parent directory after, so the file survives a forced reboot.
        /// Costs a real device round-trip; worth it for a sidecar you would
        /// hate to lose, wrong for a regenerable preview.
        case fullFsync
    }

    // MARK: - The temp-file contract

    /// Suffix every in-flight publish temp carries.
    ///
    /// Exposed deliberately: a crashed or kernel-wedged process leaves these
    /// behind, so anything that sweeps a directory this type publishes into
    /// needs to recognise them. `PreviewDiskCache.pruneNow` does.
    public static let temporarySuffix = ".vspublish.tmp"

    /// Is `name` a temp left behind by an interrupted publish?
    public static func isTemporaryPublishArtifact(_ name: String) -> Bool {
        name.hasSuffix(temporarySuffix)
    }

    private static func temporaryURL(beside destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString)\(temporarySuffix)")
    }

    // MARK: - In-flight tracking (hang forensics)

    /// A publish that has started and not yet finished.
    public struct InFlight: Sendable {
        public let destination: String
        public let byteCount: Int
        public let startedAt: Date
        public var age: TimeInterval { -startedAt.timeIntervalSinceNow }
    }

    /// Registry of publishes currently in progress.
    ///
    /// If the kernel ever wedges us again the stack is unreachable and the
    /// process cannot be killed — but *another* thread can still read this and
    /// write to the log. That is the difference between "it hung" and "it hung
    /// publishing this exact file", which is what cost us two days in
    /// September 2026.
    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [UInt64: InFlight] = [:]
        private var nextToken: UInt64 = 0
        private var watchdog: DispatchSourceTimer?
        /// Deliberately generous. A slow spinning USB volume can legitimately
        /// take seconds; we only want to hear about something pathological.
        private let stallThreshold: TimeInterval = 10.0

        func begin(destination: URL, byteCount: Int) -> UInt64 {
            lock.lock()
            nextToken &+= 1
            let token = nextToken
            entries[token] = InFlight(destination: destination.path,
                                      byteCount: byteCount,
                                      startedAt: Date())
            let needsWatchdog = watchdog == nil
            lock.unlock()
            if needsWatchdog { startWatchdog() }
            return token
        }

        func end(_ token: UInt64) {
            lock.lock()
            entries.removeValue(forKey: token)
            lock.unlock()
        }

        func snapshot() -> [InFlight] {
            lock.lock(); defer { lock.unlock() }
            return entries.values.sorted { $0.startedAt < $1.startedAt }
        }

        /// One timer for the whole process, armed on the first publish.
        ///
        /// Created under the lock behind a second `guard`: two threads can both
        /// see `needsWatchdog`, but only one may ever construct a
        /// `DispatchSourceTimer`. Dropping an unresumed one aborts the process
        /// ("release of a suspended object").
        private func startWatchdog() {
            lock.lock()
            guard watchdog == nil else { lock.unlock(); return }
            let timer = DispatchSource.makeTimerSource(
                queue: DispatchQueue(label: "Rick-Breen.VideoScan.atomic-publish.watchdog",
                                     qos: .utility))
            watchdog = timer
            lock.unlock()

            // Coarse, with a full second of leeway: this is a rare-event
            // watchdog, not a clock. It must not become a wakeup source that
            // costs battery on the MacBook Pro for nothing.
            timer.schedule(deadline: .now() + 5.0, repeating: 5.0, leeway: .seconds(2))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                // snapshot() releases the lock before we log.
                for entry in self.snapshot() where entry.age > self.stallThreshold {
                    publishLog.error("""
                        atomic publish has not completed in \
                        \(String(format: "%.0f", entry.age), privacy: .public)s — \
                        \(entry.destination, privacy: .public) \
                        (\(entry.byteCount, privacy: .public) bytes). If it never \
                        completes, see docs/incident_2026_09_14_sandbox_rename_wedge.md
                        """)
                }
            }
            timer.resume()
        }
    }

    private static let registry = Registry()

    /// Publishes that have started and not finished, oldest first.
    public static func inFlight() -> [InFlight] { registry.snapshot() }

    /// One line describing anything still in flight, or `nil` when idle.
    ///
    /// Logged on the app's termination path — a non-empty result at exit is
    /// the signature of the 2026-09-14 wedge.
    public static func inFlightSummary() -> String? {
        let entries = inFlight()
        guard !entries.isEmpty else { return nil }
        return entries
            .map { "\($0.destination) (\(String(format: "%.1f", $0.age))s)" }
            .joined(separator: ", ")
    }

    // MARK: - The publish

    /// Write `data` to `url` atomically.
    ///
    /// Writes to a **uniquely named** temp beside the destination, then
    /// publishes with `rename(2)`. A reader sees either the whole previous
    /// file or the whole new one, never a partial write, and two concurrent
    /// publishes to one `url` are safe — last writer wins, neither fails,
    /// neither wedges.
    ///
    /// The temp is removed on any failure, so a failed save leaves no litter.
    /// A temp that survives a crash is swept by whoever owns the directory;
    /// see ``isTemporaryPublishArtifact(_:)``.
    ///
    /// - Parameters:
    ///   - durability: `.fullFsync` to survive a forced reboot. Default
    ///     `.fast`, which is atomic for live readers only.
    ///   - createIntermediates: create the destination's directory if missing.
    ///     Pass `false` where a deliberately removed directory must stay
    ///     removed rather than silently reappear.
    ///
    /// - Note: The temp write is deliberately NOT `.atomic`. The temp name is
    ///   already unique, so `.atomic` would only add a second redundant
    ///   temp-and-rename underneath this one.
    public static func write(
        _ data: Data,
        to url: URL,
        durability: Durability = .fast,
        createIntermediates: Bool = true
    ) throws {
        // begin() FIRST: createDirectory on a stalled network or offline
        // volume is itself a plausible hang site, and a hang the forensics
        // cannot see is the thing this registry exists to prevent.
        let token = registry.begin(destination: url, byteCount: data.count)
        defer { registry.end(token) }
        let started = Date()

        if createIntermediates {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let tmp = temporaryURL(beside: url)

        do {
            switch durability {
            case .fast:       try data.write(to: tmp)
            case .fullFsync:  try writeAndSync(data, to: tmp)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            publishLog.error("""
                atomic publish FAILED writing temp for \(url.lastPathComponent, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            throw error
        }

        do {
            try publish(tmp, as: url)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            publishLog.error("""
                atomic publish FAILED renaming \(url.lastPathComponent, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            throw error
        }

        if durability == .fullFsync {
            // The directory entry itself must reach stable storage too, or a
            // reboot can lose the rename that a synced payload was published by.
            syncDirectory(url.deletingLastPathComponent())
        }

        let elapsed = -started.timeIntervalSinceNow
        if elapsed > 1.0 {
            publishLog.notice("""
                atomic publish SLOW \(String(format: "%.2f", elapsed), privacy: .public)s \
                — \(url.lastPathComponent, privacy: .public) (\(data.count, privacy: .public) bytes)
                """)
        } else {
            publishLog.debug("""
                atomic publish ok \(url.lastPathComponent, privacy: .public) \
                (\(data.count, privacy: .public) bytes) in \
                \(String(format: "%.0f", elapsed * 1000), privacy: .public)ms
                """)
        }
    }

    /// Rename `source` onto `destination`, replacing whatever is there, as one
    /// atomic step.
    ///
    /// Prefer ``write(_:to:durability:createIntermediates:)`` — it owns the
    /// temp name and the cleanup too. This lower-level form is for callers
    /// that already hold a fully written file (a rendered payload, a verified
    /// copy) on the **same volume** as `destination`.
    ///
    /// - Note: Named `publish`, not `replaceItem`, on purpose.
    ///   `FileManager.replaceItem(at:withItemAt:…)` falls back to a copy across
    ///   volumes; this returns `EXDEV`. Borrowing the name would promise
    ///   semantics it does not deliver — and would collide textually with the
    ///   very API the sensors ban.
    public static func publish(_ source: URL, as destination: URL) throws {
        try adoptExistingMode(of: destination, onto: source)
        if Darwin.rename(source.path, destination.path) != 0 {
            throw Failure(operation: "rename", path: destination.path, errnoValue: errno)
        }
    }

    /// Give `source` the permissions the file it is about to replace already
    /// had, so publishing never widens them.
    ///
    /// WHY THIS EXISTS (codex review 2026-09-15, runtime-confirmed). The API
    /// this type replaced, `FileManager.replaceItemAt`, preserves the
    /// destination's attributes — that is documented behaviour in
    /// `NSFileManager.h`. We publish a FRESH inode created with `0o644 & ~umask`
    /// and rename it over the top, so the destination's mode was silently
    /// discarded. Reproduced: a `0600` destination, umask `022`, one
    /// `write(_:to:durability:.fullFsync)` — the file came back **`0644`**.
    /// Nobody lost data and no restricted sidecar is known to exist today, but
    /// an atomic-save helper must not be a privilege-widening primitive.
    ///
    /// Done HERE, in the one place every publish funnels through, rather than
    /// at each call site — the whole point of the wrapper.
    ///
    /// DELIBERATE SCOPE. Mode only. Owner/group cannot be restored without
    /// privilege, and `rename(2)` keeps the temp's — which is us, the same
    /// user who owned the destination in every path this app has. ACLs and
    /// extended attributes are NOT carried over: this app sets neither, and
    /// `copyfile(3)` with `COPYFILE_METADATA` would also drag the old mtime
    /// onto a file whose whole purpose is to be new. If we ever publish over
    /// files that carry ACLs, this is the function to revisit.
    ///
    /// A NEW file keeps the process umask — correct, there is no prior
    /// intent to honour — so an absent or unreadable destination is not an
    /// error. A FAILED chmod is: it runs BEFORE the rename, so throwing has
    /// published nothing and the caller's existing cleanup removes the temp.
    /// Failing loudly beats quietly widening permissions.
    private static func adoptExistingMode(of destination: URL, onto source: URL) throws {
        // `Darwin.stat` is ambiguous in Swift — the struct and the function
        // share the name, and the type wins. FileManager reads the same
        // `st_mode & 0o7777` without the dance.
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: destination.path),
              let mode = (attrs[.posixPermissions] as? NSNumber)?.uint16Value
        else { return }                            // absent/unreadable: umask decides
        let current = (try? fm.attributesOfItem(atPath: source.path))
            .flatMap { ($0[.posixPermissions] as? NSNumber)?.uint16Value }
        if current == mode { return }
        guard Darwin.chmod(source.path, mode_t(mode)) == 0 else {
            throw Failure(operation: "chmod (preserving \(String(mode, radix: 8)))",
                          path: source.path, errnoValue: errno)
        }
    }

    // MARK: - Durable write helpers

    private static func writeAndSync(_ data: Data, to url: URL) throws {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else {
            throw Failure(operation: "open", path: url.path, errnoValue: errno)
        }
        defer { Darwin.close(fd) }

        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw Failure(operation: "write", path: url.path, errnoValue: errno)
                }
                offset += n
            }
        }
        // F_FULLFSYNC, not fsync(2): on macOS only this asks the drive to
        // flush its own write cache.
        guard fcntl(fd, F_FULLFSYNC) != -1 else {
            throw Failure(operation: "F_FULLFSYNC", path: url.path, errnoValue: errno)
        }
    }

    /// Best-effort — a failure here costs durability, not correctness, and
    /// must never fail a save that already landed.
    private static func syncDirectory(_ url: URL) {
        let fd = Darwin.open(url.path, O_RDONLY)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        _ = fcntl(fd, F_FULLFSYNC)
    }
}
