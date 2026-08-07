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
// gate.
//
// REENTRANCY (codex #289/#292 round): an actor suspends at every
// await — so a guard checked before `semaphore.wait()` can be checked
// AGAIN by a second caller before the first resumes. Two rules close
// every hole:
//   1. Transitional phases (.acquiring / .reacquiring) are set BEFORE
//      the suspension point, so concurrent callers fail the guard and
//      no-op — at most ONE wait() is ever in flight per permit.
//   2. closed WINS: a wait() that completes after close() returns its
//      slot to the semaphore and leaves the phase closed — a permit
//      can never be resurrected, and never retains a slot post-close.
//
//   unacquired --acquire--> acquiring --wait ok--> held
//   held --releaseForPause (signal)--> pausedReleased
//   pausedReleased --reacquireForResume--> reacquiring --wait ok--> held
//   any non-held --close--> closed (owes nothing)
//   held --close (signal)--> closed
//   {acquiring,reacquiring} --wait completes after close--> closed (signal back)
//   {acquiring,reacquiring} --wait cancelled--> prior phase restored
//
// Sensors: PausableGatePermitTests (RED-proven against the pre-phase
// implementation, 2026-08-07); codex owns the fuzzed interleaving
// matrix.

import Foundation

public actor PausableGatePermit {

    public enum Phase: Sendable, Equatable {
        case unacquired
        case acquiring
        case held
        case pausedReleased
        case reacquiring
        case closed
    }

    private let semaphore: AsyncSemaphore
    private var phase: Phase = .unacquired

    public init(semaphore: AsyncSemaphore) {
        self.semaphore = semaphore
    }

    /// Current phase — for tests, diagnostics, and the job-side
    /// "did resume actually re-hold?" check.
    public var currentPhase: Phase { phase }

    /// Take the slot (queues behind other holders). Throws only
    /// CancellationError (from AsyncSemaphore.wait). Concurrent
    /// callers no-op against the .acquiring guard; a cancelled wait
    /// restores .unacquired; a wait that outlives close() returns its
    /// slot and stays closed.
    public func acquire() async throws {
        guard phase == .unacquired else { return }
        phase = .acquiring
        do {
            try await semaphore.wait()
        } catch {
            if phase == .acquiring { phase = .unacquired }
            throw error
        }
        guard phase == .acquiring else {         // closed raced the wait
            await semaphore.signal()
            return
        }
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
    /// is SIGCONTed. Concurrent callers no-op against .reacquiring;
    /// a cancelled wait restores .pausedReleased (still owing
    /// nothing); a wait that outlives close() returns its slot and
    /// stays closed. Callers MUST check `currentPhase == .held`
    /// afterward before letting the worker touch the disk.
    public func reacquireForResume() async throws {
        guard phase == .pausedReleased else { return }
        phase = .reacquiring
        do {
            try await semaphore.wait()
        } catch {
            if phase == .reacquiring { phase = .pausedReleased }
            throw error
        }
        guard phase == .reacquiring else {       // closed raced the wait
            await semaphore.signal()
            return
        }
        phase = .held
    }

    /// Terminal, idempotent, and it WINS: any in-flight wait that
    /// completes later finds .closed and signals its slot straight
    /// back. Returns a slot iff one is held right now; transitional
    /// and lent phases owe the semaphore nothing.
    public func close() async {
        switch phase {
        case .held:
            phase = .closed
            await semaphore.signal()
        case .unacquired, .acquiring, .pausedReleased, .reacquiring:
            phase = .closed
        case .closed:
            break
        }
    }
}
