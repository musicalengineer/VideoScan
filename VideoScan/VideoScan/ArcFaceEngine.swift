// ArcFaceEngine.swift
// CoreML-based ArcFace face recognition engine for VideoScan.
// Uses Vision for face detection (ANE), ArcFace w600k_r50 for 512-D identity embeddings.

import Foundation
import CoreML
import Vision
import CoreImage
import CoreGraphics
import AVFoundation
import os

// MARK: - Global serialization lock for MLModel.prediction(from:)
//
// Apple's docs say distinct MLModel instances are safe across threads.
// In practice — confirmed by crash 2026-05-12 19:16 with full stack
// `arcfaceEmbedding → MLModel.predictionFromFeatures → MLE5BindEmptyMemoryObjectToPort`
// — heavy concurrent inference still trips MLE5 even when each call uses
// its own MLModel.
//
// This lock serializes ALL `model.prediction(from:)` calls in our app.
// Cost: predictions execute sequentially instead of in parallel. The
// reference-embedding cache in ScanJob (computed once per job) reduces
// total prediction count by ~100×, so the serialization cost should be
// minor in practice.
//
// If a future Apple SDK fixes MLE5 concurrency, this can be replaced
// with a no-op or removed.
nonisolated(unsafe) let arcfacePredictionLock = OSAllocatedUnfairLock()

private let arcfaceLogger = Logger(subsystem: "Rick-Breen.VideoScan", category: "ArcFace")

nonisolated(unsafe) private var arcfaceExceptionCount = 0
private let arcfaceExceptionCountLock = OSAllocatedUnfairLock()

// MARK: - ObjC Exception Catcher (Swift-visible wrapper)

/// Runs `block` and catches any ObjC NSException. Returns the exception
/// if one fired, nil on success. Bridging-header function `VSCatchObjCException`
/// does the actual @try/@catch; this wrapper re-exports it so tests can
/// reach it via `@testable import VideoScan`.
func catchObjCException(_ block: () -> Void) -> NSException? {
    var caught: NSException?
    let ok = VSCatchObjCException(block, &caught)
    return ok ? nil : caught
}

// MARK: - ArcFace CoreML Model Singleton

/// Resolves the compiled w600k_r50 CoreML model URL on first call (caching the
/// expensive compilation step), then constructs a FRESH MLModel instance on
/// every subsequent `getModel()` call.
///
/// Why a fresh instance each time: CoreML's MLE5 engine is NOT safe to share
/// across concurrent inference calls. A single `MLModel` instance with two
/// worker threads calling `prediction(from:)` simultaneously can throw
/// `MLE5BindEmptyMemoryObjectToPort` (the output port binding races). Apple's
/// docs document that distinct MLModel instances ARE safe across threads.
///
/// The expensive bit is the .mlpackage → .mlmodelc compilation, which we cache
/// in ~/dev/VideoScan/models/ on disk. Constructing an MLModel from an existing
/// .mlmodelc is fast (~10-50ms), so per-job loads are cheap.
///
/// Thread-safe via actor isolation. See memory note
/// `project_arcface_concurrency_bug.md` for the bug history.
actor ArcFaceModelLoader {
    static let shared = ArcFaceModelLoader()

    /// Cached URL of the compiled .mlmodelc — resolved on first successful
    /// load and reused across all subsequent getModel() calls.
    private var compiledURL: URL?

    /// Returns a freshly-constructed MLModel, or nil with an error message.
    /// Safe to call from multiple jobs concurrently — each gets its own instance,
    /// which avoids the MLE5BindEmptyMemoryObjectToPort race seen when worker
    /// threads inferred against a single shared MLModel.
    func getModel() -> (MLModel?, String?) {
        if let url = compiledURL {
            // Fast path: URL already resolved — just rebuild the MLModel.
            let config = MLModelConfiguration()
            config.computeUnits = .all
            do {
                let loaded = try MLModel(contentsOf: url, configuration: config)
                return (loaded, nil)
            } catch {
                // Cached URL no longer valid (file moved/deleted) — fall through
                // to re-resolve below.
                compiledURL = nil
            }
        }

        let modelsDir = NSHomeDirectory() + "/dev/VideoScan/models"
        let compiledPath = modelsDir + "/w600k_r50.mlmodelc"
        let packagePath = modelsDir + "/w600k_r50.mlpackage"
        let fm = FileManager.default

        // 1. Try pre-compiled .mlmodelc first (fastest)
        if fm.fileExists(atPath: compiledPath) {
            do {
                let url = URL(fileURLWithPath: compiledPath)
                let config = MLModelConfiguration()
                config.computeUnits = .all
                let loaded = try MLModel(contentsOf: url, configuration: config)
                self.compiledURL = url
                return (loaded, nil)
            } catch {
                // Fall through to try compiling from .mlpackage
            }
        }

        // 2. Compile .mlpackage → .mlmodelc at runtime
        if fm.fileExists(atPath: packagePath) {
            do {
                let compiledTempURL = try MLModel.compileModel(at: URL(fileURLWithPath: packagePath))
                // Move compiled model to our models/ directory for next time
                let destURL = URL(fileURLWithPath: compiledPath)
                if fm.fileExists(atPath: compiledPath) {
                    try? fm.removeItem(at: destURL)
                }
                try fm.moveItem(at: compiledTempURL, to: destURL)

                let config = MLModelConfiguration()
                config.computeUnits = .all
                let loaded = try MLModel(contentsOf: destURL, configuration: config)
                self.compiledURL = destURL
                return (loaded, nil)
            } catch {
                return (nil, "Failed to compile ArcFace model: \(error.localizedDescription)")
            }
        }

        // 3. Also check app bundle
        if let bundlePath = Bundle.main.path(forResource: "w600k_r50", ofType: "mlmodelc") {
            do {
                let url = URL(fileURLWithPath: bundlePath)
                let config = MLModelConfiguration()
                config.computeUnits = .all
                let loaded = try MLModel(contentsOf: url, configuration: config)
                self.compiledURL = url
                return (loaded, nil)
            } catch {
                return (nil, "Failed to load bundled ArcFace model: \(error.localizedDescription)")
            }
        }

        return (nil, "ArcFace model not found. Place w600k_r50.mlpackage in ~/dev/VideoScan/models/ and restart.")
    }

    func reset() { compiledURL = nil }
}

