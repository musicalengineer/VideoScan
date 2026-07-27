// VideoScanModel+Filmstrip.swift
// Filmstrip preview for AVPlayer-unplayable formats (2026-07-27).
//
// The orchestration layer between the pure plan (PreviewFilmstripPlan),
// the renderer (renderPreviewFilmstrip in VideoScanModel+Thumbnail),
// the persistent cache (PreviewDiskCache filmstrip payloads), and the
// preview pane's filmstrip branch (CatalogHelpers / FilmstripPreview).
//
// Lifecycle rules (all enforced here, on the main actor):
//   - At most ONE filmstrip generation in flight per model instance.
//   - A play click on the row a prewarm is already ripping PROMOTES
//     that prewarm to interactive (coalesce on path — never rip the
//     same master twice). A play click on any other row replaces
//     whatever is in flight.
//   - A prewarm NEVER cancels an interactive request; a newer prewarm
//     replaces an older prewarm.
//   - Selection change resets the display state and cancels any task
//     for a different row (stale frames must never show).
//   - Failures do NOT touch ThumbnailFailureStore (the fast thumbnail
//     already succeeded for these files — poisoning the shared negative
//     cache would blank their previews, the 2026-07-26 poison class).
//     Cancellations record nothing anywhere.
//
// Memory: the strip itself is ≤16 CGImages at ≤480 wide (~8 MB) living
// inside filmstripState while displayed, dropped on reset/stop/
// selection change. Generation transients are bounded in
// renderPreviewFilmstrip's header.

import Foundation
import CoreGraphics
import os

/// File-scope so detached generation tasks can log without touching
/// main-actor state — same fix class as previewLog/precacheLog.
private let filmstripLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                  category: "filmstrip")

/// What the preview pane's filmstrip branch renders. The path rides in
/// every non-idle case so the view (and the publish guards here) can
/// reject stale state for a different row without a separate field.
/// Swift enum-with-payloads ≈ a C++ tagged union (std::variant) — the
/// compiler forces every consumer to handle all cases.
enum PreviewFilmstripState {
    case idle
    /// Interactive generation in flight — pane shows
    /// "Extracting frame N of M…".
    case loading(path: String, done: Int, total: Int)
    /// Strip ready — pane shows the auto-playing filmstrip player.
    case ready(path: String, frames: [PreviewFilmstrip.Frame])

    /// True when this state belongs to `path` (loading or ready) —
    /// drives the stop button and the view branch condition.
    func isActive(forPath path: String?) -> Bool {
        switch self {
        case .idle:
            return false
        case .loading(let p, _, _), .ready(let p, _):
            return p == path
        }
    }
}

extension VideoScanModel {

    /// Sendable value snapshot of the record fields a filmstrip
    /// generation needs — VideoRecord instances never cross into the
    /// detached task (same convention as ThumbnailPrecache's
    /// PrecacheItem).
    struct FilmstripWorkItem: Sendable {
        let path: String
        let container: String
        let videoCodec: String
        let likelyUnanalyzable: Bool
        let durationSeconds: Double

        @MainActor
        init(record: VideoRecord) {
            path = record.fullPath
            container = record.container
            videoCodec = record.videoCodec
            likelyUnanalyzable = record.isLikelyUnanalyzable
            durationSeconds = record.durationSeconds
        }

        init(path: String, container: String, videoCodec: String,
             likelyUnanalyzable: Bool, durationSeconds: Double) {
            self.path = path
            self.container = container
            self.videoCodec = videoCodec
            self.likelyUnanalyzable = likelyUnanalyzable
            self.durationSeconds = durationSeconds
        }
    }

    /// Session cap on remembered filmstrip failures — memory discipline
    /// bound, mirrors ThumbnailFailureStore.maxEntries.
    static let filmstripFailedPathsCap = 10_000

    // MARK: - Entry points

