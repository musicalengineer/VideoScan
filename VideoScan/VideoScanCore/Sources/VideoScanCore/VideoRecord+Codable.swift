// VideoRecord+Codable.swift
// VideoRecord's CodingKeys enum and its encoder — extracted from the
// VideoRecord class body in Models.swift (refactor 2026-06-26, model
// decomposition step 1).
//
// NOTE on the split: Swift requires a non-final class's `required
// init(from:)` to be declared in the PRIMARY class declaration, so the
// DECODER (init(from:)) stays in VideoRecord.swift. Only CodingKeys and
// encode(to:) live here. Because the decoder in VideoRecord.swift must
// reference CodingKeys across files, `CodingKeys` was widened from the
// original `private` to internal (no access keyword). It remains nested
// in VideoRecord, so it is not visible outside the type's own files.
//
// MAINTENANCE: adding a persisted stored property to VideoRecord means
// updating FIVE places: CodingKeys (here), init(from:) (in
// VideoRecord.swift), snapshotClone() (in VideoRecord+Clone.swift), and
// VideoRecordDTO's stored property + init(_:) + encode(to:) (in
// VideoRecordDTO.swift — encode(to:) below just delegates to the DTO, which
// owns the single copy of the encode logic). The byte-identity test in
// CatalogStoreAsyncSaveTests fails loudly if the DTO drifts from the class.

import Foundation

// MARK: - Codable

extension VideoRecord {

    // Access widened private → internal: the decoder in VideoRecord.swift
    // (forced to stay in the class body by Swift) references these keys.
    enum CodingKeys: String, CodingKey {
        case id, filename, ext, streamTypeRaw, size, sizeBytes, duration, durationSeconds
        case dateCreated, dateModified, dateCreatedRaw, dateModifiedRaw
        case container, videoCodec, resolution, frameRate, videoBitrate, totalBitrate
        case colorSpace, bitDepth, scanType, audioCodec, audioChannels, audioSampleRate
        case timecode, tapeName, isPlayable, partialMD5, fullPath, directory, notes
        case originalFullPath, originVolume
        case avidClipName, avidMobID, avidMaterialUUID, avidBinFile, avidMobType
        case avidMediaPath, avidTapeName, avidEditRate, avidTracks
        case materialPackageUMID
        case pairedWithID, pairGroupID, pairConfidence
        case duplicateGroupID, duplicateConfidence, duplicateDisposition
        case duplicateReasons, duplicateBestMatchFilename, duplicateGroupCount
        case lifecycleStage, mediaDisposition, archiveStage, masterLocation, backupDestinations
        case junkScore, junkReasons
        case starRating, detectedPeople, suspectedPeople, combinedFromPairID
        case confirmedByUserPeople, rejectedPeople
        case sceneCaptions, sceneCaptionModel, sceneCaptionDate
        case ocrDateCandidates, ocrText
        case inferredRecordDate, inferredDateConfidence
        case dossierProcessedAt, dossierProcessedBy
        case audioTranscript, audioTranscriptModel, audioTranscriptDate
        case sourceHost
        case scanContext
        case purgedAt
        case drmProtected
        case needsReformat
        case derivedFrom
        case workspaceActive
    }

    // Encoding is delegated to `VideoRecordDTO`, a Sendable value mirror
    // that owns the SINGLE copy of the on-disk encode logic (moved there
    // verbatim, 2026-06-29 seam E). Delegating guarantees the live class
    // and the DTO can never diverge byte-for-byte — there is exactly one
    // encoder. The DTO is also what the off-main catalog save ships across
    // the actor boundary, so the non-Sendable VideoRecord never leaves the
    // main actor during a save. See VideoRecordDTO.swift for the full
    // byte-identity contract.
    public func encode(to encoder: Encoder) throws {
        try VideoRecordDTO(self).encode(to: encoder)
    }
}
