import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - GH #402: a degenerate VLM generation is not a caption
//
// 2,850 of 3,128 stored ocrDate captions were the 3B captioner's
// repetition loop (`!!!!!!!!…`). The orchestrator now asks
// CaptionTextQuality.verdict before the catalog writeback and drops the
// degenerate texts — on all three dossier channels and on the
// single-prompt caption pass. These tests drive the orchestrator's write
// step with stub runners (no MLX, no model) and read the record back.
//
// Regression (rule 7): `pipelinedDossierRefusesDegenerateOCRDate`,
// `serialDossierRefusesDegenerateOCRDate`,
// `singlePromptPassRefusesDegenerateScene` and the inspector truth test
// were RED on main 65f027d7 (the junk was stored / shown).

private let realScene = "A woman in a red sweater lights candles on a birthday cake in a kitchen."
private let junk = "!!!!!!!!!!!!"

@MainActor
private func makeRecord(_ path: String, streamType: StreamType = .videoAndAudio) -> VideoRecord {
    let r = VideoRecord()
    r.filename = (path as NSString).lastPathComponent
    r.fullPath = path
    r.streamTypeRaw = streamType.rawValue
    r.durationSeconds = 3.0
    r.lifecycleStage = .cataloged
    return r
}

@MainActor
private func reachable(_ path: String) -> CatalogScanTarget {
    let t = CatalogScanTarget(searchPath: path)
    t.isReachable = true
    return t
}

/// A real (tiny) file so the orchestrator's existence guard passes.
private func touch(_ name: String) -> String {
    let path = NSTemporaryDirectory() + name
    FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
    return path
}

@MainActor
@Suite("Captions — degenerate output refused before the writeback (GH #402)")
struct CaptionDegenerateRefusalTests {

    // MARK: - Regression: dossier, pipelined path (transcriber present)

