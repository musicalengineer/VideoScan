// NativeRecipeScorer.swift
// Swift-native Donna-recipe engine behind the RecipeScoring seam
// (docs/find-and-tag-design.md). Replicates the python reference scorer
// (tools/donna-recipe/recipe_smoke.py) stage for stage, on the app's own
// stack:
//
//     python (reference)                     native (this file)
//     ─────────────────────────────────────  ─────────────────────────────
//     ffmpeg yadif,fps=2 → jpgs              AVAssetReader via FramePrefetcher
//                                            (SeekingFrameProvider for TS;
//                                            FFmpegFrameProvider rawvideo
//                                            pipe when AVFoundation can't
//                                            open the clip — mkv, MPEG-2)
//     SCRFD-10G detect                       Vision VNDetectFaceRectangles r3
//     size gates ≥25px record / ≥60px vote   identical (RecipeMath, px tiers
//                                            are geometry, portable)
//     sex gate (genderage, keep F)           NOT AVAILABLE — see gap below
//     ArcFace-w600k (insightface) embed      app AdaFace/ArcFace CoreML path
//                                            (arcfaceFaceCrop + arcfaceEmbedding)
//     max cosine vs era centroids            identical (RecipeMath.maxCosine)
//     top-5 mean per clip                    identical (RecipeMath.topKMean)
//
// KNOWN GAPS vs the reference (deliberate for this pass; each measured by
// the calibration CLI rather than assumed):
//  - No sex gate. Vision exposes no sex attribute; the python engine's
//    genderage model arrives later as a converted CoreML attribute gate.
//    Expected impact: male faces can contribute cosines, lifting NotDonna
//    clip scores somewhat — the calibration AUC shows how much.
//  - No deinterlacing on the AVAssetReader path — it decodes fields as
//    stored (python ran yadif). Combing mainly degrades detection on
//    interlaced sources; revisit if G3's interlaced tier underperforms.
//    (Clips decoded via the FFmpegFrameProvider fallback DO get yadif.)
//  - Detector class: Vision r3 vs SCRFD-10G. SCRFD was chosen for small
//    faces (the 17-point Hard-set gap); Vision may drop some record-tier
//    faces SCRFD catches. Again: measured, not assumed.
//
// THRESHOLDS ARE NOT PORTABLE across embedding spaces — every cosine bar
// is injected via RecipeParameters; see the calibration NOTE in
// RecipeScoring.swift.
//
// Memory (worst case per clip): FramePrefetcher buffers ≤16 decoded frames
// (~48 MB at 1080p YpCbCr, ~200 MB at 4K — same budget as the person-finder
// pipeline it copies) + one oriented CGImage + one 112×112 crop in flight
// inside the per-frame autoreleasepool. Retained across frames: ONLY
// Double cosines (8 B per gated face) and the era centroids (512 floats
// per era). No embeddings are persisted anywhere (POI cycle-2 rule).

import AVFoundation
import CoreGraphics
import CoreML
import Foundation
import ImageIO
import os
import Vision

private let recipeLog = Logger(subsystem: "Rick-Breen.VideoScan",
                               category: "recipe")

/// Which CoreML embedding backend the scorer uses. Both are selectable;
/// vectors from the two are NOT comparable (see FaceEmbeddingBackend).
/// MEASURED 2026-08-02 (--recipe-calibrate, DonnaTestVideos, no sex
/// gate): ArcFace AUC 0.944 (0.954 at bar 0.65) vs AdaFace 0.856 —
/// AdaFace's quality-adaptive margin did NOT win on this corpus despite
/// the low-quality-face hypothesis, so the job's native arm runs ArcFace
/// until a re-measure (e.g. after the genderage gate lands) says
/// otherwise.
enum RecipeEmbeddingBackend: String, Sendable, CaseIterable {
    case adaface
    case arcface
}

/// Embeds one detected face from a full oriented frame/photo. Injected so
/// centroid building and scoring math are testable without CoreML.
typealias RecipeFaceEmbedder =
    (_ image: CGImage, _ face: VNFaceObservation) -> [Float]?

