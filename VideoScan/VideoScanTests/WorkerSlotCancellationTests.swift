import Testing
import Foundation
import os
@testable import VideoScan

// MARK: - MemoryPressureMonitor.acquireWorkerSlot honors cancellation
// (night QA 2026-09-25, M3)
//
// Before the fix a waiter parked on a plain continuation that only
// decrementWorkers() released: a Person Finder job the user Stopped sat
// until ANOTHER job's worker finished a video, then took a slot anyway.
// Each test uses a private monitor instance — no shared-state poisoning.

@Suite struct WorkerSlotCancellationTests {
    @Test("a cancelled worker-slot waiter returns promptly", .timeLimit(.minutes(1)))
    func cancelledSlotWaiter_returnsPromptly() async {
        let monitor = MemoryPressureMonitor()
        await monitor.incrementWorkers()               // another job's worker holds the only slot (requested 1)
        let returned = OSAllocatedUnfairLock(initialState: false)
        let waiter = Task {
            _ = await monitor.acquireWorkerSlot(requested: 1, engine: .vision)
            returned.withLock { $0 = true }
        }
        try? await Task.sleep(for: .milliseconds(200))  // let it park
        waiter.cancel()                                  // the user pressed Stop on this job
        let deadline = ContinuousClock.now + .seconds(2)
        while !returned.withLock({ $0 }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(returned.withLock { $0 }, "Stop must not wait for another job's worker to finish a video")
        await monitor.decrementWorkers()                 // cleanup: releases a waiter that ignored cancel
        _ = await waiter.value
    }

    @Test("a cancelled wait neither takes nor leaks a slot: the worker count stays exact", .timeLimit(.minutes(1)))
    func cancelledSlotWaiter_leavesWorkerCountCorrect() async {
        let monitor = MemoryPressureMonitor()
        await monitor.incrementWorkers()               // the holder
        let returned = OSAllocatedUnfairLock(initialState: false)
        let waiter = Task {
            _ = await monitor.acquireWorkerSlot(requested: 1, engine: .vision)
            returned.withLock { $0 = true }
        }
        try? await Task.sleep(for: .milliseconds(200))
        waiter.cancel()
        let deadline = ContinuousClock.now + .seconds(2)
        while !returned.withLock({ $0 }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(await monitor.currentWorkers() == 1, "only the holder is counted")
        await monitor.decrementWorkers()                 // the holder finishes its video
        _ = await waiter.value
        #expect(await monitor.currentWorkers() == 0,
                "the cancelled waiter must not have taken the freed slot")
    }

    @Test("acquireWorkerSlot reports whether it took a slot: true when free, false when cancelled", .timeLimit(.minutes(1)))
    func acquireWorkerSlot_returnsWhetherAcquired() async {
        let monitor = MemoryPressureMonitor()
        let got = await monitor.acquireWorkerSlot(requested: 1, engine: .vision)
        #expect(got, "a free slot is taken")
        #expect(await monitor.currentWorkers() == 1)

        // Slot full; an already-cancelled caller takes nothing and returns false.
        let cancelledResult = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await monitor.acquireWorkerSlot(requested: 1, engine: .vision)
        }.value
        #expect(cancelledResult == false)
        #expect(await monitor.currentWorkers() == 1, "a false return must not change the count")

        // A parked waiter that is NOT cancelled takes the slot when it frees.
        let waiter = Task { await monitor.acquireWorkerSlot(requested: 1, engine: .vision) }
        try? await Task.sleep(for: .milliseconds(100))
        await monitor.decrementWorkers()
        #expect(await waiter.value, "an uncancelled waiter acquires the freed slot")
        #expect(await monitor.currentWorkers() == 1)
        await monitor.decrementWorkers()
    }
    @Test("stress: 200 waiters, half cancelled, the worker count returns to exactly 0", .timeLimit(.minutes(1)))
    func slotStress() async {
        let monitor = MemoryPressureMonitor()
        await monitor.incrementWorkers()
        let tasks: [Task<Bool, Never>] = (0..<200).map { _ in
            Task {
                let got = await monitor.acquireWorkerSlot(requested: 1, engine: .vision)
                if got { await monitor.decrementWorkers() }   // finish "the video", free the slot
                return got
            }
        }
        try? await Task.sleep(for: .milliseconds(100))
        for (i, t) in tasks.enumerated() where i % 2 == 0 { t.cancel() }
        await monitor.decrementWorkers()
        var acquired = 0
        for t in tasks {
            if await t.value { acquired += 1 }
        }
        #expect(await monitor.currentWorkers() == 0)
        #expect(acquired <= 100)
    }
}
