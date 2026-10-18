// ImportToSQLiteDetailView.swift
// Double-click detail for the "Import to SQLite" MFO row: the phase or the
// outcome in words, every pre-flight / gate refusal, every comparator miss,
// the reconciliation line's counts — quarantine by reason — and the first
// 200 quarantined rows with their words, then where the database landed.
// Pure presentation over the job's published values — no model access, no
// I/O, nothing O(catalog) in the body (the sample is capped by the job).

import SwiftUI
import VideoScanCore

struct ImportToSQLiteDetailView: View {
    @ObservedObject var job: ImportToSQLiteJob

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.phaseWords(job.phase, mode: job.mode))
                .font(.system(size: 12, weight: .medium))
            Text(ImportToSQLiteJob.noPauseWords)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if let generation = job.auditedGeneration {
                Text("audited, verified and read at catalog generation \(generation)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(job.refusals.enumerated()), id: \.offset) { _, words in
                Label(words, systemImage: "hand.raised.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Self.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(job.misses.enumerated()), id: \.offset) { _, words in
                Label(words, systemImage: "xmark.octagon.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Self.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let reconciliation = job.reconciliation {
                reconciliationRows(reconciliation)
            }
            if !job.quarantineSample.isEmpty {
                quarantineList
            }
            if let url = job.databaseURL {
                Label("database: \(url.path)", systemImage: "cylinder")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(url.path)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color(NSColor.textBackgroundColor).opacity(0.5)))
        .accessibilityIdentifier("mfo.importToSQLite.detail")
    }

    private func reconciliationRows(_ r: ImportReconciliation) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("rows before \(r.rowsBefore.formatted()) · main \(r.rowsMain.formatted()) (live \(r.rowsLive.formatted()), tombstoned \(r.rowsTombstoned.formatted())) · quarantine \(r.rowsQuarantine.formatted()) · digests \(r.digests.formatted()) · knowledge rows \(r.knowledgeRows.formatted())")
                .font(.system(size: 11, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(r.quarantineByReason.keys.sorted(), id: \.self) { reason in
                Text("quarantine · \(reason): \((r.quarantineByReason[reason] ?? 0).formatted())")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text(r.line)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private var quarantineList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Quarantined rows (first \(job.quarantineSample.count.formatted()))")
                .font(.system(size: 11, weight: .semibold))
                .padding(.top, 4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(job.quarantineSample, id: \.ordinal) { row in
                        HStack(alignment: .top, spacing: 8) {
                            Text("row \(row.ordinal.formatted())")
                                .font(.system(size: 11, weight: .medium))
                                .frame(width: 80, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(row.reasonCode) · \(row.jsonRowID)")
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if !row.words.isEmpty {
                                    Text(row.words)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .frame(maxHeight: 320)
        }
    }

    static let red = Color(red: 0.80, green: 0.10, blue: 0.10)

    static func phaseWords(_ phase: ImportToSQLiteJob.Phase, mode: CatalogImporter.Mode) -> String {
        let what = mode == .dryRun ? "Dry run" : "Import"
        switch phase {
        case .preflight: return "\(what) — checking before any work (unsaved changes, other jobs, the target)"
        case .audit: return "\(what) — phase 1 of 3: Audit Catalog (catalog saves held but the audit's own)"
        case .verify: return "\(what) — phase 2 of 3: Verify Catalog at the audit's generation"
        case .gate: return "\(what) — the importer's gate (the report's hash and generation, the audit, the sidecars)"
        case .rows: return "\(what) — rows, in one transaction"
        case .sidecars: return "\(what) — sidecars (events, ignored, ledger, markers)"
        case .comparing: return "\(what) — comparing every row against the file again"
        case .done: return mode == .dryRun ? "Dry run — rolled back by design; nothing written" : "Import — finished"
        }
    }
}
