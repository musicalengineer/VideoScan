#!/usr/bin/env swift
// PersonFinder.swift
// Scans a directory tree of video files to find all videos containing a specific person
// (identified by one or more reference photos), extracts clips, and produces a CSV report.
//
// Usage: swift PersonFinder.swift <reference_photo_or_folder> <search_path> [options]

import Foundation
import AVFoundation
import Vision
import CoreImage
import CoreGraphics

// MARK: - Configuration

struct Config {
    var referencePath: String = ""      // single photo file OR folder of photos
    var searchPath: String = ""
    var name: String = ""
    var outputDir: String = ""
    var noClips: Bool = false
    var skipBundles: Bool = true    // skip .fcpbundle, .imovielibrary, etc.
    var frameStep: Int = 5
    var threshold: Float = 0.52         // max face distance (lower = stricter; was 0.65)
    var minFaceConfidence: Float = 0.55 // min Vision detection confidence to attempt recognition
    var pad: Double = 2.0
    var minDuration: Double = 1.0
    var minPresenceSecs: Double = 5.0   // skip video if total detected presence < this
    var requirePrimary: Bool = false    // only count hit when matched face is largest in frame
    var concatOutput: Bool = false      // after clips, concatenate into one compiled video
    var concatOutputPath: String = ""   // derived from name if empty
    var concurrency: Int = 4            // number of videos to process in parallel
    var decadeChapters: Bool = false    // produce chapter-based decadal compiled video
}

// MARK: - Data Structures

struct FaceHit {
    let frameIndex: Int
    let timecodeSeconds: Double
    let distance: Float
    let confidence: Float
}

struct ClipSegment {
    var startSeconds: Double
    var endSeconds: Double
    var hits: [FaceHit]

    var bestDistance: Float {
        hits.map(\.distance).min() ?? 0
    }
    var avgDistance: Float {
        guard !hits.isEmpty else { return 0 }
        return hits.map(\.distance).reduce(0, +) / Float(hits.count)
    }

    var durationSeconds: Double {
        endSeconds - startSeconds
    }
}

struct VideoResult {
    let filename: String
    let filePath: String
    let durationSeconds: Double
    let fps: Double
    let totalHits: Int
    let segments: [ClipSegment]
    var clipFiles: [String]  // filled after extraction

    var totalPresenceSecs: Double {
        segments.map(\.durationSeconds).reduce(0, +)
    }
}

// MARK: - Helpers

let videoExtensions: Set<String> = [
    // QuickTime / Apple
    "mov", "qt",
    // MPEG-4
    "mp4", "m4v", "m4p", "m4b",
    // AVI / Windows
    "avi", "divx",
    // Windows Media
    "wmv", "asf",
    // Matroska / WebM
    "mkv", "webm",
    // Professional / Broadcast
    "mxf",
    // AVCHD (Sony, Panasonic, Canon camcorders)
    "mts", "m2ts",
    // MPEG Transport / Program Streams
    "ts", "m2t", "trp", "tp",
    // MPEG-1/2
    "mpg", "mpeg", "mpe", "mpv", "m2v", "m2p", "mp2v", "vob", "dat",
    // DV tape captures
    "dv", "dif",
    // 3GPP (older phones)
    "3gp", "3g2", "3gpp", "3gpp2",
    // Flash
    "flv", "f4v",
    // JVC / Panasonic SD camcorders (very common in home video collections)
    "mod", "tod",
    // Ogg
    "ogv", "ogm",
    // Motion JPEG
    "mjpeg", "mjpg",
    // HEVC / H.264 elementary streams
    "hevc", "h264", "h265", "264", "265",
    // RealMedia (rare but exists in older archives)
    "rm", "rmvb",
    // Misc
    "amv", "wtv", "dvr-ms"
]

// Apple media bundle directory extensions to skip by default
let bundleExtensions: Set<String> = [
    "fcpbundle", "imovielibrary", "photoslibrary", "aplibrary", "dvdmedia",
    "imovieproject",    // older iMovie project packages (render/cache files, not originals)
    "dvdproj",          // DVD Studio Pro projects
    "prproj",           // Premiere Pro project (not a media bundle but avoid confusion)
    "aep", "aet",       // After Effects projects
    "fcp",              // older Final Cut Pro project packages
]

func printUsage() {
    let usage = """
    Usage: swift PersonFinder.swift <reference_photo_or_folder> <search_path> [options]

      <reference_photo_or_folder>  A single photo file, OR a folder containing
                                   multiple photos of the same person (different
                                   angles, lighting, ages, hairstyles, etc.)

    Options:
      --name NAME              Person name for output files (default: photo/folder name stem)
      --output DIR             Output directory for clips (default: ./<Name>_clips)
      --no-clips               Skip clip extraction, report only
      --include-bundles        Include files inside .fcpbundle, .imovielibrary, etc.
                               (skipped by default to avoid duplicates)
      --frame-step N           Check every Nth frame (default: 10)
      --threshold F            Max face distance to count as match (default: 0.52)
                               Lower = stricter; range typically 0.0-1.0
      --min-face-confidence F  Min Vision detection confidence to attempt recognition (default: 0.90)
                               Filters out blurry, partial, or background faces
      --pad F                  Seconds to pad each clip (default: 2.0)
      --min-duration F         Minimum individual clip duration in seconds (default: 1.0)
      --min-presence-secs F    Skip video if total detected presence < this many seconds (default: 60.0)
                               Use 0 to disable the filter
      --require-primary        Only count a face hit when the matched face is the largest in the frame
                               (person must be the main subject, not in background)
      --concat-output          After extracting clips, also concatenate all clips into one compiled video
      --concat-path PATH       Output path for compiled video (default: ./<Name>_compiled_<timestamp>.mov)
      --concurrency N          Number of videos to process in parallel (default: 4)
                               Increase for local drives (8-12), decrease for slow network drives (1-2)
      --decade-chapters        Produce a chapter-based compiled video sorted by decade
                               (e.g. "1980s", "1990s", "2000s") using ffmpeg
                               Implies --concat-output; chapters are navigable in QuickTime/VLC
      --help                   Show usage
    """
    print(usage)
}

