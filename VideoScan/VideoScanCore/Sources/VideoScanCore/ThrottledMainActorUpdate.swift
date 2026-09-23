// ThrottledMainActorUpdate.swift (VideoScanCore)
// Moved from the app's MemoryPressure.swift (2026-07-28) so the extracted
// preview-sweep engine — and its Stage-1 CLI reuse — can throttle
// progress publishes. Visibility widened to public.
//
// 2026-09-23: monotonic clock. The throttle used CFAbsoluteTimeGetCurrent()
// — the WALL clock, which timed/NTP (or a user) can step backwards. After a
// backwards step `now - lastUpdate` is negative, so every update was dropped
// until the wall clock caught up: 4 lost updates in a nightly run of
// LivePreviewPublishBenchmarkTests even at interval 0, and in production a
// frozen live preview / progress display for as long as the step. Now:
// system uptime (mach absolute time; never steps back), interval ≤ 0 never
// drops, and a reading earlier than the last one fires rather than waits.
// C++ analogy: system_clock → steady_clock.

import Foundation

/// Coalesces frequent MainActor dispatches to a maximum rate.
/// Used to prevent UI beachball when many concurrent tasks all want
/// to update progress/frames on the main thread.
public actor ThrottledMainActorUpdate {
    private let interval: TimeInterval
    private var lastUpdate: TimeInterval?
    private let now: @Sendable () -> TimeInterval

    public init(intervalSecs: TimeInterval = 0.25) {
        self.init(intervalSecs: intervalSecs, now: { Self.monotonicSeconds() })
    }

    /// Test seam: inject the clock (tests step it backwards on purpose).
    init(intervalSecs: TimeInterval, now: @escaping @Sendable () -> TimeInterval) {
        self.interval = intervalSecs
        self.now = now
    }

    /// Seconds since boot — monotonic, unaffected by wall-clock changes.
    static func monotonicSeconds() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    /// Execute `block` on MainActor only if enough time has passed since the last update.
    /// Skipped updates are silently dropped — the next one that fires will have current data.
    public func update(_ block: @MainActor @Sendable () -> Void) async {
        let t = now()
        if interval > 0, let last = lastUpdate, t >= last, t - last < interval {
            return
        }
        lastUpdate = t
        await MainActor.run { block() }
    }
}
