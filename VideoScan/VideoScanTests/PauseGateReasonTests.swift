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

// MARK: - Volume-reason ownership across keepalives (adversarial QA on 2f6bce1c)
//
// Stop → Start on the same scan target before scan #1 drains leaves two
// keepalives on ONE target gate. With a plain reason set, scan #1's late
// exit-time resume(.volume) opened a gate scan #2's keepalive still held
// while the volume was still down. Each keepalive now holds the volume
// reason under its own owner id; the reason stays while any owner remains.

private func waitUntil(_ seconds: Double = 2, _ cond: @escaping () async -> Bool) async -> Bool {
    let by = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
    while ContinuousClock.now < by {
        if await cond() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await cond()
}

@Suite struct KeepaliveVolumeReasonOwnershipTests {
    @Test("an OLD keepalive stopping late must not release a NEWER keepalive's volume pause", .timeLimit(.minutes(1)))
    func oldKeepaliveExit_doesNotOpenGateHeldByNewKeepalive() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("ka-owner-gone-\(UUID().uuidString)", isDirectory: true)
        let gate = PauseGate(autoPause: false)
        // Scan #1 on this target (network root down).
        let old = VolumeKeepalive(volumePath: missing.path, pollInterval: 0.05,
                                  recoveryPollInterval: 0.05, log: { _ in })
        await old.start(pauseGate: gate)
        #expect(await waitUntil { await gate.isPaused }, "precondition: outage paused the gate")
        // Stop, then Start again before scan #1's task finished draining:
        // scan #2 starts its own keepalive on the SAME target gate.
        let new = VolumeKeepalive(volumePath: missing.path, pollInterval: 0.05,
                                  recoveryPollInterval: 0.05, log: { _ in })
        await new.start(pauseGate: gate)
        #expect(await waitUntil { await new.volumeIsDown })
        try? await Task.sleep(for: .milliseconds(100))   // new has now paused the gate
        // Scan #1's scanTask finally reaches `await ka.stop()`.
        await old.stop()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(await gate.isPaused,
                "volume is STILL down and scan #2's keepalive holds the pause — the gate must stay closed")
        await new.stop()
        #expect(await waitUntil { !(await gate.isPaused) }, "once the last owner stops, the gate opens")
    }

    @Test("two volume owners: the reason stays until BOTH release; anonymous release does not free an owned hold")
    func volumeReason_isHeldPerOwner() async {
        let gate = PauseGate(autoPause: false)
        let a = UUID(), b = UUID()
        await gate.pause(.volume, owner: a)
        await gate.pause(.volume, owner: b)
        await gate.resume(.volume, owner: a)
        #expect(await gate.isPaused, "b still holds the volume reason")
        await gate.resume(.volume)                      // no owner: not b's hold
        #expect(await gate.isPaused)
        await gate.resume(.volume, owner: b)
        #expect(await gate.isPaused == false)
        #expect(await gate.pauseReasons.isEmpty)
    }
}

// MARK: - Gate edge probes (adversarial QA on 2f6bce1c; green by design)

@Suite struct PauseGateEdgeProbeTests {
    @Test("{user, memory}: a cancelled waiter returns after Stop's resume() even though memory is still high", .timeLimit(.minutes(1)))
    func stopDuringUserPlusMemory() async {
        let gate = PauseGate(pressureCheck: { true }, recheckInterval: .milliseconds(20), autoPause: true)
        let done = OSAllocatedUnfairLock(initialState: false)
        let t = Task { await gate.waitIfPaused(); done.withLock { $0 = true } }
        #expect(await waitUntil { await gate.pauseReasons.contains(.memory) })
        await gate.pause()
        try? await Task.sleep(for: .milliseconds(60))
        t.cancel()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!done.withLock { $0 }, "user pause holds a cancelled waiter until resume()")
        await gate.resume()
        #expect(await waitUntil { done.withLock { $0 } })
        #expect(await gate.pauseReasons == [.memory], "memory reason remains (self-heals on the next waiter's poll)")
    }

    @Test("stress: 300 waiters, random cancels, interleaved reasons — all finish, no hang", .timeLimit(.minutes(1)))
    func stress() async {
        let gate = PauseGate(autoPause: false)
        await gate.pause(); await gate.pause(.volume)
        let finished = OSAllocatedUnfairLock(initialState: 0)
        var tasks: [Task<Void, Never>] = []
        for _ in 0..<300 {
            tasks.append(Task { await gate.waitIfPaused(); finished.withLock { $0 += 1 } })
        }
        for (i, t) in tasks.enumerated() where i % 3 == 0 { t.cancel() }
        for i in 0..<50 {
            if i % 2 == 0 { await gate.resume(.volume) } else { await gate.pause(.volume) }
            await Task.yield()
        }
        await gate.resume(.volume); await gate.resume()
        #expect(await waitUntil(5) { finished.withLock { $0 } == 300 })
    }
}
