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
    //  - "Skipped offline" is a DIFFERENT bucket. If the volume containing
    //    the file isn't currently mounted we do NOT touch the record at
    //    all — no purgedAt stamp, no lifecycleStage change. The user
    //    remounts the drive later and runs the workflow again; the rows
    //    are still tagged .confirmedJunk and waiting. (Distinct from
    //    "alreadyMissing", which means the volume IS reachable but the
    //    specific file is gone — that one's a soft-delete because there's
    //    nothing more to do.)
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
    // outcomes array + failed-errors array; both bounded by `attempted`.
    //
    // Threading (2026-05-26 refactor — fix/junk-delete-async):
    //  - The disk-side FileManager loop (trashItem / removeItem /
    //    fileExists) used to run synchronously on @MainActor and pinned
    //    the UI for 1-10+ seconds on batches of a few hundred files.
    //  - Now: pre-flight on main (cheap, no I/O — just the reachability
    //    cache + empty-path check), then hop off main via
    //    `Task.detached(priority: .userInitiated)` to do all FileManager
    //    work, then come back on main to apply record-state mutations
    //    (VideoRecord lives on @MainActor) and persist.
    //  - `Task { … }` would have inherited @MainActor and stayed on the
    //    main thread; `Task.detached { … }` truly escapes the actor, so
    //    that's what we use.

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
        /// (Volume WAS reachable; the specific file just wasn't there.)
        let alreadyMissing: Int
        /// Records whose volume isn't currently mounted. We do NOT touch
        /// these records — they stay tagged .confirmedJunk and the user
        /// can retry after remounting the drive. Distinct from
        /// `alreadyMissing` because the user can still act on these later.
        let skippedOffline: Int
        /// Per-record failures with the underlying FileManager error.
        /// Surfaced in the result sheet so the user knows which files
        /// were skipped and why (permissions, locked, etc.).
        let failed: [(record: VideoRecord, error: Error)]
    }

    /// Per-record decision made by the off-main FileManager pass. The
    /// detached task returns one of these for every input record (in input
    /// order); the @MainActor body then walks the list and applies the
    /// corresponding record-state mutation. We keep this enum file-private
    /// — it's an implementation detail of the async hop.
    fileprivate enum JunkDeletionOutcome {
        case succeeded
        case alreadyMissing
        case skippedOffline
        case failed(Error)
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
    /// The disk-side FileManager work runs on a detached background task
    /// so the main thread stays responsive while a 200-file batch trashes
    /// (~3-10 seconds wall-clock on slow volumes). The function itself
    /// stays @MainActor because the catalog-state writes (rec.purgedAt,
    /// rec.lifecycleStage) and `saveCatalogDebounced()` must run on main.
    ///
    /// Returns a result summary the UI displays in the result sheet.
    @discardableResult
    func deleteConfirmedJunk(
        _ records: [VideoRecord],
        mode: JunkDeletionMode
    ) async -> JunkDeletionResult {
        // Empty-selection short-circuit: keep the public contract crisp and
        // avoid an unnecessary debounced save() that would re-write
        // catalog.json identical-bytes. Empty selection is a UI no-op,
        // not an error.
        guard !records.isEmpty else {
            return JunkDeletionResult(
                attempted: 0,
                succeeded: 0,
                alreadyMissing: 0,
                skippedOffline: 0,
                failed: []
            )
        }

        // -------------------------------------------------------------
        // Phase 1 — main-thread pre-flight (no disk I/O).
        //
        // Walk the records and decide which paths are eligible for the
        // background pass and which are immediate skipOffline hits. The
        // reachability check is a near-free cache lookup (5s TTL); the
        // empty-path check is a string test. Neither hits the disk, so
        // both stay on main.
        //
        // We build `workItems` in input order — each entry is either
        // (path, recordIndex) for the background loop OR a pre-decided
        // outcome (`skippedOffline`) we'll merge back in after the hop.
        // Carrying record INDEX through the boundary (rather than the
        // VideoRecord reference) keeps the detached task's captures
        // strictly Sendable (String paths + Int indices + the mode).
        //
        // Seam D (VideoRecord-Sendable restructure): the `Sendable`
        // conformance below is the explicit contract that NO `VideoRecord`
        // crosses into the detached FileManager pass — only this value type
        // does. The index is the key we apply outcomes back through on the
        // main actor (Phase 3). The conformance is checked, so a future
        // edit that tried to smuggle a `VideoRecord` field in here would
        // fail to compile rather than silently re-cross the boundary.
        // -------------------------------------------------------------
        struct WorkItem: Sendable {
            let index: Int
            let path: String
        }
        var workItems: [WorkItem] = []
        workItems.reserveCapacity(records.count)
        // Outcome slots: one per input record, in input order. Pre-seeded
        // with skippedOffline placeholders so the records that DON'T go
        // through the background pass still have a slot to read back.
        // Default-fill is `succeeded` only because we always overwrite
        // before reading — but use `skippedOffline` as the visible default
        // to keep the invariant defensive.
        var outcomes: [JunkDeletionOutcome] = Array(
            repeating: .skippedOffline,
            count: records.count
        )

        for (i, rec) in records.enumerated() {
            let path = rec.fullPath

            // Offline-volume pre-filter. We only treat /Volumes/<X>/...
            // paths this way — those are the only paths that can be
            // legitimately "offline" (drive unmounted). Internal paths
            // (/Users, /tmp, /private, etc.) live on the boot volume and
            // are always reachable; for those, a missing file is just
            // alreadyMissing, not offline.
            //
            // The 5s cache on VolumeReachability makes this a near-free
            // check per record (volume root is stat'd at most once per
            // 5s per volume) and runs on the calling thread — fine on
            // main. We do NOT stamp purgedAt / lifecycleStage in this
            // branch: the user will remount the drive and re-run, and
            // the row needs to still be tagged .confirmedJunk for that
            // retry to find it.
            if Self.isExternalVolumePath(path),
               !VolumeReachability.isReachable(path: path) {
                outcomes[i] = .skippedOffline
                continue
            }

            // Eligible for the background pass — defer the existence
            // check (a stat() syscall, potentially slow on a sleeping
            // drive) and the trash/remove call to the detached task.
            workItems.append(WorkItem(index: i, path: path))
        }

        // -------------------------------------------------------------
        // Phase 2 — off-main FileManager pass.
        //
        // `Task.detached` runs the closure OFF the current actor (we're
        // @MainActor here; a plain `Task { … }` would still be pinned
        // to main). Inside the closure we get a fresh non-actor thread
        // pool slot, so multi-second FileManager calls don't block UI.
        //
        // We return `[(index: Int, outcome: JunkDeletionOutcome)]` — the
        // (index, outcome) tuple lets us map results back to records on
        // main without re-walking the input. Index is a plain Int so the
        // capture is Sendable; outcomes carry Error values which are
        // Sendable per Swift's typed-error story.
        //
        // Swift's `Task.detached` ≈ C++ `std::thread([&]{…})` but with
        // structured priority and async/await integration — and we await
        // its .value to suspend the @MainActor function (NOT block) until
        // the detached work is done.
        // -------------------------------------------------------------
        let mode = mode  // capture-in
        let detachedResults: [(Int, JunkDeletionOutcome)] =
            await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                var results: [(Int, JunkDeletionOutcome)] = []
                results.reserveCapacity(workItems.count)

                for item in workItems {
                    let path = item.path

                    // Missing-file branch. We do NOT pre-flight every
                    // file with fileExists() outside this loop because
                    // the disk op below already reports "doesn't exist"
                    // via NSCocoaErrorDomain.fileNoSuchFileError; the
                    // explicit check just lets us distinguish "user
                    // tagged a file that's already gone" from a genuine
                    // permission failure for the result sheet.
                    let exists = !path.isEmpty && fm.fileExists(atPath: path)
                    if !exists {
                        results.append((item.index, .alreadyMissing))
                        continue
                    }

                    // Live-file branch. Wrap the FileManager call so we
                    // can surface the error per-record without aborting
                    // the batch. Swift's `do/catch` ≈ C++ try/catch but
                    // error is a typed value, not an exception you
                    // `throw` and unwind through.
                    do {
                        let url = URL(fileURLWithPath: path)
                        switch mode {
                        case .toTrash:
                            // trashItem moves to the volume's .Trashes;
                            // if there's no Trash on a network mount it
                            // throws — caught below.
                            var resultURL: NSURL?
                            try fm.trashItem(at: url,
                                             resultingItemURL: &resultURL)
                        case .permanent:
                            try fm.removeItem(at: url)
                        }
                        results.append((item.index, .succeeded))
                    } catch {
                        results.append((item.index, .failed(error)))
                    }
                }
                return results
            }.value

        // Merge background results back into the outcomes array. We pre-
        // seeded with .skippedOffline; this overwrites every index the
        // background pass touched, leaving only the truly-offline slots.
        for (idx, outcome) in detachedResults {
            outcomes[idx] = outcome
        }

        // -------------------------------------------------------------
        // Phase 3 — back on main, apply record-state mutations.
        //
        // We're back on @MainActor (the `await` on the detached task's
        // .value returns to our calling actor). VideoRecord writes are
        // safe here; the debounced save() at the end persists the batch.
        // -------------------------------------------------------------
        let now = Date()
        var succeeded = 0
        var alreadyMissing = 0
        var skippedOffline = 0
        var failed: [(record: VideoRecord, error: Error)] = []

        for (i, rec) in records.enumerated() {
            switch outcomes[i] {
            case .skippedOffline:
                // Untouched — see policy comment at top of file. The row
                // stays tagged .confirmedJunk so a remount-then-retry
                // pass picks it up.
                skippedOffline += 1

            case .alreadyMissing:
                alreadyMissing += 1
                // Catalog still gets stamped so the row stops showing
                // as "active confirmed junk" — otherwise the user runs
                // the workflow twice in a row and sees the same files
                // come back, which is confusing.
                rec.purgedAt = now
                // Choose lifecycleStage consistent with the user's
                // intent even though no disk op ran: they asked to
                // trash → mark trashed; they asked to delete → mark
                // deleted. Either way the row is gone from disk; the
                // distinction only matters if the user later inspects
                // "what happened to this file" via Show Removed.
                switch mode {
                case .toTrash:
                    rec.lifecycleStage = .trashed
                case .permanent:
                    rec.lifecycleStage = .deletedPermanently
                }

            case .succeeded:
                succeeded += 1
                switch mode {
                case .toTrash:
                    rec.lifecycleStage = .trashed
                case .permanent:
                    rec.lifecycleStage = .deletedPermanently
                }
                rec.purgedAt = now

            case .failed(let error):
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
        // #160: purgedAt/lifecycleStage flipped in place — no count change,
        // no undo banner — so the table's cache would never recompute and
        // the deleted rows stayed visible with Show Removed off.
        noteCatalogRecordsMutated()

        log("Delete Confirmed Junk: attempted=\(records.count) succeeded=\(succeeded) missing=\(alreadyMissing) offline=\(skippedOffline) failed=\(failed.count) mode=\(mode == .toTrash ? "trash" : "permanent")")

        return JunkDeletionResult(
            attempted: records.count,
            succeeded: succeeded,
            alreadyMissing: alreadyMissing,
            skippedOffline: skippedOffline,
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

    /// Reachability-split view over `confirmedJunkRecords`. The
    /// confirmation sheet shows separate counts/byte totals for
    /// currently-actionable rows vs. rows whose volume isn't mounted.
    /// Computed once when the sheet opens; the 5s reachability cache
    /// makes this O(records) with at most one stat() per unique volume.
    struct ConfirmedJunkSplit {
        let reachable: [VideoRecord]
        let offline: [VideoRecord]
        var reachableBytes: Int64 {
            reachable.reduce(into: Int64(0)) { $0 += $1.sizeBytes }
        }
        var offlineBytes: Int64 {
            offline.reduce(into: Int64(0)) { $0 += $1.sizeBytes }
        }
    }

    /// Split an arbitrary record list by current volume reachability.
    /// Static so the confirmation sheet can call it without going through
    /// the model — it operates purely on the records + the global
    /// VolumeReachability cache. Unit-tested independently.
    ///
    /// Mirrors the predicate in `deleteConfirmedJunk`: only paths under
    /// `/Volumes/<X>/...` are eligible to be "offline" (drive unmounted).
    /// Internal paths (/Users, /tmp, /private, ...) live on the boot
    /// volume and are always reachable; if their file is gone, that's
    /// alreadyMissing — not offline.
    static func splitByReachability(
        _ records: [VideoRecord]
    ) -> ConfirmedJunkSplit {
        var reachable: [VideoRecord] = []
        var offline: [VideoRecord] = []
        reachable.reserveCapacity(records.count)
        for r in records {
            if isExternalVolumePath(r.fullPath),
               !VolumeReachability.isReachable(path: r.fullPath) {
                offline.append(r)
            } else {
                // Everything else — internal disk, empty path, or
                // /Volumes path whose drive IS mounted — goes to
                // reachable so deleteConfirmedJunk gets to bucket it
                // (succeeded / alreadyMissing / failed).
                reachable.append(r)
            }
        }
        return ConfirmedJunkSplit(reachable: reachable, offline: offline)
    }

    /// True iff `path` is under "/Volumes/<volumeName>/..." — i.e. lives
    /// on a removable/external mount that could be ejected. Internal
    /// paths (/Users, /tmp, /private, /System, ...) return false because
    /// their "volume" is the boot disk and is always present.
    ///
    /// Static + nonisolated so callers in any context can use it without
    /// hopping actors.
    nonisolated static func isExternalVolumePath(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let comps = (path as NSString).pathComponents
        // ["/", "Volumes", "<name>", ...] → length ≥ 3, comps[1] == "Volumes".
        return comps.count >= 3 && comps[1] == "Volumes"
    }
}
