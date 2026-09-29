// ConfirmPersonSheet+HoldoutNavigation.swift
// PHASE 1 of the unified Review session — the BLIND holdout half's
// MACHINERY, extracted verbatim from ConfirmPersonSheet.swift
// (2026-09-13). Behaviour is unchanged; only the file boundary moved.
//
// What lives here: the offline + unrenderable prefilter (copy-candidate
// map, the background reachability sweep and its merge discipline, the
// hidden-row counts), holdout navigation (holdoutGo / next / first
// actionable / skip), the filmstrip rip for AVF-hostile rows, the
// set-aside path, the media-metadata pass, the read-ahead prefetcher,
// and the SERIALIZED answer write-chain that is the only writer to the
// sealed CSV.
//
// The panes this machinery serves are in ConfirmPersonSheet+Holdout.swift.
//
// Two invariants that live in the code below rather than in a comment at
// the call site: no blocking I/O on the main actor (every stat, rip and
// CSV read-modify-write runs in a background task), and no O(rows) work
// in a view body (the hidden counts are stored state, recomputed by
// recomputeHiddenCounts). The 100k-row scale test pins the second.
//
// A cross-file `extension` cannot see `private` members, so the members
// this code shares with the other three files are internal there;
// `private` here is file-private to THIS file. (Swift extension ≈ C++
// partial class via free member functions: no new stored state allowed,
// methods share the same `self`.)

import AppKit
import SwiftUI
import os

extension ConfirmPersonSheet {

    // MARK: - Offline / unplayable prefilter

    /// The path preview surfaces should use for `original`: the resolved
    /// live byte-identical copy when the sweep found one, else the original
    /// itself. Preview-only — callers that write the answer or key the
    /// sealed identity keep using `row.fullPath` directly (Rick 2026-07-30).
    func previewPath(for original: String) -> String {
        resolvedPreviewPath[original] ?? original
    }

    /// VOLUME-level offline check, main-safe by construction: only
    /// consults VolumeReachability.isReachable (SWR cache / kernel mount
    /// table — never disk I/O on the caller's thread), one lookup per
    /// distinct volume. Internal (non-/Volumes) paths pass — the per-file
    /// sweep and the per-row backstop cover those.
    /// Now a thin adapter over HoldoutNavigation.volumeLevelOfflinePaths
    /// — the badge popover needs the SAME verdict, so the logic lives in
    /// the pure layer and this only supplies the production predicate.
    nonisolated static func volumeLevelOfflinePaths(rows: [HoldoutReviewRow]) -> Set<String> {
        HoldoutNavigation.volumeLevelOfflinePaths(
            paths: rows.map(\.fullPath),
            isVolumeReachable: { VolumeReachability.isReachable(path: $0) })
    }

    /// Build the strong-identity copy-candidate map for a set of pending
    /// originals: original fullPath → ordered live-copy CANDIDATE paths
    /// (liveness unchecked — the sweep stats those). One O(records)
    /// OnlineCopyFinder index build; call on the main actor, off the view
    /// body (Rick 2026-07-30). Originals with no candidate are omitted.
    func buildCopyCandidateMap(forPending pendingPaths: [String]) -> [String: [String]] {
        let resolver = HoldoutCopyResolver(records: catalogModel.records)
        var map: [String: [String]] = [:]
        for path in pendingPaths {
            let candidates = resolver.copyCandidates(for: path)
            if !candidates.isEmpty { map[path] = candidates }
        }
        return map
    }

