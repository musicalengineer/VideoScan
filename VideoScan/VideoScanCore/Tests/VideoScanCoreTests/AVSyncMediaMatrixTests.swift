// AVSyncMediaMatrixTests.swift — the A/V sync check across the five media
// formats (CLAUDE.md rule 8): mp4/h264+aac, mov/prores+pcm, mkv/ffv1+pcm,
// mxf/mpeg2+pcm (25 fps), avi/dv+pcm (PAL, 25 fps). For each: an original in
// that format, and a processed copy in the same format with the sound moved
// 100 ms later — recovered within ±5 ms and said "100 ms late"; plus the
// Topaz shape, a ProRes original against an H.264 processed file.

import Foundation
import Testing
@testable import VideoScanCore

@Suite(.scratchCleanup)
struct AVSyncMediaMatrixTests {

    static let seconds = 60.0

    @Test("every matrix format: a 100 ms late sound is recovered within ±5 ms",
          arguments: AVSyncFixtures.Format.allCases)
    func lateSound(format: AVSyncFixtures.Format) async throws {
        let dir = try TestScratch.unique("test_avsync_matrix_")
        let source = try AVSyncFixtures.makeSource(in: dir, seconds: Self.seconds, seed: 0x3A7)
        let original = try await AVSyncFixtures.encodeOriginal(source, format: format, in: dir)
        let processed = try await AVSyncFixtures.process(original, change: .soundLate(ms: 100), format: format, in: dir)
        let report = try await AVSyncFixtures.measure(original: original, processed: processed, seconds: Self.seconds)
        AVSyncFixtures.note("matrix \(format.rawValue), sound 100 ms later", expected: "-100 ms", report: report)
        guard case let .offset(shift) = report.verdict else {
            Issue.record("\(format): expected an offset: \(AVSyncFixtures.describe(report))")
            return
        }
        #expect(abs(shift + 100) <= 5, "\(format): \(AVSyncFixtures.describe(report))")
        #expect(report.sentence.contains("ms late against the picture"), "\(report.sentence)")
    }

    @Test("the Topaz shape: ProRes original, H.264 processed copy, unchanged — in sync")
    func proResToH264() async throws {
        let dir = try TestScratch.unique("test_avsync_matrix_cross_")
        let source = try AVSyncFixtures.makeSource(in: dir, seconds: Self.seconds, seed: 0x70BA2)
        let original = try await AVSyncFixtures.encodeOriginal(source, format: .movProRes, in: dir)
        let processed = try await AVSyncFixtures.process(original, change: .none, format: .mp4H264, in: dir)
        let report = try await AVSyncFixtures.measure(original: original, processed: processed, seconds: Self.seconds)
        AVSyncFixtures.note("ProRes original vs H.264 copy", expected: "0 ms, in sync", report: report)
        #expect(report.verdict.isInSync, "\(AVSyncFixtures.describe(report))")
        #expect(abs(report.medianShiftMs ?? 99) <= 5, "\(AVSyncFixtures.describe(report))")
    }
}
