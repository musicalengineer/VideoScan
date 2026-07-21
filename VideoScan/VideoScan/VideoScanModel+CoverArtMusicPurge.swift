import Foundation
import os

// MARK: - Cover-Art Music Purge (catalog maintenance, 2026-07-20)
//
// The model-side entry points for the one-time removal of cover-art
// music strays (see CoverArtMusicPurge.swift for the pure predicate and
// the background). This is a GENUINE removal — the matching records leave
// the `records` array and catalog.json — NOT a soft-delete / set-aside.
// Rick's decision: these are commercial music purchases with zero
// archival value, so hiding them (Tidy/set-aside) still leaves 2,231
// dead rows in the file. Purge means gone.
//
// Safety, in order:
//   1. Pre-purge snapshot — catalog.pre-coverart-purge.<stamp>.json,
//      the same recovery-copy mechanism the scan-merge tripwire and
//      target-removal use. If the snapshot can't be written we DEGRADE
//      to no-op (fail-safe: no recovery copy → destroy nothing).
//   2. Removal goes THROUGH CatalogStore (saveCatalogNow → saveNow),
//      which is also the layer that rotated catalog.json → catalog.json.prev
//      at load time, so the previous-good copy is preserved independently.
//   3. Search index rebuilt from the post-purge records so a stale
//      fullPath key can never resolve to a removed record.
//   4. Stream-type / dossier / volume counters re-derive automatically:
//      they hang off the `records` @Published didSet, which the
//      array-level removeAll fires exactly once.
//
// Files on disk are NEVER touched — this only edits catalog records.
//
// Memory: one Set<UUID> of candidate IDs (≤ record count) plus the
// snapshot DTO built inside CatalogStore. Worst case is bounded by the
// catalog size (~100k records), no media bytes are ever read. Single
// pass; no per-file I/O.

let coverArtMusicPurgeLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                   category: "coverArtMusicPurge")

extension VideoScanModel {

    /// Live count of cover-art-music purge candidates in the current
    /// catalog. Recomputed on demand — the confirmation sheet reads this
    /// when it opens so the number is always the TRUE current set, never a
    /// hard-coded historical value.
    var coverArtMusicPurgeCount: Int {
        CoverArtMusicPurge.count(in: records)
    }

    /// The matching records themselves (for a CSV/preview if ever wanted).
    var coverArtMusicPurgeCandidates: [VideoRecord] {
        CoverArtMusicPurge.candidates(in: records)
    }

    /// Remove every cover-art-music stray from the catalog. Returns the
    /// number of records actually removed (0 when there are none — a safe
    /// no-op, no snapshot, no save).
    ///
    /// Discipline mirrors removeCatalogRecords(underTargetRoot:):
    /// snapshot-before-destroy with a fail-safe degrade, then a single
    /// array-level removeAll, index rebuild, and one batched save.
    @discardableResult
    func purgeCoverArtMusicRecords() -> Int {
        let doomed = CoverArtMusicPurge.candidateIDs(in: records)
        guard !doomed.isEmpty else {
            log("Purge Cover-Art Music: nothing to remove — no cover-art music records in the catalog.")
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
            snapshotPath = snapshotCatalog(prefix: "pre-coverart-purge")
            if snapshotPath == nil {
                log("""
                  ⚠️ Purge Cover-Art Music DEGRADED — this would remove \(doomed.count) record(s), \
                  but the pre-purge safety snapshot could NOT be written. NOTHING was removed. \
                  Fix the catalog directory and try again.
                  """)
                appLog.write("Purge Cover-Art Music (DEGRADED): could not write pre-purge snapshot; kept all \(doomed.count) record(s)")
                coverArtMusicPurgeLog.error("Degraded: snapshot failed; kept \(doomed.count) record(s)")
                return 0
            }
        }

        // 2. The removal. One array-level mutation → the `records` didSet
        //    fires once, re-deriving stream-type / dossier / volume counts.
        let countBefore = records.count
        records.removeAll { doomed.contains($0.id) }
        let removed = countBefore - records.count

        // 3. Rebuild the search index against the post-purge catalog. This
        //    is a bulk removal, so a full O(n) rebuild is cheaper and
        //    safer than per-record key diffs (same call the bulk
        //    volume-rename path uses).
        searchIndex.rebuild(records: records)

        // 4. Persist THROUGH CatalogStore — synchronous so the removal is
        //    on disk immediately (this is a deliberate one-shot action,
        //    not a mid-scan burst). catalog.json.prev, rotated at load,
        //    still holds the pre-session copy as a second safety net.
        saveCatalogNow()
        if !Self.isRunningTests {
            // Keep the persisted search index fresh against the catalog we
            // just saved (best-effort, exactly like the rename path).
            try? searchIndex.saveToDisk()
        }

        // The purged rows are gone wholesale — any armed soft-delete undo
        // banner is now meaningless. Drop it (same reasoning as
        // deleteAllCatalog / clearResults).
        clearPurgeUndoState()

        let snapNote = snapshotPath.map { " — recovery snapshot: \($0)" } ?? ""
        log("Purge Cover-Art Music: removed \(removed) cover-art music record(s) from the catalog. Files on disk were untouched.\(snapNote)")
        appLog.write("Purge Cover-Art Music: removed \(removed) record(s)\(snapNote)")
        coverArtMusicPurgeLog.info("Purged \(removed) cover-art music record(s) of \(doomed.count) matched")
        return removed
    }
}
