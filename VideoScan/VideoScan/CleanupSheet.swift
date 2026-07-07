import SwiftUI

// MARK: - Clean Up Video confirmation sheet
//
// Presented via `.sheet(item:)` from the catalog row's "Clean Up Video"
// submenu (NEVER chained isPresented sheets — documented antipattern).
// Shows, in plain family language: what the recipe does step by step,
// that the original is never changed, and exactly where the cleaned copy
// will go. "Clean Up" starts a CleanupJob in the Media File Operations
// window, which owns the determinate progress bar + Cancel.
//
// Text sizes are deliberately generous (.title2/.body, nothing smaller
// than .callout) — large readable text is an accessibility need here,
// not polish.

/// A pending sheet presentation. Fresh ID per menu click so choosing a
/// different recipe while a prior sheet is dismissing creates a new
/// presentation cycle (same shape as TranscodeRequest).
struct CleanupRequest: Identifiable {
    let id = UUID()
    let record: VideoRecord
    let recipe: CleanupRecipe
}

struct CleanupSheet: View {
    @EnvironmentObject private var fileOpsCenter: MediaFileOperationsCenter
    // Forwarded to MediaFileOperationsCenter when the cleanup job starts
    // (same intentional forwarding as TranscodeSheet).
    // vs-lint:disable-next vs-env-object-unused
    @EnvironmentObject private var model: VideoScanModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    let request: CleanupRequest

    /// Computed ONCE at init (one directory listing per collision) — not
    /// in `body`, which SwiftUI re-evaluates freely.
    private let destinationURL: URL

    init(request: CleanupRequest) {
        self.request = request
        self.destinationURL = CleanupJob.cleanedOutputURL(
            forSourcePath: request.record.fullPath)
    }

    /// Whether the deinterlace step will auto-skip (source already
    /// progressive) — surfaced so the step list is honest.
    private var deinterlaceSkipped: Bool {
        CleanupFFmpegEngine.isProgressive(fieldOrder: request.record.scanType)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.recipe.displayName)
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("cleanupSheet.title")

            Text(request.record.filename)
                .font(.body.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)

            Text(request.recipe.familyDescription)
                .font(.body)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("What it will do")
                        .font(.headline)
                    ForEach(request.recipe.steps) { step in
                        stepRow(step)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text("Your original file is never changed.")
                            .font(.body.weight(.medium))
                    } icon: {
                        Image(systemName: "lock.shield.fill")
                            .foregroundColor(.green)
                    }
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("The cleaned copy will be saved next to it as:")
                                .font(.body)
                            Text(destinationURL.lastPathComponent)
                                .font(.body.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    } icon: {
                        Image(systemName: "doc.badge.plus")
                            .foregroundColor(.accentColor)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Button("Clean Up") { startCleanup() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
                    .accessibilityIdentifier("cleanupSheet.cleanUpButton")
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 560)
    }

    @ViewBuilder
    private func stepRow(_ step: CleanupStep) -> some View {
        let skipped = step.kind == .deinterlace && deinterlaceSkipped
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: skipped ? "minus.circle" : "checkmark.circle.fill")
                .foregroundColor(skipped ? .secondary : .accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.familyLabel)
                    .font(.body)
                    .foregroundColor(skipped ? .secondary : .primary)
                if skipped {
                    Text("Skipped — this video has no comb lines to fix.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func startCleanup() {
        fileOpsCenter.startCleanup(record: request.record,
                                   recipe: request.recipe,
                                   model: model)
        dismiss()
        // Same handoff TranscodeSheet uses: open the operations window
        // (progress + Cancel live there) after the sheet's dismissal
        // animation starts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            openWindow(id: "combine")
        }
    }
}
