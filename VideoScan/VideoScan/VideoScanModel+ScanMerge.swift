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
//   - Mass-deletion tripwire (defense in depth): a complete scan whose
//     merge would remove MORE THAN 50 records AND MORE THAN 20% of the
//     existing records under the root first snapshots catalog.json to a
//     timestamped sibling (catalog.pre-merge.<stamp>.json — same pattern
//     as relocate's catalog.pre-relocate.*) and logs a prominent warning,
//     then proceeds. Snapshot+warn+proceed (not a confirmation dialog)
//     because scans finish unattended — overnight batches must not hang
//     on a sheet, and the snapshot makes recovery a file copy.
//
// Console etiquette (fa24921): the tripwire emits ONE warning block per
// merge, never per-record lines.

private let scanMergeLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "scanMerge")

/// What a scan-completion merge did to the catalog. Returned for logging
/// and pinned by ScanMergeScopeTests.
struct ScanMergeOutcome: Equatable {
    /// Old records under the root replaced by a fresh record at the same path.
    var refreshed: Int = 0
    /// Old records under the root removed because the scan no longer sees
    /// their file (complete scans only).
    var pruned: Int = 0
    /// Fresh records appended.
    var added: Int = 0
    /// Old records under the root kept even though the scan didn't re-see
    /// them (partial scans only — never pruned on incomplete evidence).
    var retainedStale: Int = 0
    /// True when the mass-deletion tripwire fired (snapshot + warning).
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
    /// `// C++: a free predicate — pure, trivially unit-testable.`
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
        outcome.added = targetRecords.count

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

        outcome.pruned = vanished.count

        // Tripwire: never silently mass-delete. Snapshot first, warn loudly,
        // then proceed — the merge itself may be legitimate (user really did
        // clear out a drive), but it must always be recoverable.
        if Self.scanMergeTripwireWouldFire(existingCount: existingUnderRoot.count,
                                           removedCount: vanished.count) {
            outcome.tripwireFired = true
            outcome.snapshotPath = snapshotCatalogPreMerge()
            let pct = existingUnderRoot.isEmpty ? 0 : vanished.count * 100 / existingUnderRoot.count
            log("""
              ⚠️⚠️ MASS-REMOVAL TRIPWIRE — \(volName)
              This scan removes \(vanished.count) of \(existingUnderRoot.count) cataloged record(s) under \(root) (\(pct)%).
              If files were NOT deleted from disk, the scan likely failed to see part of the tree (skip rules, unmount, I/O errors).
              Pre-merge catalog snapshot: \(outcome.snapshotPath ?? "SNAPSHOT FAILED — see log")
              """)
            scanMergeLog.warning("Mass-removal tripwire fired for \(volName, privacy: .public): removing \(vanished.count) of \(existingUnderRoot.count) records under \(root, privacy: .public); snapshot=\(outcome.snapshotPath ?? "FAILED", privacy: .public)")
            appLog.write("TRIPWIRE: scan merge for \(volName) removes \(vanished.count)/\(existingUnderRoot.count) records under \(root); pre-merge snapshot: \(outcome.snapshotPath ?? "FAILED")")
        }

        records.removeAll { PathScope.contains($0.fullPath, within: root) }
        records.append(contentsOf: targetRecords)
        scanMergeLog.info("Scan merge for \(volName, privacy: .public): +\(targetRecords.count) added/refreshed, \(vanished.count) pruned under \(root, privacy: .public)")
        appLog.write("Catalog merge (\(volName)): \(targetRecords.count) added/refreshed, \(vanished.count) pruned")
        return outcome
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
            log("  ⚠ Pre-merge snapshot failed: \(error.localizedDescription) — merge proceeding WITHOUT a safety copy")
            scanMergeLog.error("Pre-merge snapshot failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
