import Foundation
import os

// MARK: - PerceptualFingerprinter
//
// The RUNNER half of the perceptual compare tier (planner/runner split
// — the pure math lives in PerceptualHash.swift). One ffmpeg pass per
// file decodes 32 frames at evenly spaced interior positions straight
// down to 9×8 grayscale thumbnails; each becomes one 64-bit dHash.
//
// Sampling design:
//   - Skip the first and last 5% of the duration (-ss/-t input trim)
//     — home-video captures routinely open/close on black leader or
//     bars, which hash identically across UNRELATED tapes and would
//     poison the statistics.
//   - Inside the trimmed span, the `fps` filter at rate 32/span emits
//     one frame per 1/32nd of the span — both files of a pair are
//     sampled at the SAME normalized positions, which is what makes
//     index-aligned comparison meaningful.
//   - `scale=9:8:flags=area` then `format=gray`: area averaging is the
//     right downsample for "what's the average brightness of this
//     region" — exactly the question dHash asks.
//
// Cost note (accepted for v1): `fps` decodes every frame in the
// trimmed span, so a long file pays roughly one full decode at
// thumbnail scale. This tier only runs after Tiers 0–2 already read
// both files end-to-end, so it roughly doubles a compare's runtime
// rather than exploding it. 32 individual `-ss` seeks would be faster
// on long files but mean 32 process launches and keyframe-snap
// misalignment between differently-encoded copies — one pass is the
// reliable choice.
//
// Output transport: ffmpeg writes the raw frames to a TEMP FILE, not
// pipe:1 — ProcessRunner (the project's cancellation-aware Process
// wrapper, which SIGTERMs the child when the task is cancelled)
// captures stdout as UTF-8 text, which would mangle raw video bytes.
// The file is at most 32 × 72 = 2,304 bytes and is deleted on every
// exit path. Memory footprint: that same ≤ 2.3 KB read once, plus a
// 256-byte fingerprint. Nothing here scales with media size.

private let fingerprintLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                    category: "fileOps")

// MARK: - Errors

enum PerceptualFingerprintError: LocalizedError {
    /// The catalog has no usable duration for this file — without it we
    /// can't compute the sampling rate, so the tier can't run.
    case unknownDuration(String)
    /// ffmpeg exited nonzero (corrupt/undecodable video, e.g. the Avid
    /// RGBA MXFs ffprobe also chokes on).
    case ffmpegFailed(file: String, detail: String)
    /// Decoded fewer than the minimum frames — file too short or decode
    /// fell apart mid-stream. Below 10 frames the statistics in
    /// PerceptualHash are too thin to support any claim.
    case tooFewFrames(file: String, got: Int)

    var errorDescription: String? {
        switch self {
        case .unknownDuration(let path):
            let name = (path as NSString).lastPathComponent
            return "Couldn't run the visual check on \"\(name)\" — no known duration."
        case .ffmpegFailed(let file, let detail):
            let name = (file as NSString).lastPathComponent
            return "Couldn't decode frames from \"\(name)\" for the visual check."
                + (detail.isEmpty ? "" : " (\(detail))")
        case .tooFewFrames(let file, let got):
            let name = (file as NSString).lastPathComponent
            return "\"\(name)\" yielded only \(got) comparable frames — too few for a visual verdict."
        }
    }
}

// MARK: - Fingerprinter

enum PerceptualFingerprinter {

    /// Frames sampled per file. 32 × the per-frame coincidence
    /// probability (~3.9e-5) gives astronomically strong evidence when
    /// most frames agree — see the model in PerceptualHash.swift.
    static let frameCount = 32
    /// Require at least this many decoded frames to proceed — defined
    /// AS the verdict gate so the two can't silently drift apart
    /// (short clips still work, 2-second stingers don't pretend to).
    static let minimumFrames = PerceptualHash.minFramesForVerdict
    /// Fraction of the duration trimmed off EACH end before sampling.
    static let trimFraction = 0.05

    // MARK: Pure argv construction (unit-tested — PerceptualFingerprinterTests)

