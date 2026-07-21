import Foundation
import os

// MARK: - Non-Video Media Purge — unified model entry point (2026-07-21)
//
// Model side of the single "Purge Non-Video Media…" dialog. It composes the
// two existing category purges (cover-art music, unrelated audio) behind one
// call parameterized by the selected categories and volumes. NO new purge
// logic: the candidate set comes from NonVideoMediaPurge.classify (which
// reuses the two QA-approved predicates), and the removal MIRRORS
// purgeUnrelatedAudioRecords() / purgeCoverArtMusicRecords() EXACTLY —
// snapshot-before-destroy with a fail-safe degrade, one array-level
// removeAll, search-index rebuild, one synchronous save, undo-state clear,
// and the same logging shape. Files on disk are NEVER touched.
//
// Empty-anchor guard: when .unrelatedAudio is requested but the catalog has
// no video/essence anchors, the classification yields ZERO unrelated-audio
// candidates (fail-safe built into classify), so nothing in that category can
// be removed; we additionally LOG an explicit refusal for parity with
// purgeUnrelatedAudioRecords(). Cover-art removal is unaffected by anchors.
//
// Memory: the Classification matrix (a few MB worst case, see
// NonVideoMediaPurge.swift) plus one Set<UUID> of doomed IDs bounded by the
// catalog size. No media bytes read; single O(N) classification pass.

let nonVideoMediaPurgeLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                   category: "nonVideoMediaPurge")

extension VideoScanModel {

    /// Build the (category × volume) classification for the current catalog —
    /// the ONE O(N) pass the dialog computes on appear and then queries by
    /// cell arithmetic. Thin passthrough so the sheet doesn't reach into the
    /// free function directly.
    func classifyNonVideoMedia() -> NonVideoMediaPurge.Classification {
        NonVideoMediaPurge.classify(records: records)
    }

    /// Remove every non-video-media record in the selected `categories` on the
    /// selected `volumeKeys`. Returns the number of records actually removed
    /// (0 = safe no-op: no snapshot, no save).
    ///
    /// Discipline mirrors purgeUnrelatedAudioRecords() EXACTLY:
    /// snapshot-before-destroy with a fail-safe degrade, a single array-level
    /// removeAll, index rebuild, one batched save, undo-state clear.
    @discardableResult
    func purgeNonVideoMedia(categories: Set<NonVideoCategory>,
                            volumeKeys: Set<String>) -> Int {
        guard !categories.isEmpty, !volumeKeys.isEmpty else {
            log("Purge Non-Video Media: nothing selected — no categories or no volumes chosen. Nothing removed.")
            return 0
        }

        // Fresh classification at purge time so the removed set is the TRUE
        // current catalog, never a stale count captured earlier.
        let classification = NonVideoMediaPurge.classify(records: records)

        // Empty-anchor guard (parity with purgeUnrelatedAudioRecords): if the
        // caller wants unrelated-audio but there are no video/essence anchors,
        // that category is refused. classify already produced ZERO unrelated
        // candidates in that case, so the doomed set below excludes it — we
        // just log the refusal so the console explains the empty removal.
        if categories.contains(.unrelatedAudio), !classification.hasVideoAnchors {
            log("Purge Non-Video Media: REFUSED unrelated-audio category — this catalog has no video records to relate audio to. Re-scan your video volumes first. (Other selected categories still processed.)")
            appLog.write("Purge Non-Video Media (REFUSED unrelated-audio): no video anchors in catalog")
            nonVideoMediaPurgeLog.error("Refused unrelated-audio: no video anchors")
        }

        let doomed = classification.candidateIDs(categories: categories,
                                                 volumeKeys: volumeKeys)
        guard !doomed.isEmpty else {
            log("Purge Non-Video Media: nothing to remove for the selected categories / volumes.")
            return 0
        }

        // 1. Pre-purge recovery snapshot. Fail-safe: if we can't write it,
        //    remove nothing. (Skipped under XCTest / the shared store —
        //    snapshotCatalog returns nil there by design; injected-store tests
        //    exercise the .prev + save path directly.)
        var snapshotPath: String? = nil
        if !Self.isRunningTests {
            snapshotPath = snapshotCatalog(prefix: "pre-nonvideo-purge")
            if snapshotPath == nil {
                log("""
                  ⚠️ Purge Non-Video Media DEGRADED — this would remove \(doomed.count) record(s), \
                  but the pre-purge safety snapshot could NOT be written. NOTHING was removed. \
                  Fix the catalog directory and try again.
                  """)
                appLog.write("Purge Non-Video Media (DEGRADED): could not write pre-purge snapshot; kept all \(doomed.count) record(s)")
                nonVideoMediaPurgeLog.error("Degraded: snapshot failed; kept \(doomed.count) record(s)")
                return 0
            }
        }

        // 2. The removal. One array-level mutation → the `records` didSet fires
        //    once, re-deriving stream-type / dossier / volume counts.
        let countBefore = records.count
        records.removeAll { doomed.contains($0.id) }
        let removed = countBefore - records.count

        // 3. Rebuild the search index against the post-purge catalog — a bulk
        //    removal, so a full O(n) rebuild is cheaper and safer than
        //    per-record key diffs (same call the cover-art / unrelated-audio
        //    and bulk volume-rename paths use).
        searchIndex.rebuild(records: records)

        // 4. Persist THROUGH CatalogStore — synchronous so the removal is on
        //    disk immediately. catalog.json.prev, rotated at load, still holds
        //    the pre-session copy as a second safety net.
        saveCatalogNow()
        if !Self.isRunningTests {
            try? searchIndex.saveToDisk()
        }

        // Purged wholesale — any armed soft-delete undo banner is meaningless.
        clearPurgeUndoState()

        let cats = categories.map(\.rawValue).sorted().joined(separator: ", ")
        let snapNote = snapshotPath.map { " — recovery snapshot: \($0)" } ?? ""
        log("Purge Non-Video Media: removed \(removed) record(s) [\(cats)] across \(volumeKeys.count) volume(s) from the catalog. Files on disk were untouched.\(snapNote)")
        appLog.write("Purge Non-Video Media: removed \(removed) record(s) [\(cats)]\(snapNote)")
        nonVideoMediaPurgeLog.info("Purged \(removed) record(s) of \(doomed.count) matched [\(cats)]")
        return removed
    }
}
