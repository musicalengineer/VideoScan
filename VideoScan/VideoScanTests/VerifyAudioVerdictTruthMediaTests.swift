// VerifyAudioVerdictTruthMediaTests.swift
// GH #467 / #468 (2026-11-10), the two dimensions that touch the disk:
//
//   * TRUTH on real media (mp4/h264, mov/prores, mkv/ffv1+pcm, mxf, avi/dv):
//     the stored sound verdict equals what a direct astats measurement of the
//     same bytes supports; a failed read and a partial levels pass on a
//     HEALTHY file store nothing; the next run stores ok.
//   * SENSOR: one writer of the record's audio verdict, behind the typed
//     verdict; "ok" asks the one shared completeness question.
//
//   * CHECK MEDIA: the full check writes the same verdict through the same
//     writer (canned diagnoses through the real CheckMediaJob).
//
// The logic / isolation / scale tests are in VerifyAudioVerdictTruthTests.swift.
// Like that file, every behaviour assertion goes through names that exist
// before and after the fix, so it was seen red on the broken code.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private typealias S = MasterArchiveTestSupport

/// What the probe returns when the levels pass threw and the header still read.
private func readFailedDiagnosis(codec: String = "pcm_s16le") -> AudioVerifyDiagnosis {
    var shape = AudioVerifyShape()
    shape.videoCodec = "h264"
    shape.audioStreams = 1
    shape.audioCodec = codec
    shape.audioChannels = 2
    return AudioVerifyDiagnosis(findings: [.unsupportedCodec(codec: codec, decodable: false)],
                                shape: shape, balanceAnalysis: nil)
}

