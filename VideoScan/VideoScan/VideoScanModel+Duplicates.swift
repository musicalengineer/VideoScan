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
        /// Everything eligible for verify+remove on this volume: the
        /// same-drive extras, plus (only when "Also clean up working
        /// copies" is ON) the working copies whose master passed
        /// `DuplicateKeeperPolicy.crossVolumeVerdict`.
        let targets: [VideoRecord]
        let keepers: [UUID: VideoRecord]
        /// Extras on this volume that are NOT in `targets`.
        let skippedCount: Int
        /// How many of `targets` have their keeper on this same drive.
        let sameVolumeCount: Int
        /// How many of `targets` have their keeper on another drive
        /// (always 0 when the toggle is OFF).
        let crossVolumeCount: Int
        /// Display names of the drives holding the keepers of the
        /// cross-volume targets, sorted, deduped.
        let crossVolumeKeeperVolumes: [String]
        /// Why the skipped ones were skipped (family language) → count.
        /// With the toggle OFF this is the single legacy reason.
        let skippedReasons: [(reason: String, count: Int)]
        /// True when the mode was ON for this selection.
        let crossVolumeMode: Bool
        /// Number of catalog records on this volume — the denominator of
        /// the ">20% of the volume" snapshot tripwire.
        let volumeRecordCount: Int

        /// The split line: "N same-drive extras" or
        /// "N same-drive extras + M working copies whose master is on X, Y".
        var summaryLine: String {
            let same = "\(sameVolumeCount) same-drive extra\(sameVolumeCount == 1 ? "" : "s")"
            guard crossVolumeMode, crossVolumeCount > 0 else { return same }
            let vols = crossVolumeKeeperVolumes.joined(separator: ", ")
            return same + " + \(crossVolumeCount) working cop\(crossVolumeCount == 1 ? "y" : "ies") whose master is on \(vols)"
        }

        /// The confirmation-alert body (WorkingCopyCleanupText.confirmation).
        func confirmationText(volumeName: String) -> String {
            WorkingCopyCleanupText.confirmation(total: targets.count, volume: volumeName,
                                                sameDrive: sameVolumeCount, workingCopies: crossVolumeCount,
                                                masterVolumes: crossVolumeKeeperVolumes)
        }
    }

    /// Cross-volume batches larger than this (files) or than
    /// `crossVolumeSnapshotFraction` of the volume's records take a
    /// catalog.pre-dup-crossvolume.<stamp>.json recovery snapshot first
    /// (same helper as the scan-merge / target-removal tripwires). No
    /// snapshot → the cross-volume part degrades to nothing (fail safe);
    /// the same-drive part proceeds as before.
    static let crossVolumeSnapshotThreshold = 50
    static let crossVolumeSnapshotFraction = 0.20

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
        var targets = excludingMasterArchiveFiles(selection.targets, verb: "Delete Duplicates")
        let keepers = selection.keepers
        let skippedCount = selection.skippedCount
        let skippedNote = selection.skippedReasons
            .map { "\($0.count) file(s): \($0.reason)" }
            .joined(separator: "; ")
        let volumeName = URL(fileURLWithPath: volumePath).lastPathComponent
        // Which of the targets are working copies (master on another
        // drive) — drives the per-file [WORKING-COPY] log line.
        let workingCopyIDs: Set<UUID> = selection.crossVolumeMode
            ? Set(targets.compactMap { rec -> UUID? in
                guard let g = rec.duplicateGroupID, let k = keepers[g] else { return nil }
                return PathScope.contains(k.fullPath, within: volumePath) ? nil : rec.id
              })
            : []

        guard !targets.isEmpty else {
            if skippedCount > 0 {
                log("\nNo duplicates to delete on \(volumePath). Skipped \(skippedCount) file(s) — \(skippedNote).")
            } else {
                log("\nNo high-confidence duplicates to delete on \(volumePath)")
            }
            return (0, 0, skippedCount, 0)
        }

        // Cross-volume tripwire (2026-08-18): a big cross-drive batch
        // takes a recovery snapshot first; if it can't be written, the
        // cross-volume part is dropped and only same-drive extras proceed.
        if selection.crossVolumeMode, selection.crossVolumeCount > 0 {
            let fraction = selection.volumeRecordCount > 0
                ? Double(selection.crossVolumeCount) / Double(selection.volumeRecordCount) : 1
            if selection.crossVolumeCount > Self.crossVolumeSnapshotThreshold
                || fraction > Self.crossVolumeSnapshotFraction {
                if let snap = snapshotCatalog(prefix: "pre-dup-crossvolume") {
                    log("\nPre-delete safety snapshot (\(selection.crossVolumeCount) cross-drive extras): \(snap)")
                } else {
                    let before = targets.count
                    targets = targets.filter { rec in
                        guard let g = rec.duplicateGroupID, let k = keepers[g] else { return false }
                        return PathScope.contains(k.fullPath, within: volumePath)
                    }
                    log("\n⚠️ Could not write the pre-delete safety snapshot — leaving the \(before - targets.count) cross-drive extra(s) alone; only same-drive extras will be removed.")
                    guard !targets.isEmpty else { return (0, 0, skippedCount + before, 0) }
                }
            }
        }

        if selection.crossVolumeMode {
            log("\n" + WorkingCopyCleanupText.logSummary(volume: volumeName,
                    detail: "removing \(targets.count) extra cop\(targets.count == 1 ? "y" : "ies") — \(selection.summaryLine)…"))
        } else {
            log("\nDeleting \(targets.count) same-volume duplicate(s) on \(volumePath)…")
        }
        if skippedCount > 0 {
            log("  (Skipping \(skippedCount) file(s) — \(skippedNote))")
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
                if workingCopyIDs.contains(expectedID) {
                    log("  " + WorkingCopyCleanupText.logRemoved(path: expectedPath, masterPath: keeper.fullPath))
                } else {
                    log("  Deleted (verified identical to \(keeper.filename)): \(record.filename)")
                }
            case .retained(let path, let reason):
                failed += 1
                log("  RETAINED safely at \(path): \(reason)")
            }
        }

        if catalogMutated {
            NotificationCenter.default.post(name: .videoScanCatalogMutated, object: nil)
        }

        let freed = ByteCountFormatter.string(fromByteCount: bytesFreed, countStyle: .file)
        let completion = "\(deleted) deleted, \(failed) failed, \(refused) refused by verification, "
            + "\(skippedCount) skipped, \(freed) freed (\(selection.summaryLine))"
        if selection.crossVolumeMode {
            log("\n" + WorkingCopyCleanupText.logSummary(volume: volumeName, detail: "complete — " + completion))
        } else {
            log("\nDuplicate deletion complete: " + completion)
        }
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
    ///
    /// Toggle OFF (default): byte-for-byte the pre-2026-08-18 rule — an
    /// extra on `volumePath` is a target iff its master (keeper) is also
    /// under `volumePath`. Toggle ON ("Also clean up working copies"): a
    /// working copy is ALSO a target iff `crossVolumeVerdict` says
    /// eligible (master online, not retired, known, strictly higher-ranked
    /// drive) and the copy is not itself a Master Archive file. Everything
    /// skipped carries a WorkingCopyCleanupText reason for the log.
    func duplicateDeletionSelection(onVolume volumePath: String)
        -> DuplicateDeletionSelection {
        let keepers = keepersByGroupID()
        let crossMode = duplicateKeeperSettings.alsoCleanUpWorkingCopies
        let policy = crossMode ? duplicateKeeperPolicy() : nil
        let hereRoot = volumeRoot(for: volumePath)
        let hasMasterArchive = masterArchiveRootPath != nil

        var targets: [VideoRecord] = []
        var sameCount = 0
        var crossCount = 0
        var crossKeeperVolumes = Set<String>()
        var skipped: [String: Int] = [:]
        var volumeRecordCount = 0
        // Memo: keeper-volume verdicts repeat across a drive's records
        // (a handful of drives), so cache per keeper ROOT — keeps this
        // O(N) with a tiny constant, no per-record policy scans.
        var verdictByKeeperRoot: [String: DuplicateKeeperPolicy.CrossVolumeVerdict] = [:]

        for rec in records where PathScope.contains(rec.fullPath, within: volumePath) {
            volumeRecordCount += 1
            guard rec.duplicateDisposition == .extraCopy else { continue }
            guard let groupID = rec.duplicateGroupID, let keeper = keepers[groupID] else {
                skipped[WorkingCopyCleanupText.reasonNoMaster, default: 0] += 1
                continue
            }
            if PathScope.contains(keeper.fullPath, within: volumePath) {
                targets.append(rec)
                sameCount += 1
                continue
            }
            guard crossMode, let policy else {
                skipped[WorkingCopyCleanupText.reasonMasterOnAnotherDrive, default: 0] += 1
                continue
            }
            // A copy that lives in the Master Archive is never a working
            // copy (the bulk-delete exclusion still applies downstream;
            // this only names it in the skipped reasons).
            if hasMasterArchive, isArchiveCopy(rec) || isInsideMasterArchive(path: rec.fullPath) {
                skipped[WorkingCopyCleanupText.reasonMasterArchiveFile, default: 0] += 1
                continue
            }
            let keeperRoot = volumeRoot(for: keeper.fullPath)
            let verdict: DuplicateKeeperPolicy.CrossVolumeVerdict
            if let cached = verdictByKeeperRoot[keeperRoot] {
                verdict = cached
            } else {
                // Rank the CHOSEN drive (volumePath) rather than each file:
                // every extra here shares it, which is what makes the
                // per-keeper-root memo exact.
                verdict = policy.crossVolumeVerdict(extraPath: volumePath, volumeRoot: hereRoot,
                                                    keeperPath: keeper.fullPath, keeperRoot: keeperRoot)
                verdictByKeeperRoot[keeperRoot] = verdict
            }
            if verdict.isEligible {
                targets.append(rec)
                crossCount += 1
                crossKeeperVolumes.insert(URL(fileURLWithPath: keeperRoot).lastPathComponent)
            } else {
                skipped[verdict.reason, default: 0] += 1
            }
        }
        return DuplicateDeletionSelection(
            targets: targets,
            keepers: keepers,
            skippedCount: skipped.values.reduce(0, +),
            sameVolumeCount: sameCount,
            crossVolumeCount: crossCount,
            crossVolumeKeeperVolumes: crossKeeperVolumes.sorted(),
            skippedReasons: skipped.sorted { $0.value > $1.value }.map { (reason: $0.key, count: $0.value) },
            crossVolumeMode: crossMode,
            volumeRecordCount: volumeRecordCount)
    }

    /// Returns the distinct volume root paths that have high-confidence
    /// duplicate extra copies deletable on that volume: master on the same
    /// volume, plus — only with "Also clean up working copies" ON —
    /// working copies whose master passes the eligibility. Same rule
    /// as `duplicateDeletionSelection`, so the menu count and the alert
    /// count agree.
    func volumesWithDeletableDuplicates() -> [(path: String, count: Int)] {
        let keepers = keepersByGroupID()
        let crossMode = duplicateKeeperSettings.alsoCleanUpWorkingCopies
        let policy = crossMode ? duplicateKeeperPolicy() : nil
        var verdictByPair: [String: Bool] = [:]
        var volumeCounts: [String: Int] = [:]
        for rec in records {
            guard rec.duplicateDisposition == .extraCopy,
                  let groupID = rec.duplicateGroupID,
                  let keeper = keepers[groupID] else { continue }
            let volume = volumeRoot(for: rec.fullPath)
            let keeperVolume = volumeRoot(for: keeper.fullPath)
            var deletable = volume == keeperVolume
            if !deletable, let policy {
                let pairKey = volume + "\u{0}" + keeperVolume
                if let cached = verdictByPair[pairKey] {
                    deletable = cached
                } else {
                    deletable = policy.crossVolumeVerdict(extraPath: volume, volumeRoot: volume,
                                                          keeperPath: keeper.fullPath, keeperRoot: keeperVolume).isEligible
                    verdictByPair[pairKey] = deletable
                }
            }
            if deletable { volumeCounts[volume, default: 0] += 1 }
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
