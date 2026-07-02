import Foundation
import Combine

extension VideoScanModel {

    // MARK: - Audio Transcript Writeback
    //
    // Sibling to applyCaptions / applyDetectedPeople. Where the captioning
    // pipeline writes per-frame VLM descriptions, the transcription
    // pipeline writes a single text blob to `audioTranscript`, plus the
    // engine model id + date for provenance. Re-transcribing replaces
    // the text wholesale — we don't merge transcripts from different
    // models. (Matches the sceneCaptions "re-caption replaces" rule.)
    //
    // Provenance stamp (fix 2026-07-01): every apply variant also stamps
    // `dossierProcessedAt` (backfill-only). The helper and the full
    // rationale live in VideoScanModel+DossierPropagation
    // (`stampDossierProvenance`), shared with the applyCaptions family —
    // the short version: without the stamp, a legit direct write onto an
    // `isLikelyUnanalyzable` record matched the smear-cleanup corruption
    // signature and the one-shot cleanup would destroy it.

    /// Apply a fresh audio transcript to a single catalog record by
    /// reference. Replaces any prior transcript on that record (the
    /// "re-transcribe" flow) and stamps the model id + current date
    /// as provenance.
    ///
    /// An empty `transcript` string is meaningful: it records that
    /// transcription ran on this file and found no speech — distinct
    /// from "never transcribed" (audioTranscriptModel == nil).
    ///
    /// `// @MainActor` ≈ "this method must run on the UI thread". The
    /// containing class is already @MainActor so this is redundant
    /// (left explicit to match the engine-wiring spec for clarity).
    @MainActor
    func applyAudioTranscript(
        _ transcript: String,
        modelID: String,
        to record: VideoRecord
    ) {
        guard !modelID.isEmpty else { return }
        let now = Date()
        record.audioTranscript = transcript
        record.audioTranscriptModel = modelID
        record.audioTranscriptDate = now
        // Smear-signature exclusion — see the section comment above.
        stampDossierProvenance(on: record, modelID: modelID, at: now)
        // Propagate to MD5-identical siblings so search finds this
        // transcript via any copy of the file (Phase 0).
        propagateDossierToMD5Duplicates(of: record)
        objectWillChange.send()
        saveCatalogDebounced()

        // Narrative log: one line per file transcribed. Empty transcript
        // still logged with the explicit "(no speech)" suffix so the
        // log readability matches the captioning analogue.
        let filename = (record.fullPath as NSString).lastPathComponent
        let chars = transcript.count
        let summary = chars == 0 ? "no speech" : "\(chars) char(s)"
        appLog.write("Catalog: transcribed \(filename) — \(summary) (\(modelID))")
    }

    /// Path-keyed variant. Looks the record up in `records` by exact
    /// `fullPath` match (same conservative rule applyCaptions uses) and
    /// returns true if the record was found and updated, false if no
    /// catalog row matches.
    ///
    /// The transcription pipeline may produce a transcript for a file
    /// that hasn't been cataloged yet (rare, but possible if the user
    /// transcribes a folder before scanning it); silent skip is the
    /// right behavior — the next catalog scan will pick the file up
    /// and the user can re-transcribe.
    @MainActor
    @discardableResult
    func applyAudioTranscript(
        _ transcript: String,
        to path: String,
        model: String
    ) -> Bool {
        guard !path.isEmpty, !model.isEmpty else { return false }
        guard let record = records.first(where: { $0.fullPath == path }) else {
            return false
        }
        applyAudioTranscript(transcript, modelID: model, to: record)
        return true
    }

    /// Bulk variant. Maps [path → transcript] to the catalog in one
    /// pass — useful when the transcription loop finishes a batch and
    /// wants to flush all records to disk via a single debounced save.
    /// Records the same `model` and a single `Date()` for all updates
    /// so a "transcribed in this batch" filter can group by capture
    /// time.
    ///
    /// Returns the count of records updated (paths matched). Records
    /// whose paths aren't in the catalog are silently skipped — same
    /// rule as `applyCaptions(_:model:)`.
    @MainActor
    @discardableResult
    func applyAudioTranscripts(
        _ batch: [String: String],
        model: String
    ) -> Int {
        guard !model.isEmpty, !batch.isEmpty else { return 0 }
        var byPath: [String: VideoRecord] = [:]
        byPath.reserveCapacity(records.count)
        for r in records { byPath[r.fullPath] = r }

        let now = Date()
        var updated = 0
        var totalChars = 0
        var emptyCount = 0
        for (path, transcript) in batch {
            guard let record = byPath[path] else { continue }
            record.audioTranscript = transcript
            record.audioTranscriptModel = model
            record.audioTranscriptDate = now
            // Smear-signature exclusion — see the section comment above.
            stampDossierProvenance(on: record, modelID: model, at: now)
            propagateDossierToMD5Duplicates(of: record)
            updated += 1
            totalChars += transcript.count
            if transcript.isEmpty { emptyCount += 1 }
        }

        if updated > 0 {
            objectWillChange.send()
            saveCatalogDebounced()
            let skipped = batch.count - updated
            let skippedSuffix = skipped > 0
                ? ", \(skipped) skipped (uncataloged)"
                : ""
            let emptySuffix = emptyCount > 0
                ? ", \(emptyCount) with no speech"
                : ""
            appLog.write("Catalog: transcribed \(updated) file(s) — \(totalChars) char(s) total\(emptySuffix) (\(model))\(skippedSuffix)")
        }
        return updated
    }
}
