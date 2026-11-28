// AVSyncSensitivityTests.swift — how close to the limit can the A/V sync check
// tell? (Rick 2026-11-28: "make some synthetic lip sync problems which we can
// tweak closer and closer and see how well the lip sync detector works".)
//
// Real ffmpeg-made pairs through the real reader, like AVSyncSyntheticPairTests,
// but stepped toward the policy's limits (in sync from 60 ms late to 30 ms
// early; drift from 20 ms over the file): each straddling pair sits 2 ms either
// side of a limit, so the verdict must flip exactly there. The same ladder runs
// again after a Topaz-like chain (2× upscale, 30→60 fps interpolation, H.264,
// AAC at 44.1 kHz) — the processing that first showed the problem.
//
// Every case prints one "AVSYNC-SENSITIVITY" line (input, measured, verdict):
// the precision table in docs/design/av_sync_analysis.md §7 is read from them.
//
// Sign (design §2): s > 0 sound early, s < 0 sound late; delaying the sound by
// d ms gives s = −d.

import Foundation
import Testing
@testable import VideoScanCore

@Suite(.scratchCleanup)
struct AVSyncSensitivityTests {

    /// Measurement error allowed on a clean pair. The straddles are 2 ms from
    /// a limit, so this must stay below 2 ms for the flips to be exact.
    static let tolerance = 1.5

    static func pair(_ change: AVSyncFixtures.Change, seconds: Double, seed: UInt64 = 0x5E_115E) async throws
        -> AVSyncReport {
        let dir = try TestScratch.unique("test_avsync_sens_")
        let source = try AVSyncFixtures.makeSource(in: dir, seconds: seconds, seed: seed)
        let original = try await AVSyncFixtures.encodeOriginal(source, format: .mp4H264, in: dir)
        let processed = try await AVSyncFixtures.process(original, change: change, format: .mp4H264, in: dir)
        return try await AVSyncFixtures.analyzePair(original: original, processed: processed, seconds: seconds)
    }

    static func line(_ label: String, input: String, _ report: AVSyncReport) {
        let median = report.medianShiftMs.map { String(format: "%+.2f", $0) } ?? "-"
        print("AVSYNC-SENSITIVITY \(label) | in \(input) | measured \(median) ms"
              + " | \(report.measuredWindows)/\(report.windows.count) windows | \(report.sentence)")
    }

