import Foundation

private struct DuplicateDeletionWorkItem: Sendable {
    let path: String
    let keeperPath: String
    let keeperFilename: String
}

private enum DuplicateDeletionDiskOutcome: Sendable {
    case deleted(bytes: Int64)
    case refused(reason: String)
    case failed(reason: String)
    case retained(path: String, reason: String)
}

private enum DuplicateDeletionDiskWorker {
    /// Full verification and removal run outside the main actor. The worker
    /// carries only immutable value snapshots — never VideoRecord instances.
    static func run(_ item: DuplicateDeletionWorkItem,
                    hooks: SignatureVerification.Hooks)
        -> DuplicateDeletionDiskOutcome {
        switch SignatureVerification.verify(keeperPath: item.keeperPath,
                                             duplicatePath: item.path,
                                             hooks: hooks) {
        case .failure(let failure):
            return .refused(reason: duplicateRefusalNote(
                failure, keeper: item.keeperFilename))
        case .success(let proof):
            switch SignatureVerification.quarantineAndDelete(proof, hooks: hooks) {
            case .deleted(let bytes): return .deleted(bytes: bytes)
            case .refused(let failure):
                return .refused(reason: duplicateRefusalNote(
                    failure, keeper: item.keeperFilename))
            case .failed(let reason): return .failed(reason: reason)
            case .retainedQuarantine(let path, let reason):
                return .retained(path: path, reason: reason)
            }
        }
    }
}

private func duplicateRefusalNote(_ failure: SignatureVerification.Failure,
                                  keeper: String) -> String {
    switch failure {
    case .contentDiffers:
        return "content differs from keeper \(keeper) — NOT a duplicate"
    case .unreadable(let path):
        return "could not read \(URL(fileURLWithPath: path).lastPathComponent) to verify"
    case .samePath:
        return "keeper and copy are the same file"
    case .changedSinceVerification(let path):
        return "\(URL(fileURLWithPath: path).lastPathComponent) changed during verification"
    case .cancelled:
        return "verification was cancelled"
    }
}

// MARK: - Duplicate Analysis + Same-Volume Deletion
//
// analyzeDuplicates feeds DuplicateDetector, then UI uses the result to
// surface "Delete X duplicates on Y volume" affordances. The actual delete
// is conservative: same-volume only — never deletes a file whose only
// surviving copy lives on a different (e.g. backup) volume. The keeper
// lookup + volumeRoot helpers stay alongside the delete because they're
// the policy that makes the deletion safe.

extension VideoScanModel {

    struct DuplicateDeletionSelection {
        let targets: [VideoRecord]
        let keepers: [UUID: VideoRecord]
        let skippedCount: Int
    }

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
        //
        // Built with an explicit loop, NOT `scope.map { $0.snapshotClone() }`:
        // region analysis tracks "fresh array + appends of `sending` results
        // stays disconnected", but a generic `map` erases the `sending`-ness
        // of the closure result and conservatively merges the array into the
        // main-actor region — which made the transfer into the @concurrent
        // analyzer warn under Swift 6 checking. `analyzeDetached` consumes
        // its argument and returns the SAME clones back (sending both ways);
        // everything below reads the returned `clones` array.
        var freshClones: [VideoRecord] = []
        freshClones.reserveCapacity(scope.count)
        for rec in scope { freshClones.append(rec.snapshotClone()) }
        // Keeper policy is a Sendable snapshot of the settings + per-target
        // facts (role / reachable / retired / master), built HERE on main
        // because CatalogScanTarget can't cross the actor boundary.
        let keeperPolicy = duplicateKeeperPolicy()
        let (clones, summary) = await DuplicateDetector.analyzeDetached(
            freshClones, keeperPolicy: keeperPolicy)
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

