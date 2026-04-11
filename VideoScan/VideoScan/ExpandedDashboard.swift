import SwiftUI
import Combine

/// Detail dashboard shown as a popover or in the floating window.
/// Per-volume progress, cache rate, stream breakdown, throughput sparkline, errors.
struct ExpandedDashboard: View {
    @ObservedObject var dashboard: DashboardState
    let isScanning: Bool
    let isCombining: Bool

    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var completed: Int { isScanning ? dashboard.scanCompleted : dashboard.combineCompleted }
    private var total: Int { isScanning ? dashboard.scanTotal : dashboard.combineTotal }
    private var startTime: Date? { isScanning ? dashboard.scanStartTime : dashboard.combineStartTime }
    private var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }

    private var elapsed: TimeInterval {
        guard let start = startTime else { return 0 }
        return now.timeIntervalSince(start)
    }

    private var eta: String {
        guard dashboard.scanPhase != .paused,
              completed > 0, total > 0, fraction < 1.0 else { return "" }
        let secsPerItem = elapsed / Double(completed)
        let remaining = secsPerItem * Double(total - completed)
        if remaining < 60 { return "<1 min left" }
        if remaining < 3600 { return "~\(Int(remaining / 60)) min left" }
        let hrs = Int(remaining / 3600)
        let mins = Int((remaining.truncatingRemainder(dividingBy: 3600)) / 60)
        return "~\(hrs)h \(mins)m left"
    }

    private var elapsedStr: String {
        let s = Int(elapsed)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    private var barColor: Color {
        if fraction < 0.25 { return .blue }
        if fraction < 0.50 { return .cyan }
        if fraction < 0.75 { return .green }
        return Color(red: 0.2, green: 0.8, blue: 0.3)
    }

    private var phaseLabel: String {
        if isCombining { return "Combining" }
        return dashboard.scanPhase.rawValue
    }

    private var isIdle: Bool {
        !isScanning && !isCombining
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            scannerPane
            faceDetectionPane
            sharedResourcesPane
        }
        .padding(14)
        .frame(minWidth: 520, idealWidth: 560)
        .onReceive(timer) { now = $0 }
    }

    // MARK: - Pane: Catalog Scanner

    private var scannerActive: Bool {
        isScanning || isCombining || dashboard.scanPhase != .idle
    }

    private var scannerPane: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(scannerActive ? Color.cyan : Color.gray.opacity(0.4))
                        .frame(width: 8, height: 8)
                        .shadow(color: scannerActive ? .cyan.opacity(0.6) : .clear, radius: 4)
                    Text(scannerActive ? "ACTIVE" : "IDLE")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(scannerActive ? .cyan : .secondary)
                    Spacer()
                }

                if scannerActive {
                    headerSection
                    if isScanning || dashboard.scanPhase != .idle { scanSections }
                    if isCombining { combineSections }
                } else {
                    Text("No scan in progress.")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 4)
                }
            }
            .opacity(scannerActive ? 1.0 : 0.65)
        } label: {
            Label("Catalog Scanner", systemImage: "externaldrive.connected.to.line.below")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.cyan)
        }
    }

    // MARK: - Pane: Face Detection

    private var fdActive: Bool { dashboard.visionActive }

    private var faceDetectionPane: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(fdActive ? Color.purple : Color.gray.opacity(0.4))
                        .frame(width: 8, height: 8)
                        .shadow(color: fdActive ? .purple.opacity(0.6) : .clear, radius: 4)
                    Text(fdActive ? "ACTIVE" : "IDLE")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(fdActive ? .purple : .secondary)
                    Spacer()
                    if fdActive {
                        Text(String(format: "%.1f fps", dashboard.visionFPS))
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundColor(.purple)
                        Text(String(format: "%.0f ms/frame", dashboard.visionMsPerFrame))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                        if dashboard.visionWorkers > 0 {
                            Text("\(dashboard.visionWorkers) worker\(dashboard.visionWorkers == 1 ? "" : "s")")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // Apple Silicon visualizer — always visible inside the FD pane
                SiliconChipView(dashboard: dashboard)
            }
        } label: {
            Label("Face Detection (Vision / ANE)", systemImage: "brain")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.purple)
        }
    }

    // MARK: - Pane: Shared System Resources

    private var sharedResourcesPane: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                // Memory bar
                HStack(spacing: 6) {
                    Image(systemName: "memorychip")
                        .font(.system(size: 13))
                        .foregroundColor(memColor)
                    Text("Memory")
                        .font(.system(size: 14, weight: .medium))
                    Spacer()
                    Text(String(format: "%.1f / %.0f GB", dashboard.memUsedGB, dashboard.memTotalGB))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.15))
                        .frame(height: 5)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(memColor)
                            .frame(width: max(geo.size.width * memFraction, 0), height: 5)
                    }
                    .frame(height: 5)
                }

                // App RSS + Thermal + CPU load
                HStack(spacing: 12) {
                    HStack(spacing: 3) {
                        Image(systemName: "app.dashed")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text(String(format: "App: %.0f MB", dashboard.appMemoryMB))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    HStack(spacing: 3) {
                        Image(systemName: "thermometer.medium")
                            .font(.system(size: 11))
                            .foregroundColor(dashboard.thermalWarning ? .red : .secondary)
                        Text(dashboard.thermalLabel)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(dashboard.thermalWarning ? .red : .secondary)
                    }
                    HStack(spacing: 3) {
                        Image(systemName: "cpu")
                            .font(.system(size: 11))
                            .foregroundColor(.blue)
                        Text(String(format: "%.1f / %.1f / %.1f",
                                    dashboard.cpuLoad1,
                                    dashboard.cpuLoad5,
                                    dashboard.cpuLoad15))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            }
        } label: {
            Label("Shared Resources", systemImage: "gauge.with.dots.needle.50percent")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - System Metrics (always visible)

    private var memFraction: Double {
        dashboard.memTotalGB > 0 ? dashboard.memUsedGB / dashboard.memTotalGB : 0
    }

    private var memColor: Color {
        if memFraction < 0.6 { return .green }
        if memFraction < 0.8 { return .orange }
        return .red
    }

    // MARK: - Header

    private var headerSection: some View {
        GroupBox {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(barColor)
                            .frame(width: 8, height: 8)
                        Text(phaseLabel)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(barColor)
                    }
                    HStack(spacing: 10) {
                        Text("\(completed) / \(total)")
                            .font(.system(size: 15, weight: .medium, design: .monospaced))
                        Text("(\(Int(fraction * 100))%)")
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(barColor)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Elapsed: \(elapsedStr)")
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(.secondary)
                    if !eta.isEmpty {
                        Text(eta)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundColor(barColor)
                    }
                }
            }

            // Overall progress bar
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.gray.opacity(0.15))
                    .frame(height: 6)
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(
                            LinearGradient(
                                colors: [.blue, .cyan, .green],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: max(geo.size.width * fraction, 0), height: 6)
                        .animation(.easeInOut(duration: 0.3), value: fraction)
                }
                .frame(height: 6)
            }
        }
    }

    // MARK: - Scan Sections

    private var scanSections: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Per-volume progress
            if !dashboard.volumeProgress.isEmpty {
                GroupBox("Volumes") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(dashboard.volumeProgress) { vol in
                            VolumeProgressRow(volume: vol)
                        }
                    }
                }
            }

            // Cache
            let totalProbed = dashboard.scanCacheHits + dashboard.scanCacheMisses
            if totalProbed > 0 {
                GroupBox {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 13))
                                .foregroundColor(.yellow)
                            Text("Cache: \(dashboard.scanCacheHits) / \(totalProbed) hits")
                                .font(.system(size: 14, weight: .medium, design: .monospaced))
                            Text("(\(totalProbed > 0 ? Int(Double(dashboard.scanCacheHits) / Double(totalProbed) * 100) : 0)%)")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.yellow)
                        }
                        let cacheFrac = totalProbed > 0 ? Double(dashboard.scanCacheHits) / Double(totalProbed) : 0
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.gray.opacity(0.15))
                                .frame(height: 5)
                            GeometryReader { geo in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.yellow.opacity(0.7))
                                    .frame(width: max(geo.size.width * cacheFrac, 0), height: 5)
                            }
                            .frame(height: 5)
                        }
                    }
                }
            }

            // Stream type breakdown
            if !dashboard.liveStreamCounts.isEmpty {
                GroupBox {
                    StreamBreakdownBar(counts: dashboard.liveStreamCounts)
                }
            }

            // Throughput sparkline
            if dashboard.throughputSamples.count > 2 {
                GroupBox {
                    SparklineView(samples: dashboard.throughputSamples)
                }
            }

            // Errors
            if dashboard.scanErrors > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text("\(dashboard.scanErrors) file\(dashboard.scanErrors == 1 ? "" : "s") failed ffprobe")
                        .font(.system(size: 14))
                        .foregroundColor(.red)
                }
            }
        }
    }

    // MARK: - Combine Sections

    private var combineSections: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !dashboard.combineCurrentFile.isEmpty {
                GroupBox {
                    HStack(spacing: 6) {
                        Image(systemName: "film")
                            .foregroundColor(.blue)
                        Text(dashboard.combineCurrentFile)
                            .font(.system(size: 14, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            HStack(spacing: 14) {
                if dashboard.combineSucceeded > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("\(dashboard.combineSucceeded) succeeded")
                            .font(.system(size: 14, design: .monospaced))
                    }
                }
                if dashboard.combineFailed > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                        Text("\(dashboard.combineFailed) failed")
                            .font(.system(size: 14, design: .monospaced))
                    }
                }
            }
        }
    }
}

