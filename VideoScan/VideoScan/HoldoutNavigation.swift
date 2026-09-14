// HoldoutNavigation.swift
// Pure navigation decisions for the blind holdout review pane
// (fix/review-offline-prefilter, 2026-07-26).
//
// Rick: "if a video is offline, don't present it to the user to view"
// and "some of the videos don't even play … the prefilter should check
// that these are even playable." The sheet therefore navigates over
// ACTIONABLE rows only:
//   pending  AND  not cleared (Rick set it aside — see below)
//            AND  not in-flight (answer write still committing)
//            AND  not offline-excluded (volume unmounted / file gone)
//            AND  not unplayable-excluded (nothing can render a frame).
//
// PLAYBACK is decided ZERO-I/O from catalog facts, in THREE tiers
// (feature/holdout-review-explain-clear, 2026-09-13 — see `playback`):
//   .player    — AVFoundation/QuickTime can open it.
//   .filmstrip — AVFoundation cannot (matroska/webm, ffv1/vp8/vp9/av1/
//                svq3/cinepak/indeo/msmpeg4, isLikelyUnanalyzable), but
//                ffmpeg can rip frames, so the sheet shows a filmstrip
//                and the row is REVIEWABLE.
//   .noFrames  — the catalog says there is no video stream at all; no
//                decoder can show Rick anything.
// Only `.noFrames` rows are unplayable-excluded now. Before today the
// whole `.ffmpegDirect` route was excluded, which is the bug this branch
// fixes: Donna's badge sat at 1 forever because her single pending row
// (FFV1 + pcm_s32le in Matroska) was counted pending but hidden from the
// sheet. A row with NO catalog record is PRESENTED — unknown ≠
// unplayable; the offline backstop still covers missing files.
//
// Excluded rows stay PENDING in the CSV — being unreachable or
// unrenderable is not an answer — they are only hidden from navigation
// and called out in the counts so nothing is silently swallowed.
//
// CLEARED rows (HoldoutClearStore) are the app-side, reversible way out:
// Rick decides not to judge a row, it drops out of every pending count
// and out of navigation, and an undo puts it back. The clear lives in a
// sidecar under Application Support — NEVER in the sealed CSV, which
// still reads "pending" for that row.
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
//
// Worst-case memory: everything here is O(rows) over values already held
// by the caller. The breakdown additionally keeps the reviewIds of the
// rows a "clear the unreviewable ones" action would touch — at the
// pathological 100k-row queue that is ≤100k short strings (~5 MB) and
// only while the popover is open.

import Foundation

enum HoldoutNavigation {

    // MARK: - The ONE definition of "pending"

    /// A row still needs an answer from Rick. This is the single
    /// definition; `pendingQueue(for:)`, the badge count, the sheet's
    /// counts, and `isActionable` all go through here so they cannot
    /// disagree. (For Rick: one `constexpr` predicate, not four
    /// copy-pasted `if`s.)
    ///
    /// `cleared` holds reviewIds Rick set aside in the app. The CSV cell
    /// is untouched — clearing is an app-side opinion about what to show,
    /// not an answer.
    static func isPending(_ row: HoldoutReviewRow, cleared: Set<String>) -> Bool {
        row.isPending && !cleared.contains(row.reviewId)
    }

    /// The clear set NARROWED to reviewIds this queue actually has.
    /// A sidecar can name rows a regenerated CSV no longer carries (or a
    /// hand edit can invent them); every count derived from the set's
    /// SIZE — the sheet's "set aside" figure, the accountable total —
    /// must not believe those. Counts derived by walking rows are already
    /// immune. O(rows).
    static func clearedReviewIds(rows: [HoldoutReviewRow],
                                 storeCleared: Set<String>) -> Set<String> {
        guard !storeCleared.isEmpty else { return [] }
        var live = Set<String>()
        for row in rows where storeCleared.contains(row.reviewId) {
            live.insert(row.reviewId)
        }
        return live
    }

