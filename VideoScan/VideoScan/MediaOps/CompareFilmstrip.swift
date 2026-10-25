// CompareFilmstrip.swift
// Compare Media, the film half (Rick 2026-10-22): eight small frames per
// file, at the SAME fractions of each file's length on both sides
// (1/16, 3/16 … 15/16), laid directly over the sound strip so frame i
// sits over the stretch of seconds it shows. A click plays the file.
//
//   ┌──┬──┬──┬──┬──┬──┬──┬──┐   CompareFilmstripView (8 cells)
//   ▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌▌   SoundStrip (same width)
//
// Shape:
//   CompareFilmstripPlan   pure: the positions, the cache key, what stops
//                          the strip before any decode (no picture, no
//                          length, drive offline).
//   CompareFilmstripLoader @MainActor, one per card, owned by the view
//                          (@StateObject); its load runs inside the view's
//                          `.task`, so leaving the view cancels it.
//   Frames come from PreviewFrameRenderer.renderFramesAtOffsets — the
//   preview pane's routed tiers (AVF batch → bounded ffmpeg rips through
//   ProcessRunner), in its fixed-positions mode. No frame code here.
//
// Cache: the app's L1 thumbnail NSCache (PreviewService.thumbnailCache),
// under keys that can never collide with its fullPath keys: the disk
// cache's (path, mtime, size) key + "#compare-<millis>". A changed file
// has a new signature, so a stale frame can never be served.
//
// Memory: ≤8 frames per card at ≤480 wide (~0.5 MB each decoded) → ~8 MB
// for a pair while the view is up; the NSCache copy is cost-accounted and
// evictable (8 GB policy). Nothing here is per catalog record.

import AppKit
import Combine
import SwiftUI
import VideoScanCore

/// Why a whole strip shows grey cells instead of pictures.
enum CompareFilmstripBlank: Equatable {
    case noPicture, lengthUnknown, driveOffline, fileMissing, unreadable, noFFmpeg

    var words: String {
        switch self {
        case .noPicture: return "no picture (sound only)"
        case .lengthUnknown: return "length unknown"
        case .driveOffline: return "drive offline"
        case .fileMissing: return "file missing"
        case .unreadable: return "pictures could not be read"
        case .noFFmpeg: return "ffmpeg not found"
        }
    }
}

/// The pure half: where the frames go and what stops them. No I/O.
enum CompareFilmstripPlan {
    /// Frames per card.
    static let frameCount = 8

    /// Centered fractions: (i + 0.5) / count → 1/16, 3/16 … 15/16 for 8.
    /// Frame i is the middle of the i-th eighth of the strip below it.
    static func fractions(count: Int = frameCount) -> [Double] {
        guard count > 0 else { return [] }
        return (0..<count).map { (Double($0) + 0.5) / Double(count) }
    }

    /// The seconds to show for a file this long — always `count` slots, so
    /// both cards line up slot for slot (the preview pane's planner dedupes
    /// short files, which would shift the slots). [] for a length that is
    /// not finite, not positive, or absurd (the same guard as the cache's).
    static func offsets(durationSeconds: Double, count: Int = frameCount) -> [Double] {
        guard durationSeconds.isFinite, durationSeconds > 0,
              durationSeconds <= previewMaxSaneDurationSeconds else { return [] }
        return fractions(count: count).map { $0 * durationSeconds }
    }

    /// The slot a landed frame belongs to: the nearest planned offset (the
    /// AVF batch reports its requested time back through CMTime ticks, so
    /// it is only ≈ the planned value).
    static func slot(forOffset offset: Double, in offsets: [Double]) -> Int? {
        guard offset.isFinite else { return nil }
        return offsets.indices.min { abs(offsets[$0] - offset) < abs(offsets[$1] - offset) }
    }

    /// Key in the shared thumbnail NSCache. That cache's own keys are bare
    /// full paths; this one starts with the disk cache's signature key, so
    /// the two can never meet, and a changed file misses.
    static func cacheKey(signatureKey: String, offsetSeconds: Double) -> String {
        "\(signatureKey)#compare-\(Int((offsetSeconds * 1000).rounded()))"
    }

