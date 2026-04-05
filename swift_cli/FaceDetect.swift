#!/usr/bin/env swift

// facedetect.swift
// Detects faces in a video by processing every Nth frame.
// Optionally matches faces against a reference photo.
//
// Usage:
//   swift facedetect.swift <video_file> [frame_step] [timeout_seconds] [reference_photo]
//
// Defaults:
//   frame_step      = 10   (process every 10th frame)
//   timeout_seconds = 120
//   reference_photo = (none — detects all faces)
//
// Example:
//   swift facedetect.swift Clip.mov 10 120 Donna.png

import Foundation
import AVFoundation
import Vision
import CoreImage
import CoreGraphics

// MARK: - Arguments

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("Usage: swift facedetect.swift <video_file> [frame_step] [timeout_seconds] [reference_photo]")
    exit(1)
}

let videoPath     = (args[1] as NSString).expandingTildeInPath
let frameStep     = args.count >= 3 ? Int(args[2])    ?? 10    : 10
let timeoutSecs   = args.count >= 4 ? Double(args[3]) ?? 120.0 : 120.0
let refPhotoPath  = args.count >= 5 ? (args[4] as NSString).expandingTildeInPath : nil

guard FileManager.default.fileExists(atPath: videoPath) else {
    print("Error: file not found: \(videoPath)")
    exit(1)
}

// MARK: - Load asset

let assetURL = URL(fileURLWithPath: videoPath)
let asset    = AVURLAsset(url: assetURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])

guard let videoTrack = asset.tracks(withMediaType: .video).first else {
    print("Error: no video track found in \(videoPath)")
    exit(1)
}

let duration        = asset.duration
let durationSeconds = CMTimeGetSeconds(duration)
let nominalFPS      = videoTrack.nominalFrameRate
let totalFrames     = Int((durationSeconds * Double(nominalFPS)).rounded())
let framesToProcess = (totalFrames + frameStep - 1) / frameStep

let videoName = assetURL.lastPathComponent
print("")
print("facedetect — Vision Framework Face Detection")
print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
print("  Video    : \(videoName)")
print("  Duration : \(String(format: "%.2f", durationSeconds))s")
print("  FPS      : \(String(format: "%.3f", nominalFPS))")
print("  Frames   : \(totalFrames) total — checking every \(frameStep)th = \(framesToProcess) frames")
print("  Timeout  : \(Int(timeoutSecs))s")

// MARK: - Image generator

let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
let toleranceTicks = CMTimeMake(value: 2, timescale: CMTimeScale(nominalFPS))
generator.requestedTimeToleranceBefore = toleranceTicks
generator.requestedTimeToleranceAfter  = toleranceTicks
generator.maximumSize = CGSize(width: 1280, height: 720)

// MARK: - Vision helpers

// Detect faces; returns bounding boxes in Vision coords (origin bottom-left, normalized)
func detectFaceBoxes(in cgImage: CGImage) -> [VNFaceObservation] {
    let request = VNDetectFaceRectanglesRequest()
    request.revision = VNDetectFaceRectanglesRequestRevision3
    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    try? handler.perform([request])
    return (request.results as? [VNFaceObservation]) ?? []
}

// Crop a face from a CGImage given a Vision bounding box
func cropFace(_ cgImage: CGImage, box: CGRect) -> CGImage? {
    let w = CGFloat(cgImage.width)
    let h = CGFloat(cgImage.height)
    // Vision origin is bottom-left; CGImage origin is top-left
    let cropRect = CGRect(
        x:      box.origin.x * w,
        y:      (1.0 - box.origin.y - box.height) * h,
        width:  box.width  * w,
        height: box.height * h
    ).integral
    return cgImage.cropping(to: cropRect)
}

// Generate a feature-print embedding for a CGImage
func featurePrint(for cgImage: CGImage) -> VNFeaturePrintObservation? {
    let request = VNGenerateImageFeaturePrintRequest()
    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    try? handler.perform([request])
    return (request.results as? [VNFeaturePrintObservation])?.first
}

// Compute L2-style distance between two feature prints (lower = more similar)
func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Float {
    var dist: Float = 0
    try? a.computeDistance(&dist, to: b)
    return dist
}

// MARK: - Reference photo embedding (optional)

var referencePrint: VNFeaturePrintObservation? = nil
var referenceLabel = "(none)"

if let refPath = refPhotoPath {
    let refURL = URL(fileURLWithPath: refPath)
    guard FileManager.default.fileExists(atPath: refPath),
          let ciImg = CIImage(contentsOf: refURL),
          let cgImg = CIContext().createCGImage(ciImg, from: ciImg.extent) else {
        print("Error: could not load reference photo: \(refPath)")
        exit(1)
    }

    let faces = detectFaceBoxes(in: cgImg)
    guard let bestFace = faces.max(by: { $0.confidence < $1.confidence }),
          let faceCrop = cropFace(cgImg, box: bestFace.boundingBox) else {
        print("Error: no face detected in reference photo: \(refPath)")
        exit(1)
    }

    referencePrint = featurePrint(for: faceCrop)
    referenceLabel = URL(fileURLWithPath: refPath).lastPathComponent
    print("  Reference: \(referenceLabel) — face detected (conf \(String(format: "%.2f", bestFace.confidence)))")
}
print("")

// MARK: - Helpers

