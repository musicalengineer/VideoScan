import Testing
import Foundation
@testable import VideoScan

// MARK: - pfClampNominalFps
//
// Regression sensor for the 2026-06-03 LaCieWorkspace incident:
// DickyTheBoysDadBreen-1985.mp4 (h264, 71s clip) has corrupt
// container metadata where ffprobe / AVFoundation both report
// nominalFrameRate ≈ 60,000 fps (avg_frame_rate computed as
// nb_frames=4,268,265 / duration=71.137744 — nb_frames is wrong by
// ~1000x). With the unclamped raw value, the face-detect frame
// stride becomes settings.frameStep / 60000 ≈ 83µs of content time,
// the loop oversamples ~1000x, and the file wall-clocks at 3h 48m
// instead of seconds.
//
// Cap at 240 fps — high enough to preserve real consumer slo-mo
// (iPhone 240fps), low enough that 60,000 obviously trips the clamp
// and the per-file frame stride stays sane (5/240 = 21ms = 48
// samples/sec of content time, still plenty for face detection).

struct PersonFinderFpsClampTests {

    @Test func clampsBogusHighFps() {
        // The specific bad value Rick's catalog hit on 2026-06-03.
        #expect(pfClampNominalFps(60000.0) == 240.0)
        // r_frame_rate=90000/1 case (h264 90kHz timebase masquerading
        // as fps when avg_frame_rate is missing).
        #expect(pfClampNominalFps(90000.0) == 240.0)
        // Anything well above the consumer slo-mo ceiling.
        #expect(pfClampNominalFps(1000.0) == 240.0)
        // Just above the cap.
        #expect(pfClampNominalFps(240.001) == 240.0)
    }

    @Test func preservesNormalFps() {
        #expect(pfClampNominalFps(24.0) == 24.0)
        #expect(pfClampNominalFps(29.97) == 29.97)
        #expect(pfClampNominalFps(30.0) == 30.0)
        #expect(pfClampNominalFps(50.0) == 50.0)
        #expect(pfClampNominalFps(59.94) == 59.94)
        #expect(pfClampNominalFps(60.0) == 60.0)
        // iPhone 120fps slow-motion.
        #expect(pfClampNominalFps(120.0) == 120.0)
        // Boundary: iPhone 240fps slow-motion — still consumer real.
        #expect(pfClampNominalFps(240.0) == 240.0)
    }

    @Test func passesZeroAndNegativeThrough() {
        // Upstream `guard duration > 0, fps > 0` catches non-positive
        // fps and skips the file — the clamp doesn't need to second-
        // guess that, just stay neutral.
        #expect(pfClampNominalFps(0.0) == 0.0)
        #expect(pfClampNominalFps(-1.0) == -1.0)
    }
}
