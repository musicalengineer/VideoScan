import SwiftUI
import Combine

/// Compact toolbar-inline dashboard. Shows phase, progress ring, key stats,
/// error badge, cache hit count, and expand/detach buttons.
struct CompactDashboard: View {
    @ObservedObject var dashboard: DashboardState
    let isScanning: Bool
    let isCombining: Bool
    @Binding var isExpanded: Bool
    @Environment(\.openWindow) var openWindow

    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var isActive: Bool { isScanning || isCombining }
    private var completed: Int { isScanning ? dashboard.scanCompleted : dashboard.combineCompleted }
    private var total: Int { isScanning ? dashboard.scanTotal : dashboard.combineTotal }
    private var startTime: Date? { isScanning ? dashboard.scanStartTime : dashboard.combineStartTime }

    private var fraction: Double {
        total > 0 ? Double(completed) / Double(total) : 0
    }

    private var percent: Int { Int(fraction * 100) }

    private var elapsed: TimeInterval {
        guard let start = startTime else { return 0 }
        return now.timeIntervalSince(start)
    }

    private var eta: String {
        guard dashboard.scanPhase != .paused,
              completed > 0, total > 0, fraction < 1.0 else { return "" }
        let secsPerItem = elapsed / Double(completed)
        let remaining = secsPerItem * Double(total - completed)
        if remaining < 60 { return "<1m" }
        if remaining < 3600 { return "~\(Int(remaining / 60))m" }
        let hrs = Int(remaining / 3600)
        let mins = Int((remaining.truncatingRemainder(dividingBy: 3600)) / 60)
        return "~\(hrs)h\(mins)m"
    }

    private var elapsedStr: String {
        let s = Int(elapsed)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    private var barColor: Color {
        if dashboard.scanPhase == .paused { return .cyan }
        if fraction < 0.25 { return .blue }
        if fraction < 0.50 { return .cyan }
        if fraction < 0.75 { return .green }
        return Color(red: 0.2, green: 0.8, blue: 0.3)
    }

    private var phaseIcon: String {
        if isCombining { return "rectangle.stack.badge.plus" }
        switch dashboard.scanPhase {
        case .idle:        return "stop.circle"
        case .discovering: return "folder.badge.gearshape"
        case .probing:     return "waveform.badge.magnifyingglass"
        case .paused:      return "pause.circle.fill"
        case .writingCSV:  return "doc.text"
        case .complete:    return "checkmark.circle.fill"
        }
    }

    private var phaseLabel: String {
        if isCombining { return "Combining" }
        return dashboard.scanPhase.rawValue
    }

    var body: some View {
        HStack(spacing: 8) {
            // Phase icon
            Image(systemName: phaseIcon)
                .font(.system(size: 14))
                .foregroundColor(barColor)

            // Progress ring
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 3.5)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(barColor, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.3), value: fraction)
                Text("\(percent)%")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(barColor)
            }
            .frame(width: 32, height: 32)

            // Stats
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(phaseLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(barColor)
                    Text("\(completed)/\(total)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                }
                HStack(spacing: 6) {
                    Text(elapsedStr)
                        .foregroundColor(.secondary)
                    if !eta.isEmpty {
                        Text(eta)
                            .foregroundColor(barColor)
                    }
                    // Cache hits badge
                    if isScanning && dashboard.scanCacheHits > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 7))
                                .foregroundColor(.yellow)
                            Text("\(dashboard.scanCacheHits)")
                                .foregroundColor(.yellow)
                        }
                    }
                }
                .font(.system(size: 9, design: .monospaced))
            }

            // Error badge
            if dashboard.scanErrors > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                    Text("\(dashboard.scanErrors)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                }
                .foregroundColor(.red)
            }

            // Combine success/fail
            if isCombining {
                HStack(spacing: 4) {
                    if dashboard.combineSucceeded > 0 {
                        HStack(spacing: 1) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .bold))
                            Text("\(dashboard.combineSucceeded)")
                                .font(.system(size: 9, design: .monospaced))
                        }
                        .foregroundColor(.green)
                    }
                    if dashboard.combineFailed > 0 {
                        HStack(spacing: 1) {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                            Text("\(dashboard.combineFailed)")
                                .font(.system(size: 9, design: .monospaced))
                        }
                        .foregroundColor(.red)
                    }
                }
            }

            // Mini silicon chip indicator
            MiniSiliconChipView(dashboard: dashboard)

            // Expand / detach buttons
            Button { isExpanded.toggle() } label: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            Button { openWindow(id: "dashboard") } label: {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .onReceive(timer) { now = $0 }
    }
}
