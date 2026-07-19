// BalanceAudioDVOutputTests.swift
// Raw-DV output container coverage for Balance Audio
// (fix/balance-dv-output-container).
//
// THE BUG (diagnosed on Rick's real Clip 28.dv, 2026-07-18): writing the
// balanced audio back into a raw `.dv` container is a dead end —
//   1. ffmpeg's dv muxer rejects the consumer profile's 32 kHz PCM
//      ("Invalid sample rate 32000 … must be 48000");
//   2. forcing `-ar 48000` crashes ffmpeg outright (fifo.c assertion —
//      a genuine dv-muxer bug);
//   3. muxing to QuickTime (.mov — the native iMovie wrapper these
//      clips came from) works, but ONLY with an input-side `-r`
//      override: raw DV metadata reports a bogus avg_frame_rate
//      (60000/1 while r_frame_rate is the true 30000/1001) and the mov
//      muxer fails at trailer-write ("fps 60000 is too large") without
//      it. Reproduced on synthetic raw-DV fixtures too.
//
// THE CONTRACT (these tests pin it):
//   - raw DV source (container format "dv") → balanced output is
//     `<stem>_balanced.mov`, with input-side `-r <r_frame_rate>`
//     (probed, never hardcoded — PAL DV is 25/1);
//   - non-DV sources keep the same-extension behavior unchanged;
//   - the mov muxer materializes DV timecode metadata as a `tmcd` data
//     track — verification tolerates exactly that; the hard contract
//     stays: ONE audio stream, dualMono after the fix, video
//     stream-copied.
//
// FIXTURE NOTE: ffmpeg's dv MUXER cannot synthesize consumer-profile
// 12-bit DV at all — it rejects 32 kHz PCM even for a single pair
// (verified 2026-07-18: "Invalid sample rate 32000 for audio stream #0
// for this video profile, must be 48000"), which is the very bug being
// fixed. DVCPRO50 (48 kHz, the one profile the muxer accepts a second
// pair in) stands in: the DEMUXED shape — raw "dv" container, dvvideo,
// two pcm_s16le pairs, bogus avg_frame_rate — is identical, which is
// everything the probe/job/muxer path cares about. The gated real-file
// test below covers the true 32 kHz consumer profile.

import Testing
import Foundation
@testable import VideoScan

@Suite("Balance Audio — raw DV output container", .serialized)
@MainActor
struct BalanceAudioDVOutputTests {

    private let fm = FileManager.default

    /// Real 12-bit consumer DV capture — copied to a temp dir before the
    /// job runs; the original is never touched.
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

    // MARK: End-to-end — synthetic raw DV → QuickTime

    @Test("raw .dv source: balanced output is a playable .mov (DV video stream-copied, one dual-mono audio track)",
          .timeLimit(.minutes(2)))
    func dvTwoPairSourcePublishesQuickTime() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try BalanceAudioTestMedia.makeScratchDir("dv_to_mov")
        defer { try? fm.removeItem(at: dir) }

        let path = try BalanceAudioTestMedia.generateTwoAudioPairs(
            into: dir, label: "dv_to_mov",
            pair1: "0|\(BalanceAudioTestMedia.programTone)",
            pair2: "0|0",
            container: .dv)
        let analysis = try await AudioBalanceProbe.analyze(path: path)
        #expect(analysis.classification == .rightOnly)
        let (record, model) = makeRecordAndModel(path: path, analysis: analysis)
        let before = try CleanupTestMedia.fingerprint(path)

        let job = BalanceAudioJob(record: record, analysis: analysis, model: model)
        job.start()
        await job.task?.value

