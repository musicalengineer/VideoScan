// DeleteConfirmedJunkSheet.swift
// Confirmation + result sheets for the Delete Confirmed Junk workflow.
// Surfaced from CatalogToolbar's "Delete Confirmed Junk…" entry point.
// The actual filesystem op is in VideoScanModel+JunkDelete.swift; this
// file is pure presentation + the user's pick of trash vs permanent.

import SwiftUI

// MARK: - Confirmation Sheet
//
// First-stage sheet. Shows the count + total size of confirmed-junk
// records and exposes three buttons: Cancel / Move to Trash / Delete
// Permanently. The destructive button is styled with the .destructive
// role so AppKit gives it the right confirmation-dialog affordance.
//
// `onAct` is invoked with the user's mode pick. The parent owns the
// sheet's `isPresented` binding — we just dismiss via `dismiss()` after
// the choice is made; the parent will swap to the result sheet.

struct DeleteConfirmedJunkConfirmSheet: View {
    let count: Int
    let totalBytes: Int64
    let onCancel: () -> Void
    let onAct: (VideoScanModel.JunkDeletionMode) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Delete Confirmed Junk", systemImage: "trash.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.red)

            Text("\(count) file\(count == 1 ? "" : "s") marked Confirmed Junk")
                .font(.body.weight(.medium))
            Text("Total size: \(Formatting.humanSize(totalBytes))")
                .font(.callout)
                .foregroundStyle(.secondary)

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

                Button("Delete Permanently", role: .destructive) {
                    onAct(.permanent)
                    dismiss()
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

// MARK: - Result Sheet
//
// Shown after the delete pass completes. Renders the per-bucket counts
// (succeeded / alreadyMissing / failed) plus per-record errors so the
// user can see which files refused to move and why.
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
                        Text("\(actionVerb) \(result.succeeded) file\(result.succeeded == 1 ? "" : "s") (\(Formatting.humanSize(bytesSucceeded)) \(destinationPhrase)")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
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
        .frame(width: 460)
    }
}
