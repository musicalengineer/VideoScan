// PreflightCancellation.swift (VideoScanCore/Preflight)
// A one-shot "stop now" for the one slow preflight question, quick_check
// (QA r1 minor 4). Why it exists: on quit, the app's store close runs a
// checkpoint; a preflight reader still walking the file holds a read
// snapshot that the checkpoint must not wait on. So the close path stops
// the preflight FIRST.
//
// THE HOOK (wiring comes with PART 2): the app keeps the `Task` that runs
// `LaunchPreflight.run` and calls `task.cancel()` at the top of its close
// path, before closing the store. `run` turns Task cancellation into
// `cancel()` here (withTaskCancellationHandler), which interrupts the
// running SQLite statement at its next opcode check. `run` then throws
// CancellationError; nothing is logged as a verdict.
//
// (For Rick: this is a small class with a mutex around two fields — the
// flag and the callback. `@unchecked Sendable` is our promise to the
// compiler that the NSLock makes sharing it across threads safe, the way
// you'd document a class as "thread-safe: all members guarded by m_lock".)

import Foundation

public final class PreflightCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var onCancel: (@Sendable () -> Void)?

    public init() {}

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// Marks it cancelled and runs the registered handler once, outside the lock.
    public func cancel() {
        lock.lock()
        let wasCancelled = cancelled
        cancelled = true
        let handler = onCancel
        onCancel = nil
        lock.unlock()
        if !wasCancelled { handler?() }
    }

    /// Runs `body` with `handler` registered as the stop action. If already
    /// cancelled, `handler` runs at once (before `body`). The handler is
    /// cleared when `body` returns, so a late cancel never reaches a
    /// connection that has gone away.
    public func whileRegistered<T>(_ handler: @escaping @Sendable () -> Void, _ body: () throws -> T) rethrows -> T {
        lock.lock()
        let alreadyCancelled = cancelled
        if !alreadyCancelled { onCancel = handler }
        lock.unlock()
        if alreadyCancelled { handler() }
        defer {
            lock.lock()
            onCancel = nil
            lock.unlock()
        }
        return try body()
    }
}
