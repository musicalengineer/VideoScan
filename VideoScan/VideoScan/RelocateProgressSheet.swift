import SwiftUI

// MARK: - RelocateProgressSheet
//
// In-flight progress UI surfaced while `model.isRelocating == true`.
// Two display modes depending on what the run is doing:
//
//   1. Copy phase active (toMigrate.count > 0): big linear progress bar
//      driven by `dashboard.relocateCompleted / dashboard.relocateTotal`,
//      currentFile leader, verified counter. The usual "I see something
//      happening" UI.
//
//   2. Catalog-only run (Bucket B/D/E, no toMigrate): a "Verifying
//      audit trail…" spinner because there's nothing to copy. The
//      runRelocate min-visible padding (800ms floor) keeps this on
//      screen long enough to register, even on a 50-record Bucket-E
//      sweep that completes in <100ms.
//
// Dismisses automatically when the model transitions out of
// `isRelocating`; the summary sheet pops in its place via
// `pendingRelocateSummary`.

struct RelocateProgressSheet: View {

    @EnvironmentObject var model: VideoScanModel

    // Shadow the dashboard so SwiftUI re-renders on each counter tick.
    @ObservedObject var dashboard: DashboardState

    /// Action the parent passes in to dismiss the sheet without canceling
    /// the underlying job. The job keeps running; the user can now open
    /// the Migrate sheet again and queue a second volume. Status stays
    /// visible in the Migrate Jobs panel toolbar badge.
    var onHide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if dashboard.relocateTotal > 0 {
                progressBlock
            } else {
                idleSpinner
            }
            footer
        }
        .padding(22)
        .frame(minWidth: 500, idealWidth: 540)
        .accessibilityIdentifier("relocateProgress.root")
    }

    private var header: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Migrate in progress")
                .font(.headline)
                .accessibilityIdentifier("relocateProgress.title")
            Spacer()
        }
    }

    /// Hide-not-cancel control row. Lets the user queue another Migrate
    /// while the current one keeps running. Status stays visible via the
    /// Migrate Jobs panel toolbar badge.
    private var footer: some View {
        HStack {
            Spacer()
            Button("Hide", action: onHide)
                .keyboardShortcut(.cancelAction)
                .help("Close this sheet — the job keeps running. Open Migrate Jobs to monitor or add another volume to the queue.")
                .accessibilityIdentifier("relocateProgress.hide")
        }
    }

    /// "Copy is doing work" panel. Bar, leading file, verified counter.
    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The "[N / M] file.mxf" leader line. relocateCompleted
            // covers Bucket B/D/E completions + per-file copies; total
            // is set once at run start.
            HStack {
                Text("[\(dashboard.relocateCompleted) / \(dashboard.relocateTotal)]")
                    .font(.system(.body, design: .monospaced).bold())
                Text(dashboard.relocateCurrentFile.isEmpty
                     ? "(preparing…)"
                     : dashboard.relocateCurrentFile)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("relocateProgress.currentFile")
                Spacer()
            }

            ProgressView(
                value: Double(dashboard.relocateCompleted),
                total: max(Double(dashboard.relocateTotal), 1)
            )
            .progressViewStyle(.linear)
            .accessibilityIdentifier("relocateProgress.bar")

            // Verified counter — each per-file copy that hashes match
            // increments dashboard.relocateSucceeded.
            HStack(spacing: 14) {
                Label("Verified: \(dashboard.relocateSucceeded)",
                      systemImage: "checkmark.shield.fill")
                    .foregroundColor(.green)
                    .font(.caption)
                    .accessibilityIdentifier("relocateProgress.verified")
                if dashboard.relocateSafelyRedundant > 0 {
                    Label("Safe elsewhere: \(dashboard.relocateSafelyRedundant)",
                          systemImage: "shield.checkered")
                        .foregroundColor(.green)
                        .font(.caption)
                }
                if dashboard.relocateSalvageFailed > 0 {
                    Label("Salvage failed: \(dashboard.relocateSalvageFailed)",
                          systemImage: "exclamationmark.octagon.fill")
                        .foregroundColor(.red)
                        .font(.caption)
                }
                Spacer()
            }
        }
    }

    /// Catalog-only run — no copies, just dispositions + audit. Held on
    /// screen by `runRelocate`'s 800ms minimum-visible pad so the user
    /// sees the spinner instead of a flash.
    private var idleSpinner: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Verifying audit trail…")
                .font(.callout)
                .accessibilityIdentifier("relocateProgress.idleLabel")
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
