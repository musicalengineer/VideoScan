// PreviewFilmstripPlanTests.swift
// LOGIC dimension for the filmstrip preview's pure planning half
// (feature/filmstrip-preview commit 098e100, 2026-07-27).
//
// Two pure surfaces in PreviewFilmstripPlan:
//
//   1. offsets(durationSeconds:frameCount:) — which timestamps to rip.
//      The guard rails here are the same SIGTRAP class as
//      PreviewBestFramePlan.isPlannable: `Int((x * 10).rounded())` in
//      the dedupe TRAPS on non-finite input, so a poisoned catalog
//      duration reaching this function unguarded would crash the
//      prewarm (the verified 2026-07-26 incident). Every hostile
//      duration is pinned to return [].
//
//   2. selectFrames(scores:threshold:) — which ripped frames survive
//      near-solid dropping, including the keep-all floor
//      (minimumKeptFrames): a strip of blue leader still tells Rick
//      "this file decodes and is mostly blank", which beats an empty
//      pane.
//
// No I/O, no media — synthetic FrameScore values only.
// (For Rick: `#expect` ≈ gtest's EXPECT_*, `#require` ≈ ASSERT_* —
// #expect continues on failure, #require aborts the test.)

import Testing
import Foundation
@testable import VideoScan

// MARK: - Score fixtures

/// A score comfortably ABOVE nearSolidThreshold (0.01):
/// 64/128 × (1 − 0.25) × 1² = 0.375 — a real scene.
private let contentScore = PreviewFrameScorer.FrameScore(
    lumaStdDev: 64, dominantColorFraction: 0.25, structureRetention: 1.0)

/// A score of exactly 0 — solid blue/black leader.
private let solidScore = PreviewFrameScorer.FrameScore(
    lumaStdDev: 0, dominantColorFraction: 1.0, structureRetention: 0)

@Suite("PreviewFilmstripPlan")
struct PreviewFilmstripPlanTests {

    // MARK: - offsets: the normal case

    @Test("16-frame plan is centered (i+0.5)/16 sampling, strictly increasing, inside (0, duration)")
    func normalSixteenFramePlan() {
        // duration 32 makes the math exact in binary: offset_i = 2i+1.
        let offsets = PreviewFilmstripPlan.offsets(durationSeconds: 32)
        let expected: [Double] = (0..<16).map { Double(2 * $0 + 1) }
        #expect(offsets.count == PreviewFilmstripPlan.defaultFrameCount)
        #expect(offsets == expected, "centered sampling broke: \(offsets)")
        // Never the black t=0 frame, never past the end.
        #expect(offsets.first! > 0)
        #expect(offsets.last! < 32)
        // Strictly increasing (zip trick ≈ std::adjacent_find).
        #expect(zip(offsets, offsets.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test("custom frameCount is honored")
    func customFrameCount() {
        let offsets = PreviewFilmstripPlan.offsets(durationSeconds: 100, frameCount: 4)
        #expect(offsets == [12.5, 37.5, 62.5, 87.5])
    }

    // MARK: - offsets: hostile durations (the SIGTRAP class)

    @Test("hostile durations return [] instead of trapping", arguments: [
        0.0,
        -1.0,
        -.infinity,
        Double.infinity,
        Double.nan,
        PreviewBestFramePlan.maxSaneDurationSeconds + 1,   // absurd-duration guard
        Double.greatestFiniteMagnitude                     // finite but would trap the dedupe
    ])
    func hostileDurationsReturnEmpty(duration: Double) {
        #expect(PreviewFilmstripPlan.offsets(durationSeconds: duration).isEmpty,
                "duration \(duration) must be unplannable")
    }

    @Test("exactly maxSaneDurationSeconds is still plannable (boundary is inclusive)")
    func maxSaneBoundaryInclusive() {
        let offsets = PreviewFilmstripPlan.offsets(
            durationSeconds: PreviewBestFramePlan.maxSaneDurationSeconds)
        #expect(offsets.count == PreviewFilmstripPlan.defaultFrameCount)
    }

    @Test("non-positive frameCount returns []")
    func nonPositiveFrameCount() {
        #expect(PreviewFilmstripPlan.offsets(durationSeconds: 60, frameCount: 0).isEmpty)
        #expect(PreviewFilmstripPlan.offsets(durationSeconds: 60, frameCount: -3).isEmpty)
    }

