// VerifyAudioVerdictTruthTests.swift
// GH #467 / #468 (2026-11-10): the stored sound verdict must be supported by
// the measurement.
//
//   #467 — "ok" is stored only when the levels pass covered every declared
//          channel of every stream. An incomplete pass stores NOTHING and the
//          job says "could not check" with the reason.
//   #468 — a levels pass that FAILED while the header still reads is a failed
//          read, not damage: nothing is stored, the job says "could not
//          check", and the next run checks again. Damage is a decoded-and-bad
//          result (reference movie, short audio, an old codec).
//
// Dimensions here: logic (rules + both jobs) · isolation (poisoned
// diagnoses) · scale (100k verdicts) · the writer's relaunch shape (nothing
// stored = no key in the record's DTO). No file, no subprocess: canned
// diagnoses through VerifyAudioJob and the pure rules. The Check Media job's
// tests, the truth test on real media (five containers) and the source
// sensors are in VerifyAudioVerdictTruthMediaTests.swift (gauntlet: blocked
// with every other file that drives CheckMediaJob).
//
// Every assertion here goes through names that exist before and after the
// fix (record fields, job state, `persistedStatus`), so the file compiles
// against the broken code and is seen red there.
//
// C++ note: the fixtures build the same value structs the probe builds — an
// aggregate initializer per case, no mocks.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - Fixtures

private typealias S = MasterArchiveTestSupport

@MainActor
private func soundRecord(_ name: String, path: String? = nil) -> VideoRecord {
    let r = VideoRecord()
    r.filename = name
    r.fullPath = path ?? "/Volumes/T/\(name)"
    r.directory = (r.fullPath as NSString).deletingLastPathComponent
    r.streamTypeRaw = StreamType.videoAndAudio.rawValue
    return r
}

/// What the probe returns when the levels pass threw and the header still
/// read (`analyzeFailed`): no analysis, one "could not be decoded" finding.
private func readFailedDiagnosis(codec: String = "pcm_s16le",
                                 extra: [AudioVerifyFinding] = []) -> AudioVerifyDiagnosis {
    var shape = AudioVerifyShape()
    shape.videoCodec = "h264"
    shape.audioStreams = 1
    shape.audioCodec = codec
    shape.audioChannels = 2
    return AudioVerifyDiagnosis(findings: [.unsupportedCodec(codec: codec, decodable: false)] + extra,
                                shape: shape, balanceAnalysis: nil)
}

@MainActor
private func runVerify(_ rec: VideoRecord, model: VideoScanModel,
                       _ diagnose: (@Sendable (String) async throws -> AudioVerifyDiagnosis)?) async -> VerifyAudioJob {
    let job = VerifyAudioJob(record: rec, model: model, diagnoseOverride: diagnose)
    job.start()
    await job.task?.value
    return job
}

@MainActor
private func failureMessage(_ job: VerifyAudioJob) -> String? {
    if case .failed(let message) = job.state { return message }
    return nil
}

// MARK: - #467: an incomplete levels pass is never stored "ok"

@Suite("Verify Audio verdict truth — #467 incomplete levels pass")
@MainActor
struct VerifyAudioIncompleteLevelsTests {

    @Test("a pass that skipped a stream stores nothing; the job says could not check, with the reason")
    func aSkippedStreamIsNotStoredOk() async throws {
        let model = VideoScanModel()
        let rec = soundRecord("two-pairs.dv")
        model.records = [rec]
        let incomplete = S.soundDiagnosis(channels: [-18, -20], audioStreams: 2, levelsComplete: false)
        let job = await runVerify(rec, model: model) { _ in incomplete }

        #expect(rec.audioVerifyStatus == "", "an incomplete pass is not a verdict")
        #expect(rec.audioVerifyNote == "")
        #expect(rec.audioVerifyDate == nil)
        let message = try #require(failureMessage(job), "the job must end 'could not check', not finished: \(job.state)")
        #expect(message.hasPrefix("Could not check the audio — "))
        #expect(message.contains("only partly measured"), "the reason is named: \(message)")
        #expect(message.contains("no verdict was recorded"))
    }

