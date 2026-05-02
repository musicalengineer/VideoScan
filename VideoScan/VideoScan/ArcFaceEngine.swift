// ArcFaceEngine.swift
// CoreML-based ArcFace face recognition engine for VideoScan.
// Uses Vision for face detection (ANE), ArcFace w600k_r50 for 512-D identity embeddings.

import Foundation
import CoreML
import Vision
import CoreImage
import CoreGraphics
import AVFoundation

// MARK: - ArcFace CoreML Model Singleton

/// Lazily loads the w600k_r50 CoreML model from ~/dev/VideoScan/models/.
/// Thread-safe via actor isolation.
actor ArcFaceModelLoader {
    static let shared = ArcFaceModelLoader()

    private var model: MLModel?
    private var loadError: String?

    /// Returns the loaded model, or nil with an error message.
    func getModel() -> (MLModel?, String?) {
        if let model { return (model, nil) }

        let modelsDir = NSHomeDirectory() + "/dev/VideoScan/models"
        let compiledPath = modelsDir + "/w600k_r50.mlmodelc"
        let packagePath = modelsDir + "/w600k_r50.mlpackage"
        let fm = FileManager.default

        // 1. Try pre-compiled .mlmodelc first (fastest)
        if fm.fileExists(atPath: compiledPath) {
            do {
                let config = MLModelConfiguration()
                config.computeUnits = .all
                let loaded = try MLModel(contentsOf: URL(fileURLWithPath: compiledPath), configuration: config)
                self.model = loaded
                return (loaded, nil)
            } catch {
                // Fall through to try compiling from .mlpackage
            }
        }

        // 2. Compile .mlpackage → .mlmodelc at runtime
        if fm.fileExists(atPath: packagePath) {
            do {
                let compiledURL = try MLModel.compileModel(at: URL(fileURLWithPath: packagePath))
                // Move compiled model to our models/ directory for next time
                let destURL = URL(fileURLWithPath: compiledPath)
                if fm.fileExists(atPath: compiledPath) {
                    try? fm.removeItem(at: destURL)
                }
                try fm.moveItem(at: compiledURL, to: destURL)

                let config = MLModelConfiguration()
                config.computeUnits = .all
                let loaded = try MLModel(contentsOf: destURL, configuration: config)
                self.model = loaded
                return (loaded, nil)
            } catch {
                return (nil, "Failed to compile ArcFace model: \(error.localizedDescription)")
            }
        }

        // 3. Also check app bundle
        if let bundlePath = Bundle.main.path(forResource: "w600k_r50", ofType: "mlmodelc") {
            do {
                let config = MLModelConfiguration()
                config.computeUnits = .all
                let loaded = try MLModel(contentsOf: URL(fileURLWithPath: bundlePath), configuration: config)
                self.model = loaded
                return (loaded, nil)
            } catch {
                return (nil, "Failed to load bundled ArcFace model: \(error.localizedDescription)")
            }
        }

        return (nil, "ArcFace model not found. Place w600k_r50.mlpackage in ~/dev/VideoScan/models/ and restart.")
    }

    func reset() { model = nil }
}

// MARK: - Embedding Extraction

