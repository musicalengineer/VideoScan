// ArchiveAngelBufferHygieneCard.swift
// Archive Angel curation Phase 2 — the "What next?" card (Rick 2026-09-19,
// docs/archive_angel_curation_direction.md). Sits in the Archive tab ABOVE
// the ready-batch disclosure whenever prepared batches are waiting in the
// buffer or finished batches still hold files:
//
//   3 prepared batches (74 GB) are waiting in the buffer — the disk has
//   11 GB free. What next?                                   [Clear all…]
//   Sep 15 · 70.7 GB · 6 ready, 4 skipped · untouched 4 days
//                             [Review & Promote] [Clear] [Later]
//   Sep 12 · 3.7 GB · promoted — files of 2 rows left behind · untouched 7 days
//                                                [Free 3.7 GB] [Later]
//
// Nothing here deletes without an ask: Clear and Clear all both confirm,
// naming the bytes and that the originals are untouched. Every action goes
// through `model.clearArchiveAngelBatch` — never a file operation here.
// "Later" hides the row for this run of the app (ArchiveAngelHygieneSession).
// A batch a job is working on is shown for its bytes, with no Clear.

import SwiftUI

struct ArchiveAngelBufferHygieneCard: View {
    @EnvironmentObject var model: VideoScanModel
    let report: ArchiveAngelBufferHygiene.Report
    /// Open the existing review sheet for this batch.
    let openReview: (ArchiveAngelPlan) -> Void
    /// The buffer changed — re-read it.
    let batchesChanged: () -> Void

    @ObservedObject private var session = ArchiveAngelHygieneSession.shared
    @State private var pendingClear: ClearRequest?
    /// The clock the row lines are written against — fixed per render.
    private let now = Date()

    /// One confirmation for a single Clear and for Clear all.
    struct ClearRequest: Identifiable {
        let id = UUID()
        let rows: [ArchiveAngelBufferHygiene.BatchRow]
        var bytes: Int64 { rows.reduce(0) { $0 + $1.bytes } }
        var undecided: Int {
            rows.reduce(0) { total, row in
                if case .waiting(let ready, _, _, _) = row.kind { return total + ready }
                if case .parked(let ready, _) = row.kind { return total + ready }
                return total
            }
        }
        var title: String {
            rows.count == 1 ? "Clear this batch from the buffer?" : "Clear \(rows.count) batches from the buffer?"
        }
        var message: String {
            var s = bytes > 0
                ? "\(MediaBytes.display(bytes)) of the Angel's prepared copies are deleted. "
                : "Nothing was prepared in \(rows.count == 1 ? "this batch" : "these batches") — only the plan is removed. "
            s += "The original videos on their volumes are untouched, and the Angel can prepare them again."
            if undecided > 0 {
                s += " \(undecided) undecided row\(undecided == 1 ? " returns" : "s return") to the pool (counted as half a skip)."
            }
            return s
        }
    }

    private var visibleRows: [ArchiveAngelBufferHygiene.BatchRow] {
        report.batches.filter { !session.laterBatchIDs.contains($0.id) }
    }
    private var clearableRows: [ArchiveAngelBufferHygiene.BatchRow] { visibleRows.filter(\.canClear) }

    var body: some View {
        if !visibleRows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                header
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleRows) { row in
                        batchRow(row)
                        if row.id != visibleRows.last?.id { Divider() }
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
            .accessibilityIdentifier("archive.angelHygiene")
            .alert(pendingClear?.title ?? "",
                   isPresented: Binding(get: { pendingClear != nil }, set: { if !$0 { pendingClear = nil } }),
                   presenting: pendingClear) { req in
                Button(req.bytes > 0 ? "Clear \(MediaBytes.display(req.bytes))" : "Clear (nothing prepared)", role: .destructive) { perform(req) }
                Button("Keep", role: .cancel) {}
            } message: { req in
                Text(req.message)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "internaldrive.fill").foregroundStyle(Color.orange)
            Text(report.headline)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("archive.angelHygiene.headline")
            Spacer(minLength: 8)
            if clearableRows.count > 1 {
                Button("Clear all…") { pendingClear = ClearRequest(rows: clearableRows) }
                    .disabled(model.isReadOnly)
                    .accessibilityIdentifier("archive.angelHygiene.clearAll")
                    .help("Clears every batch listed here (\(MediaBytes.display(clearableRows.reduce(0) { $0 + $1.bytes }))). Only the Angel's prepared copies are deleted; the originals are untouched and the undecided rows return to the pool.")
            }
        }
    }

    // MARK: Rows

    private func batchRow(_ row: ArchiveAngelBufferHygiene.BatchRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: rowSymbol(row))
                .foregroundStyle(row.isLeftover ? Color.secondary : Color.orange)
                .frame(width: 14)
            Text(row.line(now: now))
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(row.plan.batchID)
            if row.isStale {
                Label("Untouched \(row.untouchedDays) days", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.yellow)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.yellow.opacity(0.15)))
                    .accessibilityIdentifier("archive.angelHygiene.stale")
            }
            Spacer(minLength: 8)
            if row.canReview {
                Button("Review & Promote") { openReview(row.plan) }
                    .accessibilityIdentifier("archive.angelHygiene.review")
            }
            if row.canClear {
                Button(row.clearLabel) { pendingClear = ClearRequest(rows: [row]) }
                    .disabled(model.isReadOnly)
                    .accessibilityIdentifier("archive.angelHygiene.clear")
                    .help("Deletes this batch's prepared copies from the buffer. Originals untouched; undecided rows return to the pool.")
            } else {
                Text("in progress")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("archive.angelHygiene.inProgress")
            }
            Button("Later") { session.laterBatchIDs.insert(row.id) }
                .accessibilityIdentifier("archive.angelHygiene.later")
                .help("Hides this batch from the card until the app is next opened. Nothing is deleted.")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityIdentifier("archive.angelHygiene.row.\(row.id)")
    }

    private func rowSymbol(_ row: ArchiveAngelBufferHygiene.BatchRow) -> String {
        switch row.kind {
        case .waiting: return "sparkles"
        case .leftover: return "tray.full"
        case .parked: return "pause.circle"
        case .inProgress: return "gearshape.2"
        }
    }

    // MARK: Actions

    private func perform(_ req: ClearRequest) {
        let reason = req.rows.count == 1 ? "cleared from the buffer card" : "Clear all from the buffer card"
        // The rows' measured sizes go along — no re-walk on the main actor.
        model.clearArchiveAngelBatches(req.rows.map(\.plan),
                                       bytes: Dictionary(uniqueKeysWithValues: req.rows.map { ($0.id, $0.bytes) }),
                                       reason: reason)
        pendingClear = nil
        batchesChanged()
    }
}
