// PreviewSweepExecutorFactory.swift (VideoScanCore)
// The production per-item work, lifted from PreviewSweepService
// .defaultExecutor so the app AND the Stage-1 CLI classify failures under
// the EXACT same rules — the negative-cache poison contract (only genuine
// still failures poison; cancellation / unreachable / ffmpeg-missing /
// strip-only NEVER do) is shared, not duplicated.
//
// Composed from the injected seams: a `PreviewMediaRenderer` (the
// ffmpeg/AVFoundation rip) + a `PreviewCache` (write-through). No app
// type, no VideoScanModel.
//
// Memory: one best-frame pass (≤4 candidates ≈ 2 MB) or one strip (≤16
// frames ≈ 8 MB) alive per worker at a time, released on store.

import Foundation

/// Build the production executor from injected dependencies.
/// - Parameters:
///   - cache: write-through target (PreviewDiskCache in the app).
///   - renderer: the media rip (real in production, fake in unit tests).
///   - isReachable: volume-reachability probe (injected so tests never
///     poison the VolumeReachability SWR cache).
public func makePreviewSweepExecutor(cache: PreviewCache,
                                     renderer: PreviewMediaRenderer,
                                     isReachable: @escaping @Sendable (String) -> Bool)
    -> PreviewSweepExecutor {
    { item in
        var outcome = PreviewSweepItemOutcome()
        let c = item.candidate

        // Volume may have unmounted since planning — no verdict.
        guard isReachable(c.path) else {
            outcome.skippedUnreachable = true
            return outcome
        }
        // Signature from BEFORE generation — the key must describe the
        // file we decode (same rule as the interactive paths).
        guard let sig = previewFileSignature(atPath: c.path) else {
            outcome.skippedUnreachable = true
            return outcome
        }

        if item.needsBestStill {
            do {
                let cg = try await renderer.renderBestStill(c)
                try Task.checkCancellation()
                outcome.bytesWritten += cache.store(cg,
                                                    path: c.path,
                                                    mtime: sig.mtime,
                                                    size: sig.size,
                                                    tier: .best)
                outcome.stillReady = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if (error as? PreviewRenderError) == .ffmpegUnavailable {
                    outcome.environmentFailure = true
                    return outcome
                }
                // Genuine only while the volume is still there — a drive
                // dying mid-rip is not a fact about the file.
                if isReachable(c.path) {
                    outcome.stillFailedGenuinely = true
                } else {
                    outcome.skippedUnreachable = true
                }
                return outcome
            }
        } else {
            outcome.stillReady = true
        }

        if item.needsFilmstrip {
            do {
                let frames = try await renderer.renderFilmstrip(c)
                try Task.checkCancellation()
                outcome.bytesWritten += cache.storeFilmstrip(
                    frames.map { ($0.offsetSeconds, $0.image) },
                    path: c.path,
                    mtime: sig.mtime,
                    size: sig.size)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if (error as? PreviewRenderError) == .ffmpegUnavailable {
                    outcome.environmentFailure = true
                } else {
                    // Still succeeded, strip didn't — never a
                    // ThumbnailFailureStore entry (poison class).
                    outcome.stripFailed = true
                }
            }
        }
        return outcome
    }
}
