// VideoScanModel+VolumeRenameUndo.swift
// The dialog's Undo after a volume-rename migration
// (VideoScanModel+VolumeRenameMigration.swift does the migration).
//
// Adversarial review 2026-10-18 #2 (VOL-5). Since cutover B2.3 the
// migration's safety copy under catalog.sqlite is a sealed
// `catalog.pre-volume-rename.<stamp>.sqlite`, but Undo read it with the
// catalog.json decoder, got nil, and said "Couldn't read the pre-update
// snapshot" — the rename could not be undone. Undo now reads the .sqlite
// copy (`loadSafetyCopy`); since JSON gone, slice 2b (2026-10-21), a
// pre-cutover `.json` copy is refused in words and never read.
//
// It also no longer swaps the whole records array for the copy. That was
// verbatim restore: under catalog.json it silently dropped every record
// added (and reverted every edit made) since the migration; under
// catalog.sqlite it would have PURGED those added rows (B2.3's explicit
// purge of "ids the snapshot does not hold"), and a record loaded from
// catalog.sqlite carries the documented load losses (pair confidence; a
// field whose copies disagree loads empty), which a verbatim restore would
// have written back over the live values. Undo now reverts exactly what the
// migration wrote — `fullPath`, `directory`, `scanContext.volumeName` — on
// each record that still carries the migration's rewrite, and touches
// nothing else. No record leaves the catalog, so nothing is purged.
//
// (For Rick: think of the migration as a batch of in-place
// `rec.path = rewrite(rec.path)` assignments; Undo is the inverse batch,
// guarded so it only applies where the forward assignment is still the
// current value — a compare-and-swap per record, not a memcpy of the old
// array.)

import Foundation
import os
import VideoScanCore

private let volumeRenameUndoLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                         category: "volumeRename")

extension VideoScanModel {

    /// What one Undo did: records put back, and records under the new path
    /// that no longer carry the migration's rewrite (moved, rescanned,
    /// renamed since) and were left as they are.
    struct VolumeRenameRevert: Equatable {
        var reverted = 0
        var leftAlone = 0
    }

    /// Undo an auto/accepted migration: put back the three fields the
    /// migration wrote on every record that still carries its rewrite, put
    /// the scan target back on its old path, rebuild the search index,
    /// persist, and suppress the auto pass for this volume so the very next
    /// rebuild doesn't redo what Rick just undid. Returns false (and
    /// changes nothing) when the safety copy can't be read back — or is a
    /// catalog.json copy, which is refused.
    /// `async` because the catalog.sqlite copy is read on the store's queue.
    @discardableResult
    func undoVolumeRenameMigration(_ notice: VolumeRenameNotice) async -> Bool {
        guard case .migrated(let snapshotPath) = notice.kind else { return false }
        guard let snapshot = await loadSafetyCopy(atPath: snapshotPath) else {
            log("  ⚠ Couldn't read the pre-update snapshot at \(snapshotPath) — the catalog was left as-is.")
            volumeRenameUndoLog.error("Volume rename UNDO failed: snapshot unreadable at \(snapshotPath, privacy: .public)")
            pendingVolumeRenameNotice = nil
            return false
        }
        // Suppress BEFORE mutating records — a detection rebuild's auto
        // pass must not re-migrate.
        volumeRenameAutoSuppressed.insert(PathScope.normalize(notice.oldTargetPath))
        let revert = revertVolumeRenameRewrites(from: snapshot, notice: notice)
        if let target = scanTargets.first(where: { $0.id == notice.targetID }) {
            target.searchPath = notice.oldTargetPath
            target.isReachable = VolumeReachability.isReachable(path: notice.oldTargetPath)
            persistScanTargets()
            persistScanDates()
        }
        searchIndex.rebuild(records: records)
        if !Self.isRunningTests { try? searchIndex.saveToDisk() }
        notifyVolumeAggregatesStale()
        noteCatalogChangedForDossierCounts()
        notifyTargetsChanged()
        saveCatalogNow()
        pendingVolumeRenameNotice = nil
        noteVolumeRenameCandidatesStale()
        volumeRenameUndoLog.notice("Volume rename UNDONE: \(revert.reverted) record(s) put back from \(snapshotPath, privacy: .public), \(revert.leftAlone) changed since and left alone; target back to \(notice.oldTargetPath, privacy: .public)")
        appLog.write("Volume rename undone: \(notice.newVolumeName) → \(notice.oldVolumeName); \(revert.reverted) record(s) put back from \(snapshotPath); \(revert.leftAlone) changed since and left alone")
        if revert.leftAlone > 0 {
            log("Undone — \(revert.reverted) file record(s) point at \(notice.oldVolumeName) again. \(revert.leftAlone) record(s) changed since the update and were left as they are.")
        } else {
            log("Undone — the catalog is back to how it was before the \(notice.oldVolumeName) → \(notice.newVolumeName) update.")
        }
        return true
    }