func exitWithError(_ message: String) -> Never {
    fputs("Error: \(message)\n", stderr)
    exit(1)
}

/// Sanitize a string for safe use in filenames.
func sanitizeFilename(_ input: String) -> String {
    var result = input.replacingOccurrences(of: " ", with: "_")
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    result = String(result.unicodeScalars.filter { allowed.contains($0) })
    return result
}

/// Format seconds into a human-readable duration string like "8m 14s".
func formatElapsed(_ seconds: Double) -> String {
    let total = Int(seconds)
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 {
        return "\(h)h \(m)m \(s)s"
    } else if m > 0 {
        return "\(m)m \(s)s"
    } else {
        return "\(s)s"
    }
}

/// Format seconds as X:XX for display.
func formatDuration(_ seconds: Double) -> String {
    let total = Int(seconds)
    let m = total / 60
    let s = total % 60
    return String(format: "%d:%02d", m, s)
}

/// Build a progress bar string of given width.
func progressBar(fraction: Double, width: Int = 28) -> String {
    let clamped = max(0, min(1, fraction))
    let filled = Int(clamped * Double(width))
    let empty = width - filled
    return String(repeating: "\u{2588}", count: filled) + String(repeating: "\u{2591}", count: empty)
}

// MARK: - Thread-Safe Logging

/// Serialises all console output so lines from concurrent video tasks don't interleave.
final class Logger: @unchecked Sendable {
    static let shared = Logger()
    private let queue = DispatchQueue(label: "videoscan.logger")

    func log(_ message: String) {
        queue.sync { print(message) }
    }

    /// Print a completed-video summary line. In concurrent mode the animated
    /// progress bar is skipped; we just show start + result lines.
    func videoStart(_ line: String) { log(line) }
    func videoResult(_ line: String) { log("  \u{2192} \(line)") }
}

// MARK: - Face Detection & Feature Printing

/// Detect faces in a CGImage and return the observations sorted by confidence (highest first).
func detectFaces(in image: CGImage) -> [VNFaceObservation] {
    let request = VNDetectFaceRectanglesRequest()
    request.revision = 3
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    do {
        try handler.perform([request])
    } catch {
        return []
    }
    guard let results = request.results else { return [] }
    return results.sorted { $0.confidence > $1.confidence }
}

// Shared CIContext — expensive to create; reuse across all calls.
let sharedCIContext = CIContext(options: [.useSoftwareRenderer: false])

/// Normalize a face crop: de-rotate using VNFaceObservation.roll, pad 70%, scale to 256×256.
/// Vision and CIImage share the same bottom-left coordinate origin, so no Y-flip is needed.
func normalizeFaceCrop(from source: CGImage, observation: VNFaceObservation, outputSize: Int = 256) -> CGImage? {
    let imgW   = CGFloat(source.width)
    let imgH   = CGFloat(source.height)
    let bbox   = observation.boundingBox
    let faceCX = (bbox.origin.x + bbox.width  / 2) * imgW
    let faceCY = (bbox.origin.y + bbox.height / 2) * imgH
    let roll   = CGFloat(observation.roll?.doubleValue ?? 0)
    let sideLen = max(bbox.width * imgW, bbox.height * imgH) * 1.7
    guard sideLen > 4 else { return nil }

    let ciImage = CIImage(cgImage: source)

    // Rotate around face centre so the face is upright
    let deRoll = CGAffineTransform(translationX: faceCX, y: faceCY)
        .rotated(by: -roll)
        .translatedBy(x: -faceCX, y: -faceCY)
    let rotated = ciImage.transformed(by: deRoll)

    // Crop square centred on face
    let cropOrigin = CGPoint(x: faceCX - sideLen / 2, y: faceCY - sideLen / 2)
    let cropped    = rotated.cropped(to: CGRect(origin: cropOrigin,
                                                size: CGSize(width: sideLen, height: sideLen)))

    // Translate to (0,0) and scale to outputSize
    let scale = CGFloat(outputSize) / sideLen
    let finalCI = cropped
        .transformed(by: CGAffineTransform(translationX: -cropOrigin.x, y: -cropOrigin.y))
        .transformed(by: CGAffineTransform(scaleX: scale, y: scale))

    return sharedCIContext.createCGImage(
        finalCI, from: CGRect(x: 0, y: 0, width: CGFloat(outputSize), height: CGFloat(outputSize)))
}

/// Generate a VNFeaturePrintObservation for a CGImage (should be a cropped face).
func generateFeaturePrint(for image: CGImage) -> VNFeaturePrintObservation? {
    let request = VNGenerateImageFeaturePrintRequest()
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    do {
        try handler.perform([request])
    } catch {
        return nil
    }
    return request.results?.first as? VNFeaturePrintObservation
}

// MARK: - Argument Parsing

