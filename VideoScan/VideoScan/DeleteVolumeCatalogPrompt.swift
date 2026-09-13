// DeleteVolumeCatalogPrompt.swift
// The value the Delete Volume Catalog alert presents (codex #1417,
// 2026-09-12). It carries the EXACT removal plan made at the gesture so
// the count the user reads and the ids the model removes are one thing.
//
// Before this, the alert read the coalesced `scanTargetFacts` projection
// (up to one recompute window stale) while `deleteCatalogForTarget` re-
// scoped against the live catalog: a cached "1 file" could confirm and
// remove 2 after an append; a Browse… re-point could swap the whole
// root under a stale count. Now the alert shows `plan.count`, the Delete
// button hands `plan` back, and the model refuses a plan the catalog has
// drifted from — re-presenting this prompt with the fresh plan.

import Foundation

struct DeleteVolumeCatalogPrompt {
    let target: CatalogScanTarget
    /// The plan made when the user chose Delete; what the alert counts
    /// and what Delete applies.
    let plan: TargetRemovalPlan
    /// Non-nil when this prompt replaces one the model refused as stale —
    /// the message says so and quotes the old count, so the user knows
    /// why the dialog came back.
    let replacedStalePlan: TargetRemovalPlan?

    /// Alert body. Pure over the prompt's fields (no model read) so
    /// ContentView's alert stage stays O(1) and the text is unit-testable.
    var message: String {
        let label = VolumeReachability.displayLabel(forPath: plan.root)
        var lines: [String] = []
        if let stale = replacedStalePlan {
            lines.append("The catalog changed while this was open (was \(stale.count) record(s), now \(plan.count)). Nothing was deleted — please confirm again.")
            lines.append("")
        }
        lines.append("Delete \(plan.count) catalog record(s) for \(label)?")
        if plan.keptCoveredByOtherTargets > 0 {
            lines.append("")
            lines.append("\(plan.keptCoveredByOtherTargets) record(s) under this path also belong to another scan target and will be kept.")
        }
        lines.append("")
        lines.append("The probe cache is unaffected — a re-scan will replay quickly from cache.")
        return lines.joined(separator: "\n")
    }
}
