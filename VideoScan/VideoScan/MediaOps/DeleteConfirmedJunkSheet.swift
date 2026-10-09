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
// Shown after the pass completes. Renders the report built ONCE from the
// result (JunkDeletionReport): one sentence per bucket, then EVERY file
// that did not move with its reason — a lazy list, never truncated, never
// "see the app log" (design R6).

struct DeleteConfirmedJunkResultSheet: View {
    let report: JunkDeletionReport
    let bytesMoved: Int64

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(report.hasNotes ? "Done \u{2014} with notes" : "Done",
                  systemImage: report.hasNotes ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(report.hasNotes ? .orange : .green)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(report.summary.enumerated()), id: \.offset) { index, sentence in
                    Text(index == 0 && report.movedCount > 0
                         ? "\(sentence) (\(Formatting.humanSize(bytesMoved)))"
                         : sentence)
                        .font(.callout)
                }
            }

            if report.hasNotes {
                Text("These stayed where they are:")
                    .font(.callout.weight(.medium))
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(report.lines) { line in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(line.filename)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                Text(line.reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .padding(8)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
            }

            HStack {
                Spacer()
                Button("OK") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

