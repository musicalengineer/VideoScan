// DurationEstimateTests.swift
// Verify Media's full check: a file whose header records no duration (raw
// .m2v, recovered MPEG fragments, raw ADTS AAC) shows its length counted
// from the packet census, right after what is wrong (Rick 2026-10-21).
//
// Dimensions (CLAUDE.md): LOGIC (the wording; frames ÷ rate incl.
// 30000/1001 and 0/0; packets × samples ÷ rate), ISOLATION (a failed or
// missing census, an unopenable file → "duration unknown", never a crash),
// MEDIA MATRIX (real ffmpeg: synthetic `test_*` raw .m2v and ADTS .aac
// elementary streams, plus an mp4 control that keeps its header length),
// SENSOR (the job's one-line summary carries the length; the persisted
// card does NOT — display only).

import Testing
import Foundation
@testable import VideoScan

private typealias E = DurationEstimate

/// ffprobe's header for a raw MPEG-2 elementary stream (measured on a
/// synthetic `test_` .m2v, 2026-10-21): no duration anywhere, avg 25/1
/// beside the true r 30000/1001.
private let rawM2VJSON = #"""
{"streams":[
  {"index":0,"codec_name":"mpeg2video","codec_type":"video","width":720,"height":480,
   "pix_fmt":"yuv420p","field_order":"tt","r_frame_rate":"30000/1001","avg_frame_rate":"25/1",
   "time_base":"1/1200000","disposition":{"attached_pic":0}}],
 "format":{"format_name":"mpegvideo","format_long_name":"raw MPEG video","size":"6300000000"}}
