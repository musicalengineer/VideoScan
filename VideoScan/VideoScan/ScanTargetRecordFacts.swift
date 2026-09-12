// ScanTargetRecordFacts.swift
// Per-scan-target facts the Catalog Options menu reads in O(1)
// (codex #1368, 2026-09-12; count semantics fixed codex #1393).
//
// The menu's "Delete › <volume> (N)" rows and the "File Signatures ›
// One Volume… › <volume> — N files" rows used to compute their counts
// INSIDE the pane's view builder — `model.records.contains` /
// `.filter` / `planContentHashBackfill(records:)` once per scan target
// per body evaluation. That is O(records × targets) per render, the
// exact class the project rule forbids ("NO O(records) work in view
// bodies"; fix template = VolumeStatusCache, GH #104).
//
// This projection is computed ONCE per catalog mutation (the model's
// `catalogMutationRevision`) inside `recomputeVolumeAggregates()` — the
// same event-driven pass that publishes `volumeAggregateCache`,
// `storageTotals` and `hashBackfillPlan` — and published as a
// `[UUID: Facts]` dictionary held in `@State`. The body does a
// dictionary lookup per target.
//
// Semantics (ScanTargetRecordFactsTests):
//   • `records`  — EXACTLY what `deleteCatalogForTarget` would remove:
//     `TargetRemovalScope` (component-bounded PathScope on the CURRENT
//     path only, minus rows covered by another registered target). The
//     first cut used the raw current-or-origin `hasPrefix` count the old
//     body showed, which counted "/Volumes/X2" rows under "/Volumes/X",
//     origin-only rows, and nested-target rows that the guarded removal
//     never removes (codex #1393). The Volumes table's Files column
//     keeps the raw figure on purpose — it answers a different question.
//   • `signaturePlan` — `VideoScanModel.planContentHashBackfill(
//     records:isReachable:{ _ in true }pathPrefix:)` for this target,
//     i.e. the `isUnder` scope (current OR origin path) with every
//     record treated as reachable (the menu only lists reachable targets).

import Foundation

struct ScanTargetRecordFacts: Equatable, Sendable {
    /// Records a guarded removal under this target would remove — the
    /// Delete menu's count and the Delete confirmation's count.
    var records: Int = 0
    /// File-signature backfill plan scoped to this target, reachability
    /// assumed. The "One Volume…" menu's count.
    var signaturePlan = VideoScanModel.ContentHashBackfillPlan()

    /// The two fields of a scan target the projection needs. A tuple
    /// rather than `CatalogScanTarget` so tests never construct one
    /// and the function stays pure.
    typealias Target = (id: UUID, searchPath: String)

    /// One pass over the catalog. Work is O(records × targets) — the
    /// same shape as the volume-aggregate bucketing it runs beside —
    /// and allocation-free per record: every per-target root form is
    /// prepared once up front (`PathScope.Root`, the `isUnder` "dir/").
    ///
    /// Empty `targets` → empty dictionary; a target with no records
    /// still gets an entry (zeroed), so a body lookup distinguishes
    /// "no records" from "cache not built yet" (`nil`).
    nonisolated static func project(
        _ records: [VideoRecord],
        targets: [Target]
    ) -> [UUID: ScanTargetRecordFacts] {
        guard !targets.isEmpty else { return [:] }
        let prefixes = targets.map(\.searchPath)
        // Delete count: the guarded removal's own scope per target.
        let removalScopes = prefixes.map {
            TargetRemovalScope(root: $0, allTargetRoots: prefixes)
        }
        // Signature plan: `isUnder` normalisation — "/Volumes/X" must not
        // scope "/Volumes/X2"; an empty prefix scopes everything.
        let dirs = prefixes.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        var counts = [Int](repeating: 0, count: targets.count)
        var plans = [VideoScanModel.ContentHashBackfillPlan](
            repeating: .init(), count: targets.count)

        for rec in records {
            let path = rec.fullPath
            let origin = rec.originalFullPath
            // Plan eligibility — identical guards to
            // planContentHashBackfill; evaluated once per record.
            let planEligible = rec.purgedAt == nil
                && !rec.isSetAside && !rec.isSuperseded
                && rec.sizeBytes > 0 && !path.isEmpty
            let hasSignature = !rec.contentHash.isEmpty
            // Normalize once per record, not once per target.
            let normPath = PathScope.normalize(path)

            for i in prefixes.indices {
                if removalScopes[i].claimsNormalized(normPath) { counts[i] += 1 }
                guard planEligible else { continue }
                let p = prefixes[i]
                let d = dirs[i]
                let under = p.isEmpty
                    || path == p || path.hasPrefix(d)
                    || (origin.map { $0 == p || $0.hasPrefix(d) } ?? false)
                guard under else { continue }
                if hasSignature { plans[i].alreadyHashed += 1 }
                else { plans[i].candidates += 1 }
            }
        }

        var out = [UUID: ScanTargetRecordFacts](minimumCapacity: targets.count)
        for i in targets.indices {
            out[targets[i].id] = ScanTargetRecordFacts(
                records: counts[i], signaturePlan: plans[i])
        }
        return out
    }
}
