#!/usr/bin/env swift
// FaceDiagnose.swift
// Unit-test harness for face recognition accuracy.
//
// For every sampled frame in a test video it reports the distance from every
// detected face to every reference photo, so you can see exactly where false
// positives and false negatives originate.
//
// Usage:
//   swift FaceDiagnose.swift <ref_photos_dir> <video_file_or_dir> [options]
//
// Options:
//   --threshold F       Match threshold (default: 0.52)
//   --frame-step N      Sample every Nth frame (default: 1 = every frame)
//   --min-conf F        Min Vision face-detection confidence (default: 0.55)
//   --verbose           Print distance to every reference per face
//   --help

import Foundation
import AVFoundation
import Vision
import CoreImage
import CoreGraphics

// ─────────────────────────────────────────────────────────────────────────────
// MARK: CLI
// ─────────────────────────────────────────────────────────────────────────────

struct Args {
    var refPath: String = ""
    var videoPath: String = ""
    var threshold: Float = 0.52
    var frameStep: Int = 1
    var minConf: Float = 0.55
    var verbose: Bool = false
}

func parseArgs() -> Args {
    var a = Args()
    var positional: [String] = []
    var i = 1
    let argv = CommandLine.arguments
    while i < argv.count {
        let arg = argv[i]
        switch arg {
        case "--threshold":
            i += 1; if i < argv.count { a.threshold = Float(argv[i]) ?? a.threshold }
        case "--frame-step":
            i += 1; if i < argv.count { a.frameStep = Int(argv[i]) ?? a.frameStep }
        case "--min-conf":
            i += 1; if i < argv.count { a.minConf = Float(argv[i]) ?? a.minConf }
        case "--verbose":
            a.verbose = true
        case "--help", "-h":
            printUsage(); exit(0)
        default:
            if !arg.hasPrefix("--") { positional.append(arg) }
        }
        i += 1
    }
    guard positional.count >= 2 else { printUsage(); exit(1) }
    a.refPath   = positional[0]
    a.videoPath = positional[1]
    return a
}

func printUsage() {
    print("""
    Usage: swift FaceDiagnose.swift <ref_photos_dir> <video_file_or_dir> [options]

      --threshold F     Match distance threshold (default: 0.52, lower = stricter)
      --frame-step N    Sample every Nth frame (default: 1 = every frame)
      --min-conf F      Min Vision detection confidence (default: 0.55)
      --verbose         Print one distance line per (face × reference) pair
      --help            This message

    Output sections
      REFERENCE FACES   Quality table for each loaded reference photo
      PER-FRAME LOG     Every sampled frame: faces detected, best distance, hit/miss
      SUMMARY           Distance histogram, per-reference contribution, threshold advice
    """)
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Shared
// ─────────────────────────────────────────────────────────────────────────────

let ciCtx = CIContext(options: [.useSoftwareRenderer: false])

struct RefFace {
    let filename: String
    let featurePrint: VNFeaturePrintObservation
    let confidence: Float
    let yawDeg: Double
    let rollDeg: Double
    let pitchDeg: Double
}

struct FrameFace {
    let videoFile: String
    let timeSecs: Double
    let frameIdx: Int
    let faceIdx: Int          // 0 = highest-confidence
    let detConf: Float
    let areaPct: Float        // face bbox % of frame area
    let bestDist: Float
    let bestRefFile: String
    let allDists: [Float]     // one per ref, same order as refs array
    var isHit: Bool
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Image utilities — mirrors PersonFinderModel.swift exactly
// ─────────────────────────────────────────────────────────────────────────────

func normalizeCrop(from src: CGImage, obs: VNFaceObservation, size: Int = 256) -> CGImage? {
    let W = CGFloat(src.width), H = CGFloat(src.height)
    let bb = obs.boundingBox
    let cx = (bb.origin.x + bb.width  / 2) * W
    let cy = (bb.origin.y + bb.height / 2) * H
    let roll = CGFloat(obs.roll?.doubleValue ?? 0)
    let side = max(bb.width * W, bb.height * H) * 1.7
    guard side > 4 else { return nil }

    let ci = CIImage(cgImage: src)
    let deRoll = CGAffineTransform(translationX: cx, y: cy)
        .rotated(by: -roll).translatedBy(x: -cx, y: -cy)
    let rotated = ci.transformed(by: deRoll)
    let origin  = CGPoint(x: cx - side / 2, y: cy - side / 2)
    let cropped = rotated.cropped(to: CGRect(origin: origin,
                                             size: CGSize(width: side, height: side)))
    let scale   = CGFloat(size) / side
    let final   = cropped
        .transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
        .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    return ciCtx.createCGImage(final,
        from: CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size)))
}

