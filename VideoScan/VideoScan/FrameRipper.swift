import Foundation
import AVFoundation
import Vision
import CoreImage
import AppKit
import Combine
import os

// MARK: - FrameRipper
//
// "Convert to images…" — extract the best portrait-worthy frames from
// a video as lossless PNGs, ranked by Apple's own face-quality model.
//
// Rick 2026-06-09: "I'd like to give Donna a printable Renoir-style
// portrait for her Aug 4 birthday. Can VS pull the best frames from
// her old videos so I don't have to scrub manually?" Yes.
//
// Pipeline:
//   1. Sample candidate frames at a fixed time interval across the
//      asset (default every 2 s). Coarse-enough not to thrash the
//      generator, fine-enough that we don't miss a good expression.
//   2. Score each candidate via Vision:
//        VNDetectFaceCaptureQualityRequest — Apple's own model trained
//        for "is this face suitable for a portrait?" It bakes in
//        lighting, sharpness, pose, expression. We multiply by
//        sqrt(face_area / image_area) so a tiny crisp face doesn't
//        beat a large warm one.
//   3. Sort by score, keep the top N (default 30).
//   4. Export each as a lossless PNG at native resolution — no
//      max-size, no JPEG, no temporal interpolation. Highest possible
//      quality straight from the decoded frame.
//
// Future hooks (deliberately deferred for v1):
//   - Per-person matching via existing PersonFinder reference embeddings,
//     so "just Donna" / "just Matt" partitioning works.
//   - Configurable interval / count from the sheet UI.
//   - Scene-change detector as an alternative sampling strategy.

private let frameRipperLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                    category: "frame-ripper")

@MainActor
final class FrameRipper: ObservableObject {

    // MARK: - Published state (drives the operations-window row via
    // ExtractFramesJob's change forwarding)

    /// True while a rip is in flight. UI binds to this for spinner +
    /// cancel button enabled state.
    @Published var isRunning = false

    /// Short human-readable phase label ("Sampling 12 of 60…",
    /// "Saving 7 of 30…", "Done"). Shown directly in the sheet.
    @Published var statusText = ""

    /// Number of candidate frames decoded so far. Sheet shows as
    /// "scanned: N" during sampling.
    @Published var framesScanned = 0

    /// Number of best-of-the-best frames saved as PNG. Sheet shows as
    /// "saved: N / target" during the save phase.
    @Published var framesSaved = 0

    /// Total candidate count at start of sampling (set after duration
    /// is known). UI uses this for the progress fraction.
    @Published var candidateTarget = 0

    /// Number of frames the rip will ultimately save (defaults to 30).
    /// Captured at start of rip so the UI's "of N" doesn't change
    /// mid-run if defaults are tuned.
    @Published var saveTarget = 0

    /// Last non-recoverable error message, or nil. Shown in the sheet
    /// when present.
    @Published var lastError: String?

    /// Destination folder when the rip completes successfully. UI uses
    /// it to enable a "Reveal in Finder" affordance.
    @Published var completedDestination: URL?

    /// True only between user-pressed Cancel and the loop noticing.
    /// Drives the cancel-button label ("Cancelling…").
    @Published var isCancelling = false

    // MARK: - Options
    //
    // Rick's v1 spec: "always use the very best options to generate the
    // highest quality." So defaults are aggressive. Tuneable later if
    // the sheet grows controls.

    struct Options {
        /// How often to sample a candidate frame, in seconds.
        /// 2.0 ≈ 30 candidates per minute of source video.
        var sampleIntervalSeconds: Double = 2.0
        /// Cap on number of saved frames. 30 = manageable for hand-pick;
        /// covers Rick's "25-50" target range.
        var maxOutputFrames: Int = 30
        /// Below this combined score, a candidate doesn't even count
        /// as a "face frame." Drops blurry / no-face samples cheaply.
        var minScore: Double = 0.05
    }

    // MARK: - Entry point

