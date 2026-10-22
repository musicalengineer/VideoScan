// VideoRecord+Loaded.swift
// The record a SQLite load gives back for one `files` row — the exact
// reverse of the importer's mapping (CatalogRecordDTO.init(record:) and its
// row builders), field by field per the contract's §a Fate table (cutover
// B1, docs/design/catalog_cutover_f_prime_2026_10_17.md §2). The app's
// `VideoRecord.init(row:)` calls this, then fills the four display strings
// with its own formatters.
//
// Why typed assignments and not "rebuild the JSON row, run the decoder":
// the decoder path cost ≈ 36 µs a row in Debug (a 130-entry dictionary plus
// the Codable machinery) — 3.6 s of a 100k-row load on its own. The
// round-trip sensor (CatalogLoadRoundTripTests) holds this mapping to the
// importer's, class by class, so the two cannot drift silently.
//
// What does NOT come back, by design (contract §a "drop" / not stored):
//   size, duration, dateCreated, dateModified — display copies (the app
//     recomputes them); junkScore, junkReasons — the analyzer recomputes;
//   a contentFixity that was not the digest's source, a `v1:` sound stamp,
//     a contentHash that is not `v1:` — kept by the importer only as
//     quarantine / raw evidence (§e, §f).
//
// Order matters once: `fullPath`'s didSet clears the audit stamp, so the
// path is set before the stamp (a decoder runs no observers; a convenience
// init after `self.init(id:)` does).
//
// (For Rick: a converting constructor from the row struct — each helper
// below fills one group of members, like an init list split by topic.)

import Foundation

extension VideoRecord {

    /// Why a stored row could not become a record (words for the person).
    public struct LoadedRowFailure: Error, Equatable, CustomStringConvertible {
        public let rowID: String
        public let words: String
        public var description: String { "row \(rowID): \(words)" }
    }

    public convenience init(loaded row: CatalogLoadedRow) throws {
        guard let id = UUID(uuidString: row.file.id) else {
            throw LoadedRowFailure(rowID: row.file.id, words: "its id is not a UUID")
        }
        self.init(id: id)
        applyFileColumns(row.file, volume: row.volume)
        applyProbeExtra(row.file)
        applyIdentityEvidence(row)
        applyShown(row.shown)
        applyRelations(row)
        do {
            try applyRowKnowledge(row.rowKnowledge)
            try applyDerived(row.derived)
        } catch {
            throw LoadedRowFailure(rowID: row.file.id, words: "a stored value no longer decodes: \(error)")
        }
    }

    // MARK: files columns

    private func applyFileColumns(_ f: CatalogRecordDTO.FileRow, volume: CatalogRecordDTO.VolumeRowDTO) {
        filename = f.filename
        ext = f.ext
        fullPath = f.fullPath
        directory = f.directory
        sizeBytes = f.sizeBytes
        streamTypeRaw = f.streamType
        durationSeconds = f.durationS
        dateCreatedRaw = Self.date(f.fsCreatedAt)
        dateModifiedRaw = Self.date(f.fsModifiedAt)
        container = f.container
        videoCodec = f.videoCodec
        audioCodec = f.audioCodec
        partialMD5 = f.partialMD5 ?? ""
        contentHash = f.sampledHash ?? ""
        contentHashAt = Self.date(f.sampledHashAt)
        embeddedCreationDate = Self.date(f.embeddedCreatedAt)
        embeddedCreationSource = f.embeddedCreatedSource
        originalFullPath = f.originalFullPath
        originVolume = f.originVolume
        notes = f.machineNotes
        sourceHost = f.sourceHost
        lifecycleStage = LifecycleStage(rawValue: f.lifecycle) ?? .cataloged
        archiveStage = ArchiveStage(rawValue: f.archiveStage) ?? .none
        masterLocation = f.masterLocation
        setAsideReason = f.setAsideReason
        needsReformat = f.needsReformat
        workspaceActive = f.workspaceActive
        removalRevision = f.removalRevision
        var context = ScanContext()
        context.scanHost = f.scanHost
        context.volumeUUID = f.volumeUUID
        context.volumeMountType = volume.mountType
        context.volumeName = volume.lastName
        context.remoteServerName = volume.remoteServer
        context.scannedAt = Self.date(f.scannedAt)
        context.scanRootLabel = f.scanRootLabel
        context.bundleContainer = f.bundleContainer
        scanContext = context
    }

