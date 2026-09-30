import Foundation

// MARK: - PerceptualHash
//
// PURE perceptual-hash core for the compare pipeline's PERCEPTUAL tier
// — the layer that answers "are these the same pictures, encoded
// differently?" when byte- and packet-level identity (Tiers 0–2 in
// MediaPairComparator) have already said "different". A DV original
// and its H.264 re-encode share zero bytes, but their frames look the
// same; this module quantifies "look the same".
//
// No I/O, no subprocesses, no actors — values in, values out, fully
// unit-testable (PerceptualHashTests). Frame extraction lives in
// PerceptualFingerprinter; orchestration in MediaPairComparator.
//
// ## The hash: dHash (difference hash)
//
// Each sampled frame is decoded by ffmpeg straight to a 9-wide × 8-tall
// grayscale thumbnail (72 bytes). For every row we compare the 8
// horizontal neighbor pairs: bit set iff pixel[x] > pixel[x+1].
// 8 bits/row × 8 rows = one UInt64 per frame. dHash survives exactly
// the transforms a re-encode applies — codec, bitrate, resolution,
// container, mild color shifts — because it encodes only the SIGN of
// local luminance gradients, not their magnitudes.
//
// ## The statistical model (the heart of the verdict)
//
// For two UNRELATED frames, each of the 64 bits agrees or disagrees
// essentially at random — each bit ~ Bernoulli(0.5) — so the Hamming
// distance d between their hashes is Binomial(n=64, p=0.5): mean 32,
// σ = 4. The chance a single unrelated pair lands at d ≤ 16 (our
// per-frame "match" threshold — 4σ below the mean) is
//
//     p = Σ_{k=0..16} C(64,k) / 2^64  ≈ 3.9e-5
//
// If m of n compared frame pairs land at d ≤ 16, the probability of
// that happening by coincidence is bounded by C(n,m) · p^m (union
// bound over which m frames matched). We report log10 of that bound,
// computed in log space (lgamma) so C(32,16)·p^16 doesn't underflow
// Double, clamped at -300. With 31/32 frames matching, the bound is
// below 1e-130 — "these are the same pictures" to any standard of
// evidence.
//
// (Caveat the model is honest about: consecutive frames of ONE video
// are correlated, so the n samples aren't fully independent draws —
// which is why we sample 32 frames spread across the whole duration,
// and why the verdict ALSO requires a low median distance and a high
// match fraction rather than leaning on the probability alone.)
//
// ## Known limitation (v1, accepted)
//
// Letterboxed vs cropped variants of the same content defeat dHash:
// black bars shift every row's gradient structure. A future
// crop-detect pass (ffmpeg cropdetect before scaling) could fix this;
// for v1 such pairs simply stay "Genuinely different files" — the
// tier can miss matches but is engineered never to invent one.
//
// Memory footprint: a fingerprint is 32 × 8 bytes = 256 bytes per
// file; comparison allocates a few small Int arrays. Negligible.

// MARK: - Match result

/// Everything the perceptual tier learned from comparing two
/// fingerprints. Stored values only — `isMatch` and `summary` are
/// derived. (≈ a C++ POD result struct; Equatable for tests.)
struct PerceptualMatchResult: Equatable, Sendable {
    /// Per-frame Hamming distances at the best alignment offset.
    let distances: [Int]
    /// The alignment offset (−2…+2 frame indices) that minimized the
    /// median distance. Nonzero means one file has a trimmed leader.
    let bestOffset: Int
    /// Number of frame pairs actually compared at that offset.
    let framesCompared: Int
    /// How many of those pairs landed at distance ≤ 16.
    let matchedFrames: Int
    /// Median of `distances` (upper median for even counts — the
    /// conservative choice: never lets the better half over-claim).
    /// 64 (worst possible) when nothing was comparable.
    let medianDistance: Int
    /// matchedFrames / framesCompared; 0 when nothing was comparable.
    let matchFraction: Double
    /// log10 of the coincidence-probability bound C(n,m)·p^m,
    /// clamped to ≥ -300. 0 when no frames matched (bound is 1).
    let log10CoincidenceProbability: Double

    /// The verdict gate. ALL THREE must hold — median ≤ 10 (typical
    /// re-encodes land at 0–6), ≥ 80% of frames matching (tolerates a
    /// few scene-cut/fade frames that hash unstably), and ≥ 10 frames
    /// compared (below that the statistics are too thin to claim
    /// anything). The "inconclusive" zone — e.g. median ≤ 16 but
    /// fraction 0.6 — deliberately does NOT match; the caller falls
    /// through to `differentMedia` and keeps these stats for display.
    var isMatch: Bool {
        medianDistance <= PerceptualHash.matchMedianMax
            && matchFraction >= PerceptualHash.matchFractionMin
            && framesCompared >= PerceptualHash.minFramesForVerdict
    }

