// CleanupTrashJobDetailView.swift
// Double-click detail for the Cleanup MFO row: the running totals, then
// every file with its outcome and reason — files that stayed first (they
// are the ones that need reading), then the ones that moved. Pure
// presentation over the job's published arrays; nothing O(catalog).

import SwiftUI

struct CleanupTrashJobDetailView: View {
    @ObservedObject var job: CleanupTrashJob

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(job.totals.line)
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Text("“Moved” means moved to the Finder Trash on that file's drive — Put Back restores it. Nothing is freed until you empty the Trash yourself.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if job.items.isEmpty {
                Text(job.state.isActive ? "Nothing done yet…" : "No file was reached.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(job.items.filter { $0.outcome != .moved }) { row($0) }
                        ForEach(job.items.filter { $0.outcome == .moved }) { row($0) }
                    }
                }
                .frame(maxHeight: 300)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color(NSColor.textBackgroundColor).opacity(0.5)))
        .accessibilityIdentifier("mfo.cleanupTrash.detail")
    }

    private func row(_ item: CleanupTrashItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(item.outcome.rawValue)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Self.tint(item.outcome))
                .frame(width: 66, alignment: .leading)
            Text(item.filename)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(item.path)
            Text(item.lane == .copy ? "copy" : "junk")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if !item.reason.isEmpty {
                Text(item.reason)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }

    static func tint(_ o: CleanupTrashItem.Outcome) -> Color {
        switch o {
        case .moved: return .green
        case .held: return .orange
        case .failed: return .red
        case .missing, .cancelled: return .secondary
        }
    }
}
