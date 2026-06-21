// PersonFinderDetection.swift
// Vision face-detection, feature-printing, frame iteration, and segment
// clustering helpers extracted from PersonFinderModel.swift.
//
// Step 3 of 6 in the PersonFinderModel decomposition. Pure code movement
// from PersonFinderModel.swift — no logic changes. These helpers are
// file-scope free functions (and a couple of file-private value types)
// that drive the Vision feature-print recognition pipeline.

import Foundation
@preconcurrency import AVFoundation
import Vision
import CoreImage
import CoreGraphics
import os

private let pfDetectLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "detection")

// Shared CIContext — expensive to create, reuse across calls
// Shared across the person-finder detection + ArcFace alignment paths; a
// CIContext is expensive to build, so there is exactly one.
let pfCIContext = CIContext(options: [.useSoftwareRenderer: false])

// Rate-limit for feature-print failure warnings so a systematically failing
// scan (e.g. ANE wedged) emits one warning per ~500 throwing frames rather
// than spamming the hot loop. Counter is best-effort; exactness not required.
private let pfFeaturePrintFailLock = OSAllocatedUnfairLock(initialState: 0)

// MARK: - Reference photo loading

// MARK: - detection-internal — do not call from outside PersonFinderDetection.swift
// Returns ([ReferenceFace], errorMessage) — errorMessage is nil on success.
nonisolated func pfLoadReferencePhotos(from path: String, largestFaceOnly: Bool) -> ([ReferenceFace], [ReferenceLoadFailure], String?) {
    let fm = FileManager.default
    let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp", "gif"]
    var imagePaths: [String] = []
    var isDir: ObjCBool = false
    fm.fileExists(atPath: path, isDirectory: &isDir)
    if isDir.boolValue {
        guard let e = fm.enumerator(atPath: path) else { return ([], [], "Cannot enumerate \(path)") }
        while let el = e.nextObject() as? String {
            if imageExts.contains((el as NSString).pathExtension.lowercased()) {
                imagePaths.append((path as NSString).appendingPathComponent(el))
            }
        }
        imagePaths.sort()
    } else {
        imagePaths = [path]
    }
    guard !imagePaths.isEmpty else { return ([], [], "No images found in \(path)") }

    var faces: [ReferenceFace] = []
    var failures: [ReferenceLoadFailure] = []
    for imgPath in imagePaths {
        let filename = (imgPath as NSString).lastPathComponent
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: imgPath) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            failures.append(ReferenceLoadFailure(filename: filename, reason: "Could not read image"))
            continue
        }
        let req = VNDetectFaceRectanglesRequest(); req.revision = 3
        let handler = VNImageRequestHandler(cgImage: img, options: [:])
        do {
            try handler.perform([req])
        } catch {
            failures.append(ReferenceLoadFailure(filename: filename, reason: "Vision error: \(error.localizedDescription)"))
            continue
        }

        let allResults = req.results ?? []
        if allResults.isEmpty {
            failures.append(ReferenceLoadFailure(filename: filename, reason: "No face detected"))
            continue
        }

        var candidates = allResults.filter { $0.confidence >= 0.5 }
        if candidates.isEmpty {
            let best = allResults.map { $0.confidence }.max() ?? 0
            failures.append(ReferenceLoadFailure(filename: filename, reason: "Face confidence too low (\(Int(best * 100))%)"))
            continue
        }

        if largestFaceOnly, let largest = candidates.max(by: {
            ($0.boundingBox.width * $0.boundingBox.height) < ($1.boundingBox.width * $1.boundingBox.height)
        }) { candidates = [largest] }

        var addedFromThisImage = false
        for obs in candidates {
            guard let cropped = pfNormalizeFaceCrop(from: img, observation: obs),
                  let fp = pfGenerateFeaturePrint(for: cropped) else { continue }
            let face = ReferenceFace(
                featurePrint: fp,
                thumbnail: cropped,
                sourceFilename: filename,
                confidence: obs.confidence,
                rollDeg: (obs.roll?.doubleValue ?? 0) * 180 / .pi,
                yawDeg: (obs.yaw?.doubleValue ?? 0) * 180 / .pi,
                pitchDeg: (obs.pitch?.doubleValue ?? 0) * 180 / .pi,
                faceAreaPct: Float(obs.boundingBox.width * obs.boundingBox.height * 100)
            )
            faces.append(face)
            addedFromThisImage = true
        }
        if !addedFromThisImage {
            failures.append(ReferenceLoadFailure(filename: filename, reason: "Face crop or feature print failed"))
        }
    }
    guard !faces.isEmpty else { return ([], failures, "No faces detected in reference photos") }
    return (faces, failures, nil)
}

