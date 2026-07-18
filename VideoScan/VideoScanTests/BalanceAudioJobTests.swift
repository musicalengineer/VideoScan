// BalanceAudioJobTests.swift
// End-to-end + negative + sensor dimensions for the Balance Audio job
// (GH #116). Reuses CleanupTestMedia's fingerprint/probe helpers (same
// test target) for the source-hash oracle and independent ffprobe
// verification.
//
// POSITIVE (per actionable class): real job run → finished state,
// output beside the source, output re-classifies as dualMono, video
// codec unchanged (stream-copy), SOURCE HASH UNCHANGED.
//
// NEGATIVE (the crucial ones): trueStereo and dualMono refusals — the
// job must never "fix" what is fine; cancel/failure leave nothing at
// the final path and no partial debris; double-dispatch refused at the
// MFO layer; multi-audio-track guard.
//
// PROVENANCE: derivedFrom + derivationKind stamped on the catalogued
// output; legacy catalog JSON without the new key round-trips with the
// key still absent (additive-only contract).

import Testing
import Foundation
@testable import VideoScan

@Suite("Balance Audio — job", .serialized)
@MainActor
struct BalanceAudioJobTests {

    // MARK: Helpers

    /// Generate a fixture, analyze it for real, and build the
    /// record+model pair a job needs.
    private func makeFixture(
        _ channelCase: BalanceAudioTestMedia.ChannelCase,
        wrapper: BalanceAudioTestMedia.Wrapper,
        in dir: URL
    ) async throws -> (record: VideoRecord, analysis: AudioBalanceAnalysis, model: VideoScanModel) {
        let path = try BalanceAudioTestMedia.generate(
            into: dir, channelCase: channelCase, wrapper: wrapper)
        let analysis = try await AudioBalanceProbe.analyze(path: path)
        let model = VideoScanModel()
        let record = makeBalanceSourceRecord(
            path: path,
            durationSeconds: analysis.shape.durationSeconds,
            audioCodec: analysis.shape.audioCodec)
        model.records = [record]
        return (record, analysis, model)
    }

