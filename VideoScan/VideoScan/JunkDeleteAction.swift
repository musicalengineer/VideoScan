import Foundation

// MARK: - JunkDeleteAction
//
// Shared implementation of the `onAct` closure used by
// DeleteConfirmedJunkConfirmSheet from both TriageView and CatalogHelpers.
//
// Why an extracted factory function: the SwiftUI Button calls
// `onAct(mode)` and then `dismiss()`. SwiftUI doesn't schedule the
// dismiss animation until the button's action closure returns. So
// any synchronous work inside `onAct` delays the dismiss — and if it
// delays past the next display refresh window, the dismiss animation
// freezes partway through (the "half-iconified frozen sheet"
// regression Rick reported on 2026-06-02). The fix is to defer ALL
// work into a Task so `onAct` returns within the same runloop tick.
//
// This factory exists so we can write a regression test that asserts
// the returned closure returns within a tight time bound regardless
// of catalog size — see JunkDeleteActionRegressionTests.

@MainActor
enum JunkDeleteAction {

    /// Build the onAct closure for DeleteConfirmedJunkConfirmSheet.
    ///
    /// The returned closure is callable from a SwiftUI button action.
    /// It schedules a Task and returns immediately so the button's
    /// follow-up `dismiss()` call runs unblocked, letting SwiftUI start
    /// the sheet dismiss animation in the same runloop tick.
    ///
    /// All work — record filtering, splitByReachability, the async
    /// `deleteConfirmedJunk` call, and result post-processing — runs
    /// inside the deferred Task. Disk I/O inside `deleteConfirmedJunk`
    /// uses its own `Task.detached`, so the @MainActor Task here only
    /// awaits without blocking main.
    ///
    /// - Parameters:
    ///   - model: The catalog model.
    ///   - onComplete: Called on MainActor after the disk pass returns,
    ///     with the JunkDeletionResult, the mode used, and an estimate
    ///     of the bytes successfully freed (scaled from reachable
    ///     bytes-before by the success ratio).
    static func makeOnAct(
        model: VideoScanModel,
        onComplete: @escaping @MainActor (
            _ result: VideoScanModel.JunkDeletionResult,
            _ mode: VideoScanModel.JunkDeletionMode,
            _ bytesSucceeded: Int64
        ) -> Void
    ) -> @MainActor (VideoScanModel.JunkDeletionMode) -> Void {
        return { mode in
            Task { @MainActor in
                // Re-query the model so a record tagged after the sheet
                // opened doesn't miss the pass.
                let targets = model.records.filter {
                    $0.mediaDisposition == .confirmedJunk && $0.purgedAt == nil
                }
                // bytesBefore covers only reachable records — offline
                // ones get skipped without a disk op, so they shouldn't
                // count toward the "freed N GB" reading.
                let split = VideoScanModel.splitByReachability(targets)
                let bytesBefore = split.reachableBytes
                let result = await model.deleteConfirmedJunk(targets, mode: mode)
                // Scale reachable-bytes-before by the success ratio over
                // the actionable denominator (attempted minus the no-ops).
                let actionable = max(
                    result.attempted - result.alreadyMissing - result.skippedOffline,
                    0
                )
                let bytesSucceeded: Int64 = actionable > 0
                    ? Int64(Double(bytesBefore) * Double(result.succeeded) / Double(actionable))
                    : 0
                onComplete(result, mode, bytesSucceeded)
            }
        }
    }
}
