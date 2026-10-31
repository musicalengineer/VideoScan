// ModelLabSamplerTests.swift — the Sampler port (video_llm_lab §3.2, §6).
// Dimensions:
//   LOGIC — StillsSampler equals the app's framesEvenlySpaced for three
//           durations (pinned as literal values computed from the app's
//           formula, so a drift on either side shows); WindowSampler plans
//           cover the file, never overlap, snap to scene cuts, leave a short
//           last window, and give a sane plan for zero-length and one-frame
//           files.
//   SCALE — see ModelLabScaleTests (100k files × 450 h).

import Foundation
import Testing
@testable import VideoScanCore

@Suite("ModelLab — StillsSampler (A0 parity)")
struct ModelLabStillsSamplerTests {

    /// The literal output of the app's `framesEvenlySpaced` (CaptionOrchestrator.swift)
    /// for n = 8 at 3 s, 61.7 s and 3600 s, and n = 1 at 10 s. If the app's
    /// spacing changes, this table and StillsSampler change together.
    @Test("frame times equal the app's framesEvenlySpaced for 3 s, 61.7 s, 3600 s and the n = 1 case")
    func matchesAppSpacing() {
        let cases: [(Int, Double, [Double])] = [
            (8, 3.0, [0.15000000000000002, 0.5357142857142857, 0.9214285714285714, 1.307142857142857,
                      1.6928571428571426, 2.0785714285714283, 2.464285714285714, 2.8499999999999996]),
            (8, 61.7, [3.0850000000000004, 11.017857142857144, 18.950714285714287, 26.88357142857143,
                       34.816428571428574, 42.74928571428572, 50.68214285714286, 58.615]),
            (8, 3600.0, [180.0, 642.8571428571429, 1105.7142857142858, 1568.5714285714284,
                         2031.4285714285713, 2494.285714285714, 2957.142857142857, 3420.0]),
            (1, 10.0, [5.0]),
        ]
        for (n, duration, expected) in cases {
            let plan = StillsSampler(n).plan(for: .init(durationS: duration, fps: 29.97, hasAudio: true))
            #expect(plan.windows.count == 1, "stills are one window over the whole file (\(duration) s)")
            #expect(plan.windows.first?.frameTimesS == expected, "n=\(n) d=\(duration)")
            #expect(plan.windows.first?.startS == 0 && plan.windows.first?.endS == duration)
            #expect(plan.windows.first?.audioRange == nil, "stills carry no audio")
        }
        #expect(StillsSampler(8).id == "stills-8")
    }

    @Test("zero duration, negative duration and n = 0 give an empty plan, never a crash")
    func degenerateInputs() {
        #expect(StillsSampler(8).plan(for: .init(durationS: 0, fps: 30, hasAudio: false)).windows.isEmpty)
        #expect(StillsSampler(8).plan(for: .init(durationS: -1, fps: 30, hasAudio: false)).windows.isEmpty)
        #expect(StillsSampler(0).plan(for: .init(durationS: 10, fps: 30, hasAudio: false)).windows.isEmpty)
        #expect(StillsSampler(8).plan(for: .init(durationS: .nan, fps: 30, hasAudio: false)).windows.isEmpty)
    }

    @Test("the app's 0.1 s floor is mirrored: a 0.05 s clip asks for frames up to 0.095 s and the window says so")
    func subTenthSecondFloorMirrored() {
        let plan = StillsSampler(3).plan(for: .init(durationS: 0.05, fps: 30, hasAudio: false))
        #expect(plan.windows.first?.frameTimesS == [0.005000000000000001, 0.05, 0.095])
        #expect(plan.windows.first?.endS == 0.095, "the window is widened to hold the last frame it asks for")
    }
}

@Suite("ModelLab — WindowSampler (chronological windows)")
struct ModelLabWindowSamplerTests {

    /// `tolerance` is the scene-cut snap distance: a snapped window may run
    /// up to `seconds + tolerance` (and so hold that many more frames).
    private func checkInvariants(_ plan: SamplePlan, duration: Double, seconds: Double, fps: Double, tolerance: Double = 0,
                                 sourceLocation: SourceLocation = #_sourceLocation) {
        guard let first = plan.windows.first, let last = plan.windows.last else {
            Issue.record("empty plan for \(duration) s", sourceLocation: sourceLocation); return
        }
        #expect(first.startS == 0, sourceLocation: sourceLocation)
        #expect(last.endS == duration, "the plan covers the file to its end", sourceLocation: sourceLocation)
        for (a, b) in zip(plan.windows, plan.windows.dropFirst()) {
            #expect(b.startS == a.endS, "consecutive and contiguous", sourceLocation: sourceLocation)
            #expect(b.startS >= a.endS, "never overlap", sourceLocation: sourceLocation)
        }
        for w in plan.windows {
            #expect(w.endS > w.startS, "no empty window", sourceLocation: sourceLocation)
            #expect(w.endS - w.startS <= seconds + tolerance + 1e-9 || w == last, "no window longer than its budget plus the snap tolerance", sourceLocation: sourceLocation)
            #expect(!w.frameTimesS.isEmpty, "every window shows at least one frame", sourceLocation: sourceLocation)
            #expect(w.frameTimesS == w.frameTimesS.sorted(), "frame times in order", sourceLocation: sourceLocation)
            #expect(w.frameTimesS.allSatisfy { $0 >= w.startS && $0 < w.endS }, "frames inside [start, end)", sourceLocation: sourceLocation)
            #expect(w.frameTimesS.count <= Int(((seconds + tolerance) * fps).rounded(.up)) + 1, sourceLocation: sourceLocation)
        }
    }

