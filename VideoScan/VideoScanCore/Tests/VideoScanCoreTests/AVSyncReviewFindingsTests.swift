// AVSyncReviewFindingsTests.swift — the reviewer's findings on
// feat/av-sync-analysis (2026-11-28), each pinned as the test that was red on
// the reviewed code. Judged on hand-built windows (`AVSyncAnalyzer.judge`), so
// each case says exactly which series of per-window shifts it is about.

import Foundation
import Testing
@testable import VideoScanCore

enum AVSyncWindowSeries {
    /// Windows 20 s long every 10 s; `nil` = not measured (no movement).
    static func judged(_ shifts: [Double?], policy: AVSyncPolicy = .default) -> AVSyncReport {
        let windows = shifts.enumerated().map { i, shift -> AVSyncWindow in
            var w = AVSyncWindow(startSeconds: Double(i) * 10, durationSeconds: 20)
            if let shift {
                w.soundLagMs = shift
                w.pictureLagMs = 0
            } else {
                w.notMeasured = .noMovement
            }
            return w
        }
        var report = AVSyncReport(policyIdentity: policy.identity, verdict: .couldNotMeasure(.noSharedSound),
                                  overlapStartSeconds: 0, overlapEndSeconds: Double(shifts.count - 1) * 10 + 20,
                                  windows: windows)
        AVSyncAnalyzer.judge(&report, policy: policy)
        return report
    }
}

struct AVSyncReviewFindingsTests {

    @Test("F1: windows that scatter are not an offset 'the same through the whole file'")
    func scatterIsNotAnOffset() {
        let report = AVSyncWindowSeries.judged([-150, -40, -120, -70, -200, -90, -160, -50, -130, -100, -180, -60])
        #expect(!report.verdict.needsReview, "\(report.sentence)")
        #expect(!report.sentence.contains("the same through the whole file"), "\(report.sentence)")
        #expect(report.sentence.hasPrefix("could not measure: the windows disagree (spread ±"), "\(report.sentence)")
    }

    @Test("F1: windows that agree are still an offset")
    func agreementIsAnOffset() {
        let report = AVSyncWindowSeries.judged([-101, -99, -100, -102, -98, -100, -101, -99])
        #expect(report.sentence == "sound 100 ms late against the picture, the same through the whole file")
    }

    @Test("F2: a jump keeps both levels, each said early or late")
    func jumpWordsKeepTheLevel() {
        let report = AVSyncWindowSeries.judged([Double](repeating: -200, count: 6) + [Double](repeating: -100, count: 6))
        #expect(report.sentence == "sound jumps from 200 to 100 ms late at 1:05 (frames dropped or added there)",
                "\(report.sentence)")
        let crossing = AVSyncWindowSeries.judged([Double](repeating: 40, count: 6) + [Double](repeating: -90, count: 6))
        #expect(crossing.sentence.hasPrefix("sound jumps from 40 ms early to 90 ms late at "), "\(crossing.sentence)")
    }

    @Test("F4: a window set aside as out of line is never called 'could not be measured'")
    func outliersAreNotUnmeasured() {
        let lone = AVSyncWindowSeries.judged([-5, -5, -5, -5, -5, -5, -150, -5, -5, -5, -5, -5])
        #expect(lone.verdict.isInSync, "\(lone.sentence)")
        #expect(!lone.sentence.contains("could not be measured"), "\(lone.sentence)")
        #expect(lone.sentence.hasSuffix("(1 set aside as out of line with the rest)"), "\(lone.sentence)")

        let mixed = AVSyncWindowSeries.judged([0, 0, nil, 0, 0, 0, -150, 0, 0, 0, 0, 0])
        #expect(mixed.sentence.hasSuffix("(1 could not be measured: no movement; 1 set aside as out of line with the rest)"),
                "\(mixed.sentence)")
    }

    @Test("F4: a run of out-of-line windows beyond the band is a local event, never hidden under in sync")
    func localRunIsReported() {
        let report = AVSyncWindowSeries.judged([0, 0, 0, 0, 0, 0, -150, -150, 0, 0, 0, 0, 0, 0])
        #expect(!report.verdict.isInSync, "\(report.sentence)")
        #expect(report.verdict.needsReview, "\(report.sentence)")
        #expect(report.sentence.hasPrefix("sound 150 ms late for about 20 seconds at 1:10"), "\(report.sentence)")
    }
}

struct AVSyncPairingTests {
    @Test("frames and times pair only when the counts agree, or one frame was cut short at end of file")
    func pairingOnlyAtEOF() {
        #expect(AVSyncSignalReader.pairable(times: 100, frames: 100, partialFrameAtEnd: false))
        #expect(AVSyncSignalReader.pairable(times: 101, frames: 100, partialFrameAtEnd: true))
        #expect(!AVSyncSignalReader.pairable(times: 101, frames: 100, partialFrameAtEnd: false))
        #expect(!AVSyncSignalReader.pairable(times: 100, frames: 101, partialFrameAtEnd: false))
        #expect(!AVSyncSignalReader.pairable(times: 102, frames: 100, partialFrameAtEnd: true))
        #expect(!AVSyncSignalReader.pairable(times: 0, frames: 0, partialFrameAtEnd: false))
        let sink = PictureSink(frameBytes: 4)
        sink.append(Data([1, 2, 3, 4, 5, 6]))
        #expect(sink.hasPartialFrame)
        #expect(AVSyncSignalReader.knownDuration(0) == nil && AVSyncSignalReader.knownDuration(-3) == nil
                && AVSyncSignalReader.knownDuration(.nan) == nil && AVSyncSignalReader.knownDuration(12) == 12)
    }
}

@Suite(.scratchCleanup)
struct AVSyncReviewReaderTests {

    final class Calls: @unchecked Sendable {   // guarded by `lock`
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    static func file(seconds: Double) async throws -> URL {
        let dir = try TestScratch.unique("test_avsync_review_")
        let source = try AVSyncFixtures.makeSource(in: dir, seconds: seconds, seed: 0x7E7)
        return try await AVSyncFixtures.encodeOriginal(source, format: .mkvFFV1, in: dir)
    }

    @Test("F3: a duration of 0 is unknown — the unknown-length deadline, and the read still shows it is alive")
    func zeroDurationIsUnknown() async throws {
        #expect(AVSyncSignalReader.deadline(expectedDurationSeconds: 0) == AVSyncSignalReader.deadline(expectedDurationSeconds: nil))
        #expect(AVSyncSignalReader.deadline(expectedDurationSeconds: -1) == AVSyncSignalReader.deadline(expectedDurationSeconds: nil))
        let url = try await Self.file(seconds: 25)
        let calls = Calls()
        _ = try await AVSyncSignalReader().read(path: url.path, expectedDurationSeconds: 0) { _ in calls.bump() }
        #expect(calls.count >= 1, "an unknown-length read must still tick the stall watchdog")
    }

    @Test("progress is throttled at the reader: at most ~1 % steps, not one call per frame")
    func progressIsThrottled() async throws {
        let url = try await Self.file(seconds: 25)   // 750 frames
        let calls = Calls()
        _ = try await AVSyncSignalReader().read(path: url.path, expectedDurationSeconds: 25) { _ in calls.bump() }
        #expect(calls.count >= 2 && calls.count <= 110, "\(calls.count) progress calls for 750 frames")
    }
}
