import Foundation
import os

// MARK: - Scan-completion catalog merge
//
// Root-cause fix for the LaCieWorkspace data-loss incident (2026-07-01):
// 5,586 of 5,694 records under /Volumes/LaCieWorkspace were silently
// destroyed by a routine rescan. Mechanism:
//
//   1. startTarget() removed EVERY record under the scan root at scan
//      START (records.removeAll — correctly root-scoped, but destructive
//      before any new data existed).
//   2. Discovery came back with only 181 files (four healthy subtrees —
//      CheesegraterArchive/, from_mybook/, from-Maxtor750/, from-Seagate/
//      — were never walked; discovery completeness is tracked separately).
//   3. finalizeSingleTargetScan() appended the 181 and saved. No check,
//      no snapshot, no warning.
//
// The fix restructures the merge as an ATOMIC REPLACE AT COMPLETION:
//
//   - startTarget no longer touches records. A cancelled, crashed, or
//     aborted scan therefore loses NOTHING (previously a cancelled rescan
//     lost the volume's records until the next scan — acknowledged wart).
//   - commitScanResults() (below) replaces records under the SCANNED ROOT
//     only, using component-boundary PathScope (never raw hasPrefix — so
//     /Volumes/X/A can't reach /Volumes/X/ABackup). Records on the same
//     volume outside the root are untouched; a full-volume scan (root ==
//     mount point) keeps whole-volume replace semantics.
//   - A scan that did not complete (mid-probe abort: "volume likely
//     unmounted") UPSERTS instead: refreshed records replace their
//     same-path predecessors, new files are added, and nothing is pruned
//     — a half-dead volume must never erase what it failed to re-read.
//   - Pruning is EXISTENCE-CHECKED (2026-07-02, Fix 2): a complete scan
//     prunes only records whose file is genuinely gone from disk. Records
//     the scan didn't re-see but whose file still exists are retained —
//     "not re-seen" also happens when the file is merely invisible to this
//     scan's options (extensionless probing off, small-file skip, audio
//     off, skip-listed subtrees — the t3-v shape). If the scan root itself
//     is unreachable at merge time, ALL un-re-seen records are retained —
//     including when the volume unmounts in the millisecond window BETWEEN
//     the root check and the per-record loop (a 100%-gone non-trivial
//     vanished set triggers one root re-check before any pruning).
//   - Move/rename identity (feature/move-rename-identity): a complete
//     scan's ADDED files are fingerprint-matched (partialMD5 + sizeBytes)
//     against gone/absent records — same-root genuinely-gone first, then
//     catalog records outside the root whose file is proven off-disk. A
//     match RELOCATES the old record (id, dossier, curation, pair refs
//     survive) instead of prune-here + stranger-there, and is excluded
//     from the tripwire's prune count (a folder reorganize is not a mass
//     deletion). Candidates whose file still exists are COPIES — never
//     adopted. See VideoScanModel+ScanMergeMoveIdentity.swift.
//   - Mass-deletion tripwire (defense in depth): a complete scan whose
//     merge would remove MORE THAN 50 records AND MORE THAN 20% of the
//     existing records under the root first snapshots catalog.json to a
//     timestamped sibling (catalog.pre-merge.<stamp>.json — same pattern
//     as relocate's catalog.pre-relocate.*) and logs a prominent warning,
//     then proceeds. Snapshot+warn+proceed (not a confirmation dialog)
//     because scans finish unattended — overnight batches must not hang
//     on a sheet, and the snapshot makes recovery a file copy. If the
//     snapshot CANNOT be written, the merge fails SAFE: nothing is pruned
//     (the genuinely-gone set is retained, partial-merge semantics) — a
//     mass removal must always be recoverable.
//
// Console etiquette (fa24921): the tripwire emits ONE warning block per
// merge, never per-record lines.

private let scanMergeLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "scanMerge")

