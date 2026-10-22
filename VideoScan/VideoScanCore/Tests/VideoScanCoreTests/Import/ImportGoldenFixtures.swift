// ImportGoldenFixtures.swift
// The catalog.json golden fixtures v1–v6, copied VERBATIM from the app test
// target (which this package cannot import), plus one row carrying all 129
// keys. Each constant names its source; keep them in step by hand — they are
// the importer's evidence that ONE reader covers every on-disk version
// (contract §a "JSON versions v1–v6", §9.8).

enum ImportGoldenFixtures {

    /// v1 — no `version` key at all (records-only era).
    /// Source: VideoScanTests/CatalogStoreHardeningTests.swift `snapshotMissingVersionKeyImpliesV1`.
    static let v1 = #"""
    {
      "records": []
    }
    """#

    /// v2 — ISO savedAt + savedFromHost, two legacy rows, no purgedAt.
    /// Source: VideoScanTests/CatalogPurgeTests.swift `testDecodingLegacyCatalogJsonYieldsNilPurgedAt`.
    static let v2 = #"""
    {
      "version": 2,
      "savedAt": "2026-04-01T12:00:00Z",
      "savedFromHost": "TestHost",
      "records": [
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "filename": "legacy_clip.mov",
          "fullPath": "/Volumes/Legacy/legacy_clip.mov",
          "streamTypeRaw": "Video+Audio",
          "sizeBytes": 1234567,
          "durationSeconds": 12.5
        },
        {
          "id": "00000000-0000-0000-0000-000000000002",
          "filename": "another.mxf",
          "fullPath": "/Volumes/Legacy/another.mxf",
          "streamTypeRaw": "Video only",
          "sizeBytes": 987654,
          "durationSeconds": 30
        }
      ]
    }
    """#

    /// v2 with a NUMERIC savedAt (the pre-iso8601 header).
    /// Source: VideoScanTests/FamilyTaggingTests.swift `v2CatalogJsonRoundTripsWithEmptySuspectedPeople`.
    static let v2NumericSavedAt = #"""
    {
      "version": 2,
      "savedAt": 0,
      "records": [
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "fullPath": "/v/old.mov",
          "filename": "old.mov",
          "detectedPeople": ["Donna"]
        }
      ]
    }
    """#

    /// v3 — suspectedPeople, no caption keys.
    /// Source: VideoScanTests/SceneCaptionsTests.swift `v3CatalogJsonLoadsWithEmptyCaptionFields`.
    static let v3 = #"""
    {
      "version": 3,
      "savedAt": 0,
      "records": [
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "fullPath": "/v/old.mov",
          "filename": "old.mov",
          "detectedPeople": ["Donna"],
          "suspectedPeople": ["Tim"]
        }
      ]
    }
    """#

    /// v4 — header only (the checked-in v4 fixtures carry no rows).
    /// Source: VideoScanTests/RelocateSchemaTests.swift `legacyV4CatalogSnapshotLoadsAsCurrentVersion`.
    static let v4 = #"""
    {
      "version": 4,
      "savedAt": "2026-05-29T12:00:00Z",
      "records": [],
      "savedFromHost": "RicksM4"
    }
    """#

    /// v5 — Relocate provenance keys.
    /// Source: VideoScanTests/RelocateSchemaTests.swift `legacyV5CatalogWithoutRetiredFieldsDecodes`.
    static let v5 = #"""
    {
      "version": 5,
      "savedAt": "2026-05-30T09:00:00Z",
      "records": [
        {
          "id": "22222222-2222-2222-2222-222222222222",
          "filename": "old.mov",
          "fullPath": "/Volumes/Mini2TB/old.mov",
          "directory": "/Volumes/Mini2TB",
          "partialMD5": "feedface",
          "sizeBytes": 4096,
          "originalFullPath": "/Volumes/Mini2TB/old.mov",
          "originVolume": "Mini2TB"
        }
      ],
      "savedFromHost": "RicksM4"
    }
    """#

    /// The DTO golden record (86 keys), byte-for-byte.
    /// Source: VideoScanTests/CatalogStoreAsyncSaveTests.swift `videoRecordGolden`.
    static let v6GoldenRecord = #"{"archiveStage":"Backed Up","audioChannels":"2","audioCodec":"pcm_s16le","audioSampleRate":"48000","audioTranscript":"happy birthday matt","audioTranscriptDate":"2026-06-04T01:00:00Z","audioTranscriptModel":"whisper-medium-mlx-q4","avidBinFile":"bin.avb","avidClipName":"Clip 1","avidEditRate":29.97,"avidMaterialUUID":"amu","avidMediaPath":"\/avid\/media","avidMobID":"mob1","avidMobType":"Master","avidTapeName":"AT","avidTracks":"V1, A1-A2","backupDestinations":[{"date":"2026-01-01T00:00:00Z","kind":"Local","name":"LTA_Crucial"}],"bitDepth":"8","colorSpace":"bt601","combinedFromPairID":"66666666-6666-6666-6666-666666666666","confirmedByUserPeople":[{"confirmedAt":"2026-04-12T00:00:00Z","name":"Donna"}],"container":"mov","contentHash":"","dateCreated":"1991-06-21","dateCreatedRaw":"1991-06-21T12:00:00Z","dateModified":"1991-06-22","dateModifiedRaw":"1991-06-22T12:00:00Z","derivedFrom":"55555555-AAAA-BBBB-CCCC-555555555555","detectedPeople":["Donna"],"directory":"\/Volumes\/T","dossierProcessedAt":"2026-06-04T00:00:00Z","dossierProcessedBy":"qwen+whisper","drmProtected":true,"duplicateBestMatchFilename":"other.mov","duplicateConfidence":"Medium","duplicateDisposition":"Keep","duplicateGroupCount":2,"duplicateGroupID":"77777777-7777-7777-7777-777777777777","duplicateReasons":"same md5","duration":"00:01:00","durationSeconds":60.5,"ext":"mov","filename":"clip.mov","frameRate":"29.97","fullPath":"\/Volumes\/T\/clip.mov","id":"11111111-2222-3333-4444-555555555555","inferredDateConfidence":0.95,"inferredRecordDate":"1991-06-21T00:00:00Z","isPlayable":"Yes","junkReasons":["short"],"junkScore":3,"lifecycleStage":"Cataloged","masterLocation":"Mac Studio SSD","materialPackageUMID":"0x060A2B34","mediaDisposition":"Important","needsReformat":true,"notes":"birthday","ocrDateCandidates":[{"text":"JUN.21 1991","timestamp":2}],"ocrText":[{"text":"Happy Birthday","timestamp":3}],"originVolume":"OldDrive","originalFullPath":"\/Volumes\/Old\/clip.mov","pairConfidence":"High","pairGroupID":"88888888-8888-8888-8888-888888888888","pairedWithID":"99999999-9999-9999-9999-999999999999","partialMD5":"ABC123","purgedAt":"2026-06-01T00:00:00Z","rejectedPeople":["Anna"],"removal":{"reason":"legacyPurged","since":"2026-06-01T00:00:00Z","state":"removedFromCatalog"},"resolution":"720x480","scanContext":{"remoteServerName":"macpro.local","scanHost":"MacStudio","scanRootLabel":"Movies","scannedAt":"2026-05-01T00:00:00Z","volumeMountType":"smbfs","volumeName":"MyBook3Terabytes","volumeUUID":"VU-1"},"scanType":"interlaced","sceneCaptionDate":"2026-05-22T00:00:00Z","sceneCaptionModel":"qwen2.5-vl-3b-4bit","sceneCaptions":[{"text":"a man playing guitar","timestamp":1.5}],"size":"1.2 GB","sizeBytes":123456789,"sourceHost":"MacStudio","starRating":2,"streamTypeRaw":"Video+Audio","suspectedPeople":["Tim"],"tapeName":"Tape1","timecode":"01:00:00:00","totalBitrate":"9 Mb\/s","videoBitrate":"8 Mb\/s","videoCodec":"h264","workspaceActive":true}"#

    /// v6 — the on-disk wrapper golden.
    /// Source: VideoScanTests/CatalogStoreAsyncSaveTests.swift `snapshotGolden`.
    static let v6 = #"{"version":6,"generation":0,"savedAt":"2025-06-15T15:06:40Z","savedFromHost":"MacStudio","records":["#
        + v6GoldenRecord + "]}"

    /// v6 — poisoned removal markers (`42`, a string, an array): every row
    /// must still read. Source: VideoScanTests/RemovalMarkerMigrationTests.swift
    /// `aPoisonedCatalogFileStillLoadsEveryRow` (its random ids fixed here).
    static let v6Poisoned = #"""
    {"version": 6, "records": [
      {"id":"AAAAAAAA-0000-4000-8000-000000000001","filename":"a.mov","fullPath":"/x/a.mov","removal":{"state":42}},
      {"id":"AAAAAAAA-0000-4000-8000-000000000002","filename":"b.mov","fullPath":"/x/b.mov","purgedAt":"2023-11-14T22:13:20Z","removal":"nonsense"},
      {"id":"AAAAAAAA-0000-4000-8000-000000000003","filename":"c.mov","fullPath":"/x/c.mov","archiveStage":"Manually Deleted","removal":[]}
    ]}
    """#

    /// One row with ALL 129 keys: the v6 golden plus the 43 keys it lacks
    /// (shapes from contract §b). Composed for this suite.
    static let full129Record = #"{"archiveFixity":{"algorithm":"sha256","digest":"9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08","sizeBytes":123456789,"verifiedAt":"2026-08-15T00:00:00Z"},"archiveStage":"Backed Up","archivedAt":"2026-08-15T00:00:05Z","audioChannels":"2","audioCodec":"pcm_s16le","audioFingerprint":{"analyzedSeconds":60.5,"bytes":9600,"complete":true,"computedAt":"2026-10-14T00:00:00Z","contentDigest":"sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08","engineVersion":3,"landmarks":1200,"outcome":"fingerprinted","sizeBytes":123456789},"audioSampleRate":"48000","audioTranscript":"happy birthday matt","audioTranscriptDate":"2026-06-04T01:00:00Z","audioTranscriptModel":"whisper-medium-mlx-q4","audioVerifyDate":"2026-09-01T00:00:00Z","audioVerifyNote":"clean","audioVerifyStatus":"ok","auditSeenOn":{"deviceKey":"dk-1","mountFrom":"/dev/disk9s1","seenAt":"2026-10-16T00:00:00Z","volumeUUID":"0A1B2C3D-0000-4000-8000-00000000F1F0"},"avidBinFile":"bin.avb","avidClipName":"Clip 1","avidEditRate":29.97,"avidMaterialUUID":"amu","avidMediaPath":"/avid/media","avidMobID":"mob1","avidMobType":"Master","avidTapeName":"AT","avidTracks":"V1, A1-A2","backupAttestations":[{"answer":"yes","attestedAt":"2026-09-12T20:00:00.123Z","by":"rick","kind":"cloud","label":"Backblaze"}],"backupDestinations":[{"date":"2026-01-01T00:00:00Z","kind":"Local","name":"LTA_Crucial"}],"bitDepth":"8","cleanupRecipeID":"denoise-1","cleanupRecipeVersion":2,"colorSpace":"bt601","combinedFromPairID":"66666666-6666-6666-6666-666666666666","confirmedByUserPeople":[{"confirmedAt":"2026-04-12T00:00:00Z","name":"Donna"}],"container":"mov","contentFixity":{"algorithm":"sha256","byteCount":123456789,"computedAt":"2026-09-20T00:00:00Z","digest":"9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08","stamp":{"ctimeNs":1700000000000000001,"device":16777220,"inode":4242,"mtimeNs":1700000000000000000,"size":123456789,"volumeUUID":"0A1B2C3D-0000-4000-8000-00000000F1F0"}},"contentHash":"","contentHashAt":"2026-05-01T00:00:00Z","dateCreated":"1991-06-21","dateCreatedRaw":"1991-06-21T12:00:00Z","dateModified":"1991-06-22","dateModifiedRaw":"1991-06-22T12:00:00Z","derivationKind":"trim","derivedFrom":"55555555-AAAA-BBBB-CCCC-555555555555","detectedPeople":["Donna"],"directory":"/Volumes/T","dossierProcessedAt":"2026-06-04T00:00:00Z","dossierProcessedBy":"qwen+whisper","drmProtected":true,"dupAnalyzedAt":"2026-07-01T00:00:00Z","duplicateBestMatchFilename":"other.mov","duplicateConfidence":"Medium","duplicateDisposition":"Keep","duplicateGroupCount":2,"duplicateGroupID":"77777777-7777-7777-7777-777777777777","duplicateReasons":"same md5","duration":"00:01:00","durationSeconds":60.5,"embeddedCreationDate":"1991-06-21T12:00:00Z","embeddedCreationSource":"com.apple.quicktime.creationdate","ext":"mov","familyMusic":{"markedAt":"2026-09-23T00:00:00Z","performer":"Donna","title":"Danny Boy"},"filename":"clip.mov","footage":{"algorithmVersion":1,"confidence":"strong","evidence":["sound"],"groupID":"12121212-1212-1212-1212-121212121212","groupSize":2,"originalInCatalog":true,"rank":1,"role":"original","scannedAt":"2026-09-23T00:00:00Z"},"footageDecisions":[{"decidedAt":"2026-09-24T00:00:00Z","otherID":"13131313-1313-1313-1313-131313131313","verdict":"same"}],"frameRate":"29.97","fullPath":"/Volumes/T/clip.mov","id":"11111111-2222-3333-4444-555555555555","inferredDateConfidence":0.95,"inferredDateRange":{"endYear":1991,"startYear":1990},"inferredDateReason":"on-screen burn-in","inferredDateSource":"catch-up","inferredRecordDate":"1991-06-21T00:00:00Z","isPlayable":"Yes","junkReasons":["short"],"junkScore":3,"lifecycleStage":"Cataloged","masterLocation":"Mac Studio SSD","materialPackageUMID":"0x060A2B34","materialPackageName":"00002","isAvidRender":true,"mediaDisposition":"Important","mediaReportCard":{"checkedAt":"2026-10-07T00:00:00Z","checks":[],"fileSizeBytes":123456789,"headline":"plays cleanly","tier":"quick"},"needsReformat":true,"notes":"birthday","ocrDateCandidates":[{"text":"JUN.21 1991","timestamp":2}],"ocrText":[{"text":"Happy Birthday","timestamp":3}],"originEncoder":"Lavf58","originMake":"Sony","originModel":"DCR-TRV900","originVolume":"OldDrive","originalFullPath":"/Volumes/Old/clip.mov","pairConfidence":"High","pairGroupID":"88888888-8888-8888-8888-888888888888","pairedWithID":"99999999-9999-9999-9999-999999999999","partialMD5":"ABC123","perceptualFingerprint":{"algorithmVersion":1,"computedAt":"2026-09-30T00:00:00Z","durationSeconds":60.5,"hashesBase64":"AAAAAAAAAAE=","sizeBytes":123456789},"proAppsMediaIdentifier":"PAMI-1","purgedAt":"2026-06-01T00:00:00Z","rejectedPeople":["Anna"],"removal":{"reason":"legacyPurged","since":"2026-06-01T00:00:00Z","state":"removedFromCatalog"},"removalRevision":1,"repairConfirmedDate":"2026-09-02T00:00:00Z","resolution":"720x480","scanContext":{"remoteServerName":"macpro.local","scanHost":"MacStudio","scanRootLabel":"Movies","scannedAt":"2026-05-01T00:00:00Z","volumeMountType":"smbfs","volumeName":"MyBook3Terabytes","volumeUUID":"VU-1"},"scanType":"interlaced","sceneCaptionDate":"2026-05-22T00:00:00Z","sceneCaptionModel":"qwen2.5-vl-3b-4bit","sceneCaptions":[{"text":"a man playing guitar","timestamp":1.5}],"setAsideReason":"systemArtifact","size":"1.2 GB","sizeBytes":123456789,"sourceHost":"MacStudio","starRating":2,"streamTypeRaw":"Video+Audio","supersededByID":"14141414-1414-1414-1414-141414141414","suspectedPeople":["Tim"],"tags":["Birthday","Keep"],"tapeName":"Tape1","timecode":"01:00:00:00","totalBitrate":"9 Mb/s","trimInSeconds":1.5,"trimOutSeconds":42.5,"userDate":"1991-06","userDateConfidence":"known","userNotes":"Matt's 5th birthday","userPlace":"Dublin, Ireland","userPlaceConfidence":"estimated","videoBitrate":"8 Mb/s","videoCodec":"h264","videoVerifyDate":"2026-09-23T00:00:00Z","videoVerifyNote":"","videoVerifyStatus":"warning","workspaceActive":true}"#

    static let full129 = #"{"version":6,"generation":7,"records":["# + full129Record + "]}"

    /// (name, json, expected header version, expected row count)
    static let all: [(name: String, json: String, version: Int, rows: Int)] = [
        ("v1", v1, 1, 0),
        ("v2", v2, 2, 2),
        ("v2NumericSavedAt", v2NumericSavedAt, 2, 1),
        ("v3", v3, 3, 1),
        ("v4", v4, 4, 0),
        ("v5", v5, 5, 1),
        ("v6", v6, 6, 1),
        ("v6Poisoned", v6Poisoned, 6, 3),
        ("full129", full129, 6, 1),
    ]
}