    // MARK: probe_extra (§a `X`), by key

    private static let probeStrings: [(String, ReferenceWritableKeyPath<VideoRecord, String>)] = [
        ("resolution", \.resolution), ("frameRate", \.frameRate), ("videoBitrate", \.videoBitrate),
        ("totalBitrate", \.totalBitrate), ("colorSpace", \.colorSpace), ("bitDepth", \.bitDepth), ("scanType", \.scanType),
        ("audioChannels", \.audioChannels), ("audioSampleRate", \.audioSampleRate), ("timecode", \.timecode),
        ("tapeName", \.tapeName), ("isPlayable", \.isPlayable), ("avidClipName", \.avidClipName), ("avidMobID", \.avidMobID),
        ("avidMaterialUUID", \.avidMaterialUUID), ("avidBinFile", \.avidBinFile), ("avidMobType", \.avidMobType),
        ("avidMediaPath", \.avidMediaPath), ("avidTapeName", \.avidTapeName), ("avidTracks", \.avidTracks),
        ("materialPackageUMID", \.materialPackageUMID),
        ("materialPackageName", \.materialPackageName),
    ]

    private static let probeOptionalStrings: [(String, ReferenceWritableKeyPath<VideoRecord, String?>)] = [
        ("originMake", \.originMake), ("originModel", \.originModel), ("originEncoder", \.originEncoder),
        ("proAppsMediaIdentifier", \.proAppsMediaIdentifier),
    ]

    private func applyProbeExtra(_ f: CatalogRecordDTO.FileRow) {
        let extra = f.probeExtra
        guard !extra.isEmpty else { return }
        for (key, path) in Self.probeStrings { if let s = extra[key]?.stringValue { self[keyPath: path] = s } }
        for (key, path) in Self.probeOptionalStrings { if let s = extra[key]?.stringValue { self[keyPath: path] = s } }
        avidEditRate = extra["avidEditRate"]?.doubleValue ?? 0
        drmProtected = extra["drmProtected"]?.boolValue ?? false
        isAvidRender = extra["isAvidRender"]?.boolValue ?? false
        // The importer moved a lone embedded date or source here (the DDL
        // wants both or neither in the columns); it comes back as it was.
        if f.embeddedCreatedAt == nil, let text = extra["embeddedCreationDate"]?.stringValue {
            embeddedCreationDate = CatalogJSONDate.parse(text).flatMap { Self.date($0) }
        }
        if f.embeddedCreatedSource == nil, let source = extra["embeddedCreationSource"]?.stringValue {
            embeddedCreationSource = source
        }
    }

    // MARK: fixities, archive copy, removal marker, audit stamp, sound print

    private func applyIdentityEvidence(_ row: CatalogLoadedRow) {
        let f = row.file
        if let digest = f.contentDigest, f.digestSource != .archiveFixity, let stamp = Self.stamp(f) {
            contentFixity = ContentFixity(digest: digest, byteCount: f.sizeBytes, stamp: stamp,
                                          computedAt: Self.date(f.digestComputedAt) ?? Date(timeIntervalSince1970: 0))
        }
        if let digest = f.contentDigest, let copy = row.archiveCopy {
            archiveFixity = ArchiveFixity(digest: digest, verifiedAt: Date(timeIntervalSince1970: TimeInterval(copy.fixityVerifiedAt)),
                                          sizeBytes: f.sizeBytes)
        }
        archivedAt = Self.date(row.archiveCopy?.archivedAt) ?? Self.date(row.rowKnowledge[.archivedAt])
        removal = RemovalMarker.migrated(stored: Self.marker(f), purgedAt: nil, lifecycleStage: lifecycleStage,
                                         archiveStage: archiveStage, loadedAt: Self.migrationLoadDate)
        if let volume = f.auditSeenVolumeUUID, let at = f.auditSeenAt {
            auditSeenOn = AuditSeenOn(volumeUUID: volume, mountFrom: f.auditSeenMountFrom,
                                      seenAt: Date(timeIntervalSince1970: TimeInterval(at)), deviceKey: f.auditSeenDeviceKey)
        }
        if let p = row.soundPrint, let outcome = AudioFingerprintStamp.Outcome(rawValue: p.outcome) {
            audioFingerprint = AudioFingerprintStamp(computedAt: Date(timeIntervalSince1970: TimeInterval(p.computedAt)),
                                                     engineVersion: p.engineVersion, contentDigest: "sha256:" + p.digest,
                                                     sizeBytes: f.sizeBytes, outcome: outcome, analyzedSeconds: p.analyzedS,
                                                     complete: p.complete, landmarks: p.landmarks, bytes: p.blobBytes)
        }
    }

