// VerifyAudioJobTests.swift
// LOGIC + SENSOR + MEDIA dimensions for the batch Verify Audio MFO job
// (GH #132 P1, amended by GH #135 — verify never blocks the UI):
//
//   * Job logic via the diagnoseOverride seam (healthy / damaged /
//     failed-probe) — verdict persistence, summary wording, and the
//     "a failed probe persists NOTHING" rule.
//   * Non-blocking contract sensors: VerifyAudioRequest requires a
//     COMPUTED diagnosis (the results sheet cannot exist pre-diagnosis
//     — compile-enforced, pinned here), and the Center caches the
//     computed diagnosis for instant re-presentation.
//   * Center dedupe refusal + autoRepair chaining into RebuildAudioJob
//     (codec damage chains; unrepairable damage does not).
//   * Gate serialization — two jobs sharing a 1-slot volume gate never
//     overlap (the per-disk pacing contract, AsyncSemaphore-backed).
//   * Media matrix (one real container end-to-end): a healthy synthetic
//     mov runs the REAL diagnosis through the job and lands "All is
//     well" + cached diagnosis. (The full five-container diagnosis
//     matrix lives in VerifyAudioMediaMatrixTests.)

import Testing
import Foundation
@testable import VideoScan

// MARK: - Helpers

@MainActor
private func makeRecord(name: String, path: String? = nil) -> VideoRecord {
    let r = VideoRecord()
    r.filename = name
    r.fullPath = path ?? "/Volumes/T/\(name)"
    r.directory = (r.fullPath as NSString).deletingLastPathComponent
    r.streamTypeRaw = StreamType.videoAndAudio.rawValue
    return r
}

private func healthyDiagnosis() -> AudioVerifyDiagnosis {
    var shape = AudioVerifyShape()
    shape.audioStreams = 1
    shape.audioCodec = "pcm_s16le"
    shape.audioChannels = 2
    shape.containerDurationSeconds = 2.0
    return AudioVerifyDiagnosis(findings: [], shape: shape, balanceAnalysis: nil)
}

private func codecDamagedDiagnosis() -> AudioVerifyDiagnosis {
    var shape = AudioVerifyShape()
    shape.audioStreams = 1
    shape.audioCodec = "qdm2"
    return AudioVerifyDiagnosis(
        findings: [.unsupportedCodec(codec: "qdm2", decodable: true)],
        shape: shape, balanceAnalysis: nil)
}

private func referenceMovieDiagnosis() -> AudioVerifyDiagnosis {
    AudioVerifyDiagnosis(
        findings: [.referenceMovie(referencedPaths: ["/Avid MediaFiles/x.omf — on drive “Media250”"])],
        shape: AudioVerifyShape(), balanceAnalysis: nil)
}

// MARK: - Job logic (override seam)

@Suite("VerifyAudioJob — logic")
@MainActor
struct VerifyAudioJobLogicTests {