// MARK: - Embedding Extraction

/// Extract a 512-D ArcFace embedding from a face crop (any size — will be resized to 112x112).
/// One locked ArcFace prediction attempt with the MLE5 ObjC-exception firewall.
/// Runs `model.prediction(from:)` under `lock`, catching any NSException that
/// CoreML's MLE5 engine would otherwise turn into a SIGABRT. Returns the output
/// (nil on failure), any Swift error, and whether an NSException fired (the
/// instability signal the caller uses to retry / count a drop).
private func arcfacePredictAttempt(
    input: MLFeatureProvider, model: MLModel, lock: OSAllocatedUnfairLock<Void>,
    attempt: Int, maxAttempts: Int
) -> (output: MLFeatureProvider?, swiftError: (any Error)?, exceptionFired: Bool) {
    var output: MLFeatureProvider?
    var swiftError: (any Error)?
    let ok: Bool = lock.withLock {
        var caughtException: NSException?
        let success = VSCatchObjCException({
            do {
                output = try model.prediction(from: input)
            } catch {
                swiftError = error
            }
        }, &caughtException)
        if !success {
            let n = arcfaceExceptionCountLock.withLock { arcfaceExceptionCount += 1; return arcfaceExceptionCount }
            let name = caughtException?.name.rawValue ?? "unknown"
            let reason = caughtException?.reason ?? "no reason"
            let info = caughtException?.userInfo?.description ?? "none"
            let msg = "⚠️ CoreML NSException caught (#\(n), attempt \(attempt)/\(maxAttempts), would have been SIGABRT) — name: \(name), reason: \(reason), userInfo: \(info)"
            arcfaceLogger.error("\(msg, privacy: .public)")
            appLog.write(msg)
            // First-occurrence-only greppable marker so a degraded run is
            // one grep away in videoscan.log.
            if n == 1 {
                let warn = "⚠️ ARCFACE_MLE5_INSTABILITY first occurrence — recognition may under-detect"
                arcfaceLogger.warning("\(warn, privacy: .public)")
                appLog.write(warn)
            }
        }
        return success
    }
    return (output, swiftError, !ok)
}

