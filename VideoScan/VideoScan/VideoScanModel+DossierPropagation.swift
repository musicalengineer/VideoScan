import Foundation
import Combine

// MARK: - Dossier propagation across MD5-identical records
//
// Phase 0 (Rick 2026-06-15): the same physical file gets cataloged
// multiple times — once per volume it's been scanned on — and each
// record runs its OWN Whisper / VLM / OCR pass. Speech recognition is
// non-deterministic enough that the resulting transcripts diverge
// across copies: ~10% of duplicate-file groups in Rick's catalog had
// transcripts that differed between mirrored copies. Concretely, the
// elevator-clip CapeCod1997 file existed three times: the offline
// Seagate2TB / Maxtor750 transcripts said "elevator" verbatim, while
// the online LaCieWorkspace transcript said "elevated line of trees"
// (same audio, same MD5, different Whisper run). Searching "elevator"
// found the offline copies — useless because they're not mounted —
// and missed the connected copy.
//
// Fix: dossier results belong to FILE CONTENT, not to a particular
// catalog path. Group records by partialMD5; for each group, pick the
// "best" transcript / captions / OCR (heuristic: longest non-empty
// wins — proxy for "most words recognized" / "most scenes captured")
// and propagate to every member of the group. Going forward, every
// dossier writeback propagates to siblings too.
//
// Records with empty partialMD5 are treated as unique — propagation
// can't safely identify their siblings without content-hash evidence,
// so we leave them alone.

extension VideoScanModel {

    // MARK: - Public API

    /// Propagate the freshest / largest dossier across every catalog
    /// record sharing this record's `partialMD5`. Called after every
    /// transcript / caption / OCR writeback so duplicate copies stay
    /// in sync automatically. No-op when the record has no MD5 or no
    /// siblings.
    @MainActor
    func propagateDossierToMD5Duplicates(of record: VideoRecord) {
        guard !record.partialMD5.isEmpty else { return }
        let siblings = records.filter {
            $0.partialMD5 == record.partialMD5 && $0.id != record.id
        }
        guard !siblings.isEmpty else { return }

        let group = [record] + siblings
        propagateBestDossier(in: group)
    }

    /// One-shot backfill: scan the entire catalog, group by partialMD5,
    /// and propagate the best dossier within each multi-member group.
    /// Designed to run once on catalog load to harmonize legacy records
    /// whose dossiers diverged before per-writeback propagation existed.
    /// Returns the number of records that received a dossier update.
    @MainActor
    @discardableResult
    func backfillDossierAcrossDuplicates() -> Int {
        var byMD5: [String: [VideoRecord]] = [:]
        byMD5.reserveCapacity(records.count)
        for rec in records where !rec.partialMD5.isEmpty {
            byMD5[rec.partialMD5, default: []].append(rec)
        }

        var totalUpdated = 0
        for (_, members) in byMD5 where members.count >= 2 {
            totalUpdated += propagateBestDossier(in: members)
        }

        if totalUpdated > 0 {
            objectWillChange.send()
            saveCatalogDebounced()
            log("Dossier backfill: propagated best transcript/captions/OCR to \(totalUpdated) record(s) across duplicate-MD5 groups.")
        }
        return totalUpdated
    }

    // MARK: - Per-group propagation

    /// Pick the best dossier fields from a group of MD5-identical
    /// records and write them to every group member that's currently
    /// behind. Returns the number of records mutated.
    @MainActor
    @discardableResult
    func propagateBestDossier(in group: [VideoRecord]) -> Int {
        guard group.count >= 2 else { return 0 }

        let bestTranscript = Self.bestAudioTranscript(in: group)
        let bestCaptions   = Self.bestSceneCaptions(in: group)
        let bestOCRText    = Self.bestOCRText(in: group)
        let bestOCRDates   = Self.bestOCRDateCandidates(in: group)

        var mutated = 0
        for rec in group {
            var changed = false
            if let best = bestTranscript,
               (rec.audioTranscript ?? "") != best.text {
                rec.audioTranscript = best.text
                rec.audioTranscriptModel = best.model
                rec.audioTranscriptDate = best.date
                changed = true
            }
            if let best = bestCaptions,
               rec.sceneCaptions != best.captions {
                rec.sceneCaptions = best.captions
                rec.sceneCaptionModel = best.model
                rec.sceneCaptionDate = best.date
                changed = true
            }
            if let best = bestOCRText,
               rec.ocrText != best.entries {
                rec.ocrText = best.entries
                changed = true
            }
            if let best = bestOCRDates,
               rec.ocrDateCandidates != best.entries {
                rec.ocrDateCandidates = best.entries
                changed = true
            }
            if changed { mutated += 1 }
        }
        return mutated
    }

