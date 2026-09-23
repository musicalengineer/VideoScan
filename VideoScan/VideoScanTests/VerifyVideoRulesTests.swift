// VerifyVideoRulesTests.swift
// LOGIC + SENSOR dimensions for Verify Video (Rick 2026-09-23).
//
//   * One table per check (pure functions over probe facts): dimensions,
//     frame rate, duplicate-frame bloat, bitrate plausibility, timestamps,
//     durations, decode outcome — positive AND negative rows.
//   * Verdict / note / recommendation mapping and the batch-find prefixes.
//   * Parsers: ffprobe JSON, compact packet lines, -progress lines, error
//     line cleaning, unopenable-stderr classification.
//   * SENSOR: the real Dicky pair's numbers pinned — the 46 GB HandBrake
//     file must read "Broken — each frame stored ~2,000× — broken encode;
//     46 GB for 71 s" and its 39 MB sibling must read OK. Plus a second
//     real case of the same class found on the LaCie during calibration
//     (CapeCod_June_1997.mp4, 43 GB for 37 s — header numbers only).

import Testing
import Foundation
@testable import VideoScan

// MARK: - Fixtures (numbers from real ffprobe output, read-only)

enum VerifyVideoFixtures {

    /// DickyTheBoysDadBreen-1985.mp4 — the motivating broken encode
    /// (numbers from Rick's brief, 2026-09-23).
    static var dickyBroken: VideoVerifyFacts {
        var f = VideoVerifyFacts()
        f.hasVideo = true
        f.videoCodec = "h264"
        f.width = 640; f.height = 480
        f.sampleAspectRatio = "1:1"; f.displayAspectRatio = "4:3"
        f.rFrameRate = 90_000
        f.avgFrameRate = 4_268_265.0 / 71.2
        f.frameCount = 4_268_265
        f.videoDurationSeconds = 71.2
        f.containerDurationSeconds = 71.2
        f.audioDurationSeconds = 71.2
        f.fileSizeBytes = 45_976_101_977
        f.videoBitRate = 5_165_000_000
        f.containerFormat = "mov,mp4,m4a,3gp,3g2,mj2"
        f.encoder = "HandBrake 1.9.2 2025022300"
        return f
    }

    /// DickyTheBoysDadBreen-1985-3.mp4 — the healthy sibling (real
    /// ffprobe output, 2026-09-23).
    static var dickyHealthy: VideoVerifyFacts {
        var f = VideoVerifyFacts()
        f.hasVideo = true
        f.videoCodec = "h264"
        f.width = 712; f.height = 478
        f.sampleAspectRatio = "8:9"; f.displayAspectRatio = "2848:2151"
        f.rFrameRate = 30_000.0 / 1_001.0
        f.avgFrameRate = 15_997_500.0 / 533_783.0
        f.frameCount = 2_133
        f.videoDurationSeconds = 71.171067
        f.containerDurationSeconds = 71.188
        f.audioDurationSeconds = 71.188
        f.fileSizeBytes = 39_043_440
        f.videoBitRate = 4_254_064
        f.containerFormat = "mov,mp4,m4a,3gp,3g2,mj2"
        f.encoder = "HandBrake 1.9.2 2025022300"
        return f
    }

    /// CapeCod_June_1997.mp4 on LaCieWorkspace — same HandBrake class
    /// (real ffprobe header, 2026-09-23; never decoded, never modified).
    static var capeCodBroken: VideoVerifyFacts {
        var f = VideoVerifyFacts()
        f.hasVideo = true
        f.videoCodec = "h264"
        f.width = 640; f.height = 480
        f.sampleAspectRatio = "1:1"; f.displayAspectRatio = "4:3"
        f.rFrameRate = 90_000
        f.avgFrameRate = 1_872_360_289.0 / 31_206.0
        f.frameCount = 2_159_585
        f.videoDurationSeconds = 35.993078
        f.containerDurationSeconds = 36.65
        f.audioDurationSeconds = 36.65
        f.fileSizeBytes = 43_370_703_217
        f.videoBitRate = 9_633_376_030
        return f
    }

