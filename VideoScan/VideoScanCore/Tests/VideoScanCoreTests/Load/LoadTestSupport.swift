// LoadTestSupport.swift — shared by the Load suites (cutover B1).
//   * `AppCatalogCoding`: the app's catalog.json coders (CatalogStore.swift
//     — JSONEncoder / JSONDecoder with `.iso8601` dates), so a test can say
//     "the bytes the app writes" and "the record the app reads".
//   * `KeptFields`: the DTO compared field CLASS by field class, with only
//     what the contract does not keep set aside (raw / undecodable — the
//     quarantine evidence; probe-extra members at their type's default —
//     §a "absent ≡ default"; `removal.migrated` — import bookkeeping, not
//     stored) and set-like arrays compared as sets (§a "Precision").
//   * `RichRecord`: one record with every one of the 129 keys carrying a
//     non-default value the DDL can hold.
//   * `LoadedCatalog`: import → CatalogLoad.read → `VideoRecord(loaded:)` per
//     row → pairs rewired (what the app's SQLiteCatalogLoader does, minus the
//     display strings).

import Foundation
import Testing
@testable import VideoScanCore

enum AppCatalogCoding {
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// The app's reading of a catalog.json row object.
    static func record(_ row: CatalogJSONValue) throws -> VideoRecord {
        try decoder().decode(VideoRecord.self, from: CatalogJSONValue.makeEncoder().encode(row))
    }

    /// The importer's reading of a catalog.json row object.
    static func json(_ row: CatalogJSONValue) throws -> VideoRecordJSON {
        try VideoRecordJSON.makeDecoder().decode(VideoRecordJSON.self, from: CatalogJSONValue.makeEncoder().encode(row))
    }

    /// The row object the app writes for `record`.
    static func row(_ record: VideoRecord) throws -> CatalogJSONValue {
        try JSONDecoder().decode(CatalogJSONValue.self, from: encoder().encode(VideoRecordDTO(record)))
    }
}

// MARK: - Kept fields, by class

enum KeptFields {

    /// The DTO with what the contract does not keep set aside and set-like arrays sorted.
    static func normalized(_ d: CatalogRecordDTO) -> CatalogRecordDTO {
        var k = d
        k.raw = [:]
        k.undecodable = []
        k.file.probeExtra = k.file.probeExtra.filter { !isDefault($0.value) }
        k.removal?.migrated = false
        k.backupDestinations.sort { ($0.name, $0.recordedAt) < ($1.name, $1.recordedAt) }
        k.curated.tags.sort()
        k.curated.people.sort { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) }
        k.curated.backupAttestations.sort { ($0.kind, $0.attestedAt) < ($1.kind, $1.attestedAt) }
        k.curated.footageDecisions.sort { ($0.otherRowID, $0.decidedAt) < ($1.otherRowID, $1.decidedAt) }
        k.knowledgeSources = k.knowledgeSources.map(sortedSetValue)
        return k
    }

    private static func isDefault(_ v: CatalogJSONValue) -> Bool {
        switch v {
        case .string(let s): return s.isEmpty
        case .int(let i): return i == 0
        case .double(let d): return d == 0
        case .bool(let b): return !b
        case .null: return true
        default: return false
        }
    }

    private static let setFields: Set<CatalogDDL.KnowledgeField> = [.tags, .confirmedByUserPeople, .rejectedPeople,
                                                                     .backupAttestations, .footageDecisions]

    private static func sortedSetValue(_ row: CatalogRecordDTO.KnowledgeSourceRow) -> CatalogRecordDTO.KnowledgeSourceRow {
        guard setFields.contains(row.field), let items = row.valueJSON.arrayValue else { return row }
        var sorted = row
        sorted.valueJSON = .array(items.sorted { $0.canonicalText() < $1.canonicalText() })
        return sorted
    }

    /// The field classes of the contract's §a, each compared on its own.
    static func classes(_ a: CatalogRecordDTO, _ b: CatalogRecordDTO) -> [(name: String, equal: Bool)] {
        let x = normalized(a)
        let y = normalized(b)
        return [
            ("files columns (§a col)", fileColumns(x.file) == fileColumns(y.file)),
            ("probe_extra (§a X)", x.file.probeExtra == y.file.probeExtra),
            ("digest + content", x.digestState == y.digestState && x.content == y.content),
            ("volume (scanContext)", x.volume == y.volume),
            ("contentFixity", x.contentFixity == y.contentFixity),
            ("archiveFixity", x.archiveFixity == y.archiveFixity),
            ("removal marker", x.removal == y.removal),
            ("audit stamp", x.auditStamp == y.auditStamp),
            ("archive copy", x.archiveCopy == y.archiveCopy),
            ("backup destinations", x.backupDestinations == y.backupDestinations),
            ("sound print (bound)", x.soundPrint == y.soundPrint),
            ("curated (§10b)", x.curated == y.curated),
            ("curated field list", x.curatedFields == y.curatedFields),
            ("knowledge sources", x.knowledgeSources == y.knowledgeSources),
            ("derived (unverified)", x.derivedUnverified == y.derivedUnverified),
            ("regen context", x.regenContext == y.regenContext),
            ("legacy pair ids", x.legacyPairIDs == y.legacyPairIDs),
            ("duplicate member", x.duplicateMember == y.duplicateMember),
        ]
    }

    /// The `files` row without probe_extra (its own class).
    private static func fileColumns(_ f: CatalogRecordDTO.FileRow) -> CatalogRecordDTO.FileRow {
        var c = f
        c.probeExtra = [:]
        return c
    }
}

