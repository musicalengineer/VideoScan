// VideoScanModel+UpdateCatalog.swift
// ONE door — "Update Catalog" — for reconciling reality with the catalog
// after humans fiddled with files/folders outside the app (Rick 2026-08-17).
//
// What lives behind the door:
//   1. Rename DETECTION stays automatic (the UUID-based badge in
//      VideoScanModel+VolumeRenameMigration). The badge and the Catalog
//      menu both route HERE; a target with a pending rename shows up as a
//      row whose Apply runs the existing migration.
//   2. "Rescan and relink" for reachable targets: the EXISTING rescan
//      (startTarget → runScanForTarget) runs with its scan-completion
//      merge DEFERRED — the probe results are parked in memory, the merge
//      is DRY-RUN (`previewScanMerge`, the same derivation the commit
//      uses), and the sheet shows "n moved (relinked), n new, n missing
//      (would be pruned behind the tripwire), n unchanged" plus any
//      "ambiguous — review" groups. Apply commits the parked results
//      through `commitScanResults` — which re-derives against the CURRENT
//      catalog, so a stale plan can never be trusted. Never automatic on
//      mount; always a press. Cancel/close discards the parked results
//      (and stops any deferred scan still running) so nothing commits
//      behind the user's back.
//   3. "Looks moved" prompt: when a user action needs a file that is
//      missing while its VOLUME is mounted, a non-blocking banner offers
//      Update Catalog. Debounced once per volume per session.
//
// Scan gates are unchanged: retired targets are skipped, the scratch
// volume is screened, the Master Archive may be rescanned but is never
// relinked-into (see VideoScanModel+ScanMergeMoveIdentity).
//
// State model: rows are a plain @Published value array (the sheet is a
// pure function of it); the parked probe results (live VideoRecord
// instances — NOT Sendable) live in a non-published dictionary keyed by
// normalized root. Both are cleared on close.
//
// Worst-case memory: one parked `targetRecords` array per previewed
// target — the same buffer the normal scan holds until finalize, just
// held until Apply/Cancel instead. The missing-file default check
// snapshots ONE path string per record under the eligible targets
// (~100 B × 100k = ~10 MB transient) and stats them off-main.

import Foundation
import os

private let updateCatalogLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "updateCatalog")

// MARK: - Value types

/// What Apply actually did for one target — the row's final state and the
/// log summary's source.
struct UpdateCatalogApplySummary: Equatable, Sendable {
    var moved: Int = 0
    var new: Int = 0
    var pruned: Int = 0
    var unchanged: Int = 0
    var retainedInvisible: Int = 0
    var ambiguous: Int = 0
    var tripwireFired: Bool = false
    var snapshotPath: String?

    init() {}

    init(outcome: ScanMergeOutcome) {
        moved = outcome.moved
        new = max(0, outcome.upserted - outcome.refreshed - outcome.moved)
        pruned = outcome.pruned
        unchanged = outcome.refreshed
        retainedInvisible = outcome.retainedInvisible
        ambiguous = outcome.ambiguous
        tripwireFired = outcome.tripwireFired
        snapshotPath = outcome.snapshotPath
    }
}

/// One row of the Update Catalog sheet — one scan target.
struct UpdateCatalogRow: Identifiable, Equatable {
    enum Phase: Equatable {
        /// Listed, not yet previewed.
        case idle
        /// Rescan running with the merge deferred.
        case scanning
        /// Dry run done — waiting for Apply.
        case previewed(VideoScanModel.ScanMergePreview)
        case applying
        case applied(UpdateCatalogApplySummary)
        /// Offline old path whose volume was renamed (UUID badge). Apply
        /// runs the existing migration.
        case renamePending(VolumeRenameCandidate)
        case renameApplied
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .scanning, .applying: return true
            default: return false
            }
        }
        var isPreviewed: Bool { if case .previewed = self { return true } else { return false } }
        var isRenamePending: Bool { if case .renamePending = self { return true } else { return false } }
        var isDone: Bool {
            switch self {
            case .applied, .renameApplied: return true
            default: return false
            }
        }
    }

    /// The scan target's id.
    let id: UUID
    var targetPath: String
    var displayName: String
    var isSelected: Bool
    /// From the opening check: records under this target whose file is
    /// missing right now. nil = not checked yet / still checking.
    var missingCount: Int?
    var phase: Phase = .idle
}

