// PreviewFrameScorerTests.swift
// LOGIC + SCALE dimensions for the content-aware best-frame scorer
// (perf/preview-disk-cache commit 2, 2026-07-26).
//
// The scorer is pure (CGImage in, FrameScore out) so everything here
// runs on synthetic images from PreviewTestImageSupport — no media, no
// I/O, deterministic seeds.
//
// IMPORTANT FINDING (2026-07-26, testing agent): the file-header claim
// in PreviewFrameScorer.swift that analog static "scores near-solid LOW
// just like blue leader and black" is FALSE as implemented. Measured on
// the replicated algorithm and confirmed against the real one below:
//
//     input (480x270, the real ripped-frame size)   combined
//     solid blue / solid black                      0.000
//     grayscale static (VHS snow)                   ~0.059
//     RGB static                                    ~0.060
//     two-tone scene                                ~0.260
//     nearSolidThreshold                            0.010
//
// The downsample low-pass DOES attenuate the noise variance hard
// (per-pixel stddev ~74 → luma stddev ~8–16 after the 64×64 draw), but
// the dominantColorFraction term stays LOW for noise (~0.07–0.40 —
// averaged colors straddle several 16-level buckets around mid-gray),
// so `combined` lands ~6× ABOVE the threshold. Static is therefore
// treated as "content", not leader. Behavioral blast radius today is
// small (chooseIndex picks the max score, and real scenes outscore
// static ~4×), but the header's calibration table also claims a murky
// scene scores ~0.08 — grayscale static at 320×240 measures 0.084, so
// a static frame CAN outrank a genuinely murky scene on low-res
// sources. Reported to Manager; the withKnownIssue test below pins the
// divergence and will flip when the calibration is fixed.

import Testing
import Foundation
import CoreGraphics
@testable import VideoScan

@Suite("PreviewFrameScorer")
struct PreviewFrameScorerTests {

    // MARK: - Near-solid detection (LOGIC)

