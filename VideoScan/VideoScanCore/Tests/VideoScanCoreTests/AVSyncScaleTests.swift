// AVSyncScaleTests.swift — the scale dimension of the A/V sync check
// (design §7): a 2-hour pair, read through the real reader and analysed,
// inside a time budget, with bounded resident growth; and the pure analysis
// of 2-hour signals (720 windows) on its own budget.
//
// Bars and how they are judged (the repo's rules, AudioCatalogIndexScaleTests'
// pattern): the time budgets are asserted on the reference run
// (VIDEOSCAN_TIMING_STRICT=1, the nightly) and logged elsewhere
// (`expectWithinReferenceTimingBudget`, GH #385); resident growth is a failure
// only there too — in a parallel `swift test` the process's resident size is
// not this test's.
//
// The 2-hour source: 2 h of 8 kHz speech-like sound rendered in Swift (never
// repeating — the coarse match needs that) and a 5-minute picture looped by
// ffmpeg (-stream_loop: the picture search is ±1 s, so a 5-minute period is
// never ambiguous). Encoded small (mp4/h264 160×90) so building the fixture
// is minutes, not tens of minutes; the decode cost per pixel is not the
// point here — the per-frame and per-window costs and the memory are.
// Worst-case memory: the reader holds one file's PCM (8 kHz Int16, 115 MB for
// 2 h) until its envelope and print are made; the test reads the two files
// one after the other (as the job does), so the bar is 300 MB of growth.

import Foundation
import os
import Testing
@testable import VideoScanCore

