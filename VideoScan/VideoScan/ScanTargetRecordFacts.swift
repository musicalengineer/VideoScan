// ScanTargetRecordFacts.swift
// Per-scan-target facts the Catalog Options menu reads in O(1)
// (codex #1368, 2026-09-12).
//
// The menu's "Delete › <volume> (N)" rows and the "File Signatures ›
// One Volume… › <volume> — N files" rows used to compute their counts
// INSIDE the pane's view builder — `model.records.contains` /
// `.filter` / `planContentHashBackfill(records:)` once per scan target
// per body evaluation. That is O(records × targets) per render, the
// exact class the project rule forbids ("NO O(records) work in view
// bodies"; fix template = VolumeStatusCache, GH #104).
//
// This projection is computed ONCE per records-change trigger inside
// `recomputeVolumeAggregates()` — the same event-driven pass that
// publishes `volumeAggregateCache`, `storageTotals` and
// `hashBackfillPlan` — and published as a `[UUID: Facts]` dictionary
// held in `@State`. The body does a dictionary lookup per target.
//
// Semantics are pinned to the expressions they replace
// (ScanTargetRecordFactsTests.parityWithLegacyBodyExpressions):
//   • `records`  — plain `hasPrefix(searchPath)` against the current
//     path OR the origin path. Deliberately NOT the normalised
//     `isUnder` test: the Delete count has always matched what
//     `deleteCatalogForTarget` removes, and "/Volumes/X" has always
//     counted "/Volumes/X2". Same predicate as `VolumeAggregate.files`.
//   • `signaturePlan` — `VideoScanModel.planContentHashBackfill(
//     records:isReachable:{ _ in true }pathPrefix:)` for this target,
//     i.e. the `isUnder` scope with every record treated as reachable
//     (the menu only lists reachable targets).

import Foundation

struct ScanTargetRecordFacts: Equatable, Sendable {
    /// Catalog records under this target (current OR origin path,
    /// plain prefix). The Delete menu's count.
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
    /// and allocation-free per record: the per-target "dir/" prefix is
    /// computed once up front, not once per record as `isUnder` would.
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
        // `isUnder` normalisation: "/Volumes/X" must not scope
        // "/Volumes/X2"; an empty prefix scopes everything.
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

            for i in prefixes.indices {
                let p = prefixes[i]
                let rawMatch = path.hasPrefix(p) || (origin?.hasPrefix(p) ?? false)
                if rawMatch { counts[i] += 1 }
                guard planEligible else { continue }
                // Fast reject: `isUnder` implies the raw prefix match
                // (both of its forms start with `p`), so only a raw hit
                // can be in scope. Empty prefix: rawMatch is true too.
                guard rawMatch else { continue }
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
