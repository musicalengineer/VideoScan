import Foundation

/// Cooperative concurrency limiter for structured concurrency.
/// Controls the maximum number of concurrent tasks in a task group.
actor AsyncSemaphore {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let limit: Int
    private var count: Int
    private var waiters: [Waiter] = []

    /// Rick 2026-06-14: discovered a Combine job that sat in "queued"
    /// indefinitely because perfSettings.combineConcurrency had been
    /// stored as 0 in UserDefaults (corrupt prefs from an old build,
    /// or a manual `defaults write`). AsyncSemaphore(limit: 0) starts
    /// with count=0 and no signal source — every wait() blocks forever.
    ///
    /// Treat ≤0 as a programmer error and clamp to 1. A single-permit
    /// semaphore is still slow but progresses; a zero-permit one is
    /// indistinguishable from a deadlock. Never deadlock silently.
    init(limit: Int) {
        let safeLimit = max(1, limit)
        self.limit = safeLimit
        self.count = safeLimit
    }

    func wait() async throws {
        if Task.isCancelled { throw CancellationError() }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(id: id, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func enqueue(id: UUID, continuation: CheckedContinuation<Void, Error>) {
        // `count` here is an Int counter, not a collection — empty_count rule is a false positive.
        // swiftlint:disable:next empty_count
        if count > 0 {
            count -= 1
            continuation.resume()
        } else {
            waiters.append(Waiter(id: id, continuation: continuation))
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let idx = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: idx)
        waiter.continuation.resume(throwing: CancellationError())
    }

    func signal() {
        if waiters.isEmpty {
            count = min(count + 1, limit)
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    /// Acquire a permit, run the body, then release — guarantees signal
    /// even on cancellation OR if the body throws. The defer is the
    /// contract. Body is throwing so callers don't have to wrap work in
    /// do/catch + Result just to release the permit on error.
    func withPermit<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await wait()
        defer { signal() }
        return try await body()
    }
}
