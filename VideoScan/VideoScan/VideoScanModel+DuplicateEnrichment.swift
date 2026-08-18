import Foundation

// MARK: - Enrichment carry-over on verified duplicate delete (2026-08-18)
//
// Codex review A. `DuplicateKeeperPolicy.humanMetadataScore` counts a
// transcript, scene captions, a dossier pass and a Migrate provenance
// stamp as reasons to KEEP a copy — but volume precedence outranks that
// score, so a lower-tier copy holding an expensive transcript can still
// lose to a bare master. The human merge (applyHumanMetadataInheritance —
// the repair-adoption rules, deliberately unchanged) carries none of
// those machine products. This second, separate merge carries the
// ENRICHMENT the master lacks, only ever filling holes: nothing on the
// master is overwritten.
//
// Also appends one File Journey line to the master's machine `notes` so
// the removed copy's path (and, when Migrate stamped it, where THAT came
// from) is never lost: "copy at <path> (from <originalFullPath>) removed
// <date>; identical bytes".

extension VideoScanModel {

    /// Fill the master's empty enrichment fields from the removed extra.
    /// Returns the names of the fields carried (empty ⇒ nothing to do).
    /// Never overwrites a non-empty value on the master; never touches the
    /// probe fields (codec, size, duration…), which are identical for a
    /// byte-identical twin anyway.
    @MainActor
    @discardableResult
    func applyEnrichmentInheritance(from extra: VideoRecord, to master: VideoRecord,
                                    removedAt: Date = Date()) -> [String] {
        var carried: [String] = []

        // Audio transcript (+ its provenance pair) — as a unit.
        if (master.audioTranscript ?? "").isEmpty, let t = extra.audioTranscript, !t.isEmpty {
            master.audioTranscript = t
            master.audioTranscriptModel = extra.audioTranscriptModel
            master.audioTranscriptDate = extra.audioTranscriptDate
            carried.append("transcript")
        }
        // Scene captions (+ model/date) — as a unit.
        if master.sceneCaptions.isEmpty, !extra.sceneCaptions.isEmpty {
            master.sceneCaptions = extra.sceneCaptions
            master.sceneCaptionModel = extra.sceneCaptionModel
            master.sceneCaptionDate = extra.sceneCaptionDate
            carried.append("captions")
        }
        // Dossier stamp.
        if master.dossierProcessedAt == nil, extra.dossierProcessedAt != nil {
            master.dossierProcessedAt = extra.dossierProcessedAt
            master.dossierProcessedBy = extra.dossierProcessedBy
            carried.append("dossier")
        }
        // Detected people — only when the master has none at all.
        if master.detectedPeople.isEmpty, !extra.detectedPeople.isEmpty {
            master.detectedPeople = extra.detectedPeople
            carried.append("detected people")
        }
        // Inferred date (+ confidence).
        if master.inferredRecordDate == nil, extra.inferredRecordDate != nil {
            master.inferredRecordDate = extra.inferredRecordDate
            master.inferredDateConfidence = extra.inferredDateConfidence
            carried.append("inferred date")
        }
        // Avid bin identity — field by field, empty-only.
        var avid = false
        if master.avidClipName.isEmpty, !extra.avidClipName.isEmpty { master.avidClipName = extra.avidClipName; avid = true }
        if master.avidMobID.isEmpty, !extra.avidMobID.isEmpty { master.avidMobID = extra.avidMobID; avid = true }
        if master.avidMaterialUUID.isEmpty, !extra.avidMaterialUUID.isEmpty { master.avidMaterialUUID = extra.avidMaterialUUID; avid = true }
        if master.avidBinFile.isEmpty, !extra.avidBinFile.isEmpty { master.avidBinFile = extra.avidBinFile; avid = true }
        if master.avidMobType.isEmpty, !extra.avidMobType.isEmpty { master.avidMobType = extra.avidMobType; avid = true }
        if master.avidMediaPath.isEmpty, !extra.avidMediaPath.isEmpty { master.avidMediaPath = extra.avidMediaPath; avid = true }
        if master.avidTapeName.isEmpty, !extra.avidTapeName.isEmpty { master.avidTapeName = extra.avidTapeName; avid = true }
        if master.avidEditRate == 0, extra.avidEditRate != 0 { master.avidEditRate = extra.avidEditRate; avid = true }
        if master.avidTracks.isEmpty, !extra.avidTracks.isEmpty { master.avidTracks = extra.avidTracks; avid = true }
        if avid { carried.append("Avid identity") }

        // Provenance — File Journey line on the master (machine notes,
        // never userNotes).
        let line = Self.removedCopyJourneyLine(extraPath: extra.fullPath,
                                               originalFullPath: extra.originalFullPath,
                                               removedAt: removedAt)
        master.notes = master.notes.isEmpty ? line : "\(master.notes)\n\(line)"
        carried.append("provenance note")

        return carried
    }

    /// "copy at <path> (from <originalFullPath>) removed 2026-08-18; identical bytes"
    static func removedCopyJourneyLine(extraPath: String, originalFullPath: String?,
                                       removedAt: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        let from = (originalFullPath?.isEmpty == false) ? " (from \(originalFullPath!))" : ""  // swiftlint:disable:this force_unwrapping
        return "copy at \(extraPath)\(from) removed \(fmt.string(from: removedAt)); identical bytes"
    }
}
