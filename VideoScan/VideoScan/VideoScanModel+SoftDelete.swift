import Foundation

// MARK: - Soft-delete (Remove from Catalog)
//
// Mirrors the POI delete pattern (see PersonFinderModel.deletePOI +
// POIStorage.trashPOIFolder). Differences from POI:
//  - The "trash" is the catalog itself: setting purgedAt=Date() hides
//    the row from the default view; files on disk are untouched.
//  - Undo restores the *batch* (right-click on a multi-select), not
//    just a single record — Rick wants one Cmd-Z to walk back the
//    whole "Remove from Catalog" action.
//  - There is no on-disk .trash/ folder to clean up — recovery is
//    free, the purged rows live in catalog.json forever until the
//    user explicitly restores them.
//
// Session-scope undo: app relaunch drops the banner state, exactly
// like the POI banner. Only ONE undo target at a time — a second
// purge supersedes the first (the first batch stays purged but is no
// longer one-tap recoverable; the user can still flip "Show removed"
// and right-click → Restore).
//
// Stored @Published properties (lastPurgedBatch, lastPurgeUndoError)
// stay in the main class — extensions can't add stored properties.
// The methods that mutate them live here.

extension VideoScanModel {

    /// Snapshot of the most recent purge. Holds the affected record IDs so
    /// undo can flip them back. Includes the timestamp written into each
    /// record's purgedAt for diagnostics.
    struct LastPurgedBatch: Equatable {
        let ids: [UUID]         // records whose purgedAt we set
        let timestamp: Date     // value we wrote into purgedAt
    }

    /// Mark the given record IDs as purged. Sets `purgedAt = now` on every
    /// match, persists, and arms the undo banner with the affected IDs.
    /// Returns the count actually mutated (records already purged are not
    /// double-stamped, and bogus IDs are silently ignored).
    /// Announce an in-place mutation of purge/lifecycle state that changes
    /// NO array count and arms NO undo banner (#160). The Catalog table,
    /// volume aggregates, and the memo keys in CatalogHelpers all observe
    /// `volumeAggregatesRevision`; before this, `deleteConfirmedJunk` and
    /// `discardWorkbench` stamped `purgedAt` and published nothing, so the
    /// cached table kept showing rows for files that were already gone.
    /// Every path that flips purgedAt / lifecycleStage / setAsideReason /
    /// supersededByID outside the banner-armed purge/tidy/confirm flows
    /// must call this after its batch.
    func noteCatalogRecordsMutated() {
        notifyVolumeAggregatesStale()
    }

    @discardableResult
    func purgeRecords(ids: Set<UUID>) -> Int {
        guard !ids.isEmpty else { return 0 }
        let now = Date()
        var changed: [UUID] = []
        for rec in records where ids.contains(rec.id) && rec.purgedAt == nil {
            rec.purgedAt = now
            changed.append(rec.id)
        }
        guard !changed.isEmpty else { return 0 }
        saveCatalogDebounced()
        // Arm the undo banner. Supersedes any previous batch (matches POI
        // single-target undo semantics). The previous batch stays purged
        // and can still be recovered via Show Removed → right-click → Restore.
        lastPurgedBatch = LastPurgedBatch(ids: changed, timestamp: now)
        lastPurgeUndoError = nil
        return changed.count
    }

    /// Pure selector: IDs of active (non-purged) records that are extensionless
    /// AND ffprobe couldn't identify as media — the data-blob noise the
    /// "Scan Files With No Extension" pass can sweep in (Lightroom previews,
    /// Photos/FCP/Logic/GarageBand caches, Quicken data, app binaries, MIDI…).
    /// Same predicate as the scan-time drop (shouldCatalogProbeResult), applied
    /// retroactively to clean a catalog populated before that drop existed.
    nonisolated static func unreadableExtensionlessIDs(in records: [VideoRecord]) -> [UUID] {
        records.compactMap { rec in
            guard rec.purgedAt == nil,
                  !shouldCatalogProbeResult(ext: rec.ext, streamTypeRaw: rec.streamTypeRaw)
            else { return nil }
            return rec.id
        }
    }

    /// Soft-delete (reversible) every active record that is extensionless and
    /// unreadable by ffprobe. Files on disk are untouched; rows are hidden from
    /// the default view and recoverable via Show Removed → Restore or the undo
    /// banner. Returns the count removed.
    @discardableResult
    func softDeleteUnreadableExtensionless() -> Int {
        purgeRecords(ids: Set(Self.unreadableExtensionlessIDs(in: records)))
    }

    /// Clear `purgedAt` on a single record. Used by the right-click menu
    /// on a purged row when "Show removed" is on. Returns true on success.
    @discardableResult
    func restoreRecord(id: UUID) -> Bool {
        guard let rec = records.first(where: { $0.id == id }),
              rec.purgedAt != nil else { return false }
        rec.purgedAt = nil
        CorrelationScorer.revalidateExistingPairs(in: records)
        saveCatalogDebounced()
        // If the user manually restores a record from the most recent
        // purge batch, drop it from the undo set so the banner's "Undo"
        // doesn't no-op or surface a confusing partial restore later.
        if var snap = lastPurgedBatch {
            snap = LastPurgedBatch(
                ids: snap.ids.filter { $0 != id },
                timestamp: snap.timestamp
            )
            if snap.ids.isEmpty {
                lastPurgedBatch = nil
                lastPurgeUndoError = nil
            } else {
                lastPurgedBatch = snap
            }
        }
        return true
    }

    /// Restore the most recently purged batch. Returns true if at least
    /// one record was un-purged. Drops the banner on success or when the
    /// batch has nothing left to restore (all records already deleted /
    /// already restored manually).
    @discardableResult
    func undoLastPurge() -> Bool {
        guard let snap = lastPurgedBatch else { return false }
        var restored = 0
        for id in snap.ids {
            if let rec = records.first(where: { $0.id == id }),
               rec.purgedAt != nil {
                rec.purgedAt = nil
                restored += 1
            }
        }
        if restored == 0 {
            // Everything in the batch is gone (e.g. user deleted the
            // catalog or restored records manually). Drop the banner —
            // nothing to undo.
            lastPurgedBatch = nil
            lastPurgeUndoError = nil
            return false
        }
        CorrelationScorer.revalidateExistingPairs(in: records)
        saveCatalogDebounced()
        lastPurgedBatch = nil
        lastPurgeUndoError = nil
        return true
    }

    /// Dismiss the undo banner without restoring. The purged records
    /// stay hidden in the default view — only the one-tap undo affordance
    /// goes away. They remain recoverable via "Show removed" → right-click
    /// → Restore.
    func dismissPurgeUndoBanner() {
        lastPurgedBatch = nil
        lastPurgeUndoError = nil
    }

    /// Drop the undo banner state. Called by catalog-wide mutations that
    /// reseed `records` wholesale (deleteAllCatalog, deleteCatalogForTarget,
    /// clearResults) — once the target rows are gone, the banner's "Undo"
    /// would no-op anyway, and leaving the banner armed would mislead the
    /// user into thinking their delete is reversible. Cheap idempotent reset.
    func clearPurgeUndoState() {
        lastPurgedBatch = nil
        lastPurgeUndoError = nil
    }
}
