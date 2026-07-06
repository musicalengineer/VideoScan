import Foundation

// MARK: - Duplicate Analysis + Same-Volume Deletion
//
// analyzeDuplicates feeds DuplicateDetector, then UI uses the result to
// surface "Delete X duplicates on Y volume" affordances. The actual delete
// is conservative: same-volume only — never deletes a file whose only
// surviving copy lives on a different (e.g. backup) volume. The keeper
// lookup + volumeRoot helpers stay alongside the delete because they're
// the policy that makes the deletion safe.

extension VideoScanModel {

    /// Duplicate analysis under the analysis-ledger contract
    /// (docs/analysis_ledger_design.md, 2026-07-05):
    ///
    ///   - `selectedIDs == nil` (Analyze All): INCREMENTAL. Only records
    ///     never stamped (`dupAnalyzedAt == nil` — new files, or records
    ///     invalidated by a content change) are pending. The pass examines
    ///     the pending delta plus everything it could possibly group with
    ///     (`DuplicateDetector.affectedSubset`); all other groups are
    ///     settled history and keep their identity. An unchanged catalog
    ///     is an instant no-op.
    ///   - `selectedIDs` non-empty: explicit "redo THESE" — cleared and
    ///     re-derived (legacy semantics).
    ///
    /// The grouping pass runs OFF the main actor over `snapshotClone`d
    /// records (the CatalogStore off-main contract); results copy back in
    /// one main-actor batch. Pre-fix, a full-catalog pass ran synchronously
    /// on main — the "Analyze duplicates on all" beachball (GH #104).
    func analyzeDuplicates(selectedIDs: Set<UUID>? = nil) async {
        isAnalyzingDuplicates = true
        duplicateStatus = ""
        defer {
            isAnalyzingDuplicates = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                if self?.isAnalyzingDuplicates == false { self?.duplicateStatus = "" }
            }
        }

        let scope: [VideoRecord]
        let deltaCount: Int
        if let ids = selectedIDs, !ids.isEmpty {
            scope = records.filter { ids.contains($0.id) }
            DuplicateDetector.clear(records: scope)
            deltaCount = scope.count
        } else {
            let active = pfActiveRecords(records)
            let delta = active.filter { $0.dupAnalyzedAt == nil }
            guard !delta.isEmpty else {
                duplicateStatus = "Duplicates up to date"
                log("Duplicate analysis: nothing new since the last pass — 0 records pending.")
                return
            }
            deltaCount = delta.count
            scope = DuplicateDetector.affectedSubset(delta: delta, allActive: active)
        }

        duplicateStatus = "Analyzing \(scope.count) files (\(deltaCount) new/changed)…"

        // Clone on main (snapshotClone contract), group OFF main, copy the
        // six result fields back in one batch. Position-zipped: the clone
        // array mirrors `scope` element for element.
        let clones = scope.map { $0.snapshotClone() }
        let summary = await DuplicateDetector.analyzeDetached(clones)
        let stamp = Date()
        // QA P2-3: a record pruned during the await gets no ghost writes
        // and no stamp (symmetric with the correlate atomicity guard).
        let liveInstances = Set(records.map(ObjectIdentifier.init))
        for (original, clone) in zip(scope, clones) {
            guard liveInstances.contains(ObjectIdentifier(original)) else { continue }
            original.duplicateGroupID = clone.duplicateGroupID
            original.duplicateConfidence = clone.duplicateConfidence
            original.duplicateDisposition = clone.duplicateDisposition
            original.duplicateReasons = clone.duplicateReasons
            original.duplicateBestMatchFilename = clone.duplicateBestMatchFilename
            original.duplicateGroupCount = clone.duplicateGroupCount
            // Ledger stamp — including "checked, found unique".
            original.dupAnalyzedAt = stamp
        }

        duplicateStatus = "\(summary.extraCopies) duplicates in \(summary.groups) groups"

        log("""

        Duplicate analysis complete (examined \(scope.count) of \(records.count) — \(deltaCount) new/changed):
          \(summary.groups) groups
          \(summary.highConfidenceGroups) high, \(summary.mediumConfidenceGroups) medium, \(summary.lowConfidenceGroups) low confidence
          \(summary.extraCopies) extra copy candidates, \(summary.reviewItems) review items
        """)