    @Test func healthyDiagnosisFinishesWithAllIsWellAndPersistsOk() async throws {
        let model = VideoScanModel()
        let rec = makeRecord(name: "fine.mov")
        model.records = [rec]
        let job = VerifyAudioJob(record: rec, model: model,
                                 diagnoseOverride: { _ in healthyDiagnosis() })
        job.start()
        await job.task?.value

        guard case .finished(let summary) = job.state else {
            Issue.record("expected finished, got \(job.state)")
            return
        }
        #expect(summary == "All is well — the audio track checked out.",
                "the all-clear must be visible in the job summary line (GH #135)")
        #expect(rec.audioVerifyStatus == "ok")
        #expect(rec.audioVerifyNote == "")
        #expect(rec.audioVerifyDate != nil)
        #expect(job.diagnosis != nil)
        #expect(job.finishedAt != nil, "terminal stamp freezes the row clock")
    }

    @Test func damagedDiagnosisSummaryIsThePersistedNote() async throws {
        let model = VideoScanModel()
        let rec = makeRecord(name: "pointer.mov")
        model.records = [rec]
        let job = VerifyAudioJob(record: rec, model: model,
                                 diagnoseOverride: { _ in referenceMovieDiagnosis() })
        job.start()
        await job.task?.value

        guard case .finished(let summary) = job.state else {
            Issue.record("expected finished, got \(job.state)")
            return
        }
        #expect(rec.audioVerifyStatus == "damaged")
        #expect(summary == rec.audioVerifyNote,
                "the MFO row summary carries the same verdict note the catalog persists")
        #expect(rec.audioVerifyNote.hasPrefix("Damaged audio — "),
                "damaged notes keep the standardized batch-find prefix")
    }

    @Test func verdictPersistsToReplacementRecordWithSameID() async throws {
        // regression: a rescan can replace the record class instance while
        // diagnosis is in flight. Persistence must resolve the current object
        // by UUID rather than mutate the detached request reference.
        let model = VideoScanModel()
        let original = makeRecord(name: "rescan.mov")
        model.records = [original]
        let gate = AsyncSemaphore(limit: 1)
        try await gate.wait()
        let job = VerifyAudioJob(
            record: original,
            model: model,
            diagnoseOverride: { _ in
                try await gate.wait()
                await gate.signal()
                return healthyDiagnosis()
            })
        job.start()

        try await Task.sleep(for: .milliseconds(50))
        let replacement = VideoRecord(id: original.id)
        replacement.filename = original.filename
        replacement.fullPath = original.fullPath
        replacement.directory = original.directory
        replacement.streamTypeRaw = original.streamTypeRaw
        model.records = [replacement]
        await gate.signal()
        await job.task?.value

        #expect(replacement.audioVerifyStatus == "ok")
        #expect(replacement.audioVerifyDate != nil)
        #expect(original.audioVerifyStatus.isEmpty,
                "the detached pre-rescan instance must remain untouched")
    }

    @Test func failedProbePersistsNothing() async throws {
        // "Couldn't check" is not a verdict — the GH #128 transient-I/O
        // rule must survive the sheet → job move.
        let model = VideoScanModel()
        let rec = makeRecord(name: "flaky.mov")
        model.records = [rec]
        let job = VerifyAudioJob(record: rec, model: model,
                                 diagnoseOverride: { _ in
                                     throw AudioVerifyProbeError.probeFailed("volume stopped responding")
                                 })
        job.start()
        await job.task?.value

        guard case .failed(let message) = job.state else {
            Issue.record("expected failed, got \(job.state)")
            return
        }
        #expect(message.contains("volume stopped responding"))
        #expect(rec.audioVerifyStatus == "", "a failed probe must never write a verdict")
        #expect(rec.audioVerifyNote == "")
        #expect(rec.audioVerifyDate == nil)
        #expect(job.diagnosis == nil)
    }
}

@Suite("VerifyAudio results action handoff")
@MainActor
struct VerifyAudioResultsActionHandoffTests {

    @Test func findMatchingAudioDismissesBeforeCatalogAction() {
        // regression: the Combine sheet/no-match alert must not race the
        // still-present Verification Results sheet.
        var events: [String] = []
        VerifyAudioDismissHandoff.perform(
            dismiss: { events.append("dismiss") },
            action: { events.append("act") },
            schedule: { action in
                events.append("schedule")
                action()
            })
        #expect(events == ["dismiss", "schedule", "act"])
    }

    @Test func requestCarriesFindMatchingAudioAction() {
        var invoked = false
        let request = VerifyAudioRequest(
            record: makeRecord(name: "picture-only.mov"),
            diagnosis: AudioVerifyDiagnosis(
                findings: [.noAudioStream],
                shape: AudioVerifyShape(),
                balanceAnalysis: nil),
            onFindMatchingAudio: { invoked = true })
        request.onFindMatchingAudio()
        #expect(invoked)
    }
}

// MARK: - Center: dedupe, cache, autoRepair chain

@Suite("VerifyAudioJob — center dispatch")
@MainActor
struct VerifyAudioCenterDispatchTests {

