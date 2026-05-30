import SwiftUI
import AppKit

// MARK: - RelocateSummarySheet
//
// Post-Apply summary surfaced after a real or dry-run Relocate. Replaces
// what used to be a console log dump with a visible, dismissable view
// that demonstrates to the user the media on the source volume is
// accounted for — either copied to dest, adopted in place, redundantly
// safe on another volume, or explicitly flagged as salvage-failed.
//
// Gates the Retire prompt: the §1B retire offer can only fire after this
// sheet's Done button has been pressed (the model's
// `acknowledgeRelocateSummary()` is the single trigger).

struct RelocateSummarySheet: View {

    @EnvironmentObject var model: VideoScanModel
    @Environment(\.dismiss) var dismiss

    /// Snapshot taken at sheet-init time. Owned by parent's
    /// `.sheet(item:)` binding — dismissing + nilling
    /// `pendingRelocateSummary` tears the sheet down cleanly.
    let summary: RelocateSummary

    /// Witness disclosure toggle. Off by default — Rick can expand if
    /// he wants to see the per-pair audit, but the count alone usually
    /// answers "are these copies safe?".
    @State private var showWitnesses: Bool = false

    /// Salvage-failed path disclosure. Off by default — empty unless
    /// the run had failures, so this section often won't even render.
    @State private var showSalvageFailed: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            volumeLine
            countsGrid
            if !summary.witnessSamples.isEmpty {
                witnessSection
            }
            if !summary.salvageFailedPaths.isEmpty {
                salvageFailedSection
            }
            footer
            buttonBar
        }
        .padding(22)
        .frame(minWidth: 560, idealWidth: 600)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 32))
                .foregroundColor(summary.isDryRun ? .blue : .green)
                .accessibilityIdentifier("relocateSummary.icon")
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.isDryRun ? "Dry Run Complete" : "Relocate Complete")
                    .font(.title2.bold())
                    .accessibilityIdentifier("relocateSummary.title")
                if summary.isDryRun {
                    Text("Catalog unchanged — this was a preview.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
    }

    private var volumeLine: some View {
        HStack(spacing: 6) {
            Text(summary.sourceVolumeName).fontWeight(.semibold)
            Text("→")
                .foregroundColor(.secondary)
            Text(summary.destinationDisplay)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .accessibilityIdentifier("relocateSummary.volumeLine")
    }

    private var countsGrid: some View {
        // Suppress zero-count rows so the grid isn't padded with noise.
        // Each row format: leading icon + label + monospaced count + detail.
        VStack(alignment: .leading, spacing: 4) {
            if summary.succeededCount > 0 {
                countRow(icon: "doc.on.doc.fill",
                         color: .green,
                         label: "Succeeded",
                         count: summary.succeededCount,
                         detail: byteString(summary.bytesCopied) + " copied",
                         identifier: "relocateSummary.row.succeeded")
            }
            if summary.adoptedCount > 0 {
                countRow(icon: "tray.and.arrow.down.fill",
                         color: .blue,
                         label: "Adopted",
                         count: summary.adoptedCount,
                         detail: "already at destination",
                         identifier: "relocateSummary.row.adopted")
            }
            if summary.safelyRedundantCount > 0 {
                countRow(icon: "shield.checkered",
                         color: .green,
                         label: "Safely redundant",
                         count: summary.safelyRedundantCount,
                         detail: byteString(summary.safelyRedundantBytes) + " not copied",
                         identifier: "relocateSummary.row.safelyRedundant")
            }
            if summary.sourceMovesCount > 0 {
                countRow(icon: "arrow.left.arrow.right",
                         color: .orange,
                         label: "Source moves",
                         count: summary.sourceMovesCount,
                         detail: "paths rewritten",
                         identifier: "relocateSummary.row.sourceMoves")
            }
            if summary.manuallyDeletedCount > 0 {
                countRow(icon: "trash",
                         color: .secondary,
                         label: "Manually deleted",
                         count: summary.manuallyDeletedCount,
                         detail: "marked, kept for audit",
                         identifier: "relocateSummary.row.manuallyDeleted")
            }
            if summary.salvageFailedCount > 0 {
                countRow(icon: "exclamationmark.octagon.fill",
                         color: .red,
                         label: "Salvage failed",
                         count: summary.salvageFailedCount,
                         detail: "see disclosure below",
                         identifier: "relocateSummary.row.salvageFailed",
                         badge: true)
            }
            if summary.skippedCount > 0 {
                countRow(icon: "forward.end.fill",
                         color: .secondary,
                         label: "Skipped",
                         count: summary.skippedCount,
                         detail: "previously relocated",
                         identifier: "relocateSummary.row.skipped")
            }
        }
        .accessibilityIdentifier("relocateSummary.countsGrid")
    }

    private func countRow(icon: String,
                          color: Color,
                          label: String,
                          count: Int,
                          detail: String,
                          identifier: String,
                          badge: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 22)
            Text(label)
                .frame(width: 150, alignment: .leading)
            Text("\(count)")
                .font(.system(.body, design: .monospaced).bold())
                .frame(width: 60, alignment: .trailing)
                .padding(.vertical, 2)
                .padding(.horizontal, badge ? 6 : 0)
                .background(badge ? Color.red.opacity(0.15) : Color.clear)
                .cornerRadius(4)
            Text(detail)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .accessibilityIdentifier(identifier)
    }

    private var witnessSection: some View {
        // The "show witnesses" disclosure that satisfies Rick's
        // "convinced the media is properly accounted for" requirement —
        // up to 10 sample `source → witness` pairs pulled from the
        // Bucket E audit notes.
        DisclosureGroup(isExpanded: $showWitnesses) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(summary.witnessSamples) { sample in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(sample.sourcePath)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("→")
                            .foregroundColor(.secondary)
                        Text(sample.witnessPath)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.green)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if summary.safelyRedundantCount > summary.witnessSamples.count {
                    Text("… \(summary.safelyRedundantCount - summary.witnessSamples.count) more — see relocate.log")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.top, 4)
            .accessibilityIdentifier("relocateSummary.witnessList")
        } label: {
            Text("Show witnesses (\(summary.witnessSamples.count))")
                .font(.callout)
                .accessibilityIdentifier("relocateSummary.witnessDisclosure")
        }
    }

    private var salvageFailedSection: some View {
        DisclosureGroup(isExpanded: $showSalvageFailed) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(summary.salvageFailedPaths, id: \.self) { path in
                    Text(path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.red)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if summary.salvageFailedCount > summary.salvageFailedPaths.count {
                    Text("… \(summary.salvageFailedCount - summary.salvageFailedPaths.count) more — see relocate.log")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.top, 4)
        } label: {
            Label("Show salvage-failed files (\(summary.salvageFailedCount))",
                  systemImage: "exclamationmark.octagon.fill")
                .foregroundColor(.red)
                .font(.callout)
                .accessibilityIdentifier("relocateSummary.salvageFailedDisclosure")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "clock")
                    .foregroundColor(.secondary)
                Text("Wall clock: \(String(format: "%.1f", summary.elapsedSeconds))s")
                if summary.averageMBps > 0 {
                    Text("(\(String(format: "%.1f", summary.averageMBps)) MB/s)")
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .font(.caption)

            if let snap = summary.snapshotPath {
                HStack {
                    Image(systemName: "doc.zipper")
                        .foregroundColor(.secondary)
                    Text("Pre-relocate snapshot:")
                    Button {
                        // Reveal in Finder. URL form first; falls back
                        // to selectFile if reveal fails for any reason.
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: snap)]
                        )
                    } label: {
                        Text((snap as NSString).lastPathComponent)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("relocateSummary.snapshotLink")
                    Spacer()
                }
                .font(.caption)
            }
        }
    }

    private var buttonBar: some View {
        HStack {
            Spacer()
            Button("Done") {
                // The model's acknowledge() drops the summary AND fires
                // the §1B retire offer (only when applicable + not
                // dry-run). This is the ONLY trigger path for retire now.
                model.acknowledgeRelocateSummary()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return)
            .accessibilityIdentifier("relocateSummary.doneButton")
        }
    }

    // MARK: - Helpers

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
