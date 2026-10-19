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
    ///
    /// Rules v13 (QA MAJOR-1, 2026-09-26): the Archive Angel hears it too.
    /// A footage regroup, a footage decision, a Master Archive designation
    /// change or a lifecycle flip is a CATALOG change the coverage rules
    /// read (the per-year backlog, the archived set), and only the
    /// `records` didSet reached `archiveAngel.catalogChanged()` before.
    /// O(1): an integer bump and two debounced schedules.
    func noteCatalogRecordsMutated() {
        notifyVolumeAggregatesStale()
        archiveAngel.catalogChanged()
    }

    @discardableResult
    func purgeRecords(ids requestedIDs: Set<UUID>) -> Int {
        guard !requestedIDs.isEmpty else { return 0 }
        // Master Archive files are never bulk-purged — and (Rick
        // 2026-09-22: "For now we won't Remove anything from
        // FamilyArchive") neither is anything else on the archive's
        // VOLUME, even though Remove only touches the catalog.
        let ids = Set(excludingMasterArchiveFiles(requestedIDs.compactMap { record(forID: $0) },
                                                  verb: "Remove", effect: .catalogRemoval).map(\.id))
        guard !ids.isEmpty else { return 0 }
        let now = Date()
        var changed: [UUID] = []
        var refused: [String] = []
        for rec in records where ids.contains(rec.id) && rec.removal == nil {
            // GH #143: the one marker. B2.3: the catalog may refuse (held,
            // read-only) — that row stays exactly as it was.
            if let why = Self.stampRemoval(rec, .removedFromCatalog(at: now, reason: .userRemoved)) {
                refused.append(why)
                continue
            }
            changed.append(rec.id)
        }
        if let first = refused.first {
            log("Remove from Catalog: left \(refused.count) row(s) as they were — \(first)")
        }
        guard !changed.isEmpty else { return 0 }
        saveCatalogDebounced()
        // Arm the undo banner. Supersedes any previous batch (matches POI
        // single-target undo semantics). The previous batch stays purged
        // and can still be recovered via Show Removed → right-click → Restore.
        lastPurgedBatch = LastPurgedBatch(ids: changed, timestamp: now)
        lastPurgeUndoError = nil
        // Media Ledger (stage 2): "You removed it from the catalog on …"
        // — the file is untouched, so this is a set-aside-shaped line.
        ledgerSetAside(changed.compactMap { record(forID: $0) }, reason: "removed-from-catalog", by: .rick, at: now)
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

    /// A restored row is LIVE again — through the engine (`clearRemoval`,
    /// GH #143), which refuses while the file is still in the Trash (or
    /// gone) and leaves the marker untouched (codex round 1 F2). Returns
    /// whether the row went live; one line says what to do when it did not.
    private func returnToLive(_ rec: VideoRecord) -> Bool {
        guard let line = clearRemoval(rec) else { return true }
        log(line)
        return false
    }

    /// Clear `purgedAt` on a single record. Used by the right-click menu
    /// on a purged row when "Show removed" is on. Returns true on success.
    @discardableResult
    func restoreRecord(id: UUID) -> Bool {
        guard let rec = record(forID: id),
              rec.purgedAt != nil,
              returnToLive(rec) else { return false }   // no "restored" save or ledger line on a refusal
        CorrelationScorer.revalidateExistingPairs(in: records)
        saveCatalogDebounced()
        ledgerRestored([rec], by: .rick)
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
    /// one record was un-purged. Drops the banner when every row still in
    /// the batch went live, or when the batch has nothing left to restore
    /// (all records already deleted / already restored manually).
    ///
    /// A row the catalog REFUSES to restore (cutover B2.3: catalog.sqlite
    /// held by a job, read-only, being reopened) stays in the batch and the
    /// banner stays up with the refusal's words in `lastPurgeUndoError`, so
    /// Undo can be pressed again when the catalog can save (adversarial
    /// review 2026-10-18 #10: the banner used to vanish with nothing
    /// restored and no word on screen).
    @discardableResult
    func undoLastPurge() -> Bool {
        guard let snap = lastPurgedBatch else { return false }
        var restoredRecs: [VideoRecord] = []
        var refusedIDs: [UUID] = []
        var firstRefusal: String?
        // The id index, not a linear search per id: undoing a 10k-row
        // Remove over a 100k catalog was O(n·m) — ~25 s on the M4 (GH #143
        // scale test). (≈ a hash-map lookup instead of std::find per key.)
        for id in snap.ids {
            guard let rec = record(forID: id), rec.purgedAt != nil else { continue }   // gone / already restored
            if let why = clearRemoval(rec) {
                refusedIDs.append(id)
                if firstRefusal == nil { firstRefusal = why }
            } else {
                restoredRecs.append(rec)
            }
        }
        if let firstRefusal {
            log("Undo Remove from Catalog: \(refusedIDs.count) row(s) left removed — \(firstRefusal)")
        }
        if !restoredRecs.isEmpty {
            CorrelationScorer.revalidateExistingPairs(in: records)
            saveCatalogDebounced()
            ledgerRestored(restoredRecs, by: .rick)
        }
        if let firstRefusal {
            // Keep the banner armed on exactly the rows still removed.
            lastPurgedBatch = LastPurgedBatch(ids: refusedIDs, timestamp: snap.timestamp)
            lastPurgeUndoError = refusedIDs.count == 1
                ? "Undo didn't finish: \(firstRefusal)"
                : "Undo didn't finish for \(refusedIDs.count) items: \(firstRefusal)"
        } else {
            // Everything restored, or nothing left in the batch to restore.
            lastPurgedBatch = nil
            lastPurgeUndoError = nil
        }
        return !restoredRecs.isEmpty
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
