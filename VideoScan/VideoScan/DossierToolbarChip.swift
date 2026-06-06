import SwiftUI

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

    var body: some View {
        Button {
            openWindow(id: "dossier")
        } label: {
            HStack(spacing: 6) {
                MiniRing(progress: progress)
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
        .help("Catalog dossier: \(headlineCount) (\(percentLabel)). Click for dashboard (⌘⇧O).")
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
        "dossiered · \(percentLabel)"
    }
}

// MARK: - Mini ring

/// Same gradient + arc as DossierDashboardView's DialRing but sized
/// for the toolbar — thinner stroke, smaller dimensions, no center
/// label.
private struct MiniRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.22), lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0, min(progress, 1)))
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [.blue, .indigo, .purple, .pink, .orange]),
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.3), value: progress)
        }
    }
}