func parseArguments() -> Config {
    var config = Config()
    let args = CommandLine.arguments
    var positional: [String] = []
    var i = 1
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--help", "-h":
            printUsage()
            exit(0)
        case "--name":
            i += 1
            guard i < args.count else { exitWithError("--name requires a value") }
            config.name = args[i]
        case "--output":
            i += 1
            guard i < args.count else { exitWithError("--output requires a value") }
            config.outputDir = args[i]
        case "--no-clips":
            config.noClips = true
        case "--include-bundles":
            config.skipBundles = false
        case "--frame-step":
            i += 1
            guard i < args.count, let val = Int(args[i]), val > 0 else {
                exitWithError("--frame-step requires a positive integer")
            }
            config.frameStep = val
        case "--threshold":
            i += 1
            guard i < args.count, let val = Float(args[i]) else {
                exitWithError("--threshold requires a float value")
            }
            config.threshold = val
        case "--min-face-confidence":
            i += 1
            guard i < args.count, let val = Float(args[i]), val >= 0, val <= 1 else {
                exitWithError("--min-face-confidence requires a float between 0 and 1")
            }
            config.minFaceConfidence = val
        case "--pad":
            i += 1
            guard i < args.count, let val = Double(args[i]) else {
                exitWithError("--pad requires a float value")
            }
            config.pad = val
        case "--min-duration":
            i += 1
            guard i < args.count, let val = Double(args[i]) else {
                exitWithError("--min-duration requires a float value")
            }
            config.minDuration = val
        case "--min-presence-secs":
            i += 1
            guard i < args.count, let val = Double(args[i]), val >= 0 else {
                exitWithError("--min-presence-secs requires a non-negative float")
            }
            config.minPresenceSecs = val
        case "--require-primary":
            config.requirePrimary = true
        case "--concat-output":
            config.concatOutput = true
        case "--concat-path":
            i += 1
            guard i < args.count else { exitWithError("--concat-path requires a value") }
            config.concatOutputPath = args[i]
        case "--concurrency":
            i += 1
            guard i < args.count, let val = Int(args[i]), val >= 1 else {
                exitWithError("--concurrency requires a positive integer")
            }
            config.concurrency = val
        case "--decade-chapters":
            config.decadeChapters = true
            config.concatOutput = true  // decade-chapters implies concat
        default:
            if arg.hasPrefix("-") {
                exitWithError("Unknown option: \(arg)")
            }
            positional.append(arg)
        }
        i += 1
    }

    guard positional.count >= 2 else {
        printUsage()
        exitWithError("Required: <reference_photo_or_folder> <search_path>")
    }
    config.referencePath = positional[0]
    config.searchPath = positional[1]

    if config.name.isEmpty {
        let lastComponent = (config.referencePath as NSString).lastPathComponent
        let stem = lastComponent.contains(".")
            ? lastComponent.components(separatedBy: ".").dropLast().joined(separator: ".")
            : lastComponent
        config.name = stem.isEmpty ? "Person" : stem
    }
    if config.outputDir.isEmpty {
        config.outputDir = "./\(config.name)_clips"
    }

    return config
}

// MARK: - Video Discovery

/// Recursively find all video files under the given path.
func findVideoFiles(at searchPath: String, skipBundles: Bool) -> [String] {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: searchPath, isDirectory: &isDir) else {
        exitWithError("Search path does not exist: \(searchPath)")
    }

    if !isDir.boolValue {
        let ext = (searchPath as NSString).pathExtension.lowercased()
        if videoExtensions.contains(ext) {
            return [searchPath]
        } else {
            exitWithError("File is not a recognized video type: \(searchPath)")
        }
    }

    var files: [String] = []
    guard let enumerator = fm.enumerator(atPath: searchPath) else {
        exitWithError("Cannot enumerate directory: \(searchPath)")
    }
    while let element = enumerator.nextObject() as? String {
        if skipBundles {
            let components = element.components(separatedBy: "/")
            let insideBundle = components.dropLast().contains {
                bundleExtensions.contains(($0 as NSString).pathExtension.lowercased())
            }
            if insideBundle {
                enumerator.skipDescendants()
                continue
            }
            let elemExt = (element as NSString).pathExtension.lowercased()
            if bundleExtensions.contains(elemExt) {
                enumerator.skipDescendants()
                continue
            }
        }

        let ext = (element as NSString).pathExtension.lowercased()
        if videoExtensions.contains(ext) {
            let base = searchPath.hasSuffix("/") ? searchPath : searchPath + "/"
            files.append(base + element)
        }
    }

    // Dedup: same filename + same file size = identical file, keep first occurrence
    var seen = Set<String>()
    var deduped: [String] = []
    for path in files.sorted() {
        let filename = (path as NSString).lastPathComponent
        let size = (try? fm.attributesOfItem(atPath: path)[.size] as? Int) ?? -1
        let key = "\(filename)|\(size)"
        if !seen.contains(key) {
            seen.insert(key)
            deduped.append(path)
        }
    }

    return deduped
}

// MARK: - Video Processing

/// Extract a single frame as CGImage using the async AVAssetImageGenerator API.
func generateFrame(generator: AVAssetImageGenerator, at cmTime: CMTime) async throws -> CGImage {
    try await withCheckedThrowingContinuation { continuation in
        generator.generateCGImageAsynchronously(for: cmTime) { image, _, error in
            if let image = image {
                continuation.resume(returning: image)
            } else {
                continuation.resume(throwing: error ?? NSError(
                    domain: "VideoScan", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "No image returned"]))
            }
        }
    }
}