    @Test("60 s @ 1 fps over a 10-minute file: 10 windows of 60 frames, covering, contiguous, audio range = window")
    func evenFile() {
        let sampler = WindowSampler(seconds: 60, fps: 1, cutAt: .exactSeconds)
        let plan = sampler.plan(for: .init(durationS: 600, fps: 29.97, hasAudio: true))
        checkInvariants(plan, duration: 600, seconds: 60, fps: 1)
        #expect(plan.windows.count == 10)
        #expect(plan.windows.allSatisfy { $0.frameTimesS.count == 60 })
        #expect(plan.windows[3].audioRange == 180.0...240.0)
        #expect(plan.frameCount == 600)
        #expect(sampler.id == "window-60s-1fps")
    }

    @Test("a short last window: 150 s at 60 s windows is 60 + 60 + 30")
    func shortLastWindow() {
        let plan = WindowSampler(seconds: 60, fps: 1, cutAt: .exactSeconds).plan(for: .init(durationS: 150, fps: 25, hasAudio: false))
        checkInvariants(plan, duration: 150, seconds: 60, fps: 1)
        #expect(plan.windows.map { $0.endS - $0.startS } == [60, 60, 30])
        #expect(plan.windows.allSatisfy { $0.audioRange == nil }, "no audio in the file, none in the plan")
    }

    @Test("boundaries snap to a scene cut within the tolerance; a cut outside it is ignored; the next window starts at the cut")
    func snapsToSceneCuts() {
        let sampler = WindowSampler(seconds: 60, fps: 1, cutAt: .sceneCuts(withinS: 15))
        // Cuts: 57.5 (inside tolerance of 60) · 100 (not near 120 → ignored) · 172 (inside tolerance of 177.5) · 290 (outside).
        let plan = sampler.plan(for: .init(durationS: 300, fps: 30, hasAudio: true, sceneCutsS: [57.5, 100, 172, 290]))
        checkInvariants(plan, duration: 300, seconds: 60, fps: 1, tolerance: 15)
        #expect(plan.windows.map(\.endS) == [57.5, 117.5, 172, 232, 290, 300])
        #expect(sampler.id == "window-60s-1fps-scenecut")
    }

    @Test("the nearest cut to the nominal boundary wins when two are inside the tolerance")
    func nearestCutWins() {
        let plan = WindowSampler(seconds: 60, fps: 1, cutAt: .sceneCuts(withinS: 20)).plan(
            for: .init(durationS: 120, fps: 30, hasAudio: false, sceneCutsS: [45, 66]))
        #expect(plan.windows.first?.endS == 66)
    }

    @Test("unsorted, duplicate, out-of-range and non-finite cuts are ignored, never trusted")
    func cutsAreSanitized() {
        let plan = WindowSampler(seconds: 60, fps: 1, cutAt: .sceneCuts(withinS: 15)).plan(
            for: .init(durationS: 120, fps: 30, hasAudio: false, sceneCutsS: [500, .nan, -3, 0, 70, 70, .infinity, 120]))
        checkInvariants(plan, duration: 120, seconds: 60, fps: 1, tolerance: 15)
        #expect(plan.windows.map(\.endS) == [70, 120])
    }

    @Test("zero-length file → empty plan; a one-frame file (1/30 s) → one window, one frame at 0")
    func zeroAndOneFrame() {
        let sampler = WindowSampler(seconds: 60, fps: 1, cutAt: .sceneCuts(withinS: 15))
        #expect(sampler.plan(for: .init(durationS: 0, fps: 30, hasAudio: true)).windows.isEmpty)
        #expect(sampler.plan(for: .init(durationS: -5, fps: 30, hasAudio: true)).windows.isEmpty)
        #expect(sampler.plan(for: .init(durationS: .infinity, fps: 30, hasAudio: true)).windows.isEmpty)
        let one = sampler.plan(for: .init(durationS: 1.0 / 30.0, fps: 30, hasAudio: true))
        #expect(one.windows.count == 1)
        #expect(one.windows.first?.frameTimesS == [0])
        #expect(one.windows.first?.endS == 1.0 / 30.0)
        checkInvariants(one, duration: 1.0 / 30.0, seconds: 60, fps: 1)
    }

    @Test("a window shorter than one frame interval still shows its first frame; fps ≤ 0 or seconds ≤ 0 are clamped, not a crash")
    func degenerateParameters() {
        let tiny = WindowSampler(seconds: 60, fps: 0.1, cutAt: .exactSeconds).plan(for: .init(durationS: 65, fps: 30, hasAudio: false))
        #expect(tiny.windows.map(\.frameTimesS) == [[0, 10, 20, 30, 40, 50], [60]])
        let clamped = WindowSampler(seconds: 0, fps: -1, cutAt: .exactSeconds)
        #expect(clamped.seconds > 0 && clamped.fps > 0)
        let plan = clamped.plan(for: .init(durationS: 2.5, fps: 30, hasAudio: false))
        checkInvariants(plan, duration: 2.5, seconds: clamped.seconds, fps: clamped.fps)
    }

    @Test("a 4-hour tape at 60 s @ 1 fps is 240 windows and 14,400 frame times — the plan's worst case is ~115 KB of doubles")
    func fourHourTape() {
        let plan = WindowSampler(seconds: 60, fps: 1, cutAt: .exactSeconds).plan(for: .init(durationS: 14_400, fps: 29.97, hasAudio: true))
        checkInvariants(plan, duration: 14_400, seconds: 60, fps: 1)
        #expect(plan.windows.count == 240)
        #expect(plan.frameCount == 14_400)
    }
}
