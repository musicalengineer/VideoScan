// VideoRecordJSON.swift
// The importer's OWN reading of one catalog.json row (step D′). It is a
// plain `Decodable` mirror of all 131 keys of contract §a (source of truth:
// `VideoRecord.CodingKeys`, C/VideoRecord+Codable.swift:34–102), with every
// key OPTIONAL on read (contract §a "all keys are optional on READ").
//
// It deliberately does NOT go through the app's `VideoRecord` class:
//   * the class invents a fresh UUID when `id` is absent (VideoRecord.swift:758)
//     and migrates `purgedAt` onto a removal marker (:880–884) — the importer
//     must see what the file says, not what the model would make of it;
//   * a damaged nested value (a removal marker `42`, a report card from the
//     future) must not cost the row: each key decodes on its own, a key that
//     fails is listed in `undecodable`, and `raw` keeps the whole object.
//
// Dates are `CatalogJSONDate` (ISO-8601 text + unix seconds), so no decoder date
// strategy is needed; use `VideoRecordJSON.makeDecoder()` anyway.
//
// (For Rick: a POD mirror of the on-disk row; `raw` ≈ the parsed DOM kept
// beside it.)

import Foundation

public struct VideoRecordJSON: Decodable, Sendable, Equatable {

    /// The 131 keys of contract §a, in `VideoRecord.CodingKeys` order (the
    /// contract table lists the same keys grouped its own way).
    public enum Key: String, CodingKey, CaseIterable, Sendable {
        case id, filename, ext, streamTypeRaw, size, sizeBytes, duration, durationSeconds
        case dateCreated, dateModified, dateCreatedRaw, dateModifiedRaw
        case container, videoCodec, resolution, frameRate, videoBitrate, totalBitrate
        case colorSpace, bitDepth, scanType, audioCodec, audioChannels, audioSampleRate
        case timecode, tapeName, isPlayable, partialMD5, fullPath, directory, notes
        case contentHash, contentHashAt
        case embeddedCreationDate, embeddedCreationSource
        case originMake, originModel, originEncoder
        case originalFullPath, originVolume
        case avidClipName, avidMobID, avidMaterialUUID, avidBinFile, avidMobType
        case avidMediaPath, avidTapeName, avidEditRate, avidTracks
        case materialPackageUMID
        case materialPackageName, isAvidRender   // 130, 131 — A/V pair matcher 2026-10-22
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
        case inferredRecordDate, inferredDateConfidence, inferredDateSource
        case inferredDateRange, inferredDateReason
        case dossierProcessedAt, dossierProcessedBy
        case audioTranscript, audioTranscriptModel, audioTranscriptDate
        case sourceHost
        case scanContext
        case purgedAt
        case removal
        case removalRevision
        case auditSeenOn
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
        case userPlace
        case userPlaceConfidence
        case backupAttestations
        case workspaceActive
        case userNotes
        case tags
        case audioVerifyStatus
        case audioVerifyNote
        case audioVerifyDate
        case videoVerifyStatus
        case videoVerifyNote
        case videoVerifyDate
        case supersededByID
        case repairConfirmedDate
        case archiveFixity
        case contentFixity
        case archivedAt
        case proAppsMediaIdentifier
        case footage
        case footageDecisions
        case familyMusic
        case perceptualFingerprint
        case mediaReportCard
        case audioFingerprint
    }

    // MARK: Nested mirrors (contract §b) — field names are the JSON keys.

    /// `FileIdentityStamp` (C/ContentFixity.swift:83).
    public struct StampJSON: Codable, Sendable, Equatable {
        public var device: UInt64
        public var inode: UInt64
        public var size: Int64
        public var mtimeNs: Int64
        /// Absent on pre-ctime stamps → −1 (`FileIdentityStamp.unknownCtime`).
        public var ctimeNs: Int64?
        public var volumeUUID: String?
    }

    /// `ContentFixity` (C/ContentFixity.swift:250).
    public struct ContentFixityJSON: Codable, Sendable, Equatable {
        public var algorithm: String
        public var digest: String
        public var byteCount: Int64
        public var stamp: StampJSON
        public var computedAt: CatalogJSONDate
    }

    /// `ArchiveFixity` (C/ArchiveFixity.swift:17).
    public struct ArchiveFixityJSON: Codable, Sendable, Equatable {
        public var algorithm: String
        public var digest: String
        public var verifiedAt: CatalogJSONDate
        public var sizeBytes: Int64
    }

