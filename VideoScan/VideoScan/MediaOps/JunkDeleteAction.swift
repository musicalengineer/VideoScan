import Foundation

// MARK: - JunkSheet state machine
//
// Single Identifiable enum that drives the .sheet(item:) modifier replacing
// the previous pair of chained .sheet(isPresented:) modifiers. The chained
// pattern raced: confirm-sheet dismiss animation and result-sheet present
// could overlap when the delete task completed faster than the 0.4s defer
// allowed (or when the system was busy and dismiss took longer). Symptom:
// confirm sheet stuck mid-iconify, app appears unresponsive ("cannot return
// to main window" — Rick's report 2026-06-02).
//
// With .sheet(item:), the transition from .confirm to .result happens via
// a SINGLE item-binding mutation. SwiftUI handles the content swap inside
// the same modal presentation context — no second .sheet ever tries to
// activate. Cancel still dismisses normally (item → nil); the Move button
// doesn't call dismiss() at all; the JunkDeleteAction callback flips
// item → .result(...) when the disk pass completes.
//
// `.confirm` carries the FROZEN snapshot (design R1, 2026-10-09): what the
// sheet shows is exactly what Move to Trash acts on.

enum JunkSheet: Identifiable {
    case confirm(VideoScanModel.JunkTrashSnapshot)
    case result(VideoScanModel.JunkDeletionResult,
                VideoScanModel.JunkDeletionMode,
                Int64)

    /// CRITICAL: both cases return the SAME id. SwiftUI uses `id` to
    /// decide whether an item change should animate a dismiss-then-present
    /// cycle or just swap content in place. Different ids per case would
    /// re-introduce the very race this enum was created to eliminate
    /// (confirm dismiss racing result present). Same id → SwiftUI keeps
    /// the modal context alive and switches content atomically.
    var id: String { "junkSheet" }
}

// MARK: - JunkDeleteAction
//
// The `onAct` closure of DeleteConfirmedJunkConfirmSheet (Triage).
//
// Why an extracted factory function: the SwiftUI Button calls `onAct()`;
// SwiftUI doesn't schedule follow-up animation work until the button's
// action closure returns. So any synchronous work inside `onAct` delays it
// — and if it delays past the next display refresh window, the sheet
// freezes partway through (the "half-iconified frozen sheet" regression
// Rick reported on 2026-06-02). The fix is to defer ALL work into a Task so
// `onAct` returns within the same runloop tick. See
// JunkDeleteActionRegressionTests.

@MainActor
enum JunkDeleteAction {

    /// Build the onAct closure for DeleteConfirmedJunkConfirmSheet.
    ///
    /// The returned closure schedules a Task and returns immediately. The
    /// Task runs `trashFrozenJunk` on EXACTLY `snapshot` — never a fresh
    /// query of the catalog (a file marked after the sheet opened is not
    /// in the set). Disk I/O inside uses its own `Task.detached`, so this
    /// @MainActor Task only awaits without blocking main.
    ///
    /// - Parameters:
    ///   - model: The catalog model.
    ///   - snapshot: The set the confirmation showed, frozen when it opened.
    ///   - onComplete: Called on MainActor after the disk pass returns,
    ///     with the result, the mode used, and an estimate of the bytes
    ///     moved (scaled from the counted bytes by the success ratio).
    static func makeOnAct(
        model: VideoScanModel,
        snapshot: VideoScanModel.JunkTrashSnapshot,
        onComplete: @escaping @MainActor (
            _ result: VideoScanModel.JunkDeletionResult,
            _ mode: VideoScanModel.JunkDeletionMode,
            _ bytesSucceeded: Int64
        ) -> Void
    ) -> @MainActor () -> Void {
        return {
            Task { @MainActor in
                let result = await model.trashFrozenJunk(snapshot)
                let bytesBefore = snapshot.moveBytes
                // Scale counted bytes by the success ratio over the
                // actionable denominator (attempted minus the no-ops).
                let actionable = max(
                    result.attempted - result.alreadyMissing - result.skippedOffline,
                    0
                )
                let bytesSucceeded: Int64 = actionable > 0
                    ? Int64(Double(bytesBefore) * Double(result.succeeded) / Double(actionable))
                    : 0
                onComplete(result, .toTrash, bytesSucceeded)
            }
        }
    }
}