    /// Human-readable stats line for the verdict UI, e.g.
    /// "31/32 frames agree (median distance 4) — P(coincidence) < 1e-130".
    var summary: String {
        guard framesCompared > 0 else {
            return "Not enough comparable frames for a visual check"
        }
        var s = "\(matchedFrames)/\(framesCompared) frames agree"
            + " (median distance \(medianDistance))"
        // Only quote a probability when it's actually compelling;
        // "P < 1e0" would be statistical noise dressed up as math.
        if log10CoincidenceProbability <= -3 {
            // log10P = -40.3 → exponent -40, and P < 1e-40 holds
            // because rounding UP makes the bound looser, never tighter.
            let exponent = Int(log10CoincidenceProbability.rounded(.up))
            s += " — P(coincidence) < 1e\(exponent)"
        }
        return s
    }
}

// MARK: - Core

enum PerceptualHash {

    // MARK: Geometry & thresholds (single source of truth; tests pin these)

    /// dHash thumbnail geometry: 9 wide × 8 tall grayscale.
    static let grayWidth = 9
    static let grayHeight = 8
    /// 9 × 8 = 72 bytes per frame.
    static let grayByteCount = grayWidth * grayHeight

    /// Per-frame Hamming threshold: distance ≤ 16 counts as a frame
    /// match. 16 = mean − 4σ for unrelated frames (Binomial(64, 0.5)).
    static let perFrameBitThreshold = 16
    /// Verdict gates — see PerceptualMatchResult.isMatch.
    static let matchMedianMax = 10
    static let matchFractionMin = 0.8
    static let minFramesForVerdict = 10

    /// Alignment offsets tried by compare(), in preference order —
    /// 0 first so ties go to "no trim", then growing |offset|.
    static let alignmentOffsets = [0, -1, 1, -2, 2]

    /// P(Hamming ≤ 16) for two unrelated 64-bit dHashes:
    /// Σ_{k=0..16} C(64,k) / 2^64 ≈ 3.9e-5. Computed once via the
    /// multiplicative recurrence C(n,k) = C(n,k−1)·(n−k+1)/k — every
    /// C(64,k) for k ≤ 16 is < 2^53, so each term is EXACT in Double
    /// (no lgamma rounding in the constant the verdict depends on).
    static let perFrameCoincidenceProbability: Double = {
        var binomial = 1.0   // C(64, 0)
        var sum = 1.0
        for k in 1...perFrameBitThreshold {
            binomial = binomial * Double(64 - k + 1) / Double(k)
            sum += binomial
        }
        return sum / exp2(64)
    }()

    /// log10 of the above — the per-matched-frame evidence weight
    /// (≈ −4.41 decades per matching frame).
    static let log10PerFrameCoincidence = log10(perFrameCoincidenceProbability)

    // MARK: dHash

    /// 64-bit difference hash of one 9×8 row-major grayscale frame.
    /// Bit layout: bit (row·8 + x) is set iff pixel[row][x] > pixel[row][x+1].
    /// Strict `>` means a perfectly flat frame hashes to 0 — flat black
    /// leaders compare equal to each other, which the trim-skip in the
    /// fingerprinter already mostly avoids.
    static func dHash64(gray9x8 bytes: [UInt8]) -> UInt64 {
        precondition(bytes.count == grayByteCount,
                     "dHash64 requires exactly \(grayByteCount) bytes, got \(bytes.count)")
        var hash: UInt64 = 0
        var bit: UInt64 = 1
        for row in 0..<grayHeight {
            let base = row * grayWidth
            for x in 0..<(grayWidth - 1) {
                if bytes[base + x] > bytes[base + x + 1] {
                    hash |= bit
                }
                bit &<<= 1   // `&<<` masks the shift AMOUNT; plain << also just discards shifted-out bits (≈ C++ <<)
            }
        }
        return hash
    }

    /// Number of differing bits between two hashes — xor + popcount.
    /// (`nonzeroBitCount` ≈ __builtin_popcountll.)
    static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    // MARK: Sequence comparison

