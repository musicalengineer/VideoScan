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
    func requestFilmstrip(for record: VideoRecord) {
        let item = FilmstripWorkItem(record: record)

        // Coalesce: a prewarm already ripping THIS file is promoted to
        // interactive instead of ripping twice — its progress callbacks
        // start publishing from the next frame on.
        if filmstripTask != nil, filmstripTaskPath == item.path {
            filmstripTaskIsInteractive = true
            let progress = filmstripLatestProgress
            filmstripState = .loading(path: item.path,
                                      done: progress.done,
                                      total: max(progress.total, 1))
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
    func prewarmFilmstripIfNeeded(item: FilmstripWorkItem) {
        guard PreviewFrameRouter.previewRoute(container: item.container,
                                              videoCodec: item.videoCodec,
                                              likelyUnanalyzable: item.likelyUnanalyzable) == .ffmpegDirect else {
            return
        }
        guard !filmstripFailedPaths.contains(item.path) else { return }
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
            // L2 first: a complete cached strip costs ≤16 JPEG decodes,
            // no media I/O. Signature nil (file vanished / dead volume)
            // skips the cache both ways; generation reports the truth.
            let signature = PreviewDiskCache.fileSignature(atPath: item.path)
            if let signature,
               let cached = diskCache.lookupFilmstrip(path: item.path,
                                                      mtime: signature.mtime,
                                                      size: signature.size) {
                let frames = cached.map {
                    PreviewFilmstrip.Frame(offsetSeconds: $0.offsetSeconds, image: $0.image)
                }
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

        // ffmpegUnavailable is an environment failure, not a fact about
        // this file — don't blacklist the path over it.
        if (error as? PreviewFrameError) != .ffmpegUnavailable,
           filmstripFailedPaths.count < Self.filmstripFailedPathsCap {
            filmstripFailedPaths.insert(path)
        }
        filmstripLog.notice("filmstrip generation failed for \((path as NSString).lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")

        guard wasInteractive else { return }
        filmstripState = .idle
        // Full failure falls through to the existing NO PREVIEW state
        // (stale-completion guarded — an old failure must not stamp a
        // newer selection).
        if previewRequestPath == path {
            previewImage = nil
            previewUnavailable = true
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
