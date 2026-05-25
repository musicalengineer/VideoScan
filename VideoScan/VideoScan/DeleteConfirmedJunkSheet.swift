// DeleteConfirmedJunkSheet.swift
// Confirmation + result sheets for the Delete Confirmed Junk workflow.
// Surfaced from CatalogToolbar's "Delete Confirmed Junk…" entry point.
// The actual filesystem op is in VideoScanModel+JunkDelete.swift; this
// file is pure presentation + the user's pick of trash vs permanent.

import SwiftUI

// MARK: - Confirmation Sheet
//
// First-stage sheet. Shows a breakdown of the confirmed-junk selection
// split by volume reachability — currently-reachable rows that will be
// acted on, and offline rows that will be skipped until the user remounts
// their drives. Three buttons: Cancel / Move to Trash / Delete
// Permanently. The destructive button is styled with the .destructive
// role so AppKit gives it the right confirmation-dialog affordance.
//
// `onAct` is invoked with the user's mode pick. The parent owns the
// sheet's `isPresented` binding — we just dismiss via `dismiss()` after
// the choice is made; the parent will swap to the result sheet.
//
// Offline-aware (feature/triage-offline-aware, 2026-05-25):
//  - The split is computed ONCE in `init` using
//    VideoScanModel.splitByReachability, which is backed by a 5s cache.
//    Cheap; no repeated stat() calls as SwiftUI re-renders the sheet.
//  - If zero rows are currently reachable, the Move/Delete buttons are
//    disabled and a friendly remount message is shown — there's nothing
//    to do until a drive comes back.

struct DeleteConfirmedJunkConfirmSheet: View {
    let records: [VideoRecord]
    let onCancel: () -> Void
    let onAct: (VideoScanModel.JunkDeletionMode) -> Void

    @Environment(\.dismiss) private var dismiss

    // Computed once at sheet-open. SwiftUI's struct re-init across renders
    // would normally recompute this every body evaluation, but the
    // VolumeReachability 5s cache absorbs that — the second-through-nth
    // calls are O(1) lookups into the per-volume hash. Still, snapshot
    // into a stored `let` via init() so the math is obviously single-shot.
    private let split: VideoScanModel.ConfirmedJunkSplit

    // Total count is `records.count` (matches what the caller showed in
    // the toolbar badge). Reachable/offline are derived from the split.
    private var totalCount: Int { records.count }
    private var reachableCount: Int { split.reachable.count }
    private var offlineCount: Int { split.offline.count }
    private var reachableBytes: Int64 { split.reachableBytes }

    init(
        records: [VideoRecord],
        onCancel: @escaping () -> Void,
        onAct: @escaping (VideoScanModel.JunkDeletionMode) -> Void
    ) {
        self.records = records
        self.onCancel = onCancel
        self.onAct = onAct
        self.split = VideoScanModel.splitByReachability(records)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Delete Confirmed Junk", systemImage: "trash.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.red)

            Text("\(totalCount) record\(totalCount == 1 ? "" : "s") marked Confirmed Junk:")
                .font(.body.weight(.medium))

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("\(reachableCount) currently reachable")
                        .font(.callout)
                    Text("(will be deleted)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "nosign")
                        .foregroundStyle(.secondary)
                    Text("\(offlineCount) on offline volume\(offlineCount == 1 ? "" : "s")")
                        .font(.callout)
                    Text("(will be skipped — remount their drives to delete later)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 4)

            if reachableCount > 0 {
                Text("Total size of reachable: \(Formatting.humanSize(reachableBytes))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                // Friendly nudge — no actionable rows in this batch. Keep
                // it factual; the user isn't doing anything wrong, the
                // drives just aren't mounted right now.
                Text("Nothing to delete right now — mount the relevant volumes and try again.")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.top, 2)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("These files cannot be undeleted from the catalog — the catalog row stays, with a deletion timestamp — but the files themselves:")
                    .font(.callout)

                HStack(alignment: .top, spacing: 6) {
                    Text("•").foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text("Move to Trash").font(.callout.weight(.semibold))
                        Text("Recoverable from Finder. Space freed when Trash is emptied.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(alignment: .top, spacing: 6) {
                    Text("•").foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text("Delete Permanently").font(.callout.weight(.semibold))
                        Text("Gone immediately. Not recoverable from the app.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)

            HStack {
                Button("Cancel", role: .cancel) {
                    onCancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Move to Trash") {
                    onAct(.toTrash)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(reachableCount == 0)

                Button("Delete Permanently", role: .destructive) {
                    onAct(.permanent)
                    dismiss()
                }
                .disabled(reachableCount == 0)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

// MARK: - Result Sheet
//
// Shown after the delete pass completes. Renders the per-bucket counts
// (succeeded / skippedOffline / alreadyMissing / failed) plus per-record
// errors so the user can see which files refused to move and why.
//
// Mode is passed in so the success label can read either "Moved N files
// to Trash" or "Deleted N files permanently". We also pin the total
// successful bytes for the size summary — computed by the parent from
// the input records (Note: not from the result; the result doesn't
// re-carry the records that succeeded, only those that failed).

struct DeleteConfirmedJunkResultSheet: View {
    let mode: VideoScanModel.JunkDeletionMode
    let result: VideoScanModel.JunkDeletionResult
    let bytesSucceeded: Int64

    @Environment(\.dismiss) private var dismiss

    private var actionVerb: String {
        switch mode {
        case .toTrash:   return "Moved"
        case .permanent: return "Deleted"
        }
    }

    private var destinationPhrase: String {
        switch mode {
        case .toTrash:   return "to Trash"
        case .permanent: return "permanently"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Done", systemImage: result.failed.isEmpty
                  ? "checkmark.seal.fill"
                  : "exclamationmark.triangle.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(result.failed.isEmpty ? .green : .orange)

            VStack(alignment: .leading, spacing: 6) {
                if result.succeeded > 0 {
                    Label {
                        Text("\(actionVerb) \(result.succeeded) file\(result.succeeded == 1 ? "" : "s") (\(Formatting.humanSize(bytesSucceeded))) \(destinationPhrase)")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                if result.skippedOffline > 0 {
                    Label {
                        Text("\(result.skippedOffline) skipped: on offline volume\(result.skippedOffline == 1 ? "" : "s")")
                    } icon: {
                        Image(systemName: "nosign")
                            .foregroundStyle(.secondary)
                    }
                }

                if result.alreadyMissing > 0 {
                    Label {
                        Text("\(result.alreadyMissing) file\(result.alreadyMissing == 1 ? " was" : "s were") already missing (catalog updated)")
                    } icon: {
                        Image(systemName: "questionmark.circle.fill")
                            .foregroundStyle(.yellow)
                    }
                }

                if !result.failed.isEmpty {
                    Label {
                        Text("\(result.failed.count) file\(result.failed.count == 1 ? "" : "s") failed:")
                    } icon: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                    // Capped at first 8 errors; if the user really wants the
                    // full list we punt them to the app log (line emitted by
                    // deleteConfirmedJunk). Keeps the sheet a manageable
                    // size for a worst-case batch with many failures.
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(result.failed.prefix(8).enumerated()), id: \.offset) { _, item in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.record.filename)
                                        .font(.callout.weight(.medium))
                                        .lineLimit(1)
                                    Text(item.error.localizedDescription)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            if result.failed.count > 8 {
                                Text("…and \(result.failed.count - 8) more (see app log)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .italic()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                    .padding(8)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(6)
                }
            }

            HStack {
                Spacer()
                Button("OK") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