    /// ONE background reachability sweep over the pending rows — run per
    /// open and per "Continue Reviewing" click, no polling. Cheap ladder:
    /// volume reachability once per distinct volume (mount table — no
    /// disk touch for unmounted drives), then fileExists per row only on
    /// reachable volumes, strictly serialized at O(rows). Result REPLACES
    /// the offline set (a reconnected volume's rows come back); the
    /// per-row backstop re-inserts anything that vanishes afterwards.
    ///
    /// `precomputedCandidates` lets the caller (startHoldout) hand in the
    /// copy-candidate map it already built for its deferral set, so the open
    /// path pays ONE O(records) OnlineCopyFinder index pass, not two
    /// (Rick 2026-07-30). resumeHoldout passes nil — its pending set changed,
    /// so the map is rebuilt for the current rows.
    func startOfflineSweep(precomputedCandidates: [String: [String]]? = nil) {
        guard let q = holdout else { return }
        offlineSweepTask?.cancel()
        backstopInsertsSinceSweep = []
        let clearedNow = clearedReviewIds
        let pendingRows = q.rows
            .filter { HoldoutNavigation.isPending($0, cleared: clearedNow) }
            .map(\.fullPath)
        // Offline-copy preview resolution (Rick 2026-07-30): the strong-
        // identity copy candidates are precomputed on the main actor, where
        // the catalog lives — one O(records) index build off the view body.
        // The sweep's @concurrent half does the per-candidate liveness stats
        // in its existing serialized context, so we never touch `records`
        // from the background and never do O(records) work in a body.
        let copyCandidates = precomputedCandidates
            ?? buildCopyCandidateMap(forPending: pendingRows)
        // Gate the per-row backstop for these originals until the sweep
        // returns a verdict (a live copy resolution must not be pre-empted
        // by holdoutGo's optimistic stat of the offline original).
        awaitingCopyResolution = Set(copyCandidates.keys)
        offlineSweepTask = Task { @MainActor in
            let result = await Self.sweepOfflinePaths(
                paths: pendingRows, copyCandidates: copyCandidates)
            guard !Task.isCancelled else { return }
            // Pure set-algebra merge (extracted + unit-testable — QA flagged
            // this as the likeliest regression site, 2026-07-30). Sweep
            // result ∪ backstop-inserts-since-launch, MINUS anything the
            // sweep resolved to a live copy (resolution is authoritative — a
            // live byte-identical copy was just statted). `resolvedPreviewPath`
            // is replaced wholesale each sweep so a reconnected original drops
            // its copy note; never merged across sweeps.
            let merged = Self.mergeSweepResult(
                offline: result.offline,
                backstop: backstopInsertsSinceSweep,
                resolved: result.resolved)
            offlineExcludedPaths = merged.excluded
            resolvedPreviewPath = merged.resolved
            awaitingCopyResolution = []
            recomputeHiddenCounts()
            // If the row on screen just turned out to be offline, honor
            // "never present an offline video" — move along (or to the
            // candidate transition if nothing actionable remains). The
            // INVERSE case (a row that was showing its transient offline
            // pane while awaiting resolution, now resolved to a live copy)
            // re-lands so the copy's reachability + thumbnail get picked up.
            if phase == .holdout, let qq = holdout,
               qq.rows.indices.contains(holdoutIndex),
               qq.rows[holdoutIndex].isPending {
                let cur = qq.rows[holdoutIndex].fullPath
                if offlineExcludedPaths.contains(cur) {
                    holdoutAdvance()
                } else if resolvedPreviewPath[cur] != nil, !holdoutReachable {
                    holdoutGo(to: holdoutIndex)
                }
            }
        }
    }

