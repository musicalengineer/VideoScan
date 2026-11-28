// AVSyncSyntheticPairTests.swift — synthetic truth for the A/V sync check
// (docs/design/av_sync_analysis.md §7): pairs made from ONE source with ffmpeg,
// each with one known change, read through the real reader (ffmpeg) and
// analysed. Tolerances, from the design: offset ±5 ms, drift ±10 ms/min,
// jump time ±1 window (10 s); an unchanged re-encode says "in sync".
//
// Sign (design §2): s > 0 sound early, s < 0 sound late. Delaying the sound
// by d ms makes s = −d ("d ms late").

import Foundation
import Testing
@testable import VideoScanCore

@Suite(.scratchCleanup)
struct AVSyncSyntheticPairTests {

    static let seconds = 90.0

    static func pair(_ change: AVSyncFixtures.Change, format: AVSyncFixtures.Format = .mp4H264,
                     seconds: Double = AVSyncSyntheticPairTests.seconds,
                     seed: UInt64 = 0xA5_5EED) async throws -> AVSyncReport {
        let dir = try TestScratch.unique("test_avsync_pair_")
        let source = try AVSyncFixtures.makeSource(in: dir, seconds: seconds, seed: seed)
        let original = try await AVSyncFixtures.encodeOriginal(source, format: format, in: dir)
        let processed = try await AVSyncFixtures.process(original, change: change, format: format, in: dir)
        return try await AVSyncFixtures.measure(original: original, processed: processed, seconds: seconds)
    }

    // MARK: Constant offsets −200…+200 ms (±5 ms)

    @Test("a constant sound offset is recovered within ±5 ms, said early or late",
          arguments: [-200.0, -100.0, -40.0, 40.0, 80.0, 100.0, 200.0])
    func constantOffset(lateMs: Double) async throws {
        let report = try await Self.pair(.soundLate(ms: lateMs))
        let expected = -lateMs
        AVSyncFixtures.note("offset sound \(Int(lateMs)) ms later", expected: "\(Int(expected)) ms", report: report)
        let median = try #require(report.medianShiftMs, "\(AVSyncFixtures.describe(report))")
        #expect(abs(median - expected) <= 5, "\(AVSyncFixtures.describe(report))")
        #expect(report.measuredWindows >= 6, "\(AVSyncFixtures.describe(report))")
        if AVSyncPolicy.default.isInSync(shiftMs: expected) {
            #expect(report.verdict.isInSync, "\(AVSyncFixtures.describe(report))")
        } else {
            guard case let .offset(shift) = report.verdict else {
                Issue.record("expected an offset: \(AVSyncFixtures.describe(report))")
                return
            }
            #expect(abs(shift - expected) <= 5)
            let word = expected < 0 ? "late" : "early"
            #expect(report.sentence.hasPrefix("sound ") && report.sentence.contains(" ms \(word) against the picture"),
                    "\(report.sentence)")
            #expect(report.sentence.hasSuffix(", the same through the whole file"))
        }
    }

    @Test("an unchanged re-encode says in sync, within 5 ms")
    func unchangedReencode() async throws {
        let report = try await Self.pair(.lowQualityReencode)
        AVSyncFixtures.note("re-encode (H.264 crf 35, AAC 64k)", expected: "0 ms, in sync", report: report)
        #expect(report.verdict.isInSync, "\(AVSyncFixtures.describe(report))")
        #expect(abs(report.medianShiftMs ?? 99) <= 5, "\(AVSyncFixtures.describe(report))")
        #expect(report.sentence.hasPrefix("in sync: sound within "))
    }

    @Test("trimming the same span from sound and picture is harmless (s = 0, coarse finds the trim)")
    func trimBothIsHarmless() async throws {
        let report = try await Self.pair(.trimBoth(seconds: 3))
        AVSyncFixtures.note("both trimmed 3 s", expected: "0 ms, in sync", report: report)
        #expect(report.verdict.isInSync, "\(AVSyncFixtures.describe(report))")
        #expect(abs(report.medianShiftMs ?? 99) <= 5, "\(AVSyncFixtures.describe(report))")
        #expect(abs((report.coarseOffsetSeconds ?? 0) - 3) <= 0.1, "\(AVSyncFixtures.describe(report))")
    }

    // MARK: Drift (±10 ms/min)

    @Test("a steady drift is recovered within ±10 ms per minute and said in words")
    func drift() async throws {
        let rate = 60.0   // ms later per minute → 0…180 ms late over 3 minutes
        let report = try await Self.pair(.soundDrifts(lateMsPerMinute: rate), seconds: 180)
        AVSyncFixtures.note("drift 60 ms/min later", expected: "-60 ms/min", report: report)
        guard case let .drift(from, to, over) = report.verdict else {
            Issue.record("expected drift: \(AVSyncFixtures.describe(report))")
            return
        }
        let measuredRate = (to - from) / over * 60
        #expect(abs(measuredRate - (-rate)) <= 10, "\(AVSyncFixtures.describe(report))")
        #expect(abs(from) <= 15, "\(AVSyncFixtures.describe(report))")
        #expect(report.sentence.hasPrefix("sound drifts from 0 to ") || report.sentence.hasPrefix("sound drifts from "))
        #expect(report.sentence.contains("ms late over 3 minutes"), "\(report.sentence)")
    }

    // MARK: Jump (±1 window)

    @Test("frames dropped at one moment read as a jump at that time, ±1 window")
    func jump() async throws {
        let at = 60.0, drop = 200.0
        let report = try await Self.pair(.pictureDrop(atSeconds: at, dropMs: drop), seconds: 120)
        AVSyncFixtures.note("200 ms of picture dropped at 1:00", expected: "jump 200 ms late at 1:00", report: report)
        guard case let .jump(step, when) = report.verdict else {
            Issue.record("expected a jump: \(AVSyncFixtures.describe(report))")
            return
        }
        #expect(abs(step - (-drop)) <= 10, "\(AVSyncFixtures.describe(report))")
        #expect(abs(when - at) <= AVSyncPolicy.default.hopSeconds, "\(AVSyncFixtures.describe(report))")
        #expect(report.sentence.hasPrefix("sound jumps 200 ms late at 1:0"), "\(report.sentence)")
        #expect(report.sentence.hasSuffix("(frames dropped or added there)"))
    }

    // MARK: Frame-rate change

    @Test("frames duplicated to 60 fps: a sound offset is still recovered (half a frame of slack)")
    func fpsDuplicated() async throws {
        let report = try await Self.pair(.fps60Duplicated)
        AVSyncFixtures.note("frames duplicated 30→60 fps", expected: "0 ms, in sync", report: report)
        // Duplicated frames move each change's centre by up to half an
        // original frame (AVSyncSignals header): 1/60 s ≈ 17 ms / 2.
        #expect(abs(report.medianShiftMs ?? 99) <= 5 + 1_000.0 / 60, "\(AVSyncFixtures.describe(report))")
        #expect(report.verdict.isInSync, "\(AVSyncFixtures.describe(report))")
    }

    @Test("frames interpolated to 60 fps (the Topaz case): in sync within 5 ms")
    func fpsInterpolated() async throws {
        let report = try await Self.pair(.fps60Interpolated)
        AVSyncFixtures.note("frames interpolated 30→60 fps", expected: "0 ms, in sync", report: report)
        #expect(abs(report.medianShiftMs ?? 99) <= 5, "\(AVSyncFixtures.describe(report))")
        #expect(report.verdict.isInSync, "\(AVSyncFixtures.describe(report))")
    }
}
