import SwiftUI
import Combine

// MARK: - Dossier toolbar chip
//
// Small persistent progress indicator embedded in the catalog tab
// toolbar. Always visible while Rick is searching so he can see fleet
// progress at a glance without keeping the full Dossier Dashboard
// window open. Click opens the dashboard.
//
// Shape: ~28pt ring + "N/M" label. The ring uses the same
// AngularGradient as the full dashboard's DialRing for visual
// consistency — they're the same data, different sizes.
//
// Refresh: observed via the @ObservedObject model. SwiftUI auto-
// recomputes the counts when records change, which happens via the
// live-reload poll (every 30s) AND the in-app sweep's writeback.

struct DossierToolbarChip: View {

    @ObservedObject var model: VideoScanModel
    @Environment(\.openWindow) private var openWindow

    /// Tracks the dossier count over a sliding window so we can color
    /// the ring green when the fleet is actively producing. Mirrors
    /// the dashboard's RateTracker exactly — same window, same units.
    @State private var rate: RateTracker = .init()

    /// 5s tick. Mirrors the dashboard's refresh cadence. Keeps the
    /// chip color in lock-step with the dial.
    private let refreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        Button {
            openWindow(id: "dossier")
        } label: {
            HStack(spacing: 6) {
                MiniRing(progress: progress, active: rate.perMinute >= 1)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(headlineCount)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    Text(subText)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help("Catalog dossier: \(headlineCount) (\(percentLabel))\(rateHelp). Click for dashboard (⌘⇧O).")
        .onAppear { rate.record(count: dossieredCount, at: Date()) }
        .onReceive(refreshTimer) { _ in
            rate.record(count: dossieredCount, at: Date())
        }
    }

    /// Suffix the tooltip with the rate when it's meaningful. Empty
    /// while we wait for the second sample.
    private var rateHelp: String {
        rate.hasEnoughSamples ? ". Rate \(rate.displayText)." : ""
    }

    // MARK: - Derived

    private var dossieredCount: Int {
        model.records.reduce(0) { $0 + ($1.dossierProcessedAt != nil ? 1 : 0) }
    }

    private var totalCount: Int { model.records.count }

    private var progress: Double {
        guard totalCount > 0 else { return 0 }
        return Double(dossieredCount) / Double(totalCount)
    }

    private var percentLabel: String {
        let pct = progress * 100
        if pct < 1 && dossieredCount > 0 { return "<1%" }
        return String(format: "%.0f%%", pct)
    }

    private var headlineCount: String {
        "\(dossieredCount)/\(totalCount)"
    }

    private var subText: String {
        "completed · \(percentLabel)"
    }
}

// MARK: - Mini ring

/// Same gradient + arc as DossierDashboardView's DialRing but sized
/// for the toolbar — thinner stroke, smaller dimensions, no center
/// label.
private struct MiniRing: View {
    let progress: Double
    /// True when the fleet is actively producing (rate >= 1/min).
    /// Drives the stroke gradient — full color when active, muted
    /// gray-on-gray when idle so the chip looks "asleep at a glance."
    let active: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.22), lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0, min(progress, 1)))
                .stroke(strokeStyle, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.3), value: progress)
                .animation(.easeOut(duration: 0.3), value: active)
        }
    }

    /// Active = the same blue→orange AngularGradient the big dial uses
    /// (consistent fleet-color identity). Idle = a single muted gray
    /// so the chip still shows progress %, just without the "alive"
    /// signal.
    private var strokeStyle: AnyShapeStyle {
        if active {
            return AnyShapeStyle(AngularGradient(
                gradient: Gradient(colors: [.blue, .indigo, .purple, .pink, .orange]),
                center: .center
            ))
        }
        return AnyShapeStyle(Color.secondary.opacity(0.55))
    }
}