// MARK: - Face detection utilities

nonisolated func pfNormalizeFaceCrop(from source: CGImage, observation: VNFaceObservation, outputSize: Int = 256) -> CGImage? {
    let imgW = CGFloat(source.width)
    let imgH = CGFloat(source.height)
    let bbox = observation.boundingBox

    // Vision and CIImage both use bottom-left origin — no Y flip needed for these coordinates
    let faceCX = (bbox.origin.x + bbox.width / 2) * imgW
    let faceCY = (bbox.origin.y + bbox.height / 2) * imgH
    let roll   = CGFloat(observation.roll?.doubleValue ?? 0)

    // Expand crop 70% beyond face bbox to include forehead, chin and sides
    let sideLen = max(bbox.width * imgW, bbox.height * imgH) * 1.7
    guard sideLen > 4 else { return nil }

    let ciImage = CIImage(cgImage: source)

    // De-rotate around the face centre so the face is upright
    let deRoll = CGAffineTransform(translationX: faceCX, y: faceCY)
        .rotated(by: -roll)
        .translatedBy(x: -faceCX, y: -faceCY)
    let rotated = ciImage.transformed(by: deRoll)

    // Crop a square centred on the face
    let cropOrigin = CGPoint(x: faceCX - sideLen / 2, y: faceCY - sideLen / 2)
    let cropRect   = CGRect(origin: cropOrigin, size: CGSize(width: sideLen, height: sideLen))
    let cropped    = rotated.cropped(to: cropRect)

    // Translate to (0,0) then scale to the desired output size
    let scale = CGFloat(outputSize) / sideLen
    let finalCI = cropped
        .transformed(by: CGAffineTransform(translationX: -cropOrigin.x, y: -cropOrigin.y))
        .transformed(by: CGAffineTransform(scaleX: scale, y: scale))

    return pfCIContext.createCGImage(finalCI,
        from: CGRect(x: 0, y: 0, width: CGFloat(outputSize), height: CGFloat(outputSize)))
}

private nonisolated func pfGenerateFeaturePrint(for image: CGImage) -> VNFeaturePrintObservation? {
    let req = VNGenerateImageFeaturePrintRequest()
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    do {
        try handler.perform([req])
    } catch {
        // Rate-limited: warn on the 1st failure and every 500th thereafter so a
        // systematic Vision/ANE failure is visible without per-frame log spam.
        let n = pfFeaturePrintFailLock.withLock { state -> Int in
            state += 1
            return state
        }
        if n == 1 || n % 500 == 0 {
            pfDetectLog.warning("VNGenerateImageFeaturePrint failed (occurrence \(n, privacy: .public)): \(error.localizedDescription, privacy: .public)")
        }
    }
    return req.results?.first as? VNFeaturePrintObservation
}

/// Clamp an AVFoundation-reported nominalFrameRate to the realistic
/// consumer range. Some files (h264 with corrupt `nb_frames` in the
/// container) report avg_frame_rate ≈ 60,000+ because ffprobe /
/// AVFoundation compute it as nb_frames / duration. The hot frame-
/// sampling loop uses fps to set the stride
/// (`frameInterval = settings.frameStep / fps`); an uncorrected
/// 60,000 fps gives an 83µs stride and the loop oversamples ~1000x.
///
/// 240 fps is the iPhone slo-mo ceiling — high enough to preserve
/// genuine high-fps content, low enough that 60,000 obviously trips
/// the clamp and a 5/240 = 21ms stride stays sane.
///
/// Zero / negative pass through; an upstream `guard fps > 0` already
/// skips those files.
///
/// Regression sensor: `PersonFinderFpsClampTests`. Incident:
/// DickyTheBoysDadBreen-1985.mp4 wedged a 71-second clip for 3h 48m
/// on 2026-06-03 LaCieWorkspace scan.
nonisolated func pfClampNominalFps(_ raw: Double, max cap: Double = 240.0) -> Double {
    raw > cap ? cap : raw
}

