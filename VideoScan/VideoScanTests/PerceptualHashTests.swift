import Testing
import Foundation
@testable import VideoScan

// MARK: - PerceptualHash tests (2026-06-11)
//
// The perceptual compare tier was layered so this entire file needs no
// media, no ffmpeg, no I/O — PerceptualHash is values-in/values-out:
//
//   - dHash64           — 72 gray bytes → 64-bit difference hash
//   - hammingDistance   — xor + popcount
//   - compare           — fingerprint sequences → PerceptualMatchResult
//   - the statistical model (per-frame Binomial tail, log-space C(n,m))
//   - the verdict gate  — PerceptualMatchResult.isMatch thresholds
//   - encoding helpers  — [UInt64] ↔ Data ↔ base64 round trips
//
// Per the project's safety-critical testing policy: positive AND
// negative coverage, with deterministic hardcoded vectors — no
// randomness, so a failure always reproduces.

// MARK: - Deterministic vector helpers

/// splitmix64 — tiny deterministic PRNG-quality mixer. Same seed →
/// same value, forever; gives uncorrelated 64-bit patterns so two
/// differently-seeded sequences behave like unrelated fingerprints.
private func splitmix64(_ seed: UInt64) -> UInt64 {
    var z = seed &+ 0x9E37_79B9_7F4A_7C15
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
}

private func sequence(seed: UInt64, count: Int) -> [UInt64] {
    (0..<count).map { splitmix64(seed &+ UInt64($0)) }
}

/// Flat mid-gray 9×8 frame — every neighbor comparison is `128 > 128`
/// = false, so its dHash must be all zeros.
private let flatFrame = [UInt8](repeating: 128, count: 72)

// MARK: - dHash

@Suite("PerceptualHash.dHash64")
struct DHashTests {

    @Test func flatImageHashesToZero() {
        #expect(PerceptualHash.dHash64(gray9x8: flatFrame) == 0)
    }

    // Strictly decreasing pixels within every row: pixel[x] > pixel[x+1]
    // everywhere → all 64 comparison bits set.
    @Test func strictlyDecreasingRowsHashToAllOnes() {
        var frame = [UInt8]()
        for _ in 0..<8 {
            frame.append(contentsOf: (0..<9).map { UInt8(100 - $0) })
        }
        #expect(PerceptualHash.dHash64(gray9x8: frame) == UInt64.max)
    }

    // Strictly increasing rows: never `>` → all zeros (and distinct
    // from decreasing — sanity that direction matters).
    @Test func strictlyIncreasingRowsHashToZero() {
        var frame = [UInt8]()
        for _ in 0..<8 {
            frame.append(contentsOf: (0..<9).map { UInt8(100 + $0) })
        }
        #expect(PerceptualHash.dHash64(gray9x8: frame) == 0)
    }

    // Locality: flipping ONE pixel touches at most its two neighbor
    // comparisons → Hamming distance 1…2 from the original. This is
    // the property that makes dHash robust to encoding noise.
    @Test func singlePixelFlipChangesAtMostTwoBits() {
        let original = PerceptualHash.dHash64(gray9x8: flatFrame)

        // Middle of a row: two comparisons affected, (3,4) and (4,5).
        var middle = flatFrame
        middle[2 * 9 + 4] = 200
        let dMiddle = PerceptualHash.hammingDistance(
            original, PerceptualHash.dHash64(gray9x8: middle))
        #expect(dMiddle >= 1 && dMiddle <= 2)

        // First pixel of a row: only comparison (0,1) affected.
        var first = flatFrame
        first[0] = 200
        let dFirst = PerceptualHash.hammingDistance(
            original, PerceptualHash.dHash64(gray9x8: first))
        #expect(dFirst == 1)
    }

    // Bit layout contract: bit (row*8 + x) is set iff pixel[x] > pixel[x+1]
    // in that row. Pin bit 0 and bit 63 explicitly.
    @Test func bitLayoutMatchesRowMajorOrder() {
        var frame = flatFrame
        frame[0] = 200                       // row 0, comparison (0,1) → bit 0
        #expect(PerceptualHash.dHash64(gray9x8: frame) == 1)

        frame = flatFrame
        frame[7 * 9 + 7] = 200               // row 7, comparison (7,8) → bit 63
        #expect(PerceptualHash.dHash64(gray9x8: frame) == (1 << 63))
    }
}

// MARK: - Hamming distance

@Suite("PerceptualHash.hammingDistance")
struct HammingTests {

    @Test func identityIsZero() {
        #expect(PerceptualHash.hammingDistance(0, 0) == 0)
        #expect(PerceptualHash.hammingDistance(.max, .max) == 0)
        #expect(PerceptualHash.hammingDistance(0xDEAD_BEEF, 0xDEAD_BEEF) == 0)
    }