/// `actor` ≈ a class with an implicit mutex around all members — prepare
/// and score are serialized, which is exactly the contract FindPersonJob
/// uses (one clip at a time; MLE5 concurrency rules stay satisfied because
/// every prediction also goes through the global serialization lock).
actor NativeRecipeScorer: RecipeScoring {

    private let params: RecipeParameters
    private let backend: RecipeEmbeddingBackend
    private let onProgress: RecipeProgressHandler?
    /// Cooperative pause shared with the owning job (nil = never pauses,
    /// e.g. the calibration CLI).
    private let pauseGate: PauseGate?

    private var embedder: RecipeFaceEmbedder?
    private var eraCentroids: [RecipeEraCentroid] = []
    private var centroidVectors: [[Float]] = []

    /// Heartbeat cadence — matches the python bridge's BEAT_EVERY so the
    /// job's stall watchdog sees the same rhythm from both engines.
    private static let beatEveryFrames = 50

    /// Production init: embedder comes from the CoreML backend, resolved
    /// lazily in prepare() (model load is the slow part and belongs in the
    /// job's "warming up" phase).
    init(backend: RecipeEmbeddingBackend,
         params: RecipeParameters = RecipeParameters(),
         pauseGate: PauseGate? = nil,
         onProgress: RecipeProgressHandler? = nil) {
        self.backend = backend
        self.params = params
        self.pauseGate = pauseGate
        self.onProgress = onProgress
    }

    /// Test seam: inject the embedder, skip CoreML entirely.
    init(embedder: @escaping RecipeFaceEmbedder,
         params: RecipeParameters = RecipeParameters(),
         pauseGate: PauseGate? = nil,
         onProgress: RecipeProgressHandler? = nil) {
        self.backend = .adaface
        self.params = params
        self.pauseGate = pauseGate
        self.onProgress = onProgress
        self.embedder = embedder
    }

    // MARK: - Prepare (model + era centroids)

    func prepare(galleryRoot: URL) async throws -> Int {
        if embedder == nil {
            onProgress?(.preparing(detail: "Loading \(backend.rawValue) model…"))
            let (model, err): (MLModel?, String?)
            switch backend {
            case .adaface: (model, err) = await AdaFaceModelLoader.shared.getModel()
            case .arcface: (model, err) = await ArcFaceModelLoader.shared.getModel()
            }
            guard let model else {
                throw RecipeError("\(backend.rawValue) model load failed: \(err ?? "unknown")")
            }
            // useSharedPool false for BOTH backends: the ArcFace K>1 pool
            // holds ArcFace instances (an AdaFace borrow would infer
            // against the wrong network), and the recipe embeds one face
            // at a time anyway — the serialized global-lock path is the
            // proven-safe MLE5 configuration.
            embedder = { image, obs in
                guard let crop = arcfaceFaceCrop(from: image, observation: obs,
                                                 useLandmarkAlignment: true) else { return nil }
                return arcfaceEmbedding(from: crop, model: model,
                                        useSharedPool: false).embedding
            }
        }

        onProgress?(.preparing(detail: "Building era reference centroids…"))
        let centroids = RecipeGallery.buildEraCentroids(galleryRoot: galleryRoot) { url in
            self.embedSingleVotableFace(photo: url)
        }
        guard !centroids.isEmpty else {
            throw RecipeError("gallery produced no centroids (\(galleryRoot.path))")
        }
        eraCentroids = centroids
        centroidVectors = centroids.map(\.centroid)
        recipeLog.info("recipe centroids ready: \(centroids.map(\.era).joined(separator: ", "), privacy: .public)")
        onProgress?(.ready(eras: centroids.map(\.era)))
        return centroids.count
    }

    /// Embedding for the single votable face in a reference photo, or nil
    /// to skip it (group shot, small face, unreadable). Mirrors the
    /// python gallery rule: exactly one detected face, short side ≥ votePx.
    private func embedSingleVotableFace(photo: URL) -> [Float]? {
        guard let embedder,
              let img = Self.loadOrientedImage(photo) else { return nil }
        let req = VNDetectFaceRectanglesRequest()
        req.revision = 3
        let handler = VNImageRequestHandler(cgImage: img, options: [:])
        try? handler.perform([req])
        let candidates = (req.results ?? []).filter {
            $0.confidence >= params.minFaceConfidence
        }
        guard candidates.count == 1, let obs = candidates.first else { return nil }
        guard Self.faceSidePx(obs, imageWidth: img.width, imageHeight: img.height)
            >= params.votePx else { return nil }
        return embedder(img, obs)
    }

    /// EXIF-honoring photo load (python side used PIL's exif_transpose;
    /// a plain CGImageSourceCreateImageAtIndex would hand Vision sideways
    /// iPhone gallery photos). Thumbnail-with-transform at full pixel size
    /// applies the rotation; falls back to the raw image.
    private static func loadOrientedImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1)
        ]
        if let oriented = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) {
            return oriented
        }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Short bbox side in source pixels — the python face_px() analogue.
    /// Vision boxes are normalized to the oriented image.
    private static func faceSidePx(_ obs: VNFaceObservation,
                                   imageWidth: Int, imageHeight: Int) -> Int {
        Int(min(obs.boundingBox.width * CGFloat(imageWidth),
                obs.boundingBox.height * CGFloat(imageHeight)))
    }

    // MARK: - Score one clip

    /// One clip's frame source, whichever transport opened it. `release`
    /// returns a lent buffer slot; `postLoopError` is the source-specific
    /// failure check after the frame loop (reader status vs ffmpeg exit),
    /// nil when the decode ended cleanly.
    private struct FrameSource {
        let stream: AsyncStream<PrefetchedFrame>
        let release: () -> Void
        let duration: Double
        let orientation: CGImagePropertyOrientation
        let transform: CGAffineTransform
        let postLoopError: () -> String?
    }

    /// Transport ladder: AVAssetReader (FramePrefetcher; SeekingFrameProvider
    /// for MPEG-TS, where sequential demux wastes ~98% of the work), and
    /// when AVFoundation can't open the clip at all (mkv, DNxHD/MPEG-2
    /// QuickTime, …) an ffmpeg rawvideo pipe — the python engine's
    /// transport. ffmpeg frames arrive pre-rotated (autorotate), so that
    /// path's orientation/transform are identity.
    private func openFrameSource(clip: URL, frameInterval: Double) async
        -> Result<FrameSource, RecipeError> {
        switch await Self.openReader(clip: clip, samplingFPS: params.samplingFPS) {
        case .success(let ctx):
            let stream: AsyncStream<PrefetchedFrame>
            let release: () -> Void
            let ext = clip.pathExtension.lowercased()
            if ext == "mts" || ext == "m2ts" || ext == "ts" {
                let seeker = SeekingFrameProvider(asset: ctx.asset, duration: ctx.duration,
                                                  frameInterval: frameInterval)
                ctx.reader.cancelReading()
                stream = seeker.frames()
                release = { seeker.releaseSlot() }
            } else {
                let prefetcher = FramePrefetcher(reader: ctx.reader,
                                                 trackOutput: ctx.trackOutput,
                                                 frameInterval: frameInterval)
                stream = prefetcher.frames()
                release = { prefetcher.releaseSlot() }
            }
            return .success(FrameSource(
                stream: stream, release: release, duration: ctx.duration,
                orientation: ctx.orientation, transform: ctx.transform,
                postLoopError: {
                    guard ctx.reader.status == .failed else { return nil }
                    return "reader error: \(ctx.reader.error?.localizedDescription ?? "unknown")"
                }))

        case .failure(let openError):
            switch await FFmpegFrameProvider.open(clip: clip, frameInterval: frameInterval) {
            case .failure(let ffError):
                return .failure(RecipeError(
                    "\(openError.message); ffmpeg fallback: \(ffError.message)"))
            case .success(let provider):
                recipeLog.notice("ffmpeg decode fallback for \(clip.lastPathComponent, privacy: .public) (\(openError.message, privacy: .public))")
                return .success(FrameSource(
                    stream: provider.frames(),
                    release: { provider.releaseSlot() },
                    duration: provider.duration,
                    orientation: .up, transform: .identity,
                    postLoopError: {
                        // A consumer-side cancel SIGTERMs ffmpeg (nonzero
                        // exit) — that's not a decode failure, and the job
                        // discards post-cancel results anyway.
                        guard !Task.isCancelled else { return nil }
                        return provider.failureMessage()
                    }))
            }
        }
    }

    func score(clip: URL) async -> RecipeClipScore {
        guard embedder != nil, !centroidVectors.isEmpty else {
            return RecipeClipScore(error: "scorer not prepared (no centroids)")
        }
        let source: FrameSource
        switch await openFrameSource(clip: clip, frameInterval: 1.0 / params.samplingFPS) {
        case .failure(let error):
            return RecipeClipScore(error: error.message)
        case .success(let opened):
            source = opened
        }
        let duration = source.duration
        let releaseSlot = source.release

        var cosines: [Double] = []
        var samples: [RecipeFaceSample] = []
        var frameCount = 0
        let wallStart = CFAbsoluteTimeGetCurrent()

        for await frame in source.stream {
            // Break, never cancelReading(): the consumer-side cancel races
            // the producer's in-flight copyNextSampleBuffer and crashes in
            // CoreMedia (same fix as pfProcessVideo).
            if Task.isCancelled { break }
            let elapsed = CFAbsoluteTimeGetCurrent() - wallStart
            if pfShouldAbortForWatchdog(elapsedSecs: elapsed, mediaSecs: duration) {
                releaseSlot()
                return RecipeClipScore(
                    frameCount: frameCount, gatedFaceCount: cosines.count,
                    error: "watchdog abort after \(Int(elapsed))s (media \(Int(duration))s)")
            }
            releaseSlot()

            if frameCount % Self.beatEveryFrames == 0 {
                onProgress?(.beat(clip: clip, frameIndex: frameCount))
            }

            processFrame(frame, orientation: source.orientation,
                         transform: source.transform,
                         cosines: &cosines, samples: &samples)
            frameCount += 1

            if frameCount % 5 == 0, let gate = pauseGate {
                await gate.waitIfPaused()
                if Task.isCancelled { break }
            }
        }

        if let decodeError = source.postLoopError() {
            return RecipeClipScore(
                frameCount: frameCount, gatedFaceCount: cosines.count,
                error: decodeError)
        }

        return RecipeClipScore(
            score: RecipeMath.topKMean(cosines, k: params.topK),
            frameCount: frameCount,
            gatedFaceCount: cosines.count,
            faceSamples: params.collectFaceSamples ? samples : nil)
    }

    /// One frame's detect → embed → gate pass. Everything transient
    /// (detect results, oriented CGImage, crop, embedding) lives and dies
    /// inside the autoreleasepool — project memory rule for media loops.
    private func processFrame(_ frame: PrefetchedFrame,
                              orientation: CGImagePropertyOrientation,
                              transform: CGAffineTransform,
                              cosines: inout [Double],
                              samples: inout [RecipeFaceSample]) {
        autoreleasepool {
            let faces = pfDetectFacesInBuffer(frame.pixelBuffer,
                                              orientation: orientation,
                                              longEdgeCap: pfDetectionLongEdgeCap)
            let candidates = faces.filter { $0.confidence >= params.minFaceConfidence }
            guard !candidates.isEmpty,
                  let img = pfOrientedCGImage(from: frame.pixelBuffer,
                                              transform: transform),
                  let embedder = self.embedder else { return }
            for obs in candidates {
                let px = Self.faceSidePx(obs, imageWidth: img.width,
                                         imageHeight: img.height)
                guard px >= params.recordPx else { continue }
                // Sex gate would run here (python: keep F only) —
                // unavailable natively until the genderage conversion
                // lands. See the gap note in the file header.
                guard let embedding = embedder(img, obs) else { continue }
                let cos = RecipeMath.maxCosine(embedding, centroids: centroidVectors)
                if params.collectFaceSamples {
                    samples.append(RecipeFaceSample(sidePx: px, cosine: cos))
                }
                guard RecipeMath.passesTierGate(sidePx: px, cosine: cos,
                                                params: params) else { continue }
                cosines.append(cos)
            }
        }
    }

    // MARK: - Reader setup

    private struct RecipeReaderContext {
        let asset: AVURLAsset
        let reader: AVAssetReader
        let trackOutput: AVAssetReaderTrackOutput
        let duration: Double
        let orientation: CGImagePropertyOrientation
        let transform: CGAffineTransform
    }

    /// Same setup ladder as openArcFaceVideoReader, with failures returned
    /// as data (per-clip errors keep the job going — python parity).
    private static func openReader(clip: URL, samplingFPS: Double) async
        -> Result<RecipeReaderContext, RecipeError> {
        let asset = AVURLAsset(url: clip,
                               options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let videoTrack: AVAssetTrack
        let duration: Double
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                return .failure(RecipeError("no video track"))
            }
            videoTrack = track
            duration = CMTimeGetSeconds(try await asset.load(.duration))
        } catch {
            return .failure(RecipeError("open failed: \(error.localizedDescription)"))
        }
        guard duration > 0 else { return .failure(RecipeError("zero-duration clip")) }

        let transform: CGAffineTransform
        do {
            transform = try await videoTrack.load(.preferredTransform)
        } catch {
            return .failure(RecipeError("can't load transform: \(error.localizedDescription)"))
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            return .failure(RecipeError("AVAssetReader: \(error.localizedDescription)"))
        }
        let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        trackOutput.alwaysCopiesSampleData = false
        reader.add(trackOutput)
        guard reader.startReading() else {
            return .failure(RecipeError("AVAssetReader failed to start"))
        }
        return .success(RecipeReaderContext(
            asset: asset, reader: reader, trackOutput: trackOutput,
            duration: duration,
            orientation: pfOrientationFromTransform(transform),
            transform: transform))
    }
}
