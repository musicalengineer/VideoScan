import Testing
import Foundation
@testable import VideoScan

// MARK: - arcfaceCosine — core ArcFace match primitive
//
// `arcfaceCosine(_:_:)` (ArcFaceEngine.swift) was at 0 direct coverage
// before this file. It is the distance function every ArcFace match
// decision rides on: pfMatchEmbedding compares `arcfaceCosine(...) >=
// settings.arcfaceThreshold` (default 0.40) to decide whether a frame
// is a hit. If this primitive drifts, "find Donna with ArcFace" breaks
// silently — no crash, just wrong matches.
//
// LOAD-BEARING CONTRACT being pinned here:
//   The function computes a PLAIN DOT PRODUCT with no normalization
//   (ArcFaceEngine.swift line ~249-254). It is only a true cosine
//   similarity because callers pass L2-NORMALIZED unit vectors —
//   arcfaceEmbedding() normalizes at line ~235-237 before returning.
//   These tests therefore use unit vectors and assert the cosine
//   identities. A future refactor that feeds un-normalized embeddings
//   (or removes the normalize step) would make `>= 0.40` magnitude-
//   dependent and meaningless; the "magnitude sensitivity" test below
//   is the tripwire that would catch exactly that.
//
// C++ analogy: @Test ≈ TEST, #expect ≈ EXPECT_TRUE, and
// `#expect(abs(x - y) < eps)` ≈ EXPECT_NEAR(x, y, eps).

@Suite("arcfaceCosine")
struct PersonFinderArcFaceCosineTests {

    /// Float tolerance for accumulated dot-product rounding over 512 lanes.
    private let eps: Float = 1e-5

    // MARK: - Cosine identities on unit vectors

    @Test func identicalUnitVectorsScoreOne() {
        // A normalized embedding compared to itself must score exactly 1
        // (within fp tolerance). This is the "perfect self-match" anchor;
        // if it ever drops below 1, the threshold sweep shifts under us.
        let v = Self.unitVector(seed: 1, dim: 512)
        let s = arcfaceCosine(v, v)
        #expect(abs(s - 1.0) < eps, "self-similarity must be 1.0, got \(s)")
    }

    @Test func orthogonalUnitVectorsScoreZero() {
        // Two axis-aligned unit vectors in different dimensions are
        // orthogonal → cosine 0. Pins that the dot product actually
        // zeroes out non-overlapping support.
        var a = [Float](repeating: 0, count: 512); a[0] = 1
        var b = [Float](repeating: 0, count: 512); b[1] = 1
        let s = arcfaceCosine(a, b)
        #expect(abs(s) < eps, "orthogonal vectors must score ~0, got \(s)")
    }

    @Test func oppositeUnitVectorsScoreNegativeOne() {
        // Antiparallel unit vectors → -1, the floor of the range the
        // doc comment promises ([-1, 1]).
        let v = Self.unitVector(seed: 7, dim: 512)
        let neg = v.map { -$0 }
        let s = arcfaceCosine(v, neg)
        #expect(abs(s - (-1.0)) < eps, "antiparallel vectors must score -1, got \(s)")
    }