/// Process a single video file and return face hits and computed segments.
func processVideo(
    filePath: String,
    referenceFeaturePrints: [VNFeaturePrintObservation],
    config: Config,
    index: Int,
    total: Int,
    concurrent: Bool = false
) async -> VideoResult? {
    let filename = (filePath as NSString).lastPathComponent
    let url = URL(fileURLWithPath: filePath)
    let asset = AVURLAsset(url: url, options: [
        AVURLAssetPreferPreciseDurationAndTimingKey: true
    ])

    // Load track, duration, and frame rate with the modern async API
    let log = Logger.shared
    let videoTrack: AVAssetTrack
    let duration: Double
    let fps: Double
    do {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            log.log("[\(index)/\(total)] \(filename)  — skipping (no video track)")
            return nil
        }
        videoTrack = track
        duration = CMTimeGetSeconds(try await asset.load(.duration))
        fps = Double(try await videoTrack.load(.nominalFrameRate))
    } catch {
        log.log("[\(index)/\(total)] \(filename)  — skipping (could not load metadata: \(error.localizedDescription))")
        return nil
    }

    let totalFrames = Int(duration * fps)
    guard totalFrames > 0, fps > 0 else {
        log.log("[\(index)/\(total)] \(filename)  — skipping (invalid duration/fps)")
        return nil
    }

    log.log("[\(index)/\(total)] \(filename)  (\(formatDuration(duration)), \(String(format: "%.1f", fps)) fps)\(concurrent ? "" : "")")

    // Set up image generator
    let generator = AVAssetImageGenerator(asset: asset)
    generator.maximumSize = CGSize(width: 1280, height: 720)
    generator.appliesPreferredTrackTransform = true
    let frameDuration = CMTimeMake(value: 1, timescale: Int32(fps))
    let tolerance = CMTimeMultiply(frameDuration, multiplier: 2)
    generator.requestedTimeToleranceBefore = tolerance
    generator.requestedTimeToleranceAfter = tolerance

    var hits: [FaceHit] = []
    let startTime = Date()
    var framesChecked = 0

    var frameIndex = 0
    while frameIndex < totalFrames {
        let timeSeconds = Double(frameIndex) / fps
        let cmTime = CMTimeMakeWithSeconds(timeSeconds, preferredTimescale: 600)

        // Extract frame
        let cgImage: CGImage
        do {
            cgImage = try await generateFrame(generator: generator, at: cmTime)
        } catch {
            frameIndex += config.frameStep
            framesChecked += 1
            continue
        }

        // Detect faces in this frame
        let allFaces = detectFaces(in: cgImage)

        // If requirePrimary, only examine the largest face in the frame.
        let candidateFaces: [VNFaceObservation]
        if config.requirePrimary {
            if let largest = allFaces.max(by: {
                ($0.boundingBox.width * $0.boundingBox.height) <
                ($1.boundingBox.width * $1.boundingBox.height)
            }) {
                candidateFaces = [largest]
            } else {
                candidateFaces = []
            }
        } else {
            candidateFaces = allFaces
        }

        for obs in candidateFaces {
            // Skip faces Vision isn't confident it detected (blurry, partial, background)
            guard obs.confidence >= config.minFaceConfidence else { continue }

            guard let cropped = normalizeFaceCrop(from: cgImage, observation: obs) else { continue }
            guard let facePrint = generateFeaturePrint(for: cropped) else { continue }

            // Take the minimum distance across all reference prints (best match wins)
            var bestDistance: Float = Float.greatestFiniteMagnitude
            for refPrint in referenceFeaturePrints {
                var d: Float = 0
                guard (try? refPrint.computeDistance(&d, to: facePrint)) != nil else { continue }
                if d < bestDistance { bestDistance = d }
            }

            if bestDistance <= config.threshold {
                hits.append(FaceHit(
                    frameIndex: frameIndex,
                    timecodeSeconds: timeSeconds,
                    distance: bestDistance,
                    confidence: obs.confidence
                ))
            }
        }

        framesChecked += 1

        // Progress display — only show animated bar in single-threaded mode
        if !concurrent {
            let totalSteps = (totalFrames + config.frameStep - 1) / config.frameStep
            let fraction = Double(framesChecked) / Double(totalSteps)
            let percent = Int(fraction * 100)
            let bar = progressBar(fraction: fraction)
            let elapsed = Date().timeIntervalSince(startTime)
            var etaStr = "..."
            if framesChecked > 0 && fraction < 1.0 {
                let remaining = Double(totalSteps - framesChecked)
                let etaSec = Int(remaining * (elapsed / Double(framesChecked)))
                etaStr = "\(etaSec)s"
            }
            fputs("\r\u{1B}[K  [\(bar)] \(percent)%  frame \(frameIndex)/\(totalFrames)  hits: \(hits.count)  ETA \(etaStr)", stdout)
            fflush(stdout)
        }

        frameIndex += config.frameStep
    }

    if !concurrent { print("") }  // newline after progress bar

    guard !hits.isEmpty else {
        log.log("  [\(index)/\(total)] \(filename)  → no matches")
        return VideoResult(
            filename: filename, filePath: filePath,
            durationSeconds: duration, fps: fps,
            totalHits: 0, segments: [], clipFiles: []
        )
    }

    let sortedHits = hits.sorted { $0.timecodeSeconds < $1.timecodeSeconds }
    let gapTolerance = Double(config.frameStep) / fps * 3.0

    // Cluster hits into raw segments
    var rawSegments: [ClipSegment] = []
    var currentSeg = ClipSegment(
        startSeconds: sortedHits[0].timecodeSeconds,
        endSeconds: sortedHits[0].timecodeSeconds,
        hits: [sortedHits[0]]
    )
    for i in 1..<sortedHits.count {
        let hit = sortedHits[i]
        if hit.timecodeSeconds - currentSeg.endSeconds <= gapTolerance {
            currentSeg.endSeconds = hit.timecodeSeconds
            currentSeg.hits.append(hit)
        } else {
            rawSegments.append(currentSeg)
            currentSeg = ClipSegment(
                startSeconds: hit.timecodeSeconds,
                endSeconds: hit.timecodeSeconds,
                hits: [hit]
            )
        }
    }
    rawSegments.append(currentSeg)

    // Apply padding and merge overlapping segments
    var padded = rawSegments.map { seg -> ClipSegment in
        var s = seg
        s.startSeconds = max(0, s.startSeconds - config.pad)
        s.endSeconds = min(duration, s.endSeconds + config.pad)
        return s
    }
    padded.sort { $0.startSeconds < $1.startSeconds }

    var merged: [ClipSegment] = []
    for seg in padded {
        if var last = merged.last, seg.startSeconds <= last.endSeconds {
            last.endSeconds = max(last.endSeconds, seg.endSeconds)
            last.hits.append(contentsOf: seg.hits)
            merged[merged.count - 1] = last
        } else {
            merged.append(seg)
        }
    }

    let finalSegments = merged.filter { $0.durationSeconds >= config.minDuration }
    let presenceSecs = finalSegments.map(\.durationSeconds).reduce(0, +)
    log.log("  [\(index)/\(total)] \(filename)  → \(hits.count) hits, \(finalSegments.count) segments, \(formatDuration(presenceSecs)) presence")

    return VideoResult(
        filename: filename, filePath: filePath,
        durationSeconds: duration, fps: fps,
        totalHits: hits.count, segments: finalSegments, clipFiles: []
    )
}

// MARK: - Clip Extraction

/// Extract a single clip from a video using the async export API.
func extractClip(
    asset: AVURLAsset,
    startSeconds: Double,
    endSeconds: Double,
    outputURL: URL
) async -> Bool {
    guard let exportSession = AVAssetExportSession(
        asset: asset,
        presetName: AVAssetExportPresetHighestQuality
    ) else {
        fputs("  Error: Could not create export session\n", stderr)
        return false
    }

    let startTime = CMTimeMakeWithSeconds(startSeconds, preferredTimescale: 600)
    let clipDuration = CMTimeMakeWithSeconds(endSeconds - startSeconds, preferredTimescale: 600)
    exportSession.timeRange = CMTimeRangeMake(start: startTime, duration: clipDuration)

    do {
        try await exportSession.export(to: outputURL, as: .mov)
        return true
    } catch {
        fputs("  Error exporting clip: \(error.localizedDescription)\n", stderr)
        return false
    }
}

