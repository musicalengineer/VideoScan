import Testing
import Foundation
@testable import VideoScan

// MARK: - Pause→Quit→Restart→Restore round-trip
//
// Bug history (Rick reported 2026-06-03):
//
//   "When I restarted the app, the searches that were in progress which I
//    paused to quit & restart the app, did not resume."
//
// Root cause traced to PersonFinderModel+JobLifecycle.makeJob — the restore-
// side constructor hard-codes `job.status = .done` regardless of what state
// the job was in when its descriptor was persisted. The PersistedJobDescriptor
// struct has no `status` field, so paused-state information is lost the
// moment the user pauses-and-quits.
//
// This was NOT a regression introduced by 2026-06-02/03's work — it's been
// the contract since the original "persist completed searches across app
// launches" feature in commit ff832eb (May 18). The feature was designed for
// completed searches only; pause-resume-across-restart was never wired up.
//
// The reason it wasn't caught: there was no test covering the full
// pause→persist→restore round-trip. PersonFinderLifecycleTests covers pause
// and resume but NOT through the persist-restore cycle. JunkDeletionTests
// covers persist shape but NOT how restore interprets it.
//
// This file fills that gap. The first test below is a red→green→red
// regression sensor for the user-visible contract: a job paused before quit
// MUST come back as `.paused` (not `.done`) on restore. The second pins down
// that progress reflects actual completion, not 1.0.

@MainActor
struct SessionRestorePauseStateTests {