// MARK: - A record with every key set

enum RichRecord {

    static let at = Date(timeIntervalSince1970: 1_790_000_000)
    static func day(_ n: Double) -> Date { at.addingTimeInterval(n * 86_400) }

    /// Every one of the 129 keys non-default. `digest` is the whole-file
    /// SHA-256 both fixities name; the audit stamp is inside the poisoned
    /// fixture's audit window so the row lands in `files`.
    static func make(id: UUID, path: String, digest: String, sizeBytes: Int64, pairWith: UUID, otherRow: UUID) -> VideoRecord {
        let r = VideoRecord(id: id)
        identity(r, path: path, sizeBytes: sizeBytes)
        probe(r)
        fixity(r, digest: digest, sizeBytes: sizeBytes)
        curated(r, otherRow: otherRow)
        derived(r, sizeBytes: sizeBytes, otherRow: otherRow)
        relations(r, pairWith: pairWith, digest: digest, sizeBytes: sizeBytes)
        return r
    }

    private static func identity(_ r: VideoRecord, path: String, sizeBytes: Int64) {
        r.filename = (path as NSString).lastPathComponent
        r.ext = "mov"
        r.fullPath = path
        r.directory = (path as NSString).deletingLastPathComponent
        r.sizeBytes = sizeBytes
        r.size = "4 KB"
        r.durationSeconds = 63.5
        r.duration = "00:01:03"
        r.dateCreated = "2026-09-01 10:00:00"
        r.dateModified = "2026-09-02 10:00:00"
        r.dateCreatedRaw = day(-30)
        r.dateModifiedRaw = day(-29)
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.notes = "Promote 2026-09-01: machine note"
        r.sourceHost = "FixtureHost"
        r.originalFullPath = "/Volumes/Old/Clips/rich.mov"
        r.originVolume = "Old"
        r.lifecycleStage = .reviewing
        r.archiveStage = .masterAssigned
        r.masterLocation = "Mac Studio SSD"
        r.setAsideReason = "damaged"
        r.needsReformat = true
        r.workspaceActive = true
        r.scanContext = ScanContext()
        r.scanContext.scanHost = "FixtureHost"
        r.scanContext.volumeUUID = PoisonedCatalogFixture.volumeUUID
        r.scanContext.volumeName = "Fixture"
        r.scanContext.volumeMountType = "local"
        r.scanContext.scannedAt = day(-20)
        r.scanContext.scanRootLabel = "Clips"
    }

    private static func probe(_ r: VideoRecord) {
        r.container = "mov,mp4,m4a"; r.videoCodec = "prores"; r.audioCodec = "pcm_s24le"
        r.resolution = "1920x1080"; r.frameRate = "29.97"; r.videoBitrate = "120 Mb/s"; r.totalBitrate = "122 Mb/s"
        r.colorSpace = "bt709"; r.bitDepth = "10"; r.scanType = "progressive"; r.audioChannels = "2"
        r.audioSampleRate = "48000"; r.timecode = "01:00:00:00"; r.tapeName = "TAPE 7"; r.isPlayable = "Yes"
        r.partialMD5 = "0123456789abcdef0123456789abcdef"
        r.contentHash = "v1:" + String(repeating: "c", count: 64)
        r.contentHashAt = day(-25)
        r.embeddedCreationDate = day(-400)
        r.embeddedCreationSource = "format:creation_time"
        r.originMake = "Sony"; r.originModel = "HDR-FX1"; r.originEncoder = "Lavf60"
        r.avidClipName = "Clip 7"; r.avidMobID = "mob-7"; r.avidMaterialUUID = "mat-7"; r.avidBinFile = "Bin.avb"
        r.avidMobType = "MasterMob"; r.avidMediaPath = "/Avid MediaFiles/MXF/1"; r.avidTapeName = "TAPE 7"
        r.avidEditRate = 29.97; r.avidTracks = "V1, A1-A2"; r.materialPackageUMID = "060a2b34-umid"
        r.drmProtected = true
        r.proAppsMediaIdentifier = "pro-apps-7"
    }

