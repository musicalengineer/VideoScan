// CheckMediaFullTierTests.swift
// Check Media's broadened full tier (Rick 2026-10-07: "the full check
// should do as much as possible and it is OK to wait").
//
//   * LOGIC — packet census tallies and their rows (timing, keyframes,
//     data rate, sync, whole-file Layout, row merging); sound levels
//     (loudness parse, DC, clipping runs, channel relation); colour labels
//     vs luma; timecode validity; decode-error times.
//   * MEDIA — synthetic `test_*` fixtures through the real passes, one per
//     new check (a 3 s timestamp jump, a single keyframe, late sound, a
//     timecode track, a full-range label on limited content, mono-as-
//     stereo, an inverted channel, DC offset, hard clipping, a very quiet
//     track), and the five-container matrix through the FULL tier: no new
//     row may warn on a healthy file.
//   * SCALE — the census over 200,000 synthetic packets inside a budget.
//   * Opt-in throughput: TEST_RUNNER_VS_CHECKMEDIA_FULL_PATH (READ-ONLY)
//     prints the full card, the time and the MB/s for the MFO's ETA.

import Testing
import Foundation
@testable import VideoScan

private typealias R = CheckMediaRules

// MARK: - Census (logic)

private func line(pts: Double, dts: Double? = nil, dur: Double = 0.04, size: Int = 1_000,
                  pos: Int64, key: Bool = false) -> String {
    "pts_time=\(pts)|dts_time=\(dts ?? pts)|duration_time=\(dur)|size=\(size)|pos=\(pos)|flags=\(key ? "K_" : "__")"
}

@Suite("Check Media — packet census")
struct CheckMediaCensusTests {

    @Test func packetLineParses() throws {
        let p = try #require(CensusPacket.parse(line(pts: 1.5, size: 77, pos: 900, key: true)))
        #expect(p.pts == 1.5 && p.size == 77 && p.pos == 900 && p.isKey)
        #expect(CensusPacket.parse("garbage") == nil)
    }

    @Test func timingFindsBackwardsAndGaps() {
        var t = StreamTimingTally()
        for (i, d) in [0.0, 0.04, 0.08, 0.06, 3.5, 3.54].enumerated() {
            t.observe(CensusPacket(pts: d, dts: d, duration: 0.04, size: 1, pos: Int64(i)))
        }
        #expect(t.backwards.occurrences == 1)
        #expect(t.gaps.occurrences == 1 && abs(t.largestGapSeconds - 3.38) < 0.001)
        #expect(t.firstSeconds == 0 && abs((t.endSeconds ?? 0) - 3.58) < 1e-9)
    }

    @Test func bFrameReorderWithoutDtsIsNotBackwards() {
        var t = StreamTimingTally()
        for p in [0.0, 0.12, 0.04, 0.08, 0.24, 0.16] { t.observe(CensusPacket(pts: p, duration: 0.04, size: 1)) }
        #expect(t.backwards.occurrences < 1)
    }

    @Test func keyframesAndDataRate() {
        var k = KeyframeTally(), r = DataRateTally()
        for i in 0..<250 {
            let t = Double(i) * 0.04
            let p = CensusPacket(pts: t, dts: t, duration: 0.04, size: (4...5).contains(Int(t)) ? 0 : 5_000,
                                 pos: Int64(i), isKey: i % 125 == 0)
            k.observe(p); r.observe(p)
        }
        #expect(k.keyframes == 2 && abs(k.longestGapSeconds - 5) < 1e-9)
        #expect(r.emptySeconds.occurrences == 2 && r.emptySeconds.firstSeconds == [4, 5])
        let median: Int64? = r.spread?.median
        #expect(median == 1_000_000, "25 packets/s × 5,000 B × 8 bits")
    }

