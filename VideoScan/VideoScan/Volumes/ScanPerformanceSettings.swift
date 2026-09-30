import Foundation

// MARK: - Performance Settings
//
// Standalone value type — not part of VideoScanModel's identity. Extracted
// from VideoScanModel.swift during the 2026-05 size-cap refactor so the
// model file stays under the 1,000-line SwiftLint threshold.

struct ScanPerformanceSettings {
    var probesPerVolume: Int = 8          // concurrent ffprobe processes per volume
    var ramDiskGB: Int = 16               // RAM disk size for network prefetch (GB)
    var prefetchMB: Int = 50              // bytes to prefetch from network files (MB)
    var combineConcurrency: Int = 4       // concurrent ffmpeg combine processes
    var memoryFloorGB: Int = 4            // auto-pause when available RAM drops below this (GB)

    // MARK: Persistence

    // See ScanOptions.defaults — UserDefaults is thread-safe.
    nonisolated(unsafe) private static let defaults = UserDefaults.standard
    private static let prefix = "perf_"

    static func restored() -> ScanPerformanceSettings {
        let d = defaults; let p = prefix
        var s = ScanPerformanceSettings()
        if d.object(forKey: "\(p)probesPerVolume") != nil { s.probesPerVolume = d.integer(forKey: "\(p)probesPerVolume") }
        if d.object(forKey: "\(p)ramDiskGB") != nil { s.ramDiskGB = d.integer(forKey: "\(p)ramDiskGB") }
        if d.object(forKey: "\(p)prefetchMB") != nil { s.prefetchMB = d.integer(forKey: "\(p)prefetchMB") }
        if d.object(forKey: "\(p)combineConcurrency") != nil {
            // Floor at 1 — a stored 0 (corrupt prefs / old migration /
            // manual `defaults write`) would otherwise make
            // AsyncSemaphore(limit: 0) deadlock the combine queue.
            // Rick 2026-06-14 hit this in production. Belt-and-
            // suspenders: AsyncSemaphore also clamps, but loading
            // honest values here is cleaner.
            let stored = d.integer(forKey: "\(p)combineConcurrency")
            s.combineConcurrency = max(1, stored)
        }
        if d.object(forKey: "\(p)memoryFloorGB") != nil { s.memoryFloorGB = d.integer(forKey: "\(p)memoryFloorGB") }
        return s
    }

    func save() {
        let d = Self.defaults; let p = Self.prefix
        d.set(probesPerVolume, forKey: "\(p)probesPerVolume")
        d.set(ramDiskGB, forKey: "\(p)ramDiskGB")
        d.set(prefetchMB, forKey: "\(p)prefetchMB")
        d.set(combineConcurrency, forKey: "\(p)combineConcurrency")
        d.set(memoryFloorGB, forKey: "\(p)memoryFloorGB")
    }
}
