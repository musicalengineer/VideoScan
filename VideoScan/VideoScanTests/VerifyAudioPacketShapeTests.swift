// VerifyAudioPacketShapeTests.swift
// Verify Audio on PCM stored as ONE SAMPLE FRAME PER PACKET (the corpus
// check lane's five audio timeouts, 2026-11-24).
//
// Some QuickTime writers (Core Media with a 90 kHz sound timescale, and
// remuxes of such files into Matroska) store PCM so that ffmpeg's mov
// demuxer indexes one packet per sample frame: 21 M packets for a 7-minute
// stereo file, 56 M for 19 minutes. Before the fix every one of those became
// a frame that crossed the filter graph, the encoder and the null muxer of
// the levels and difference passes: a 444 s file took 419 s for the levels
// pass alone, and five corpus files ran past the 300 s per-file deadline.
// The fix (AudioBalanceProbe.reframeFilter) regroups the decoded sound into
// 4096-sample frames first.
//
//   - frames: the deterministic regression pin — how many frames reach the
//     null muxer (ffmpeg's own count at -v verbose). Red before the fix
//     (one per sample), green after (one per 4096).
//   - same numbers: the reframe changes no measurement — on every packet
//     shape (normal, one-sample, edit-listed, both, Matroska) the engine's
//     levels and difference passes give the same peak, RMS and sample count
//     as the chains without it. This is what keeps the verdict unchanged.
//   - budget: the real call site (VerifyAudioProbe.diagnose, what the
//     corpus lane and the Verify Audio job call) on a 10 s one-sample file,
//     against one pass of the pre-fix chain timed beside it.
//
// The one-sample shape is made, not found: an ffmpeg-made mov whose sound
// track is rewritten (media timescale ×2, every sample 2 ticks long). Same
// sound bytes, same length; ffmpeg groups PCM into chunks only when each
// sample lasts one tick, so it then demuxes one packet per sample frame —
// exactly what ffprobe shows on the corpus files. No family media.

import Testing
import Foundation
import VideoScanCore
@testable import VideoScan

// MARK: - Fixture: the one-sample-per-packet QuickTime shape

enum OneSamplePacketMov {

    struct NoSoundTrack: Error {}

    private struct Box {
        let type: String
        let start: Int
        let body: Int
        let end: Int
    }

    private static func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
        b[i..<i + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }
    private static func be64(_ b: [UInt8], _ i: Int) -> UInt64 {
        b[i..<i + 8].reduce(0) { $0 << 8 | UInt64($1) }
    }
    private static func put32(_ b: inout [UInt8], _ i: Int, _ v: UInt32) {
        for k in 0..<4 { b[i + k] = UInt8(truncatingIfNeeded: v >> (24 - 8 * UInt32(k))) }
    }
    private static func put64(_ b: inout [UInt8], _ i: Int, _ v: UInt64) {
        for k in 0..<8 { b[i + k] = UInt8(truncatingIfNeeded: v >> (56 - 8 * UInt64(k))) }
    }

    /// The child boxes in `start..<end` (ISO BMFF: 32-bit size + type, size 1 = 64-bit size follows).
    private static func boxes(_ b: [UInt8], _ start: Int, _ end: Int) -> [Box] {
        var out: [Box] = []
        var i = start
        while i + 8 <= end {
            var size = Int(be32(b, i))
            var header = 8
            if size == 1, i + 16 <= end {
                size = Int(be64(b, i + 8))
                header = 16
            } else if size == 0 {
                size = end - i
            }
            guard size >= header, i + size <= end else { break }
            out.append(Box(type: String(bytes: b[i + 4..<i + 8], encoding: .isoLatin1) ?? "",
                           start: i, body: i + header, end: i + size))
            i += size
        }
        return out
    }

    private static func child(_ b: [UInt8], _ parent: Box, _ type: String) -> Box? {
        boxes(b, parent.body, parent.end).first { $0.type == type }
    }

