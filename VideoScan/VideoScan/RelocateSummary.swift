import Foundation

// MARK: - RelocateSummary
//
// Payload for the post-Apply summary sheet. Captures everything the user
// needs to feel "convinced the media is properly accounted for" before
// the §1B Retire prompt can fire. See docs/relocate_volume_plan.md.
//
// Two ways this summary is produced:
//   1. Real run: counts come from `dashboard.relocate*` after every
//      Bucket B/D/E mutation + per-record copy has completed.
//   2. Dry run: counts come straight from the `ReconcileResult` because
//      no mutations were applied (the dry-run gate now suppresses Bucket
//      B/D/E disposition writes too — see fix in `runRelocate`).
//
// Equatable so SwiftUI's `.sheet(item:)` re-evaluation behaves; Identifiable
// so we can drive the sheet binding directly off `pendingRelocateSummary`.

struct RelocateSummary: Identifiable, Equatable {
    let id = UUID()

    /// Was this a dry run (Rick was previewing)? Drives the sheet title
    /// and suppresses any retire offer follow-up.
    let isDryRun: Bool

    /// "Maxtor500FW" — pretty form taken from sourceVolumeRootPath's last
    /// path component, falling back to the full path if empty.
    let sourceVolumeName: String
    /// "/Volumes/Maxtor500FW" — the raw root that scoped the run.
    let sourceVolumeRootPath: String
    /// "LaCieWorkspace/from-Maxtor500" — the rendered destination, just
    /// the trailing two components for display. Full path lives in
    /// destinationRootPath.
    let destinationDisplay: String
    /// Full destination path. Clickable "show in Finder" links use this.
    let destinationRootPath: String

    // Counts — caller is expected to only present non-zero rows.
    let succeededCount: Int
    let bytesCopied: Int64
    let adoptedCount: Int
    let safelyRedundantCount: Int
    let safelyRedundantBytes: Int64
    let sourceMovesCount: Int
    let manuallyDeletedCount: Int
    let salvageFailedCount: Int
    let skippedCount: Int

    /// Per-path detail for the salvage-failed disclosure. Empty when the
    /// run had no failures. Capped on the producing side.
    let salvageFailedPaths: [String]

    /// Sample `source → witness` pairs, parsed from each Bucket E
    /// record's audit-trail note. Capped at 10 — enough to satisfy "show
    /// me a few examples" without ballooning the sheet. Full witness list
    /// stays in the catalog notes + relocate.log.
    let witnessSamples: [WitnessSample]

    /// Wall clock seconds for the entire run.
    let elapsedSeconds: Double

    /// `bytesCopied / elapsedSeconds` in MB/s. Zero when no copies
    /// happened.
    let averageMBps: Double

    /// Absolute path to the pre-relocate catalog snapshot, or nil if
    /// snapshotting failed (logged + we proceeded anyway).
    let snapshotPath: String?

    struct WitnessSample: Equatable, Identifiable {
        let id = UUID()
        let sourcePath: String
        let witnessPath: String
    }
}
