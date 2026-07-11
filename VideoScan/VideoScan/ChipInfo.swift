import Foundation
import IOKit

// MARK: - ChipInfo
//
// Single source of truth for the hardware identity line, e.g.
//   "Apple M4 Max · 64 GB · 16 CPU (12P+4E) · 40 GPU · 16 ANE"
// Shown in the About window and the dashboard header (via
// DashboardState.chipName). Each segment is appended only when the
// machine actually answers for it, so an Intel Mac degrades to
// name + RAM + CPU with no fake zeros.

enum ChipInfo {

    /// Computed once — the hardware doesn't change under a running app.
    static let line: String = detect()

    private static func detect() -> String {
        let name = brandString()
        return name + detailSuffix(chipName: name)
    }

    private static func brandString() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "Apple Silicon" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        let s = String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "Apple Silicon" : s
    }

    private static func detailSuffix(chipName: String) -> String {
        var parts: [String] = []
        if let mem = sysctlUInt64("hw.memsize"), mem > 0 {
            parts.append("\(mem / (1 << 30)) GB")
        }
        if let ncpu = sysctlUInt64("hw.ncpu"), ncpu > 0 {
            // P/E split exists only on Apple Silicon; omit when absent.
            if let p = sysctlUInt64("hw.perflevel0.physicalcpu"),
               let e = sysctlUInt64("hw.perflevel1.physicalcpu"), p > 0 {
                parts.append("\(ncpu) CPU (\(p)P+\(e)E)")
            } else {
                parts.append("\(ncpu) CPU")
            }
        }
        if let gpu = gpuCoreCount() {
            parts.append("\(gpu) GPU")
        }
        if chipName.hasPrefix("Apple") {
            // Neural Engine core count isn't queryable; every M1–M4 chip
            // ships 16 ANE cores except the Ultras, which fuse two dies.
            parts.append(chipName.contains("Ultra") ? "32 ANE" : "16 ANE")
        }
        return parts.isEmpty ? "" : " · " + parts.joined(separator: " · ")
    }

    private static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    /// GPU core count from the IORegistry ("gpu-core-count" on the
    /// AGXAccelerator node). nil on Intel or if the key ever moves.
    private static func gpuCoreCount() -> Int? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let prop = IORegistryEntryCreateCFProperty(
            service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue(), let count = prop as? Int, count > 0 else {
            return nil
        }
        return count
    }
}