    static func sample(packets: Int = 300, span: Double = 10, backward: Int = 0,
                       gap: Double = 0.04, median: Double = 0.033,
                       tiny: Double = 0, medianBytes: Int = 12_000) -> VideoPacketSample {
        VideoPacketSample(packets: packets, ptsSpanSeconds: span,
                          dtsBackwardSteps: backward, largestGapSeconds: gap,
                          medianDeltaSeconds: median, tinyPacketFraction: tiny,
                          medianPacketBytes: medianBytes)
    }

    static var cleanDecode: VideoDecodeFacts { VideoDecodeFacts(coverage: .complete) }
}

private typealias Fx = VerifyVideoFixtures

// MARK: - Sensor: the real Dicky pair

@Suite("VerifyVideo — Dicky sensor")
struct VerifyVideoDickySensorTests {

    @Test func dickyBrokenReadsBrokenWithTheTwoThousandTimesSentence() {
        let f = Fx.dickyBroken
        let findings = VerifyVideoRules.findings(facts: f, sample: nil,
                                                 decode: VideoDecodeFacts(coverage: .skipped(reason: "x")))
        #expect(VerifyVideoRules.verdict(for: findings) == .broken)
        let note = VerifyVideoRules.note(for: findings)
        #expect(note.hasPrefix("Broken video — each frame stored ~2,000× — broken encode; 46 GB for 71 s"),
                "got: \(note)")
        guard case .duplicateFrameBloat(let factor, let frames, let seconds, let size, _)? = findings.first else {
            Issue.record("bloat must lead: \(findings)"); return
        }
        #expect(abs(factor - 2_000) < 5, "factor \(factor)")
        #expect(frames == 4_268_265)
        #expect(abs(seconds - 71.2) < 0.01)
        #expect(size == 45_976_101_977)
        #expect(findings.contains(.frameRateBroken(fps: f.avgFrameRate)),
                "the frame-rate check names the broken timing too")
        #expect(!findings.contains { if case .bitrateImplausible = $0 { return true }; return false },
                "bloat already carries the size clause — no second 'N× too big' line")
        #expect(VerifyVideoRules.recommendation(for: findings).hasPrefix("Don't archive this copy."))
    }

    @Test func dickyBrokenSkipsTheFullDecode() {
        let pre = VerifyVideoRules.preDecodeFindings(facts: Fx.dickyBroken, sample: nil)
        #expect(VerifyVideoRules.decodeIsPointless(pre),
                "46 GB must not be read end to end to learn nothing new")
    }

    @Test func dickyHealthySiblingReadsOK() {
        let findings = VerifyVideoRules.findings(facts: Fx.dickyHealthy,
                                                 sample: Fx.sample(),
                                                 decode: Fx.cleanDecode)
        #expect(findings.isEmpty, "\(findings)")
        #expect(VerifyVideoRules.verdict(for: findings) == .ok)
        #expect(VerifyVideoRules.note(for: findings) == "")
        #expect(VerifyVideoRules.summary(for: findings) == "OK — the picture checked out.")
        #expect(!VerifyVideoRules.decodeIsPointless(
            VerifyVideoRules.preDecodeFindings(facts: Fx.dickyHealthy, sample: nil)))
    }

    @Test func capeCodIsTheSameBrokenClass() {
        let findings = VerifyVideoRules.findings(facts: Fx.capeCodBroken, sample: nil, decode: nil)
        #expect(VerifyVideoRules.verdict(for: findings) == .broken)
        #expect(VerifyVideoRules.note(for: findings)
            .hasPrefix("Broken video — each frame stored ~2,000× — broken encode; 43 GB for 36 s"),
                "got: \(VerifyVideoRules.note(for: findings))")
    }

    /// Thresholds are part of the contract — pinned so a tweak is a
    /// deliberate, reviewed change.
    @Test func thresholdsPinned() {
        #expect(VerifyVideoRules.maxPlausibleFPS == 240)
        #expect(VerifyVideoRules.brokenFPS == 1_000)
        #expect(VerifyVideoRules.bloatMinFactor == 4)
        #expect(VerifyVideoRules.durationToleranceSeconds == 1)
        #expect(VerifyVideoRules.brokenNotePrefix == "Broken video — ")
        #expect(VerifyVideoRules.warningNotePrefix == "Video warning — ")
    }
}

