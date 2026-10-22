// AvidIDBackfillDetailView.swift
// Expanded panel for the "Fill in Avid IDs" row in Media File Operations:
// the running totals, every file that could not be read with its reason,
// the stored pairs the new IDs released (each with its reason), then the
// first results (the job keeps at most AvidIDBackfillJob.sampleCap of each).
// Pure presentation over the job's published arrays — no model access, no
// I/O, nothing O(catalog) in the body.

import SwiftUI

struct AvidIDBackfillDetailView: View {
    @ObservedObject var job: AvidIDBackfillJob

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(job.totals.done) of \(job.totals.total) · " + AvidIDBackfillJob.summaryCounts(job.totals))
                .font(.system(size: 12, weight: .medium))
            if job.problems.isEmpty && job.sample.isEmpty && job.released.isEmpty {
                Text(job.state.isActive ? "Nothing read yet…" : "Every MXF already had its Avid IDs.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(job.problems) { row($0) }
                        ForEach(Array(job.released.enumerated()), id: \.offset) { _, pair in
                            releasedRow(pair)
                        }
                        ForEach(job.sample) { row($0) }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color(NSColor.textBackgroundColor).opacity(0.5)))
        .accessibilityIdentifier("mfo.fillAvidIDs.detail")
    }

    private func releasedRow(_ pair: CorrelationScorer.ReleasedPair) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "link.badge.plus")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.orange)
                .font(.system(size: 12))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(pair.first)  \u{2194}  \(pair.second)")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Pair released — \(pair.reason)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func row(_ item: AvidIDBackfillJob.Item) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: Self.icon(item.kind))
                .foregroundStyle(Self.color(item.kind))
                .font(.system(size: 12))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.filename)
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

    static func icon(_ kind: AvidIDBackfillJob.Item.Kind) -> String {
        switch kind {
        case .filled: return "checkmark.circle.fill"
        case .render: return "film.stack"
        case .noIDs: return "questionmark.circle"
        case .failed: return "xmark.octagon.fill"
        case .offline: return "externaldrive.badge.xmark"
        case .notFound: return "doc.questionmark"
        case .recordChanged: return "arrow.triangle.2.circlepath"
        }
    }

    static func color(_ kind: AvidIDBackfillJob.Item.Kind) -> Color {
        switch kind {
        case .filled, .render: return Color(red: 0.10, green: 0.45, blue: 0.25)
        case .failed: return Color(red: 0.80, green: 0.10, blue: 0.10)
        case .noIDs, .offline, .notFound, .recordChanged: return .secondary
        }
    }
}

/// The row's double-click detail (the window asks the job for it).
extension AvidIDBackfillJob: MediaFileOperationOwnDetail {
    var detailView: AnyView { AnyView(AvidIDBackfillDetailView(job: self)) }
}

/// Catalog ▸ "Fill In Avid IDs…" — next to Fill In Full Hashes and
/// Fingerprint Sound (the other whole-catalog read-only fill-ins).
struct AvidIDBackfillMenuItem: View {
    let model: VideoScanModel
    let center: MediaFileOperationsCenter
    let isReadOnly: Bool

    var body: some View {
        Button("Fill In Avid IDs…") {
            _ = center.startedByUser { $0.startAvidIDBackfill(model: model) }
        }
        .disabled(isReadOnly)
        .help("Read the Avid clip name and UMID of every MXF that has none yet (one quick tag read each), mark Avid renders, then release the stored audio/video pairs the IDs prove wrong. Read only on media: nothing is moved, renamed or deleted. Drives that are not connected are skipped and counted.")
    }
}
