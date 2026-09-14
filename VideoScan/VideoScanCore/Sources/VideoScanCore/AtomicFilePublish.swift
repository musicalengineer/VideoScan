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
/// app-specific about it), four threads or fewer onto ONE destination:
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
/// - Important: Do not reintroduce `replaceItemAt` anywhere in this project.
///   `AtomicFilePublishSensorTests` fails if it reappears.
public enum AtomicFilePublish {

    // MARK: - Errors

    public struct Failure: Error, CustomStringConvertible {
        public let source: URL
        public let destination: URL
        public let errnoValue: Int32
        public var description: String {
            "rename(\(source.path) -> \(destination.path)) failed: "
            + String(cString: strerror(errnoValue)) + " (errno \(errnoValue))"
        }
    }

    // MARK: - In-flight tracking (hang forensics)

    /// A publish that has started and not yet finished.
    public struct InFlight: Sendable {
        public let destination: String
        public let byteCount: Int
        public let startedAt: Date
        public var age: TimeInterval { -startedAt.timeIntervalSinceNow }
    }

    /// Registry of publishes currently inside `rename(2)` or the temp write.
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
        /// Publishes older than this are reported as probably wedged.
        private let stallThreshold: TimeInterval = 3.0

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

        /// One timer for the whole process, armed on the first publish and
        /// left running. It fires rarely and does nothing when idle.
        private func startWatchdog() {
            lock.lock()
            guard watchdog == nil else { lock.unlock(); return }
            let timer = DispatchSource.makeTimerSource(
                queue: DispatchQueue(label: "Rick-Breen.VideoScan.atomic-publish.watchdog",
                                     qos: .utility))
            watchdog = timer
            lock.unlock()

            timer.schedule(deadline: .now() + 2.0, repeating: 2.0, leeway: .seconds(1))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                for entry in self.snapshot() where entry.age > self.stallThreshold {
                    publishLog.error("""
                        atomic publish STALLED \(String(format: "%.1f", entry.age), privacy: .public)s \
                        — \(entry.destination, privacy: .public) (\(entry.byteCount, privacy: .public) bytes). \
                        If this never clears the thread is wedged in the kernel; \
                        see docs/incident_2026_09_14_sandbox_rename_wedge.md
                        """)
                }
            }
            timer.resume()
        }
    }

    private static let registry = Registry()

    /// Publishes that have started and not finished, oldest first.
    ///
    /// Worth logging on the app's termination path: a non-empty result at exit
    /// is the signature of the 2026-09-14 wedge.
    public static func inFlight() -> [InFlight] { registry.snapshot() }

    /// One line describing anything still in flight, or `nil` when idle.
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
    /// Creates the destination's directory if needed, writes to a **uniquely
    /// named** temp file beside it, then publishes with `rename(2)`. A reader
    /// sees either the whole previous file or the whole new one, never a
    /// partial write, and two concurrent publishes to one `url` are safe —
    /// last writer wins, neither fails, neither wedges.
    ///
    /// The temp is removed on any failure, so a failed save leaves no litter.
    ///
    /// - Note: The temp write is deliberately NOT `.atomic`. The temp name is
    ///   already unique, so `.atomic` would only add a second redundant
    ///   temp-and-rename underneath this one.
    public static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp")

        let token = registry.begin(destination: url, byteCount: data.count)
        defer { registry.end(token) }
        let started = Date()

        do {
            try data.write(to: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            publishLog.error("""
                atomic publish FAILED writing temp for \(url.lastPathComponent, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            throw error
        }

        do {
            try replaceItem(at: url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            publishLog.error("""
                atomic publish FAILED renaming \(url.lastPathComponent, privacy: .public): \
                \(String(describing: error), privacy: .public)
                """)
            throw error
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

    /// Encode `value` as JSON and publish it at `url` atomically.
    ///
    /// The single entry point every JSON sidecar store in this project should
    /// use, so none of them can drift back into a hand-rolled save.
    public static func writeJSON<T: Encodable>(
        _ value: T, to url: URL, encoder: JSONEncoder = JSONEncoder()
    ) throws {
        try write(try encoder.encode(value), to: url)
    }

    /// Move `source` onto `destination`, replacing whatever is there, as one
    /// atomic step.
    ///
    /// Prefer ``write(_:to:)`` — it owns the temp name and the cleanup too.
    /// This lower-level form is for callers that already hold a fully written
    /// file (a rendered payload, a verified copy) on the **same volume** as
    /// `destination`.
    public static func replaceItem(at destination: URL, withItemAt source: URL) throws {
        if rename(source.path, destination.path) != 0 {
            throw Failure(source: source, destination: destination, errnoValue: errno)
        }
    }
}