    /// Run a rip inline in the caller's task. Phase 2 of the Media
    /// File Operations window: `ExtractFramesJob` owns the run Task
    /// (so the rip survives window close) and awaits this to know when
    /// to release its volume gates. Cancellation arrives via the
    /// caller's Task being cancelled — the sampling and saving loops
    /// below check `Task.isCancelled` once per frame, so cancel lands
    /// within one decode. Frames already written stay on disk.
    ///
    /// (Replaces the sheet-era fire-and-forget `rip()` + internal
    /// `currentTask` + `cancel()` trio, retired with FrameRipperSheet.)
    func run(videoURL: URL, intoParent parentDir: URL, options: Options = Options()) async {
        isRunning = true
        isCancelling = false
        statusText = "Preparing…"
        framesScanned = 0
        framesSaved = 0
        candidateTarget = 0
        saveTarget = options.maxOutputFrames
        lastError = nil
        completedDestination = nil

        await runRip(videoURL: videoURL, parentDir: parentDir, options: options)
    }

    private func runRip(videoURL: URL, parentDir: URL, options: Options) async {
        // AVURLAsset is the modern replacement for AVAsset(url:) per the
        // macOS 15 deprecation. Same semantics for our read-only use.
        let asset = AVURLAsset(url: videoURL)

        // Build output dir: <parent>/<videoStem>-frames/
        let stem = videoURL.deletingPathExtension().lastPathComponent
        let destDir = parentDir.appendingPathComponent("\(stem)-frames",
                                                       isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destDir,
                                                    withIntermediateDirectories: true)
        } catch {
            await finish(error: "Couldn't create folder: \(error.localizedDescription)")
            return
        }

        // Probe duration.
        let durationSeconds: Double
        do {
            let cmDur = try await asset.load(.duration)
            durationSeconds = CMTimeGetSeconds(cmDur)
        } catch {
            await finish(error: "Couldn't read video: \(error.localizedDescription)")
            return
        }
        guard durationSeconds.isFinite, durationSeconds > 0.1 else {
            await finish(error: "Zero-duration video.")
            return
        }

        // Build candidate timestamps.
        let nCandidates = max(1, Int(durationSeconds / options.sampleIntervalSeconds))
        await MainActor.run {
            self.candidateTarget = nCandidates
            self.statusText = "Scanning \(nCandidates) candidate frames…"
        }

        // Image generator — configured for native-resolution exact frames.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true     // rotation honored
        generator.requestedTimeToleranceBefore = .zero      // exact frame
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = .zero                        // native res, no downscale

        // Collect (timestamp, image, score) for every candidate.
        var candidates: [Candidate] = []
        candidates.reserveCapacity(nCandidates)

        for i in 0..<nCandidates {
            if Task.isCancelled { break }
            let t = Double(i) * options.sampleIntervalSeconds
            let cmTime = CMTime(seconds: t, preferredTimescale: 600)

            do {
                // iOS 16+ / macOS 13+ async API. Returns the closest
                // I-frame within the tolerance we set (zero).
                let result = try await generator.image(at: cmTime)
                let cgImage = result.image
                let score = await Self.scoreFace(in: cgImage, log: frameRipperLog)
                if score >= options.minScore {
                    candidates.append(Candidate(timestamp: t,
                                                image: cgImage,
                                                score: score))
                }
            } catch {
                // Decode failure on a single frame is common (codec
                // edge cases on legacy media) — skip and continue.
                frameRipperLog.notice("frame at t=\(t)s skipped: \(error.localizedDescription, privacy: .public)")
            }

            await MainActor.run {
                self.framesScanned = i + 1
                self.statusText = "Scanning \(i + 1) of \(nCandidates) — \(candidates.count) face frame(s) so far"
            }
        }

        if Task.isCancelled {
            await finish(error: nil, cancelled: true)
            return
        }

        // Rank by score descending; take top N.
        candidates.sort { $0.score > $1.score }
        let kept = Array(candidates.prefix(options.maxOutputFrames))

        if kept.isEmpty {
            await finish(error: "No face-containing frames found. Try a different video.")
            return
        }

        await MainActor.run {
            self.statusText = "Saving \(kept.count) best frames…"
        }

