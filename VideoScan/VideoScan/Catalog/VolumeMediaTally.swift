// VolumeMediaTally.swift
// The volume table's per-target numbers, as one pure pass over the
// records: the Files and Media Size columns (LIVE content), plus the
// history bucket the error count, the "uncataloged" filter and ⌘I read.
//
// Bug fixed 2026-10-11 (docs/reviews/night/diagnose_trash_and_volume_floor_2026_10_10.md §2c):
// Media Size summed `sizeBytes` over EVERY record whose current or origin
// path started with the target path — trashed, removed, set-aside,
// superseded and Manually Deleted rows included — so a volume's size
// never went down after Rick trashed files, and the rows summed to
// ~13.4 TB against the footer's 7.85 TB. The match was also a plain
// string prefix, so "/Volumes/A" swallowed "/Volumes/AB/…".
//
// Now:
//   * LIVE (Files, Media Size): the record passes the footer's own
//     predicate, `CatalogStorageTotalsCalculator.isCounted` — one
//     definition, not a copy — AND its CURRENT path is under the target.
//     A migrated record's bytes live on the volume it moved TO, not the
//     one it came from.
//   * HISTORY (errors, "has records", ⌘I): any record whose current OR
//     origin path is under the target, any state — an emptied
//     relocate-source volume still "has records" via its provenance.
//   * Both use PathScope's component-boundary match.
//
// Invariant (pinned in VolumeMediaTallyTests): with disjoint targets that
// cover every record, Σ live bytes over the rows == the footer's
// TOTAL CATALOG `grossBytes`. Nested targets (a folder target inside a
// volume target) count a file in both rows, on purpose — the parent
// volume really does hold it.
//
// O(records × targets). Called from the coalesced aggregate recompute,
// NEVER from a view body. (Swift `enum` with only static members ≈ a C++
// namespace of free functions.)

import Foundation

enum VolumeMediaTally {

    /// One target's numbers for the volume table.
    struct Bucket {
        /// Every record whose current or origin path is under the target,
        /// in any state. Feeds ⌘I and the error count.
        var history: [VideoRecord] = []
        /// `history` rows with `streamType == .ffprobeFailed`.
        var errors = 0
        /// Records the footer counts whose file is on this target now.
        var liveFiles = 0
        /// Their bytes (negative sizes clamp to 0, exactly as the footer).
        var liveBytes: Int64 = 0
    }

    /// One pass over `records`, bucketed per target id. A record is LIVE
    /// on a target when the footer counts it (`isCounted`, asked once per
    /// record) and its current path is under the target's root.
    static func compute(
        _ records: [VideoRecord],
        targets: [(id: UUID, searchPath: String)]
    ) -> [UUID: Bucket] {
        let roots = targets.map { (id: $0.id, root: PathScope.Root($0.searchPath)) }
        var out: [UUID: Bucket] = [:]
        out.reserveCapacity(roots.count)
        for t in roots { out[t.id] = Bucket() }
        for r in records {
            let current = PathScope.normalize(r.fullPath)
            let origin = r.originalFullPath.map(PathScope.normalize)
            let counted = CatalogStorageTotalsCalculator.isCounted(r)
            let isError = r.streamType == .ffprobeFailed
            for t in roots {
                let onNow = t.root.containsNormalized(current)
                guard onNow || (origin.map(t.root.containsNormalized) ?? false) else { continue }
                out[t.id, default: Bucket()].add(r, live: counted && onNow, isError: isError)
            }
        }
        return out
    }
}

private extension VolumeMediaTally.Bucket {
    mutating func add(_ r: VideoRecord, live: Bool, isError: Bool) {
        history.append(r)
        if isError { errors += 1 }
        if live {
            liveFiles += 1
            liveBytes += max(0, r.sizeBytes)
        }
    }
}
