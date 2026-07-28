// PreviewSweepSeams.swift (VideoScanCore)
// The injected protocol seams the preview-sweep engine depends on. The
// engine composes these ABSTRACTIONS — never VideoScanModel or any app
// singleton — so the SAME engine can be driven in-process by the app
// today and out-of-process by a CLI helper (Stage 1) tomorrow, with zero
// logic or key drift. Each protocol has a small app-side adapter plus (for
// the catalog) a file-backed Core implementation.
//
// For Rick: these are pure interfaces (≈ C++ abstract base classes /
// concepts). The engine holds references to them; concrete types are
// supplied at construction (dependency injection).

import Foundation
import CoreGraphics

// MARK: - Catalog source (the work-list)

/// Supplies the eligible sweep work-list (video-bearing, reachable
/// records) as lightweight value types. Two implementations must AGREE
/// (parity-tested):
///   - a model-backed adapter (app) wrapping today's live `records`, and
///   - `FileBackedCatalogSource` (Core) reading the persisted catalog.json
///     — the linchpin of the out-of-process design.
public protocol PreviewCatalogSource: Sendable {
    /// The eligible candidates right now. `async` so the model-backed
    /// adapter can hop to the main actor; the file-backed one just reads
    /// disk. Volume reachability is a runtime check INSIDE the impl.
    func eligibleCandidates() async -> [PreviewSweepCandidate]
}

// MARK: - Preview cache (read-index + write)

/// The preview disk cache behind a protocol — the engine reads the
/// one-listing index through `currentListing()`; the default executor
/// writes through `store` / `storeFilmstrip`. Wraps the app's
/// PreviewDiskCache (never reimplemented). The Stage-1 CLI injects the
/// same concrete cache.
public protocol PreviewCache: Sendable {
    /// ONE directory listing of the cache root as (filename, sizeBytes) —
    /// the scale invariant's single cache probe. The engine feeds this to
    /// PreviewSweepPlanner.buildCacheIndex.
    func currentListing() -> [(name: String, size: Int64)]

    /// Write-through a generated still; returns bytes actually written
    /// (0 on skip/failure). Semantics per PreviewDiskCache.store.
    @discardableResult
    func store(_ image: CGImage,
               path: String, mtime: TimeInterval, size: Int64,
               tier: PreviewCacheTier) -> Int64

    /// Write-through a complete filmstrip; returns total bytes written.
    /// Semantics per PreviewDiskCache.storeFilmstrip.
    @discardableResult
    func storeFilmstrip(_ frames: [(offsetSeconds: Double, image: CGImage)],
                        path: String, mtime: TimeInterval, size: Int64) -> Int64
}

// MARK: - Failure store (negative cache)

/// The genuine-failure negative cache behind a protocol so the engine's
/// failure-store rule doesn't bind to the app's ThumbnailFailureStore.
public protocol PreviewSweepFailureStore: Sendable {
    func isKnownFailure(atPath path: String) -> Bool
    func recordFailure(forPath path: String)
}

// MARK: - Media renderer (the FilmstripRipper — ffmpeg/AVFoundation)

/// A frame ripped for a filmstrip: its media timestamp + the image.
public struct PreviewFilmstripFrame: Sendable {
    public let offsetSeconds: Double
    public let image: CGImage
    public init(offsetSeconds: Double, image: CGImage) {
        self.offsetSeconds = offsetSeconds
        self.image = image
    }
}

/// Errors a renderer raises that the executor classifies specially.
/// `ffmpegUnavailable` is an ENVIRONMENT fact (no ffmpeg on this machine),
/// never a verdict about the file — the app renderer maps its
/// PreviewFrameError.ffmpegUnavailable onto this so the Core executor
/// stays app-free.
public enum PreviewRenderError: Error, Equatable {
    case ffmpegUnavailable
}

/// The actual media rip (ffmpeg / AVFoundation) behind a protocol so unit
/// tests inject a fake (NO real ffmpeg) and the Stage-1 CLI reuses the
/// real one. Implementations MUST rethrow `CancellationError` untouched
/// and map a missing-ffmpeg condition to `PreviewRenderError
/// .ffmpegUnavailable`; any other throw is treated as a genuine decode
/// failure by the executor.
public protocol PreviewMediaRenderer: Sendable {
    /// The content-scored best still for this record.
    func renderBestStill(_ candidate: PreviewSweepCandidate) async throws -> CGImage
    /// The evenly-spaced filmstrip for this record (ffmpegDirect only).
    func renderFilmstrip(_ candidate: PreviewSweepCandidate) async throws -> [PreviewFilmstripFrame]
}