    @Test func duplicateDispatchIsRefused() async throws {
        let center = MediaFileOperationsCenter()
        let model = VideoScanModel()
        let rec = makeRecord(name: "clip.mov")
        model.records = [rec]

        // A freshly-dispatched job is `.running` before its task gets a
        // turn, so the immediate re-dispatch deterministically sees an
        // active twin.
        let first = center.startVerifyAudio(record: rec, model: model,
                                            diagnoseOverride: { _ in healthyDiagnosis() })
        #expect(first != nil)
        let second = center.startVerifyAudio(record: rec, model: model,
                                             diagnoseOverride: { _ in healthyDiagnosis() })
        #expect(second == nil, "the Center must refuse a duplicate verify for the same record")
        await first?.task?.value

        // After the first completes, a re-verify is allowed again.
        let third = center.startVerifyAudio(record: rec, model: model,
                                            diagnoseOverride: { _ in healthyDiagnosis() })
        #expect(third != nil)
        await third?.task?.value
    }

    @Test func completedDiagnosisIsCachedForInstantResults() async throws {
        // GH #135 sensor: "Verification Results…" presents the CACHED
        // diagnosis — no re-probe, no levels decode. The request type
        // enforces the no-probe half at compile time (it REQUIRES a
        // diagnosis); this pins the cache half.
        let center = MediaFileOperationsCenter()
        let model = VideoScanModel()
        let rec = makeRecord(name: "clip.mov")
        model.records = [rec]

        #expect(center.verifyDiagnosis(forRecordID: rec.id) == nil)
        let job = center.startVerifyAudio(record: rec, model: model,
                                          diagnoseOverride: { _ in healthyDiagnosis() })
        await job?.task?.value
        let cached = center.verifyDiagnosis(forRecordID: rec.id)
        #expect(cached != nil, "completed verify must park its diagnosis for instant results")
        #expect(cached?.isHealthy == true)

        // The results sheet's request is constructible ONLY with a
        // computed diagnosis — the pre-diagnosis blocking sheet is
        // unrepresentable.
        if let cached {
            let request = VerifyAudioRequest(
                record: rec,
                diagnosis: cached,
                onFindMatchingAudio: {})
            #expect(request.diagnosis.isHealthy)
        }
    }

    @Test func cacheEvictsFIFOAtCap() {
        let center = MediaFileOperationsCenter()
        var ids: [UUID] = []
        for _ in 0..<(MediaFileOperationsCenter.verifyDiagnosisCap + 1) {
            let id = UUID()
            ids.append(id)
            center.storeVerifyDiagnosis(healthyDiagnosis(), forRecordID: id)
        }
        #expect(center.verifyDiagnosis(forRecordID: ids[0]) == nil,
                "oldest entry evicted at the cap (bounded memory)")
        #expect(center.verifyDiagnosis(forRecordID: ids[1]) != nil)
        #expect(center.verifyDiagnosis(forRecordID: ids.last ?? UUID()) != nil)
    }

    @Test func autoRepairChainsRebuildForCodecDamage() async throws {
        let center = MediaFileOperationsCenter()
        let model = VideoScanModel()
        let rec = makeRecord(name: "qdm2.mov")
        model.records = [rec]

        let job = center.startVerifyAudio(record: rec, model: model,
                                          autoRepair: true,
                                          diagnoseOverride: { _ in codecDamagedDiagnosis() })
        await job?.task?.value

        let rebuilds = center.jobs.compactMap { $0 as? RebuildAudioJob }
        #expect(rebuilds.count == 1,
                "codec-damage + autoRepair must chain exactly one Rebuild Audio Track job")
        #expect(rebuilds.first?.record.id == rec.id)
        // Let the chained job settle (its source path doesn't exist, so
        // it fails fast — the chain, not the render, is under test).
        await rebuilds.first?.task?.value
    }

    @Test func autoRepairDoesNotChainForUnrepairableDamage() async throws {
        // A reference movie has no essence — nothing to rebuild.
        let center = MediaFileOperationsCenter()
        let model = VideoScanModel()
        let rec = makeRecord(name: "pointer.mov")
        model.records = [rec]

        let job = center.startVerifyAudio(record: rec, model: model,
                                          autoRepair: true,
                                          diagnoseOverride: { _ in referenceMovieDiagnosis() })
        await job?.task?.value

        #expect(center.jobs.compactMap { $0 as? RebuildAudioJob }.isEmpty,
                "reference-movie damage must not chain a rebuild — there is no essence to repair")
        #expect(rec.audioVerifyStatus == "damaged", "the verdict still persists")
    }
}