    /// `FileIdentityStamp` from the `stamp_*` columns (device / inode are
    /// stored as the Int64 bit pattern of the UInt64).
    private static func stamp(_ f: CatalogRecordDTO.FileRow) -> FileIdentityStamp? {
        guard let device = f.stampDevice, let inode = f.stampInode, let mtime = f.stampMtimeNs, let ctime = f.stampCtimeNs else { return nil }
        return FileIdentityStamp(device: UInt64(bitPattern: device), inode: UInt64(bitPattern: inode), size: f.sizeBytes,
                                 mtimeNs: mtime, ctimeNs: ctime, volumeUUID: f.stampVolumeUUID)
    }

    /// The stored marker (the importer already migrated legacy rows).
    private static func marker(_ f: CatalogRecordDTO.FileRow) -> RemovalMarker? {
        guard let state = f.removalState, let since = date(f.removalSince), let reasonWord = f.removalReason else { return nil }
        let reason = RemovalReason(rawValue: reasonWord)
        switch RemovalMarker.State(rawValue: state) {
        case .inTrash:
            var m = RemovalMarker.inTrash(movedAt: since, trashPath: f.removalTrashPath, reason: reason)
            if let emptied = date(f.removalTrashEmptiedAt) { m.noteTrashEmptied(at: emptied) }
            return m
        case .removedFromCatalog:
            return .removedFromCatalog(at: since, reason: reason)
        case .missing:
            return .missing(noticedAt: since, lastSeen: date(f.removalLastSeen), reason: reason)
        case nil:
            return nil
        }
    }

    // MARK: curated: what the content shows (conflicts already emptied)

    private func applyShown(_ s: CatalogLoadedRow.Shown) {
        starRating = s.starRating ?? 0
        userNotes = s.userNotes ?? ""
        mediaDisposition = s.mediaDisposition.flatMap(MediaDisposition.init(rawValue:)) ?? .unreviewed
        userDate = s.userDate?.value
        userDateConfidence = s.userDate?.confidence
        userPlace = s.userPlace?.place
        userPlaceConfidence = s.userPlace?.confidence
        tags = s.tags
        confirmedByUserPeople = s.confirmedPeople.compactMap { p in
            p.confirmedAt.map { ConfirmedTag(name: p.name, confirmedAt: Date(timeIntervalSince1970: TimeInterval($0))) }
        }
        rejectedPeople = s.rejectedPeople
        familyMusic = s.familyMusic.map {
            FamilyMusicInfo(performer: $0.performer, title: $0.title, markedAt: Date(timeIntervalSince1970: TimeInterval($0.markedAt)))
        }
        backupAttestations = s.backupAttestations.compactMap { a in
            guard let kind = BackupAttestation.Kind(rawValue: a.kind), let answer = BackupAttestation.Answer(rawValue: a.answer) else { return nil }
            return BackupAttestation(kind: kind, answer: answer, label: a.label,
                                     attestedAt: Date(timeIntervalSince1970: TimeInterval(a.attestedAt)), by: a.byWhom)
        }
    }

    // MARK: the occurrence's row-scoped knowledge (lineage, supersession)

    private func applyRowKnowledge(_ k: [CatalogDDL.KnowledgeField: CatalogJSONValue]) throws {
        let decoder = CatalogJSONValueDecoder()
        if let lineage = k[.lineage] {
            let value = try decoder.decode(CatalogRecordDTO.LineageValue.self, from: lineage)
            derivedFrom = value.derivedFrom.flatMap(UUID.init(uuidString:))
            derivationKind = value.derivationKind
            cleanupRecipeID = value.cleanupRecipeID
            cleanupRecipeVersion = value.cleanupRecipeVersion
            trimInSeconds = value.trimInSeconds
            trimOutSeconds = value.trimOutSeconds
        }
        supersededByID = k[.supersededByID]?.stringValue.flatMap(UUID.init(uuidString:))
        repairConfirmedDate = Self.date(k[.repairConfirmedDate])
    }

    // MARK: relations (pairs, duplicates, footage decisions, backups)