@MainActor
private func soundRecord(_ name: String, path: String? = nil) -> VideoRecord {
    let r = VideoRecord()
    r.filename = name
    r.fullPath = path ?? "/Volumes/T/\(name)"
    r.directory = (r.fullPath as NSString).deletingLastPathComponent
    r.streamTypeRaw = StreamType.videoAndAudio.rawValue
    return r
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

// MARK: - Check Media writes the same verdict through the same writer

@Suite("Verify Audio verdict truth — Check Media", .serialized)
@MainActor
struct VerifyAudioVerdictCheckMediaTests {

    private func fullCheck(_ name: String, audio: AudioVerifyDiagnosis,
                           seed: (VideoRecord) -> Void = { _ in }) async throws -> (VideoRecord, CheckMediaJob, MediaFileOperationsCenter) {
        let model = VideoScanModel()
        let center = MediaFileOperationsCenter()
        let rec = soundRecord(name)
        seed(rec)
        model.records = [rec]
        let quick = try CheckMediaFixtures.healthy()
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
        return (rec, job, center)
    }

    private func notRunReason(_ rec: VideoRecord) -> String? {
        if case .notRun(let reason)? = rec.mediaReportCard?.check(.sound)?.verdict { return reason }
        return nil
    }

    @Test("#467: an incomplete levels pass — no sound verdict stored, the Sound row says Not checked and why")
    func incompletePassStoresNoSoundVerdict() async throws {
        let (rec, _, center) = try await fullCheck(
            "test_cm_incomplete.avi", audio: S.soundDiagnosis(channels: [-18, -20], audioStreams: 2, levelsComplete: false))
        #expect(rec.audioVerifyStatus == "" && rec.audioVerifyDate == nil)
        #expect(notRunReason(rec)?.contains("only partly measured") == true,
                "Sound row: \(String(describing: rec.mediaReportCard?.check(.sound)))")
        #expect(rec.videoVerifyStatus == "ok", "the picture's verdict is its own")
        #expect(rec.mediaReportCard?.tier == .full, "the card is still written — its Sound row carries the reason")
        #expect(center.verifyDiagnosis(forRecordID: rec.id) != nil)
    }

    @Test("#468: a failed levels pass — not stored as damaged, the Sound row is Not checked, not Problem")
    func failedReadStoresNoSoundVerdict() async throws {
        let (rec, _, _) = try await fullCheck("test_cm_hiccup.avi", audio: readFailedDiagnosis())
        #expect(rec.audioVerifyStatus == "" && rec.audioVerifyNote == "" && rec.audioVerifyDate == nil)
        #expect(notRunReason(rec)?.contains("could not be decoded") == true,
                "Sound row: \(String(describing: rec.mediaReportCard?.check(.sound)))")
        #expect(rec.mediaReportCard?.verdict != .problem, "a failed read is not a Problem card")
    }

    @Test("#470: through the real job — the card is not OK, the log line does not say OK, the job does not count it OK")
    func aSoundNotCheckedCardIsNotLoggedOrCountedOK() async throws {
        for audio in [readFailedDiagnosis(), S.soundDiagnosis(channels: [-18, -20], audioStreams: 2, levelsComplete: false)] {
            let model = VideoScanModel()
            let rec = soundRecord("test_cm_470.avi")
            model.records = [rec]
            let quick = try CheckMediaFixtures.healthy()
            let video = VideoVerifyDiagnosis(findings: [], facts: quick.videoFacts, sample: nil,
                                             decode: VideoDecodeFacts(coverage: .complete))
            let job = CheckMediaJob(records: [rec], tier: .full, model: model, center: MediaFileOperationsCenter(),
                                    quickRunner: { _, _ in .measured(quick) },
                                    fullRunner: { _, _, _, _ in
                                        // No signal scan: its rows are honestly "not run", so
                                        // nothing but the sound stands between this card and OK.
                                        CheckMediaFullInputs(video: .success(video), audio: .success(audio), signals: nil)
                                    })
            job.start()
            await job.task?.value
            let card = try #require(rec.mediaReportCard)
            #expect(card.headline.hasPrefix("Sound not checked — "), "fixture: \(card.headline)")
            #expect(card.verdict != .ok, "the stored card's verdict")
            // The console flushes 0.15 s after a line is logged.
            let needle = "Verify: test_cm_470.avi → "
            for _ in 0..<40 where !model.dashboard.consoleLines.contains(where: { $0.contains(needle) }) {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let outcome = try #require(model.dashboard.consoleLines.last { $0.contains(needle) })
            #expect(!outcome.contains("→ OK"), "\(outcome)")
            #expect(outcome.contains("→ Sound not checked — "), "the headline stands alone, as in the summary: \(outcome)")
            #expect(CheckMediaTally(job.items).ok == 0)
        }
    }

    @Test("an earlier verdict is left alone by a full check that could not check the sound")
    func anEarlierVerdictIsLeftAlone() async throws {
        let then = Date(timeIntervalSince1970: 1_780_000_000)
        let (rec, _, _) = try await fullCheck("test_cm_earlier.avi", audio: readFailedDiagnosis()) {
            $0.audioVerifyStatus = "ok"
            $0.audioVerifyDate = then
        }
        #expect(rec.audioVerifyStatus == "ok" && rec.audioVerifyDate == then)
    }

    @Test("a complete pass and measured damage are still stored by the full check")
    func completeAndDamagedAreStored() async throws {
        let (fine, _, _) = try await fullCheck("test_cm_fine.avi", audio: S.soundDiagnosis(channels: [-18, -20]))
        #expect(fine.audioVerifyStatus == "ok")
        #expect(fine.mediaReportCard?.check(.sound)?.verdict == .ok)
        let mismatch = AudioVerifyFinding.durationMismatch(audioSeconds: 120, videoSeconds: 3780)
        let (bad, _, _) = try await fullCheck("test_cm_short.avi",
                                              audio: S.soundDiagnosis(channels: [-18, -20], extraFindings: [mismatch]))
        #expect(bad.audioVerifyStatus == "damaged")
        #expect(bad.mediaReportCard?.check(.sound)?.verdict == .problem)
    }
}

