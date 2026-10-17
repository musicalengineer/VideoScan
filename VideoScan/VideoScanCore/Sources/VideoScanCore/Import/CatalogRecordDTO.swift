// CatalogRecordDTO.swift
// One catalog.json row occurrence, mapped onto the table-shaped values of
// the frozen contract (docs/design/catalog_contract_freeze_2026_10_17.md,
// schema docs/design/catalog_sqlite_schema_v1.sql v1.3). PURE: no GRDB, no
// SQLite, no file I/O — the GRDB importer (another agent) binds these
// values; this file only decides what each value IS.
//
// Rules carried here, each cited where it bites:
//   * identity = whole-file SHA-256 (`storedFullDigest`, contract §e);
//     sampled `v1:` / partialMD5 are evidence only (§e.1, §e.6);
//   * both fixities present and disagreeing → no digest (§f row 2, F10);
//   * the `purgedAt` → marker migration is the app's (`RemovalMarker
//     .migrated`, contract §a "the only semantic migration");
//   * every curated value is a `knowledge_sources` row, verbatim, read from
//     the RAW row so a value the typed decode could not read still counts
//     (§e.10, F1);
//   * every derived value imports `unverified` except a `sha256:` sound
//     print (§e.8, N2);
//   * nothing is dropped: `raw` is the whole row (quarantine.raw_row).
//
// Property names are the DDL column names in lowerCamelCase
// (`content_digest` → `contentDigest`); value objects that are stored
// verbatim as JSON (`knowledge_sources.value_json`, `derived_unverified
// .value_json`) keep the JSON keys.
//
// (For Rick: plain value structs ≈ C++ PODs, one per table row the
// importer will INSERT; the init is a pure function JSON row → rows.)

import Foundation

public struct CatalogRecordDTO: Codable, Sendable, Equatable {

    // MARK: - Where each of the 129 keys goes (contract §a "Fate")

    public enum Fate: String, Codable, Sendable, Equatable {
        /// A `files` column.
        case column
        /// `files.probe_extra`, by DTO key.
        case probeExtra
        /// A table / evidence column set other than a plain `files` column.
        case table
        /// Display copy of another field; recomputed, not stored.
        case drop
    }

    /// Contract §a Fate = `X`.
    public static let probeExtraKeys: [VideoRecordJSON.Key] = [
        .resolution, .frameRate, .videoBitrate, .totalBitrate, .colorSpace, .bitDepth, .scanType,
        .audioChannels, .audioSampleRate, .timecode, .tapeName, .isPlayable,
        .originMake, .originModel, .originEncoder,
        .avidClipName, .avidMobID, .avidMaterialUUID, .avidBinFile, .avidMobType, .avidMediaPath,
        .avidTapeName, .avidEditRate, .avidTracks, .materialPackageUMID,
        .drmProtected, .proAppsMediaIdentifier,
    ]

    /// Contract §a Fate = `drop` (display copies; `purgedAt` = removal.since).
    public static let droppedKeys: [VideoRecordJSON.Key] = [
        .size, .duration, .dateCreated, .dateModified, .duplicateGroupCount, .junkScore, .junkReasons, .purgedAt,
    ]

    /// Contract §a Fate = `col`.
    public static let columnKeys: [VideoRecordJSON.Key] = [
        .id, .filename, .ext, .streamTypeRaw, .sizeBytes, .durationSeconds, .dateCreatedRaw, .dateModifiedRaw,
        .container, .videoCodec, .audioCodec, .partialMD5, .contentHash, .contentHashAt,
        .embeddedCreationDate, .embeddedCreationSource, .originalFullPath, .originVolume,
        .fullPath, .directory, .notes, .lifecycleStage, .archiveStage, .masterLocation, .sourceHost,
        .removalRevision, .setAsideReason, .needsReformat, .workspaceActive,
    ]

    public static func fate(of key: VideoRecordJSON.Key) -> Fate {
        if probeExtraKeys.contains(key) { return .probeExtra }
        if droppedKeys.contains(key) { return .drop }
        if columnKeys.contains(key) { return .column }
        return .table
    }

    // MARK: - Digest (contract §e, §f "Digest")

    public enum DigestState: Codable, Sendable, Equatable {
        /// No whole-file digest the importer may use as identity.
        case none
        /// `storedFullDigest(r)` (VideoScanModel+Cleanup.swift:124).
        case known(digest: String, source: CatalogDDL.DigestSource)
        /// contentFixity and archiveFixity are both sha256 and differ (§f row 2).
        case disagree(digests: [String])

        public var digest: String? {
            if case .known(let d, _) = self { return d }
            return nil
        }
    }

    // MARK: - Row-shaped values

