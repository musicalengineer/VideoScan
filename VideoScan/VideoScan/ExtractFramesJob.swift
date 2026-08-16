import Combine
import Foundation
import os

// MARK: - ExtractFramesJob
//
// Phase 2 of the Media File Operations window: "Extract Frames…" runs
// as a row in the one operations window instead of its own modal sheet
// (FrameRipperSheet, retired to .trash/).
//
// Wraps `FrameRipper` (core pipeline untouched) as a
// `MediaFileOperationJob`, exactly the way PairCompareJob wraps
// MediaPairComparator:
//
//   - The run Task lives HERE, on the job — not in a view's `.task` —
//     so the rip keeps running when the window closes and survives
//     until cancel or completion.
//   - Cancel propagation is structured concurrency: `task.cancel()`
//     reaches the ripper's per-frame `Task.isCancelled` checks in both
//     the sampling and saving loops, so it lands within one frame
//     decode. Frames already saved stay on disk — the row verdict says
//     so.
//   - Per-volume gating: before the rip's long sequential decode, the
//     job acquires one slot for the source file's volume root (gates
//     built and shared by MediaFileOperationsCenter — same HDD-thrash
//     rationale as compare). While queued, the row shows
//     "Waiting for <volume>…". Gating lives in this wrapper, NOT in
//     the ripper.
//
// Memory footprint: unchanged from the sheet era — the dominant cost
// is FrameRipper's candidate buffer (up to duration/2s native-res
// CGImages held until ranking). The job itself adds O(1). Multiple
// concurrent extracts multiply that buffer; the per-volume gates bound
// concurrency on spinning/network volumes but NOT on SSDs — if Rick
// queues many SSD extracts at once, revisit with a global extract gate.
//
// Pause/resume: deliberately NOT implemented (protocol no-op defaults
// stand). The ripper's loops do have a per-frame yield point, but a
// clean pause needs a continuation gate inside FrameRipper's core
// sampling loop — phase 2 keeps the ripper untouched. Cancel is cheap
// and a re-run re-samples quickly.

/// File-scope logger — the job's detached run task logs through this.
private let fileOpsLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                category: "fileOps")

// `@MainActor` isolation: the protocol's requirements may only be
// used from the main actor — which is exactly how the window uses them.
@MainActor
final class ExtractFramesJob: @MainActor MediaFileOperationJob {

    let id = UUID()
    let kind: MediaFileOperationKind = .extract
    let startedAt = Date()

    /// Source video being ripped. Kept for the row title and the
    /// disabled-state checks at the call site.
    let record: VideoRecord

    /// Parent folder picked in the NSOpenPanel; the ripper creates
    /// "<videoStem>-frames/" inside it.
    let destinationParent: URL

    /// One ripper instance per job — never shared, never reused.
    let ripper = FrameRipper()

    /// Pause (phase 2): OFF for extract — see header note.
    let canPause = false

    /// Tracked explicitly — never inferred from the ripper's
    /// statusText (string-sniffing state is how subtle bugs happen).
    @Published private(set) var wasCancelled = false

    /// Terminal-transition stamp — freezes the row clock (see
    /// MediaFileOperationClock). `state` is DERIVED here, so the run
    /// Task's completion and the immediate-cancel path in `cancel()`
    /// both stamp via `stampFinishedIfTerminal()` — first stamp wins.
    @Published private(set) var finishedAt: Date?

    /// Non-nil while queued behind another job on a gated volume.
    @Published private(set) var waitingForVolumeLabel: String?
    /// Root of the gate being queued on — subtitle names its holder
    /// live via VolumeGateBoard (2026-08-07 incident).
    private var waitingForVolumeRoot: String?

    /// The run Task — owned by the job (see header note). Internal so
    /// tests can `await job.task?.value` to reach the terminal state.
    private(set) var task: Task<Void, Never>?

    /// Re-publish the ripper's @Published changes as our own so the
    /// row view re-renders on progress.
    private var ripperForwarder: AnyCancellable?

    private let gates: [MediaVolumeGate]
    private let options: FrameRipper.Options

    // MARK: Init / start

