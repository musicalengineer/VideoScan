// CaptionPipelineTypes.swift
// Value types describing the caption pipeline's status and live activity
// state. Extracted from CaptionOrchestrator.swift (Rick 2026-06-15) —
// these were declared at file scope (NOT inside the orchestrator class),
// referenced from DossierDashboardView and the orchestrator's public
// surface. Moving them is pure file organization: zero visibility
// change (all default-internal), zero behavior change.
//
// CaptionOrchestrator.swift dropped from 1847 → ~1740 lines after this
// move. Next safe extraction would be the auto-resume + shutdown
// section as a cross-file extension, but that requires widening
// several `private` members to `internal` — deliberate visibility leak
// that needs your eyes on it.

import Foundation

// MARK: - Status

/// Per-batch status. Mirrors ScanJobStatus's shape: an enum with
/// associated values for the in-flight payload (progress, current
/// file, ETA) and a terminal `.finished` carrying counts.
///
/// Swift's enum-with-associated-values ≈ a C++ tagged union /
/// std::variant; SwiftUI views switch on the case and read payload by
/// pattern match.
enum CaptionJobStatus: Equatable {
    case idle
    case running(progress: Double, currentFile: String, etaSec: Int?)
    case cancelling
    case finished(captioned: Int, skipped: Int, failed: Int)

    /// Convenience used by the UI to disable the start button while
    /// any prior batch is mid-flight.
    var isActive: Bool {
        switch self {
        case .running, .cancelling: return true
        default: return false
        }
    }

    /// True while the orchestrator is doing real work. Used by the
    /// progress sheet to show / hide.
    var isInFlight: Bool {
        switch self {
        case .running, .cancelling: return true
        default: return false
        }
    }
}

// MARK: - Live pipeline activity (dashboard feed)
//
// Feeds the Dossier Dashboard's "Now Analyzing" / "Recently Completed"
// panels. Stage names are plain data-driven strings derived from the
// engines' modelIDs — deliberately NOT an enum, so future stages
// (FancyAlg2/3...) show up on the dashboard just by reporting in with
// their own name. No dashboard change needed when a stage is added.

/// One in-flight file. A lane is opened when the file enters the
/// pipeline and closed when it finishes (success, failure, or skip).
/// Stage transitions (VLM → Whisper) mutate `stageName`/`verb` in
/// place rather than spawning a new lane — that way the dashboard
/// shows one row per file and per-channel checkmarks (`hasCaptions`,
/// `hasTranscript`) light up as each stage banks its result.
struct PipelineLane: Identifiable, Equatable {
    let id: UUID
    /// Absolute path — used as the dedup key (one lane per path).
    let path: String
    let filename: String
    /// Short stage family currently running on this file, e.g.
    /// "MLXVLM", "Whisper". Mutates as the pipeline advances.
    var stageName: String
    /// Present-tense action for the stage line, e.g. "extracting scenes…".
    var verb: String
    /// When THIS file entered the pipeline — the dashboard derives the
    /// live "(Ns)" elapsed readout from this. Deliberately NOT reset on
    /// stage transitions so the elapsed counter shows total time on the
    /// file, not just time in the current stage.
    let startedAt: Date
    /// True when the file's stream type is video-only (no audio stream).
    /// The dashboard renders the Audio Transcript indicator as a gray
    /// dash when this is set, regardless of `hasTranscript`/`transcriptFailed`.
    let isVideoOnly: Bool
    /// True once the VLM successfully extracted scene captions for this
    /// file. The dashboard shows a green check; otherwise a red X.
    var hasCaptions: Bool
    /// True once Whisper successfully produced a transcript. Mutually
    /// exclusive in practice with `transcriptFailed`. Gray dash overrides
    /// both when `isVideoOnly`.
    var hasTranscript: Bool
    /// True when Whisper was attempted and threw. Distinguishes "we
    /// tried and failed" (red X) from "not yet" (also red X today but
    /// could become a spinner later) and from "no audio at all"
    /// (gray dash via `isVideoOnly`).
    var transcriptFailed: Bool
}

/// A file that finished the full pipeline and was synced to the catalog.
struct CompletedActivity: Identifiable, Equatable {
    let id: UUID
    let filename: String
    /// Full path — the dedup key for Show in Catalog navigation.
    /// Without this, filename-based lookup picks the first record
    /// matching `filename`, which is wrong for duplicates (e.g.
    /// `_combined.mov` files produced per-volume share the same leaf
    /// name across drives). Rick 2026-06-13 caught this on a
    /// `00005.V14D1BBE8B_combined.mov` whose Show in Catalog jumped
    /// to a sibling with no captions, making the dashboard look like
    /// it was lying.
    let path: String
    /// Wall-clock seconds the VLM dossier extraction took. nil only if
    /// the stage didn't run (not the case today, but the field is
    /// optional so future stages can report partial pipelines).
    let vlmSeconds: Double?
    /// Wall-clock seconds Whisper took. nil when no transcript was
    /// produced (no transcriber, audio-less file, or Whisper failure).
    let whisperSeconds: Double?
    /// Inline caveat, e.g. "no transcript". nil for clean runs.
    let note: String?
    /// When the result landed in the catalog (applyDossier).
    let syncedAt: Date
    /// Per-channel indicator state. Moved off the active lane row
    /// (Rick 2026-06-13: the indicators belong with the completed
    /// summary, not while the file is still in flight) and mirrored
    /// from the lane's final state at endLane time. Same three-state
    /// semantics as the lane:
    ///   - Captions: green ✓ when extraction.scenes was non-empty;
    ///     red ✗ otherwise.
    ///   - Audio Transcript: green ✓ when transcript trimmed to
    ///     non-empty; gray — when isVideoOnly; red ✗ otherwise.
    let isVideoOnly: Bool
    let hasCaptions: Bool
    let hasTranscript: Bool
    let transcriptFailed: Bool
}
