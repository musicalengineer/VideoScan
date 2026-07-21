import Foundation
import os

// MARK: - Unrelated Audio Purge (catalog maintenance, 2026-07-21)
//
// Model-side entry points for removing audio-only records that have no
// relationship to any video (see UnrelatedAudioPurge.swift for the pure
// criterion and background). This is a GENUINE removal — matching records
// leave the `records` array and catalog.json — NOT a soft-delete. It is
// reversible only in the sense that a re-scan re-adds the records and the
// files on disk are never touched.
//
// Safety mirrors purgeCoverArtMusicRecords() EXACTLY, in order:
//   1. Pre-purge snapshot — catalog.pre-unrelated-audio-purge.<stamp>.json,
//      the same recovery-copy mechanism cover-art purge / target-removal
//      use. If the snapshot can't be written we DEGRADE to a no-op
//      (fail-safe: no recovery copy → destroy nothing).
//   2. Removal goes THROUGH CatalogStore (saveCatalogNow → saveNow), which
//      also rotated catalog.json → catalog.json.prev at load, preserving a
//      second independent pre-session copy.
//   3. Search index rebuilt from the post-purge records so a stale
//      fullPath key can never resolve to a removed record.
//   4. Stream-type / dossier / volume counters re-derive automatically off
//      the `records` @Published didSet, fired exactly once by removeAll.
//
// Files on disk are NEVER touched — this only edits catalog records.
//
// Memory: three Set<String> video-side sets (~16k video records) plus one
// Set<UUID> of candidate IDs (bounded by the ~100k catalog size). No media
// bytes are read; single O(N) pass, no per-file I/O.

let unrelatedAudioPurgeLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                    category: "unrelatedAudioPurge")

extension VideoScanModel {

    /// Live count of unrelated-audio purge candidates in the current
    /// catalog. Recomputed on demand — the confirmation sheet reads the
    /// full `summary` (which includes this) on appear so the number is
    /// always the TRUE current set, never a hard-coded historical value.
    var unrelatedAudioPurgeCount: Int {
        UnrelatedAudioPurge.count(in: records)
    }

    /// The confirmation-sheet summary: live candidate count + the top
    /// parent directories among the candidates, in one combined pass so
    /// the sheet doesn't scan the catalog twice.
    func unrelatedAudioPurgeSummary(topN: Int = 6) -> UnrelatedAudioPurge.Summary {
        UnrelatedAudioPurge.summary(in: records, topN: topN)
    }

    /// The matching records themselves (for a CSV/preview if ever wanted).
    var unrelatedAudioPurgeCandidates: [VideoRecord] {
        UnrelatedAudioPurge.candidates(in: records)
    }

    /// Remove every unrelated audio-only record from the catalog. Returns
    /// the number of records actually removed (0 when there are none — a
    /// safe no-op, no snapshot, no save).
    ///
    /// Discipline mirrors purgeCoverArtMusicRecords() /
    /// removeCatalogRecords(underTargetRoot:): snapshot-before-destroy with
    /// a fail-safe degrade, then a single array-level removeAll, index
    /// rebuild, and one batched save.
    @discardableResult
    func purgeUnrelatedAudioRecords() -> Int {
        let doomed = UnrelatedAudioPurge.candidateIDs(in: records)
        guard !doomed.isEmpty else {
            log("Purge Non-Video Audio Junk: nothing to remove — no unrelated audio records in the catalog.")
            return 0
        }

        // 1. Pre-purge recovery snapshot. Fail-safe: if we can't write it,
        //    remove nothing. (Skipped under XCTest / the shared store —
        //    snapshotCatalog returns nil there by design, which would
        //    otherwise trip the degrade; tests drive removal through an
        //    injected store where the .prev + save path is exercised
        //    directly, so the snapshot is not the test's safety net.)
        var snapshotPath: String? = nil
        if !Self.isRunningTests {
            snapshotPath = snapshotCatalog(prefix: "pre-unrelated-audio-purge")
            if snapshotPath == nil {
                log("""
                  ⚠️ Purge Non-Video Audio Junk DEGRADED — this would remove \(doomed.count) record(s), \
                  but the pre-purge safety snapshot could NOT be written. NOTHING was removed. \
                  Fix the catalog directory and try again.
                  """)
                appLog.write("Purge Non-Video Audio Junk (DEGRADED): could not write pre-purge snapshot; kept all \(doomed.count) record(s)")
                unrelatedAudioPurgeLog.error("Degraded: snapshot failed; kept \(doomed.count) record(s)")
                return 0
            }
        }

        // 2. The removal. One array-level mutation → the `records` didSet
        //    fires once, re-deriving stream-type / dossier / volume counts.
        let countBefore = records.count
        records.removeAll { doomed.contains($0.id) }
        let removed = countBefore - records.count

        // 3. Rebuild the search index against the post-purge catalog. This
        //    is a bulk removal, so a full O(n) rebuild is cheaper and safer
        //    than per-record key diffs (same call the bulk volume-rename
        //    and cover-art purge paths use).
        searchIndex.rebuild(records: records)

        // 4. Persist THROUGH CatalogStore — synchronous so the removal is on
        //    disk immediately (a deliberate one-shot action, not a mid-scan
        //    burst). catalog.json.prev, rotated at load, still holds the
        //    pre-session copy as a second safety net.
        saveCatalogNow()
        if !Self.isRunningTests {
            // Keep the persisted search index fresh against the catalog we
            // just saved (best-effort, exactly like the rename path).
            try? searchIndex.saveToDisk()
        }

        // The purged rows are gone wholesale — any armed soft-delete undo
        // banner is now meaningless. Drop it (same reasoning as
        // deleteAllCatalog / clearResults / cover-art purge).
        clearPurgeUndoState()

        let snapNote = snapshotPath.map { " — recovery snapshot: \($0)" } ?? ""
        log("Purge Non-Video Audio Junk: removed \(removed) unrelated audio record(s) from the catalog. Files on disk were untouched.\(snapNote)")
        appLog.write("Purge Non-Video Audio Junk: removed \(removed) record(s)\(snapNote)")
        unrelatedAudioPurgeLog.info("Purged \(removed) unrelated audio record(s) of \(doomed.count) matched")
        return removed
    }
}
