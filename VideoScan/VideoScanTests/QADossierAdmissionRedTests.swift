import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// QA red tests for branch worktree-agent-a3bdaf6849ddd05a3 (2026-10-10).

/// Captures the orchestrator's OUTCOME coverage line while a batch is armed.
final class QAOrchBox: @unchecked Sendable { weak var orch: CaptionOrchestrator? }

actor QACoverageProbeRunner: CaptionRunner {
    nonisolated let modelID = "stub-qa-probe"
    private let box: QAOrchBox
    private(set) var lines: [String] = []
    init(box: QAOrchBox) { self.box = box }
    func caption(videoPath: String, atTimestamps timestamps: [Double]) async throws -> [SceneCaption] {
        timestamps.map { SceneCaption(timestamp: $0, text: "scene") }
    }
    func dossier(videoPath: String, atTimestamps timestamps: [Double]) async throws -> DossierExtraction {
        let box = self.box
        let line = await MainActor.run { box.orch?.dossierCoverageLine() ?? "" }
        lines.append(line)
        return DossierExtraction(scenes: timestamps.map { SceneCaption(timestamp: $0, text: "a picnic") },
                                 dates: [], texts: [])
    }
}

@MainActor
@Suite("QA red — Dossier admission (2026-10-10)", .serialized)
struct QADossierAdmissionRedTests {

    typealias F = DossierAdmissionFixtures