    @Test("pipelined dossier: the scene caption lands, the degenerate ocrDate does not, the file is stamped")
    func pipelinedDossierRefusesDegenerateOCRDate() async {
        let path = touch("vs-402-pipelined.mp4")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let model = VideoScanModel()
        let rec = makeRecord(path)
        model.records = [rec]
        model.scanTargets = [reachable(NSTemporaryDirectory())]

        let stub = StubDossierRunner(modelID: "stub-402", scenePerFrame: realScene,
                                     dateText: junk, textPerFrame: nil)
        let orch = CaptionOrchestrator(runnerFactory: { stub })
        await orch.startCatalogWideDossier(model: model,
                                           transcriber: StubAudioTranscriber(modelID: "stub-w-402"))

        #expect(rec.sceneCaptions.count == 3, "the real scene caption is stored for every frame")
        #expect(rec.sceneCaptions.allSatisfy { $0.text == realScene })
        #expect(rec.ocrDateCandidates.isEmpty,
                "a degenerate generation is not an OCR date: \(rec.ocrDateCandidates.map(\.text))")
        // Same stamp semantics as a legitimate "NONE": processed, not retried.
        #expect(rec.dossierProcessedAt != nil)
        guard case .finished(let captioned, _, let failed) = orch.currentStatus else {
            Issue.record("expected .finished, got \(orch.currentStatus)"); return
        }
        #expect(captioned == 1 && failed == 0, "a refused generation is not a failed file")
    }

    // MARK: - Regression: dossier, serial path (no transcriber)

    @Test("serial dossier: degenerate ocrDate and ocrText are refused, scenes kept")
    func serialDossierRefusesDegenerateOCRDate() async {
        let path = touch("vs-402-serial.mp4")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let model = VideoScanModel()
        let rec = makeRecord(path)
        model.records = [rec]
        model.scanTargets = [reachable(NSTemporaryDirectory())]

        let stub = StubDossierRunner(modelID: "stub-402-serial", scenePerFrame: realScene,
                                     dateText: junk, textPerFrame: "━━━━━━━━━━━━")
        let orch = CaptionOrchestrator(runnerFactory: { stub })
        await orch.runDossierBatchSerial(runner: stub, transcriber: nil, candidates: [rec],
                                         framesPerFile: 3, force: false, model: model,
                                         stackID: "stub-402-serial",
                                         started: CFAbsoluteTimeGetCurrent())

        #expect(rec.sceneCaptions.count == 3)
        #expect(rec.ocrDateCandidates.isEmpty)
        #expect(rec.ocrText.isEmpty)
        #expect(rec.dossierProcessedAt != nil, "stamped exactly as a 'no date found' file is")
    }

    // MARK: - Regression: single-prompt caption pass (runBatch)

    @Test("single-prompt caption pass: a degenerate scene caption is not stored")
    func singlePromptPassRefusesDegenerateScene() async {
        let path = touch("vs-402-single.mp4")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let model = VideoScanModel()
        let rec = makeRecord(path)
        model.records = [rec]

        let stub = StubCaptionRunner(modelID: "stub-402-single", captionText: junk)
        let orch = CaptionOrchestrator(runnerFactory: { stub })
        await orch.startCaptioning(target: CatalogScanTarget(searchPath: NSTemporaryDirectory()), model: model)

        #expect(await stub.countCalled() == 1)
        #expect(rec.sceneCaptions.isEmpty, "stored: \(rec.sceneCaptions.map(\.text))")
        // The writeback still ran (stamp unchanged): an empty result is
        // recorded the way an all-frames-failed run is today.
        #expect(rec.sceneCaptionModel == "stub-402-single")
    }

    // MARK: - Feature: count, OUTCOME, log line (added with the fix)

    @Test("the refusal is counted per frame and carried into the dossier OUTCOME coverage line")
    func refusalIsCountedInOutcome() async {
        let path = touch("vs-402-outcome.mp4")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let model = VideoScanModel()
        let rec = makeRecord(path)
        model.records = [rec]
        model.scanTargets = [reachable(NSTemporaryDirectory())]

        let stub = StubDossierRunner(modelID: "stub-402-out", scenePerFrame: realScene,
                                     dateText: junk, textPerFrame: "the the the the the the")
        let orch = CaptionOrchestrator(runnerFactory: { stub })
        await orch.startCatalogWideDossier(model: model,
                                           transcriber: StubAudioTranscriber(modelID: "stub-w-402"))

        #expect(orch.liveDegenerateRefused == 6, "3 frames × (ocrDate + ocrText)")
        #expect(orch.dossierCoverageLine().contains("degenerate refused · 6"), "\(orch.dossierCoverageLine())")
    }

    @Test("isolation: usable output is untouched and a fresh batch starts the count at zero")
    func usableOutputUntouched() async {
        let path = touch("vs-402-usable.mp4")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let model = VideoScanModel()
        let rec = makeRecord(path)
        model.records = [rec]
        model.scanTargets = [reachable(NSTemporaryDirectory())]

        let stub = StubDossierRunner(modelID: "stub-402-ok")   // "MAR 14 1991", "TEST OVERLAY"
        let orch = CaptionOrchestrator(runnerFactory: { stub })
        orch.liveDegenerateRefused = 99   // poisoned leftover from an imagined previous batch
        await orch.startCatalogWideDossier(model: model,
                                           transcriber: StubAudioTranscriber(modelID: "stub-w-402"))

        #expect(rec.ocrDateCandidates.map(\.text) == ["MAR 14 1991", "MAR 14 1991", "MAR 14 1991"])
        #expect(rec.ocrText.count == 3)
        #expect(orch.liveDegenerateRefused == 0)
        #expect(orch.dossierCoverageLine().contains("degenerate refused · 0"))
    }

    @Test("single-prompt pass counts its refusals")
    func singlePromptCounts() async {
        let path = touch("vs-402-single-count.mp4")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let model = VideoScanModel()
        model.records = [makeRecord(path)]
        let stub = StubCaptionRunner(modelID: "stub-402-sc", captionText: "━━━━━━━━━━━━")
        let orch = CaptionOrchestrator(runnerFactory: { stub })
        await orch.startCaptioning(target: CatalogScanTarget(searchPath: NSTemporaryDirectory()), model: model)
        #expect(orch.liveDegenerateRefused == 3)
    }

    @Test("sensor: the per-file log line names kinds, counts, model and file — never the refused text")
    func refusalLineShape() {
        let line = CaptionOrchestrator.degenerateRefusalLine(
            [("ocrDate", 3), ("ocrText", 2)], modelID: "qwen2.5-vl-3b-4bit", filename: "test_402.mov")
        #expect(line == "[captions] degenerate output refused — kind=ocrDate frames=3, kind=ocrText frames=2 model=qwen2.5-vl-3b-4bit — test_402.mov")
        #expect(!line.contains("!!"))
    }

    // MARK: - Truth: the inspector never quotes a degenerate OCR date

    @Test("truth: Copy All Metadata lists usable OCR dates only, rows stored before the fix included")
    func inspectorNeverQuotesDegenerateOCRDate() {
        let rec = VideoRecord()
        rec.filename = "test_402.mov"
        rec.fullPath = "/tmp/test_402.mov"
        rec.ocrDateCandidates = [
            SceneCaption(timestamp: 1, text: junk),
            SceneCaption(timestamp: 2, text: "JUN 21 1991"),
            SceneCaption(timestamp: 3, text: "！！！！！！！！！！"),
        ]
        let panel = InspectorPanel(record: rec, duplicateGroupMembers: [],
                                   previewImage: nil, previewOfflineVolumeName: nil)
        let text = panel.formatAllMetadata(rec)
        #expect(text.contains("JUN 21 1991"))
        #expect(text.contains("OCR Date Candidates (1):"), "the count is of shown dates")
        // Every quoted caption line ("    [mm:ss] text") passes the verdict.
        for line in text.components(separatedBy: "\n") where line.hasPrefix("    [") {
            let quoted = line.replacingOccurrences(of: #"^\s*\[[^\]]*\]\s*"#, with: "", options: .regularExpression)
            #expect(!CaptionTextQuality.verdict(quoted).isDegenerate, "inspector quoted a degenerate string: \(line)")
        }
        #expect(!text.contains(junk))
    }

    @Test("truth: a record whose only OCR dates are degenerate shows no OCR section")
    func inspectorOmitsAllDegenerateSection() {
        let rec = VideoRecord()
        rec.filename = "test_402b.mov"
        rec.fullPath = "/tmp/test_402b.mov"
        rec.ocrDateCandidates = [SceneCaption(timestamp: 1, text: junk)]
        let panel = InspectorPanel(record: rec, duplicateGroupMembers: [],
                                   previewImage: nil, previewOfflineVolumeName: nil)
        let text = panel.formatAllMetadata(rec)
        #expect(!text.contains("OCR Date Candidates"))
        #expect(!text.contains(junk))
    }
}

