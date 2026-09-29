import Foundation

extension VideoScanModel {

    // MARK: - Archive State Mutation
    //
    // VideoRecord is a class, so mutating a property in-place (`rec.foo = x`)
    // changes the in-memory instance but does NOT trigger the debounced
    // catalog save. ArchiveView used to do exactly that for the five
    // lifecycle buttons and addBackup, which is why archive disposition
    // sometimes vanished across app launches — the change persisted only
    // when an unrelated mutation elsewhere happened to fire a save before
    // quit. Always go through these helpers when mutating archive state
    // from the UI so the save is bundled with the mutation.

    /// Set `archiveStage` on every record in `recs` and persist synchronously.
    /// Uses `saveCatalogNow` (not the debounced variant) because these are
    /// explicit one-shot user actions — if the user clicks "Mark Archived"
    /// and quits half a second later, the change must already be on disk.
    func setArchiveStage(_ stage: ArchiveStage, for recs: [VideoRecord]) {
        for rec in recs { rec.archiveStage = stage }
        saveCatalogNow()
    }

    /// Append `entry` to each record's `backupDestinations` (dedup by name),
    /// auto-advance `archiveStage` to at least `.backedUp`, and persist
    /// synchronously (see `setArchiveStage` for rationale).
    func addBackup(_ entry: BackupEntry, to recs: [VideoRecord]) {
        for rec in recs {
            if !rec.backupDestinations.contains(where: { $0.name == entry.name }) {
                rec.backupDestinations.append(entry)
            }
            if rec.archiveStage < .backedUp {
                rec.archiveStage = .backedUp
            }
        }
        saveCatalogNow()
    }
}
