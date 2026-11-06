// AnalyzeLegacyCodecTests.swift
// Analyze reads legacy codecs through ffmpeg and never asks to reformat
// first (Rick 2026-11-06: "If I select say 10 files and click Analyze, it
// often tells me they need to be reformatted to be analyzed").
//
// The gate lived in the Catalog row menu: any row whose codec was on the
// legacy list (svq1/svq3/cinepak/rpza/…), or that an earlier pass had
// flagged needsReformat, got a "Reformat Required … Convert them to HEVC
// first? New files will be created next to the originals" alert instead of
// an AnalyzeJob. The analyzers already decode those files: frame extraction
// falls back to ffmpeg when AVFoundation can't open or decode the file
// (CaptionRunner.extractFramesForCaptioning), and Whisper decodes audio with
// its own ffmpeg (the admission check, audioTrackIsPresent, asks ffprobe).
//
// What these tests drive: the REAL Analyze path — MediaFileOperationsCenter
// .startAnalyze(records:) → AnalyzeJob → CaptionOrchestrator.startAnalyzing
// → the dossier loop → applyDossier. Only the models are fakes: the caption
// runner decodes frames with the production extractor and captions each
// decoded frame with its size; the transcriber runs the production audio
// admission check and then the exact ffmpeg decode mlx-whisper performs
// (`ffmpeg -nostdin -threads 0 -i <file> -f s16le -ac 1 -acodec pcm_s16le
// -ar 16000 -`), counting samples. So "captioned" means frames really
// decoded, and "transcribed" means audio really decoded.
//
// Fixtures are generated per test with ffmpeg into a scratch folder (no
// family media in the repo). Worst-case memory: one fixture (≤ 8 MB, the DV
// clips) read whole for its SHA-256, plus one decoded frame per extractor
// call; the PCM is streamed and only counted.
//
// (For Rick: `@Test(arguments:)` is a table-driven test — one body, one
// reported case per row, like a gtest TEST_P.)

import AVFoundation
import CryptoKit
import Foundation
import os
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - Fakes with real decode

/// Caption "model" that decodes frames with the production extractor (the
/// same call MLXVLMCaptionRunner makes) and captions each decoded frame
/// with its size. Throws exactly what the extractor throws.
actor RealDecodeCaptionRunner: CaptionRunner {
    nonisolated let modelID = "fake-vlm-real-decode"
    func caption(videoPath: String, atTimestamps timestamps: [Double]) async throws -> [SceneCaption] {
        let frames = try await extractFramesForCaptioning(from: URL(fileURLWithPath: videoPath),
                                                          atTimestamps: timestamps)
        return frames.compactMap { slot in
            guard case .success(let cg) = slot.frame else { return nil }
            return SceneCaption(timestamp: slot.timestamp, text: "decoded frame \(cg.width)x\(cg.height)")
        }
    }
}

/// Transcriber "model": the production admission check, then mlx-whisper's
/// own ffmpeg decode, streamed and counted (≈ a C++ read loop that only
/// tallies bytes). Returns "decoded N samples".
struct RealDecodeTranscriber: AudioTranscriber {
    let modelID = "fake-whisper-real-decode"
    func transcribe(videoPath: String, deadlineSeconds: Double?) async throws -> String {
        guard try await audioTrackIsPresent(at: videoPath) else {
            throw AudioTranscriberError.audioUnreadable(path: videoPath)
        }
        let bytes = OSAllocatedUnfairLock(initialState: 0)
        let result = await ProcessRunner.runProcess(
            executable: ToolLocator.ffmpegPath,
            arguments: ["-nostdin", "-threads", "0", "-i", videoPath,
                        "-f", "s16le", "-ac", "1", "-acodec", "pcm_s16le", "-ar", "16000", "-"],
            stdoutData: { chunk in bytes.withLock { $0 += chunk.count } },
            stdoutLimitBytes: 0,
            deadlineSeconds: 60)
        let samples = bytes.withLock { $0 } / 2
        guard result.exitCode == 0, samples > 0 else {
            throw AudioTranscriberError.subprocessFailed(exitCode: result.exitCode, stderrTail: result.stderr)
        }
        return "decoded \(samples) samples"
    }
}

// MARK: - Fixtures

/// One row of the media matrix: how ffmpeg makes it, and whether the old
/// menu gate would have held it back for Reformat.
struct AnalyzeFixture: Sendable, CustomTestStringConvertible {
    let label: String
    let file: String
    let video: [String]
    let audio: [String]
    /// An earlier pass flagged it needsReformat (the analyzer-flag case).
    var flaggedBefore = false
    var testDescription: String { label }