/// What a scan-completion merge did to the catalog. Returned for logging
/// and pinned by ScanMergeScopeTests.
struct ScanMergeOutcome: Equatable {
    /// Old records under the root replaced by a fresh record at the same path.
    var refreshed: Int = 0
    /// Old records under the root removed because their file is GENUINELY
    /// gone from disk (complete scans only; existence-checked).
    var pruned: Int = 0
    /// Records that FOLLOWED THEIR FILES to new locations (complete scans
    /// only): an added path fingerprint-matched a gone/absent record, so the
    /// old record was relocated in place — id, dossier, user curation, and
    /// pair references preserved — instead of prune-here + stranger-there.
    /// Never counted in `pruned`, and excluded from the tripwire's judgment
    /// (a mass folder reorganize is not a mass deletion). See
    /// VideoScanModel+ScanMergeMoveIdentity.swift.
    var moved: Int = 0
    /// Fresh records committed under the root: same-path refreshes PLUS
    /// genuinely new paths (i.e. every record in `targetRecords`). The
    /// overlap is `refreshed`; `moved` is the subset of new paths that
    /// landed by relocating an existing record instead of a fresh insert;
    /// genuine strangers = `upserted - refreshed - moved`.
    /// (Was `added`, which silently double-counted the refreshed set.)
    var upserted: Int = 0
    /// Old records under the root kept even though the scan didn't re-see
    /// them (partial scans only — never pruned on incomplete evidence).
    var retainedStale: Int = 0
    /// Old records under the root the scan didn't re-see but whose file is
    /// STILL ON DISK (complete scans only) — invisible to this scan's
    /// options (extensionless probing off, small-file skip, audio off,
    /// skip-listed subtree), not deleted. Never pruned. Includes ALL
    /// vanished records when the scan root itself is unreachable at merge
    /// time (never prune based on an unreachable disk).
    var retainedInvisible: Int = 0
    /// Genuinely-gone records RETAINED because the tripwire fired but the
    /// pre-merge safety snapshot could not be written (fail-safe: the merge
    /// degrades to partial-merge semantics for those records rather than
    /// mass-prune without a recovery copy). Always 0 when `pruned` > 0.
    var retainedNoSnapshot: Int = 0
    /// True when the mass-deletion tripwire fired (snapshot + warning — or,
    /// when the snapshot failed, the degraded no-prune merge).
    var tripwireFired: Bool = false
    /// Absolute path of the pre-merge catalog snapshot, when one was written.
    var snapshotPath: String?
}

extension VideoScanModel {

    /// Mass-deletion tripwire predicate: would removing `removedCount` of
    /// `existingCount` records be suspicious enough to snapshot + warn?
    /// Thresholds (Manager dispatch 2026-07-02): strictly more than 50
    /// records AND strictly more than 20% of what's there.
    ///
    /// Like a C++ free-function predicate — pure, trivially unit-testable.
    nonisolated static func scanMergeTripwireWouldFire(existingCount: Int, removedCount: Int) -> Bool {
        removedCount > 50 && removedCount * 5 > existingCount
    }

    /// Sendable result of the OFF-MAIN-ACTOR existence sweep: whether the
    /// scan root was reachable, and for every pre-await vanished path,
    /// whether its file is still on disk. The results are keyed by path so
    /// they stay valid across the merge's suspension even if the records
    /// array is mutated meanwhile (the post-await re-derivation consumes
    /// them by path, never by cached record reference).
    struct ScanMergeExistenceEvidence: Sendable {
        var rootReachable: Bool
        var existsByPath: [String: Bool]
    }

