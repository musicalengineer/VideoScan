import SwiftUI
import AppKit

// MARK: - FrameRipperSheet
//
// Modal sheet shown while FrameRipper is sampling + saving. Mirrors the
// shape of CaptionProgressSheet (and other in-app progress sheets) so
// the visual language is consistent.
//
// Two phases visible to the user:
//   1. SAMPLING — "Scanning 12 of 60 — 4 face frame(s) so far"
//   2. SAVING   — "Saving 7 of 30…"
//
// Terminal states:
//   - DONE → green checkmark + "Reveal in Finder" + Close
//   - ERROR → red x + Close
//   - CANCELLED → orange slash + Close

struct FrameRipperSheet: View {
    @ObservedObject var ripper: FrameRipper
    @Binding var isPresented: Bool

    /// 0…1 derived from ripper's two-phase counters. Sampling
    /// contributes the first half of the bar, saving the second.
    private var fraction: Double {
        let candidateProgress: Double = {
            guard ripper.candidateTarget > 0 else { return 0 }
            return min(1.0, Double(ripper.framesScanned) / Double(ripper.candidateTarget))
        }()
        let saveProgress: Double = {
            guard ripper.saveTarget > 0 else { return 0 }
            return min(1.0, Double(ripper.framesSaved) / Double(ripper.saveTarget))
        }()
        // Sampling = 0…0.5, saving = 0.5…1.0. So users see early progress
        // even before the save phase starts.
        return candidateProgress * 0.5 + saveProgress * 0.5
    }

    private var isTerminal: Bool {
        !ripper.isRunning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            // Title row
            HStack(spacing: 8) {
                if ripper.lastError != nil {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .font(.title2)
                } else if !ripper.isRunning && ripper.completedDestination != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.title2)
                } else if !ripper.isRunning {
                    Image(systemName: "slash.circle")
                        .foregroundStyle(.orange)
                        .font(.title2)
                } else {
                    Image(systemName: "wand.and.stars")
                        .foregroundStyle(.tint)
                        .font(.title2)
                }
                Text("Convert to Images")
                    .font(.title3.weight(.semibold))
            }

            // Progress bar (smooth in both phases).
            ProgressView(value: fraction)
                .progressViewStyle(.linear)

            // Status line — from FrameRipper.statusText.
            Text(ripper.statusText)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            // Counters row — sampling + saving + face hits.
            HStack(spacing: 12) {
                Text("\(ripper.framesScanned) of \(ripper.candidateTarget) scanned")
                    .font(.system(size: 12, design: .monospaced))
                Text("·").foregroundStyle(.tertiary)
                Text("\(ripper.framesSaved) of \(ripper.saveTarget) saved")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.green)
            }
            .foregroundStyle(.primary)

            // Error display
            if let err = ripper.lastError {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .padding(.vertical, 4)
            }

            // Buttons row
            HStack {
                if isTerminal, let dest = ripper.completedDestination {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([dest])
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                }
                Spacer()
                if ripper.isRunning {
                    Button(role: .destructive) {
                        ripper.cancel()
                    } label: {
                        Text(ripper.isCancelling ? "Cancelling…" : "Cancel")
                    }
                    .disabled(ripper.isCancelling)
                } else {
                    Button("Close") { isPresented = false }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
