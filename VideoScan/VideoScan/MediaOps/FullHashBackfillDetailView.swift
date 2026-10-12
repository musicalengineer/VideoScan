// FullHashBackfillDetailView.swift
// Double-click detail for the "Fill in full hashes" MFO row: the running
// totals, one line per drive (N of M, reading / finished / disconnected),
// every file that could not be done with its reason, then the first files
// hashed (the job keeps at most FullHashBackfillJob.sampleCap). Pure
// presentation over the job's published arrays — no model access, no I/O,
// nothing O(catalog) in the body.

import SwiftUI

struct FullHashBackfillDetailView: View {
    @ObservedObject var job: FullHashBackfillJob

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(job.totals.line)
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(job.lanes) { laneRow($0) }
            if job.problems.isEmpty && job.sample.isEmpty {
                Text(job.state.isActive ? "Nothing done yet…" : "No file needed a full hash.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(job.problems) { row($0) }
                        ForEach(job.sample) { row($0) }
                        let shown = job.sample.count
                        if job.totals[.hashed] > shown {
                            Text("…and \((job.totals[.hashed] - shown).formatted()) more hashed")
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
        .accessibilityIdentifier("mfo.fillFullHashes.detail")
    }

    private func laneRow(_ lane: FullHashBackfillLaneStatus) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(lane.label)
                .font(.system(size: 12, weight: .medium))
            Text("\(lane.done.formatted()) of \(lane.planned.formatted()) · \(Self.words(lane.phase))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private func row(_ item: FullHashBackfillItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: Self.icon(item.result))
                .foregroundStyle(Self.color(item.result))
                .font(.system(size: 12))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(item.filename)  ·  \(item.drive)")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.path)
                Text(item.result == .hashed ? item.detail : "\(item.result.words) — \(item.detail)")
                    .font(.system(size: 11))
                    .foregroundStyle(item.result == .unreadable ? Self.color(.unreadable) : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    static func words(_ phase: FullHashBackfillLaneStatus.Phase) -> String {
        switch phase {
        case .waiting: return "waiting"
        case .reading: return "reading"
        case .finished: return "finished"
        case .disconnected: return "drive not connected"
        case .stopped: return "stopped"
        }
    }

    static func icon(_ result: FullHashBackfillResult) -> String {
        switch result {
        case .hashed: return "checkmark.circle.fill"
        case .unreadable, .changedDuringRead: return "xmark.octagon.fill"
        case .driveNotConnected: return "externaldrive.badge.xmark"
        case .missing: return "questionmark.folder"
        case .noVolumeIdentity, .recordChanged: return "arrow.triangle.2.circlepath"
        }
    }

    static func color(_ result: FullHashBackfillResult) -> Color {
        switch result {
        case .hashed: return Color(red: 0.10, green: 0.45, blue: 0.25)
        case .unreadable, .changedDuringRead: return Color(red: 0.80, green: 0.10, blue: 0.10)
        default: return .secondary
        }
    }
}
