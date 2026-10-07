import Foundation
import Testing
@testable import VideoScan

// MARK: - Dossier batch — characterization (golden) tests
//
// Pins EVERYTHING the two batch loops (`runDossierBatch`, pipelined, and
// `runDossierBatchSerial`) do to a mixed batch: per-record writeback and
// flags, the activity feed's notes and timings, and the live counters.
// Recorded from the pre-refactor code (Rick 2026-10-07: split these two
// functions into small units "and demonstrate you know how to do it").
// The goldens live in `DossierBatchCharacterization.golden.json` next to
// this file; a mismatch writes `<case>.actual.txt` beside it for review.
//
// Not covered here (moved verbatim, covered elsewhere or impractical):
// the Whisper deadline path (needs a 60 s minimum deadline), the probed
// DRM path (needs a real protected asset), mid-batch cancel / pause / skip
// (CaptionOrchestratorActivityTests + ShutdownTests).

/// Per-path behaviour for the scene extractor.
actor CharacterizationRunner: CaptionRunner {
    nonisolated let modelID: String = "char-vlm"
    enum Behaviour: Sendable { case normal, emptyFast, throwsError }
    private let behaviours: [String: Behaviour]
    init(behaviours: [String: Behaviour]) { self.behaviours = behaviours }

    func caption(videoPath: String, atTimestamps timestamps: [Double]) async throws -> [SceneCaption] {
        timestamps.map { SceneCaption(timestamp: $0, text: "scene") }
    }

    func dossier(videoPath: String, atTimestamps timestamps: [Double]) async throws -> DossierExtraction {
        switch behaviours[(videoPath as NSString).lastPathComponent] ?? .normal {
        case .normal:
            return DossierExtraction(
                scenes: timestamps.map { SceneCaption(timestamp: $0, text: "scene") },
                dates: [], texts: [])
        case .emptyFast:
            return .empty
        case .throwsError:
            throw NSError(domain: "char", code: 7, userInfo: [NSLocalizedDescriptionKey: "decoder exploded"])
        }
    }
}

/// Per-path behaviour for the transcriber.
final class CharacterizationTranscriber: AudioTranscriber, @unchecked Sendable {
    let modelID = "char-whisper"
    enum Behaviour: Sendable { case text(String), throwsError }
    private let behaviours: [String: Behaviour]
    private let lock = NSLock()
    private var _called: [String] = []
    init(behaviours: [String: Behaviour]) { self.behaviours = behaviours }
    var called: [String] { lock.withLock { _called } }

    func transcribe(videoPath: String, deadlineSeconds: Double?) async throws -> String {
        let name = (videoPath as NSString).lastPathComponent
        lock.withLock { _called.append(name) }
        switch behaviours[name] ?? .text("words") {
        case .text(let t): return t
        case .throwsError: throw NSError(domain: "char", code: 9)
        }
    }
}

@MainActor
@Suite("Dossier batch — characterization", .serialized)
struct DossierBatchCharacterizationTests {

    /// The mixed batch. File names encode the case; order is the batch order.
    struct Fixture {
        let dir: String
        let records: [VideoRecord]
        let runner: CharacterizationRunner
        let transcriber: CharacterizationTranscriber
    }