    /// The inverse of the migration's apply step, per record: when the live
    /// record's path is exactly what the migration made of the copy's path,
    /// the copy's `fullPath`, `directory` and `scanContext.volumeName` go
    /// back. Every other record — added since, untouched by the migration,
    /// or changed since — is left exactly as it is. One O(records) pass on
    /// the main actor, no awaits.
    func revertVolumeRenameRewrites(from snapshot: [VideoRecord], notice: VolumeRenameNotice) -> VolumeRenameRevert {
        var before: [UUID: VideoRecord] = [:]
        before.reserveCapacity(snapshot.count)
        for old in snapshot { before[old.id] = old }
        var revert = VolumeRenameRevert()
        for rec in records {
            guard let old = before[rec.id],
                  let rewritten = Self.rewritePathPrefix(old.fullPath, from: notice.oldTargetPath, to: notice.newTargetPath)
            else { continue }
            guard rec.fullPath == rewritten else {
                if Self.rewritePathPrefix(rec.fullPath, from: notice.newTargetPath, to: notice.oldTargetPath) != nil {
                    revert.leftAlone += 1
                }
                continue
            }
            invalidateThumbnailCacheEntry(forPath: rec.fullPath)
            rec.fullPath = old.fullPath
            rec.directory = old.directory
            rec.scanContext.volumeName = old.scanContext.volumeName
            revert.reverted += 1
        }
        return revert
    }

    /// Why a `.json` safety copy is not read (JSON gone, slice 2b).
    nonisolated static let jsonSafetyCopyWords =
        "it is a catalog.json copy from before the switch to catalog.sqlite, and VideoScan no longer reads catalog.json; "
            + "the rename was not undone and the catalog is unchanged"

    /// Read back a safety copy `snapshotCatalog` wrote: a sealed
    /// catalog.sqlite copy (`.sqlite`, cutover B2.3) through the app's one
    /// SQLite loader. Anything else — a pre-cutover
    /// `catalog.pre-volume-rename.*.json` copy — is refused in words and
    /// never read (JSON gone, slice 2b, 2026-10-21). nil = unreadable or
    /// refused (the caller changes nothing).
    func loadSafetyCopy(atPath path: String) async -> [VideoRecord]? {
        guard path.hasSuffix(".sqlite") else {
            catalogAuthorityNote("REFUSED reading the safety copy \(path) — \(Self.jsonSafetyCopyWords)")
            return nil
        }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        // Read-only, never `open(at:)` (#359 QA r2): a read-write open would
        // switch the sealed copy to WAL, create sidecars and maybe migrate it —
        // the safety copy would no longer be the copy that was taken. A sealed
        // copy (VACUUM INTO, rollback journal) opens with nothing created
        // beside it; one an older build already switched to WAL falls back to
        // the plain read-only door (no migration: an older schema is refused).
        let url = URL(fileURLWithPath: path)
        let repository = GRDBCatalogRepository()
        var opened = await repository.openSealedSnapshot(at: url)
        if case .refused = opened, GRDBCatalogRepository.sealedSnapshotRefusal(url) != nil {
            opened = await repository.openReadOnly(at: url, reason: "a safety copy, read for Undo")
        }
        if case .refused(let reason) = opened {
            catalogAuthorityNote("REFUSED reading the safety copy \(path) — \(reason)")
            return nil
        }
        // Close awaited on both paths (≈ RAII by hand: Swift has no async defer).
        let loaded: SQLiteCatalogLoader.LoadResult
        do {
            loaded = try await SQLiteCatalogLoader.load(repository: repository)
        } catch {
            await repository.close()
            catalogAuthorityNote("REFUSED reading the safety copy \(path) — \(error)")
            return nil
        }
        await repository.close()
        return loaded.records
    }
}
