// InspectorHistoryView.swift
// "History" section of the catalog Inspector (Media Ledger, promote-and-
// prune stage 2 — Rick 2026-09-12): the dated sentences LedgerNarrator
// composes from the ledger lines for the selected record, newest first.
//
// The body does NO file I/O and NO O(records) work: `.task(id:)` asks the
// ledger (off-main, `@concurrent`) for the narrated lines, which the
// ledger caches per record until its next append. The parent embeds this
// with `.id(record.id)` so the state reseeds when the selection moves.
//
// (For Rick: `.task(id:)` ≈ "start this async job when the view appears
// or when `id` changes, cancel the previous one" — the SwiftUI way to
// load per-selection data without a manual lifecycle.)

import SwiftUI

struct InspectorHistoryView: View {

    let record: VideoRecord
    @EnvironmentObject var model: VideoScanModel

    @State private var lines: [String]?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let lines {
                if lines.isEmpty {
                    Text("No history recorded yet.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .accessibilityIdentifier("inspector.history.empty")
                } else {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            } else {
                Text("Reading history…")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .accessibilityIdentifier("inspector.history")
        .task(id: record.id) {
            let ledger = model.mediaLedger
            let id = record.id
            let key = VideoScanModel.ledgerContentKey(for: record)
            let name = record.filename
            let loaded = await ledger.narrated(recordID: id, contentKey: key, filename: name)
            if !Task.isCancelled { lines = loaded }
        }
    }
}
