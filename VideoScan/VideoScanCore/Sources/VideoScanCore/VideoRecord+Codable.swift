// VideoRecord+Codable.swift
// VideoRecord's CodingKeys enum — extracted from the VideoRecord class
// body in Models.swift (refactor 2026-06-26, model decomposition step 1).
//
// VideoRecord is `Decodable` ONLY (refactor 2026-06-29, step 5b): all
// ENCODE logic lives in `VideoRecordDTO`, a Sendable value mirror, so the
// non-Sendable class never crosses an actor boundary on the save path and
// never needs an `@unchecked Sendable` box. The class's `init(from:)`
// (decoder) stays in VideoRecord.swift — Swift requires a non-final
// class's `required init(from:)` to be declared in the PRIMARY class
// declaration. Only CodingKeys lives here. Because the decoder in
// VideoRecord.swift references CodingKeys across files, `CodingKeys` was
// widened from the original `private` to internal (no access keyword). It
// remains nested in VideoRecord, so it is not visible outside the type's
// own files, and VideoRecordDTO.encode(to:) reuses it (same module).
//
// MAINTENANCE: adding a persisted stored property to VideoRecord means
// updating FIVE places: CodingKeys (here), init(from:) (in
// VideoRecord.swift), snapshotClone() (in VideoRecord+Clone.swift), and
// VideoRecordDTO's stored property + init(_:) + encode(to:) (in
// VideoRecordDTO.swift — the DTO owns the single copy of the encode
// logic). The byte-identity golden in CatalogStoreAsyncSaveTests fails
// loudly if the DTO drifts from the on-disk schema.

import Foundation

// MARK: - CodingKeys

extension VideoRecord {

    // Access widened private → internal: the decoder in VideoRecord.swift
    // (forced to stay in the class body by Swift) and VideoRecordDTO's
    // encoder both reference these keys.
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
        case dupAnalyzedAt
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
        case setAsideReason
        case drmProtected
        case needsReformat
        case derivedFrom
        case cleanupRecipeID
        case cleanupRecipeVersion
        case derivationKind
        case trimInSeconds
        case trimOutSeconds
        case userDate
        case userDateConfidence
        case workspaceActive
        case userNotes
        case tags
    }
}
