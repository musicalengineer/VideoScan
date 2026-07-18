// BalanceAudioMultiTrackTests.swift
// Multi-audio-stream (12-bit DV) coverage for Balance Audio.
//
// THE BUG (fix/balance-audio-dv-multitrack): DV camcorders in 12-bit
// audio mode record TWO stereo pairs; ffprobe reports two audio
// streams. The probe measured only `0:a:0` (so the sheet promised a
// fix from stream 1 alone) while the job refused any file with more
// than one audio stream — sheet promises, job refuses, and common
// 12-bit DV tapes could never be balanced. Red evidence 2026-07-18:
// (a) job refused a fixable DV shape ("This file has 2 audio tracks…"),
// (b) two-program-track file was NOT refused at analyze time,
// (c) program on the second stream classified .silent.
//
// THE CONTRACT (these tests pin it):
//   - exactly ONE audio stream carries program, the rest are silent →
//     fixable; the job maps video + THE program stream (correct
//     absolute index) and DROPS the silent pair(s);
//   - MORE than one stream carries program → refused at ANALYZE time,
//     through the same gate the sheet consults (sheet/job agreement);
//   - zero program streams → the existing silent refusal.
//
// Fixtures use a REAL .dv container where possible (DVCPRO50 — the
// only ffmpeg dv profile that accepts a second pair; see
// BalanceAudioTestMedia.TwoPairContainer.dv) plus a mov two-stream
// variant for the QuickTime family. One test probes Rick's real
// `Clip 28.dv` READ-ONLY, skipping gracefully when the volume is
// absent.

import Testing
import Foundation
@testable import VideoScan

@Suite("Balance Audio — multi-track (12-bit DV shape)", .serialized)
@MainActor
struct BalanceAudioMultiTrackTests {

    private let fm = FileManager.default

    /// Real 12-bit DV capture on Rick's Movies volume — READ ONLY.
    private static let realClip28 =
        "/Users/rickb/Movies/TimmyBaby-1996/Media/Clip 28.dv"