// MARK: - GH #402 part B: the stored junk, counted read-only in Catalog Status

@MainActor
@Suite("Catalog Status — degenerate OCR captions stored before the fix (GH #402)")
struct CatalogStatusDegenerateOCRTests {

    private func compute(_ inputs: [AnalyzeCoverageInput]) -> AnalyzeCoverageReport {
        AnalyzeCoverageCalculator.compute(inputs: inputs, volumes: [], mountedRoots: [], scope: AnalysisScope())
    }

    @Test("truth: the projection counts exactly the OCR dates the verdict calls degenerate")
    func projectionCountsByVerdict() {
        let r = VideoRecord()
        r.fullPath = "/tmp/test_402c.mov"; r.filename = "test_402c.mov"
        r.ocrDateCandidates = [SceneCaption(timestamp: 1, text: junk),
                               SceneCaption(timestamp: 2, text: "JUN 21 1991"),
                               SceneCaption(timestamp: 3, text: "！！！！！！！！")]
        #expect(AnalyzeCoverageInput(record: r).degenerateOCRDates == 2)
        let clean = VideoRecord()
        clean.fullPath = "/tmp/test_402d.mov"
        #expect(AnalyzeCoverageInput(record: clean).degenerateOCRDates == 0)
    }

    @Test("the report sums live rows only, and the count is part of the publish gate")
    func reportSumsLiveRows() {
        let inputs = [AnalyzeCoverageInput(fullPath: "/tmp/a.mov", degenerateOCRDates: 2),
                      AnalyzeCoverageInput(fullPath: "/tmp/b.mov", isHidden: true, degenerateOCRDates: 5),
                      AnalyzeCoverageInput(fullPath: "/tmp/c.mov", degenerateOCRDates: 1)]
        let report = compute(inputs)
        #expect(report.degenerateOCRDates == 3, "a hidden (purged / set-aside / superseded) row is not counted")
        var other = report
        other.degenerateOCRDates = 4
        #expect(other != report)
    }

    @Test("the band says it as an information line: never a colour, never a review item")
    func informationLineOnly() {
        let facts = CatalogFreshnessFacts()
        let without = CatalogRealityFactsBuilder.inputs(facts: facts, missing: MissingCopyCounts())
        let with = CatalogRealityFactsBuilder.inputs(facts: facts, missing: MissingCopyCounts(), degenerateOCRDates: 2_850)
        #expect(with.information.contains("2,850 degenerate OCR captions stored before 2026-10-30 — not shown in the inspector"))
        #expect(with.facts == without.facts && with.review == without.review)
        let now = Date()
        #expect(CatalogRealityPolicy.judge(with.facts, review: with.review, information: with.information, now: now).colour
                == CatalogRealityPolicy.judge(without.facts, review: without.review, information: without.information, now: now).colour)
        #expect(without.information.allSatisfy { !$0.contains("degenerate") }, "zero says nothing")
        #expect(CatalogRealityFactsBuilder.degenerateOCRLine(1) == "1 degenerate OCR caption stored before 2026-10-30 — not shown in the inspector")
    }

    @Test("scale: 100k rows (3,128 with OCR dates, 2,850 of them junk) projected and counted within 10 s")
    func scale() {
        var records: [VideoRecord] = []
        records.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let r = VideoRecord()
            r.fullPath = "/tmp/vs-402-scale/\(i).mov"
            r.filename = "\(i).mov"
            if i < 3_128 {
                r.ocrDateCandidates = [SceneCaption(timestamp: 1, text: i < 2_850 ? junk : "JUN 21 1991")]
            }
            records.append(r)
        }
        let clock = ContinuousClock()
        let start = clock.now
        let report = compute(AnalyzeCoverageCalculator.project(records))
        let elapsed = clock.now - start
        #expect(report.degenerateOCRDates == 2_850)
        #expect(elapsed < .seconds(10), "project + compute at 100k took \(elapsed)")
    }
}
