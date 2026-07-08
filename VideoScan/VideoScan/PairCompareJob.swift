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
// Gating lives in this wrapper, NOT in the comparator. The perceptual
// tier (Tier 3) runs inside the same gate scope — it's just more
// sequential reading of the same two files.

/// File-scope logger — the job's detached run task logs through this.
private let fileOpsLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                category: "fileOps")

// `@MainActor` isolation: the protocol's requirements may only be
// used from the main actor — which is exactly how the window uses them.
@MainActor
final class PairCompareJob: MediaFileOperationJob {

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

    /// Terminal-transition stamp — freezes the row clock (see
    /// MediaFileOperationClock). `state` is DERIVED here, so there is
    /// no single setter to observe; the run Task's completion (which
    /// is exactly when the derived state settles terminal) and the
    /// immediate-cancel path in `cancel()` both stamp via
    /// `stampFinishedIfTerminal()`. Nil-guarded — first stamp wins.
    @Published private(set) var finishedAt: Date?

    /// Set by the stall watchdog when the comparator stops making progress
    /// (a sleeping /Volumes drive mid-read during an ffmpeg streamhash /
    /// perceptual tier). Surfaced as `.failed` with volume-drop attribution
    /// — distinct from a user cancel. The watchdog cancels the Task, which
    /// kills the ffmpeg child via ProcessRunner's SIGTERM→SIGKILL path.
    @Published private(set) var stallReason: String?

    /// Live for the duration of the comparator run; kicked by the
    /// comparator's `objectWillChange` (which fires on every ffmpeg
    /// `out_time_us` progress line and every hash-loop byte-granularity
    /// update). Silence past the threshold ⇒ stall.
    private var stallMonitor: StallMonitor?

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
            // Each comparator publish (progress line / hash-loop tick) is a
            // liveness signal — kick the stall watchdog before re-broadcast.
            self?.stallMonitor?.tick()
            self?.objectWillChange.send()
        }
    }

    /// Start the comparison. Idempotent — a second call is a no-op.
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            await self.runHoldingGates(self.gates[...])
            // The derived `state` is terminal once the run unwinds —
            // this is the terminal transition for clock purposes.
            self.stampFinishedIfTerminal()
        }
    }

    /// Freeze the row clock at the terminal transition. Nil-guarded so
    /// the first stamp wins (cancel-before-start stamps here first;
    /// the run Task's completion is then a no-op).
    private func stampFinishedIfTerminal() {
        if !state.isActive, finishedAt == nil { finishedAt = Date() }
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
            // Stall watchdog spans the whole comparator run (all tiers).
            let monitor = StallMonitor(label: "compare \(recordA.filename) vs \(recordB.filename)") { [weak self] silentFor in
                Task { @MainActor [weak self] in
                    self?.handleStall(silentFor: silentFor)
                }
            }
            stallMonitor = monitor
            monitor.start()
            fileOpsLog.info("compare RUN: \(self.recordA.filename, privacy: .public) vs \(self.recordB.filename, privacy: .public)")
            await comparator.run(recordA: recordA, recordB: recordB)
            monitor.stop()
            stallMonitor = nil
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
            // finishedSubtitle, not verdict.detail: the perceptual
            // verdict leads with its statistics ("31/32 frames agree …").
            return comparator.finishedSubtitle ?? "Done"
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
        // Stall wins over a generic comparator error / cancel: it's the more
        // specific cause (and carries volume-drop attribution).
        if let stallReason {
            return .failed(message: stallReason)
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
        // Cancelled before start(), or while not mid-comparator: the
        // derived state is ALREADY .cancelled and no run Task will end
        // (or it ends without another transition) — stamp now.
        stampFinishedIfTerminal()
        fileOpsLog.info("compare cancelled: \(self.title, privacy: .public)")
    }

    // MARK: Stall handling

    /// Invoked (on the main actor) by the StallMonitor when the comparator
    /// stops publishing progress. Records a SPECIFIC reason with volume-drop
    /// vs file-error attribution (#6.4) and cancels the run — killing any
    /// live ffmpeg child via ProcessRunner's SIGTERM→SIGKILL escalation.
    /// (Note: an in-process Tier-1 hash read blocked in uninterruptible
    /// kernel I/O is detected here but can't be force-unblocked — only the
    /// ffmpeg-subprocess tiers, including the perceptual tier, are killable.)
    /// Internal (not private) so tests can drive the stall path directly —
    /// the StallMonitor wiring is timer-based and nondeterministic in tests.
    func handleStall(silentFor: Double) {
        guard state.isActive, stallReason == nil, !wasCancelled else { return }
        let attribution = StallMonitor.attribution(forPaths: [recordA.fullPath, recordB.fullPath])
        let reason = "Stalled — no compare progress for \(Int(silentFor))s. \(attribution)"
        stallReason = reason
        fileOpsLog.error("compare WATCHDOG: killing \(self.title, privacy: .public) — \(reason, privacy: .public)")
        appLog.write("compare watchdog: \(title) stalled \(Int(silentFor))s — \(attribution); killing")
        task?.cancel()
        // stallReason just flipped the derived state to .failed, and if the
        // stalled read is blocked in uninterruptible kernel I/O the run Task
        // may never unwind to deliver its stamp — freeze the clock here.
        stampFinishedIfTerminal()
    }
}