// MARK: - Logic tables, one per check

@Suite("VerifyVideo — check tables")
struct VerifyVideoCheckTableTests {

    // Dimensions / aspect
    @Test(arguments: [
        (640, 480, "1:1", "4:3", 0),
        (712, 478, "8:9", "2848:2151", 0),
        (720, 480, "0:1", "", 0),          // unknown SAR is not odd
        (0, 480, "", "", -1),              // zero → broken
        (640, 0, "", "", -1),
        (20_000, 480, "1:1", "", 1),       // implausible size
        (640, 480, "10:1", "40:3", 1),     // absurd SAR/DAR
        (640, 480, "1:1", "1:10", 1),      // absurd DAR
    ])
    func dimensions(_ w: Int, _ h: Int, _ sar: String, _ dar: String, _ expected: Int) {
        var f = Fx.dickyHealthy
        f.width = w; f.height = h; f.sampleAspectRatio = sar; f.displayAspectRatio = dar
        let out = VerifyVideoRules.checkDimensions(f)
        switch expected {
        case 0: #expect(out.isEmpty, "\(out)")
        case -1: #expect(out == [.zeroDimensions(width: w, height: h)])
        default:
            #expect(out.count == 1)
            #expect(out.allSatisfy { VerifyVideoRules.severity($0) == .warning })
        }
    }

    // Frame rate
    @Test(arguments: [
        (30_000.0 / 1_001.0, 29.97, "none"),
        (25.0, 25.0, "none"),
        (240.0, 240.0, "none"),
        (0.0, 29.97, "none"),              // r unknown, avg fine
        (90_000.0, 29.97, "headerOdd"),    // VFR-style timebase
        (29.97, 300.0, "warnBroken"),      // avg absurd but < 1000 → warning
        (90_000.0, 59_947.0, "broken"),    // Dicky
        (0.0, 0.0, "unknown"),
        (90_000.0, 0.0, "broken"),         // no average to go on
    ])
    func frameRate(_ r: Double, _ avg: Double, _ expected: String) {
        var f = Fx.dickyHealthy
        f.rFrameRate = r; f.avgFrameRate = avg
        let out = VerifyVideoRules.checkFrameRate(f)
        switch expected {
        case "none": #expect(out.isEmpty, "\(out)")
        case "headerOdd":
            #expect(out == [.frameRateHeaderOdd(declared: r, actual: avg)])
            #expect(VerifyVideoRules.severity(out[0]) == .warning)
        case "warnBroken":
            #expect(out == [.frameRateBroken(fps: avg)])
            #expect(VerifyVideoRules.severity(out[0]) == .warning)
        case "broken":
            #expect(out.count == 1)
            #expect(VerifyVideoRules.severity(out[0]) == .broken)
        case "unknown": #expect(out == [.frameRateUnknown])
        default: Issue.record("bad row")
        }
    }

    // Duplicate-frame bloat
    @Test func bloatFromFrameCount() {
        var f = Fx.dickyHealthy
        f.frameCount = 2_133 * 10     // 10× the frames
        f.rFrameRate = 30_000.0 / 1_001.0
        let out = VerifyVideoRules.checkDuplicateBloat(f, sample: nil)
        guard case .duplicateFrameBloat(let factor, _, _, _, _)? = out.first else {
            Issue.record("expected bloat, got \(out)"); return
        }
        #expect(abs(factor - 10) < 0.1)
    }

