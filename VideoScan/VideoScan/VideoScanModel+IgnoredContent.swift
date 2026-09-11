// VideoScanModel+IgnoredContent.swift
// Model glue for the content-keyed ignore list (IgnoredContentStore.swift):
// the launch load, the two writers' hooks (Tidy apply / Remove from
// Catalog add; Put Back / Undo remove — the override), the scan-time gate
// that keeps ignored content from being re-ingested at a NEW path, and
// the retroactive index the Tidy plan uses for "Junk that came back".
//
// Console etiquette (fa24921): ONE summary line per scan, never per-file
// spam; per-file detail goes to catalog.log like the scope gate's
// "NOT CATALOGED —" lines (VideoScanModel+CatalogScope.swift).

import Foundation
import os

private let ignoredContentLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "ignoredContent")

extension VideoScanModel {

    // MARK: Launch

    /// Called once from init (beside configureArchiveAngelSweep). Loads
    /// the sidecar off-main so the first scan already knows what to skip.
    /// Test hosts never load (their store points at a scratch folder).
    func configureIgnoredContent() {
        guard !TestEnvironment.isTestHost else { return }
        Task { [weak self] in
            guard let self else { return }
            let loaded = await self.ignoredContentStore.load()
            self.ignoredContentRevision &+= 1
            if loaded {
                appLog.write("Ignored content: \(self.ignoredContentStore.count) entr\(self.ignoredContentStore.count == 1 ? "y" : "ies") loaded — content set aside before will not be cataloged again (Tidy → Ignored content to put back)")
            }
        }
    }

    // MARK: Writers (add) — Tidy apply, Remove from Catalog

    /// Remember a record's content so a rescan never catalogs another copy
    /// of it under a new path. `reason` = the set-aside reason key.
    /// Returns true when a NEW entry was made (already-known content is a
    /// no-op — the original date and reason stand). Per-record, O(1);
    /// the BATCH caller publishes once via `scheduleIgnoredContentSave`.
    @discardableResult
    func noteIgnoredContent(_ rec: VideoRecord, reason: String, now: Date = Date()) -> Bool {
        ignoredContentStore.add(partialMD5: rec.partialMD5, sizeBytes: rec.sizeBytes,
                                filename: rec.filename, reason: reason,
                                samplePath: rec.fullPath, now: now)
    }

    // MARK: Writers (remove) — Put Back in Catalog, Undo, the sheet

    /// THE OVERRIDE for a record: forget its content so a rescan brings
    /// it back. Returns the number of entries removed. Per-record, O(1).
    @discardableResult
    func forgetIgnoredContent(for rec: VideoRecord) -> Int {
        ignoredContentStore.remove(partialMD5: rec.partialMD5, sizeBytes: rec.sizeBytes,
                                   filename: rec.filename)
    }

    /// The override sheet's "Put back": forget one entry; the next rescan
    /// of its volume catalogs the file again. Files were never deleted.
    @discardableResult
    func putBackIgnoredContent(id: UUID) -> Bool {
        guard let entry = ignoredContentStore.entry(id: id) else { return false }
        guard ignoredContentStore.remove(id: id) else { return false }
        scheduleIgnoredContentSave()
        log("Ignored content: put back “\(entry.filename)” — it will be cataloged again on the next scan of its volume.")
        appLog.write("Ignored content: entry removed for \(entry.filename) (\(entry.sizeBytes) bytes, reason \(entry.reason)); will be re-ingested on rescan")
        return true
    }

    /// Persist the store off-main AND publish the change (ONE
    /// `ignoredContentRevision` bump per batch — never per record: Tidy
    /// can remember 80k rows in one apply). A test host's store writes to
    /// its scratch folder.
    func scheduleIgnoredContentSave() {
        ignoredContentRevision &+= 1
        let store = ignoredContentStore
        Task { @MainActor in
            if await store.save() == false {
                ignoredContentLog.error("ignored-content.json could not be written under \(store.directory.path, privacy: .public)")
            }
        }
    }

    // MARK: Scan-time gate

    /// What the gate did to one scan's fresh records.
    struct IgnoredContentGateOutcome {
        var admitted: [VideoRecord] = []
        /// Fresh files at NEW paths whose content is on the ignore list.
        var ignored = 0
    }

    /// Drop fresh probes whose content is on the ignore list — but ONLY
    /// files at paths the catalog does not know. A path that already has a
    /// record (active, set aside or purged) is always admitted: the merge
    /// + rescan preservation own that row, and silently dropping it would
    /// prune an existing record (the row would look "genuinely gone").
    /// Runs AFTER the catalog-scope gate, BEFORE preservation and merge.
    /// O(targetRecords) with O(1) lookups; no I/O.
    func applyIgnoredContentGate(targetRecords: [VideoRecord], volName: String) -> IgnoredContentGateOutcome {
        var outcome = IgnoredContentGateOutcome()
        guard !ignoredContentStore.isEmpty else {
            outcome.admitted = targetRecords
            return outcome
        }
        outcome.admitted.reserveCapacity(targetRecords.count)
        for rec in targetRecords {
            if record(forPath: rec.fullPath) != nil {
                outcome.admitted.append(rec)          // existing row — never dropped here
                continue
            }
            if let reason = ignoredContentStore.reason(partialMD5: rec.partialMD5, sizeBytes: rec.sizeBytes,
                                                       filename: rec.filename) {
                outcome.ignored += 1
                appLog.write("NOT CATALOGED — previously set aside (\(reason); Tidy → Ignored content to put back): \(rec.fullPath)")
                continue
            }
            outcome.admitted.append(rec)
        }
        if outcome.ignored > 0 {
            // ONE summary line per scan.
            log("  IGNORED \(outcome.ignored) file\(outcome.ignored == 1 ? "" : "s") previously set aside (Tidy → Ignored content to put back)")
            ignoredContentLog.info("Ignore gate \(volName, privacy: .public): ignored=\(outcome.ignored) admitted=\(outcome.admitted.count)")
        }
        return outcome
    }

    // MARK: Retroactive index for Tidy

    /// The lookup the Tidy plan uses for "Junk that came back": the
    /// persisted store PLUS the catalog's own memory of junk — every
    /// set-aside record (reason = its set-aside reason) and every purged
    /// tombstone (reason = removed-by-user). The tombstones are what make
    /// the category RETROACTIVE on a catalog that predates the store: the
    /// 2,030 copies measured on 2026-09-11 match records that were set
    /// aside or removed BEFORE any entry was ever written.
    ///
    /// Duplicate-delete tombstones are excluded: a purged "Extra copy"
    /// shares its content with the KEEPER, which is not junk. (Measured
    /// 2026-09-11: 4 such tombstones; 0 of the 628 purged-content matches
    /// shared a duplicate group with their tombstone.)
    func retroactiveIgnoredContentIndex() -> IgnoredContentIndex {
        var index = ignoredContentStore.index()
        for rec in records {
            if let reason = rec.setAsideReason {
                index.add(partialMD5: rec.partialMD5, sizeBytes: rec.sizeBytes,
                          filename: rec.filename, reason: reason)
            } else if rec.isPurged, rec.duplicateDisposition != .extraCopy {
                index.add(partialMD5: rec.partialMD5, sizeBytes: rec.sizeBytes,
                          filename: rec.filename,
                          reason: CatalogScopePolicy.SetAsideReason.removedByUser.rawValue)
            }
        }
        return index
    }
}