    /// `AudioFingerprintStamp` (C/AudioFingerprintStamp.swift:37).
    public struct AudioFingerprintJSON: Codable, Sendable, Equatable {
        public var computedAt: CatalogJSONDate
        public var engineVersion: Int
        public var contentDigest: String
        public var sizeBytes: Int64
        public var outcome: String
        public var analyzedSeconds: Double
        public var complete: Bool
        public var landmarks: Int
        public var bytes: Int
    }

    /// `RemovalMarker` (C/RemovalMarker.swift:64). `state` and `reason` are
    /// kept as words: an unknown state is the importer's question, not a
    /// decode failure.
    public struct RemovalJSON: Codable, Sendable, Equatable {
        public var state: String
        public var since: CatalogJSONDate
        public var reason: String
        public var trashPath: String?
        public var trashEmptiedSeenAt: CatalogJSONDate?
        public var lastSeen: CatalogJSONDate?
    }

    /// `AuditSeenOn` (C/AuditSeenOn.swift:27).
    public struct AuditSeenOnJSON: Codable, Sendable, Equatable {
        public var volumeUUID: String
        public var mountFrom: String?
        public var seenAt: CatalogJSONDate
        public var deviceKey: String?
    }

    /// `ScanContext` (C/ScanContext.swift:24); every member optional on read.
    public struct ScanContextJSON: Codable, Sendable, Equatable {
        public var scanHost: String?
        public var volumeUUID: String?
        public var volumeMountType: String?
        public var volumeName: String?
        public var remoteServerName: String?
        public var scannedAt: CatalogJSONDate?
        public var scanRootLabel: String?
        public var bundleContainer: String?
    }

    /// `BackupEntry` (C/ArchiveModels.swift:68).
    public struct BackupEntryJSON: Codable, Sendable, Equatable {
        public var name: String
        public var kind: String
        public var date: CatalogJSONDate
    }

    /// `ConfirmedTag` (C/Tagging.swift:39).
    public struct ConfirmedTagJSON: Codable, Sendable, Equatable {
        public var name: String
        public var confirmedAt: CatalogJSONDate
    }

    /// `SceneCaption` (C/Tagging.swift:20).
    public struct SceneCaptionJSON: Codable, Sendable, Equatable {
        public var timestamp: Double
        public var text: String
    }

    /// `InferredDateRange` (C/InferredDateRange.swift:18).
    public struct InferredDateRangeJSON: Codable, Sendable, Equatable {
        public var startYear: Int
        public var endYear: Int
    }

    /// `BackupAttestation` (C/BackupAttestation.swift:57); `attestedAt` is
    /// millisecond ISO-8601 text (`BackupAttestation.Timestamp`).
    public struct BackupAttestationJSON: Codable, Sendable, Equatable {
        public var kind: String
        public var answer: String
        public var label: String?
        public var attestedAt: CatalogJSONDate
        public var by: String
    }

    /// `FootageDecision` (C/FootageMembership.swift:171).
    public struct FootageDecisionJSON: Codable, Sendable, Equatable {
        public var otherID: String
        public var verdict: String
        public var decidedAt: CatalogJSONDate
    }

    /// `FamilyMusicInfo` (C/FamilyMusicInfo.swift:22).
    public struct FamilyMusicJSON: Codable, Sendable, Equatable {
        public var performer: String?
        public var title: String?
        public var markedAt: CatalogJSONDate
    }

    /// `StoredPerceptualFingerprint` (C/StoredPerceptualFingerprint.swift:36).
    public struct PerceptualPrintJSON: Codable, Sendable, Equatable {
        public var algorithmVersion: Int
        public var hashesBase64: String
        public var sizeBytes: Int64
        public var durationSeconds: Double
        public var computedAt: CatalogJSONDate
    }

    // MARK: Typed fields (131), CodingKeys order. nil = absent, null, or undecodable.