// MARK: - Volume Progress Row

private struct VolumeProgressRow: View {
    let volume: VolumeProgress

    private var fraction: Double {
        volume.totalFiles > 0 ? Double(volume.completedFiles) / Double(volume.totalFiles) : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: volume.isWalking ? "folder.badge.gearshape" : "externaldrive.fill")
                    .font(.system(size: 13))
                    .foregroundColor(volume.isWalking ? .orange : .blue)
                Text(volume.volumeName)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                Spacer()
                if volume.isWalking {
                    Text("scanning...")
                        .font(.system(size: 13))
                        .foregroundColor(.orange)
                } else {
                    Text("\(volume.completedFiles)/\(volume.totalFiles)")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                if volume.cacheHits > 0 {
                    HStack(spacing: 1) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 9))
                        Text("\(volume.cacheHits)")
                            .font(.system(size: 12, design: .monospaced))
                    }
                    .foregroundColor(.yellow)
                }
                if volume.errors > 0 {
                    HStack(spacing: 1) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                        Text("\(volume.errors)")
                            .font(.system(size: 12, design: .monospaced))
                    }
                    .foregroundColor(.red)
                }
            }

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.gray.opacity(0.15))
                    .frame(height: 5)
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(
                            LinearGradient(
                                colors: [.blue, .cyan],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: max(geo.size.width * fraction, 0), height: 5)
                        .animation(.easeInOut(duration: 0.3), value: fraction)
                }
                .frame(height: 5)
            }
        }
    }
}