    @Test("a channel whose level could not be read stores nothing — never ok, never one-sided")
    func aParseGapIsNotStoredOk() async throws {
        let model = VideoScanModel()
        let rec = soundRecord("gap.mov")
        model.records = [rec]
        let gap = S.soundDiagnosis(channels: [-18, nil], levelsComplete: true)
        let job = await runVerify(rec, model: model) { _ in gap }

        #expect(rec.audioVerifyStatus == "")
        #expect(rec.audioVerifyDate == nil)
        #expect(failureMessage(job)?.contains("only partly measured") == true, "\(job.state)")
    }

    @Test("no level finding is built from an incomplete pass: not one-sided, not silent, not surround")
    func noLevelFindingsFromAnIncompletePass() {
        for channels in [[-18, -Double.infinity], [-Double.infinity, -Double.infinity],
                         [-18, -18, -18, -18, -18, -18]] as [[Double]] {
            let complete = S.soundDiagnosis(channels: channels, levelsComplete: true)
            let incomplete = S.soundDiagnosis(channels: channels, levelsComplete: false)
            #expect(!complete.findings.isEmpty, "precondition: \(channels) has a level finding when measured")
            #expect(incomplete.findings.isEmpty, "an unmeasured fact is not a finding: \(incomplete.findings)")
            #expect(!incomplete.isHealthy, "and it is not 'All is well' either")
            #expect(incomplete.persistedStatus != "ok" && incomplete.persistedStatus != "damaged")
        }
    }

    @Test("a verdict stored earlier is left exactly as it was: status, note and date")
    func anEarlierVerdictIsLeftAlone() async {
        let model = VideoScanModel()
        let rec = soundRecord("earlier.mov")
        let then = Date(timeIntervalSince1970: 1_780_000_000)
        rec.audioVerifyStatus = "ok"
        rec.audioVerifyNote = "mono audio"
        rec.audioVerifyDate = then
        model.records = [rec]
        _ = await runVerify(rec, model: model) { _ in
            S.soundDiagnosis(channels: [-18, -20], levelsComplete: false)
        }
        #expect(rec.audioVerifyStatus == "ok")
        #expect(rec.audioVerifyNote == "mono audio")
        #expect(rec.audioVerifyDate == then, "a run that could not check must not re-date the old verdict")
    }

    @Test("the diagnosis is still handed over, so the results sheet can say what was not checked")
    func theDiagnosisIsStillCached() async {
        let center = MediaFileOperationsCenter()
        let model = VideoScanModel()
        let rec = soundRecord("cached.mov")
        model.records = [rec]
        let job = center.startVerifyAudio(record: rec, model: model, diagnoseOverride: { _ in
            S.soundDiagnosis(channels: [-18, -20], levelsComplete: false)
        })
        await job?.task?.value
        #expect(rec.audioVerifyStatus == "")
        #expect(center.verifyDiagnosis(forRecordID: rec.id)?.isHealthy == false)
    }

    @Test("a complete pass is still stored: ok, ok with a note, and the all-clear summary")
    func aCompletePassIsStored() async {
        let model = VideoScanModel()
        let fine = soundRecord("fine.mov"), oneSided = soundRecord("left.mov")
        model.records = [fine, oneSided]
        let a = await runVerify(fine, model: model) { _ in S.soundDiagnosis(channels: [-18, -20]) }
        let b = await runVerify(oneSided, model: model) { _ in S.soundDiagnosis(channels: [-18, -.infinity]) }
        #expect(a.state == .finished(summary: "All is well — the audio track checked out."))
        #expect(fine.audioVerifyStatus == "ok" && fine.audioVerifyNote == "" && fine.audioVerifyDate != nil)
        #expect(b.state == .finished(summary: "one-sided audio (left only)"))
        #expect(oneSided.audioVerifyStatus == "ok" && oneSided.audioVerifyNote == "one-sided audio (left only)")
    }