    static let sd = ["-s", "720x480", "-r", "30000/1001"]

    static let matrix: [AnalyzeFixture] = [
        // Controls — the five-format matrix.
        .init(label: "mp4/h264+aac", file: "clip.mp4",
              video: ["-s", "320x240", "-c:v", "libx264", "-pix_fmt", "yuv420p"], audio: ["-c:a", "aac"]),
        .init(label: "mov/prores+pcm", file: "clip.mov",
              video: ["-s", "320x240", "-c:v", "prores_ks", "-profile:v", "0"], audio: ["-c:a", "pcm_s16le"]),
        .init(label: "mkv/ffv1+pcm", file: "clip.mkv",
              video: ["-s", "320x240", "-c:v", "ffv1"], audio: ["-c:a", "pcm_s16le"]),
        .init(label: "mxf/mpeg2+pcm", file: "clip.mxf",
              video: sd + ["-c:v", "mpeg2video", "-b:v", "8M"], audio: ["-ar", "48000", "-c:a", "pcm_s16le"]),
        .init(label: "avi/dv+pcm", file: "clip.avi",
              video: sd + ["-pix_fmt", "yuv411p", "-c:v", "dvvideo"], audio: ["-ar", "48000", "-c:a", "pcm_s16le"]),
        // Legacy — what the gate named or old QuickTime / AVI shipped.
        .init(label: "mov/dv+pcm (flagged by an earlier pass)", file: "dv.mov",
              video: sd + ["-pix_fmt", "yuv411p", "-c:v", "dvvideo"], audio: ["-ar", "48000", "-c:a", "pcm_s16le"],
              flaggedBefore: true),
        .init(label: "mov/cinepak+ima4", file: "cinepak.mov",
              video: ["-s", "160x120", "-c:v", "cinepak"], audio: ["-c:a", "adpcm_ima_qt"]),
        .init(label: "mov/svq1 (Sorenson 1)+pcm", file: "svq1.mov",
              video: ["-s", "320x240", "-c:v", "svq1"], audio: ["-c:a", "pcm_s16le"]),
        .init(label: "mov/rpza (Apple Video)+pcm", file: "rpza.mov",
              video: ["-s", "320x240", "-c:v", "rpza"], audio: ["-c:a", "pcm_s16le"]),
        .init(label: "mov/smc (QuickTime Graphics)+pcm", file: "smc.mov",
              video: ["-s", "320x240", "-c:v", "smc"], audio: ["-c:a", "pcm_s16le"]),
        .init(label: "avi/msvideo1+pcm", file: "msvideo1.avi",
              video: ["-s", "320x240", "-c:v", "msvideo1"], audio: ["-c:a", "pcm_s16le"]),
        .init(label: "avi/msmpeg4v3 (DivX 3)+pcm", file: "divx3.avi",
              video: ["-s", "320x240", "-c:v", "msmpeg4"], audio: ["-c:a", "pcm_s16le"]),
        .init(label: "flv/sorenson spark+pcm", file: "spark.flv",
              video: ["-s", "320x240", "-c:v", "flv"], audio: ["-ar", "44100", "-c:a", "pcm_s16le"]),
    ]
}

@MainActor
enum AnalyzeLegacyCodecSupport {

