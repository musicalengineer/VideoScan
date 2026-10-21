// SystemPreflightProbe.swift (VideoScanCore/Preflight)
// The real machine behind `PreflightProbe`. Every answer is one cheap
// system call: a URLResourceValues read, a sysctl, a stat, an IOKit power
// snapshot, or a one-row read-only SQLite query. Together well under the
// 200 ms fast-phase budget (quick_check, the one O(N) question, is separate).
//
// Sources:
//   disk     URLResourceValues: min(.volumeAvailableCapacityKey,
//            .volumeAvailableCapacityForImportantUsageKey) — bytes free now,
//            purgeable space NOT counted (QA r1 M4); the important-usage
//            figure is kept for the log only. .volumeTotalCapacityKey; the
//            volume's mount point is its id. ≈ 7–20 ms per call (macOS
//            totals purgeable space) — the one costly question.
//   memory   ProcessInfo.physicalMemory
//   swap     sysctl vm.swapusage → xsw_usage.xsu_used
//   thermal  ProcessInfo.thermalState
//   power    IOPSCopyPowerSourcesInfo / IOPSGetProvidingPowerSourceType
//   tools    FFmpegLocator — the resolver the app and the preview helper use
//   catalog  CatalogPreflightReader (Store/, read-only GRDB queue)
//
// (For Rick: `sysctlbyname` is the same C call you'd make from C++; Swift
// passes `&usage` as a pointer to the struct, like `&usage` in C.)

import Foundation
import IOKit.ps

public struct SystemPreflightProbe: PreflightProbe {

    public init() {}

    // MARK: Disks

    public func volume(containing url: URL) throws -> PreflightVolume? {
        let existing = Self.nearestExisting(url)
        let values = try existing.resourceValues(forKeys: [
            .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey, .volumeURLKey, .volumeNameKey,
        ])
        guard let total = values.volumeTotalCapacity else { return nil }
        let freeNow = values.volumeAvailableCapacity.map(Int64.init)
        let important = values.volumeAvailableCapacityForImportantUsage
        // QA r1 (M4): the rules use bytes free RIGHT NOW. The important-usage
        // figure counts purgeable files macOS hasn't freed (8.2 GB more than
        // free on the M4, 2026-10-21); a commit's write() won't wait for the
        // purge. Take the smaller of the two; either alone if only one answers.
        guard let available = [freeNow, important].compactMap({ $0 }).min() else { return nil }
        return PreflightVolume(id: values.volume?.path ?? existing.path,
                               name: values.volumeName ?? "the disk",
                               availableBytes: available, totalBytes: Int64(total),
                               freeIncludingPurgeableBytes: important)
    }

    public func isVolumeMounted(at url: URL) -> Bool {
        let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
        let wanted = url.standardizedFileURL.path
        return mounted.contains { $0.standardizedFileURL.path == wanted }
    }

    /// `url`, or the closest ancestor that exists (a not-yet-created folder
    /// lives on its parent's volume).
    static func nearestExisting(_ url: URL) -> URL {
        var candidate = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: candidate.path), candidate.path != "/" {
            candidate.deleteLastPathComponent()
        }
        return candidate
    }

    // MARK: Memory and machine

    public func physicalMemoryBytes() -> UInt64? {
        let bytes = ProcessInfo.processInfo.physicalMemory
        return bytes > 0 ? bytes : nil
    }

    public func swapUsedBytes() throws -> UInt64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return usage.xsu_used
    }

    public func thermalState() -> PreflightThermalState? {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return nil
        }
    }

    public func powerSource() -> PreflightPowerSource? {
        // IOPS* follow the CF "Copy rule": we own the snapshot (takeRetainedValue);
        // the type string is borrowed from it (takeUnretainedValue).
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String? else {
            return nil
        }
        switch type {
        case kIOPMBatteryPowerKey: return .battery
        case kIOPMACPowerKey, kIOPMUPSPowerKey: return .mains
        default: return nil
        }
    }

    // MARK: Files and tools

    public func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func fileSize(at url: URL) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attributes[.size] as? NSNumber)?.uint64Value
    }

    public func isWritableFolder(at url: URL) -> Bool {
        let fm = FileManager.default
        var isFolder: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isFolder) {
            return isFolder.boolValue && fm.isWritableFile(atPath: url.path)
        }
        return fm.isWritableFile(atPath: url.deletingLastPathComponent().path)
    }

    public func executablePath(for tool: PreflightTool) -> String? {
        let path: String
        switch tool {
        case .ffmpeg: path = FFmpegLocator.ffmpegPath
        case .ffprobe: path = FFmpegLocator.ffprobePath
        }
        // The locator falls back to its first candidate even when nothing is
        // there; only an executable file counts as found.
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    // MARK: Catalog

    public func catalogSchemaVersion(at databaseURL: URL) throws -> Int? {
        try CatalogPreflightReader.schemaVersion(at: databaseURL)
    }

    public func catalogQuickCheck(at databaseURL: URL, budget: Duration,
                                  cancellation: PreflightCancellation) throws -> PreflightQuickCheckOutcome {
        try CatalogPreflightReader.quickCheck(at: databaseURL, budget: budget, cancellation: cancellation)
    }
}