/// The highest resident size (MB) seen while `body` runs, sampled every
/// 20 ms — the growth a reader causes, unlike `resident_size_max`, which a
/// fixture's own rendering already raised.
enum ResidentPeak {
    static func during<T: Sendable>(_ body: () async throws -> T) async throws -> (value: T, peakMB: Double) {
        let peak = OSAllocatedUnfairLock(initialState: ResidentSize.now().current)
        let sampler = Task.detached {
            while !Task.isCancelled {
                let current = ResidentSize.now().current
                peak.withLock { $0 = max($0, current) }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        defer { sampler.cancel() }
        let value = try await body()
        let current = ResidentSize.now().current
        return (value, peak.withLock { max($0, current) })
    }
}

@Suite("AVSync scale", .tags(.scale), .serialized, .scratchCleanup)
struct AVSyncScaleTests {

    static let twoHours = 7_200.0

    @Test("a 2-hour pair: read and analysed within the budget, sound 100 ms late recovered, memory bounded",
          .tags(.quietMachine))
    func twoHourPair() async throws {
        let dir = try TestScratch.unique("test_avsync_scale_")
        let raw = dir.appendingPathComponent("source.gray")
        try AVSyncFixtures.renderPicture(to: raw, seconds: 300, seed: 0x2_0000, kind: .moving)
        let wav = dir.appendingPathComponent("source.wav")
        try WAVWriter.write(SyntheticSpeech.toInt16(SyntheticSpeech.render(seconds: Self.twoHours, seed: 0x2_0001,
                                                                           sampleRate: 8_000)),
                            sampleRate: 8_000, to: wav)
        let original = dir.appendingPathComponent("original.mp4")
        try await AVSyncFixtures.run(["-nostdin", "-v", "error", "-stream_loop", "-1", "-f", "rawvideo",
                                      "-pix_fmt", "gray", "-s", "64x36", "-r", "30", "-i", raw.path, "-i", wav.path,
                                      "-map", "0:v", "-map", "1:a", "-vf", "scale=160:90", "-c:v", "libx264",
                                      "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "64k",
                                      "-t", String(Self.twoHours), "-y", original.path])
        try FileManager.default.removeItem(at: wav)
        let processed = dir.appendingPathComponent("processed.mp4")
        try await AVSyncFixtures.run(["-nostdin", "-v", "error", "-i", original.path, "-map", "0:v", "-map", "0:a",
                                      "-c:v", "copy", "-af", "adelay=100:all=1", "-c:a", "aac", "-b:a", "64k",
                                      "-y", processed.path])

        let clock = ContinuousClock()
        let loadBefore = TimingBudget.sampleLoad()
        let before = ResidentSize.now().current
        let start = clock.now
        let reader = AVSyncSignalReader()
        let (pair, peak) = try await ResidentPeak.during {
            let o = try await reader.read(path: original.path, expectedDurationSeconds: Self.twoHours)
            let p = try await reader.read(path: processed.path, expectedDurationSeconds: Self.twoHours)
            return (o, p)
        }
        let (o, p) = pair
        let readWall = clock.now - start
        let analysisStart = clock.now
        let report = AVSyncAnalyzer.analyze(original: o, processed: p)
        let analysisWall = clock.now - analysisStart
        let wall = clock.now - start
        let growth = peak - before
        let realTime = 2 * Self.twoHours / TimingBudget.seconds(readWall)
        print(String(format: "AVSync scale: 2 × 2 h read in %.1f s (%.0f× real time), analysis of %d windows %.2f s, "
                     + "resident +%.0f MB — %@", TimingBudget.seconds(readWall), realTime, report.windows.count,
                     TimingBudget.seconds(analysisWall), growth, report.sentence))
        AVSyncFixtures.note("2-hour pair, sound 100 ms later", expected: "-100 ms", report: report,
                            seconds: 2 * Self.twoHours, elapsed: TimingBudget.seconds(wall))

        guard case let .offset(shift) = report.verdict else {
            Issue.record("expected 100 ms late: \(report.sentence)")
            return
        }
        #expect(abs(shift + 100) <= 5)
        #expect((718...719).contains(report.windows.count), "\(report.windows.count) windows")
        #expect(Double(report.measuredWindows) >= 0.9 * Double(report.windows.count))
        expectWithinReferenceTimingBudget("AVSync 2-hour pair, read + analysis", measured: wall,
                                          budget: .seconds(180), loadBefore: loadBefore)
        let growthLine = Comment(rawValue: String(format: "resident growth %.0f MB (bar 300 MB)", growth))
        if TimingBudget.isReferenceRun(environment: ProcessInfo.processInfo.environment) {
            #expect(growth < 300, growthLine)
        } else {
            withKnownIssue("resident-size growth is not attributable outside the reference run", isIntermittent: true) {
                #expect(growth < 300, growthLine)
            }
        }
    }

    @Test("decode speed: SD DV and 1080p H.264 read faster than real time", .tags(.quietMachine),
          arguments: ["dv-sd", "h264-1080p"])
    func decodeSpeed(kind: String) async throws {
        let seconds = 60.0
        let dir = try TestScratch.unique("test_avsync_speed_")
        let source = try AVSyncFixtures.makeSource(in: dir, seconds: seconds, seed: 0x5BEED)
        let file: URL
        if kind == "dv-sd" {
            file = try await AVSyncFixtures.encodeOriginal(source, format: .aviDV, in: dir)
        } else {
            file = dir.appendingPathComponent("hd.mp4")
            try await AVSyncFixtures.run(["-nostdin", "-v", "error", "-f", "rawvideo", "-pix_fmt", "gray", "-s", "64x36",
                                          "-r", "30", "-i", source.rawPicture.path, "-i", source.sound.path,
                                          "-map", "0:v", "-map", "1:a", "-vf", "scale=1920:1080", "-c:v", "libx264",
                                          "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "aac", "-y", file.path])
        }
        let loadBefore = TimingBudget.sampleLoad()
        let clock = ContinuousClock()
        let start = clock.now
        let evidence = try await AVSyncSignalReader().read(path: file.path, expectedDurationSeconds: seconds)
        let wall = clock.now - start
        print(String(format: "AVSync decode speed %@: %.0f s of media in %.2f s = %.0f× real time (%d frames)",
                     kind, seconds, TimingBudget.seconds(wall), seconds / TimingBudget.seconds(wall),
                     evidence.signals.frameCount))
        #expect(evidence.signals.frameCount > 0)
        expectWithinReferenceTimingBudget("AVSync read \(kind), 60 s", measured: wall, budget: .seconds(30),
                                          loadBefore: loadBefore)
    }

    @Test("analysis alone: 2-hour signals (719 windows) within 5 s", .tags(.quietMachine))
    func twoHourAnalysis() {
        let pair = AVSyncSyntheticSignals.pair(seconds: Self.twoHours, sound: { _ in -100 }, picture: { _ in 0 })
        let loadBefore = TimingBudget.sampleLoad()
        let clock = ContinuousClock()
        let start = clock.now
        let report = AVSyncAnalyzer.analyze(original: pair.0, processed: pair.1, coarseOffsetSeconds: 0)
        let wall = clock.now - start
        print(String(format: "AVSync scale: analysis of %d windows %.2f s", report.windows.count,
                     TimingBudget.seconds(wall)))
        #expect(report.windows.count == 719)
        guard case let .offset(shift) = report.verdict else {
            Issue.record("expected an offset: \(report.sentence)")
            return
        }
        #expect(abs(shift + 100) <= 2)
        expectWithinReferenceTimingBudget("AVSync analysis, 719 windows", measured: wall, budget: .seconds(5),
                                          loadBefore: loadBefore)
    }
}