    @Test("WRITER, relaunch shape: a run that could not check leaves no audio-verdict key in the saved record")
    func nothingStoredMeansNoKeyOnDisk() async throws {
        let model = VideoScanModel()
        let rec = soundRecord("relaunch.mov")
        model.records = [rec]
        _ = await runVerify(rec, model: model) { _ in
            S.soundDiagnosis(channels: [-18, -20], levelsComplete: false)
        }
        let json = try String(decoding: JSONEncoder().encode(VideoRecordDTO(rec)), as: UTF8.self)
        #expect(!json.contains("audioVerifyStatus") && !json.contains("audioVerifyDate"),
                "media_checks takes only 'ok' / 'damaged' — a not-checked run writes no row")
        let back = try JSONDecoder().decode(VideoRecord.self, from: Data(json.utf8))
        #expect(back.audioVerifyStatus == "" && back.audioVerifyDate == nil)
    }

    // MARK: GH #470 — a decode that ended early (the pure rule)

    @Test("#470: short means more than 1 s AND more than 2 % of the stated length is missing")
    func theShortDecodeRule() {
        func short(_ decodedSeconds: Double?, of stated: Double?, rate: Int? = 48_000) -> Double? {
            AudioBalanceProbe.shortDecodeSeconds(decodedSamples: decodedSeconds.map { Int64($0 * 48_000) },
                                                 sampleRateHz: rate, statedSeconds: stated)
        }
        // Whole, and inside the tolerance on both sides of each line.
        #expect(short(12, of: 12) == nil)
        #expect(short(11.1, of: 12) == nil, "0.9 s missing: under 1 s")
        #expect(short(2, of: 2.9) == nil, "31 % missing but only 0.9 s")
        #expect(short(7100, of: 7200) == nil, "100 s missing of two hours is 1.4 %: under 2 %")
        #expect(short(13, of: 12) == nil, "more sound than stated is not a short decode")
        // Beyond both.
        #expect(short(7.2, of: 12).map { abs($0 - 4.8) < 0.001 } == true, "the 60 % cut")
        #expect(short(10.9, of: 12) != nil, "1.1 s and 9 %")
        #expect(short(7000, of: 7200) != nil, "200 s and 2.8 %")
        #expect(short(0, of: 12) == 12, "nothing decoded")
        // A stated length and no count: not evidence the decode finished.
        #expect(short(nil, of: 12) == 12)
        // Nothing to compare against: never a finding.
        #expect(short(7.2, of: nil) == nil && short(7.2, of: 0) == nil)
        #expect(short(7.2, of: 12, rate: nil) == nil && short(7.2, of: 12, rate: 0) == nil)
        #expect(AudioBalanceProbe.shortDecodeToleranceSeconds == 1.0 && AudioBalanceProbe.shortDecodeToleranceFraction == 0.02)
    }

    @Test("#470: the sample count is astats' own line; a missing or unreadable line is nil, and the levels still parse")
    func theSampleCountLine() {
        let tag = "vs0123456789abcdef0123456789abcdef"
        let p = "[astats@\(tag) @ 0x7548c00d80] "
        let stderr = p + "Channel: 1\n" + p + "Peak level dB: -21.07\n" + p + "RMS level dB: -24.08\n"
            + p + "Channel: 2\n" + p + "Peak level dB: -21.07\n" + p + "RMS level dB: -24.08\n"
            + p + "Overall\n" + p + "Number of samples: 220500\n"
            + "size=N/A time=00:00:05.00 bitrate=N/A speed=1e+03x\n"
        #expect(AstatsOutputParser.samplesPerChannel(fromStderr: stderr, runTag: tag) == 220_500)
        for levels in [AstatsOutputParser.perChannelLevels(fromStderr: stderr, runTag: tag),
                       AstatsOutputParser.perChannelLevels(fromStderr: stderr)] {
            #expect(levels.count == 2 && levels.allSatisfy { $0.rmsMeasured && $0.rmsDBFS == -24.08 }, "the Overall section adds no channel")
        }
        #expect(AstatsOutputParser.samplesPerChannel(fromStderr: p + "Channel: 1\n" + p + "RMS level dB: -24\n", runTag: tag) == nil)
        #expect(AstatsOutputParser.samplesPerChannel(fromStderr: p + "Number of samples: many\n", runTag: tag) == nil)
        #expect(AstatsOutputParser.samplesPerChannel(fromStderr: "", runTag: tag) == nil)
        #expect(AudioBalanceProbe.astatsFilter.contains("measure_overall=Number_of_samples"), "the pass asks for the count")
    }

    @Test("#470: the stated length is the stream's own — duration, else Matroska's DURATION tag, else unknown (never the container's)")
    func theStatedLength() throws {
        func infos(_ audio: String) throws -> [AudioBalanceStreamInfo] {
            let json = #"{"streams":[{"index":0,"codec_type":"video","codec_name":"ffv1","duration":"99.0"},"# + audio
                + #"],"format":{"format_name":"x","duration":"99.0"}}"#
            return try AudioBalanceProbe.shape(fromProbeJSON: Data(json.utf8)).audioStreamInfos
        }
        let mov = try infos(#"{"index":1,"codec_type":"audio","codec_name":"pcm_s16le","channels":2,"sample_rate":"48000","duration":"12.000000","tags":{}}"#)
        #expect(mov.first?.statedSeconds == 12 && mov.first?.sampleRateHz == 48_000)
        let mkv = try infos(#"{"index":1,"codec_type":"audio","codec_name":"pcm_s16le","channels":2,"sample_rate":"44100","tags":{"DURATION":"01:02:03.500000000"}}"#)
        #expect(mkv.first?.statedSeconds == 3723.5 && mkv.first?.sampleRateHz == 44_100)
        let avi = try infos(#"{"index":1,"codec_type":"audio","codec_name":"pcm_s16le","channels":2,"sample_rate":"48000"}"#)
        #expect(avi.first?.statedSeconds == nil, "no stream length stated: the container's 99 s is not borrowed")
        #expect(AudioBalanceProbe.seconds(fromDurationTag: "garbage") == nil && AudioBalanceProbe.seconds(fromDurationTag: nil) == nil)
        #expect(AudioBalanceProbe.shapeArgs(input: "x").contains { $0.contains("sample_rate,duration:stream_tags=DURATION") })
    }

    @Test("Codex #286 F1 / #287 F1: only a line THIS run's astats instance logged is the measurement — the file's own metadata (values and multi-line keys) is printed on the same stream and cannot know the run's tag")
    func onlyThisRunsLinesCount() {
        typealias A = AstatsOutputParser
        let tag = A.newRunTag()
        let mine = "[astats@\(tag) @ 0x7516c30a80] "
        let genuine = mine + "Channel: 1\n" + mine + "Peak level dB: -18.0\n" + mine + "RMS level dB: -21.0\n"
            + mine + "Overall\n" + mine + "Number of samples: 345088\n"
        // What a file can put at column 0 through a metadata key with newlines (Codex #287): the default
        // instance name, a named instance with a guessed tag, and a bare line.
        let forged = "    REVIEW\n"
            + "[Parsed_astats_0 @ 0x1] Channel: 1\n[Parsed_astats_0 @ 0x1] RMS level dB: -3\n"
            + "[Parsed_astats_0 @ 0x1] Channel: 2\n[Parsed_astats_0 @ 0x1] RMS level dB: -3\n"
            + "[Parsed_astats_0 @ 0x1] Overall\n[Parsed_astats_0 @ 0x1] Number of samples: 576000\n"
            + "[astats@vs00000000000000000000000000000000 @ 0x1] Number of samples: 576000\n"
            + "[astats@ @ 0x1] Number of samples: 576000\nNumber of samples: 576000\n"
            + "    COMMENT         : x] Number of samples: 576000\n"
        // Forged lines before AND after the genuine ones change nothing.
        for text in [forged + genuine, genuine + forged, forged + genuine + forged] {
            #expect(A.samplesPerChannel(fromStderr: text, runTag: tag) == 345_088)
            let levels = A.perChannelLevels(fromStderr: text, runTag: tag)
            #expect(levels.count == 1 && levels.first?.rmsDBFS == -21.0, "no forged channel, no forged level: \(levels)")
        }
        // Only forged lines (the genuine ones never printed, or pushed out of the kept stderr): no count, no levels.
        #expect(A.samplesPerChannel(fromStderr: forged, runTag: tag) == nil)
        #expect(A.perChannelLevels(fromStderr: forged, runTag: tag).isEmpty)
        // …so a stated length reads short by all of it, never complete.
        #expect(AudioBalanceProbe.shortDecodeSeconds(decodedSamples: A.samplesPerChannel(fromStderr: forged, runTag: tag),
                                                     sampleRateHz: 48_000, statedSeconds: 12) == 12)
        // A progress line ends in a carriage return; the count after it still reads.
        #expect(A.samplesPerChannel(fromStderr: "size=N/A time=00:00:12.00 speed=1e+03x\r" + mine + "Number of samples: 576000\n", runTag: tag) == 576_000)
        // Two counts that disagree, a negative or an overflowing count: nil.
        #expect(A.samplesPerChannel(fromStderr: mine + "Number of samples: 1\n" + mine + "Number of samples: 2\n", runTag: tag) == nil)
        #expect(A.samplesPerChannel(fromStderr: mine + "Number of samples: -5\n", runTag: tag) == nil)
        #expect(A.samplesPerChannel(fromStderr: mine + "Number of samples: 99999999999999999999999\n", runTag: tag) == nil)

        // The tag: fresh every run, letters and digits only (safe inside a filter description), and in the args.
        let other = A.newRunTag()
        #expect(tag != other && tag.count == 34 && tag.hasPrefix("vs") && tag.allSatisfy { $0.isLetter || $0.isNumber })
        #expect(AudioBalanceProbe.astatsFilter(runTag: tag) == "astats@\(tag)=measure_perchannel=Peak_level+RMS_level:measure_overall=Number_of_samples")
        #expect(AudioBalanceProbe.astatsFilter(runTag: nil) == AudioBalanceProbe.astatsFilter)
        #expect(AudioBalanceProbe.levelsArgs(input: "x", audioStreamOrdinal: 1, runTag: tag).contains(AudioBalanceProbe.astatsFilter(runTag: tag)))
        #expect(AudioBalanceProbe.differenceArgs(input: "x", runTag: tag).contains { $0.hasSuffix("," + AudioBalanceProbe.astatsFilter(runTag: tag)) })
    }

    @Test("Codex #287 F2: no timestamp takes sound off a stated length — a stated 12 s with 6 s decoded is short whatever the file's first packet says")
    func noCorrectionFromTimestamps() {
        // The correction (#286 F3) is gone: the rule has three inputs and no other.
        #expect(AudioBalanceProbe.shortDecodeSeconds(decodedSamples: 288_000, sampleRateHz: 48_000, statedSeconds: 12) == 6)
        let info = AudioBalanceStreamInfo(absoluteIndex: 1, codec: "pcm_s16le", channels: 1, bitRate: nil,
                                          sampleRateHz: 48_000, statedSeconds: 12)
        let shape = AudioBalanceStreamShape(videoCodec: "ffv1", totalStreams: 2, videoStreams: 1, audioStreams: 1,
                                            audioCodec: "pcm_s16le", audioChannels: 1, audioBitRate: nil, durationSeconds: 12,
                                            audioStreamInfos: [info])
        let tag = AstatsOutputParser.newRunTag()
        let stderr = "[astats@\(tag) @ 0x1] Number of samples: 288000\n"
        #expect(AudioBalanceProbe.shortDecodeOfStream(0, levelsStderr: stderr, runTag: tag, shape: shape, path: "/x/test.mkv")
                == AudioShortDecode(missingSeconds: 6, statedSeconds: 12))
    }

    @Test("Codex #286 F2 (the pure half): a levels pass that gave no measurement is named — our timeout is never a decode failure")
    func theLevelsFailure() {
        typealias P = AudioBalanceProbe
        let ch = [AudioChannelLevels(rmsDBFS: -20, peakDBFS: -14)]
        #expect(P.levelsFailure(exitCode: 0, timedOut: false, channels: ch, ordinal: 1, deadline: 300) == nil)
        // The runner's deadline can fire as the child finishes: exit 0 is still a measurement.
        #expect(P.levelsFailure(exitCode: 0, timedOut: true, channels: ch, ordinal: 1, deadline: 300) == nil)
        #expect(P.levelsFailure(exitCode: 0, timedOut: false, channels: [], ordinal: 1, deadline: 300)
                == .probeFailed("astats produced no per-channel measurements for audio stream 1"))
        #expect(P.levelsFailure(exitCode: 234, timedOut: false, channels: [], ordinal: 1, deadline: 300)
                == .probeFailed("ffmpeg astats pass on audio stream 1 exited with status 234"))
        #expect(P.levelsFailure(exitCode: 234, timedOut: true, channels: [], ordinal: 1, deadline: 300) == .timedOut(afterSeconds: 300))
    }
}

