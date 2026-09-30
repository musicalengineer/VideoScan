import Foundation
import os

// MARK: - Non-Video Media Purge — unified model entry point (2026-07-21)
//
// Model side of the single "Purge Non-Video Media…" dialog. REDESIGN (Rick,
// 2026-07-21): the dialog's "what to purge" control is a PURE EXTENSION
// CHECKLIST, so this purge is parameterized by a set of file EXTENSIONS and a
// set of volumes. It removes every catalog record whose lowercased extension
// is in the selected set AND whose volume key is in the selected set —
// LITERAL, including any A/V-paired records (the user was shown the
// "(N paired)" annotation per Rick; the guard is visible, not hidden here).
//
// The candidate set comes from NonVideoMediaPurge.classify (ONE O(N) pass),
// and the removal MIRRORS the other purges EXACTLY: snapshot-before-destroy
// with a fail-safe degrade, one array-level removeAll, search-index rebuild,
// one synchronous save, undo-state clear, same logging shape. Video containers
// and Avid essence are never offered by classify, so they can never be removed
// here. Files on disk are NEVER touched.
//
// Memory: the Classification matrix (a few MB worst case, see
// NonVideoMediaPurge.swift) plus one Set<UUID> of doomed IDs bounded by the
// catalog size. No media bytes read; single O(N) classification pass.

let nonVideoMediaPurgeLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                   category: "nonVideoMediaPurge")

/// Result of a `purgeNonVideoMedia` call — how many catalog records were
/// removed and where the pre-purge recovery snapshot was written. The sheet
/// threads both out to its completion dialog so the user sees the count AND the
/// recovery path. `snapshotPath == nil` means no snapshot was written (a safe
/// no-op purge, or the shared-store test path). A struct-with-value-semantics
/// return ≈ a C++ small POD returned by value.
struct PurgeOutcome: Equatable {
    let removed: Int
    let snapshotPath: String?

    /// Nothing removed, no snapshot — the safe no-op / refusal result.
    static let none = PurgeOutcome(removed: 0, snapshotPath: nil)
}

extension VideoScanModel {

    /// Build the (extension × volume) classification for the current catalog —
    /// the ONE O(N) pass the dialog computes on appear and then queries by
    /// cell arithmetic. Thin passthrough so the sheet doesn't reach into the
    /// free function directly.
    func classifyNonVideoMedia() -> NonVideoMediaPurge.Classification {
        NonVideoMediaPurge.classify(records: records)
    }

