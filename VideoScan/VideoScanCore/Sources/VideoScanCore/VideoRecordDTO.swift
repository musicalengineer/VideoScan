// VideoRecordDTO.swift
// A `Sendable`, value-type mirror of VideoRecord's PERSISTED state.
//
// Why this exists (refactor 2026-06-29, seam E — VideoRecord Sendable):
// catalog.json is ~73 MB, so the encode+write runs OFF the main actor
// (the 2026-06-10 beachball fix). VideoRecord is a mutable, non-Sendable
// class, so shipping it off the main actor previously required an
// `@unchecked Sendable` box — an unsafe escape hatch. This struct replaces
// that box: it is a true `Sendable` value type, so the off-main encode path
// crosses the actor boundary with NO unsafe hatch and NO live VideoRecord.
//
// BYTE-IDENTITY CONTRACT (load-bearing — irreplaceable catalog data):
// This struct is the SINGLE source of truth for VideoRecord's on-disk JSON.
// `VideoRecord.encode(to:)` delegates to `VideoRecordDTO(self).encode(to:)`,
// so the live class and the DTO can NEVER diverge byte-for-byte — there is
// only one encoder. The `encode(to:)` body below was moved VERBATIM from
// `VideoRecord.encode(to:)` and reuses `VideoRecord.CodingKeys` unchanged,
// so the keys, their order, the optional/nil omission rules, the date
// formatting, and the pairedWith→pairedWithID flattening are identical.
//
// DECODE NOTE: there is no DTO decoder. Decode runs on the main actor
// (`CatalogStore.decode(url:)` is @MainActor; JSONDecoder runs synchronously
// on the calling actor), so the non-Sendable VideoRecord never crosses an
// actor boundary on load. Only the ENCODE path needed a Sendable mirror.
//
// MAINTENANCE: adding a persisted stored property to VideoRecord now means
// updating FIVE places: CodingKeys + VideoRecord.init(from:) (decode),
// VideoRecordDTO's stored property + init(_:) + encode(to:) (here), and
// snapshotClone() (VideoRecord+Clone.swift). The byte-identity test in
// CatalogStoreAsyncSaveTests will fail loudly if the DTO drifts from the
// class. (`// like serializing a C++ class through a POD snapshot struct`)

import Foundation

public struct VideoRecordDTO: Sendable, Encodable {

    // MARK: Persisted fields (value-typed mirror of VideoRecord)

    public let id: UUID
    public let filename: String
    public let ext: String
    public let streamTypeRaw: String
    public let size: String
    public let sizeBytes: Int64
    public let duration: String
    public let durationSeconds: Double
    public let dateCreated: String
    public let dateModified: String
    public let dateCreatedRaw: Date?
    public let dateModifiedRaw: Date?
    public let container: String
    public let videoCodec: String
    public let resolution: String
    public let frameRate: String
    public let videoBitrate: String
    public let totalBitrate: String
    public let colorSpace: String
    public let bitDepth: String
    public let scanType: String
    public let audioCodec: String
    public let audioChannels: String
    public let audioSampleRate: String
    public let timecode: String
    public let tapeName: String
    public let isPlayable: String
    public let partialMD5: String
    public let fullPath: String
    public let directory: String
    public let notes: String
    public let avidClipName: String
    public let avidMobID: String
    public let avidMaterialUUID: String
    public let avidBinFile: String
    public let avidMobType: String
    public let avidMediaPath: String
    public let avidTapeName: String
    public let avidEditRate: Double
    public let avidTracks: String
    public let materialPackageUMID: String
    /// Flattened from `VideoRecord.pairedWith?.id` — encode only ever read
    /// the partner's id, never the partner object.
    public let pairedWithID: UUID?
    public let pairGroupID: UUID?
    public let pairConfidence: PairConfidence?
    public let duplicateGroupID: UUID?
    public let duplicateConfidence: DuplicateConfidence?
    public let duplicateDisposition: DuplicateDisposition
    public let duplicateReasons: String
    public let duplicateBestMatchFilename: String
    public let duplicateGroupCount: Int
    public let dupAnalyzedAt: Date?
    public let sourceHost: String
    public let lifecycleStage: LifecycleStage
    public let mediaDisposition: MediaDisposition
    public let archiveStage: ArchiveStage
    public let masterLocation: String
    public let backupDestinations: [BackupEntry]
    public let junkScore: Int
    public let junkReasons: [String]
    public let starRating: Int
    public let detectedPeople: [String]
    public let suspectedPeople: [String]
    public let confirmedByUserPeople: [ConfirmedTag]
    public let rejectedPeople: [String]
    public let sceneCaptions: [SceneCaption]
    public let sceneCaptionModel: String?
    public let sceneCaptionDate: Date?
    public let ocrDateCandidates: [SceneCaption]
    public let ocrText: [SceneCaption]
    public let inferredRecordDate: Date?
    public let inferredDateConfidence: Float?
    public let dossierProcessedAt: Date?
    public let dossierProcessedBy: String?
    public let audioTranscript: String?
    public let audioTranscriptModel: String?
    public let audioTranscriptDate: Date?
    public let combinedFromPairID: UUID?
    public let scanContext: ScanContext
    public let purgedAt: Date?
    public let needsReformat: Bool
    public let derivedFrom: UUID?
    public let workspaceActive: Bool
    public let drmProtected: Bool
    public let originalFullPath: String?
    public let originVolume: String?

    // MARK: Capture from a live VideoRecord (called ON the main actor)