/// Extract all clips for the results, updating clipFiles in place.
/// Clips across different source videos are extracted concurrently.
func extractAllClips(results: inout [VideoResult], config: Config) async {
    let fm = FileManager.default
    do {
        try fm.createDirectory(atPath: config.outputDir, withIntermediateDirectories: true)
    } catch {
        fputs("Error creating output directory: \(error.localizedDescription)\n", stderr)
        return
    }

    let log = Logger.shared

    // Build a flat work list: (resultIndex, segmentIndex, clipName, outputURL, asset)
    struct ClipWork {
        let ri: Int; let si: Int
        let clipName: String; let outputURL: URL
        let asset: AVURLAsset
        let startSecs: Double; let endSecs: Double
    }
    var workItems: [ClipWork] = []

    for ri in 0..<results.count {
        let result = results[ri]
        guard !result.segments.isEmpty else { continue }
        let url = URL(fileURLWithPath: result.filePath)
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let videoStem = sanitizeFilename((result.filename as NSString).deletingPathExtension)
        for (si, segment) in result.segments.enumerated() {
            let totalSec = Int(segment.startSeconds)
            let clipName = String(
                format: "%@_%@_%02dh%02dm%02ds_%03d.mov",
                sanitizeFilename(config.name), videoStem,
                totalSec / 3600, (totalSec % 3600) / 60, totalSec % 60,
                si + 1
            )
            let outputURL = URL(fileURLWithPath: config.outputDir).appendingPathComponent(clipName)
            if fm.fileExists(atPath: outputURL.path) { try? fm.removeItem(at: outputURL) }
            workItems.append(ClipWork(ri: ri, si: si, clipName: clipName, outputURL: outputURL,
                                     asset: asset, startSecs: segment.startSeconds, endSecs: segment.endSeconds))
        }
    }

    // Pre-size clipFiles arrays
    for ri in 0..<results.count {
        results[ri].clipFiles = Array(repeating: "", count: results[ri].segments.count)
    }

    // Extract concurrently, bounded by config.concurrency
    let workCount = workItems.count
    await withTaskGroup(of: (Int, Bool).self) { group in
        var submitted = 0
        let seed = min(config.concurrency, workCount)
        for i in 0..<seed {
            let w = workItems[i]
            group.addTask {
                let ok = await extractClip(asset: w.asset, startSeconds: w.startSecs,
                                           endSeconds: w.endSecs, outputURL: w.outputURL)
                return (i, ok)
            }
            submitted += 1
        }
        for await (widx, ok) in group {
            let w = workItems[widx]
            if ok {
                log.log("  \u{2192} Saved: \(w.clipName)")
                results[w.ri].clipFiles[w.si] = w.clipName
            }
            if submitted < workCount {
                let nextIdx = submitted
                let nw = workItems[nextIdx]
                group.addTask {
                    let ok = await extractClip(asset: nw.asset, startSeconds: nw.startSecs,
                                               endSeconds: nw.endSecs, outputURL: nw.outputURL)
                    return (nextIdx, ok)
                }
                submitted += 1
            }
        }
    }
}

// MARK: - Year / Decade Utilities

/// Extract a 4-digit year (1920–2029) from a file path, trying the filename first,
/// then the parent directory names, then the file's creation date as a fallback.
func extractYear(from path: String) -> Int? {
    // Search filename and each path component for a plausible year
    let components = path.components(separatedBy: "/")
    let pattern = try? NSRegularExpression(pattern: "\\b(19[2-9][0-9]|20[0-2][0-9])\\b")
    // Prefer the filename, then walk up the path
    for component in components.reversed() {
        let range = NSRange(component.startIndex..., in: component)
        if let m = pattern?.firstMatch(in: component, range: range),
           let yr = Range(m.range(at: 1), in: component),
           let year = Int(component[yr]) {
            return year
        }
    }
    // Fallback: file creation date
    if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
       let created = attrs[.creationDate] as? Date {
        return Calendar.current.component(.year, from: created)
    }
    return nil
}

/// Round a year down to its decade label, e.g. 1984 → "1980s", 2003 → "2000s".
func decadeLabel(for year: Int) -> String {
    return "\((year / 10) * 10)s"
}

// MARK: - Decade-Chapter Concat (ffmpeg)

struct ClipEntry {
    let clipPath: String        // absolute path to the extracted .mov clip
    let sourceVideoPath: String // original source video (used for year extraction)
    let year: Int               // estimated year
    let decade: String          // e.g. "1980s"
}

/// Build clip entries from results, infer year from source path, sort chronologically.
func buildSortedClipEntries(results: [VideoResult], outputDir: String) -> [ClipEntry] {
    var entries: [ClipEntry] = []
    for result in results {
        let year = extractYear(from: result.filePath) ?? 2000
        let decade = decadeLabel(for: year)
        for clipName in result.clipFiles where !clipName.isEmpty {
            let clipPath = (outputDir as NSString).appendingPathComponent(clipName)
            entries.append(ClipEntry(
                clipPath: clipPath, sourceVideoPath: result.filePath,
                year: year, decade: decade))
        }
    }
    // Sort by year, then by source video path (preserves timecode order within a video)
    return entries.sorted {
        $0.year != $1.year ? $0.year < $1.year : $0.sourceVideoPath < $1.sourceVideoPath
    }
}