    /// What stops the strip before any file is opened, in the order a
    /// person would say it. nil = go ahead.
    static func blocker(hasPicture: Bool, offsets: [Double], volumeMounted: Bool) -> CompareFilmstripBlank? {
        if !hasPicture { return .noPicture }
        if offsets.isEmpty { return .lengthUnknown }
        if !volumeMounted { return .driveOffline }
        return nil
    }

    /// How a render error reads on the card. Cancellation is not a failure
    /// and says nothing (nil).
    static func blank(for error: Error) -> CompareFilmstripBlank? {
        if error is CancellationError { return nil }
        if (error as? PreviewFrameError) == .ffmpegUnavailable { return .noFFmpeg }
        return .unreadable
    }
}

/// One card's request: the record's fields as Sendable values (a
/// VideoRecord never leaves the main actor).
struct CompareFilmstripRequest: Sendable {
    let item: PreviewService.FilmstripWorkItem
    let hasPicture: Bool
    var ffmpegPath: String = ToolLocator.ffmpegPath

    @MainActor
    init(record: VideoRecord) {
        item = PreviewService.FilmstripWorkItem(record: record)
        hasPicture = record.streamType != .audioOnly && record.streamType != .noStreams
    }

    init(item: PreviewService.FilmstripWorkItem, hasPicture: Bool, ffmpegPath: String = ToolLocator.ffmpegPath) {
        self.item = item
        self.hasPicture = hasPicture
        self.ffmpegPath = ffmpegPath
    }
}

/// One cell of the strip.
enum CompareFilmstripCell {
    /// Not decoded yet: a grey placeholder.
    case waiting
    case picture(NSImage)
    /// Tried and nothing came back for this position (or the whole strip
    /// is blank — the loader's `blank` says why once).
    case empty

    var image: NSImage? {
        if case .picture(let image) = self { return image }
        return nil
    }
}

/// Loads one card's frames. `@MainActor` ≈ "only touched on the UI
/// thread"; the decode itself runs on the renderer's `@concurrent` pool.
@MainActor
final class CompareFilmstripLoader: ObservableObject {
    @Published private(set) var cells: [CompareFilmstripCell] =
        Array(repeating: .waiting, count: CompareFilmstripPlan.frameCount)
    @Published private(set) var blank: CompareFilmstripBlank?
    private(set) var offsets: [Double] = []
    /// The current run's cache and signature key (main-actor state, so the
    /// renderer's @Sendable frame callback never has to carry the cache).
    private var cache: NSCache<NSString, NSImage>?
    private var signatureKey = ""
    /// Identifies the current load so a superseded run's late frames
    /// (hops queued before a cancel) cannot land in a newer strip.
    private var generation = UUID()

    /// The whole load, awaited by the view's `.task` (structured: the
    /// view going away cancels the decode and its ffmpeg children).
    /// `isVolumeMounted` is the reachability seam (tests pass a fake).
    func load(_ request: CompareFilmstripRequest, cache: NSCache<NSString, NSImage>,
              isVolumeMounted: (String) -> Bool = { VolumeReachability.isVolumeReachable(path: $0) }) async {
        let run = UUID()
        generation = run
        let path = request.item.path
        offsets = CompareFilmstripPlan.offsets(durationSeconds: request.item.durationSeconds)
        cells = Array(repeating: .waiting, count: CompareFilmstripPlan.frameCount)
        blank = nil
        self.cache = nil
        if let stop = CompareFilmstripPlan.blocker(hasPicture: request.hasPicture, offsets: offsets,
                                                   volumeMounted: isVolumeMounted(path)) {
            return finish(stop)
        }
        // One stat, off the main actor (a spun-down disk can take seconds).
        let signature = await Task.detached(priority: .userInitiated) {
            PreviewDiskCache.fileSignature(atPath: path)
        }.value
        guard !Task.isCancelled, generation == run else { return }
        guard let signature else { return finish(.fileMissing) }
        self.cache = cache
        signatureKey = PreviewDiskCache.cacheKey(path: path, mtime: signature.mtime, size: signature.size)
        let wanted = fillFromCache()
        guard !wanted.isEmpty else { return }
        await render(request, offsets: wanted, run: run)
    }

