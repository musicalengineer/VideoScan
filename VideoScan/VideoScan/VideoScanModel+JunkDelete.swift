import Foundation

extension VideoScanModel {

    // MARK: - Delete Confirmed Junk
    //
    // The "Delete Confirmed Junk" workflow. The caller hands us records the
    // user has already tagged `.confirmedJunk` (via the catalog row context
    // menu's Tag submenu); we go to disk and either trash or hard-delete the
    // file, then soft-delete the catalog record so the row stops cluttering
    // the default view. The record itself is preserved with a deletion
    // timestamp (`purgedAt`) so the user can still see WHAT got deleted
    // even though the file is gone.
    //
    // Policy (decided 2026-05-25):
    //  - No backup check, no dup check. The user already promoted these to
    //    .confirmedJunk; second-guessing them via "did you back this up?"
    //    is paternalistic, and the dup-check belongs to a different feature.
    //  - Two flavors. .toTrash uses FileManager.trashItem so the file ends
    //    up in macOS Finder's Trash (recoverable, disk space freed when
    //    Trash is emptied). .permanent uses FileManager.removeItem (gone
    //    immediately, frees space now). The user picks at confirm time.
    //  - "Already missing" is not an error. If the file vanished between
    //    tagging and the delete pass (network drive ejected, user nuked it
    //    from Finder), we still update the catalog record so the row reads
    //    consistently afterward. The count surfaces in the result sheet so
    //    the user knows what happened.
    //  - Per-record errors are collected and reported, not thrown. One
    //    permission-denied file does NOT abort the batch — the user marked
    //    20 things as junk and wants the other 19 gone.
    //
    // `fullPath` is intentionally NOT cleared on the record. The user might
    // want to remember "where did that ~/Movies/garbage_2003.mov live?"
    // months later when they're auditing the archive. We just stamp
    // purgedAt + lifecycleStage and let the catalog row's "Show removed"
    // toggle surface it. Same pattern as the soft-delete (Remove from
    // Catalog) flow above — purgedAt is the source of truth for "this row
    // is hidden by default."
    //
    // Memory: this is a single pass over the input records (which is the
    // user's selection, typically O(10²-10³)). No file content is read —
    // we only call FileManager methods. Worst case footprint is the
    // failed-errors array; bounded by `attempted`.

    /// User's deletion choice. `.toTrash` is the default reach via the
    /// confirmation sheet; `.permanent` requires deliberate confirmation
    /// (.destructive role on the button).
    enum JunkDeletionMode {
        case toTrash
        case permanent
    }

    /// Outcome of a single batch deletion. The result sheet renders these
    /// counts; tests assert against them directly.
    struct JunkDeletionResult {
        /// Total records passed in (could include records already missing
        /// from disk or that ultimately fail).
        let attempted: Int
        /// Files actually moved to Trash or removed from disk this pass.
        let succeeded: Int
        /// Records whose `fullPath` did not exist when we tried — catalog
        /// was still updated (purgedAt + lifecycleStage), but no disk op.
        let alreadyMissing: Int
        /// Per-record failures with the underlying FileManager error.
        /// Surfaced in the result sheet so the user knows which files
        /// were skipped and why (permissions, locked, etc.).
        let failed: [(record: VideoRecord, error: Error)]
    }