    /// Build an isolated tmp store. ScanJobsStorage.storeDir under tests
    /// already redirects to a per-process tmp dir, so this just clears it.
    private static func cleanStore() throws -> URL {
        let dir = ScanJobsStorage.storeDir
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Wait up to `timeoutMs` for the detached descriptor-save Task to settle.
    /// pauseJob calls persistDescriptor which dispatches via Task.detached, so
    /// the JSON isn't on disk by the time pauseJob() returns — the test has
    /// to wait for the storage to settle.
    private static func waitForDescriptor(count: Int, timeoutMs: Int = 1000) async throws {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            if ScanJobsStorage.listAll().count == count { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func pausedJobRestoresAsPausedNotDone() async throws {
        _ = try Self.cleanStore()

        // Build a model, add a job, simulate it being in mid-scan, then pause it.
        let model = PersonFinderModel()
        let job = ScanJob(searchPath: "/tmp/persist-restore-test-paused")
        job.videosTotal = 100
        job.videosScanned = 50
        job.status = .scanning   // pauseJob requires .scanning to transition
        model.jobs.append(job)

        model.pauseJob(job)
        #expect(job.status == .paused, "Sanity: pauseJob must transition status to .paused")

        // Wait for the detached descriptor save to settle.
        try await Self.waitForDescriptor(count: 1)
        #expect(ScanJobsStorage.listAll().count == 1, "Pause must persist the descriptor")

        // Simulate app restart: fresh model, explicit restore.
        let restoredModel = PersonFinderModel()
        restoredModel.restoreSessionFromDisk()
        #expect(restoredModel.jobs.count == 1, "Restored model should see 1 persisted job")

        // THE USER CONTRACT: paused → paused. Currently fails because
        // makeJob hard-codes status = .done.
        let restoredJob = restoredModel.jobs[0]
        // A job paused before quit MUST restore as .paused. Without this
        // the user has no Resume affordance after relaunch and must re-
        // trigger the scan from scratch (cache lookup will skip already-
        // done files, but that's the wrong UX — Resume should just work).
        let label = restoredJob.status.label
        #expect(restoredJob.status == .paused, "Paused job restored as \(label), not .paused")
    }

    @Test func pausedJobRestoresWithActualProgressNotFullyComplete() async throws {
        _ = try Self.cleanStore()

        let model = PersonFinderModel()
        let job = ScanJob(searchPath: "/tmp/persist-restore-test-progress")
        job.videosTotal = 200
        job.videosScanned = 80
        job.status = .scanning
        model.jobs.append(job)

        model.pauseJob(job)
        try await Self.waitForDescriptor(count: 1)

        let restoredModel = PersonFinderModel()
        restoredModel.restoreSessionFromDisk()
        let restoredJob = restoredModel.jobs[0]

        // Currently fails because makeJob sets progress = 1.0 unconditionally.
        // Paused jobs should reflect actual completion ratio so the row in
        // the UI shows e.g. "40% paused" not "100% done".
        // A 100% reading for an incomplete scan is misleading and removes
        // the user's signal that there is more work to do.
        let expected = 80.0 / 200.0
        let got = restoredJob.progress
        #expect(abs(got - expected) < 0.01, "Paused progress should be \(expected), got \(got)")
    }

    @Test func resumeFromDiskPausedJobInvokesStartJobPath() async throws {
        _ = try Self.cleanStore()

        // Persist a paused-state descriptor for a volume that won't be
        // mounted during the test — startJob's first guard inside its
        // restored-from-disk branch is the reachability check, so we get
        // a deterministic "fell through into startJob" signal: status
        // transitions to .failed with an "offline" message instead of
        // staying at .paused.
        let descriptor = PersistedJobDescriptor(
            id: UUID(),
            personName: "TestPerson",
            profileFolderName: nil,
            searchPath: "/Volumes/_DefinitelyNotMounted_VS_RestoreResumeTest",
            engine: "vision",
            threshold: 0.5,
            referencePath: "",
            referenceFilenames: [],
            completedAt: Date(),
            videosScanned: 50,
            videosTotal: 100,
            videosWithHits: 0,
            clipsFound: 0,
            presenceSecs: 0,
            elapsedSecs: 0,
            statusRaw: "paused"
        )
        try ScanJobsStorage.save(descriptor)

        let model = PersonFinderModel()
        model.restoreSessionFromDisk()
        #expect(model.jobs.count == 1)
        let job = model.jobs[0]

        // Sanity: precondition. The earlier test already covers these but
        // we re-assert here so a failure in this test pinpoints the
        // resumeJob branch, not the makeJob branch.
        #expect(job.status == .paused, "Precondition: restored job must be .paused")
        #expect(job.wasRestoredFromDisk, "Precondition: restored job must carry the flag")

        // The user clicks Resume on a from-disk paused job. The contract
        // we're pinning down: resumeJob must route to startJob (NOT the
        // pauseGate.resume() path, which would be a no-op since the
        // scanTask was nil'd at app exit).
        model.resumeJob(job)

        // Three observable effects prove the startJob branch ran:
        //  1. wasRestoredFromDisk reset to false (so a subsequent
        //     in-process pause/resume uses the gate path).
        //  2. status is NOT still .paused — startJob always transitions
        //     to either .scanning (volume reachable) or .failed (not).
        //  3. The specific .failed message contains "offline" — proves
        //     execution reached startJob's reachability guard, not just
        //     some other transition.
        #expect(!job.wasRestoredFromDisk, "Flag must reset after resume")
        if case .failed(let msg) = job.status {
            #expect(msg.contains("offline"), "Expected offline failure msg, got: \(msg)")
        } else {
            Issue.record("Expected startJob's reachability guard to fire; got status=\(job.status.label) — likely means resumeJob fell into the wrong branch")
        }
    }

    @Test func completedJobStillRestoresAsDone() async throws {
        _ = try Self.cleanStore()

        // Negative control: a job that genuinely completed must still restore
        // as .done after the fix, not get accidentally promoted to .paused.
        let descriptor = PersistedJobDescriptor(
            id: UUID(),
            personName: "TestPerson",
            profileFolderName: nil,
            searchPath: "/tmp/persist-restore-test-done",
            engine: "vision",
            threshold: 0.5,
            referencePath: "/tmp/refs",
            referenceFilenames: [],
            completedAt: Date(),
            videosScanned: 100,
            videosTotal: 100,
            videosWithHits: 7,
            clipsFound: 14,
            presenceSecs: 42,
            elapsedSecs: 300
        )
        try ScanJobsStorage.save(descriptor)
        #expect(ScanJobsStorage.listAll().count == 1)

        let restoredModel = PersonFinderModel()
        restoredModel.restoreSessionFromDisk()
        let restoredJob = restoredModel.jobs[0]

        // A descriptor without explicit pause-state info (the old format)
        // should keep restoring as .done — preserves the historical contract
        // for all 9 of Rick's existing persisted job records.
        #expect(restoredJob.status == .done, "Pre-fix descriptors must still restore as .done — got \(restoredJob.status.label)")
        #expect(restoredJob.progress == 1.0, "Completed jobs keep progress=1.0")
    }
}
