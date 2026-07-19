// GauntletFixturePlanTests.swift
//
// Unit coverage for the Gauntlet's pure fixture planning (see
// GauntletFixturePlan.swift). These assert the ffmpeg invocations and the
// match-floor arithmetic the UI flows depend on — so a broken plan fails
// HERE in seconds, not forty minutes into an M1 gauntlet run.
//
// Style: Swift Testing (`@Test` / `#expect`). For Rick (C++): `#expect`
// ≈ EXPECT_TRUE with automatic expression capture — on failure it prints
// the sub-expression values, so no EXPECT_EQ variant is needed.

import Testing
import Foundation
import VideoScanCore

@Suite("GauntletFixturePlan — ffmpeg invocations")
struct GauntletFixturePlanInvocationTests {

    // MARK: faceTimelineVideo

    @Test func fullFaceVideoIsSingleSegment() {
        let inv = GauntletFixturePlan.faceTimelineVideo(
            photoPath: "/tmp/ref.jpg", label: "found",
            faceSeconds: 10, totalSeconds: 10)
        #expect(inv.outputFilename == "test_gauntlet_face_found.mp4")
        #expect(inv.outputFilename.hasPrefix("test_"))   // fixture convention
        // Single-segment: no concat filter, photo is the only input.
        #expect(!inv.arguments.contains("-filter_complex"))
        #expect(inv.arguments.contains("/tmp/ref.jpg"))
        #expect(inv.arguments.contains("libx264"))
        // The -vf chain must normalize to 640x480 yuv420p for Vision.
        let vf = inv.arguments.drop(while: { $0 != "-vf" }).dropFirst().first ?? ""
        #expect(vf.contains("scale=640:480"))
        #expect(vf.contains("format=yuv420p"))
    }

    @Test func briefFaceVideoConcatsPhotoThenPattern() {
        let inv = GauntletFixturePlan.faceTimelineVideo(
            photoPath: "/tmp/ref.jpg", label: "belowfloor",
            faceSeconds: 1, totalSeconds: 20)
        // Two segments: photo (1s) + testsrc (19s), concatenated.
        let filter = inv.arguments.drop(while: { $0 != "-filter_complex" })
            .dropFirst().first ?? ""
        #expect(filter.contains("concat=n=2:v=1:a=0"))
        #expect(inv.arguments.contains(where: { $0.contains("testsrc=duration=19") }))
        // Both segments carry setsar=1 or concat would reject them.
        #expect(filter.components(separatedBy: "setsar=1").count == 3)
    }

    // MARK: catalogClip

    @Test func catalogClipHasVideoAndAudio() {
        let inv = GauntletFixturePlan.catalogClip(label: "beach_1992")
        #expect(inv.outputFilename == "test_gauntlet_beach_1992.mp4")
        #expect(inv.arguments.contains("aac"))
        #expect(inv.arguments.contains("libx264"))
        // Both streams mapped — the catalog colors rows by stream type.
        #expect(inv.arguments.contains("0:v:0"))
        #expect(inv.arguments.contains("1:a:0"))
    }

    // MARK: twoPairDV (the 12-bit DV shape)

    @Test func twoPairDVMatchesCamcorderShape() {
        let inv = GauntletFixturePlan.twoPairDV(
            label: "fixable",
            pair1: GauntletFixturePlan.rightOnlyPair,
            pair2: GauntletFixturePlan.silentPair)
        #expect(inv.outputFilename == "test_gauntlet_2pair_fixable.dv")
        // DVCPRO50 stand-in: dvvideo + yuv422p (the dv muxer rejects
        // consumer 32 kHz PCM — documented in BalanceAudioTestSupport).
        #expect(inv.arguments.contains("dvvideo"))
        #expect(inv.arguments.contains("yuv422p"))
        #expect(inv.arguments.contains("pcm_s16le"))
        // TWO audio inputs mapped — the whole point of the fixture.
        #expect(inv.arguments.filter { $0 == "-map" }.count == 3)
        #expect(inv.arguments.contains(where: { $0.contains("aevalsrc=0|0.5*sin") }))
        #expect(inv.arguments.contains(where: { $0.contains("aevalsrc=0|0:") }))
        // NTSC DV frame rate.
        #expect(inv.arguments.contains(where: { $0.contains("rate=30000/1001") }))
    }

    @Test func trueStereoMovIsDecorrelated() {
        let inv = GauntletFixturePlan.trueStereoMov(label: "refusal")
        #expect(inv.outputFilename == "test_gauntlet_stereo_refusal.mov")
        // Two DIFFERENT tones — that's what makes it true stereo to the
        // classifier rather than dual-mono.
        let aeval = inv.arguments.first(where: { $0.hasPrefix("aevalsrc=") }) ?? ""
        #expect(aeval.contains("440"))
        #expect(aeval.contains("987"))
        #expect(inv.arguments.contains("pcm_s16le"))
    }
}

@Suite("GauntletFixturePlan — match-floor arithmetic")
struct GauntletFixturePlanFloorTests {

    // The production defaults flow 1 runs under: floor 7, frameStep 5,
    // fixtures rendered at 25 fps.
    let fps = 25.0
    let step = 5
    let floor = 7

    @Test func sampledFrameEstimateMatchesAppFormula() {
        // duration * fps / step, floored — the exact matchFloorDecision input.
        #expect(GauntletFixturePlan.estimatedSampledFrames(
            durationSeconds: 20, fps: fps, frameStep: step) == 100)
        #expect(GauntletFixturePlan.estimatedSampledFrames(
            durationSeconds: 1, fps: fps, frameStep: step) == 5)
        // Degenerate inputs never trap (guard against divide-by-zero).
        #expect(GauntletFixturePlan.estimatedSampledFrames(
            durationSeconds: 0, fps: fps, frameStep: step) == 0)
        #expect(GauntletFixturePlan.estimatedSampledFrames(
            durationSeconds: 10, fps: 0, frameStep: step) == 0)
        #expect(GauntletFixturePlan.estimatedSampledFrames(
            durationSeconds: 10, fps: fps, frameStep: 0) == 0)
    }

    @Test func gauntletFoundFixtureClearsTheFloor() {
        // Flow 1's "found" fixture: face for all 10 s → ~50 hits ≥ 7.
        let hits = GauntletFixturePlan.expectedFaceHits(
            faceSeconds: 10, fps: fps, frameStep: step)
        #expect(hits >= floor)
    }

    @Test func gauntletBelowFloorFixtureIsRefusedNotFallback() {
        // Flow 1's "refused" fixture: face for 1 s of 20 s → ~5 hits,
        // sampled ≈ 100 ≥ 7 so the short-clip fallback must NOT engage.
        #expect(GauntletFixturePlan.shouldBeRefusedByFloor(
            faceSeconds: 1, totalSeconds: 20,
            fps: fps, frameStep: step, floor: floor))
    }

    @Test func shortClipDoesNotCountAsRefused() {
        // A clip so short the floor is unreachable engages the app's
        // any-hit fallback — the plan must not claim it will be refused.
        #expect(!GauntletFixturePlan.shouldBeRefusedByFloor(
            faceSeconds: 0.5, totalSeconds: 1,
            fps: fps, frameStep: step, floor: floor))
    }

    @Test func fullPresenceIsNeverRefused() {
        #expect(!GauntletFixturePlan.shouldBeRefusedByFloor(
            faceSeconds: 10, totalSeconds: 10,
            fps: fps, frameStep: step, floor: floor))
    }
}
