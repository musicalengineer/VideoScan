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
        #expect(R.layoutApartBytes == 67_108_864)
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
    @Test(.timeLimit(.minutes(2)))
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
        #expect(elapsed < .seconds(60), "10 min of stereo took \(elapsed) (Debug build)")
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