    /// Snapshot every persisted field of `r` by value. String/Array are
    /// CoW value types so this is a cheap, fully-independent copy — the
    /// resulting DTO shares no mutable state with the live record and is
    /// safe to ship off the main actor. This is the ONLY place VideoRecord
    /// is read on the save path.
    public init(_ r: VideoRecord) {
        id                          = r.id
        filename                    = r.filename
        ext                         = r.ext
        streamTypeRaw               = r.streamTypeRaw
        size                        = r.size
        sizeBytes                   = r.sizeBytes
        duration                    = r.duration
        durationSeconds             = r.durationSeconds
        dateCreated                 = r.dateCreated
        dateModified                = r.dateModified
        dateCreatedRaw              = r.dateCreatedRaw
        dateModifiedRaw             = r.dateModifiedRaw
        container                   = r.container
        videoCodec                  = r.videoCodec
        resolution                  = r.resolution
        frameRate                   = r.frameRate
        videoBitrate                = r.videoBitrate
        totalBitrate                = r.totalBitrate
        colorSpace                  = r.colorSpace
        bitDepth                    = r.bitDepth
        scanType                    = r.scanType
        audioCodec                  = r.audioCodec
        audioChannels               = r.audioChannels
        audioSampleRate             = r.audioSampleRate
        timecode                    = r.timecode
        tapeName                    = r.tapeName
        isPlayable                  = r.isPlayable
        partialMD5                  = r.partialMD5
        fullPath                    = r.fullPath
        directory                   = r.directory
        notes                       = r.notes
        avidClipName                = r.avidClipName
        avidMobID                   = r.avidMobID
        avidMaterialUUID            = r.avidMaterialUUID
        avidBinFile                 = r.avidBinFile
        avidMobType                 = r.avidMobType
        avidMediaPath               = r.avidMediaPath
        avidTapeName                = r.avidTapeName
        avidEditRate                = r.avidEditRate
        avidTracks                  = r.avidTracks
        materialPackageUMID         = r.materialPackageUMID
        pairedWithID                = r.pairedWith?.id
        pairGroupID                 = r.pairGroupID
        pairConfidence              = r.pairConfidence
        duplicateGroupID            = r.duplicateGroupID
        duplicateConfidence         = r.duplicateConfidence
        duplicateDisposition        = r.duplicateDisposition
        duplicateReasons            = r.duplicateReasons
        duplicateBestMatchFilename  = r.duplicateBestMatchFilename
        duplicateGroupCount         = r.duplicateGroupCount
        dupAnalyzedAt               = r.dupAnalyzedAt
        sourceHost                  = r.sourceHost
        lifecycleStage              = r.lifecycleStage
        mediaDisposition            = r.mediaDisposition
        archiveStage                = r.archiveStage
        masterLocation              = r.masterLocation
        backupDestinations          = r.backupDestinations
        junkScore                   = r.junkScore
        junkReasons                 = r.junkReasons
        starRating                  = r.starRating
        detectedPeople              = r.detectedPeople
        suspectedPeople             = r.suspectedPeople
        confirmedByUserPeople       = r.confirmedByUserPeople
        rejectedPeople              = r.rejectedPeople
        sceneCaptions               = r.sceneCaptions
        sceneCaptionModel           = r.sceneCaptionModel
        sceneCaptionDate            = r.sceneCaptionDate
        ocrDateCandidates           = r.ocrDateCandidates
        ocrText                     = r.ocrText
        inferredRecordDate          = r.inferredRecordDate
        inferredDateConfidence      = r.inferredDateConfidence
        dossierProcessedAt          = r.dossierProcessedAt
        dossierProcessedBy          = r.dossierProcessedBy
        audioTranscript             = r.audioTranscript
        audioTranscriptModel        = r.audioTranscriptModel
        audioTranscriptDate         = r.audioTranscriptDate
        combinedFromPairID          = r.combinedFromPairID
        scanContext                 = r.scanContext
        purgedAt                    = r.purgedAt
        needsReformat               = r.needsReformat
        derivedFrom                 = r.derivedFrom
        workspaceActive             = r.workspaceActive
        drmProtected                = r.drmProtected
        originalFullPath            = r.originalFullPath
        originVolume                = r.originVolume
    }

    // MARK: Encode — VERBATIM from VideoRecord.encode(to:)
    //
    // The ONLY change from the original class encoder is `pairedWith?.id`
    // → the pre-flattened `pairedWithID`. Keys, order, encodeIfPresent /
    // isEmpty / non-zero gating, and the encoder's date strategy are all
    // unchanged. Reuses VideoRecord.CodingKeys directly (same module, the
    // enum is internal-nested so it is visible here).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: VideoRecord.CodingKeys.self)
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
        try c.encodeIfPresent(pairedWithID, forKey: .pairedWithID)
        try c.encodeIfPresent(pairGroupID, forKey: .pairGroupID)
        try c.encodeIfPresent(pairConfidence, forKey: .pairConfidence)
        try c.encodeIfPresent(duplicateGroupID, forKey: .duplicateGroupID)
        try c.encodeIfPresent(duplicateConfidence, forKey: .duplicateConfidence)
        try c.encode(duplicateDisposition, forKey: .duplicateDisposition)
        try c.encode(duplicateReasons, forKey: .duplicateReasons)
        try c.encode(duplicateBestMatchFilename, forKey: .duplicateBestMatchFilename)
        try c.encode(duplicateGroupCount, forKey: .duplicateGroupCount)
        try c.encodeIfPresent(dupAnalyzedAt, forKey: .dupAnalyzedAt)
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
