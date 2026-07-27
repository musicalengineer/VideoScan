// PreviewBestFramePlanTests.swift
// LOGIC dimension for the best-frame candidate planner
// (perf/preview-disk-cache commit 2, 2026-07-26). Pure functions —
// offsets from the catalog duration, the 25% fallback rule, and the
// winner pick — so every case here is exact and instant.

import Testing
import Foundation
// AVFoundation (not just CoreMedia): the NSValue(time:)/.timeValue
// bridging used by the dedupe pin lives in AVFoundation's NSValue
// additions.
import AVFoundation
@testable import VideoScan

@Suite("PreviewBestFramePlan")
struct PreviewBestFramePlanTests {

    // MARK: - candidateOffsets

    @Test("long file: anchor + 10%/25%/50%, all distinct, order preserved")
    func longFileOffsets() {
        let offsets = PreviewBestFramePlan.candidateOffsets(durationSeconds: 60)
        #expect(offsets == [0.5, 6.0, 15.0, 30.0])
    }

    @Test("5s file: 10% offset collapses into the 0.5s anchor")
    func fiveSecondFileCollapses() {
        // 10% of 5 s = 0.5 s — identical to the anchor at decisecond
        // granularity, so the dedupe must drop it.
        let offsets = PreviewBestFramePlan.candidateOffsets(durationSeconds: 5)
        #expect(offsets == [0.5, 1.25, 2.5])
    }

    @Test("2s file: 25% offset collapses into the anchor, order preserved")
    func twoSecondFileCollapses() {
        // raw = [0.5, 0.2, 0.5, 1.0] → the second 0.5 dedupes; the
        // 10% offset (0.2) keeps its position AFTER the anchor.
        let offsets = PreviewBestFramePlan.candidateOffsets(durationSeconds: 2)
        #expect(offsets == [0.5, 0.2, 1.0])
    }

    @Test("degenerate durations plan a single 0.5s candidate", arguments: [
        0.0, -3.0, 1.9, 0.5, Double.nan
    ])
    func degenerateDurations(duration: Double) {
        // Unknown (0), garbage (negative / NaN — NaN fails the >= guard
        // by IEEE comparison rules), and sub-2s all degenerate to the
        // plain single-frame plan.
        #expect(PreviewBestFramePlan.candidateOffsets(durationSeconds: duration) == [0.5])
    }

