import SwiftUI
import AppKit

// MARK: - RelocateSummarySheet
//
// Post-Apply summary surfaced after a real or dry-run Relocate. Family-
// friendly tone (per feedback_friendly_language.md) — the user came to
// VideoScan to feel that their old family-media drive's contents are
// accounted for, not to read a forensic surveillance report.
//
// Five headline modes (`RelocateSummaryHeadline`, RelocateSummary.swift):
//   - "Your files are safe"     — nothing copied; every file has a copy on
//                                  a safe, non-Aging drive proven by its
//                                  full SHA-256 now (ContentCopyProof).
//   - "Files copied and verified" — some Bucket A copies happened; the
//                                   rest have proven backups.
//   - "Some files are not proven safe yet" — any copy failed, still at
//                                  its path, not marked, missing from the
//                                  source, or a backup not proven. Never
//                                  "safe", never "retire" (adversarial
//                                  2026-10-26 F1; Codex #150 F1/F2/F5).
//   - "Nothing was copied"       — nothing copied or checked this run.
//   - "Dry-run preview"          — preview only.
// The "retire <drive>" line shows only for the first two.
//
// Drops the auto-retire prompt that used to fire from the Done button —
// instead the sheet ends with "Open the Volumes window to retire <name>
// when ready." plus a button that opens the Volumes window with the
// source pre-selected. The `pendingRetireOffer` machinery is still
// programmatically callable (tests use it) but the UI no longer drives
// it from here.

struct RelocateSummarySheet: View {

    @EnvironmentObject var model: VideoScanModel
    @Environment(\.dismiss) var dismiss
    /// Lets us deep-link into the Volumes window when the user clicks
    /// "Open Volumes window". Cmd+Shift+V also works system-wide; this
    /// button is the in-context shortcut from the summary.
    @Environment(\.openWindow) var openWindow

    /// Snapshot taken at sheet-init time. Owned by parent's
    /// `.sheet(item:)` binding — dismissing + nilling
    /// `pendingRelocateSummary` tears the sheet down cleanly.
    let summary: RelocateSummary

    /// Degraded-witness disclosure toggle. Hidden by default — Rick
    /// wanted the "safe drives only" view as the primary signal.
    @State private var showDegraded: Bool = false

