import Foundation
import Combine

extension VideoScanModel {

    // MARK: - Dossier Writeback
    //
    // Multi-signal dossier sibling to applyCaptions / applyAudioTranscript.
    // Where those two write a single signal each, applyDossier flushes
    // the full dossier pass: scene captions + OCR dates + OCR text +
    // (optionally) audio transcript + triangulated record date + dossier
    // provenance — all on one record, atomically, with a single
    // saveCatalogDebounced flush.
    //
    // Re-dossiering REPLACES wholesale. We don't merge dossiers from
    // different model stacks because the consensus inference would mix
    // model biases. The dossierProcessedBy field is pure provenance:
    // it records which stack produced the current dossier, but it is
    // NOT part of the orchestrator's idempotent-skip predicate (a
    // non-nil dossierProcessedAt is enough). The UI can offer "re-
    // dossier with current stack" via force=true if the engine
    // version drifts and the user wants a fresh pass.
    //
    // GH #201 (2026-09-26): the date is TRIANGULATED — every criterion
    // (burn-ins, spoken now-cues, ages + People-tab birth years, the
    // folder year, a camera stamp) is combined, constrained by the export
    // stamp / media-era floor / catalog priors, and the record gets the
    // point date, its year span and the WRITTEN reason. A filesystem or
    // container time is never an inferred date any more: no evidence ⇒
    // nil, reason "no evidence".

    /// Apply a fresh dossier extraction (and optional Whisper transcript)
    /// to a single catalog record by path. Triangulates the record's
    /// inferred date via `pfTriangulateRecordDate` (DateTriangulator.swift).
    /// Stamps `dossierProcessedAt` + `dossierProcessedBy` for idempotent-skip
    /// on the next pass.
    ///
    /// - Parameters:
    ///   - extraction: Output of `CaptionRunner.dossier(...)`. Scenes
    ///     replace `sceneCaptions`; dates fill `ocrDateCandidates`;
    ///     texts fill `ocrText`.
    ///   - path: `fullPath` of the target record. Silent skip if no
    ///     record matches (same rule applyCaptions uses).
    ///   - vlmModel: The VLM `modelID` (e.g. "qwen2.5-vl-3b-4bit"),
    ///     stamped into `sceneCaptionModel`.
    ///   - transcript: Audio transcript text, or nil if Whisper didn't
    ///     run on this record. Empty string ≠ nil — empty means
    ///     "Whisper ran, found no speech".
    ///   - whisperModel: The transcriber `modelID`, stamped into
    ///     `audioTranscriptModel`. Required iff `transcript` is non-nil.
    /// - Returns: true if a record matched and was updated; false if
    ///   the path is not in the catalog.
    @MainActor
    @discardableResult
    func applyDossier(
        _ extraction: DossierExtraction,
        to path: String,
        vlmModel: String,
        transcript: String?,
        whisperModel: String?
    ) -> Bool {
        guard !path.isEmpty, !vlmModel.isEmpty else { return false }
        // O(1) via the path index (ride-along 2026-07-14) — this runs
        // once PER FILE inside every dossier batch, and the old linear
        // scan was ~103k iterations per call on Rick's catalog.
        guard let record = record(forPath: path) else {
            return false
        }

        let now = Date()

        // Scene channel
        record.sceneCaptions      = extraction.scenes
        record.sceneCaptionModel  = vlmModel
        record.sceneCaptionDate   = now

        // OCR channels
        record.ocrDateCandidates  = extraction.dates
        record.ocrText            = extraction.texts

        // Whisper channel (optional)
        if let transcript {
            record.audioTranscript      = transcript
            record.audioTranscriptModel = whisperModel
            record.audioTranscriptDate  = now
        }

        // Date triangulation (GH #201) — pure helper over the signals we
        // just wrote plus the record's own format / stamp / folder facts.
        // This IS the record's own pass — whatever it inherited before (a
        // propagated / folder-year / footage-shared placeholder) is
        // superseded, so the source is nil.
        var input = Self.triangulationInput(for: record, people: dateInferencePeopleResolved,
                                            includePathHints: true, now: now)
        input.pathHintStandsAlone = true   // a full pass ran: the folder year may stand alone
        let inferred = pfTriangulateRecordDate(input)
        // Rick 2026-09-27: a Master Archive file keeps its filed date — the
        // channels above are metadata notes and land; the date does not
        // move (its own archive folder would otherwise feed the folder-year
        // hint straight back into it). The narrative line below still says
        // what the pass concluded, so nothing is lost.
        let archivedFile = isArchiveElement(record)
        if !archivedFile {
            Self.applyTriangulation(inferred, to: record, source: nil)
        }

        // Provenance — stack id matches the Python POC shape:
        //   "qwen2.5-vl-3b-4bit+whisper-medium-mlx-q4"
        // when both engines ran; VLM-only otherwise.
        let stackID: String
        if let whisperModel, transcript != nil {
            stackID = "\(vlmModel)+\(whisperModel)"
        } else {
            stackID = vlmModel
        }
        record.dossierProcessedAt = now
        record.dossierProcessedBy = stackID

        objectWillChange.send()
        // In-place write — the records array didn't change, so its didSet
        // can't see this. Keep the cached chrome counts honest.
        noteCatalogChangedForDossierCounts()
        saveCatalogDebounced()

        // Same bytes, same date (Rick 2026-09-12): every other active copy
        // of this content that has no date of its own gets this one, with
        // provenance; and (GH #201) the footage group settles on its
        // strongest claim. Never overwrites a user date — see
        // VideoScanModel+DateInference.
        propagateInferredDate(from: record)

        // Narrative log — one line per file. Same shape as applyCaptions
        // and applyAudioTranscript.
        let filename = (path as NSString).lastPathComponent
        let dateStr  = inferred.date.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"
        let confStr  = String(format: "%.2f", inferred.confidence)
        let txtSummary = transcript.map { $0.isEmpty ? "no speech" : "\($0.count) char(s)" } ?? "no whisper"
        appLog.write("Catalog: dossier \(filename) — \(extraction.scenes.count) scene(s), \(extraction.dates.count) date(s), \(extraction.texts.count) text(s); transcript \(txtSummary); inferred \(dateStr) (conf \(confStr)) [\(stackID)]")
        if archivedFile {
            // A separate line (the one above keeps its format).
            appLog.write("Catalog: dossier \(filename) — archived file: date left as filed (\(record.resolvedDateDisplay))")
        }
        return true
    }
}