    /// The blocking half of the sweep, off the main actor. Serialized —
    /// one stat at a time — so a spun-down HDD sees a polite sequential
    /// scan, not a seek storm.
    ///
    /// Offline-copy preview resolution (Rick 2026-07-30): when a path is
    /// found offline, walk its precomputed strong-identity `copyCandidates`
    /// (ordered by HoldoutCopyResolver / OnlineCopyFinder) and take the
    /// first one that is on a mounted volume AND exists on disk. That
    /// original is NOT added to the offline set — it is reviewable via the
    /// live copy — and is recorded in the returned `resolved` map
    /// (original → live copy). The candidate liveness stats reuse the same
    /// serialized, memoized-per-volume ladder, so the polite-sequential
    /// property holds for the copies too.
    #if compiler(>=6.2)
    @concurrent
    #endif
    private nonisolated static func sweepOfflinePaths(
        paths: [String],
        copyCandidates: [String: [String]]
    ) async -> (offline: Set<String>, resolved: [String: String]) {
        var offline = Set<String>()
        var resolved: [String: String] = [:]
        var volumeReachable: [String: Bool] = [:]

        // Shared liveness test: mounted volume (memoized, kernel mount table
        // — no disk spin-up for unmounted drives) + file present. Used for
        // both the primary paths and the copy candidates.
        func isLive(_ path: String) -> Bool {
            if let key = HoldoutNavigation.volumeKey(forPath: path) {
                let reachable = volumeReachable[key] ?? {
                    // Honest one-shot answer: the kernel mount table
                    // (getmntinfo MNT_NOWAIT — in-kernel state, never
                    // spins up a disk), not the SWR cache, so a just-
                    // yanked drive can't answer stale-true.
                    let v = VolumeReachability.currentMountedRoots().contains(key)
                    volumeReachable[key] = v
                    return v
                }()
                if !reachable { return false }
            }
            // Mounted volume or internal path → the file itself decides.
            return FileManager.default.fileExists(atPath: path)
        }

        for path in paths {
            if Task.isCancelled { return (offline, resolved) }
            if isLive(path) { continue }
            // Original is offline — try a live byte-identical copy before
            // giving up and hiding the row.
            if let candidates = copyCandidates[path],
               let live = candidates.first(where: { isLive($0) }) {
                resolved[path] = live
            } else {
                offline.insert(path)
            }
        }
        return (offline, resolved)
    }

    /// Pure set-algebra for the sweep completion, extracted so it is
    /// unit-testable without a sheet (Rick 2026-07-30 — QA flagged the merge
    /// as the likeliest future regression site). The excluded set is the
    /// sweep's offline verdict UNIONED with anything the per-row backstop
    /// flagged since this sweep launched, MINUS every original the sweep
    /// resolved to a live copy — resolution wins over an optimistic backstop
    /// flag because it statted a live byte-identical copy. `resolved` passes
    /// through unchanged (it is replaced wholesale each sweep upstream); it
    /// rides along so the single call site gets both values from one tested
    /// surface.
    nonisolated static func mergeSweepResult(
        offline: Set<String>,
        backstop: Set<String>,
        resolved: [String: String]
    ) -> (excluded: Set<String>, resolved: [String: String]) {
        (offline.union(backstop).subtracting(resolved.keys), resolved)
    }

    /// Refresh the stored hidden-pending counts (never computed in view
    /// bodies — the queue can be arbitrarily large per the scale test).
    func recomputeHiddenCounts() {
        guard let q = holdout else {
            offlineHiddenPending = 0
            unplayableHiddenPending = 0
            return
        }
        let counts = HoldoutNavigation.hiddenPendingCounts(
            rows: q.rows,
            inFlight: inFlightAnswerIds,
            offlineExcluded: offlineExcludedPaths,
            unplayableExcluded: unplayableExcludedPaths,
            cleared: clearedReviewIds)
        offlineHiddenPending = counts.offline
        unplayableHiddenPending = counts.unplayable
    }