    /// P2-a — VideoScanModel+DossierCarryOver.swift:125 (mayDonate) / :111.
    /// An A/V-pair video half (captions, no transcript) is a "likely"
    /// same-footage donor for the muxed file. Carry-over stamps the muxed
    /// file dossierProcessedAt with NO transcript, so no batch ever runs
    /// Whisper on it again.
    @Test func carryOverNeverSkipsARecipientWhoseAudioTheDonorNeverHad() async throws {
        let sb = try F.Sandbox("qa-carry-channels")
        defer { sb.cleanup() }
        let g = UUID()
        let videoHalf = sb.record("test_clip_V1.mxf", stage: .cataloged, duration: 600)
        videoHalf.streamTypeRaw = StreamType.videoOnly.rawValue
        videoHalf.sceneCaptions = [SceneCaption(timestamp: 10, text: "a birthday cake")]
        videoHalf.dossierProcessedAt = Date(timeIntervalSince1970: 1_700_000_000)
        videoHalf.dossierProcessedBy = "vlm-x"
        videoHalf.footage = DossierArchivedAdmissionTests.footage(g, .likely, original: videoHalf, rank: 0)
        let muxed = sb.record("test_clip_muxed.mov", stage: .archived, duration: 600)   // videoAndAudio
        muxed.footage = DossierArchivedAdmissionTests.footage(g, .likely, original: videoHalf, rank: 1)
        sb.model.records = [videoHalf, muxed]

        let stub = StubDossierRunner(modelID: "stub-qa-channels")
        let orch = CaptionOrchestrator(runnerFactory: { stub })
        await orch.startCatalogWideDossier(model: sb.model)

        let analyzed = Set(await stub.pathsCalled().map { ($0 as NSString).lastPathComponent })
        #expect(analyzed.contains("test_clip_muxed.mov"),
                "muxed file was stamped done from a donor with no audio channel: by=\(muxed.dossierProcessedBy ?? "nil") transcript=\(muxed.audioTranscript ?? "nil")")
    }

    /// P2-b — VideoScanModel+DossierCarryOver.swift:102-103 / :132 (personSplit
    /// is checked only within the bucket being searched). The header
    /// promises: "text that went A → B (carried) must not reach C when Rick
    /// said C ≠ A". Here A = D, B = Y (same footage as D), C = X (byte twin
    /// of Y, Rick said X ≠ D). X receives D's text through Y's same-bytes
    /// bucket, where D is not a member, so the decision is never seen.
    @Test func notSameDecisionSurvivesASameBytesHop() async throws {
        let sb = try F.Sandbox("qa-carry-chain")
        defer { sb.cleanup() }
        let g = UUID()
        let d = sb.record("test_master.mov", stage: .archived, duration: 600)
        d.sceneCaptions = [SceneCaption(timestamp: 281, text: "a dinner table")]
        d.audioTranscript = "happy birthday"
        d.dossierProcessedAt = Date(timeIntervalSince1970: 1_700_000_000)
        d.footage = DossierArchivedAdmissionTests.footage(g, .likely, original: d, rank: 0)
        let y = sb.record("test_copy_y.mov", stage: .cataloged, duration: 600)
        y.footage = DossierArchivedAdmissionTests.footage(g, .likely, original: d, rank: 1)
        let x = sb.record("test_copy_x.mov", stage: .cataloged, duration: 600)
        x.footage = DossierArchivedAdmissionTests.footage(g, .likely, original: d, rank: 2)
        for r in [y, x] { r.partialMD5 = "md5-qa-chain"; r.sizeBytes = 9_999 }
        x.footageDecisions = [FootageDecision(otherID: d.id, verdict: .notSame)]
        sb.model.records = [d, y, x]

        let stub = StubDossierRunner(modelID: "stub-qa-chain")
        let orch = CaptionOrchestrator(runnerFactory: { stub })
        await orch.startCatalogWideDossier(model: sb.model)

        #expect(x.sceneCaptions != d.sceneCaptions,
                "Rick said X is not D, yet X carries D's text: by=\(x.dossierProcessedBy ?? "nil")")
    }

    /// P3-a — CaptionOrchestrator+Dossier.swift:116-119 + :150 and
    /// CaptionOrchestrator+DossierSteps.swift:326. A per-volume pass builds
    /// its tally over EVERY record with only that volume reachable, so every
    /// eligible file on every OTHER (mounted) volume is reported as
    /// "eligible on offline volumes not queued".
    @Test func perVolumeCoverageLineDoesNotCallOtherVolumesOffline() async throws {
        let sb = try F.Sandbox("qa-pervolume-offline")
        defer { sb.cleanup() }
        let here = sb.record("test_here.mov", stage: .cataloged)
        let otherDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_qa_other_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: otherDir) }
        let elsewhere = sb.record("test_elsewhere.mov", stage: .cataloged, onDisk: false)
        elsewhere.fullPath = otherDir.appendingPathComponent("test_elsewhere.mov").path
        elsewhere.directory = otherDir.path
        FileManager.default.createFile(atPath: elsewhere.fullPath, contents: Data("x".utf8))
        sb.model.records = [here, elsewhere]

        let box = QAOrchBox()
        let probe = QACoverageProbeRunner(box: box)
        let orch = CaptionOrchestrator(runnerFactory: { probe })
        box.orch = orch
        _ = await orch.startAnalyzing(volumePrefix: sb.dir.path, model: sb.model, transcriber: nil)

        let line = await probe.lines.first ?? ""
        #expect(line.contains(", 0 eligible on offline volumes not queued"), "\(line)")
    }

    /// P3-b — VideoScanModel+LiveReload.swift:205. The external merger's
    /// date still lands on an Archived-stage row outside the archive root,
    /// which Dossier (isDossierReadOnly) and the date lane now treat as
    /// frozen — and the catch-up pass can no longer repair it.
    @Test func liveReloadMergeLeavesAnArchivedStageRowsDateAlone() throws {
        let sb = try F.Sandbox("qa-livereload")
        defer { sb.cleanup() }
        let t = sb.record("test_filed.mov", stage: .archived, onDisk: false)
        t.fullPath = "/Volumes/TestSrcQA/FromCheesegrater/test_filed.mov"
        t.directory = "/Volumes/TestSrcQA/FromCheesegrater"
        t.inferredRecordDate = F.utc(1985); t.inferredDateConfidence = 0.9
        t.inferredDateReason = "filed as 1985"
        t.dossierProcessedAt = Date(timeIntervalSince1970: 1_700_000_000)
        sb.model.records = [t]
        let fresh = VideoRecord()
        fresh.fullPath = t.fullPath; fresh.filename = t.filename; fresh.directory = t.directory
        fresh.inferredRecordDate = F.utc(1991); fresh.inferredDateConfidence = 0.95
        fresh.inferredDateReason = "on-screen date 1991"
        fresh.dossierProcessedAt = Date(timeIntervalSince1970: 1_800_000_000)
        _ = sb.model.mergeDossierFields(from: [fresh])
        // HOLD (Manager 2026-10-10): P3-b awaits Rick's ruling — a known issue
        // until LiveReload uses isDossierReadOnly; flips to a failure when fixed.
        withKnownIssue("P3-b pending Rick's ruling") {
            #expect(t.inferredRecordDate == F.utc(1985), "archived-stage row re-dated by live reload")
        }
    }

    /// P3-c — VideoScanModel+DuplicateEnrichment.swift:60. Same predicate
    /// gap on the duplicate-delete enrichment merge.
    @Test func duplicateEnrichmentDoesNotDateAnArchivedStageKeeper() throws {
        let sb = try F.Sandbox("qa-dupenrich")
        defer { sb.cleanup() }
        let master = sb.record("test_keeper.mov", stage: .archived, onDisk: false)
        master.fullPath = "/Volumes/TestSrcQA/FromCheesegrater/test_keeper.mov"
        let extra = sb.record("test_extra.mov", stage: .cataloged, onDisk: false)
        extra.fullPath = "/Volumes/TestOtherQA/test_extra.mov"
        extra.inferredRecordDate = F.utc(1991); extra.inferredDateConfidence = 0.8
        sb.model.records = [master, extra]
        _ = sb.model.applyEnrichmentInheritance(from: extra, to: master)
        // HOLD (Manager 2026-10-10): P3-c awaits Rick's ruling.
        withKnownIssue("P3-c pending Rick's ruling") {
            #expect(master.inferredRecordDate == nil, "archived-stage keeper dated by duplicate enrichment")
        }
    }

    /// PIN (green today; red if the guard at CaptionOrchestrator+Dossier.swift
    /// :570 `guard !plan.readOnly` is removed). Production runs the PIPELINED
    /// loop (a transcriber is present); every batch test in
    /// DossierArchivedAdmissionTests passes transcriber nil and so runs the
    /// SERIAL loop, which never calls flagUndecodableIfExtractorBailed.
    @Test("pipelined: a 0-scene archived file is not flagged needsReformat", arguments: [false, true])
    func pipelinedZeroSceneArchivedRowIsNotFlagged(_ archived: Bool) async throws {
        let sb = try F.Sandbox("qa-pipelined-\(archived)")
        defer { sb.cleanup() }
        let r = sb.record("test_blank.mov", stage: archived ? .archived : .cataloged)
        sb.model.records = [r]
        let empty = QAEmptySceneRunner()
        let orch = CaptionOrchestrator(runnerFactory: { empty })
        _ = await orch.startAnalyzing(volumePrefix: sb.dir.path, model: sb.model,
                                      transcriber: StubAudioTranscriber())
        #expect(r.needsReformat == !archived,
                archived ? "archived row flagged needsReformat on the pipelined path"
                         : "control: a live 0-scene row IS flagged (else this pin proves nothing)")
    }
}

actor QAEmptySceneRunner: CaptionRunner {
    nonisolated let modelID = "stub-qa-empty"
    func caption(videoPath: String, atTimestamps timestamps: [Double]) async throws -> [SceneCaption] { [] }
    func dossier(videoPath: String, atTimestamps timestamps: [Double]) async throws -> DossierExtraction {
        DossierExtraction(scenes: [], dates: [], texts: [])
    }
}