func featurePrint(for img: CGImage) -> VNFeaturePrintObservation? {
    let req = VNGenerateImageFeaturePrintRequest()
    try? VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
    return req.results?.first as? VNFeaturePrintObservation
}

func detectFacesInBuffer(_ buf: CVPixelBuffer,
                         orientation: CGImagePropertyOrientation) -> [VNFaceObservation] {
    let req = VNDetectFaceRectanglesRequest(); req.revision = 3
    try? VNImageRequestHandler(cvPixelBuffer: buf, orientation: orientation,
                               options: [:]).perform([req])
    return (req.results ?? []).sorted { $0.confidence > $1.confidence }
}

func orientationFrom(_ t: CGAffineTransform) -> CGImagePropertyOrientation {
    switch (t.a, t.b, t.c, t.d) {
    case (0,  1, -1,  0): return .right
    case (0, -1,  1,  0): return .left
    case (-1, 0,  0, -1): return .down
    default:              return .up
    }
}

func cgImage(from buf: CVPixelBuffer, transform: CGAffineTransform) -> CGImage? {
    var ci = CIImage(cvPixelBuffer: buf).transformed(by: transform)
    ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.origin.x,
                                               y: -ci.extent.origin.y))
    return ciCtx.createCGImage(ci, from: ci.extent)
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Reference loading
// ─────────────────────────────────────────────────────────────────────────────

