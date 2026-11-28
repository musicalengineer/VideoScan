// AVSyncHonestNegativeTests.swift — the A/V sync check says "could not
// measure" when there is no usable evidence, and never "in sync"
// (docs/design/av_sync_analysis.md §1, §7; CLAUDE.md rule 1).
//
// Silence, a static slide, a steady tone, a periodic metronome, two different
// recordings, and a clip shorter than one window — each read through the real
// reader (ffmpeg) and judged.

import Foundation
import Testing
@testable import VideoScanCore

@Suite(.scratchCleanup)
struct AVSyncHonestNegativeTests {

    static func pair(sound: AVSyncFixtures.Sound = .speech, picture: AVSyncFixtures.Picture = .moving,
                     seconds: Double = 60, otherSeed: UInt64? = nil) async throws -> AVSyncReport {
        let dir = try TestScratch.unique("test_avsync_negative_")
        let source = try AVSyncFixtures.makeSource(in: dir, seconds: seconds, seed: 0xBEE5, sound: sound, picture: picture)
        let original = try await AVSyncFixtures.encodeOriginal(source, format: .mp4H264, in: dir)
        let processed: URL
        if let otherSeed {
            let otherDir = try TestScratch.unique("test_avsync_negative_other_")
            let other = try AVSyncFixtures.makeSource(in: otherDir, seconds: seconds, seed: otherSeed)
            processed = try await AVSyncFixtures.encodeOriginal(other, format: .mp4H264, in: otherDir, name: "processed")
        } else {
            processed = try await AVSyncFixtures.process(original, change: .soundLate(ms: 80), format: .mp4H264, in: dir)
        }
        return try await AVSyncFixtures.measure(original: original, processed: processed, seconds: seconds)
    }

    static func expectCouldNotMeasure(_ report: AVSyncReport, _ label: String) {
        AVSyncFixtures.note(label, expected: "could not measure", report: report)
        guard case .couldNotMeasure = report.verdict else {
            Issue.record("\(label) must be 'could not measure': \(AVSyncFixtures.describe(report))")
            return
        }
        #expect(!report.verdict.isInSync)
        #expect(!report.sentence.contains("in sync"), "\(report.sentence)")
        #expect(report.sentence.hasPrefix("could not measure: "), "\(report.sentence)")
    }

    @Test("silence: could not measure — no sound to line up")
    func silence() async throws {
        let report = try await Self.pair(sound: .silence)
        Self.expectCouldNotMeasure(report, "silence")
        #expect(report.verdict == .couldNotMeasure(.noSound(processed: true)), "\(report.sentence)")
    }

    @Test("a static slide: could not measure — no movement")
    func staticSlide() async throws {
        let report = try await Self.pair(picture: .staticSlide)
        Self.expectCouldNotMeasure(report, "static slide")
        guard case let .couldNotMeasure(.tooFewWindows(measured, total, reasons)) = report.verdict else {
            Issue.record("expected too few windows: \(report.sentence)")
            return
        }
        #expect(measured == 0 && total > 0)
        #expect(reasons.first?.reason == .noMovement, "\(report.sentence)")
        #expect(report.sentence.contains("no movement"), "\(report.sentence)")
    }

    @Test("a steady tone: could not measure")
    func tone() async throws {
        Self.expectCouldNotMeasure(try await Self.pair(sound: .tone), "steady tone")
    }

    @Test("a periodic metronome: could not measure")
    func metronome() async throws {
        Self.expectCouldNotMeasure(try await Self.pair(sound: .metronome), "metronome")
    }

    @Test("two different recordings: could not measure — they do not share the same sound")
    func differentRecordings() async throws {
        let report = try await Self.pair(otherSeed: 0xD1FF)
        Self.expectCouldNotMeasure(report, "different recordings")
        #expect(report.verdict == .couldNotMeasure(.noSharedSound), "\(report.sentence)")
        #expect(report.sentence == "could not measure: these two files do not share the same sound")
    }

    @Test("a clip shorter than one window: could not measure — too short")
    func tooShort() async throws {
        let report = try await Self.pair(seconds: 15)
        Self.expectCouldNotMeasure(report, "15 s clip")
        guard case .couldNotMeasure(.tooShort) = report.verdict else {
            Issue.record("expected too short: \(report.sentence)")
            return
        }
    }
}