    /// The keeper-election policy for THIS catalog right now: the
    /// user-ordered precedence list plus a snapshot of every scan target's
    /// role / reachability / retirement / master-archive status
    /// (2026-08-18). Pure value — safe to hand to the off-main analyzer.
    func duplicateKeeperPolicy() -> DuplicateKeeperPolicy {
        var facts: [String: DuplicateKeeperPolicy.VolumeFacts] = [:]
        for target in scanTargets {
            facts[target.searchPath] = DuplicateKeeperPolicy.VolumeFacts(
                role: target.role,
                isReachable: target.isReachable,
                isRetired: target.isRetired,
                isMasterArchive: isMasterArchive(target))
        }
        return DuplicateKeeperPolicy(
            precedence: duplicateKeeperSettings.volumePrecedence,
            facts: facts)
    }

    /// Delete high-confidence duplicate files on a given volume, but ONLY when
    /// the keeper (the `.keep` file in the same duplicate group) is also on the
    /// same volume.  This prevents deleting a file whose only surviving copy
    /// lives on a different (e.g. backup) volume.
    @discardableResult
    func deleteDuplicates(onVolume volumePath: String,
                          verificationHooks: SignatureVerification.Hooks = .live) async
        -> (deleted: Int, failed: Int, skipped: Int, bytesFreed: Int64) {
        guard !isReadOnly else {
            duplicateStatus = "Deletion unavailable in viewer mode"
            log("\nREFUSED duplicate deletion on \(volumePath): this Mac is in read-only viewer mode.")
            return (0, 0, 0, 0)
        }
        guard !isDeletingDuplicates else {
            log("\nREFUSED duplicate deletion on \(volumePath): another duplicate deletion is already running.")
            return (0, 0, 0, 0)
        }
        isDeletingDuplicates = true
        defer { isDeletingDuplicates = false }

        let selection = duplicateDeletionSelection(onVolume: volumePath)
        // Master Archive files are never bulk-deleted, even as "extras".
        let targets = excludingMasterArchiveFiles(selection.targets, verb: "Delete Duplicates")
        let keepers = selection.keepers
        let skippedCount = selection.skippedCount

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
        var refused = 0
        var bytesFreed: Int64 = 0
        var catalogMutated = false

        // EVERY deletion is gated on a full byte-for-byte comparison,
        // performed HERE, immediately before the remove.
        //
        // WHY THIS GATE EXISTS (codex #333, 2026-08-12). Until tonight
        // this loop deleted whatever the scorer marked `.extraCopy`, and
        // the scorer's strongest signal is `partialMD5` + size — a
        // 64 KB HEAD-AND-TAIL hash that never looks at the middle of a
        // file. Two Avid MXF essence files from one session share a
        // wrapper header and can be padded to the same length; add a
        // matching filename stem (3) and duration (3) to the hash's 8
        // and they reach 14, past the high-confidence threshold of 12.
        // Two DISTINCT family videos, permanently removed, silently.
        //
        // The comparison is deliberately fresh rather than trusting any
        // stored signature: a hash computed last month says nothing
        // about the bytes on disk now, and the gap between "decided to
        // delete" and "deleted" is exactly the window that matters.
        //
        // This is slow — it reads both files in full — and that is correct.
        // The disk work is not allowed to freeze SwiftUI, however. Each pair
        // is verified and removed in a detached task; the main actor awaits
        // it and remains responsive, updating progress between pairs.
        for (offset, record) in targets.enumerated() {
            guard !Task.isCancelled else {
                failed += targets.count - offset
                log("  Duplicate deletion cancelled before verification completed")
                break
            }
            guard let groupID = record.duplicateGroupID,
                  let keeper = keepers[groupID] else {
                refused += 1
                log("  REFUSED \(record.filename): no keeper to verify against")
                continue
            }

            duplicateStatus = "Verifying duplicate \(offset + 1) of \(targets.count)…"
            let item = DuplicateDeletionWorkItem(
                path: record.fullPath,
                keeperPath: keeper.fullPath,
                keeperFilename: keeper.filename)
            let expectedID = record.id
            let expectedPath = record.fullPath
            let worker = Task.detached(priority: .userInitiated) {
                DuplicateDeletionDiskWorker.run(item, hooks: verificationHooks)
            }
            let outcome = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            let currentRecord = records.first {
                $0.id == expectedID && $0.fullPath == expectedPath
            }

            switch outcome {
            case .refused(let reason):
                refused += 1
                currentRecord?.duplicateDisposition = .review
                currentRecord?.duplicateReasons = reason
                catalogMutated = catalogMutated || currentRecord != nil
                log("  REFUSED \(record.filename): \(reason)")
            case .failed(let reason):
                failed += 1
                log("  FAILED to delete \(record.filename): \(reason)")
            case .deleted(let bytes):
                bytesFreed += bytes
                deleted += 1
                // Metadata carry-over (2026-08-18). The bytes are gone —
                // verified identical to the keeper — but the ROW still
                // holds whatever Rick put on this copy (stars, people,
                // notes, tags, provenance stamp). Fold it into the
                // keeper before the row leaves the catalog, using the
                // SAME union rules as repair adoption
                // (applyHumanMetadataInheritance): never clobber a
                // judgment already on the keeper, never touch machine
                // metadata. Uses the live keeper object from `keepers`
                // (a `records` member), so the merge lands in the
                // catalog, not on a clone.
                let extraRow = currentRecord ?? record
                let carried = applyHumanMetadataInheritance(from: extraRow, to: keeper)
                if !carried.isEmpty {
                    log("  Carried over to \(keeper.filename) from \(record.filename): "
                        + carried.joined(separator: ", "))
                    catalogMutated = true
                }
                if let index = records.firstIndex(where: {
                    $0.id == expectedID && $0.fullPath == expectedPath
                }) {
                    records.remove(at: index)
                    catalogMutated = true
                } else {
                    log("  Catalog changed while deleting \(record.filename); current row retained")
                }
                log("  Deleted (verified identical to \(keeper.filename)): \(record.filename)")
            case .retained(let path, let reason):
                failed += 1
                log("  RETAINED safely at \(path): \(reason)")
            }
        }

        if catalogMutated {
            NotificationCenter.default.post(name: .videoScanCatalogMutated, object: nil)
        }

        let freed = ByteCountFormatter.string(fromByteCount: bytesFreed, countStyle: .file)
        log("\nDuplicate deletion complete: \(deleted) deleted, \(failed) failed, "
            + "\(refused) refused by verification, \(skippedCount) skipped (cross-volume), \(freed) freed")
        if refused > 0 {
            log("  \(refused) file(s) were NOT identical to their keeper despite matching "
                + "on hash/name/duration — they are marked Review and left on disk.")
        }
        duplicateStatus = "\(deleted) deleted, \(freed) freed"

        return (deleted, failed, skippedCount, bytesFreed)
    }

    /// Human-readable reason a verified deletion was refused.
    static func refusalNote(_ failure: SignatureVerification.Failure,
                            keeper: String) -> String {
        duplicateRefusalNote(failure, keeper: keeper)
    }

    /// O(N) candidate planning, isolated from disk I/O so the adopted 100k
    /// scale gate can pin it independently of media size.
    func duplicateDeletionSelection(onVolume volumePath: String)
        -> DuplicateDeletionSelection {
        let keepers = keepersByGroupID()
        let targets = records.filter { rec in
            guard rec.duplicateDisposition == .extraCopy,
                  PathScope.contains(rec.fullPath, within: volumePath),
                  let groupID = rec.duplicateGroupID,
                  let keeper = keepers[groupID] else { return false }
            return PathScope.contains(keeper.fullPath, within: volumePath)
        }
        let targetIDs = Set(targets.map(\.id))
        let skippedCount = records.lazy.filter { rec in
            rec.duplicateDisposition == .extraCopy
                && PathScope.contains(rec.fullPath, within: volumePath)
                && !targetIDs.contains(rec.id)
        }.count
        return DuplicateDeletionSelection(targets: targets,
                                          keepers: keepers,
                                          skippedCount: skippedCount)
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