    /// Delete (trash or hard-remove) every record in `records`, regardless
    /// of their current `mediaDisposition`. Caller filters to
    /// `.confirmedJunk` before invoking — this method does not double-check
    /// the disposition, which keeps it usable from tests with arbitrary
    /// records and from future callers (e.g. a "Delete Selected" path).
    ///
    /// All catalog mutations happen in-memory on the existing
    /// `VideoRecord` instances; a single `saveCatalogDebounced()` at the
    /// end persists the batch (per the dispatch — no per-record I/O).
    ///
    /// Returns a result summary the UI displays in the result sheet.
    @discardableResult
    func deleteConfirmedJunk(
        _ records: [VideoRecord],
        mode: JunkDeletionMode
    ) -> JunkDeletionResult {
        // Empty-selection short-circuit: keep the public contract crisp and
        // avoid an unnecessary debounced save() that would re-write
        // catalog.json identical-bytes. Empty selection is a UI no-op,
        // not an error.
        guard !records.isEmpty else {
            return JunkDeletionResult(
                attempted: 0,
                succeeded: 0,
                alreadyMissing: 0,
                failed: []
            )
        }

        let now = Date()
        let fm = FileManager.default
        var succeeded = 0
        var alreadyMissing = 0
        var failed: [(record: VideoRecord, error: Error)] = []

        for rec in records {
            let path = rec.fullPath

            // Missing-file branch. We do NOT pre-flight every file with
            // fileExists() because the disk op below already reports
            // "doesn't exist" via NSCocoaErrorDomain.fileNoSuchFileError;
            // keeping the check explicit lets us tell the UI "you tagged
            // a file that's already gone" without conflating it with a
            // genuine permission failure.
            let exists = !path.isEmpty && fm.fileExists(atPath: path)
            if !exists {
                alreadyMissing += 1
                // Catalog still gets stamped so the row stops showing as
                // "active confirmed junk" — otherwise the user runs the
                // workflow twice in a row and sees the same files come
                // back, which is confusing.
                rec.purgedAt = now
                // Choose lifecycleStage consistent with the user's intent
                // even though no disk op ran: they asked to trash → mark
                // trashed; they asked to delete → mark deleted. Either
                // way the row is gone from disk; the distinction only
                // matters if the user later inspects "what happened to
                // this file" via Show Removed.
                switch mode {
                case .toTrash:
                    rec.lifecycleStage = .trashed
                case .permanent:
                    rec.lifecycleStage = .deletedPermanently
                }
                continue
            }

            // Live-file branch. Wrap the FileManager call so we can
            // surface the error per-record without aborting the batch.
            // Swift's `do/catch` ≈ C++ try/catch but error is a typed
            // value, not an exception you `throw` and unwind through.
            do {
                let url = URL(fileURLWithPath: path)
                switch mode {
                case .toTrash:
                    // trashItem moves to the volume's .Trashes; if there's
                    // no Trash on a network mount it throws — caught below.
                    var resultURL: NSURL?
                    try fm.trashItem(at: url, resultingItemURL: &resultURL)
                    rec.lifecycleStage = .trashed
                case .permanent:
                    try fm.removeItem(at: url)
                    rec.lifecycleStage = .deletedPermanently
                }
                rec.purgedAt = now
                succeeded += 1
            } catch {
                failed.append((record: rec, error: error))
                // Do NOT stamp purgedAt or lifecycleStage on failure —
                // the file is still there, the row should remain active
                // so the user can retry or inspect.
            }
        }

        // Single batched persist. Per-record save() would saturate the
        // debouncer and (worse) leave the catalog in a partially-written
        // state if the app crashes mid-loop. One write at the end matches
        // the pattern used by purgeRecords() above.
        saveCatalogDebounced()

        log("Delete Confirmed Junk: attempted=\(records.count) succeeded=\(succeeded) missing=\(alreadyMissing) failed=\(failed.count) mode=\(mode == .toTrash ? "trash" : "permanent")")

        return JunkDeletionResult(
            attempted: records.count,
            succeeded: succeeded,
            alreadyMissing: alreadyMissing,
            failed: failed
        )
    }

    /// Convenience filter: every active (non-purged) record currently
    /// tagged `.confirmedJunk`. Used by the catalog toolbar to compute the
    /// "Delete Confirmed Junk…" badge count and to populate the
    /// confirmation sheet.
    ///
    /// We deliberately exclude purged records — once `purgedAt` is set
    /// the row is hidden by default and the file (per this workflow) is
    /// already gone or trashed. Re-offering "delete junk" on a purged row
    /// would either no-op (file is gone) or surprise the user (file in
    /// Trash gets permanently deleted because we'd re-call removeItem).
    var confirmedJunkRecords: [VideoRecord] {
        records.filter {
            $0.mediaDisposition == .confirmedJunk && $0.purgedAt == nil
        }
    }
}
