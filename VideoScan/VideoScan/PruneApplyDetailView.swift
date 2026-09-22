// PruneApplyDetailView.swift
// The expanded "Move N to Trash" row in Media File Operations: a header
// with the counts and the time left, then one line per copy: file · size
// · state chip · reason (held copies say WHY, in the row and in the log).
// Read-only presentation over the job's published rows — no catalog
// lookup, no media work; the only O(n) is the rows themselves, capped.

import SwiftUI

struct PruneApplyDetailView: View {
    @ObservedObject var job: PruneApplyJob

    /// Rows drawn at most — a batch is bounded by the checklist (hundreds),
    /// but the cap keeps the view honest either way.
    static let visibleCap = 2_000

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !job.rows.isEmpty {
                let visible = job.rows.prefix(Self.visibleCap)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section(header: PruneApplyTableHeader()) {
                            ForEach(visible) { row in
                                PruneApplyRowView(row: row)
                                Divider()
                            }
                            if job.rows.count > visible.count {
                                Text("… and \(job.rows.count - visible.count) more")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .padding(PruneApplyTableLayout.rowPadding)
                            }
                        }
                    }
                }
                .frame(maxHeight: 520)
                .background(RoundedRectangle(cornerRadius: 10)
                    .fill(Color(NSColor.controlBackgroundColor)))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(0.14)))
            } else {
                Text(job.isQueued
                     ? "Waiting its turn — nothing is checked or moved until the batch before finishes. Every copy is checked when this batch starts."
                     : (job.state.isActive ? "Working out what may go…" : "Nothing was moved."))
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(Color(NSColor.textBackgroundColor).opacity(0.5)))
        .accessibilityIdentifier("mfo.pruneCopies.detail")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("TRASH")
                    .font(Font.system(size: 12, weight: .heavy))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(MediaFileOperationKind.pruneCopies.badgeColor))
                Text(job.title)
                    .font(.system(size: 15, weight: .semibold))
            }
            Text(job.subtitle)
                .font(.system(size: 14))
                .fixedSize(horizontal: false, vertical: true)
            Text("Each copy goes only after its archive copy is proven current and the copy itself is proven identical to it (a duplicate is read in full; the promotion original is trusted on the stamp Promote bound to it; a version goes on provenance) — and both are re-checked the instant before the move. Anything in doubt is held, and says why.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func chip(_ row: PruneApplyJob.Row) -> (label: String, color: Color) {
        switch row.status {
        case .pending:        return ("Pending", .secondary)
        case .verifying:      return ("Verifying…", .orange)
        case .trashed:        return ("Moved to Trash", .green)
        case .held:           return ("Held: \(row.note)", .red)
        case .failed:         return ("Failed: \(row.note)", .red)
        case .alreadyMissing: return ("Already gone", .secondary)
        case .skippedOffline: return ("Drive not connected", .secondary)
        case .stopped:        return ("Stopped — left alone", .blue)
        case .movedEarlier:   return ("Already moved by the batch before", .secondary)
        }
    }
}

enum PruneApplyTableLayout {
    static let sizeWidth: CGFloat = 84
    static let statusWidth: CGFloat = 420
    static let rowPadding: CGFloat = 10
}

struct PruneApplyTableHeader: View {
    var body: some View {
        HStack(spacing: 0) {
            Text("File").frame(maxWidth: .infinity, alignment: .leading)
            Text("Size").frame(width: PruneApplyTableLayout.sizeWidth, alignment: .trailing)
            Text("Status").frame(width: PruneApplyTableLayout.statusWidth, alignment: .leading)
                .padding(.leading, 12)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, PruneApplyTableLayout.rowPadding)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct PruneApplyRowView: View {
    let row: PruneApplyJob.Row

    var body: some View {
        let chip = PruneApplyDetailView.chip(row)
        HStack(spacing: 0) {
            Text(row.filename)
                .font(.system(size: 13, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(row.path.isEmpty ? row.filename : row.path)
            Text(ByteCountFormatter.string(fromByteCount: row.sizeBytes, countStyle: .file))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: PruneApplyTableLayout.sizeWidth, alignment: .trailing)
            Text(chip.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(chip.color)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: PruneApplyTableLayout.statusWidth, alignment: .leading)
                .padding(.leading, 12)
                .help(row.note.isEmpty ? chip.label : row.note)
        }
        .padding(.horizontal, PruneApplyTableLayout.rowPadding)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(row.status == .verifying ? 0.08 : 0))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.filename): \(chip.label)")
    }
}
