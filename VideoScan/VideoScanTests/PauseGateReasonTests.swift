import Testing
import Foundation
import os
@testable import VideoScan

// MARK: - PauseGate pause reasons (night QA 2026-09-25, M2)
//
// Before the fix PauseGate had ONE `_isPaused` Bool with three owners: the
// user (Pause / Resume buttons), the memory auto-pause loop, and
// VolumeKeepalive. Any owner's resume() cleared the others' pauses:
//   - memory relief undid a Pause All pressed while Combine was auto-paused
//     (Combine kept running under a "Resume All" button);
//   - a network share coming back undid the user's Pause on that scan row;
//   - a user Resume undid an active memory pause.
// The gate now holds a set of reasons; each owner adds and removes only its
// own, and the gate is paused while the set is non-empty.
//
// Every wait is bounded by a deadline that FAILS instead of hanging.

@Suite struct PauseGateManualPauseSurvivesPressureReliefTests {
    @Test("a manual Pause pressed while AUTO-paused stays paused when memory recovers", .timeLimit(.minutes(1)))
    func manualPauseDuringAutoPause_survivesPressureRelief() async {
        let high = OSAllocatedUnfairLock(initialState: true)
        let gate = PauseGate(pressureCheck: { high.withLock { $0 } },
                             recheckInterval: .milliseconds(20), autoPause: true)
        let waiter = Task { await gate.waitIfPaused() }
        // Let the waiter auto-pause.
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await gate.isPaused), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await gate.isPaused, "precondition: the gate auto-paused")
        await gate.pause()                       // the user presses Pause All
        high.withLock { $0 = false }             // memory recovers
        try? await Task.sleep(for: .milliseconds(300))
        #expect(await gate.isPaused, "memory relief must not undo the user's Pause (Combine kept running under a 'Resume All' button)")
        await gate.resume()                      // cleanup
        _ = await waiter.value
    }
}

@Suite struct PauseGateUserResumeKeepsMemoryPauseTests {
    @Test("a user Resume does NOT override an active memory pause; relief then releases the waiter", .timeLimit(.minutes(1)))
    func userResume_doesNotOverrideMemoryPause() async {
        let high = OSAllocatedUnfairLock(initialState: true)
        let gate = PauseGate(pressureCheck: { high.withLock { $0 } },
                             recheckInterval: .milliseconds(20), autoPause: true)
        let returned = OSAllocatedUnfairLock(initialState: false)
        let waiter = Task {
            await gate.waitIfPaused()
            returned.withLock { $0 = true }
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await gate.isPaused), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await gate.isPaused, "precondition: the gate auto-paused")
        await gate.resume()                      // the user presses Resume while memory is still low
        try? await Task.sleep(for: .milliseconds(200))
        #expect(await gate.isPaused, "memory is still low: the gate must stay paused")
        #expect(!returned.withLock { $0 }, "the waiter must stay parked while memory is low")

        high.withLock { $0 = false }             // memory recovers
        let upBy = ContinuousClock.now + .seconds(3)
        while !returned.withLock({ $0 }), ContinuousClock.now < upBy {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(returned.withLock { $0 }, "pressure relief releases the waiter")
        #expect(await gate.isPaused == false)
        waiter.cancel()
        _ = await waiter.value
    }
}

@Suite struct KeepaliveRecoveryKeepsUserPauseTests {
    @Test("a user Pause survives a volume outage + recovery", .timeLimit(.minutes(1)))
    func userPause_survivesVolumeRecovery() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keepalive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let gate = PauseGate(autoPause: false)
        let ka = VolumeKeepalive(volumePath: dir.path, pollInterval: 0.05,
                                 recoveryPollInterval: 0.05, log: { _ in })
        await ka.start(pauseGate: gate)                 // dir missing → "volume down" → pause
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await ka.volumeIsDown), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await ka.volumeIsDown, "precondition: the outage was seen")
        await gate.pause()                              // the user presses Pause on the row
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let upBy = ContinuousClock.now + .seconds(3)
        while await ka.volumeIsDown, ContinuousClock.now < upBy {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await gate.isPaused, "the volume coming back must not undo the user's Pause")
        await ka.stop()
        await gate.resume()
    }

    /// Sensor for the reason model's Stop path: a scan stopped DURING an
    /// outage has its probe children cancelled and resume() called — which
    /// now removes only the user reason. The cancelled waiter must still
    /// return, and stopping the keepalive must not leave a stale volume
    /// reason behind to park the next scan on this target forever.
    @Test("Stop during an outage: the cancelled waiter returns and keepalive.stop() releases its volume pause", .timeLimit(.minutes(1)))
    func stopDuringOutage_releasesWaiterAndVolumeReason() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("keepalive-gone-\(UUID().uuidString)", isDirectory: true)
        let gate = PauseGate(autoPause: false)
        let ka = VolumeKeepalive(volumePath: missing.path, pollInterval: 0.05,
                                 recoveryPollInterval: 0.05, log: { _ in })
        await ka.start(pauseGate: gate)
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await gate.isPaused), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await gate.isPaused, "precondition: the outage paused the gate")

        let returned = OSAllocatedUnfairLock(initialState: false)
        let probe = Task {
            await gate.waitIfPaused()
            returned.withLock { $0 = true }
        }
        try? await Task.sleep(for: .milliseconds(100))   // let it park
        probe.cancel()                                    // Stop: children cancelled…
        await gate.resume()                               // …and the Stop path's resume()
        let by = ContinuousClock.now + .seconds(2)
        while !returned.withLock({ $0 }), ContinuousClock.now < by {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(returned.withLock { $0 }, "a stopped scan must not stay parked on a volume outage")

        await ka.stop()                                   // the scan's finalize stops the keepalive
        let clearBy = ContinuousClock.now + .seconds(2)
        while await gate.isPaused, ContinuousClock.now < clearBy {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await gate.isPaused == false, "a stopped keepalive must not leave the gate volume-paused")
        _ = await probe.value
    }
}