    /// Salvage-failed path disclosure. Off by default — empty unless
    /// the run had failures, so this section often won't even render.
    @State private var showSalvageFailed: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headline
            countsGrid
            if !summary.witnessSamples.isEmpty {
                witnessSection
            }
            if !summary.salvageFailedPaths.isEmpty {
                salvageFailedSection
            }
            volumesWindowCTA
            footer
            buttonBar
        }
        .padding(22)
        .frame(minWidth: 600, idealWidth: 640)
    }

    // MARK: - Sections

    /// Family-friendly title + sub-headline. Picks one of three
    /// modes based on what the run actually did.
    @ViewBuilder
    private var headline: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: headlineIcon)
                .font(.system(size: 36))
                .foregroundColor(headlineIconColor)
                .accessibilityIdentifier("relocateSummary.icon")
            VStack(alignment: .leading, spacing: 6) {
                Text(headlineTitle)
                    .font(.title.bold())
                    .accessibilityIdentifier("relocateSummary.title")
                Text(headlineBody)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("relocateSummary.subtitle")
            }
            Spacer()
        }
    }

    /// The words, icon and retire invitation — a pure value of the summary
    /// (`RelocateSummaryHeadline`, RelocateSummary.swift), pinned by
    /// RelocateSummaryHeadlineTests.
    private var headlineWords: RelocateSummaryHeadline { RelocateSummaryHeadline(summary) }

    private var headlineIcon: String { headlineWords.icon }

    private var headlineIconColor: Color {
        switch headlineWords.tint {
        case .blue: return .blue
        case .green: return .green
        case .orange: return .orange
        }
    }

    private var headlineTitle: String { headlineWords.title }

    /// The conversational sub-headline ("I" instead of "the application",
    /// "safer drives" instead of "redundant storage volumes").
    private var headlineBody: String { headlineWords.body }

    private var countsGrid: some View {
        // Suppress zero-count rows so the grid isn't padded with noise.
        // Each row format: leading icon + label + monospaced count + detail.
        VStack(alignment: .leading, spacing: 4) {
            if summary.succeededCount > 0 {
                countRow(icon: "doc.on.doc.fill",
                         color: .green,
                         label: "Copied and verified",
                         count: summary.succeededCount,
                         detail: byteString(summary.bytesCopied) + " copied to "
                            + summary.destinationDisplay,
                         identifier: "relocateSummary.row.succeeded")
            }
            if summary.adoptedCount > 0 {
                countRow(icon: "tray.and.arrow.down.fill",
                         color: .blue,
                         label: "Already at destination",
                         count: summary.adoptedCount,
                         detail: "adopted in place",
                         identifier: "relocateSummary.row.adopted")
            }
            if summary.safelyBackedUpCount > 0 {
                countRow(icon: "shield.checkered",
                         color: .green,
                         label: "Safely backed up elsewhere",
                         count: summary.safelyBackedUpCount,
                         detail: byteString(summary.safelyRedundantBytes)
                            + " not copied — already safe on other drives",
                         identifier: "relocateSummary.row.safelyRedundant")
            }
            if summary.degradedOnlyCount > 0 {
                countRow(icon: "exclamationmark.triangle.fill",
                         color: .orange,
                         label: "Backed up only on aging/retired drives",
                         count: summary.degradedOnlyCount,
                         detail: "needs attention — see disclosure below",
                         identifier: "relocateSummary.row.degradedOnly",
                         badge: true)
            }
            // Backed up on a safe drive, but the copy is not proven by its
            // full SHA-256 now (Codex #150 F1/F5); degraded-only shown above.
            if summary.unprovenBackupCount - summary.degradedOnlyCount > 0 {
                countRow(icon: "questionmark.circle",
                         color: .orange,
                         label: "Backup not proven",
                         count: summary.unprovenBackupCount - summary.degradedOnlyCount,
                         detail: "no matching full SHA-256 on record, the file changed since, or the drive is Aging",
                         identifier: "relocateSummary.row.backupNotProven",
                         badge: true)
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
                         label: "Missing from source",
                         count: summary.manuallyDeletedCount,
                         detail: "marked, kept for audit",
                         identifier: "relocateSummary.row.manuallyDeleted")
            }
            if summary.notMarkedCount > 0 {
                countRow(icon: "pause.circle",
                         color: .orange,
                         label: "Not marked",
                         count: summary.notMarkedCount,
                         detail: "the catalog could not save — the next Migrate asks again",
                         identifier: "relocateSummary.row.notMarked")
            }
            if summary.stillThereCount > 0 {
                countRow(icon: "questionmark.folder",
                         color: .orange,
                         label: "Still at their path",
                         count: summary.stillThereCount,
                         detail: "not matched, not marked, not copied — rescan, then Migrate again",
                         identifier: "relocateSummary.row.stillThere")
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
                         detail: "previously migrated",
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
                .frame(width: 250, alignment: .leading)
            Text("\(count)")
                .font(.system(.body, design: .monospaced).bold())
                .frame(width: 60, alignment: .trailing)
                .padding(.vertical, 2)
                .padding(.horizontal, badge ? 6 : 0)
                .background(badge ? color.opacity(0.15) : Color.clear)
                .cornerRadius(4)
            Text(detail)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .accessibilityIdentifier(identifier)
    }

    /// Witness section with two parts:
    ///   - Always-visible: safe witnesses (sorted by safety score).
    ///   - Disclosure: degraded witnesses (retired/unreliable hosts),
    ///                  greyed and tagged.
    private var witnessSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Section header — counts split safe vs degraded.
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Safely backed up elsewhere")
                    .font(.callout.weight(.medium))
                Text("\(summary.safelyBackedUpCount)")
                    .font(.system(.callout, design: .monospaced).bold())
                if summary.degradedOnlyCount > 0 {
                    Text("·")
                        .foregroundColor(.secondary)
                    Text("\(summary.degradedOnlyCount) degraded")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                Spacer()
            }
            .accessibilityIdentifier("relocateSummary.witnessHeader")

            // Safe witnesses come first, each rendered with the host
            // volume's role/trust badge.
            ForEach(safeSamples) { sample in
                witnessRow(sample, demoted: false)
            }

            // Degraded witnesses go under a "See all matches" disclosure.
            if !degradedSamples.isEmpty {
                DisclosureGroup(isExpanded: $showDegraded) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(degradedSamples) { sample in
                            witnessRow(sample, demoted: true)
                        }
                    }
                    .padding(.top, 4)
                    .accessibilityIdentifier("relocateSummary.degradedList")
                } label: {
                    Text("See all matches (\(degradedSamples.count) on aging/retired drives)")
                        .font(.caption)
                        .accessibilityIdentifier("relocateSummary.degradedDisclosure")
                }
            }

            // "And N more" hint when the sample is capped.
            if summary.safelyRedundantCount > summary.witnessSamples.count {
                Text("… \(summary.safelyRedundantCount - summary.witnessSamples.count) more — see relocate.log")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    // Filename `relocate.log` is intentional (log file paths
                    // are not part of the user-facing rename).
            }
        }
        .padding(10)
        .background(Color.green.opacity(0.04))
        .cornerRadius(6)
    }

    /// One safe-vs-degraded witness row. `demoted` styles the row grey +
    /// adds the `(retired)` / `(unreliable)` tag.
    private func witnessRow(_ sample: RelocateSummary.WitnessSample,
                             demoted: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: demoted ? "exclamationmark.triangle" : "checkmark.circle.fill")
                .foregroundColor(demoted ? .orange : .green)
                .font(.caption)
                .frame(width: 14)
            // Host-volume label leads — that's the "where is it safe?"
            // signal Rick wanted to lead with.
            Text(sample.witnessVolumeLabel)
                .font(.system(.caption, design: .monospaced).bold())
                .foregroundColor(demoted ? .secondary : .primary)
            Text("·")
                .foregroundColor(.secondary)
            Text(sample.witnessRole.rawValue)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text("·")
                .foregroundColor(.secondary)
            Text(sample.witnessTrust.rawValue)
                .font(.caption2)
                .foregroundColor(.secondary)
            if demoted {
                Text(sample.witnessIsRetired ? "(retired)" : "(unreliable)")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
            Spacer()
            Text((sample.witnessPath as NSString).lastPathComponent)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .opacity(demoted ? 0.7 : 1.0)
        .accessibilityIdentifier(demoted
                                 ? "relocateSummary.witnessRow.demoted"
                                 : "relocateSummary.witnessRow.safe")
    }

    private var safeSamples: [RelocateSummary.WitnessSample] {
        summary.witnessSamples.filter { $0.isSafe }
    }

    private var degradedSamples: [RelocateSummary.WitnessSample] {
        summary.witnessSamples.filter { !$0.isSafe }
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

    /// "Open the Volumes window to retire <name> when ready." — replaces
    /// the auto-retire prompt that used to fire from the Done button.
    /// Suppressed on dry-run + on runs that left records un-disposed.
    @ViewBuilder
    private var volumesWindowCTA: some View {
        if headlineWords.invitesRetire {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundColor(.secondary)
                // Interpolated Text keeps the bold volume name; `Text + Text`
                // is deprecated in macOS 26.
                Text("Open the Volumes window to retire \(Text(summary.sourceVolumeName).font(.body.bold()).foregroundColor(.primary)) when you're ready.")
                    .foregroundColor(.secondary)
                Spacer()
            }
            .font(.callout)
            .padding(.top, 4)
            .accessibilityIdentifier("relocateSummary.volumesCTA")
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
                    Text("Pre-migrate snapshot:")
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
            // "Open Volumes window" — the replacement for the auto-retire
            // prompt. Pre-selects the source volume via
            // `pendingVolumesSelectionID` (see VolumesWindow.onAppear).
            // Suppressed on dry-run.
            if !summary.isDryRun {
                Button("Open Volumes window") {
                    if let target = model.scanTargets.first(
                        where: { $0.searchPath == summary.sourceVolumeRootPath }
                    ) {
                        model.pendingVolumesSelectionID = target.id
                    }
                    openWindow(id: "volumes")
                    model.acknowledgeRelocateSummary()
                    dismiss()
                }
                .accessibilityIdentifier("relocateSummary.openVolumesButton")
            }
            Button("Done") {
                // No longer fires retire offer — feedback_friendly_language.md
                // calls for the Volumes window to be the retire surface.
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
        // Rick 2026-08-18: one app-wide decimal formatter (Finder / df base).
        MediaBytes.display(bytes)
    }
}
