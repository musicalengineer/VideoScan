import Testing
import Foundation
import os
@testable import VideoScan

// MARK: - PauseGateCancellationTests
//
// Regression net for the CI hang of 2026-09-24/25 (every CI run since
// d7724f6f timed out in CombineNeverOverwritesTests on the movProRes case).
//
// Root cause: processCombinePair's first checkpoint is
// combinePauseGate.waitIfPaused(), whose memory auto-pause consults the
// shared MemoryPressureMonitor (floor 4 GB). The GitHub macOS runner has
// ~7 GB and was at 2.2 GB free ("Memory pressure HIGH — available: 2223 MB,
// threshold: 4096 MB" is the last line the hung run logged), so the gate
// auto-paused and polled forever. Worse, the poll loop used
// `try? await Task.sleep`, which swallows cancellation: a cancelled waiter
// hot-spun instead of returning, so nothing — not Stop's cancel, not a
// Swift Testing time limit — could end it while memory stayed low.
//
// These tests inject the pressure answer (no dependence on the host's RAM,
// no poisoning of the shared monitor) and bound every wait with a deadline
// that FAILS instead of hanging.

@Suite struct PauseGateCancellationTests {

    /// Start `waitIfPaused()` in a child task and report whether it returned
    /// within `seconds`. Never hangs: the caller's cleanup (resume()) is what
    /// finally releases a waiter that did not honor cancellation.
    static func waiterReturns(on gate: PauseGate, cancelAfter delay: Duration?,
                              within seconds: Double) async -> Bool {
        let done = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            await gate.waitIfPaused()
            done.withLock { $0 = true }
        }
        if let delay {
            try? await Task.sleep(for: delay)
            task.cancel()
        }
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if done.withLock({ $0 }) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return done.withLock { $0 }
    }

    @Test("RED 2026-09-25: a waiter cancelled while AUTO-paused under sustained pressure returns promptly")
    func autoPausedWaiter_cancelled_returnsPromptly() async {
        let gate = PauseGate(pressureCheck: { true }, recheckInterval: .milliseconds(50))
        let returned = await Self.waiterReturns(on: gate, cancelAfter: .milliseconds(200), within: 3)
        #expect(returned, "a cancelled waiter must not keep polling while memory stays low (the CI hang)")
        await gate.resume()   // releases a spinning waiter if the fix regresses
    }

    @Test("an auto-paused waiter that is NOT cancelled keeps waiting while pressure stays high")
    func autoPausedWaiter_notCancelled_keepsWaiting() async {
        let gate = PauseGate(pressureCheck: { true }, recheckInterval: .milliseconds(50))
        let returned = await Self.waiterReturns(on: gate, cancelAfter: nil, within: 0.5)
        #expect(!returned, "auto-pause is a real pause: no pressure relief, no return")
        await gate.resume()
    }

    @Test("an auto-paused waiter resumes by itself when pressure clears")
    func autoPausedWaiter_resumesWhenPressureClears() async {
        let high = OSAllocatedUnfairLock(initialState: true)
        let gate = PauseGate(pressureCheck: { high.withLock { $0 } }, recheckInterval: .milliseconds(50))
        let clear = Task {
            try? await Task.sleep(for: .milliseconds(300))
            high.withLock { $0 = false }
        }
        let returned = await Self.waiterReturns(on: gate, cancelAfter: nil, within: 3)
        #expect(returned)
        #expect(await gate.isPaused == false)
        clear.cancel()
    }

    @Test("auto-pause disabled: the gate never consults pressure and never waits")
    func autoPauseDisabled_neverWaits() async {
        let consulted = OSAllocatedUnfairLock(initialState: false)
        let gate = PauseGate(pressureCheck: { consulted.withLock { $0 = true }; return true })
        await gate.setAutoPause(false)
        let returned = await Self.waiterReturns(on: gate, cancelAfter: nil, within: 1)
        #expect(returned)
        #expect(!consulted.withLock { $0 })
    }

    @Test("a MANUAL pause still waits for resume() even when cancelled (Stop paths call resume)")
    func manualPause_waitsForResume() async {
        let gate = PauseGate(pressureCheck: { false })
        await gate.pause()
        let returnedBeforeResume = await Self.waiterReturns(on: gate, cancelAfter: .milliseconds(50), within: 0.3)
        #expect(!returnedBeforeResume)
        await gate.resume()
    }

    /// Isolation sensor: the Combine model's gate must be usable with
    /// auto-pause off, so Combine tests never depend on the host's free RAM.
    @MainActor @Test("Combine's gate with auto-pause off passes straight through regardless of host memory")
    func combineGate_autoPauseOff_passesThrough() async {
        let model = VideoScanModel()
        await model.combinePauseGate.setAutoPause(false)
        let returned = await Self.waiterReturns(on: model.combinePauseGate, cancelAfter: nil, within: 1)
        #expect(returned)
    }
}