    // MARK: - offsets: very-short-file dedupe

    @Test("0.5 s duration collapses to deciseconds-deduped, strictly increasing offsets")
    func halfSecondDurationDedupes() {
        // offset_i = (i+0.5)/32; deciseconds keys round(10·offset) hit
        // {0,0,1,1,1,2,2,2,3,3,3,4,4,4,5,5} → 6 survivors (i = 0, 2, 5,
        // 8, 11, 14). Pinning the exact count pins the documented
        // deciseconds granularity — if this fails after a deliberate
        // granularity change, update the comment AND the count together.
        let offsets = PreviewFilmstripPlan.offsets(durationSeconds: 0.5)
        #expect(offsets.count == 6, "deciseconds dedupe changed: \(offsets)")
        #expect(zip(offsets, offsets.dropFirst()).allSatisfy { $0 < $1 },
                "dedupe must leave a strictly increasing plan: \(offsets)")
        #expect(offsets.allSatisfy { $0 > 0 && $0 < 0.5 })
    }

    // MARK: - selectFrames

    @Test("all-content strip keeps every frame in order")
    func allContentKeepsAll() {
        let scores: [PreviewFrameScorer.FrameScore?] = Array(repeating: contentScore, count: 16)
        #expect(PreviewFilmstripPlan.selectFrames(scores: scores) == Array(0..<16))
    }

    @Test("all-solid strip triggers the keep-all floor — a strip of leader beats an empty pane")
    func allSolidKeepsAllViaFloor() {
        let scores: [PreviewFrameScorer.FrameScore?] = Array(repeating: solidScore, count: 16)
        #expect(PreviewFilmstripPlan.selectFrames(scores: scores) == Array(0..<16))
    }

    @Test("exactly minimumKeptFrames−1 survivors still keeps ALL frames")
    func threeSurvivorsKeepsAll() {
        // 3 content frames scattered among solids: 3 < minimumKeptFrames
        // (4) → the floor kicks in and everything comes back.
        var scores: [PreviewFrameScorer.FrameScore?] = Array(repeating: solidScore, count: 16)
        for i in [1, 7, 13] { scores[i] = contentScore }
        #expect(PreviewFilmstripPlan.selectFrames(scores: scores) == Array(0..<16),
                "3 survivors is below the floor of \(PreviewFilmstripPlan.minimumKeptFrames) — must keep all")
    }

    @Test("exactly minimumKeptFrames survivors keeps exactly those, in input order")
    func fourSurvivorsKeepsThoseFour() {
        var scores: [PreviewFrameScorer.FrameScore?] = Array(repeating: solidScore, count: 16)
        for i in [2, 5, 9, 15] { scores[i] = contentScore }
        #expect(PreviewFilmstripPlan.selectFrames(scores: scores) == [2, 5, 9, 15])
    }

    @Test("nil scores (scorer couldn't rasterize) are kept — benefit of the doubt")
    func nilScoresKept() {
        // 4 nils + 1 solid: the nils count as survivors (4 ≥ floor), so
        // ONLY they come back and the solid frame is dropped.
        let scores: [PreviewFrameScorer.FrameScore?] = [nil, solidScore, nil, nil, nil]
        #expect(PreviewFilmstripPlan.selectFrames(scores: scores) == [0, 2, 3, 4])
    }

    @Test("a score exactly AT the threshold is near-solid (content is strictly above)")
    func thresholdIsExclusive() {
        // Same convention as PreviewBestFramePlan.chooseIndex. Build a
        // synthetic threshold so the boundary is exact.
        var scores: [PreviewFrameScorer.FrameScore?] = Array(repeating: contentScore, count: 8)
        scores[0] = solidScore
        // Threshold set exactly at the content score: EVERY frame is now
        // "near-solid" → floor keeps all.
        #expect(PreviewFilmstripPlan.selectFrames(scores: scores,
                                                  threshold: contentScore.combined) == Array(0..<8))
        // Threshold just below: the 7 content frames survive, solid drops.
        #expect(PreviewFilmstripPlan.selectFrames(scores: scores,
                                                  threshold: contentScore.combined - 0.001) == Array(1..<8))
    }

    @Test("empty scores → empty selection (degenerate, no trap)")
    func emptyScores() {
        #expect(PreviewFilmstripPlan.selectFrames(scores: []).isEmpty)
    }
}