    /// Rewrite, in place, every sound track of an ffmpeg-made QuickTime file: media timescale ×`factor`
    /// (mdhd, with its duration) and every sample `factor` ticks long (stts). Fixtures are a few MB,
    /// read whole.
    static func rewrite(_ url: URL, factor: UInt32 = 2) throws {
        var b = [UInt8](try Data(contentsOf: url))
        var rewritten = 0
        for moov in boxes(b, 0, b.count) where moov.type == "moov" {
            for trak in boxes(b, moov.body, moov.end) where trak.type == "trak" {
                guard let mdia = child(b, trak, "mdia"), let hdlr = child(b, mdia, "hdlr"),
                      String(bytes: b[hdlr.body + 8..<hdlr.body + 12], encoding: .isoLatin1) == "soun",
                      let mdhd = child(b, mdia, "mdhd"), let minf = child(b, mdia, "minf"),
                      let stbl = child(b, minf, "stbl"), let stts = child(b, stbl, "stts") else { continue }
                let version1 = b[mdhd.body] == 1
                let timescale = mdhd.body + (version1 ? 20 : 12)
                put32(&b, timescale, be32(b, timescale) * factor)
                if version1 {
                    put64(&b, timescale + 4, be64(b, timescale + 4) * UInt64(factor))
                } else {
                    put32(&b, timescale + 4, be32(b, timescale + 4) * factor)
                }
                let entries = Int(be32(b, stts.body + 4))
                for entry in 0..<entries {
                    let delta = stts.body + 8 + 8 * entry + 4
                    put32(&b, delta, be32(b, delta) * factor)
                }
                rewritten += 1
            }
        }
        guard rewritten > 0 else { throw NoSoundTrack() }
        try Data(b).write(to: url)
    }

    /// testsrc + a decorrelated stereo tone pair (both channels carry program, so the difference pass
    /// runs) as mpeg2video + pcm_s16be in mov. `audioLead` > 0 starts the sound that many seconds
    /// before the picture: the mov muxer then writes an edit list that trims it, and the demuxer
    /// marks the lead's packets for discard.
    static func generate(into dir: URL, name: String, seconds: Double, audioLead: Double = 0) throws -> String {
        let out = dir.appendingPathComponent(name).path
        var args = ["-f", "lavfi", "-i", "testsrc=duration=\(seconds):size=160x120:rate=25"]
        if audioLead > 0 { args += ["-itsoffset", "-\(audioLead)"] }
        args += ["-f", "lavfi", "-i", "aevalsrc=\(VerifyAudioTestMedia.trueStereoExpr):s=48000:d=\(seconds + audioLead)",
                 "-map", "0:v:0", "-map", "1:a:0", "-c:v", "mpeg2video", "-c:a", "pcm_s16be"]
        try CleanupTestMedia.runFFmpeg(args, output: out)
        return out
    }

    /// The same file in the one-sample shape, beside it.
    static func oneSampleCopy(of path: String, name: String) throws -> String {
        let out = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(name)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: out)
        try rewrite(out)
        return out.path
    }

    /// Audio packets ffprobe demuxes from the first sound stream.
    static func audioPackets(_ path: String) async -> Int? {
        let r = await ProcessRunner.runProcess(
            executable: ToolLocator.ffprobePath,
            arguments: ["-v", "error", "-select_streams", "a:0", "-count_packets",
                        "-show_entries", "stream=nb_read_packets", "-of", "csv=p=0", path],
            stdoutLimitBytes: 1 << 16, deadlineSeconds: 120)
        return r.stdout.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}

// MARK: - Tests

@Suite("Verify Audio — one-sample PCM packets (corpus timeouts)", .serialized)
struct VerifyAudioPacketShapeTests {

    typealias Probe = AudioBalanceProbe

    /// One ffmpeg pass; returns its stderr (untruncated for these small fixtures).
    private func ffmpeg(_ args: [String]) async throws -> String {
        let r = await ProcessRunner.runProcess(executable: ToolLocator.ffmpegPath, arguments: args,
                                               stderrLimitBytes: 8 << 20, deadlineSeconds: 600)
        try #require(r.exitCode == 0, "ffmpeg exited \(r.exitCode)")
        return r.stderr
    }

    /// ffmpeg's own end-of-run count at -v verbose:
    /// "Output stream #0:0 (audio): 118 frames encoded (480000 samples); …"
    private func framesEncoded(_ stderr: String) -> (frames: Int, samples: Int)? {
        guard let line = stderr.split(whereSeparator: \.isNewline)
            .last(where: { $0.contains("Output stream #0:0 (audio):") && $0.contains("frames encoded") }),
            let m = line.firstMatch(of: /(\d+) frames encoded \((\d+) samples\)/),
            let frames = Int(m.1), let samples = Int(m.2) else { return nil }
        return (frames, samples)
    }

