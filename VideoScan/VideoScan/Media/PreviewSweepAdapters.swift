// PreviewSweepAdapters.swift
// App-side concrete implementations of the VideoScanCore preview-sweep
// seams (PreviewSweepSeams.swift). These are the thin adapters that bind
// the Core engine's ABSTRACTIONS to the live app: the disk cache, the
// negative-cache store, the real media renderer, and the model-backed
// catalog source. Stage 1's CLI helper will supply its OWN renderer + the
// file-backed catalog source instead, driving the SAME engine.

import Foundation
import CoreGraphics

// MARK: - Cache + failure store conformances

// `PreviewDiskCache: PreviewCache` moved to VideoScanCore alongside the type
// itself (2026-07-28, Stage 1) — the cache is now the ONE implementation
// shared by the app and the CLI helper, so the conformance (and the
// currentListing one-listing probe) live in Core. See
// VideoScanCore/PreviewDiskCache.swift.

/// The negative cache IS the engine's `PreviewSweepFailureStore` — the
/// methods already match; this is a pure conformance declaration.
extension ThumbnailFailureStore: PreviewSweepFailureStore {}

// MARK: - Media renderer (the FilmstripRipper)

/// Binds the Core `PreviewMediaRenderer` seam to the app's real routed
/// frame generators (the same cores the interactive paths use). Maps the
/// app's `PreviewFrameError.ffmpegUnavailable` onto the Core
/// `PreviewRenderError.ffmpegUnavailable` so the Core executor's
/// environment-fact classification stays app-free; every other error and
/// CancellationError pass through untouched.
struct VideoScanMediaRenderer: PreviewMediaRenderer {

    func renderBestStill(_ candidate: PreviewSweepCandidate) async throws -> CGImage {
        do {
            return try await VideoScanModel.renderBestPreviewCGImage(
                path: candidate.path,
                container: candidate.container,
                videoCodec: candidate.videoCodec,
                likelyUnanalyzable: candidate.likelyUnanalyzable,
                durationSeconds: candidate.durationSeconds)
        } catch let error as PreviewFrameError where error == .ffmpegUnavailable {
            throw PreviewRenderError.ffmpegUnavailable
        }
    }

    func renderFilmstrip(_ candidate: PreviewSweepCandidate) async throws -> [PreviewFilmstripFrame] {
        do {
            let strip = try await VideoScanModel.renderPreviewFilmstrip(
                path: candidate.path,
                container: candidate.container,
                videoCodec: candidate.videoCodec,
                likelyUnanalyzable: candidate.likelyUnanalyzable,
                durationSeconds: candidate.durationSeconds)
            return strip.frames.map {
                PreviewFilmstripFrame(offsetSeconds: $0.offsetSeconds, image: $0.image)
            }
        } catch let error as PreviewFrameError where error == .ffmpegUnavailable {
            throw PreviewRenderError.ffmpegUnavailable
        }
    }
}

// MARK: - Model-backed catalog source

/// Wraps today's model closure (the live `records` eligibility snapshot,
/// taken on the main actor) behind the Core `PreviewCatalogSource` seam —
/// the in-process twin of `FileBackedCatalogSource`. Parity-tested against
/// the file-backed reader (both call the shared
/// `previewSweepCandidates(from:isReachable:)` mapping, so the only thing
/// that can differ is the READ path — which is exactly what the test
/// pins).
struct ModelBackedCatalogSource: PreviewCatalogSource {
    /// Main-actor snapshot of the eligible candidates (VideoScanModel
    /// .previewSweepCandidates()).
    let snapshot: @Sendable () async -> [PreviewSweepCandidate]

    func eligibleCandidates() async -> [PreviewSweepCandidate] {
        await snapshot()
    }
}