/// Per-file wall-clock watchdog. Returns true when the file has
/// burned more than `max(60s, 10 × media duration)` of real time —
/// the calling loop should log + break. Defense-in-depth: even if
/// pfClampNominalFps misses some pathology, this stops a single
/// file from spinning for hours. The 10× factor accommodates slow
/// disks + slow Vision passes on legit content; the 60s floor
/// covers ANE warmup variance on very short clips.
///
/// Regression sensor: `PersonFinderWatchdogTests`. Same incident
/// origin as pfClampNominalFps — see that doc for context.
nonisolated func pfShouldAbortForWatchdog(elapsedSecs: Double, mediaSecs: Double) -> Bool {
    let budget = max(60.0, mediaSecs * 10.0)
    return elapsedSecs > budget
}

/// Map a track's preferredTransform to the CGImagePropertyOrientation Vision expects.
nonisolated func pfOrientationFromTransform(_ t: CGAffineTransform) -> CGImagePropertyOrientation {
    switch (t.a, t.b, t.c, t.d) {
    case (0, 1, -1, 0): return .right  // 90° CW  — phone portrait, home-button right
    case (0, -1, 1, 0): return .left   // 90° CCW — phone portrait, home-button left
    case (-1, 0, 0, -1): return .down  // 180°    — upside down
    default:              return .up     // identity / landscape
    }
}

/// Long-edge pixel cap for the face-DETECTION pass only. Frames whose long edge
/// exceeds this are downsampled (aspect-preserving) before Vision runs, keeping
/// detection cost and memory bounded on very high-resolution sources — a 4K frame
/// is ~33 MB and ~9x the pixels of a 1280-wide one, with no meaningful loss in
/// detecting normally-framed faces. Identity feature-printing (phase 2) still uses
/// the FULL-resolution frame, so match accuracy is unaffected at any resolution.
/// All current catalog material is well under this, so the cap is a no-op today —
/// it exists so a converted/upscaled (e.g. 4K) clip can't beachball or exhaust
/// memory. 1536 keeps comfortable detection-recall headroom over a 1280 floor.
let pfDetectionLongEdgeCap = 1536

/// Phase-1 face detection: run Vision directly on the CVPixelBuffer (no CGImage needed).
/// Vision handles YpCbCr natively and dispatches to the Neural Engine / ANE.
///
/// When `longEdgeCap` is set and the source exceeds it, detection runs on an
/// aspect-preserving downsampled copy (see `pfDownsampledForDetection`). Vision
/// returns NORMALIZED bounding boxes, so the caller maps them straight onto the
/// full-resolution frame for feature-printing — only the cheap detect pass is
/// downsampled. `nil` (the default) preserves the original full-res behavior.
nonisolated func pfDetectFacesInBuffer(_ buffer: CVPixelBuffer,
                                      orientation: CGImagePropertyOrientation,
                                      longEdgeCap: Int? = nil) -> [VNFaceObservation] {
    let detectBuffer = pfDownsampledForDetection(buffer, longEdgeCap: longEdgeCap)
    let req = VNDetectFaceRectanglesRequest(); req.revision = 3
    let handler = VNImageRequestHandler(cvPixelBuffer: detectBuffer, orientation: orientation, options: [:])
    try? handler.perform([req])
    return (req.results ?? []).sorted { $0.confidence > $1.confidence }
}

/// Aspect-preserving downsample of a frame buffer for the DETECTION pass only.
/// Returns the original buffer untouched when no cap is set or the source already
/// fits within it (the common case — zero allocation, zero copy). Renders to
/// 32BGRA regardless of source pixel format, so it's safe for both the YpCbCr
/// dense-reader path and the BGRA seeking path. On any allocation/render failure
/// it returns the original buffer (detection then runs full-res — correct, just
/// slower), so it can never break a scan.
nonisolated func pfDownsampledForDetection(_ src: CVPixelBuffer, longEdgeCap: Int?) -> CVPixelBuffer {
    guard let cap = longEdgeCap, cap > 0 else { return src }
    let w = CVPixelBufferGetWidth(src)
    let h = CVPixelBufferGetHeight(src)
    let longEdge = max(w, h)
    guard longEdge > cap else { return src }

    let scale = CGFloat(cap) / CGFloat(longEdge)
    let dstW = max(2, Int((CGFloat(w) * scale).rounded()))
    let dstH = max(2, Int((CGFloat(h) * scale).rounded()))

    var out: CVPixelBuffer?
    let attrs = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary] as CFDictionary
    guard CVPixelBufferCreate(kCFAllocatorDefault, dstW, dstH,
                              kCVPixelFormatType_32BGRA, attrs, &out) == kCVReturnSuccess,
          let dst = out else {
        return src
    }
    let ci = CIImage(cvPixelBuffer: src).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    pfCIContext.render(ci, to: dst)
    return dst
}