/// The parked probe results of one deferred scan (live records — main
/// actor only, never crosses to another task).
struct UpdateCatalogPendingMerge {
    let targetID: UUID
    let root: String
    let volName: String
    let targetRecords: [VideoRecord]
    let scanWasComplete: Bool
    let preview: VideoScanModel.ScanMergePreview
}

/// "Looks moved" banner payload.
struct LooksMovedNotice: Equatable {
    let filename: String
    let volumeName: String
    /// The scan target the file's path falls under (preselected in the
    /// sheet), when there is one.
    let targetID: UUID?
}

// MARK: - Model surface

extension VideoScanModel {

    // MARK: Eligibility

    /// Targets the door can act on: reachable, not retired, not the
    /// scratch volume — plus OFFLINE targets with a detected rename (their
    /// action is the migration, not a rescan).
    func updateCatalogEligibleTargets() -> [CatalogScanTarget] {
        scanTargets.filter { t in
            guard !t.searchPath.isEmpty, !t.isRetired, !t.isScratchVolume else { return false }
            if t.isReachable { return true }
            return volumeRenameCandidate(for: t.searchPath) != nil
        }
    }

    // MARK: Open / close

    /// Open the sheet. `preselecting` wins over the default selection when
    /// given (badge / "looks moved" entry points); otherwise the default is
    /// "targets with any missing records or a pending rename", filled in
    /// asynchronously by the off-main missing check.
    func openUpdateCatalog(preselecting: Set<UUID>? = nil) {
        guard !isReadOnly else { return }
        // Re-opening while a session exists keeps it (rows carry state the
        // user may be waiting on); a fresh open builds new rows.
        if updateCatalogRows.isEmpty {
            updateCatalogRows = updateCatalogEligibleTargets().map { t in
                let cand = volumeRenameCandidate(for: t.searchPath)
                var row = UpdateCatalogRow(
                    id: t.id,
                    targetPath: t.searchPath,
                    displayName: VolumeReachability.displayLabel(forPath: t.searchPath),
                    isSelected: preselecting?.contains(t.id) ?? (cand != nil),
                    missingCount: nil)
                if let cand { row.phase = .renamePending(cand) }
                return row
            }
        } else if let preselecting {
            for i in updateCatalogRows.indices where preselecting.contains(updateCatalogRows[i].id) {
                updateCatalogRows[i].isSelected = true
            }
        }
        showUpdateCatalogSheet = true
        Task { await refreshUpdateCatalogMissingCounts(applyDefaultSelection: preselecting == nil) }
    }

    /// Close/cancel: stop any deferred scan still running, discard parked
    /// results, clear rows. Nothing that was only previewed is committed.
    func closeUpdateCatalog() {
        for row in updateCatalogRows where row.phase == .scanning {
            if let t = scanTargets.first(where: { $0.id == row.id }), t.status.isActive {
                stopTarget(t)
            }
        }
        let parked = updateCatalogPendingMerges.count
        updateCatalogPendingMerges.removeAll()
        updateCatalogDeferredRoots.removeAll()
        updateCatalogRows.removeAll()
        showUpdateCatalogSheet = false
        if parked > 0 {
            updateCatalogLog.notice("Update Catalog closed with \(parked) previewed target(s) not applied — parked results discarded")
        }
    }

    // MARK: Missing-file check (default selection)

    /// Sendable snapshot for the off-main stat sweep.
    struct UpdateCatalogPathSnap: Sendable {
        let targetID: UUID
        let paths: [String]
    }

