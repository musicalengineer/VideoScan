// PausableGatePermit.swift (VideoScanCore)
// One volume-gate permit that can STEP ASIDE while its job is paused
// (2026-08-07 — the compare-starvation incident: a paused Verify Audio
// held the LaCie's single HDD slot for hours; its SIGSTOPped ffmpeg
// did zero IO, yet a queued compare waited behind it with no recourse).
//
// The count-discipline problem this type exists to solve: the shared
// AsyncSemaphore MUST see exactly one signal() per successful wait(),
// across every interleaving of pause / resume / cancel / close. The
// naive fix (signal on pause inside a withPermit body) double-credits
// the semaphore when the body later unwinds — permanently widening the
// gate. This actor owns the permit's whole lifecycle instead, and its
// phase machine makes the invariant checkable:
//
//   unacquired --acquire()--> held --releaseForPause()--> pausedReleased
//        |                     |  ^--reacquireForResume()--/     |
//        |                     +--close(): signal, -> closed     |
//        +--close(): no signal owed --> closed <-- close(): no signal owed
//
//   signal happens EXACTLY when leaving `held` — via releaseForPause
//   (slot lent to the queue) or close (done). pausedReleased owes
//   nothing: its slot was already returned.
//
// codex owns the adversarial test matrix (interleavings, cancel-mid-
// reacquire, double calls) against this seam.

import Foundation

public actor PausableGatePermit {

    public enum Phase: Sendable, Equatable {
        case unacquired
        case held
        case pausedReleased
        case closed
    }

    private let semaphore: AsyncSemaphore
    private var phase: Phase = .unacquired

    public init(semaphore: AsyncSemaphore) {
        self.semaphore = semaphore
    }

    /// Current phase — for tests and diagnostics.
    public var currentPhase: Phase { phase }

    /// Take the slot (queues behind other holders). Throws only
    /// CancellationError (from AsyncSemaphore.wait); a cancelled
    /// acquire leaves the permit unacquired — close() then owes
    /// nothing.
    public func acquire() async throws {
        guard phase == .unacquired else { return }
        try await semaphore.wait()
        phase = .held
    }

    /// Pause is stepping aside: a SIGSTOPped worker does no IO, so the
    /// slot goes back to the queue and a waiting job proceeds.
    public func releaseForPause() async {
        guard phase == .held else { return }
        phase = .pausedReleased
        await semaphore.signal()
    }

    /// Resume re-joins the queue — and must complete BEFORE the worker
    /// is SIGCONTed, so the disk never sees an unslotted reader. A
    /// cancellation mid-wait leaves the permit pausedReleased (still
    /// owing nothing).
    public func reacquireForResume() async throws {
        guard phase == .pausedReleased else { return }
        try await semaphore.wait()
        phase = .held
    }

    /// Terminal, idempotent. Returns the slot iff one is currently
    /// held; a permit closed while unacquired or pausedReleased owes
    /// the semaphore nothing.
    public func close() async {
        switch phase {
        case .held:
            phase = .closed
            await semaphore.signal()
        case .unacquired, .pausedReleased:
            phase = .closed
        case .closed:
            break
        }
    }
}
