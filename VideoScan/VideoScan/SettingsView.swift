// SettingsView.swift
// Performance settings panel — accessed via Cmd+, (Apple menu > Settings).

import SwiftUI
import IOKit

// MARK: - Settings Tab

struct SettingsTabView: View {
    @Binding var settings: ScanPerformanceSettings
    let totalRAMGB: Int

    private func ramDiskColor(_ gb: Int) -> Color {
        let pct = Double(gb) / Double(totalRAMGB)
        if pct > 0.5 { return .red }
        if pct > 0.30 { return .yellow }
        return .green
    }

    private func floorColor(_ gb: Int) -> Color {
        if gb < 2 { return .red }
        if gb < 4 { return .yellow }
        return .green
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                // Header
                settingsHeader

                Divider()

                // Scanning section
                VStack(alignment: .leading, spacing: 16) {
                    Label("Scanning", systemImage: "magnifyingglass")
                        .font(.headline)
                        .foregroundColor(.blue)

                    settingRow(
                        title: "Probes per volume",
                        value: "\(settings.probesPerVolume)",
                        description: "Concurrent ffprobe processes per volume",
                        slider: Slider(value: Binding(
                            get: { Double(settings.probesPerVolume) },
                            set: { settings.probesPerVolume = Int($0) }
                        ), in: 1...32, step: 1),
                        accentColor: .blue
                    )

                    settingRow(
                        title: "Memory floor",
                        value: "\(settings.memoryFloorGB) GB",
                        valueColor: floorColor(settings.memoryFloorGB),
                        description: "Auto-pause scanning when free RAM drops below this",
                        slider: Slider(value: Binding(
                            get: { Double(settings.memoryFloorGB) },
                            set: { settings.memoryFloorGB = Int($0) }
                        ), in: 1...Double(max(1, totalRAMGB / 4)), step: 1),
                        accentColor: .blue
                    )
                }

                Divider()

                // Network section
                VStack(alignment: .leading, spacing: 16) {
                    Label("Network Volumes", systemImage: "network")
                        .font(.headline)
                        .foregroundColor(.mint)

                    settingRow(
                        title: "RAM disk size",
                        value: "\(settings.ramDiskGB) GB",
                        valueColor: ramDiskColor(settings.ramDiskGB),
                        description: "Temporary RAM disk for network file prefetch (mounted at /Volumes/VideoScan_Temp)",
                        slider: Slider(value: Binding(
                            get: { Double(settings.ramDiskGB) },
                            set: { settings.ramDiskGB = Int($0) }
                        ), in: 1...Double(max(1, totalRAMGB / 2)), step: 1),
                        accentColor: .mint
                    )

                    settingRow(
                        title: "Prefetch size",
                        value: "\(settings.prefetchMB) MB",
                        description: "Header bytes copied per network file before probing",
                        slider: Slider(value: Binding(
                            get: { Double(settings.prefetchMB) },
                            set: { settings.prefetchMB = Int($0) }
                        ), in: 10...200, step: 10),
                        accentColor: .mint
                    )
                }

                Divider()

                // Video Combiner section
                VStack(alignment: .leading, spacing: 16) {
                    Label("Video Combiner", systemImage: "arrow.triangle.merge")
                        .font(.headline)
                        .foregroundColor(.orange)

                    settingRow(
                        title: "Concurrent tasks",
                        value: "\(settings.combineConcurrency)",
                        description: "Parallel ffmpeg processes for combining video + audio pairs",
                        slider: Slider(value: Binding(
                            get: { Double(settings.combineConcurrency) },
                            set: { settings.combineConcurrency = Int($0) }
                        ), in: 1...16, step: 1),
                        accentColor: .orange
                    )
                }

                Divider()

                HStack {
                    Button("Reset All to Defaults") {
                        settings = ScanPerformanceSettings()
                        settings.save()
                    }
                    .controlSize(.large)
                }
            }
            .padding(30)
            .frame(maxWidth: 600, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Settings Header (chip + RAM info)

    private var settingsHeader: some View {
        let info = Self.chipInfo()
        let freeGB = Int(MemoryPressureMonitor.shared.availableMemory() / (1024 * 1024 * 1024))
        let freeColor: Color = freeGB < 4 ? .red : freeGB < 8 ? .yellow : .green
        return VStack(alignment: .leading, spacing: 10) {
            Text("Performance Settings")
                .font(.title2.weight(.semibold))
            HStack {
                Image(systemName: "cpu.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.blue)
                Text(info.name)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                Spacer()
                chipTile("\(info.pCores)", label: "P-cores", color: .blue, icon: "bolt.fill")
                Spacer()
                chipTile("\(info.eCores)", label: "E-cores", color: .green, icon: "leaf.fill")
                Spacer()
                if info.gpuCores > 0 {
                    chipTile("\(info.gpuCores)", label: "GPU", color: .purple, icon: "gpu")
                    Spacer()
                }
                if info.neuralCores > 0 {
                    chipTile("\(info.neuralCores)", label: "Neural", color: .orange, icon: "brain")
                    Spacer()
                }
                // RAM tile — unified: total on top, free below
                VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 3) {
                            Image(systemName: "memorychip")
                                .font(.system(size: 10))
                            Text("\(totalRAMGB) GB RAM")
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                        }
                        .foregroundColor(.cyan)
                        HStack(spacing: 3) {
                            Image(systemName: "memorychip")
                                .font(.system(size: 10))
                                .hidden()
                            Text("\(freeGB) GB Free")
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundColor(freeColor)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.cyan.opacity(0.10))
                    .cornerRadius(6)
            }
        }
    }

    private func chipTile(_ value: String, label: String, color: Color, icon: String) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(value)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
            }
            Text(label)
                .font(.system(size: 12, weight: .bold))
        }
        .foregroundColor(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.10))
        .cornerRadius(6)
    }

    private struct ChipInfo {
        let name: String
        let pCores: Int
        let eCores: Int
        let gpuCores: Int
        let neuralCores: Int
    }

    private static func chipInfo() -> ChipInfo {
        func sysctl(_ key: String) -> Int {
            var val: Int = 0
            var size = MemoryLayout<Int>.size
            sysctlbyname(key, &val, &size, nil, 0)
            return val
        }

        func sysctlString(_ key: String) -> String {
            var size = 0
            sysctlbyname(key, nil, &size, nil, 0)
            guard size > 0 else { return "" }
            var buf = [CChar](repeating: 0, count: size)
            sysctlbyname(key, &buf, &size, nil, 0)
            return String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let name = sysctlString("machdep.cpu.brand_string")
            .replacingOccurrences(of: "Apple ", with: "")

        // perflevel0 = Performance cores, perflevel1 = Efficiency cores
        let pCores = sysctl("hw.perflevel0.physicalcpu")
        let eCores = sysctl("hw.perflevel1.physicalcpu")

        // GPU core count from IORegistry
        var gpuCores = 0
        let matchDict = IOServiceMatching("AGXAccelerator")
        var iterator: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iterator) == KERN_SUCCESS {
            var entry = IOIteratorNext(iterator)
            while entry != 0 {
                if let prop = IORegistryEntryCreateCFProperty(entry, "gpu-core-count" as CFString, kCFAllocatorDefault, 0) {
                    gpuCores = (prop.takeRetainedValue() as? Int) ?? 0
                }
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }
            IOObjectRelease(iterator)
        }

        // Neural Engine: not exposed via sysctl, derive from chip model
        let neuralCores = Self.neuralCoresForChip(name)

        return ChipInfo(name: name, pCores: pCores, eCores: eCores,
                        gpuCores: gpuCores, neuralCores: neuralCores)
    }

    private static func neuralCoresForChip(_ name: String) -> Int {
        let lower = name.lowercased()
        if lower.contains("m4") { return 16 }
        if lower.contains("m3") { return 16 }
        if lower.contains("m2") { return 16 }
        if lower.contains("m1") { return 16 }
        return 0
    }

    private func settingRow(
        title: String,
        value: String,
        valueColor: Color = .secondary,
        description: String,
        slider: some View,
        accentColor: Color = .accentColor
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.body)
                Spacer()
                Text(value)
                    .font(.system(.body, design: .monospaced).weight(.medium))
                    .foregroundColor(valueColor)
            }
            slider
                .tint(accentColor)
            Text(description)
                .font(.footnote).foregroundColor(.secondary)
        }
    }
}
