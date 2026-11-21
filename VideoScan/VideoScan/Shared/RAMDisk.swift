import Foundation
import os
import VideoScanCore

/// This file runs on the QUIT path (VideoScanApp.applicationWillTerminate),
/// synchronously, AFTER "app quitting" is written — and until 2026-09-14 it
/// contained no logging at all. Both `contentsOfDirectory(/Volumes)` and
/// `hdiutil detach -force` can block on an unresponsive mount, which
/// reproduces the 2026-09-13 wedge signature exactly: "app quitting", then
/// silence, forever. Rick's rule, 2026-09-14: log that you are ENTERING an
/// operation that can block, not only that it finished.
///
/// 2026-11-21: every command here goes through ProcessRunner (they were four
/// hand-rolled `Process()` sites with `waitUntilExit()` and no deadline), so
///   • each has a deadline (SIGTERM → SIGKILL → abandon): a wedged hdiutil or
///     diskutil is a named failure, not a hang;
///   • a ScriptedExecutor answers them in RAMDiskNegativeMatrixTests;
///   • the two DESTRUCTIVE commands — `diskutil eraseVolume` and
///     `hdiutil detach -force` on a device node — take an `OwnedDevice`,
///     which can only be made from the output of this actor's own
///     `hdiutil attach -nomount ram://N`. Before, whatever hdiutil printed
///     was handed to `diskutil eraseVolume`, which also accepts a mount
///     point or a volume name.
private let ramDiskLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                category: "ramdisk")

