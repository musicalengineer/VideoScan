// ThrottledMainActorUpdate.swift (VideoScanCore)
// Moved from the app's MemoryPressure.swift (2026-07-28) so the extracted
// preview-sweep engine — and its Stage-1 CLI reuse — can throttle
// progress publishes. Logic verbatim; visibility widened to public.

import Foundation

/// Coalesces frequent MainActor dispatches to a maximum rate.
/// Used to prevent UI beachball when many concurrent tasks all want
/// to update progress/frames on the main thread.
public actor ThrottledMainActorUpdate {
    private let interval: TimeInterval
    private var lastUpdate: CFAbsoluteTime = 0

    public init(intervalSecs: TimeInterval = 0.25) {
        self.interval = intervalSecs
    }

    /// Execute `block` on MainActor only if enough time has passed since the last update.
    /// Skipped updates are silently dropped — the next one that fires will have current data.
    public func update(_ block: @MainActor @Sendable () -> Void) async {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastUpdate >= interval else { return }
        lastUpdate = now
        await MainActor.run { block() }
    }
}
