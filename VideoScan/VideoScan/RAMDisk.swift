import Foundation

/// Manages a macOS RAM disk for high-speed temp I/O.
/// Uses hdiutil to create an in-memory disk image — pure RAM, no SSD wear, no latency.
actor RAMDisk {
    private(set) var mountPoint: String?
    private var devicePath: String?

    /// Mount a RAM disk of the given size. Returns true on success.
    func mount(sizeMB: Int) -> Bool {
        guard mountPoint == nil else { return true }

        let sectors = sizeMB * 2048  // 512-byte sectors
        let name = "VideoScan_Temp"
        let mp = "/Volumes/\(name)"

        let createProc = Process()
        createProc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        createProc.arguments = ["attach", "-nomount", "ram://\(sectors)"]
        let createPipe = Pipe()
        createProc.standardOutput = createPipe
        createProc.standardError = Pipe()

        do { try createProc.run() } catch { return false }
        createProc.waitUntilExit()
        guard createProc.terminationStatus == 0 else { return false }

        let devData = createPipe.fileHandleForReading.readDataToEndOfFile()
        guard let dev = String(data: devData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !dev.isEmpty else { return false }

        let fmtProc = Process()
        fmtProc.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        fmtProc.arguments = ["eraseVolume", "APFS", name, dev]
        fmtProc.standardOutput = Pipe()
        fmtProc.standardError = Pipe()

        do { try fmtProc.run() } catch {
            ejectDevice(dev)
            return false
        }
        fmtProc.waitUntilExit()
        guard fmtProc.terminationStatus == 0 else {
            ejectDevice(dev)
            return false
        }

        devicePath = dev
        mountPoint = mp
        return true
    }

    /// Unmount and release the RAM disk.
    func unmount() {
        guard let dev = devicePath else { return }
        ejectDevice(dev)
        devicePath = nil
        mountPoint = nil
    }

    private func ejectDevice(_ dev: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["detach", dev, "-force"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
    }
}