// MARK: - Sensor: one writer, one rule

@Suite("Verify Audio verdict — sensors")
struct VerifyAudioVerdictSensorTests {

    static var appRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan", isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
    }

    /// (path relative to the app folder, code lines with comment-only lines dropped).
    static func appFiles() throws -> [(rel: String, code: [Substring])] {
        var out: [(String, [Substring])] = []
        let base = appRoot
        let it = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
        while let url = it?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            let text = try String(contentsOf: url, encoding: .utf8)
            let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            out.append((String(path.dropFirst(base.path.count + 1)), code))
        }
        return out
    }

    @Test("the record's audio verdict is assigned in one file, and only from the typed verdict")
    func oneWriterBehindTheVerdict() throws {
        var writers: Set<String> = []
        for file in try Self.appFiles() {
            for line in file.code where line.contains("ecord.audioVerifyStatus = ") || line.contains("ecord.audioVerifyDate = ") {
                writers.insert(file.rel)
            }
        }
        #expect(writers == ["MediaOps/VerifyAudioJob.swift"], "writers: \(writers.sorted())")
        let job = try String(contentsOf: Self.appRoot.appendingPathComponent("MediaOps/VerifyAudioJob.swift"), encoding: .utf8)
        #expect(job.contains("switch diagnosis.verdict"), "the writer decides on the typed verdict")
        #expect(job.contains("case .notChecked"), "and has a branch that stores nothing")
    }

    @Test("ok needs a complete levels pass: the rule asks the one shared completeness question")
    func okNeedsACompletePass() throws {
        let probe = try String(contentsOf: Self.appRoot.appendingPathComponent("MediaOps/VerifyAudioProbe.swift"), encoding: .utf8)
        #expect(probe.contains("enum AudioLevelsPass"), "the levels pass's outcome is one typed value")
        #expect(!probe.contains("var analyzeFailed"), "not a Bool beside an optional")
        #expect(probe.contains("analysis.measuredSilent != nil"),
                "completeness is AudioBalanceAnalysis.measuredSilent — the question Promote's gate and Check Media ask")
    }
}

// MARK: - Truth on real media: the stored verdict is what a direct measurement supports

@Suite("Verify Audio verdict truth — media matrix", .serialized)
@MainActor
struct VerifyAudioVerdictTruthMediaTests {

    struct Container: Sendable, CustomTestStringConvertible {
        let name: String, videoCodec: String, videoArgs: [String], audioCodec: String, size: String, rate: String
        var testDescription: String { name }
    }

    nonisolated static let matrix: [Container] = [
        Container(name: "test_va_truth.mp4", videoCodec: "libx264", videoArgs: ["-preset", "ultrafast"],
                  audioCodec: "aac", size: "320x240", rate: "25"),
        Container(name: "test_va_truth.mov", videoCodec: "prores", videoArgs: [],
                  audioCodec: "pcm_s16le", size: "320x240", rate: "25"),
        Container(name: "test_va_truth.mkv", videoCodec: "ffv1", videoArgs: [],
                  audioCodec: "pcm_s16le", size: "320x240", rate: "25"),
        Container(name: "test_va_truth.mxf", videoCodec: "mpeg2video", videoArgs: ["-g", "15"],
                  audioCodec: "pcm_s16le", size: "720x576", rate: "25"),
        Container(name: "test_va_truth.avi", videoCodec: "dvvideo", videoArgs: ["-pix_fmt", "yuv411p"],
                  audioCodec: "pcm_s16le", size: "720x480", rate: "30000/1001"),
    ]