    init(record: VideoRecord,
         destinationParent: URL,
         gates: [MediaVolumeGate],
         options: FrameRipper.Options = FrameRipper.Options()) {
        self.record = record
        self.destinationParent = destinationParent
        self.gates = gates
        self.options = options
        ripperForwarder = ripper.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// Start the rip. Idempotent — a second call is a no-op.
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
    /// guarantee release even on cancellation), then run the ripper
    /// while holding all of them. Single source file ⇒ at most one
    /// gate today, but the recursion matches PairCompareJob so the two
    /// wrappers stay textually comparable.
    private func runHoldingGates(_ remaining: ArraySlice<MediaVolumeGate>) async {
        guard let gate = remaining.first else {
            waitingForVolumeLabel = nil
            await ripper.run(videoURL: URL(fileURLWithPath: record.fullPath),
                             intoParent: destinationParent,
                             options: options)
            logCompletion()
            return
        }
        waitingForVolumeLabel = gate.label
        waitingForVolumeRoot = gate.root
        fileOpsLog.info("extract \(self.id, privacy: .public) waiting for \(gate.root, privacy: .public)")
        let holder = "Extract \(title)"   // capture on MainActor, before the Sendable closure
        let jobID = id
        do {
            try await gate.semaphore.withPermit { [weak self] in
                await MainActor.run { VolumeGateBoard.shared.claim(root: gate.root, jobID: jobID, name: holder) }
                await self?.runHoldingGates(remaining.dropFirst())
                await MainActor.run { VolumeGateBoard.shared.clear(root: gate.root, jobID: jobID) }
            }
        } catch {
            // Only CancellationError escapes withPermit here (the body
            // doesn't throw) — the user cancelled while we were queued.
            waitingForVolumeLabel = nil
            fileOpsLog.info("extract \(self.id, privacy: .public) cancelled while waiting for \(gate.root, privacy: .public)")
        }
    }

    private func logCompletion() {
        switch state {
        case .finished(let summary):
            fileOpsLog.info("extract finished: \(self.record.filename, privacy: .public) — \(summary, privacy: .public) in \(self.ripper.completedDestination?.path ?? "?", privacy: .public)")
        case .failed(let message):
            fileOpsLog.error("extract failed: \(self.record.filename, privacy: .public) — \(message, privacy: .public)")
        case .cancelled:
            fileOpsLog.info("extract cancelled: \(self.record.filename, privacy: .public) — \(self.ripper.framesSaved) frame(s) kept on disk")
        default:
            break
        }
    }

    // MARK: MediaFileOperationJob

    var title: String { record.filename }

    var subtitle: String {
        if let label = waitingForVolumeLabel {
            return VolumeGateBoard.describeWait(label: label,
                                                root: waitingForVolumeRoot ?? "")
        }
        switch state {
        case .failed(let message):
            return message
        case .finished:
            if let dest = ripper.completedDestination {
                return "Saved \(ripper.framesSaved) frame(s) → \(dest.path)"
            }
            return "Done"
        case .cancelled:
            // Cancel never deletes output — anything already saved is
            // kept, and the row says so explicitly.
            if ripper.framesSaved > 0, let dest = ripper.completedDestination {
                return "Stopped — \(ripper.framesSaved) already-saved frame(s) kept in \(dest.lastPathComponent)"
            }
            return "Stopped — no frames saved"
        case .cancelling:
            return "Stopping…"
        case .running:
            return ripper.statusText.isEmpty ? "Starting…" : ripper.statusText
        }
    }

    /// Two-phase fraction (carried over from the retired sheet):
    /// sampling fills 0…0.5, saving fills 0.5…1.0 — early visible
    /// progress before the save phase starts.
    var fraction: Double {
        let scanPart: Double = ripper.candidateTarget > 0
            ? min(1.0, Double(ripper.framesScanned) / Double(ripper.candidateTarget))
            : 0
        let savePart: Double = ripper.saveTarget > 0
            ? min(1.0, Double(ripper.framesSaved) / Double(ripper.saveTarget))
            : 0
        return scanPart * 0.5 + savePart * 0.5
    }

    /// Indeterminate while queued for a volume slot or before the
    /// duration probe has sized the candidate set.
    var isIndeterminate: Bool {
        waitingForVolumeLabel != nil || ripper.candidateTarget == 0
    }

    /// Derived from ripper state + the explicit cancel flag.
    /// Precedence mirrors PairCompareJob: an error that landed before
    /// cancel wins; a successful destination only counts as finished
    /// when the user didn't cancel (a cancelled-mid-save rip also sets
    /// `completedDestination` so Reveal works on the partial output).
    var state: MediaFileOperationState {
        if let error = ripper.lastError {
            return .failed(message: error)
        }
        if wasCancelled {
            return ripper.isRunning ? .cancelling : .cancelled
        }
        if ripper.completedDestination != nil {
            return .finished(summary: "\(ripper.framesSaved) frame\(ripper.framesSaved == 1 ? "" : "s") saved")
        }
        return .running
    }

    func cancel() {
        guard state.isActive, !wasCancelled else { return }
        wasCancelled = true
        // Mirror the ripper's own cancel UX flag so its statusText
        // pipeline stays coherent; the actual stop is the task cancel.
        ripper.isCancelling = true
        task?.cancel()
        // Cancelled before start() (no run Task will ever end): the
        // derived state is ALREADY .cancelled — stamp the clock now.
        stampFinishedIfTerminal()
        fileOpsLog.info("extract cancelled by user: \(self.title, privacy: .public)")
    }
}