func formatTimecode(_ seconds: Double) -> String {
    let s = Int(seconds)
    return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
}

func progressBar(done: Int, total: Int, width: Int = 28) -> String {
    let pct    = total > 0 ? Double(done) / Double(total) : 0
    let filled = Int(pct * Double(width))
    let bar    = String(repeating: "█", count: filled)
             + String(repeating: "░", count: width - filled)
    return "[\(bar)] \(String(format: "%3.0f%%", pct * 100))"
}

// MARK: - Processing loop

struct FaceHit {
    let frameIndex:  Int
    let timecode:    Double
    let confidence:  Float       // Vision detection confidence
    let similarity:  Float?      // distance to reference (nil if no reference)
}

var hits:         [FaceHit] = []
var framesChecked = 0
let startTime     = Date()
var timedOut      = false

print("Scanning...")
print("")

for step in 0 ..< framesToProcess {

    // Timeout check
    let elapsed = Date().timeIntervalSince(startTime)
    if elapsed >= timeoutSecs {
        timedOut = true
        print("\r\u{1B}[K  [TIMEOUT] Reached \(Int(timeoutSecs))s after \(framesChecked)/\(framesToProcess) frames.")
        break
    }

    let frameIndex   = step * frameStep
    let frameSeconds = Double(frameIndex) / Double(nominalFPS)
    let frameTime    = CMTime(seconds: frameSeconds, preferredTimescale: 600)

    let cgImage: CGImage
    do {
        cgImage = try generator.copyCGImage(at: frameTime, actualTime: nil)
    } catch {
        continue
    }

    let observations = detectFaceBoxes(in: cgImage)
    framesChecked += 1

    for obs in observations {
        var similarity: Float? = nil

        if let refPrint = referencePrint,
           let faceCrop = cropFace(cgImage, box: obs.boundingBox),
           let facePrint = featurePrint(for: faceCrop) {
            similarity = distance(refPrint, facePrint)
        }

        hits.append(FaceHit(
            frameIndex: frameIndex,
            timecode:   frameSeconds,
            confidence: obs.confidence,
            similarity: similarity
        ))
    }

    // Progress
    let elapsed2 = Date().timeIntervalSince(startTime)
    let etaStr: String
    if framesChecked > 1 {
        let remaining = Double(framesToProcess - framesChecked) * (elapsed2 / Double(framesChecked))
        etaStr = "ETA \(String(format: "%.0f", remaining))s"
    } else {
        etaStr = "ETA --s"
    }
    let bar = progressBar(done: framesChecked, total: framesToProcess)
    print("\r\u{1B}[K  \(bar)  \(framesChecked)/\(framesToProcess) frames  faces: \(hits.count)  \(etaStr)",
          terminator: "")
    fflush(stdout)
}

print("")
print("")

// MARK: - Results

print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

if referencePrint != nil {
    // Sort by similarity (lower distance = better match)
    let sorted = hits.compactMap { h -> (FaceHit, Float)? in
        guard let s = h.similarity else { return nil }
        return (h, s)
    }.sorted { $0.1 < $1.1 }

    // Normalise distances to a 0–100 similarity score within this result set
    let minDist = sorted.first?.1 ?? 0
    let maxDist = sorted.last?.1  ?? 1
    let range   = max(maxDist - minDist, 0.001)

    func score(_ d: Float) -> Int { Int(((maxDist - d) / range) * 100) }

    let topN = min(20, sorted.count)

    print("Best matches for: \(referenceLabel)")
    print("(top \(topN) of \(sorted.count) detected faces — lower distance = closer match)")
    print("")
    print("  Timecode    Frame    Distance  Score  Det-Conf")
    print("  ─────────   ──────   ────────  ─────  ────────")
    for (hit, dist) in sorted.prefix(topN) {
        let s      = score(dist)
        let marker = s >= 80 ? " ***" : s >= 60 ? " **" : s >= 40 ? " *" : ""
        print("  \(formatTimecode(hit.timecode))   \(String(format: "%6d", hit.frameIndex))   \(String(format: "%.4f", dist))   \(String(format: "%3d", s))%%  \(String(format: "%.2f", hit.confidence))\(marker)")
    }

} else {
    // No reference — plain face list
    if hits.isEmpty {
        print("No faces detected.")
    } else {
        print("Frames with faces:")
        print("")
        print("  Timecode    Frame    Det-Conf")
        print("  ─────────   ──────   ────────")
        for hit in hits {
            print("  \(formatTimecode(hit.timecode))   \(String(format: "%6d", hit.frameIndex))   \(String(format: "%.2f", hit.confidence))")
        }
    }
}

print("")
print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
print("Summary")
print("  Frames checked  : \(framesChecked) of \(framesToProcess)\(timedOut ? " (timed out)" : "")")
print("  Total faces     : \(hits.count)")
if referencePrint != nil, let best = hits.compactMap({ ($0, $0.similarity ?? 9) } as ((FaceHit) -> (FaceHit, Float))).min(by: { $0.1 < $1.1 }) {
    print("  Best match      : \(formatTimecode(best.0.timecode)) (dist \(String(format: "%.3f", best.1)))")
}
let totalElapsed = Date().timeIntervalSince(startTime)
print("  Elapsed time    : \(String(format: "%.1f", totalElapsed))s")
print("")
print(timedOut ? "Done (timed out)." : "Done.")
print("")
