// CheckMediaLayoutContinuityTests.swift
// Check Media, 2026-10-07 follow-up — a quick check called a stuttering
// file healthy (Brockton: every sound packet stored 41 GB after its
// picture). Covers:
//
//   * LOGIC — the Layout measure and rule on synthetic packet lists
//     (interleaved → OK; all sound at the end → Problem; 1 s chunks → OK;
//     long low-bitrate chunks → Warning; a shorter sound window never
//     reads as a long run).
//   * LOGIC — the continuity detectors on in-memory PCM, and the
//     `ashowinfo` timing parser (gap / overlap).
//   * MEDIA — synthetic `test_*` WAVs through the real ffmpeg pass: a
//     50 ms digital-zero gap, a replayed 1024-frame block, a click → each
//     flagged; a clean tone → OK.
//   * SCALE — the analyzer streams 10 minutes of stereo in pipe-sized
//     chunks inside a time budget, with nothing retained.
//   * SENSOR — wording: a quick pass never says fine / healthy / OK; a
//     legacy quick card persisted with "Looks healthy" displays the new
//     sentence.
//   * Opt-in real file: TEST_RUNNER_VS_CHECKMEDIA_LAYOUT_PATH (READ-ONLY;
//     no path in git) must be a Layout Problem with clean Sound continuity.

import Testing
import Foundation
@testable import VideoScan

private typealias R = CheckMediaRules

// MARK: - Packet-list builders

private enum LayoutFixtures {
    /// Writes `seconds` of picture (fps, frameBytes each) and sound (47
    /// packets/s, 6 KB) into one file, alternating in chunks of
    /// `chunkSeconds` (picture chunk then its sound chunk). chunkSeconds ≥
    /// seconds = everything of one stream first.
    static func file(seconds: Double, fps: Double = 29.97, frameBytes: Int,
                     chunkSeconds: Double, soundLast: Bool = false) -> (video: [MediaPacketRow], audio: [MediaPacketRow]) {
        var video: [MediaPacketRow] = [], audio: [MediaPacketRow] = []
        var pos: Int64 = 48
        let audioStep = 1024.0 / 48_000
        var t = 0.0
        func addVideo(_ from: Double, _ to: Double) {
            var f = (from * fps).rounded(.up)
            while f / fps < to {
                video.append(MediaPacketRow(pts: f / fps, size: frameBytes, pos: pos))
                pos += Int64(frameBytes)
                f += 1
            }
        }
        func addAudio(_ from: Double, _ to: Double) {
            var k = (from / audioStep).rounded(.up)
            while k * audioStep < to {
                audio.append(MediaPacketRow(pts: k * audioStep, size: 6_144, pos: pos))
                pos += 6_144
                k += 1
            }
        }
        if soundLast {
            addVideo(0, seconds)
            addAudio(0, seconds)
            return (video, audio)
        }
        while t < seconds {
            let end = min(seconds, t + chunkSeconds)
            addVideo(t, end)
            addAudio(t, end)
            t = end
        }
        return (video, audio)
    }