/// Computes the 512-D ArcFace embedding for a face crop.
///
/// Returns `(embedding, instabilityDrop)`. `embedding` is nil when no usable
/// embedding could be produced. `instabilityDrop` is true ONLY when the face
/// was lost because CoreML's MLE5 engine threw an ObjC NSException on every
/// attempt (the "silent drop" failure mode) — callers use it to surface a
/// degraded run instead of under-detecting silently (P0-2). Setup failures and
/// Swift throws return `instabilityDrop == false`.
nonisolated func arcfaceEmbedding(from faceImage: CGImage, model: MLModel) -> (embedding: [Float]?, instabilityDrop: Bool) {
    // Resize to 112x112 RGB
    let size = 112
    guard let context = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: size * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return (nil, false) }

    context.interpolationQuality = .high
    context.draw(faceImage, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let resized = context.makeImage() else { return (nil, false) }

    // Create CVPixelBuffer from CGImage for CoreML
    var pixelBuffer: CVPixelBuffer?
    let attrs: [String: Any] = [
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
    ]
    let status = CVPixelBufferCreate(kCFAllocatorDefault, size, size,
                                     kCVPixelFormatType_32ARGB, attrs as CFDictionary, &pixelBuffer)
    guard status == kCVReturnSuccess, let pb = pixelBuffer else { return (nil, false) }

    CVPixelBufferLockBaseAddress(pb, [])
    if let ctx = CGContext(
        data: CVPixelBufferGetBaseAddress(pb),
        width: size, height: size,
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue  // ARGB
    ) {
        ctx.draw(resized, in: CGRect(x: 0, y: 0, width: size, height: size))
    }
    CVPixelBufferUnlockBaseAddress(pb, [])

    // Run CoreML prediction. The lock guards against MLE5BindEmptyMemoryObjectToPort
    // races. VSCatchObjCException guards against NSExceptions that Swift's
    // do/try/catch cannot intercept (CoreML throws ObjC exceptions from MLE5
    // even under serialized, per-instance access — crash 2026-05-23).
    do {
        let input = try MLDictionaryFeatureProvider(dictionary: ["faceImage": pb])

        // CoreML's MLE5 engine can throw a transient ObjC NSException
        // (MLE5BindEmptyMemoryObjectToPort) even under serialized, per-instance
        // access. Such failures are usually transient, so retry ONCE before
        // giving up and counting the face as a real instability drop (P0-2:
        // recover what we can, then surface the rest instead of dropping silently).
        var output: MLFeatureProvider?
        var swiftError: (any Error)?
        var instabilityDrop = false
        let maxAttempts = 2

        for attempt in 1...maxAttempts {
            // Borrow a (model, lock) for this attempt: serialized mode returns
            // the per-video `model` + the global lock (unchanged); pooled mode
            // (K>1) returns one of K individually-locked instances.
            let (predModel, lock) = ArcFacePredictor.shared.borrow(fallback: model)
            let r = arcfacePredictAttempt(
                input: input, model: predModel, lock: lock,
                attempt: attempt, maxAttempts: maxAttempts
            )
            output = r.output
            swiftError = r.swiftError
            if !r.exceptionFired {
                instabilityDrop = false
                break
            }
            // NSException fired on this attempt; flag it and let the loop retry.
            // If the retry also fails, instabilityDrop stays true => real drop.
            instabilityDrop = true
        }

        if let swiftError {
            arcfaceLogger.warning("CoreML prediction Swift error: \(swiftError.localizedDescription, privacy: .public)")
        }
        // A Swift throw leaves instabilityDrop == false (success was true, just
        // empty output), so only a surviving NSException counts as a drop.
        guard swiftError == nil, let output else { return (nil, instabilityDrop) }
        return (arcfaceNormalizedEmbedding(from: output), false)
    } catch {
        return (nil, false)
    }
}

/// Extracts the first 512-D feature value from a CoreML output and returns it
/// L2-normalized (ArcFace embeddings are compared by cosine, which assumes unit
/// vectors). Returns nil if no 512-element array is present.
private func arcfaceNormalizedEmbedding(from output: MLFeatureProvider) -> [Float]? {
    for name in output.featureNames {
        guard let arr = output.featureValue(for: name)?.multiArrayValue else { continue }
        let count = arr.count
        guard count == 512 else { continue }
        var embedding = [Float](repeating: 0, count: count)
        let ptr = arr.dataPointer.bindMemory(to: Float.self, capacity: count)
        for i in 0..<count { embedding[i] = ptr[i] }
        let norm = sqrt(embedding.reduce(0) { $0 + $1 * $1 })
        if norm > 0 { for i in 0..<count { embedding[i] /= norm } }
        return embedding
    }
    return nil
}