    private static func fixity(_ r: VideoRecord, digest: String, sizeBytes: Int64) {
        let stamp = FileIdentityStamp(device: 16_777_220, inode: 4_242, size: sizeBytes, mtimeNs: 1_700_000_000_000_000_000,
                                      ctimeNs: 1_700_000_000_000_000_001, volumeUUID: PoisonedCatalogFixture.volumeUUID)
        r.contentFixity = ContentFixity(digest: digest, byteCount: sizeBytes, stamp: stamp, computedAt: day(-3))
        r.archiveFixity = ArchiveFixity(digest: digest, verifiedAt: day(-2), sizeBytes: sizeBytes)
        r.archivedAt = day(-2)
        r.auditSeenOn = AuditSeenOn(volumeUUID: PoisonedCatalogFixture.volumeUUID, mountFrom: "/dev/disk9s1",
                                    seenAt: Date(timeIntervalSince1970: TimeInterval(PoisonedCatalogFixture.seenAt)),
                                    deviceKey: "16777220")
    }

    private static func curated(_ r: VideoRecord, otherRow: UUID) {
        r.userNotes = "Donna at the lake"
        r.tags = ["Gold", "Follow Up"]
        r.mediaDisposition = .important
        r.starRating = 3
        r.confirmedByUserPeople = [ConfirmedTag(name: "Donna", confirmedAt: day(-10)), ConfirmedTag(name: "Matt", confirmedAt: day(-9))]
        r.rejectedPeople = ["Eileen"]
        r.userDate = "1990-06"
        r.userDateConfidence = "estimated"
        r.userPlace = "Middlefield"
        r.userPlaceConfidence = "known"
        r.backupAttestations = [BackupAttestation(kind: .cloud, answer: .yes, label: "Backblaze", attestedAt: day(-8), by: "rick")]
        r.familyMusic = FamilyMusicInfo(performer: "Rick", title: "Lake Song", markedAt: day(-7))
        r.footageDecisions = [FootageDecision(otherID: otherRow, verdict: .same, decidedAt: day(-6))]
        r.supersededByID = otherRow
        r.repairConfirmedDate = day(-5)
        r.derivedFrom = otherRow
        r.derivationKind = "trim"
        r.trimInSeconds = 1.5
        r.trimOutSeconds = 9.25
    }

    private static func derived(_ r: VideoRecord, sizeBytes: Int64, otherRow: UUID) {
        r.sceneCaptions = [SceneCaption(timestamp: 1.5, text: "a lake"), SceneCaption(timestamp: 4, text: "a dock")]
        r.sceneCaptionModel = "qwen2.5-vl"
        r.sceneCaptionDate = day(-4)
        r.ocrDateCandidates = [SceneCaption(timestamp: 2, text: "JUN 1990")]
        r.ocrText = [SceneCaption(timestamp: 3, text: "Lake Garfield")]
        r.inferredRecordDate = day(-12_000)
        r.inferredDateConfidence = 0.7
        r.inferredDateSource = "propagated from \(otherRow.uuidString)"
        r.inferredDateRange = InferredDateRange(startYear: 1989, endYear: 1991)
        r.inferredDateReason = "OCR date on the title card"
        r.dossierProcessedAt = day(-4)
        r.dossierProcessedBy = "dossier v3"
        r.audioTranscript = "happy birthday"
        r.audioTranscriptModel = "whisper-large-v3"
        r.audioTranscriptDate = day(-4)
        r.audioVerifyStatus = "ok"; r.audioVerifyNote = "clean"; r.audioVerifyDate = day(-3)
        r.videoVerifyStatus = "warning"; r.videoVerifyNote = "a dropped frame"; r.videoVerifyDate = day(-3)
        r.detectedPeople = ["Donna", "Matt"]
        r.suspectedPeople = ["Timothy"]
        r.perceptualFingerprint = StoredPerceptualFingerprint(hashes: [1, 2, 3], sizeBytes: sizeBytes, durationSeconds: 63.5,
                                                              computedAt: day(-4))
        r.footage = FootageMembership(groupID: otherRow, groupSize: 2, confidence: .identical, role: .original, rank: 0,
                                      likelyOriginalID: r.id, originalInCatalog: true, evidence: ["same bytes"],
                                      scannedAt: day(-4), algorithmVersion: 1)
        r.mediaReportCard = MediaReportCard(tier: .full, checkedAt: day(-3), fileSizeBytes: sizeBytes, headline: "Plays clean",
                                            checks: [MediaCheck(kind: MediaCheckKind.allCases[0], verdict: .notRun(reason: "fixture"),
                                                                sentence: "Not checked — fixture.", evidence: [MediaEvidence("a", "b")])],
                                            measuredPictureSeconds: 63.4)
    }