    @Test("frames: on one-sample packets the levels and difference passes hand 4096-sample frames downstream, not one frame per sample",
          .timeLimit(.minutes(5)))
    func reframedDownstream() async throws {
        try #require(VerifyAudioTestMedia.toolsAvailable)
        let dir = try VerifyAudioTestMedia.makeScratchDir("packetshape_frames")
        defer { try? FileManager.default.removeItem(at: dir) }
        let normal = try OneSamplePacketMov.generate(into: dir, name: "test_shape_normal.mov", seconds: 3)
        let oneSample = try OneSamplePacketMov.oneSampleCopy(of: normal, name: "test_shape_one_sample.mov")
        // The fixture IS the corpus shape: one packet per sample frame.
        #expect(await OneSamplePacketMov.audioPackets(oneSample) == 144_000)

        for args in [Probe.levelsArgs(input: oneSample, runTag: AstatsOutputParser.newRunTag()),
                     Probe.differenceArgs(input: oneSample, runTag: AstatsOutputParser.newRunTag())] {
            let counted = try #require(framesEncoded(try await ffmpeg(["-v", "verbose"] + args)))
            #expect(counted.samples == 144_000)
            // ceil(144000 / 4096) = 36. Before the fix: 144000 frames, one per sample.
            #expect(counted.frames <= 36, "\(counted.frames) frames crossed the filter graph and muxer")
        }
    }

    /// The pass the engine ran before the reframe, rebuilt here as the reference.
    private func referenceArgs(_ path: String, difference: Bool, tag: String) -> [String] {
        ["-hide_banner", "-nostdin", "-i", path, "-map", "0:a:0",
         "-af", (difference ? "aeval=val(0)-val(1):c=mono," : "") + Probe.astatsFilter(runTag: tag),
         "-f", "null", "-"]
    }

    private struct Measured: Equatable {
        let channels: [AudioChannelLevels]
        let samples: Int64?
    }

    private func measure(_ args: [String], tag: String) async throws -> Measured {
        let stderr = try await ffmpeg(args)
        return Measured(channels: AstatsOutputParser.perChannelLevels(fromStderr: stderr, runTag: tag),
                        samples: AstatsOutputParser.samplesPerChannel(fromStderr: stderr, runTag: tag))
    }

    @Test("same numbers: the reframe changes no peak, RMS or sample count on any packet shape — normal, one-sample, edit-listed, both, Matroska",
          .timeLimit(.minutes(10)))
    func reframeChangesNoMeasurement() async throws {
        try #require(VerifyAudioTestMedia.toolsAvailable)
        let dir = try VerifyAudioTestMedia.makeScratchDir("packetshape_truth")
        defer { try? FileManager.default.removeItem(at: dir) }
        let normal = try OneSamplePacketMov.generate(into: dir, name: "test_shape_normal.mov", seconds: 2)
        let edited = try OneSamplePacketMov.generate(into: dir, name: "test_shape_edit.mov", seconds: 2, audioLead: 0.25)
        let mkv = try VerifyAudioTestMedia.generate(into: dir, name: "test_shape_pcm.mkv", videoCodec: "ffv1",
                                                    audioCodec: "pcm_s24le", videoDuration: 2)
        let oneSample = try OneSamplePacketMov.oneSampleCopy(of: normal, name: "test_shape_one_sample.mov")
        let oneSampleMkv = dir.appendingPathComponent("test_shape_one_sample.mkv").path
        try CleanupTestMedia.runFFmpeg(["-i", oneSample, "-map", "0", "-c", "copy"], output: oneSampleMkv)
        let fixtures = [normal, edited, mkv, oneSample,
                        try OneSamplePacketMov.oneSampleCopy(of: edited, name: "test_shape_edit_one_sample.mov"),
                        oneSampleMkv]
        // The edit list is real: the decode delivers less than was written.
        let editedLevels = try await measure(referenceArgs(edited, difference: false, tag: "vsedit"), tag: "vsedit")
        #expect(editedLevels.samples.map { $0 < 108_000 } == true)

        for path in fixtures {
            let name = URL(fileURLWithPath: path).lastPathComponent
            for difference in [false, true] {
                let tag = AstatsOutputParser.newRunTag()
                let engine = difference ? Probe.differenceArgs(input: path, runTag: tag)
                                        : Probe.levelsArgs(input: path, runTag: tag)
                let before = try await measure(referenceArgs(path, difference: difference, tag: tag), tag: tag)
                let after = try await measure(engine, tag: tag)
                #expect(!before.channels.isEmpty && before.samples != nil, "\(name): the reference pass measured nothing")
                #expect(after == before, "\(name) \(difference ? "difference" : "levels"): \(after) vs \(before)")
            }
        }
    }