// MARK: - Path year hints
//
// Pure helper, file-private so it doesn't pollute the VideoScanModel
// surface. Scans the directory components of a full path for 4-digit
// years in [1900, 2100]. Used by `applyDossier` to feed
// `pfInferRecordDate`'s third-priority signal (after OCR consensus
// and audio mentions, before file mtime).

/// Extract candidate years from the directory portion of a path.
/// Examples:
///   - "/Vols/MyBook/Christmas2010/clip.mp4" → [2010]
///   - "/Vols/MyBook/Summer 2010/Holiday1991/clip.mp4" → [1991, 2010]
///   - "/Vols/MyBook/DSC_2010.MP4" → [] (filename excluded)
///
/// Returned in path-walk order (deepest directory first) so a more
/// specific subdir like "Holiday1991" wins over an ancestor's
/// "Archive2024". `pfInferRecordDate` takes only the first.
nonisolated func pfPathYearHints(in fullPath: String) -> [Int] {
    let nsPath = fullPath as NSString
    let directory = nsPath.deletingLastPathComponent
    let parts = (directory as NSString).pathComponents
    // Compiled once (GH #201: the catch-up pass now reads folder hints for
    // every evidence-bearing row; the old per-call compile was the cost).
    guard let regex = DateTriangulationRegex.directoryYear else { return [] }
    var hints: [Int] = []
    // Walk components from deepest to shallowest so the closest
    // directory's year wins.
    for component in parts.reversed() {
        // Cheap gate: no "19"/"20" digits, no year.
        guard component.contains("19") || component.contains("20") else { continue }
        let range = NSRange(component.startIndex..., in: component)
        let matches = regex.matches(in: component, range: range)
        for match in matches {
            if let r = Range(match.range(at: 1), in: component),
               let y = Int(component[r]),
               y >= 1900, y <= 2100 {
                hints.append(y)
            }
        }
    }
    return hints
}