func loadReferences(from path: String) -> [RefFace] {
    let fm = FileManager.default
    let imgExts: Set<String> = ["jpg","jpeg","png","heic","heif","tiff","tif","bmp"]
    var imgPaths: [String] = []
    var isDir: ObjCBool = false
    fm.fileExists(atPath: path, isDirectory: &isDir)
    if isDir.boolValue {
        guard let e = fm.enumerator(atPath: path) else { return [] }
        while let el = e.nextObject() as? String {
            if imgExts.contains((el as NSString).pathExtension.lowercased()) {
                imgPaths.append((path as NSString).appendingPathComponent(el))
            }
        }
        imgPaths.sort()
    } else {
        imgPaths = [path]
    }

    var refs: [RefFace] = []
    for p in imgPaths {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
        let req = VNDetectFaceRectanglesRequest(); req.revision = 3
        try? VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
        let faces = (req.results ?? []).filter { $0.confidence >= 0.5 }
        for obs in faces {
            guard let crop = normalizeCrop(from: img, obs: obs),
                  let fp   = featurePrint(for: crop) else { continue }
            refs.append(RefFace(
                filename: (p as NSString).lastPathComponent,
                featurePrint: fp,
                confidence: obs.confidence,
                yawDeg:   (obs.yaw?.doubleValue   ?? 0) * 180 / .pi,
                rollDeg:  (obs.roll?.doubleValue  ?? 0) * 180 / .pi,
                pitchDeg: (obs.pitch?.doubleValue ?? 0) * 180 / .pi
            ))
        }
    }
    return refs
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Video file discovery
// ─────────────────────────────────────────────────────────────────────────────

func findVideos(at path: String) -> [String] {
    let vidExts: Set<String> = ["mov","mp4","m4v","avi","mkv","mxf","mts","m2ts",
                                 "mpg","mpeg","dv","3gp","wmv","ts","mod","tod"]
    let fm = FileManager.default
    var isDir: ObjCBool = false
    fm.fileExists(atPath: path, isDirectory: &isDir)
    if !isDir.boolValue {
        return vidExts.contains((path as NSString).pathExtension.lowercased()) ? [path] : []
    }
    var files: [String] = []
    guard let e = fm.enumerator(atPath: path) else { return [] }
    while let el = e.nextObject() as? String {
        if vidExts.contains((el as NSString).pathExtension.lowercased()) {
            files.append((path as NSString).appendingPathComponent(el))
        }
    }
    return files.sorted()
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Video analysis  (synchronous — uses deprecated AVAsset properties,
//       which are fine for a CLI diagnostic tool and avoid async complexity)
// ─────────────────────────────────────────────────────────────────────────────

func analyzeVideo(path: String, refs: [RefFace], args: Args) -> [FrameFace] {
    let filename = (path as NSString).lastPathComponent
    let asset = AVURLAsset(url: URL(fileURLWithPath: path),
                           options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])

    guard let track = asset.tracks(withMediaType: .video).first else {
        fputs("  Skipped \(filename): no video track\n", stderr); return []
    }
    let duration  = CMTimeGetSeconds(asset.duration)
    let fps       = Double(track.nominalFrameRate)
    let transform = track.preferredTransform

    guard duration > 0, fps > 0 else {
        fputs("  Skipped \(filename): invalid duration/fps\n", stderr); return []
    }

    let orientation = orientationFrom(transform)
    guard let reader = try? AVAssetReader(asset: asset) else {
        fputs("  Skipped \(filename): AVAssetReader init failed\n", stderr); return []
    }
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    ])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    guard reader.startReading() else {
        fputs("  Skipped \(filename): AVAssetReader start failed\n", stderr); return []
    }

    print("  \(filename)  \(String(format: "%.1f", duration))s  " +
          "\(String(format: "%.1f", fps)) fps  " +
          "step=\(args.frameStep)")

    let frameInterval = Double(args.frameStep) / fps
    var lastProcessed = -frameInterval
    var frameIdx = 0
    var results: [FrameFace] = []

    while let sb = output.copyNextSampleBuffer() {
        let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))
        guard t - lastProcessed >= frameInterval else { continue }
        lastProcessed = t

        guard let buf = CMSampleBufferGetImageBuffer(sb) else { continue }
        let allFaces = detectFacesInBuffer(buf, orientation: orientation)
            .filter { $0.confidence >= args.minConf }

        if !allFaces.isEmpty, let cgImg = cgImage(from: buf, transform: transform) {
            for (fIdx, obs) in allFaces.enumerated() {
                guard let crop = normalizeCrop(from: cgImg, obs: obs),
                      let fp   = featurePrint(for: crop) else { continue }

                var allDists: [Float] = []
                var bestDist: Float = .greatestFiniteMagnitude
                var bestRefFile = ""

                for ref in refs {
                    var d: Float = 0
                    if (try? ref.featurePrint.computeDistance(&d, to: fp)) != nil {
                        allDists.append(d)
                        if d < bestDist { bestDist = d; bestRefFile = ref.filename }
                    } else {
                        allDists.append(-1)
                    }
                }

                let areaPct = Float(obs.boundingBox.width * obs.boundingBox.height * 100)
                results.append(FrameFace(
                    videoFile:   filename,
                    timeSecs:    t,
                    frameIdx:    frameIdx,
                    faceIdx:     fIdx,
                    detConf:     obs.confidence,
                    areaPct:     areaPct,
                    bestDist:    bestDist,
                    bestRefFile: bestRefFile,
                    allDists:    allDists,
                    isHit:       bestDist <= args.threshold
                ))
            }
        }
        frameIdx += 1
    }
    return results
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Reporting
// ─────────────────────────────────────────────────────────────────────────────

