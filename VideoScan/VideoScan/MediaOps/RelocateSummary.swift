import Foundation

// MARK: - RelocateSummary
//
// Payload for the post-Apply summary sheet. Captures everything the user
// needs to feel "convinced the media is properly accounted for" before
// the §1B Retire prompt can fire. See docs/design/relocate_volume_plan.md.
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
    /// on a safe host volume (not retired AND trust != .unreliable).
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

    /// Bucket B rows the catalog refused to mark (held / read-only) —
    /// left unmarked; the next Reconcile asks again. Defaulted so the
    /// memberwise init keeps its historical shape.
    var notMarkedCount: Int = 0
    /// Bucket B rows whose file was still at its path (or could not be
    /// checked) when Migrate went to mark it "source not found" — left
    /// unmarked and not copied (adversarial 2026-10-19).
    var stillThereCount: Int = 0

    /// Of `safelyRedundantCount`, the files whose backup copy is PROVEN now
    /// (`ContentCopyProof`): a witness on a safe drive that is not marked
    /// Aging, holding the same whole-file SHA-256 on record as the source,
    /// and both stored stamps still describe their files (live stat). The
    /// partial-MD5 match that put a file in Bucket E is not proof
    /// (Codex #150 F1). Defaulted so the memberwise init keeps its shape.
    var provenBackupCount: Int = 0

    /// Backed-up files whose copy is not proven (see `provenBackupCount`):
    /// no full SHA-256 on record, the copy or the source changed since it
    /// was hashed, or the only copies are on aging, retired or unreliable
    /// drives (Codex #150 F1, F5). Includes `degradedOnlyCount`.
    var unprovenBackupCount: Int { max(0, safelyRedundantCount - provenBackupCount) }

    /// Files this run left WITHOUT proof: the copy failed, the file was still
    /// at its path (or could not be checked), the catalog could not mark it,
    /// it was marked missing from the source (no copy proven anywhere —
    /// Codex #150 F2), or its backup is not proven. The buckets are disjoint
    /// (A-failed, B-refused, B-present/unchecked, B-missing, E-unproven).
    /// Any of them > 0 withholds "safe" and "retire".
    var needsAttentionCount: Int {
        salvageFailedCount + stillThereCount + notMarkedCount + manuallyDeletedCount + unprovenBackupCount
    }

    /// One source-to-witness pairing. Carries the host volume's
    /// role + trust so the summary sheet can render the safety badge
    /// without having to query the model.
    struct WitnessSample: Equatable, Identifiable {
        let id = UUID()
        let sourcePath: String
        let witnessPath: String
        let witnessRole: VolumeRole
        let witnessTrust: VolumeTrust
        /// Host volume retired (`retiredAt` stamped) — a shelved disk
        /// renders demoted no matter its role. Defaulted so the memberwise
        /// init keeps its historical shape.
        var witnessIsRetired: Bool = false

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
            VolumeSafety(role: witnessRole, trust: witnessTrust, isRetired: witnessIsRetired).isSafe
        }
    }
}

// MARK: - RelocateSummaryHeadline
//
// The summary sheet's headline as a pure value of the summary, so the words
// are testable without SwiftUI (adversarial 2026-10-26 F1, MOPS-6).
// (A value type with a converting init ≈ a C++ struct built by an explicit
// constructor from the payload.)

struct RelocateSummaryHeadline: Equatable {
    enum Tint: Equatable { case blue, green, orange }

    let title: String
    let body: String
    /// SF Symbol name.
    let icon: String
    let tint: Tint
    /// May the sheet say "retire <drive>"? The Volumes-window line shows only when true.
    let invitesRetire: Bool

    init(_ s: RelocateSummary) {
        if s.isDryRun {
            title = "Dry-run preview"
            body = "If you ran this for real, here's what would happen."
            icon = "eye.fill"; tint = .blue; invitesRetire = false
            return
        }
        // "Safe" and "retire" only when this run proved every file: copied
        // and verified, or a copy proven by its full SHA-256 on a safe drive.
        // Any unproven file (copy failed, still at its path, not marked,
        // missing from the source, backup not proven) says so and never
        // invites a retire.
        let unproven = s.needsAttentionCount
        if unproven > 0 {
            title = "Some files are not proven safe yet"
            let done = s.succeededCount > 0
                ? Self.copiedLine(s)
                : "No files were copied." + Self.backedUpSentence(s, more: false)
            body = done + " \(unproven) " + (unproven == 1 ? "file is" : "files are")
                + " not proven safe yet — see the rows below. Keep \(s.sourceVolumeName) until "
                + (unproven == 1 ? "it is." : "they are.")
            icon = "exclamationmark.triangle.fill"; tint = .orange; invitesRetire = false
            return
        }
        let total = s.succeededCount + s.provenBackupCount
        if s.succeededCount > 0 {
            title = "Files copied and verified"
            body = Self.copiedLine(s)
            icon = "checkmark.seal.fill"; tint = .green; invitesRetire = true
            return
        }
        if total == 0 {
            // Nothing copied and nothing checked against a backup: this run
            // proved nothing, so it claims nothing.
            title = "Nothing was copied"
            body = "Nothing on \(s.sourceVolumeName) was copied or checked against a backup this time — see the counts below."
            icon = "info.circle"; tint = .blue; invitesRetire = false
            return
        }
        invitesRetire = true
        title = "Your files are safe"
        body = "I found backup copies of all \(total) file"
            + (total == 1 ? "" : "s")
            + " on safer drives, each matched by its full SHA-256 checksum. "
            + "Everything's accounted for — you can retire "
            + "\(s.sourceVolumeName) whenever you're ready."
        icon = "shield.checkered"; tint = .green
    }

    /// "I copied N files to D and verified the checksums. M more are already
    /// safely backed up on other drives."
    static func copiedLine(_ s: RelocateSummary) -> String {
        "I copied \(s.succeededCount) file"
            + (s.succeededCount == 1 ? "" : "s")
            + " to \(s.destinationDisplay) and verified the checksums."
            + backedUpSentence(s, more: true)
    }

    /// " M more are already backed up on other drives, matched by full
    /// SHA-256." ("" when none) — proven backups only.
    static func backedUpSentence(_ s: RelocateSummary, more: Bool) -> String {
        guard s.provenBackupCount > 0 else { return "" }
        return " \(s.provenBackupCount)" + (more ? " more " : " ")
            + (s.provenBackupCount == 1 ? "is" : "are")
            + " already backed up on other drives, matched by full SHA-256 checksum."
    }
}