    @Test func wholeFileLayoutInterleavedVersusSeparated() {
        func census(soundOffset: Int64) -> PacketCensusReport {
            var c = PacketCensus()
            for i in 0..<300 { _ = c.notePicture(line: line(pts: Double(i) / 30, size: 900_000, pos: Int64(i) * 1_000_000)) }
            for i in 0..<470 {
                _ = c.noteSound(line: line(pts: Double(i) * 0.0213, size: 6_144, pos: Int64(Double(i) * 0.0213 * 30) * 1_000_000 + 950_000 + soundOffset))
            }
            return c.report
        }
        let near = census(soundOffset: 0).layout
        #expect(near?.farApart == 0 && (near?.soundPackets ?? 0) > 400)
        #expect(R.checkFullLayout(.success(census(soundOffset: 0)))?.verdict == .ok)
        let far = R.checkFullLayout(.success(census(soundOffset: 41_000_000_000)))
        #expect(far?.verdict == .problem)
        #expect(far?.sentence.hasPrefix("All the sound is stored away from its picture") == true, "\(far?.sentence ?? "")")
        #expect(R.checkFullLayout(.failure(CheckMediaSkip(reason: "x"))) == nil, "no census → keep the quick sample")
    }

    @Test func fullRowsReplaceQuickRowsOfTheSameKind() {
        let quick = [MediaCheck(kind: .bitrate, verdict: .ok, sentence: "a"),
                     MediaCheck(kind: .layout, verdict: .ok, sentence: "sampled")]
        let full = [MediaCheck(kind: .layout, verdict: .problem, sentence: "every packet"),
                    MediaCheck(kind: .keyframes, verdict: .ok, sentence: "k")]
        let merged = R.merging(quick, with: full)
        #expect(merged.map(\.kind) == [.bitrate, .layout, .keyframes])
        #expect(merged[1].sentence == "every packet")
    }

    @Test func censusRowsWording() throws {
        var facts = MediaFacts()
        var v = MediaStreamFacts(index: 0, kind: .video)
        v.avgFrameRateText = "25"
        v.durationSeconds = 10
        facts.streams = [v, MediaStreamFacts(index: 1, kind: .audio)]
        var report = PacketCensusReport()
        var vt = StreamTimingTally(), at = StreamTimingTally()
        vt.observe(CensusPacket(pts: 0, dts: 0, duration: 0.04, size: 1))
        at.observe(CensusPacket(pts: 1.2, dts: 1.2, duration: 0.02, size: 1))
        report.video = vt
        report.audio = at
        let sync = R.checkSync(.success(report), facts: facts)
        #expect(sync.verdict == .warning)
        #expect(sync.sentence == "The sound starts 1.2 s after the picture — voices may be out of step.")
        #expect(R.checkPacketTiming(nil).verdict == .notRun(reason: R.censusMissing))
    }

    /// SCALE: 200,000 packets (≈ 2 h of 25 fps picture + sound) in budget.
    @Test(.timeLimit(.minutes(2)))
    func censusAtTwoHundredThousandPackets() {
        var c = PacketCensus()
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for i in 0..<120_000 { _ = c.notePicture(line: line(pts: Double(i) / 25, pos: Int64(i) * 2_000, key: i % 12 == 0)) }
            for i in 0..<80_000 { _ = c.noteSound(line: line(pts: Double(i) * 0.06, dur: 0.06, size: 500, pos: Int64(i) * 3_000 + 1_000)) }
        }
        #expect(c.report.video?.packets == 120_000 && c.report.audio?.packets == 80_000)
        #expect(elapsed < .seconds(60), "census of 200k packets took \(elapsed) (Debug)")
    }
}

// MARK: - Levels, colour, timecode (logic)

@Suite("Check Media — levels, colour and timecode")
struct CheckMediaLevelsColourTimecodeTests {

    @Test func loudnessSummaryParses() {
        var l = LoudnessSummary()
        for s in ["Summary:", "Integrated loudness:", "I:         -19.6 LUFS", "Threshold: -29.9 LUFS",
                  "LRA:         8.3 LU", "Peak:       -0.3 dBFS"] { l = l.adding(line: s) }
        #expect(l.integratedLUFS == -19.6 && l.rangeLU == 8.3 && l.truePeakDBFS == -0.3)
    }

