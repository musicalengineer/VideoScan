import Combine
import Foundation
import os

// MARK: - RipAllFramesJob
//
// "Extract Frames…" (ffmpeg-only, verb split 2026-06-10) as a row in
// the Media File Operations window. Wraps `AllFramesRipper` as a
// `MediaFileOperationJob`, mirroring ExtractFramesJob line-for-line
// where the semantics match:
//
//   - The run Task lives HERE, on the job — not in a view's `.task` —
//     so the export keeps running when the window closes and survives
//     until cancel or completion.
//   - Cancel propagation is structured concurrency: `task.cancel()`
//     reaches the ripper's `withTaskCancellationHandler`, which
//     SIGTERMs the ffmpeg child. ffmpeg exits cleanly; PNGs already
//     written stay on disk — the row verdict says so.
//   - Per-volume gating: ffmpeg reads the source sequentially for the
//     whole run, so the job holds one slot for the source volume
//     (gates built and shared by MediaFileOperationsCenter — same
//     HDD-thrash rationale as compare/extract). While queued, the row
//     shows "Waiting for <volume>…".
//
// Memory footprint: O(1) — see the header note in AllFramesRipper.
// The DISK footprint is the hazard with this verb (10-min DV ≈ 18k
// PNGs ≈ several GB); the options sheet shows the estimate before
// start and the subtitle repeats it while running.
//
// Pause/resume: deliberately NOT implemented (protocol no-op defaults
// stand) — can't pause mid-ffmpeg without SIGSTOP games. Cancel keeps
// partial output, and a re-run with `-y` just overwrites.

/// File-scope logger — the job's detached run task logs through this.
private let fileOpsLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                category: "fileOps")

// `@MainActor` isolation: the protocol's requirements may only be
// used from the main actor — which is exactly how the window uses them.
@MainActor
final class RipAllFramesJob: MediaFileOperationJob {

    let id = UUID()
    let kind: MediaFileOperationKind = .ripFrames
    let startedAt = Date()

    /// Source video being exported. Kept for the row title and the
    /// disabled-state checks at the call site.
    let record: VideoRecord

    /// Parent folder picked in the options sheet; the ripper creates
    /// "<videoStem>-allframes/" inside it.
    let destinationParent: URL

    /// One ripper instance per job — never shared, never reused.
    let ripper = AllFramesRipper()

    /// Pause: OFF for frame export — see header note.
    let canPause = false

    /// Tracked explicitly — never inferred from the ripper's
    /// statusText (string-sniffing state is how subtle bugs happen).
    @Published private(set) var wasCancelled = false

    /// Non-nil while queued behind another job on a gated volume.
    @Published private(set) var waitingForVolumeLabel: String?

    /// The run Task — owned by the job (see header note). Internal so
    /// tests can `await job.task?.value` to reach the terminal state.
    private(set) var task: Task<Void, Never>?

    /// Re-publish the ripper's @Published changes as our own so the
    /// row view re-renders on progress.
    private var ripperForwarder: AnyCancellable?

    private let gates: [MediaVolumeGate]
    private let options: AllFramesRipper.Options

    // MARK: Init / start