    /// `files` (DDL §4). `contentDigest == nil` ⇒ this occurrence cannot enter
    /// `files` (§e.2): it goes to `quarantine` with `raw`. `volume_case_sensitive`
    /// is not here: it is a copy of `volumes.case_sensitive`, which the scan
    /// reads from the volume (F12), not the JSON.
    public struct FileRow: Codable, Sendable, Equatable {
        public var id: String
        public var contentDigest: String?
        public var volumeUUID: String
        public var fullPath: String
        /// The app's fold (DDL files.path_fold, N3): NFC, then case folding only.
        public var pathFold: String
        public var filename: String
        public var ext: String
        public var directory: String
        public var sizeBytes: Int64
        public var fsCreatedAt: Int64?
        public var fsModifiedAt: Int64?
        public var stampDevice: Int64?
        public var stampInode: Int64?
        public var stampMtimeNs: Int64?
        public var stampCtimeNs: Int64?
        public var stampVolumeUUID: String?
        public var digestComputedAt: Int64?
        public var digestSource: CatalogDDL.DigestSource?
        public var sampledHash: String?
        public var sampledHashAt: Int64?
        public var partialMD5: String?
        public var streamType: String
        public var durationS: Double
        public var container: String
        public var videoCodec: String
        public var audioCodec: String
        public var embeddedCreatedAt: Int64?
        public var embeddedCreatedSource: String?
        public var probeExtra: [String: CatalogJSONValue]
        public var scanHost: String
        public var scannedAt: Int64?
        public var scanRootLabel: String
        public var bundleContainer: String
        public var sourceHost: String
        public var originalFullPath: String?
        public var originVolume: String?
        public var machineNotes: String
        public var lifecycle: String
        public var archiveStage: String
        public var masterLocation: String
        public var setAsideReason: String?
        public var needsReformat: Bool
        public var workspaceActive: Bool
        public var removalState: String?
        public var removalSince: Int64?
        public var removalReason: String?
        public var removalTrashPath: String?
        public var removalTrashEmptiedAt: Int64?
        public var removalLastSeen: Int64?
        public var removalRevision: Int
        public var auditSeenVolumeUUID: String?
        public var auditSeenMountFrom: String?
        public var auditSeenDeviceKey: String?
        public var auditSeenAt: Int64?
        /// NULL: the JSON carries no catalogued date (§9.2 — never invented).
        public var cataloguedAt: Int64?
    }

    /// `content` (DDL §2).
    public struct ContentRow: Codable, Sendable, Equatable {
        public var digest: String
        public var algorithm: String
        public var byteCount: Int64
        public var firstSeenAt: Int64
        public var firstSeenHow: CatalogDDL.FirstSeenHow
    }

    /// `volumes` (DDL §3), from the row's `scanContext`.
    public struct VolumeRowDTO: Codable, Sendable, Equatable {
        public var volumeUUID: String
        public var lastName: String
        public var mountType: String
        public var remoteServer: String
    }

    /// `contentFixity` as evidence (stamp → `files.stamp_*`).
    public struct ContentFixityEvidence: Codable, Sendable, Equatable {
        public var algorithm: String
        public var digest: String
        public var byteCount: Int64
        public var stampDevice: Int64
        public var stampInode: Int64
        public var stampSize: Int64
        public var stampMtimeNs: Int64
        public var stampCtimeNs: Int64
        public var stampVolumeUUID: String?
        public var computedAt: Int64
    }

    /// `archiveFixity` as evidence (→ `archive_copies.fixity_verified_at`).
    public struct ArchiveFixityEvidence: Codable, Sendable, Equatable {
        public var algorithm: String
        public var digest: String
        public var sizeBytes: Int64
        public var verifiedAt: Int64
    }

    /// The removal marker after the app's load-time migration
    /// (`RemovalMarker.migrated`, C/RemovalMarker.swift:142).
    public struct RemovalMarkerRow: Codable, Sendable, Equatable {
        public var removalState: String
        public var removalSince: Int64
        public var removalReason: String
        public var removalTrashPath: String?
        public var removalTrashEmptiedAt: Int64?
        public var removalLastSeen: Int64?
        /// True when the marker was made by the migration, not read.
        public var migrated: Bool
    }

    /// `auditSeenOn` (→ `files.audit_seen_*`).
    public struct AuditStamp: Codable, Sendable, Equatable {
        public var auditSeenVolumeUUID: String
        public var auditSeenMountFrom: String?
        public var auditSeenDeviceKey: String?
        public var auditSeenAt: Int64
    }

    /// `archive_copies` (DDL §5) for a row carrying `archiveFixity`.
    /// `sourceFileID` is resolved by the importer (NULL while the source is
    /// quarantined); `sourceRowID` is `derivedFrom` verbatim (F1).
    public struct ArchiveCopyRow: Codable, Sendable, Equatable {
        public var sourceRowID: String?
        public var archivedAt: Int64?
        public var fixityVerifiedAt: Int64
        public var promotedBy: CatalogDDL.PromotedBy
    }

    /// `backup_destinations`.
    public struct BackupDestinationRow: Codable, Sendable, Equatable {
        public var name: String
        public var kind: String
        public var recordedAt: Int64
    }

    /// `sound_prints` — only a `sha256:`-keyed stamp (§b, §e.6); the prefix
    /// is stripped.
    public struct SoundPrintRow: Codable, Sendable, Equatable {
        public var digest: String
        public var engineVersion: Int
        public var outcome: String
        public var analyzedS: Double
        public var complete: Bool
        public var landmarks: Int
        public var blobBytes: Int
        public var computedAt: Int64
    }