/// Cosine similarity between two L2-normalized 512-D embeddings.
/// Returns value in [-1, 1] where 1 = identical.
nonisolated func arcfaceCosine(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count else { return -1 }
    var dot: Float = 0
    for i in 0..<a.count { dot += a[i] * b[i] }
    return dot
}

// MARK: - Reference Embedding Loading

/// Load reference photos and extract ArcFace 512-D embeddings.
/// Returns (embeddings, thumbnails, error).
/// Produce the 112x112 crop fed to ArcFace for one face: the landmark-aligned
/// norm_crop when `useLandmarkAlignment` is on and Vision recovers the
/// landmarks, otherwise the plain bbox crop. Returns nil only when both fail.
nonisolated func arcfaceFaceCrop(from image: CGImage, observation: VNFaceObservation,
                                 useLandmarkAlignment: Bool) -> CGImage? {
    if useLandmarkAlignment, let aligned = arcfaceAlignedCrop(from: image, observation: observation) {
        return aligned
    }
    return pfNormalizeFaceCrop(from: image, observation: observation, outputSize: 112)
}

nonisolated func arcfaceLoadReferenceEmbeddings(
    from path: String,
    largestFaceOnly: Bool,
    useLandmarkAlignment: Bool,
    model: MLModel
) -> ([[Float]], String?) {
    let fm = FileManager.default
    let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp", "gif"]
    var imagePaths: [String] = []
    var isDir: ObjCBool = false
    fm.fileExists(atPath: path, isDirectory: &isDir)
    if isDir.boolValue {
        guard let e = fm.enumerator(atPath: path) else { return ([], "Cannot enumerate \(path)") }
        while let el = e.nextObject() as? String {
            if imageExts.contains((el as NSString).pathExtension.lowercased()) {
                imagePaths.append((path as NSString).appendingPathComponent(el))
            }
        }
        imagePaths.sort()
    } else {
        imagePaths = [path]
    }
    guard !imagePaths.isEmpty else { return ([], "No images found in \(path)") }

    var embeddings: [[Float]] = []
    for imgPath in imagePaths {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: imgPath) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }

        // Detect faces with Vision
        let req = VNDetectFaceRectanglesRequest(); req.revision = 3
        let handler = VNImageRequestHandler(cgImage: img, options: [:])
        do {
            try handler.perform([req])
        } catch {
            // Surface reference-photo detect failures the way the Vision loader
            // does (P1-5); previously swallowed silently and the photo was
            // skipped with no feedback.
            arcfaceLogger.warning("reference photo Vision detect failed: \((imgPath as NSString).lastPathComponent, privacy: .public) — \(error.localizedDescription, privacy: .public)")
            continue
        }

        var candidates = (req.results ?? []).filter { $0.confidence >= 0.5 }
        if largestFaceOnly, let largest = candidates.max(by: {
            ($0.boundingBox.width * $0.boundingBox.height) < ($1.boundingBox.width * $1.boundingBox.height)
        }) { candidates = [largest] }

        for obs in candidates {
            // Same crop path the scan uses, so reference and frame embeddings
            // are aligned the same way and stay comparable by cosine.
            guard let cropped = arcfaceFaceCrop(from: img, observation: obs,
                                                useLandmarkAlignment: useLandmarkAlignment) else { continue }
            guard let emb = arcfaceEmbedding(from: cropped, model: model).embedding else { continue }
            embeddings.append(emb)
        }
    }
    guard !embeddings.isEmpty else { return ([], "No faces detected in reference photos") }
    return (embeddings, nil)
}

// MARK: - ArcFace Video Processing

/// Process a single video using Vision for detection + ArcFace CoreML for recognition.
/// Same contract as pfProcessVideo — returns pfVideoResult.
/// Bundle of reader + track metadata returned by `openArcFaceVideoReader`.
private struct ArcFaceReaderContext {
    let asset: AVURLAsset
    let reader: AVAssetReader
    let trackOutput: AVAssetReaderTrackOutput
    let duration: Double
    let fps: Double
    let orientation: CGImagePropertyOrientation
    let transform: CGAffineTransform
}