    @Test func complementIsSixtyFour() {
        #expect(PerceptualHash.hammingDistance(0, .max) == 64)
        let v: UInt64 = 0x0123_4567_89AB_CDEF
        #expect(PerceptualHash.hammingDistance(v, ~v) == 64)
    }

    @Test func knownXorCases() {
        #expect(PerceptualHash.hammingDistance(0b1011, 0b0001) == 2)
        #expect(PerceptualHash.hammingDistance(0b1111_0000, 0b0000_1111) == 8)
        #expect(PerceptualHash.hammingDistance(1 << 63, 0) == 1)
    }
}

// MARK: - Sequence comparison

@Suite("PerceptualHash.compare")
struct CompareTests {

    // Positive: identical 32-frame fingerprints → perfect agreement
    // and an astronomically small coincidence bound (32 frames at
    // ~−4.4 decades each ≈ −141; assert a generous < −100).
    @Test func identicalSequencesMatchPerfectly() {
        let fp = sequence(seed: 7, count: 32)
        let r = PerceptualHash.compare(fp, fp)
        #expect(r.medianDistance == 0)
        #expect(r.matchFraction == 1.0)
        #expect(r.framesCompared == 32)
        #expect(r.matchedFrames == 32)
        #expect(r.bestOffset == 0)
        #expect(r.log10CoincidenceProbability < -100)
        #expect(r.isMatch)
    }

    // Negative: two unrelated deterministic sequences must NOT match —
    // distances cluster around 32 (mean of Binomial(64, 0.5)).
    @Test func unrelatedSequencesDoNotMatch() {
        let a = sequence(seed: 1, count: 32)
        let b = sequence(seed: 999_983, count: 32)   // far-away seed
        let r = PerceptualHash.compare(a, b)
        #expect(!r.isMatch)
        #expect(r.medianDistance > PerceptualHash.perFrameBitThreshold,
                "Unrelated median was \(r.medianDistance) — model violated")
        #expect(r.matchFraction < PerceptualHash.matchFractionMin)
    }

    // Positive: the alignment search rescues an off-by-one trim — the
    // same fingerprints shifted by one index still match, at offset −1.
    @Test func offsetByOneStillMatches() {
        let base = sequence(seed: 42, count: 34)
        let a = Array(base[0..<32])     // a[i] = base[i]
        let b = Array(base[1..<33])     // b[j] = base[j+1] ⇒ a[i] == b[i−1]
        let r = PerceptualHash.compare(a, b)
        #expect(r.isMatch)
        #expect(r.bestOffset == -1)
        #expect(r.medianDistance == 0)
        // Overlap shrinks by |offset|.
        #expect(r.framesCompared == 31)
    }

    // Negative: short identical sequences are real agreement but TOO
    // FEW frames to support a verdict — must stay inconclusive.
    @Test func shortSequencesAreInconclusive() {
        let fp = sequence(seed: 5, count: 5)
        let r = PerceptualHash.compare(fp, fp)
        #expect(r.medianDistance == 0)          // they DO agree…
        #expect(r.framesCompared == 5)
        #expect(!r.isMatch)                     // …but no claim under 10 frames
    }

    // Negative (safety-critical): empty inputs must report worst-case
    // numbers, never anything a caller could mistake for a match.
    @Test func emptyInputsNeverMatch() {
        for (a, b) in [([], sequence(seed: 3, count: 8)),
                       (sequence(seed: 3, count: 8), []),
                       ([], [])] {
            let r = PerceptualHash.compare(a, b)
            #expect(!r.isMatch)
            #expect(r.framesCompared == 0)
            #expect(r.medianDistance == 64)
            #expect(r.matchFraction == 0)
            #expect(r.log10CoincidenceProbability == 0)
        }
    }

    // The "inconclusive zone": median under the per-frame threshold
    // (16) but over the verdict gate (10) must NOT claim a match.
    // Build it synthetically: every distance exactly 12.
    @Test func mediumDistancesAreInconclusive() {
        let a = [UInt64](repeating: 0, count: 32)
        // 12 bits set → every pairwise distance is exactly 12.
        let twelveBits: UInt64 = 0b1111_1111_1111
        let b = [UInt64](repeating: twelveBits, count: 32)
        let r = PerceptualHash.compare(a, b)
        #expect(r.medianDistance == 12)
        #expect(r.matchFraction == 1.0)         // all ≤ 16…
        #expect(!r.isMatch)                     // …but median > 10 ⇒ no claim
        // Stats remain available for display under differentMedia.
        #expect(r.log10CoincidenceProbability < -100)
    }
}

// MARK: - Statistical model

@Suite("PerceptualHash statistics")
struct PerceptualStatisticsTests {