    @Test func channelRelationKinds() {
        func kind(_ f: (Int32) -> Int32) -> ChannelRelation.Kind {
            var c = ChannelRelation()
            for n in 0..<10_000 {
                let l = Int32(400_000_000 * sin(Double(n) * 0.0576))
                c.observe(left: l, right: f(l))
            }
            return c.kind
        }
        #expect(kind { $0 } == .identical)
        #expect(kind { -$0 } == .inverted)
        #expect(kind { $0 / 3 + 1_000_000 } == .independent)
    }

    @Test func clipRunsNeedThreePinnedSamples() {
        var c = ClipRunTracker(channels: 1)
        for x: Int32 in [0, .max, .max, 5, .max, .max, .max, .max, 0] { c.observe(x, channel: 0, at: 1) }
        #expect(c.runs.occurrences == 1)
    }

    @Test func levelRowsWording() {
        var l = SoundLevelReport(dcOffsets: [0.02, 0.0], channels: .inverted, correlation: -1, channelCount: 2)
        l.loudness = LoudnessSummary(integratedLUFS: -50, rangeLU: 2, truePeakDBFS: -30)
        #expect(R.checkLoudness(l).verdict == .warning && R.checkLoudness(l).sentence.hasPrefix("Very quiet"))
        #expect(R.checkDCOffset(l).verdict == .warning && R.checkDCOffset(l).sentence.contains("left"))
        #expect(R.checkChannels(l).verdict == .warning)
        l.channels = .identical
        #expect(R.checkChannels(l).sentence == "Both channels carry the same sound (mono stored as stereo).")
        #expect(R.levelChecks(nil, facts: MediaFacts()).allSatisfy { $0.verdict == .notRun(reason: "this file has no sound track") })
    }

    @Test func lumaAndErrorClockParse() {
        var s = MediaSignalScan()
        for l in ["[Parsed_metadata_5 @ 0x1] [info] frame:0 pts:0 pts_time:12.5",
                  "[Parsed_metadata_5 @ 0x1] [info] lavfi.signalstats.YMIN=2",
                  "[Parsed_metadata_6 @ 0x1] [info] lavfi.signalstats.YMAX=253",
                  "[h264 @ 0x2] [error] error while decoding MB 3 4"] { s = s.adding(line: l) }
        #expect(s.luma.frames == 1 && s.luma.darkest == 2 && s.luma.brightest == 253)
        #expect(s.errorClock.errors.firstSeconds == [12.5])
    }

    @Test func colourLabelsAgainstThePicture() {
        var facts = MediaFacts()
        var v = MediaStreamFacts(index: 0, kind: .video)
        v.height = 1080
        v.pixelFormat = "yuv420p"
        v.colour = MediaColourLabels(range: "tv", matrix: "smpte170m", transfer: nil, primaries: nil)
        facts.streams = [v]
        #expect(R.checkColour(facts, signals: nil).verdict == .warning, "HD with SD colour maths")
        facts.streams[0].colour = MediaColourLabels(range: "pc", matrix: "bt709", transfer: nil, primaries: nil)
        var limited = MediaSignalScan()
        limited.luma = LumaRangeScan(frames: 100, darkest: 16, brightest: 235)
        #expect(R.checkColour(facts, signals: limited).sentence.hasPrefix("Labelled full range"))
        facts.streams[0].colour = MediaColourLabels()
        #expect(R.checkColour(facts, signals: limited).verdict == .ok)
        facts.streams[0].colour = MediaColourLabels(range: "pc", matrix: nil, transfer: nil, primaries: nil)
        facts.streams[0].pixelFormat = "gbrp"
        #expect(R.checkColour(facts, signals: limited).verdict == .ok, "RGB is always full range")
    }

