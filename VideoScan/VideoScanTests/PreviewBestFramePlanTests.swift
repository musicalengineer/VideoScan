// PreviewBestFramePlanTests.swift
// LOGIC dimension for the best-frame candidate planner
// (perf/preview-disk-cache commit 2, 2026-07-26). Pure functions —
// offsets from the catalog duration, the 25% fallback rule, and the
// winner pick — so every case here is exact and instant.

import Testing
import Foundation
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
        // NOT tested: durationSeconds = .infinity. It TRAPS (SIGTRAP,
        // verified out-of-process 2026-07-26): `Int((offset * 10)
        // .rounded())` in candidateOffsets is an unchecked Double→Int
        // conversion, and Int(.infinity) crashes rather than throwing.
        // A crashing assertion would take the whole suite down, so the
        // hazard is REPORTED to the Manager instead: garbage catalog
        // duration data (non-finite, or > ~1.8e18 s) crashes the
        // prewarm. Fix shape: guard durationSeconds.isFinite in the
        // top guard alongside the >= check.
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