    /// Interactive: the preview pane's play button for an
    /// ffmpegDirect-routed record. Publishes loading state immediately,
    /// then either serves the disk-cached strip or generates one.
    ///
    /// `dependencyCheck` is the injectable preflight seam (defaults to
    /// the real DependencyChecker probe) — tests simulate a bare
    /// machine without touching global tool state.
    func requestFilmstrip(for record: VideoRecord,
                          dependencyCheck: () -> MissingDependency? = { DependencyChecker.checkFilmstripPreview() }) {
        // Preflight ffmpeg BEFORE any state change (codex 🔴 2026-07-27:
        // a missing ffmpeg was a dead click — the run failed off-screen
        // and idled, and MKV/FFV1 has no alternate play surface to fall
        // back to). Same mechanism as Scan/Combine: raise the app-wide
        // MissingDependency alert and leave the pane exactly as it was
        // (thumbnail + play overlay).
        if let missing = dependencyCheck() {
            missingDependency = missing
            return
        }

        let item = FilmstripWorkItem(record: record)

        // Coalesce: a prewarm already ripping THIS file is promoted to
        // interactive instead of ripping twice — its progress callbacks
        // start publishing from the next frame on.
        if let task = filmstripTask, filmstripTaskPath == item.path {
            filmstripTaskIsInteractive = true
            // Seed the loading total from the prewarm's own report when
            // it has one, else from the plan (QA nit 2026-07-27 — the
            // old (0, 1) seed showed "1 of 1" until the next frame).
            let progress = filmstripLatestProgress
            let plannedTotal = max(1, PreviewFilmstripPlan.offsets(durationSeconds: item.durationSeconds).count)
            filmstripState = .loading(path: item.path,
                                      done: progress.done,
                                      total: progress.total > 0 ? progress.total : plannedTotal)
            // Priority donation (QA 🟡 2026-07-27): the running task was
            // launched at .background and NOTHING awaits it, so flipping
            // the flag alone gives the click background-speed frames.
            // Awaiting its value from a .userInitiated task escalates the
            // running task via Swift's priority donation — ≈ priority
            // inheritance on a held mutex: the waiter lends its priority
            // to the holder.
            Task(priority: .userInitiated) { _ = await task.value }
            filmstripLog.debug("filmstrip prewarm promoted to interactive — \((item.path as NSString).lastPathComponent, privacy: .public)")
            return
        }

        // Anything else in flight is stale for this click (a prewarm
        // for another row, or an interactive for a previous selection).
        cancelFilmstripTask()
        let plannedTotal = max(1, PreviewFilmstripPlan.offsets(durationSeconds: item.durationSeconds).count)
        filmstripState = .loading(path: item.path, done: 0, total: plannedTotal)
        startFilmstripTask(item: item, interactive: true)
    }

    /// Background prewarm — called from the thumbnail request sites
    /// after a fast thumbnail lands for an ffmpegDirect-routed row, so
    /// the strip is usually on disk before the user ever clicks play.
    /// All guards live HERE so callers can invoke it unconditionally.
    /// Same injectable preflight seam as requestFilmstrip.
    func prewarmFilmstripIfNeeded(item: FilmstripWorkItem,
                                  dependencyCheck: () -> MissingDependency? = { DependencyChecker.checkFilmstripPreview() }) {
        guard PreviewFrameRouter.previewRoute(container: item.container,
                                              videoCodec: item.videoCodec,
                                              likelyUnanalyzable: item.likelyUnanalyzable) == .ffmpegDirect else {
            return
        }
        guard !filmstripFailedPaths.contains(item.path) else { return }
        // Missing ffmpeg: SILENT skip — background work never raises
        // dialogs (the interactive click surfaces the alert), and
        // launching a doomed generation would just burn a subprocess
        // attempt per keystroke. A few stats, same cost class as the
        // reachability gate below.
        guard dependencyCheck() == nil else { return }
        if filmstripTask != nil {
            // Never cancel an interactive request in favor of a prewarm;
            // same-path prewarm is already doing this exact work.
            if filmstripTaskIsInteractive { return }
            if filmstripTaskPath == item.path { return }
            // Replacing an older prewarm is fine — the user has moved on.
            cancelFilmstripTask()
        }
        guard VolumeReachability.isReachable(path: item.path) else { return }
        startFilmstripTask(item: item, interactive: false)
    }

    /// Stop button: exit filmstrip mode. Cancels an in-flight
    /// INTERACTIVE generation (symmetric with the AVPlayer stop path);
    /// a background prewarm is left running — its result still lands
    /// in the disk cache for next time.
    func stopFilmstrip() {
        if filmstripTaskIsInteractive {
            cancelFilmstripTask()
        }
        filmstripState = .idle
    }