    /// No partial debris anywhere in `dir`.
    private func partialDebris(in dir: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.contains(".vs-partial.") }
    }

    // MARK: Positive — end-to-end per actionable class

    @Test("left-only mp4/aac: balanced output is dualMono, video stream-copied, source untouched",
          .timeLimit(.minutes(2)))
    func leftOnlyEndToEnd() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try BalanceAudioTestMedia.makeScratchDir("job_left")
        defer { try? FileManager.default.removeItem(at: dir) }

        let (record, analysis, model) = try await makeFixture(.leftOnly, wrapper: .mp4H264Aac, in: dir)
        #expect(analysis.classification == .leftOnly)
        let before = try CleanupTestMedia.fingerprint(record.fullPath)

        let job = BalanceAudioJob(record: record, analysis: analysis, model: model)
        job.start()
        await job.task?.value

        guard case .finished = job.state else {
            Issue.record("job did not finish: \(job.state) — \(job.subtitle)")
            return
        }
        let published = try #require(job.publishedURL)
        #expect(published.lastPathComponent == "test_balance_leftOnly_balanced.mp4")
        #expect(published.deletingLastPathComponent() == URL(fileURLWithPath: record.fullPath).deletingLastPathComponent())

        // THE hash oracle: source bytes + mtime byte-identical.
        let after = try CleanupTestMedia.fingerprint(record.fullPath)
        #expect(after == before, "SOURCE FILE CHANGED during balance — must never happen")

        // Output re-classifies balanced; video codec + stream count intact.
        let check = try await AudioBalanceProbe.analyze(path: published.path)
        #expect(check.classification == .dualMono)
        #expect(check.shape.videoCodec == "h264")
        #expect(check.shape.totalStreams == analysis.shape.totalStreams)
        #expect(abs(check.shape.durationSeconds - analysis.shape.durationSeconds)
                <= BalanceAudioFix.durationToleranceSeconds)
        #expect(partialDebris(in: dir).isEmpty)

        // Provenance on the catalogued derivative.
        let derived = model.records.first { $0.fullPath == published.path }
        #expect(derived?.derivedFrom == record.id)
        #expect(derived?.derivationKind == "balanceAudio")
        #expect(record.notes.contains("Balance Audio"))
    }

    @Test("right-only mov/pcm: lossless PCM family preserved end-to-end",
          .timeLimit(.minutes(2)))
    func rightOnlyPCMEndToEnd() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try BalanceAudioTestMedia.makeScratchDir("job_right")
        defer { try? FileManager.default.removeItem(at: dir) }

        let (record, analysis, model) = try await makeFixture(.rightOnly, wrapper: .movH264Pcm, in: dir)
        #expect(analysis.classification == .rightOnly)
        let before = try CleanupTestMedia.fingerprint(record.fullPath)

        let job = BalanceAudioJob(record: record, analysis: analysis, model: model)
        job.start()
        await job.task?.value

        guard case .finished = job.state else {
            Issue.record("job did not finish: \(job.state) — \(job.subtitle)")
            return
        }
        let published = try #require(job.publishedURL)
        #expect(published.pathExtension == "mov", "container must be preserved")

        let check = try await AudioBalanceProbe.analyze(path: published.path)
        #expect(check.classification == .dualMono)
        #expect(check.shape.audioCodec == "pcm_s16le", "PCM in → same PCM out (lossless)")
        #expect(check.shape.videoCodec == "h264")
        #expect(try CleanupTestMedia.fingerprint(record.fullPath) == before)
    }

    @Test("mono single-channel stream spreads to dual-mono stereo",
          .timeLimit(.minutes(2)))
    func monoEndToEnd() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try BalanceAudioTestMedia.makeScratchDir("job_mono")
        defer { try? FileManager.default.removeItem(at: dir) }

        let (record, analysis, model) = try await makeFixture(.mono, wrapper: .mp4H264Aac, in: dir)
        #expect(analysis.classification == .mono)

        let job = BalanceAudioJob(record: record, analysis: analysis, model: model)
        job.start()
        await job.task?.value

        guard case .finished = job.state else {
            Issue.record("job did not finish: \(job.state) — \(job.subtitle)")
            return
        }
        let published = try #require(job.publishedURL)
        let check = try await AudioBalanceProbe.analyze(path: published.path)
        #expect(check.classification == .dualMono)
        #expect(check.shape.audioChannels == 2)
    }

    // MARK: Negative — refusals (never "fix" what is fine)

    @Test("true stereo is REFUSED — the crucial never-touch case",
          .timeLimit(.minutes(2)))
    func trueStereoRefused() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try BalanceAudioTestMedia.makeScratchDir("refuse_stereo")
        defer { try? FileManager.default.removeItem(at: dir) }

        let (record, analysis, model) = try await makeFixture(.trueStereo, wrapper: .mp4H264Aac, in: dir)
        #expect(analysis.classification == .trueStereo)
        let before = try CleanupTestMedia.fingerprint(record.fullPath)

        let job = BalanceAudioJob(record: record, analysis: analysis, model: model)
        job.start()
        await job.task?.value

        guard case .failed(let message) = job.state else {
            Issue.record("true-stereo job must refuse, got \(job.state)")
            return
        }
        #expect(message.contains("True stereo"))
        #expect(!FileManager.default.fileExists(atPath: job.outputURL.path),
                "refusal must produce NO output file")
        #expect(partialDebris(in: dir).isEmpty)
        #expect(try CleanupTestMedia.fingerprint(record.fullPath) == before)
    }

    @Test("dual-mono is REFUSED as already balanced",
          .timeLimit(.minutes(2)))
    func dualMonoRefused() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try BalanceAudioTestMedia.makeScratchDir("refuse_dualmono")
        defer { try? FileManager.default.removeItem(at: dir) }

        let (record, analysis, model) = try await makeFixture(.dualMono, wrapper: .mp4H264Aac, in: dir)
        #expect(analysis.classification == .dualMono)

        let job = BalanceAudioJob(record: record, analysis: analysis, model: model)
        job.start()
        await job.task?.value

        guard case .failed(let message) = job.state else {
            Issue.record("dual-mono job must refuse, got \(job.state)")
            return
        }
        #expect(message.contains("Already balanced"))
        #expect(!FileManager.default.fileExists(atPath: job.outputURL.path))
    }

    @Test("silent audio is REFUSED — no program to balance",
          .timeLimit(.minutes(2)))
    func silentRefused() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try BalanceAudioTestMedia.makeScratchDir("refuse_silent")
        defer { try? FileManager.default.removeItem(at: dir) }

        let (record, analysis, model) = try await makeFixture(.silent, wrapper: .mp4H264Aac, in: dir)
        let job = BalanceAudioJob(record: record, analysis: analysis, model: model)
        job.start()
        await job.task?.value

        guard case .failed(let message) = job.state else {
            Issue.record("silent job must refuse, got \(job.state)")
            return
        }
        #expect(message.contains("No audio program"))
    }

    @Test("multiple PROGRAM-carrying tracks are refused (12-bit DV with one program pair is fixable — see BalanceAudioMultiTrackTests)")
    func multiProgramTrackRefused() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try BalanceAudioTestMedia.makeScratchDir("refuse_multitrack")
        defer { try? FileManager.default.removeItem(at: dir) }

        let (record, real, model) = try await makeFixture(.leftOnly, wrapper: .mp4H264Aac, in: dir)
        // Same real measurements, but an analysis claiming TWO streams
        // carry program — the analyze-time refusal the sheet also shows.
        var doctored = real
        doctored.shape.audioStreams = 2
        doctored.programStreamCount = 2
        let job = BalanceAudioJob(record: record, analysis: doctored, model: model)
        job.start()
        await job.task?.value

        guard case .failed(let message) = job.state else {
            Issue.record("multi-program job must refuse, got \(job.state)")
            return
        }
        #expect(message.contains("audio tracks"))
        #expect(!FileManager.default.fileExists(atPath: job.outputURL.path))
    }

    // MARK: Negative — cancel / failure leave nothing

    @Test("cancel leaves nothing at the final path and no partial debris",
          .timeLimit(.minutes(2)))
    func cancelLeavesNothing() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try BalanceAudioTestMedia.makeScratchDir("cancel")
        defer { try? FileManager.default.removeItem(at: dir) }

        let (record, analysis, model) = try await makeFixture(.leftOnly, wrapper: .movH264Pcm, in: dir)
        let job = BalanceAudioJob(record: record, analysis: analysis, model: model)
        job.start()
        job.cancel()                       // land the cancel immediately
        await job.task?.value

        #expect(job.state == .cancelled, "expected cancelled, got \(job.state)")
        #expect(!FileManager.default.fileExists(atPath: job.outputURL.path),
                "cancel must never leave a file at the final path")
        #expect(partialDebris(in: dir).isEmpty, "cancel must clean up its partial")
    }

    @Test("in-flight ffmpeg failure leaves nothing (injected via ffmpeg override)",
          .timeLimit(.minutes(2)))
    func renderFailureLeavesNothing() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try BalanceAudioTestMedia.makeScratchDir("fail")
        defer { try? FileManager.default.removeItem(at: dir) }

        let (record, analysis, model) = try await makeFixture(.leftOnly, wrapper: .mp4H264Aac, in: dir)
        let job = BalanceAudioJob(record: record, analysis: analysis, model: model,
                                  ffmpegPathOverride: "/usr/bin/false")
        job.start()
        await job.task?.value

        guard case .failed = job.state else {
            Issue.record("expected failed, got \(job.state)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: job.outputURL.path))
        #expect(partialDebris(in: dir).isEmpty)
    }

    // MARK: Negative — MFO-layer duplicate dispatch guard

    @Test("second dispatch against the same record is refused at the MFO layer",
          .timeLimit(.minutes(2)))
    func doubleDispatchRefused() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try BalanceAudioTestMedia.makeScratchDir("dupe")
        defer { try? FileManager.default.removeItem(at: dir) }

        let (record, analysis, model) = try await makeFixture(.leftOnly, wrapper: .mp4H264Aac, in: dir)
        let center = MediaFileOperationsCenter()

        let first = center.startBalanceAudio(record: record, analysis: analysis, model: model)
        let second = center.startBalanceAudio(record: record, analysis: analysis, model: model)
        #expect(first != nil)
        #expect(second == nil, "duplicate active dispatch must be refused")
        #expect(center.jobs.count == 1)

        await first?.task?.value
        // Once the first is terminal, a new dispatch is allowed again.
        let third = center.startBalanceAudio(record: record, analysis: analysis, model: model)
        #expect(third != nil)
        await third?.task?.value
    }

    // MARK: Pure naming / free-space

    @Test("balanced output naming: same extension, Finder-style uniquify")
    func outputNaming() {
        var existing: Set<String> = []
        let u1 = BalanceAudioFix.balancedOutputURL(
            forSourcePath: "/tmp/tape7.mxf", fileExists: { existing.contains($0) })
        #expect(u1.lastPathComponent == "tape7_balanced.mxf")
        existing.insert("/tmp/tape7_balanced.mxf")
        let u2 = BalanceAudioFix.balancedOutputURL(
            forSourcePath: "/tmp/tape7.mxf", fileExists: { existing.contains($0) })
        #expect(u2.lastPathComponent == "tape7_balanced 2.mxf")
    }

    @Test("audio encode args: PCM stays lossless, lossy never below source bitrate")
    func audioEncodeArgs() {
        #expect(BalanceAudioFix.audioEncodeArgs(sourceCodec: "pcm_s24le", bitRateBitsPerSec: nil)
                == ["-c:a", "pcm_s24le"])
        #expect(BalanceAudioFix.audioEncodeArgs(sourceCodec: "aac", bitRateBitsPerSec: 256_000)
                == ["-c:a", "aac", "-b:a", "256000"])
        // Floor: unknown/low bitrate never downgrades below 192k.
        #expect(BalanceAudioFix.audioEncodeArgs(sourceCodec: "aac", bitRateBitsPerSec: 96_000)
                == ["-c:a", "aac", "-b:a", "192000"])
        // Unknown legacy codec → AAC fallback at a generous bitrate.
        #expect(BalanceAudioFix.audioEncodeArgs(sourceCodec: "qdm2", bitRateBitsPerSec: nil)
                == ["-c:a", "aac", "-b:a", "256000"])
    }

    @Test("pan filter table: only actionable classes have a fix")
    func panFilterTable() {
        #expect(BalanceAudioFix.panFilter(for: .leftOnly) == "pan=stereo|c0=c0|c1=c0")
        #expect(BalanceAudioFix.panFilter(for: .rightOnly) == "pan=stereo|c0=c1|c1=c1")
        #expect(BalanceAudioFix.panFilter(for: .mono) == "pan=stereo|c0=c0|c1=c0")
        #expect(BalanceAudioFix.panFilter(for: .trueStereo) == nil)
        #expect(BalanceAudioFix.panFilter(for: .dualMono) == nil)
        #expect(BalanceAudioFix.panFilter(for: .silent) == nil)
        #expect(BalanceAudioFix.panFilter(for: .multichannel) == nil)
        // Refusal reasons exactly complement the fixes.
        for c in [AudioChannelClass.leftOnly, .rightOnly, .mono] {
            #expect(BalanceAudioFix.refusalReason(for: c) == nil)
        }
        for c in [AudioChannelClass.trueStereo, .dualMono, .silent, .multichannel] {
            #expect(BalanceAudioFix.refusalReason(for: c) != nil)
        }
    }

    // MARK: Provenance — additive-only Codable contract

    @Test("derivationKind: absent for legacy records, round-trips when set, cloned")
    func provenanceCodableContract() throws {
        // 1. A record without the field encodes WITHOUT the key —
        //    legacy catalogs stay byte-identical. (Encoding goes through
        //    VideoRecordDTO — the app's one true encoder.)
        let plain = VideoRecord()
        plain.filename = "legacy.mov"
        let plainJSON = String(decoding: try JSONEncoder().encode(VideoRecordDTO(plain)),
                               as: UTF8.self)
        #expect(!plainJSON.contains("derivationKind"))

        // 2. Legacy JSON (no key) decodes to nil.
        let decodedLegacy = try JSONDecoder().decode(
            VideoRecord.self, from: Data(plainJSON.utf8))
        #expect(decodedLegacy.derivationKind == nil)

        // 3. Set → encode → decode round-trips the value.
        let stamped = VideoRecord()
        stamped.filename = "tape7_balanced.mxf"
        stamped.derivedFrom = UUID()
        stamped.derivationKind = "balanceAudio"
        let stampedData = try JSONEncoder().encode(VideoRecordDTO(stamped))
        let roundTripped = try JSONDecoder().decode(VideoRecord.self, from: stampedData)
        #expect(roundTripped.derivationKind == "balanceAudio")
        #expect(roundTripped.derivedFrom == stamped.derivedFrom)

        // 4. The snapshot clone carries it.
        #expect(stamped.snapshotClone().derivationKind == "balanceAudio")
    }
}