    @Test("solid blue scores near-solid with ~0 stddev and ~1 dominance")
    func solidBlueIsNearSolid() throws {
        let score = try #require(PreviewFrameScorer.score(
            PreviewTestImages.solid(red: 0, green: 0, blue: 1)))
        #expect(score.combined <= PreviewFrameScorer.nearSolidThreshold)
        // Component pins — each signal must independently say "solid".
        #expect(score.lumaStdDev < 1.0,
                "solid frame luma stddev should be ~0, got \(score.lumaStdDev)")
        #expect(score.dominantColorFraction > 0.95,
                "solid frame should be one color bucket, got \(score.dominantColorFraction)")
    }

    @Test("solid black scores near-solid")
    func solidBlackIsNearSolid() throws {
        let score = try #require(PreviewFrameScorer.score(
            PreviewTestImages.solid(red: 0, green: 0, blue: 0)))
        #expect(score.combined <= PreviewFrameScorer.nearSolidThreshold)
        #expect(score.lumaStdDev < 1.0)
        #expect(score.dominantColorFraction > 0.95)
    }

    // MARK: - Scene detection (LOGIC)

    @Test("two-tone scene clears the near-solid threshold decisively")
    func twoToneClearsThreshold() throws {
        let score = try #require(PreviewFrameScorer.score(PreviewTestImages.twoTone()))
        // Decisively: an order of magnitude, not a squeak — if this
        // margin collapses, the threshold calibration has drifted.
        #expect(score.combined > PreviewFrameScorer.nearSolidThreshold * 10,
                "a real two-tone scene scored \(score.combined) — threshold margin collapsed")
    }

    @Test("smooth gradient (structure without edges) clears the threshold")
    func gradientClearsThreshold() throws {
        let score = try #require(PreviewFrameScorer.score(PreviewTestImages.gradient()))
        #expect(score.combined > PreviewFrameScorer.nearSolidThreshold * 10)
    }

    // MARK: - Analog static (LOGIC — the load-bearing design claim)

    @Test("downsample low-pass attenuates static's variance (the mechanism works)")
    func downsampleAttenuatesStatic() throws {
        // Raw per-pixel stddev of uniform noise is ~74; after the 64×64
        // area-averaging draw the luma stddev must collapse by ~5×.
        // This is the half of the header claim that IS true — pin it so
        // nobody "fixes" the scorer by switching interpolation to .none
        // (which would let static keep full variance and rank as the
        // most detailed frame in the file).
        let gray = try #require(PreviewFrameScorer.score(
            PreviewTestImages.grayNoise(seed: 7)))
        let rgb = try #require(PreviewFrameScorer.score(
            PreviewTestImages.rgbNoise(seed: 7)))
        #expect(gray.lumaStdDev < 25,
                "gray static stddev \(gray.lumaStdDev) — the low-pass has stopped averaging")
        #expect(rgb.lumaStdDev < 25,
                "rgb static stddev \(rgb.lumaStdDev) — the low-pass has stopped averaging")
    }

    @Test("KNOWN ISSUE: static does NOT score near-solid as the design claims")
    func staticNearSolidClaimIsCurrentlyFalse() throws {
        // PreviewFrameScorer.swift's header claims static "scores
        // near-solid LOW just like blue leader and black". Measured:
        // combined ≈ 0.06 at 480×270 — 6× ABOVE the 0.01 threshold,
        // because dominantColorFraction stays low for averaged noise.
        // withKnownIssue = expected-failure marker (like GTest's
        // DISABLED_ prefix, but it FAILS the build the day the issue
        // stops reproducing — forcing this pin to be promoted to a real
        // assertion when the calibration is fixed).
        withKnownIssue("scorer calibration: static clears nearSolidThreshold — reported to Manager 2026-07-26") {
            let gray = try #require(PreviewFrameScorer.score(
                PreviewTestImages.grayNoise(seed: 42)))
            #expect(gray.combined <= PreviewFrameScorer.nearSolidThreshold,
                    "gray static combined \(gray.combined) vs threshold \(PreviewFrameScorer.nearSolidThreshold)")
        }
    }

    @Test("static still ranks strictly below a real scene (what chooseIndex relies on)")
    func staticRanksBelowRealScene() throws {
        // The behaviorally load-bearing property TODAY: even though
        // static clears the threshold (known issue above), it must
        // never outrank actual content, or the best-frame pick degrades
        // to "the frame with the most snow".
        let statics = try #require(PreviewFrameScorer.score(
            PreviewTestImages.grayNoise(seed: 99)))
        let scene = try #require(PreviewFrameScorer.score(PreviewTestImages.twoTone()))
        let grad = try #require(PreviewFrameScorer.score(PreviewTestImages.gradient()))
        #expect(statics.combined < scene.combined)
        #expect(statics.combined < grad.combined)
    }

    // MARK: - FrameScore arithmetic (LOGIC)

    @Test("combined = clamped(stddev/128) × (1 − dominance)")
    func combinedFormulaPinned() {
        // Direct construction — no image needed; pins the formula so a
        // refactor can't silently reweight the two signals.
        let mid = PreviewFrameScorer.FrameScore(lumaStdDev: 64,
                                                dominantColorFraction: 0.5)
        #expect(abs(mid.combined - 0.25) < 1e-12)

        // stddev term clamps at 1.0 (a stddev of 200 is not "more than
        // fully contrasty").
        let clamped = PreviewFrameScorer.FrameScore(lumaStdDev: 300,
                                                    dominantColorFraction: 0)
        #expect(clamped.combined == 1.0)

        // Full dominance zeroes the score regardless of contrast —
        // the multiplicative gate the header documents.
        let dominated = PreviewFrameScorer.FrameScore(lumaStdDev: 127,
                                                      dominantColorFraction: 1.0)
        #expect(dominated.combined == 0.0)
    }

    // MARK: - Time budget (SCALE)

    @Test("scoring 1920x1080 frames stays well inside the 50 ms budget", .timeLimit(.minutes(1)))
    func scoreTimeBudget() throws {
        // Distinct images so CoreGraphics' internal same-image draw
        // cache can't hide the real per-frame cost of the first score
        // (which is what the background pass actually pays).
        let images = (0..<8).map {
            PreviewTestImages.rgbNoise(seed: UInt64(1000 + $0), width: 1920, height: 1080)
        }
        let clock = ContinuousClock()
        for image in images {
            let start = clock.now
            _ = try #require(PreviewFrameScorer.score(image))
            let elapsed = clock.now - start
            #expect(elapsed < .milliseconds(50),
                    "cold score of a 1080p frame took \(elapsed) — budget is 50 ms")
        }

        // 100 warm iterations bounded — a pathological O(pixels²)
        // regression trips this even with CG caching in play.
        let start = clock.now
        for i in 0..<100 {
            _ = PreviewFrameScorer.score(images[i % images.count])
        }
        let total = clock.now - start
        #expect(total < .seconds(5),
                "100 scores took \(total) — scoring cost has regressed")
    }
}
