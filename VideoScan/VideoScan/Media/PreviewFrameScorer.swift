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
//     here": luma standard deviation × color-dominance penalty ×
//     squared structure retention, over a 64×64 downsample.
//   - PreviewBestFramePlan — candidate offsets from the CATALOG
//     duration (never ffprobe at preview time), the 25% fallback rule,
//     and the pick-the-winner decision.
// The I/O side (actually ripping candidates) lives in
// VideoScanModel+Thumbnail.swift with the other frame generators.
//
// How static is told apart from scenes (calibrated 2026-07-26 after the
// testing agent FALSIFIED the first design's claim — see the measured
// table below): a TWO-SCALE variance ratio. The 64×64 area-averaging
// draw attenuates noise variance hard (per-pixel stddev ~74 → ~8–16)
// but not to zero, and averaged noise straddles several color buckets,
// so neither the stddev term nor the dominance gate alone closes on
// static. What DOES separate them: averaging the 64×64 luma again down
// to 8×8 block means. Noise loses variance under every further
// averaging (÷√64 across an 8×8 block); large-scale structure — scenes,
// murky VHS, smooth gradients — survives it almost untouched. The
// ratio stddev(8×8)/stddev(64×64) is therefore ~1 for content (measured
// 0.97–1.0) and collapses to ~0.11–0.14 for static (theory: 1/8), and
// its SQUARE multiplies into `combined` — squaring costs content <2%
// but buys static another ×8, which is what puts 320×240 static (the
// worst case: least pre-averaging in the 64×64 draw, so the highest
// base score) safely under the threshold. Scoring at full resolution
// would still rank static as "detailed"; the first downsample is still
// load-bearing.
//
// Memory: one 64×64 RGBA buffer (16 KB) + a 4 KB luma plane + a
// 4096-int histogram (32 KB) per call, released on return.

import Foundation
import CoreGraphics

// MARK: - Scorer (pure)

enum PreviewFrameScorer {

    /// Downsample edge. 64×64 = 4096 samples — plenty for a solid-vs-
    /// scene verdict, small enough to score in well under a millisecond.
    static let sampleDimension = 64

    /// Second-scale edge for the structure-retention ratio: the 64×64
    /// luma plane is block-averaged down to 8×8. Must divide
    /// `sampleDimension`.
    static let coarseDimension = 8

    /// `combined` scores at or below this are "near-solid" (blue/black
    /// leader, or analog static). Calibration — MEASURED on the test
    /// fixtures (PreviewTestImageSupport, seeds 7/42/99), 2026-07-26,
    /// sizes 320×240 → 1920×1080:
    ///
    ///     solid blue / solid black        0.000    (all sizes)
    ///     grayscale static                0.0002–0.0013
    ///     RGB static                      0.0002–0.0017  (worst 320×240)
    ///     two-tone scene                  0.260
    ///     smooth gradient                 0.373
    ///
    /// ≥6× headroom below the threshold for the worst static case,
    /// 26× above it for the weakest scene. Static is size-dependent
    /// (smaller sources get less pre-averaging in the 64×64 draw);
    /// scenes are size-invariant.
    static let nearSolidThreshold: Double = 0.01

    /// Component scores for one frame. Kept separate (not just the
    /// combined Double) so tests can pin each signal independently.
    struct FrameScore: Equatable {
        /// Standard deviation of Rec. 601 luma over the 64×64
        /// downsample, 0…~127. Near 0 for any solid color.
        let lumaStdDev: Double
        /// Fraction of samples falling in the modal color bucket
        /// (RGB quantized to 16 levels/channel — a "tight band" of 16
        /// values per component). Near 1 for solid frames.
        let dominantColorFraction: Double
        /// stddev(8×8 block means) / stddev(64×64), clamped to [0, 1].
        /// ~1 when the luma structure is large-scale (real scenes,
        /// gradients — further averaging barely touches it); collapses
        /// toward ~0.1 for noise, which loses ~√(blockArea) of its
        /// stddev under every additional averaging. This is the gate
        /// that actually closes on analog static — the 2026-07-26
        /// recalibration after the single-scale design was falsified.
        let structureRetention: Double

