// PreviewSweepStatus.swift (VideoScanCore)
// The sweep's live status, lifted from PreviewSweepService so the Core
// engine can construct/publish it and the Stage-1 CLI can surface the same
// honest counts. UI-free (just strings + Foundation number formatting).

import Foundation

/// What the sweep is doing right now — drives the settings pane line and
/// the catalog's unobtrusive progress line. Counts are WORK ITEMS this
/// run (records that actually needed something), not the whole catalog —
/// honest numbers: a warm cache sweeps "3 of 12", not "17,398 of 17,401".
public enum PreviewSweepStatus: Equatable, Sendable {
    case idle
    case planning
    case sweeping(done: Int, total: Int)
    case pausedForInteraction(done: Int, total: Int)
    case pausedForThermal(done: Int, total: Int)
    /// Stopped honestly: cache bytes (existing + written) reached the
    /// 2 GB cap — continuing would just thrash the prune.
    case cacheFull(done: Int, total: Int)
    /// ready = eligible records with a best still on disk when the run
    /// ended; unpreviewable = known + fresh genuine failures; deferred =
    /// records this run didn't finish (volume vanished mid-run, ffmpeg
    /// missing, or a path an interactive rip owned). A `deferred` count
    /// keeps the tally honest — ready + unpreviewable no longer has to
    /// equal the eligible total (QA MINOR-5, 2026-07-27); deferred
    /// records are picked up by the next replan.
    case done(ready: Int, unpreviewable: Int, deferred: Int)

    /// Friendly-family language (no surveillance terms), one line.
    public var displayText: String {
        switch self {
        case .idle:
            return ""
        case .planning:
            return "Preview sweep: checking what's needed…"
        case .sweeping(let done, let total):
            return "Preview sweep: \(done.formatted()) of \(total.formatted())"
        case .pausedForInteraction(let done, let total):
            return "Preview sweep: \(done.formatted()) of \(total.formatted()) · paused while you browse"
        case .pausedForThermal(let done, let total):
            return "Preview sweep: \(done.formatted()) of \(total.formatted()) · paused to keep the Mac cool"
        case .cacheFull(let done, let total):
            return "Preview sweep stopped at \(done.formatted()) of \(total.formatted()) — preview storage is full (2 GB limit)"
        case .done(let ready, let unpreviewable, let deferred):
            var line = "Previews are fresh — \(ready.formatted()) ready"
            if unpreviewable > 0 { line += ", \(unpreviewable.formatted()) unpreviewable" }
            if deferred > 0 { line += ", \(deferred.formatted()) deferred" }
            return line
        }
    }
}