    /// How many rows still need an answer. O(rows), never in a view body.
    static func pendingCount(rows: [HoldoutReviewRow], cleared: Set<String>) -> Int {
        guard !cleared.isEmpty else { return rows.reduce(0) { $0 + ($1.isPending ? 1 : 0) } }
        return rows.reduce(0) { $0 + (isPending($1, cleared: cleared) ? 1 : 0) }
    }

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
    ///
    /// `unplayableExcluded` keeps its original label but its MEANING
    /// narrowed on 2026-09-13: it now holds only rows nothing can render
    /// (`playback == .noFrames`), not every AVFoundation-hostile row —
    /// those are reviewable through the filmstrip.
    static func isActionable(_ row: HoldoutReviewRow,
                             inFlight: Set<String>,
                             offlineExcluded: Set<String>,
                             unplayableExcluded: Set<String>,
                             cleared: Set<String> = []) -> Bool {
        isPending(row, cleared: cleared)
            && !inFlight.contains(row.reviewId)
            && !offlineExcluded.contains(row.fullPath)
            && !unplayableExcluded.contains(row.fullPath)
    }

    /// First actionable row from the top — the resume-at-first-unanswered
    /// landing point, now skipping hidden rows too.
    static func firstActionableIndex(rows: [HoldoutReviewRow],
                                     inFlight: Set<String>,
                                     offlineExcluded: Set<String>,
                                     unplayableExcluded: Set<String>,
                                     cleared: Set<String> = []) -> Int? {
        nextIndex(after: -1, count: rows.count, wraps: false) { i in
            isActionable(rows[i], inFlight: inFlight,
                         offlineExcluded: offlineExcluded,
                         unplayableExcluded: unplayableExcluded,
                         cleared: cleared)
        }
    }