/// Open and validate the video asset, returning a fully configured reader or
/// logging + returning nil on any failure. Centralizes all the early-exit
/// setup boilerplate that previously lived at the top of `pfProcessVideoWithArcFace`.
private func openArcFaceVideoReader(
    filePath: String,
    filename: String,
    index: Int,
    total: Int,
    logFn: @escaping @Sendable (String) async -> Void
) async -> ArcFaceReaderContext? {
    let fileURL = URL(fileURLWithPath: filePath)

    let asset = AVURLAsset(url: fileURL,
                           options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])

    let videoTrack: AVAssetTrack
    let duration: Double
    let fps: Double
    do {
        guard let t = try await asset.loadTracks(withMediaType: .video).first else {
            await logFn("[\(index)/\(total)] \(filename) — skipped (no video track)")
            return nil
        }
        videoTrack = t
        duration = CMTimeGetSeconds(try await asset.load(.duration))
        let rawFps = Double(try await videoTrack.load(.nominalFrameRate))
        fps = pfClampNominalFps(rawFps)
        if rawFps > fps {
            await logFn("[\(index)/\(total)] \(filename) — clamped fps \(String(format: "%.1f", rawFps)) → \(fps) (corrupt container metadata)")
        }
    } catch {
        await logFn("[\(index)/\(total)] \(filename) — skipped (\(error.localizedDescription))")
        return nil
    }
    guard duration > 0, fps > 0, Int(duration * fps) > 0 else { return nil }

    let preferredTransform: CGAffineTransform
    do { preferredTransform = try await videoTrack.load(.preferredTransform) } catch {
        await logFn("[\(index)/\(total)] \(filename) — skipped (can't load transform)")
        return nil
    }

    let reader: AVAssetReader
    do { reader = try AVAssetReader(asset: asset) } catch {
        await logFn("[\(index)/\(total)] \(filename) — skipped (AVAssetReader: \(error.localizedDescription))")
        return nil
    }
    let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    ])
    trackOutput.alwaysCopiesSampleData = false
    reader.add(trackOutput)
    guard reader.startReading() else {
        await logFn("[\(index)/\(total)] \(filename) — skipped (AVAssetReader failed to start)")
        return nil
    }

    return ArcFaceReaderContext(
        asset: asset,
        reader: reader,
        trackOutput: trackOutput,
        duration: duration,
        fps: fps,
        orientation: pfOrientationFromTransform(preferredTransform),
        transform: preferredTransform
    )
}

/// Per-frame result from the embedding + compare pipeline. One instance per
/// frame processed inside the main loop.
private struct ArcFaceFrameMatch {
    var hits: [(Double, Float)] = []            // (timeSecs, distance=1-cosine)
    var matchedRects: [CGRect] = []
    var unmatchedRects: [CGRect] = []
    var facesDetected: Int = 0
    var bestCosineInFrame: Float = -1
    var embedDrops: Int = 0     // faces lost to CoreML MLE5 instability (P0-2)
}

/// For each detected face in the oriented image, compute an ArcFace embedding
/// and compare against all references. Returns matched/unmatched rects and
/// the best-cosine-seen in this frame.
private func arcFaceMatchCandidates(
    timeSecs: Double,
    orientedImage: CGImage,
    candidates: [VNFaceObservation],
    referenceEmbeddings: [[Float]],
    settings: PersonFinderSettings,
    model: MLModel,
    cosineThreshold: Float
) -> ArcFaceFrameMatch {
    var m = ArcFaceFrameMatch()
    for obs in candidates {
        guard obs.confidence >= settings.minFaceConfidence,
              let cropped = arcfaceFaceCrop(from: orientedImage, observation: obs,
                                            useLandmarkAlignment: settings.arcfaceLandmarkAlignment) else { continue }
        let embedResult = arcfaceEmbedding(from: cropped, model: model)
        guard let embedding = embedResult.embedding else {
            if embedResult.instabilityDrop { m.embedDrops += 1 }
            continue
        }
        m.facesDetected += 1

        var bestCosine: Float = -1
        for ref in referenceEmbeddings {
            let cosine = arcfaceCosine(embedding, ref)
            if cosine > bestCosine { bestCosine = cosine }
        }
        if bestCosine > m.bestCosineInFrame { m.bestCosineInFrame = bestCosine }

        if bestCosine >= cosineThreshold {
            m.hits.append((timeSecs, 1.0 - bestCosine))
            m.matchedRects.append(obs.boundingBox)
        } else {
            m.unmatchedRects.append(obs.boundingBox)
        }
    }
    return m
}