func printRefTable(_ refs: [RefFace]) {
    print("\n╔══════════════════════════════════════════════════════════════════════╗")
    print(  "║  REFERENCE FACES                                                     ║")
    print(  "╠══════════════════════════════════════════════════════════════════════╣")
    print(  "║  #   Filename                         Conf   Yaw°   Roll°  Qual     ║")
    print(  "╠══════════════════════════════════════════════════════════════════════╣")
    for (i, r) in refs.enumerated() {
        let qual: String
        if r.confidence >= 0.80 && abs(r.yawDeg) < 30 && abs(r.rollDeg) < 25 { qual = "GOOD" }
        else if r.confidence >= 0.60 { qual = "FAIR" }
        else { qual = "POOR" }
        let name = String(r.filename.prefix(34))
        print(String(format: "║  %-3d %-34@ %5.2f  %6.1f  %5.1f  %-4@     ║",
                     i + 1, name as NSString, r.confidence, r.yawDeg, r.rollDeg, qual as NSString))
    }
    print(  "╚══════════════════════════════════════════════════════════════════════╝")
}

func printFrameLog(_ faces: [FrameFace], refs: [RefFace], args: Args) {
    print("\n╔══════════════════════════════════════════════════════════════════════╗")
    print(  "║  PER-FRAME FACE LOG                                                  ║")
    print(  "╠══════════════════════════════════════════════════════════════════════╣")
    print(  "║  time    face  conf    area%  best-dist  best-ref                hit ║")
    print(  "╠══════════════════════════════════════════════════════════════════════╣")

    for f in faces.sorted(by: { ($0.timeSecs, $0.faceIdx) < ($1.timeSecs, $1.faceIdx) }) {
        let hitMark = f.isHit ? "HIT" : "   "
        let ref22   = String(f.bestRefFile.prefix(22))
        print(String(format: "║ %6.2fs  #%-2d  %.3f  %5.2f%%   %.4f  %-22@  %@ ║",
                     f.timeSecs, f.faceIdx + 1, f.detConf, f.areaPct,
                     f.bestDist, ref22 as NSString, hitMark as NSString))
        if args.verbose {
            for (ri, d) in f.allDists.enumerated() {
                let marker = d <= args.threshold ? " ← MATCH" : ""
                let rname  = String(refs[ri].filename.prefix(32))
                print(String(format: "║     ref %02d  %-32@  %.4f%@",
                             ri + 1, rname as NSString, d, marker as NSString))
            }
            print("║")
        }
    }
    print(  "╚══════════════════════════════════════════════════════════════════════╝")
}