    public var id: String?
    public var filename: String?
    public var ext: String?
    public var streamTypeRaw: String?
    public var size: String?
    public var sizeBytes: Int64?
    public var duration: String?
    public var durationSeconds: Double?
    public var dateCreated: String?
    public var dateModified: String?
    public var dateCreatedRaw: CatalogJSONDate?
    public var dateModifiedRaw: CatalogJSONDate?
    public var container: String?
    public var videoCodec: String?
    public var resolution: String?
    public var frameRate: String?
    public var videoBitrate: String?
    public var totalBitrate: String?
    public var colorSpace: String?
    public var bitDepth: String?
    public var scanType: String?
    public var audioCodec: String?
    public var audioChannels: String?
    public var audioSampleRate: String?
    public var timecode: String?
    public var tapeName: String?
    public var isPlayable: String?
    public var partialMD5: String?
    public var fullPath: String?
    public var directory: String?
    public var notes: String?
    public var contentHash: String?
    public var contentHashAt: CatalogJSONDate?
    public var embeddedCreationDate: CatalogJSONDate?
    public var embeddedCreationSource: String?
    public var originMake: String?
    public var originModel: String?
    public var originEncoder: String?
    public var originalFullPath: String?
    public var originVolume: String?
    public var avidClipName: String?
    public var avidMobID: String?
    public var avidMaterialUUID: String?
    public var avidBinFile: String?
    public var avidMobType: String?
    public var avidMediaPath: String?
    public var avidTapeName: String?
    public var avidEditRate: Double?
    public var avidTracks: String?
    public var materialPackageUMID: String?
    public var materialPackageName: String?
    public var isAvidRender: Bool?
    public var pairedWithID: String?
    public var pairGroupID: String?
    public var pairConfidence: String?
    public var duplicateGroupID: String?
    public var duplicateConfidence: String?
    public var duplicateDisposition: String?
    public var duplicateReasons: String?
    public var duplicateBestMatchFilename: String?
    public var duplicateGroupCount: Int?
    public var dupAnalyzedAt: CatalogJSONDate?
    public var lifecycleStage: String?
    public var mediaDisposition: String?
    public var archiveStage: String?
    public var masterLocation: String?
    public var backupDestinations: [BackupEntryJSON]?
    public var junkScore: Int?
    public var junkReasons: [String]?
    public var starRating: Int?
    public var detectedPeople: [String]?
    public var suspectedPeople: [String]?
    public var combinedFromPairID: String?
    public var confirmedByUserPeople: [ConfirmedTagJSON]?
    public var rejectedPeople: [String]?
    public var sceneCaptions: [SceneCaptionJSON]?
    public var sceneCaptionModel: String?
    public var sceneCaptionDate: CatalogJSONDate?
    public var ocrDateCandidates: [SceneCaptionJSON]?
    public var ocrText: [SceneCaptionJSON]?
    public var inferredRecordDate: CatalogJSONDate?
    /// `Float` in the model (contract §a: REAL, compared as Float32).
    public var inferredDateConfidence: Float?
    public var inferredDateSource: String?
    public var inferredDateRange: InferredDateRangeJSON?
    public var inferredDateReason: String?
    public var dossierProcessedAt: CatalogJSONDate?
    public var dossierProcessedBy: String?
    public var audioTranscript: String?
    public var audioTranscriptModel: String?
    public var audioTranscriptDate: CatalogJSONDate?
    public var sourceHost: String?
    public var scanContext: ScanContextJSON?
    public var purgedAt: CatalogJSONDate?
    public var removal: RemovalJSON?
    public var removalRevision: Int?
    public var auditSeenOn: AuditSeenOnJSON?
    public var setAsideReason: String?
    public var drmProtected: Bool?
    public var needsReformat: Bool?
    public var derivedFrom: String?
    public var cleanupRecipeID: String?
    public var cleanupRecipeVersion: Int?
    public var derivationKind: String?
    public var trimInSeconds: Double?
    public var trimOutSeconds: Double?
    public var userDate: String?
    public var userDateConfidence: String?
    public var userPlace: String?
    public var userPlaceConfidence: String?
    public var backupAttestations: [BackupAttestationJSON]?
    public var workspaceActive: Bool?
    public var userNotes: String?
    public var tags: [String]?
    public var audioVerifyStatus: String?
    public var audioVerifyNote: String?
    public var audioVerifyDate: CatalogJSONDate?
    public var videoVerifyStatus: String?
    public var videoVerifyNote: String?
    public var videoVerifyDate: CatalogJSONDate?
    public var supersededByID: String?
    public var repairConfirmedDate: CatalogJSONDate?
    public var archiveFixity: ArchiveFixityJSON?
    public var contentFixity: ContentFixityJSON?
    public var archivedAt: CatalogJSONDate?
    public var proAppsMediaIdentifier: String?
    /// `FootageMembership` — machine, rewritten per run; kept as JSON
    /// (`footage_membership.membership`).
    public var footage: CatalogJSONValue?
    public var footageDecisions: [FootageDecisionJSON]?
    public var familyMusic: FamilyMusicJSON?
    public var perceptualFingerprint: PerceptualPrintJSON?
    /// `MediaReportCard` — kept as JSON (`media_checks.card`); a card from a
    /// future build must not fail the row.
    public var mediaReportCard: CatalogJSONValue?
    public var audioFingerprint: AudioFingerprintJSON?

