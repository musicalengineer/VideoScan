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
//
// Companions: CatalogRecordDTO+Rows.swift (the row-shaped value types and
// how each builds itself from the JSON row) and CatalogRecordDTO+Derived.swift
// (the derived values, table-driven).

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

        /// Where the digest came from; nil unless known.
        public var source: CatalogDDL.DigestSource? {
            if case .known(_, let s) = self { return s }
            return nil
        }

        /// `files.digest_computed_at`: the source fixity's own stamp.
        public func computedAt(contentFixity cf: ContentFixityEvidence?,
                               archiveFixity af: ArchiveFixityEvidence?) -> Int64? {
            switch source {
            case .contentFixity: return cf?.computedAt
            case .archiveFixity, .rescan: return af?.verifiedAt
            case nil: return nil
            }
        }
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
    ///
    /// Each table-shaped value builds itself from the row (its own init in
    /// CatalogRecordDTO+Rows.swift); this init only orders them and shares
    /// the digest decision between them.
    public init(record r: VideoRecordJSON,
                migrationLoadedAt: Int64 = Int64(Date().timeIntervalSince1970)) {
        let sizeBytes = r.sizeBytes ?? 0
        let cf = r.contentFixity.map { ContentFixityEvidence($0) }
        let af = r.archiveFixity.map { ArchiveFixityEvidence($0) }
        contentFixity = cf
        archiveFixity = af
        let state = Self.resolveDigest(contentFixity: cf, archiveFixity: af, sizeBytes: sizeBytes)
        digestState = state
        content = ContentRow(digest: state, contentFixity: cf, archiveFixity: af, byteCount: sizeBytes)
        volume = VolumeRowDTO(r.scanContext)
        let marker = Self.migratedRemoval(r, loadedAt: migrationLoadedAt)
        removal = marker
        let audit = r.auditSeenOn.map { AuditStamp($0) }
        auditStamp = audit
        file = FileRow(record: r, digest: state, contentFixity: cf, archiveFixity: af, removal: marker, audit: audit)
        archiveCopy = af.map { ArchiveCopyRow(record: r, archiveFixity: $0) }
        backupDestinations = (r.backupDestinations ?? []).map { BackupDestinationRow($0) }
        soundPrint = r.audioFingerprint.flatMap { SoundPrintRow($0) }
        curated = Self.curatedKnowledge(r, id: Self.canonicalID(r.id), archiveFixity: af)
        curatedFields = Self.curatedFieldList(raw: r.raw)
        knowledgeSources = Self.knowledgeSourceRows(raw: r.raw)
        derivedUnverified = Self.derivedValueRows(raw: r.raw)
        regenContext = Self.regenContextRows(raw: r.raw)
        legacyPairIDs = LegacyPairIDsRow(record: r)
        duplicateMember = r.duplicateGroupID.map { DuplicateMemberRow(record: r, groupID: $0) }
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

}