    @Test func timecodeRules() {
        #expect(R.isValidTimecode("01:00:00:00", fps: 29.97))
        #expect(R.isValidTimecode("00:59:59;29", fps: 29.97))
        #expect(!R.isValidTimecode("01:00:00:30", fps: 29.97))
        #expect(!R.isValidTimecode("25:00:00:00", fps: 25))
        var facts = MediaFacts()
        #expect(R.checkTimecode(facts).verdict == .notRun(reason: "the file carries no timecode"))
        var v = MediaStreamFacts(index: 0, kind: .video)
        v.timecode = "01:00:00:00"
        v.rFrameRateText = "30000/1001"
        var tc = MediaStreamFacts(index: 2, kind: .data)
        tc.timecode = "02:00:00:00"
        facts.streams = [v, tc]
        #expect(R.checkTimecode(facts).sentence.hasPrefix("The file's timecodes disagree"))
    }

    @Test func everyKindHasATitleAndATier() {
        #expect(MediaCheckKind.allCases.allSatisfy { MediaCheckKind.titles[$0] != nil })
        #expect(MediaCheckKind.fullTier.isSubset(of: Set(MediaCheckKind.allCases)))
        #expect(!MediaCheckKind.layout.isFullTier && MediaCheckKind.loudness.isFullTier)
    }
}

// MARK: - Fixtures through the real passes

private enum FullFixtures {
    static func dir() throws -> URL { try VerifyVideoTestMedia.makeScratchDir("cmfulltier") }

    /// 3 s stereo WAV, one Int16 pair per frame from `pair`.
    static func wav(_ name: String, in dir: URL, _ pair: (Int) -> (Int16, Int16)) throws -> String {
        let rate = 48_000, frames = 3 * rate
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + frames * 4))
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(2)
        u32(UInt32(rate)); u32(UInt32(rate * 4)); u16(4); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(frames * 4))
        for n in 0..<frames {
            let (l, r) = pair(n)
            withUnsafeBytes(of: l.littleEndian) { d.append(contentsOf: $0) }
            withUnsafeBytes(of: r.littleEndian) { d.append(contentsOf: $0) }
        }
        let url = dir.appendingPathComponent(name)
        try d.write(to: url)
        return url.path
    }

    static func tone(_ n: Int, _ amp: Double = 9_800, _ hz: Double = 440) -> Int16 {
        Int16(amp * sin(2 * .pi * hz * Double(n) / 48_000))
    }

    /// Sound-level rows for a WAV through the real sound pass.
    static func levelRows(_ path: String) async throws -> [MediaCheckKind: MediaCheck] {
        let facts = try #require(try? await CheckMediaProbe.facts(path: path).get())
        let r = try await CheckMediaProbe.soundContinuity(path: path, facts: facts)
        return Dictionary(uniqueKeysWithValues: R.levelChecks(r, facts: facts).map { ($0.kind, $0) })
    }

    /// Every full-tier row for a picture file through the real passes.
    static func fullRows(_ path: String) async throws -> [MediaCheckKind: MediaCheck] {
        let facts = try #require(try? await CheckMediaProbe.facts(path: path).get())
        let full = try await CheckMediaProbe.full(path: path, facts: facts)
        return Dictionary(uniqueKeysWithValues: R.fullChecks(full, facts: facts).map { ($0.kind, $0) })
    }
}

private typealias FX = FullFixtures

@Suite("Check Media — full tier fixtures", .serialized)
struct CheckMediaFullTierFixtureTests {