    private static func relations(_ r: VideoRecord, pairWith: UUID, digest: String, sizeBytes: Int64) {
        r.pairedWith = VideoRecord(id: pairWith)
        r.pairGroupID = UUID(uuidString: PoisonedCatalogFixture.pairGroupID)
        r.pairConfidence = .high
        r.combinedFromPairID = UUID(uuidString: "0A1B2C3D-0000-4000-8000-00000000AA77")
        r.duplicateGroupID = UUID(uuidString: "0A1B2C3D-0000-4000-8000-00000000DD01")
        r.duplicateConfidence = .high
        r.duplicateDisposition = .keep
        r.duplicateReasons = "hash,size"
        r.duplicateBestMatchFilename = "other.mov"
        r.duplicateGroupCount = 1
        r.dupAnalyzedAt = day(-5)
        r.junkScore = 4
        r.junkReasons = ["short"]
        r.backupDestinations = [BackupEntry(name: "Offsite drive", kind: .offsite, date: day(-6))]
        r.audioFingerprint = AudioFingerprintStamp(computedAt: day(-3), contentDigest: "sha256:" + digest, sizeBytes: sizeBytes,
                                                   outcome: .fingerprinted, analyzedSeconds: 63.5, complete: true,
                                                   landmarks: 812, bytes: 6_496)
    }
}

// MARK: - Import → load

struct LoadedCatalog {
    let snapshot: CatalogLoad.Snapshot
    /// By id, each built by `VideoRecord(loaded:)`.
    let records: [String: VideoRecord]
    /// The store read (display pass + snapshot) and the record build, timed apart.
    var readDuration: Duration = .zero
    var buildDuration: Duration = .zero

    /// Load the scene's committed catalog.sqlite through the seam.
    static func load(_ scene: ImporterScene) async throws -> LoadedCatalog {
        let repository = GRDBCatalogRepository(host: "load-test", durability: .volatileForTests)
        let opened = await repository.open(at: scene.databaseURL)
        guard opened == .readWrite else { throw FixtureFailure(words: "load could not open: \(opened)") }
        do {
            let clock = ContinuousClock()
            let start = clock.now
            let snapshot = try await CatalogLoad.read(repository)
            await repository.close()
            let read = clock.now - start
            var records: [String: VideoRecord] = [:]
            records.reserveCapacity(snapshot.rows.count)
            for row in snapshot.rows {
                let record = try VideoRecord(loaded: row)
                records[row.file.id] = record
            }
            resolvePairs(Array(records.values))
            return LoadedCatalog(snapshot: snapshot, records: records, readDuration: read, buildDuration: clock.now - start - read)
        } catch {
            await repository.close()
            throw error
        }
    }

    /// The DTO of the record the load built for `id`.
    func dto(_ id: String, loadedAt: Int64 = 0) throws -> CatalogRecordDTO {
        let record = try #require(records[id], "no record loaded for \(id)")
        return try CatalogRecordDTO(record: record, migrationLoadedAt: loadedAt)
    }
}

/// `pendingPairedWithID` → `pairedWith`, as CatalogStore's load does: a
/// live record's pair is the object reference (its encoder writes
/// `pairedWith?.id`). An id with no partner in the set stays unresolved.
func resolvePairs(_ records: [VideoRecord]) {
    var byID: [UUID: VideoRecord] = [:]
    for r in records { byID[r.id] = r }
    for r in records {
        guard let id = r.pendingPairedWithID, let partner = byID[id] else { continue }
        r.pairedWith = partner
        r.pendingPairedWithID = nil
    }
}

/// The DTO the importer builds from row `ordinal` of the scene's catalog.json.
func importedDTO(_ scene: ImporterScene, ordinal: Int, loadedAt: Int64 = 0) throws -> CatalogRecordDTO {
    let catalog = try CatalogFileJSON.decode(try Data(contentsOf: scene.inputs.catalogURL))
    return CatalogRecordDTO(record: catalog.records[ordinal], migrationLoadedAt: loadedAt)
}