/// Concatenate clips into a single video with navigable decade chapter markers using ffmpeg.
func concatenateWithDecadeChapters(results: [VideoResult], config: Config) async {
    let entries = buildSortedClipEntries(results: results, outputDir: config.outputDir)
    guard !entries.isEmpty else { fputs("  No clips to compile.\n", stderr); return }

    // Load duration of each clip to compute chapter timestamps
    var durations: [Double] = []
    for entry in entries {
        let asset = AVURLAsset(url: URL(fileURLWithPath: entry.clipPath),
                               options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let dur = (try? await CMTimeGetSeconds(asset.load(.duration))) ?? 0
        durations.append(dur)
    }

    // Compute chapter boundaries (decade transitions)
    struct Chapter { let title: String; let startMs: Int64 }
    var chapters: [Chapter] = []
    var cumulativeMs: Int64 = 0
    var currentDecade = ""
    for (i, entry) in entries.enumerated() {
        if entry.decade != currentDecade {
            chapters.append(Chapter(title: entry.decade, startMs: cumulativeMs))
            currentDecade = entry.decade
        }
        cumulativeMs += Int64(durations[i] * 1000)
    }
    let totalMs = cumulativeMs

    // Write ffmpeg concat file list
    let tmp = NSTemporaryDirectory()
    let ts = Int(Date().timeIntervalSince1970)
    let listPath = (tmp as NSString).appendingPathComponent("pf_list_\(ts).txt")
    let metaPath = (tmp as NSString).appendingPathComponent("pf_meta_\(ts).txt")

    let listContent = entries.map { "file '\($0.clipPath)'" }.joined(separator: "\n")
    try? listContent.write(toFile: listPath, atomically: true, encoding: .utf8)

    // Write ffmetadata with chapter markers
    var meta = ";FFMETADATA1\n\n"
    for (i, chapter) in chapters.enumerated() {
        let end = i + 1 < chapters.count ? chapters[i + 1].startMs : totalMs
        meta += "[CHAPTER]\nTIMEBASE=1/1000\nSTART=\(chapter.startMs)\nEND=\(end)\ntitle=\(chapter.title)\n\n"
    }
    try? meta.write(toFile: metaPath, atomically: true, encoding: .utf8)

    // Determine output path
    let df = DateFormatter(); df.dateFormat = "yyyyMMdd_HHmmss"
    let outputPath = config.concatOutputPath.isEmpty
        ? (config.outputDir as NSString).appendingPathComponent(
            "\(sanitizeFilename(config.name))_by_decade_\(df.string(from: Date())).mov")
        : config.concatOutputPath

    let fm = FileManager.default
    if fm.fileExists(atPath: outputPath) { try? fm.removeItem(atPath: outputPath) }

    // Locate ffmpeg
    let ffmpegCandidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
    guard let ffmpegPath = ffmpegCandidates.first(where: { fm.fileExists(atPath: $0) }) else {
        fputs("  ⚠ ffmpeg not found — install via: brew install ffmpeg\n", stderr)
        try? fm.removeItem(atPath: listPath); try? fm.removeItem(atPath: metaPath)
        return
    }

    print("  Building decade chapter video (\(chapters.map(\.title).joined(separator: ", ")))…")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: ffmpegPath)
    process.arguments = [
        "-hide_banner", "-nostdin",
        "-f", "concat", "-safe", "0", "-i", listPath,
        "-i", metaPath,
        "-map_metadata", "1",
        "-map_chapters", "1",
        "-vf", "scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30000/1001",
        "-c:v", "libx264", "-preset", "fast", "-crf", "18",
        "-c:a", "aac", "-b:a", "192k",
        "-movflags", "+faststart",
        "-y", outputPath
    ]
    process.standardOutput = FileHandle.nullDevice
    // Drain stderr to prevent 64KB pipe buffer deadlock
    let chapterStderrPipe = Pipe()
    process.standardError = chapterStderrPipe
    chapterStderrPipe.fileHandleForReading.readabilityHandler = { handle in
        _ = handle.availableData  // discard but drain
    }

    do { try process.run() } catch {
        fputs("  ⚠ Could not launch ffmpeg: \(error.localizedDescription)\n", stderr)
        try? fm.removeItem(atPath: listPath); try? fm.removeItem(atPath: metaPath)
        return
    }

    // Wait for ffmpeg asynchronously without blocking the actor
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        process.terminationHandler = { _ in cont.resume() }
        if !process.isRunning { cont.resume() }  // already done edge case
    }
    chapterStderrPipe.fileHandleForReading.readabilityHandler = nil
    try? fm.removeItem(atPath: listPath); try? fm.removeItem(atPath: metaPath)

    if process.terminationStatus == 0 {
        let totalSecs = durations.reduce(0, +)
        print("  → Decade video saved: \(outputPath)")
        print("  → Duration: \(formatElapsed(totalSecs))  Chapters: \(chapters.map(\.title).joined(separator: " · "))")
    } else {
        fputs("  ⚠ ffmpeg exited with code \(process.terminationStatus)\n", stderr)
    }
}

// MARK: - Concat Output (simple, no chapters)

