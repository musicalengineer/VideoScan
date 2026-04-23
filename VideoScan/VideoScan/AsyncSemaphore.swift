import Foundation

/// Cooperative concurrency limiter for structured concurrency.
/// Controls the maximum number of concurrent tasks in a task group.
actor AsyncSemaphore {
    private let limit: Int
    private var count: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
        self.count = limit
    }

    func wait() async {
        // `count` here is an Int counter, not a collection — empty_count rule is a false positive.
        // swiftlint:disable:next empty_count
        if count > 0 {
            count -= 1
        } else {
            await withCheckedContinuation { cont in
                waiters.append(cont)
            }
        }
    }

    func signal() {
        if waiters.isEmpty {
            count = min(count + 1, limit)
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// Acquire a permit, run the body, then release — guarantees signal even on cancellation.
    func withPermit<T: Sendable>(_ body: @Sendable () async -> T) async -> T {
        await wait()
        let result = await body()
        signal()
        return result
    }
}
