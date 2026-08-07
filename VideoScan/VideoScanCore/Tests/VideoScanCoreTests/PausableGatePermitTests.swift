import Testing
import Foundation
@testable import VideoScanCore

// PausableGatePermit — the count-discipline seam (2026-08-07 compare-
// starvation incident). The invariant under test: the shared semaphore
// sees EXACTLY one signal per successful wait across any interleaving
// of pause / resume / close. codex extends with the adversarial matrix.
struct PausableGatePermitTests {

    @Test func pauseLendsTheSlotAndResumeTakesItBack() async throws {
        let semaphore = AsyncSemaphore(limit: 1)
        let permit = PausableGatePermit(semaphore: semaphore)
        try await permit.acquire()
        #expect(await permit.currentPhase == .held)

        // A second job queues behind the held slot…
        let waiter = PausableGatePermit(semaphore: semaphore)
        let waiterTask = Task { try await waiter.acquire() }

        // …pause steps aside: the waiter gets through.
        await permit.releaseForPause()
        try await waiterTask.value
        #expect(await waiter.currentPhase == .held)
        #expect(await permit.currentPhase == .pausedReleased)

        // Resume re-queues; it completes once the waiter closes.
        let reacquire = Task { try await permit.reacquireForResume() }
        await waiter.close()
        try await reacquire.value
        #expect(await permit.currentPhase == .held)
        await permit.close()
        #expect(await permit.currentPhase == .closed)
    }

    @Test func closeWhilePausedReleasedOwesNothing() async throws {
        // The double-credit trap: pause already returned the slot; a
        // close (cancel-while-paused unwind) must NOT signal again —
        // limit-1 semaphore still admits exactly one holder after.
        let semaphore = AsyncSemaphore(limit: 1)
        let permit = PausableGatePermit(semaphore: semaphore)
        try await permit.acquire()
        await permit.releaseForPause()
        await permit.close()                       // must not signal

        let a = PausableGatePermit(semaphore: semaphore)
        try await a.acquire()                      // takes the one slot
        let b = PausableGatePermit(semaphore: semaphore)
        let bTask = Task { try await b.acquire() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await b.currentPhase == .acquiring,
                "a second holder got in — the gate was double-credited")
        await a.close()
        try await bTask.value
        await b.close()
    }

    @Test func closeUnacquiredOwesNothingAndIsIdempotent() async throws {
        let semaphore = AsyncSemaphore(limit: 1)
        let permit = PausableGatePermit(semaphore: semaphore)
        await permit.close()
        await permit.close()
        #expect(await permit.currentPhase == .closed)
        // Slot count intact: an acquire still succeeds immediately.
        let a = PausableGatePermit(semaphore: semaphore)
        try await a.acquire()
        await a.close()
    }

    // MARK: Actor-reentrancy races (codex #289/#292 RED sensors)

    @Test func closeDuringBlockedReacquireStaysClosedAndStealsNoSlot() async throws {
        // The resurrection race: reacquire suspends in wait(); close()
        // marks the permit closed; the LATE wait completion must NOT
        // flip the phase back to held — and the slot it was granted
        // must go back to the semaphore (a closed permit owns nothing).
        let semaphore = AsyncSemaphore(limit: 1)
        let permit = PausableGatePermit(semaphore: semaphore)
        try await permit.acquire()
        await permit.releaseForPause()

        let blocker = PausableGatePermit(semaphore: semaphore)
        try await blocker.acquire()                    // takes the lone slot
        let reacquire = Task { try? await permit.reacquireForResume() }
        try? await Task.sleep(nanoseconds: 50_000_000) // reacquire now blocked

        await permit.close()                           // terminal — must stay so
        await blocker.close()                          // frees the slot; late wait fires
        _ = await reacquire.value
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(await permit.currentPhase == .closed,
                "late wait completion resurrected a closed permit")
        // Slot conservation: the lone slot must be immediately takeable.
        let prober = PausableGatePermit(semaphore: semaphore)
        let probe = Task { try await prober.acquire() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(await prober.currentPhase == .held,
                "closed permit kept the slot its late wait was granted")
        probe.cancel()
        await prober.close()
    }

    @Test func concurrentBlockedReacquiresConsumeAtMostOneSlot() async throws {
        // Both callers pass the .pausedReleased guard before either's
        // wait() suspends (the actor suspension point IS the reentrancy
        // window) — without a .reacquiring phase BOTH join the wait
        // queue, and the second admission lands after close(),
        // consuming a phantom slot and resurrecting the permit.
        let semaphore = AsyncSemaphore(limit: 1)
        let permit = PausableGatePermit(semaphore: semaphore)
        try await permit.acquire()
        await permit.releaseForPause()

        let blocker = PausableGatePermit(semaphore: semaphore)
        try await blocker.acquire()                    // both resumes must BLOCK
        let resumeA = Task { try? await permit.reacquireForResume() }
        let resumeB = Task { try? await permit.reacquireForResume() }
        try? await Task.sleep(nanoseconds: 50_000_000)

        await blocker.close()                          // admits exactly one waiter
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await permit.currentPhase == .held)

        await permit.close()                           // frees the held slot
        _ = await resumeA.value
        _ = await resumeB.value
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await permit.currentPhase == .closed,
                "second queued reacquire resurrected the closed permit")

        // Slot conservation: the lone slot must be free again.
        let prober = PausableGatePermit(semaphore: semaphore)
        let probe = Task { try? await prober.acquire() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(await prober.currentPhase == .held,
                "phantom second wait still holds the slot")
        probe.cancel()
        await prober.close()
    }

    @Test func doublePauseAndDoubleResumeAreNoOps() async throws {
        let semaphore = AsyncSemaphore(limit: 1)
        let permit = PausableGatePermit(semaphore: semaphore)
        try await permit.acquire()
        await permit.releaseForPause()
        await permit.releaseForPause()             // no second signal
        try await permit.reacquireForResume()
        try await permit.reacquireForResume()      // no second wait
        #expect(await permit.currentPhase == .held)
        await permit.close()

        // Balanced: exactly one slot free at the end.
        let a = PausableGatePermit(semaphore: semaphore)
        try await a.acquire()
        let b = PausableGatePermit(semaphore: semaphore)
        let bTask = Task { try await b.acquire() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await b.currentPhase == .acquiring)   // blocked, not admitted
        await a.close()
        try await bTask.value
        await b.close()
    }
}