/// Cluster raw timestamped hits into padded, duration-filtered segments —
/// same algorithm used by the Vision engine.
private func arcFaceClusterSegments(
    hits: [(timeSecs: Double, distance: Float)],
    settings: PersonFinderSettings,
    fps: Double,
    duration: Double
) -> [pfSegment] {
    guard !hits.isEmpty else { return [] }

    let gapTol = Double(settings.frameStep) / fps * 3.0
    let sorted = hits.sorted { $0.timeSecs < $1.timeSecs }
    var raw: [(start: Double, end: Double, distances: [Float])] = []
    var cur = (start: sorted[0].timeSecs, end: sorted[0].timeSecs, distances: [sorted[0].distance])
    for h in sorted.dropFirst() {
        if h.timeSecs - cur.end <= gapTol {
            cur.end = h.timeSecs; cur.distances.append(h.distance)
        } else {
            raw.append(cur); cur = (h.timeSecs, h.timeSecs, [h.distance])
        }
    }
    raw.append(cur)

    var padded = raw.map { (max(0, $0.start - settings.pad),
                           min(duration, $0.end + settings.pad),
                           $0.distances) }
    padded.sort { $0.0 < $1.0 }

    var merged: [(Double, Double, [Float])] = []
    for seg in padded {
        if var last = merged.last, seg.0 <= last.1 {
            last.1 = max(last.1, seg.1)
            last.2.append(contentsOf: seg.2)
            merged[merged.count - 1] = last
        } else {
            merged.append(seg)
        }
    }

    return merged.compactMap { s in
        guard (s.1 - s.0) >= settings.minDuration else { return nil }
        let avg = s.2.reduce(0, +) / Float(s.2.count)
        return pfSegment(startSecs: s.0, endSecs: s.1,
                         bestDistance: s.2.min() ?? 0, avgDistance: avg)
    }
}

private nonisolated func arcFaceLogMilestones(
    frameTime: Double, duration: Double, filename: String,
    index: Int, total: Int, hits: [(timeSecs: Double, distance: Float)],
    totalFacesDetected: Int, bestCosineEver: Float,
    milestones: Set<Int>, loggedMilestones: inout Set<Int>,
    progressFn: @escaping @Sendable (String) async -> Void,
    logFn: @escaping @Sendable (String) async -> Void,
    distFn: @escaping @Sendable (Float) async -> Void
) async {
    let pct = duration > 0 ? Int(frameTime / duration * 100) : 0
    await progressFn("\(filename)  [t=\(String(format: "%.0f", frameTime))s / \(String(format: "%.0f", duration))s · \(hits.count) hit(s)]")
    for m in milestones where pct >= m && !loggedMilestones.contains(m) {
        loggedMilestones.insert(m)
        let cosStr = bestCosineEver > -1 ? String(format: "%.3f", bestCosineEver) : "—"
        await logFn("    \(m)% — t=\(String(format: "%.0f", frameTime))s/\(String(format: "%.0f", duration))s, \(totalFacesDetected) faces detected, \(hits.count) hit(s), best cosine \(cosStr)")
        if bestCosineEver > -1 { await distFn(1.0 - bestCosineEver) }
    }
}

