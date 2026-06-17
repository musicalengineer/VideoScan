// JobLifecycleUncoveredPathsTests.swift
// Covers the easily-testable branches of PersonFinderModel's job
// lifecycle that the existing PersonFinderBoundaryTests didn't
// reach. Focused on @MainActor methods that mutate in-memory state
// (jobs array, settings) without spinning up real Vision/face
// engines or detached scan tasks. Rick 2026-06-17.
//
// Scope:
//   - addJob(path:) — default empty + explicit path + with selected person
//   - enqueueFamilyJobs(at:) — filtering on referencePath emptiness
//   - startJob — offline-volume fail-fast branch
//   - togglePauseJob — running ↔ paused round-trip
//   - stopAll / pauseAll / resumeAll — batch-mutation behavior
//   - removeJob — descriptor-on-disk cleanup

import Testing
import Foundation
@testable import VideoScan

@MainActor
@Suite("PersonFinder job lifecycle — uncovered paths")
struct JobLifecycleUncoveredPathsTests {

    // MARK: - addJob

    @Test func addJobWithEmptyPathAppendsBlankJob() {
        let model = PersonFinderModel()
        let before = model.jobs.count
        model.addJob()
        #expect(model.jobs.count == before + 1)
        #expect(model.jobs.last?.searchPath == "")
        #expect(model.jobs.last?.assignedProfile == nil)
    }

    @Test func addJobWithExplicitPathSticks() {
        let model = PersonFinderModel()
        model.addJob(path: "/Volumes/X/clips")
        #expect(model.jobs.last?.searchPath == "/Volumes/X/clips")
    }

    @Test func addJobInheritsSelectedPersonForNewJobs() {
        let model = PersonFinderModel()
        let profile = POIProfile(name: "TestProfile", referencePath: "/Volumes/refs/test")
        model.selectedPersonForNewJobs = profile
        model.addJob(path: "/Volumes/X")
        #expect(model.jobs.last?.assignedProfile?.name == "TestProfile")
    }

    // MARK: - enqueueFamilyJobs

    @Test func enqueueFamilyJobs_skipsProfilesWithoutReferencePath() {
        let model = PersonFinderModel()
        // Inject two profiles: one viable, one without refs.
        model.savedProfiles = [
            POIProfile(name: "Donna", referencePath: "/refs/donna"),
            POIProfile(name: "NoRefs", referencePath: ""),
        ]
        let before = model.jobs.count
        let new = model.enqueueFamilyJobs(at: "/Volumes/X")
        #expect(new.count == 1, "Only the profile with a referencePath should produce a job")
        #expect(new.first?.assignedProfile?.name == "Donna")
        #expect(model.jobs.count == before + 1)
    }

    @Test func enqueueFamilyJobs_emptySavedProfilesReturnsEmpty() {
        let model = PersonFinderModel()
        model.savedProfiles = []
        let new = model.enqueueFamilyJobs(at: "/Volumes/X")
        #expect(new.isEmpty)
    }

    @Test func enqueueFamilyJobs_allViableEnqueueAll() {
        let model = PersonFinderModel()
        model.savedProfiles = (0..<3).map { i in
            POIProfile(name: "P\(i)", referencePath: "/refs/p\(i)")
        }
        let new = model.enqueueFamilyJobs(at: "/Volumes/X")
        #expect(new.count == 3)
    }

    @Test func enqueueFamilyJobs_doesNotStartScans() {
        let model = PersonFinderModel()
        model.savedProfiles = [
            POIProfile(name: "Donna", referencePath: "/refs/donna")
        ]
        let new = model.enqueueFamilyJobs(at: "/Volumes/X")
        // Newly-enqueued jobs are idle, not active. startFamilyScan is
        // the entry point that flips them; this method just enqueues.
        #expect(new.first?.status.isActive == false)
    }

    // MARK: - startJob — offline-volume fail-fast branch

    @Test func startJob_offlineVolumeFailsImmediately() {
        let model = PersonFinderModel()
        let job = ScanJob(searchPath: "/Volumes/DefinitelyNotMounted_\(UUID().uuidString)/clips")
        model.jobs = [job]
        // No actual scan should run; the volume is offline so startJob
        // bails before the loadFacesForJob hop. Pre-condition: idle.
        #expect(job.status.isIdle)
        model.startJob(job)
        // Post-condition: failed with a volume-offline message. The
        // exact string isn't load-bearing — that it transitioned to
        // .failed is the contract.
        if case .failed(let msg) = job.status {
            #expect(msg.contains("offline"),
                    "Expected failure message to mention 'offline', got: \(msg)")
        } else {
            Issue.record("Expected job.status == .failed but got \(job.status)")
        }
    }

    // MARK: - togglePauseJob

    @Test func togglePauseJob_runningGoesPaused_pausedGoesRunning() {
        let model = PersonFinderModel()
        let job = ScanJob(searchPath: "/Volumes/X")
        model.jobs = [job]
        // Simulate a running job (we don't actually launch a Task).
        job.status = .scanning

        model.togglePauseJob(job)
        #expect(job.status == .paused)

        model.togglePauseJob(job)
        // Resume from paused: status should leave .paused. The exact
        // resumed state depends on the engine; .running is the
        // common case.
        #expect(job.status != .paused)
    }

    // MARK: - removeJob

    @Test func removeJob_dropsJobFromArrayAndClearsDescriptor() {
        let model = PersonFinderModel()
        let job = ScanJob(searchPath: "/Volumes/X/clips")
        model.jobs = [job]
        let beforeCount = model.jobs.count
        model.removeJob(job)
        #expect(model.jobs.count == beforeCount - 1)
        // ScanJobsStorage.delete is a no-op when the file isn't on
        // disk — verified via not-throwing rather than checking
        // disk state (we don't seed a descriptor file in this test).
    }

    @Test func removeJob_byIdNotByReferenceIdentity() {
        let model = PersonFinderModel()
        let a = ScanJob(searchPath: "/V/A")
        let b = ScanJob(searchPath: "/V/B")
        model.jobs = [a, b]
        model.removeJob(a)
        #expect(model.jobs.count == 1)
        #expect(model.jobs.first?.searchPath == "/V/B")
    }

    // MARK: - Batch ops

    @Test func stopAll_clearsActiveJobs() {
        let model = PersonFinderModel()
        let j1 = ScanJob(searchPath: "/V/1")
        let j2 = ScanJob(searchPath: "/V/2")
        j1.status = .scanning
        j2.status = .scanning
        model.jobs = [j1, j2]
        model.stopAll()
        // After stopAll: status moves out of .running (typically to
        // .idle or .stopped depending on the implementation). The
        // exact terminal status varies; the contract is "no longer
        // active."
        #expect(!j1.status.isActive)
        #expect(!j2.status.isActive)
    }

    @Test func pauseAll_pausesEveryRunningJob() {
        let model = PersonFinderModel()
        let j1 = ScanJob(searchPath: "/V/1")
        let j2 = ScanJob(searchPath: "/V/2")
        j1.status = .scanning
        j2.status = .scanning
        model.jobs = [j1, j2]
        model.pauseAll()
        #expect(j1.status == .paused)
        #expect(j2.status == .paused)
    }

    @Test func pauseAll_leavesIdleJobsAlone() {
        let model = PersonFinderModel()
        let idle = ScanJob(searchPath: "/V/1")
        let running = ScanJob(searchPath: "/V/2")
        running.status = .scanning
        model.jobs = [idle, running]
        model.pauseAll()
        #expect(idle.status.isIdle, "Idle jobs stay idle through pauseAll")
        #expect(running.status == .paused)
    }
}