    /// The budget is relative, measured back to back on the same file, because the hosts that run
    /// this suite are shared and an absolute wall-clock bound measured the load, not the engine (one
    /// 20 s fixture: 41 s after the fix on a loaded M5 Ultra, 55 s before it on a lighter one). The
    /// bound: Verify Audio's WHOLE diagnosis — two ffprobe shapes, the levels pass and the difference
    /// pass — finishes before ONE levels pass of the pre-fix chain does. Before the fix the diagnosis
    /// is two such passes (ratio ≈ 2); after it each pass costs about a quarter (ratio ≈ 0.5).
    @Test("budget: Verify Audio's whole diagnosis of a one-sample file beats ONE pre-fix levels pass, with the verdict of the same sound in normal packets",
          .timeLimit(.minutes(5)))
    func diagnoseWithinBudget() async throws {
        try #require(VerifyAudioTestMedia.toolsAvailable)
        let dir = try VerifyAudioTestMedia.makeScratchDir("packetshape_budget")
        defer { try? FileManager.default.removeItem(at: dir) }
        let normal = try OneSamplePacketMov.generate(into: dir, name: "test_shape_normal.mov", seconds: 10)
        let oneSample = try OneSamplePacketMov.oneSampleCopy(of: normal, name: "test_shape_one_sample.mov")
        let reference = try await VerifyAudioProbe.diagnose(path: normal)

        let clock = ContinuousClock()
        var start = clock.now
        let tag = AstatsOutputParser.newRunTag()
        _ = try await measure(referenceArgs(oneSample, difference: false, tag: tag), tag: tag)
        let oldPassSeconds = (clock.now - start) / .seconds(1)
        start = clock.now
        let diagnosis = try await VerifyAudioProbe.diagnose(path: oneSample)
        let seconds = (clock.now - start) / .seconds(1)

        print("VerifyAudioPacketShapeTests: on 480 000 one-sample packets, diagnose \(String(format: "%.1f", seconds)) s; one pre-fix levels pass \(String(format: "%.1f", oldPassSeconds)) s")
        #expect(seconds < oldPassSeconds, "diagnose took \(seconds) s, one pre-fix levels pass \(oldPassSeconds) s")
        #expect(diagnosis.isHealthy && reference.isHealthy, "\(diagnosis.findings) / \(reference.findings)")
        #expect(diagnosis.balanceAnalysis?.levelsComplete == true)
        #expect(diagnosis.balanceAnalysis?.measurements == reference.balanceAnalysis?.measurements)
    }
}

// MARK: - A mid-stream parameter change (Codex #368 P1)
//
// When the decoded sound changes sample rate, format or channel layout
// mid-stream, ffmpeg tears the filter graph down and builds a new one; the
// samples the reframe holds (fewer than 4096) are dropped, not flushed. Before
// the reframe each graph's astats printed its own count, the counts disagreed
// and the parser answered nil, so a stated length read "decode ended early"
// and nothing was stored. With the reframe a first segment under 4096 samples
// leaves NO count, the second graph's count alone can look whole, and the pass
// read complete. The rule now: a pass whose graph was reconfigured has no
// sample count (AstatsOutputParser.graphReconfiguredMarker) — the outcome the
// old chain gave.

enum ReconfiguredSoundFixture {

    /// One AAC/ADTS segment (ADTS files concatenate into one stream whose
    /// parameters change at the join).
    private static func segment(_ dir: URL, _ name: String, rate: Int, channels: Int, seconds: Double) throws -> URL {
        let expr = channels == 2 ? VerifyAudioTestMedia.trueStereoExpr : "0.5*sin(440*2*PI*t)"
        let out = dir.appendingPathComponent(name)
        try CleanupTestMedia.runFFmpeg(["-f", "lavfi", "-i", "aevalsrc=\(expr):s=\(rate):d=\(seconds)", "-c:a", "aac"],
                                       output: out.path)
        return out
    }