    private func partialDebris(in dir: URL) -> [String] {
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.contains(".vs-partial.") }
    }

    private func makeRecordAndModel(path: String,
                                    analysis: AudioBalanceAnalysis)
    -> (VideoRecord, VideoScanModel) {
        let model = VideoScanModel()
        let record = makeBalanceSourceRecord(
            path: path,
            durationSeconds: analysis.shape.durationSeconds,
            audioCodec: analysis.shape.audioCodec)
        model.records = [record]
        return (record, model)
    }

    // MARK: (a) program pair + silent pair → fixable, silent pair dropped

    @Test("(a) real .dv, right-only program on pair 1, pair 2 silent: fixable and the job balances it",
          .timeLimit(.minutes(2)))
    func dvProgramPlusSilentPairBalances() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try BalanceAudioTestMedia.makeScratchDir("dv_right_silent")
        defer { try? fm.removeItem(at: dir) }

        let path = try BalanceAudioTestMedia.generateTwoAudioPairs(
            into: dir, label: "right_silent",
            pair1: "0|\(BalanceAudioTestMedia.programTone)",
            pair2: "0|0",
            container: .dv)
        let analysis = try await AudioBalanceProbe.analyze(path: path)
        #expect(analysis.classification == .rightOnly,
                "program pair must classify from ITS channels, got \(analysis.classification)")
        #expect(analysis.programStreamCount == 1)
        #expect(analysis.programStreamIndex == 1,
                "dv fixture: video=0, program pair=1")
        #expect(analysis.droppedStreamIndices == [2],
                "the unused second pair (absolute stream 2) must be recorded droppable")
        #expect(BalanceAudioFix.refusalReason(for: analysis) == nil,
                "the sheet gate must offer the fix")

        let (record, model) = makeRecordAndModel(path: path, analysis: analysis)
        let before = try CleanupTestMedia.fingerprint(path)

        let job = BalanceAudioJob(record: record, analysis: analysis, model: model)
        job.start()
        await job.task?.value

        guard case .finished = job.state else {
            Issue.record("job refused a fixable 12-bit-DV shape: \(job.state) — \(job.subtitle)")
            return
        }
        let published = try #require(job.publishedURL)
        #expect(published.pathExtension == "dv", "container must be preserved")

        // Output: ONE balanced dual-mono program track, dvvideo stream-
        // copied. NOTE the DV container carries audio in fixed slots
        // inside the frame data — the dropped pair re-appears as a
        // silent slot, so the demuxer may still report 2 audio streams;
        // the content contract is "exactly one PROGRAM stream".
        let check = try await AudioBalanceProbe.analyze(path: published.path)
        #expect(check.classification == .dualMono)
        #expect(check.programStreamCount == 1,
                "output must carry exactly one program stream, got \(check.programStreamCount)")
        #expect(check.shape.videoCodec == "dvvideo")

        // Source untouched; no partial debris.
        #expect(try CleanupTestMedia.fingerprint(path) == before,
                "SOURCE FILE CHANGED during balance — must never happen")
        #expect(partialDebris(in: dir).isEmpty)
    }

    // MARK: (b) BOTH pairs carry program → refused at analyze time

    @Test("(b) real .dv, both pairs carry program: refused at ANALYZE time via the sheet's gate, and the job agrees",
          .timeLimit(.minutes(2)))
    func dvBothPairsCarryProgramRefused() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try BalanceAudioTestMedia.makeScratchDir("dv_both_program")
        defer { try? fm.removeItem(at: dir) }

        // Pair 1 right-only (pre-fix this alone looked fixable — the
        // trap), pair 2 fully live: TWO streams carry program.
        let path = try BalanceAudioTestMedia.generateTwoAudioPairs(
            into: dir, label: "both_program",
            pair1: "0|\(BalanceAudioTestMedia.programTone)",
            pair2: "\(BalanceAudioTestMedia.programTone2)|\(BalanceAudioTestMedia.programTone2)",
            container: .dv)
        let analysis = try await AudioBalanceProbe.analyze(path: path)
        #expect(analysis.programStreamCount == 2)

        // The gate the SHEET consults must already refuse — this is the
        // analyze-time promise (button disabled, reason shown).
        let refusal = BalanceAudioFix.refusalReason(for: analysis)
        #expect(refusal != nil,
                "two program-carrying tracks must be refused at analyze time — sheet offered a fix")
        #expect(refusal?.contains("audio tracks") == true,
                "refusal must name the multi-track reason, got: \(refusal ?? "nil")")

        // And the JOB refuses through the very same gate, touching
        // nothing on disk.
        let (record, model) = makeRecordAndModel(path: path, analysis: analysis)
        let before = try CleanupTestMedia.fingerprint(path)
        let job = BalanceAudioJob(record: record, analysis: analysis, model: model)
        job.start()
        await job.task?.value
        guard case .failed(let message) = job.state else {
            Issue.record("multi-program job must refuse, got \(job.state)")
            return
        }
        #expect(message == refusal, "job and sheet must give the SAME reason")
        #expect(!fm.fileExists(atPath: job.outputURL.path))
        #expect(partialDebris(in: dir).isEmpty)
        #expect(try CleanupTestMedia.fingerprint(path) == before)
    }

    // MARK: (c) program on the SECOND stream, first silent

    @Test("(c) mov two-pair, first pair silent, program on the SECOND: fixable, correct stream selected",
          .timeLimit(.minutes(2)))
    func programOnSecondStreamBalances() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try BalanceAudioTestMedia.makeScratchDir("second_program")
        defer { try? fm.removeItem(at: dir) }

        let path = try BalanceAudioTestMedia.generateTwoAudioPairs(
            into: dir, label: "second_program",
            pair1: "0|0",
            pair2: "\(BalanceAudioTestMedia.programTone)|0",
            container: .movPcm)
        let analysis = try await AudioBalanceProbe.analyze(path: path)
        #expect(analysis.classification == .leftOnly,
                "program on stream 2 must classify from stream 2, got \(analysis.classification)")
        #expect(analysis.programStreamIndex == 2,
                "mov fixture: video=0, silent pair=1, program pair=2")
        #expect(analysis.droppedStreamIndices == [1])
        #expect(analysis.shape.audioCodec == "pcm_s16le",
                "encoder args must follow the PROGRAM stream's codec")

        let (record, model) = makeRecordAndModel(path: path, analysis: analysis)
        let before = try CleanupTestMedia.fingerprint(path)

        let job = BalanceAudioJob(record: record, analysis: analysis, model: model)
        job.start()
        await job.task?.value

        guard case .finished = job.state else {
            Issue.record("job refused program-on-second-stream: \(job.state) — \(job.subtitle)")
            return
        }
        let published = try #require(job.publishedURL)
        let check = try await AudioBalanceProbe.analyze(path: published.path)
        #expect(check.classification == .dualMono,
                "the PROGRAM stream (not silent 0:a:0) must feed the output")
        #expect(check.shape.audioStreams == 1)
        #expect(check.shape.videoCodec == "h264")
        #expect(check.shape.audioCodec == "pcm_s16le", "PCM in → same PCM out")
        #expect(try CleanupTestMedia.fingerprint(path) == before)
    }

    // MARK: SENSOR — sheet/job agreement on track count

    @Test("SENSOR: an analysis the sheet deems fixable is never refused by the job for track count",
          .timeLimit(.minutes(2)))
    func sheetJobAgreementOnTrackCount() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try BalanceAudioTestMedia.makeScratchDir("agreement")
        defer { try? fm.removeItem(at: dir) }

        // A REAL two-audio-stream file (left-only program + silent
        // pair) — the exact shape v1's blunt `audioStreams == 1` guard
        // refused AFTER the sheet had promised a fix.
        let path = try BalanceAudioTestMedia.generateTwoAudioPairs(
            into: dir, label: "agreement",
            pair1: "\(BalanceAudioTestMedia.programTone)|0",
            pair2: "0|0",
            container: .movPcm)
        let analysis = try await AudioBalanceProbe.analyze(path: path)

        // Sheet gate says fixable…
        try #require(BalanceAudioFix.refusalReason(for: analysis) == nil,
                     "precondition: the sheet offers the fix")

        // …so the job must NEVER refuse it. Any failure here is a
        // sheet/job disagreement — THE original bug class.
        let (record, model) = makeRecordAndModel(path: path, analysis: analysis)
        let job = BalanceAudioJob(record: record, analysis: analysis, model: model)
        job.start()
        await job.task?.value
        guard case .finished = job.state else {
            Issue.record("sheet promised a fix, job refused/failed: \(job.state) — \(job.subtitle)")
            return
        }
    }

    // MARK: Pure — gate wording, mapping, verification expectation

    @Test("stream refusal wording: nil for ≤1 program stream, both/all phrasing above")
    func streamRefusalWording() {
        #expect(BalanceAudioFix.streamRefusalReason(programStreamCount: 0) == nil)
        #expect(BalanceAudioFix.streamRefusalReason(programStreamCount: 1) == nil)
        #expect(BalanceAudioFix.streamRefusalReason(programStreamCount: 2)
                == "2 audio tracks both carry sound — Balance Audio handles a single program track.")
        #expect(BalanceAudioFix.streamRefusalReason(programStreamCount: 3)
                == "3 audio tracks all carry sound — Balance Audio handles a single program track.")
    }

    @Test("map args: single-audio keeps -map 0 (v1-identical); multi-audio maps video + absolute program index")
    func mapArgsTable() {
        #expect(BalanceAudioFix.mapArgs(audioStreams: 1, programStreamIndex: 1)
                == ["-map", "0"])
        #expect(BalanceAudioFix.mapArgs(audioStreams: 2, programStreamIndex: 1)
                == ["-map", "0:v?", "-map", "0:1"])
        #expect(BalanceAudioFix.mapArgs(audioStreams: 2, programStreamIndex: 2)
                == ["-map", "0:v?", "-map", "0:2"],
                "ABSOLUTE stream index, never an assumed a:0")
    }

    @Test("expected output streams: everything for single-audio, video + one track for multi-audio")
    func expectedOutputStreamsTable() throws {
        // Single audio (mp4: v+a): all 2 streams survive.
        let single = try AudioBalanceProbe.shape(fromProbeJSON: Data("""
        {"streams":[
            {"index":0,"codec_type":"video","codec_name":"h264"},
            {"index":1,"codec_type":"audio","codec_name":"aac","channels":2}],
         "format":{"duration":"2.0"}}
        """.utf8))
        #expect(BalanceAudioFix.expectedOutputStreams(source: single) == 2)

        // 12-bit DV (v + two pairs): video + the one program track.
        let dv = try AudioBalanceProbe.shape(fromProbeJSON: Data("""
        {"streams":[
            {"index":0,"codec_type":"video","codec_name":"dvvideo"},
            {"index":1,"codec_type":"audio","codec_name":"pcm_s16le","channels":2},
            {"index":2,"codec_type":"audio","codec_name":"pcm_s16le","channels":2}],
         "format":{"duration":"2.0"}}
        """.utf8))
        #expect(BalanceAudioFix.expectedOutputStreams(source: dv) == 2)
        #expect(dv.videoStreams == 1)
        #expect(dv.audioStreams == 2)
        #expect(dv.audioStreamInfos.map(\.absoluteIndex) == [1, 2])
    }

    @Test("per-stream astats args select the right audio ordinal")
    func perStreamLevelArgs() {
        #expect(AudioBalanceProbe.levelsArgs(input: "/x.dv", audioStreamOrdinal: 1)
                .contains("0:a:1"))
        // Default stays 0:a:0 — the v1 single-stream path unchanged.
        #expect(AudioBalanceProbe.levelsArgs(input: "/x.mp4").contains("0:a:0"))
        #expect(AudioBalanceProbe.differenceArgs(input: "/x.dv", audioStreamOrdinal: 1)
                .contains("0:a:1"))
    }

    // MARK: Real file — READ-ONLY probe of Clip 28.dv

    @Test("real Clip 28.dv (12-bit DV): fixable rightOnly with the unused pair droppable",
          .timeLimit(.minutes(3)))
    func realClip28ProbeReadOnly() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        guard fm.fileExists(atPath: Self.realClip28) else {
            // TimmyBaby-1996 not present on this machine — nothing to
            // verify here (the synthetic .dv tests above still run).
            return
        }
        let analysis = try await AudioBalanceProbe.analyze(path: Self.realClip28)
        #expect(analysis.classification == .rightOnly,
                "Clip 28 carries program on the RIGHT of pair 1, got \(analysis.classification)")
        #expect(BalanceAudioFix.refusalReason(for: analysis) == nil,
                "Clip 28 must be fixable")
        #expect(analysis.programStreamCount == 1)
        #expect(analysis.programStreamIndex == 1,
                "program pair is absolute stream 1 (video is 0)")
        #expect(analysis.droppedStreamIndices == [2],
                "the unused second DV pair (stream 2) must be droppable")
        #expect(analysis.shape.audioCodec == "pcm_s16le")
    }
}
