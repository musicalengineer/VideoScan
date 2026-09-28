import Testing
import Foundation
import os
@testable import VideoScan

// MARK: - Stopping a PAUSED Person Finder job releases its workers (GH #191)
//
// stopJob (also reached by Stop All and delete-person) and removeJob
// cancelled the scan task but never resumed the job's gate. A user-paused
// worker parked at a checkpoint — while HOLDING a MemoryPressureMonitor
// worker slot — stayed parked: the slot leaked (activeWorkers never came
// back down) and runScan never returned. A user pause holds even a
// cancelled waiter by design; the Stop path must resume() to release it.

@MainActor
@Suite struct PersonFinderStopWhilePausedTests {
    private func parkedWorker(on job: ScanJob) async -> OSAllocatedUnfairLock<Bool> {
        let gate = job.pauseGate
        await gate.pause()                       // what pauseJob's Task does
        job.status = .paused
        let returned = OSAllocatedUnfairLock(initialState: false)
        job.scanTask = Task.detached {
            // A worker parked at the mid-video checkpoint
            // (PersonFinderDetection.swift:647), holding a worker slot.
            await gate.waitIfPaused()
            returned.withLock { $0 = true }
        }
        try? await Task.sleep(for: .milliseconds(100))
        return returned
    }

    private func returnsWithin(_ seconds: Double, _ flag: OSAllocatedUnfairLock<Bool>) async -> Bool {
        let by = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while !flag.withLock({ $0 }), ContinuousClock.now < by {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return flag.withLock { $0 }
    }

    @Test("Stop on a user-paused job ends its parked workers", .timeLimit(.minutes(1)))
    func stopWhilePaused_releasesParkedWorkers() async {
        let model = PersonFinderModel()
        let job = ScanJob(searchPath: "/tmp")
        model.jobs.append(job)
        let returned = await parkedWorker(on: job)
        model.stopJob(job)
        #expect(await returnsWithin(2, returned), "Stop on a paused PF job must release its parked workers (and their worker slots)")
        await job.pauseGate.resume()             // cleanup so the test never hangs
    }

    @Test("Stop All on a user-paused job ends its parked workers", .timeLimit(.minutes(1)))
    func stopAllWhilePaused_releasesParkedWorkers() async {
        let model = PersonFinderModel()
        let job = ScanJob(searchPath: "/tmp")
        model.jobs.append(job)
        let returned = await parkedWorker(on: job)
        model.stopAll()
        #expect(await returnsWithin(2, returned))
        await job.pauseGate.resume()
    }

    @Test("Removing a user-paused job ends its parked workers", .timeLimit(.minutes(1)))
    func removeWhilePaused_releasesParkedWorkers() async {
        let model = PersonFinderModel()
        let job = ScanJob(searchPath: "/tmp")
        model.jobs.append(job)
        let returned = await parkedWorker(on: job)
        model.removeJob(job)
        #expect(await returnsWithin(2, returned), "removeJob cancels the same way Stop does and must release the gate too")
        await job.pauseGate.resume()
    }
}
