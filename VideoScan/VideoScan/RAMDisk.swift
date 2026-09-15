import Foundation
import os

/// This file runs on the QUIT path (VideoScanApp.applicationWillTerminate),
/// synchronously, AFTER "app quitting" is written — and until 2026-09-14 it
/// contained no logging at all. Both `contentsOfDirectory(/Volumes)` and
/// `hdiutil detach -force` + `waitUntilExit()` can block indefinitely on an
/// unresponsive mount, which reproduces the 2026-09-13 wedge signature exactly:
/// "app quitting", then silence, forever. Rick's rule, 2026-09-14: log that you
/// are ENTERING an operation that can block, not only that it finished.
private let ramDiskLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                category: "ramdisk")

/// Manages a macOS RAM disk for high-speed temp I/O.
/// Uses hdiutil to create an in-memory disk image — pure RAM, no SSD wear, no latency.
/// All Process calls run on detached tasks to avoid blocking the cooperative thread pool.
actor RAMDisk {
    private(set) var mountPoint: String?
    private var devicePath: String?
    /// Ref count of active users (concurrent scans). Only the last unmount()
    /// actually ejects — prevents one scan's completion from yanking the disk
    /// out from under a still-running parallel scan, which was causing every
    /// subsequent network probe to fall back to direct reads and hit the 60s
    /// timeout. See VideoScan issue #33 thread / overnight 2026-04-21.
    private var refCount: Int = 0

    /// Mount a RAM disk of the given size. Returns true on success.
    /// Idempotent across callers — if already mounted, just bumps the refcount.
    func mount(sizeMB: Int) async -> Bool {
        if mountPoint != nil {
            refCount += 1
            return true
        }

        let sectors = sizeMB * 2048  // 512-byte sectors
        let name = "VideoScan_Temp"
        let mp = "/Volumes/\(name)"

        // Run hdiutil/diskutil on a real OS thread — these block on I/O
        let result = await Task.detached(priority: .userInitiated) {
            // Step 1: Create RAM device
            let createProc = Process()
            createProc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            createProc.arguments = ["attach", "-nomount", "ram://\(sectors)"]
            let createPipe = Pipe()
            createProc.standardOutput = createPipe
            createProc.standardError = Pipe()

            do { try createProc.run() } catch { return nil as String? }
            createProc.waitUntilExit()
            guard createProc.terminationStatus == 0 else { return nil as String? }

            let devData = createPipe.fileHandleForReading.readDataToEndOfFile()
            guard let dev = String(data: devData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !dev.isEmpty else { return nil as String? }

            // Step 2: Format as APFS
            let fmtProc = Process()
            fmtProc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            fmtProc.arguments = ["eraseVolume", "APFS", name, dev]
            fmtProc.standardOutput = Pipe()
            fmtProc.standardError = Pipe()

            do { try fmtProc.run() } catch {
                Self.ejectDeviceSync(dev)
                return nil as String?
            }
            fmtProc.waitUntilExit()
            guard fmtProc.terminationStatus == 0 else {
                Self.ejectDeviceSync(dev)
                return nil as String?
            }

            return dev as String?
        }.value

        guard let dev = result else { return false }
        devicePath = dev
        mountPoint = mp
        refCount = 1
        return true
    }

    /// Decrement refcount; only actually unmount when the last user releases.
    /// Matches the mount()/unmount() lifecycle of a single scan task.
    func unmount() async {
        guard let dev = devicePath else { return }
        refCount -= 1
        if refCount > 0 { return }
        await Task.detached(priority: .userInitiated) {
            Self.ejectDeviceSync(dev)
        }.value
        devicePath = nil
        mountPoint = nil
        refCount = 0
    }

    /// Current refcount — exposed for tests and diagnostics only.
    var currentRefCount: Int { refCount }

    /// Synchronous eject — only call from a detached task, never from the cooperative pool.
    private static func ejectDeviceSync(_ dev: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["detach", dev, "-force"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
    }

    // MARK: - Stale-mount cleanup

    /// Hard-detach any RAM disks left over from previous launches (or crashes).
    /// Scans `/Volumes` for anything matching the `VideoScan_Temp*` naming pattern
    /// and force-detaches each via `hdiutil`. Safe to call at app launch and at
    /// app termination — no-op if nothing is mounted.
    ///
    /// Synchronous on purpose: we want it to finish before app exit returns.
    @discardableResult
    static func cleanupStaleMounts() -> [String] {
        let prefix = "VideoScan_Temp"
        let volumesDir = "/Volumes"
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
        for name in entries where name.hasPrefix(prefix) {
            let mountPath = "\(volumesDir)/\(name)"
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            proc.arguments = ["detach", mountPath, "-force"]
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            do {
                // BEGIN line: hdiutil detach on a busy volume has no deadline
                // here and waitUntilExit() never returns if it wedges.
                ramDiskLog.notice("ram disk sweep: hdiutil detach -force \(mountPath, privacy: .public)")
                appLog.write("ram disk sweep: hdiutil detach -force \(mountPath)")
                try proc.run()
                proc.waitUntilExit()
                if proc.terminationStatus == 0 {
                    detached.append(mountPath)
                }
                appLog.write("ram disk sweep: hdiutil exited \(proc.terminationStatus) for \(mountPath)")
            } catch {
                appLog.write("ram disk sweep: could not launch hdiutil for \(mountPath): \(error.localizedDescription)")
            }
        }
        ramDiskLog.notice("ram disk sweep: done — detached \(detached.count)")
        appLog.write("ram disk sweep: done — detached \(detached.count)")
        return detached
    }
}