/// Manages a macOS RAM disk for high-speed temp I/O.
/// Uses hdiutil to create an in-memory disk image — pure RAM, no SSD wear, no latency.
///
/// Memory: the RAM disk itself is the caller's `sizeMB`. This type holds
/// two short strings; each command's collected output is capped at 4 KB
/// stdout / 16 KB stderr.
actor RAMDisk {

    /// A device node this process's own `hdiutil attach -nomount ram://N`
    /// just printed — the ONLY thing `eraseVolume` and a device `detach` are
    /// ever given. There is no other way to make one.
    /// (C++: a strong typedef with a private constructor and one factory;
    /// a function taking `OwnedDevice` cannot be handed a stray string.)
    struct OwnedDevice: Sendable, Equatable {
        let node: String

        /// nil unless the WHOLE of what attach printed is exactly one
        /// whole-disk node `/dev/diskN` (N ≥ 1) plus whitespace. Refused:
        /// empty output, two lines, a slice (`/dev/disk4s1`), a mount
        /// point, a volume name, text around the node, and `/dev/disk0`
        /// (always the internal boot disk — a RAM device can never be
        /// given that number).
        ///
        /// `collectionCap` is the `stdoutLimitBytes` the output was
        /// collected under. A copy that REACHED the cap may be a truncated
        /// prefix of something longer — "/dev/disk5", padding up to the
        /// cap, then a second node the runner dropped — so it is not the
        /// whole output and is refused (Codex r1 P1, 2026-11-21).
        init?(attachOutput: String, collectionCap: Int) {
            guard attachOutput.utf8.count < collectionCap else { return nil }
            let text = attachOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = "/dev/disk"
            guard text.hasPrefix(prefix) else { return nil }
            let digits = text.dropFirst(prefix.count)
            guard (1...6).contains(digits.count),
                  digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                  digits.first != "0" else { return nil }
            node = text
        }
    }

    /// Per-command deadlines. Production values are generous (a 16 GB RAM
    /// device formats in a second or two); a test passes short ones.
    struct Timeouts: Sendable {
        var attachSeconds: Double = 60
        var eraseSeconds: Double = 120
        var detachSeconds: Double = 30
        var killGraceSeconds: Double = ProcessRunner.defaultKillGraceSeconds
    }

    static let volumeName = "VideoScan_Temp"
    /// The cap attach's stdout is collected under (hdiutil prints ~40
    /// bytes). `OwnedDevice` refuses output that reaches it.
    static let attachOutputCap = 4096
    static let hdiutil = "/usr/bin/hdiutil"
    static let diskutil = "/usr/sbin/diskutil"

    private(set) var mountPoint: String?
    private var device: OwnedDevice?
    private let timeouts: Timeouts
    /// Ref count of active users (concurrent scans). Only the last unmount()
    /// actually ejects — prevents one scan's completion from yanking the disk
    /// out from under a still-running parallel scan, which was causing every
    /// subsequent network probe to fall back to direct reads and hit the 60s
    /// timeout. See VideoScan issue #33 thread / overnight 2026-04-21.
    private var refCount: Int = 0

    init(timeouts: Timeouts = Timeouts()) {
        self.timeouts = timeouts
    }

    /// Mount a RAM disk of the given size. Returns true on success.
    /// Idempotent across callers — if already mounted, just bumps the refcount.
    func mount(sizeMB: Int) async -> Bool {
        if mountPoint != nil {
            refCount += 1
            return true
        }

        let sectors = sizeMB * 2048  // 512-byte sectors
        let timeouts = self.timeouts

        // Detached, as it always was: a caller's cancellation must not kill
        // hdiutil/diskutil half way and then skip the detach (a cancelled
        // task's next command is never launched) — that would leak the RAM
        // device. `detachedKeepingExecutor` is Task.detached that keeps a
        // test's mock; the deadlines bound it instead.
        let made = await ProcessRunner.detachedKeepingExecutor(priority: .userInitiated) {
            await Self.attachAndFormat(sectors: sectors, timeouts: timeouts)
        }.value

        guard let made else { return false }
        device = made
        mountPoint = "/Volumes/\(Self.volumeName)"
        refCount = 1
        return true
    }

    /// Attach a RAM device and format it. nil — with the reason logged and
    /// nothing left behind that this call made — on any failure.
    /// Order: every refusal happens BEFORE the erase.
    private static func attachAndFormat(sectors: Int, timeouts: Timeouts) async -> OwnedDevice? {
        // Step 1: create the RAM device.
        let attach = await ProcessRunner.runProcess(
            executable: hdiutil, arguments: ["attach", "-nomount", "ram://\(sectors)"],
            stdoutLimitBytes: attachOutputCap, stderrLimitBytes: 16 * 1024,
            deadlineSeconds: timeouts.attachSeconds, killGraceSeconds: timeouts.killGraceSeconds)
        guard attach.launched, attach.exitCode == 0 else {
            note("ram disk: hdiutil attach failed (\(describe(attach))) — no RAM disk; nothing erased, nothing detached")
            return nil
        }
        guard let owned = OwnedDevice(attachOutput: attach.stdout ?? "", collectionCap: attachOutputCap) else {
            // Refuse rather than guess: `diskutil eraseVolume` accepts a
            // mount point or a volume name as its device argument.
            note("ram disk: REFUSED — hdiutil attach exited 0 but printed \((attach.stdout ?? "").utf8.count) byte(s) "
                 + "\(String((attach.stdout ?? "").prefix(200)).debugDescription), not exactly one /dev/diskN; nothing erased, nothing detached (a RAM device it made, if any, is left for the quit sweep)")
            return nil
        }

        // Step 2: format it as APFS.
        let erase = await ProcessRunner.runProcess(
            executable: diskutil, arguments: ["eraseVolume", "APFS", volumeName, owned.node],
            stdoutLimitBytes: 4096, stderrLimitBytes: 16 * 1024,
            deadlineSeconds: timeouts.eraseSeconds, killGraceSeconds: timeouts.killGraceSeconds)
        guard erase.launched, erase.exitCode == 0 else {
            note("ram disk: diskutil eraseVolume on \(owned.node) failed (\(describe(erase))) — detaching the device this call attached")
            await detach(owned, timeouts: timeouts)
            return nil
        }
        return owned
    }

    /// Decrement refcount; only actually unmount when the last user releases.
    /// Matches the mount()/unmount() lifecycle of a single scan task.
    func unmount() async {
        guard let owned = device else { return }
        refCount -= 1
        if refCount > 0 { return }
        let timeouts = self.timeouts
        _ = await ProcessRunner.detachedKeepingExecutor(priority: .userInitiated) {
            await Self.detach(owned, timeouts: timeouts)
        }.value
        // Cleared whether or not the detach succeeded (as before): a failed
        // detach is logged by `detach`, and the launch/quit sweep retries it.
        device = nil
        mountPoint = nil
        refCount = 0
    }

    /// Current refcount — exposed for tests and diagnostics only.
    var currentRefCount: Int { refCount }

    /// `hdiutil detach <node> -force` for a device this actor attached.
    /// True when hdiutil exited 0; a failure is logged, never silent.
    @discardableResult
    private static func detach(_ owned: OwnedDevice, timeouts: Timeouts) async -> Bool {
        let result = await ProcessRunner.runProcess(
            executable: hdiutil, arguments: ["detach", owned.node, "-force"],
            stdoutLimitBytes: 4096, stderrLimitBytes: 16 * 1024,
            deadlineSeconds: timeouts.detachSeconds, killGraceSeconds: timeouts.killGraceSeconds)
        guard result.launched, result.exitCode == 0 else {
            note("ram disk: hdiutil detach of \(owned.node) FAILED (\(describe(result))) — the RAM device is still attached; the launch/quit sweep will retry")
            return false
        }
        return true
    }

    /// How one command ended, in words, for the log.
    private static func describe(_ result: ProcessRunner.Result) -> String {
        if !result.launched { return "could not start: \(result.stderr)" }
        let words = result.stderr.split(separator: "\n").last.map { ": " + $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if result.timedOut { return "timed out, exit \(result.exitCode)\(words)" }
        return "exit \(result.exitCode)\(words)"
    }

    private static func note(_ line: String) {
        ramDiskLog.notice("\(line, privacy: .public)")
        appLog.write(line)
    }

    // MARK: - Stale-mount cleanup

    /// True for the names macOS gives THIS app's RAM disk: `VideoScan_Temp`,
    /// or `VideoScan_Temp N` when that name was already mounted. Anything
    /// else that merely starts with the name (`VideoScan_Temp_Archive`,
    /// `VideoScan_Temporary`) is somebody's volume and is never detached.
    static func isOwnMountName(_ name: String) -> Bool {
        if name == volumeName { return true }
        guard name.hasPrefix(volumeName + " ") else { return false }
        let suffix = name.dropFirst(volumeName.count + 1)
        return !suffix.isEmpty && suffix.count <= 3 && suffix.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Hard-detach any RAM disks left over from previous launches (or crashes).
    /// Scans `/Volumes` for this app's RAM-disk names (`isOwnMountName`)
    /// and force-detaches each via `hdiutil`. Safe to call at app launch and at
    /// app termination — no-op if nothing is mounted.
    ///
    /// Synchronous on purpose: we want it to finish before app exit returns.
    /// Bounded: each detach has `detachSeconds` (then SIGKILL, then abandon),
    /// so a wedged hdiutil cannot hold the quit forever.
    ///
    /// `volumesDir` is a parameter so a test sweeps a scratch directory.
    @discardableResult
    static func cleanupStaleMounts(volumesDir: String = "/Volumes",
                                   timeouts: Timeouts = Timeouts()) -> [String] {
        let prefix = volumeName
        let fm = FileManager.default
        // BEGIN line: this stat of the mount table blocks on an unresponsive
        // network or RAID mount, and it is one of the last things the process
        // does before exiting.
        ramDiskLog.notice("ram disk sweep: scanning \(volumesDir, privacy: .public) for \(prefix, privacy: .public)*")
        appLog.write("ram disk sweep: scanning \(volumesDir) for \(prefix)*")
        guard let entries = try? fm.contentsOfDirectory(atPath: volumesDir) else {
            ramDiskLog.notice("ram disk sweep: \(volumesDir, privacy: .public) unreadable — nothing to detach")
            appLog.write("ram disk sweep: \(volumesDir) unreadable — nothing to detach")
            return []
        }

        var detached: [String] = []
        for name in entries.sorted() where name.hasPrefix(prefix) {
            let mountPath = "\(volumesDir)/\(name)"
            guard isOwnMountName(name) else {
                note("ram disk sweep: LEFT ALONE \(mountPath) — it starts with \(prefix) but is not a name this app's RAM disk gets")
                continue
            }
            // BEGIN line: hdiutil detach on a busy volume can wedge; the
            // deadline below is what ends it.
            ramDiskLog.notice("ram disk sweep: hdiutil detach -force \(mountPath, privacy: .public)")
            appLog.write("ram disk sweep: hdiutil detach -force \(mountPath)")
            let result = ProcessRunner.runProcessBlocking(
                executable: hdiutil, arguments: ["detach", mountPath, "-force"],
                stdoutLimitBytes: 4096, stderrLimitBytes: 16 * 1024,
                deadlineSeconds: timeouts.detachSeconds, killGraceSeconds: timeouts.killGraceSeconds)
            guard result.launched || result.timedOut else {
                appLog.write("ram disk sweep: could not launch hdiutil for \(mountPath): \(result.stderr)")
                continue
            }
            if result.exitCode == 0 {
                detached.append(mountPath)
            }
            appLog.write("ram disk sweep: hdiutil \(result.timedOut ? "timed out, exit" : "exited") \(result.exitCode) for \(mountPath)")
        }
        ramDiskLog.notice("ram disk sweep: done — detached \(detached.count)")
        appLog.write("ram disk sweep: done — detached \(detached.count)")
        return detached
    }
}