    static func makeFixture(tag: String) -> Fixture {
        let dir = NSTemporaryDirectory() + "test_dossier_char_\(tag)_\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func rec(_ name: String, stream: StreamType = .videoAndAudio, onDisk: Bool = true) -> VideoRecord {
            let r = VideoRecord()
            r.filename = name
            r.fullPath = dir + name
            r.streamTypeRaw = stream.rawValue
            r.durationSeconds = 3.0
            r.lifecycleStage = .cataloged
            if onDisk { FileManager.default.createFile(atPath: r.fullPath, contents: Data("x".utf8)) }
            return r
        }
        let already = rec("test_01_already.mp4")
        already.dossierProcessedAt = Date(timeIntervalSince1970: 1_000)
        already.dossierProcessedBy = "older-stack"
        let missing = rec("test_02_missing.mp4", onDisk: false)
        let drm = rec("test_03_drm_cached.m4v")
        drm.drmProtected = true
        let records = [
            already, missing, drm,
            rec("test_04_normal.mp4"),
            rec("test_05_video_only.mov", stream: .videoOnly),
            rec("test_06_audio.mp3", stream: .audioOnly),
            rec("test_07_whisper_throws.mp4"),
            rec("test_08_vlm_throws.mp4"),
            rec("test_09_vlm_empty_fast.mp4"),
            rec("test_10_blank_transcript.mp4"),
            rec("test_11_normal_last.mp4"),
        ]
        let runner = CharacterizationRunner(behaviours: [
            "test_08_vlm_throws.mp4": .throwsError,
            "test_09_vlm_empty_fast.mp4": .emptyFast,
        ])
        let transcriber = CharacterizationTranscriber(behaviours: [
            "test_07_whisper_throws.mp4": .throwsError,
            "test_10_blank_transcript.mp4": .text("   \n"),
        ])
        return Fixture(dir: dir, records: records, runner: runner, transcriber: transcriber)
    }

    /// Deterministic text description of everything observable.
    static func describe(_ orch: CaptionOrchestrator, _ fx: Fixture) -> String {
        var lines: [String] = []
        for r in fx.records {
            lines.append([
                "rec \(r.filename)",
                "dossier=\(r.dossierProcessedAt != nil && r.dossierProcessedAt != Date(timeIntervalSince1970: 1_000))",
                "by=\(r.dossierProcessedBy ?? "-")",
                "scenes=\(r.sceneCaptions.count)",
                "transcript=\(r.audioTranscript ?? "-")",
                "whisperModel=\(r.audioTranscriptModel ?? "-")",
                "needsReformat=\(r.needsReformat)",
                "purged=\(r.purgedAt != nil)",
            ].joined(separator: " "))
        }
        for e in orch.recentActivity.reversed() {   // oldest first
            lines.append("act \(e.filename) note=\(e.note ?? "-") vlm=\(e.vlmSeconds != nil) whisper=\(e.whisperSeconds != nil)")
        }
        lines.append("counts captioned=\(orch.liveCaptioned) skipped=\(orch.liveSkipped) failed=\(orch.liveFailed) already=\(orch.liveSkipAlreadyAnalyzed) missing=\(orch.liveSkipMissing) protected=\(orch.liveSkipProtected) transcriptFailures=\(orch.transcriptFailures)")
        lines.append("status \(orch.currentStatus)")
        lines.append("lanes \(orch.activeLanes.count)")
        lines.append("transcribed \(fx.transcriber.called.joined(separator: ","))")
        return lines.joined(separator: "\n")
    }

    static let goldenURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("DossierBatchCharacterization.golden.json")

    static func check(_ name: String, _ actual: String) {
        let goldens = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: goldenURL))) ?? [:]
        let actualURL = goldenURL.deletingLastPathComponent().appendingPathComponent("\(name).actual.txt")
        guard let expected = goldens[name] else {
            try? actual.write(to: actualURL, atomically: true, encoding: .utf8)
            Issue.record("no golden for \(name); wrote \(actualURL.lastPathComponent)")
            return
        }
        if expected != actual { try? actual.write(to: actualURL, atomically: true, encoding: .utf8) }
        #expect(expected == actual, "\(name) changed; see \(actualURL.lastPathComponent)")
    }

    func run(_ name: String, transcriber useTranscriber: Bool, stages: Set<AnalyzeStage>, direct serial: Bool = false) async {
        let fx = Self.makeFixture(tag: name)
        defer { try? FileManager.default.removeItem(atPath: fx.dir) }
        let model = VideoScanModel()
        model.records = fx.records
        let orch = CaptionOrchestrator(runnerFactory: { fx.runner })
        if serial {
            orch.resetLiveCounts()
            orch.liveTotal = fx.records.count
            await orch.runDossierBatchSerial(
                runner: fx.runner, transcriber: useTranscriber ? fx.transcriber : nil,
                candidates: fx.records, framesPerFile: 3, force: false, model: model,
                stackID: "char-stack", started: CFAbsoluteTimeGetCurrent(), stages: stages)
        } else {
            await orch.runDossierBatch(
                runner: fx.runner, transcriber: useTranscriber ? fx.transcriber : nil,
                candidates: fx.records, framesPerFile: 3, force: false, model: model, stages: stages)
        }
        Self.check(name, Self.describe(orch, fx))
    }

    @Test("pipelined: both stages with a transcriber")
    func pipelined() async { await run("pipelined", transcriber: true, stages: AnalyzeStage.all) }

    @Test("serial: no transcriber")
    func serialNoTranscriber() async { await run("serialNoTranscriber", transcriber: false, stages: AnalyzeStage.all) }

    @Test("serial: captions only, transcriber present")
    func serialCaptionsOnly() async { await run("serialCaptionsOnly", transcriber: true, stages: [.captions]) }

    @Test("serial: transcript only, transcriber present")
    func serialTranscriptOnly() async { await run("serialTranscriptOnly", transcriber: true, stages: [.transcript]) }

    @Test("serial entry point called directly with both stages (the activity tests' route)")
    func serialDirectBothStages() async { await run("serialDirectBothStages", transcriber: true, stages: AnalyzeStage.all, direct: true) }
}
