// DossierDashboardView+Subviews.swift
// The small leaf subviews behind the dashboard's static chrome —
// extracted verbatim from DossierDashboardView.swift (refactor
// 2026-06-25): DialRing, StatRow, ChannelStat, StatusBadge. Only
// ChannelStat lost its `private` (DossierDashboardView's body, still
// in the main file, instantiates it in the Total Processed box across
// the file boundary, and Swift `private` is file-scoped). DialRing /
// StatRow / StatusBadge are leftovers from the old dial + fleet panel,
// not referenced anywhere today, so they keep their `private`.
// (Swift file split ≈ C++ splitting a translation unit; `private`
// here means file-private to THIS .swift file.)

import SwiftUI

// MARK: - Existing subviews (DialRing, StatRow, ChannelStat, StatusBadge)

/// The big colorful ring. Drawn as two stacked circles: faint full
/// circle (the track), then the colored arc trimmed to the progress
/// fraction. Center label is the % string.
private struct DialRing: View {
    let progress: Double
    let centerLabel: String

    var body: some View {
        ZStack {
            // Stroke width scaled with the ring — 24 reads better at
            // 270px than the old 16.
            Circle()
                .stroke(Color.secondary.opacity(0.18), lineWidth: 24)

            Circle()
                .trim(from: 0, to: max(0, min(progress, 1)))
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [.blue, .indigo, .purple, .pink, .orange]),
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 24, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: progress)

            VStack(spacing: 4) {
                // Scaled with the ring — bigger graphics per Rick's
                // preference. Rounded font reads well at this size.
                Text(centerLabel)
                    .font(.system(size: 56, weight: .semibold, design: .rounded))
                    // numericText() animates digit changes (a brief
                    // scroll/flip) so the % readout glides instead of
                    // popping when the catalog ticks up.
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.3), value: centerLabel)
                Text("Analyzed")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
        }
    }
}

private struct StatRow: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .frame(width: 90, alignment: .leading)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 60, alignment: .trailing)
                .foregroundColor(color)
                // Number-aware transition: each digit change scrolls
                // briefly rather than popping. Rate/ETA also pass
                // through here — a "—" → "1.2/min" transition still
                // animates because contentTransition handles both.
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.3), value: value)
        }
    }
}

struct ChannelStat: View {
    let icon: String
    let label: String
    let value: Int
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundColor(color)
            Text("\(value)")
                .font(.system(.title3, design: .monospaced))
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.3), value: value)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct StatusBadge: View {
    let status: CaptionJobStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(badgeColor)
                .frame(width: 8, height: 8)
            Text(badgeText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.12))
        .cornerRadius(10)
    }

    private var badgeColor: Color {
        switch status {
        case .idle:       return .gray
        case .running:    return .green
        case .cancelling: return .orange
        case .finished:   return .blue
        }
    }

    private var badgeText: String {
        switch status {
        case .idle:       return "in-app sweep idle"
        case .running:    return "in-app sweep running"
        case .cancelling: return "stopping…"
        case .finished:   return "in-app sweep finished"
        }
    }
}
