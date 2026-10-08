import Foundation

// MARK: - MediaVolumeGateHold (2026-10-07)
//
// The per-volume read gate + pause lend-back that VerifyAudioJob,
// VerifyVideoJob and five other jobs each carry as a verbatim copy
// (the 2026-08-07 compare-starvation fix, codex #289/#292/#295 ordering).
// Check Media uses it as ONE type instead of an eighth copy; moving the
// other seven onto it is a separate, behaviour-neutral refactor.
//
// Contract, unchanged from those copies:
//   - acquire gates in order; a pause that lands while waiting for a gate
//     lends that gate straight back and holds until resume;
//   - pause: the caller SIGSTOPs its child FIRST, then calls `lend()` —
//     the disk never has an extra active reader;
//   - resume: re-hold EVERY slot, THEN the caller SIGCONTs (only when all
//     slots came back);
//   - `close()` releases in reverse order; permits that lent their slot
//     owe the semaphore nothing (PausableGatePermit's phase machine).
//
// (`@MainActor final class` ≈ a C++ class whose every member must be
// touched on the UI thread; the op chain ≈ a serial queue of lambdas.)

@MainActor
final class MediaVolumeGateHold {
    private let jobID: UUID
    private let holderName: String
    private var permits: [(gate: MediaVolumeGate, permit: PausableGatePermit)] = []
    private var opsChain: Task<Void, Never>?

    /// The volume being waited for (label, root) — nil once held.
    private(set) var waiting: (label: String, root: String)?

    init(jobID: UUID, holderName: String) {
        self.jobID = jobID
        self.holderName = holderName
    }

    private func enqueue(_ op: @escaping @MainActor () async -> Void) {
        let previous = opsChain
        opsChain = Task { @MainActor in
            await previous?.value
            await op()
        }
    }

    /// Hold every gate. `isPaused` is read after each acquire. Returns
    /// false when the task was cancelled (everything already released).
    func acquire(_ gates: [MediaVolumeGate], isPaused: @escaping @MainActor () -> Bool) async -> Bool {
        for gate in gates {
            waiting = (gate.label, gate.root)
            let permit = PausableGatePermit(semaphore: gate.semaphore)
            do {
                try await permit.acquire()
            } catch {
                waiting = nil
                await close()
                return false
            }
            permits.append((gate, permit))
            VolumeGateBoard.shared.claim(root: gate.root, jobID: jobID, name: holderName)
            if isPaused() {
                // codex #295: a pause that landed while we waited for THIS
                // gate must lend it too, and hold here.
                lend(only: (gate, permit), while: isPaused)
                while isPaused(), !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                if Task.isCancelled {
                    waiting = nil
                    await close()
                    return false
                }
            }
        }
        waiting = nil
        return true
    }

    private func lend(only entry: (gate: MediaVolumeGate, permit: PausableGatePermit),
                      while isPaused: @escaping @MainActor () -> Bool) {
        enqueue { [weak self] in
            guard let self, isPaused() else { return }
            await entry.permit.releaseForPause()
            VolumeGateBoard.shared.clear(root: entry.gate.root, jobID: self.jobID)
        }
    }

    /// Lend every held slot back (call AFTER suspending the child).
    func lend() {
        enqueue { [weak self] in
            guard let self else { return }
            for entry in self.permits {
                await entry.permit.releaseForPause()
                VolumeGateBoard.shared.clear(root: entry.gate.root, jobID: self.jobID)
            }
        }
    }

    /// Re-hold every slot, then call `then(true)` — or `then(false)` when
    /// one could not be re-held (stay paused).
    func reacquire(then: @escaping @MainActor (Bool) -> Void) {
        enqueue { [weak self] in
            guard let self else { return }
            var allHeld = true
            for entry in self.permits {
                try? await entry.permit.reacquireForResume()
                if await entry.permit.currentPhase == .held {
                    VolumeGateBoard.shared.claim(root: entry.gate.root, jobID: self.jobID, name: self.holderName)
                } else {
                    allHeld = false
                }
            }
            then(allHeld)
        }
    }

    /// Release everything, reverse order.
    func close() async {
        // Deliberately NOT awaiting the op chain (the originals don't): a
        // resume blocked on a busy disk must not wedge a Stop.
        for entry in permits.reversed() {
            await entry.permit.close()
            VolumeGateBoard.shared.clear(root: entry.gate.root, jobID: jobID)
        }
        permits = []
    }
}