        // Save each as PNG.
        var savedCount = 0
        for (rank, cand) in kept.enumerated() {
            if Task.isCancelled { break }
            let filename = Self.makeFilename(rank: rank + 1,
                                             timestamp: cand.timestamp,
                                             score: cand.score)
            let fileURL = destDir.appendingPathComponent(filename)
            if Self.writePNG(image: cand.image, to: fileURL) {
                savedCount += 1
            }
            await MainActor.run {
                self.framesSaved = savedCount
                self.statusText = "Saving \(savedCount) of \(kept.count)…"
            }
        }

        if Task.isCancelled {
            await finish(error: nil, cancelled: true, destination: destDir)
            return
        }

        await finish(error: nil, destination: destDir, savedCount: savedCount)
    }

    // MARK: - Finish helpers

    @MainActor
    private func finish(error: String?,
                        cancelled: Bool = false,
                        destination: URL? = nil,
                        savedCount: Int? = nil) {
        self.isRunning = false
        self.isCancelling = false
        if let error {
            self.statusText = "Error"
            self.lastError = error
        } else if cancelled {
            self.statusText = "Cancelled"
        } else {
            self.statusText = "Done — saved \(savedCount ?? framesSaved) frame(s)"
            self.completedDestination = destination
        }
        if let destination {
            self.completedDestination = destination
        }
    }

    // MARK: - Vision scoring (static so tests can drive it directly)

    /// Score a CGImage for "best portrait frame" suitability. Returns
    /// a 0…1+ value where higher is better. Zero means no usable face
    /// detected.
    ///
    /// The score combines:
    ///   - Apple's VNDetectFaceCaptureQualityRequest — a model
    ///     specifically trained to rate face frames for portrait use
    ///     (lighting, sharpness, pose, expression).
    ///   - The square root of the face's fractional area, so a large
    ///     warm face slightly outranks a small crisp one. sqrt() not
    ///     linear because faceCaptureQuality already saturates near 1
    ///     and we don't want size to completely dominate.
    ///
    /// When multiple faces are present (group shot), we take the
    /// highest single-face score. Could change later to a weighted sum
    /// or pick the largest.
    nonisolated static func scoreFace(in cgImage: CGImage,
                                      log: Logger? = nil) async -> Double {
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNDetectFaceCaptureQualityRequest()
        do {
            try handler.perform([request])
        } catch {
            log?.notice("Vision face-capture request failed: \(error.localizedDescription, privacy: .public)")
            return 0
        }
        guard let observations = request.results, !observations.isEmpty else {
            return 0
        }
        var best: Double = 0
        for face in observations {
            // boundingBox is normalised 0…1 in Vision's coordinate
            // system. Multiply width * height → fractional image area.
            let areaRatio = Double(face.boundingBox.width * face.boundingBox.height)
            // captureQuality is Float? — nil means Vision couldn't
            // assess (very low-res or unusual aspect). Treat as 0.
            let q = Double(face.faceCaptureQuality ?? 0)
            // Combined score. sqrt(areaRatio) keeps small but crisp
            // faces competitive while letting size break ties.
            let score = q * max(0.001, areaRatio.squareRoot())
            if score > best { best = score }
        }
        return best
    }

    // MARK: - File output

    /// Sortable filename: rank | timestamp | quality.
    /// E.g. "frame_07_t01m42s_q87.png" — rank 7, 1m42s into video, q=0.87.
    nonisolated static func makeFilename(rank: Int,
                                         timestamp: TimeInterval,
                                         score: Double) -> String {
        let s = max(0, Int(timestamp))
        let m = s / 60
        let sec = s % 60
        let q = Int(min(99, max(0, score * 100)))
        return String(format: "frame_%02d_t%02dm%02ds_q%02d.png", rank, m, sec, q)
    }

    /// Write a CGImage as a lossless PNG at native resolution.
    /// Returns true on success.
    nonisolated static func writePNG(image: CGImage, to url: URL) -> Bool {
        let utType = "public.png" as CFString
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                         utType, 1, nil) else {
            return false
        }
        // No compression options — PNG is already lossless. Default
        // compression filter set by CG is fine for portraits.
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    // MARK: - Candidate type

    /// A single sampled frame, decoded image + its computed score.
    /// Internal — never escapes the rip loop except via the saved PNGs.
    private struct Candidate {
        let timestamp: TimeInterval
        let image: CGImage
        let score: Double
    }
}
