import Combine
import Foundation
import os

// MARK: - PairCompareJob
//
// Wraps `MediaPairComparator` (untouched) as a `MediaFileOperationJob`
// so the quick two-file check runs as a row in the Media File
// Operations window instead of a modal sheet.
//
// Ownership shift vs. the old sheet: the run Task lives HERE, on the
// job — not in a view's `.task` — so the comparison keeps running when
// the window is closed and survives until cancel or completion. Cancel
// propagation is unchanged: `task.cancel()` reaches the comparator's
// per-chunk `Task.checkCancellation()` and ProcessRunner's cancellation
// handler, which terminates any running ffmpeg child.
//
// Per-volume HDD gating: before the comparator's heavy Tier-1/Tier-2
// reads, the job acquires one slot per spinning volume root it touches
// (gates are built and shared by MediaFileOperationsCenter). While
// queued behind another compare, the row shows "Waiting for <volume>…".
// Gating lives in this wrapper, NOT in the comparator.

/// File-scope logger — the job's detached run task logs through this.
private let fileOpsLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                category: "fileOps")

@MainActor
// `@MainActor` on the conformance (SE-0470 isolated conformances):
// the protocol's requirements may only be used from the main actor —
// which is exactly how the window uses them.
final class PairCompareJob: @MainActor MediaFileOperationJob {

    /// One volume gate this job must hold while reading. Phase 2
    /// hoisted the concrete type to `MediaVolumeGate` (shared with
    /// ExtractFramesJob); the nested alias keeps phase-1 call sites
    /// and tests reading naturally.
    typealias Gate = MediaVolumeGate

    let id = UUID()
    let kind: MediaFileOperationKind = .compare
    let startedAt = Date()

    /// Kept for the expanded row detail (verdict banner + side-by-side
    /// metadata diff table).
    let recordA: VideoRecord
    let recordB: VideoRecord

    /// One comparator instance per job — never shared, never reused.
    let comparator = MediaPairComparator()

    /// Pause (phase 1): OFF for compare. The comparator has no safe
    /// pause points — Tier 1 is a hash loop we'd have to gate per-chunk
    /// and Tier 2 is a live ffmpeg child that can't be suspended
    /// cleanly through ProcessRunner. Revisit if compare pausing earns
    /// its keep; cancel is cheap and the tiers restart fast.
    let canPause = false

    /// Tracked explicitly — never inferred from the comparator's
    /// statusText (string-sniffing state is how subtle bugs happen).
    @Published private(set) var wasCancelled = false

    /// Non-nil while queued behind another compare on a gated volume.
    @Published private(set) var waitingForVolumeLabel: String?

    /// The run Task — owned by the job (see header note). Internal so
    /// tests can `await job.task?.value` to reach the terminal state.
    private(set) var task: Task<Void, Never>?

    /// Re-publish the comparator's @Published changes as our own so
    /// the row view re-renders on progress.
    private var comparatorForwarder: AnyCancellable?

    private let gates: [Gate]

    // MARK: Init / start

    init(recordA: VideoRecord, recordB: VideoRecord, gates: [Gate]) {
        self.recordA = recordA
        self.recordB = recordB
        self.gates = gates
        comparatorForwarder = comparator.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// Start the comparison. Idempotent — a second call is a no-op.
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            await self.runHoldingGates(self.gates[...])
        }
    }

    /// Acquire each gate in order (recursing so `withPermit` can
    /// guarantee release even on cancellation), then run the comparator
    /// while holding all of them. The comparator reads files strictly
    /// sequentially, so holding both volumes' slots for the whole run
    /// is slightly conservative but keeps "at most one compare reads a
    /// spinning volume" trivially true.
    private func runHoldingGates(_ remaining: ArraySlice<Gate>) async {
        guard let gate = remaining.first else {
            waitingForVolumeLabel = nil
            await comparator.run(recordA: recordA, recordB: recordB)
            return
        }
        waitingForVolumeLabel = gate.label
        fileOpsLog.info("compare \(self.id, privacy: .public) waiting for \(gate.root, privacy: .public)")
        do {
            try await gate.semaphore.withPermit { [weak self] in
                await self?.runHoldingGates(remaining.dropFirst())
            }
        } catch {
            // Only CancellationError escapes withPermit here (the body
            // doesn't throw) — the user cancelled while we were queued.
            waitingForVolumeLabel = nil
            fileOpsLog.info("compare \(self.id, privacy: .public) cancelled while waiting for \(gate.root, privacy: .public)")
        }
    }

    // MARK: MediaFileOperationJob

    var title: String {
        "\(recordA.filename) vs \(recordB.filename)"
    }

    var subtitle: String {
        if let label = waitingForVolumeLabel {
            return "Waiting for \(label)…"
        }
        switch state {
        case .failed(let message):
            return message
        case .finished:
            return comparator.verdict?.detail ?? "Done"
        case .cancelled:
            return "Stopped"
        case .cancelling:
            return "Stopping…"
        case .running:
            return comparator.statusText.isEmpty ? "Starting…" : comparator.statusText
        }
    }

    var fraction: Double { comparator.fraction }

    /// Indeterminate while queued for a volume slot (no meaningful
    /// fraction yet) or while the comparator itself has no duration
    /// hint for ffmpeg progress.
    var isIndeterminate: Bool {
        waitingForVolumeLabel != nil || comparator.isIndeterminate
    }

    /// Derived from comparator state + the explicit cancel flag.
    /// Precedence: a verdict or error that landed before cancel wins —
    /// the work IS done, no point pretending otherwise.
    var state: MediaFileOperationState {
        if let verdict = comparator.verdict {
            return .finished(summary: verdict.title)
        }
        if let error = comparator.lastError {
            return .failed(message: error)
        }
        if wasCancelled {
            return comparator.isRunning ? .cancelling : .cancelled
        }
        return .running
    }

    func cancel() {
        guard state.isActive, !wasCancelled else { return }
        wasCancelled = true
        task?.cancel()
        fileOpsLog.info("compare cancelled: \(self.title, privacy: .public)")
    }
}