    // MARK: - Pure "best wins" selectors (testable)

    struct BestTranscript: Equatable {
        let text: String
        let model: String?
        let date: Date?
    }

    struct BestCaptions: Equatable {
        let captions: [SceneCaption]
        let model: String?
        let date: Date?
    }

    struct BestOCREntries: Equatable {
        let entries: [SceneCaption]
    }

    /// Best transcript = the longest non-empty audioTranscript in the
    /// group. Carries forward the originating record's model + date so
    /// the propagated copy is honestly attributed to the run that made
    /// it. Returns nil when no member has a non-empty transcript
    /// (nothing worth propagating).
    nonisolated static func bestAudioTranscript(in group: [VideoRecord]) -> BestTranscript? {
        var best: BestTranscript?
        for rec in group {
            guard let tx = rec.audioTranscript, !tx.isEmpty else { continue }
            if best == nil || tx.count > (best?.text.count ?? 0) {
                best = BestTranscript(
                    text: tx,
                    model: rec.audioTranscriptModel,
                    date: rec.audioTranscriptDate
                )
            }
        }
        return best
    }

    /// Best scene captions = largest count of captions, tiebreak on
    /// total text length. More scenes captured + more text per scene =
    /// more search signal. Nil when nobody has captions.
    nonisolated static func bestSceneCaptions(in group: [VideoRecord]) -> BestCaptions? {
        var best: BestCaptions?
        var bestScore = -1
        for rec in group {
            guard !rec.sceneCaptions.isEmpty else { continue }
            let textLen = rec.sceneCaptions.reduce(0) { $0 + $1.text.count }
            // Score: count × 1000 + total text length. Caps total text
            // contribution so a 50-caption record beats a 1-caption
            // 50KB record. Real-world counts are < 100 so the 1000x
            // weight is safe.
            let score = rec.sceneCaptions.count * 1000 + textLen
            if score > bestScore {
                bestScore = score
                best = BestCaptions(
                    captions: rec.sceneCaptions,
                    model: rec.sceneCaptionModel,
                    date: rec.sceneCaptionDate
                )
            }
        }
        return best
    }

    /// Best OCR text = largest count, tiebreak on total text length.
    /// Same shape as scene captions. Nil when nobody has OCR text.
    nonisolated static func bestOCRText(in group: [VideoRecord]) -> BestOCREntries? {
        var best: BestOCREntries?
        var bestScore = -1
        for rec in group {
            guard !rec.ocrText.isEmpty else { continue }
            let textLen = rec.ocrText.reduce(0) { $0 + $1.text.count }
            let score = rec.ocrText.count * 1000 + textLen
            if score > bestScore {
                bestScore = score
                best = BestOCREntries(entries: rec.ocrText)
            }
        }
        return best
    }

    /// Best OCR date candidates = largest count, tiebreak on total
    /// text length. Same shape as OCR text. Nil when nobody has
    /// OCR date candidates.
    nonisolated static func bestOCRDateCandidates(in group: [VideoRecord]) -> BestOCREntries? {
        var best: BestOCREntries?
        var bestScore = -1
        for rec in group {
            guard !rec.ocrDateCandidates.isEmpty else { continue }
            let textLen = rec.ocrDateCandidates.reduce(0) { $0 + $1.text.count }
            let score = rec.ocrDateCandidates.count * 1000 + textLen
            if score > bestScore {
                bestScore = score
                best = BestOCREntries(entries: rec.ocrDateCandidates)
            }
        }
        return best
    }
}