    /// The stat work of a complete-scan merge, extracted so it can run on a
    /// DETACHED task instead of the main actor (QA/perf 2026-07-02: with
    /// thousands of vanished records under cold/unwalked subtrees the
    /// per-record `fileExists` loop measured ~11–50 s of main-thread
    /// beachball). Pure function of the filesystem: root reachability check,
    /// one `fileExists` per vanished path, and the millisecond-unmount-window
    /// root re-check.
    ///
    /// `// nonisolated static ≈ a free function in C++ — no actor hop, no
    /// // access to model state, everything it needs comes in by value.`
    nonisolated static func gatherScanMergeExistenceEvidence(
        root: String,
        vanishedPaths: [String],
        afterRootCheck: (@Sendable () -> Void)?
    ) -> ScanMergeExistenceEvidence {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root) else {
            return ScanMergeExistenceEvidence(rootReachable: false, existsByPath: [:])
        }
        afterRootCheck?()
        var exists = [String: Bool](minimumCapacity: vanishedPaths.count)
        var goneCount = 0
        for path in vanishedPaths {
            let onDisk = fm.fileExists(atPath: path)
            exists[path] = onDisk
            if !onDisk { goneCount += 1 }
        }
        // Millisecond unmount window (QA 2026-07-02): the root check above
        // and the loop just now are not atomic — a volume that unmounts in
        // between passes the check, then fails EVERY per-record existence
        // test. That signature (100% of a non-trivial vanished set gone at
        // once) warrants ONE root re-check before pruning; if the root is
        // no longer there, report it unreachable (the merge then retains
        // all — never prune based on an unreachable disk). The >10 floor
        // keeps small legitimate cleanups (user deleted a handful of
        // files) off the extra stat.
        if goneCount == vanishedPaths.count, vanishedPaths.count > 10,
           !fm.fileExists(atPath: root) {
            return ScanMergeExistenceEvidence(rootReachable: false, existsByPath: exists)
        }
        return ScanMergeExistenceEvidence(rootReachable: true, existsByPath: exists)
    }

    /// Commit a finished scan into the catalog: replace records under the
    /// scanned `root` (component-boundary scoped) with `targetRecords`.
    ///
    /// - Parameter scanWasComplete: `completedCount >= discoveredCount` at
    ///   the call site. `false` means the probe loop aborted early (e.g.
    ///   consecutive-inaccessible threshold: volume unmounted mid-scan) —
    ///   the merge then upserts and NEVER prunes.
    ///
    /// ASYNC (2026-07-02): complete-scan merges suspend ONCE, while the
    /// existence sweep runs off-actor. Partial merges never suspend.
    ///
    /// Caller is responsible for persisting (saveCatalogDebounced) — kept
    /// out of here so tests can assert pure in-memory semantics.
    @discardableResult
    func commitScanResults(
        root: String,
        volName: String,
        targetRecords: [VideoRecord],
        scanWasComplete: Bool
    ) async -> ScanMergeOutcome {
        guard scanWasComplete else {
            return mergePartialScanResults(root: root, volName: volName, targetRecords: targetRecords)
        }
        var outcome = ScanMergeOutcome()
        let newPaths = Set(targetRecords.map(\.fullPath))
        outcome.upserted = targetRecords.count

        // Complete scan. "Not re-seen" conflates two very different things:
        // the file was DELETED from disk (prune — correct), and the file is
        // still on disk but INVISIBLE to this scan's options
        // (probeExtensionless off, skipSmallFiles, scanAudioFiles off,
        // skip-listed subtrees — the t3-v shape). Pruning the latter repeats
        // the incident class with the catalog's own options as the weapon,
        // and slips under the tripwire whenever the invisible set is small.
        // Existence-check the vanished set (only the vanished set — usually
        // small) and retain every record whose file is still on disk. If the
        // scan ROOT itself is unreachable at merge time (volume unmounted
        // between scan and merge), trust nothing: retain ALL vanished —
        // never prune based on an unreachable disk.
        //
        // OFF-MAIN-ACTOR (QA/perf 2026-07-02): the stats run on a detached
        // task — vanished paths are hoisted as plain strings, the sweep
        // returns Sendable evidence keyed by path. This derivation exists
        // ONLY to know which paths to stat; it is deliberately shadowed by
        // the post-await re-derivation below and must never feed the merge.
        let vanishedPathsPreAwait: [String] = records.compactMap { rec in
            guard PathScope.contains(rec.fullPath, within: root),
                  !newPaths.contains(rec.fullPath) else { return nil }
            return rec.fullPath
        }
        // Move/rename identity (2026-07-02): outside-root records whose
        // fingerprint matches one of this scan's added files are cross-root
        // MOVE candidates — but only if their file is genuinely gone from
        // its old location, which is blocking I/O to find out. Hoisted as
        // plain paths here; statted on the SAME detached task below (the
        // merge keeps its ONE suspension point); match decisions are
        // re-derived post-await. See VideoScanModel+ScanMergeMoveIdentity.
        let moveCandidatePathsPreAwait = hoistOutsideRootMoveCandidatePaths(
            root: root, targetRecords: targetRecords)
        let afterRootCheck = scanMergeAfterRootCheckForTesting
        let evidenceTask = Task.detached(priority: .userInitiated) {
            let existence = Self.gatherScanMergeExistenceEvidence(
                root: root, vanishedPaths: vanishedPathsPreAwait, afterRootCheck: afterRootCheck)
            let moveCandidateExists = Self.gatherMoveCandidateExistenceEvidence(
                paths: moveCandidatePathsPreAwait)
            return (existence, moveCandidateExists)
        }
        if let hook = scanMergeDuringExistenceChecksForTesting { await hook() }
        let (evidence, moveCandidateExists) = await evidenceTask.value

        // ATOMICITY RE-DERIVATION (QA correctness constraint, 2026-07-02):
        // the await above is the merge's ONE suspension point, and `records`
        // may have been mutated meanwhile (another target's finalize, a
        // LiveReload merge, a user edit). Everything the merge acts on is
        // therefore re-derived from the CURRENT records array here — no
        // pre-await record set survives past this comment. The existence
        // evidence stays valid because it is keyed by PATH:
        //   - path in evidence → use its on-disk verdict;
        //   - path NOT in evidence (record appeared under the root during
        //     the await) → NO evidence, so it is RETAINED (`?? true`) —
        //     never prune a record whose file was never statted;
        //   - path that left the catalog during the await → simply absent
        //     from the re-derived vanished set; its evidence goes unused.
        // From here to the records.removeAll/append below there are no
        // further awaits, so the mutation is atomic on the main actor.
        let existingUnderRoot = records.filter { PathScope.contains($0.fullPath, within: root) }
        let vanished = existingUnderRoot.filter { !newPaths.contains($0.fullPath) }
        outcome.refreshed = existingUnderRoot.count - vanished.count

        var genuinelyGone: [VideoRecord] = []
        var retainedInvisible: [VideoRecord] = []
        let rootReachable = evidence.rootReachable
        if rootReachable {
            for rec in vanished {
                if evidence.existsByPath[rec.fullPath] ?? true {
                    retainedInvisible.append(rec)
                } else {
                    genuinelyGone.append(rec)
                }
            }
        } else {
            retainedInvisible = vanished
        }

        // MOVE / RENAME IDENTITY (2026-07-02): fingerprint-match this scan's
        // added files against (a) the genuinely-gone set (same-root rename)
        // and (b) outside-root records whose file the detached sweep proved
        // gone (cross-root move). Derivation runs against the CURRENT
        // records array (same post-await re-derivation discipline as the
        // prune path); a candidate with no stat evidence is never adopted.
        // Matched candidates are RELOCATIONS, not deletions — pull them out
        // of genuinelyGone BEFORE the tripwire judges the prune count, so a
        // whole-folder reorganize can't fire the mass-deletion tripwire.
        let adoptions = deriveMoveAdoptions(
            root: root,
            targetRecords: targetRecords,
            existingPathsUnderRoot: Set(existingUnderRoot.map(\.fullPath)),
            genuinelyGone: genuinelyGone,
            outsideRootCandidateExists: moveCandidateExists)
        if !adoptions.isEmpty {
            let adoptedOldPaths = Set(adoptions.values)
            genuinelyGone.removeAll { adoptedOldPaths.contains($0.fullPath) }
        }
        outcome.moved = adoptions.count
        outcome.pruned = genuinelyGone.count
        outcome.retainedInvisible = retainedInvisible.count

        // ONE summary line per merge (fa24921 console etiquette) — never
        // per-record spam.
        if !rootReachable && !vanished.isEmpty {
            log("  ⚠ Scan root \(root) is not reachable at merge time — kept all \(vanished.count) un-re-seen record(s) under it (never prune based on an unreachable disk).")
            scanMergeLog.warning("Scan merge for \(volName, privacy: .public): root unreachable at merge time; retained all \(vanished.count) vanished records under \(root, privacy: .public)")
        } else if !retainedInvisible.isEmpty {
            log("  ℹ Kept \(retainedInvisible.count) existing record(s) under \(root) that this scan did not re-see — their files exist on disk but were not visible to this scan's options (e.g. extensionless probing off, small-file skip, audio files off, skip-listed folders).")
        }

        // Tripwire: never silently mass-delete — see applyMassRemovalTripwire.
        // Evaluated on the GENUINELY-GONE set only: retained-invisible
        // records are kept regardless, so they are not part of the removal
        // being judged. May EMPTY genuinelyGone (fail-safe degrade).
        applyMassRemovalTripwire(volName: volName, root: root,
                                 existingCount: existingUnderRoot.count,
                                 genuinelyGone: &genuinelyGone,
                                 outcome: &outcome)

        // QA P1-4 (2026-07-05, analysis-ledger): pairs must survive the
        // re-seen replacement below (fresh instances carry no pair fields
        // — RescanPreservedFields never covered them), and a genuinely
        // pruned record's partner must return HONESTLY to "pending"
        // rather than dangling as "settled" forever under the incremental
        // correlate. Capture before the sweep, rewire after the append.
        let pairCarry = capturePairCarryover(existingUnderRoot: existingUnderRoot,
                                             newPaths: newPaths)
        for rec in genuinelyGone {
            if let partner = rec.pairedWith, partner.pairedWith === rec {
                partner.pairedWith = nil
                partner.pairGroupID = nil
                partner.pairConfidence = nil
            }
        }

        // Remove only what the scan re-saw (replaced by the fresh instance)
        // or what is genuinely gone from disk — retained-invisible records
        // stay untouched (original instances, so their dossier/user fields
        // never even need restoring). Adopted candidates survive this sweep
        // by construction: their CURRENT path is the old one (updated only
        // below), which is neither re-seen nor in the (post-exclusion) gone
        // set, and cross-root candidates aren't under the root at all.
        let gonePaths = Set(genuinelyGone.map(\.fullPath))
        records.removeAll {
            PathScope.contains($0.fullPath, within: root)
                && (newPaths.contains($0.fullPath) || gonePaths.contains($0.fullPath))
        }
        // Adopted paths are NOT appended: the moved file's record is the OLD
        // instance, relocated in place right after — its id survives, so
        // pairedWith references from other records keep resolving.
        if adoptions.isEmpty {
            records.append(contentsOf: targetRecords)
        } else {
            let adoptedNewPaths = Set(adoptions.keys)
            records.append(contentsOf: targetRecords.filter { !adoptedNewPaths.contains($0.fullPath) })
            applyMoveAdoptions(adoptions, targetRecords: targetRecords)
            // ONE summary line per merge (fa24921) — never per-record spam.
            log("  ↪ \(adoptions.count) record(s) followed their files to new locations (rename/move detected — catalog identity, dossier and tags preserved).")
        }
        let pairsCarried = rewirePairCarryover(pairCarry, targetRecords: targetRecords)
        if pairsCarried > 0 {
            log("  ↪ \(pairsCarried) A/V pairing(s) carried across the rescan (pair identity preserved).")
        }
        scanMergeLog.info("Scan merge for \(volName, privacy: .public): +\(targetRecords.count) upserted (\(outcome.refreshed) refreshed), \(genuinelyGone.count) pruned, \(adoptions.count) moved, \(retainedInvisible.count) retained-invisible under \(root, privacy: .public)")
        appLog.write("Catalog merge (\(volName)): \(targetRecords.count) upserted (\(outcome.refreshed) refreshed), \(genuinelyGone.count) pruned, \(adoptions.count) moved (followed their files), \(retainedInvisible.count) retained (files on disk, invisible to scan options)")
        return outcome
    }

    // MARK: - Pair carryover across record replacement (QA P1-4, 2026-07-05)

    /// One re-seen record's pair wiring, captured before the replace sweep.
    private struct PairCarry {
        let partner: VideoRecord    // OLD partner instance (may itself be replaced)
        let partnerPath: String
        let gid: UUID?
        let confidence: PairConfidence?
    }

    /// Capture the pair wiring of every re-seen record (keyed by path —
    /// the fresh instance lands at the same path).
    private func capturePairCarryover(
        existingUnderRoot: [VideoRecord],
        newPaths: Set<String>
    ) -> [String: PairCarry] {
        var carry: [String: PairCarry] = [:]
        for rec in existingUnderRoot where newPaths.contains(rec.fullPath) {
            if let partner = rec.pairedWith {
                carry[rec.fullPath] = PairCarry(partner: partner,
                                                partnerPath: partner.fullPath,
                                                gid: rec.pairGroupID,
                                                confidence: rec.pairConfidence)
            }
        }
        return carry
    }

    /// Rewire captured pairs onto the post-merge instances. The partner
    /// resolves to its OWN fresh replacement when both sides were re-seen,
    /// or to the surviving original (cross-root partner). A partner that
    /// was pruned this merge stays unwired — the pair dies honestly and
    /// both sides read as pending. Idempotent under the both-sides double
    /// visit (second direction sees pairedWith already set and skips).
    /// Returns the number of pairings wired.
    private func rewirePairCarryover(
        _ carry: [String: PairCarry],
        targetRecords: [VideoRecord]
    ) -> Int {
        guard !carry.isEmpty else { return 0 }
        var freshByPath: [String: VideoRecord] = [:]
        freshByPath.reserveCapacity(targetRecords.count)
        for r in targetRecords { freshByPath[r.fullPath] = r }
        let liveInstances = Set(records.map(ObjectIdentifier.init))
        var wired = 0
        for (path, c) in carry {
            guard let fresh = freshByPath[path],
                  liveInstances.contains(ObjectIdentifier(fresh)),
                  fresh.pairedWith == nil else { continue }
            let partner: VideoRecord
            if let freshPartner = freshByPath[c.partnerPath],
               liveInstances.contains(ObjectIdentifier(freshPartner)) {
                partner = freshPartner
            } else if liveInstances.contains(ObjectIdentifier(c.partner)) {
                partner = c.partner
            } else {
                continue    // partner pruned this merge — pair dies honestly
            }
            fresh.pairedWith = partner
            fresh.pairGroupID = c.gid
            fresh.pairConfidence = c.confidence
            partner.pairedWith = fresh
            partner.pairGroupID = c.gid
            partner.pairConfidence = c.confidence
            wired += 1
        }
        return wired
    }

    /// Partial scan (aborted mid-probe). Evidence is incomplete, so pruning
    /// is forbidden: replace only the paths the scan actually re-saw, keep
    /// everything else under the root. NO suspension on this path — no
    /// existence checks (and no move detection: nothing is ever pruned, so
    /// there is nothing to rescue; the eventual COMPLETE scan adopts).
    /// Extracted verbatim from commitScanResults' guard (2026-07-02, body-
    /// length ceiling) — behavior pinned by partialScanUpsertsWithoutPruning
    /// and partialScanUpsertReplacesSamePathRecord.
    private func mergePartialScanResults(
        root: String,
        volName: String,
        targetRecords: [VideoRecord]
    ) -> ScanMergeOutcome {
        var outcome = ScanMergeOutcome()
        let newPaths = Set(targetRecords.map(\.fullPath))
        outcome.upserted = targetRecords.count
        let existingUnderRoot = records.filter { PathScope.contains($0.fullPath, within: root) }
        let vanished = existingUnderRoot.filter { !newPaths.contains($0.fullPath) }
        outcome.refreshed = existingUnderRoot.count - vanished.count
        outcome.retainedStale = vanished.count
        // QA P1-4: pairs survive the re-seen replacement on the partial
        // path too (no pruning here, so no partner-clearing needed).
        let pairCarry = capturePairCarryover(existingUnderRoot: existingUnderRoot,
                                             newPaths: newPaths)
        records.removeAll {
            PathScope.contains($0.fullPath, within: root) && newPaths.contains($0.fullPath)
        }
        records.append(contentsOf: targetRecords)
        let pairsCarried = rewirePairCarryover(pairCarry, targetRecords: targetRecords)
        if pairsCarried > 0 {
            log("  ↪ \(pairsCarried) A/V pairing(s) carried across the partial rescan.")
        }
        if !vanished.isEmpty {
            log("  ⚠ Scan of \(volName) did not complete — kept \(vanished.count) existing record(s) under \(root) that were not re-verified (no pruning on partial scans).")
        }
        scanMergeLog.notice("Partial-scan merge for \(volName, privacy: .public): +\(targetRecords.count) upserted, \(vanished.count) stale retained under \(root, privacy: .public)")
        appLog.write("Catalog merge (\(volName), PARTIAL): \(targetRecords.count) upserted, \(vanished.count) stale retained, 0 pruned")
        return outcome
    }

    /// Mass-deletion tripwire for a complete-scan merge: snapshot first,
    /// warn loudly, then let the prune proceed — the merge itself may be
    /// legitimate (user really did clear out a drive), but it must always
    /// be recoverable.
    ///
    /// FAIL SAFE (QA 2026-07-02): "recoverable" is the whole contract. If
    /// the snapshot cannot be written (unwritable directory, full disk,
    /// no catalog file yet), proceeding would be exactly the incident
    /// class with the safety net announced but absent — so the merge
    /// DEGRADES instead: `genuinelyGone` is EMPTIED (upsert what the scan
    /// re-saw, prune nothing) and the set is counted in
    /// `outcome.retainedNoSnapshot`.
    private func applyMassRemovalTripwire(
        volName: String,
        root: String,
        existingCount: Int,
        genuinelyGone: inout [VideoRecord],
        outcome: inout ScanMergeOutcome
    ) {
        // Locals, not the inout params, inside the log interpolations —
        // Logger messages are escaping autoclosures and cannot capture inout.
        let goneCount = genuinelyGone.count
        guard Self.scanMergeTripwireWouldFire(existingCount: existingCount,
                                              removedCount: goneCount) else { return }
        outcome.tripwireFired = true
        let snapshotPath = snapshotCatalogPreMerge()
        outcome.snapshotPath = snapshotPath
        let pct = existingCount == 0 ? 0 : goneCount * 100 / existingCount
        if snapshotPath == nil {
            outcome.retainedNoSnapshot = goneCount
            outcome.pruned = 0
            log("""
              ⚠️⚠️ MASS-REMOVAL TRIPWIRE — \(volName) — MERGE DEGRADED (fail-safe)
              This scan would remove \(goneCount) of \(existingCount) cataloged record(s) under \(root) (\(pct)%), but the pre-merge safety snapshot could NOT be written.
              NOTHING was pruned: all \(goneCount) record(s) were retained (partial-merge semantics). Fix the catalog directory and re-scan to prune for real.
              """)
            scanMergeLog.error("Mass-removal tripwire for \(volName, privacy: .public): snapshot FAILED — merge degraded, retained all \(goneCount) of \(existingCount) genuinely-gone records under \(root, privacy: .public) (no prune without a recovery copy)")
            appLog.write("TRIPWIRE (DEGRADED): scan merge for \(volName) could not write a pre-merge snapshot; retained all \(goneCount)/\(existingCount) genuinely-gone records under \(root) instead of pruning")
            genuinelyGone = []
        } else {
            log("""
              ⚠️⚠️ MASS-REMOVAL TRIPWIRE — \(volName)
              This scan removes \(goneCount) of \(existingCount) cataloged record(s) under \(root) (\(pct)%) whose files are no longer on disk.
              If files were NOT deleted from disk, the scan likely failed to see part of the tree (skip rules, unmount, I/O errors).
              Pre-merge catalog snapshot: \(snapshotPath ?? "")
              """)
            scanMergeLog.warning("Mass-removal tripwire fired for \(volName, privacy: .public): removing \(goneCount) of \(existingCount) records under \(root, privacy: .public); snapshot=\(snapshotPath ?? "", privacy: .public)")
            appLog.write("TRIPWIRE: scan merge for \(volName) removes \(goneCount)/\(existingCount) records under \(root); pre-merge snapshot: \(snapshotPath ?? "")")
        }
    }

    /// Write the CURRENT in-memory records to a timestamped sibling
    /// `catalog.pre-merge.<stamp>.json` before a tripwired merge. Mirrors
    /// relocate's snapshotCatalogPreRelocate. Returns the snapshot path,
    /// or nil when the write failed.
    ///
    /// FROM MEMORY, not a disk copy (QA 🟡 #7, 2026-07-02): copying
    /// catalog.json lagged in-memory state by the 2 s save debounce, so a
    /// user edit made just before finalize was missing from the safety
    /// copy. Encoding `records` through the store's canonical
    /// makePayload/encode path (CatalogStore.writeSnapshot) captures
    /// exactly what the user sees, in the exact catalog.json format.
    /// Bonus: a first-ever scan with no catalog.json on disk yet can now
    /// still write a snapshot (the old copyItem returned nil there).
    ///
    /// Test gate: the SHARED store points at the user's real
    /// ~/Library/Application Support/VideoScan — never write there from a
    /// test host (same narrow gate as CatalogStore.saveNow). Tests inject
    /// CatalogStore(directory:) to exercise the real snapshot.
    @discardableResult
    func snapshotCatalogPreMerge() -> String? {
        let snap = snapshotCatalog(prefix: "pre-merge")
        if snap == nil {
            log("  ⚠ Pre-merge snapshot failed — a tripwired merge will now degrade to no-prune (fail safe)")
            scanMergeLog.error("Pre-merge snapshot failed")
        }
        return snap
    }

    /// Write the CURRENT in-memory records to a timestamped sibling
    /// `catalog.<prefix>.<stamp>.json`. Shared core of the scan-merge
    /// tripwire (`pre-merge`) and the target-removal safety net
    /// (`pre-target-removal`, 2026-07-03). Same test gate and same
    /// same-second uniquify behavior as always. Returns nil on failure —
    /// callers treat that as "no recovery copy → do not destroy".
    @discardableResult
    func snapshotCatalog(prefix: String) -> String? {
        if TestEnvironment.isTestHost && catalogStore === CatalogStore.shared { return nil }
        let dir = (catalogStore.fileLocation as NSString).deletingLastPathComponent
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        var snap = (dir as NSString).appendingPathComponent("catalog.\(prefix).\(stamp).json")
        // Two snapshots in the same second: uniquify rather than fail.
        var n = 1
        while FileManager.default.fileExists(atPath: snap) {
            snap = (dir as NSString).appendingPathComponent("catalog.\(prefix).\(stamp).\(n).json")
            n += 1
        }
        if catalogStore.writeSnapshot(records: records, toPath: snap) {
            return snap
        }
        return nil
    }
}
