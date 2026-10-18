// CatalogRecordDTO+Rows.swift
// The table-shaped value types of one catalog.json row occurrence (contract
// docs/design/catalog_contract_freeze_2026_10_17.md, DDL
// docs/design/catalog_sqlite_schema_v1.sql) and how each builds itself from
// the row. Property names are the DDL column names in lowerCamelCase.
//
// The nested types are declared here (an extension may declare nested
// types); CatalogRecordDTO.swift holds the mapping rules and the init that
// orders them. The JSON-reading inits live in their own extensions so each
// struct keeps its memberwise init (the tests and the GRDB layer use it).
//
// (For Rick: the PODs, each with one converting constructor from the JSON
// mirror — like a `static Row from(const Json&)` per table.)

import Foundation

extension CatalogRecordDTO {

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

    public struct PeopleTagRow: Codable, Sendable, Hashable {
        public var name: String
        public var kind: CatalogDDL.PeopleTagKind
        public var confirmedAt: Int64?
    }

    public struct FamilyMusicRow: Codable, Sendable, Equatable {
        public var performer: String?
        public var title: String?
        public var markedAt: Int64
    }

    public struct BackupAttestationRow: Codable, Sendable, Hashable {
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

}

// MARK: - Building each row from the JSON mirror

extension CatalogRecordDTO.ContentFixityEvidence {
    /// The JSON fixity as evidence: digest lowered, device/inode as the DDL
    /// stores them, a missing ctime → −1 (`FileIdentityStamp.unknownCtime`).
    init(_ f: VideoRecordJSON.ContentFixityJSON) {
        self.init(algorithm: f.algorithm, digest: f.digest.lowercased(), byteCount: f.byteCount,
                  stampDevice: Int64(bitPattern: f.stamp.device), stampInode: Int64(bitPattern: f.stamp.inode),
                  stampSize: f.stamp.size, stampMtimeNs: f.stamp.mtimeNs,
                  stampCtimeNs: f.stamp.ctimeNs ?? -1, stampVolumeUUID: f.stamp.volumeUUID,
                  computedAt: f.computedAt.unixSeconds)
    }
}

extension CatalogRecordDTO.ArchiveFixityEvidence {
    init(_ a: VideoRecordJSON.ArchiveFixityJSON) {
        self.init(algorithm: a.algorithm, digest: a.digest.lowercased(),
                  sizeBytes: a.sizeBytes, verifiedAt: a.verifiedAt.unixSeconds)
    }
}

extension CatalogRecordDTO.ContentRow {
    /// The `content` row a digest-bearing occurrence feeds; nil when the
    /// occurrence has no agreeing whole-file digest (§e.2).
    init?(digest: CatalogRecordDTO.DigestState, contentFixity cf: CatalogRecordDTO.ContentFixityEvidence?,
          archiveFixity af: CatalogRecordDTO.ArchiveFixityEvidence?, byteCount: Int64) {
        guard let d = digest.digest else { return nil }
        let seen = [cf?.computedAt, af?.verifiedAt].compactMap { $0 }.min() ?? 0
        self.init(digest: d, algorithm: "sha256", byteCount: byteCount, firstSeenAt: seen, firstSeenHow: .import)
    }
}

extension CatalogRecordDTO.VolumeRowDTO {
    /// `volumes` from the row's `scanContext` (absent members → '').
    init(_ ctx: VideoRecordJSON.ScanContextJSON?) {
        self.init(volumeUUID: ctx?.volumeUUID ?? "", lastName: ctx?.volumeName ?? "",
                  mountType: ctx?.volumeMountType ?? "", remoteServer: ctx?.remoteServerName ?? "")
    }
}

extension CatalogRecordDTO.AuditStamp {
    init(_ s: VideoRecordJSON.AuditSeenOnJSON) {
        self.init(auditSeenVolumeUUID: s.volumeUUID, auditSeenMountFrom: s.mountFrom,
                  auditSeenDeviceKey: s.deviceKey, auditSeenAt: s.seenAt.unixSeconds)
    }
}

extension CatalogRecordDTO.ArchiveCopyRow {
    /// `archive_copies` for a row carrying `archiveFixity`; `sourceRowID` is
    /// `derivedFrom` verbatim (F1).
    init(record r: VideoRecordJSON, archiveFixity a: CatalogRecordDTO.ArchiveFixityEvidence) {
        self.init(sourceRowID: r.derivedFrom, archivedAt: r.archivedAt?.unixSeconds,
                  fixityVerifiedAt: a.verifiedAt, promotedBy: .import)
    }
}

extension CatalogRecordDTO.BackupDestinationRow {
    init(_ e: VideoRecordJSON.BackupEntryJSON) {
        self.init(name: e.name, kind: e.kind, recordedAt: e.date.unixSeconds)
    }
}

extension CatalogRecordDTO.SoundPrintRow {
    /// Only a `sha256:`-keyed stamp binds (§b, §e.6); a `v1:` stamp is not
    /// imported, and neither is a digest that is not 64 lowercase hex.
    init?(_ s: VideoRecordJSON.AudioFingerprintJSON) {
        guard s.contentDigest.hasPrefix("sha256:") else { return nil }
        let hex = String(s.contentDigest.dropFirst("sha256:".count)).lowercased()
        guard CatalogRecordDTO.isWholeFileDigest(hex) else { return nil }
        self.init(digest: hex, engineVersion: s.engineVersion, outcome: s.outcome,
                  analyzedS: s.analyzedSeconds, complete: s.complete, landmarks: s.landmarks,
                  blobBytes: s.bytes, computedAt: s.computedAt.unixSeconds)
    }
}

extension CatalogRecordDTO.LegacyPairIDsRow {
    /// `legacy_pair_ids` (F9) when the row names a pair; nil otherwise.
    init?(record r: VideoRecordJSON) {
        guard r.pairedWithID != nil || r.pairGroupID != nil else { return nil }
        self.init(pairedWithID: r.pairedWithID, pairGroupID: r.pairGroupID,
                  pairConfidence: r.pairConfidence, combinedFromPairID: r.combinedFromPairID)
    }

