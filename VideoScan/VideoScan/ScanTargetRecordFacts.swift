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
    /// Worst case codex measured on the first cut (#1417): building one
    /// `TargetRemovalScope` per target and asking each `claimsNormalized`
    /// per record is O(records × targets²) when targets nest — every
    /// root contains the path, and every hit re-walks every other root.
    /// Twenty nested folder targets under one volume target is not
    /// exotic. So the removal rule is evaluated here in ONE walk over the
    /// roots per record: collect which roots contain the path and how
    /// many DISTINCT normalized roots that is. Exactly one distinct root
    /// ⇒ that root (and any duplicate registration of the same path,
    /// which the scope never treats as "other") claims the record; two or
    /// more ⇒ nobody does. Byte-identical to `TargetRemovalScope.claims`
    /// — `nestedTargetsProjectionMatchesScope_worstCaseIsLinearInTargets`
    /// pins both the equivalence and the cost.
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
        // Delete count: the guarded removal's own rule, evaluated per
        // record in one pass over the roots (see the doc comment).
        let roots = prefixes.map { PathScope.Root($0) }
        // `group[i]` = index of the first target whose normalized root
        // equals target i's — duplicates of one path form one group.
        var group = [Int](repeating: 0, count: roots.count)
        for i in roots.indices {
            group[i] = roots.firstIndex { $0.normalized == roots[i].normalized } ?? i
        }
        // Signature plan: `isUnder` normalisation — "/Volumes/X" must not
        // scope "/Volumes/X2"; an empty prefix scopes everything.
        let dirs = prefixes.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        var counts = [Int](repeating: 0, count: targets.count)
        var plans = [VideoScanModel.ContentHashBackfillPlan](
            repeating: .init(), count: targets.count)
        // Scratch for the roots containing the current record; reused
        // across records so the loop stays allocation-free.
        var containing = [Int]()
        containing.reserveCapacity(targets.count)

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

            containing.removeAll(keepingCapacity: true)
            var firstGroup = -1
            var severalGroups = false
            for i in prefixes.indices {
                if roots[i].containsNormalized(normPath) {
                    containing.append(i)
                    if firstGroup < 0 { firstGroup = group[i] }
                    else if group[i] != firstGroup { severalGroups = true }
                }
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
            // TargetRemovalScope.claims: under this root AND under no
            // OTHER (distinct) root.
            if !severalGroups {
                for i in containing { counts[i] += 1 }
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
