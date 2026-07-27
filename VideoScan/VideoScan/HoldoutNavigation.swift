// HoldoutNavigation.swift
// Pure navigation decisions for the blind holdout review pane
// (fix/review-offline-prefilter, 2026-07-26).
//
// Rick: "if a video is offline, don't present it to the user to view"
// and "some of the videos don't even play … the prefilter should check
// that these are even playable." The sheet therefore navigates over
// ACTIONABLE rows only:
//   pending  AND  not in-flight (answer write still committing)
//            AND  not offline-excluded (volume unmounted / file gone)
//            AND  not unplayable-excluded (QuickTime can't open it).
//
// UNPLAYABLE is decided ZERO-I/O from catalog facts: Review's only
// playback path is Open in QuickTime, and QT's playability boundary is
// AVFoundation's — which is exactly what PreviewFrameRouter classifies
// (matroska/webm, ffv1/vp8/vp9/av1/svq3/cinepak/indeo/msmpeg4,
// isLikelyUnanalyzable). A row with NO catalog record is PRESENTED —
// unknown ≠ unplayable; the offline backstop still covers missing files.
//
// Excluded rows stay PENDING in the CSV — being unreachable or
// unplayable is not an answer — they are only hidden from navigation
// and called out in the counts ("3 offline, 2 unplayable — hidden") so
// nothing is silently swallowed.
//
// PURE functions over HoldoutReviewRow + sets — no I/O, no view state —
// so the skip logic is unit-testable without a sheet. (The wrap-order
// walk mirrors HoldoutReviewQueue.nextPendingIndex; with all sets empty
// these reduce exactly to that behavior.)
//
// UNIFIED-REVIEW (2026-07-27, docs/design/unified-review.md D5): the
// wrap-walk is now a GENERIC core (`nextIndex`) shared by both phases of
// the unified Review session. The holdout phase keeps the wrap policy
// over actionable rows (unchanged semantics — the delegating wrappers
// below are pinned against the original behavior); the candidate phase
// uses the LINEAR policy (skipped candidates do not come back around —
// the existing Confirm semantic).
//
// Blindness contract: reachability is a filesystem fact and
// container/codec are media facts (same carve-out as the thumbnail
// routing) — nothing here reads or adds model/detection fields.

import Foundation

enum HoldoutNavigation {

    // MARK: - Generic walk core (unified-review D5)

    /// The one walk implementation. `wraps: true` visits every index except
    /// `idx` itself exactly once, in wrap order (a row is never its own
    /// successor — same contract as HoldoutReviewQueue.nextPendingIndex);
    /// `wraps: false` walks strictly forward. Pass `idx: -1` with
    /// `wraps: false` to search from the front.
    static func nextIndex(after idx: Int, count: Int, wraps: Bool,
                          isActionable: (Int) -> Bool) -> Int? {
        // The wrap walk is defined relative to a REAL current index —
        // a negative idx with wraps would mis-modulo. Linear mode
        // accepts -1 as "search from the front". (QA 2026-07-27 nit.)
        precondition(idx >= 0 || !wraps,
                     "wrap walk requires a valid current index (got \(idx))")
        guard count > 0 else { return nil }
        if wraps {
            guard count > 1 else { return nil }
            for step in 1..<count {
                let i = (idx + step) % count
                if isActionable(i) { return i }
            }
            return nil
        }
        var i = max(idx + 1, 0)
        while i < count {
            if isActionable(i) { return i }
            i += 1
        }
        return nil
    }

    // MARK: - Holdout-phase actionability

    /// Can this row be presented for answering right now?
    static func isActionable(_ row: HoldoutReviewRow,
                             inFlight: Set<String>,
                             offlineExcluded: Set<String>,
                             unplayableExcluded: Set<String>) -> Bool {
        row.isPending
            && !inFlight.contains(row.reviewId)
            && !offlineExcluded.contains(row.fullPath)
            && !unplayableExcluded.contains(row.fullPath)
    }