    /// Navigate to a holdout row: reset the thumbnail, prefill the notes
    /// draft, and kick off the background stat + thumbnail load. NO
    /// synchronous file I/O here — a fileExists against a spun-down USB
    /// HDD can stall the main thread for seconds, which was navigation
    /// bug #2 of the LaCie review slowness (2026-07-26).
    func holdoutGo(to idx: Int) {
        guard let q = holdout, q.rows.indices.contains(idx) else { return }
        thumbnailLoadTask?.cancel()
        reachabilityTask?.cancel()
        // Drop the previous row's strip AND its in-flight rip — this is
        // the ~8 MB release that keeps one strip in memory at a time.
        holdoutFilmstripTask?.cancel()
        holdoutFilmstrip = .idle
        holdoutFilmstripError = nil
        thumbnail = nil
        thumbnailFailed = false
        holdoutIndex = idx
        holdoutNotes = q.rows[idx].notes
        // Sealed identity stays the ORIGINAL; preview surfaces follow the
        // resolved live copy when the sweep found one (Rick 2026-07-30).
        let original = q.rows[idx].fullPath
        let path = previewPath(for: original)
        keepalive.setCurrentPath(path)

        // Optimistic: render as reachable immediately; the background
        // stat corrects to the offline pane if the file is gone. The
        // thumbnail load starts right away — on a spun-up disk it wins;
        // on a missing file it fails fast and the stat verdict lands.
        holdoutReachable = true
        reachabilityTask = Task { @MainActor in
            let exists = await Self.statFileExists(path)
            guard !Task.isCancelled, holdoutIndex == idx else { return }
            holdoutReachable = exists
            if !exists {
                thumbnailLoadTask?.cancel()
                thumbnail = nil
                // While the sweep is still deciding whether this offline
                // original has a LIVE copy, don't backstop-exclude it — the
                // transient offline pane is expected, and the sweep's
                // resolution (or offline verdict) is authoritative
                // (Rick 2026-07-30). Otherwise: backstop feeds the
                // prefilter — a file can vanish AFTER the open-time sweep,
                // so exclude it (navigation is once-per-open, no polling).
                // Recorded per-sweep so an in-flight sweep's completion
                // can't wholesale-replace it away (QA minor 1). Keyed on the
                // ORIGINAL: offlineExcludedPaths and navigation key by
                // row.fullPath, and if the previewed copy ALSO vanished the
                // row is once again unreviewable.
                if !awaitingCopyResolution.contains(original) {
                    offlineExcludedPaths.insert(original)
                    backstopInsertsSinceSweep.insert(original)
                    recomputeHiddenCounts()
                }
            }
        }
        // ONE preview surface per row, chosen from the same catalog facts
        // the badge popover classifies with: a filmstrip when
        // AVFoundation can't decode the file, the routed single-frame
        // thumbnail otherwise. Meta stays keyed on the ORIGINAL — a
        // resolved live copy is byte-identical, so the catalog's routing
        // metadata still fits.
        let meta = mediaMetaByPath[original]
        if HoldoutNavigation.playback(meta: meta) == .filmstrip {
            loadHoldoutFilmstrip(path: path, meta: meta, index: idx)
        } else {
            loadThumbnail(path: path)
        }
    }

    /// Rip the current row's filmstrip, off the main actor, progress
    /// reported honestly. Frames land only while the sheet is still on
    /// `index` — a slow rip for a row Rick navigated away from is
    /// cancelled AND its result discarded.
    ///
    /// Failure is NOT recorded in the model's shared thumbnail negative
    /// cache: a filmstrip rip failing says nothing about the fast
    /// single-frame path, and poisoning that cache would blank the file's
    /// preview everywhere (the 2026-07-26 poison class).
    private func loadHoldoutFilmstrip(path: String, meta: HoldoutMediaMeta?, index: Int) {
        holdoutFilmstripError = nil
        let planned = max(1, PreviewFilmstripPlan.offsets(
            durationSeconds: meta?.durationSeconds ?? 0).count)
        holdoutFilmstrip = .loading(path: path, done: 0, total: planned)
        let filename = (path as NSString).lastPathComponent
        holdoutFilmstripTask = Task { @MainActor in
            // Progress hops back to the main actor from the rendering
            // executor; the guards make a stale row's report a no-op.
            let onProgress: @Sendable (Int, Int) -> Void = { done, total in
                Task { @MainActor in
                    guard holdoutIndex == index else { return }
                    if case .loading = holdoutFilmstrip {
                        holdoutFilmstrip = .loading(path: path, done: done,
                                                    total: max(total, 1))
                    }
                }
            }
            do {
                let strip = try await VideoScanModel.renderPreviewFilmstrip(
                    path: path,
                    container: meta?.container ?? "",
                    videoCodec: meta?.videoCodec ?? "",
                    likelyUnanalyzable: meta?.likelyUnanalyzable ?? false,
                    durationSeconds: meta?.durationSeconds ?? 0,
                    onFrameProgress: onProgress)
                guard !Task.isCancelled, holdoutIndex == index else { return }
                guard !strip.frames.isEmpty else {
                    holdoutFilmstrip = .idle
                    holdoutFilmstripError = "No frames could be read from this file."
                    return
                }
                holdoutFilmstrip = .ready(path: path, frames: strip.frames)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, holdoutIndex == index else { return }
                holdoutSheetLog.error("holdout filmstrip FAILED — file: \(filename, privacy: .public), error: \(error.localizedDescription, privacy: .public)")
                holdoutFilmstrip = .idle
                holdoutFilmstripError = "No frames could be read from this file (\(error.localizedDescription))."
            }
        }
    }

