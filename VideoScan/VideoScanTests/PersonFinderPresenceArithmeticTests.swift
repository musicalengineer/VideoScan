import Testing
import Foundation
@testable import VideoScan

// MARK: - pfSegment.duration / pfVideoResult.totalPresenceSecs
//
// These two computed properties (PersonFinderTypes.swift) had no direct
// coverage. They are the arithmetic that the (private, currently
// untestable) `filterByPresence` gate rides on: a scanned video is KEPT
// in the results only if `totalPresenceSecs >= settings.minPresenceSecs`
// (default 5s). Get this arithmetic wrong and Donna-bearing clips either
// vanish from the results or junk clips slip through.
//
// Pinning the arithmetic here protects half the presence gate that we
// can reach without a production seam (the filter function itself needs
// internal visibility — see the seam proposal in the report).
//
// IMPORTANT characterization note: totalPresenceSecs SUMS per-segment
// durations; it does NOT union overlapping intervals. The clustering
// stage (pfVisionClusterSegments) is responsible for merging overlaps
// before results reach here, so by the time a pfVideoResult exists its
// segments are already disjoint. The "overlapping inputs sum, not union"
// test pins the *property's* actual behavior, not a hypothetical ideal.
//
// C++ analogy: @Test ≈ TEST, #expect ≈ EXPECT_*; computed property ≈
// a const member function.

@Suite("pfSegment / pfVideoResult presence arithmetic")
struct PersonFinderPresenceArithmeticTests {

    private let eps = 1e-9

    // MARK: - pfSegment.duration

    @Test func segmentDurationIsEndMinusStart() {
        let s = pfSegment(startSecs: 10.0, endSecs: 17.5, bestDistance: 0.3, avgDistance: 0.4)
        #expect(abs(s.duration - 7.5) < eps)
    }

    @Test func zeroLengthSegmentHasZeroDuration() {
        // A degenerate single-frame segment (start == end) has 0 duration.
        // It would never clear minPresence, which is correct.
        let s = pfSegment(startSecs: 42.0, endSecs: 42.0, bestDistance: 0.1, avgDistance: 0.1)
        #expect(s.duration == 0.0)
    }

    // MARK: - pfVideoResult.totalPresenceSecs

    @Test func totalPresenceIsSumOfSegmentDurations() {
        // Three disjoint segments: 3s + 2s + 5s = 10s.
        let result = pfVideoResult(
            filename: "clip.mov", filePath: "/tmp/clip.mov",
            durationSeconds: 60, fps: 30, totalHits: 9,
            segments: [
                pfSegment(startSecs: 0,  endSecs: 3,  bestDistance: 0.2, avgDistance: 0.3),
                pfSegment(startSecs: 10, endSecs: 12, bestDistance: 0.2, avgDistance: 0.3),
                pfSegment(startSecs: 20, endSecs: 25, bestDistance: 0.2, avgDistance: 0.3)
            ]
        )
        #expect(abs(result.totalPresenceSecs - 10.0) < eps)
    }

    @Test func totalPresenceIsZeroWhenNoSegments() {
        // A scanned-but-no-match result. This is the value that makes
        // filterByPresence treat the video as "no presence" → excluded
        // (and the zero-hit cache entry path relies on it too).
        let result = pfVideoResult(
            filename: "nohits.mov", filePath: "/tmp/nohits.mov",
            durationSeconds: 30, fps: 30, totalHits: 0, segments: []
        )
        #expect(result.totalPresenceSecs == 0.0)
    }

    @Test func singleSegmentPresenceEqualsItsDuration() {
        let result = pfVideoResult(
            filename: "one.mov", filePath: "/tmp/one.mov",
            durationSeconds: 30, fps: 30, totalHits: 4,
            segments: [pfSegment(startSecs: 5, endSecs: 11, bestDistance: 0.2, avgDistance: 0.3)]
        )
        #expect(abs(result.totalPresenceSecs - 6.0) < eps)
    }

    @Test func overlappingSegmentsSumRatherThanUnion_characterization() {
        // CHARACTERIZATION (pins what IS): two overlapping intervals
        // [0,4] and [2,6] sum to 4 + 4 = 8, NOT the 6s of their union.
        // Production never produces overlapping segments at this layer
        // (clustering merges them first), but if a refactor ever bypassed
        // clustering, this test documents that totalPresenceSecs would
        // double-count the overlap. Encoded deliberately — see file header.
        let result = pfVideoResult(
            filename: "ovl.mov", filePath: "/tmp/ovl.mov",
            durationSeconds: 30, fps: 30, totalHits: 8,
            segments: [
                pfSegment(startSecs: 0, endSecs: 4, bestDistance: 0.2, avgDistance: 0.3),
                pfSegment(startSecs: 2, endSecs: 6, bestDistance: 0.2, avgDistance: 0.3)
            ]
        )
        #expect(abs(result.totalPresenceSecs - 8.0) < eps,
                "property sums durations; it does not union overlaps")
    }

    // MARK: - Presence-gate boundary (reachable arithmetic side of the filter)
    //
    // We can't call the private filterByPresence, but we CAN pin the exact
    // arithmetic comparison it performs against the default 5s threshold,
    // so the keep/skip boundary is regression-protected at the property
    // level. The filter uses `totalPresenceSecs >= minSecs`.

    @Test func presenceAtExactlyFiveSecondsMeetsDefaultThreshold() {
        let minSecs = PersonFinderSettings().minPresenceSecs   // 5.0 by default
        #expect(minSecs == 5.0, "precondition: default min presence is 5s")
        let result = pfVideoResult(
            filename: "edge.mov", filePath: "/tmp/edge.mov",
            durationSeconds: 30, fps: 30, totalHits: 3,
            segments: [pfSegment(startSecs: 0, endSecs: 5, bestDistance: 0.2, avgDistance: 0.3)]
        )
        // Mirrors filterByPresence's `>= minSecs` (inclusive) keep test.
        #expect(result.totalPresenceSecs >= minSecs,
                "exactly 5s presence must be KEPT under the inclusive >= gate")
    }

    @Test func presenceJustUnderFiveSecondsFailsDefaultThreshold() {
        let minSecs = PersonFinderSettings().minPresenceSecs
        let result = pfVideoResult(
            filename: "under.mov", filePath: "/tmp/under.mov",
            durationSeconds: 30, fps: 30, totalHits: 2,
            segments: [pfSegment(startSecs: 0, endSecs: 4.9, bestDistance: 0.2, avgDistance: 0.3)]
        )
        #expect(!(result.totalPresenceSecs >= minSecs),
                "4.9s presence must be SKIPPED under the 5s gate")
    }
}
