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

        /// nil unless the WHOLE of what attach printed — judged on its RAW
        /// BYTES, before any decoding — is exactly hdiutil's own line:
        ///
        ///     "/dev/disk" · 1–6 ASCII digits, no leading zero · then only
        ///     spaces, tabs, CR and LF · at most `maxAttachOutputBytes` in all
        ///
        /// Refused: empty output, a second line with content, a slice
        /// (`/dev/disk4s1`), a mount point, a volume name, text before or
        /// after the node, `/dev/disk0` (always the internal boot disk),
        /// any byte that is not ASCII (a BOM, a no-break space, Unicode
        /// digits), a NUL, and anything longer than the bound.
        ///
        /// Why raw bytes (Codex r1 P1, r2 P1; 2026-11-21): a decoded String
        /// is not what the tool wrote. The runner's collected copy is cut at
        /// a cap, and decoding then DROPS a leading UTF-8 BOM — so
        /// "BOM · /dev/disk5 · padding to the cap · a second node" arrived
        /// as a clean one-node string three bytes UNDER the cap. `raw` is
        /// every byte attach wrote, up to one past the bound (`RawOutput`),
        /// so over-long output is seen as over-long, never as a prefix.
        init?(rawAttachOutput raw: Data) {
            guard !raw.isEmpty, raw.count <= RAMDisk.maxAttachOutputBytes else { return nil }
            let bytes = [UInt8](raw)
            let prefix = Array("/dev/disk".utf8)
            guard bytes.starts(with: prefix) else { return nil }
            var index = prefix.count
            let digitsStart = index
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
            let digits = bytes[digitsStart..<index]
            guard (1...6).contains(digits.count), digits.first != 0x30 else { return nil }
            // Nothing after the node but hdiutil's padding.
            guard bytes[index...].allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }) else { return nil }
            node = String(decoding: bytes[..<index], as: UTF8.self)     // pure ASCII by construction
        }
    }

    /// The raw bytes one command wrote to stdout, kept up to `limit + 1`
    /// (one past the bound is enough to know the output was longer) and
    /// counted in full. Fed from the runner's `stdoutData` callback — the
    /// pipe's own chunks, before any cap or decoding.
    /// (C++: a mutex-guarded std::vector<uint8_t> with a high-water mark.)
    final class RawOutput: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var kept = Data()
        private var total = 0

        init(limit: Int) { self.limit = limit }

        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            total += chunk.count
            let room = limit + 1 - kept.count
            if room > 0 { kept.append(chunk.prefix(room)) }
        }

        var data: Data { lock.lock(); defer { lock.unlock() }; return kept }
        var byteCount: Int { lock.lock(); defer { lock.unlock() }; return total }
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
    /// The most `hdiutil attach -nomount` may print and still be believed.
    /// Its line is a 20-column device field, a tab, a 30-column (empty)
    /// content field, a tab and a newline — about 53 bytes; 256 leaves
    /// room for a wider layout without admitting pages of text.
    static let maxAttachOutputBytes = 256
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
        // stdout is taken RAW (stdoutData) and nothing is collected as a
        // String: the device node is validated on the bytes attach wrote.
        let raw = RawOutput(limit: maxAttachOutputBytes)
        let attach = await ProcessRunner.runProcess(
            executable: hdiutil, arguments: ["attach", "-nomount", "ram://\(sectors)"],
            stdoutData: { raw.append($0) },
            stdoutLimitBytes: 0, stderrLimitBytes: 16 * 1024,
            deadlineSeconds: timeouts.attachSeconds, killGraceSeconds: timeouts.killGraceSeconds)
        guard attach.launched, attach.exitCode == 0 else {
            note("ram disk: hdiutil attach failed (\(describe(attach))) — no RAM disk; nothing erased, nothing detached")
            return nil
        }
        guard let owned = OwnedDevice(rawAttachOutput: raw.data) else {
            // Refuse rather than guess: `diskutil eraseVolume` accepts a
            // mount point or a volume name as its device argument.
            note("ram disk: REFUSED — hdiutil attach exited 0 but printed \(raw.byteCount) byte(s) "
                 + "\(String(decoding: raw.data.prefix(80), as: UTF8.self).debugDescription), not exactly one /dev/diskN; nothing erased, nothing detached (a RAM device it made, if any, is left for the quit sweep)")
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