    /// stat() off the main actor (house convention: @concurrent so the
    /// blocking call can't inherit the caller's actor).
    #if compiler(>=6.2)
    @concurrent
    #endif
    private nonisolated static func statFileExists(_ path: String) async -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// Record yes/no + notes for the current row. Still write-through —
    /// every answer is durably in the CSV moments after the click — but
    /// the CSV reload+rewrite runs OFF the main actor (bug #2:
    /// synchronous Data(contentsOf:) + atomic rewrite per answer stalled
    /// the UI on slow disks). The UI advances optimistically; writes are
    /// chained so they execute strictly one at a time in click order
    /// (two quick answers can never interleave the read-modify-write),
    /// and each write STILL merges onto a fresh disk load inside
    /// HoldoutReviewQueue.recordAnswer — the QA-gated semantic (commit
    /// 65fbfcf) is untouched, only the executor changed.
    func holdoutAnswer(_ confirm: String) {
        guard let q = holdout, q.rows.indices.contains(holdoutIndex) else { return }
        let row = q.rows[holdoutIndex]
        // WRITE-SINK CUSTODY: a blind answer may only route to the
        // sealed CSV. The router returning anything else means a wiring
        // bug — drop the write loudly, never coerce
        // (UnifiedReviewSessionTests custody sensors).
        guard ReviewWriteRouting.sink(for: .holdout(row),
                                      answer: .holdoutConfirm(confirm)) == .sealedHoldoutCSV else {
            holdoutSheetLog.fault("custody: holdout answer refused a non-CSV sink — dropped")
            // Visible to Rick, not just Console (QA 2026-07-27 🟡 D) —
            // a future wiring bug must not present as a dead button.
            holdoutSaveError = "Internal safety check refused to save this answer (nothing was written). Please tell Claude — this is a wiring bug."
            return
        }
        let notes = holdoutNotes
        let snapshot = q          // Sendable value copy for the writer
        let wasPending = row.isPending
        let filename = row.filename

        if wasPending {
            inFlightAnswerIds.insert(row.reviewId)
            // In-flight rows count toward neither hidden bucket
            // (QA minor 2) — refresh so the counts flip immediately.
            recomputeHiddenCounts()
        }
        holdoutSaveError = nil

        // Captured HERE (view installed, wrapper resolved) so the escaped
        // task holds the center CLASS REFERENCE — a failure landing after
        // dismissal must not go through dead @EnvironmentObject storage.
        let center = holdoutCenter
        let previous = holdoutWriteChain
        holdoutWriteChain = Task { @MainActor in
            _ = await previous?.value   // strict FIFO across answers
            let result = await Self.performAnswerWrite(
                queue: snapshot, reviewId: row.reviewId,
                confirm: confirm, notes: notes)
            // Commit-after-write, on the main actor: memory only ever
            // reflects what is durably on disk (WAL discipline).
            switch result {
            case .success(let updated):
                holdout = updated
                if wasPending { holdoutAnsweredThisSession += 1 }
            case .failure(let error):
                // Three surfaces, because the sheet may already be gone
                // (QA 2026-07-26 🟠): the in-sheet banner, the log trail,
                // and the badge center the gallery watches. The row is
                // still pending on disk — nothing was written — so the
                // badge count stays honest too.
                holdoutSheetLog.error("holdout answer write FAILED — file: \(filename, privacy: .public), reviewId: \(row.reviewId, privacy: .public), error: \(error.localizedDescription, privacy: .public)")
                holdoutSaveError = "Could not save answer for \(filename): \(error.localizedDescription) \u{2014} the row is still pending; use Back to re-answer."
                center.reportAnswerWriteFailure(
                    "The answer for \(filename) was not saved (\(error.localizedDescription)). Its row is still pending \u{2014} reopen the review to answer it again.")
            }
            if wasPending { inFlightAnswerIds.remove(row.reviewId) }
            // AFTER the in-flight removal, whatever the outcome: on
            // success the pending flags changed; on failure the row is
            // pending-and-visible again — either way the hidden counts
            // must reflect the post-commit truth (QA minor 2).
            recomputeHiddenCounts()
        }
        holdoutAdvance()
    }