    // MARK: Evidence of the read itself

    /// The whole row object, verbatim.
    public var raw: [String: CatalogJSONValue]
    /// Keys present (and not null) whose typed decode failed. Their values
    /// are only in `raw`.
    public var undecodable: [String]

    /// Keys present in the row that are not one of the 131 (a future build's
    /// field). Kept in `raw`.
    public var unknownKeys: [String] {
        let known = Set(Key.allCases.map(\.rawValue))
        return raw.keys.filter { !known.contains($0) }.sorted()
    }

    public static func makeDecoder() -> JSONDecoder { JSONDecoder() }

    public init(from decoder: Decoder) throws {
        // The DOM first; a row that is not an object fails here (and only here).
        let whole = try CatalogJSONValue(from: decoder)
        guard case .object(let object) = whole else {
            throw DecodingError.typeMismatch([String: CatalogJSONValue].self,
                                             .init(codingPath: decoder.codingPath, debugDescription: "a catalog row is a JSON object"))
        }
        raw = object
        let c = try decoder.container(keyedBy: Key.self)
        var bad: [String] = []

        id = Self.read(c, .id, &bad)
        filename = Self.read(c, .filename, &bad)
        ext = Self.read(c, .ext, &bad)
        streamTypeRaw = Self.read(c, .streamTypeRaw, &bad)
        size = Self.read(c, .size, &bad)
        sizeBytes = Self.read(c, .sizeBytes, &bad)
        duration = Self.read(c, .duration, &bad)
        durationSeconds = Self.read(c, .durationSeconds, &bad)
        dateCreated = Self.read(c, .dateCreated, &bad)
        dateModified = Self.read(c, .dateModified, &bad)
        dateCreatedRaw = Self.read(c, .dateCreatedRaw, &bad)
        dateModifiedRaw = Self.read(c, .dateModifiedRaw, &bad)
        container = Self.read(c, .container, &bad)
        videoCodec = Self.read(c, .videoCodec, &bad)
        resolution = Self.read(c, .resolution, &bad)
        frameRate = Self.read(c, .frameRate, &bad)
        videoBitrate = Self.read(c, .videoBitrate, &bad)
        totalBitrate = Self.read(c, .totalBitrate, &bad)
        colorSpace = Self.read(c, .colorSpace, &bad)
        bitDepth = Self.read(c, .bitDepth, &bad)
        scanType = Self.read(c, .scanType, &bad)
        audioCodec = Self.read(c, .audioCodec, &bad)
        audioChannels = Self.read(c, .audioChannels, &bad)
        audioSampleRate = Self.read(c, .audioSampleRate, &bad)
        timecode = Self.read(c, .timecode, &bad)
        tapeName = Self.read(c, .tapeName, &bad)
        isPlayable = Self.read(c, .isPlayable, &bad)
        partialMD5 = Self.read(c, .partialMD5, &bad)
        fullPath = Self.read(c, .fullPath, &bad)
        directory = Self.read(c, .directory, &bad)
        notes = Self.read(c, .notes, &bad)
        contentHash = Self.read(c, .contentHash, &bad)
        contentHashAt = Self.read(c, .contentHashAt, &bad)
        embeddedCreationDate = Self.read(c, .embeddedCreationDate, &bad)
        embeddedCreationSource = Self.read(c, .embeddedCreationSource, &bad)
        originMake = Self.read(c, .originMake, &bad)
        originModel = Self.read(c, .originModel, &bad)
        originEncoder = Self.read(c, .originEncoder, &bad)
        originalFullPath = Self.read(c, .originalFullPath, &bad)
        originVolume = Self.read(c, .originVolume, &bad)
        avidClipName = Self.read(c, .avidClipName, &bad)
        avidMobID = Self.read(c, .avidMobID, &bad)
        avidMaterialUUID = Self.read(c, .avidMaterialUUID, &bad)
        avidBinFile = Self.read(c, .avidBinFile, &bad)
        avidMobType = Self.read(c, .avidMobType, &bad)
        avidMediaPath = Self.read(c, .avidMediaPath, &bad)
        avidTapeName = Self.read(c, .avidTapeName, &bad)
        avidEditRate = Self.read(c, .avidEditRate, &bad)
        avidTracks = Self.read(c, .avidTracks, &bad)
        materialPackageUMID = Self.read(c, .materialPackageUMID, &bad)
        materialPackageName = Self.read(c, .materialPackageName, &bad)
        isAvidRender = Self.read(c, .isAvidRender, &bad)
        pairedWithID = Self.read(c, .pairedWithID, &bad)
        pairGroupID = Self.read(c, .pairGroupID, &bad)
        pairConfidence = Self.read(c, .pairConfidence, &bad)
        duplicateGroupID = Self.read(c, .duplicateGroupID, &bad)
        duplicateConfidence = Self.read(c, .duplicateConfidence, &bad)
        duplicateDisposition = Self.read(c, .duplicateDisposition, &bad)
        duplicateReasons = Self.read(c, .duplicateReasons, &bad)
        duplicateBestMatchFilename = Self.read(c, .duplicateBestMatchFilename, &bad)
        duplicateGroupCount = Self.read(c, .duplicateGroupCount, &bad)
        dupAnalyzedAt = Self.read(c, .dupAnalyzedAt, &bad)
        lifecycleStage = Self.read(c, .lifecycleStage, &bad)
        mediaDisposition = Self.read(c, .mediaDisposition, &bad)
        archiveStage = Self.read(c, .archiveStage, &bad)
        masterLocation = Self.read(c, .masterLocation, &bad)
        backupDestinations = Self.read(c, .backupDestinations, &bad)
        junkScore = Self.read(c, .junkScore, &bad)
        junkReasons = Self.read(c, .junkReasons, &bad)
        starRating = Self.read(c, .starRating, &bad)
        detectedPeople = Self.read(c, .detectedPeople, &bad)
        suspectedPeople = Self.read(c, .suspectedPeople, &bad)
        combinedFromPairID = Self.read(c, .combinedFromPairID, &bad)
        confirmedByUserPeople = Self.read(c, .confirmedByUserPeople, &bad)
        rejectedPeople = Self.read(c, .rejectedPeople, &bad)
        sceneCaptions = Self.read(c, .sceneCaptions, &bad)
        sceneCaptionModel = Self.read(c, .sceneCaptionModel, &bad)
        sceneCaptionDate = Self.read(c, .sceneCaptionDate, &bad)
        ocrDateCandidates = Self.read(c, .ocrDateCandidates, &bad)
        ocrText = Self.read(c, .ocrText, &bad)
        inferredRecordDate = Self.read(c, .inferredRecordDate, &bad)
        inferredDateConfidence = Self.read(c, .inferredDateConfidence, &bad)
        inferredDateSource = Self.read(c, .inferredDateSource, &bad)
        inferredDateRange = Self.read(c, .inferredDateRange, &bad)
        inferredDateReason = Self.read(c, .inferredDateReason, &bad)
        dossierProcessedAt = Self.read(c, .dossierProcessedAt, &bad)
        dossierProcessedBy = Self.read(c, .dossierProcessedBy, &bad)
        audioTranscript = Self.read(c, .audioTranscript, &bad)
        audioTranscriptModel = Self.read(c, .audioTranscriptModel, &bad)
        audioTranscriptDate = Self.read(c, .audioTranscriptDate, &bad)
        sourceHost = Self.read(c, .sourceHost, &bad)
        scanContext = Self.read(c, .scanContext, &bad)
        purgedAt = Self.read(c, .purgedAt, &bad)
        removal = Self.read(c, .removal, &bad)
        removalRevision = Self.read(c, .removalRevision, &bad)
        auditSeenOn = Self.read(c, .auditSeenOn, &bad)
        setAsideReason = Self.read(c, .setAsideReason, &bad)
        drmProtected = Self.read(c, .drmProtected, &bad)
        needsReformat = Self.read(c, .needsReformat, &bad)
        derivedFrom = Self.read(c, .derivedFrom, &bad)
        cleanupRecipeID = Self.read(c, .cleanupRecipeID, &bad)
        cleanupRecipeVersion = Self.read(c, .cleanupRecipeVersion, &bad)
        derivationKind = Self.read(c, .derivationKind, &bad)
        trimInSeconds = Self.read(c, .trimInSeconds, &bad)
        trimOutSeconds = Self.read(c, .trimOutSeconds, &bad)
        userDate = Self.read(c, .userDate, &bad)
        userDateConfidence = Self.read(c, .userDateConfidence, &bad)
        userPlace = Self.read(c, .userPlace, &bad)
        userPlaceConfidence = Self.read(c, .userPlaceConfidence, &bad)
        backupAttestations = Self.read(c, .backupAttestations, &bad)
        workspaceActive = Self.read(c, .workspaceActive, &bad)
        userNotes = Self.read(c, .userNotes, &bad)
        tags = Self.read(c, .tags, &bad)
        audioVerifyStatus = Self.read(c, .audioVerifyStatus, &bad)
        audioVerifyNote = Self.read(c, .audioVerifyNote, &bad)
        audioVerifyDate = Self.read(c, .audioVerifyDate, &bad)
        videoVerifyStatus = Self.read(c, .videoVerifyStatus, &bad)
        videoVerifyNote = Self.read(c, .videoVerifyNote, &bad)
        videoVerifyDate = Self.read(c, .videoVerifyDate, &bad)
        supersededByID = Self.read(c, .supersededByID, &bad)
        repairConfirmedDate = Self.read(c, .repairConfirmedDate, &bad)
        archiveFixity = Self.read(c, .archiveFixity, &bad)
        contentFixity = Self.read(c, .contentFixity, &bad)
        archivedAt = Self.read(c, .archivedAt, &bad)
        proAppsMediaIdentifier = Self.read(c, .proAppsMediaIdentifier, &bad)
        footage = Self.read(c, .footage, &bad)
        footageDecisions = Self.read(c, .footageDecisions, &bad)
        familyMusic = Self.read(c, .familyMusic, &bad)
        perceptualFingerprint = Self.read(c, .perceptualFingerprint, &bad)
        mediaReportCard = Self.read(c, .mediaReportCard, &bad)
        audioFingerprint = Self.read(c, .audioFingerprint, &bad)

        undecodable = bad.sorted()
    }