    /// A scratch folder standing in for a media volume folder.
    static func scratchDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs-analyze-legacy-\(tag)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Generate `fx` in `dir` with ffmpeg (2 s testsrc + 440 Hz tone).
    static func generate(_ fx: AnalyzeFixture, in dir: URL) throws -> URL {
        let out = dir.appendingPathComponent(fx.file)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ToolLocator.ffmpegPath)
        proc.arguments = ["-y", "-hide_banner", "-loglevel", "error",
                          "-f", "lavfi", "-i", "testsrc=duration=2:size=320x240:rate=25",
                          "-f", "lavfi", "-i", "sine=frequency=440:duration=2:sample_rate=44100"]
            + fx.video + fx.audio + ["-shortest", out.path]
        let err = Pipe()
        proc.standardError = err
        proc.standardOutput = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw TestMediaGenerator.GeneratorError.ffmpegFailed(status: proc.terminationStatus, message: msg)
        }
        return out
    }

    /// ffprobe's codec_name for the first stream of `kind` ("v" / "a").
    static func codecName(_ url: URL, _ kind: String) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ToolLocator.ffprobePath)
        proc.arguments = ["-v", "error", "-select_streams", "\(kind):0",
                          "-show_entries", "stream=codec_name", "-of", "csv=p=0", url.path]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.split(whereSeparator: { $0 == "," || $0.isNewline }).first.map(String.init) ?? ""
    }

    /// Whole-file SHA-256, lowercase hex.
    static func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    /// A cataloged row for `url` as the scanner leaves it: codecs from
    /// ffprobe, identity = whole-file SHA-256.
    static func record(for url: URL, flaggedBefore: Bool = false) throws -> VideoRecord {
        let r = VideoRecord()
        r.filename = url.lastPathComponent
        r.fullPath = url.path
        r.directory = url.deletingLastPathComponent().path
        r.ext = url.pathExtension
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.durationSeconds = 2.0
        r.lifecycleStage = .cataloged
        r.videoCodec = codecName(url, "v")
        r.audioCodec = codecName(url, "a")
        r.needsReformat = flaggedBefore
        let size = Int64((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0)
        r.sizeBytes = size
        r.contentFixity = ContentFixity.captured(path: url.path, digest: try sha256(url), byteCount: size)
        return r
    }

    /// Which decoder serves frames: AVFoundation when it decodes a frame
    /// itself, else ffmpeg (the production fallback). Evidence for the
    /// report, not an assertion — Apple may add or drop codecs.
    static func frameDecoder(_ url: URL) async -> String {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        do {
            _ = try await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600))
            return "AVFoundation"
        } catch {
            return "ffmpeg"
        }
    }

    static func listing(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    static func awaitTerminal(_ jobs: [AnalyzeJob], timeoutSeconds: Double = 120) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if jobs.allSatisfy({ !$0.state.isActive }) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// A model, center and orchestrator wired like the app, with the fakes.
    static func harness(_ dir: URL) -> (VideoScanModel, MediaFileOperationsCenter, CaptionOrchestrator) {
        let model = VideoScanModel(logDirectory: dir.appendingPathComponent(".logs", isDirectory: true))
        let orch = CaptionOrchestrator(runnerFactory: { RealDecodeCaptionRunner() })
        orch.transcriberFactory = { RealDecodeTranscriber() }
        return (model, MediaFileOperationsCenter(), orch)
    }
}

// MARK: - Media matrix + truth

@MainActor
@Suite("Analyze reads legacy codecs as is — media matrix", .serialized)
struct AnalyzeLegacyCodecMatrixTests {
    typealias S = AnalyzeLegacyCodecSupport

    /// Every fixture is analyzed AS IS through the Analyze verb: captions
    /// from really-decoded frames and a transcript from really-decoded audio
    /// land on the ORIGINAL row (found by its whole-file SHA-256), the file's
    /// bytes are unchanged, and nothing new appears beside it.
    @Test(arguments: AnalyzeFixture.matrix)
    func analyzesTheOriginalAsIs(_ fx: AnalyzeFixture) async throws {
        try #require(TestMediaGenerator.isAvailable, "ffmpeg is required for the media matrix")
        let dir = try S.scratchDir("matrix")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try S.generate(fx, in: dir)
        let rec = try S.record(for: url, flaggedBefore: fx.flaggedBefore)
        let sha = try #require(rec.contentFixity?.digest)
        let (model, center, orch) = S.harness(dir)
        model.records = [rec]
        let before = S.listing(dir)
        let decoder = await S.frameDecoder(url)
        let legacy = hasUnplayableLegacyCodec(videoCodec: rec.videoCodec, audioCodec: rec.audioCodec)

        let jobs = center.startAnalyze(records: [rec], model: model, orchestrator: orch)

        try #require(jobs.count == 1,
                     "\(fx.label): Analyze must start one job for the file as is (got \(jobs.count) — held back for Reformat?)")
        #expect(await S.awaitTerminal(jobs), "\(fx.label): job never finished")
        #expect(center.jobs.allSatisfy { !($0 is ReformatJob) }, "\(fx.label): Analyze must never start a Reformat")
        if case .failed(let msg) = jobs[0].state { Issue.record("\(fx.label): analyze failed — \(msg)") }

