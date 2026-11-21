// SeamRendezvousSupport.swift
// A rendezvous for seam-isolation tests (Codex #347 P2, 2026-11-21).
//
// "N tests ran at once and each saw its own binding" proves nothing unless
// the bindings were really held AT THE SAME TIME: under a serial schedule a
// process-global that each case sets and resets passes too. So the cases
// are sibling tasks of ONE test, each makes its binding and then waits
// here, and nobody proceeds until all N are waiting — inside their
// bindings. Only then does each look at what it can see. The overlap is
// constructed and counted, not hoped for.
//
// (C++: a std::barrier(N). Every thread installs its thread_local, calls
// barrier.arrive_and_wait(), and reads only after all N have installed.)

import Foundation

actor SeamRendezvous {
    let parties: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var held = 0
    /// The most parties that were inside their binding at one moment.
    private(set) var peakHeld = 0

    init(parties: Int) { self.parties = parties }

    /// Call INSIDE the binding. Returns once all `parties` are inside theirs.
    func arrive() async {
        held += 1
        peakHeld = max(peakHeld, held)
        if held == parties {
            let all = waiting
            waiting = []
            all.forEach { $0.resume() }
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Call when leaving the binding.
    func leave() { held -= 1 }
}