    /// One key, on its own: absent or null → nil; a value that does not
    /// decode → nil AND the key is listed (its value stays in `raw`).
    private static func read<T: Decodable>(_ c: KeyedDecodingContainer<Key>, _ key: Key,
                                           _ bad: inout [String]) -> T? {
        guard c.contains(key) else { return nil }
        if let isNil = try? c.decodeNil(forKey: key), isNil { return nil }
        do {
            return try c.decode(T.self, forKey: key)
        } catch {
            bad.append(key.rawValue)
            return nil
        }
    }
}

// MARK: - The catalog file

/// catalog.json as the importer reads it: the header (absent `version` → 1,
/// absent `generation` → 0, CatalogStore.swift:119–120) and every row
/// occurrence, in file order. `savedAt` is kept verbatim (old files wrote a
/// number, contract fixtures v2/v3).
public struct CatalogFileJSON: Decodable, Sendable, Equatable {
    /// The newest JSON version the importer accepts (contract §f).
    public static let newestVersion = 6

    public var version: Int
    public var generation: Int
    public var savedAt: CatalogJSONValue?
    public var savedFromHost: String?
    public var records: [VideoRecordJSON]
    /// Header keys verbatim (everything but `records`).
    public var header: [String: CatalogJSONValue]

    private enum Keys: String, CodingKey { case version, generation, savedAt, savedFromHost, records }

    public init(from decoder: Decoder) throws {
        let whole = try CatalogJSONValue(from: decoder)
        var head = whole.objectValue ?? [:]
        head.removeValue(forKey: "records")
        header = head
        let c = try decoder.container(keyedBy: Keys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        generation = try c.decodeIfPresent(Int.self, forKey: .generation) ?? 0
        savedAt = try c.decodeIfPresent(CatalogJSONValue.self, forKey: .savedAt)
        savedFromHost = try c.decodeIfPresent(String.self, forKey: .savedFromHost)
        records = try c.decodeIfPresent([VideoRecordJSON].self, forKey: .records) ?? []
    }

    public static func decode(_ data: Data) throws -> CatalogFileJSON {
        try VideoRecordJSON.makeDecoder().decode(CatalogFileJSON.self, from: data)
    }
}