        // TRUTH: the dossier is on the row whose identity is this file's digest.
        let owner = try #require(model.records.first { $0.contentFixity?.digest == sha })
        #expect(owner.id == rec.id)
        #expect(owner.sceneCaptions.count == 3,
                "\(fx.label): 3 frames requested, \(owner.sceneCaptions.count) decoded and captioned")
        #expect(owner.sceneCaptions.allSatisfy { $0.text.hasPrefix("decoded frame ") })
        #expect(owner.audioTranscript?.hasPrefix("decoded ") == true,
                "\(fx.label): transcript must come from decoded audio, got \(owner.audioTranscript ?? "nil")")
        #expect(owner.dossierProcessedAt != nil)
        #expect(!owner.needsReformat, "\(fx.label): a file that decoded is not 'needs reformat'")
        // Nothing written to media: same bytes, same folder.
        #expect(try S.sha256(url) == sha, "\(fx.label): the original's bytes changed")
        #expect(S.listing(dir) == before, "\(fx.label): a file appeared beside the original: \(S.listing(dir))")

        print("ANALYZE-MATRIX \(fx.label) | codecs \(rec.videoCodec)/\(rec.audioCodec) | "
              + "old gate \(legacy || fx.flaggedBefore ? "HELD BACK" : "passed") | frames via \(decoder) | "
              + "captions \(owner.sceneCaptions.count) | \(owner.audioTranscript ?? "-")")
    }
}

// MARK: - Isolation: an undecodable file among good ones

@MainActor
@Suite("Analyze — an undecodable file among good ones", .serialized)
struct AnalyzeUndecodableIsolationTests {
    typealias S = AnalyzeLegacyCodecSupport

    /// Three selected files, the middle one bytes no decoder reads. The good
    /// two are analyzed; the bad one's job FAILS with ffprobe's own words
    /// (the MFO OUTCOME line is that message) — never silent, never "run
    /// Reformat first"; nothing new appears in the folder.
    @Test func undecodableFileFailsWithTheDecodersReasonAndTheOthersAreAnalyzed() async throws {
        try #require(TestMediaGenerator.isAvailable, "ffmpeg is required")
        let dir = try S.scratchDir("isolation")
        defer { try? FileManager.default.removeItem(at: dir) }
        let good1 = try S.generate(AnalyzeFixture.matrix[0], in: dir)
        let good2 = try S.generate(AnalyzeFixture.matrix[7], in: dir)   // svq1
        let bad = dir.appendingPathComponent("tape-garbage.mov")
        try Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }).write(to: bad)
        let recs = try [good1, bad, good2].map { try S.record(for: $0) }
        let (model, center, orch) = S.harness(dir)
        model.records = recs
        let before = S.listing(dir)

        let jobs = center.startAnalyze(records: recs, model: model, orchestrator: orch)

        try #require(jobs.count == 3, "every selected file gets its own Analyze job (got \(jobs.count))")
        #expect(await S.awaitTerminal(jobs))
        #expect(recs[0].sceneCaptions.count == 3 && recs[0].audioTranscript != nil, "good file 1 analyzed")
        #expect(recs[2].sceneCaptions.count == 3 && recs[2].audioTranscript != nil, "good file 2 (svq1) analyzed")
        guard case .failed(let msg) = jobs[1].state else {
            Issue.record("the undecodable file must end Failed, got \(jobs[1].state)")
            return
        }
        #expect(msg.contains("Invalid data found when processing input"),
                "the failure names the decoder's own reason (ffprobe): \(msg)")
        #expect(!msg.localizedCaseInsensitiveContains("reformat"), "no Reformat hint: \(msg)")
        let outcome = MediaFileOperationsCenter.terminalSummaryLine(
            verb: jobs[1].kind.logVerb, title: jobs[1].title, state: jobs[1].state, wasRefused: false)
        #expect(outcome?.contains("tape-garbage.mov") == true && outcome?.contains("Invalid data") == true,
                "the OUTCOME line carries the file and the reason: \(outcome ?? "nil")")
        #expect(recs[1].dossierProcessedAt == nil)
        #expect(S.listing(dir) == before, "nothing written beside the originals: \(S.listing(dir))")
    }

    /// The orchestrator's per-file notes are bounded: a long volume batch of
    /// failures can't grow them without limit.
    @Test func failureNotesAreBounded() {
        var notes = DossierFailureNotes(capacity: 3)
        for i in 0..<10 { notes.record(path: "/v/\(i).mov", reason: "r\(i)") }
        #expect(notes.count == 3)
        #expect(notes.take(path: "/v/0.mov") == nil, "the oldest note was dropped")
        #expect(notes.take(path: "/v/9.mov") == "r9")
        #expect(notes.take(path: "/v/9.mov") == nil, "a note is taken once")
        #expect(notes.count == 2)
    }
}