/// Concatenate all extracted clips (in order) into a single compiled video.
func concatenateClips(results: [VideoResult], config: Config) async {
    var clipPaths: [String] = []
    for result in results {
        for clipName in result.clipFiles where !clipName.isEmpty {
            clipPaths.append((config.outputDir as NSString).appendingPathComponent(clipName))
        }
    }

    guard !clipPaths.isEmpty else {
        fputs("  No clips to concatenate.\n", stderr)
        return
    }

    let fm = FileManager.default
    let ffmpegCandidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
    guard let ffmpegPath = ffmpegCandidates.first(where: { fm.fileExists(atPath: $0) }) else {
        fputs("  ⚠ ffmpeg not found — install via: brew install ffmpeg\n", stderr)
        return
    }

    // Write concat list
    let tmp = NSTemporaryDirectory()
    let ts = Int(Date().timeIntervalSince1970)
    let listPath = (tmp as NSString).appendingPathComponent("pf_concat_\(ts).txt")
    let listContent = clipPaths.map { "file '\($0)'" }.joined(separator: "\n")
    try? listContent.write(toFile: listPath, atomically: true, encoding: .utf8)

    // Determine output path
    let df = DateFormatter(); df.dateFormat = "yyyyMMdd_HHmmss"
    let outputPath = config.concatOutputPath.isEmpty
        ? (config.outputDir as NSString).appendingPathComponent(
            "\(sanitizeFilename(config.name))_compiled_\(df.string(from: Date())).mp4")
        : config.concatOutputPath

    if fm.fileExists(atPath: outputPath) { try? fm.removeItem(atPath: outputPath) }

    print("  Normalising and compiling \(clipPaths.count) clips via ffmpeg…")
    print("  Re-encoding to uniform H.264 1280x720 @ 29.97fps to avoid codec mismatch corruption")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: ffmpegPath)
    process.arguments = [
        "-hide_banner", "-nostdin",
        "-f", "concat", "-safe", "0", "-i", listPath,
        "-vf", "scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30000/1001",
        "-c:v", "libx264", "-preset", "fast", "-crf", "18",
        "-c:a", "aac", "-b:a", "192k",
        "-movflags", "+faststart",
        "-y", outputPath
    ]
    process.standardOutput = FileHandle.nullDevice
    // Drain stderr asynchronously to prevent 64KB pipe buffer deadlock
    // when ffmpeg emits many warnings with mixed-format inputs.
    let stderrPipe = Pipe()
    process.standardError = stderrPipe
    let stderrBox = StderrBox()
    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        if !chunk.isEmpty { stderrBox.append(chunk) }
    }

    do { try process.run() } catch {
        fputs("  ⚠ Could not launch ffmpeg: \(error.localizedDescription)\n", stderr)
        try? fm.removeItem(atPath: listPath)
        return
    }

    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        process.terminationHandler = { _ in cont.resume() }
        if !process.isRunning { cont.resume() }
    }
    stderrPipe.fileHandleForReading.readabilityHandler = nil
    try? fm.removeItem(atPath: listPath)

    if process.terminationStatus == 0 {
        print("  → Compiled video saved: \(outputPath)")
    } else {
        let errText = stderrBox.text
        fputs("  ⚠ ffmpeg exited with code \(process.terminationStatus)\n", stderr)
        if !errText.isEmpty {
            let lastLines = errText.split(separator: "\n").suffix(10).joined(separator: "\n")
            fputs("  stderr (last 10 lines):\n\(lastLines)\n", stderr)
        }
    }
}

// MARK: - CSV Report