    // MARK: Curated (§10b) — display-table shapes; the verbatim value is `knowledgeSources`.

    public struct UserDateRow: Codable, Sendable, Equatable {
        public var value: String?
        public var confidence: String?
    }

    public struct UserPlaceRow: Codable, Sendable, Equatable {
        public var place: String?
        public var confidence: String?
    }

    public struct PeopleTagRow: Codable, Sendable, Equatable {
        public var name: String
        public var kind: CatalogDDL.PeopleTagKind
        public var confirmedAt: Int64?
    }

    public struct FamilyMusicRow: Codable, Sendable, Equatable {
        public var performer: String?
        public var title: String?
        public var markedAt: Int64
    }

    public struct BackupAttestationRow: Codable, Sendable, Equatable {
        public var kind: String
        public var answer: String
        public var label: String?
        public var attestedAt: Int64
        public var byWhom: String
    }

    /// `footage_decisions`; the digests are the importer's (both NULL-able, F3).
    public struct FootageDecisionRow: Codable, Sendable, Equatable {
        public var rowID: String
        public var otherRowID: String
        public var verdict: String
        public var decidedAt: Int64
    }

    /// The lineage value, JSON keys verbatim (knowledge_sources 'lineage').
    public struct LineageValue: Codable, Sendable, Equatable {
        public var derivedFrom: String?
        public var derivationKind: String?
        public var cleanupRecipeID: String?
        public var cleanupRecipeVersion: Int?
        public var trimInSeconds: Double?
        public var trimOutSeconds: Double?

        /// Archive promotion copies bytes: it is `archive_copies`, not
        /// content lineage (§e.5).
        public var isArchivePromotion: Bool { derivationKind == "archivePromotion" }

        /// `lineage.kind`: the writer's kind when it is one; cleanup ⇐ a
        /// recipe; otherwise `unrecorded` — never guessed (§b).
        public var kind: CatalogDDL.LineageKind {
            if let k = derivationKind, let known = CatalogDDL.LineageKind(rawValue: k) { return known }
            if cleanupRecipeID != nil { return .cleanup }
            return .unrecorded
        }
    }

    /// One `knowledge_sources` row (without run / ordinal / digest, which the
    /// importer adds): the field, its value verbatim, and its stamp if any.
    public struct KnowledgeSourceRow: Codable, Sendable, Equatable {
        public var field: CatalogDDL.KnowledgeField
        public var valueJSON: CatalogJSONValue
        public var setAt: Int64?
    }

    public struct CuratedKnowledge: Codable, Sendable, Equatable {
        public var userNotes: String?
        public var tags: [String]
        /// nil = 'Unreviewed' (no dispositions row).
        public var mediaDisposition: String?
        /// nil = unrated (0).
        public var starRating: Int?
        public var people: [PeopleTagRow]
        public var userDate: UserDateRow?
        public var userPlace: UserPlaceRow?
        public var backupAttestations: [BackupAttestationRow]
        public var footageDecisions: [FootageDecisionRow]
        public var familyMusic: FamilyMusicRow?
        public var setAsideReason: String?
        public var archivedAt: Int64?
        public var archiveFixity: ArchiveFixityEvidence?
        public var lineage: LineageValue?
        public var supersededByID: String?
        public var repairConfirmedDate: Int64?
        public var mediaReportCard: CatalogJSONValue?
    }

    // MARK: Derived (§10b regenerable) — all imported `unverified` but sha256 sound prints.

    /// One `derived_unverified` row (without digest / source row / run).
    public struct DerivedValueRow: Codable, Sendable, Equatable {
        public var kind: CatalogDDL.DerivedKind
        public var seq: Int
        public var valueJSON: CatalogJSONValue
        public var stampJSON: CatalogJSONValue
    }

    /// `regen_context` (§e.8): folder- and donor-derived dates.
    public struct RegenContextRow: Codable, Sendable, Equatable {
        public var kind: CatalogDDL.RegenKind
        public var valueJSON: CatalogJSONValue
        public var reason: String?
    }

    /// `legacy_pair_ids` (F9); the importer adds the event member keys.
    public struct LegacyPairIDsRow: Codable, Sendable, Equatable {
        public var pairedWithID: String?
        public var pairGroupID: String?
        public var pairConfidence: String?
        public var combinedFromPairID: String?
    }

    /// `duplicate_members` + `duplicate_groups.analyzed_at` (rebuildable).
    public struct DuplicateMemberRow: Codable, Sendable, Equatable {
        public var groupID: String
        public var confidence: String?
        public var disposition: String
        public var reasons: String
        public var bestMatch: String
        public var analyzedAt: Int64?
    }

    // MARK: - The mapped occurrence

