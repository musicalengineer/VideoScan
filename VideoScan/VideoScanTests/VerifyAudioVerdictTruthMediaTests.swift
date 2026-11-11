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
// The logic / isolation / scale tests are in VerifyAudioVerdictTruthTests.swift.
// Like that file, every behaviour assertion goes through names that exist
// before and after the fix, so it was seen red on the broken code.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@MainActor
private func soundRecord(_ name: String, path: String) -> VideoRecord {
    let r = VideoRecord()
    r.filename = name
    r.fullPath = path
    r.directory = (path as NSString).deletingLastPathComponent
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
}