    @Test("sound: mono-as-stereo, inverted, DC, clipping, quiet, healthy", .timeLimit(.minutes(3)))
    func soundLevelFixtures() async throws {
        try #require(VerifyVideoTestMedia.toolsAvailable)
        let dir = try FX.dir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let healthy = try await FX.levelRows(FX.wav("test_cm_lv_ok.wav", in: dir) { (FX.tone($0), FX.tone($0, 9_800, 660)) })
        #expect(healthy.values.allSatisfy { $0.verdict == .ok }, "\(healthy.values.map(\.sentence))")
        let mono = try await FX.levelRows(FX.wav("test_cm_lv_mono.wav", in: dir) { (FX.tone($0), FX.tone($0)) })
        #expect(mono[.channels]?.sentence == "Both channels carry the same sound (mono stored as stereo).")
        let inverted = try await FX.levelRows(FX.wav("test_cm_lv_inv.wav", in: dir) { (FX.tone($0), -FX.tone($0)) })
        #expect(inverted[.channels]?.verdict == .warning)
        let dc = try await FX.levelRows(FX.wav("test_cm_lv_dc.wav", in: dir) { (FX.tone($0) + 1_600, FX.tone($0, 9_800, 660)) })
        #expect(dc[.dcOffset]?.verdict == .warning, "\(dc[.dcOffset]?.sentence ?? "")")
        let clip = try await FX.levelRows(FX.wav("test_cm_lv_clip.wav", in: dir) { n in
            let x = Int16(max(-32_767, min(32_767, 60_000 * sin(2 * .pi * 440 * Double(n) / 48_000))))
            return (x, x == 32_767 || x == -32_767 ? x : x / 2)
        })
        #expect(clip[.clipping]?.verdict == .warning, "\(clip[.clipping]?.sentence ?? "")")
        let quiet = try await FX.levelRows(FX.wav("test_cm_lv_quiet.wav", in: dir) { (FX.tone($0, 60), FX.tone($0, 60, 660)) })
        #expect(quiet[.loudness]?.sentence.hasPrefix("Very quiet") == true, "\(quiet[.loudness]?.sentence ?? "")")
    }

    @Test("picture: timestamp jump, one keyframe, late sound, timecode, full-range label", .timeLimit(.minutes(4)))
    func pictureAndSyncFixtures() async throws {
        try #require(VerifyVideoTestMedia.toolsAvailable)
        let dir = try FX.dir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = ["-f", "lavfi", "-i", "testsrc=duration=6:size=320x240:rate=25"]
        let tone = ["-f", "lavfi", "-i", "aevalsrc=0.5*sin(440*2*PI*t)|0.5*sin(987*2*PI*t):s=48000:d=6"]
        func make(_ name: String, _ args: [String]) throws -> String {
            let out = dir.appendingPathComponent(name).path
            try CleanupTestMedia.runFFmpeg(args, output: out)
            return out
        }
        let gap = try await FX.fullRows(make("test_cm_ft_gap.mkv", src + [
            "-vf", "setpts=PTS+gte(T\\,2)*3/TB", "-fps_mode", "passthrough",
            "-c:v", "libx264", "-preset", "ultrafast", "-bf", "0", "-an"]))
        #expect(gap[.packetTiming]?.verdict == .warning, "\(gap[.packetTiming]?.sentence ?? "")")
        #expect(gap[.dataRate]?.verdict == .warning, "\(gap[.dataRate]?.sentence ?? "")")
        let oneKey = try await FX.fullRows(make("test_cm_ft_onekey.mp4", [
            "-f", "lavfi", "-i", "testsrc=duration=15:size=160x120:rate=25", "-c:v", "libx264", "-preset", "ultrafast",
            "-g", "1000", "-keyint_min", "1000", "-sc_threshold", "0", "-an"]))
        #expect(oneKey[.keyframes]?.sentence.hasPrefix("Only the first frame is a keyframe") == true)
        let late = try await FX.fullRows(make("test_cm_ft_late.mov", src + ["-itsoffset", "1"] + tone + [
            "-map", "0:v", "-map", "1:a", "-c:v", "mpeg4", "-c:a", "pcm_s16le"]))
        #expect(late[.sync]?.verdict == .warning, "\(late[.sync]?.sentence ?? "")")
        let tc = try await FX.fullRows(make("test_cm_ft_tc.mov", src + tone + [
            "-c:v", "mpeg4", "-c:a", "pcm_s16le", "-timecode", "01:00:00:00"]))
        #expect(tc[.timecode]?.verdict == .ok && tc[.timecode]?.sentence.hasPrefix("Timecode starts at 01:00:00:00") == true)
        let pc = try await FX.fullRows(make("test_cm_ft_pc.mp4", src + [
            "-c:v", "libx264", "-preset", "ultrafast",
            "-bsf:v", "h264_metadata=video_full_range_flag=1", "-an"]))   // label only; content stays 16–235
        #expect(pc[.colour]?.sentence.hasPrefix("Labelled full range") == true, "\(pc[.colour]?.sentence ?? "")")
    }