// MARK: - The verb's routing (logic) and the menu (sensor)

@MainActor
@Suite("Analyze — one path, no reformat-first", .serialized)
struct AnalyzeRoutingTests {
    typealias S = AnalyzeLegacyCodecSupport

    /// Legacy-codec rows and rows an earlier pass flagged are dispatched to
    /// Analyze like any other — one AnalyzeJob each, no Reformat job.
    @Test func legacyAndFlaggedRowsGetAnAnalyzeJobNotAReformat() async throws {
        let dir = try S.scratchDir("routing")
        defer { try? FileManager.default.removeItem(at: dir) }
        func row(_ name: String, v: String, a: String, flagged: Bool = false) -> VideoRecord {
            let r = VideoRecord()
            r.filename = name
            r.fullPath = dir.appendingPathComponent(name).path
            r.directory = dir.path
            r.videoCodec = v
            r.audioCodec = a
            r.needsReformat = flagged
            r.durationSeconds = 2
            r.lifecycleStage = .cataloged
            FileManager.default.createFile(atPath: r.fullPath, contents: Data("x".utf8))
            return r
        }
        let recs = [row("a.mov", v: "svq3", a: "qdm2"), row("b.mov", v: "cinepak", a: "ima4"),
                    row("c.mov", v: "h264", a: "aac", flagged: true), row("d.mp4", v: "h264", a: "aac")]
        let (model, center, orch) = S.harness(dir)
        model.records = recs
        // Hold the orchestrator so the jobs wait: routing is the subject.
        orch.currentStatus = .running(progress: 0, currentFile: "foreign.mov", etaSec: nil)

        let jobs = center.startAnalyze(records: recs, model: model, orchestrator: orch)

        #expect(jobs.map(\.record.id) == recs.map(\.id), "one Analyze job per selected row, in order")
        #expect(center.jobs.allSatisfy { !($0 is ReformatJob) }, "no Reformat started by Analyze")
        jobs.forEach { $0.cancel() }
        #expect(await S.awaitTerminal(jobs, timeoutSeconds: 10))
        orch.currentStatus = .idle
    }

    /// Reformat stays its own verb (Transcode ▸ Reformat Old Codec to
    /// H.264): offered for a legacy or flagged file, never for an archived
    /// row, never for a file macOS plays.
    @Test func reformatIsOfferedOnItsOwnOnlyWhereItHelps() {
        #expect(CatalogRowMenuRules.reformatOffered(isLikelyUnanalyzable: true, readOnly: false))
        #expect(!CatalogRowMenuRules.reformatOffered(isLikelyUnanalyzable: true, readOnly: true))
        #expect(!CatalogRowMenuRules.reformatOffered(isLikelyUnanalyzable: false, readOnly: false))
    }
}

/// SENSOR (source): the Catalog row menu's Analyze handlers carry no codec
/// gate and no Reformat offer; both call the one Analyze verb.
@Suite("Analyze menu — no Reformat-before-Analyze (sensor)")
struct AnalyzeMenuNoReformatGateSensorTests {
    @Test func analyzeHandlersHaveNoReformatGate() throws {
        let code = try SourceTree.appCode(named: "Catalog/CatalogRowContextMenu+Actions.swift")
        for banned in ["Reformat Required", "startReformat(", "hasUnplayableLegacyCodec(",
                       "needsReformat", "ReformatAlertChoice"] {
            #expect(!code.contains(banned),
                    "CatalogRowContextMenu+Actions.swift must not gate Analyze on codecs or offer Reformat: found \(banned)")
        }
        let calls = code.components(separatedBy: "startAnalyze(records:").count - 1
        #expect(calls >= 1, "the menu's Analyze goes through MediaFileOperationsCenter.startAnalyze(records:)")
    }

    @Test func theAnalyzeVerbHasNoCodecGate() throws {
        let code = try SourceTree.appCode(named: "MediaOps/MediaFileOperations.swift")
        let start = try #require(code.range(of: "func startAnalyze(records:"))
        let body = String(code[start.lowerBound...].prefix(900))
        #expect(!body.contains("hasUnplayableLegacyCodec") && !body.contains("needsReformat"),
                "startAnalyze(records:) dispatches every reachable row as is")
    }
}
