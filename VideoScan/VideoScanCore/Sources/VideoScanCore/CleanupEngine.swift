// CleanupEngine.swift
// The engine boundary for executing a CleanupRecipe — VideoScanCore.
//
// WHY THIS SEAM IS SHAPED THE WAY IT IS (design constraint, Rick-approved
// architecture 2026-07-07): v1 implements exactly one engine — a
// single-pass ffmpeg filtergraph renderer (app-side, CleanupFFmpegEngine)
// — but the protocol must also accommodate, WITHOUT changing shape:
//
//   (a) frame-level processors: decode → per-frame CoreML model (Zero-DCE
//       etc.) → encode. Such an engine does all of that inside `render`,
//       using `scratchDirectory` for frame dumps / intermediate encodes,
//       and reports progress through the same callback.
//   (b) multi-pass steps (vidstab detect/transform, two-pass encodes): an
//       engine runs N internal phases against the same scratch directory
//       (pass artifacts like vidstab's .trf live there) and reports
//       (passIndex, passCount) so the UI can say "Pass 1 of 2".
//   (c) external tools (Topaz Video AI CLI, tech not yet invented): the
//       contract is only "produce ONE finished file inside
//       scratchDirectory and return its URL" — how is the engine's
//       business.
//
// The CALLER (CleanupJob, app-side) owns everything around the render:
// output naming, collision handling, the atomic move next to the
// original, catalog registration, provenance stamping. Engines never
// touch the final destination — that's what makes "the file never
// appears half-written next to the original" a single-owner invariant.
//
// (For Rick: this is the classic C++ strategy-interface split — a pure
// virtual `render()` with the transactional commit kept in the caller.)

import Foundation

// MARK: - Source description

/// Everything an engine may consult about the input file. Built by the
/// caller from the catalog record's existing ffprobe metadata — engines
/// must NOT re-probe (the catalog already paid for that).
public struct CleanupSource: Sendable, Equatable {
    /// Absolute path of the original media file. Engines READ ONLY.
    public var path: String
    /// Duration in seconds (0 = unknown → indeterminate progress).
    public var durationSeconds: Double
    /// Raw ffprobe `field_order` value as stored in the catalog
    /// (`VideoRecord.scanType`): "progressive", "tt", "bb", "tb", "bt",
    /// "unknown", or "" when never probed. Drives the deinterlace
    /// auto-skip.
    public var fieldOrder: String
    /// Whether the source carries an audio stream (drives -map/copy).
    public var hasAudio: Bool

    public init(path: String,
                durationSeconds: Double,
                fieldOrder: String,
                hasAudio: Bool) {
        self.path = path
        self.durationSeconds = durationSeconds
        self.fieldOrder = fieldOrder
        self.hasAudio = hasAudio
    }
}

// MARK: - Progress

/// One progress beat from an engine. `fraction` is nil while a phase is
/// indeterminate. Multi-pass engines advance `passIndex`/`passCount`;
/// single-pass engines report 1 of 1.
public struct CleanupProgress: Sendable {
    /// Human-readable phase ("Rendering…", "Stabilize pass 1…").
    public var phase: String
    /// 0…1 within the CURRENT pass; nil = indeterminate.
    public var fraction: Double?
    /// 1-based index of the current pass.
    public var passIndex: Int
    /// Total passes this engine will run for this recipe.
    public var passCount: Int

    public init(phase: String, fraction: Double?, passIndex: Int = 1, passCount: Int = 1) {
        self.phase = phase
        self.fraction = fraction
        self.passIndex = passIndex
        self.passCount = passCount
    }
}

// MARK: - Errors

/// Engine-side failures. `renderFailed` carries a user-presentable reason.
public enum CleanupEngineError: Error, Equatable, Sendable {
    /// Required external tool not found (e.g. ffmpeg missing).
    case toolUnavailable(String)
    /// The recipe contains a step this engine cannot execute — callers
    /// should have checked `canExecute` first; this is the loud backstop.
    case unsupportedStep(CleanupStepKind)
    /// The render ran but produced no usable output.
    case renderFailed(String)
}

// MARK: - Engine protocol

/// Executes a recipe against one source file, producing ONE finished
/// media file inside `scratchDirectory`.
///
/// Contract:
///   - Engines never write anywhere except `scratchDirectory` and never
///     modify the source file.
///   - Cancellation: engines must honor Swift task cancellation (kill
///     subprocesses, stop frame loops) and throw `CancellationError` or
///     return promptly; partial scratch output is discarded by the caller
///     (it deletes the whole scratch directory).
///   - Progress: call `progress` from any thread; the caller hops to the
///     main actor itself.
public protocol CleanupRecipeEngine: Sendable {
    /// Stable identifier recorded in logs ("ffmpeg-filtergraph-v1").
    var engineID: String { get }

    /// Whether every ENABLED step of `recipe` is executable by this
    /// engine. Lets a future dispatcher route a mixed recipe to a more
    /// capable engine instead of failing mid-render.
    func canExecute(_ recipe: CleanupRecipe) -> Bool

    /// Render `recipe` applied to `source` into `scratchDirectory` and
    /// return the finished file's URL (inside that directory). Throws
    /// `CleanupEngineError` / `CancellationError` on failure.
    func render(recipe: CleanupRecipe,
                source: CleanupSource,
                scratchDirectory: URL,
                progress: @escaping @Sendable (CleanupProgress) -> Void) async throws -> URL
}