    /// The CSV read-modify-write, off the main actor. Delegates entirely
    /// to HoldoutReviewQueue.recordAnswer, which reloads the CSV fresh
    /// from disk as the merge base — the snapshot's staleness cannot
    /// clobber external edits (QA 2026-07-25 gate finding 1; regression
    /// tests pin it).
    #if compiler(>=6.2)
    @concurrent
    #endif
    private nonisolated static func performAnswerWrite(
        queue: HoldoutReviewQueue, reviewId: String,
        confirm: String, notes: String
    ) async -> Result<HoldoutReviewQueue, any Error> {
        var q = queue
        do {
            try q.recordAnswer(reviewId: reviewId, confirm: confirm, notes: notes)
            return .success(q)
        } catch {
            return .failure(error)
        }
    }

    /// Navigation goes through the PURE decision in HoldoutNavigation:
    /// pending, minus in-flight answers, minus offline-excluded, minus
    /// unplayable-excluded. The user is simply never shown a hidden row.
    private func nextActionableIndex(after idx: Int, in q: HoldoutReviewQueue) -> Int? {
        HoldoutNavigation.nextActionableIndex(
            after: idx, rows: q.rows,
            inFlight: inFlightAnswerIds,
            offlineExcluded: offlineExcludedPaths,
            unplayableExcluded: unplayableExcludedPaths,
            cleared: clearedReviewIds)
    }

    func firstActionableIndex() -> Int? {
        guard let q = holdout else { return nil }
        return HoldoutNavigation.firstActionableIndex(
            rows: q.rows,
            inFlight: inFlightAnswerIds,
            offlineExcluded: offlineExcludedPaths,
            unplayableExcluded: unplayableExcludedPaths,
            cleared: clearedReviewIds)
    }

    /// Called right after an answer is enqueued (or a Skip) — the current
    /// row is either in flight or deliberately left pending; move to the
    /// next actionable one, or hand the session over to the candidate
    /// phase when the blind portion is done.
    private func holdoutAdvance() {
        guard let q = holdout else { return }
        if let next = nextActionableIndex(after: holdoutIndex, in: q) {
            holdoutGo(to: next)
        } else {
            transitionToCandidates()
        }
    }

    /// Set the current row aside: record it in the clear sidecar, drop it
    /// out of every pending count and out of navigation, and move on.
    ///
    /// NOTHING is written to the CSV here — a clear is not an answer, and
    /// the sealed artifact may only ever receive an exact "yes"/"no"
    /// through recordAnswer's merge-on-write path.
    func holdoutClearCurrentRow() {
        guard let q = holdout, q.rows.indices.contains(holdoutIndex) else { return }
        let row = q.rows[holdoutIndex]
        guard row.isPending else { return }
        let store = holdoutCenter.clears
        guard store.clear(queueKey: q.queueKey, reviewId: row.reviewId,
                          filename: row.filename, reason: .userChoice) else { return }
        clearedReviewIds.insert(row.reviewId)
        recomputeHiddenCounts()
        Task { await store.save() }
        holdoutAdvance()
    }

    func holdoutSkip() {
        guard let q = holdout else { return }
        if let next = nextActionableIndex(after: holdoutIndex, in: q) {
            holdoutGo(to: next)
        } else {
            // Nothing else actionable — this row remains unanswered by
            // choice (resume lands here next open); on to candidates.
            transitionToCandidates()
        }
    }

