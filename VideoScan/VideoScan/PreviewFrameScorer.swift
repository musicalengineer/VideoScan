// PreviewFrameScorer.swift
// Phase B piece 1, commit 2 (2026-07-26): content-aware "best frame"
// selection for cached previews.
//
// Why: VHS captures routinely open with ~1 minute of solid blue (or
// black leader, or analog static) — the interactive t=0.5s frame is a
// useless preview for those. The background pass rips a few candidate
// frames across the file, scores each for visual content, and caches
// the best at the disk cache's "best" tier.
//
// Two PURE pieces, both trivially unit-testable with synthetic images:
//   - PreviewFrameScorer — score one CGImage for "is there a picture
//     here": luma standard deviation × color-dominance penalty over a
//     64×64 downsample.
//   - PreviewBestFramePlan — candidate offsets from the CATALOG
//     duration (never ffprobe at preview time), the 25% fallback rule,
//     and the pick-the-winner decision.
// The I/O side (actually ripping candidates) lives in
// VideoScanModel+Thumbnail.swift with the other frame generators.
//
// Why downsample FIRST: drawing into 64×64 with interpolation is an
// area-averaging low-pass filter. Analog static — high per-pixel
// variance but no structure — averages toward uniform mid-gray, so it
// scores near-solid LOW just like blue leader and black, while real
// scenes keep their large-scale luma structure. That's the whole trick;
// scoring at full resolution would rank static as "detailed".
//
// Memory: one 64×64 RGBA buffer (16 KB) + a 4096-int histogram (32 KB)
// per call, released on return.

import Foundation
import CoreGraphics

// MARK: - Scorer (pure)

enum PreviewFrameScorer {

    /// Downsample edge. 64×64 = 4096 samples — plenty for a solid-vs-
    /// scene verdict, small enough to score in well under a millisecond.
    static let sampleDimension = 64

    /// `combined` scores at or below this are "near-solid" (blue/black
    /// leader, averaged-out static). Calibration: a solid frame scores
    /// ~0.0003 (stddev ≈ 2, dominance ≈ 0.98); a murky low-contrast VHS
    /// scene still clears ~0.08 (stddev ≈ 15, dominance ≈ 0.3). An
    /// order of magnitude of headroom on both sides.
    static let nearSolidThreshold: Double = 0.01

    /// Component scores for one frame. Kept separate (not just the
    /// combined Double) so tests can pin each signal independently.
    struct FrameScore: Equatable {
        /// Standard deviation of Rec. 601 luma over the downsample,
        /// 0…~127. Near 0 for any solid color.
        let lumaStdDev: Double
        /// Fraction of samples falling in the modal color bucket
        /// (RGB quantized to 16 levels/channel — a "tight band" of 16
        /// values per component). Near 1 for solid frames.
        let dominantColorFraction: Double

        /// Contrast gated by color diversity: a frame must have BOTH
        /// luma structure and more than one color to score high.
        /// Multiplicative so a textured-but-monochrome leader can't
        /// sneak past on stddev alone.
        var combined: Double {
            min(lumaStdDev / 128.0, 1.0) * (1.0 - dominantColorFraction)
        }
    }

    /// Score one frame. Pure math over a private bitmap — no I/O, no
    /// caches, safe from any executor. Returns nil only if CoreGraphics
    /// can't rasterize the image (callers treat nil as score 0).
    static func score(_ image: CGImage) -> FrameScore? {
        let dim = sampleDimension
        guard let ctx = CGContext(data: nil, width: dim, height: dim,
                                  bitsPerComponent: 8, bytesPerRow: dim * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        // .medium interpolation = the area-averaging low-pass described
        // in the file header. Do not switch to .none — nearest-neighbor
        // sampling would let analog static keep its variance and defeat
        // the near-solid detection.
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: dim, height: dim))
        guard let buffer = ctx.data else { return nil }
        let px = buffer.bindMemory(to: UInt8.self, capacity: dim * dim * 4)

