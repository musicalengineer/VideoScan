import Foundation

/// Manages a macOS RAM disk for high-speed temp I/O.
/// Uses hdiutil to create an in-memory disk image — pure RAM, no SSD wear, no latency.
/// All Process calls run on detached tasks to avoid blocking the cooperative thread pool.
actor RAMDisk {
    private(set) var mountPoint: String?
    private var devicePath: String?

    /// Mount a RAM disk of the given size. Returns true on success.
    func mount(sizeMB: Int) async -> Bool {
        guard mountPoint == nil else { return true }

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
        return true
    }

    /// Unmount and release the RAM disk.
    func unmount() async {
        guard let dev = devicePath else { return }
        await Task.detached(priority: .userInitiated) {
            Self.ejectDeviceSync(dev)
        }.value
        devicePath = nil
        mountPoint = nil
    }

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
        guard let entries = try? fm.contentsOfDirectory(atPath: volumesDir) else {
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
                try proc.run()
                proc.waitUntilExit()
                if proc.terminationStatus == 0 {
                    detached.append(mountPath)
                }
            } catch {
                // ignore — best-effort
            }
        }
        return detached
    }
}