    /// Remove every catalog record whose (lowercased) extension is in the
    /// selected `extensions` AND whose volume key is in the selected
    /// `volumeKeys`. Returns a `PurgeOutcome` carrying the number of records
    /// actually removed AND the recovery-snapshot path that was written
    /// (`PurgeOutcome.none` = safe no-op: no snapshot, no save). The sheet uses
    /// both fields to render its completion confirmation.
    ///
    /// LITERAL removal — this includes A/V-paired records that match. The
    /// paired-record risk is surfaced to the user by the dialog's "(N paired)"
    /// annotation, per Rick; there is no hidden keep-rule for pairs here.
    /// Video containers / Avid essence are never in the classification, so a
    /// selection can never target them.
    ///
    /// Discipline mirrors the other purges EXACTLY: snapshot-before-destroy
    /// with a fail-safe degrade, a single array-level removeAll, index rebuild,
    /// one batched save, undo-state clear.
    @discardableResult
    func purgeNonVideoMedia(extensions: Set<String>,
                            volumeKeys: Set<String>) -> PurgeOutcome {
        // Normalize the incoming extension selection so ".MP3" / "MP3" / "mp3"
        // all match the classification's lowercased, dot-stripped keys.
        let wanted = Set(extensions.map { ext -> String in
            var e = ext.lowercased()
            if e.hasPrefix(".") { e.removeFirst() }
            return e
        })

        guard !wanted.isEmpty, !volumeKeys.isEmpty else {
            log("Purge Non-Video Media: nothing selected — no extensions or no volumes chosen. Nothing removed.")
            return .none
        }

        // Fresh classification at purge time so the removed set is the TRUE
        // current catalog, never a stale count captured earlier.
        let classification = NonVideoMediaPurge.classify(records: records)

        let doomed = classification.candidateIDs(extensions: wanted,
                                                 volumeKeys: volumeKeys)
        guard !doomed.isEmpty else {
            log("Purge Non-Video Media: nothing to remove for the selected extensions / volumes.")
            return .none
        }

        // 1. Pre-purge recovery snapshot. Fail-safe: if we can't write it,
        //    remove nothing. Skipped ONLY for the shared store under XCTest —
        //    snapshotCatalog returns nil there by design. An INJECTED temp
        //    store (the removal-test harness) DOES take a real snapshot to its
        //    own temp dir, so the outcome's snapshotPath is exercised in tests.
        let usingSharedStoreUnderTest =
            Self.isRunningTests && catalogStore === CatalogStore.shared
        var snapshotPath: String? = nil
        if !usingSharedStoreUnderTest {
            snapshotPath = snapshotCatalog(prefix: "pre-nonvideo-purge")
            if snapshotPath == nil {
                log("""
                  ⚠️ Purge Non-Video Media DEGRADED — this would remove \(doomed.count) record(s), \
                  but the pre-purge safety snapshot could NOT be written. NOTHING was removed. \
                  Fix the catalog directory and try again.
                  """)
                appLog.write("Purge Non-Video Media (DEGRADED): could not write pre-purge snapshot; kept all \(doomed.count) record(s)")
                nonVideoMediaPurgeLog.error("Degraded: snapshot failed; kept \(doomed.count) record(s)")
                return .none
            }
        }

        // 2a. SEVER the surviving partner's back-reference BEFORE removal.
        //    VideoRecord is a class and `pairedWith` is a STRONG ref, so the
        //    common A/V pair — a video-only .mxf (always excluded → survives)
        //    plus its audio half (offered → doomed) — would otherwise keep the
        //    "removed" audio record ALIVE via the survivor's `pairedWith`, and
        //    the survivor would still carry the shared `pairGroupID`. That
        //    resurrects the doomed record in the "Show pairs only" view (which
        //    appends `pairedWith` without re-filtering against live `records`)
        //    and lets Combine act on a record no longer in the catalog. So the
        //    "removing them severs that pairing" promise must be made TRUE
        //    here: for every SURVIVOR whose partner is doomed, clear its pairing.
        //    We only mutate survivors; a both-sides-doomed pair needs no special
        //    case (both ids are in `doomed`, both skipped). This runs inside the
        //    same mutation, before removeAll, so the single `records` didSet
        //    fires once and the index rebuild sees a consistent state.
        //    (C++ analogy: null out the dangling shared_ptr on the kept node so
        //    the erased node's refcount actually drops.)
        var doomedGroupIDs = Set<UUID>()
        for r in records where doomed.contains(r.id) {
            if let g = r.pairGroupID { doomedGroupIDs.insert(g) }
        }
        for r in records where !doomed.contains(r.id) {
            let partnerPurged =
                (r.pairedWith.map { doomed.contains($0.id) } ?? false) ||
                (r.pairGroupID.map { doomedGroupIDs.contains($0) } ?? false)
            if partnerPurged {
                r.pairedWith = nil
                r.pairGroupID = nil
            }
        }

        // 2b. The removal. One array-level mutation → the `records` didSet fires
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

        let exts = wanted.sorted().joined(separator: ", ")
        let snapNote = snapshotPath.map { " — recovery snapshot: \($0)" } ?? ""
        log("Purge Non-Video Media: removed \(removed) record(s) [\(exts)] across \(volumeKeys.count) volume(s) from the catalog. Files on disk were untouched.\(snapNote)")
        appLog.write("Purge Non-Video Media: removed \(removed) record(s) [\(exts)]\(snapNote)")
        nonVideoMediaPurgeLog.info("Purged \(removed) record(s) of \(doomed.count) matched [\(exts)]")
        return PurgeOutcome(removed: removed, snapshotPath: snapshotPath)
    }
}