        let count = dim * dim
        var sum = 0.0
        var sumSquares = 0.0
        // 16 levels per channel → 4096 buckets. Indexed r'<<8|g'<<4|b'.
        var buckets = [Int](repeating: 0, count: 16 * 16 * 16)

        for i in 0..<count {
            let r = px[i * 4], g = px[i * 4 + 1], b = px[i * 4 + 2]
            // Rec. 601 luma — same weights the codebase's other
            // brightness math uses; exactness is irrelevant here.
            let luma = 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)
            sum += luma
            sumSquares += luma * luma
            buckets[(Int(r) >> 4) << 8 | (Int(g) >> 4) << 4 | (Int(b) >> 4)] += 1
        }

        let mean = sum / Double(count)
        // E[x²] − E[x]² — clamped at 0 against float round-off.
        let variance = max(0, sumSquares / Double(count) - mean * mean)
        return FrameScore(
            lumaStdDev: variance.squareRoot(),
            dominantColorFraction: Double(buckets.max() ?? count) / Double(count)
        )
    }
}

// MARK: - Candidate plan (pure)

enum PreviewBestFramePlan {

    /// Hard bound on candidate rips per file (scale dimension of the
    /// feature-test checklist): the offset builder can never emit more.
    static let maxCandidates = 4

    /// Below this duration the multi-candidate pass degenerates to the
    /// plain single-frame path — a 2 s clip has no meaningful "lead-in"
    /// and its percentage offsets all collapse near t=0.5 anyway.
    static let minDurationForCandidates: Double = 2.0

    /// Candidate rip offsets (seconds): the interactive anchor at 0.5 s
    /// plus 10% / 25% / 50% of the CATALOG duration — the duration is
    /// ffprobe-stamped at scan time; preview time never probes.
    /// Deduped to 0.1 s granularity (short files collapse offsets),
    /// order preserved, count ≤ `maxCandidates`. Unknown/zero duration
    /// → just [0.5].
    static func candidateOffsets(durationSeconds: Double) -> [Double] {
        guard durationSeconds >= minDurationForCandidates else { return [0.5] }
        let raw = [0.5,
                   0.10 * durationSeconds,
                   0.25 * durationSeconds,
                   0.50 * durationSeconds]
        var seen = Set<Int>()
        var offsets: [Double] = []
        for offset in raw {
            // Dedupe key: offset in deciseconds.
            if seen.insert(Int((offset * 10).rounded())).inserted {
                offsets.append(offset)
            }
        }
        return offsets
    }

    /// The keep-anyway frame when every candidate scores near-solid:
    /// 25% in — far enough past any lead-in, early enough to still be
    /// "the start of the tape" for identification purposes.
    static func fallbackOffset(durationSeconds: Double) -> Double {
        durationSeconds >= minDurationForCandidates ? 0.25 * durationSeconds : 0.5
    }

    /// Pick the winning candidate. `scores` and `offsets` are parallel
    /// arrays for the candidates that actually decoded (failed rips are
    /// simply absent). Returns the index of:
    ///   - the highest score, if it clears `threshold`;
    ///   - otherwise the candidate at `fallbackOffset` (±0.5 s — CMTime
    ///     tick rounding means ripped offsets aren't bit-exact) — a
    ///     decodable file NEVER falls through to "no preview" just
    ///     because it's wall-to-wall blue;
    ///   - otherwise the highest score anyway.
    /// nil only for zero candidates.
    static func chooseIndex(scores: [Double],
                            offsets: [Double],
                            fallbackOffset: Double,
                            threshold: Double) -> Int? {
        guard !scores.isEmpty, scores.count == offsets.count else { return nil }
        let bestIndex = scores.indices.max(by: { scores[$0] < scores[$1] })!
        if scores[bestIndex] > threshold { return bestIndex }
        if let fallbackIndex = offsets.firstIndex(where: { abs($0 - fallbackOffset) < 0.5 }) {
            return fallbackIndex
        }
        return bestIndex
    }
}