// MARK: - Gate serialization (per-disk pacing)

@Suite("VerifyAudioJob — volume gate pacing")
@MainActor
struct VerifyAudioGateTests {

    @Test func jobWaitsForTheVolumeGateAndRunsWhenReleased() async throws {
        // The HDD contract, tested deterministically: hold the volume's
        // only permit externally — the job must queue (visible in its
        // subtitle, no verdict written), then run to completion once the
        // permit is released.
        let semaphore = AsyncSemaphore(limit: 1)
        try await semaphore.wait()   // hold the only permit
        let gate = MediaVolumeGate(root: "/Volumes/SpinningRust",
                                   label: "SpinningRust",
                                   semaphore: semaphore)
        let model = VideoScanModel()
        let rec = makeRecord(name: "tape.mov",
                             path: "/Volumes/SpinningRust/tape.mov")
        model.records = [rec]
        let job = VerifyAudioJob(record: rec, model: model,
                                 gates: [gate],
                                 diagnoseOverride: { _ in healthyDiagnosis() })
        job.start()

        // Give the job's task time to reach the gate and park.
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(job.state == .running)
        #expect(job.subtitle == "Waiting for SpinningRust…",
                "queued jobs must say which volume they're waiting for")
        #expect(rec.audioVerifyStatus == "", "no verdict while queued")

        await semaphore.signal()     // release — the job may now run
        await job.task?.value
        guard case .finished = job.state else {
            Issue.record("gated job did not finish after release: \(job.state)")
            return
        }
        #expect(rec.audioVerifyStatus == "ok")
    }

    @Test func fourJobsOnAOneSlotGateAllComplete() async throws {
        // No deadlock, no starvation: everything queued behind a 1-slot
        // gate eventually runs and lands a verdict.
        let semaphore = AsyncSemaphore(limit: 1)
        let gate = MediaVolumeGate(root: "/Volumes/SpinningRust",
                                   label: "SpinningRust",
                                   semaphore: semaphore)
        let model = VideoScanModel()
        var jobs: [VerifyAudioJob] = []
        for i in 0..<4 {
            let rec = makeRecord(name: "tape\(i).mov",
                                 path: "/Volumes/SpinningRust/tape\(i).mov")
            model.records.append(rec)
            let job = VerifyAudioJob(record: rec, model: model,
                                     gates: [gate],
                                     diagnoseOverride: { _ in healthyDiagnosis() })
            jobs.append(job)
            job.start()
        }
        for job in jobs { await job.task?.value }
        for job in jobs {
            guard case .finished = job.state else {
                Issue.record("gated job did not finish: \(job.state)")
                return
            }
        }
        #expect(model.records.allSatisfy { $0.audioVerifyStatus == "ok" })
    }
}

// MARK: - Media matrix (one real end-to-end container)

@Suite("VerifyAudioJob — media", .serialized)
@MainActor
struct VerifyAudioJobMediaTests {

    @Test(.enabled(if: VerifyAudioTestMedia.toolsAvailable))
    func realHealthyMovRunsThroughTheJobEndToEnd() async throws {
        let dir = try VerifyAudioTestMedia.makeScratchDir("job")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try VerifyAudioTestMedia.generate(
            into: dir, name: "test_job_healthy.mov",
            videoCodec: "prores_ks", extraVideoArgs: ["-profile:v", "1"],
            audioCodec: "pcm_s16le")

        let center = MediaFileOperationsCenter()
        let model = VideoScanModel()
        let rec = makeRecord(name: "test_job_healthy.mov", path: path)
        model.records = [rec]

        let job = center.startVerifyAudio(record: rec, model: model)
        await job?.task?.value

        guard case .finished(let summary) = job?.state else {
            Issue.record("expected finished, got \(String(describing: job?.state))")
            return
        }
        #expect(summary == "All is well — the audio track checked out.")
        #expect(rec.audioVerifyStatus == "ok")
        #expect(center.verifyDiagnosis(forRecordID: rec.id)?.isHealthy == true)
    }
}