        guard case .finished = job.state else {
            Issue.record("job failed on a raw DV source: \(job.state) — \(job.subtitle)")
            return
        }
        let published = try #require(job.publishedURL)
        #expect(published.pathExtension == "mov",
                "raw DV can't carry the balanced audio — output must be QuickTime, got \(published.lastPathComponent)")
        #expect(published.deletingPathExtension().lastPathComponent
                    .hasSuffix("_balanced"))

        // ffprobe-clean output: dual-mono program, DV video untouched,
        // exactly one audio stream (the dropped silent pair stays
        // dropped in QuickTime — no fixed DV audio slots here).
        let check = try await AudioBalanceProbe.analyze(path: published.path)
        #expect(check.classification == .dualMono)
        #expect(check.programStreamCount == 1)
        #expect(check.shape.audioStreams == 1,
                "QuickTime output must carry exactly ONE audio stream, got \(check.shape.audioStreams)")
        #expect(check.shape.videoCodec == "dvvideo", "video must be stream-copied")
        #expect(check.shape.videoRFrameRate == "30000/1001",
                "the probed r_frame_rate (not the bogus 60000/1 avg) must survive the mux")
        #expect(abs(check.shape.durationSeconds - analysis.shape.durationSeconds)
                <= BalanceAudioFix.durationToleranceSeconds)

        // Source untouched; no partial debris; no stray .dv output.
        #expect(try CleanupTestMedia.fingerprint(path) == before,
                "SOURCE FILE CHANGED during balance — must never happen")
        #expect(partialDebris(in: dir).isEmpty)
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        #expect(!names.contains { $0.hasSuffix("_balanced.dv") },
                "no .dv-container balanced output may be left behind")
    }

    // MARK: Real file — full job against a COPY of Clip 28.dv

    @Test("real Clip 28.dv (32 kHz consumer DV): full job on a temp COPY produces a playable balanced .mov",
          .timeLimit(.minutes(5)))
    func realClip28FullJobOnCopy() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        guard fm.fileExists(atPath: Self.realClip28) else {
            // TimmyBaby-1996 not present on this machine — the synthetic
            // raw-DV test above still pins the container rule.
            return
        }
        let dir = try BalanceAudioTestMedia.makeScratchDir("clip28_copy")
        defer { try? fm.removeItem(at: dir) }
        let copy = dir.appendingPathComponent("Clip 28.dv")
        try fm.copyItem(at: URL(fileURLWithPath: Self.realClip28), to: copy)

        let analysis = try await AudioBalanceProbe.analyze(path: copy.path)
        #expect(analysis.classification == .rightOnly)
        #expect(analysis.programStreamIndex == 1)
        #expect(analysis.droppedStreamIndices == [2])

        let (record, model) = makeRecordAndModel(path: copy.path, analysis: analysis)
        let before = try CleanupTestMedia.fingerprint(copy.path)

        let job = BalanceAudioJob(record: record, analysis: analysis, model: model)
        job.start()
        await job.task?.value

        guard case .finished = job.state else {
            Issue.record("job failed on the real consumer-DV clip: \(job.state) — \(job.subtitle)")
            return
        }
        let published = try #require(job.publishedURL)
        #expect(published.lastPathComponent == "Clip 28_balanced.mov")

        let check = try await AudioBalanceProbe.analyze(path: published.path)
        #expect(check.classification == .dualMono)
        #expect(check.shape.audioStreams == 1)
        #expect(check.shape.videoCodec == "dvvideo")
        #expect(check.shape.videoRFrameRate == "30000/1001")
        #expect(check.shape.audioCodec == "pcm_s16le", "PCM in → same PCM out")
        #expect(abs(check.shape.durationSeconds - analysis.shape.durationSeconds)
                <= BalanceAudioFix.durationToleranceSeconds,
                "duration must be preserved (source ≈ 74.74 s)")

        #expect(try CleanupTestMedia.fingerprint(copy.path) == before)
        #expect(partialDebris(in: dir).isEmpty)
    }

    // MARK: SENSOR — pure container/naming rules

    @Test("SENSOR: balancedOutputURL — raw DV → .mov; every other container keeps its extension")
    func balancedOutputURLContainerRule() {
        let never: (String) -> Bool = { _ in false }

        // Raw DV → QuickTime, with the uniquify counter in .mov too.
        var existing: Set<String> = []
        let dv1 = BalanceAudioFix.balancedOutputURL(
            forSourcePath: "/tapes/Clip 28.dv", containerFormat: "dv",
            fileExists: { existing.contains($0) })
        #expect(dv1.lastPathComponent == "Clip 28_balanced.mov")
        existing.insert("/tapes/Clip 28_balanced.mov")
        let dv2 = BalanceAudioFix.balancedOutputURL(
            forSourcePath: "/tapes/Clip 28.dv", containerFormat: "dv",
            fileExists: { existing.contains($0) })
        #expect(dv2.lastPathComponent == "Clip 28_balanced 2.mov")

        // Non-DV containers unchanged — including DV video INSIDE
        // QuickTime (shared mov demuxer name, not raw DV).
        #expect(BalanceAudioFix.balancedOutputURL(
            forSourcePath: "/x/tape7.mxf", containerFormat: "mxf",
            fileExists: never).lastPathComponent == "tape7_balanced.mxf")
        #expect(BalanceAudioFix.balancedOutputURL(
            forSourcePath: "/x/clip.mov",
            containerFormat: "mov,mp4,m4a,3gp,3g2,mj2",
            fileExists: never).lastPathComponent == "clip_balanced.mov")
        #expect(BalanceAudioFix.balancedOutputURL(
            forSourcePath: "/x/clip.mp4",
            containerFormat: "mov,mp4,m4a,3gp,3g2,mj2",
            fileExists: never).lastPathComponent == "clip_balanced.mp4")
        // Unknown container (pre-analysis callers) → historical rule.
        #expect(BalanceAudioFix.balancedOutputURL(
            forSourcePath: "/x/clip.mkv",
            fileExists: never).lastPathComponent == "clip_balanced.mkv")
    }

    @Test("SENSOR: isRawDVContainer — exactly the raw dv demuxer, never QuickTime/MKV")
    func rawDVContainerDetection() {
        #expect(BalanceAudioFix.isRawDVContainer("dv"))
        #expect(!BalanceAudioFix.isRawDVContainer("mov,mp4,m4a,3gp,3g2,mj2"))
        #expect(!BalanceAudioFix.isRawDVContainer("matroska,webm"))
        #expect(!BalanceAudioFix.isRawDVContainer("mxf"))
        #expect(!BalanceAudioFix.isRawDVContainer("avi"))
        #expect(!BalanceAudioFix.isRawDVContainer(""))
    }

    @Test("rawDVInputArgs: probed rate fed back for raw DV (NTSC and PAL), nothing for other containers or degenerate rates")
    func rawDVInputArgsTable() {
        func shape(container: String, rate: String?) -> AudioBalanceStreamShape {
            AudioBalanceStreamShape(
                videoCodec: "dvvideo", totalStreams: 3, videoStreams: 1,
                audioStreams: 2, audioCodec: "pcm_s16le", audioChannels: 2,
                audioBitRate: nil, durationSeconds: 74.7,
                audioStreamInfos: [],
                containerFormat: container, videoRFrameRate: rate)
        }
        // NTSC consumer DV — the Clip 28 case.
        #expect(BalanceAudioFix.rawDVInputArgs(shape: shape(container: "dv", rate: "30000/1001"))
                == ["-r", "30000/1001"])
        // PAL DV — probed, never hardcoded NTSC.
        #expect(BalanceAudioFix.rawDVInputArgs(shape: shape(container: "dv", rate: "25/1"))
                == ["-r", "25/1"])
        // Non-DV containers get NO override even with a rate.
        #expect(BalanceAudioFix.rawDVInputArgs(shape: shape(container: "mov,mp4,m4a,3gp,3g2,mj2", rate: "30000/1001"))
                == [])
        // Missing/degenerate rate → no override (let ffmpeg guess).
        #expect(BalanceAudioFix.rawDVInputArgs(shape: shape(container: "dv", rate: nil)) == [])
        #expect(BalanceAudioFix.rawDVInputArgs(shape: shape(container: "dv", rate: "0/0")) == [])
    }

    @Test("ffmpegArgs: inputArgs land BEFORE -i (demuxer options); empty inputArgs is byte-identical to v1")
    func ffmpegArgsInputSidePlacement() {
        let withR = BalanceAudioFix.ffmpegArgs(
            input: "/in/clip.dv", output: "/out/clip_balanced.mov",
            mapArgs: ["-map", "0:v?", "-map", "0:1"],
            panFilter: "pan=stereo|c0=c1|c1=c1",
            audioArgs: ["-c:a", "pcm_s16le"],
            inputArgs: ["-r", "30000/1001"])
        let rIdx = try? #require(withR.firstIndex(of: "-r"))
        let iIdx = try? #require(withR.firstIndex(of: "-i"))
        if let rIdx, let iIdx {
            #expect(rIdx < iIdx, "-r must be an INPUT option (before -i)")
        }
        #expect(withR.contains("30000/1001"))

        // Default: no input args — the historical vector, unchanged.
        let plain = BalanceAudioFix.ffmpegArgs(
            input: "/in/clip.mp4", output: "/out/clip_balanced.mp4",
            mapArgs: ["-map", "0"],
            panFilter: "pan=stereo|c0=c0|c1=c0",
            audioArgs: ["-c:a", "aac", "-b:a", "192000"])
        #expect(Array(plain.prefix(5))
                == ["-hide_banner", "-nostdin", "-y", "-i", "/in/clip.mp4"])
        #expect(!plain.contains("-r"))
    }

    @Test("outputStreamMismatch: one audio + video preserved + at most one gained timecode track")
    func outputStreamMismatchTable() {
        func shape(total: Int, video: Int, audio: Int) -> AudioBalanceStreamShape {
            AudioBalanceStreamShape(
                videoCodec: video > 0 ? "dvvideo" : nil,
                totalStreams: total, videoStreams: video,
                audioStreams: audio, audioCodec: "pcm_s16le",
                audioChannels: 2, audioBitRate: nil,
                durationSeconds: 2, audioStreamInfos: [])
        }
        let dvSource = shape(total: 3, video: 1, audio: 2)   // v + two pairs

        // Clip 28's shape: v + a + tmcd data track ← the fix's output.
        #expect(BalanceAudioFix.outputStreamMismatch(
            observed: shape(total: 3, video: 1, audio: 1), source: dvSource) == nil)
        // No timecode track (plain mov two-pair source) — also fine.
        #expect(BalanceAudioFix.outputStreamMismatch(
            observed: shape(total: 2, video: 1, audio: 1), source: dvSource) == nil)
        // Single-audio -map 0 source carried verbatim.
        let plainSource = shape(total: 2, video: 1, audio: 1)
        #expect(BalanceAudioFix.outputStreamMismatch(
            observed: shape(total: 2, video: 1, audio: 1), source: plainSource) == nil)

        // Breaches: a second audio stream, lost video, >1 gained extra.
        #expect(BalanceAudioFix.outputStreamMismatch(
            observed: shape(total: 3, video: 1, audio: 2), source: dvSource) != nil)
        #expect(BalanceAudioFix.outputStreamMismatch(
            observed: shape(total: 1, video: 0, audio: 1), source: dvSource) != nil)
        #expect(BalanceAudioFix.outputStreamMismatch(
            observed: shape(total: 4, video: 1, audio: 1), source: plainSource) != nil)
    }

    @Test("probe shape decodes format_name + video r_frame_rate (audio streams' 0/0 never leaks in)")
    func shapeDecodesContainerAndFrameRate() throws {
        let dv = try AudioBalanceProbe.shape(fromProbeJSON: Data("""
        {"streams":[
            {"index":0,"codec_type":"video","codec_name":"dvvideo","r_frame_rate":"30000/1001"},
            {"index":1,"codec_type":"audio","codec_name":"pcm_s16le","channels":2,"r_frame_rate":"0/0"},
            {"index":2,"codec_type":"audio","codec_name":"pcm_s16le","channels":2,"r_frame_rate":"0/0"}],
         "format":{"format_name":"dv","duration":"74.741333"}}
        """.utf8))
        #expect(dv.containerFormat == "dv")
        #expect(dv.videoRFrameRate == "30000/1001",
                "must be the VIDEO stream's rate, not an audio stream's 0/0")
        #expect(BalanceAudioFix.isRawDVContainer(dv.containerFormat))

        // Legacy canned JSON without the new keys → defaults ("", nil).
        let legacy = try AudioBalanceProbe.shape(fromProbeJSON: Data("""
        {"streams":[
            {"index":0,"codec_type":"video","codec_name":"h264"},
            {"index":1,"codec_type":"audio","codec_name":"aac","channels":2}],
         "format":{"duration":"2.0"}}
        """.utf8))
        #expect(legacy.containerFormat.isEmpty)
        #expect(legacy.videoRFrameRate == nil)
        #expect(!BalanceAudioFix.isRawDVContainer(legacy.containerFormat))
    }
}
