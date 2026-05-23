import Foundation
import Combine

extension VideoScanModel {

    // MARK: - Scene Captions Writeback
    //
    // Sibling to applyDetectedPeople (the people-tagging writeback). Where
    // PersonFinder writes detected names to detectedPeople, the captioning
    // pipeline writes VLM-generated descriptions to sceneCaptions, along
    // with the model id and date that produced them. Re-captioning
    // *replaces* the array wholesale — we don't merge captions from
    // different models per docs/scene_captions_plan.md.

    /// Apply scene captions from a captioning run to a single catalog
    /// record by path. Replaces any prior captions on that record (the
    /// "re-caption" flow) and records the model + current date as
    /// provenance.
    ///
    /// Passing an empty `captions` array is meaningful: it records that
    /// captioning ran on this file and found nothing recognizable —
    /// distinct from "never captioned" (sceneCaptionModel == nil).
    ///
    /// Returns true if a record was found and updated, false if no
    /// record matches `path` in the catalog (the captioning pipeline
    /// may produce captions for files not yet cataloged).
    @discardableResult
    func applyCaptions(
        _ captions: [SceneCaption],
        to path: String,
        model: String
    ) -> Bool {
        guard !path.isEmpty, !model.isEmpty else { return false }
        guard let record = records.first(where: { $0.fullPath == path }) else {
            return false
        }
        record.sceneCaptions = captions
        record.sceneCaptionModel = model
        record.sceneCaptionDate = Date()
        objectWillChange.send()
        saveCatalogDebounced()
        // Narrative log: one line per file captioned. Empty captions
        // still logged (and explicitly noted) — "ran VLM, found
        // nothing" is itself useful progress info that distinguishes
        // from "never captioned".
        let filename = (path as NSString).lastPathComponent
        let summary = captions.isEmpty
            ? "no captions"
            : "\(captions.count) caption(s)"
        appLog.write("Catalog: captioned \(filename) — \(summary) (\(model))")
        return true
    }

    /// Bulk variant. Maps [path → captions] to the catalog in one pass —
    /// useful when the captioning loop finishes a batch and wants to
    /// flush all records to disk via a single debounced save. Records
    /// the same `model` and a single `Date()` for all updates so a
    /// "captioned in this batch" filter can group by capture time.
    ///
    /// Returns the count of records updated (paths matched). Records
    /// whose paths aren't in the catalog are silently skipped.
    @discardableResult
    func applyCaptions(
        _ batch: [String: [SceneCaption]],
        model: String
    ) -> Int {
        guard !model.isEmpty, !batch.isEmpty else { return 0 }
        var byPath: [String: VideoRecord] = [:]
        byPath.reserveCapacity(records.count)
        for r in records { byPath[r.fullPath] = r }

        let now = Date()
        var updated = 0
        var totalCaptions = 0
        for (path, captions) in batch {
            guard let record = byPath[path] else { continue }
            record.sceneCaptions = captions
            record.sceneCaptionModel = model
            record.sceneCaptionDate = now
            updated += 1
            totalCaptions += captions.count
        }

        if updated > 0 {
            objectWillChange.send()
            saveCatalogDebounced()
            // Batch narrative: one line per batch flush. Skipped is the
            // count of paths in the batch that didn't match a catalog
            // row (e.g. files captioned but not yet scanned in).
            let skipped = batch.count - updated
            let skippedSuffix = skipped > 0
                ? ", \(skipped) skipped (uncataloged)"
                : ""
            appLog.write("Catalog: captioned \(updated) file(s) with \(totalCaptions) caption(s) (\(model))\(skippedSuffix)")
        }
        return updated
    }
}
