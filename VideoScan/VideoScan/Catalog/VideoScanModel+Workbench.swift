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

    /// Under Construction's "Promote" — the same Promote as the Catalog's:
    /// `requestPromote(records:)` → confirmation sheet → PromoteToArchiveJob
    /// (copy + fixity + archive row). It used to stamp
    /// `lifecycleStage = .archived` and copy nothing, so the file left
    /// Triage, its dates froze, and the Archive tab never saw it
    /// (tab-charter audit T2, 2026-10-11). The stage is now the engine's to
    /// set, on the archive copy, after the copy is verified.
    func promoteWorkbenchToArchive(_ recs: [VideoRecord]) {
        requestPromote(records: recs)
    }

    /// Demote workbench items back to the Catalog — they're no longer
    /// "recent work" but the file stays on disk. Useful when a combined
    /// file is just ordinary media now and shouldn't clutter the
    /// Workbench review queue.
    func dropWorkbenchToCatalog(_ recs: [VideoRecord]) {
        for rec in recs { rec.lifecycleStage = .cataloged }
        saveCatalogNow()
    }

    /// A viewer Mac never trashes a file or purges a row (QA round 1 on
    /// C04-F5, 2026-10-06). Either signal refuses: the model flag or
    /// ViewerModeCenter. Logs one line; true = refused, touch nothing.
    func workbenchDiscardRefusedOnViewer(_ records: [VideoRecord]) -> Bool {
        let viewer = ViewerWriteGuard.refuse("VideoScanModel.discardWorkbench")
        guard viewer || isReadOnly else { return false }
        log("Discard refused — this Mac is a read-only viewer of the catalog; \(records.count) file(s) left untouched.")
        return true
    }

    /// Discard workbench items: move each file to the macOS Trash
    /// (recoverable from Finder until emptied) through THE Trash engine,
    /// `deleteConfirmedJunk(reason: .workbench)` (GH #143 — before, Discard
    /// had its own copy of the engine's disk turn). Returns the number of
    /// rows marked gone (moved + already missing).
    ///
    /// Each file gets exactly ONE outcome, the same six words every delete
    /// verb uses (DeletionAudit):
    ///   - moved   — the Trash took it: the row is marked In the Trash
    ///               (with the Trash path), legacy stage `.trashed`.
    ///   - missing — already gone from a CONNECTED drive: marked Missing.
    ///   - failed  — the Trash call threw: the file is where it was, the
    ///               record is untouched, the error is logged and the audit
    ///               row says FAILED (B1, 2026-10-10).
    ///   - offline — its drive is not mounted: untouched; remount and retry.
    ///   - held    — the Master Archive / a drive marked Read only: untouched.
    /// START, one line per file, and the OUTCOME line go through the one
    /// audit sink, and the run writes a receipt CSV under
    /// ~/Library/Logs/VideoScan/deletions/.
    ///
    /// The engine asks the gate TWICE — for the whole request up front (by
    /// path, verb "Discard"), and again at EACH file's turn, on the main
    /// actor and in the disk half by the file's own volume identity (the F5
    /// class of codex #258). Master Archive files and drives marked Read only
    /// are left alone, row and file.
    ///
    /// `trash` is the file operation, for tests; nil = FileManager's
    /// trashItem, whose resulting location goes on the marker and receipt.
    /// Explicit one-shot user action → a synchronous save afterwards (the
    /// header's persistence rule), on top of the engine's debounced one.
    @discardableResult
    func discardWorkbench(_ requested: [VideoRecord],
                          trash: (@Sendable (URL) throws -> Void)? = nil) async -> Int {
        if workbenchDiscardRefusedOnViewer(requested) { return 0 }
        guard !requested.isEmpty else { return 0 }
        let audit = DeletionAudit(kind: .workbench, verb: "Discard", linePrefix: "[workbench] ", sink: deletionAuditSink())
        audit.start(scope: "\(requested.count) selected in Under Construction", requested: requested.count,
                    bytes: requested.reduce(Int64(0)) { $0 + $1.sizeBytes })
        let fileGuard = JunkDeletionGuard(
            authorize: { _ in nil }, beforeRemoval: { _ in nil }, remove: trash,
            settled: { rec, outcome in audit.record(Self.discardAuditRow(rec, outcome), id: rec.id) })
        let result = await deleteConfirmedJunk(requested, mode: .toTrash, reason: .workbench, guard: fileGuard)
        audit.finish()
        let gone = result.succeeded + result.alreadyMissing
        if gone > 0 { saveCatalogNow() }
        return gone
    }

    /// The junk lanes' audit row, except that a Trash call that threw is
    /// written as FAILED, not held: Discard has no hold-and-retry story for
    /// it, and the OUTCOME line must count it as a failure (B1). The
    /// reason still names the drive and the error.
    static func discardAuditRow(_ rec: VideoRecord, _ outcome: JunkFileOutcome) -> DeletionAuditRow {
        var row = JunkDeletionResult.auditRow(rec, outcome)
        if outcome.kind == .failed { row.outcome = .failed }
        return row
    }
}
