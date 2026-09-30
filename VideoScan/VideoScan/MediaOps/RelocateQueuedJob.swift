import Foundation

// MARK: - RelocateQueuedJob
//
// User-facing queue entry for the Relocate Volume feature. Each "I want
// to relocate <vol>" request becomes one of these. The queue runs them
// strictly serially — concurrent writes to one destination thrash the
// filesystem, concurrent reads from a single networked Mac Pro share
// one NIC, and concurrent catalog mutations race on the same in-memory
// model. From the user's perspective the appearance is parallel: kick
// off four runs and walk away to dinner.
//
// Naming note: there's an engine-level `RelocateJob` in
// `RelocateEngine.swift` that's per-file. This is the per-volume
// queue-level job — qualified as "Queued" to keep the two from
// colliding. (Swift's namespace ≈ a C++ class scope; both types are
// top-level here, so a name suffix is the disambiguator.)
//
// Access level matches the rest of the Relocate stack (internal).
// See docs/relocate_volume_plan.md §3 (Relocate Job Queue).

/// Lifecycle of one queued relocate. The states are strictly monotonic
/// in the happy path: queued → reconciling → copying → awaitingDone →
/// complete. Failure can short-circuit from any state to .failed; a
/// .queued job can be canceled, but a running job runs to completion
/// (no mid-copy abort in v1).
enum RelocateJobStatus: Equatable, Sendable {
    /// Waiting in the queue. Cancelable.
    case queued
    /// Reconcile + snapshot phase. Not yet touching the destination.
    case reconciling
    /// Per-file copy phase active. `copyProgress` carries the live
    /// (done/total/currentFile/bytes) tick.
    case copying
    /// Reconcile + copy finished; summary sheet is up. The user has not
    /// yet dismissed it. Queue is paused here so the next job doesn't
    /// race the user's eyeballs.
    case awaitingDone
    /// Summary acknowledged. Terminal.
    case complete
    /// Hit a fatal error somewhere. The reason is the rendered display
    /// string from `RelocateError` or the underlying NSError.
    case failed(reason: String)
    /// Removed before it started. Terminal.
    case canceled
}

/// One row in `VideoScanModel.relocateQueue`. Identifiable so SwiftUI's
/// ForEach can bind directly; Equatable so .onChange observers fire
/// only on actual change. Not Sendable — `summary` and `copyProgress`
/// mutate on @MainActor.
struct RelocateQueuedJob: Identifiable, Equatable {
    let id: UUID
    /// Absolute path of the source volume root, e.g. "/Volumes/Mini2TB".
    /// Same value that flows into `RelocateOptions.sourceVolumeRootPath`.
    let sourceVolumeRootPath: String
    /// Pre-resolved display name — "Mini2TB". Captured at enqueue time
    /// so the panel can render even after the volume has unmounted.
    let sourceVolumeName: String
    /// Destination directory. Matches `RelocateOptions.destinationRoot`.
    let destinationRoot: URL
    /// Full options blob — replayed verbatim into `runRelocate` when the
    /// job's turn arrives. Captured so a user toggling defaults mid-queue
    /// doesn't retroactively change earlier jobs.
    let options: RelocateOptions
    /// When the user clicked Run/Add to Queue. Used to order the panel.
    let enqueuedAt: Date
    /// Wall-clock start of the reconcile phase. nil while .queued.
    var startedAt: Date?
    /// Set when status flips to .complete / .failed / .canceled. Drives
    /// the "elapsed" display on completed rows.
    var completedAt: Date?
    var status: RelocateJobStatus
    /// Post-flight summary payload. Set once status reaches
    /// .awaitingDone and persists through .complete so the panel's
    /// "Show summary" context-menu action has data to surface.
    var summary: RelocateSummary?
    /// Live tick during the copy phase. nil outside .copying.
    var copyProgress: CopyProgress?

    /// Per-file progress snapshot. Written by the runner after each
    /// file copy lands (success or fail). Kept as a struct (not a
    /// stream) so SwiftUI re-renders only when the bar actually moves.
    struct CopyProgress: Equatable, Sendable {
        let done: Int
        let total: Int
        let currentFile: String
        let bytesCopied: Int64
    }

    init(
        id: UUID = UUID(),
        sourceVolumeRootPath: String,
        sourceVolumeName: String,
        destinationRoot: URL,
        options: RelocateOptions,
        enqueuedAt: Date = Date(),
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        status: RelocateJobStatus = .queued,
        summary: RelocateSummary? = nil,
        copyProgress: CopyProgress? = nil
    ) {
        self.id = id
        self.sourceVolumeRootPath = sourceVolumeRootPath
        self.sourceVolumeName = sourceVolumeName
        self.destinationRoot = destinationRoot
        self.options = options
        self.enqueuedAt = enqueuedAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.status = status
        self.summary = summary
        self.copyProgress = copyProgress
    }

    /// Convenience classifiers for the UI. Swift property-style
    /// predicate ≈ a const member function returning bool in C++.
    var isTerminal: Bool {
        switch status {
        case .complete, .failed, .canceled: return true
        default: return false
        }
    }

    var isInFlight: Bool {
        switch status {
        case .reconciling, .copying, .awaitingDone: return true
        default: return false
        }
    }

    /// Wall-clock seconds from start to completion. nil if not finished
    /// or never started.
    var elapsedSeconds: TimeInterval? {
        guard let started = startedAt, let done = completedAt else { return nil }
        return done.timeIntervalSince(started)
    }

    /// Human-friendly badge text — keep this in sync with the panel's
    /// status pill labels. Drives both the panel row pill and the
    /// notification body lines.
    var statusLabel: String {
        switch status {
        case .queued:        return "Queued"
        case .reconciling:   return "Reconciling"
        case .copying:       return "Running"
        case .awaitingDone:  return "Awaiting Done"
        case .complete:      return "Done"
        case .failed:        return "Failed"
        case .canceled:      return "Canceled"
        }
    }
}

// MARK: - RelocateOptions Equatable conformance for queue snapshotting

// `RelocateQueuedJob: Equatable` requires `RelocateOptions: Equatable`.
// Synthesis works because every field is already Equatable; the
// conformance is purely so SwiftUI's diffing logic can tell jobs apart.
extension RelocateOptions: Equatable {
    static func == (lhs: RelocateOptions, rhs: RelocateOptions) -> Bool {
        lhs.sourceVolumeRootPath == rhs.sourceVolumeRootPath
            && lhs.destinationRoot == rhs.destinationRoot
            && lhs.maxConcurrency == rhs.maxConcurrency
            && lhs.dryRun == rhs.dryRun
            && lhs.skipAlreadyRelocated == rhs.skipAlreadyRelocated
            && lhs.skipDupsOnOtherVolumes == rhs.skipDupsOnOtherVolumes
    }
}