    public var file: FileRow
    public var digestState: DigestState
    public var content: ContentRow?
    public var volume: VolumeRowDTO
    public var contentFixity: ContentFixityEvidence?
    public var archiveFixity: ArchiveFixityEvidence?
    public var removal: RemovalMarkerRow?
    public var auditStamp: AuditStamp?
    public var archiveCopy: ArchiveCopyRow?
    public var backupDestinations: [BackupDestinationRow]
    public var soundPrint: SoundPrintRow?
    public var curated: CuratedKnowledge
    /// The §10b fields this occurrence carried (non-default), DDL order —
    /// `import_items.curated_fields`.
    public var curatedFields: [CatalogDDL.KnowledgeField]
    public var knowledgeSources: [KnowledgeSourceRow]
    public var derivedUnverified: [DerivedValueRow]
    public var regenContext: [RegenContextRow]
    public var legacyPairIDs: LegacyPairIDsRow?
    public var duplicateMember: DuplicateMemberRow?
    /// The whole row, verbatim (`quarantine.raw_row`).
    public var raw: [String: CatalogJSONValue]
    /// Keys whose typed decode failed (their value is only in `raw`).
    public var undecodable: [String]

    // MARK: - Mapping

    /// `migrationLoadedAt`: the `since` the app's migration gives a
    /// "Manually Deleted" label with no purge date (it uses the load time,
    /// VideoRecord.swift:884). Pass the import run's start.
    public init(record r: VideoRecordJSON,
                migrationLoadedAt: Int64 = Int64(Date().timeIntervalSince1970)) {
        let sizeBytes = r.sizeBytes ?? 0
        let fullPath = r.fullPath ?? ""

        // Evidence structs.
        let cf: ContentFixityEvidence? = r.contentFixity.map { f in
            ContentFixityEvidence(
                algorithm: f.algorithm, digest: f.digest.lowercased(), byteCount: f.byteCount,
                stampDevice: Int64(bitPattern: f.stamp.device), stampInode: Int64(bitPattern: f.stamp.inode),
                stampSize: f.stamp.size, stampMtimeNs: f.stamp.mtimeNs,
                stampCtimeNs: f.stamp.ctimeNs ?? -1, stampVolumeUUID: f.stamp.volumeUUID,
                computedAt: f.computedAt.unixSeconds)
        }
        let af: ArchiveFixityEvidence? = r.archiveFixity.map { a in
            ArchiveFixityEvidence(algorithm: a.algorithm, digest: a.digest.lowercased(),
                                  sizeBytes: a.sizeBytes, verifiedAt: a.verifiedAt.unixSeconds)
        }
        contentFixity = cf
        archiveFixity = af
        let state = Self.resolveDigest(contentFixity: cf, archiveFixity: af, sizeBytes: sizeBytes)
        digestState = state

        var digestComputedAt: Int64?
        var stampFromContent = false
        if case .known(_, let source) = state {
            switch source {
            case .contentFixity:
                digestComputedAt = cf?.computedAt
                stampFromContent = true
            case .archiveFixity, .rescan:
                digestComputedAt = af?.verifiedAt
            }
        }
        if let digest = state.digest {
            let seen = [cf?.computedAt, af?.verifiedAt].compactMap { $0 }.min() ?? (digestComputedAt ?? 0)
            content = ContentRow(digest: digest, algorithm: "sha256", byteCount: sizeBytes,
                                 firstSeenAt: seen, firstSeenHow: .import)
        } else {
            content = nil
        }

        let ctx = r.scanContext
        let volumeUUID = ctx?.volumeUUID ?? ""
        volume = VolumeRowDTO(volumeUUID: volumeUUID, lastName: ctx?.volumeName ?? "",
                              mountType: ctx?.volumeMountType ?? "", remoteServer: ctx?.remoteServerName ?? "")

        let marker = Self.migratedRemoval(r, loadedAt: migrationLoadedAt)
        removal = marker
        let audit: AuditStamp? = r.auditSeenOn.map {
            AuditStamp(auditSeenVolumeUUID: $0.volumeUUID, auditSeenMountFrom: $0.mountFrom,
                       auditSeenDeviceKey: $0.deviceKey, auditSeenAt: $0.seenAt.unixSeconds)
        }
        auditStamp = audit

        var extra: [String: CatalogJSONValue] = [:]
        for key in Self.probeExtraKeys {
            if let v = r.raw[key.rawValue], v != .null { extra[key.rawValue] = v }
        }

        let sampled = r.contentHash.flatMap { $0.hasPrefix("v1:") ? $0 : nil }
        let stamp = stampFromContent ? cf : nil
        file = FileRow(
            id: Self.canonicalID(r.id),
            contentDigest: state.digest,
            volumeUUID: volumeUUID,
            fullPath: fullPath,
            pathFold: Self.pathFold(fullPath),
            filename: r.filename ?? "",
            ext: r.ext ?? "",
            directory: r.directory ?? "",
            sizeBytes: sizeBytes,
            fsCreatedAt: r.dateCreatedRaw?.unixSeconds,
            fsModifiedAt: r.dateModifiedRaw?.unixSeconds,
            stampDevice: stamp?.stampDevice,
            stampInode: stamp?.stampInode,
            stampMtimeNs: stamp?.stampMtimeNs,
            stampCtimeNs: stamp?.stampCtimeNs,
            stampVolumeUUID: stamp?.stampVolumeUUID,
            digestComputedAt: digestComputedAt,
            digestSource: state.digest == nil ? nil : Self.source(of: state),
            sampledHash: sampled,
            sampledHashAt: sampled == nil ? nil : r.contentHashAt?.unixSeconds,
            partialMD5: (r.partialMD5?.isEmpty ?? true) ? nil : r.partialMD5,
            streamType: r.streamTypeRaw ?? "",
            durationS: r.durationSeconds ?? 0,
            container: r.container ?? "",
            videoCodec: r.videoCodec ?? "",
            audioCodec: r.audioCodec ?? "",
            embeddedCreatedAt: r.embeddedCreationDate?.unixSeconds,
            embeddedCreatedSource: r.embeddedCreationSource,
            probeExtra: extra,
            scanHost: ctx?.scanHost ?? "",
            scannedAt: ctx?.scannedAt?.unixSeconds,
            scanRootLabel: ctx?.scanRootLabel ?? "",
            bundleContainer: ctx?.bundleContainer ?? "",
            sourceHost: r.sourceHost ?? "",
            originalFullPath: r.originalFullPath,
            originVolume: r.originVolume,
            machineNotes: r.notes ?? "",
            lifecycle: r.lifecycleStage ?? CatalogDDL.Lifecycle.cataloged.rawValue,
            archiveStage: r.archiveStage ?? CatalogDDL.ArchiveStage.none.rawValue,
            masterLocation: r.masterLocation ?? "",
            setAsideReason: r.setAsideReason,
            needsReformat: r.needsReformat ?? false,
            workspaceActive: r.workspaceActive ?? false,
            removalState: marker?.removalState,
            removalSince: marker?.removalSince,
            removalReason: marker?.removalReason,
            removalTrashPath: marker?.removalTrashPath,
            removalTrashEmptiedAt: marker?.removalTrashEmptiedAt,
            removalLastSeen: marker?.removalLastSeen,
            removalRevision: r.removalRevision ?? 0,
            auditSeenVolumeUUID: audit?.auditSeenVolumeUUID,
            auditSeenMountFrom: audit?.auditSeenMountFrom,
            auditSeenDeviceKey: audit?.auditSeenDeviceKey,
            auditSeenAt: audit?.auditSeenAt,
            cataloguedAt: nil)

        archiveCopy = af.map { a in
            ArchiveCopyRow(sourceRowID: r.derivedFrom, archivedAt: r.archivedAt?.unixSeconds,
                           fixityVerifiedAt: a.verifiedAt, promotedBy: .import)
        }
        backupDestinations = (r.backupDestinations ?? []).map {
            BackupDestinationRow(name: $0.name, kind: $0.kind, recordedAt: $0.date.unixSeconds)
        }
        soundPrint = r.audioFingerprint.flatMap { (s) -> SoundPrintRow? in
            guard s.contentDigest.hasPrefix("sha256:") else { return nil }   // v1: keyed → not imported (§b)
            let hex = String(s.contentDigest.dropFirst("sha256:".count)).lowercased()
            guard Self.isWholeFileDigest(hex) else { return nil }
            return SoundPrintRow(digest: hex, engineVersion: s.engineVersion, outcome: s.outcome,
                                 analyzedS: s.analyzedSeconds, complete: s.complete, landmarks: s.landmarks,
                                 blobBytes: s.bytes, computedAt: s.computedAt.unixSeconds)
        }

        curated = Self.curatedKnowledge(r, id: Self.canonicalID(r.id), archiveFixity: af)
        curatedFields = Self.curatedFieldList(raw: r.raw)
        knowledgeSources = Self.knowledgeSourceRows(raw: r.raw)
        derivedUnverified = Self.derivedValueRows(raw: r.raw)
        regenContext = Self.regenContextRows(raw: r.raw)
        if r.pairedWithID != nil || r.pairGroupID != nil {
            legacyPairIDs = LegacyPairIDsRow(pairedWithID: r.pairedWithID, pairGroupID: r.pairGroupID,
                                             pairConfidence: r.pairConfidence,
                                             combinedFromPairID: r.combinedFromPairID)
        } else {
            legacyPairIDs = nil
        }
        duplicateMember = r.duplicateGroupID.map { g in
            DuplicateMemberRow(groupID: g, confidence: r.duplicateConfidence,
                               disposition: r.duplicateDisposition ?? "", reasons: r.duplicateReasons ?? "",
                               bestMatch: r.duplicateBestMatchFilename ?? "", analyzedAt: r.dupAnalyzedAt?.unixSeconds)
        }
        raw = r.raw
        undecodable = r.undecodable
    }

