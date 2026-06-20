import SwiftUI

// MARK: - RelocateJobsBadge
//
// Toolbar badge for the Volumes window's "Migrate Jobs" button. Extracted
// into its own small View so the badge logic lives in one place and the
// toolbar stays declarative (Swift's idiom for modularity is composing
// small Views, not subclassing).
//
// It counts jobs that still need attention — queued OR in flight — so a job
// you've *hidden but is still running* always leaves a visible breadcrumb,
// even when nothing is queued behind it. The old badge counted only queued
// jobs, so a lone running job showed nothing (the "where did it go?" gap).
//
// Tint signals state at a glance: accent + filled tray while work is running,
// secondary + outline tray when the queue is only waiting.

struct RelocateJobsBadge: View {
    /// Non-terminal jobs (queued + in flight). Drives whether a badge shows.
    let activeCount: Int
    /// In-flight jobs (reconciling / copying / awaiting done). Drives the tint.
    let runningCount: Int

    private var isRunning: Bool { runningCount > 0 }

    var body: some View {
        Label("Migrate Jobs", systemImage: isRunning ? "tray.full.fill" : "tray.full")
            .overlay(alignment: .topTrailing) {
                if activeCount > 0 {
                    Text("\(activeCount)")
                        .font(.caption2.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(isRunning ? Color.accentColor : Color.secondary)
                        .clipShape(Capsule())
                        .offset(x: 8, y: -8)
                        .accessibilityLabel(isRunning
                            ? "\(activeCount) migrate jobs, \(runningCount) running"
                            : "\(activeCount) migrate jobs queued")
                }
            }
    }
}