    @Test func noBloatForRealHighFrameRates() {
        var f = Fx.dickyHealthy
        f.rFrameRate = 240; f.avgFrameRate = 240
        f.frameCount = Int(240 * f.videoDurationSeconds)
        #expect(VerifyVideoRules.checkDuplicateBloat(f, sample: nil).isEmpty,
                "a real 240 fps slow-motion clip is not bloat")
    }

    @Test func bloatFromPacketSampleWhenNoFrameCount() {
        var f = Fx.dickyHealthy
        f.frameCount = nil                      // Matroska
        let s = Fx.sample(packets: 300, span: 0.1, tiny: 0.95)   // ~2,990 fps
        let out = VerifyVideoRules.checkDuplicateBloat(f, sample: s)
        guard case .duplicateFrameBloat(let factor, _, _, _, let empty)? = out.first else {
            Issue.record("expected bloat, got \(out)"); return
        }
        #expect(factor > 90 && factor < 110)
        #expect(empty, "95% tiny packets = mostly empty frames")
    }

    @Test func smallPacketSamplesAreNotEvidence() {
        var f = Fx.dickyHealthy
        f.frameCount = nil
        #expect(VerifyVideoRules.checkDuplicateBloat(f, sample: Fx.sample(packets: 10, span: 0.001)).isEmpty,
                "fewer than 50 packets never proves bloat")
    }

    // Bitrate plausibility
    @Test(arguments: [
        ("h264", 4_254_064, "none"),        // healthy sibling
        ("h264", 40_000_000, "warning"),    // SD at 40 Mbit/s
        ("h264", 400_000_000, "broken"),    // SD at 400 Mbit/s
        ("prores", 60_000_000, "none"),     // ProRes SD is big by design
        ("prores", 200_000_000, "warning"),
        ("ffv1", 100_000_000, "none"),      // lossless
        ("dvvideo", 25_000_000, "none"),
        ("rawvideo", 300_000_000, "none"),
        ("mysterycodec", 900_000_000, "none"),   // unknown family: no claim
    ])
    func bitrate(_ codec: String, _ bps: Int64, _ expected: String) {
        var f = Fx.dickyHealthy
        f.videoCodec = codec
        f.width = 720; f.height = 480
        f.videoBitRate = bps
        let out = VerifyVideoRules.checkBitrate(f)
        switch expected {
        case "none": #expect(out.isEmpty, "\(codec) \(bps): \(out)")
        case "warning":
            #expect(out.count == 1 && VerifyVideoRules.severity(out[0]) == .warning, "\(out)")
        case "broken":
            #expect(out.count == 1 && VerifyVideoRules.severity(out[0]) == .broken, "\(out)")
        default: Issue.record("bad row")
        }
    }

    @Test func bitrateFallsBackToSizeOverDuration() {
        var f = Fx.dickyHealthy
        f.videoBitRate = 0
        f.fileSizeBytes = 45_976_101_977
        #expect(VerifyVideoRules.bitsPerSecond(f) > 5_000_000_000)
    }

    // Timestamps
    @Test func timestampChecks() {
        #expect(VerifyVideoRules.checkTimestamps(nil).isEmpty)
        #expect(VerifyVideoRules.checkTimestamps(Fx.sample()).isEmpty)
        #expect(VerifyVideoRules.checkTimestamps(Fx.sample(backward: 3))
                == [.timestampsOutOfOrder(count: 3, sampled: 300)])
        #expect(VerifyVideoRules.checkTimestamps(Fx.sample(gap: 5.0))
                == [.timestampGap(seconds: 5.0)])
        // 1.5 s but a slideshow-like median of 1 s: not 20× — no gap.
        #expect(VerifyVideoRules.checkTimestamps(Fx.sample(gap: 1.5, median: 1.0)).isEmpty)
    }

    // Durations
    @Test(arguments: [
        (71.17, 71.19, 71.19, 0),
        (71.0, 75.0, 71.0, 1),       // stream vs container
        (71.0, 71.0, 60.0, 1),       // video vs audio
        (71.0, 80.0, 60.0, 2),
        (71.0, 0.0, 0.0, 0),         // unknowns never fire
        (0.0, 71.0, 10.0, 0),
    ])
    func durations(_ v: Double, _ c: Double, _ a: Double, _ expected: Int) {
        var f = Fx.dickyHealthy
        f.videoDurationSeconds = v; f.containerDurationSeconds = c; f.audioDurationSeconds = a
        let out = VerifyVideoRules.checkDurations(f)
        #expect(out.count == expected, "\(out)")
        #expect(out.allSatisfy { VerifyVideoRules.severity($0) == .warning })
    }

    // Decode
    @Test func decodeOutcomes() {
        #expect(VerifyVideoRules.checkDecode(nil, totalSeconds: 60).isEmpty)
        #expect(VerifyVideoRules.checkDecode(Fx.cleanDecode, totalSeconds: 60).isEmpty)

        let few = VerifyVideoRules.checkDecode(
            VideoDecodeFacts(coverage: .complete, errorCount: 3), totalSeconds: 3_600)
        #expect(few == [.decodeErrors(count: 3, severe: false)])
        #expect(VerifyVideoRules.verdict(for: few) == .warning)

        let many = VerifyVideoRules.checkDecode(
            VideoDecodeFacts(coverage: .complete, errorCount: 150), totalSeconds: 3_600)
        #expect(many == [.decodeErrors(count: 150, severe: true)])
        #expect(VerifyVideoRules.verdict(for: many) == .broken)

        // 52 errors in 4 s (the synthetic corrupt fixture's rate) → severe.
        let dense = VerifyVideoRules.checkDecode(
            VideoDecodeFacts(coverage: .complete, errorCount: 52), totalSeconds: 4)
        #expect(dense == [.decodeErrors(count: 52, severe: true)])

        let partial = VerifyVideoRules.checkDecode(
            VideoDecodeFacts(coverage: .partial(checkedSeconds: 600)), totalSeconds: 7_200)
        #expect(partial == [.partiallyChecked(checkedSeconds: 600, totalSeconds: 7_200)])
        #expect(VerifyVideoRules.verdict(for: partial) == .ok, "partial alone is not a problem — just honest")

        let stopped = VerifyVideoRules.checkDecode(
            VideoDecodeFacts(coverage: .complete, failedToFinish: true, stoppedAtSeconds: 83),
            totalSeconds: 600)
        #expect(stopped == [.decodeStopped(atSeconds: 83)])
        #expect(VerifyVideoRules.verdict(for: stopped) == .broken)

        let skipped = VerifyVideoRules.checkDecode(
            VideoDecodeFacts(coverage: .skipped(reason: "r"), errorCount: 9), totalSeconds: 60)
        #expect(skipped == [.decodeSkipped(reason: "r")])
    }

    @Test func decodeBudget() {
        #expect(VerifyVideoRules.decodeBudgetSeconds(durationSeconds: 0) == 600)
        #expect(VerifyVideoRules.decodeBudgetSeconds(durationSeconds: 7_200) == 7_800)
        #expect(VerifyVideoRules.decodeBudgetSeconds(durationSeconds: 100_000) == 14_400)
    }

    @Test func referenceFPSChoice() {
        var f = VideoVerifyFacts()
        f.rFrameRate = 25; f.avgFrameRate = 24.9
        #expect(VerifyVideoRules.referenceFPS(f) == 25)
        f.rFrameRate = 90_000
        #expect(VerifyVideoRules.referenceFPS(f) == 24.9)
        f.avgFrameRate = 60_000
        #expect(abs(VerifyVideoRules.referenceFPS(f) - 29.97) < 0.01)
    }

    @Test func codecFamilies() {
        #expect(VerifyVideoRules.codecFamily("H264") == .lossy)
        #expect(VerifyVideoRules.codecFamily("prores") == .intraMezzanine)
        #expect(VerifyVideoRules.codecFamily("dvvideo") == .intraMezzanine)
        #expect(VerifyVideoRules.codecFamily("ffv1") == .lossless)
        #expect(VerifyVideoRules.codecFamily("") == .unknown)
    }
}

