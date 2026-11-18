// RawDVLateSoundTrackWritersTests.swift
// Codex #318-1 / GH #485 — the OTHER writers on a raw DV tape whose second
// sound track first appears part-way through (a camcorder switched to 12-bit
// / 32 kHz mid-tape; FFmpeg's dv demuxer creates the second stream there,
// after every header read).
//
// Repair Now refuses such a tape before writing (MediaRepairRawDVTests).
// These pin what Balance Audio, Rebuild Audio Track and the balanced-copy
// proof do with it. The contract each is held to is the same: a copy is
// never published, and a pair never proven the same, without the late pair.
// Where a writer does not meet it yet, the test is a TRACKED known issue
// (GH #485) — it runs, and the gauntlet lists it — never a skip.

import Foundation
import Testing
@testable import VideoScan

@Suite("Raw DV with a late second sound track — the other writers (GH #485)", .serialized)
@MainActor
struct RawDVLateSoundTrackWritersTests {

    typealias Media = UnlockedDVMedia
    private let fm = FileManager.default

    private func record(for path: String, duration: Double, codec: String, model: VideoScanModel) -> VideoRecord {
        let record = makeBalanceSourceRecord(path: path, durationSeconds: duration, audioCodec: codec)
        model.records = [record]
        return record
    }

    /// Sound streams in `path` as FFmpeg's demuxer finds them over the whole
    /// file (header + any created part-way) — Repair's own scan.
    private func wholeFileSoundStreams(_ path: String) async throws -> Int {
        let header = try await MediaRepairProbe.summary(path: path, control: nil)
        let late = try await MediaRepairProbe.lateStreams(path: path, inputArgs: [], control: nil)
        return header.codecs("audio").count + late.filter { $0.kind == "audio" }.count
    }

    @Test("GH #485 Rebuild Audio Track: on a late-pair tape it must not publish a copy without the late pair",
          .timeLimit(.minutes(3)))
    func rebuildAudioJob() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try BalanceAudioTestMedia.makeScratchDir("late_rebuildjob")
        defer { try? fm.removeItem(at: dir) }
        let original = try MediaRepairRawDVTests.lateSecondPairTape(in: dir, name: "late")
        #expect(try await wholeFileSoundStreams(original) == 2)
        let diagnosis = try await VerifyAudioProbe.diagnose(path: original)
        let model = VideoScanModel()
        let job = RebuildAudioJob(record: record(for: original, duration: diagnosis.shape.containerDurationSeconds,
                                                 codec: diagnosis.shape.audioCodec, model: model),
                                  reason: "test", shape: diagnosis.shape, model: model)
        job.start()
        await job.task?.value
        let published = job.publishedURL
        withKnownIssue("GH #485: Rebuild Audio Track maps 0:a:0 and publishes a raw DV copy without a sound track that first appears part-way through") {
            #expect(published == nil, "Rebuild Audio published \(published?.lastPathComponent ?? "") without the late pair")
        }
        if let published {
            #expect(try await wholeFileSoundStreams(published.path) == 1, "the copy carries the late pair after all")
        }
    }

    @Test("GH #485 Balance Audio: on a late-pair tape it must not publish a copy without the late pair",
          .timeLimit(.minutes(3)))
    func balanceAudioJob() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try BalanceAudioTestMedia.makeScratchDir("late_balancejob")
        defer { try? fm.removeItem(at: dir) }
        let original = try MediaRepairRawDVTests.lateSecondPairTape(in: dir, name: "late")
        let analysis = try await AudioBalanceProbe.analyze(path: original)
        let model = VideoScanModel()
        let job = BalanceAudioJob(record: record(for: original, duration: analysis.shape.durationSeconds,
                                                 codec: analysis.shape.audioCodec, model: model),
                                  analysis: analysis, model: model)
        job.start()
        await job.task?.value
        #expect(job.publishedURL == nil, "Balance published \(job.publishedURL?.lastPathComponent ?? "") on a late-pair tape: \(job.state)")
        guard case .failed(let message) = job.state else {
            Issue.record("expected a refusal or a failure, got \(job.state)")
            return
        }
        // What stops it today: the analysis is not a whole measurement (the sound's rate changes at the switch),
        // so the one gate refuses before any render. Nothing in Balance looks for the late pair itself.
        #expect(message == BalanceAudioFix.incompleteMeasurementReason && job.wasRefused, "\(message)")
    }

    @Test("GH #485 balanced-copy proof: a copy rendered by Balance's own argument vector on a late-pair tape is never proven the same",
          .timeLimit(.minutes(3)))
    func proofOnALatePairTape() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try BalanceAudioTestMedia.makeScratchDir("late_proof")
        defer { try? fm.removeItem(at: dir) }
        let original = try MediaRepairRawDVTests.lateSecondPairTape(in: dir, name: "late")
        // The job refuses this tape; the arguments it WOULD run, rendered anyway.
        let copy = dir.appendingPathComponent("rendered.mov").path
        let args = BalanceAudioFix.ffmpegArgs(
            input: original, output: copy, mapArgs: ["-map", "0"], panFilter: "pan=stereo|c0=c0|c1=c0",
            audioArgs: ["-c:a", "pcm_s16le"] + BalanceAudioFix.soundTimestampArgs(containerFormat: "dv"),
            inputArgs: ["-r", "30000/1001"])
        let render = await ProcessRunner.runProcess(executable: ToolLocator.ffmpegPath, arguments: args, deadlineSeconds: 120)
        try #require(render.exitCode == 0, "render failed: \(render.stderr.suffix(300))")
        #expect(try await wholeFileSoundStreams(copy) == 1)

        let outcome = await BalancedCopyProof.measure(original: original, balanced: copy)
        #expect(!outcome.playsTheSame, "the proof called a copy without the late pair the same: \(outcome)")
        // Why, today: NOT because it saw the late pair — the levels pass cannot measure the original's sound
        // whole across the rate switch. Pinned, so the day that reason changes the late pair is looked at (GH #485).
        #expect(outcome == .couldNotCheck("the original's sound was only partly measured"), "\(outcome)")
    }
}