/// Phase-2 image: apply the track's preferredTransform so the CGImage is right-side-up,
/// matching the oriented coordinate space Vision used for bounding boxes.
nonisolated func pfOrientedCGImage(from buffer: CVPixelBuffer,
                                           transform: CGAffineTransform) -> CGImage? {
    var ci = CIImage(cvPixelBuffer: buffer).transformed(by: transform)
    // Transform may shift the extent off-origin — translate back to (0,0)
    ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.origin.x,
                                               y: -ci.extent.origin.y))
    return pfCIContext.createCGImage(ci, from: ci.extent)
}

// MARK: - Video processing

/// Bundle of reader + track metadata returned by `pfOpenVisionVideoReader`.
private struct PFVisionReaderContext {
    let asset: AVURLAsset
    let reader: AVAssetReader
    let trackOutput: AVAssetReaderTrackOutput
    let duration: Double
    let fps: Double
    let orientation: CGImagePropertyOrientation
    let transform: CGAffineTransform
}

/// Open and validate the video asset, returning a fully configured reader or
/// logging + returning nil on any failure. Mirrors `openArcFaceVideoReader`.
private func pfOpenVisionVideoReader(
    filePath: String,
    filename: String,
    index: Int,
    total: Int,
    logFn: @escaping @Sendable (String) async -> Void
) async -> PFVisionReaderContext? {
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

    return PFVisionReaderContext(
        asset: asset,
        reader: reader,
        trackOutput: trackOutput,
        duration: duration,
        fps: fps,
        orientation: pfOrientationFromTransform(preferredTransform),
        transform: preferredTransform
    )
}

/// Per-frame result from the Vision feature-print pipeline.
private struct PFVisionFrameMatch {
    var hits: [(Double, Float)] = []
    var matchedRects: [CGRect] = []
    var unmatchedRects: [CGRect] = []
    var facesDetected: Int = 0
    var bestDistInFrame: Float = .greatestFiniteMagnitude
}

/// For each candidate face, generate a Vision feature print and compare against
/// each reference print. Returns matched/unmatched rects and the best distance.
private func pfVisionMatchCandidates(
    timeSecs: Double,
    orientedImage: CGImage,
    candidates: [VNFaceObservation],
    referencePrints: [VNFeaturePrintObservation],
    settings: PersonFinderSettings
) -> PFVisionFrameMatch {
    var m = PFVisionFrameMatch()
    for obs in candidates {
        guard obs.confidence >= settings.minFaceConfidence,
              let cropped = pfNormalizeFaceCrop(from: orientedImage, observation: obs),
              let fp = pfGenerateFeaturePrint(for: cropped) else { continue }
        m.facesDetected += 1

        var best: Float = .greatestFiniteMagnitude
        for ref in referencePrints {
            var d: Float = 0
            if (try? ref.computeDistance(&d, to: fp)) != nil, d < best { best = d }
        }
        if best < m.bestDistInFrame { m.bestDistInFrame = best }

        if best <= settings.threshold {
            m.hits.append((timeSecs, best))
            m.matchedRects.append(obs.boundingBox)
        } else {
            m.unmatchedRects.append(obs.boundingBox)
        }
    }
    return m
}