// MARK: - Verdict / words

@Suite("VerifyVideo — verdict and words")
struct VerifyVideoWordsTests {

    @Test func verdictIsTheWorstSeverity() {
        #expect(VerifyVideoRules.verdict(for: []) == .ok)
        #expect(VerifyVideoRules.verdict(for: [.decodeSkipped(reason: "x")]) == .ok)
        #expect(VerifyVideoRules.verdict(for: [.frameRateUnknown]) == .warning)
        #expect(VerifyVideoRules.verdict(for: [.frameRateUnknown, .unopenable(detail: "x")]) == .broken)
    }

    @Test func notesCarryFindablePrefixesAndLeadWithTheWorst() {
        let warn = VerifyVideoRules.note(for: [.timestampGap(seconds: 5)])
        #expect(warn == "Video warning — gap of 5.0 s in the timestamps")
        let mixed = VerifyVideoRules.note(for: [.frameRateUnknown, .unopenable(detail: "d")])
        #expect(mixed == "Broken video — can't be opened (d); frame rate unknown")
        let infoOnly = VerifyVideoRules.note(for: [.partiallyChecked(checkedSeconds: 600, totalSeconds: 7_200)])
        #expect(infoOnly == "partially checked (decoded 10 min of 2 h 0 min)", "OK notes stay bare")
    }

