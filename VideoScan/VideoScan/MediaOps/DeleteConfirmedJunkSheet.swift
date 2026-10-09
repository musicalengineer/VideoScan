// DeleteConfirmedJunkSheet.swift
// Confirmation + result sheets for Triage's Delete Junk. The filesystem op
// is in VideoScanModel+JunkDelete.swift; the frozen set is in
// VideoScanModel+JunkTrashSnapshot.swift; this file is pure presentation.

import SwiftUI

// MARK: - Confirmation Sheet
//
// Shows the FROZEN snapshot (design R1, 2026-10-09): the files that will
// move to the Trash, the ones on drives that aren't connected (skipped),
// and the ones held back, with the reason. Every number is a stored value
// of the snapshot — nothing is computed in the body. Move to Trash acts on
// exactly this snapshot; there is no other button that removes anything
// (Trash only, ruling 2026-10-09).
//
// The parent owns the `.sheet(item:)` binding; the Move button doesn't call
// dismiss() — the parent swaps to the result sheet when the pass is done.

struct DeleteConfirmedJunkConfirmSheet: View {
    let snapshot: VideoScanModel.JunkTrashSnapshot
    let onCancel: () -> Void
    let onAct: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Move Confirmed Junk to Trash", systemImage: "trash")
                .font(.title2.weight(.semibold))

            Text("\(snapshot.count) file\(snapshot.count == 1 ? "" : "s") marked Confirmed Junk:")
                .font(.body.weight(.medium))

            VStack(alignment: .leading, spacing: 4) {
                line(icon: "checkmark.circle.fill", tint: .green,
                     "\(snapshot.moveCount) will move to the Trash (\(Formatting.humanSize(snapshot.moveBytes)))")
                if snapshot.offlineCount > 0 {
                    line(icon: "nosign", tint: .secondary,
                         "\(snapshot.offlineCount) on drives that aren't connected \u{2014} skipped")
                }
                ForEach(Array(snapshot.heldGroups.enumerated()), id: \.offset) { _, group in
                    line(icon: "hand.raised.fill", tint: .orange,
                         "\(group.count) held back \u{2014} \(group.reason)")
                }
            }
            .padding(.leading, 4)

            if snapshot.moveCount == 0 {
                Text("Nothing to move right now.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            Text("Each file is checked again just before it moves: if it changed, was replaced, or is no longer marked Confirmed Junk, it stays where it is and is listed with the reason. Empty the Trash yourself when you are sure.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Cancel", role: .cancel) {
                    onCancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Move \(snapshot.moveCount) to Trash") {
                    onAct()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(snapshot.moveCount == 0)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func line(icon: String, tint: Color, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.callout)
        }
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