/// Cluster raw timestamped hits into padded, duration-filtered segments.
/// Identical algorithm to the ArcFace variant.
private func pfVisionClusterSegments(
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


private nonisolated func pfLogMilestones(
    frameTime: Double, duration: Double, filename: String,
    index: Int, total: Int, hits: [(timeSecs: Double, distance: Float)],
    totalFacesDetected: Int, bestDistEver: Float,
    milestones: Set<Int>, loggedMilestones: inout Set<Int>,
    progressFn: @escaping @Sendable (String) async -> Void,
    logFn: @escaping @Sendable (String) async -> Void,
    distFn: @escaping @Sendable (Float) async -> Void
) async {
    let pct = duration > 0 ? Int(frameTime / duration * 100) : 0
    await progressFn("\(filename)  [t=\(String(format: "%.0f", frameTime))s / \(String(format: "%.0f", duration))s · \(hits.count) hit(s)]")
    for m in milestones where pct >= m && !loggedMilestones.contains(m) {
        loggedMilestones.insert(m)
        let distStr = bestDistEver < .greatestFiniteMagnitude ? String(format: "%.3f", bestDistEver) : "—"
        await logFn("    \(m)% — t=\(String(format: "%.0f", frameTime))s/\(String(format: "%.0f", duration))s, \(totalFacesDetected) faces detected, \(hits.count) hit(s), best dist \(distStr)")
        await distFn(bestDistEver)
    }
}

// MARK: - detection-internal — do not call from outside PersonFinderDetection.swift
nonisolated func pfProcessVideo(
    filePath: String,
    prints: [VNFeaturePrintObservation],
    settings: PersonFinderSettings,
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
    guard let ctx = await pfOpenVisionVideoReader(
        filePath: filePath, filename: filename, index: index, total: total, logFn: logFn
    ) else {
        signpostLog.endInterval("video", spVideo)
        return nil
    }
    perf.videoOpenMs = (CFAbsoluteTimeGetCurrent() - videoOpenStart) * 1000
    let wallStart = CFAbsoluteTimeGetCurrent()

    await progressFn(filename)
    await logFn("[\(index)/\(total)] \(filename)  (\(pfFormatDuration(ctx.duration)), \(String(format: "%.1f", ctx.fps)) fps)")

    var hits: [(timeSecs: Double, distance: Float)] = []
    var totalFacesDetected = 0
    var bestDistEver: Float = .greatestFiniteMagnitude
    let frameInterval = Double(settings.frameStep) / ctx.fps
    var sampledSoFar = 0
    let milestones: Set<Int> = [25, 50, 75]
    var loggedMilestones = Set<Int>()
    var visionFrameTimes: [Double] = []

    // For MPEG-TS containers (mts/m2ts/ts), sequential AVAssetReader demux
    // wastes ~98% of the work; SeekingFrameProvider uses
    // AVAssetImageGenerator instead for a 10–34× speedup on those files.
    // The reader is preflighted in pfMakeReadingContext but isn't used on
    // the seeker path, so cancelling it before we start is safe (no race).
    let ext = (filePath as NSString).pathExtension.lowercased()
    let useSeeker = ext == "mts" || ext == "m2ts" || ext == "ts"

    // Bind exactly one source so the rest of the loop never has to ask
    // "which provider is live?" — eliminates the prefetcher!/seekProvider!
    // pairs that swiftlint flagged as force unwraps.
    let frameStream: AsyncStream<PrefetchedFrame>
    let releaseSlot: () -> Void
    if useSeeker {
        let sp = SeekingFrameProvider(asset: ctx.asset, duration: ctx.duration, frameInterval: frameInterval)
        ctx.reader.cancelReading()
        frameStream = sp.frames()
        releaseSlot = { sp.releaseSlot() }
    } else {
        let pf = FramePrefetcher(reader: ctx.reader, trackOutput: ctx.trackOutput, frameInterval: frameInterval)
        frameStream = pf.frames()
        releaseSlot = { pf.releaseSlot() }
    }

    for await frame in frameStream {
        if Task.isCancelled {
            // Don't call ctx.reader.cancelReading() here on the prefetcher
            // path — it races with the producer queue's in-flight
            // copyNextSampleBuffer and crashes inside CoreMedia
            // (`_dispatch_semaphore_dispose` / FigSimpleMutexUnlock).
            // The for-await exit triggers AsyncStream onTermination, which
            // sets the producer's cancel flag; after the in-flight
            // copyNextSampleBuffer returns the queue exits cleanly and
            // AVAssetReader's deinit handles teardown without a race.
            // Same applies to the seeker path — just break.
            break
        }
        let elapsedWall = CFAbsoluteTimeGetCurrent() - wallStart
        if pfShouldAbortForWatchdog(elapsedSecs: elapsedWall, mediaSecs: ctx.duration) {
            await logFn("[\(index)/\(total)] \(filename) — watchdog abort (wall=\(pfFormatDuration(elapsedWall)) exceeded \(pfFormatDuration(max(60, ctx.duration * 10))) budget for \(pfFormatDuration(ctx.duration)) clip)")
            break
        }
        releaseSlot()

        let frameTime = frame.presentationTime
        var frameMatch = PFVisionFrameMatch()
        var previewImage: CGImage?

        autoreleasepool {
            let t1 = CFAbsoluteTimeGetCurrent()
            // Detect on a resolution-capped copy (no-op at/under the cap); the
            // full-res frame.pixelBuffer is still used for the phase-2 oriented
            // image below, so identity feature-printing stays full resolution.
            let allFaces = pfDetectFacesInBuffer(frame.pixelBuffer, orientation: ctx.orientation,
                                                 longEdgeCap: pfDetectionLongEdgeCap)
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
                frameMatch = pfVisionMatchCandidates(
                    timeSecs: frameTime,
                    orientedImage: img,
                    candidates: candidates,
                    referencePrints: prints,
                    settings: settings
                )
                matchTime = CFAbsoluteTimeGetCurrent() - t3
                if frameMatch.bestDistInFrame < bestDistEver {
                    bestDistEver = frameMatch.bestDistInFrame
                }
                totalFacesDetected += frameMatch.facesDetected
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
            // See top of this for-await: don't call cancelReading() from
            // the consumer side — it races with the prefetcher's in-flight
            // copyNextSampleBuffer. Just break; the AsyncStream onTermination
            // path handles the reader teardown safely.
            if Task.isCancelled { break }
        }

        if visionFrameTimes.count >= 10 {
            let avg = visionFrameTimes.reduce(0, +) / Double(visionFrameTimes.count)
            await visionStatsFn(avg > 0 ? 1.0 / avg : 0, avg * 1000)
            visionFrameTimes.removeAll(keepingCapacity: true)
        }

        await pfLogMilestones(
            frameTime: frameTime, duration: ctx.duration, filename: filename,
            index: index, total: total, hits: hits, totalFacesDetected: totalFacesDetected,
            bestDistEver: bestDistEver, milestones: milestones,
            loggedMilestones: &loggedMilestones, progressFn: progressFn, logFn: logFn, distFn: distFn
        )
    }

    let wallMs = (CFAbsoluteTimeGetCurrent() - wallStart) * 1000
    let summary = perf.summary(filename: filename, wallMs: wallMs)
    perfLog.notice("\(summary, privacy: .public)")
    signpostLog.endInterval("video", spVideo)

    // Terminal best-distance publish: bypass the per-frame throttle so the last
    // value is never dropped on a short tail (P2-4). Falls back to the throttled
    // distFn if no unthrottled terminal sink was supplied.
    await (distFnFinal ?? distFn)(bestDistEver)
    if ctx.reader.status == .failed {
        await logFn("[\(index)/\(total)] \(filename) — reader error: \(ctx.reader.error?.localizedDescription ?? "unknown")")
    }

    let distStr = bestDistEver < .greatestFiniteMagnitude ? String(format: "%.3f", bestDistEver) : "—"

    guard !hits.isEmpty else {
        await logFn("  [\(index)/\(total)] \(filename) → no match  (faces detected: \(totalFacesDetected), best dist: \(distStr), threshold: \(String(format: "%.3f", settings.threshold)))")
        return pfVideoResult(filename: filename, filePath: filePath,
                             durationSeconds: ctx.duration, fps: ctx.fps, totalHits: 0, segments: [])
    }

    let segs = pfVisionClusterSegments(hits: hits, settings: settings, fps: ctx.fps, duration: ctx.duration)
    let presence = segs.reduce(0) { $0 + ($1.endSecs - $1.startSecs) }
    let bestHitDist = hits.map(\.distance).min() ?? 0
    await logFn("  [\(index)/\(total)] \(filename) → \(hits.count) hits, \(segs.count) seg(s), \(pfFormatDuration(presence)) presence  (faces: \(totalFacesDetected), best dist: \(String(format: "%.3f", bestHitDist)))")

    return pfVideoResult(filename: filename, filePath: filePath,
                         durationSeconds: ctx.duration, fps: ctx.fps,
                         totalHits: hits.count, segments: segs)
}
