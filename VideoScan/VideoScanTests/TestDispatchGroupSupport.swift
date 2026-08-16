import Dispatch

/// Suspends an async test until all work registered with `group` completes.
///
/// Unlike `DispatchGroup.wait()`, notification does not block a Swift
/// concurrency worker thread. The continuation resumes exactly once when the
/// group's count reaches zero.
func awaitCompletion(of group: DispatchGroup) async {
    await withCheckedContinuation { continuation in
        group.notify(queue: .global()) {
            continuation.resume()
        }
    }
}