    // MARK: - Pure helpers (also used by the comparator)

    /// 64 lowercase hex — `content.digest` CHECK (DDL §2).
    public static func isWholeFileDigest(_ s: String) -> Bool {
        s.utf8.count == 64 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// `UUID.uuidString` (uppercase) when the text is a UUID; else verbatim.
    public static func canonicalID(_ id: String?) -> String {
        guard let id else { return "" }
        return UUID(uuidString: id)?.uuidString ?? id
    }

    /// The app's path fold (DDL files.path_fold, N3).
    public static func pathFold(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
    }

    /// `storedFullDigest` plus the F10 agreement rule: two sha256 fixities that
    /// differ → `.disagree` (compared whatever their sizes say: two full
    /// hashes that disagree are not trusted, §f row 2).
    public static func resolveDigest(contentFixity cf: ContentFixityEvidence?,
                                   archiveFixity af: ArchiveFixityEvidence?,
                                   sizeBytes: Int64) -> DigestState {
        let c = cf.flatMap { $0.algorithm == "sha256" && isWholeFileDigest($0.digest) ? $0 : nil }
        let a = af.flatMap { $0.algorithm == "sha256" && isWholeFileDigest($0.digest) ? $0 : nil }
        if let c, let a, c.digest != a.digest {
            return .disagree(digests: [c.digest, a.digest])
        }
        if let c, c.byteCount == sizeBytes { return .known(digest: c.digest, source: .contentFixity) }
        if let a, a.sizeBytes == sizeBytes { return .known(digest: a.digest, source: .archiveFixity) }
        return .none
    }

    private static func source(of state: DigestState) -> CatalogDDL.DigestSource? {
        if case .known(_, let s) = state { return s }
        return nil
    }

    /// `RemovalMarker.migrated` (C/RemovalMarker.swift:142) on the JSON's
    /// words: a readable stored marker is kept; else `purgedAt` + lifecycle
    /// decide; else a "Manually Deleted" label is removedFromCatalog.
    public static func migratedRemoval(_ r: VideoRecordJSON, loadedAt: Int64) -> RemovalMarkerRow? {
        if let m = r.removal, CatalogDDL.RemovalState(rawValue: m.state) != nil {
            return RemovalMarkerRow(removalState: m.state, removalSince: m.since.unixSeconds, removalReason: m.reason,
                                    removalTrashPath: m.trashPath, removalTrashEmptiedAt: m.trashEmptiedSeenAt?.unixSeconds,
                                    removalLastSeen: m.lastSeen?.unixSeconds, migrated: false)
        }
        if let purged = r.purgedAt?.unixSeconds {
            switch r.lifecycleStage ?? "" {
            case CatalogDDL.Lifecycle.trashed.rawValue:
                return RemovalMarkerRow(removalState: "inTrash", removalSince: purged, removalReason: "legacyTrashed",
                                        removalTrashPath: nil, removalTrashEmptiedAt: nil, removalLastSeen: nil, migrated: true)
            case CatalogDDL.Lifecycle.deleted.rawValue:
                return RemovalMarkerRow(removalState: "missing", removalSince: purged, removalReason: "legacyDeleted",
                                        removalTrashPath: nil, removalTrashEmptiedAt: nil, removalLastSeen: purged, migrated: true)
            default:
                return RemovalMarkerRow(removalState: "removedFromCatalog", removalSince: purged, removalReason: "legacyPurged",
                                        removalTrashPath: nil, removalTrashEmptiedAt: nil, removalLastSeen: nil, migrated: true)
            }
        }
        if r.archiveStage == CatalogDDL.ArchiveStage.manuallyDeleted.rawValue {
            return RemovalMarkerRow(removalState: "removedFromCatalog", removalSince: loadedAt,
                                    removalReason: "legacyDeletedLabel", removalTrashPath: nil,
                                    removalTrashEmptiedAt: nil, removalLastSeen: nil, migrated: true)
        }
        return nil
    }

    private static func curatedKnowledge(_ r: VideoRecordJSON, id: String,
                                         archiveFixity af: ArchiveFixityEvidence?) -> CuratedKnowledge {
        var people: [PeopleTagRow] = (r.confirmedByUserPeople ?? []).map {
            PeopleTagRow(name: $0.name, kind: .confirmed, confirmedAt: $0.confirmedAt.unixSeconds)
        }
        people += (r.rejectedPeople ?? []).map { PeopleTagRow(name: $0, kind: .rejected, confirmedAt: nil) }
        let date: UserDateRow? = (r.userDate == nil && r.userDateConfidence == nil)
            ? nil : UserDateRow(value: r.userDate, confidence: r.userDateConfidence)
        let place: UserPlaceRow? = (r.userPlace == nil && r.userPlaceConfidence == nil)
            ? nil : UserPlaceRow(place: r.userPlace, confidence: r.userPlaceConfidence)
        let lineage = LineageValue(derivedFrom: r.derivedFrom, derivationKind: r.derivationKind,
                                   cleanupRecipeID: r.cleanupRecipeID, cleanupRecipeVersion: r.cleanupRecipeVersion,
                                   trimInSeconds: r.trimInSeconds, trimOutSeconds: r.trimOutSeconds)
        let hasLineage = lineage.derivedFrom != nil || lineage.derivationKind != nil || lineage.cleanupRecipeID != nil
            || lineage.cleanupRecipeVersion != nil || lineage.trimInSeconds != nil || lineage.trimOutSeconds != nil
        let disposition = r.mediaDisposition.flatMap { $0 == CatalogDDL.Disposition.unreviewed ? nil : $0 }
        let stars = r.starRating.flatMap { $0 > 0 ? $0 : nil }
        return CuratedKnowledge(
            userNotes: (r.userNotes?.isEmpty ?? true) ? nil : r.userNotes,
            tags: r.tags ?? [],
            mediaDisposition: disposition,
            starRating: stars,
            people: people,
            userDate: date,
            userPlace: place,
            backupAttestations: (r.backupAttestations ?? []).map {
                BackupAttestationRow(kind: $0.kind, answer: $0.answer, label: $0.label,
                                     attestedAt: $0.attestedAt.unixSeconds, byWhom: $0.by)
            },
            footageDecisions: (r.footageDecisions ?? []).map {
                FootageDecisionRow(rowID: id, otherRowID: canonicalID($0.otherID), verdict: $0.verdict,
                                   decidedAt: $0.decidedAt.unixSeconds)
            },
            familyMusic: r.familyMusic.map {
                FamilyMusicRow(performer: $0.performer, title: $0.title, markedAt: $0.markedAt.unixSeconds)
            },
            setAsideReason: r.setAsideReason,
            archivedAt: r.archivedAt?.unixSeconds,
            archiveFixity: af,
            lineage: hasLineage ? lineage : nil,
            supersededByID: r.supersededByID,
            repairConfirmedDate: r.repairConfirmedDate?.unixSeconds,
            mediaReportCard: r.mediaReportCard)
    }

    // MARK: Knowledge sources — read from the RAW row (F1: verbatim, nothing lost)

    /// The JSON keys whose values make up each curated field.
    public static func rawKeys(of field: CatalogDDL.KnowledgeField) -> [String] {
        switch field {
        case .lineage:
            return ["derivedFrom", "derivationKind", "cleanupRecipeID", "cleanupRecipeVersion",
                    "trimInSeconds", "trimOutSeconds"]
        default:
            return [field.rawValue]
        }
    }

    /// True when `value` is the default the DTO does not write (contract §a
    /// "Absent ≡ default for every key marked N or P").
    private static func isDefault(_ value: CatalogJSONValue, field: CatalogDDL.KnowledgeField) -> Bool {
        switch value {
        case .null: return true
        case .string(let s):
            if field == .userNotes { return s.isEmpty }
            if field == .mediaDisposition { return s == CatalogDDL.Disposition.unreviewed }
            return false
        case .array(let a): return a.isEmpty
        case .int(let i): return field == .starRating && i == 0
        case .double(let d): return field == .starRating && d == 0
        default: return false
        }
    }

    /// The value a field carries, verbatim; nil when it carries none.
    public static func knowledgeValue(_ field: CatalogDDL.KnowledgeField,
                                      raw: [String: CatalogJSONValue]) -> CatalogJSONValue? {
        if field == .lineage {
            var object: [String: CatalogJSONValue] = [:]
            for key in rawKeys(of: .lineage) {
                if let v = raw[key], v != .null { object[key] = v }
            }
            return object.isEmpty ? nil : .object(object)
        }
        guard let v = raw[field.rawValue], !isDefault(v, field: field) else { return nil }
        return v
    }

    /// `import_items.curated_fields`, DDL order.
    public static func curatedFieldList(raw: [String: CatalogJSONValue]) -> [CatalogDDL.KnowledgeField] {
        CatalogDDL.KnowledgeField.allCases.filter { knowledgeValue($0, raw: raw) != nil }
    }

    /// One `knowledge_sources` row per carried field.
    public static func knowledgeSourceRows(raw: [String: CatalogJSONValue]) -> [KnowledgeSourceRow] {
        CatalogDDL.KnowledgeField.allCases.compactMap { (field) -> KnowledgeSourceRow? in
            guard let v = knowledgeValue(field, raw: raw) else { return nil }
            return KnowledgeSourceRow(field: field, valueJSON: v, setAt: setAt(field, value: v))
        }
    }

    private static func seconds(_ v: CatalogJSONValue?) -> Int64? {
        v?.stringValue.flatMap { CatalogJSONDate.parse($0) }
    }

    private static func setAt(_ field: CatalogDDL.KnowledgeField, value: CatalogJSONValue) -> Int64? {
        switch field {
        case .archivedAt, .repairConfirmedDate: return seconds(value)
        case .familyMusic: return seconds(value["markedAt"])
        case .archiveFixity: return seconds(value["verifiedAt"])
        case .mediaReportCard: return seconds(value["checkedAt"])
        default: return nil
        }
    }

    // MARK: Derived values — every one `unverified` (§e.8), keyed (kind, seq)

    private static func object(_ raw: [String: CatalogJSONValue], _ keys: [String]) -> CatalogJSONValue {
        var o: [String: CatalogJSONValue] = [:]
        for k in keys {
            if let v = raw[k], v != .null { o[k] = v }
        }
        return .object(o)
    }

    private static func nonEmpty(_ v: CatalogJSONValue) -> Bool {
        if case .object(let o) = v { return !o.isEmpty }
        return true
    }

    /// `derived_unverified` rows for one occurrence. A sound print is not
    /// here: a `sha256:` stamp is bound (`soundPrint`), a `v1:` stamp is not
    /// imported (§b).
    public static func derivedValueRows(raw: [String: CatalogJSONValue]) -> [DerivedValueRow] {
        var out: [DerivedValueRow] = []
        let captionStamp = object(raw, ["sceneCaptionModel", "sceneCaptionDate"])
        let lists: [(String, CatalogDDL.DerivedKind)] = [
            ("sceneCaptions", .scene), ("ocrDateCandidates", .ocrDate), ("ocrText", .ocrText),
        ]
        for (key, kind) in lists {
            for (i, v) in (raw[key]?.arrayValue ?? []).enumerated() {
                out.append(DerivedValueRow(kind: kind, seq: i, valueJSON: v, stampJSON: captionStamp))
            }
        }
        if nonEmpty(captionStamp) {
            out.append(DerivedValueRow(kind: .captionRun, seq: 0, valueJSON: captionStamp, stampJSON: .object([:])))
        }
        if let t = raw["audioTranscript"], t != .null {
            out.append(DerivedValueRow(kind: .transcript, seq: 0, valueJSON: t,
                                       stampJSON: object(raw, ["audioTranscriptModel", "audioTranscriptDate"])))
        }
        let dossier = object(raw, ["dossierProcessedAt", "dossierProcessedBy"])
        if nonEmpty(dossier) {
            out.append(DerivedValueRow(kind: .dossier, seq: 0, valueJSON: dossier, stampJSON: .object([:])))
        }
        let inferred = object(raw, ["inferredRecordDate", "inferredDateConfidence", "inferredDateSource",
                                    "inferredDateRange", "inferredDateReason"])
        if nonEmpty(inferred) {
            out.append(DerivedValueRow(kind: .inferredDate, seq: 0, valueJSON: inferred, stampJSON: .object([:])))
        }
        let checks: [(String, CatalogDDL.DerivedKind, String, String)] = [
            ("audioVerifyStatus", .audioCheck, "audioVerifyNote", "audioVerifyDate"),
            ("videoVerifyStatus", .videoCheck, "videoVerifyNote", "videoVerifyDate"),
        ]
        for (statusKey, kind, noteKey, dateKey) in checks {
            if let s = raw[statusKey]?.stringValue, !s.isEmpty {
                out.append(DerivedValueRow(kind: kind, seq: 0, valueJSON: object(raw, [statusKey, noteKey, dateKey]),
                                           stampJSON: object(raw, [dateKey])))
            }
        }
        if let card = raw["mediaReportCard"], card != .null {
            var stamp: [String: CatalogJSONValue] = [:]
            if let v = card["fileSizeBytes"] { stamp["fileSizeBytes"] = v }
            if let v = card["checkedAt"] { stamp["checkedAt"] = v }
            out.append(DerivedValueRow(kind: .reportCard, seq: 0, valueJSON: card, stampJSON: .object(stamp)))
        }
        if let fingerprint = raw["perceptualFingerprint"], fingerprint != .null {
            var stamp: [String: CatalogJSONValue] = [:]
            if let v = fingerprint["sizeBytes"] { stamp["sizeBytes"] = v }
            out.append(DerivedValueRow(kind: .perceptualPrint, seq: 0, valueJSON: fingerprint, stampJSON: .object(stamp)))
        }
        if let footage = raw["footage"], footage != .null {
            out.append(DerivedValueRow(kind: .footageMembership, seq: 0, valueJSON: footage, stampJSON: .object([:])))
        }
        let names: [(String, CatalogDDL.DerivedKind)] = [("detectedPeople", .detectedPerson), ("suspectedPeople", .suspectedPerson)]
        for (key, kind) in names {
            for (i, v) in (raw[key]?.arrayValue ?? []).enumerated() {
                out.append(DerivedValueRow(kind: kind, seq: i, valueJSON: v, stampJSON: .object([:])))
            }
        }
        return out
    }

    /// `regen_context` (§e.8): 'folder-year' → folderDate, 'propagated from
    /// <uuid>' → donorDate (the donor row id stays verbatim in the value).
    public static func regenContextRows(raw: [String: CatalogJSONValue]) -> [RegenContextRow] {
        guard let source = raw["inferredDateSource"]?.stringValue else { return [] }
        let kind: CatalogDDL.RegenKind
        if source == "folder-year" {
            kind = .folderDate
        } else if source.hasPrefix("propagated from ") {
            kind = .donorDate
        } else {
            return []
        }
        let value = object(raw, ["inferredDateSource", "inferredRecordDate", "inferredDateRange"])
        return [RegenContextRow(kind: kind, valueJSON: value, reason: raw["inferredDateReason"]?.stringValue)]
    }
}
