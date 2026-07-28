// PreviewSweepOutcome.swift (VideoScanCore)
// The per-item result value + the executor function type, lifted from the
// app's PreviewSweepService so the sweep engine (Core) and the default
// executor (Core) — and, Stage 1, the CLI — share one contract. The
// executor CLASSIFIES; the engine applies the failure-store rule and the
// counters. That split is what lets tests inject a scripted executor.

import Foundation

/// What one work item's execution produced.
public struct PreviewSweepItemOutcome: Sendable, Equatable {
    public var bytesWritten: Int64 = 0
    /// A best-tier still is on disk for this record after this item.
    public var stillReady = false
    /// The still generation failed for reasons that ARE facts about the
    /// file (decode failure on a reachable volume). The ONLY flag that
    /// reaches ThumbnailFailureStore.
    public var stillFailedGenuinely = false
    /// Volume went away / file vanished mid-run — no verdict, no record.
    public var skippedUnreachable = false
    /// ffmpeg missing — an environment fact, never a file verdict. Also
    /// makes the sweep stop attempting further ffmpeg-routed items.
    public var environmentFailure = false
    /// Strip generation failed but the still is fine. Never poisons the
    /// failure store (same rule as the filmstrip prewarm).
    public var stripFailed = false

    public init(bytesWritten: Int64 = 0,
                stillReady: Bool = false,
                stillFailedGenuinely: Bool = false,
                skippedUnreachable: Bool = false,
                environmentFailure: Bool = false,
                stripFailed: Bool = false) {
        self.bytesWritten = bytesWritten
        self.stillReady = stillReady
        self.stillFailedGenuinely = stillFailedGenuinely
        self.skippedUnreachable = skippedUnreachable
        self.environmentFailure = environmentFailure
        self.stripFailed = stripFailed
    }
}

/// The per-item work function. Throws ONLY CancellationError; everything
/// else is classified into the outcome.
public typealias PreviewSweepExecutor =
    @Sendable (PreviewSweepWorkItem) async throws -> PreviewSweepItemOutcome