    /// Two segments joined, stream-copied into NUT beside a 12 s picture, the
    /// sound tagged DURATION=12 s (Codex's executed shape). ffprobe reports
    /// the FIRST segment's rate and layout.
    static func make(into dir: URL, name: String,
                     first: (rate: Int, channels: Int, seconds: Double),
                     second: (rate: Int, channels: Int, seconds: Double)) throws -> String {
        let a = try segment(dir, name + ".a.aac", rate: first.rate, channels: first.channels, seconds: first.seconds)
        let b = try segment(dir, name + ".b.aac", rate: second.rate, channels: second.channels, seconds: second.seconds)
        let joined = dir.appendingPathComponent(name + ".aac")
        try (try Data(contentsOf: a) + (try Data(contentsOf: b))).write(to: joined)
        let out = dir.appendingPathComponent(name).path
        try CleanupTestMedia.runFFmpeg(["-f", "lavfi", "-i", "testsrc=duration=12:size=160x120:rate=25", "-i", joined.path,
                                        "-map", "0:v", "-map", "1:a", "-c:v", "mpeg4", "-c:a", "copy",
                                        "-metadata:s:a:0", "DURATION=00:00:12.000000000"], output: out)
        return out
    }
}

@Suite("Verify Audio — a mid-stream sound parameter change is never a complete pass (Codex #368 P1)", .serialized)
struct VerifyAudioReconfigurationTests {

    /// The real call site: no complete levels pass, a short decode, verdict
    /// "not checked", nothing to store.
    private func expectRefused(_ path: String, _ label: String) async throws {
        let analysis = try await AudioBalanceProbe.analyze(path: path)
        #expect(analysis.levelsComplete == false, "\(label): levels read complete")
        #expect(analysis.shortDecode != nil, "\(label): no short decode")
        let diagnosis = try await VerifyAudioProbe.diagnose(path: path)
        guard case .notChecked = diagnosis.verdict else {
            Issue.record("\(label): verdict \(diagnosis.verdict), findings \(diagnosis.findings)")
            return
        }
        #expect(diagnosis.persistedStatus.isEmpty)
    }

    @Test("rate change before the first reframed frame: 0.02 s at 48 kHz then 6 s at 96 kHz, stated 12 s — refused",
          .timeLimit(.minutes(3)))
    func rateChangeBeforeFirstFrame() async throws {
        try #require(VerifyAudioTestMedia.toolsAvailable)
        let dir = try VerifyAudioTestMedia.makeScratchDir("reconfig_rate_early")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try ReconfiguredSoundFixture.make(into: dir, name: "test_reconfig_rate_early.nut",
                                                     first: (48_000, 2, 0.02), second: (96_000, 2, 6))
        try await expectRefused(path, "rate change, early")
    }

    @Test("rate change after reframed frames went out: 2 s at 48 kHz then 6 s at 96 kHz, stated 12 s — refused",
          .timeLimit(.minutes(3)))
    func rateChangeAfterFirstFrame() async throws {
        try #require(VerifyAudioTestMedia.toolsAvailable)
        let dir = try VerifyAudioTestMedia.makeScratchDir("reconfig_rate_late")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try ReconfiguredSoundFixture.make(into: dir, name: "test_reconfig_rate_late.nut",
                                                     first: (48_000, 2, 2), second: (96_000, 2, 6))
        try await expectRefused(path, "rate change, late")
    }

    @Test("channel-layout change before the first reframed frame: 0.02 s stereo then 12 s mono at 48 kHz, stated 12 s — refused",
          .timeLimit(.minutes(3)))
    func layoutChangeBeforeFirstFrame() async throws {
        try #require(VerifyAudioTestMedia.toolsAvailable)
        let dir = try VerifyAudioTestMedia.makeScratchDir("reconfig_layout")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try ReconfiguredSoundFixture.make(into: dir, name: "test_reconfig_layout.nut",
                                                     first: (48_000, 2, 0.02), second: (48_000, 1, 12))
        try await expectRefused(path, "layout change")
    }

    @Test("the marker: ffmpeg names the reconfiguration on stderr; a count beside it is no answer, and without it the count stands")
    func markerRule() {
        let tag = "vstest"
        let count = "[astats@vstest @ 0x1] Number of samples: 577536\n"
        #expect(AstatsOutputParser.samplesPerChannel(fromStderr: count, runTag: tag) == 577_536)
        let reconfigured = "[af#0:0 @ 0x2] Reconfiguring filter graph because audio parameters changed to 96000 Hz, stereo, fltp\n" + count
        #expect(AstatsOutputParser.samplesPerChannel(fromStderr: reconfigured, runTag: tag) == nil)
    }
}