    /// Compare two fingerprint sequences sampled at the same normalized
    /// time positions. Tries small index offsets (±2) so a trimmed
    /// leader/trailer on one copy doesn't wreck the alignment, keeps
    /// the offset with the lowest median distance, then runs the
    /// statistical model over the per-frame distances at that offset.
    static func compare(_ a: [UInt64], _ b: [UInt64]) -> PerceptualMatchResult {
        var bestOffset = 0
        var bestDistances: [Int] = []
        var bestMedian = Int.max

        for offset in alignmentOffsets {
            let d = distances(a, b, offset: offset)
            guard !d.isEmpty else { continue }
            let m = median(d)
            // Strict < keeps the earlier (smaller-|offset|) candidate on ties.
            if m < bestMedian {
                bestMedian = m
                bestDistances = d
                bestOffset = offset
            }
        }

        guard !bestDistances.isEmpty else {
            // Nothing comparable (one/both fingerprints empty). Worst
            // possible median so no downstream check can mistake this
            // for evidence of a match.
            return PerceptualMatchResult(distances: [],
                                         bestOffset: 0,
                                         framesCompared: 0,
                                         matchedFrames: 0,
                                         medianDistance: 64,
                                         matchFraction: 0,
                                         log10CoincidenceProbability: 0)
        }

        let n = bestDistances.count
        // filter().count rather than count(where:) — the latter needs a
        // newer OS-shipped stdlib than the macOS 13 deployment target.
        let m = bestDistances.filter { $0 <= perFrameBitThreshold }.count
        let fraction = Double(m) / Double(n)

        // Coincidence bound: C(n,m) · p^m, in log10 space. m = 0 ⇒
        // bound is 1 ⇒ log10 = 0 (no evidence either way).
        // Display-only honesty notes (verdict gates don't use this):
        // picking the best of 5 alignment offsets costs ~log10(5) ≈ 0.7
        // decades, and dHash bits of real frames aren't fully
        // independent — treat the figure as an order-of-magnitude bound.
        var log10P = 0.0
        if m > 0 {
            log10P = log10Choose(n, m) + Double(m) * log10PerFrameCoincidence
            log10P = max(log10P, -300)   // clamp; beyond this the number is theater
        }

        return PerceptualMatchResult(distances: bestDistances,
                                     bestOffset: bestOffset,
                                     framesCompared: n,
                                     matchedFrames: m,
                                     medianDistance: bestMedian,
                                     matchFraction: fraction,
                                     log10CoincidenceProbability: log10P)
    }

    /// Per-frame Hamming distances comparing a[i] against b[i + offset]
    /// over the overlapping index range.
    private static func distances(_ a: [UInt64], _ b: [UInt64], offset: Int) -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(min(a.count, b.count))
        for i in a.indices {
            let j = i + offset
            guard j >= 0, j < b.count else { continue }
            result.append(hammingDistance(a[i], b[j]))
        }
        return result
    }

    /// Integer median; for even counts, the UPPER of the two middle
    /// values — the conservative direction (a higher median can only
    /// make us LESS likely to claim a match, never more).
    static func median(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 64 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// log10(C(n, m)) via lgamma — exact enough (≪ 1e-10 relative) and
    /// immune to the overflow a direct C(n,m) would hit for large n.
    /// (lgamma(x) = ln Γ(x); Γ(n+1) = n!, so this is ln-factorial
    /// arithmetic converted to base 10.)
    static func log10Choose(_ n: Int, _ m: Int) -> Double {
        guard m >= 0, m <= n else { return -.infinity }
        let ln = lgamma(Double(n) + 1) - lgamma(Double(m) + 1) - lgamma(Double(n - m) + 1)
        return ln / log(10.0)
    }

    // MARK: Fingerprint encoding (future catalog persistence)
    //
    // Compact round-trip helpers so a future schema change can store
    // fingerprints (32 hashes → 256 bytes → 344 base64 chars) in
    // SQLite without re-decoding video. Deliberately NOT wired into
    // the catalog in this feature — persistence is a schema decision.

    /// Big-endian packed bytes — endian-pinned so a fingerprint written
    /// on one machine reads identically anywhere.
    static func data(from fingerprint: [UInt64]) -> Data {
        var d = Data(capacity: fingerprint.count * 8)
        for value in fingerprint {
            withUnsafeBytes(of: value.bigEndian) { d.append(contentsOf: $0) }
        }
        return d
    }

    /// Inverse of `data(from:)`. nil when the length isn't a whole
    /// number of UInt64s — corrupt input must not half-parse.
    static func fingerprint(from data: Data) -> [UInt64]? {
        guard data.count % 8 == 0 else { return nil }
        var result: [UInt64] = []
        result.reserveCapacity(data.count / 8)
        var value: UInt64 = 0
        var byteIndex = 0
        for byte in data {
            value = (value &<< 8) | UInt64(byte)
            byteIndex += 1
            if byteIndex == 8 {
                result.append(value)
                value = 0
                byteIndex = 0
            }
        }
        return result
    }

    /// Base64 of the packed bytes — the form a TEXT catalog column
    /// would hold.
    static func base64(from fingerprint: [UInt64]) -> String {
        data(from: fingerprint).base64EncodedString()
    }

    /// Inverse of `base64(from:)`. nil on malformed input.
    static func fingerprint(fromBase64 string: String) -> [UInt64]? {
        guard let data = Data(base64Encoded: string) else { return nil }
        return fingerprint(from: data)
    }
}