// MARK: - #468: a failed read is not damage

@Suite("Verify Audio verdict truth — #468 a failed read is not damage")
@MainActor
struct VerifyAudioReadFailureTests {

    @Test("levels pass failed, header still reads: nothing stored, not in the damaged selection, could not check")
    func aFailedReadIsNotStoredDamaged() async throws {
        let model = VideoScanModel()
        let rec = soundRecord("hiccup.mov")
        model.records = [rec]
        let job = await runVerify(rec, model: model) { _ in readFailedDiagnosis() }

        #expect(rec.audioVerifyStatus == "", "a failed read is not a damage verdict")
        #expect(rec.audioVerifyNote == "")
        #expect(rec.audioVerifyDate == nil)
        #expect(model.records.filter { $0.audioVerifyStatus == "damaged" }.isEmpty,
                "it must not join the damaged-file selection")
        let message = try #require(failureMessage(job), "the job must end 'could not check': \(job.state)")
        #expect(message.hasPrefix("Could not check the audio — "))
        #expect(message.contains("could not be decoded") && message.contains("pcm_s16le"))
        #expect(message.contains("no verdict was recorded"))
        #expect(!message.lowercased().contains("damaged"))
    }

    @Test("an earlier ok is not turned into damaged by a failed read")
    func anEarlierOkSurvivesAFailedRead() async {
        let model = VideoScanModel()
        let rec = soundRecord("was-ok.mov")
        let then = Date(timeIntervalSince1970: 1_780_000_000)
        rec.audioVerifyStatus = "ok"
        rec.audioVerifyDate = then
        model.records = [rec]
        _ = await runVerify(rec, model: model) { _ in readFailedDiagnosis() }
        #expect(rec.audioVerifyStatus == "ok" && rec.audioVerifyNote == "" && rec.audioVerifyDate == then)
    }

    @Test("decoded-and-bad is still damaged: reference movie, short audio, an old codec — and short audio beside a failed pass")
    func measuredDamageIsStillStored() async {
        let model = VideoScanModel()
        var shape = AudioVerifyShape()
        shape.audioStreams = 1
        shape.audioCodec = "qdm2"
        let mismatch = AudioVerifyFinding.durationMismatch(audioSeconds: 120, videoSeconds: 3780)
        let cases: [(String, AudioVerifyDiagnosis)] = [
            ("pointer.mov", AudioVerifyDiagnosis(findings: [.referenceMovie(referencedPaths: ["/x"])],
                                                 shape: AudioVerifyShape(), balanceAnalysis: nil)),
            ("short.mov", S.soundDiagnosis(channels: [-18, -20], extraFindings: [mismatch])),
            ("qdm2.mov", AudioVerifyDiagnosis(findings: [.unsupportedCodec(codec: "qdm2", decodable: true)],
                                              shape: shape, balanceAnalysis: nil)),
            ("short-and-failed.mov", readFailedDiagnosis(extra: [mismatch])),
        ]
        for (name, diagnosis) in cases {
            let rec = soundRecord(name)
            model.records.append(rec)
            let job = await runVerify(rec, model: model) { _ in diagnosis }
            #expect(rec.audioVerifyStatus == "damaged", "\(name): \(job.state)")
            #expect(rec.audioVerifyNote.hasPrefix(VerifyAudioRules.damagedNotePrefix), "\(name): \(rec.audioVerifyNote)")
            #expect(job.state == .finished(summary: rec.audioVerifyNote), "\(name)")
        }
    }

    @Test("Repair Damaged Audio still chains a rebuild for a track that could not be decoded")
    func autoRepairStillChainsARebuild() async {
        let center = MediaFileOperationsCenter()
        let model = VideoScanModel()
        let rec = soundRecord("rebuild-me.mov")
        model.records = [rec]
        let job = center.startVerifyAudio(record: rec, model: model, autoRepair: true,
                                          diagnoseOverride: { _ in readFailedDiagnosis(codec: "qdm2") })
        await job?.task?.value
        let rebuilds = center.jobs.compactMap { $0 as? RebuildAudioJob }
        #expect(rebuilds.count == 1, "the rebuild is the way to find out whether the track decodes")
        #expect(rec.audioVerifyStatus == "")
        await rebuilds.first?.task?.value
    }

    @Test("the same answer as the Promote sound gate: what the gate calls 'could not check', Verify does not store")
    func consistentWithThePromoteSoundGate() {
        let mismatch = AudioVerifyFinding.durationMismatch(audioSeconds: 120, videoSeconds: 3780)
        let cases: [AudioVerifyDiagnosis] = [
            readFailedDiagnosis(),
            readFailedDiagnosis(extra: [mismatch]),
            S.soundDiagnosis(channels: [-18, -20], levelsComplete: false),
            S.soundDiagnosis(channels: [-18, nil]),
            S.soundDiagnosis(channels: [-18, -20]),
            S.soundDiagnosis(channels: [-70, -70]),
            S.soundDiagnosis(channels: [], audioStreams: 0),
            S.soundDiagnosis(channels: [-18, -20], extraFindings: [mismatch]),
        ]
        for d in cases {
            let stored = d.persistedStatus
            switch PromoteSoundGate.finding(from: d) {
            case .unchecked: #expect(stored == "", "gate: could not check → nothing stored (\(d.findings))")
            case .damaged: #expect(stored == "damaged", "gate: damaged → damaged (\(d.findings))")
            case .present, .silent, .noTrack: #expect(stored == "ok", "gate: measured → ok (\(d.findings))")
            }
        }
    }
}

