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
// Blindness contract: reachability is a filesystem fact and
// container/codec are media facts (same carve-out as the thumbnail
// routing) — nothing here reads or adds model/detection fields.

import Foundation

enum HoldoutNavigation {

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
        rows.firstIndex {
            isActionable($0, inFlight: inFlight,
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
        let n = rows.count
        guard n > 1 else { return nil }
        for step in 1..<n {
            let i = (idx + step) % n
            if isActionable(rows[i], inFlight: inFlight,
                            offlineExcluded: offlineExcluded,
                            unplayableExcluded: unplayableExcluded) {
                return i
            }
        }
        return nil
    }

    /// How many pending rows each filter is hiding, for the honest
    /// counts. A row in BOTH sets counts as UNPLAYABLE — that's the
    /// permanent fact (reconnecting its volume won't make it reviewable),
    /// so the "reconnect and reopen to finish" guidance only claims rows
    /// reconnecting would actually recover.
    static func hiddenPendingCounts(rows: [HoldoutReviewRow],
                                    offlineExcluded: Set<String>,
                                    unplayableExcluded: Set<String>)
        -> (offline: Int, unplayable: Int) {
        guard !offlineExcluded.isEmpty || !unplayableExcluded.isEmpty else {
            return (0, 0)
        }
        var offline = 0
        var unplayable = 0
        for row in rows where row.isPending {
            if unplayableExcluded.contains(row.fullPath) {
                unplayable += 1
            } else if offlineExcluded.contains(row.fullPath) {
                offline += 1
            }
        }
        return (offline, unplayable)
    }

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