    @Test func persistedStatusesAreTheVerdictRawValues() {
        #expect(VideoVerifyVerdict.ok.rawValue == "ok")
        #expect(VideoVerifyVerdict.warning.rawValue == "warning")
        #expect(VideoVerifyVerdict.broken.rawValue == "broken")
    }

    @Test func everyFindingHasWordsAndARecommendation() {
        let all: [VideoVerifyFinding] = [
            .unopenable(detail: "d"), .zeroDimensions(width: 0, height: 0),
            .implausibleDimensions(width: 1, height: 1), .oddAspect(sar: "", dar: ""),
            .frameRateBroken(fps: 5_000), .frameRateHeaderOdd(declared: 90_000, actual: 25),
            .frameRateUnknown,
            .duplicateFrameBloat(factor: 5, frames: 1, seconds: 1, sizeBytes: 1, mostlyEmptyPackets: false),
            .bitrateImplausible(ratio: 50, bitsPerSecond: 1, severe: true),
            .timestampsOutOfOrder(count: 1, sampled: 2), .timestampGap(seconds: 2),
            .streamVsContainerDuration(stream: 1, container: 3),
            .videoVsAudioDuration(video: 1, audio: 3), .decodeErrors(count: 1, severe: false),
            .decodeStopped(atSeconds: 1), .partiallyChecked(checkedSeconds: 1, totalSeconds: 2),
            .decodeSkipped(reason: "r"),
        ]
        for f in all {
            #expect(!VerifyVideoRules.noteFragment(for: f).isEmpty)
            #expect(!VerifyVideoRules.recommendation(for: [f]).isEmpty)
        }
        #expect(VerifyVideoRules.recommendation(for: []) == "Nothing to do — the picture checked out.")
    }

    @Test(arguments: [
        (2_000.2, "2,000"), (2_260.0, "2,300"), (100.4, "100"), (57.6, "58"), (3.44, "3.4"),
    ])
    func factorText(_ f: Double, _ expected: String) {
        #expect(VerifyVideoRules.factorText(f) == expected)
    }