    @Test("offset count never exceeds maxCandidates across the duration range")
    func candidateCountAlwaysBounded() {
        // SCALE guardrail: the prewarm multiplies this by every record
        // on a volume — the bound must hold everywhere, including the
        // dedupe boundary region. Sweep 0…3h in 0.1s steps plus a few
        // hostile values.
        var duration = 0.0
        while duration < 10_800 {
            let offsets = PreviewBestFramePlan.candidateOffsets(durationSeconds: duration)
            #expect(offsets.count <= PreviewBestFramePlan.maxCandidates,
                    "duration \(duration) produced \(offsets.count) candidates")
            #expect(!offsets.isEmpty, "duration \(duration) produced an empty plan")
            duration += duration < 30 ? 0.1 : 97.3
        }
        // .infinity and absurd finite durations are covered by
        // garbageDurationsDegrade below — testable since the 2026-07-26
        // fix; pre-fix they SIGTRAPped the test host (see that test).
    }

    @Test("garbage durations degenerate to [0.5] instead of trapping", arguments: [
        Double.infinity, -Double.infinity, 2e18, 1e300,
        PreviewBestFramePlan.maxSaneDurationSeconds + 1
    ])
    func garbageDurationsDegrade(duration: Double) {
        // Regression sensor for the 2026-07-26 🔴: `Int((offset * 10)
        // .rounded())` in the dedupe traps on non-finite doubles AND on
        // finite values past ~1.8e18 (Int.max / 5). Pre-fix, a poisoned
        // catalog durationSeconds crashed the whole prewarm — this test
        // couldn't even be written because the trap killed the test
        // host. The isPlannable guard (finite + ≤ maxSaneDurationSeconds,
        // ~115 days) now routes all of it to the plain single-frame
        // plan. NaN is covered by degenerateDurations above.
        #expect(PreviewBestFramePlan.candidateOffsets(durationSeconds: duration) == [0.5])
        #expect(PreviewBestFramePlan.fallbackOffset(durationSeconds: duration) == 0.5)
    }

    // MARK: - fallbackOffset

    @Test("fallback is 25% in for real durations, 0.5s for degenerate ones")
    func fallbackOffsetRule() {
        #expect(PreviewBestFramePlan.fallbackOffset(durationSeconds: 100) == 25.0)
        #expect(PreviewBestFramePlan.fallbackOffset(durationSeconds: 2) == 0.5)
        #expect(PreviewBestFramePlan.fallbackOffset(durationSeconds: 1.9) == 0.5)
        #expect(PreviewBestFramePlan.fallbackOffset(durationSeconds: 0) == 0.5)
    }

    // MARK: - chooseIndex

    @Test("highest score wins when it clears the threshold")
    func clearWinnerPicked() {
        let index = PreviewBestFramePlan.chooseIndex(
            scores: [0.001, 0.30, 0.20, 0.05],
            offsets: [0.5, 6.0, 15.0, 30.0],
            fallbackOffset: 15.0,
            threshold: 0.01)
        #expect(index == 1)
    }

    @Test("all near-solid: the fallback-offset candidate wins, NOT the max")
    func allNearSolidPicksFallback() {
        // Max is index 1 (0.005) but nothing clears the threshold — the
        // pick must be the candidate at the fallback offset (index 2),
        // proving the fallback path is not just "max with extra steps".
        let index = PreviewBestFramePlan.chooseIndex(
            scores: [0.001, 0.005, 0.002, 0.003],
            offsets: [0.5, 6.0, 15.0, 30.0],
            fallbackOffset: 15.0,
            threshold: 0.01)
        #expect(index == 2)
    }

    @Test("fallback matching tolerates CMTime tick rounding (±0.5s)")
    func fallbackToleranceForTickRounding() {
        // AVF's requestedTime round-trips through 600-tick CMTime, so a
        // planned 15.0 comes back as e.g. 15.3 — must still match.
        let index = PreviewBestFramePlan.chooseIndex(
            scores: [0.001, 0.002, 0.003],
            offsets: [0.52, 6.01, 15.3],
            fallbackOffset: 15.0,
            threshold: 0.01)
        #expect(index == 2)
    }

    @Test("all near-solid and fallback candidate failed to rip: best anyway")
    func fallbackMissingFallsBackToMax() {
        // The 15.0 candidate's rip failed (absent from the arrays) —
        // a decodable file still gets SOME frame: the max score.
        let index = PreviewBestFramePlan.chooseIndex(
            scores: [0.001, 0.005],
            offsets: [0.5, 6.0],
            fallbackOffset: 15.0,
            threshold: 0.01)
        #expect(index == 1)
    }

    @Test("score exactly at threshold does not clear it (strict >)")
    func exactThresholdDoesNotClear() {
        // 0.01 > 0.01 is false → threshold not cleared → fallback path.
        // If someone relaxes > to >=, index 0 wins and this trips.
        let index = PreviewBestFramePlan.chooseIndex(
            scores: [0.01, 0.009],
            offsets: [5.0, 25.0],
            fallbackOffset: 25.0,
            threshold: 0.01)
        #expect(index == 1)
    }

    // MARK: - dedupedCandidateTimes (AVF batch liveness)

    @Test("colliding offsets collapse to one CMTime request, order preserved")
    func candidateTimesDedupeOnTickValue() {
        // The AVF candidate collector counts down one callback per
        // REQUESTED time; a duplicate CMTimeValue that AVF coalesced
        // would leave the countdown short and hang the awaiting
        // continuation forever (QA 🟡, 2026-07-26). The times array is
        // therefore deduped on the quantized tick value and the
        // collector sized from it — pin that here with offsets that
        // are distinct as Doubles but identical at timescale 600.
        let times = VideoScanModel.dedupedCandidateTimes(
            offsets: [0.5, 0.5000001, 2.0, 0.5])
        #expect(times.count == 2)
        #expect(times.map(\.timeValue.value) == [300, 1200],
                "expected 0.5s (300 ticks) then 2.0s (1200 ticks), got \(times.map(\.timeValue.value))")

        // Distinct offsets pass through untouched.
        let distinct = VideoScanModel.dedupedCandidateTimes(offsets: [0.5, 6.0, 15.0, 30.0])
        #expect(distinct.count == 4)
    }

    @Test("zero candidates → nil")
    func emptyIsNil() {
        let index = PreviewBestFramePlan.chooseIndex(
            scores: [], offsets: [], fallbackOffset: 0.5, threshold: 0.01)
        #expect(index == nil)
    }

    @Test("mismatched parallel arrays → nil, never a bad index")
    func mismatchedLengthsAreNil() {
        let index = PreviewBestFramePlan.chooseIndex(
            scores: [0.5, 0.2],
            offsets: [0.5],
            fallbackOffset: 0.5,
            threshold: 0.01)
        #expect(index == nil)
    }
}
