import Foundation
import VideoScanCore

// MARK: - Duplicate Analysis + Same-Volume Deletion
//
// analyzeDuplicates feeds DuplicateDetector, then UI uses the result to
// surface "Delete X duplicates on Y volume" affordances. The actual delete
// is conservative: same-volume only — never deletes a file whose only
// surviving copy lives on a different (e.g. backup) volume. The keeper
// lookup + volumeRoot helpers stay alongside the delete because they're
// the policy that makes the deletion safe.
//
// 2026-09-20 (Rick: "Verifying 1 of 2,992 … hours, nothing to look at"):
// the verify-and-remove LOOP moved out of this file into
// DeleteDuplicatesJob — an MFO job with a DELETE chip, bytes-based
// progress, a rate + ETA, Pause/Resume, Stop, a saved plan that can be
// offered for resume after a quit, and a detail view listing every file.
// What stays here is the POLICY the job runs under: the selection, the
// Master Archive exclusion, the cross-volume safety-snapshot tripwire, the
// per-pair catalog settlement (carry-over, row removal, ledger, log) and
// the model verb `deleteDuplicates(onVolume:)` that starts the job and
// waits for it — same signature and same result tuple as before, so every
// existing caller and test keeps working.

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

    /// Mid-batch checkpoint interval (QA minor 4).
    static let deletionCheckpointEvery = 25

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

        // Codex review B: the ledger only re-derives new/changed records,
        // so a changed keeper policy (list order, retire, reachability,
        // master) never reached stamped groups. Compare the live election
        // descriptor with the one the last full pass ran under; when they
        // differ, re-elect keepers for ALL groups (election only —
        // grouping/hash work is reused).
        let livePolicy = duplicateKeeperPolicy()
        let policyStale = selectedIDs == nil
            && duplicateKeeperSettings.lastElectionDescriptor != electionStamp(for: livePolicy)

        var scope: [VideoRecord]
        let deltaCount: Int
        if let ids = selectedIDs, !ids.isEmpty {
            scope = records.filter { ids.contains($0.id) }
            DuplicateDetector.clear(records: scope)
            deltaCount = scope.count
        } else {
            let active = pfActiveRecords(records)
            let delta = active.filter { $0.dupAnalyzedAt == nil }
            if delta.isEmpty {
                if policyStale {
                    let changed = await reelectDuplicateKeepers(policy: livePolicy)
                    duplicateStatus = "Keepers re-elected (\(changed) group\(changed == 1 ? "" : "s") changed)"
                    log("Duplicate analysis: nothing new to group — re-elected keepers under the current order (\(changed) group(s) changed).")
                    duplicateReanalyzeHint = isDuplicateKeeperPolicyStale ? WorkingCopyCleanupText.reanalyzeHint : nil
                    NotificationCenter.default.post(name: .videoScanCatalogMutated, object: nil)
                } else {
                    duplicateStatus = "Duplicates up to date"
                    log("Duplicate analysis: nothing new since the last pass — 0 records pending.")
                }
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
        let (clones, summary) = await DuplicateDetector.analyzeDetached(
            freshClones, keeperPolicy: livePolicy)
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
        // Stale policy: the groups OUTSIDE this pass's scope still carry
        // keepers elected under the old order — re-elect them too.
        if policyStale {
            let changed = await reelectDuplicateKeepers(policy: livePolicy)
            if changed > 0 { log("  Re-elected keepers under the current order: \(changed) group(s) changed.") }
        }
        // Codex final nit: only drop the hint when the catalog really is
        // current — a re-election that skipped rows leaves the stamp stale
        // on purpose, and the hint must survive with it.
        if selectedIDs == nil {
            duplicateReanalyzeHint = isDuplicateKeeperPolicyStale ? WorkingCopyCleanupText.reanalyzeHint : nil
        }

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

    // MARK: - Delete Duplicates (the verb — runs a DeleteDuplicatesJob)

    /// Delete high-confidence duplicate files on a given volume, but ONLY when
    /// the keeper (the `.keep` file in the same duplicate group) is also on the
    /// same volume (or, with "Also clean up working copies" ON, on a
    /// higher-ranked online drive). This prevents deleting a file whose only
    /// surviving copy lives on a different (e.g. backup) volume.
    ///
    /// Since 2026-09-20 the work is a `DeleteDuplicatesJob`: this verb
    /// builds one WITHOUT registering it in the Media File Operations
    /// window (the window's Delete button goes through
    /// `MediaFileOperationsCenter.startDeleteDuplicates` instead), runs it
    /// to completion and returns the same tuple as before. Cancelling the
    /// calling Task cancels the job, exactly as cancelling the old loop did.
    @discardableResult
    func deleteDuplicates(onVolume volumePath: String,
                          verificationHooks: SignatureVerification.Hooks = .live) async
        -> (deleted: Int, failed: Int, skipped: Int, bytesFreed: Int64) {
        let job = DeleteDuplicatesJob(model: self, volumePath: volumePath, hooks: verificationHooks)
        job.start()
        // `withTaskCancellationHandler` ≈ a scope guard whose cleanup runs
        // the moment the enclosing Task is cancelled — the hop through a
        // main-actor Task is needed because the handler itself is not
        // isolated.
        await withTaskCancellationHandler {
            await job.task?.value
        } onCancel: {
            Task { @MainActor in job.cancel() }
        }
        return job.result
    }

    /// Everything that happens before the first byte is read, in the
    /// order the old loop did it: selection, Master Archive exclusion, the
    /// cross-volume safety-snapshot tripwire, the console summary. Returns
    /// the plan the job will run, or nil when there is nothing to do (the
    /// reason is already logged). Same log lines as before, so the
    /// existing sensors keep matching.
    func prepareDuplicateDeletion(onVolume volumePath: String) async -> DeleteDuplicatesPlan? {
        let selection = duplicateDeletionSelection(onVolume: volumePath)
        // Master Archive files are never bulk-deleted, even as "extras".
        var targets = excludingMasterArchiveFiles(selection.targets, verb: "Delete Duplicates")
        let keepers = selection.keepers
        // Both may grow if the snapshot tripwire drops the cross-drive part
        // (codex review E) — the summary and the skipped count then say so.
        var skippedCount = selection.skippedCount
        var summaryLine = selection.summaryLine
        var skippedNote = selection.skippedReasons
            .map { "\($0.count) file(s): \($0.reason)" }
            .joined(separator: "; ")
        let volumeName = URL(fileURLWithPath: volumePath).lastPathComponent
        var snapshotPath: String?

        func isWorkingCopy(_ rec: VideoRecord) -> Bool {
            guard selection.crossVolumeMode, let g = rec.duplicateGroupID, let k = keepers[g] else { return false }
            return !PathScope.contains(k.fullPath, within: volumePath)
        }

        guard !targets.isEmpty else {
            if skippedCount > 0 {
                log("\nNo duplicates to delete on \(volumePath). Skipped \(skippedCount) file(s) — \(skippedNote).")
            } else {
                log("\nNo high-confidence duplicates to delete on \(volumePath)")
            }
            return emptyDeletionPlan(volumePath: volumePath, selection: selection,
                                     skippedCount: skippedCount, summaryLine: summaryLine)
        }

        // Cross-volume tripwire (2026-08-18): a big cross-drive batch
        // takes a recovery snapshot first; if it can't be written, the
        // cross-volume part is dropped and only same-drive extras proceed.
        if selection.crossVolumeMode, selection.crossVolumeCount > 0 {
            let fraction = selection.volumeRecordCount > 0
                ? Double(selection.crossVolumeCount) / Double(selection.volumeRecordCount) : 1
            if selection.crossVolumeCount > Self.crossVolumeSnapshotThreshold
                || fraction > Self.crossVolumeSnapshotFraction {
                duplicateStatus = "Writing safety snapshot…"
                // Encode + write run off-main; this await is the barrier —
                // nothing is unlinked until the snapshot has landed (or
                // failed) — codex review D.
                if let snap = await snapshotCatalogAsync(prefix: "pre-dup-crossvolume") {
                    snapshotPath = snap
                    log("\nPre-delete safety snapshot (\(selection.crossVolumeCount) working copies): \(snap)")
                } else {
                    let before = targets.count
                    targets = targets.filter { rec in
                        guard let g = rec.duplicateGroupID, let k = keepers[g] else { return false }
                        return PathScope.contains(k.fullPath, within: volumePath)
                    }
                    let dropped = before - targets.count
                    skippedCount += dropped
                    summaryLine = "\(targets.count) same-drive extra\(targets.count == 1 ? "" : "s")"
                        + " (\(dropped) working cop\(dropped == 1 ? "y" : "ies") left alone — no safety snapshot)"
                    skippedNote += (skippedNote.isEmpty ? "" : "; ") + "\(dropped) file(s): safety snapshot could not be written"
                    log("\n⚠️ Could not write the pre-delete safety snapshot — leaving the \(dropped) working cop\(dropped == 1 ? "y" : "ies") alone; only same-drive extras will be removed.")
                    guard !targets.isEmpty else {
                        return emptyDeletionPlan(volumePath: volumePath, selection: selection,
                                                 skippedCount: skippedCount, summaryLine: summaryLine)
                    }
                }
            }
        }

        if selection.crossVolumeMode {
            log("\n" + WorkingCopyCleanupText.logSummary(volume: volumeName,
                    detail: "removing \(targets.count) extra cop\(targets.count == 1 ? "y" : "ies") — \(summaryLine)…"))
        } else {
            log("\nDeleting \(targets.count) same-volume duplicate(s) on \(volumePath)…")
        }
        if skippedCount > 0 {
            log("  (Skipping \(skippedCount) file(s) — \(skippedNote))")
        }

        // Keeper stamps (the resume re-check's "keeper unchanged since the
        // plan" reference) in ONE detached pass — never a stat per target
        // on the main actor (QA MINOR 5). Keepers repeat across targets, so
        // the set is small.
        let keeperPaths = Set(targets.compactMap { rec in rec.duplicateGroupID.flatMap { keepers[$0]?.fullPath } })
        let keeperStamps = await Self.captureStamps(paths: Array(keeperPaths))
        var entries: [DeleteDuplicatesPlan.Entry] = []
        entries.reserveCapacity(targets.count)
        for rec in targets {
            // A target without a keeper is still listed — the job refuses
            // it with the same "no keeper to verify against" line as before.
            let keeper = rec.duplicateGroupID.flatMap { keepers[$0] }
            entries.append(DeleteDuplicatesPlan.Entry(
                id: rec.id, path: rec.fullPath, filename: rec.filename, sizeBytes: rec.sizeBytes,
                keeperID: keeper?.id ?? UUID(), keeperPath: keeper?.fullPath ?? "",
                keeperFilename: keeper?.filename ?? "",
                keeperStamp: keeper.flatMap { keeperStamps[$0.fullPath] },
                isWorkingCopy: isWorkingCopy(rec)))
        }
        return DeleteDuplicatesPlan(volumePath: volumePath, catalogLocation: catalogStore.fileLocation,
                                    crossVolumeMode: selection.crossVolumeMode, skippedBeforePlan: skippedCount,
                                    summaryLine: summaryLine, snapshotPath: snapshotPath, entries: entries)
    }

    /// One stat per path, off the main actor. Unreachable paths are absent
    /// from the result.
    nonisolated static func captureStamps(paths: [String]) async -> [String: FileIdentityStamp] {
        guard !paths.isEmpty else { return [:] }
        return await Task.detached(priority: .userInitiated) {
            var out: [String: FileIdentityStamp] = [:]
            for path in paths {
                if let stamp = FileIdentityStamp.capture(path: path) { out[path] = stamp }
            }
            return out
        }.value
    }

    /// A plan with no rows — the job finishes at once with the old
    /// "(0, 0, skipped, 0)" result and nothing is written to disk.
    private func emptyDeletionPlan(volumePath: String, selection: DuplicateDeletionSelection,
                                   skippedCount: Int, summaryLine: String) -> DeleteDuplicatesPlan {
        DeleteDuplicatesPlan(volumePath: volumePath, catalogLocation: catalogStore.fileLocation,
                             crossVolumeMode: selection.crossVolumeMode, skippedBeforePlan: skippedCount,
                             summaryLine: summaryLine, entries: [])
    }

    /// What the catalog says about one plan row RIGHT NOW. Asked
    /// immediately before every pair is dispatched (and by the resume
    /// re-check), never cached across a pause, a resume or a preflight
    /// (codex 1593 #3): the row must still be an active record at its
    /// path, still an extra copy in a group whose keeper is the plan's
    /// keeper (same id, same path, still `.keep`), not a Master Archive
    /// file, and — for a working copy — still eligible under the LIVE
    /// cross-volume policy.
    enum DuplicateDeletionAuthorization {
        case authorized(record: VideoRecord, keeper: VideoRecord)
        /// The catalog decided differently (record gone / moved / no
        /// longer an extra copy): left alone, not a refusal — the row is
        /// NOT re-marked Review.
        case skip(note: String, log: String)
        /// The pair no longer lines up (keeper / group / archive /
        /// eligibility): refused, and the extra copy is marked Review.
        case refuse(note: String)
    }

    func authorizeDuplicateDeletion(entry e: DeleteDuplicatesPlan.Entry, volumePath: String,
                                    crossVolumeMode: Bool, stage: String) -> DuplicateDeletionAuthorization {
        guard let rec = record(forID: e.id), !rec.isPurged, rec.fullPath == e.path else {
            return .skip(note: "record is no longer in the catalog at this path — skipped \(stage)",
                         log: "Skipped \(e.filename): no longer in the catalog at \(e.path)")
        }
        guard !e.keeperPath.isEmpty else {
            return .refuse(note: "no keeper to verify against")
        }
        guard rec.duplicateDisposition == .extraCopy, let group = rec.duplicateGroupID else {
            // Re-elected, decided by hand, or re-analysed: the catalog's
            // call. Touching its disposition here could turn a keeper
            // into Review.
            return .skip(note: "no longer marked as an extra copy — skipped \(stage)",
                         log: "Skipped \(e.filename): no longer marked as an extra copy")
        }
        guard let keeper = record(forID: e.keeperID), !keeper.isPurged,
              keeper.duplicateDisposition == .keep, keeper.duplicateGroupID == group,
              keeper.fullPath == e.keeperPath else {
            return .refuse(note: "keeper \(e.keeperFilename) is no longer this file's keeper — refused \(stage)")
        }
        guard excludingMasterArchiveFiles([rec], verb: "Delete Duplicates").count == 1 else {
            return .refuse(note: "now lives in the Master Archive — refused \(stage)")
        }
        if !PathScope.contains(keeper.fullPath, within: volumePath) {
            // A working copy: the keeper is on another drive. The policy
            // is re-read live — the toggle, the drive list, reachability
            // and retirement can all have changed since the plan.
            guard crossVolumeMode, duplicateKeeperSettings.alsoCleanUpWorkingCopies else {
                return .refuse(note: "keeper \(keeper.filename) is on another drive and working-copy cleanup is off — refused \(stage)")
            }
            let verdict = duplicateKeeperPolicy().crossVolumeVerdict(
                extraPath: volumePath, volumeRoot: volumeRoot(for: volumePath),
                keeperPath: keeper.fullPath, keeperRoot: volumeRoot(for: keeper.fullPath))
            guard verdict.isEligible else {
                return .refuse(note: "\(verdict.reason) — refused \(stage)")
            }
        }
        return .authorized(record: rec, keeper: keeper)
    }

    /// The catalog side of ONE verified-and-removed pair, exactly as the
    /// old loop did it: fold the extra's human metadata and enrichment into
    /// the live master, drop the extra's row (by id AND path — a row
    /// replaced during the disk work is left alone), write the ledger line,
    /// and say what happened. Returns whether the catalog changed.
    ///
    /// `preAwait` is an IMMUTABLE snapshot (`snapshotClone`) of the row
    /// taken before the disk work — never the live instance. When the live
    /// row no longer matches by id AND path it is retained untouched, and
    /// the ledger line is written from the snapshot: the file that left
    /// the disk is the one at `expectedPath` (codex 1593 #4 — the old
    /// fallback stamped the captured live instance, which tombstoned a row
    /// that had merely been moved during the await).
    @discardableResult
    func settleDeletedDuplicate(expectedID: UUID, expectedPath: String,
                                preAwait record: VideoRecord,
                                keeperID: UUID, keeperPath: String, keeperFilename: String,
                                isWorkingCopy: Bool, batchID: String,
                                keeperMatchedByStoredFixity: Bool) -> Bool {
        var catalogMutated = false
        let currentRecord = records.first { $0.id == expectedID && $0.fullPath == expectedPath }
        let liveInstances = Set(records.map(ObjectIdentifier.init))
        // The snapshot must be detached from the catalog: if a caller
        // handed us a live row by mistake, clone it now rather than stamp
        // a retained record.
        let snapshot = liveInstances.contains(ObjectIdentifier(record)) ? record.snapshotClone() : record
        // Metadata carry-over (2026-08-18). The bytes are gone —
        // verified identical to the keeper — but the ROW still
        // holds whatever Rick put on this copy (stars, people,
        // notes, tags, provenance stamp). Fold it into the
        // keeper before the row leaves the catalog, using the
        // SAME union rules as repair adoption
        // (applyHumanMetadataInheritance): never clobber a
        // judgment already on the keeper, never touch machine
        // metadata.
        // QA minor 3: re-resolve the master in `records` by id AFTER
        // the await (mirrors the extra's currentRecord check) — a
        // catalog replacement during the disk work must not send
        // the merge to a detached object.
        // Codex follow-up MAJOR 1: BOTH merges require the extra's
        // LIVE row (same id AND path after the await). If the
        // catalog changed during verification, the pre-await
        // `record` is detached — merging its fields into the master
        // would carry stale metadata. Skip, and say so.
        if currentRecord == nil {
            log("  catalog changed during verification — carry-over skipped for \(record.filename) (file already verified and removed)")
        } else if let extraRow = currentRecord,
                  let liveMaster = records.first(where: { $0.id == keeperID }) {
            let carried = applyHumanMetadataInheritance(from: extraRow, to: liveMaster)
            if !carried.isEmpty {
                log("  Carried over to master \(liveMaster.filename) from \(record.filename): "
                    + carried.joined(separator: ", "))
            }
            // Codex review A: enrichment the master lacks
            // (transcript, captions, dossier, detected people,
            // inferred date, Avid identity) + a provenance line.
            let enriched = applyEnrichmentInheritance(from: extraRow, to: liveMaster)
            if !enriched.isEmpty {
                log("  Enrichment carried to master \(liveMaster.filename): "
                    + enriched.joined(separator: ", "))
            }
            // The keeper's haystack changed (place, tags, notes,
            // people…): re-index it NOW, not on the next rebuild —
            // the checkpoint notification below is record-less
            // (codex #1380).
            searchIndex.update(liveMaster)
            catalogMutated = true
        } else {
            log("  master row gone — carry-over skipped for \(record.filename) (file already verified and removed)")
        }
        if let index = records.firstIndex(where: {
            $0.id == expectedID && $0.fullPath == expectedPath
        }) {
            records.remove(at: index)
            catalogMutated = true
        } else {
            log("  Catalog changed while deleting \(record.filename); current row retained")
        }
        // Media Ledger: one copyDeleted line per file that left the disk,
        // batch-keyed to the plan so the run reads as one decision. The
        // removed row is stamped so the ledger line carries its final
        // state; it is no longer in `records`, so nothing else sees it.
        // When the live row was retained (id/path mismatch), the line is
        // written from the pre-await SNAPSHOT — the retained row is never
        // stamped deleted.
        let removed = currentRecord ?? snapshot
        assert(!liveInstances.contains(ObjectIdentifier(removed)) || currentRecord != nil,
               "a retained live row must never be stamped as deleted")
        removed.lifecycleStage = .deletedPermanently
        removed.purgedAt = Date()
        ledgerCopyRemoved([removed], permanent: true, by: .rick, batchID: batchID)
        let how = keeperMatchedByStoredFixity
            ? "keeper matched by stored fixity, not re-read"
            : "keeper read in full, fixity stored"
        if isWorkingCopy {
            log("  " + WorkingCopyCleanupText.logRemoved(path: expectedPath, masterPath: keeperPath) + " [\(how)]")
        } else {
            log("  Deleted (verified identical to \(keeperFilename)): \(record.filename) [\(how)]")
        }
        return catalogMutated
    }

    /// A pair the gate refused: the live row (same id AND path) is marked
    /// Review with the reason, as before. Returns whether the catalog changed.
    @discardableResult
    func noteRefusedDuplicate(expectedID: UUID, expectedPath: String, filename: String,
                              reason: String) -> Bool {
        let currentRecord = records.first { $0.id == expectedID && $0.fullPath == expectedPath }
        currentRecord?.duplicateDisposition = .review
        currentRecord?.duplicateReasons = reason
        log("  REFUSED \(filename): \(reason)")
        return currentRecord != nil
    }

    /// Store a whole-file fixity on the live record at `path` (id AND path
    /// must still match — a row replaced meanwhile gets nothing). Called
    /// for a keeper the moment it was read in full, so every later pair
    /// with that keeper is verified one-sided. Returns whether it was
    /// written.
    @discardableResult
    func storeContentFixity(recordID: UUID, path: String, fixity: ContentFixity) -> Bool {
        guard !isReadOnly,
              let rec = record(forID: recordID), rec.fullPath == path else { return false }
        rec.contentFixity = fixity
        return true
    }

    // MARK: - Resume after a quit

    /// Look for unfinished plans at launch (called from VideoScanApp's
    /// onAppear, where the other launch settlements happen) and EXPOSE the
    /// OLDEST one for this catalog — never start it. The MFO window and
    /// the main window offer "Resume / Discard"; once that plan is settled
    /// (resumed to the end, or discarded) the next check offers the next
    /// one, oldest first, one at a time (QA MINOR 7). Plans made from
    /// another catalog are left alone (they would re-validate to nothing
    /// anyway).
    func checkForUnfinishedDeleteDuplicatesPlans(root: URL = DeleteDuplicatesPlanStore.defaultRoot) {
        guard !isReadOnly, !isDeletingDuplicates else { return }
        let plans = DeleteDuplicatesPlanStore.unfinishedPlans(root: root, log: { [weak self] in self?.log($0) })
        let mine = plans.filter { $0.catalogLocation == catalogStore.fileLocation }
        guard let oldest = mine.last else {   // unfinishedPlans is newest-first
            pendingDeleteDuplicatesResume = nil
            return
        }
        pendingDeleteDuplicatesResume = oldest
        let others = mine.count - 1
        log("\nDelete Duplicates: an unfinished run on \(oldest.volumeName) was found — "
            + "\(oldest.remainingCount) of \(oldest.entries.count) still to do. Nothing resumes on its own; "
            + "use Resume or Discard in Media File Operations."
            + (others > 0 ? " \(others) more unfinished run\(others == 1 ? "" : "s") will be offered after it, oldest first." : ""))
    }

    /// The user chose Discard: the plan is settled (remaining rows skipped,
    /// outcome "discarded") and moved to done/ — kept for the log. The
    /// NEXT unfinished plan, if any, is offered right away (codex 1593 #8
    /// — it used to take another launch).
    func discardPendingDeleteDuplicatesPlan(root: URL = DeleteDuplicatesPlanStore.defaultRoot) {
        guard var plan = pendingDeleteDuplicatesResume else { return }
        pendingDeleteDuplicatesResume = nil
        let skipped = plan.skipRemaining(reason: "discarded by you at the next launch")
        plan.finishedAt = Date()
        plan.outcome = "discarded"
        plan.log.append("Discarded at launch: \(skipped) row(s) never reached")
        do {
            try DeleteDuplicatesPlanStore.save(plan, root: root)
            try DeleteDuplicatesPlanStore.moveToDone(plan, root: root)
            log("Delete Duplicates: discarded the unfinished run on \(plan.volumeName) (\(skipped) file(s) left alone).")
        } catch {
            log("Delete Duplicates: could not file the discarded plan for \(plan.volumeName) — \(error.localizedDescription)")
            // Left in place and unfinished: the next check would offer it
            // again, which is the honest outcome — but not this instant,
            // or Discard would appear to do nothing.
            return
        }
        checkForUnfinishedDeleteDuplicatesPlans(root: root)
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
        let hasMasterArchive = masterArchiveRootPath != nil
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
                // QA minor 6: same Master-Archive-copy skip as the
                // selection, so menu count == alert count.
                if hasMasterArchive, isArchiveCopy(rec) || isInsideMasterArchive(path: rec.fullPath) { continue }
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

/// Human-readable reason a verified deletion was refused (shared by the
/// job's worker and `VideoScanModel.refusalNote`).
func duplicateRefusalNote(_ failure: SignatureVerification.Failure,
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


// MARK: - Keeper settings changes (QA minor 7, 2026-08-18)

extension VideoScanModel {
    /// Call after ANY user change to `duplicateKeeperSettings` (list order,
    /// toggle): saves, refreshes the Duplicates menu counts, and raises the
    /// one-line "run Find Duplicates again" hint. Never auto-runs analysis.
    func noteDuplicateKeeperSettingsChanged() {
        saveDuplicateKeeperSettings()
        refreshDossierCountsNow()
        // Only an election-affecting change (list order — the toggle
        // doesn't move keepers) earns the hint; codex review B pins the
        // re-election itself to the descriptor comparison in Analyze.
        duplicateReanalyzeHint = isDuplicateKeeperPolicyStale ? WorkingCopyCleanupText.reanalyzeHint : nil
    }
}


// MARK: - Keeper re-election (codex review B, 2026-08-18)

extension VideoScanModel {
    /// Re-elect keepers for every existing group under `policy` — off-main
    /// over clones, copy back disposition + best-match, then stamp the
    /// policy descriptor so the next Analyze knows the ledger is current.
    /// Returns the number of groups whose keeper changed.
    @discardableResult
    func reelectDuplicateKeepers(policy: DuplicateKeeperPolicy) async -> Int {
        let grouped = pfActiveRecords(records).filter { $0.duplicateGroupID != nil }
        var clones: [VideoRecord] = []
        clones.reserveCapacity(grouped.count)
        for rec in grouped { clones.append(rec.snapshotClone()) }
        let (analyzed, changed) = await DuplicateDetector.reelectKeepersDetached(clones, keeperPolicy: policy)
        // Test seam: lets a test mutate the catalog "during the await"
        // (same role as SignatureVerification.Hooks for the delete path).
        if let hook = duplicateReelectionAwaitHook { await hook() }
        let liveInstances = Set(records.map(ObjectIdentifier.init))
        var skippedRows = 0
        for (original, clone) in zip(grouped, analyzed) {
            guard liveInstances.contains(ObjectIdentifier(original)) else { skippedRows += 1; continue }
            original.duplicateDisposition = clone.duplicateDisposition
            original.duplicateBestMatchFilename = clone.duplicateBestMatchFilename
        }
        // Codex follow-up NOTE 3: stamp the policy as current ONLY when it
        // was applied to every row; otherwise leave it stale so the next
        // Find Duplicates re-elects again.
        if skippedRows == 0 {
            duplicateKeeperSettings.lastElectionDescriptor = electionStamp(for: policy)
            saveDuplicateKeeperSettings()
            duplicateReanalyzeHint = nil
        } else {
            log("  Keeper re-election: \(skippedRows) row(s) changed during the pass — policy left unstamped; the next Find Duplicates re-elects again.")
        }
        return changed
    }

    /// The value compared/stored for the ledger stamp: the policy
    /// descriptor PREFIXED with the catalog's identity (its file location)
    /// — codex follow-up NOTE 4. Settings live in UserDefaults, which is
    /// per-user, not per-catalog; another catalog directory or a viewer
    /// session sharing the same preferences must not be able to suppress
    /// re-election here.
    func electionStamp(for policy: DuplicateKeeperPolicy) -> String {
        "catalog=\(catalogStore.fileLocation);" + policy.electionDescriptor
    }

    /// True when the stored stamp is not the live one for THIS catalog.
    var isDuplicateKeeperPolicyStale: Bool {
        duplicateKeeperSettings.lastElectionDescriptor != electionStamp(for: duplicateKeeperPolicy())
    }
}
