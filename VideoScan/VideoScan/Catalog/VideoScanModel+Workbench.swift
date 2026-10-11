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

    /// A viewer Mac never trashes a file or purges a row (QA round 1 on
    /// C04-F5, 2026-10-06). Either signal refuses: the model flag or
    /// ViewerModeCenter. Logs one line; true = refused, touch nothing.
    func workbenchDiscardRefusedOnViewer(_ records: [VideoRecord]) -> Bool {
        let viewer = ViewerWriteGuard.refuse("VideoScanModel.discardWorkbench")
        guard viewer || isReadOnly else { return false }
        log("Discard refused — this Mac is a read-only viewer of the catalog; \(records.count) file(s) left untouched.")
        return true
    }

    /// Discard workbench items: move the file to macOS Trash (recoverable
    /// from Finder until emptied) and soft-delete the record via
    /// `purgedAt`. Returns the number of records purged.
    ///
    /// Each file gets exactly ONE outcome, the same six words every delete
    /// verb uses (DeletionAudit):
    ///   - moved   — the Trash took it: record purged, stage `.trashed`.
    ///   - missing — already gone from a CONNECTED drive: record purged
    ///               (an un-purgeable row would linger forever), no Trash call.
    ///   - failed  — the Trash call threw: the file is where it was, the
    ///               record is untouched, the error is logged (B1,
    ///               2026-10-10 — before this, a failed Trash still stamped
    ///               the row purged + Trashed).
    ///   - offline — its drive is not mounted: untouched; remount and retry.
    ///   - held    — the Master Archive / a drive marked Read only: untouched.
    /// START, one line per file, and the OUTCOME line go through the one
    /// audit sink, and the run writes a receipt CSV under
    /// ~/Library/Logs/VideoScan/deletions/.
    ///
    /// Master Archive files — the tree AND anything else on the archive's
    /// volume (Rick 2026-09-22) — are left alone, row and file, through
    /// the one bulk-verb rule (before 2026-09-22 this path had no archive
    /// check at all).
    ///
    /// The gate is asked TWICE: for the whole request up front (by path),
    /// and again for EACH file immediately before it is trashed — the
    /// removal-time check every other bulk verb makes: the file's real
    /// path and its OWN volume's identity, from the model as it is at that
    /// moment. A file on a Read-only drive mounted under a name the
    /// snapshot never saw, or reached through a link, stays (the F5 class
    /// of codex #258).
    ///
    /// `trash` is the file operation, for tests; nil = FileManager's
    /// trashItem, whose resulting location goes on the receipt.
    @discardableResult
    func discardWorkbench(_ requested: [VideoRecord],
                          trash: ((URL) throws -> Void)? = nil) -> Int {
        if workbenchDiscardRefusedOnViewer(requested) { return 0 }
        guard !requested.isEmpty else { return 0 }
        let audit = DeletionAudit(kind: .workbench, verb: "Discard", linePrefix: "[workbench] ", sink: deletionAuditSink())
        audit.start(scope: "\(requested.count) selected in Under Construction", requested: requested.count,
                    bytes: requested.reduce(Int64(0)) { $0 + $1.sizeBytes })
        let recs = excludingMasterArchiveFiles(requested, verb: "Discard")
        let going = Set(recs.map(\.id))
        for rec in requested where !going.contains(rec.id) {
            audit.record(JunkDeletionResult.auditRow(rec, .held("protected by the Master Archive / Read-only rule — nothing moved")),
                         id: rec.id)
        }
        let now = Date()
        var holds = WorkbenchDiscardHolds()
        var moved: [VideoRecord] = []
        var purged = 0
        for rec in recs {
            let outcome = discardTurn(rec, trash: trash, holds: &holds)
            if outcome.isMoved || outcome.kind == .missing {
                rec.purgedAt = now
                rec.lifecycleStage = .trashed
                purged += 1
            }
            if outcome.isMoved { moved.append(rec) }
            audit.record(Self.discardAuditRow(rec, outcome), id: rec.id)
        }
        for line in holds.lines() { log(line) }
        if purged > 0 {
            saveCatalogNow()
            noteCatalogRecordsMutated()   // #160: in-place purge, no banner
            ledgerCopyRemoved(moved, permanent: false, by: .rick, at: now)   // Media Ledger (stage 2)
        }
        audit.finish()
        return purged
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

    /// One file's turn: the removal-time gate, the drive, the file, then
    /// the Trash. Never stamps the record — the caller does, from the
    /// outcome. (For Rick: `inout` ≈ a C++ non-const reference parameter.)
    private func discardTurn(_ rec: VideoRecord, trash: ((URL) throws -> Void)?,
                             holds: inout WorkbenchDiscardHolds) -> JunkFileOutcome {
        let path = rec.fullPath
        // The last word for THIS file, now — row and file are left alone.
        let check = archiveRemovalCheck()
        if let held = check?.bulkRefusal(forPath: path) {
            holds.note(held, snapshot: check?.protection)
            return .held(Self.bulkDeleteRefusalNote(held.refusal, volume: held.volume) + " — nothing moved")
        }
        // An unplugged drive is not a missing file: the record stays.
        if Self.isExternalVolumePath(path), !VolumeReachability.isReachable(path: path) { return .offline }
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return .missing }
        let bytes = FileIdentityStamp.capture(path: path)?.size ?? rec.sizeBytes
        let url = URL(fileURLWithPath: path)
        do {
            if let trash {
                try trash(url)
                return .moved(bytes: bytes, trashPath: nil)
            }
            var landed: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &landed)
            return .moved(bytes: bytes, trashPath: landed?.path)
        } catch {
            // The file is where it was; the record is not touched.
            return .failed(error)
        }
    }
}

/// The per-file refusals Discard found at removal time, tallied for the
/// one summary line per kind it has always written.
struct WorkbenchDiscardHolds {
    private var readOnly: [String: Int] = [:]
    private var archive = 0
    private var unprovable = 0
    private var archiveLabel = "the archive volume"
    private var unprovableSnapshot: ArchiveVolumeProtection?

    mutating func note(_ held: (refusal: VideoScanModel.BulkDeleteRefusal, volume: String),
                       snapshot: ArchiveVolumeProtection?) {
        switch held.refusal {
        case .readOnlyVolume(let name), .readOnlyVolumeDifferentDrive(let name): readOnly[name, default: 0] += 1
        case .archiveVolumeUnprovable:
            // The snapshot this very check used — says whether the archive was mounted.
            unprovable += 1; archiveLabel = held.volume; unprovableSnapshot = snapshot
        case .archiveVolume, .archiveTree: archive += 1; archiveLabel = held.volume
        }
    }

    func lines() -> [String] {
        var out = readOnly.sorted(by: { $0.key < $1.key }).map {
            VideoScanModel.readOnlyVolumeRefusalLine(verb: "Discard", count: $0.value, volume: $0.key)
        }
        if archive > 0 {
            out.append(VideoScanModel.masterArchiveVolumeRefusalLine(verb: "Discard", count: archive, volume: archiveLabel))
        }
        if unprovable > 0 {
            out.append(VideoScanModel.masterArchiveUnprovableRefusalLine(verb: "Discard", count: unprovable,
                                                                         volume: archiveLabel, atRemoval: unprovableSnapshot))
        }
        return out
    }
}