    @Test("stored verdict == direct astats measurement; a failed read and a partial pass store nothing; the next run stores ok",
          .enabled(if: VerifyAudioTestMedia.toolsAvailable), .timeLimit(.minutes(3)), arguments: matrix)
    func storedVerdictEqualsTheMeasurement(_ c: Container) async throws {
        let dir = try VerifyAudioTestMedia.makeScratchDir("truth")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try VerifyAudioTestMedia.generate(into: dir, name: c.name, videoCodec: c.videoCodec,
                                                     extraVideoArgs: c.videoArgs, audioCodec: c.audioCodec,
                                                     size: c.size, rate: c.rate)
        let model = VideoScanModel()
        let rec = soundRecord(c.name, path: path)
        model.records = [rec]

        // 1. The drive hiccups mid-pass on this HEALTHY file: the real probe,
        //    the real "is the header still readable" recheck, a levels pass
        //    that throws what ffmpeg's nonzero exit throws.
        let hiccup = await runVerify(rec, model: model) { p in
            try await VerifyAudioProbe.diagnose(path: p, analyzeOverride: { _ in
                throw AudioBalanceProbeError.probeFailed("ffmpeg astats pass on audio stream 0 exited with status 1")
            })
        }
        #expect(rec.audioVerifyStatus == "", "\(c.name): a failed read on a healthy file stored '\(rec.audioVerifyStatus)'")
        #expect(failureMessage(hiccup)?.hasPrefix("Could not check the audio — ") == true, "\(hiccup.state)")

        // 2. The real levels pass, cut short of one stream.
        let partial = await runVerify(rec, model: model) { p in
            try await VerifyAudioProbe.diagnose(path: p, analyzeOverride: { q in
                var analysis = try await AudioBalanceProbe.analyze(path: q)
                analysis.levelsComplete = false
                return analysis
            })
        }
        #expect(rec.audioVerifyStatus == "", "\(c.name): a partial pass stored '\(rec.audioVerifyStatus)'")
        #expect(failureMessage(partial)?.contains("only partly measured") == true, "\(partial.state)")

        // 3. The next run, undisturbed, checks again and stores what a direct
        //    measurement of the same bytes supports.
        let again = await runVerify(rec, model: model, nil)
        let direct = try await AudioBalanceProbe.analyze(path: path)
        #expect(direct.levelsComplete && direct.measuredSilent == false,
                "\(c.name): direct measurement — every channel read, sound present")
        #expect(direct.measurements.channels.count == 2
                && direct.measurements.channels.allSatisfy { $0.rmsMeasured && $0.rmsDBFS > -20 && $0.rmsDBFS < 0 },
                "\(c.name): a 0.5-amplitude sine is about -9 dBFS RMS: \(direct.measurements.channels.map(\.rmsDBFS))")
        #expect(rec.audioVerifyStatus == "ok" && rec.audioVerifyNote == "" && rec.audioVerifyDate != nil)
        #expect(again.state == .finished(summary: "All is well — the audio track checked out."))
    }

    // MARK: GH #470 — a decode that ends early and exits 0

    /// Containers whose header still states the sound's full length after the
    /// file's tail is cut off (mov/mp4 with the index in front, mkv, mxf).
    /// avi is not here: its header states no length for the sound stream, so
    /// there is nothing to compare the decode against.
    nonisolated static let cutShortMatrix: [Container] = [
        Container(name: "test_va_cut.mp4", videoCodec: "libx264", videoArgs: ["-preset", "ultrafast", "-movflags", "+faststart"],
                  audioCodec: "aac", size: "320x240", rate: "25"),
        Container(name: "test_va_cut.mov", videoCodec: "prores", videoArgs: ["-movflags", "+faststart"],
                  audioCodec: "pcm_s16le", size: "320x240", rate: "25"),
        Container(name: "test_va_cut.mkv", videoCodec: "ffv1", videoArgs: [],
                  audioCodec: "pcm_s16le", size: "320x240", rate: "25"),
        Container(name: "test_va_cut.mxf", videoCodec: "mpeg2video", videoArgs: ["-g", "15"],
                  audioCodec: "pcm_s16le", size: "720x576", rate: "25"),
    ]

    @Test("#470: the file's tail is cut off, ffmpeg decodes what is left and exits 0 — not a complete measurement, nothing stored",
          .enabled(if: VerifyAudioTestMedia.toolsAvailable), .timeLimit(.minutes(3)), arguments: cutShortMatrix)
    func aDecodeThatEndsEarlyIsNotStoredOk(_ c: Container) async throws {
        let dir = try VerifyAudioTestMedia.makeScratchDir("cut")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try VerifyAudioTestMedia.generate(into: dir, name: c.name, videoCodec: c.videoCodec,
                                                     extraVideoArgs: c.videoArgs, audioCodec: c.audioCodec,
                                                     size: c.size, rate: c.rate, videoDuration: 12)
        // Whole: a complete measurement, as before.
        let whole = try await VerifyAudioProbe.diagnose(path: path)
        #expect(whole.verdict == .ok && whole.levelsPass == .complete, "\(c.name) whole: \(whole.verdict)")

        // Cut to 60 % of its bytes: the header still reads and still says 12 s.
        let size = try #require((try FileManager.default.attributesOfItem(atPath: path))[.size] as? NSNumber).uint64Value
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.truncate(atOffset: size * 6 / 10)
        try handle.close()

        // The real probe, the real ffmpeg: it exits 0 on this file.
        let cut = try await VerifyAudioProbe.diagnose(path: path)
        #expect(cut.verdict != .ok, "\(c.name): a decode that stopped early was called a complete measurement")
        #expect(cut.persistedStatus == "", "\(c.name): nothing may be stored — '\(cut.persistedStatus)'")
        if case .incomplete = cut.levelsPass {} else { Issue.record("\(c.name): levels pass \(cut.levelsPass)") }
        // The part that did decode carries sound; it is still not a verdict.
        #expect(cut.balanceAnalysis?.measurements.channels.contains { $0.rmsDBFS > -20 } == true)
        #expect(cut.balanceAnalysis?.measuredSilent == nil, "\(c.name): not a measurement of the whole track")

        // Through the job: nothing stored, and it says could not check.
        let model = VideoScanModel()
        let rec = soundRecord(c.name, path: path)
        model.records = [rec]
        let job = await runVerify(rec, model: model, nil)
        #expect(rec.audioVerifyStatus == "" && rec.audioVerifyDate == nil, "\(c.name): stored '\(rec.audioVerifyStatus)'")
        #expect(failureMessage(job)?.hasPrefix("Could not check the audio — ") == true, "\(job.state)")
    }

    /// 17 s of picture, 12 s of sound that starts 5 s in.
    private func lateStartFixture(_ dir: URL, _ name: String, videoCodec: String, videoArgs: [String]) throws -> String {
        try VerifyAudioTestMedia.generate(into: dir, name: name, videoCodec: videoCodec,
                                          extraVideoArgs: videoArgs + ["-af", "asetpts=PTS+5/TB"],
                                          audioCodec: "pcm_s16le", videoDuration: 17, audioDuration: 12)
    }

    @Test("Codex #286 F3 / #287 F2, known and accepted: mov states the SOUND's length, so a whole late-starting track is a complete measurement; Matroska states the END timestamp (17 s for 12 s of sound), so the same whole track reads 'not checked' — never 'ok' by a guess",
          .enabled(if: VerifyAudioTestMedia.toolsAvailable), .timeLimit(.minutes(3)))
    func aLateStartingTrack() async throws {
        let dir = try VerifyAudioTestMedia.makeScratchDir("late")
        defer { try? FileManager.default.removeItem(at: dir) }
        let mov = try await AudioBalanceProbe.analyze(
            path: try lateStartFixture(dir, "test_va_late.mov", videoCodec: "prores", videoArgs: ["-movflags", "+faststart"]))
        #expect(mov.shortDecode == nil && mov.levelsComplete && mov.measuredSilent == false)

        let mkv = try await AudioBalanceProbe.analyze(path: try lateStartFixture(dir, "test_va_late.mkv", videoCodec: "ffv1", videoArgs: []))
        let short = try #require(mkv.shortDecode, "if Matroska's stated length ever becomes the sound's, this pin and the comment in shortDecodeOfStream go")
        #expect(abs(short.missingSeconds - 5) < 0.05 && abs(short.statedSeconds - 17) < 0.05, "\(short)")
        #expect(!mkv.levelsComplete && mkv.measuredSilent == nil)
    }

    @Test("Codex #286 F2: stream 0's decode ends early, then stream 1 cannot be decoded at all — the answer stays 'the decode ended early' (a check that RAN), never 'could not be decoded', which the Archive-anyway tick may accept",
          .enabled(if: VerifyAudioTestMedia.toolsAvailable), .timeLimit(.minutes(3)))
    func aLaterFailureDoesNotEraseAShortDecode() async throws {
        let dir = try VerifyAudioTestMedia.makeScratchDir("short_then_bad")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("test_va_two.mkv").path
        try CleanupTestMedia.runFFmpeg([
            "-f", "lavfi", "-i", "testsrc=duration=12:size=320x240:rate=25",
            "-f", "lavfi", "-i", "aevalsrc=\(VerifyAudioTestMedia.trueStereoExpr):s=48000:d=12",
            "-f", "lavfi", "-i", "aevalsrc=\(VerifyAudioTestMedia.trueStereoExpr):s=48000:d=12",
            "-map", "0:v", "-map", "1:a", "-map", "2:a", "-c:v", "ffv1", "-c:a", "pcm_s16le"], output: path)
        // The SECOND track's codec id becomes one no decoder knows (same length), then the tail is cut off.
        var bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let id = Data("A_PCM/INT/LIT".utf8)
        let first = try #require(bytes.range(of: id))
        let second = try #require(bytes.range(of: id, in: first.upperBound..<bytes.endIndex), "two PCM tracks expected")
        bytes.replaceSubrange(second, with: Data("A_BAD/INT/LIT".utf8))
        try bytes.prefix(bytes.count * 6 / 10).write(to: URL(fileURLWithPath: path))

        // The probe: no throw; the short decode of stream 0 is carried.
        let analysis = try await AudioBalanceProbe.analyze(path: path)   // RED before the fix: throws probeFailed
        #expect(analysis.shortDecode != nil && !analysis.levelsComplete && analysis.measuredSilent == nil)
        // Verify Audio and the Promote gate read it as a check that ran and came up short.
        let d = try await VerifyAudioProbe.diagnose(path: path)
        #expect(PromoteSoundGate.ranButCameUpShort(d), "the tick must not be eligible")
        guard case .unchecked(let why) = PromoteSoundGate.finding(from: d) else {
            Issue.record("\(PromoteSoundGate.finding(from: d))"); return
        }
        #expect(why.hasPrefix("the sound decode stopped early"), "\(why)")
        #expect(d.verdict != .ok && d.persistedStatus == "")
    }

    @Test("#470 unchanged: 12 s of whole, healthy sound in every matrix container is still a complete measurement",
          .enabled(if: VerifyAudioTestMedia.toolsAvailable), .timeLimit(.minutes(3)), arguments: matrix)
    func aWholeFileIsStillComplete(_ c: Container) async throws {
        let dir = try VerifyAudioTestMedia.makeScratchDir("whole")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try VerifyAudioTestMedia.generate(into: dir, name: c.name, videoCodec: c.videoCodec,
                                                     extraVideoArgs: c.videoArgs, audioCodec: c.audioCodec,
                                                     size: c.size, rate: c.rate, videoDuration: 12)
        let d = try await VerifyAudioProbe.diagnose(path: path)
        #expect(d.verdict == .ok && d.levelsPass == .complete && d.balanceAnalysis?.measuredSilent == false, "\(c.name): \(d.verdict)")
    }
}