    /// Next actionable row strictly after `idx`, wrapping to the front.
    /// Excludes `idx` itself (a row is never its own successor) — same
    /// contract as HoldoutReviewQueue.nextPendingIndex.
    static func nextActionableIndex(after idx: Int,
                                    rows: [HoldoutReviewRow],
                                    inFlight: Set<String>,
                                    offlineExcluded: Set<String>,
                                    unplayableExcluded: Set<String>,
                                    cleared: Set<String> = []) -> Int? {
        nextIndex(after: idx, count: rows.count, wraps: true) { i in
            isActionable(rows[i], inFlight: inFlight,
                         offlineExcluded: offlineExcluded,
                         unplayableExcluded: unplayableExcluded,
                         cleared: cleared)
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
    /// the done pane's all-hidden count. CLEARED rows likewise: they are
    /// already out of the pending count, so counting them as hidden would
    /// double-subtract.
    static func hiddenPendingCounts(rows: [HoldoutReviewRow],
                                    inFlight: Set<String>,
                                    offlineExcluded: Set<String>,
                                    unplayableExcluded: Set<String>,
                                    cleared: Set<String> = [])
        -> (offline: Int, unplayable: Int) {
        guard !offlineExcluded.isEmpty || !unplayableExcluded.isEmpty else {
            return (0, 0)
        }
        var offline = 0
        var unplayable = 0
        for row in rows where isPending(row, cleared: cleared)
            && !inFlight.contains(row.reviewId) {
            if unplayableExcluded.contains(row.fullPath) {
                unplayable += 1
            } else if offlineExcluded.contains(row.fullPath) {
                offline += 1
            }
        }
        return (offline, unplayable)
    }

    // MARK: - Playability classification

    /// Which surface can actually show Rick this row, decided ZERO-I/O
    /// from catalog media facts.
    enum Playback: Equatable, Sendable {
        /// AVFoundation opens it — AVPlayer / Open in QuickTime.
        case player
        /// AVFoundation cannot, ffmpeg can: the sheet rips frames and
        /// shows a filmstrip. Still fully reviewable.
        case filmstrip
        /// The catalog says there is no video stream — no decoder has a
        /// frame to give. The only rows still hidden from the review.
        case noFrames
    }

    /// nil meta (row not in catalog) → `.player`: unknown ≠ unplayable,
    /// and the existing thumbnail ladder (AVF watchdog → ffmpeg fallback)
    /// already copes with a surprise.
    ///
    /// `.noFrames` is deliberately NARROW — a catalog record that names a
    /// container but carries no video codec, i.e. an audio-only file.
    /// Over-eager exclusion is exactly the bug being fixed; when in doubt
    /// the row is shown and the pane reports honestly if the rip fails.
    static func playback(meta: HoldoutMediaMeta?) -> Playback {
        guard let meta else { return .player }
        let codec = meta.videoCodec.trimmingCharacters(in: .whitespacesAndNewlines)
        let container = meta.container.trimmingCharacters(in: .whitespacesAndNewlines)
        if codec.isEmpty && !container.isEmpty { return .noFrames }
        return PreviewFrameRouter.previewRoute(
            container: meta.container,
            videoCodec: meta.videoCodec,
            likelyUnanalyzable: meta.likelyUnanalyzable) == .ffmpegDirect
            ? .filmstrip : .player
    }

    /// True when AVFoundation (and therefore QuickTime, and therefore an
    /// AVPlayer) cannot open this file. Still the honest answer to "can
    /// QuickTime play it" — it is no longer the exclusion rule, because a
    /// filmstrip can review these rows. Kept for the pane's wording and
    /// for the classifier tests.
    static func isUnplayable(meta: HoldoutMediaMeta?) -> Bool {
        guard let meta else { return false }
        return PreviewFrameRouter.previewRoute(
            container: meta.container,
            videoCodec: meta.videoCodec,
            likelyUnanalyzable: meta.likelyUnanalyzable) == .ffmpegDirect
    }

    /// Every row QuickTime cannot play, from the session's catalog
    /// metadata map. Pure + O(rows). NOTE: this is no longer the
    /// exclusion set — see `unrenderablePaths`.
    static func unplayablePaths(rows: [HoldoutReviewRow],
                                meta: [String: HoldoutMediaMeta]) -> Set<String> {
        var excluded = Set<String>()
        for row in rows where isUnplayable(meta: meta[row.fullPath]) {
            excluded.insert(row.fullPath)
        }
        return excluded
    }

    /// THE exclusion set: rows not even ffmpeg can draw a frame from.
    /// Pure + O(rows).
    static func unrenderablePaths(rows: [HoldoutReviewRow],
                                  meta: [String: HoldoutMediaMeta]) -> Set<String> {
        var excluded = Set<String>()
        for row in rows where playback(meta: meta[row.fullPath]) == .noFrames {
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

    /// Friendly volume label for the breakdown copy: "MediaExpansion" for
    /// a /Volumes path, "this Mac" for an internal one. Pure string work
    /// (no mount-table lookup), so it is safe anywhere.
    static func volumeLabel(forPath path: String) -> String {
        guard let key = volumeKey(forPath: path) else { return "this Mac" }
        return (key as NSString).lastPathComponent
    }

    // MARK: - Catalog metadata map (extracted from ConfirmPersonSheet)

    /// fullPath → media facts for the given files, in ONE pass over the
    /// catalog. Extracted from ConfirmPersonSheet.buildMediaMeta so the
    /// sheet AND the badge popover classify from the same code — a second
    /// opinion about a row's format is exactly how a badge and a sheet
    /// start disagreeing.
    ///
    /// Media facts only (container / codec / duration / the derived
    /// can't-analyze flag) — no detection or scoring data crosses into
    /// the blind pane. O(records); never call from a view body.
    static func mediaMetaMap(paths: Set<String>,
                             records: [VideoRecord]) -> [String: HoldoutMediaMeta] {
        guard !paths.isEmpty else { return [:] }
        var map: [String: HoldoutMediaMeta] = [:]
        map.reserveCapacity(paths.count)
        for rec in records where paths.contains(rec.fullPath) {
            map[rec.fullPath] = HoldoutMediaMeta(
                container: rec.container,
                videoCodec: rec.videoCodec,
                durationSeconds: rec.durationSeconds,
                likelyUnanalyzable: rec.isLikelyUnanalyzable)
        }
        return map
    }

    // MARK: - Volume-level offline precheck (extracted from ConfirmPersonSheet)

    /// VOLUME-level offline check: one reachability question per distinct
    /// volume, injected so this stays pure and testable. Internal
    /// (non-/Volumes) paths pass — the per-file sweep and the per-row
    /// backstop cover those.
    ///
    /// The production predicate (VolumeReachability.isReachable) is
    /// documented to never touch the disk on the caller's thread (SWR
    /// cache + kernel mount table), which is why the sheet may call this
    /// synchronously during its first landing.
    static func volumeLevelOfflinePaths(paths: [String],
                                        isVolumeReachable: (String) -> Bool) -> Set<String> {
        var verdictByVolume: [String: Bool] = [:]
        var offline = Set<String>()
        for path in paths {
            guard let key = volumeKey(forPath: path) else { continue }
            let reachable = verdictByVolume[key] ?? {
                let v = isVolumeReachable(key)
                verdictByVolume[key] = v
                return v
            }()
            if !reachable { offline.insert(path) }
        }
        return offline
    }

    // MARK: - Badge breakdown (the popover's honest arithmetic)

    /// What the purple "Review N" badge is actually made of. Computed by
    /// `breakdown(...)` below and rendered by BOTH the badge popover and
    /// (for its status banner counts) the review sheet, so the two can
    /// never tell Rick different stories.
    struct Breakdown: Equatable, Sendable {
        /// Pending, reachable, and AVFoundation can play it.
        var ready: Int = 0
        /// Pending, reachable, needs the ffmpeg filmstrip — reviewable.
        var needsFilmstrip: Int = 0
        /// Pending but its volume is not mounted (or the file is gone).
        var offline: Int = 0
        /// Pending but nothing can draw a frame from it.
        var unrenderable: Int = 0
        /// Rows Rick set aside. Out of `pending` entirely; shown so the
        /// popover can offer the undo.
        var cleared: Int = 0
        /// Volume labels behind `offline`, sorted, deduped — so the copy
        /// can name the drive to reconnect.
        var offlineVolumes: [String] = []
        /// reviewIds behind `offline`, in row order — kept separate from
        /// the unrenderable ones so a bulk clear records the RIGHT reason
        /// for each (they are different facts with different remedies).
        var offlineReviewIds: [String] = []
        /// reviewIds behind `unrenderable`, in row order.
        var unrenderableReviewIds: [String] = []

        /// Rows Rick could answer right now.
        var actionable: Int { ready + needsFilmstrip }
        /// Rows still owed an answer — what the badge counts.
        var pending: Int { ready + needsFilmstrip + offline + unrenderable }
        /// Pending rows that cannot be shown at this moment.
        var blocked: Int { offline + unrenderable }
        /// Every reviewId a "set aside the ones I can't review" action
        /// would take, offline first.
        var clearableReviewIds: [String] { offlineReviewIds + unrenderableReviewIds }
    }

    /// Classify every row of a queue into the badge's honest buckets.
    /// PURE and O(rows) — the caller supplies the catalog metadata map
    /// and the already-computed offline set, so nothing here does I/O and
    /// this can run off the main actor.
    ///
    /// PRECEDENCE, and why it changed: cleared wins (it is Rick's own
    /// decision), then in-flight rows are skipped entirely (their answer
    /// is mid-commit), then OFFLINE, then format. Reachability now
    /// outranks format because a filmstrip row is reviewable once its
    /// drive is back — the old code preferred "unplayable" precisely
    /// because that verdict was permanent, and it no longer is.
    static func breakdown(rows: [HoldoutReviewRow],
                          meta: [String: HoldoutMediaMeta],
                          cleared: Set<String>,
                          offlinePaths: Set<String>,
                          inFlight: Set<String> = []) -> Breakdown {
        var result = Breakdown()
        var volumes = Set<String>()
        for row in rows {
            guard row.isPending else { continue }
            if cleared.contains(row.reviewId) {
                result.cleared += 1
                continue
            }
            if inFlight.contains(row.reviewId) { continue }
            if offlinePaths.contains(row.fullPath) {
                result.offline += 1
                volumes.insert(volumeLabel(forPath: row.fullPath))
                result.offlineReviewIds.append(row.reviewId)
                continue
            }
            switch playback(meta: meta[row.fullPath]) {
            case .noFrames:
                result.unrenderable += 1
                result.unrenderableReviewIds.append(row.reviewId)
            case .filmstrip:
                result.needsFilmstrip += 1
            case .player:
                result.ready += 1
            }
        }
        result.offlineVolumes = volumes.sorted()
        return result
    }
}