    /// MEDIA MATRIX through the FULL tier: no new row may warn on a
    /// healthy file in any of the five containers.
    @Test("healthy matrix stays OK through the full tier", .timeLimit(.minutes(5)))
    func healthyMatrixFullTier() async throws {
        try #require(VerifyVideoTestMedia.toolsAvailable)
        let dir = try FX.dir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cases: [(String, String, [String], String, String)] = [
            ("test_cm_ftm.mp4", "libx264", ["-preset", "ultrafast"], "aac", "320x240"),
            ("test_cm_ftm.mov", "prores", [], "pcm_s16le", "320x240"),
            ("test_cm_ftm.mkv", "ffv1", [], "pcm_s16le", "320x240"),
            ("test_cm_ftm.mxf", "mpeg2video", ["-g", "15", "-aspect", "4:3"], "pcm_s16le", "720x576"),
            ("test_cm_ftm.avi", "dvvideo", ["-pix_fmt", "yuv411p", "-aspect", "4:3"], "pcm_s16le", "720x480"),
        ]
        for (name, codec, extra, audio, size) in cases {
            let path = try VerifyVideoTestMedia.generate(
                into: dir, name: name, videoCodec: codec, extraVideoArgs: extra, audioCodec: audio,
                size: size, rate: name.hasSuffix(".avi") ? "30000/1001" : "25", videoDuration: 4)
            let rows = try await FX.fullRows(path)
            for row in rows.values where row.verdict.rank >= MediaCheckVerdict.warning.rank {
                Issue.record("\(name) \(row.kind): \(row.sentence)")
            }
        }
    }
}

// MARK: - Throughput (opt-in)

/// TEST_RUNNER_VS_CHECKMEDIA_FULL_PATH → VS_CHECKMEDIA_FULL_PATH: a
/// healthy file (≈ 1 GB) for the full tier's throughput. READ-ONLY.
@Suite("Check Media — full tier throughput (opt-in)", .serialized)
struct CheckMediaFullTierThroughputTests {
    @Test(.timeLimit(.minutes(30)))
    func fullTierThroughput() async throws {
        guard let path = ProcessInfo.processInfo.environment["VS_CHECKMEDIA_FULL_PATH"], !path.isEmpty else { return }
        let clock = ContinuousClock()
        let started = clock.now
        guard case .measured(let q) = try await CheckMediaProbe.quick(path: path) else { Issue.record("unopenable"); return }
        let quickTime = clock.now - started
        let fullStarted = clock.now
        let full = try await CheckMediaProbe.full(path: path, facts: q.facts)
        let fullTime = clock.now - fullStarted
        let checks = R.merging(R.quickChecks(q), with: R.fullChecks(full, facts: q.facts))
        let card = R.card(tier: .full, checks: checks, quick: q, at: Date())
        let mb = Double(q.facts.sizeBytes ?? 0) / 1_000_000
        let seconds = Double(fullTime.components.seconds) + Double(fullTime.components.attoseconds) / 1e18
        print("CHECKMEDIA-FULL quick=\(quickTime) full=\(fullTime) size=\(Int(mb)) MB throughput=\(String(format: "%.0f", mb / max(seconds, 0.001))) MB/s\n"
              + R.text(of: card) + "\nCHECKMEDIA-FULL-END")
    }
}
