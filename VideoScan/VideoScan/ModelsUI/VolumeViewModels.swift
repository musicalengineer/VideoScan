// VolumeViewModels.swift
// Value types backing the volumes table and combine UI — VolumeRow,
// VolumeAggregate, CombinePairItem, and the OptionalDateComparator (with its
// private ComparisonResult helper) —
// moved verbatim from Models.swift (refactor 2026-06-26, model
// decomposition step 1). In step 2 this file moved from Models/ into the
// app-side ModelsUI/ group: these are view-model value types backing
// SwiftUI tables/UI, not part of the pure (Foundation-only) domain
// layer. Moved verbatim — no logic change.

import Foundation

// MARK: - Volume Row (value type for Table display)

struct VolumeRow: Identifiable {
    let id: UUID                    // matches CatalogScanTarget.id
    let name: String                // friendly volume name
    let path: String                // full search path
    let status: CatalogTargetStatus
    /// User-facing status (drives VolumeStatusView). Replaces the older
    /// `connection`/`connectionColor` pair, which only encoded mount state
    /// and missed Verify/Backfill/Combine activity.
    let uiStatus: VolumeUIStatus
    let files: Int
    let errors: Int
    let mediaBytes: Int64
    let phase: VolumePhase
    let lastScanned: Date?
    let isReachable: Bool
    let isNetwork: Bool
    let catalogStatusText: String
    /// Volume role (Original / Backup / Archive / LTA / etc.). Surfaced
    /// in the Role column so the user can see at a glance which drives
    /// in the table are the source-of-truth vs duplicates vs long-term
    /// archives, without opening the Volumes editor.
    let role: VolumeRole
    /// Drive trust signal (Reliable / Aging / Unreliable / Unknown).
    /// Paired with `role` in the Role column — when degraded, the
    /// column shows "Original · Aging" with the trust word colored;
    /// when reliable/unknown only the role is shown to keep it quiet.
    let trust: VolumeTrust
    /// `CatalogScanTarget.isRetired` — retirement is a lifecycle badge on
    /// any role (taxonomy 2026-08-16); the Role column appends "· Retired".
    var isRetired: Bool = false
}

/// Per-volume aggregate derived from the catalog. Cached once per
/// records-mutation in `ContentView` so the scan-volumes table can be
/// rebuilt in O(targets) per render instead of O(targets × records).
/// Before this struct, every click on a volume row triggered ~15 ×
/// O(13K) catalog walks on the main thread, queuing NSTableView's
/// selection visuals behind hundreds of ms of recompute and producing
/// the "highlight sometimes appears, sometimes doesn't" lag.
struct VolumeAggregate {
    let files: Int
    let errors: Int
    let mediaBytes: Int64
    /// Pre-rendered Cmd+I popover text. Built once per cache refresh
    /// because the underlying provenance/summary/error tabulation also
    /// walks the records linearly.
    let catalogStatusText: String
}

/// Sort comparator for `Date?` columns that sorts `nil` to the END
/// regardless of direction — "never scanned" rows should never crowd
/// the top of either ascending or descending sorts on the Scanned
/// column. SwiftUI's default Optional handling sorts nil to the front
/// in ascending order, which buries actual dates the user is trying to
/// inspect.
struct OptionalDateComparator: SortComparator {
    var order: SortOrder = .forward
    func compare(_ lhs: Date?, _ rhs: Date?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil): return .orderedSame
        case (nil, _):   return .orderedDescending  // nil always goes last
        case (_, nil):   return .orderedAscending
        case let (l?, r?):
            let cmp = l.compare(r)
            return order == .forward ? cmp : cmp.flipped
        }
    }
}

private extension ComparisonResult {
    var flipped: ComparisonResult {
        switch self {
        case .orderedAscending:  return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame:       return .orderedSame
        }
    }
}

// MARK: - Combine Pair Item

struct CombinePairItem: Identifiable {
    let id = UUID()
    let video: VideoRecord
    let audio: VideoRecord
}
