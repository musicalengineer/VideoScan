import Foundation

extension VideoScanModel {

    // MARK: - Workbench Actions
    //
    // The Workbench is the staging area between Combine/Repair work and
    // the long-term Archive. These helpers cover the three things a user
    // does with workbench items: promote to Archive (verified, ready),
    // drop back to Catalog (treat as ordinary media, "not work-in-
    // progress anymore"), or discard entirely (delete the file + the
    // record — for test artifacts and bad runs).
    //
    // All three persist via saveCatalogNow — the [[feedback_archive_persistence]]
    // class of bug already cost us once; explicit one-shot user actions
    // get synchronous saves so a quit-immediately scenario can't lose them.
    //
    // Step 2C of [[project_archive_combine_pipeline_order]].

    /// Promote workbench items to the Archive — moves them off the
    /// Workbench tab and onto the Archive tab. Sets `archiveStage` to
    /// `.healthy` so the archive lifecycle starts at the bottom rung
    /// rather than jumping straight to "fully archived".
    func promoteWorkbenchToArchive(_ recs: [VideoRecord]) {
        for rec in recs {
            rec.lifecycleStage = .archived
            if rec.archiveStage == .none { rec.archiveStage = .healthy }
        }
        saveCatalogNow()
    }

    /// Demote workbench items back to the Catalog — they're no longer
    /// "recent work" but the file stays on disk. Useful when a combined
    /// file is just ordinary media now and shouldn't clutter the
    /// Workbench review queue.
    func dropWorkbenchToCatalog(_ recs: [VideoRecord]) {
        for rec in recs { rec.lifecycleStage = .cataloged }
        saveCatalogNow()
    }

    /// Discard workbench items: move the file to macOS Trash (recoverable
    /// from Finder until emptied) and soft-delete the record via
    /// `purgedAt`. The trash step is best-effort — if the file is already
    /// gone or the trash op fails, the record is still purged so the row
    /// doesn't linger in the UI. Returns the number actually deleted.
    @discardableResult
    func discardWorkbench(_ recs: [VideoRecord]) -> Int {
        var count = 0
        let now = Date()
        for rec in recs {
            let url = URL(fileURLWithPath: rec.fullPath)
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            rec.purgedAt = now
            rec.lifecycleStage = .trashed
            count += 1
        }
        if count > 0 { saveCatalogNow() }
        return count
    }
}
