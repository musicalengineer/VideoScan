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
// MAINTENANCE: adding a stored property to VideoRecord means updating
// FOUR places: CodingKeys + encode(to:) (here), init(from:) (in
// VideoRecord.swift), and snapshotClone() (in VideoRecord+Clone.swift).

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

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(filename, forKey: .filename)
        try c.encode(ext, forKey: .ext)
        try c.encode(streamTypeRaw, forKey: .streamTypeRaw)
        try c.encode(size, forKey: .size)
        try c.encode(sizeBytes, forKey: .sizeBytes)
        try c.encode(duration, forKey: .duration)
        try c.encode(durationSeconds, forKey: .durationSeconds)
        try c.encode(dateCreated, forKey: .dateCreated)
        try c.encode(dateModified, forKey: .dateModified)
        try c.encodeIfPresent(dateCreatedRaw, forKey: .dateCreatedRaw)
        try c.encodeIfPresent(dateModifiedRaw, forKey: .dateModifiedRaw)
        try c.encode(container, forKey: .container)
        try c.encode(videoCodec, forKey: .videoCodec)
        try c.encode(resolution, forKey: .resolution)
        try c.encode(frameRate, forKey: .frameRate)
        try c.encode(videoBitrate, forKey: .videoBitrate)
        try c.encode(totalBitrate, forKey: .totalBitrate)
        try c.encode(colorSpace, forKey: .colorSpace)
        try c.encode(bitDepth, forKey: .bitDepth)
        try c.encode(scanType, forKey: .scanType)
        try c.encode(audioCodec, forKey: .audioCodec)
        try c.encode(audioChannels, forKey: .audioChannels)
        try c.encode(audioSampleRate, forKey: .audioSampleRate)
        try c.encode(timecode, forKey: .timecode)
        try c.encode(tapeName, forKey: .tapeName)
        try c.encode(isPlayable, forKey: .isPlayable)
        try c.encode(partialMD5, forKey: .partialMD5)
        try c.encode(fullPath, forKey: .fullPath)
        try c.encode(directory, forKey: .directory)
        try c.encode(notes, forKey: .notes)
        try c.encode(avidClipName, forKey: .avidClipName)
        try c.encode(avidMobID, forKey: .avidMobID)
        try c.encode(avidMaterialUUID, forKey: .avidMaterialUUID)
        try c.encode(avidBinFile, forKey: .avidBinFile)
        try c.encode(avidMobType, forKey: .avidMobType)
        try c.encode(avidMediaPath, forKey: .avidMediaPath)
        try c.encode(avidTapeName, forKey: .avidTapeName)
        try c.encode(avidEditRate, forKey: .avidEditRate)
        try c.encode(avidTracks, forKey: .avidTracks)
        if !materialPackageUMID.isEmpty {
            try c.encode(materialPackageUMID, forKey: .materialPackageUMID)
        }
        try c.encodeIfPresent(pairedWith?.id, forKey: .pairedWithID)
        try c.encodeIfPresent(pairGroupID, forKey: .pairGroupID)
        try c.encodeIfPresent(pairConfidence, forKey: .pairConfidence)
        try c.encodeIfPresent(duplicateGroupID, forKey: .duplicateGroupID)
        try c.encodeIfPresent(duplicateConfidence, forKey: .duplicateConfidence)
        try c.encode(duplicateDisposition, forKey: .duplicateDisposition)
        try c.encode(duplicateReasons, forKey: .duplicateReasons)
        try c.encode(duplicateBestMatchFilename, forKey: .duplicateBestMatchFilename)
        try c.encode(duplicateGroupCount, forKey: .duplicateGroupCount)
        try c.encode(sourceHost, forKey: .sourceHost)
        try c.encode(lifecycleStage, forKey: .lifecycleStage)
        try c.encode(mediaDisposition, forKey: .mediaDisposition)
        try c.encode(archiveStage, forKey: .archiveStage)
        if !masterLocation.isEmpty {
            try c.encode(masterLocation, forKey: .masterLocation)
        }
        if !backupDestinations.isEmpty {
            try c.encode(backupDestinations, forKey: .backupDestinations)
        }
        try c.encode(junkScore, forKey: .junkScore)
        if !junkReasons.isEmpty {
            try c.encode(junkReasons, forKey: .junkReasons)
        }
        if starRating > 0 {
            try c.encode(starRating, forKey: .starRating)
        }
        if !detectedPeople.isEmpty {
            try c.encode(detectedPeople, forKey: .detectedPeople)
        }
        if !suspectedPeople.isEmpty {
            try c.encode(suspectedPeople, forKey: .suspectedPeople)
        }
        // Delta-minimal encoding: only write when non-empty so old
        // records pre-confirmedByUserPeople round-trip byte-identical.
        if !confirmedByUserPeople.isEmpty {
            try c.encode(confirmedByUserPeople, forKey: .confirmedByUserPeople)
        }
        if !rejectedPeople.isEmpty {
            try c.encode(rejectedPeople, forKey: .rejectedPeople)
        }
        if !sceneCaptions.isEmpty {
            try c.encode(sceneCaptions, forKey: .sceneCaptions)
        }
        try c.encodeIfPresent(sceneCaptionModel, forKey: .sceneCaptionModel)
        try c.encodeIfPresent(sceneCaptionDate, forKey: .sceneCaptionDate)
        // Delta-minimal: skip the dossier keys entirely when the
        // record hasn't been processed yet. Keeps catalog.json deltas
        // minimal for the 13,569 unprocessed records.
        if !ocrDateCandidates.isEmpty {
            try c.encode(ocrDateCandidates, forKey: .ocrDateCandidates)
        }
        if !ocrText.isEmpty {
            try c.encode(ocrText, forKey: .ocrText)
        }
        try c.encodeIfPresent(inferredRecordDate, forKey: .inferredRecordDate)
        try c.encodeIfPresent(inferredDateConfidence, forKey: .inferredDateConfidence)
        try c.encodeIfPresent(dossierProcessedAt, forKey: .dossierProcessedAt)
        try c.encodeIfPresent(dossierProcessedBy, forKey: .dossierProcessedBy)
        // Audio transcript: only write when something to write. Matches the
        // sceneCaption* shape — keeps catalog.json deltas minimal for the
        // (majority) of records that haven't been transcribed.
        try c.encodeIfPresent(audioTranscript, forKey: .audioTranscript)
        try c.encodeIfPresent(audioTranscriptModel, forKey: .audioTranscriptModel)
        try c.encodeIfPresent(audioTranscriptDate, forKey: .audioTranscriptDate)
        if combinedFromPairID != nil {
            try c.encode(combinedFromPairID, forKey: .combinedFromPairID)
        }
        if scanContext.isPopulated || scanContext.scannedAt != nil {
            try c.encode(scanContext, forKey: .scanContext)
        }
        // Only write purgedAt when present — keeps catalog.json deltas minimal
        // for the (vast majority) of records that are never purged, and means
        // un-purging a record makes its JSON byte-identical to before purge.
        try c.encodeIfPresent(purgedAt, forKey: .purgedAt)
        // Only write drmProtected when true — same rationale as purgedAt: most
        // records are unprotected and writing `false` everywhere would inflate
        // catalog.json without changing any decoder behavior.
        if needsReformat {
            try c.encode(needsReformat, forKey: .needsReformat)
        }
        try c.encodeIfPresent(derivedFrom, forKey: .derivedFrom)
        // Only write workspaceActive when true — keeps catalog.json deltas
        // minimal for the majority of records that are never imported into
        // the workspace. Legacy decode treats absence as false (same shape
        // as needsReformat / drmProtected).
        if workspaceActive {
            try c.encode(workspaceActive, forKey: .workspaceActive)
        }
        if drmProtected {
            try c.encode(drmProtected, forKey: .drmProtected)
        }
        // Relocate provenance: only written for records that have been
        // migrated. For un-relocated records (the vast majority pre-rollout)
        // these add zero bytes to catalog.json.
        try c.encodeIfPresent(originalFullPath, forKey: .originalFullPath)
        try c.encodeIfPresent(originVolume, forKey: .originVolume)
    }
}