    private func applyRelations(_ row: CatalogLoadedRow) {
        pendingPairedWithID = row.pair?.pairedWithID.flatMap(UUID.init(uuidString:))
        pairGroupID = row.pair?.pairGroupID.flatMap(UUID.init(uuidString:))
        pairConfidence = row.pair?.pairConfidence.flatMap(PairConfidence.init(rawValue:))
        combinedFromPairID = row.pair?.combinedFromPairID.flatMap(UUID.init(uuidString:))
        if let d = row.duplicate {
            duplicateGroupID = UUID(uuidString: d.groupID)
            duplicateConfidence = d.confidence.flatMap(DuplicateConfidence.init(rawValue:))
            duplicateDisposition = DuplicateDisposition(rawValue: d.disposition) ?? .none
            duplicateReasons = d.reasons
            duplicateBestMatchFilename = d.bestMatch
            dupAnalyzedAt = Self.date(d.analyzedAt)
            duplicateGroupCount = row.duplicateGroupCount
        }
        footageDecisions = row.footageDecisions.compactMap { d in
            guard let other = UUID(uuidString: d.otherRowID), let verdict = FootageDecision.Verdict(rawValue: d.verdict) else { return nil }
            return FootageDecision(otherID: other, verdict: verdict, decidedAt: Date(timeIntervalSince1970: TimeInterval(d.decidedAt)))
        }
        backupDestinations = row.backupDestinations.compactMap { b in
            BackupEntry.BackupKind(rawValue: b.kind).map {
                BackupEntry(name: b.name, kind: $0, date: Date(timeIntervalSince1970: TimeInterval(b.recordedAt)))
            }
        }
    }

    // MARK: derived values — back to their JSON keys, then typed

    private func applyDerived(_ rows: [CatalogRecordDTO.DerivedValueRow]) throws {
        guard !rows.isEmpty else { return }
        let raw = DerivedMembers(CatalogRecordDTO.rawMembers(of: rows))
        sceneCaptions = try raw[.sceneCaptions] ?? []
        sceneCaptionModel = try raw[.sceneCaptionModel]
        sceneCaptionDate = try raw[.sceneCaptionDate]
        ocrDateCandidates = try raw[.ocrDateCandidates] ?? []
        ocrText = try raw[.ocrText] ?? []
        inferredRecordDate = try raw[.inferredRecordDate]
        inferredDateConfidence = try raw[.inferredDateConfidence]
        inferredDateSource = try raw[.inferredDateSource]
        inferredDateRange = try raw[.inferredDateRange]
        inferredDateReason = try raw[.inferredDateReason]
        dossierProcessedAt = try raw[.dossierProcessedAt]
        dossierProcessedBy = try raw[.dossierProcessedBy]
        audioTranscript = try raw[.audioTranscript]
        audioTranscriptModel = try raw[.audioTranscriptModel]
        audioTranscriptDate = try raw[.audioTranscriptDate]
        audioVerifyStatus = try raw[.audioVerifyStatus] ?? ""
        audioVerifyNote = try raw[.audioVerifyNote] ?? ""
        audioVerifyDate = try raw[.audioVerifyDate]
        videoVerifyStatus = try raw[.videoVerifyStatus] ?? ""
        videoVerifyNote = try raw[.videoVerifyNote] ?? ""
        videoVerifyDate = try raw[.videoVerifyDate]
        detectedPeople = try raw[.detectedPeople] ?? []
        suspectedPeople = try raw[.suspectedPeople] ?? []
        perceptualFingerprint = try raw[.perceptualFingerprint]
        footage = try raw[.footage]
        // A card a newer build wrote reads as absent, as the JSON decoder does.
        mediaReportCard = try? raw[.mediaReportCard] as MediaReportCard?
    }

    // MARK: value shapes

    static func date(_ seconds: Int64?) -> Date? {
        seconds.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    static func date(_ value: CatalogJSONValue?) -> Date? {
        date(value?.stringValue.flatMap(CatalogJSONDate.parse))
    }
}

/// The derived values' JSON members, decoded on demand by key.
private struct DerivedMembers {
    let raw: [String: CatalogJSONValue]

    init(_ raw: [String: CatalogJSONValue]) { self.raw = raw }

    subscript<T: Decodable>(key: VideoRecordJSON.Key) -> T? {
        get throws {
            guard let value = raw[key.rawValue], value != .null else { return nil }
            return try CatalogJSONValueDecoder().decode(T.self, from: value)
        }
    }
}