func csvEscape(_ field: String) -> String {
    if field.contains(",") || field.contains("\"") || field.contains("\n") {
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    return field
}

func writeCSVReport(results: [VideoResult], filteredCount: Int, config: Config) -> String {
    let fm = FileManager.default
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
    let timestamp = dateFormatter.string(from: Date())
    let csvFilename = "\(sanitizeFilename(config.name))_report_\(timestamp).csv"

    let reportDir: String
    if config.noClips {
        reportDir = fm.currentDirectoryPath
    } else {
        reportDir = config.outputDir
        try? fm.createDirectory(atPath: reportDir, withIntermediateDirectories: true)
    }

    let csvPath = (reportDir as NSString).appendingPathComponent(csvFilename)

    var lines: [String] = []
    lines.append("Person,VideoFile,VideoPath,DurationSecs,FPS,TotalHits,SegmentsFound,PresenceSecs,ClipFile,ClipStartSecs,ClipEndSecs,BestDistance,AvgDistance")

    for result in results {
        if result.segments.isEmpty {
            let row = [
                csvEscape(config.name), csvEscape(result.filename), csvEscape(result.filePath),
                String(format: "%.2f", result.durationSeconds),
                String(format: "%.1f", result.fps),
                "0", "0", "0", "", "", "", "", ""
            ].joined(separator: ",")
            lines.append(row)
        } else {
            let presenceSecs = result.totalPresenceSecs
            for (si, segment) in result.segments.enumerated() {
                let clipFile = si < result.clipFiles.count ? result.clipFiles[si] : ""
                let row = [
                    csvEscape(config.name), csvEscape(result.filename), csvEscape(result.filePath),
                    String(format: "%.2f", result.durationSeconds),
                    String(format: "%.1f", result.fps),
                    "\(result.totalHits)", "\(result.segments.count)",
                    String(format: "%.1f", presenceSecs),
                    csvEscape(clipFile),
                    String(format: "%.2f", segment.startSeconds),
                    String(format: "%.2f", segment.endSeconds),
                    String(format: "%.4f", segment.bestDistance),
                    String(format: "%.4f", segment.avgDistance)
                ].joined(separator: ",")
                lines.append(row)
            }
        }
    }

    let csvContent = lines.joined(separator: "\n") + "\n"
    do {
        try csvContent.write(toFile: csvPath, atomically: true, encoding: .utf8)
    } catch {
        fputs("Error writing CSV report: \(error.localizedDescription)\n", stderr)
    }

    return csvPath
}

// MARK: - Main

func main() async {
    let overallStart = Date()
    let config = parseArguments()

    // Step 1: Load reference photo(s) and extract face feature prints
    let fm = FileManager.default
    let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp", "gif"]

    guard fm.fileExists(atPath: config.referencePath) else {
        exitWithError("Reference path not found: \(config.referencePath)")
    }

    var imagePaths: [String] = []
    var isDir: ObjCBool = false
    fm.fileExists(atPath: config.referencePath, isDirectory: &isDir)
    if isDir.boolValue {
        print("Loading reference photos from folder: \(config.referencePath)")
        guard let enumerator = fm.enumerator(atPath: config.referencePath) else {
            exitWithError("Cannot enumerate reference folder: \(config.referencePath)")
        }
        while let element = enumerator.nextObject() as? String {
            let ext = (element as NSString).pathExtension.lowercased()
            if imageExtensions.contains(ext) {
                imagePaths.append((config.referencePath as NSString).appendingPathComponent(element))
            }
        }
        imagePaths.sort()
        guard !imagePaths.isEmpty else {
            exitWithError("No image files found in reference folder: \(config.referencePath)")
        }
    } else {
        print("Loading reference photo: \(config.referencePath)")
        imagePaths = [config.referencePath]
    }

    var referenceFeaturePrints: [VNFeaturePrintObservation] = []
    for imagePath in imagePaths {
        let photoURL = URL(fileURLWithPath: imagePath)
        guard let imageSource = CGImageSourceCreateWithURL(photoURL as CFURL, nil),
              let refImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            print("  \u{26A0} Could not load image: \((imagePath as NSString).lastPathComponent) — skipping")
            continue
        }
        let faces = detectFaces(in: refImage).filter { $0.confidence >= 0.5 }
        guard !faces.isEmpty else {
            print("  \u{26A0} No face detected in: \((imagePath as NSString).lastPathComponent) — skipping")
            continue
        }
        var added = 0
        for face in faces {
            guard let cropped = normalizeFaceCrop(from: refImage, observation: face),
                  let featurePrint = generateFeaturePrint(for: cropped) else { continue }
            referenceFeaturePrints.append(featurePrint)
            added += 1
        }
        print("  \u{2713} \((imagePath as NSString).lastPathComponent)  (\(added) face(s), top conf \(String(format: "%.2f", faces[0].confidence)))")
    }

    guard !referenceFeaturePrints.isEmpty else {
        exitWithError("No usable reference faces found in: \(config.referencePath)")
    }

    print("")
    print("Reference loaded for: \(config.name)  (\(referenceFeaturePrints.count) photo(s))")
    print("Settings: threshold \(config.threshold)  min-face-confidence \(config.minFaceConfidence)  min-presence \(Int(config.minPresenceSecs))s  concurrency \(config.concurrency)\(config.requirePrimary ? "  require-primary" : "")")
    print("")

    // Step 2: Find video files
    print("Scanning for videos in: \(config.searchPath)")
    if config.skipBundles {
        print("  (skipping .fcpbundle / .imovielibrary bundles — use --include-bundles to override)")
    }
    let videoFiles = findVideoFiles(at: config.searchPath, skipBundles: config.skipBundles)
    guard !videoFiles.isEmpty else {
        exitWithError("No video files found in: \(config.searchPath)")
    }
    let concurrent = config.concurrency > 1
    print("Found \(videoFiles.count) video file(s)  (concurrency: \(config.concurrency))\n")

    // Step 3: Process videos — concurrently up to config.concurrency at a time
    // Results array is pre-sized so original order is preserved for the CSV.
    let total = videoFiles.count
    var orderedResults = [VideoResult?](repeating: nil, count: total)

    await withTaskGroup(of: (Int, VideoResult?).self) { group in
        var submitted = 0

        // Seed the initial batch
        let seed = min(config.concurrency, total)
        for i in 0..<seed {
            let idx = i
            group.addTask {
                let r = await processVideo(
                    filePath: videoFiles[idx],
                    referenceFeaturePrints: referenceFeaturePrints,
                    config: config, index: idx + 1, total: total,
                    concurrent: concurrent
                )
                return (idx, r)
            }
            submitted += 1
        }

        // As each task completes, slot its result and submit the next video
        for await (idx, result) in group {
            orderedResults[idx] = result
            if submitted < total {
                let nextIdx = submitted
                group.addTask {
                    let r = await processVideo(
                        filePath: videoFiles[nextIdx],
                        referenceFeaturePrints: referenceFeaturePrints,
                        config: config, index: nextIdx + 1, total: total,
                        concurrent: concurrent
                    )
                    return (nextIdx, r)
                }
                submitted += 1
            }
        }
    }

    var results: [VideoResult] = orderedResults.compactMap { $0 }
    if !concurrent { print("") }

    // Step 4: Filter videos below minimum presence threshold
    var filteredCount = 0
    if config.minPresenceSecs > 0 {
        results = results.map { result -> VideoResult in
            if result.totalPresenceSecs < config.minPresenceSecs && !result.segments.isEmpty {
                print("  \u{26A0} Skipping \(result.filename): \(formatDuration(result.totalPresenceSecs)) presence < \(Int(config.minPresenceSecs))s minimum")
                filteredCount += 1
                return VideoResult(
                    filename: result.filename, filePath: result.filePath,
                    durationSeconds: result.durationSeconds, fps: result.fps,
                    totalHits: result.totalHits, segments: [], clipFiles: []
                )
            }
            return result
        }
        let kept = results.filter { !$0.segments.isEmpty }.count
        if filteredCount > 0 {
            print("Presence filter: \(kept) video(s) kept, \(filteredCount) below \(Int(config.minPresenceSecs))s threshold\n")
        }
    }

    // Step 5: Extract clips
    if !config.noClips {
        let totalClips = results.reduce(0) { $0 + $1.segments.count }
        if totalClips > 0 {
            print("Extracting \(totalClips) clip(s) to: \(config.outputDir)")
            await extractAllClips(results: &results, config: config)
            print("")
        }
    }

    // Step 6: Concatenate (simple or decade-chapter)
    if !config.noClips {
        if config.decadeChapters {
            print("Creating decade chapter video...")
            await concatenateWithDecadeChapters(results: results, config: config)
            print("")
        } else if config.concatOutput {
            print("Creating compiled video...")
            await concatenateClips(results: results, config: config)
            print("")
        }
    }

    // Step 7: CSV Report
    let csvPath = writeCSVReport(results: results, filteredCount: filteredCount, config: config)

    // Step 8: Final summary
    let videosWithHits = results.filter { !$0.segments.isEmpty }.count
    let totalClips = results.reduce(0) { $0 + $1.segments.count }
    let totalPresence = results.map(\.totalPresenceSecs).reduce(0, +)
    let elapsed = Date().timeIntervalSince(overallStart)

    let separator = String(repeating: "\u{2501}", count: 45)
    print(separator)
    print("Summary: \(config.name)")
    print("  Videos scanned      : \(results.count)")
    print("  Videos with hits    : \(videosWithHits)")
    if filteredCount > 0 {
        print("  Below presence min  : \(filteredCount) (skipped)")
    }
    print("  Total clips         : \(totalClips)")
    print("  Total presence      : \(formatElapsed(totalPresence))")
    print("  Report saved        : \(csvPath)")
    if !config.noClips {
        print("  Clips saved to      : \(config.outputDir)/")
    }
    print("  Elapsed             : \(formatElapsed(elapsed))")
    print("Done.")
}

// MARK: - Entry Point
// Run main() inside a Task so async/await works in a top-level Swift script.
/// Thread-safe box for capturing stderr data from ffmpeg subprocesses.
private final class StderrBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    func append(_ chunk: Data) { lock.lock(); buffer.append(chunk); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(data: buffer, encoding: .utf8) ?? "" }
}

let _sema = DispatchSemaphore(value: 0)
Task {
    await main()
    _sema.signal()
}
_sema.wait()