    /// Off-main: count the paths that are NOT on disk, per target. Pure
    /// function of the filesystem.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func countMissingFiles(_ snaps: [UpdateCatalogPathSnap]) async -> [UUID: Int] {
        let fm = FileManager.default
        var out: [UUID: Int] = [:]
        for snap in snaps {
            var missing = 0
            for p in snap.paths where !fm.fileExists(atPath: p) { missing += 1 }
            out[snap.targetID] = missing
        }
        return out
    }

    /// Snapshot paths under each REACHABLE row's target on the main actor,
    /// stat them off-main, publish counts, and (when asked) apply the
    /// default selection: any missing → selected. Generation-guarded so a
    /// close/reopen during the sweep can't resurrect stale rows.
    func refreshUpdateCatalogMissingCounts(applyDefaultSelection: Bool) async {
        updateCatalogCheckGeneration &+= 1
        let gen = updateCatalogCheckGeneration
        var snaps: [UpdateCatalogPathSnap] = []
        for row in updateCatalogRows where !row.phase.isRenamePending {
            let paths = records.compactMap { rec -> String? in
                guard rec.purgedAt == nil,
                      PathScope.contains(rec.fullPath, within: row.targetPath) else { return nil }
                return rec.fullPath
            }
            snaps.append(UpdateCatalogPathSnap(targetID: row.id, paths: paths))
        }
        let counts = await Self.countMissingFiles(snaps)
        guard gen == updateCatalogCheckGeneration else { return }
        for i in updateCatalogRows.indices {
            guard let n = counts[updateCatalogRows[i].id] else { continue }
            updateCatalogRows[i].missingCount = n
            if applyDefaultSelection && n > 0 && updateCatalogRows[i].phase == .idle {
                updateCatalogRows[i].isSelected = true
            }
        }
    }

    // MARK: Preview (deferred rescan)

    /// True when a scan finishing for `root` must PARK its results instead
    /// of committing — checked by finalizeSingleTargetScan.
    ///
    /// Belt and suspenders (poisoned-state isolation): the root must ALSO
    /// have a live row in `.scanning` — a stale entry left in the deferred
    /// set by any future bug can never turn an ordinary scan into a silent
    /// no-commit.
    func isUpdateCatalogDeferred(root: String) -> Bool {
        let key = PathScope.normalize(root)
        guard updateCatalogDeferredRoots.contains(key) else { return false }
        return updateCatalogRows.contains {
            $0.phase == .scanning && PathScope.normalize($0.targetPath) == key
        }
    }

    /// Kick off the rescan for every SELECTED idle row. Each runs through
    /// the ordinary scan lifecycle with its commit deferred.
    func startUpdateCatalogPreview() {
        guard !isReadOnly else { return }
        for i in updateCatalogRows.indices {
            let row = updateCatalogRows[i]
            guard row.isSelected, row.phase == .idle else { continue }
            guard let target = scanTargets.first(where: { $0.id == row.id }) else {
                updateCatalogRows[i].phase = .failed("This target is no longer in the list.")
                continue
            }
            let key = PathScope.normalize(target.searchPath)
            // Arm the deferral BEFORE the scan task exists (the predicate
            // needs both the set entry and a `.scanning` row).
            updateCatalogDeferredRoots.insert(key)
            updateCatalogPendingMerges[key] = nil
            updateCatalogRows[i].phase = .scanning
            startTarget(target)
            if !target.status.isActive {
                // startTarget refused (already active, ffprobe missing, …) —
                // it logged why; don't leave the row spinning.
                updateCatalogDeferredRoots.remove(key)
                updateCatalogRows[i].phase = .failed("The rescan couldn't start — see the console for the reason.")
            }
        }
    }

    /// Called by finalizeSingleTargetScan INSTEAD of commitScanResults when
    /// the root is deferred: dry-run the merge, park the results, update
    /// the row. The parked payload is committed by `applyUpdateCatalog`.
    func parkScanResultsForUpdateCatalog(
        target: CatalogScanTarget,
        volName: String,
        targetRecords: [VideoRecord],
        scanWasComplete: Bool
    ) async {
        let key = PathScope.normalize(target.searchPath)
        let preview = await previewScanMerge(root: target.searchPath,
                                             targetRecords: targetRecords,
                                             scanWasComplete: scanWasComplete)
        // The sheet may have been closed while the scan ran — then there is
        // nobody to apply, and NOTHING commits (never automatic).
        guard updateCatalogDeferredRoots.contains(key) else {
            updateCatalogLog.notice("Deferred scan for \(volName, privacy: .public) finished after Update Catalog closed — results discarded, catalog unchanged")
            log("  Update Catalog was closed — rescan results for \(volName) discarded, catalog unchanged.")
            return
        }
        updateCatalogPendingMerges[key] = UpdateCatalogPendingMerge(
            targetID: target.id, root: target.searchPath, volName: volName,
            targetRecords: targetRecords, scanWasComplete: scanWasComplete, preview: preview)
        setUpdateCatalogPhase(targetID: target.id, .previewed(preview))
        log("  Update Catalog preview for \(volName): \(preview.moved) moved (relinked), \(preview.new) new, \(preview.missing) missing, \(preview.unchanged) unchanged\(preview.ambiguous.isEmpty ? "" : ", \(preview.ambiguous.count) ambiguous — review")\(preview.scanWasComplete ? "" : " (scan incomplete — nothing would be pruned)"). Nothing changed yet — press Apply.")
        updateCatalogLog.info("Preview \(volName, privacy: .public): moved=\(preview.moved) new=\(preview.new) missing=\(preview.missing) unchanged=\(preview.unchanged) ambiguous=\(preview.ambiguous.count) complete=\(preview.scanWasComplete)")
    }

    /// A deferred scan ended without producing results (cancelled, error,
    /// empty discovery). Empty discovery is a legitimate "nothing to do".
    func noteUpdateCatalogScanEnded(target: CatalogScanTarget, emptyDiscovery: Bool, cancelled: Bool) {
        let key = PathScope.normalize(target.searchPath)
        guard updateCatalogDeferredRoots.contains(key) else { return }
        if emptyDiscovery {
            var p = ScanMergePreview()
            p.note = "No media files were found — an empty scan never prunes, so there is nothing to update."
            setUpdateCatalogPhase(targetID: target.id, .previewed(p))
            updateCatalogPendingMerges[key] = UpdateCatalogPendingMerge(
                targetID: target.id, root: target.searchPath,
                volName: VolumeReachability.displayLabel(forPath: target.searchPath),
                targetRecords: [], scanWasComplete: false, preview: p)
        } else {
            updateCatalogDeferredRoots.remove(key)
            setUpdateCatalogPhase(targetID: target.id,
                                  .failed(cancelled ? "The rescan was stopped before it finished."
                                                    : "The rescan could not run — see the console."))
        }
    }

    // MARK: Apply

    /// Commit every previewed row (and run the rename migration for every
    /// selected rename-pending row). One log summary per target.
    func applyUpdateCatalog() async {
        guard !isReadOnly else { return }
        for i in updateCatalogRows.indices {
            let row = updateCatalogRows[i]
            switch row.phase {
            case .previewed:
                await applyParkedMerge(rowIndex: i)
            case .renamePending:
                guard row.isSelected,
                      let target = scanTargets.first(where: { $0.id == row.id }) else { continue }
                setUpdateCatalogPhase(targetID: row.id, .applying)
                await userInitiatedVolumeRenameMigration(for: target)
                setUpdateCatalogPhase(targetID: row.id, .renameApplied)
            default:
                continue
            }
        }
    }

    private func applyParkedMerge(rowIndex: Int) async {
        let row = updateCatalogRows[rowIndex]
        let key = PathScope.normalize(row.targetPath)
        guard let pending = updateCatalogPendingMerges[key] else {
            setUpdateCatalogPhase(targetID: row.id, .failed("The previewed results are no longer available — run Preview again."))
            return
        }
        guard let target = scanTargets.first(where: { $0.id == row.id }) else {
            setUpdateCatalogPhase(targetID: row.id, .failed("This target is no longer in the list."))
            return
        }
        guard !target.status.isActive else {
            setUpdateCatalogPhase(targetID: row.id, .failed("This target is being scanned right now — try again when it finishes."))
            return
        }
        setUpdateCatalogPhase(targetID: row.id, .applying)
        var summary = UpdateCatalogApplySummary()
        if !pending.targetRecords.isEmpty {
            let outcome = await commitScanResults(root: pending.root,
                                                  volName: pending.volName,
                                                  targetRecords: pending.targetRecords,
                                                  scanWasComplete: pending.scanWasComplete)
            summary = UpdateCatalogApplySummary(outcome: outcome)
            saveCatalogDebounced()
            target.status = pending.scanWasComplete ? .complete : .stopped
            target.lastScannedDate = Date()
            if target.phase == .noCatalog { target.phase = .cataloged }
            persistScanDates()
            notifyTargetsChanged()
            updateGlobalScanState()
        }
        updateCatalogPendingMerges[key] = nil
        updateCatalogDeferredRoots.remove(key)
        setUpdateCatalogPhase(targetID: row.id, .applied(summary))
        let line = "Update Catalog (\(pending.volName)): \(summary.moved) moved (relinked), \(summary.new) new, \(summary.pruned) missing pruned, \(summary.unchanged) unchanged, \(summary.retainedInvisible) kept (invisible to scan options)\(summary.ambiguous > 0 ? ", \(summary.ambiguous) ambiguous left for review" : "")\(summary.tripwireFired ? " — TRIPWIRE fired, snapshot: \(summary.snapshotPath ?? "none")" : "")"
        log("  \(line)")
        appLog.write(line)
        updateCatalogLog.notice("\(line, privacy: .public)")
    }

    private func setUpdateCatalogPhase(targetID: UUID, _ phase: UpdateCatalogRow.Phase) {
        guard let i = updateCatalogRows.firstIndex(where: { $0.id == targetID }) else { return }
        updateCatalogRows[i].phase = phase
    }

    // MARK: "Looks moved" prompt

    /// Call from a user action that needs `rec`'s file. Returns true (and
    /// raises the banner, once per volume per session) when the file is
    /// missing while its volume IS mounted — the "someone moved things in
    /// Finder" signature. Returns false when the file is there, or the
    /// whole volume is offline (that's the existing offline story, not a
    /// move). Never blocks the caller.
    @discardableResult
    func noteMissingFileForUserAction(_ rec: VideoRecord) -> Bool {
        let path = rec.fullPath
        guard !path.isEmpty,
              VolumeReachability.isReachable(path: path),
              !FileManager.default.fileExists(atPath: path) else { return false }
        let volume = VolumeReachability.volumeName(forPath: path)
        let volumeKey = volume.isEmpty ? VideoScanModel.volumeRootForPathPublic(path) : volume
        guard !looksMovedPromptedVolumes.contains(volumeKey) else { return true }
        looksMovedPromptedVolumes.insert(volumeKey)
        // Longest matching target owns the path (a subfolder target beats
        // its volume root).
        let owner = scanTargets
            .filter { !$0.searchPath.isEmpty && PathScope.contains(path, within: $0.searchPath) }
            .max { $0.searchPath.count < $1.searchPath.count }
        looksMovedNotice = LooksMovedNotice(
            filename: rec.filename.isEmpty ? (path as NSString).lastPathComponent : rec.filename,
            volumeName: VolumeReachability.displayLabel(forPath: path),
            targetID: owner?.id)
        updateCatalogLog.info("Looks-moved prompt for \(path, privacy: .public)")
        return true
    }

    /// Re-arm the per-volume debounce (the user asked again — e.g. after
    /// dismissing, they can trigger it from another missing file on the
    /// same volume only via Update Catalog itself, which is why the sheet
    /// clears it).
    func resetLooksMovedDebounce(forVolume volume: String? = nil) {
        if let volume { looksMovedPromptedVolumes.remove(volume) } else { looksMovedPromptedVolumes.removeAll() }
    }

    func dismissLooksMovedNotice() {
        looksMovedNotice = nil
    }

    /// Banner's primary button: open the door with the file's target
    /// preselected.
    func openUpdateCatalogFromLooksMoved() {
        let notice = looksMovedNotice
        looksMovedNotice = nil
        if let id = notice?.targetID {
            openUpdateCatalog(preselecting: [id])
        } else {
            openUpdateCatalog()
        }
    }
}
