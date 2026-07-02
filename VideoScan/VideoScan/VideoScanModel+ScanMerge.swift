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
    /// Fresh records committed under the root: same-path refreshes PLUS
    /// genuinely new paths (i.e. every record in `targetRecords`). The
    /// overlap is `refreshed`; genuinely-new = `upserted - refreshed`.
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

    /// Commit a finished scan into the catalog: replace records under the
    /// scanned `root` (component-boundary scoped) with `targetRecords`.
    ///
    /// - Parameter scanWasComplete: `completedCount >= discoveredCount` at
    ///   the call site. `false` means the probe loop aborted early (e.g.
    ///   consecutive-inaccessible threshold: volume unmounted mid-scan) —
    ///   the merge then upserts and NEVER prunes.
    ///
    /// Caller is responsible for persisting (saveCatalogDebounced) — kept
    /// out of here so tests can assert pure in-memory semantics.
    @discardableResult
    func commitScanResults(
        root: String,
        volName: String,
        targetRecords: [VideoRecord],
        scanWasComplete: Bool
    ) -> ScanMergeOutcome {
        var outcome = ScanMergeOutcome()
        let newPaths = Set(targetRecords.map(\.fullPath))
        let existingUnderRoot = records.filter { PathScope.contains($0.fullPath, within: root) }
        let vanished = existingUnderRoot.filter { !newPaths.contains($0.fullPath) }
        outcome.refreshed = existingUnderRoot.count - vanished.count
        outcome.upserted = targetRecords.count

        guard scanWasComplete else {
            // Partial scan (aborted mid-probe). Evidence is incomplete, so
            // pruning is forbidden: replace only the paths the scan actually
            // re-saw, keep everything else under the root.
            outcome.retainedStale = vanished.count
            records.removeAll {
                PathScope.contains($0.fullPath, within: root) && newPaths.contains($0.fullPath)
            }
            records.append(contentsOf: targetRecords)
            if !vanished.isEmpty {
                log("  ⚠ Scan of \(volName) did not complete — kept \(vanished.count) existing record(s) under \(root) that were not re-verified (no pruning on partial scans).")
            }
            scanMergeLog.notice("Partial-scan merge for \(volName, privacy: .public): +\(targetRecords.count) upserted, \(vanished.count) stale retained under \(root, privacy: .public)")
            appLog.write("Catalog merge (\(volName), PARTIAL): \(targetRecords.count) upserted, \(vanished.count) stale retained, 0 pruned")
            return outcome
        }

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
        let fm = FileManager.default
        var rootReachable = fm.fileExists(atPath: root)
        var genuinelyGone: [VideoRecord] = []
        var retainedInvisible: [VideoRecord] = []
        if rootReachable {
            scanMergeAfterRootCheckForTesting?()
            for rec in vanished {
                if fm.fileExists(atPath: rec.fullPath) {
                    retainedInvisible.append(rec)
                } else {
                    genuinelyGone.append(rec)
                }
            }
            // Millisecond unmount window (QA 2026-07-02): the root check
            // above and the loop just now are not atomic — a volume that
            // unmounts in between passes the check, then fails EVERY
            // per-record existence test. That signature (100% of a
            // non-trivial vanished set gone at once) warrants ONE root
            // re-check before pruning; if the root is no longer there,
            // fall through to the unreachable-root semantics below (retain
            // all — never prune based on an unreachable disk). The >10
            // floor keeps small legitimate cleanups (user deleted a
            // handful of files) off the extra stat.
            if genuinelyGone.count == vanished.count, vanished.count > 10,
               !fm.fileExists(atPath: root) {
                rootReachable = false
                genuinelyGone = []
            }
        }
        if !rootReachable {
            retainedInvisible = vanished
        }
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

        // Remove only what the scan re-saw (replaced by the fresh instance)
        // or what is genuinely gone from disk — retained-invisible records
        // stay untouched (original instances, so their dossier/user fields
        // never even need restoring).
        let gonePaths = Set(genuinelyGone.map(\.fullPath))
        records.removeAll {
            PathScope.contains($0.fullPath, within: root)
                && (newPaths.contains($0.fullPath) || gonePaths.contains($0.fullPath))
        }
        records.append(contentsOf: targetRecords)
        scanMergeLog.info("Scan merge for \(volName, privacy: .public): +\(targetRecords.count) upserted (\(outcome.refreshed) refreshed), \(genuinelyGone.count) pruned, \(retainedInvisible.count) retained-invisible under \(root, privacy: .public)")
        appLog.write("Catalog merge (\(volName)): \(targetRecords.count) upserted (\(outcome.refreshed) refreshed), \(genuinelyGone.count) pruned, \(retainedInvisible.count) retained (files on disk, invisible to scan options)")
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

    /// Copy the live catalog.json to a timestamped sibling
    /// `catalog.pre-merge.<stamp>.json` before a tripwired merge. Mirrors
    /// relocate's snapshotCatalogPreRelocate. Returns the snapshot path,
    /// or nil when no catalog file exists yet / the copy failed.
    ///
    /// Test gate: the SHARED store points at the user's real
    /// ~/Library/Application Support/VideoScan — never write there from a
    /// test host (same narrow gate as CatalogStore.saveNow). Tests inject
    /// CatalogStore(directory:) to exercise the real snapshot.
    @discardableResult
    func snapshotCatalogPreMerge() -> String? {
        if TestEnvironment.isTestHost && catalogStore === CatalogStore.shared { return nil }
        let src = catalogStore.fileLocation
        guard FileManager.default.fileExists(atPath: src) else { return nil }
        let dir = (src as NSString).deletingLastPathComponent
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        var snap = (dir as NSString).appendingPathComponent("catalog.pre-merge.\(stamp).json")
        // Two tripwires in the same second: uniquify rather than fail.
        var n = 1
        while FileManager.default.fileExists(atPath: snap) {
            snap = (dir as NSString).appendingPathComponent("catalog.pre-merge.\(stamp).\(n).json")
            n += 1
        }
        do {
            try FileManager.default.copyItem(atPath: src, toPath: snap)
            return snap
        } catch {
            log("  ⚠ Pre-merge snapshot failed: \(error.localizedDescription) — a tripwired merge will now degrade to no-prune (fail safe)")
            scanMergeLog.error("Pre-merge snapshot failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
