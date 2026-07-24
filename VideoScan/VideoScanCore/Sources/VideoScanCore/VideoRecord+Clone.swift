// VideoRecord+Clone.swift
// VideoRecord's field-by-field deep-copy snapshot — extracted verbatim
// from the VideoRecord class body in Models.swift (refactor 2026-06-26,
// model decomposition step 1).

import Foundation

// MARK: - Snapshot clone (CatalogStore off-main save path)

extension VideoRecord {

    /// Field-by-field deep copy. Used by `CatalogStore` to snapshot the live
    /// record graph ON the main actor before encoding it OFF the main actor —
    /// encoding the live objects on a background thread would race with
    /// main-actor mutations (VideoRecord is a mutable class).
    ///
    /// `// In C++ terms: a copy constructor for a class that otherwise has
    /// reference semantics.` Swift String/Array/struct properties have value
    /// semantics with copy-on-write: assigning them here bumps a refcount;
    /// a later mutation on the live record copies ITS storage, so the clone's
    /// view is immutable from that point on. That's what makes the clone safe
    /// to read from another thread.
    ///
    /// `pairedWith` is deliberately NOT copied (object reference into the
    /// live graph — and possibly a cycle). `CatalogStore.deepCopySnapshot`
    /// rewires it across the cloned array, mirroring what `decode` does with
    /// `pendingPairedWithID`.
    ///
    /// MAINTENANCE: adding a stored property to VideoRecord means updating
    /// FOUR places: CodingKeys, init(from:), encode(to:), and this clone.
    /// CatalogStoreAsyncSaveTests.cloneEncodesIdenticallyToOriginal pins the
    /// parity for every field its fixture populates.
    ///
    /// `sending` result (2026-07-07): the clone is a freshly-allocated
    /// object holding only value-type copies (the compiler verifies this —
    /// copying any reference-typed field here would be a build error), so
    /// callers receive it in a DISCONNECTED region and may legally ship it
    /// across an actor boundary. That turns the "exclusively-owned clone"
    /// contract from a comment into something region analysis can prove.
    /// Purely additive for existing callers: merging the result back into
    /// the caller's own region (deepCopySnapshot's pairedWith rewiring)
    /// remains fine.
    public func snapshotClone() -> sending VideoRecord {
        let c = VideoRecord(id: id)
        c.filename = filename
        c.ext = ext
        c.streamTypeRaw = streamTypeRaw
        c.size = size
        c.sizeBytes = sizeBytes
        c.duration = duration
        c.durationSeconds = durationSeconds
        c.dateCreated = dateCreated
        c.dateModified = dateModified
        c.dateCreatedRaw = dateCreatedRaw
        c.dateModifiedRaw = dateModifiedRaw
        c.container = container
        c.videoCodec = videoCodec
        c.resolution = resolution
        c.frameRate = frameRate
        c.videoBitrate = videoBitrate
        c.totalBitrate = totalBitrate
        c.colorSpace = colorSpace
        c.bitDepth = bitDepth
        c.scanType = scanType
        c.audioCodec = audioCodec
        c.audioChannels = audioChannels
        c.audioSampleRate = audioSampleRate
        c.timecode = timecode
        c.tapeName = tapeName
        c.isPlayable = isPlayable
        c.partialMD5 = partialMD5
        c.fullPath = fullPath
        c.directory = directory
        c.notes = notes
        c.userNotes = userNotes
        c.tags = tags
        c.originalFullPath = originalFullPath
        c.originVolume = originVolume
        c.wasCacheHit = wasCacheHit
        c.avidClipName = avidClipName
        c.avidMobID = avidMobID
        c.avidMaterialUUID = avidMaterialUUID
        c.avidBinFile = avidBinFile
        c.avidMobType = avidMobType
        c.avidMediaPath = avidMediaPath
        c.avidTapeName = avidTapeName
        c.avidEditRate = avidEditRate
        c.avidTracks = avidTracks
        c.materialPackageUMID = materialPackageUMID
        // pairedWith: rewired by CatalogStore.deepCopySnapshot — see doc above.
        c.pendingPairedWithID = pendingPairedWithID
        c.pairGroupID = pairGroupID
        c.pairConfidence = pairConfidence
        c.duplicateGroupID = duplicateGroupID
        c.duplicateConfidence = duplicateConfidence
        c.duplicateDisposition = duplicateDisposition
        c.duplicateReasons = duplicateReasons
        c.duplicateBestMatchFilename = duplicateBestMatchFilename
        c.duplicateGroupCount = duplicateGroupCount
        c.dupAnalyzedAt = dupAnalyzedAt
        c.lifecycleStage = lifecycleStage
        c.mediaDisposition = mediaDisposition
        c.archiveStage = archiveStage
        c.masterLocation = masterLocation
        c.backupDestinations = backupDestinations
        c.junkScore = junkScore
        c.junkReasons = junkReasons
        c.starRating = starRating
        c.detectedPeople = detectedPeople
        c.suspectedPeople = suspectedPeople
        c.confirmedByUserPeople = confirmedByUserPeople
        c.rejectedPeople = rejectedPeople
        c.sceneCaptions = sceneCaptions
        c.ocrDateCandidates = ocrDateCandidates
        c.ocrText = ocrText
        c.inferredRecordDate = inferredRecordDate
        c.inferredDateConfidence = inferredDateConfidence
        c.dossierProcessedAt = dossierProcessedAt
        c.dossierProcessedBy = dossierProcessedBy
        c.sceneCaptionModel = sceneCaptionModel
        c.sceneCaptionDate = sceneCaptionDate
        c.audioTranscript = audioTranscript
        c.audioTranscriptModel = audioTranscriptModel
        c.audioTranscriptDate = audioTranscriptDate
        c.combinedFromPairID = combinedFromPairID
        c.sourceHost = sourceHost
        c.purgedAt = purgedAt
        c.setAsideReason = setAsideReason
        c.drmProtected = drmProtected
        c.needsReformat = needsReformat
        c.derivedFrom = derivedFrom
        c.cleanupRecipeID = cleanupRecipeID
        c.cleanupRecipeVersion = cleanupRecipeVersion
        c.derivationKind = derivationKind
        c.trimInSeconds = trimInSeconds
        c.trimOutSeconds = trimOutSeconds
        c.userDate = userDate
        c.userDateConfidence = userDateConfidence
        c.workspaceActive = workspaceActive
        c.audioVerifyStatus = audioVerifyStatus
        c.audioVerifyNote = audioVerifyNote
        c.audioVerifyDate = audioVerifyDate
        c.scanContext = scanContext
        return c
    }
}