    // The per-frame constant must equal the Binomial(64, 0.5) tail
    // Σ_{k=0..16} C(64,k)/2^64, recomputed here INDEPENDENTLY via
    // lgamma (production uses the exact multiplicative recurrence —
    // two different routes must land on the same number).
    @Test func perFrameProbabilityMatchesBinomialTail() {
        var sum = 0.0
        for k in 0...16 {
            let logC = lgamma(65) - lgamma(Double(k) + 1) - lgamma(Double(64 - k) + 1)
            sum += exp(logC)
        }
        let expected = sum / exp2(64)
        let actual = PerceptualHash.perFrameCoincidenceProbability
        #expect(abs(actual - expected) / expected < 1e-9,
                "constant \(actual) vs independent \(expected)")
        // Ballpark pin so a broken recurrence can't pass by matching a
        // broken cross-check: the tail is a few-in-100k event.
        #expect(actual > 3e-5 && actual < 5e-5)
        // And the log form used by compare() is consistent.
        #expect(abs(PerceptualHash.log10PerFrameCoincidence - log10(actual)) < 1e-12)
    }

    // log-space C(n,m) sanity for n = 32 (the fingerprint length).
    @Test func log10ChooseKnownValues() {
        // C(32,16) = 601,080,390 → log10 ≈ 8.778953
        #expect(abs(PerceptualHash.log10Choose(32, 16) - log10(601_080_390)) < 1e-6)
        // C(n,0) = C(n,n) = 1 → log10 = 0.
        #expect(abs(PerceptualHash.log10Choose(32, 0)) < 1e-12)
        #expect(abs(PerceptualHash.log10Choose(32, 32)) < 1e-12)
        // C(32,1) = 32.
        #expect(abs(PerceptualHash.log10Choose(32, 1) - log10(32)) < 1e-9)
        // Out-of-range m → −∞ (probability bound of an impossible count).
        #expect(PerceptualHash.log10Choose(32, 33) == -.infinity)
        #expect(PerceptualHash.log10Choose(32, -1) == -.infinity)
    }

    // The clamp: a perfect long match must floor at −300, not produce
    // −inf or NaN that would poison the summary string.
    @Test func coincidenceProbabilityIsClamped() {
        let fp = sequence(seed: 11, count: 32)
        let r = PerceptualHash.compare(fp, fp)
        #expect(r.log10CoincidenceProbability >= -300)
        #expect(r.log10CoincidenceProbability.isFinite)
    }
}

// MARK: - Verdict gate thresholds (boundary cases)

@Suite("PerceptualMatchResult.isMatch boundaries")
struct PerceptualVerdictGateTests {

    /// Construct a result directly (memberwise init via @testable) so
    /// each gate can be probed at its exact boundary.
    private func result(median: Int,
                        fraction: Double,
                        frames: Int) -> PerceptualMatchResult {
        PerceptualMatchResult(distances: [],
                              bestOffset: 0,
                              framesCompared: frames,
                              matchedFrames: Int(fraction * Double(frames)),
                              medianDistance: median,
                              matchFraction: fraction,
                              log10CoincidenceProbability: -50)
    }

    @Test func medianBoundary() {
        #expect(result(median: 10, fraction: 1.0, frames: 32).isMatch)
        #expect(!result(median: 11, fraction: 1.0, frames: 32).isMatch)
    }

    @Test func fractionBoundary() {
        #expect(result(median: 0, fraction: 0.80, frames: 32).isMatch)
        #expect(!result(median: 0, fraction: 0.79, frames: 32).isMatch)
    }

    @Test func frameCountBoundary() {
        #expect(result(median: 0, fraction: 1.0, frames: 10).isMatch)
        #expect(!result(median: 0, fraction: 1.0, frames: 9).isMatch)
    }

    // All three gates must hold SIMULTANEOUSLY.
    @Test func anySingleFailingGateBlocksTheMatch() {
        #expect(!result(median: 11, fraction: 0.79, frames: 9).isMatch)
        #expect(!result(median: 10, fraction: 0.80, frames: 9).isMatch)
        #expect(!result(median: 10, fraction: 0.79, frames: 10).isMatch)
        #expect(!result(median: 11, fraction: 0.80, frames: 10).isMatch)
        #expect(result(median: 10, fraction: 0.80, frames: 10).isMatch)
    }

    // Summary string contract — the verdict UI leans on this format.
    @Test func summaryIncludesStatsAndProbability() {
        let r = PerceptualMatchResult(distances: [],
                                      bestOffset: 0,
                                      framesCompared: 32,
                                      matchedFrames: 31,
                                      medianDistance: 4,
                                      matchFraction: 31.0 / 32.0,
                                      log10CoincidenceProbability: -40.3)
        #expect(r.summary == "31/32 frames agree (median distance 4) — P(coincidence) < 1e-40")
    }

