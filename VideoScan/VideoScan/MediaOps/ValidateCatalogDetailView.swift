// ValidateCatalogDetailView.swift
// Double-click detail for the "Validate Catalog" MFO row: which step it is
// on (or how it ended), then step 1's own detail (the audit: totals, drives,
// every row that was not simply present) and — only when step 2 ran — step
// 2's (Verify: one line per tier, every finding). Pure presentation over the
// job and its two phase jobs' published values — no model access, no I/O,
// nothing O(catalog) in the body (both child views cap their lists).

import SwiftUI

struct ValidateCatalogDetailView: View {
    @ObservedObject var job: ValidateCatalogJob

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.phaseWords(job.phase))
                .font(.system(size: 12, weight: .medium))
            if let ending = job.ending, !ending.verifyRan {
                Label(ValidateCatalogEnding.catalogSkipped, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let audit = job.auditJob {
                Text("Step 1 — files on disk")
                    .font(.system(size: 11, weight: .semibold))
                CatalogAuditDetailView(job: audit)
            }
            if let verify = job.verifyJob {
                Text("Step 2 — the catalog agrees with itself")
                    .font(.system(size: 11, weight: .semibold))
                VerifyCatalogDetailView(job: verify)
            }
        }
        .accessibilityIdentifier("mfo.validateCatalog.detail")
    }

    static func phaseWords(_ phase: ValidateCatalogJob.Phase) -> String {
        switch phase {
        case .files: return "Step 1 of 2: checking every file on disk (one stat per row; nothing is opened)"
        case .catalog: return "Step 2 of 2: checking the catalog agrees with itself (tiers 0–6, from the fresh file check)"
        case .done: return "Finished — the row's line says how"
        }
    }
}