    @Test func formatting() {
        #expect(VerifyVideoRules.sizeText(45_976_101_977) == "46 GB")
        #expect(VerifyVideoRules.sizeText(39_043_440) == "39 MB")
        #expect(VerifyVideoRules.sizeText(1_500_000_000) == "1.5 GB")
        #expect(VerifyVideoRules.durationText(71.2) == "71 s")
        #expect(VerifyVideoRules.durationText(4.0) == "4.0 s")
        #expect(VerifyVideoRules.durationText(3_900) == "1 h 5 min")
        #expect(VerifyVideoRules.fpsText(59_947.3) == "59,947")
        #expect(VerifyVideoRules.fpsText(30_000.0 / 1_001.0) == "29.97")
        #expect(VerifyVideoRules.fpsText(25) == "25")
        #expect(VerifyVideoRules.groupedInt(4_268_265) == "4,268,265")
        #expect(VerifyVideoRules.timecode(83) == "00:01:23")
    }
}

// MARK: - Parsers

@Suite("VerifyVideo — parsers")
struct VerifyVideoParserTests {

    @Test func probeJSONOfTheHealthySibling() throws {
        let json = """
        {"streams":[{"codec_name":"h264","codec_type":"video","width":712,"height":478,
        "sample_aspect_ratio":"8:9","display_aspect_ratio":"2848:2151",
        "r_frame_rate":"30000/1001","avg_frame_rate":"15997500/533783","duration":"71.171067",
        "bit_rate":"4254064","nb_frames":"2133","disposition":{"attached_pic":0}},
        {"codec_name":"aac","codec_type":"audio","r_frame_rate":"0/0","avg_frame_rate":"0/0",
        "duration":"71.188000","bit_rate":"125826","nb_frames":"3339","disposition":{"attached_pic":0}}],
        "format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2","duration":"71.188000","size":"39043440",
        "tags":{"encoder":"HandBrake 1.9.2 2025022300"}}}
        """
        let f = try VerifyVideoRules.facts(fromProbeJSON: Data(json.utf8))
        #expect(f == Fx.dickyHealthy)
    }

    @Test func coverArtIsNotAPicture() throws {
        let json = """
        {"streams":[{"codec_name":"aac","codec_type":"audio","duration":"180"},
        {"codec_name":"mjpeg","codec_type":"video","width":600,"height":600,"disposition":{"attached_pic":1}}],
        "format":{"format_name":"mov,mp4","duration":"180","size":"5000000"}}
        """
        let f = try VerifyVideoRules.facts(fromProbeJSON: Data(json.utf8))
        #expect(!f.hasVideo)
    }

    @Test func matroskaWithoutStreamDurationFallsBackToContainer() throws {
        let json = """
        {"streams":[{"codec_name":"ffv1","codec_type":"video","width":320,"height":240,
        "r_frame_rate":"25/1","avg_frame_rate":"25/1"},{"codec_name":"pcm_s16le","codec_type":"audio"}],
        "format":{"format_name":"matroska,webm","duration":"2.000","size":"900000"}}
        """
        let f = try VerifyVideoRules.facts(fromProbeJSON: Data(json.utf8))
        #expect(f.videoDurationSeconds == 2.0)
        #expect(f.audioDurationSeconds == 0, "the audio side must stay unknown, never guessed")
        #expect(f.frameCount == nil)
    }

