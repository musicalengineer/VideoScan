// InMemoryPreviewSweepFailureStore.swift (VideoScanCore)
// A minimal, bounded, thread-safe `PreviewSweepFailureStore` for the
// out-of-process helper (2026-07-28, Stage 1). The app's negative cache is
// ThumbnailFailureStore (app target, coupled to the interactive preview
// paths); the CLI is a fresh process per launch and only needs a
// within-run negative cache so a genuinely-undecodable file isn't re-ripped
// N times inside one pass. Kept in Core so tests can inject it too.
//
// For Rick: a mutex-guarded Set<String> with a hard entry cap — the same
// "tiny box" convention as ThumbnailFailureStore, just process-local.

import Foundation

public final class InMemoryPreviewSweepFailureStore: PreviewSweepFailureStore, @unchecked Sendable {

    /// Memory bound — mirrors ThumbnailFailureStore.maxEntries so a
    /// pathological catalog can't grow this without limit.
    public let maxEntries: Int

    private let lock = NSLock()
    private var failures: Set<String> = []

    public init(maxEntries: Int = 10_000) {
        self.maxEntries = maxEntries
    }

    public func isKnownFailure(atPath path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return failures.contains(path)
    }

    public func recordFailure(forPath path: String) {
        lock.lock()
        defer { lock.unlock() }
        guard failures.count < maxEntries else { return }
        failures.insert(path)
    }

    /// Count — for the CLI's honest end-of-run summary and tests.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return failures.count
    }
}
