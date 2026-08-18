import Foundation
import os

// MARK: - Probe task-group bounding helpers (GH #163)
//
// Support types for the bounded-live-children probe groups in
// VideoScanModel+ProbeEngine. Both are tiny lock-guarded counters — a
// `std::atomic<int>` with a mutex, in C++ terms — because the probe
// children run on the cooperative pool while the loop that reads them is
// main-actor-isolated.

/// Counts probe children that have FINISHED (returned their outcome) but
/// may not yet have been drained by `TaskGroup.next()`. The main-actor
/// enqueue loop compares this against its own drained count to know
/// whether a `next()` would return immediately (an outcome is ready) or
/// block on an unfinished probe — it only ever calls next() in the first
/// case while the walk is still going, so the walk never waits on ffprobe.
final class ProbeChildCompletionCounter: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: 0)

    /// Called by the child on every exit path (defer).
    func signal() {
        lock.withLock { $0 += 1 }
    }

    /// Total children finished so far.
    var value: Int {
        lock.withLock { $0 }
    }
}

/// Test seam: observes the live-children count of a probe group after
/// every enqueue and every drain, remembering the maximum. Installed on
/// `VideoScanModel.probeGroupLiveChildrenGauge` by the GH #163 scale test;
/// nil in production.
final class ProbeGroupLiveChildrenGauge: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: (current: 0, max: 0, observations: 0))

    func observe(_ live: Int) {
        lock.withLock { s in
            s.current = live
            if live > s.max { s.max = live }
            s.observations += 1
        }
    }

    var current: Int { lock.withLock { $0.current } }
    var maxLive: Int { lock.withLock { $0.max } }
    var observations: Int { lock.withLock { $0.observations } }
}