// MARK: - Isolation: poisoned diagnoses never read as ok

@Suite("Verify Audio verdict truth — isolation")
struct VerifyAudioVerdictIsolationTests {

    @Test("diagnoses no probe would build are never stored ok")
    func poisonedDiagnosesAreNotOk() {
        var shape = AudioVerifyShape()
        shape.audioStreams = 1
        shape.audioCodec = "aac"
        // A sound track, no findings, no levels at all.
        let neverDecoded = AudioVerifyDiagnosis(findings: [], shape: shape, balanceAnalysis: nil)
        // "Complete", but with no channel measured.
        var empty = S.soundDiagnosis(channels: [-18, -20])
        empty.balanceAnalysis?.measurements = AudioBalanceMeasurements(channels: [], differenceRMSDBFS: nil)
        // A failed pass that also carries an analysis.
        var both = S.soundDiagnosis(channels: [-18, -20])
        both.findings = [.unsupportedCodec(codec: "aac", decodable: false)]
        // A level finding pasted onto an incomplete pass.
        var pasted = S.soundDiagnosis(channels: [-18, -20], levelsComplete: false)
        pasted.findings = [.silentAudio]

        for (name, d) in [("never decoded", neverDecoded), ("no channels", empty),
                          ("failed + analysis", both), ("pasted finding", pasted)] {
            #expect(d.persistedStatus == "", "\(name): got '\(d.persistedStatus)'")
            #expect(!d.isHealthy, "\(name) is not 'All is well'")
        }
    }