    /// Selection-change / teardown reset: drop any display state and
    /// cancel any in-flight task that belongs to a DIFFERENT row than
    /// `newPath` (nil = tearing down entirely). An in-flight prewarm
    /// for the SAME row survives — the play click will coalesce onto
    /// it. Called from requestThumbnailDebounced / generateThumbnail /
    /// clearPreview / clearResults.
    func resetFilmstrip(forNewPath newPath: String?) {
        if filmstripTaskPath != nil, filmstripTaskPath != newPath {
            cancelFilmstripTask()
        }
        if case .idle = filmstripState { return }
        if !filmstripState.isActive(forPath: newPath) {
            filmstripState = .idle
        }
    }

    // MARK: - Task lifecycle (private)

    private func cancelFilmstripTask() {
        filmstripTask?.cancel()
        filmstripTask = nil
        filmstripTaskPath = nil
        filmstripTaskIsInteractive = false
        filmstripLatestProgress = (0, 0)
        // Rotate the run ID so the cancelled task's still-queued
        // completion hops fail the guard even before any new run starts
        // (QA nit 2026-07-27).
        filmstripRunID = UUID()
    }

    /// Launch the single generation task. Flow: L2 disk lookup →
    /// generate → publish (interactive only) → write-through to disk.
    /// Publish-before-store follows the interactive path's QA rule
    /// (the user's frames must not wait behind the cache lock); for a
    /// pure prewarm the publish is a no-op, so the order is harmless.
    private func startFilmstripTask(item: FilmstripWorkItem, interactive: Bool) {
        let runID = UUID()
        filmstripRunID = runID
        filmstripTaskPath = item.path
        filmstripTaskIsInteractive = interactive
        filmstripLatestProgress = (0, 0)
        let diskCache = previewDiskCache

        filmstripTask = Task.detached(priority: interactive ? .userInitiated : .background) { [weak self] in
            // Cancellation guard BEFORE any disk I/O (QA 🟠 2026-07-27:
            // this task was cancellation-blind — a per-keystroke prewarm
            // replaced by the next row's still paid the stat + listing).
            // A cancelled run needs no bookkeeping hop: every cancel goes
            // through cancelFilmstripTask, which already cleared it.
            guard !Task.isCancelled else { return }

            let signature = PreviewDiskCache.fileSignature(atPath: item.path)

            // Prewarm early-out (QA 🟠 2026-07-27): if a complete strip
            // is already on disk, a prewarm's job is DONE — the listing-
            // only completeness check replaces decoding ~16 JPEGs just
            // to discard them (this branch fires per keystroke via the
            // thumbnail cache-hit sites). One main hop decides: if a
            // play click promoted this run mid-check, fall THROUGH to
            // the decoding lookup below instead of returning — an early
            // return would leave the click spinning on .loading forever.
            if !interactive, let signature,
               diskCache.hasCompleteFilmstrip(path: item.path,
                                              mtime: signature.mtime,
                                              size: signature.size) {
                let promoted = await MainActor.run { [weak self] () -> Bool in
                    guard let self, self.filmstripRunID == runID else { return false }
                    if self.filmstripTaskIsInteractive { return true }
                    // Still a pure prewarm: complete early — clear the
                    // bookkeeping so the next prewarm/click isn't blocked
                    // by a phantom "in flight" task.
                    self.clearFilmstripBookkeeping()
                    return false
                }
                if !promoted { return }
            }

            // L2 decode: a complete cached strip costs ≤16 JPEG decodes,
            // no media I/O. Signature nil (file vanished / dead volume)
            // skips the cache both ways; generation reports the truth.
            guard !Task.isCancelled else { return }
            if let signature,
               let cached = diskCache.lookupFilmstrip(path: item.path,
                                                      mtime: signature.mtime,
                                                      size: signature.size) {
                let frames = cached.map {
                    PreviewFilmstrip.Frame(offsetSeconds: $0.offsetSeconds, image: $0.image)
                }
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    self?.finishFilmstrip(runID: runID, path: item.path, frames: frames)
                }
                return
            }

            do {
                let strip = try await VideoScanModel.renderPreviewFilmstrip(
                    path: item.path,
                    container: item.container,
                    videoCodec: item.videoCodec,
                    likelyUnanalyzable: item.likelyUnanalyzable,
                    durationSeconds: item.durationSeconds,
                    onFrameProgress: { done, total in
                        Task { @MainActor [weak self] in
                            self?.noteFilmstripProgress(runID: runID, path: item.path,
                                                        done: done, total: total)
                        }
                    })
                await MainActor.run { [weak self] in
                    self?.finishFilmstrip(runID: runID, path: item.path, frames: strip.frames)
                }
                // Write-through to disk (still off-main). Signature from
                // BEFORE generation is correct: the key must describe
                // the file we just decoded.
                if let signature {
                    diskCache.storeFilmstrip(strip.frames.map { ($0.offsetSeconds, $0.image) },
                                             path: item.path,
                                             mtime: signature.mtime,
                                             size: signature.size)
                }
            } catch {
                let wasCancelled = (error is CancellationError) || Task.isCancelled
                await MainActor.run { [weak self] in
                    self?.failFilmstrip(runID: runID, path: item.path,
                                        wasCancelled: wasCancelled, error: error)
                }
            }
        }
    }

    // MARK: - Main-actor completion handlers (private)

    private func noteFilmstripProgress(runID: UUID, path: String, done: Int, total: Int) {
        guard filmstripRunID == runID else { return }
        // Per-frame reports arrive via unordered unstructured tasks —
        // "5 of 16" must never regress to "3 of 16" (QA 🟡 2026-07-27).
        // Monotonic gate per total; a total change (single-frame
        // degeneration path) resets the baseline.
        if total == filmstripLatestProgress.total,
           done <= filmstripLatestProgress.done {
            return
        }
        filmstripLatestProgress = (done, total)
        // Publish only when the run is (or has been promoted to)
        // interactive AND this row is still the current selection.
        if filmstripTaskIsInteractive, previewRequestPath == path {
            filmstripState = .loading(path: path, done: done, total: total)
        }
    }

    private func finishFilmstrip(runID: UUID, path: String, frames: [PreviewFilmstrip.Frame]) {
        guard filmstripRunID == runID else { return }
        let wasInteractive = filmstripTaskIsInteractive
        clearFilmstripBookkeeping()
        guard wasInteractive else { return }  // pure prewarm: disk cache was the point
        // Stale-completion guard, same contract as generateThumbnail's:
        // never clobber a newer selection's pane.
        guard previewRequestPath == path, !frames.isEmpty else {
            if filmstripState.isActive(forPath: path) { filmstripState = .idle }
            return
        }
        filmstripState = .ready(path: path, frames: frames)
    }

    private func failFilmstrip(runID: UUID, path: String, wasCancelled: Bool, error: Error) {
        guard filmstripRunID == runID else { return }
        let wasInteractive = filmstripTaskIsInteractive
        clearFilmstripBookkeeping()

        // Cancellation says nothing about the file — record NOTHING
        // (the 2026-07-26 cache-poison class; see
        // PreviewCachePoisonSensorTests for the sibling sensor).
        guard !wasCancelled else {
            if wasInteractive, filmstripState.isActive(forPath: path) {
                filmstripState = .idle
            }
            return
        }

        // Environmental failures are not facts about the file — don't
        // blacklist the path over them (QA 🟡 2026-07-27):
        //   - ffmpegUnavailable: no ffmpeg binary at all;
        //   - unreachable volume: the drive died/unmounted mid-rip (one
        //     statfs, same pattern as generateThumbnail's offline gate).
        if (error as? PreviewFrameError) != .ffmpegUnavailable,
           VolumeReachability.isReachable(path: path),
           filmstripFailedPaths.count < Self.filmstripFailedPathsCap {
            filmstripFailedPaths.insert(path)
        }
        filmstripLog.notice("filmstrip generation failed for \((path as NSString).lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")

        guard wasInteractive else { return }
        // Return the pane to the thumbnail + play overlay (QA 🟡
        // 2026-07-27): previewImage/previewUnavailable are left ALONE —
        // the fast thumbnail is truthful, and blanking it into NO
        // PREVIEW lied about the file (and self-contradicted: reselect
        // brought the thumbnail back). The notice above is the failure
        // record; a re-click retries honestly.
        if filmstripState.isActive(forPath: path) {
            filmstripState = .idle
        }
    }

    /// Post-completion cleanup — the task FINISHED, so no cancel here
    /// (cancelFilmstripTask is the pre-emption path).
    private func clearFilmstripBookkeeping() {
        filmstripTask = nil
        filmstripTaskPath = nil
        filmstripTaskIsInteractive = false
        filmstripLatestProgress = (0, 0)
    }
}
