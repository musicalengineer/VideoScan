import Foundation
import Testing
@testable import VideoScan

// MARK: - AnalyzeJob wait-loop behavior (QA review 2026-07-14)
//
// The 2026-07-14 wait-for-turn loop let a single-file AnalyzeJob wait
// while a volume batch owns the orchestrator. Two defects hid in it:
//
//   F3 — cancel() fell back to orchestrator.cancel() whenever no lane
//        matched this record's path. A WAITING job has no lane, so
//        cancelling the waiting row aborted the FOREIGN running batch.
//        Fixed: the orchestrator-level cancel fires only when the
//        current batch belongs to this job (currentVolumePrefix ==
//        record.fullPath — the single-file batch key).
//   F5 — the loop called startAnalyzing every 400 ms; each refusal
//        logged a warning. N waiting jobs behind an hours-long batch
//        = tens of thousands of lines. Fixed: poll the plain
//        currentStatus.isActive bool and only attempt startAnalyzing
//        when the orchestrator looks idle.

// MARK: Fixtures

@MainActor
private func waitLoopRecord(fullPath: String) -> VideoRecord {
    let r = VideoRecord()
    r.filename = (fullPath as NSString).lastPathComponent
    r.fullPath = fullPath
    r.streamTypeRaw = StreamType.videoAndAudio.rawValue
    r.durationSeconds = 3.0
    r.lifecycleStage = .cataloged
    return r
}

/// One tmp media stand-in so AnalyzeJob's fileExists pre-flight passes.
@MainActor
private func makeTempClip(tag: String) throws -> (root: String, record: VideoRecord) {
    let root = NSTemporaryDirectory() + "vs-analyzejob-\(tag)-\(UUID().uuidString)/"
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    let file = root + "clip.mp4"
    FileManager.default.createFile(atPath: file, contents: Data("x".utf8))
    return (root, waitLoopRecord(fullPath: file))
}

@MainActor
private func awaitTerminal(_ job: AnalyzeJob, timeoutSeconds: Double = 10) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if !job.state.isActive { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}

// MARK: - Tests

@MainActor
@Suite("AnalyzeJob wait loop")
struct AnalyzeJobWaitLoopTests {

    @Test("F3: cancelling a WAITING job leaves the foreign running batch alone")
    func cancelWaitingJobDoesNotKillForeignBatch() async throws {
        let model = VideoScanModel()
        let (root, rec) = try makeTempClip(tag: "cancel")
        defer { try? FileManager.default.removeItem(atPath: root) }
        model.records = [rec]

        let orch = CaptionOrchestrator(runnerFactory: { StubDossierRunner(modelID: "stub-vlm-wait-cancel") })
        // Simulate a FOREIGN volume batch owning the orchestrator.
        let foreignStatus = CaptionJobStatus.running(progress: 0.2, currentFile: "foreign.mov", etaSec: nil)
        orch.currentStatus = foreignStatus
        orch.currentVolumePrefix = "/Volumes/Foreign/"

        let job = AnalyzeJob(record: rec, model: model, orchestrator: orch)
        job.start()
        // Let the job enter its wait loop (a few poll ticks).
        try? await Task.sleep(for: .milliseconds(300))
        #expect(job.state == .running, "job should be waiting, not terminal")

        job.cancel()
        #expect(await awaitTerminal(job), "cancelled waiting job must reach a terminal state")
        #expect(job.state == .cancelled)
        #expect(orch.currentStatus == foreignStatus,
                "cancelling a WAITING job must not cancel the foreign batch")
        orch.currentStatus = .idle
        orch.currentVolumePrefix = nil
    }

    @Test("F3 scope: a job that OWNS the single-file batch may still cancel it")
    func cancelOwnBatchStillCancelsOrchestrator() async throws {
        let model = VideoScanModel()
        let (root, rec) = try makeTempClip(tag: "own")
        defer { try? FileManager.default.removeItem(atPath: root) }
        model.records = [rec]

        let orch = CaptionOrchestrator(runnerFactory: { StubDossierRunner(modelID: "stub-vlm-own-cancel") })
        // Simulate THIS job's single-file batch holding the orchestrator
        // between lanes (model load): currentVolumePrefix is the
        // record's exact fullPath — startAnalyzing's single-file key.
        orch.currentStatus = .running(progress: 0.0, currentFile: "(loading model…)", etaSec: nil)
        orch.currentVolumePrefix = rec.fullPath

        let job = AnalyzeJob(record: rec, model: model, orchestrator: orch)
        job.start()
        try? await Task.sleep(for: .milliseconds(100))
        job.cancel()
        #expect(await awaitTerminal(job))
        #expect(orch.currentStatus == .cancelling,
                "a job cancelling its OWN batch must still cancel the orchestrator")
        orch.currentStatus = .idle
        orch.currentVolumePrefix = nil
    }

    @Test("F5: a waiting job does not hammer startAnalyzing while the orchestrator is busy")
    func waitingJobDoesNotHammerBusyOrchestrator() async throws {
        let model = VideoScanModel()
        let (root, rec) = try makeTempClip(tag: "quiet")
        defer { try? FileManager.default.removeItem(atPath: root) }
        model.records = [rec]

        let stub = StubDossierRunner(modelID: "stub-vlm-wait-quiet")
        let orch = CaptionOrchestrator(runnerFactory: { stub })
        orch.currentStatus = .running(progress: 0.3, currentFile: "foreign.mov", etaSec: nil)
        orch.currentVolumePrefix = "/Volumes/Foreign/"

        let job = AnalyzeJob(record: rec, model: model, orchestrator: orch)
        job.start()
        // ~4 poll ticks worth of busy time. The old loop would have
        // attempted (and logged a refusal for) each tick.
        try? await Task.sleep(for: .milliseconds(1300))
        #expect(orch.startAnalyzingAttempts == 0,
                "while busy, the wait loop must poll a plain bool — zero startAnalyzing attempts, zero refusal log lines")

        // Free the orchestrator: the job takes its turn and completes.
        orch.currentStatus = .idle
        orch.currentVolumePrefix = nil
        #expect(await awaitTerminal(job), "job must run once the orchestrator frees up")
        #expect(orch.startAnalyzingAttempts >= 1)
        if case .failed(let msg) = job.state {
            Issue.record("job unexpectedly failed: \(msg)")
        }
        #expect(await stub.pathsCalled() == [rec.fullPath])
    }
}