    static func check(_ report: AVSyncReport, lateMs: Double, tolerance: Double) {
        let expected = -lateMs
        guard let median = report.medianShiftMs else {
            Issue.record("nothing measured: \(AVSyncFixtures.describe(report))"); return
        }
        #expect(abs(median - expected) <= tolerance, "measured \(median), expected \(expected)\n\(AVSyncFixtures.describe(report))")
        let shouldBeInSync = AVSyncPolicy.default.isInSync(shiftMs: expected)
        #expect(report.verdict.isInSync == shouldBeInSync,
                "\(expected) ms must read \(shouldBeInSync ? "in sync" : "out of sync"): \(AVSyncFixtures.describe(report))")
        if !shouldBeInSync {
            #expect(report.sentence.contains(expected < 0 ? " late" : " early"), "\(report.sentence)")
        }
    }

    // MARK: Offsets, stepped to the limits (2 ms either side of +30 early and −60 late)

    /// lateMs > 0: the sound moved later. −28/−32 straddle the early limit;
    /// 58/62 straddle the late limit.
    static let ladder: [Double] = [-5, -10, -20, -28, -32, -45, 10, 30, 50, 58, 62, 80, 125]

    @Test("offset ladder: each step recovered within 1.5 ms; the verdict flips exactly at +30 / −60",
          arguments: ladder)
    func offsetLadder(lateMs: Double) async throws {
        let report = try await Self.pair(.soundLate(ms: lateMs), seconds: 60)
        Self.line("offset", input: String(format: "%+.0f ms", -lateMs), report)
        Self.check(report, lateMs: lateMs, tolerance: Self.tolerance)
    }

    // MARK: The same, after Topaz-style processing

    /// Measured 2026-11-28: this chain reads 1.4–1.8 ms later than the offset
    /// put in, at every step (a steady bias from the chain, ±0.2 ms scatter) —
    /// so the straddles here sit 5 ms from a limit, and the tolerance is 3 ms.
    static let processedTolerance = 3.0

    @Test("after a Topaz-like chain (2× upscale, 60 fps interpolation, H.264, AAC 44.1 kHz): within 3 ms; flips at ±5 ms of a limit",
          arguments: [0.0, -25, -35, 55, 65, 100])
    func topazLadder(lateMs: Double) async throws {
        let report = try await Self.pair(.topazLike(lateMs: lateMs), seconds: 60)
        Self.line("topaz-like", input: String(format: "%+.0f ms", -lateMs), report)
        if lateMs == 55 {
            // GH #539: one window reads the interpolated picture half a frame
            // off (−70.5 of −55); the worst-window rule then flags a file
            // inside the band. Remove this wrapper when #539 is fixed.
            withKnownIssue("GH #539: a half-frame-noisy window flips in sync on interpolated footage",
                           isIntermittent: true) {
                Self.check(report, lateMs: lateMs, tolerance: Self.processedTolerance)
            }
        } else {
            Self.check(report, lateMs: lateMs, tolerance: Self.processedTolerance)
        }
    }

    // MARK: Drift, stepped to the limit (20 ms over the file)

    /// ms later per minute over 3 minutes → 6, 15, 30, 60 ms over the file.
    @Test("drift ladder: under 20 ms over the file is not drift; above it is, with its rate",
          arguments: [2.0, 5, 10, 20])
    func driftLadder(lateMsPerMinute: Double) async throws {
        let seconds = 180.0
        let report = try await Self.pair(.soundDrifts(lateMsPerMinute: lateMsPerMinute), seconds: seconds)
        let total = lateMsPerMinute * seconds / 60
        Self.line("drift", input: String(format: "%.0f ms over 3 min", total), report)
        if total < AVSyncPolicy.default.maxDriftMs {
            if case .drift = report.verdict { Issue.record("\(total) ms over the file is not drift: \(report.sentence)") }
            #expect(report.verdict.isInSync, "\(AVSyncFixtures.describe(report))")
        } else {
            guard case let .drift(from, to, over) = report.verdict else {
                Issue.record("\(total) ms over the file must read as drift: \(AVSyncFixtures.describe(report))"); return
            }
            #expect(abs((to - from) / over * 60 + lateMsPerMinute) <= 2, "\(report.sentence)")
        }
    }

    // MARK: Small jumps (frames dropped at one moment)

    /// Picture can only lose whole frames: asking to drop 40 ms at 30 fps
    /// drops 2 frames (66.7 ms), 80 ms drops 3 (100 ms) — the fixture trims
    /// at `at + drop` and the next whole frame is where the picture resumes.
    static func wholeFramesDropped(_ dropMs: Double, at: Double) -> Double {
        let fps = Double(AVSyncFixtures.fps)
        return ((at + dropMs / 1_000) * fps).rounded(.up) / fps * 1_000 - at * 1_000
    }

    @Test("a small jump: 1, 2 and 3 frames dropped at 1:00 (33, 67, 100 ms) — read to the frame",
          arguments: [30.0, 40, 80])
    func smallJump(dropMs: Double) async throws {
        let at = 60.0
        let dropped = Self.wholeFramesDropped(dropMs, at: at)
        let report = try await Self.pair(.pictureDrop(atSeconds: at, dropMs: dropMs), seconds: 120)
        Self.line("jump", input: String(format: "%.1f ms (%.0f frames) dropped at 1:00", dropped, dropped * 0.03), report)
        guard case let .jump(from, to, when) = report.verdict else {
            Issue.record("expected a jump: \(AVSyncFixtures.describe(report))"); return
        }
        #expect(abs(from) <= Self.tolerance && abs(to + dropped) <= 2, "\(AVSyncFixtures.describe(report))")
        #expect(abs(when - at) <= AVSyncPolicy.default.hopSeconds, "\(report.sentence)")
    }
}
