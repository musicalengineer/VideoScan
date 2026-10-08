// CheckMediaTests.swift
// Check Media (Rick 2026-10-07) — LOGIC, ISOLATION, SCALE and SENSOR
// dimensions. The media matrix lives in CheckMediaMediaMatrixTests.swift.
//
//   * Facts: ffprobe JSON → MediaFacts (sample count, bit depth, cover art).
//   * Quick rules, one per check, on canned numbers — including the
//     CapeCod-class numbers measured read-only on 2026-10-07 (no file path
//     or media in git; the numbers are the evidence).
//   * Full rules: decode mapping, black / freeze shares, interlace label,
//     sound (damaged / silent / clipping), the signal-line parser.
//   * Card persistence: Codable round trip (the `.notRun(reason:)` payload
//     survives), legacy records decode nil, the DTO writes the key only
//     when present, clone parity, an unreadable card never fails a record.
//   * Job (through its runner seams): card + verify fields persisted onto
//     the CURRENT record, a failed read persists nothing, the audio
//     diagnosis lands in the Center cache, the summary line.
//   * ⌘I: which item File ▸ offers; one publisher per focused value.

import Testing
import Foundation
@testable import VideoScan

// MARK: - Fixtures (numbers only)

enum CheckMediaFixtures {

    /// The CapeCod-class header (measured 2026-10-07; the stream fields
    /// ffprobe printed, file name and tags of family significance left out).
    static let capeCodJSON = #"""
    {"streams":[
      {"index":0,"codec_name":"h264","profile":"High","codec_type":"video","width":640,"height":480,
       "sample_aspect_ratio":"1:1","display_aspect_ratio":"4:3","pix_fmt":"yuv420p","field_order":"progressive",
       "r_frame_rate":"90000/1","avg_frame_rate":"1872360289/31206","time_base":"1/90000","start_time":"0.000000",
       "duration_ts":3239377,"duration":"35.993078","bit_rate":"9633376030","bits_per_raw_sample":"8",
       "nb_frames":"2159585","disposition":{"attached_pic":0}},
      {"index":1,"codec_name":"aac","profile":"LC","codec_type":"audio","sample_fmt":"fltp","sample_rate":"48000",
       "channels":2,"channel_layout":"stereo","bits_per_sample":0,"r_frame_rate":"0/0","avg_frame_rate":"0/0",
       "time_base":"1/48000","start_time":"0.000000","duration_ts":1759200,"duration":"36.650000",
       "bit_rate":"379989","nb_frames":"1720","disposition":{"attached_pic":0}}],
     "format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2","format_long_name":"QuickTime / MOV","start_time":"0.000000",
       "duration":"36.650000","size":"43370703217","bit_rate":"9467002066","tags":{"encoder":"HandBrake 1.9.2 2025022300"}}}
    """#

    /// A healthy 29.97 fps SD clip with matching sound.
    static let healthyJSON = #"""
    {"streams":[
      {"index":0,"codec_name":"dvvideo","codec_type":"video","width":720,"height":480,
       "sample_aspect_ratio":"8:9","display_aspect_ratio":"4:3","pix_fmt":"yuv411p","field_order":"bb",
       "r_frame_rate":"30000/1001","avg_frame_rate":"30000/1001","time_base":"1/30000","start_time":"0.000000",
       "duration":"600.600000","bit_rate":"28771200","nb_frames":"18000","disposition":{"attached_pic":0}},
      {"index":1,"codec_name":"pcm_s16le","codec_type":"audio","sample_fmt":"s16","sample_rate":"48000",
       "channels":2,"channel_layout":"stereo","bits_per_sample":16,"time_base":"1/48000","start_time":"0.000000",
       "duration_ts":28828800,"duration":"600.600000","disposition":{"attached_pic":0}}],
     "format":{"format_name":"avi","format_long_name":"AVI (Audio Video Interleaved)","duration":"600.600000",
       "size":"2230000000","bit_rate":"29700000"}}
    """#

    static func quick(_ json: String, packets: MediaPacketScan? = nil,
                      distinct: DistinctFrameSample? = nil,
                      layout: MediaLayoutSample? = nil) throws -> CheckMediaQuickInputs {
        let data = Data(json.utf8)
        return CheckMediaQuickInputs(facts: try MediaFacts.parse(probeJSON: data),
                                     videoFacts: try VerifyVideoRules.facts(fromProbeJSON: data),
                                     packets: packets, distinct: distinct, layout: layout)
    }

    /// DV-style: each frame's sound right after its picture.
    static func interleavedLayout() -> MediaLayoutSample {
        MediaLayoutSample(windows: [MediaLayoutMeasure(startSeconds: 0, separationBytes: 120_000,
                                                       longestRunSeconds: 0.03)])
    }

    /// 300 packets 1–2 ticks apart at 1/90000, a 235 KB keyframe every 12.
    static func capeCodPackets() -> MediaPacketScan {
        var rows: [MediaPacketRow] = []
        var t = 18.0, pos: Int64 = 21_548_661_470
        for i in 0..<300 {
            let step = (i % 2 == 0 ? 1.0 : 2.0) / 90_000
            let size = i % 12 == 0 ? 235_587 : 160
            rows.append(MediaPacketRow(pts: t, dts: t, duration: step, size: size, pos: pos))
            t += step
            pos += Int64(size)
        }
        let tail = [MediaPacketRow(pts: 35.99, dts: 35.99, duration: 1.0 / 90_000, size: 158,
                                   pos: 43_370_600_000)]
        return MediaPacketScan.summarize(windows: [rows], tail: tail)
    }

    static func capeCodDistinct() -> DistinctFrameSample {
        DistinctFrameSample(windows: [.init(offsetSeconds: 3.6, framesIn: 300, framesKept: 1),
                                      .init(offsetSeconds: 18.0, framesIn: 300, framesKept: 1),
                                      .init(offsetSeconds: 31.0, framesIn: 300, framesKept: 1)])
    }

    /// 300 packets at a steady 29.97 fps.
    static func healthyPackets(fileSize: Int64 = 2_230_000_000) -> MediaPacketScan {
        let step = 1001.0 / 30_000
        let rows = (0..<300).map { i in
            MediaPacketRow(pts: Double(i) * step, dts: Double(i) * step, duration: step,
                           size: 120_000, pos: Int64(i) * 120_000)
        }
        let tail = [MediaPacketRow(pts: 600.5, dts: 600.5, duration: step, size: 120_000, pos: fileSize - 200_000)]
        return MediaPacketScan.summarize(windows: [rows], tail: tail)
    }

    static func healthyDistinct() -> DistinctFrameSample {
        DistinctFrameSample(windows: [.init(offsetSeconds: 60, framesIn: 300, framesKept: 296),
                                      .init(offsetSeconds: 300, framesIn: 300, framesKept: 288)])
    }

    static func capeCod() throws -> CheckMediaQuickInputs {
        try quick(capeCodJSON, packets: capeCodPackets(), distinct: capeCodDistinct())
    }

    static func healthy() throws -> CheckMediaQuickInputs {
        try quick(healthyJSON, packets: healthyPackets(), distinct: healthyDistinct(),
                  layout: interleavedLayout())
    }
}

private typealias F = CheckMediaFixtures
private typealias R = CheckMediaRules

private func verdicts(_ checks: [MediaCheck]) -> [MediaCheckKind: MediaCheckVerdict] {
    Dictionary(uniqueKeysWithValues: checks.map { ($0.kind, $0.verdict) })
}

// MARK: - Facts

@Suite("Check Media — facts parser")
struct CheckMediaFactsTests {

    @Test func capeCodHeaderParses() throws {
        let f = try MediaFacts.parse(probeJSON: Data(F.capeCodJSON.utf8))
        #expect(f.sizeBytes == 43_370_703_217)
        #expect(f.durationSeconds == 36.65)
        #expect(f.encoder.hasPrefix("HandBrake 1.9.2"))
        let v = try #require(f.video)
        #expect(v.rFrameRate == 90_000)
        #expect(v.frameCount == 2_159_585)
        #expect(v.timeBase == "1/90000")
        #expect(v.fieldOrder == "progressive")
        let a = try #require(f.audio)
        #expect(a.sampleRate == 48_000 && a.channels == 2 && a.channelLayout == "stereo")
        #expect(a.sampleCount == 1_759_200, "duration_ts in a 1/48000 time base IS the sample count")
        #expect(a.bitDepth == 32, "fltp → 32-bit float")
        #expect(f.impliedBitRate.map { $0 > 9_000_000_000 } == true, "≈ 9.5 Gbit/s")
    }

    @Test func coverArtIsNotThePicture() throws {
        let json = #"{"streams":[{"index":0,"codec_type":"video","codec_name":"mjpeg","width":600,"height":600,"disposition":{"attached_pic":1}},{"index":1,"codec_type":"audio","codec_name":"mp3","sample_rate":"44100","channels":2}],"format":{"format_name":"mp3"}}"#
        let f = try MediaFacts.parse(probeJSON: Data(json.utf8))
        #expect(f.video == nil)
        #expect(f.audio?.sampleCount == nil, "no duration_ts → never guessed")
    }

    @Test func unreadableJSONThrows() {
        #expect(throws: MediaFacts.ParseError.unreadable) { try MediaFacts.parse(probeJSON: Data("nope".utf8)) }
    }

    @Test func factsRowsName_rFrameRateAndAverage() throws {
        let f = try MediaFacts.parse(probeJSON: Data(F.capeCodJSON.utf8))
        let rows = MediaFactsRows.stream(try #require(f.video))
        #expect(rows.contains { $0.0 == "Frame rate (r_frame_rate)" && $0.1 == "90000/1 (90,000 fps)" })
        #expect(rows.contains { $0.0 == "Frames" && $0.1 == "2,159,585" })
        #expect(MediaFactsRows.container(f).contains { $0.0 == "Implied bitrate" && $0.1.hasSuffix("Gbit/s") })
    }
}

// MARK: - Quick rules

@Suite("Check Media — quick rules")
struct CheckMediaQuickRuleTests {

    @Test func capeCodClassIsAProblemOnEveryTimingCheck() throws {
        let v = verdicts(R.quickChecks(try F.capeCod()))
        #expect(v[.bitrate] == .problem)
        #expect(v[.frameRate] == .problem)
        #expect(v[.timestamps] == .problem)
        #expect(v[.distinctFrames] == .problem)
        #expect(v[.avDuration] == .ok, "0.66 s of 36.65 s is within tolerance")
        #expect(v[.audioSamples] == .ok)
        #expect(v[.aspect] == .ok, "640×480 square pixels is right for 640×480")
        #expect(v[.truncation] == .ok)
    }

    @Test func capeCodHeadlineIsThePlainSentence() throws {
        let q = try F.capeCod()
        let card = R.card(tier: .quick, checks: R.quickChecks(q) + R.fullRowsNotRun(), quick: q, at: Date())
        #expect(card.headline == "Plays, but its timing is broken: ~60,000 fps — each real frame is stored ~2,000 times.")
        #expect(card.verdict == .problem)
    }

    @Test func healthyClipIsOKEverywhere() throws {
        let checks = R.quickChecks(try F.healthy())
        for c in checks { #expect(c.verdict == .ok, "\(c.kind): \(c.sentence)") }
        let card = R.card(tier: .quick, checks: checks + R.fullRowsNotRun(), quick: try F.healthy(), at: Date())
        #expect(card.verdict == .ok)
        #expect(card.headline == MediaReportCard.quickPassHeadline,
                "a quick pass never claims the file is healthy (Rick 2026-10-07)")
    }

    @Test func audioOnlyFileSkipsPictureChecksWithAReason() throws {
        let json = #"{"streams":[{"index":0,"codec_type":"audio","codec_name":"pcm_s16le","sample_rate":"48000","channels":2,"time_base":"1/48000","duration_ts":480000,"duration":"10.0"}],"format":{"format_name":"wav","duration":"10.0","size":"1920044"}}"#
        let v = verdicts(R.quickChecks(try F.quick(json)))
        #expect(v[.frameRate] == .notRun(reason: R.noPicture))
        #expect(v[.audioSamples] == .ok)
    }

    @Test func squarePixelSDIsAWarning() throws {
        let json = F.healthyJSON.replacingOccurrences(of: #""sample_aspect_ratio":"8:9""#, with: #""sample_aspect_ratio":"1:1""#)
        let c = R.checkAspect(try F.quick(json))
        #expect(c.verdict == .warning)
        #expect(c.sentence.contains("12 % too wide"))
    }

    @Test func mislabelledSampleRateIsAProblem() throws {
        // 48 kHz worth of samples labelled 44.1 kHz: 600.6 s × 48,000.
        let json = F.healthyJSON
            .replacingOccurrences(of: #""sample_rate":"48000""#, with: #""sample_rate":"44100""#)
            .replacingOccurrences(of: #""time_base":"1/48000""#, with: #""time_base":"1/44100""#)
        let c = R.checkAudioSamples(try F.quick(json))
        #expect(c.verdict == .problem, "\(c.sentence)")
        #expect(c.sentence.contains("48 kHz sound labelled as 44.1 kHz"))
    }

    @Test func avLengthTolerances() throws {
        func check(audio: String) throws -> MediaCheckVerdict {
            let json = F.healthyJSON.replacingOccurrences(of: #""duration_ts":28828800,"duration":"600.600000""#,
                                                          with: #""duration_ts":28828800,"duration":"\#(audio)""#)
            return R.checkAVDuration(try F.quick(json)).verdict
        }
        #expect(try check(audio: "600.100000") == .ok, "0.5 s on 10 min")
        #expect(try check(audio: "598.000000") == .warning, "2.6 s")
        #expect(try check(audio: "500.000000") == .problem, "100 s, 17 %")
    }

    @Test func truncatedFileIsAProblem() throws {
        // The last sampled frame ends at ~2.0 GB but the file on disk is 1.9 GB.
        var q = try F.healthy()
        q.packets = F.healthyPackets(fileSize: 2_000_000_000)
        q.facts.sizeBytes = 1_900_000_000
        #expect(R.checkTruncation(q).verdict == .problem)
    }

    @Test func repeatsWithoutAnAbsurdRateAreOnlyAWarning() throws {
        var q = try F.healthy()
        q.distinct = DistinctFrameSample(windows: [.init(offsetSeconds: 10, framesIn: 300, framesKept: 3)])
        let c = R.checkDistinctFrames(q)
        #expect(c.verdict == .warning, "a slideshow repeats frames too")
    }

    @Test func tinyWindowsDontCount() throws {
        var q = try F.healthy()
        q.distinct = DistinctFrameSample(windows: [.init(offsetSeconds: 0, framesIn: 10, framesKept: 1)])
        guard case .notRun = R.checkDistinctFrames(q).verdict else {
            Issue.record("a 10-frame window must not judge"); return
        }
    }

    @Test func variableFrameRateIsAWarning() throws {
        var rows: [MediaPacketRow] = []
        var t = 0.0
        for i in 0..<300 {
            let d = i % 3 == 0 ? 0.1 : 0.01
            rows.append(MediaPacketRow(pts: t, dts: t, duration: d, size: 9_000, pos: Int64(i) * 9_000))
            t += d
        }
        var q = try F.healthy()
        q.packets = MediaPacketScan.summarize(windows: [rows], tail: [])
        #expect(R.checkTimestamps(q).verdict == .warning)
    }

    @Test func packetParserReadsDurationAndPos() {
        let rows = MediaPacketRow.rows(fromCompact: "pts_time=17.999867|dts_time=17.999867|duration_time=0.000011|size=235587|pos=21548661470\npts_time=N/A|dts_time=N/A|duration_time=N/A|size=12|pos=N/A\n")
        #expect(rows.count == 2)
        #expect(rows[0].pos == 21_548_661_470 && rows[0].duration == 0.000011)
        #expect(rows[1].pts == nil && rows[1].size == 12)
    }

    @Test func progressParserTakesTheLastFrameLine() {
        #expect(DistinctFrameSample.framesWritten(fromProgress: "frame=0\nfps=0\nframe=1\nprogress=end\n") == 1)
        #expect(DistinctFrameSample.framesWritten(fromProgress: "progress=end\n") == nil)
    }

    @Test func distinctOffsetsStayInsideTheFile() {
        #expect(CheckMediaProbe.distinctOffsets(durationSeconds: 10, fps: 30, frames: 300) == [0])
        let o = CheckMediaProbe.distinctOffsets(durationSeconds: 600, fps: 29.97, frames: 300)
        #expect(o.count == 3 && o.allSatisfy { $0 + 300 / 29.97 < 600 })
        #expect(CheckMediaProbe.framesIn(offset: 590, durationSeconds: 600, fps: 10, asked: 300, kept: 5) == 100)
    }

    @Test func argumentBuildersAreReadOnly() {
        let all = CheckMediaProbe.headerArgs(input: "/x.mov")
            + CheckMediaProbe.packetArgs(input: "/x.mov", startSeconds: 1, maxPackets: 300)
            + CheckMediaProbe.distinctArgs(input: "/x.mov", offsetSeconds: 1, frames: 300)
        #expect(!all.contains("-y"), "never overwrite anything")
        #expect(CheckMediaProbe.distinctArgs(input: "/x.mov", offsetSeconds: 1, frames: 300)
            .contains("trim=end_frame=300,mpdecimate"))
        #expect(CheckMediaProbe.distinctArgs(input: "/x.mov", offsetSeconds: 1, frames: 300).suffix(6)
            .contains("null"), "decodes to the null muxer only")
    }
}

// MARK: - Full rules

@Suite("Check Media — full rules")
struct CheckMediaFullRuleTests {

    private func facts() throws -> MediaFacts { try F.healthy().facts }

    @Test func signalLinesParse() {
        var s = MediaSignalScan()
        for line in [
            "[Parsed_idet_0 @ 0x1] [info] Multi frame detection: TFF:     0 BFF:     0 Progressive:     0 Undetermined:     0",
            "[Parsed_freezedetect_2 @ 0x2] [info] lavfi.freezedetect.freeze_duration: 1.5015",
            "[Parsed_blackdetect_1 @ 0x3] [info] black_start:1.001 black_end:2.5025 black_duration:1.5015",
            "[Parsed_idet_0 @ 0x4] [info] Multi frame detection: TFF:     3 BFF:   200 Progressive:    90 Undetermined:    29",
        ] { s = s.adding(line: line) }
        #expect(s.blackStretches == 1 && abs(s.blackSeconds - 1.5015) < 1e-9)
        #expect(s.freezeStretches == 1)
        #expect(s.topFieldFirst == 3 && s.bottomFieldFirst == 200 && s.progressive == 90, "the LAST idet report wins")
    }

    @Test func levelTaggedErrorLinesAreRecognised() {
        #expect(VerifyVideoProbe.logLevel(ofTaggedLine: "[h264 @ 0x1] [error] error while decoding MB 1 1") == "error")
        #expect(VerifyVideoProbe.logLevel(ofTaggedLine: "[Parsed_idet_0 @ 0x1] [info] Multi frame") == "info")
        #expect(VerifyVideoRules.cleanErrorLine(VerifyVideoProbe.strippingLevelTag("[h264 @ 0x1] [error] bad MB"))
            == "h264: bad MB")
        #expect(VerifyVideoProbe.decodeWithSignalsArgs(input: "/x").contains(R.signalFilterChain))
        #expect(!VerifyVideoProbe.decodeArgs(input: "/x").contains(R.signalFilterChain), "Verify Video unchanged")
    }

    @Test func blackAndFreezeShares() throws {
        let f = try facts()   // 600.6 s
        #expect(R.checkBlack(MediaSignalScan(blackStretches: 3, blackSeconds: 12), facts: f).verdict == .ok)
        #expect(R.checkBlack(MediaSignalScan(blackStretches: 1, blackSeconds: 400), facts: f).verdict == .warning)
        #expect(R.checkFreeze(MediaSignalScan(freezeStretches: 1, freezeSeconds: 600), facts: f).verdict == .problem)
        guard case .notRun = R.checkBlack(nil, facts: f).verdict else { Issue.record("no decode → not run"); return }
    }

    @Test func interlaceLabelMismatch() throws {
        var f = try facts()
        f.streams[0].fieldOrder = "progressive"
        let interlaced = MediaSignalScan(topFieldFirst: 0, bottomFieldFirst: 900, progressive: 50)
        #expect(R.checkInterlace(interlaced, facts: f).verdict == .warning)
        f.streams[0].fieldOrder = "bb"
        #expect(R.checkInterlace(interlaced, facts: f).verdict == .ok)
        let progressive = MediaSignalScan(topFieldFirst: 0, bottomFieldFirst: 2, progressive: 900)
        #expect(R.checkInterlace(progressive, facts: f).verdict == .warning)
    }

    @Test func decodeMapping() throws {
        let q = try F.healthy()
        var d = VideoVerifyDiagnosis(findings: [], facts: q.videoFacts, sample: nil,
                                     decode: VideoDecodeFacts(coverage: .complete, errorCount: 0))
        #expect(R.checkDecode(.success(d)).verdict == .ok)
        d.decode = VideoDecodeFacts(coverage: .complete, errorCount: 500)
        #expect(R.checkDecode(.success(d)).verdict == .problem)
        #expect(R.checkDecode(.failure(CheckMediaSkip(reason: "drive gone"))).verdict == .notRun(reason: "drive gone"))
        d.decode = VerifyVideoProbe.skippedAsPointless(q.videoFacts)
        guard case .notRun = R.checkDecode(.success(d)).verdict else { Issue.record("skipped decode is not OK"); return }
    }

    @Test func soundVerdicts() throws {
        let f = try facts()
        let shape = AudioVerifyShape()
        func diag(_ channels: [AudioChannelLevels], findings: [AudioVerifyFinding] = []) -> AudioVerifyDiagnosis {
            var d = AudioVerifyDiagnosis(findings: findings, shape: shape, balanceAnalysis: nil)
            if !channels.isEmpty {
                let streamShape = AudioBalanceStreamShape(
                    videoCodec: "dvvideo", totalStreams: 2, videoStreams: 1, audioStreams: 1,
                    audioCodec: "pcm_s16le", audioChannels: channels.count, audioBitRate: nil,
                    durationSeconds: 600.6,
                    audioStreamInfos: [AudioBalanceStreamInfo(absoluteIndex: 1, codec: "pcm_s16le",
                                                              channels: channels.count, bitRate: nil)])
                d.balanceAnalysis = AudioBalanceAnalysis(
                    classification: .trueStereo,
                    measurements: AudioBalanceMeasurements(channels: channels, differenceRMSDBFS: nil),
                    shape: streamShape, programStreamCount: 1, programStreamIndex: 1,
                    droppedStreamIndices: [])
            }
            return d
        }
        let healthy = diag([.init(rmsDBFS: -18, peakDBFS: -3), .init(rmsDBFS: -19, peakDBFS: -4)])
        let ok = R.checkSound(.success(healthy), facts: f)
        #expect(ok.verdict == .ok)
        #expect(ok.evidence.map(\.label) == ["Left", "Right"], "per-channel loudness is evidence")
        #expect(R.checkSound(.success(diag([.init(rmsDBFS: -.infinity, peakDBFS: -.infinity)])), facts: f).verdict == .warning)
        #expect(R.checkSound(.success(diag([.init(rmsDBFS: -12, peakDBFS: 0)])), facts: f).verdict == .warning)
        let damaged = diag([], findings: [.unsupportedCodec(codec: "qdm2", decodable: false)])
        #expect(R.checkSound(.success(damaged), facts: f).verdict == .problem)
    }
}

// MARK: - Card persistence

@Suite("Check Media — card persistence")
struct CheckMediaCardPersistenceTests {

    private func card() throws -> MediaReportCard {
        let q = try F.capeCod()
        return R.card(tier: .quick, checks: R.quickChecks(q) + R.fullRowsNotRun(), quick: q,
                      at: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func cardRoundTripsWithNotRunReasons() throws {
        let c = try card()
        let back = try JSONDecoder().decode(MediaReportCard.self, from: JSONEncoder().encode(c))
        #expect(back == c)
        #expect(back.check(.decode)?.verdict == .notRun(reason: "quick check only — the full check decodes every frame and listens to every sample"))
    }

    @Test func recordWithoutACardStaysKeyless() throws {
        let r = VideoRecord()
        r.filename = "a.mov"
        let json = try String(decoding: JSONEncoder().encode(VideoRecordDTO(r)), as: UTF8.self)
        #expect(!json.contains("mediaReportCard"), "never-checked records round-trip byte-identical")
        let back = try JSONDecoder().decode(VideoRecord.self, from: Data(json.utf8))
        #expect(back.mediaReportCard == nil)
    }

    @Test func recordWithACardRoundTripsAndClones() throws {
        let r = VideoRecord()
        r.filename = "a.mov"
        r.mediaReportCard = try card()
        let back = try JSONDecoder().decode(VideoRecord.self, from: JSONEncoder().encode(VideoRecordDTO(r)))
        #expect(back.mediaReportCard == r.mediaReportCard)
        #expect(r.snapshotClone().mediaReportCard == r.mediaReportCard)
    }

    /// ISOLATION: a card this build can't read (a future check kind) reads
    /// as absent — it never fails the record, so it never fails the catalog.
    @Test func unreadableCardNeverFailsTheRecord() throws {
        let r = VideoRecord()
        r.filename = "a.mov"
        r.audioVerifyStatus = "ok"
        r.mediaReportCard = try card()
        var json = try String(decoding: JSONEncoder().encode(VideoRecordDTO(r)), as: UTF8.self)
        json = json.replacingOccurrences(of: "\"bitrate\"", with: "\"aCheckFromTheFuture\"")
        let back = try JSONDecoder().decode(VideoRecord.self, from: Data(json.utf8))
        #expect(back.mediaReportCard == nil)
        #expect(back.audioVerifyStatus == "ok", "the rest of the record is intact")
    }

    @Test func aCardForAnotherSizeIsStale() throws {
        let c = try card()
        #expect(c.isCurrent(forSizeBytes: 43_370_703_217))
        #expect(!c.isCurrent(forSizeBytes: 39_000_000))
    }
}

// MARK: - Job (runner seams)

@Suite("CheckMediaJob — persistence and summary", .serialized)
@MainActor
struct CheckMediaJobTests {

    private func record(_ name: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = "/Volumes/T/\(name)"
        r.directory = "/Volumes/T"
        return r
    }

    @Test func quickCheckPersistsCardAndTheConclusiveVideoVerdict() async throws {
        let model = VideoScanModel()
        let rec = record("test_cm_job.mp4")
        model.records = [rec]
        let quick = try F.capeCod()
        let job = CheckMediaJob(records: [rec], tier: .quick, model: model, center: nil,
                                quickRunner: { _, _ in .measured(quick) })
        job.start()
        await job.task?.value
        let card = try #require(rec.mediaReportCard)
        #expect(card.verdict == .problem)
        #expect(rec.videoVerifyStatus == "broken", "the quick tier settles the picture exactly as Verify Video would")
        #expect(rec.videoVerifyNote.hasPrefix(VerifyVideoRules.brokenNotePrefix))
        #expect(rec.audioVerifyStatus.isEmpty, "a quick check never claims a sound verdict")
        guard case .finished(let summary) = job.state else { Issue.record("\(job.state)"); return }
        #expect(summary.hasPrefix("Problem — Plays, but its timing is broken"))
    }

    @Test func healthyQuickCheckLeavesVerifyFieldsAlone() async throws {
        let model = VideoScanModel()
        let rec = record("test_cm_ok.avi")
        model.records = [rec]
        let quick = try F.healthy()
        let job = CheckMediaJob(records: [rec], tier: .quick, model: model, center: nil,
                                quickRunner: { _, _ in .measured(quick) })
        job.start()
        await job.task?.value
        #expect(rec.mediaReportCard?.verdict == .ok)
        #expect(rec.videoVerifyStatus.isEmpty, "a decode could still change it — no verdict without one")
    }

    @Test func aFailedReadPersistsNothing() async throws {
        let model = VideoScanModel()
        let rec = record("test_cm_gone.mov")
        model.records = [rec]
        let job = CheckMediaJob(records: [rec], tier: .full, model: model, center: nil,
                                quickRunner: { _, _ in throw CheckMediaProbe.ProbeError.couldNotRead("the drive went away") })
        job.start()
        await job.task?.value
        #expect(rec.mediaReportCard == nil)
        #expect(rec.videoVerifyStatus.isEmpty && rec.audioVerifyStatus.isEmpty)
        guard case .failed(let why) = job.items[0].outcome else { Issue.record("\(job.items[0].outcome)"); return }
        #expect(why == "the drive went away")
        guard case .finished(let summary) = job.state else { Issue.record("\(job.state)"); return }
        #expect(summary == "0 checked — 1 couldn't be checked")
    }

    @Test func fullCheckWritesSoundVerdictAndFillsTheCenterCache() async throws {
        let model = VideoScanModel()
        let center = MediaFileOperationsCenter()
        let rec = record("test_cm_full.avi")
        model.records = [rec]
        let quick = try F.healthy()
        let audio = AudioVerifyDiagnosis(findings: [], shape: AudioVerifyShape(), balanceAnalysis: nil)
        let video = VideoVerifyDiagnosis(findings: [], facts: quick.videoFacts, sample: nil,
                                         decode: VideoDecodeFacts(coverage: .complete))
        let job = CheckMediaJob(records: [rec], tier: .full, model: model, center: center,
                                quickRunner: { _, _ in .measured(quick) },
                                fullRunner: { _, _, _, _ in
                                    CheckMediaFullInputs(video: .success(video), audio: .success(audio),
                                                         signals: MediaSignalScan(progressive: 900))
                                })
        job.start()
        await job.task?.value
        #expect(rec.audioVerifyStatus == "ok")
        #expect(rec.videoVerifyStatus == "ok")
        #expect(center.verifyDiagnosis(forRecordID: rec.id) != nil, "the Angel's prepare step reads this cache")
        #expect(rec.mediaReportCard?.tier == .full)
        #expect(rec.mediaReportCard?.check(.decode)?.verdict == .ok)
    }

    /// A rescan replaced the record instance mid-run: the verdict lands on
    /// the CURRENT catalog object (the Verify jobs' rule).
    @Test func persistsOntoTheCurrentRecordInstance() async throws {
        let model = VideoScanModel()
        let original = record("test_cm_rescan.mp4")
        let replacement = original.snapshotClone()
        model.records = [replacement]
        let quick = try F.capeCod()
        let job = CheckMediaJob(records: [original], tier: .quick, model: model, center: nil,
                                quickRunner: { _, _ in .measured(quick) })
        job.start()
        await job.task?.value
        #expect(replacement.mediaReportCard != nil)
    }

    @Test func summaryAndTimeLeftWording() throws {
        let card = R.card(tier: .quick, checks: R.quickChecks(try F.healthy()), quick: try F.healthy(), at: Date())
        let items = [CheckMediaItem(id: UUID(), filename: "a", outcome: .checked(card)),
                     CheckMediaItem(id: UUID(), filename: "b", outcome: .failed("x"))]
        #expect(CheckMediaJob.summary(items) == "1 checked — 1 with no problems in the quick check, 1 couldn't be checked")
        #expect(CheckMediaJob.timeLeftText(elapsed: 2, fraction: 0.5) == nil, "too early to say")
        #expect(CheckMediaJob.timeLeftText(elapsed: 60, fraction: 0.25) == "about 3 min left")
    }

    /// SCALE: the summary over a 100k-file selection stays cheap.
    @Test func summaryAtHundredThousand() throws {
        let card = R.card(tier: .quick, checks: R.quickChecks(try F.healthy()), quick: try F.healthy(), at: Date())
        let items = (0..<100_000).map { CheckMediaItem(id: UUID(), filename: "f\($0)", outcome: .checked(card)) }
        let clock = ContinuousClock()
        var s = ""
        let elapsed = clock.measure { s = CheckMediaJob.summary(items) }
        #expect(s == "100000 checked — 100000 with no problems in the quick check")
        #expect(elapsed < .seconds(2), "100k summary took \(elapsed)")
    }

    @Test func kindBadgeAndVerb() {
        #expect(MediaFileOperationKind.checkMedia.badgeText == "Check")
        #expect(MediaFileOperationKind.checkMedia.logVerb == "check media")
        #expect(MediaFileOperationKind.checkMedia.hasDetailView)
    }
}

// MARK: - ⌘I and menu sensors

@Suite("Check Media — ⌘I and menu sensors")
struct CheckMediaMenuSensorTests {

    @Test func commandIFollowsTheFocusedTable() {
        #expect(CatalogInfoTarget.resolve(volumeAvailable: true, fileAvailable: nil) == .volume)
        #expect(CatalogInfoTarget.resolve(volumeAvailable: nil, fileAvailable: true) == .file)
        #expect(CatalogInfoTarget.resolve(volumeAvailable: nil, fileAvailable: false) == .none,
                "files table focused with 0 or 2+ rows: greyed, never a volume's info")
        #expect(CatalogInfoTarget.resolve(volumeAvailable: false, fileAvailable: nil) == .none)
    }

    @Test func onlyTheFilesTablePublishesFileInfo() throws {
        let publishers = SourceTree.appSources.filter { entry in
            ((try? String(contentsOf: entry.url, encoding: .utf8)) ?? "").contains("focusedValue(\\.catalogFileInfo")
        }
        #expect(publishers.map { ($0.relative as NSString).lastPathComponent } == ["CatalogContent+Table.swift"])
    }

    @Test func retiredItemsStayRetired() throws {
        let menu = try ["CatalogRowContextMenu.swift", "CatalogRowContextMenu+FileOps.swift",
                        "CatalogRowContextMenu+Organize.swift", "CatalogRowContextMenu+Media.swift"]
            .map { try SourceTree.appSource(named: $0) }.joined(separator: "\n")
        #expect(!menu.contains("Button(\"Extract Facial Frames…\")"))
        #expect(!menu.contains("Button(\"Extract Frames…\")"))
        #expect(!menu.contains("FamilyMusicMenu.markTitle"))
        #expect(!menu.contains("Menu(\"Tag\")"), "one Tags ▸ menu")
        #expect(menu.contains("Menu(\"Open With\")") && menu.contains("Menu(\"Analyze\")") && menu.contains("Menu(\"Find\")"))
        #expect(menu.contains("checkMediaRequest = CheckMediaRequest("))
    }
}

// MARK: - Real file (opt-in, never in CI)

/// Prints the quick-tier report card for a real file when
/// TEST_RUNNER_VS_CHECKMEDIA_REAL_PATH is set (xcodebuild passes it on as
/// VS_CHECKMEDIA_REAL_PATH). READ-ONLY; skipped otherwise. No path in git.
@Suite("Check Media — real file (opt-in)", .serialized)
struct CheckMediaRealFileTests {
    @Test(.timeLimit(.minutes(2)))
    func quickCardForARealFile() async throws {
        guard let path = ProcessInfo.processInfo.environment["VS_CHECKMEDIA_REAL_PATH"], !path.isEmpty else { return }
        let started = ContinuousClock.now
        guard case .measured(let q) = try await CheckMediaProbe.quick(path: path) else {
            Issue.record("unopenable"); return
        }
        let card = R.card(tier: .quick, checks: R.quickChecks(q) + R.fullRowsNotRun(), quick: q, at: Date())
        print("CHECKMEDIA-REAL-CARD (\(ContinuousClock.now - started))\n" + R.text(of: card) + "\nCHECKMEDIA-REAL-END")
    }
}