    @Test func badJSONThrowsProbeFailed() {
        #expect(throws: VideoVerifyProbeError.self) {
            _ = try VerifyVideoRules.facts(fromProbeJSON: Data("nope".utf8))
        }
    }

    @Test func compactPacketLinesParseAndSummarize() {
        let text = """
        pts_time=0.000000|dts_time=-0.066733|size=42635
        pts_time=0.166833|dts_time=-0.033367|size=36796
        pts_time=0.066733|dts_time=0.000000|size=20506
        pts_time=0.033367|dts_time=0.033367|size=14518
        pts_time=0.100100|dts_time=0.066733|size=13658
        pts_time=N/A|dts_time=N/A|size=12
        """
        let rows = VerifyVideoRules.packetRows(fromCompact: text)
        #expect(rows.count == 6)
        #expect(rows[5].pts == nil && rows[5].size == 12)
        let s = VerifyVideoRules.packetSample(from: rows)
        #expect(s.dtsBackwardSteps == 0, "B-frame PTS reordering is normal; DTS is what must climb")
        #expect(abs(s.ptsSpanSeconds - 0.166833) < 1e-6)
        #expect(s.tinyPacketFraction > 0.16 && s.tinyPacketFraction < 0.17)
    }

    @Test func backwardDTSIsCounted() {
        let rows = [VerifyVideoRules.PacketRow(pts: 0, dts: 0, size: 100),
                    VerifyVideoRules.PacketRow(pts: 1, dts: 1, size: 100),
                    VerifyVideoRules.PacketRow(pts: 0.5, dts: 0.5, size: 100)]
        #expect(VerifyVideoRules.packetSample(from: rows).dtsBackwardSteps == 1)
    }

    @Test func mergeKeepsTheSlowestWindowRate() throws {
        let a = Fx.sample(packets: 300, span: 10)      // ~30 fps
        let b = Fx.sample(packets: 300, span: 0.1)     // ~3,000 fps
        let m = try #require(VerifyVideoRules.merge([a, b]))
        #expect(m.packets == 600)
        let fps = try #require(m.sampledFPS)
        #expect(fps < 31, "a Broken claim must hold everywhere we looked")
        #expect(VerifyVideoRules.merge([]) == nil)
    }

    @Test func progressLines() {
        #expect(VerifyVideoRules.progressSeconds(fromLine: "out_time_us=71171100") == 71.1711)
        #expect(VerifyVideoRules.progressSeconds(fromLine: "out_time_us=N/A") == nil)
        #expect(VerifyVideoRules.progressSeconds(fromLine: "frame=2133") == nil)
    }

    @Test func errorLinesAndUnopenableWords() {
        #expect(VerifyVideoRules.cleanErrorLine("[h264 @ 0x75d044700] error while decoding MB 18 11")
                == "h264: error while decoding MB 18 11")
        #expect(VerifyVideoRules.cleanErrorLine("plain") == "plain")
        let moov = "[mov,mp4 @ 0x1] moov atom not found\n/x.mp4: Invalid data found when processing input"
        #expect(VerifyVideoRules.stderrBlamesContent(moov))
        #expect(VerifyVideoRules.unopenableDetail(fromProbeStderr: moov).contains("index is missing"))
        #expect(!VerifyVideoRules.stderrBlamesContent("/x.mp4: Input/output error"))
        #expect(!VerifyVideoRules.stderrBlamesContent("/x.mp4: No such file or directory"))
    }

    @Test func rateAndRatioParsing() {
        #expect(abs(VerifyVideoRules.parseRate("30000/1001") - 29.97) < 0.01)
        #expect(VerifyVideoRules.parseRate("0/0") == 0)
        #expect(VerifyVideoRules.parseRate("25") == 25)
        #expect(VerifyVideoRules.parseRate(nil) == 0)
        #expect(VerifyVideoRules.parseRatio("0:1") == nil)
        #expect(VerifyVideoRules.parseRatio("4:3") == 4.0 / 3.0)
    }

    @Test func argumentBuildersAreReadOnlyAndBounded() {
        let decode = VerifyVideoProbe.decodeArgs(input: "/v/x.mp4")
        #expect(decode.contains("null") && decode.last == "-nostats")
        #expect(!decode.contains("-y"), "the decode writes nowhere — never an overwrite flag")
        let sample = VerifyVideoProbe.packetSampleArgs(input: "/v/x.mp4", startSeconds: 35.5)
        #expect(sample.contains("35.500%+#300"), "a bounded packet window, never a whole-file walk")
        #expect(VerifyVideoProbe.packetSampleArgs(input: "/v/x.mp4", startSeconds: nil).contains("%+#300"))
    }
}