nonisolated func pfProcessVideoWithArcFace(
    filePath: String,
    referenceEmbeddings: [[Float]],
    settings: PersonFinderSettings,
    model: MLModel,
    index: Int,
    total: Int,
    pauseGate: PauseGate,
    logFn: @escaping @Sendable (String) async -> Void,
    progressFn: @escaping @Sendable (String) async -> Void,
    frameFn: @escaping @Sendable (CGImage, [CGRect], [CGRect]) async -> Void,
    distFn: @escaping @Sendable (Float) async -> Void,
    distFnFinal: (@Sendable (Float) async -> Void)? = nil,
    visionStatsFn: @escaping @Sendable (Double, Double) async -> Void = { _, _ in },
    previewRateFn: @escaping @Sendable () -> Int = { 5 }
) async -> pfVideoResult? {
    let filename = (filePath as NSString).lastPathComponent
    var perf = FramePerfAccumulator()
    let videoOpenStart = CFAbsoluteTimeGetCurrent()
    let spVideo = signpostLog.beginInterval("video", id: .exclusive, "\(filename, privacy: .public)")
    guard let ctx = await openArcFaceVideoReader(
        filePath: filePath, filename: filename, index: index, total: total, logFn: logFn
    ) else {
        signpostLog.endInterval("video", spVideo)
        return nil
    }
    perf.videoOpenMs = (CFAbsoluteTimeGetCurrent() - videoOpenStart) * 1000
    let wallStart = CFAbsoluteTimeGetCurrent()

    await progressFn(filename)
    await logFn("[\(index)/\(total)] \(filename)  (\(pfFormatDuration(ctx.duration)), \(String(format: "%.1f", ctx.fps)) fps)  [ArcFace]")

    let cosineThreshold = settings.arcfaceThreshold

    var hits: [(timeSecs: Double, distance: Float)] = []
    var totalFacesDetected = 0
    var totalEmbedDrops = 0
    var bestCosineEver: Float = -1
    let frameInterval = Double(settings.frameStep) / ctx.fps
    var sampledSoFar = 0
    let milestones: Set<Int> = [25, 50, 75]
    var loggedMilestones = Set<Int>()
    var visionFrameTimes: [Double] = []

    let ext = (filePath as NSString).pathExtension.lowercased()
    let useSeeker = ext == "mts" || ext == "m2ts" || ext == "ts"
    let frameStream: AsyncStream<PrefetchedFrame>
    let releaseFrameSlot: () -> Void
    if useSeeker {
        let seekProvider = SeekingFrameProvider(asset: ctx.asset, duration: ctx.duration, frameInterval: frameInterval)
        ctx.reader.cancelReading()
        await logFn("[\(index)/\(total)] \(filename) — using seek-optimized transport-stream reader")
        frameStream = seekProvider.frames()
        releaseFrameSlot = { seekProvider.releaseSlot() }
    } else {
        let prefetcher = FramePrefetcher(
            reader: ctx.reader, trackOutput: ctx.trackOutput,
            frameInterval: frameInterval
        )
        frameStream = prefetcher.frames()
        releaseFrameSlot = { prefetcher.releaseSlot() }
    }

    for await frame in frameStream {
        if Task.isCancelled {
            // Don't call ctx.reader.cancelReading() — it races with the
            // prefetcher's in-flight copyNextSampleBuffer and crashes
            // inside CoreMedia. Break instead; AsyncStream onTermination
            // signals the producer to exit, then the reader is released
            // cleanly via deinit. (See PersonFinderModel.pfProcessVideo
            // for the same fix.)
            break
        }
        let elapsedWall = CFAbsoluteTimeGetCurrent() - wallStart
        if pfShouldAbortForWatchdog(elapsedSecs: elapsedWall, mediaSecs: ctx.duration) {
            await logFn("[\(index)/\(total)] \(filename) — watchdog abort (wall=\(pfFormatDuration(elapsedWall)) exceeded \(pfFormatDuration(max(60, ctx.duration * 10))) budget for \(pfFormatDuration(ctx.duration)) clip)")
            break
        }
        releaseFrameSlot()

        let frameTime = frame.presentationTime
        var frameMatch = ArcFaceFrameMatch()
        var previewImage: CGImage?

        autoreleasepool {
            let t1 = CFAbsoluteTimeGetCurrent()
            let allFaces = pfDetectFacesInBuffer(frame.pixelBuffer, orientation: ctx.orientation)
            let candidates: [VNFaceObservation] = settings.requirePrimary
                ? (allFaces.max(by: { ($0.boundingBox.width * $0.boundingBox.height) < ($1.boundingBox.width * $1.boundingBox.height) }).map { [$0] } ?? [])
                : allFaces
            let t2 = CFAbsoluteTimeGetCurrent()

            var orientTime = 0.0
            var matchTime = 0.0
            if !candidates.isEmpty,
               let img = pfOrientedCGImage(from: frame.pixelBuffer, transform: ctx.transform) {
                let t3 = CFAbsoluteTimeGetCurrent()
                orientTime = t3 - t2
                frameMatch = arcFaceMatchCandidates(
                    timeSecs: frameTime,
                    orientedImage: img,
                    candidates: candidates,
                    referenceEmbeddings: referenceEmbeddings,
                    settings: settings,
                    model: model,
                    cosineThreshold: cosineThreshold
                )
                matchTime = CFAbsoluteTimeGetCurrent() - t3
                if frameMatch.bestCosineInFrame > bestCosineEver {
                    bestCosineEver = frameMatch.bestCosineInFrame
                }
                totalFacesDetected += frameMatch.facesDetected
                totalEmbedDrops += frameMatch.embedDrops
                let rate = max(1, previewRateFn())
                if (sampledSoFar + 1) % rate == 0 { previewImage = img }
            }
            perf.addFrame(decode: frame.decodeSeconds, detect: t2 - t1, orient: orientTime, match: matchTime)
            sampledSoFar += 1
            visionFrameTimes.append(CFAbsoluteTimeGetCurrent() - t1 + frame.decodeSeconds)
        }

        hits.append(contentsOf: frameMatch.hits)

        if let img = previewImage {
            await frameFn(img, frameMatch.matchedRects, frameMatch.unmatchedRects)
            // Drop the full-res oriented CGImage now that it's been handed off,
            // so it isn't pinned across the next await/suspension (P1-3).
            previewImage = nil
        }

        if sampledSoFar % 5 == 0 {
            await pauseGate.waitIfPaused()
            if Task.isCancelled { break }
        }

        if visionFrameTimes.count >= 10 {
            let avg = visionFrameTimes.reduce(0, +) / Double(visionFrameTimes.count)
            await visionStatsFn(avg > 0 ? 1.0 / avg : 0, avg * 1000)
            visionFrameTimes.removeAll(keepingCapacity: true)
        }

        await arcFaceLogMilestones(
            frameTime: frameTime, duration: ctx.duration, filename: filename,
            index: index, total: total, hits: hits, totalFacesDetected: totalFacesDetected,
            bestCosineEver: bestCosineEver, milestones: milestones,
            loggedMilestones: &loggedMilestones, progressFn: progressFn, logFn: logFn, distFn: distFn
        )
    }

    let wallMs = (CFAbsoluteTimeGetCurrent() - wallStart) * 1000
    let summary = perf.summary(filename: filename, wallMs: wallMs)
    perfLog.notice("\(summary, privacy: .public)")
    let wallSecs = wallMs / 1000.0
    if wallSecs > max(120.0, ctx.duration * 2.0) {
        await logFn("[perf] slow ArcFace file: \(filename) media=\(pfFormatDuration(ctx.duration)) wall=\(pfFormatDuration(wallSecs)) sampled=\(sampledSoFar) faces=\(totalFacesDetected)")
    }
    signpostLog.endInterval("video", spVideo)

    if totalEmbedDrops > 0 {
        await logFn("  [\(index)/\(total)] \(filename) → ⚠️ \(totalEmbedDrops) face embedding(s) dropped after retry (CoreML MLE5 instability) — this clip may under-detect")
    }

    // Terminal best-distance publish: bypass the per-frame throttle so the last
    // value is never dropped on a short tail (P2-4). Falls back to the throttled
    // distFn if no unthrottled terminal sink was supplied.
    if bestCosineEver > -1 { await (distFnFinal ?? distFn)(1.0 - bestCosineEver) }
    if ctx.reader.status == .failed {
        await logFn("[\(index)/\(total)] \(filename) — reader error: \(ctx.reader.error?.localizedDescription ?? "unknown")")
    }

    let cosStr = bestCosineEver > -1 ? String(format: "%.3f", bestCosineEver) : "—"

    guard !hits.isEmpty else {
        await logFn("  [\(index)/\(total)] \(filename) → no match  (faces: \(totalFacesDetected), best cosine: \(cosStr), threshold: \(String(format: "%.2f", cosineThreshold)))  [ArcFace]")
        return pfVideoResult(filename: filename, filePath: filePath,
                             durationSeconds: ctx.duration, fps: ctx.fps, totalHits: 0, segments: [])
    }

    let segs = arcFaceClusterSegments(hits: hits, settings: settings, fps: ctx.fps, duration: ctx.duration)
    let presence = segs.reduce(0) { $0 + ($1.endSecs - $1.startSecs) }
    await logFn("  [\(index)/\(total)] \(filename) → \(hits.count) hits, \(segs.count) seg(s), \(pfFormatDuration(presence)) presence  (faces: \(totalFacesDetected), best cosine: \(cosStr))  [ArcFace]")

    return pfVideoResult(filename: filename, filePath: filePath,
                         durationSeconds: ctx.duration, fps: ctx.fps,
                         totalHits: hits.count, segments: segs)
}
