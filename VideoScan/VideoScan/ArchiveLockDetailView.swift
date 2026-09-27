// ArchiveLockDetailView.swift
// Expanded panel for the one-time "Lock files already in the archive" row in Media File
// Operations: the totals, every failed / skipped file with its reason, then
// the first results (the job keeps at most ArchiveLockJob.sampleCap). Pure
// presentation over the job's published arrays — no model access, no I/O,
// nothing O(archive) in the body (the job keeps the lists already split).

import SwiftUI

struct ArchiveLockDetailView: View {
    @ObservedObject var job: ArchiveLockJob

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(totalsLine)
                .font(.system(size: 12, weight: .medium))
            if job.problems.isEmpty && job.sample.isEmpty {
                Text(job.state.isActive ? "Nothing done yet…" : "No archived files were listed in the manifest.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(job.problems) { row($0) }
                        ForEach(job.sample) { row($0) }
                        let shown = job.sample.count
                        let ok = job.totals.changed + job.totals.already
                        if ok > shown {
                            Text("…and \(ok - shown) more locked or already locked")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color(NSColor.textBackgroundColor).opacity(0.5)))
    }

    private var totalsLine: String {
        let t = job.totals
        return "\(t.done) of \(t.total) · " + ArchiveLockJob.summaryLine(t)
    }

    private func row(_ item: ArchiveLockJob.Item) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: Self.icon(item.kind))
                .foregroundStyle(Self.color(item.kind))
                .font(.system(size: 12))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.relPath)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(item.kind == .failed ? Self.color(.failed) : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    static func icon(_ kind: ArchiveLockJob.Item.Kind) -> String {
        switch kind {
        case .changed: return "lock.fill"
        case .already: return "lock"
        case .failed: return "xmark.octagon.fill"
        case .skipped: return "minus.circle"
        case .busy: return "hourglass"
        }
    }

    static func color(_ kind: ArchiveLockJob.Item.Kind) -> Color {
        switch kind {
        case .changed: return Color(red: 0.10, green: 0.45, blue: 0.25)
        case .already: return .secondary
        case .failed: return Color(red: 0.80, green: 0.10, blue: 0.10)
        case .skipped: return .secondary
        case .busy: return .orange
        }
    }
}
