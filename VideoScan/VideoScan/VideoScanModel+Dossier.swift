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
    // model biases. The dossierProcessedBy field records which stack
    // produced the current dossier so the UI can offer "re-dossier with
    // current stack" if the engine version drifts.

    /// Apply a fresh dossier extraction (and optional Whisper transcript)
    /// to a single catalog record by path. Triangulates the record's
    /// inferred date from OCR + path-year + file mtime via
    /// `pfInferRecordDate`. Stamps `dossierProcessedAt` + `dossierProcessedBy`
    /// for idempotent-skip on the next pass.
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
        guard let record = records.first(where: { $0.fullPath == path }) else {
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

        // Date triangulation — pure helper, depends only on the signals
        // we just wrote plus the file's existing time hints.
        let ocrStrings = extraction.dates.map(\.text)
        let yearHints  = pfPathYearHints(in: path)
        let inferred = pfInferRecordDate(
            ocrDateCandidates:      ocrStrings,
            audioTranscript:        transcript,
            pathYearHints:          yearHints,
            fileMtime:              record.dateModifiedRaw,
            containerCreationTime:  record.dateCreatedRaw
        )
        record.inferredRecordDate     = inferred.date
        record.inferredDateConfidence = inferred.confidence

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
        saveCatalogDebounced()

        // Narrative log — one line per file. Same shape as applyCaptions
        // and applyAudioTranscript.
        let filename = (path as NSString).lastPathComponent
        let dateStr  = inferred.date.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"
        let confStr  = String(format: "%.2f", inferred.confidence)
        let txtSummary = transcript.map { $0.isEmpty ? "no speech" : "\($0.count) char(s)" } ?? "no whisper"
        appLog.write("Catalog: dossier \(filename) — \(extraction.scenes.count) scene(s), \(extraction.dates.count) date(s), \(extraction.texts.count) text(s); transcript \(txtSummary); inferred \(dateStr) (conf \(confStr)) [\(stackID)]")
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
    let regex = try? NSRegularExpression(pattern: #"(?<![\d])((?:19|20)\d{2})(?![\d])"#)
    var hints: [Int] = []
    // Walk components from deepest to shallowest so the closest
    // directory's year wins.
    for component in parts.reversed() {
        guard let regex else { break }
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