"""#

private func facts(_ json: String) throws -> MediaFacts {
    try MediaFacts.parse(probeJSON: Data(json.utf8))
}

private func stream(_ kind: MediaStreamFacts.Kind, codec: String = "", r: String = "",
                    avg: String = "", sampleRate: Int? = nil) -> MediaStreamFacts {
    var s = MediaStreamFacts(index: 0, kind: kind)
    s.codec = codec
    s.rFrameRateText = r
    s.avgFrameRateText = avg
    s.sampleRate = sampleRate
    return s
}

@Suite("Duration estimate — logic")
struct DurationEstimateLogicTests {

    @Test func aboutTextWording() {
        #expect(E.aboutText(2_754.75) == "about 45 min 55 s")
        #expect(E.aboutText(3_900) == "about 1 h 5 min")
        #expect(E.aboutText(7_260.4) == "about 2 h 1 min")
        #expect(E.aboutText(42.4) == "about 42 s")
        #expect(E.aboutText(59.6) == "about 1 min 0 s")
        #expect(E.aboutText(0.3) == "under a second")
        #expect(E.aboutText(.nan) == "an unknown length")
        #expect(E.aboutText(-1) == "an unknown length")
    }

    @Test func framesPerSecondPrefersRThenAvg() throws {
        let ntsc = try #require(E.framesPerSecond(stream(.video, r: "30000/1001", avg: "25/1")))
        #expect(abs(ntsc - 29.970_029_97) < 1e-6, "r wins over a wrong avg")
        #expect(E.framesPerSecond(stream(.video, r: "0/0", avg: "25/1")) == 25, "0/0 falls back to avg")
        #expect(E.framesPerSecond(stream(.video, r: "0/0", avg: "0/0")) == nil)
        #expect(E.framesPerSecond(stream(.video)) == nil, "empty strings are unknown, not zero")
    }

    /// The JustPatsHouse measurement: 82,560 frames at 30000/1001 = 45:55.
    @Test func framesOverRateMatchesTheMeasuredFile() throws {
        let s = try #require(E.pictureSeconds(packets: 82_560, stream: stream(.video, r: "30000/1001")))
        #expect(abs(s - 2_754.752) < 0.01)
        #expect(E.counted(seconds: s, source: .frames).sentence
                == "about 45 min 55 s of video (counted from frames)")
        #expect(E.pictureSeconds(packets: 0, stream: stream(.video, r: "25/1")) == nil)
        #expect(E.pictureSeconds(packets: 100, stream: stream(.video, r: "0/0")) == nil)
        #expect(E.pictureSeconds(packets: 100, stream: nil) == nil)
    }

    @Test func audioPacketsTimesSamplesOverRate() throws {
        let aac = stream(.audio, codec: "aac", sampleRate: 48_000)
        let s = try #require(E.soundSeconds(packets: 469, stream: aac))
        #expect(abs(s - 469.0 * 1_024 / 48_000) < 1e-9)
        #expect(E.counted(seconds: 191, source: .audioPackets).sentence
                == "about 3 min 11 s of sound (counted from audio packets)")
        #expect(E.soundSeconds(packets: 100, stream: stream(.audio, codec: "mp2", sampleRate: 48_000))
                == 100.0 * 1_152 / 48_000)
        #expect(E.soundSeconds(packets: 100, stream: stream(.audio, codec: "pcm_s16le", sampleRate: 48_000)) == nil,
                "no fixed packet size → no guess")
        #expect(E.soundSeconds(packets: 100, stream: stream(.audio, codec: "aac", sampleRate: 0)) == nil)
        #expect(E.soundSeconds(packets: 100, stream: stream(.audio, codec: "aac")) == nil)
    }

    @Test func onlyAFileWithNoRecordedDurationGetsAnEstimate() throws {
        let raw = try facts(rawM2VJSON)
        #expect(!E.hasRecordedDuration(raw))
        let census = PacketCensusReport(picturePackets: 82_560)
        #expect(E.make(facts: raw, census: .success(census))
                == .counted(seconds: 82_560 / (30_000.0 / 1_001), source: .frames))
        let healthy = try CheckMediaFixtures.healthy().facts
        #expect(E.hasRecordedDuration(healthy))
        #expect(E.make(facts: healthy, census: .success(census)) == nil, "the header's length stands")
    }

    @Test func pictureWinsOverSoundWhenBothCounted() {
        var f = MediaFacts()
        f.streams = [stream(.video, r: "25/1"), stream(.audio, codec: "aac", sampleRate: 48_000)]
        let both = PacketCensusReport(picturePackets: 250, soundPackets: 1_000)
        #expect(E.make(facts: f, census: .success(both)) == .counted(seconds: 10, source: .frames))
        f.streams[0].rFrameRateText = "0/0"
        #expect(E.make(facts: f, census: .success(both))
                == .counted(seconds: 1_000.0 * 1_024 / 48_000, source: .audioPackets), "no picture rate → the sound")
    }

    @Test func censusProgressBasis() {
        var f = MediaFacts()
        f.durationSeconds = 100
        #expect(CensusProgressBasis.basis(for: f) == .seconds(100))
        f.durationSeconds = nil
        f.sizeBytes = 1_000
        #expect(CensusProgressBasis.basis(for: f) == .bytes(1_000), "no duration → follow the bytes")
        let p = CensusPacket(pts: nil, dts: 50, pos: 250)
        #expect(CensusProgressBasis.bytes(1_000).fraction(of: p) == 0.25)
        #expect(CensusProgressBasis.seconds(100).fraction(of: p) == 0.5)
        #expect(CensusProgressBasis.bytes(1_000).fraction(of: CensusPacket(pos: 5_000)) == 1, "clamped")
        f.sizeBytes = nil
        #expect(CensusProgressBasis.basis(for: f) == nil)
    }

    @Test func censusCountsUntimedPackets() {
        var c = PacketCensus()
        for i in 0..<10 {
            _ = c.notePicture(line: "pts_time=N/A|dts_time=N/A|duration_time=N/A|size=100|pos=\(i * 100)|flags=___")
        }
        _ = c.noteSound(line: "pts_time=0.0|dts_time=0.0|duration_time=0.021333|size=200|pos=0|flags=K__")
        let r = c.report
        #expect(r.picturePackets == 10, "a packet with no time still counts")
        #expect(r.video == nil, "…but not as a timed packet")
        #expect(r.soundPackets == 1)
    }
}

@Suite("Duration estimate — isolation")
struct DurationEstimateIsolationTests {

    @Test func aFailedOrMissingCensusIsUnknownNeverACrash() throws {
        let raw = try facts(rawM2VJSON)
        #expect(E.make(facts: raw, census: .failure(CheckMediaSkip(reason: "ffprobe could not list"))) == .unknown)
        #expect(E.make(facts: raw, census: nil) == .unknown)
        #expect(E.make(facts: raw, census: .success(PacketCensusReport())) == .unknown, "zero packets")
        #expect(E.make(facts: MediaFacts(), census: .success(PacketCensusReport(picturePackets: 9))) == .unknown,
                "no streams at all")
        #expect(E.unknown.sentence == "duration unknown — no header to read it from")
    }
}

@Suite("Duration estimate — the Verify job", .serialized)
@MainActor
struct DurationEstimateJobTests {

    private func record(_ name: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = "/Volumes/T/\(name)"
        r.directory = "/Volumes/T"
        return r
    }

    /// SENSOR: the one-line result names what is wrong, then the length;
    /// the persisted card carries no estimate (display only).
    @Test func fullCheckSummaryCarriesTheLengthAndTheCardDoesNot() async throws {
        let model = VideoScanModel()
        let rec = record("test_de_raw.m2v")
        model.records = [rec]
        let quick = try CheckMediaFixtures.quick(rawM2VJSON)
        let job = CheckMediaJob(records: [rec], tier: .full, model: model, center: nil,
                                quickRunner: { _, _ in .measured(quick) },
                                fullRunner: { _, _, _, _ in
                                    CheckMediaFullInputs(census: .success(PacketCensusReport(picturePackets: 82_560)))
                                },
                                soundAdviceLookup: { _ in .none })
        job.start()
        await job.task?.value
        #expect(job.items[0].durationEstimate == .counted(seconds: 82_560 / (30_000.0 / 1_001), source: .frames))
        guard case .finished(let summary) = job.state else { Issue.record("\(job.state)"); return }
        #expect(summary.hasSuffix(" · about 45 min 55 s of video (counted from frames)"), "\(summary)")
        let card = try #require(rec.mediaReportCard)
        #expect(!card.headline.contains("counted from"), "display only: \(card.headline)")
        #expect(summary.hasPrefix("\(card.verdict.word) — \(card.headline)"), "what is wrong comes first")
        print("DURATION-ESTIMATE-SUMMARY: \(summary)")
    }

    @Test func quickCheckNeverCounts() async throws {
        let model = VideoScanModel()
        let rec = record("test_de_quick.m2v")
        model.records = [rec]
        let quick = try CheckMediaFixtures.quick(rawM2VJSON)
        let job = CheckMediaJob(records: [rec], tier: .quick, model: model, center: nil,
                                quickRunner: { _, _ in .measured(quick) },
                                soundAdviceLookup: { _ in .none })
        job.start()
        await job.task?.value
        #expect(job.items[0].durationEstimate == nil, "the count reads the whole file — full check only")
    }

    @Test func unopenableFileInAFullCheckSaysUnknown() async throws {
        let model = VideoScanModel()
        let rec = record("test_de_garbage.995")
        model.records = [rec]
        let job = CheckMediaJob(records: [rec], tier: .full, model: model, center: nil,
                                quickRunner: { _, _ in .unopenable(detail: "Invalid data found", sizeBytes: 4_096) })
        job.start()
        await job.task?.value
        #expect(job.items[0].durationEstimate == .unknown)
        guard case .finished(let summary) = job.state else { Issue.record("\(job.state)"); return }
        #expect(summary.hasSuffix(" · duration unknown — no header to read it from"), "\(summary)")
    }

    @Test func failedCensusInAFullCheckSaysUnknown() async throws {
        let model = VideoScanModel()
        let rec = record("test_de_badcensus.m2v")
        model.records = [rec]
        let quick = try CheckMediaFixtures.quick(rawM2VJSON)
        let job = CheckMediaJob(records: [rec], tier: .full, model: model, center: nil,
                                quickRunner: { _, _ in .measured(quick) },
                                fullRunner: { _, _, _, _ in
                                    CheckMediaFullInputs(census: .failure(CheckMediaSkip(reason: "exit 1")))
                                },
                                soundAdviceLookup: { _ in .none })
        job.start()
        await job.task?.value
        #expect(job.items[0].durationEstimate == .unknown)
    }
}

@Suite("Duration estimate — media matrix", .serialized)
struct DurationEstimateMediaMatrixTests {

    private func quickInputs(_ path: String) async throws -> CheckMediaQuickInputs {
        guard case .measured(let q) = try await CheckMediaProbe.quick(path: path) else {
            throw CheckMediaSkip(reason: "unopenable")
        }
        return q
    }

    /// Raw MPEG-2 elementary stream, 10 s at 30000/1001: no header length;
    /// the full check counts ≈ 300 frames → "about 10 s of video".
    @Test("raw .m2v: counted from frames", .timeLimit(.minutes(2)))
    func rawM2V() async throws {
        try #require(VerifyVideoTestMedia.toolsAvailable)
        let dir = try VerifyVideoTestMedia.makeScratchDir("durm2v")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("test_de_raw.m2v").path
        try CleanupTestMedia.runFFmpeg(["-f", "lavfi", "-i", "testsrc=duration=10:size=160x120:rate=30000/1001",
                                        "-c:v", "mpeg2video", "-f", "mpeg2video"], output: path)
        let q = try await quickInputs(path)
        #expect(!E.hasRecordedDuration(q.facts), "a raw elementary stream records no length")
        let fractions = FractionLog()
        let full = try await CheckMediaProbe.full(path: path, facts: q.facts,
                                                  progress: { phase, f in if phase == .census { fractions.add(f) } })
        guard case .counted(let seconds, .frames)? = E.make(facts: q.facts, census: full.census) else {
            Issue.record("expected a frame count, got \(String(describing: E.make(facts: q.facts, census: full.census)))")
            return
        }
        #expect(abs(seconds - 10) < 0.2, "\(seconds)")
        #expect(E.counted(seconds: seconds, source: .frames).sentence == "about 10 s of video (counted from frames)")
        #expect(fractions.max > 0.5, "the census bar moves by bytes when there are no seconds: \(fractions.max)")
    }

    /// Raw ADTS AAC, 10 s at 48 kHz. ffprobe estimates a header length from
    /// the bit rate, so the card keeps that; the packet count — what is
    /// used when the header has none — agrees with it.
    @Test("raw .aac: counted from audio packets", .timeLimit(.minutes(2)))
    func rawAAC() async throws {
        try #require(VerifyVideoTestMedia.toolsAvailable)
        let dir = try VerifyVideoTestMedia.makeScratchDir("duraac")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("test_de_raw.aac").path
        try CleanupTestMedia.runFFmpeg(["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=10",
                                        "-c:a", "aac", "-f", "adts"], output: path)
        let q = try await quickInputs(path)
        let census = try await CheckMediaProbe.census(path: path, facts: q.facts)
        var headerless = q.facts
        headerless.durationSeconds = nil
        for i in headerless.streams.indices { headerless.streams[i].durationSeconds = nil }
        guard case .counted(let seconds, .audioPackets)? = E.make(facts: headerless, census: census) else {
            Issue.record("expected an audio-packet count, got \(String(describing: E.make(facts: headerless, census: census)))")
            return
        }
        #expect(abs(seconds - 10) < 0.1, "\(seconds)")
    }

    /// Control: an mp4 keeps its header length — no estimate line.
    @Test("mp4 control: header length stands", .timeLimit(.minutes(2)))
    func mp4Control() async throws {
        try #require(VerifyVideoTestMedia.toolsAvailable)
        let dir = try VerifyVideoTestMedia.makeScratchDir("durmp4")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try VerifyVideoTestMedia.generate(into: dir, name: "test_de_control.mp4", videoCodec: "libx264",
                                                     extraVideoArgs: ["-preset", "ultrafast"], audioCodec: "aac")
        let q = try await quickInputs(path)
        let census = try await CheckMediaProbe.census(path: path, facts: q.facts)
        #expect(E.hasRecordedDuration(q.facts))
        #expect(E.make(facts: q.facts, census: census) == nil)
    }
}

/// Thread-safe max of the progress fractions seen (reader thread → test).
private final class FractionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var highest = 0.0
    func add(_ f: Double) { lock.lock(); highest = Swift.max(highest, f); lock.unlock() }
    var max: Double { lock.lock(); defer { lock.unlock() }; return highest }
}