    /// First actionable row from the top — the resume-at-first-unanswered
    /// landing point, now skipping hidden rows too.
    static func firstActionableIndex(rows: [HoldoutReviewRow],
                                     inFlight: Set<String>,
                                     offlineExcluded: Set<String>,
                                     unplayableExcluded: Set<String>) -> Int? {
        nextIndex(after: -1, count: rows.count, wraps: false) { i in
            isActionable(rows[i], inFlight: inFlight,
                         offlineExcluded: offlineExcluded,
                         unplayableExcluded: unplayableExcluded)
        }
    }

    /// Next actionable row strictly after `idx`, wrapping to the front.
    /// Excludes `idx` itself (a row is never its own successor) — same
    /// contract as HoldoutReviewQueue.nextPendingIndex.
    static func nextActionableIndex(after idx: Int,
                                    rows: [HoldoutReviewRow],
                                    inFlight: Set<String>,
                                    offlineExcluded: Set<String>,
                                    unplayableExcluded: Set<String>) -> Int? {
        nextIndex(after: idx, count: rows.count, wraps: true) { i in
            isActionable(rows[i], inFlight: inFlight,
                         offlineExcluded: offlineExcluded,
                         unplayableExcluded: unplayableExcluded)
        }
    }

    // MARK: - Honest hidden counts

    /// How many pending rows each filter is hiding, for the honest
    /// counts. A row in BOTH sets counts as UNPLAYABLE — that's the
    /// permanent fact (reconnecting its volume won't make it reviewable),
    /// so the "reconnect and reopen to finish" guidance only claims rows
    /// reconnecting would actually recover.
    ///
    /// IN-FLIGHT rows count toward NEITHER bucket (QA 2026-07-26
    /// minor 2): holdoutEffectivePending already subtracts them, so a
    /// just-answered row whose path lands in an excluded set mid-commit
    /// would otherwise be double-subtracted — transiently overstating
    /// the done pane's all-hidden count.
    static func hiddenPendingCounts(rows: [HoldoutReviewRow],
                                    inFlight: Set<String>,
                                    offlineExcluded: Set<String>,
                                    unplayableExcluded: Set<String>)
        -> (offline: Int, unplayable: Int) {
        guard !offlineExcluded.isEmpty || !unplayableExcluded.isEmpty else {
            return (0, 0)
        }
        var offline = 0
        var unplayable = 0
        for row in rows where row.isPending && !inFlight.contains(row.reviewId) {
            if unplayableExcluded.contains(row.fullPath) {
                unplayable += 1
            } else if offlineExcluded.contains(row.fullPath) {
                offline += 1
            }
        }
        return (offline, unplayable)
    }

    // MARK: - Playability classification

    /// ZERO-I/O playability classification from catalog media metadata.
    /// nil meta (row not in catalog) → playable: unknown ≠ unplayable.
    static func isUnplayable(meta: HoldoutMediaMeta?) -> Bool {
        guard let meta else { return false }
        return PreviewFrameRouter.previewRoute(
            container: meta.container,
            videoCodec: meta.videoCodec,
            likelyUnanalyzable: meta.likelyUnanalyzable) == .ffmpegDirect
    }

    /// The full unplayable-exclusion set for a queue, from the session's
    /// catalog metadata map. Pure + O(rows).
    static func unplayablePaths(rows: [HoldoutReviewRow],
                                meta: [String: HoldoutMediaMeta]) -> Set<String> {
        var excluded = Set<String>()
        for row in rows where isUnplayable(meta: meta[row.fullPath]) {
            excluded.insert(row.fullPath)
        }
        return excluded
    }

    // MARK: - Volume grouping

    /// The volume key a path's reachability is judged by, or nil for
    /// internal (non-/Volumes) paths — those have no separable volume to
    /// pre-check and go straight to the per-file existence pass. Mirrors
    /// VolumeReachability's private cacheKey grouping.
    static func volumeKey(forPath path: String) -> String? {
        let comps = (path as NSString).pathComponents
        if comps.count >= 3, comps[1] == "Volumes" {
            return "/Volumes/\(comps[2])"
        }
        return nil
    }
}