    static let json = #"""
    {"streams":[
      {"index":0,"codec_name":"dnxhd","codec_type":"video","width":1920,"height":1080,"r_frame_rate":"30000/1001",
       "avg_frame_rate":"30000/1001","time_base":"1/30000","duration":"1494.127461","nb_frames":"44779",
       "field_order":"progressive","sample_aspect_ratio":"1:1","display_aspect_ratio":"16:9","disposition":{"attached_pic":0}},
      {"index":1,"codec_name":"pcm_s24be","codec_type":"audio","sample_rate":"48000","channels":2,"time_base":"1/48000",
       "duration_ts":71718000,"duration":"1494.125000","disposition":{"attached_pic":0}}],
     "format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2","duration":"1494.127461","size":"41515219938"}}
    """#

    static func inputs(_ sample: MediaLayoutSample?) throws -> CheckMediaQuickInputs {
        let data = Data(json.utf8)
        return CheckMediaQuickInputs(facts: try MediaFacts.parse(probeJSON: data),
                                     videoFacts: try VerifyVideoRules.facts(fromProbeJSON: data),
                                     layout: sample)
    }

    static func check(_ files: [(video: [MediaPacketRow], audio: [MediaPacketRow])]) throws -> MediaCheck {
        let windows = files.compactMap { MediaLayoutMeasure.measure(video: $0.video, audio: $0.audio) }
        return R.checkLayout(try inputs(MediaLayoutSample(windows: windows)))
    }
}

private typealias LF = LayoutFixtures

@Suite("Check Media — layout rules")
struct CheckMediaLayoutRuleTests {

    @Test func perFrameInterleaveIsOK() throws {
        let c = try LF.check([LF.file(seconds: 5, frameBytes: 917_504, chunkSeconds: 1.0 / 29.97)])
        #expect(c.verdict == .ok, "\(c.sentence)")
        #expect(c.sentence.hasPrefix("Sound and picture are stored side by side"))
    }

    /// DNxHD 220 in 1 s chunks: ≈ 27 MB apart at most — players cope.
    @Test func oneSecondChunksAreOK() throws {
        let c = try LF.check([LF.file(seconds: 5, frameBytes: 917_504, chunkSeconds: 1)])
        #expect(c.verdict == .ok, "\(c.sentence) \(c.evidence)")
    }

    /// The Brockton shape: all picture, then all sound, 41 GB apart.
    @Test func allSoundAtTheEndIsAProblem() throws {
        var f = LF.file(seconds: 5, frameBytes: 917_504, chunkSeconds: 5, soundLast: true)
        f.audio = f.audio.map { var r = $0; r.pos = (r.pos ?? 0) + 41_084_900_000; return r }
        let c = try LF.check([f])
        #expect(c.verdict == .problem)
        #expect(c.sentence == "All the sound is stored after all the picture (41 GB apart): players reading from a spinning disk will stutter. The sound itself may be fine.")
        #expect(c.fix == "Lossless remux (no re-encode) puts sound and picture side by side.")
    }

    /// Low bitrate, 6 s per stream at a time: close in bytes, long in
    /// time — a Warning, not a Problem.
    @Test func longLowBitrateChunksAreAWarning() throws {
        let c = try LF.check([LF.file(seconds: 12, frameBytes: 4_000, chunkSeconds: 6)])
        #expect(c.verdict == .warning, "\(c.sentence) \(c.evidence)")
    }

    /// Thresholds pinned: 64 MB, 2 s for a Problem, 4 s for a Warning.
    @Test func thresholdsArePinned() {
        #expect(R.layoutApartBytes == 64_000_000)
        #expect(R.layoutRunProblemSeconds == 2.0)
        #expect(R.layoutRunWarningSeconds == 4.0)
    }

    /// A sound window shorter than the picture window must not read as
    /// a long run of picture (seen on a healthy ffmpeg mp4).
    @Test func onlyTheSharedTimeCounts() {
        let f = LF.file(seconds: 5, frameBytes: 10_000, chunkSeconds: 1.0 / 29.97)
        let shortAudio = f.audio.filter { ($0.pts ?? 0) < 3.2 }
        let m = MediaLayoutMeasure.measure(video: f.video, audio: shortAudio)
        #expect((m?.longestRunSeconds ?? 99) < 0.1, "\(String(describing: m))")
    }

    @Test func oneStreamOnlyIsNotMeasured() throws {
        let f = LF.file(seconds: 5, frameBytes: 10_000, chunkSeconds: 1)
        #expect(MediaLayoutMeasure.measure(video: f.video, audio: []) == nil)
        let c = R.checkLayout(try LF.inputs(MediaLayoutSample(windows: [])))
        #expect(c.verdict == .notRun(reason: "the sound and picture could not be sampled together"))
    }

    @Test func argumentsAreReadOnlyAndNamed() {
        let a = CheckMediaProbe.layoutArgs(input: "/x.mov", stream: "a:0", interval: "1.000%+4.000")
        #expect(a.contains("packet=pts_time,size,pos"), "fields by NAME, never by csv column order")
        #expect(!a.contains("-y") && !a.contains("-c"))
        #expect(CheckMediaProbe.layoutVideoPackets(fps: 29.97) == 150)
        #expect(CheckMediaProbe.layoutVideoPackets(fps: 90_000) == 300, "a 60,000 fps file can't make it read gigabytes")
    }
}

// MARK: - Continuity: PCM builders

private enum PCM {
    static let rate = 48_000

    /// Stereo Int16 tone (440 Hz left, 660 Hz right, ≈ −10 dBFS).
    static func tone(seconds: Double) -> [Int16] {
        let frames = Int(seconds * Double(rate))
        var out = [Int16](repeating: 0, count: frames * 2)
        for n in 0..<frames {
            let t = Double(n) / Double(rate)
            out[2 * n] = Int16(9_800 * sin(2 * .pi * 440 * t))
            out[2 * n + 1] = Int16(9_800 * sin(2 * .pi * 660 * t))
        }
        return out
    }

    static func withGap(_ s: [Int16], at seconds: Double, ms: Double) -> [Int16] {
        var s = s
        let start = Int(seconds * Double(rate)), n = Int(ms / 1000 * Double(rate))
        for i in (2 * start)..<(2 * (start + n)) { s[i] = 0 }
        return s
    }

    /// Copies the 1024 frames before `frame` over the 1024 from `frame`
    /// (a replayed buffer, deliberately NOT block-aligned).
    static func withReplay(_ s: [Int16], atFrame frame: Int) -> [Int16] {
        var s = s
        for i in 0..<(1024 * 2) { s[2 * frame + i] = s[2 * (frame - 1024) + i] }
        return s
    }

    static func withClick(_ s: [Int16], atFrame frame: Int) -> [Int16] {
        var s = s
        s[2 * frame] = 30_000
        return s
    }

    /// One channel (0 = left, 1 = right) set to digital zero over a stretch.
    static func withQuietSide(_ s: [Int16], channel: Int, from: Double, seconds: Double) -> [Int16] {
        var s = s
        let start = Int(from * Double(rate)), n = Int(seconds * Double(rate))
        for f in start..<min(start + n, s.count / 2) { s[2 * f + channel] = 0 }
        return s
    }

    /// Int16 → the s32le bytes ffmpeg would pipe.
    static func s32le(_ s: [Int16]) -> Data {
        var d = Data(capacity: s.count * 4)
        for v in s { withUnsafeBytes(of: (Int32(v) << 16).littleEndian) { d.append(contentsOf: $0) } }
        return d
    }

    /// Feed in pipe-sized chunks of odd length (splits frames mid-sample).
    static func analyze(_ s: [Int16]) -> SoundContinuityReport {
        var a = SoundContinuityAnalyzer(channels: 2, sampleRate: rate)
        let bytes = s32le(s)
        var i = 0
        while i < bytes.count {
            let end = min(bytes.count, i + 65_531)
            a.consume(bytes.subdata(in: i..<end))
            i = end
        }
        return a.finish()
    }

    /// A 16-bit stereo WAV, written by hand (no ffmpeg on the way in).
    static func writeWAV(_ s: [Int16], to url: URL) throws {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let dataBytes = UInt32(s.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(2)
        u32(UInt32(rate)); u32(UInt32(rate * 4)); u16(4); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        for v in s { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        try d.write(to: url)
    }
}

@Suite("Check Media — sound continuity")
struct CheckMediaSoundContinuityTests {

    @Test func cleanToneHasNothing() {
        let r = PCM.analyze(PCM.tone(seconds: 3))
        #expect(r.dropouts.occurrences < 1 && r.repeatedBlocks.occurrences < 1 && r.clicks.occurrences < 1, "\(r)")
        #expect(abs(r.seconds - 3) < 0.001)
    }

    @Test func fiftyMsGapIsADropout() {
        let r = PCM.analyze(PCM.withGap(PCM.tone(seconds: 3), at: 1.5, ms: 50))
        #expect(r.dropouts.occurrences == 1)
        #expect(abs((r.dropouts.firstSeconds.first ?? 0) - 1.5) < 0.001)
        #expect(abs(r.longestDropoutSeconds - 0.05) < 0.001)
    }

    @Test func edgesAndLongSilencesAreNotDropouts() {
        var s = PCM.withGap(PCM.tone(seconds: 6), at: 0.02, ms: 30)      // inside the first 100 ms
        s = PCM.withGap(s, at: 5.95, ms: 20)                              // inside the last 100 ms
        s = PCM.withGap(s, at: 2, ms: 2_500)                              // a silent passage
        let r = PCM.analyze(s)
        #expect(r.dropouts.occurrences < 1, "\(r.dropouts)")
        #expect(r.silentPassages == 1)
    }

    @Test func replayedBlockIsFoundAtAnyAlignment() {
        let r = PCM.analyze(PCM.withReplay(PCM.tone(seconds: 3), atFrame: 60_001))
        #expect(r.repeatedBlocks.occurrences == 1, "\(r.repeatedBlocks)")
        #expect(abs((r.repeatedBlocks.firstSeconds.first ?? 0) - 60_001.0 / 48_000) < 0.001)
    }

    @Test func clickIsFound() {
        let r = PCM.analyze(PCM.withClick(PCM.tone(seconds: 3), atFrame: 96_000))
        #expect(r.clicks.occurrences == 1, "\(r.clicks)")
        #expect(abs((r.clicks.firstSeconds.first ?? 0) - 2.0) < 0.001)
    }

    @Test func timingGapsAndOverlapsFromShowInfo() {
        var a = SoundContinuityAnalyzer(channels: 2, sampleRate: 48_000)
        let line = { (pts: Int) in "[Parsed_ashowinfo_1 @ 0x1] n:0 pts:\(pts) pts_time:0 fmt:s32 channels:2 chlayout:stereo rate:48000 nb_samples:1024 checksum:0" }
        for pts in [0, 1024, 2048, 3072 + 4_800, 4096 + 4_800 - 2_000, 5120 + 2_800] { a.consume(showInfoLine: line(pts)) }
        a.consume(showInfoLine: "Stream mapping: pts: nonsense")
        let r = a.finish()
        #expect(r.timingJumps.occurrences == 2, "a 100 ms gap and a 42 ms overlap: \(r.timingJumps)")
        #expect(abs(r.largestTimingJumpSeconds - 0.1) < 0.001)
    }

    @Test func ruleWording() {
        let facts = MediaFacts.withAudio()
        var r = SoundContinuityReport(seconds: 10)
        #expect(R.checkSoundContinuity(.success(r), facts: facts).verdict == .ok)
        r.dropouts.note(4.2)
        let one = R.checkSoundContinuity(.success(r), facts: facts)
        #expect(one.verdict == .warning)
        #expect(one.sentence == "The sound breaks up: 1 dropout to digital silence.")
        #expect(one.evidence.contains(MediaEvidence("Dropouts", "1 at 4.20 s")))
        r.repeatedBlocks.note(5); r.timingJumps.note(6)
        #expect(R.checkSoundContinuity(.success(r), facts: facts).verdict == .problem)
        #expect(R.checkSoundContinuity(.failure(CheckMediaSkip(reason: "x")), facts: facts).verdict == .notRun(reason: "x"))
    }

    /// SCALE: 10 minutes of stereo, streamed in 64 KB chunks, in budget.
    ///
    /// Not run under a sanitizer (2026-10-14): the analyzer touches every
    /// one of the 230 MB of samples, and instrumented per-sample work is
    /// not 4–15× slower but 66× (ASan, 45.7 s on 10/10) to 163× (TSan,
    /// 112 s on 10/11, 8 s short of the 2-minute limit) against 0.69 s in
    /// plain Debug. No honest factor covers that, and the 3-second cases
    /// above already exercise the same code under the sanitizer.
    @Test(.timeLimit(.minutes(2)),
          .disabled(if: PerformanceLane.isSanitizerRun,
                    "10-minute PCM stream is 66–163× slower under a sanitizer (45.7 s ASan, 112 s TSan vs 0.69 s plain); the 3 s cases cover the analyzer there"))
    func tenMinutesStreamInBudget() {
        let minute = PCM.s32le(PCM.tone(seconds: 60))
        var a = SoundContinuityAnalyzer(channels: 2, sampleRate: PCM.rate)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<10 {
                var i = 0
                while i < minute.count {
                    let end = min(minute.count, i + 65_536)
                    a.consume(minute.subdata(in: i..<end))
                    i = end
                }
            }
        }
        let r = a.finish()
        #expect(abs(r.seconds - 600) < 0.01)
        // Seams between the repeated minutes are continuous enough not to click.
        #expect(r.dropouts.occurrences < 1)
        // Through the shared lane rule like every other Debug budget; a
        // sanitizer never reaches this line (trait above), and the 2-minute
        // trait still caps the run regardless of any widening.
        #expect(elapsed < PerformanceLane.debugCeiling(.seconds(60)),
                "10 min of stereo took \(elapsed) (\(PerformanceLane.loadDescription()))")
    }

    // MARK: Through the real ffmpeg pass (synthetic WAVs)

    private func run(_ samples: [Int16], name: String) async throws -> MediaCheck {
        let dir = try VerifyVideoTestMedia.makeScratchDir("cmcontinuity")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(name)
        try PCM.writeWAV(samples, to: url)
        let facts = try #require(try? await CheckMediaProbe.facts(path: url.path).get())
        let result = try await CheckMediaProbe.soundContinuity(path: url.path, facts: facts)
        return R.checkSoundContinuity(result, facts: facts)
    }

    @Test("ffmpeg: clean tone OK; gap, replay and click each flagged", .timeLimit(.minutes(2)))
    func throughFFmpeg() async throws {
        try #require(VerifyVideoTestMedia.toolsAvailable)
        let tone = PCM.tone(seconds: 3)
        let clean = try await run(tone, name: "test_cm_tone.wav")
        #expect(clean.verdict == .ok, "\(clean.sentence) \(clean.evidence)")
        let gap = try await run(PCM.withGap(tone, at: 1.5, ms: 50), name: "test_cm_gap.wav")
        #expect(gap.verdict.rank >= MediaCheckVerdict.warning.rank && gap.sentence.contains("dropout"), "\(gap.sentence)")
        let replay = try await run(PCM.withReplay(tone, atFrame: 60_001), name: "test_cm_replay.wav")
        #expect(replay.verdict.rank >= MediaCheckVerdict.warning.rank && replay.sentence.contains("replayed"), "\(replay.sentence)")
        let click = try await run(PCM.withClick(tone, atFrame: 96_000), name: "test_cm_click.wav")
        #expect(click.verdict == .warning && click.sentence.contains("click"), "\(click.sentence)")
        let side = try await run(PCM.withQuietSide(PCM.tone(seconds: 30), channel: 0, from: 8, seconds: 14), name: "test_cm_side.wav")
        #expect(side.verdict == .warning && side.sentence.contains("the left channel for 14 s from 00:00:08"), "\(side.sentence)")
    }

    // MARK: Sound over time, per channel (Rick 2026-11-12)

    @Test("one side quiet for 12 s while the other carries on: counted for that channel, with where and how long")
    func oneSideGoesQuiet() {
        let r = PCM.analyze(PCM.withQuietSide(PCM.tone(seconds: 40), channel: 1, from: 20, seconds: 12))
        #expect(r.oneSidedQuiet.count == 2 && r.oneSidedQuiet[0].stretches == 0)
        let right = r.oneSidedQuiet[1]
        #expect(right.stretches == 1, "\(right)")
        #expect(abs(right.longestStartSeconds - 20) <= 0.11 && abs(right.longestSeconds - 12) <= 0.21, "\(right)")
        #expect(abs(right.totalSeconds - 12) <= 0.21)
        #expect(r.allQuiet.stretches == 0)
    }

    @Test("under 10 s on one side is not a stretch; both sides quiet together is 'all quiet', never one-sided")
    func shortAndSharedQuietAreNotOneSided() {
        var s = PCM.withQuietSide(PCM.tone(seconds: 60), channel: 0, from: 5, seconds: 9)      // 9 s: too short
        s = PCM.withQuietSide(s, channel: 0, from: 30, seconds: 15)                            // both quiet 30…45
        s = PCM.withQuietSide(s, channel: 1, from: 30, seconds: 15)
        let r = PCM.analyze(s)
        #expect(r.oneSidedQuiet.allSatisfy { $0.stretches == 0 }, "\(r.oneSidedQuiet)")
        #expect(r.allQuiet.stretches == 1 && abs(r.allQuiet.longestSeconds - 15) <= 0.21
                && abs(r.allQuiet.longestStartSeconds - 30) <= 0.11, "\(r.allQuiet)")
    }

    @Test("the other side's pauses do not break a one-sided stretch; a side that never sounds at all is the channels row's finding, not this one")
    func pausesAndAWhollySilentSide() {
        // Right quiet 10…50; left pauses for 2 s at 20 and at 35 (both quiet there).
        var s = PCM.withQuietSide(PCM.tone(seconds: 60), channel: 1, from: 10, seconds: 40)
        s = PCM.withQuietSide(s, channel: 0, from: 20, seconds: 2)
        s = PCM.withQuietSide(s, channel: 0, from: 35, seconds: 2)
        let r = PCM.analyze(s)
        #expect(r.oneSidedQuiet[1].stretches == 1 && abs(r.oneSidedQuiet[1].longestSeconds - 40) <= 0.21, "\(r.oneSidedQuiet[1])")
        #expect(r.allQuiet.stretches == 0, "2 s pauses are under 10 s")

        // Left only, start to end: the right channel never sounds.
        let leftOnly = PCM.analyze(PCM.withQuietSide(PCM.tone(seconds: 30), channel: 1, from: 0, seconds: 30))
        #expect(leftOnly.oneSidedQuiet.allSatisfy { $0.stretches == 0 }, "\(leftOnly.oneSidedQuiet)")

        // A tail where the left ticks once: the right was quiet 64 s, the left sounded 0.1 s of it.
        var tail = PCM.withQuietSide(PCM.tone(seconds: 100), channel: 0, from: 36, seconds: 64)
        tail = PCM.withQuietSide(tail, channel: 1, from: 36, seconds: 64)
        tail[2 * 48_000 * 70] = 9_000
        let t = PCM.analyze(tail)
        #expect(t.oneSidedQuiet.allSatisfy { $0.stretches == 0 }, "\(t.oneSidedQuiet)")
        #expect(t.allQuiet.stretches == 2 && abs(t.allQuiet.totalSeconds - 63.9) <= 0.31, "\(t.allQuiet)")
    }

    @Test("quiet is a level (under −60 dBFS peak), not digital zero")
    func quietIsALevel() {
        var s = PCM.tone(seconds: 30)
        for f in (10 * 48_000)..<(22 * 48_000) { s[2 * f + 1] = Int16(f % 2 == 0 ? 20 : -20) }   // ≈ −64 dBFS
        let r = PCM.analyze(s)
        #expect(r.oneSidedQuiet[1].stretches == 1, "\(r.oneSidedQuiet[1])")
        #expect(r.silentPassages == 0, "not digital silence")
    }

    @Test("the row: every channel quiet for 10 s or more in a track that has sound is a Warning that says where and how long; a wholly quiet track is the Sound row's finding, not this one's")
    func theSoundStops() {
        let facts = MediaFacts.withAudio()
        var r = SoundContinuityReport(seconds: 1_200)
        r.oneSidedQuiet = [QuietLog(), QuietLog()]
        r.allQuiet.note(start: 1_100, seconds: 100)
        let tail = R.checkSoundContinuity(.success(r), facts: facts)
        #expect(tail.verdict == .warning)
        #expect(tail.sentence == "The sound stops on every channel for 100 s from 00:18:20.", "\(tail.sentence)")
        #expect(tail.fix.contains("Listen"))
        #expect(tail.evidence.contains(MediaEvidence("All channels quiet (≥ 10 s)", "1 stretch, 100 s in all; longest 100 s from 00:18:20")))

        r.allQuiet.note(start: 200, seconds: 15)
        let two = R.checkSoundContinuity(.success(r), facts: facts)
        #expect(two.sentence == "The sound stops on every channel for 100 s from 00:18:20 (2 stretches).", "\(two.sentence)")

        r.dropouts.note(4.2)
        let withDropout = R.checkSoundContinuity(.success(r), facts: facts)
        #expect(withDropout.sentence == "The sound breaks up: 1 dropout to digital silence; every channel is quiet for 100 s from 00:18:20 (2 stretches).",
                "\(withDropout.sentence)")
        #expect(withDropout.verdict == .warning, "a stop is not a stutter event")

        // Codex #289 F2 — half a second of sound, then nothing: not a wholly quiet track.
        var brief = SoundContinuityReport(seconds: 30)
        brief.oneSidedQuiet = [QuietLog(), QuietLog()]
        brief.allQuiet.note(start: 0.5, seconds: 29.5)
        #expect(R.checkSoundContinuity(.success(brief), facts: facts).verdict == .warning)
        // Through the analyzer: digital zero from end to end is one stretch the length of the track.
        let zero = PCM.analyze([Int16](repeating: 0, count: 2 * 20 * PCM.rate))
        #expect(zero.allQuiet.stretches == 1 && zero.allQuiet.longestSeconds == zero.seconds, "\(zero.allQuiet) of \(zero.seconds)")
        #expect(R.checkSoundContinuity(.success(zero), facts: facts).verdict == .ok)

        // Quiet from the first sample to the last: "silent" is the Sound row's word.
        var silent = SoundContinuityReport(seconds: 1_200)
        silent.oneSidedQuiet = [QuietLog(), QuietLog()]
        silent.allQuiet.note(start: 0, seconds: 1_200)
        let whole = R.checkSoundContinuity(.success(silent), facts: facts)
        #expect(whole.verdict == .ok, "\(whole.sentence)")
    }

    @Test("the row: one side quiet is a Warning with its own words, and names a stop on every channel beside it")
    func quietRuleWording() {
        let facts = MediaFacts.withAudio()
        var r = SoundContinuityReport(seconds: 1_200)
        r.oneSidedQuiet = [QuietLog(), QuietLog()]
        r.oneSidedQuiet[1].note(start: 974, seconds: 64)
        r.oneSidedQuiet[1].note(start: 300, seconds: 12)
        var withStop = r
        withStop.allQuiet.note(start: 1_100, seconds: 100)
        let sideAndStop = R.checkSoundContinuity(.success(withStop), facts: facts)
        #expect(sideAndStop.sentence == "One side goes quiet while the other carries on: the right channel for 64 s from 00:16:14 (2 stretches); every channel for 100 s from 00:18:20.",
                "\(sideAndStop.sentence)")
        let one = R.checkSoundContinuity(.success(r), facts: facts)
        #expect(one.verdict == .warning)
        #expect(one.sentence == "One side goes quiet while the other carries on: the right channel for 64 s from 00:16:14 (2 stretches).",
                "\(one.sentence)")
        #expect(one.evidence.contains(MediaEvidence("Right quiet, others not (≥ 10 s)", "2 stretches, 76 s in all; longest 64 s from 00:16:14")))
        #expect(one.fix.contains("Listen"))

        r.dropouts.note(4.2)
        let both = R.checkSoundContinuity(.success(r), facts: facts)
        #expect(both.sentence == "The sound breaks up: 1 dropout to digital silence; the right channel is quiet for 64 s from 00:16:14 (2 stretches).",
                "\(both.sentence)")
        #expect(both.verdict == .warning, "a quiet side is not a stutter event")
    }

    // MARK: GH #470 — the continuity decode ends early and ffmpeg exits 0

    /// (name, video codec, extra video args): containers whose header still
    /// states the sound's full length after the file's tail is cut off.
    static let cutShort: [(String, String, [String])] = [
        ("test_cm_cut.mov", "prores", ["-movflags", "+faststart"]),
        ("test_cm_cut.mkv", "ffv1", []),
    ]

    @Test("#470: a file cut to 60 % — the continuity and level rows are 'not run' with the numbers, never 'Every sample decoded'",
          .enabled(if: VerifyAudioTestMedia.toolsAvailable), .timeLimit(.minutes(3)), arguments: [0, 1])
    func aDecodeThatEndsEarlyIsNotEverySample(_ which: Int) async throws {
        let (name, codec, args) = Self.cutShort[which]
        let dir = try VerifyAudioTestMedia.makeScratchDir("cmcut")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try VerifyAudioTestMedia.generate(into: dir, name: name, videoCodec: codec, extraVideoArgs: args,
                                                     audioCodec: "pcm_s16le", videoDuration: 12)
        // Whole: every sample decoded.
        let wholeFacts = try #require(try? await CheckMediaProbe.facts(path: path).get())
        let whole = R.checkSoundContinuity(try await CheckMediaProbe.soundContinuity(path: path, facts: wholeFacts),
                                           facts: wholeFacts)
        #expect(whole.verdict == .ok, "\(name) whole: \(whole.sentence)")

        let size = try #require((try FileManager.default.attributesOfItem(atPath: path))[.size] as? NSNumber).uint64Value
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.truncate(atOffset: size * 6 / 10)
        try handle.close()

        let facts = try #require(try? await CheckMediaProbe.facts(path: path).get())
        let result = try await CheckMediaProbe.soundContinuity(path: path, facts: facts)
        let row = R.checkSoundContinuity(result, facts: facts)
        guard case .notRun(let reason) = row.verdict else {
            Issue.record("\(name): a decode that stopped early read '\(row.sentence)'"); return
        }
        #expect(reason.hasPrefix("the sound decode stopped early — "), "\(reason)")
        #expect(reason.contains("of the 12.0 s"), "\(reason)")
        // The level rows ride the same decode: none of them is a measurement either.
        for check in R.levelChecks(result, facts: facts) {
            if case .notRun = check.verdict {} else { Issue.record("\(name): \(check.kind) read '\(check.sentence)'") }
        }
    }

    @Test("the short-decode rule on the continuity pass: more than 1 s AND more than 2 % missing; an unstated length never makes a finding")
    func theContinuityShortDecodeRule() {
        let short = { (decoded: Double, stated: Double?) in
            CheckMediaProbe.shortDecode(report: SoundContinuityReport(seconds: decoded), sampleRate: 48_000, statedSeconds: stated)
        }
        #expect(short(7.2, 12) == AudioShortDecode(missingSeconds: 4.8, statedSeconds: 12))
        #expect(short(12, 12) == nil && short(11.2, 12) == nil, "0.8 s missing is inside the 1 s tolerance")
        #expect(short(3_540, 3_600) == nil, "60 s of an hour is 1.7 %: inside the 2 % tolerance")
        #expect(short(3_500, 3_600) != nil)
        #expect(short(13, 12) == nil, "more sound than stated is not short")
        #expect(short(0, 12)?.missingSeconds == 12)
        #expect(short(5, nil) == nil)
    }

    @Test("the stated sound length: the stream's own duration, else Matroska's DURATION tag, else none")
    func theStatedSoundLength() throws {
        let json = { (stream: String) in
            Data(#"{"streams":[{"index":0,"codec_type":"audio","sample_rate":"48000"\#(stream)}],"format":{}}"#.utf8)
        }
        let own = try MediaFacts.parse(probeJSON: json(#","duration":"12.5","tags":{"DURATION":"00:00:20.000000000"}"#))
        #expect(own.audio?.statedSeconds == 12.5)
        let tagged = try MediaFacts.parse(probeJSON: json(#","tags":{"DURATION":"00:01:02.500000000"}"#))
        #expect(tagged.audio?.durationSeconds == nil && tagged.audio?.statedSeconds == 62.5)
        let none = try MediaFacts.parse(probeJSON: json(#","tags":{"DURATION":"soon"}"#))
        #expect(none.audio?.statedSeconds == nil)
        #expect(MediaFacts.probeEntries.contains("stream_tags=creation_time,timecode,DURATION"))
    }

    @Test("AVI states its PCM sound's length as a sample count: that is the stated length there, for PCM only, and nowhere else")
    func theStatedSoundLengthInAVI() throws {
        let json = { (format: String, codec: String, more: String) in
            Data(#"{"streams":[{"index":0,"codec_type":"audio","codec_name":"\#(codec)","sample_rate":"48000"\#(more)}],"format":{"format_name":"\#(format)"}}"#.utf8)
        }
        let avi = try MediaFacts.parse(probeJSON: json("avi", "pcm_s16le", #","nb_frames":"1920000""#))
        #expect(avi.audio?.durationSeconds == nil && avi.audio?.statedSeconds == 40)
        // A compressed codec's count is packets, not samples.
        #expect(try MediaFacts.parse(probeJSON: json("avi", "mp3", #","nb_frames":"1500""#)).audio?.statedSeconds == nil)
        // Other containers state a duration of their own; a bare count there is not read as samples.
        #expect(try MediaFacts.parse(probeJSON: json("mpeg", "pcm_dvd", #","nb_frames":"1920000""#)).audio?.statedSeconds == nil)
        // The stream's own duration still wins.
        #expect(try MediaFacts.parse(probeJSON: json("avi", "pcm_s16le", #","nb_frames":"1920000","duration":"12.5""#)).audio?.statedSeconds == 12.5)
        #expect(MediaFacts.countedPCMSeconds(formatName: "avi", codec: "pcm_u8", frameCount: 0, sampleRate: 8000) == nil)
        #expect(MediaFacts.countedPCMSeconds(formatName: "avi", codec: "pcm_u8", frameCount: 8000, sampleRate: nil) == nil)

        // The levels pass (what the Promote gate reads) states the same length.
        let shape = try AudioBalanceProbe.shape(fromProbeJSON: Data(#"""
            {"streams":[{"index":0,"codec_type":"video","codec_name":"mpeg4","duration":"24.0","nb_frames":"1000"},
                        {"index":1,"codec_type":"audio","codec_name":"pcm_s16le","channels":2,"sample_rate":"48000","nb_frames":"1920000"}],
             "format":{"format_name":"avi","duration":"24.0"}}
            """#.utf8))
        #expect(shape.audioStreamInfos.first?.statedSeconds == 40)
        #expect(AudioBalanceProbe.shapeArgs(input: "x").contains { $0.contains("nb_frames") })
    }

    @Test("picture and sound lengths are compared wherever the header states them: Matroska's tags and AVI's count too")
    func lengthsInMatroskaAndAVI() throws {
        let mkv = try MediaFacts.parse(probeJSON: Data(#"""
            {"streams":[{"index":0,"codec_type":"video","codec_name":"ffv1","tags":{"DURATION":"00:00:40.000000000"}},
                        {"index":1,"codec_type":"audio","codec_name":"pcm_s16le","sample_rate":"48000","tags":{"DURATION":"00:00:20.000000000"}}],
             "format":{"format_name":"matroska,webm","duration":"40.0"}}
            """#.utf8))
        let row = R.checkAVDuration(CheckMediaQuickInputs(facts: mkv, videoFacts: VideoVerifyFacts()))
        #expect(row.verdict == .problem && row.sentence.hasPrefix("The picture runs 20 s longer"), "\(row.verdict) \(row.sentence)")

        let avi = try MediaFacts.parse(probeJSON: Data(#"""
            {"streams":[{"index":0,"codec_type":"video","codec_name":"mpeg4","duration":"40.0","nb_frames":"1000","avg_frame_rate":"25/1"},
                        {"index":1,"codec_type":"audio","codec_name":"pcm_s16le","sample_rate":"48000","nb_frames":"1920000"}],
             "format":{"format_name":"avi","duration":"40.0"}}
            """#.utf8))
        #expect(R.checkAVDuration(CheckMediaQuickInputs(facts: avi, videoFacts: VideoVerifyFacts())).verdict == .ok)

        // Codex #289 F1 — an AVI cut short: ffprobe recomputes the picture's duration from what is
        // left (24 s) while both header counts still state 40 s. Counts are compared with counts, so
        // the row does not claim 16 s of extra sound; the short decode is the Sound row's finding.
        let cut = try MediaFacts.parse(probeJSON: Data(#"""
            {"streams":[{"index":0,"codec_type":"video","codec_name":"mpeg4","duration":"24.0","nb_frames":"1000","r_frame_rate":"25/1","avg_frame_rate":"25/1"},
                        {"index":1,"codec_type":"audio","codec_name":"pcm_s16le","sample_rate":"48000","nb_frames":"1920000"}],
             "format":{"format_name":"avi","duration":"24.0"}}
            """#.utf8))
        let cutRow = R.checkAVDuration(CheckMediaQuickInputs(facts: cut, videoFacts: VideoVerifyFacts()))
        #expect(cutRow.verdict == .ok, "\(cutRow.verdict) \(cutRow.sentence)")
        // Half the sound, by the counts: still a Problem.
        let half = try MediaFacts.parse(probeJSON: Data(#"""
            {"streams":[{"index":0,"codec_type":"video","codec_name":"mpeg4","duration":"40.0","nb_frames":"1000","r_frame_rate":"25/1","avg_frame_rate":"25/1"},
                        {"index":1,"codec_type":"audio","codec_name":"pcm_s16le","sample_rate":"48000","nb_frames":"960000"}],
             "format":{"format_name":"avi","duration":"40.0"}}
            """#.utf8))
        #expect(R.checkAVDuration(CheckMediaQuickInputs(facts: half, videoFacts: VideoVerifyFacts())).verdict == .problem)

        // Nothing stated: still "not run", never a guess.
        let bare = try MediaFacts.parse(probeJSON: Data(#"""
            {"streams":[{"index":0,"codec_type":"video","codec_name":"mpeg2video"},
                        {"index":1,"codec_type":"audio","codec_name":"mp2","sample_rate":"48000"}],
             "format":{"format_name":"mpeg","duration":"40.0"}}
            """#.utf8))
        if case .notRun = R.checkAVDuration(CheckMediaQuickInputs(facts: bare, videoFacts: VideoVerifyFacts())).verdict {} else {
            Issue.record("a file that states no stream lengths got a length verdict")
        }
    }
}

private extension MediaFacts {
    static func withAudio() -> MediaFacts {
        var f = MediaFacts()
        f.streams = [MediaStreamFacts(index: 0, kind: .audio)]
        return f
    }
}

// MARK: - Wording sensor

@Suite("Check Media — quick-pass wording")
@MainActor
struct CheckMediaQuickPassWordingTests {

    private func quickPassCard(headline: String? = nil) throws -> MediaReportCard {
        let q = try CheckMediaFixtures.healthy()
        var card = R.card(tier: .quick, checks: R.quickChecks(q) + R.fullRowsNotRun(), quick: q, at: Date())
        if let headline { card.headline = headline }
        return card
    }

    /// Rick 2026-10-07: a quick check said a stuttering file was fine.
    @Test func quickPassNeverSaysFine() throws {
        let card = try quickPassCard()
        #expect(card.isQuickPassOnly)
        let words = [card.displayHeadline, card.verdictWord,
                     CheckMediaJob.summary([CheckMediaItem(id: UUID(), filename: "a", outcome: .checked(card))])]
        for w in words {
            let lower = w.lowercased()
            #expect(!lower.contains("fine") && !lower.contains("healthy") && !w.hasPrefix("OK"), "\(w)")
        }
        #expect(card.displayHeadline == "No problems found in the quick check — run the full check to listen to every sample and decode every frame.")
        #expect(R.text(of: card).hasPrefix(card.displayHeadline))
    }

    /// A card saved before the fix still shows the honest sentence.
    @Test func legacyQuickCardDisplaysTheNewSentence() throws {
        let card = try quickPassCard(headline: "Looks healthy (quick check — a full check decodes every frame).")
        #expect(card.displayHeadline == MediaReportCard.quickPassHeadline)
    }

    @Test func fullPassMaySayHealthy() throws {
        var card = try quickPassCard()
        card.tier = .full
        #expect(!card.isQuickPassOnly)
        #expect(card.verdictWord == "OK")
    }

    @Test func newKindsAreAdditive() {
        #expect(MediaCheckKind(rawValue: "layout") == .layout && !MediaCheckKind.layout.isFullTier)
        #expect(MediaCheckKind(rawValue: "soundContinuity") == .soundContinuity && MediaCheckKind.soundContinuity.isFullTier)
        #expect(R.fullRowsNotRun().contains { $0.kind == .soundContinuity })
        let untitled = MediaCheckKind.allCases.filter { MediaCheckKind.titles[$0] == nil }
        #expect(untitled.isEmpty, "every check has a family-words title: \(untitled)")
    }
}

// MARK: - Real file (opt-in, never in CI)

/// TEST_RUNNER_VS_CHECKMEDIA_LAYOUT_PATH (xcodebuild passes it on as
/// VS_CHECKMEDIA_LAYOUT_PATH): a known non-interleaved file whose sound is
/// clean. READ-ONLY. Layout must be a Problem; Sound continuity OK.
@Suite("Check Media — layout real file (opt-in)", .serialized)
struct CheckMediaLayoutRealFileTests {
    @Test(.timeLimit(.minutes(20)))
    func nonInterleavedRealFile() async throws {
        guard let path = ProcessInfo.processInfo.environment["VS_CHECKMEDIA_LAYOUT_PATH"], !path.isEmpty else { return }
        let started = ContinuousClock.now
        guard case .measured(let q) = try await CheckMediaProbe.quick(path: path) else {
            Issue.record("unopenable"); return
        }
        let quickTime = ContinuousClock.now - started
        let checks = R.quickChecks(q)
        let card = R.card(tier: .quick, checks: checks + R.fullRowsNotRun(), quick: q, at: Date())
        print("CHECKMEDIA-LAYOUT-CARD (\(quickTime))\n" + R.text(of: card) + "\nCHECKMEDIA-LAYOUT-END")
        #expect(checks.first { $0.kind == .layout }?.verdict == .problem)
        let soundStart = ContinuousClock.now
        let continuity = R.checkSoundContinuity(try await CheckMediaProbe.soundContinuity(path: path, facts: q.facts),
                                                facts: q.facts)
        print("CHECKMEDIA-CONTINUITY (\(ContinuousClock.now - soundStart)) [\(continuity.verdict.word)] \(continuity.sentence)\n    "
              + continuity.evidence.map { "\($0.label): \($0.value)" }.joined(separator: " · "))
        #expect(continuity.verdict == .ok)
    }
}