/// Extract a 512-D ArcFace embedding from a face crop (any size — will be resized to 112x112).
nonisolated func arcfaceEmbedding(from faceImage: CGImage, model: MLModel) -> [Float]? {
    // Resize to 112x112 RGB
    let size = 112
    guard let context = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: size * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.interpolationQuality = .high
    context.draw(faceImage, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let resized = context.makeImage() else { return nil }

    // Create CVPixelBuffer from CGImage for CoreML
    var pixelBuffer: CVPixelBuffer?
    let attrs: [String: Any] = [
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
    ]
    let status = CVPixelBufferCreate(kCFAllocatorDefault, size, size,
                                     kCVPixelFormatType_32ARGB, attrs as CFDictionary, &pixelBuffer)
    guard status == kCVReturnSuccess, let pb = pixelBuffer else { return nil }

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

    // Run CoreML prediction
    do {
        let input = try MLDictionaryFeatureProvider(dictionary: ["faceImage": pb])
        let output = try model.prediction(from: input)

        // The output tensor name from the converted model
        // Try common output names
        for name in output.featureNames {
            if let arr = output.featureValue(for: name)?.multiArrayValue {
                let count = arr.count
                guard count == 512 else { continue }
                var embedding = [Float](repeating: 0, count: count)
                let ptr = arr.dataPointer.bindMemory(to: Float.self, capacity: count)
                for i in 0..<count { embedding[i] = ptr[i] }
                // L2-normalize
                let norm = sqrt(embedding.reduce(0) { $0 + $1 * $1 })
                if norm > 0 { for i in 0..<count { embedding[i] /= norm } }
                return embedding
            }
        }
        return nil
    } catch {
        return nil
    }
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
nonisolated func arcfaceLoadReferenceEmbeddings(
    from path: String,
    largestFaceOnly: Bool,
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
        try? handler.perform([req])

        var candidates = (req.results ?? []).filter { $0.confidence >= 0.5 }
        if largestFaceOnly, let largest = candidates.max(by: {
            ($0.boundingBox.width * $0.boundingBox.height) < ($1.boundingBox.width * $1.boundingBox.height)
        }) { candidates = [largest] }

        for obs in candidates {
            // Use the existing normalization crop (will be resized to 112x112 inside arcfaceEmbedding)
            guard let cropped = pfNormalizeFaceCrop(from: img, observation: obs, outputSize: 112) else { continue }
            guard let emb = arcfaceEmbedding(from: cropped, model: model) else { continue }
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
    let asset = AVURLAsset(url: URL(fileURLWithPath: filePath),
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
        fps = Double(try await videoTrack.load(.nominalFrameRate))
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
              let cropped = pfNormalizeFaceCrop(from: orientedImage, observation: obs, outputSize: 112),
              let embedding = arcfaceEmbedding(from: cropped, model: model) else { continue }
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

private enum ArcFaceFrameResult {
    case skipped
    case finished
    case processed(frameTime: Double, match: ArcFaceFrameMatch, preview: CGImage?)
}

private nonisolated func arcFaceSampleNextFrame(
    ctx: ArcFaceReaderContext, settings: PersonFinderSettings,
    referenceEmbeddings: [[Float]], model: MLModel, cosineThreshold: Float,
    lastProcessedTime: inout Double, frameInterval: Double,
    bestCosineEver: inout Float, totalFacesDetected: inout Int,
    sampledSoFar: inout Int, visionFrameTimes: inout [Double],
    previewRateFn: @escaping @Sendable () -> Int
) -> ArcFaceFrameResult {
    var frameTime: Double = 0
    var frameMatch = ArcFaceFrameMatch()
    var previewImage: CGImage?
    var shouldSkip = false

    autoreleasepool {
        guard let sampleBuffer = ctx.trackOutput.copyNextSampleBuffer() else {
            shouldSkip = true; return
        }
        let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        guard t - lastProcessedTime >= frameInterval else {
            shouldSkip = true; frameTime = -1; return
        }
        lastProcessedTime = t
        frameTime = t

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            shouldSkip = true; frameTime = -1; return
        }

        let frameStart = CFAbsoluteTimeGetCurrent()
        let allFaces = pfDetectFacesInBuffer(pixelBuffer, orientation: ctx.orientation)
        let candidates: [VNFaceObservation] = settings.requirePrimary
            ? (allFaces.max(by: { ($0.boundingBox.width * $0.boundingBox.height) < ($1.boundingBox.width * $1.boundingBox.height) }).map { [$0] } ?? [])
            : allFaces

        if !candidates.isEmpty,
           let img = pfOrientedCGImage(from: pixelBuffer, transform: ctx.transform) {
            frameMatch = arcFaceMatchCandidates(
                timeSecs: t,
                orientedImage: img,
                candidates: candidates,
                referenceEmbeddings: referenceEmbeddings,
                settings: settings,
                model: model,
                cosineThreshold: cosineThreshold
            )
            if frameMatch.bestCosineInFrame > bestCosineEver {
                bestCosineEver = frameMatch.bestCosineInFrame
            }
            totalFacesDetected += frameMatch.facesDetected
            let rate = max(1, previewRateFn())
            if (sampledSoFar + 1) % rate == 0 { previewImage = img }
        }
        sampledSoFar += 1
        visionFrameTimes.append(CFAbsoluteTimeGetCurrent() - frameStart)
    }

    if shouldSkip {
        return frameTime == -1 ? .skipped : .finished
    }
    return .processed(frameTime: frameTime, match: frameMatch, preview: previewImage)
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
    visionStatsFn: @escaping @Sendable (Double, Double) async -> Void = { _, _ in },
    previewRateFn: @escaping @Sendable () -> Int = { 5 }
) async -> pfVideoResult? {
    let filename = (filePath as NSString).lastPathComponent
    guard let ctx = await openArcFaceVideoReader(
        filePath: filePath, filename: filename, index: index, total: total, logFn: logFn
    ) else { return nil }

    await progressFn(filename)
    await logFn("[\(index)/\(total)] \(filename)  (\(pfFormatDuration(ctx.duration)), \(String(format: "%.1f", ctx.fps)) fps)  [ArcFace]")

    // ArcFace uses cosine similarity (higher = better match); default 0.40 ~ Vision 0.52.
    let cosineThreshold = settings.arcfaceThreshold

    var hits: [(timeSecs: Double, distance: Float)] = []
    var totalFacesDetected = 0
    var bestCosineEver: Float = -1
    let frameInterval = Double(settings.frameStep) / ctx.fps
    var lastProcessedTime = -frameInterval
    var sampledSoFar = 0
    let milestones: Set<Int> = [25, 50, 75]
    var loggedMilestones = Set<Int>()
    var visionFrameTimes: [Double] = []

    while true {
        if Task.isCancelled { ctx.reader.cancelReading(); break }

        let frameResult = arcFaceSampleNextFrame(
            ctx: ctx, settings: settings, referenceEmbeddings: referenceEmbeddings,
            model: model, cosineThreshold: cosineThreshold,
            lastProcessedTime: &lastProcessedTime, frameInterval: frameInterval,
            bestCosineEver: &bestCosineEver, totalFacesDetected: &totalFacesDetected,
            sampledSoFar: &sampledSoFar, visionFrameTimes: &visionFrameTimes,
            previewRateFn: previewRateFn
        )

        if sampledSoFar > 0 && sampledSoFar % 5 == 0 {
            await pauseGate.waitIfPaused()
            if Task.isCancelled { ctx.reader.cancelReading(); break }
        }

        switch frameResult {
        case .skipped: continue
        case .finished: break
        case let .processed(frameTime, frameMatch, previewImage):
            hits.append(contentsOf: frameMatch.hits)

            if let img = previewImage {
                await frameFn(img, frameMatch.matchedRects, frameMatch.unmatchedRects)
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
        if case .finished = frameResult { break }
    }

    if bestCosineEver > -1 { await distFn(1.0 - bestCosineEver) }
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
