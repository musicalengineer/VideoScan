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

    /// Subset of `safelyRedundantCount` whose top-ranked witness lives
    /// on a safe host volume (role != .retired AND trust != .unreliable).
    /// Drives the section header "<safelyBacked> · <degradedOnly>".
    /// Always ≤ `safelyRedundantCount`.
    let safelyBackedUpCount: Int
    /// `safelyRedundantCount - safelyBackedUpCount`. Records where the
    /// only witnesses were on retired/unreliable volumes — included for
    /// audit completeness but shown demoted.
    let degradedOnlyCount: Int

    /// Per-path detail for the salvage-failed disclosure. Empty when the
    /// run had no failures. Capped on the producing side.
    let salvageFailedPaths: [String]

    /// Sample `source → witness` pairs (top-ranked witness per source),
    /// extracted from each Bucket E record. Capped at 10 — enough to
    /// satisfy "show me a few examples" without ballooning the sheet.
    /// Full witness list stays in the catalog notes + relocate.log.
    let witnessSamples: [WitnessSample]

    /// Wall clock seconds for the entire run.
    let elapsedSeconds: Double

    /// `bytesCopied / elapsedSeconds` in MB/s. Zero when no copies
    /// happened.
    let averageMBps: Double

    /// Absolute path to the pre-relocate catalog snapshot, or nil if
    /// snapshotting failed (logged + we proceeded anyway).
    let snapshotPath: String?

    /// One source-to-witness pairing. Carries the host volume's
    /// role + trust so the summary sheet can render the safety badge
    /// without having to query the model.
    struct WitnessSample: Equatable, Identifiable {
        let id = UUID()
        let sourcePath: String
        let witnessPath: String
        let witnessRole: VolumeRole
        let witnessTrust: VolumeTrust

        /// "MyBook3Terabytes" — leading path component of the witness for
        /// display. Mirrors `VolumeReachability.volumeName(forPath:)` but
        /// keeps the struct self-sufficient (no side-on resolver needed
        /// at render time).
        var witnessVolumeLabel: String {
            let comps = (witnessPath as NSString).pathComponents
            if comps.count >= 3, comps[1] == "Volumes" { return comps[2] }
            if comps.count >= 3, comps[1] == "Users" { return comps[2] }
            if comps.count >= 3 { return comps[1] }
            return (witnessPath as NSString).deletingLastPathComponent
        }

        /// "Safe enough to display un-demoted." Mirrors
        /// `SafeWitnessInfo.isSafe` so the summary sheet doesn't pull in
        /// the reconcile module just to compute the same predicate.
        var isSafe: Bool {
            witnessRole != .retired && witnessTrust != .unreliable
        }
    }
}