func printSummary(_ faces: [FrameFace], refs: [RefFace], args: Args) {
    guard !faces.isEmpty else {
        print("\nNo faces detected — try lowering --min-conf or --frame-step.")
        return
    }

    let hits   = faces.filter { $0.isHit }
    let misses = faces.filter { !$0.isHit }
    let dists  = faces.map { $0.bestDist }.sorted()

    // Histogram in 0.05 buckets
    print("\n╔══════════════════════════════════════════════════════════════════════╗")
    print(  "║  DISTANCE HISTOGRAM  (best-dist per face across all refs)            ║")
    print(  "╠══════════════════════════════════════════════════════════════════════╣")
    let buckets = 20
    let bw = Float(1.0) / Float(buckets)
    var counts = [Int](repeating: 0, count: buckets)
    for d in dists { counts[min(buckets - 1, Int(d / bw))] += 1 }
    let maxC = max(1, counts.max() ?? 1)
    for b in 0..<buckets {
        let lo = Float(b) * bw
        let hi = lo + bw
        let bar = String(repeating: "█", count: counts[b] * 44 / maxC)
        let mark = lo <= args.threshold && args.threshold < hi ? " ← threshold" : ""
        print(String(format: "║  %.2f–%.2f  %-44@  %3d%@",
                     lo, hi, bar as NSString, counts[b], mark as NSString))
    }
    print(  "╚══════════════════════════════════════════════════════════════════════╝")

    // Per-reference contribution
    print("\n╔══════════════════════════════════════════════════════════════════════╗")
    print(  "║  REFERENCE CONTRIBUTION  (which ref was closest match per face)      ║")
    print(  "╠══════════════════════════════════════════════════════════════════════╣")
    var refAny  = [String: Int]()   // times this ref was the closest to ANY face
    var refHits = [String: Int]()   // times this ref was closest and it was a hit
    for f in faces { refAny[f.bestRefFile,  default: 0] += 1 }
    for f in hits  { refHits[f.bestRefFile, default: 0] += 1 }
    for name in refAny.keys.sorted() {
        let a = refAny[name]!
        let h = refHits[name] ?? 0
        let flag = Double(h) / Double(a) > 0.8 ? " ← possible noisy ref" : ""
        print(String(format: "║  %-36@  closest: %3d  hits: %3d%@",
                     String(name.prefix(36)) as NSString, a, h, flag as NSString))
    }
    print(  "╚══════════════════════════════════════════════════════════════════════╝")

    // Stats + advice
    let p5  = dists[max(0, Int(Double(dists.count) * 0.05))]
    let p50 = dists[Int(Double(dists.count) * 0.50)]
    let p95 = dists[min(dists.count - 1, Int(Double(dists.count) * 0.95))]
    let hitBelow40  = hits.filter  { $0.bestDist < 0.40 }.count
    let hitAbove40  = hits.filter  { $0.bestDist >= 0.40 }.count
    let nearMisses  = misses.filter { $0.bestDist < args.threshold + 0.05 }.count
    let hitRate     = Double(hits.count) / Double(faces.count) * 100

    print("\n╔══════════════════════════════════════════════════════════════════════╗")
    print(  "║  SUMMARY                                                             ║")
    print(  "╠══════════════════════════════════════════════════════════════════════╣")
    print(String(format: "║  Faces detected:       %4d                                          ║", faces.count))
    print(String(format: "║  Hits (≤ %.2f):        %4d   (%.1f%%)                               ║",
                 args.threshold, hits.count, hitRate))
    print(String(format: "║  Misses:               %4d                                          ║", misses.count))
    print(String(format: "║  Best dist (min):      %.4f                                        ║", dists.first ?? 0))
    print(String(format: "║  Dist p5/p50/p95:      %.3f / %.3f / %.3f                        ║", p5, p50, p95))
    print(  "╠══════════════════════════════════════════════════════════════════════╣")
    print(  "║  THRESHOLD ADVICE                                                    ║")
    print(  "╠══════════════════════════════════════════════════════════════════════╣")
    print(String(format: "║  Confident hits (< 0.40):    %3d                                    ║", hitBelow40))
    print(String(format: "║  Borderline hits (0.40–%.2f): %3d                                    ║",
                 args.threshold, hitAbove40))
    print(String(format: "║  Near-misses (thresh+0.05):  %3d  (gain by loosening threshold)     ║", nearMisses))
    if dists.first ?? 1 > args.threshold {
        print("║  ⚠  No face came within threshold — target may not appear here.     ║")
    } else if hitRate > 50 {
        print("║  ⚠  >50% of all faces matched — threshold is too loose.            ║")
    } else if hitAbove40 > hitBelow40 {
        print("║  ⚠  Most hits are borderline — consider tightening to ~0.42.       ║")
    } else {
        print("║  ✓  Hit distribution looks reasonable.                              ║")
    }
    print(  "╚══════════════════════════════════════════════════════════════════════╝\n")
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Entry point — fully synchronous
// ─────────────────────────────────────────────────────────────────────────────

let args = parseArgs()

print("FaceDiagnose")
print("  References: \(args.refPath)")
print("  Video path: \(args.videoPath)")
print("  threshold=\(args.threshold)  frame-step=\(args.frameStep)  min-conf=\(args.minConf)\n")

let refs = loadReferences(from: args.refPath)
guard !refs.isEmpty else {
    fputs("Error: no reference faces loaded from \(args.refPath)\n", stderr); exit(1)
}
print("Loaded \(refs.count) reference face(s)")
printRefTable(refs)

let videos = findVideos(at: args.videoPath)
guard !videos.isEmpty else {
    fputs("Error: no video files found at \(args.videoPath)\n", stderr); exit(1)
}
print("\nFound \(videos.count) video(s) to analyze:")

var allFaces: [FrameFace] = []
for v in videos {
    let faces = analyzeVideo(path: v, refs: refs, args: args)
    allFaces.append(contentsOf: faces)
}

printFrameLog(allFaces, refs: refs, args: args)
printSummary(allFaces, refs: refs, args: args)