    init(record: VideoRecord,
         destinationParent: URL,
         gates: [MediaVolumeGate],
         options: AllFramesRipper.Options) {
        self.record = record
        self.destinationParent = destinationParent
        self.gates = gates
        self.options = options
        ripperForwarder = ripper.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// Start the export. Idempotent — a second call is a no-op.
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            await self.runHoldingGates(self.gates[...])
        }
    }

    /// Acquire each gate in order (recursing so `withPermit` can
    /// guarantee release even on cancellation), then run the ripper
    /// while holding all of them. Single source file ⇒ at most one
    /// gate today, but the recursion matches ExtractFramesJob so the
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
        fileOpsLog.info("ripFrames \(self.id, privacy: .public) waiting for \(gate.root, privacy: .public)")
        do {
            try await gate.semaphore.withPermit { [weak self] in
                await self?.runHoldingGates(remaining.dropFirst())
            }
        } catch {
            // Only CancellationError escapes withPermit here (the body
            // doesn't throw) — the user cancelled while we were queued.
            waitingForVolumeLabel = nil
            fileOpsLog.info("ripFrames \(self.id, privacy: .public) cancelled while waiting for \(gate.root, privacy: .public)")
        }
    }

    private func logCompletion() {
        switch state {
        case .finished(let summary):
            fileOpsLog.info("ripFrames finished: \(self.record.filename, privacy: .public) — \(summary, privacy: .public) in \(self.ripper.completedDestination?.path ?? "?", privacy: .public)")
        case .failed(let message):
            fileOpsLog.error("ripFrames failed: \(self.record.filename, privacy: .public) — \(message, privacy: .public)")
        case .cancelled:
            fileOpsLog.info("ripFrames cancelled: \(self.record.filename, privacy: .public) — \(self.ripper.framesWritten) frame(s) kept on disk (\(self.ripper.bytesWritten) bytes)")
        default:
            break
        }
    }

    // MARK: MediaFileOperationJob

    var title: String { record.filename }

    var subtitle: String {
        if let label = waitingForVolumeLabel {
            return "Waiting for \(label)…"
        }
        switch state {
        case .failed(let message):
            return message
        case .finished:
            if let dest = ripper.completedDestination {
                return "Saved \(ripper.framesWritten.formatted()) frame(s), \(Formatting.humanSize(ripper.bytesWritten)) → \(dest.path)"
            }
            return "Done"
        case .cancelled:
            // Cancel never deletes output — anything already written is
            // kept, and the row says so explicitly (with the size, since
            // disk usage is this verb's whole risk profile).
            if ripper.framesWritten > 0, let dest = ripper.completedDestination {
                return "Stopped — \(ripper.framesWritten.formatted()) frame(s) (\(Formatting.humanSize(ripper.bytesWritten))) kept in \(dest.lastPathComponent)"
            }
            return "Stopped — no frames written"
        case .cancelling:
            return "Stopping…"
        case .running:
            return ripper.statusText.isEmpty ? "Starting…" : ripper.statusText
        }
    }

    /// Single-phase fraction: ffmpeg writes frames monotonically, so
    /// frames-written over the sheet's estimate is the whole story.
    /// Clamped — the estimate can undershoot on VFR sources.
    var fraction: Double {
        guard let total = ripper.options.estimatedFrames, total > 0 else { return 0 }
        return min(1.0, Double(ripper.framesWritten) / Double(total))
    }

    /// Indeterminate while queued for a volume slot, or for the whole
    /// run when duration/frame-rate metadata was missing (no estimate
    /// to divide by).
    var isIndeterminate: Bool {
        waitingForVolumeLabel != nil || ripper.options.estimatedFrames == nil
    }

    /// Derived from ripper state + the explicit cancel flag.
    /// Precedence mirrors ExtractFramesJob: an error that landed before
    /// cancel wins; a successful destination only counts as finished
    /// when the user didn't cancel (a cancelled export also sets
    /// `completedDestination` so Reveal works on the partial output).
    var state: MediaFileOperationState {
        if let error = ripper.lastError {
            return .failed(message: error)
        }
        if wasCancelled {
            return ripper.isRunning ? .cancelling : .cancelled
        }
        if ripper.completedDestination != nil {
            return .finished(summary: "\(ripper.framesWritten.formatted()) frame\(ripper.framesWritten == 1 ? "" : "s"), \(Formatting.humanSize(ripper.bytesWritten))")
        }
        return .running
    }

    func cancel() {
        guard state.isActive, !wasCancelled else { return }
        wasCancelled = true
        // Mirror the ripper's own cancel UX flag so its statusText
        // stays coherent; the actual stop is the task cancel reaching
        // the ffmpeg SIGTERM in the cancellation handler.
        ripper.markCancelling()
        task?.cancel()
        fileOpsLog.info("ripFrames cancelled by user: \(self.title, privacy: .public)")
    }
}
