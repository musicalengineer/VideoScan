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

    /// Starvation is not a stall: under heavy disk contention (the
    /// 2026-08-04 false kill — ~20 concurrent Verify Audio probes
    /// starved an mp4 below 50 frames per 5 min) frames still trickle,
    /// and every trickling frame is proof of life. Any frame arriving
    /// more than this long after the last beat emits one immediately,
    /// so only a truly frozen decode (zero frames) can trip the 300 s
    /// watchdog.
    private static let beatMaxIntervalSeconds: Double = 5

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

    /// Decoder/media-matrix test seam: start with already-built centroids
    /// so tests can exercise the real AVFoundation/ffmpeg frame transport
    /// without loading private family photos or a CoreML model. Production
    /// still uses prepare(galleryRoot:) and never calls this initializer.
    init(testEmbedder: @escaping RecipeFaceEmbedder,
         centroids: [RecipeEraCentroid],
         params: RecipeParameters = RecipeParameters(),
         pauseGate: PauseGate? = nil,
         onProgress: RecipeProgressHandler? = nil) {
        self.backend = .adaface
        self.params = params
        self.pauseGate = pauseGate
        self.onProgress = onProgress
        self.embedder = testEmbedder
        self.eraCentroids = centroids
        self.centroidVectors = centroids.map(\.centroid)
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
        /// Which decode path opened the clip — carried into the verdict
        /// so telemetry can report fallback share.
        let transport: String
        let postLoopError: () -> String?
    }

    /// Transport ladder: AVAssetReader (FramePrefetcher; SeekingFrameProvider
    /// for MPEG-TS, where sequential demux wastes ~98% of the work), and
    /// when AVFoundation can't open the clip at all (mkv, DNxHD/MPEG-2
    /// QuickTime, …) an ffmpeg rawvideo pipe — the python engine's
    /// transport. ffmpeg frames arrive pre-rotated (autorotate), so that
    /// path's orientation/transform are identity.
    /// Containers AVFoundation cannot open at all — the doomed open
    /// attempt (0.3–1.5 s each, 45 s worst case through the hang race)
    /// is skipped and the clip goes straight to the ffmpeg transport.
    private static let ffmpegOnlyExtensions: Set<String> = ["mkv", "webm", "mxf"]

    private func openFrameSource(clip: URL, frameInterval: Double) async
        -> Result<FrameSource, RecipeError> {
        let ext = clip.pathExtension.lowercased()
        if Self.ffmpegOnlyExtensions.contains(ext) {
            return await Self.openFFmpegSource(
                clip: clip, frameInterval: frameInterval,
                why: "\(ext) container — AVFoundation skipped")
        }
        switch await Self.openReaderTimed(clip: clip, samplingFPS: params.samplingFPS) {
        case .success(let ctx):
            let stream: AsyncStream<PrefetchedFrame>
            let release: () -> Void
            let transport: String
            let ext = clip.pathExtension.lowercased()
            if ext == "mts" || ext == "m2ts" || ext == "ts" {
                let seeker = SeekingFrameProvider(asset: ctx.asset, duration: ctx.duration,
                                                  frameInterval: frameInterval)
                ctx.reader.cancelReading()
                stream = seeker.frames()
                release = { seeker.releaseSlot() }
                transport = "avfoundation-seek"
            } else {
                let prefetcher = FramePrefetcher(reader: ctx.reader,
                                                 trackOutput: ctx.trackOutput,
                                                 frameInterval: frameInterval)
                stream = prefetcher.frames()
                release = { prefetcher.releaseSlot() }
                transport = "avfoundation"
            }
            return .success(FrameSource(
                stream: stream, release: release, duration: ctx.duration,
                orientation: ctx.orientation, transform: ctx.transform,
                transport: transport,
                postLoopError: {
                    guard ctx.reader.status == .failed else { return nil }
                    return "reader error: \(ctx.reader.error?.localizedDescription ?? "unknown")"
                }))

        case .failure(let openError):
            return await Self.openFFmpegSource(
                clip: clip, frameInterval: frameInterval,
                why: openError.message)
        }
    }

    /// The ffmpeg arm of the transport ladder — reached directly for
    /// ffmpeg-only containers or as the fallback when AVFoundation's
    /// open fails/times out. `why` explains the routing in the log and
    /// in a dual-cause error message.
    private static func openFFmpegSource(clip: URL, frameInterval: Double,
                                         why: String) async
        -> Result<FrameSource, RecipeError> {
        switch await FFmpegFrameProvider.open(clip: clip, frameInterval: frameInterval) {
        case .failure(let ffError):
            return .failure(RecipeError(
                "\(why); ffmpeg fallback: \(ffError.message)"))
        case .success(let provider):
            recipeLog.notice("ffmpeg decode fallback for \(clip.lastPathComponent, privacy: .public) (\(why, privacy: .public))")
            return .success(FrameSource(
                stream: provider.frames(),
                release: { provider.releaseSlot() },
                duration: provider.duration,
                orientation: .up, transform: .identity,
                transport: "ffmpeg",
                postLoopError: {
                    // A consumer-side cancel SIGTERMs ffmpeg (nonzero
                    // exit) — that's not a decode failure, and the job
                    // discards post-cancel results anyway.
                    guard !Task.isCancelled else { return nil }
                    return provider.failureMessage()
                }))
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
        var lastBeatAt = wallStart

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
                    error: "watchdog abort after \(Int(elapsed))s (media \(Int(duration))s)",
                    decodeTransport: source.transport)
            }
            releaseSlot()

            let now = CFAbsoluteTimeGetCurrent()
            if frameCount % Self.beatEveryFrames == 0
                || now - lastBeatAt > Self.beatMaxIntervalSeconds {
                lastBeatAt = now
                let fraction: Double? = duration > 0
                    ? min(frame.presentationTime / duration, 1) : nil
                onProgress?(.beat(clip: clip, frameIndex: frameCount,
                                  fraction: fraction, mediaSeconds: duration))
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
                error: decodeError,
                decodeTransport: source.transport)
        }

        return RecipeClipScore(
            score: RecipeMath.topKMean(cosines, k: params.topK),
            frameCount: frameCount,
            gatedFaceCount: cosines.count,
            decodeTransport: source.transport,
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

    /// @unchecked Sendable: built entirely inside one task and handed
    /// across the timed-open race exactly once; the single consumer
    /// owns every member afterwards (openReaderTimed's abandon rule).
    private struct RecipeReaderContext: @unchecked Sendable {
        let asset: AVURLAsset
        let reader: AVAssetReader
        let trackOutput: AVAssetReaderTrackOutput
        let duration: Double
        let orientation: CGImagePropertyOrientation
        let transform: CGAffineTransform
    }

    /// AVFoundation's open ladder has NO timeout of its own, and a
    /// damaged file can hang `loadTracks`/`load(.duration)` forever —
    /// silently, because a suspended await occupies no thread (the
    /// 2026-08-03 overnight stall: one bad file, zero log lines, whole
    /// job killed by the 315 s watchdog). Race the open against a
    /// deadline and ABANDON the loser: the hung task can't be cancelled
    /// (AVF ignores it), so it leaks one suspended continuation —
    /// bounded, and vastly better than a dead batch. A late-arriving
    /// success is closed out via cancelReading(). On timeout the caller
    /// falls through to the ffmpeg fallback, whose ffprobe is
    /// deadline-bounded — so the worst case per damaged file is
    /// ~timeout + 60 s, well under the job's stall threshold.
    private static func openReaderTimed(clip: URL, samplingFPS: Double,
                                        timeoutSeconds: Double = 45) async
        -> Result<RecipeReaderContext, RecipeError> {
        await withCheckedContinuation { cont in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            // True exactly once — the winner resumes the continuation.
            @Sendable func claimWin() -> Bool {
                resumed.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
            }
            Task.detached {
                let result = await openReader(clip: clip, samplingFPS: samplingFPS)
                if claimWin() {
                    cont.resume(returning: result)
                } else if case .success(let ctx) = result {
                    // Lost the race but the open eventually finished —
                    // close the orphaned reader instead of leaking it.
                    ctx.reader.cancelReading()
                }
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                if claimWin() {
                    recipeLog.error("AVFoundation open hang on \(clip.lastPathComponent, privacy: .public) — abandoned after \(Int(timeoutSeconds))s")
                    cont.resume(returning: .failure(
                        RecipeError("open timed out after \(Int(timeoutSeconds))s (AVFoundation hang)")))
                }
            }
        }
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