    /// Build the exact ffmpeg argv for one file's fingerprint pass.
    /// PURE — no filesystem checks, fully deterministic for tests
    /// (same pattern as CombineEngine's arg builders).
    ///
    /// `-ss` BEFORE `-i` is input seeking (fast keyframe seek, then
    /// the fps filter re-times from 0 within the trimmed span);
    /// `-an -sn -dn` drop audio/subtitle/data so only video decodes;
    /// `-progress pipe:2` feeds the job's progress bar via stderr.
    static func buildArgs(inputPath: String,
                          durationSeconds: Double,
                          frameCount: Int,
                          outputPath: String) -> [String] {
        let start = durationSeconds * trimFraction
        // max() guard: a pathological sub-millisecond duration must not
        // produce span 0 → fps division by zero.
        let span = max(durationSeconds * (1 - 2 * trimFraction), 0.001)
        let fps = Double(frameCount) / span
        return [
            "-nostdin", "-nostats",
            "-v", "error",
            "-progress", "pipe:2",
            "-ss", String(format: "%.3f", start),
            "-t", String(format: "%.3f", span),
            "-i", inputPath,
            "-an", "-sn", "-dn",
            "-vf", String(format: "fps=%.6f,scale=%d:%d:flags=area,format=gray",
                          fps, PerceptualHash.grayWidth, PerceptualHash.grayHeight),
            "-frames:v", String(frameCount),
            "-f", "rawvideo",
            "-y", outputPath
        ]
    }

    /// The trimmed span in seconds — the denominator for progress
    /// reporting (ffmpeg's out_time runs over the trimmed range).
    static func sampledSpan(durationSeconds: Double) -> Double {
        max(durationSeconds * (1 - 2 * trimFraction), 0.001)
    }

    // MARK: Extraction

    /// Decode up to 32 thumbnails from `path` and return their dHashes.
    /// Throws PerceptualFingerprintError; cancellation propagates via
    /// ProcessRunner (child ffmpeg is terminated) + checkCancellation.
    ///
    /// `@concurrent`: same reasoning as MediaPairComparator's helpers —
    /// under Approachable Concurrency a plain nonisolated async func
    /// would run on the CALLER's (main) actor; this pins the decode
    /// wait and byte-shuffling to the global pool.
    // #if guard: the nightly CI's Xcode 16.4 (Swift 6.1) knows
    // `@concurrent` only as a deprecated alias of `@Sendable` and warns;
    // pre-6.2 a nonisolated async already runs off-actor.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func fingerprint(
        ffmpegPath: String,
        path: String,
        durationSeconds: Double,
        onFraction: @escaping @Sendable (Double) -> Void
    ) async throws -> [UInt64] {
        guard durationSeconds > 0 else {
            throw PerceptualFingerprintError.unknownDuration(path)
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs-phash-\(UUID().uuidString).gray")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let span = sampledSpan(durationSeconds: durationSeconds)
        let args = buildArgs(inputPath: path,
                             durationSeconds: durationSeconds,
                             frameCount: frameCount,
                             outputPath: tempURL.path)

        fingerprintLog.info("perceptual fingerprint start: \(path, privacy: .public)")
        let result = await ProcessRunner.runProcess(
            executable: ffmpegPath,
            arguments: args,
            stderrLine: { line in
                // Same -progress parsing as the streamhash tier.
                guard line.hasPrefix("out_time_us="),
                      let micros = Double(line.dropFirst("out_time_us=".count))
                else { return }
                onFraction((micros / 1_000_000) / span)
            }
        )
        try Task.checkCancellation()
        guard result.exitCode == 0 else {
            // Last non-progress stderr line is usually ffmpeg's actual
            // complaint (ProcessRunner already caps stderr capture).
            // Exclude only `key=value` progress lines (frame=, speed=…)
            // — real error messages often contain '=' mid-sentence and
            // must survive this filter.
            let tail = result.stderr
                .split(separator: "\n")
                .last(where: { line in
                    guard let eq = line.firstIndex(of: "=") else { return true }
                    let key = line[line.startIndex..<eq]
                    return key.isEmpty || !key.allSatisfy { $0.isLetter || $0 == "_" }
                })
                .map(String.init) ?? ""
            throw PerceptualFingerprintError.ffmpegFailed(file: path, detail: tail)
        }

        guard let raw = try? Data(contentsOf: tempURL) else {
            throw PerceptualFingerprintError.ffmpegFailed(
                file: path, detail: "no frame output produced")
        }
        let bytesPerFrame = PerceptualHash.grayByteCount
        let frames = raw.count / bytesPerFrame
        guard frames >= minimumFrames else {
            throw PerceptualFingerprintError.tooFewFrames(file: path, got: frames)
        }

        var fingerprint: [UInt64] = []
        fingerprint.reserveCapacity(min(frames, frameCount))
        for i in 0..<min(frames, frameCount) {
            let slice = Array(raw[(i * bytesPerFrame)..<((i + 1) * bytesPerFrame)])
            fingerprint.append(PerceptualHash.dHash64(gray9x8: slice))
        }
        fingerprintLog.info("perceptual fingerprint done: \(frames) frames from \(path, privacy: .public)")
        return fingerprint
    }
}