        /// Contrast, gated by color diversity AND scale persistence: a
        /// frame must have luma structure, more than one color, and
        /// structure that survives coarser averaging to score high.
        /// Multiplicative so no single signal can carry a leader frame
        /// past the threshold. Retention enters SQUARED — see the file
        /// header for the measured margins behind that choice.
        var combined: Double {
            min(lumaStdDev / 128.0, 1.0)
                * (1.0 - dominantColorFraction)
                * structureRetention * structureRetention
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
        var luma = [Double](repeating: 0, count: count)
        var sum = 0.0
        var sumSquares = 0.0
        // 16 levels per channel → 4096 buckets. Indexed r'<<8|g'<<4|b'.
        var buckets = [Int](repeating: 0, count: 16 * 16 * 16)

        for i in 0..<count {
            let r = px[i * 4], g = px[i * 4 + 1], b = px[i * 4 + 2]
            // Rec. 601 luma — same weights the codebase's other
            // brightness math uses; exactness is irrelevant here.
            let y = 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)
            luma[i] = y
            sum += y
            sumSquares += y * y
            buckets[(Int(r) >> 4) << 8 | (Int(g) >> 4) << 4 | (Int(b) >> 4)] += 1
        }

        let mean = sum / Double(count)
        // E[x²] − E[x]² — clamped at 0 against float round-off.
        let variance = max(0, sumSquares / Double(count) - mean * mean)
        let stdDevFine = variance.squareRoot()

        // Second scale: 8×8 block means of the luma plane (plain
        // arithmetic — no second CG draw, so the two scales can't
        // diverge on interpolation behavior). Noise collapses here;
        // structure doesn't. See the file header.
        let coarse = coarseDimension
        let block = dim / coarse
        let blockArea = Double(block * block)
        var coarseSum = 0.0
        var coarseSumSquares = 0.0
        for by in 0..<coarse {
            for bx in 0..<coarse {
                var s = 0.0
                for y in 0..<block {
                    let row = (by * block + y) * dim + bx * block
                    for x in 0..<block { s += luma[row + x] }
                }
                let m = s / blockArea
                coarseSum += m
                coarseSumSquares += m * m
            }
        }
        let coarseCount = Double(coarse * coarse)
        let coarseMean = coarseSum / coarseCount
        let coarseVariance = max(0, coarseSumSquares / coarseCount - coarseMean * coarseMean)
        // Epsilon floor so a solid frame (both stddevs ~0) doesn't
        // divide by zero; its combined is already zeroed by the
        // stddev term, so the retention value there is inert.
        let retention = min(1.0, coarseVariance.squareRoot() / max(stdDevFine, 1e-6))

        return FrameScore(
            lumaStdDev: stdDevFine,
            dominantColorFraction: Double(buckets.max() ?? count) / Double(count),
            structureRetention: retention
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

    /// Upper sanity bound on a plannable duration (~115 days). Catalog
    /// durations beyond this are garbage metadata, and the planner must
    /// never trust them: `Int((offset * 10).rounded())` in the dedupe
    /// TRAPS on non-finite doubles and on finite values past ~1.8e18 —
    /// a poisoned record would crash the whole prewarm (testing agent
    /// 🔴, 2026-07-26, SIGTRAP verified). Out-of-range → plain [0.5].
    /// Value lives in VideoScanCore (`previewMaxSaneDurationSeconds`) so
    /// the app plan and the disk cache's strip-offset ceiling share ONE
    /// source of truth.
    static let maxSaneDurationSeconds: Double = previewMaxSaneDurationSeconds

    /// True when the catalog duration is usable for candidate planning:
    /// finite and within [min, max]. NaN fails every comparison by IEEE
    /// rules, so it lands here too. One shared predicate so
    /// candidateOffsets and fallbackOffset can't drift apart.
    private static func isPlannable(_ durationSeconds: Double) -> Bool {
        durationSeconds.isFinite
            && durationSeconds >= minDurationForCandidates
            && durationSeconds <= maxSaneDurationSeconds
    }

    /// Candidate rip offsets (seconds): the interactive anchor at 0.5 s
    /// plus 10% / 25% / 50% of the CATALOG duration — the duration is
    /// ffprobe-stamped at scan time; preview time never probes.
    /// Deduped to 0.1 s granularity (short files collapse offsets),
    /// order preserved, count ≤ `maxCandidates`. Unknown/zero/garbage
    /// duration (non-finite or absurd — see maxSaneDurationSeconds)
    /// → just [0.5].
    static func candidateOffsets(durationSeconds: Double) -> [Double] {
        guard isPlannable(durationSeconds) else { return [0.5] }
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
    /// "the start of the tape" for identification purposes. Same
    /// garbage-duration hardening as candidateOffsets (→ 0.5).
    static func fallbackOffset(durationSeconds: Double) -> Double {
        isPlannable(durationSeconds) ? 0.25 * durationSeconds : 0.5
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