    /// Build the fullPath → media-metadata map for the given files in
    /// ONE pass over the catalog (never per navigation, never in a view
    /// body). Files not in the catalog simply have no entry — the
    /// renderer then takes the shared default (AVF watchdog + ffmpeg
    /// fallback) path. `merge:` keeps the holdout rows' entries alive
    /// when the candidate phase adds its own.
    func buildMediaMeta(for paths: Set<String>, merge: Bool = false) {
        if !merge { mediaMetaByPath = [:] }
        guard !paths.isEmpty else { return }
        // ONE extraction, shared with the badge popover
        // (HoldoutNavigation.mediaMetaMap) so the two surfaces can never
        // form different opinions about a row's format.
        let fresh = HoldoutNavigation.mediaMetaMap(paths: paths,
                                                   records: catalogModel.records)
        mediaMetaByPath.merge(fresh) { _, new in new }
    }

    /// Create the shared read-ahead worker (both phases) if it doesn't
    /// exist yet. The render closure guards on the model's shared
    /// negative cache — same gate as the interactive path — but does NOT
    /// record failures (best-effort; nil is not a fact about the file).
    /// QA 2026-07-26 🟡 2.
    func ensurePrefetcher() {
        guard prefetcher == nil else { return }
        let failureStore = catalogModel.thumbnailFailureStore
        prefetcher = HoldoutReviewPrefetcher(
            renderThumbnail: { path, meta in
                guard !failureStore.isKnownFailure(atPath: path) else { return nil }
                return await ReviewThumbnailRenderer.renderOrNil(path: path, meta: meta)
            })
    }

    /// Queue read-ahead for the next few items of the CURRENT phase —
    /// ONE path for both (design note: one thumbnail + read-ahead
    /// pipeline). Called from the thumbnail-load completion so the disk
    /// sees strictly one reader at a time — the prefetcher additionally
    /// serializes its own batches internally.
    func schedulePrefetch() {
        guard let prefetcher else { return }
        var entries: [HoldoutReviewPrefetcher.Entry] = []
        switch phase {
        case .holdout:
            guard let q = holdout else { return }
            let n = q.rows.count
            guard n > 0 else { return }
            var i = holdoutIndex
            for _ in 0..<max(n - 1, 0) {
                i = (i + 1) % n
                let r = q.rows[i]
                // Only warm rows the user can actually be shown — hidden
                // (offline/unplayable) rows would waste the HDD's time.
                guard HoldoutNavigation.isActionable(
                    r, inFlight: inFlightAnswerIds,
                    offlineExcluded: offlineExcludedPaths,
                    unplayableExcluded: unplayableExcludedPaths,
                    cleared: clearedReviewIds) else { continue }
                entries.append(HoldoutReviewPrefetcher.Entry(
                    // Warm the PREVIEW path — a resolved offline-with-copy
                    // row must prefetch the live copy, not the offline
                    // original it's standing in for (Rick 2026-07-30). Meta
                    // stays keyed on the original: the copy is byte-identical
                    // content, so the catalog's routing metadata still fits.
                    path: previewPath(for: r.fullPath),
                    meta: mediaMetaByPath[r.fullPath],
                    // Pre-decode a thumbnail only for the NEXT item; bytes
                    // warming covers the rest of the window.
                    wantsThumbnail: entries.isEmpty))
                if entries.count >= HoldoutReviewPrefetcher.lookahead { break }
            }
        case .labeling:
            // Candidate walk is LINEAR (no wrap — matches navigation).
            var i = currentIndex + 1
            while i < candidates.count && entries.count < HoldoutReviewPrefetcher.lookahead {
                let c = candidates[i]
                entries.append(HoldoutReviewPrefetcher.Entry(
                    path: c.recordPath,
                    meta: mediaMetaByPath[c.recordPath],
                    wantsThumbnail: entries.isEmpty))
                i += 1
            }
        case .setup, .summary:
            return
        }
        if !entries.isEmpty { prefetcher.schedule(entries: entries) }
    }
}
