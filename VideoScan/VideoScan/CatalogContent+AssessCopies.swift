// CatalogContent+AssessCopies.swift
// "Assess Copies for Archive…" row verb (Promote-Helper slice 2,
// docs/promote_helper_plan.md). Split out like CatalogContent+Promote so
// the giant context-menu builder stays inside Xcode's type-check budget.

import SwiftUI

extension CatalogContent {

    /// One record at a time: the assessment is about that recording's
    /// whole copy family, which the job discovers itself (duplicate group
    /// ∪ lineage ∪ archive links ∪ same content signature).
    @ViewBuilder
    func assessCopiesMenuItem(activeRecs: [VideoRecord], pureActive: Bool) -> some View {
        Button("Assess Copies for Archive…") {
            guard let seed = activeRecs.first else { return }
            fileOpsCenter.startAssessCopies(seed: seed, model: model)
            openWindow(id: "combine")
        }
        .disabled(!pureActive || activeRecs.count != 1)
        .help(activeRecs.count == 1
              ? "Which of this recording's copies is the original source master? Collapses every copy into distinct representations, names the one to promote, and offers the next steps — Promote, companion, access copy."
              : "Assess works on one recording at a time — select a single row.")
        .accessibilityIdentifier("catalog.row.assessCopies")
    }
}