        // One mutation notification (debounced save + cache invalidation +
        // view refresh) replaces the records=[]/records=tmp double-republish.
        NotificationCenter.default.post(name: .videoScanCatalogMutated, object: nil)
    }

    /// Delete high-confidence duplicate files on a given volume, but ONLY when
    /// the keeper (the `.keep` file in the same duplicate group) is also on the
    /// same volume.  This prevents deleting a file whose only surviving copy
    /// lives on a different (e.g. backup) volume.
    @discardableResult
    func deleteDuplicates(onVolume volumePath: String) -> (deleted: Int, failed: Int, skipped: Int, bytesFreed: Int64) {
        isDeletingDuplicates = true
        defer { isDeletingDuplicates = false }

        // Build keeper lookup: groupID → keeper record
        let keepers = keepersByGroupID()

        // Only target extra copies whose keeper is on the same volume.
        // Component-boundary scoping (PathScope) so a sibling volume can
        // never be swept into a destructive file deletion. // regression: codex C2
        let targets = records.filter { rec in
            guard rec.duplicateDisposition == .extraCopy,
                  PathScope.contains(rec.fullPath, within: volumePath),
                  let groupID = rec.duplicateGroupID,
                  let keeper = keepers[groupID] else { return false }
            return PathScope.contains(keeper.fullPath, within: volumePath)
        }

        let skippedCount = records.filter { rec in
            rec.duplicateDisposition == .extraCopy &&
            PathScope.contains(rec.fullPath, within: volumePath) &&
            !targets.contains(where: { $0.id == rec.id })
        }.count

        guard !targets.isEmpty else {
            if skippedCount > 0 {
                log("\nNo same-volume duplicates to delete on \(volumePath). Skipped \(skippedCount) file(s) whose keeper is on a different volume.")
            } else {
                log("\nNo high-confidence duplicates to delete on \(volumePath)")
            }
            return (0, 0, skippedCount, 0)
        }

        log("\nDeleting \(targets.count) same-volume duplicate(s) on \(volumePath)…")
        if skippedCount > 0 {
            log("  (Skipping \(skippedCount) file(s) whose keeper is on a different volume)")
        }

        var deleted = 0
        var failed = 0
        var bytesFreed: Int64 = 0
        let fm = FileManager.default

        for record in targets {
            let path = record.fullPath
            do {
                let attrs = try fm.attributesOfItem(atPath: path)
                let size = (attrs[.size] as? Int64) ?? 0
                try fm.removeItem(atPath: path)
                bytesFreed += size
                deleted += 1
                log("  Deleted: \(record.filename)")
            } catch {
                failed += 1
                log("  FAILED to delete \(record.filename): \(error.localizedDescription)")
            }
        }

        // Remove deleted records from the catalog
        let deletedPaths = Set(targets.filter { !FileManager.default.fileExists(atPath: $0.fullPath) }.map { $0.fullPath })
        records.removeAll { deletedPaths.contains($0.fullPath) }

        let freed = ByteCountFormatter.string(fromByteCount: bytesFreed, countStyle: .file)
        log("\nDuplicate deletion complete: \(deleted) deleted, \(failed) failed, \(skippedCount) skipped (cross-volume), \(freed) freed")
        duplicateStatus = "\(deleted) deleted, \(freed) freed"

        return (deleted, failed, skippedCount, bytesFreed)
    }

    /// Returns the distinct volume root paths that have high-confidence duplicate
    /// extra copies deletable on that volume (keeper also on same volume).
    func volumesWithDeletableDuplicates() -> [(path: String, count: Int)] {
        let keepers = keepersByGroupID()
        let extras = records.filter { rec in
            guard rec.duplicateDisposition == .extraCopy,
                  let groupID = rec.duplicateGroupID,
                  let keeper = keepers[groupID] else { return false }
            let volume = volumeRoot(for: rec.fullPath)
            let keeperVolume = volumeRoot(for: keeper.fullPath)
            return volume == keeperVolume
        }
        var volumeCounts: [String: Int] = [:]
        for record in extras {
            let volume = volumeRoot(for: record.fullPath)
            volumeCounts[volume, default: 0] += 1
        }
        return volumeCounts.sorted { $0.key < $1.key }.map { (path: $0.key, count: $0.value) }
    }

    /// Build a lookup from duplicate group ID to the keeper record in that group.
    func keepersByGroupID() -> [UUID: VideoRecord] {
        var result: [UUID: VideoRecord] = [:]
        for record in records {
            if record.duplicateDisposition == .keep, let groupID = record.duplicateGroupID {
                result[groupID] = record
            }
        }
        return result
    }

    func volumeRoot(for path: String) -> String {
        if path.hasPrefix("/Volumes/") {
            let parts = path.split(separator: "/", maxSplits: 3)
            if parts.count >= 2 {
                return "/\(parts[0])/\(parts[1])"
            }
        }
        // For non-/Volumes paths, use the scan target root that contains it
        for target in scanTargets {
            if PathScope.contains(path, within: target.searchPath) { // regression: codex C2
                return target.searchPath
            }
        }
        return (path as NSString).deletingLastPathComponent
    }
}