    // Near-1 bounds must not be dressed up as evidence.
    @Test func summaryOmitsWeakProbability() {
        let r = PerceptualMatchResult(distances: [],
                                      bestOffset: 0,
                                      framesCompared: 32,
                                      matchedFrames: 1,
                                      medianDistance: 30,
                                      matchFraction: 1.0 / 32.0,
                                      log10CoincidenceProbability: -2.9)
        #expect(r.summary == "1/32 frames agree (median distance 30)")
    }

    @Test func summaryHandlesZeroFrames() {
        let r = PerceptualMatchResult(distances: [],
                                      bestOffset: 0,
                                      framesCompared: 0,
                                      matchedFrames: 0,
                                      medianDistance: 64,
                                      matchFraction: 0,
                                      log10CoincidenceProbability: 0)
        #expect(r.summary == "Not enough comparable frames for a visual check")
    }
}

// MARK: - Verdict fold including the perceptual tier

@Suite("PairCompareLogic.verdict with perceptual tier")
struct PerceptualVerdictFoldTests {

    // Perceptual match upgrades differentMedia…
    @Test func perceptualMatchYieldsReencodedVerdict() {
        let v = PairCompareLogic.verdict(sizesMatch: false,
                                         bytesMatch: nil,
                                         streamsMatch: false,
                                         perceptualMatch: true)
        #expect(v == .samePerceptualContent)
    }

    // …but never outranks a stronger claim.
    @Test func strongerTiersOutrankPerceptual() {
        #expect(PairCompareLogic.verdict(sizesMatch: true, bytesMatch: true,
                                         streamsMatch: nil, perceptualMatch: true)
                == .exactDuplicates)
        #expect(PairCompareLogic.verdict(sizesMatch: false, bytesMatch: nil,
                                         streamsMatch: true, perceptualMatch: true)
                == .sameContentDifferentContainer)
    }

    // Negative: a failed or skipped perceptual tier stays differentMedia.
    @Test func perceptualFalseOrNilStaysDifferent() {
        #expect(PairCompareLogic.verdict(sizesMatch: false, bytesMatch: nil,
                                         streamsMatch: false, perceptualMatch: false)
                == .differentMedia)
        #expect(PairCompareLogic.verdict(sizesMatch: false, bytesMatch: nil,
                                         streamsMatch: false, perceptualMatch: nil)
                == .differentMedia)
    }

    // The default argument keeps every pre-Tier-3 call site compiling
    // and behaving identically (regression sensor for the older fold).
    @Test func threeArgumentCallStillWorks() {
        #expect(PairCompareLogic.verdict(sizesMatch: false, bytesMatch: nil,
                                         streamsMatch: false)
                == .differentMedia)
    }
}

// MARK: - Fingerprint encoding round trips

@Suite("PerceptualHash fingerprint encoding")
struct FingerprintEncodingTests {

    @Test func dataRoundTripPreservesValues() {
        let fp = sequence(seed: 99, count: 32) + [0, .max, 1, 1 << 63]
        let encoded = PerceptualHash.data(from: fp)
        #expect(encoded.count == fp.count * 8)
        #expect(PerceptualHash.fingerprint(from: encoded) == fp)
    }

    @Test func base64RoundTripPreservesValues() {
        let fp = sequence(seed: 123, count: 32)
        let b64 = PerceptualHash.base64(from: fp)
        #expect(PerceptualHash.fingerprint(fromBase64: b64) == fp)
    }

    @Test func emptyFingerprintRoundTrips() {
        #expect(PerceptualHash.data(from: []).isEmpty)
        #expect(PerceptualHash.fingerprint(from: Data()) == [])
        #expect(PerceptualHash.fingerprint(fromBase64: "") == [])
    }

    // Negative: truncated data and garbage base64 must decode to nil,
    // never to a half-parsed fingerprint.
    @Test func malformedInputDecodesToNil() {
        let valid = PerceptualHash.data(from: sequence(seed: 7, count: 4))
        #expect(PerceptualHash.fingerprint(from: valid.dropLast()) == nil)
        #expect(PerceptualHash.fingerprint(from: Data([1, 2, 3])) == nil)
        #expect(PerceptualHash.fingerprint(fromBase64: "not base64!!!") == nil)
    }

    // Endianness pin: the encoding is big-endian by contract — a
    // future persistence layer depends on this exact byte order.
    @Test func encodingIsBigEndian() {
        let encoded = PerceptualHash.data(from: [0x0102_0304_0506_0708])
        #expect([UInt8](encoded) == [1, 2, 3, 4, 5, 6, 7, 8])
    }
}