    @Test func resultStaysWithinClosedRangeForUnitInputs() {
        // Spot-check several random unit-vector pairs all land in [-1, 1].
        // Cheap invariant guard against any future SIMD rewrite producing
        // out-of-range garbage that would corrupt the threshold compare.
        for seedA in 0..<8 {
            for seedB in 8..<16 {
                let a = Self.unitVector(seed: seedA, dim: 512)
                let b = Self.unitVector(seed: seedB, dim: 512)
                let s = arcfaceCosine(a, b)
                #expect(s >= -1.0 - eps && s <= 1.0 + eps,
                        "cosine \(s) out of [-1,1] for seeds \(seedA),\(seedB)")
            }
        }
    }

    // MARK: - Length-mismatch sentinel

    @Test func mismatchedLengthsReturnNeverMatchSentinel() {
        // The guard `a.count == b.count else { return -1 }` is a safety
        // net: a malformed/short embedding must never accidentally clear
        // the threshold. -1 is below any sane arcfaceThreshold, so a
        // mismatch is treated as "definitely not this person".
        let a = [Float](repeating: 0.1, count: 512)
        let b = [Float](repeating: 0.1, count: 256)
        #expect(arcfaceCosine(a, b) == -1,
                "length mismatch must return the -1 never-match sentinel")
        // Symmetry: order of arguments must not change the sentinel.
        #expect(arcfaceCosine(b, a) == -1)
    }

    @Test func emptyVectorsScoreZeroNotSentinel() {
        // Two empty vectors are *equal length* (0 == 0), so they pass the
        // guard and the dot-product loop runs zero times → 0. Pin this so
        // a refactor doesn't conflate "empty" with "mismatch". 0 is below
        // threshold, so it's still safely a non-match in practice.
        #expect(arcfaceCosine([], []) == 0)
    }

    // MARK: - Threshold-boundary semantics (the actual match decision)
    //
    // The match site does `bestCosine >= cosineThreshold`. These tests
    // construct unit-vector pairs whose cosine lands JUST BELOW, EXACTLY
    // AT, and JUST ABOVE the default 0.40 threshold and pin which side of
    // the inequality each falls on. This is the boundary that decides
    // whether a frame becomes a hit.

    @Test func cosineThresholdBoundaryIsInclusiveAtExactlyThreshold() {
        let threshold: Float = 0.40
        // Build a pair with a KNOWN cosine of exactly 0.40 using a 2-D
        // construction embedded in 512-D: a = (1,0,...), b = (0.40, y, 0...)
        // with y = sqrt(1 - 0.40^2) so b is a unit vector and a·b = 0.40.
        let cos: Float = 0.40
        var a = [Float](repeating: 0, count: 512); a[0] = 1
        var b = [Float](repeating: 0, count: 512)
        b[0] = cos
        b[1] = (1 - cos * cos).squareRoot()
        let s = arcfaceCosine(a, b)
        #expect(abs(s - 0.40) < eps, "constructed pair should score ~0.40, got \(s)")
        // `>=` is inclusive: a score equal to threshold IS a match.
        #expect(s >= threshold - eps,
                "score at exactly threshold must satisfy the >= match test")
    }

    @Test func justBelowThresholdIsNotAMatch() {
        let threshold: Float = 0.40
        let cos: Float = 0.35   // clearly below 0.40
        var a = [Float](repeating: 0, count: 512); a[0] = 1
        var b = [Float](repeating: 0, count: 512)
        b[0] = cos
        b[1] = (1 - cos * cos).squareRoot()
        let s = arcfaceCosine(a, b)
        #expect(abs(s - cos) < eps)
        #expect(!(s >= threshold),
                "0.35 cosine must fail the >= 0.40 match test (non-hit)")
    }

    @Test func justAboveThresholdIsAMatch() {
        let threshold: Float = 0.40
        let cos: Float = 0.45   // clearly above 0.40
        var a = [Float](repeating: 0, count: 512); a[0] = 1
        var b = [Float](repeating: 0, count: 512)
        b[0] = cos
        b[1] = (1 - cos * cos).squareRoot()
        let s = arcfaceCosine(a, b)
        #expect(abs(s - cos) < eps)
        #expect(s >= threshold,
                "0.45 cosine must clear the >= 0.40 match test (hit)")
    }

    // MARK: - Normalization-contract tripwire
    //
    // This is the highest-value test in the file. arcfaceCosine ONLY
    // behaves like a cosine because inputs are unit vectors. If someone
    // ever feeds it un-normalized embeddings (or deletes the L2-normalize
    // in arcfaceEmbedding), the dot product scales with magnitude and the
    // 0.40 threshold silently loses meaning. We can't reach the private
    // match function, but we CAN demonstrate the magnitude sensitivity so
    // the invariant is documented and locked: scaling one input by 3x
    // scales the score by 3x. A green here is the CONTRACT; if the
    // function were ever changed to self-normalize, this test would fail
    // and force a conscious decision (update the test + the embedding
    // path together, never silently).

    @Test func scoreScalesWithInputMagnitude_documentsNormalizationRequirement() {
        let u = Self.unitVector(seed: 3, dim: 512)
        let selfScore = arcfaceCosine(u, u)          // ≈ 1.0 for a unit vector
        let scaled = u.map { $0 * 3 }                // NOT a unit vector
        let scaledScore = arcfaceCosine(u, scaled)   // ≈ 3.0 — magnitude leaks in
        #expect(abs(selfScore - 1.0) < eps)
        #expect(abs(scaledScore - 3.0) < 3 * eps,
                """
                arcfaceCosine is a bare dot product; a 3x-scaled input yields a \
                3x score. This is correct ONLY because callers pass L2-normalized \
                embeddings. If this assertion ever changes, the embedding \
                normalization contract changed with it — review the 0.40 threshold.
                """)
    }

    // MARK: - Helpers

    /// Deterministic L2-normalized vector. A tiny LCG fills the lanes so
    /// the test is reproducible across runs/machines (no RNG seed plumbing).
    nonisolated static func unitVector(seed: Int, dim: Int) -> [Float] {
        var state = UInt64(bitPattern: Int64(seed &* 2654435761 &+ 1))
        var v = [Float](repeating: 0, count: dim)
        for i in 0..<dim {
            // xorshift64* — deterministic, decent spread
            state ^= state >> 12; state ^= state << 25; state ^= state >> 27
            let r = Float(state &* 0x2545F4914F6CDD1D >> 40) / Float(1 << 24)
            v[i] = r - 0.5
        }
        let norm = (v.reduce(Float(0)) { $0 + $1 * $1 }).squareRoot()
        if norm > 0 { for i in 0..<dim { v[i] /= norm } }
        return v
    }
}