    /// The whole link when any of its four members is set (v1.7 'pair').
    init?(link r: VideoRecordJSON) {
        guard r.pairedWithID != nil || r.pairGroupID != nil || r.pairConfidence != nil || r.combinedFromPairID != nil else { return nil }
        self.init(pairedWithID: r.pairedWithID, pairGroupID: r.pairGroupID,
                  pairConfidence: r.pairConfidence, combinedFromPairID: r.combinedFromPairID)
    }

    /// True when `legacy_pair_ids` cannot say all of it (a confidence, or a
    /// Combine link): the importer then writes the link to `row_knowledge`.
    public var needsLinkRow: Bool { pairConfidence != nil || combinedFromPairID != nil }

    /// The `row_knowledge` 'pair' value: the set members only.
    public var linkValue: CatalogJSONValue {
        var o: [String: CatalogJSONValue] = [:]
        if let pairedWithID { o["pairedWithID"] = .string(pairedWithID) }
        if let pairGroupID { o["pairGroupID"] = .string(pairGroupID) }
        if let pairConfidence { o["pairConfidence"] = .string(pairConfidence) }
        if let combinedFromPairID { o["combinedFromPairID"] = .string(combinedFromPairID) }
        return .object(o)
    }
}

extension CatalogRecordDTO.DuplicateMemberRow {
    init(record r: VideoRecordJSON, groupID: String) {
        self.init(groupID: groupID, confidence: r.duplicateConfidence,
                  disposition: r.duplicateDisposition ?? "", reasons: r.duplicateReasons ?? "",
                  bestMatch: r.duplicateBestMatchFilename ?? "", analyzedAt: r.dupAnalyzedAt?.unixSeconds)
    }
}

extension CatalogRecordDTO.FileRow {
    /// The `files` row of one occurrence (DDL §4). The stamp columns come
    /// from `contentFixity` only when it is the digest's source — an
    /// archive-only fixity has no stamp (§f "Digest", F10). `cataloguedAt`
    /// is NULL: the JSON carries no catalogued date (§9.2, never invented).
    init(record r: VideoRecordJSON, digest: CatalogRecordDTO.DigestState,
         contentFixity cf: CatalogRecordDTO.ContentFixityEvidence?,
         archiveFixity af: CatalogRecordDTO.ArchiveFixityEvidence?,
         removal marker: CatalogRecordDTO.RemovalMarkerRow?, audit: CatalogRecordDTO.AuditStamp?) {
        let path = r.fullPath ?? ""
        let ctx = r.scanContext
        let stamp = digest.source == .contentFixity ? cf : nil
        let sampled = r.contentHash.flatMap { $0.hasPrefix("v1:") ? $0 : nil }
        id = CatalogRecordDTO.canonicalID(r.id)
        contentDigest = digest.digest
        volumeUUID = ctx?.volumeUUID ?? ""
        fullPath = path
        pathFold = CatalogRecordDTO.pathFold(path)
        filename = r.filename ?? ""
        ext = r.ext ?? ""
        directory = r.directory ?? ""
        sizeBytes = r.sizeBytes ?? 0
        fsCreatedAt = r.dateCreatedRaw?.unixSeconds
        fsModifiedAt = r.dateModifiedRaw?.unixSeconds
        stampDevice = stamp?.stampDevice
        stampInode = stamp?.stampInode
        stampMtimeNs = stamp?.stampMtimeNs
        stampCtimeNs = stamp?.stampCtimeNs
        stampVolumeUUID = stamp?.stampVolumeUUID
        digestComputedAt = digest.computedAt(contentFixity: cf, archiveFixity: af)
        digestSource = digest.source
        sampledHash = sampled
        sampledHashAt = sampled == nil ? nil : r.contentHashAt?.unixSeconds
        partialMD5 = (r.partialMD5?.isEmpty ?? true) ? nil : r.partialMD5
        streamType = r.streamTypeRaw ?? ""
        durationS = r.durationSeconds ?? 0
        container = r.container ?? ""
        videoCodec = r.videoCodec ?? ""
        audioCodec = r.audioCodec ?? ""
        embeddedCreatedAt = r.embeddedCreationDate?.unixSeconds
        embeddedCreatedSource = r.embeddedCreationSource
        probeExtra = CatalogRecordDTO.probeExtra(raw: r.raw)
        scanHost = ctx?.scanHost ?? ""
        scannedAt = ctx?.scannedAt?.unixSeconds
        scanRootLabel = ctx?.scanRootLabel ?? ""
        bundleContainer = ctx?.bundleContainer ?? ""
        sourceHost = r.sourceHost ?? ""
        originalFullPath = r.originalFullPath
        originVolume = r.originVolume
        machineNotes = r.notes ?? ""
        lifecycle = r.lifecycleStage ?? CatalogDDL.Lifecycle.cataloged.rawValue
        archiveStage = r.archiveStage ?? CatalogDDL.ArchiveStage.none.rawValue
        masterLocation = r.masterLocation ?? ""
        setAsideReason = r.setAsideReason
        needsReformat = r.needsReformat ?? false
        workspaceActive = r.workspaceActive ?? false
        removalState = marker?.removalState
        removalSince = marker?.removalSince
        removalReason = marker?.removalReason
        removalTrashPath = marker?.removalTrashPath
        removalTrashEmptiedAt = marker?.removalTrashEmptiedAt
        removalLastSeen = marker?.removalLastSeen
        removalRevision = r.removalRevision ?? 0
        auditSeenVolumeUUID = audit?.auditSeenVolumeUUID
        auditSeenMountFrom = audit?.auditSeenMountFrom
        auditSeenDeviceKey = audit?.auditSeenDeviceKey
        auditSeenAt = audit?.auditSeenAt
        cataloguedAt = nil
    }
}

extension CatalogRecordDTO {
    /// `files.probe_extra`: the X-fated keys (contract §a) the row carries, verbatim.
    static func probeExtra(raw: [String: CatalogJSONValue]) -> [String: CatalogJSONValue] {
        var extra: [String: CatalogJSONValue] = [:]
        for key in probeExtraKeys {
            if let v = raw[key.rawValue], v != .null { extra[key.rawValue] = v }
        }
        return extra
    }
}
