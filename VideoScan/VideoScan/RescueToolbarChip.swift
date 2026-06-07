import SwiftUI

// MARK: - Rescue toolbar chip
//
// Mirror of DossierToolbarChip but for the in-flight rescue copy. Sits
// next to the Dossier chip in the catalog tab toolbar so Rick can
// monitor a multi-hour copy at a glance without opening Compare.
//
// Visibility rule: only renders when there's something to show
// (running OR a freshly-finished operation that hasn't been
// acknowledged). Otherwise it's hidden — toolbar real estate is
// scarce, especially on the 14" M5.
//
// Click action: re-opens Compare (sets the bound `showVolumeCompare`
// flag). The persistent rescueBanner inside the sheet picks up the
// state from the same @ObservedObject and renders the progress UI
// without requiring a fresh comparison run.

struct RescueToolbarChip: View {
    /// Subscribed via environment so only the chip re-renders when
    /// rescue state changes — NOT the entire ContentView. Lint hook
    /// `scripts/lint_environment_objects.py` enforces that any view
    /// declaring @EnvironmentObject actually reads from it; the body
    /// below reads .isRunning / .isDone / .progress / .filesCopied so
    /// the subscription is meaningful.
    @EnvironmentObject var rescue: VolumeRescueOperation
    /// Opens the standalone "Compare Volumes" window (defined in
    /// VideoScanApp). The chip + the toolbar Compare button both go
    /// through this same affordance; the window is single-instance
    /// (Window not WindowGroup) so repeat clicks bring the existing
    /// window to front rather than spawning new ones.
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if rescue.isRunning {
            chipShell(color: .blue, icon: "doc.on.doc.fill", label: runningLabel)
        } else if rescue.isDone {
            chipShell(color: .green, icon: "checkmark.circle.fill", label: doneLabel)
        }
        // Otherwise: hide. Toolbar width is precious.
    }

    private var runningLabel: String {
        let pct = Int(rescue.progress * 100)
        return "Copy \(pct)% · \(rescue.filesCopied)"
    }

    private var doneLabel: String {
        "Copy done · \(rescue.filesCopied)"
    }

    @ViewBuilder
    private func chipShell(color: Color, icon: String, label: String) -> some View {
        Button {
            openWindow(id: "compare")
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(color)
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                if rescue.isRunning && rescue.progress > 0 {
                    // Tiny ring mirrors the chip pattern Rick already
                    // recognizes from the Dossier chip.
                    MiniRescueRing(progress: rescue.progress, color: color)
                        .frame(width: 14, height: 14)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(color.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(color.opacity(0.35), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help("Volume rescue copy. Click to open Compare and see progress / cancel.")
    }
}

// MARK: - Mini ring (shape mirrors DossierToolbarChip's MiniRing)

private struct MiniRescueRing: View {
    let progress: Double
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.22), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0, min(progress, 1)))
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.3), value: progress)
        }
    }
}