    @Test("a file with no sound track, and a reference movie, need no levels pass")
    func noLevelsPassNeeded() {
        #expect(S.soundDiagnosis(channels: [], audioStreams: 0).persistedStatus == "ok")
        let pointer = AudioVerifyDiagnosis(findings: [.referenceMovie(referencedPaths: ["/x"])],
                                           shape: AudioVerifyShape(), balanceAnalysis: nil)
        #expect(pointer.persistedStatus == "damaged")
    }
}

// MARK: - Scale

@Suite("Verify Audio verdict truth — scale")
struct VerifyAudioVerdictScaleTests {

    @Test("100,000 verdicts are decided in under a second")
    func hundredThousandVerdicts() {
        let kinds = [S.soundDiagnosis(channels: [-18, -20]),
                     S.soundDiagnosis(channels: [-18, -20], levelsComplete: false),
                     readFailedDiagnosis(),
                     S.soundDiagnosis(channels: [-18, -.infinity])]
        let clock = ContinuousClock()
        var ok = 0, notStored = 0
        let elapsed = clock.measure {
            for i in 0..<100_000 {
                switch kinds[i % kinds.count].persistedStatus {
                case "ok": ok += 1
                case "": notStored += 1
                default: break
                }
            }
        }
        #expect(ok == 50_000 && notStored == 50_000, "ok \(ok), not stored \(notStored)")
        #expect(elapsed < .seconds(1), "100k verdicts took \(elapsed)")
    }
}
