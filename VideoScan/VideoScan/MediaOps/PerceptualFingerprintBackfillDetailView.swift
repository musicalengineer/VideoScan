// PerceptualFingerprintBackfillDetailView.swift
// Expanded panel for the "Fingerprint pictures (archive first)" row in Media
// File Operations (GH #293 item 1): the running totals, every file that could
// not be done with its reason, then the first results (the job keeps at most
// PerceptualFingerprintBackfillJob.sampleCap). Pure presentation over the
// job's published arrays — no model access, no I/O, nothing O(catalog) in
// the body (the job keeps the lists already split).

import SwiftUI

struct PerceptualFingerprintBackfillDetailView: View {
    @ObservedObject var job: PerceptualFingerprintBackfillJob

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(totalsLine)
                .font(.system(size: 12, weight: .medium))
            if job.problems.isEmpty && job.sample.isEmpty {
                Text(job.state.isActive ? "Nothing done yet…" : "No video needed a fingerprint.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(job.problems) { row($0) }
                        ForEach(job.sample) { row($0) }
                        let shown = job.sample.count
                        if job.totals.stored > shown {
                            Text("…and \(job.totals.stored - shown) more fingerprinted")
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
        .accessibilityIdentifier("mfo.fingerprintBackfill.detail")
    }

    private var totalsLine: String {
        let t = job.totals
        return "\(t.done) of \(t.total) (\(t.archivedTotal) archived first) · "
            + PerceptualFingerprintBackfillJob.summaryCounts(t)
    }

    private func row(_ item: PerceptualFingerprintBackfillJob.Item) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: Self.icon(item.kind))
                .foregroundStyle(Self.color(item.kind))
                .font(.system(size: 12))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.archived ? "\(item.filename)  ·  archive" : item.filename)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.path)
                Text(item.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(item.kind == .failed ? Self.color(.failed) : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    static func icon(_ kind: PerceptualFingerprintBackfillJob.Item.Kind) -> String {
        switch kind {
        case .stored: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .offline: return "externaldrive.badge.xmark"
        case .recordChanged: return "arrow.triangle.2.circlepath"
        }
    }

    static func color(_ kind: PerceptualFingerprintBackfillJob.Item.Kind) -> Color {
        switch kind {
        case .stored: return Color(red: 0.10, green: 0.45, blue: 0.25)
        case .failed: return Color(red: 0.80, green: 0.10, blue: 0.10)
        case .offline, .recordChanged: return .secondary
        }
    }
}
