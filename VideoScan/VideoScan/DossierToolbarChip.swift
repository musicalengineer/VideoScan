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
// Refresh: observed via the @ObservedObject model. The counts are READ
// from the model's cached `dossierCounts` (recomputed on catalog
// mutation, debounced) — never computed over `records` here. This chip
// sits in the catalog toolbar, whose hosting view re-evaluates body on
// every sibling invalidation; an O(records) reduce in body was one leg
// of the 2026-07-02 scan/UI feedback storm at 90k records.

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
            DossierWindowOpener.open(using: openWindow, source: "chip")
        } label: {
            // Geometry matched to backupStatusBadge, its immediate
            // neighbour on the Volume Scanner row (Rick 2026-08-12: the
            // chip "doesn't blend in with the theme on this row"). The
            // old version stacked two lines of text beside a 22pt ring,
            // which made it noticeably taller and heavier than every
            // bordered button around it — it read as pasted on rather
            // than part of the row. One line, a smaller ring, and the
            // badge's stroke/fill treatment put it in the same register.
            HStack(spacing: 6) {
                MiniRing(progress: progress, active: rate.perMinute >= 1)
                    .frame(width: 14, height: 14)
                Text(headlineCount)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.secondary.opacity(0.08))
                    )
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

    // O(1) reads off the model's cache — NO O(records) work in view
    // bodies (see VideoScanModel.dossierCounts).
    private var dossieredCount: Int { model.dossierCounts.dossiered }

    private var totalCount: Int { model.dossierCounts.total }

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