    /// The renderer's fixed-positions mode for the offsets the cache did
    /// not have; each frame fills its cell as it lands.
    private func render(_ request: CompareFilmstripRequest, offsets wanted: [Double], run: UUID) async {
        let item = request.item
        do {
            let frames = try await PreviewFrameRenderer.renderFramesAtOffsets(
                path: item.path, container: item.container, videoCodec: item.videoCodec,
                likelyUnanalyzable: item.likelyUnanalyzable, offsets: wanted,
                ffmpegPath: request.ffmpegPath,
                onFrame: { [weak self] offset, image in
                    Task { @MainActor in self?.place(offset, image, run: run) }
                })
            // The hops above may still be queued: place every frame now
            // (idempotent), then mark what never came as empty.
            for frame in frames { place(frame.offsetSeconds, frame.image, run: run) }
            guard generation == run else { return }
            cells = cells.map { $0.image == nil ? .empty : $0 }
        } catch {
            guard generation == run, let why = CompareFilmstripPlan.blank(for: error) else { return }
            finish(why)
        }
    }

    /// Cells the cache already holds; returns the offsets still to decode.
    private func fillFromCache() -> [Double] {
        var wanted: [Double] = []
        for (i, offset) in offsets.enumerated() {
            let key = CompareFilmstripPlan.cacheKey(signatureKey: signatureKey, offsetSeconds: offset) as NSString
            if let hit = cache?.object(forKey: key) {
                cells[i] = .picture(hit)
            } else {
                wanted.append(offset)
            }
        }
        return wanted
    }

    private func place(_ offset: Double, _ image: CGImage, run: UUID) {
        guard generation == run, let i = CompareFilmstripPlan.slot(forOffset: offset, in: offsets),
              cells[i].image == nil else { return }
        let ns = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        cells[i] = .picture(ns)
        cache?.setObject(ns, forKey: CompareFilmstripPlan.cacheKey(signatureKey: signatureKey, offsetSeconds: offsets[i]) as NSString,
                        cost: ThumbnailCachePolicy.estimatedCost(pixelsWide: image.width, pixelsHigh: image.height))
    }

    private func finish(_ why: CompareFilmstripBlank) {
        blank = why
        cells = cells.map { $0.image == nil ? .empty : $0 }
    }
}

/// Eight cells across the card's width, the same width as the sound strip
/// below. Grey while waiting; the reason once, centered, when the whole
/// strip is blank. A picture plays the file on click.
struct CompareFilmstripView: View {
    @ObservedObject var loader: CompareFilmstripLoader
    let onPlay: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(loader.cells.enumerated()), id: \.offset) { index, cell in
                cellView(cell, index: index)
            }
        }
        .frame(height: 34)
        .overlay {
            if let blank = loader.blank {
                Text(blank.words).font(.system(size: 10)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.85), in: Capsule())
            }
        }
        .accessibilityIdentifier("compareMedia.filmstrip")
    }

    @ViewBuilder
    private func cellView(_ cell: CompareFilmstripCell, index: Int) -> some View {
        // Color sets the cell's size; the picture fills it and is clipped —
        // ≈ a fixed-size viewport the image is drawn into.
        let base = Color.gray.opacity(cell.image == nil ? 0.18 : 0.0)
        if let image = cell.image {
            base.overlay(Image(nsImage: image).resizable().scaledToFill())
                .clipped()
                .padding(.horizontal, 0.5)
                .contentShape(Rectangle())
                .onTapGesture(perform: onPlay)
                .help(helpText(index))
        } else {
            base.padding(.horizontal, 0.5)
        }
    }

    private func helpText(_ index: Int) -> String {
        let at = loader.offsets.indices.contains(index) ? RelatedLadder.mmss(loader.offsets[index]) : "?"
        return "Frame at \(at). Click to play this file (the player opens at the start)."
    }
}
