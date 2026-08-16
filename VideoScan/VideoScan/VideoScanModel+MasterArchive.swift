// VideoScanModel+MasterArchive.swift
// Master Archive designation + Initialize + the promotion helpers the UI
// and the Promote job call on the main actor (design v2 —
// docs/archive_promotion_workflow.md §3, §4, §5.6).
//
//   Phase A: `initializeMasterArchive(at:)`, `clearMasterArchive()`,
//            the derived `masterArchiveTargetID` / `masterArchiveRootPath`.
//   Phase B: `masterArchiveCopy(of:)` / `promotionSource(of:)` (memoized
//            reverse index), `buildPromotePlan(for:)` (the confirmation
//            sheet's numbers), `requestPromote(recordIDs:)` (routes to the
//            sheet or the no-master alert), and `registerPromotedCopy(...)`
//            (the main-actor catalog step the job calls per file).
//
// The stored properties live in VideoScanModel.swift (extensions cannot
// add storage); the pure path/manifest rules live in MasterArchive.swift.

import Foundation
import os

private let masterArchiveLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                      category: "masterArchive")

// MARK: - Provenance tag

/// The `VideoRecord.derivationKind` value stamped on every archive copy.
/// Additive — legacy derivation kinds ("trim", "rebuildAudio", …) are
/// untouched; the reverse index keys on this string.
enum ArchivePromotion {
    static let derivationKind = "archivePromotion"
}

/// Initialize refusals (retired volume, scratch volume) — surfaced in the
/// sheet's error line. Filesystem errors propagate as CocoaError.
enum MasterArchiveError: Error, LocalizedError, Equatable {
    case refused(String)
    var errorDescription: String? {
        switch self { case .refused(let why): return why }
    }
}

// MARK: - UI payloads (model-driven sheets / alerts)

/// "Initialize as Master Archive…" sheet payload. `isNewTarget` is true
/// when the volume is not yet a scan target (the sheet's "Also add as
/// scan target" line is then always on).
struct MasterArchiveInitOffer: Identifiable, Equatable {
    let id = UUID()
    let targetPath: String
    let isNewTarget: Bool
    /// When the user got here from a refused Promote, re-offer that
    /// promotion after Initialize succeeds.
    var promoteAfterwards: [UUID] = []
}

/// The no-master refusal: which records the user tried to promote.
struct ArchivePromoteWithoutMaster: Identifiable, Equatable {
    let id = UUID()
    let recordIDs: [UUID]
}

/// The Promote confirmation sheet's payload — the plan the sheet renders
/// and the job executes.
struct ArchivePromoteRequest: Identifiable {
    let id = UUID()
    let plan: ArchivePromotePlan
}

/// Everything the confirmation sheet shows (spec §4): counts, bytes,
/// destination folders grouped, warnings, free-space verdict. Built once
/// on the main actor from the selection; pure value afterwards.
struct ArchivePromotePlan: Sendable {
    struct Entry: Sendable, Identifiable {
        var id: UUID { recordID }
        let recordID: UUID
        let filename: String
        let sizeBytes: Int64
        /// Destination folder (relative), before collision suffixing.
        let folder: String
        let dateHint: ArchiveDateHint
        let lowConfidenceDate: Bool
    }
    enum Skip: Sendable, Equatable {
        case alreadyPromoted
        case isArchiveCopy
        case insideArchiveRoot
        case offline
        case purged
    }
    let rootPath: String
    let entries: [Entry]
    let skipped: [(id: UUID, filename: String, reason: Skip)]
    let totalBytes: Int64
    let freeBytesAtRoot: Int64?

    var undatedCount: Int { entries.filter { $0.dateHint == .unknown }.count }
    var lowConfidenceCount: Int { entries.filter { $0.lowConfidenceDate }.count }
    var alreadyPromotedCount: Int {
        skipped.filter { $0.reason == .alreadyPromoted || $0.reason == .isArchiveCopy }.count
    }
    /// Folder → count, sorted by folder for the sheet's grouped list.
    var foldersGrouped: [(folder: String, count: Int)] {
        var counts: [String: Int] = [:]
        for e in entries { counts[e.folder, default: 0] += 1 }
        return counts.keys.sorted().map { ($0, counts[$0] ?? 0) }
    }
    /// Spec §5.2 — batch free-space check up front (10% headroom or 256 MB,
    /// whichever is larger, on top of the raw bytes).
    var requiredBytes: Int64 { totalBytes + max(totalBytes / 10, 256 << 20) }
    var hasEnoughFreeSpace: Bool {
        guard let free = freeBytesAtRoot else { return true }   // unknown → do not block
        return free >= requiredBytes
    }
}

// MARK: - Reverse index (memoized)

/// source-id → archive-copy record and copy-id → source-id, rebuilt at
/// most once per `RecordsVersion` (the CatalogHelpers memo discipline:
/// count catches add/remove, `volumeAggregatesRevision` catches in-place
/// stamps). Memory: two dictionaries of UUID → ref / UUID → UUID over the
/// promoted subset only — bytes per promoted record, not per record.
@MainActor
final class ArchivePromotionIndex {
    private var builtFor: RecordsVersion?
    private var copyBySource: [UUID: VideoRecord] = [:]
    private var sourceByCopy: [UUID: UUID] = [:]
    /// Rebuild counter, exposed for the scale test ("did N lookups do
    /// ONE rebuild?").
    private(set) var rebuildCount = 0

    func copy(ofSourceID id: UUID, in records: [VideoRecord], version: RecordsVersion) -> VideoRecord? {
        rebuildIfNeeded(records, version: version)
        return copyBySource[id]
    }

    func sourceID(ofCopyID id: UUID, in records: [VideoRecord], version: RecordsVersion) -> UUID? {
        rebuildIfNeeded(records, version: version)
        return sourceByCopy[id]
    }

    func invalidate() { builtFor = nil }

    private func rebuildIfNeeded(_ records: [VideoRecord], version: RecordsVersion) {
        if builtFor == version { return }
        rebuildCount += 1
        copyBySource.removeAll(keepingCapacity: true)
        sourceByCopy.removeAll(keepingCapacity: true)
        for rec in records where rec.derivationKind == ArchivePromotion.derivationKind && !rec.isPurged {
            guard let src = rec.derivedFrom else { continue }
            copyBySource[src] = rec
            sourceByCopy[rec.id] = src
        }
        builtFor = version
    }
}

// MARK: - Model surface

extension VideoScanModel {

    // MARK: Designation

    /// The scan target designated as Master Archive (resolved by canonical
    /// path — target ids are per-launch and never persisted). nil when
    /// none or the target is gone.
    var masterArchiveTarget: CatalogScanTarget? {
        guard let path = masterArchive?.targetPath else { return nil }
        return scanTargets.first { Self.samePath($0.searchPath, path) }
    }

    /// Canonical path equality (standardized, trailing slash stripped).
    nonisolated static func samePath(_ a: String, _ b: String) -> Bool {
        PathScope.normalize(URL(fileURLWithPath: a).standardizedFileURL.path)
            == PathScope.normalize(URL(fileURLWithPath: b).standardizedFileURL.path)
    }

    /// Volume-UUID-first re-resolution (codex QA blocker 1). If the
    /// designated path is not reachable but a mounted volume under
    /// /Volumes carries the designation's volume UUID, the designation
    /// follows the volume to its new mount point. Called at load and on
    /// every mount notification. No-op when the path is fine, the UUID is
    /// unknown, or no mounted volume matches.
    func reresolveMasterArchiveMount() {
        guard let current = masterArchive, let uuid = current.volumeUUID else { return }
        let fm = FileManager.default
        if fm.fileExists(atPath: current.rootPath) { return }
        // The stored target may be a folder inside a volume — recover the
        // volume-relative tail so a rename keeps the sub-folder.
        guard let mounts = try? fm.contentsOfDirectory(atPath: "/Volumes") else { return }
        for name in mounts {
            let mountPath = "/Volumes/\(name)"
            guard MasterArchiveDesignation.volumeUUID(forPath: mountPath) == uuid else { continue }
            let oldComps = URL(fileURLWithPath: current.targetPath).standardizedFileURL.pathComponents
            // "/Volumes/<old>/<tail…>" → keep <tail…> under the new mount.
            let tail = oldComps.count > 3 ? Array(oldComps[3...]) : []
            var newURL = URL(fileURLWithPath: mountPath, isDirectory: true)
            for comp in tail { newURL.appendPathComponent(comp) }
            let rehomed = current.rehomed(to: newURL.path)
            guard fm.fileExists(atPath: rehomed.rootPath) else { continue }
            masterArchive = rehomed
            noteCatalogRecordsMutated()
            saveCatalogDebounced()
            log("Master Archive volume found at \(rehomed.targetPath) (same volume UUID; was \(current.targetPath)).")
            masterArchiveLog.notice("rehomed master archive \(current.targetPath, privacy: .public) → \(rehomed.targetPath, privacy: .public)")
            return
        }
    }

    /// The designated CatalogScanTarget's id, or nil.
    var masterArchiveTargetID: UUID? { masterArchiveTarget?.id }

    /// `<target>/Breen_Family_Archive`, or nil when no master is set.
    var masterArchiveRootPath: String? { masterArchive?.rootPath }

    /// True when a Master Archive is designated AND its root folder is
    /// reachable right now (the promote job needs it online).
    var isMasterArchiveOnline: Bool {
        guard let root = masterArchiveRootPath else { return false }
        return FileManager.default.fileExists(atPath: root)
    }

    /// True when `target` is the designated Master Archive — drives the
    /// "Master Archive" chip on the volume row.
    func isMasterArchive(_ target: CatalogScanTarget) -> Bool {
        guard let path = masterArchive?.targetPath else { return false }
        return Self.samePath(target.searchPath, path)
    }

    /// Why a path may not become / serve as the Master Archive right now,
    /// or nil when it is fine. Retirement is `isRetired` (`retiredAt`),
    /// NEVER `role == .retired` (codex QA blocker 2 — two owners).
    func masterArchiveRefusal(forTargetPath path: String) -> String? {
        if let t = scanTargets.first(where: { Self.samePath($0.searchPath, path) }), t.isRetired {
            return "\(VolumeReachability.displayLabel(forPath: path)) is retired — reinstate it in the Volumes window before making it the Master Archive."
        }
        if CatalogScanTarget.isScratchVolumePath(path) {
            return "That's VideoScan's RAM-disk scratch volume — not a place for the archive."
        }
        return nil
    }

    /// What Initialize did — for the log line and the sheet's summary.
    struct MasterArchiveInitResult: Equatable {
        var createdPaths: [String] = []
        var addedScanTarget = false
        var rootPath: String
    }

    /// Initialize (spec §1 "one gesture"): designate `volumeOrFolderURL`
    /// as the Master Archive AND scaffold the tree + index files.
    /// Idempotent — re-running on an initialized volume creates nothing
    /// new and NEVER truncates the manifest (a hand-edited README stays
    /// too). Ensures a CatalogScanTarget exists (adds one for a
    /// never-seen volume) with role Archive; sets the designation; marks
    /// the catalog mutated and schedules a save.
    @discardableResult
    func initializeMasterArchive(at volumeOrFolderURL: URL) throws -> MasterArchiveInitResult {
        let targetPath = PathScope.normalize(volumeOrFolderURL.standardizedFileURL.path)
        if let refusal = masterArchiveRefusal(forTargetPath: targetPath) {
            throw MasterArchiveError.refused(refusal)
        }
        let rootURL = MasterArchiveLayout.rootURL(forTargetPath: targetPath)
        var result = MasterArchiveInitResult(rootPath: rootURL.path)

        result.createdPaths = try Self.scaffoldMasterArchive(rootURL: rootURL)

        // Scan target: add if never seen; either way it becomes role
        // Archive so the tree is cataloged like any volume.
        let target: CatalogScanTarget
        if let existing = scanTargets.first(where: { Self.samePath($0.searchPath, targetPath) }) {
            target = existing
        } else {
            target = CatalogScanTarget(searchPath: targetPath)
            scanTargets.append(target)
            persistScanTargets()
            result.addedScanTarget = true
        }
        if target.role != .archive && target.role != .lta {
            target.role = .archive
        }
        persistScanDates()
        notifyTargetsChanged()
        refreshTargetReachability()

        masterArchive = MasterArchiveDesignation(
            targetPath: targetPath,
            rootPath: rootURL.path,
            volumeUUID: MasterArchiveDesignation.volumeUUID(forPath: targetPath))
        noteCatalogRecordsMutated()
        saveCatalogDebounced()

        let created = result.createdPaths.isEmpty
            ? "already initialized — nothing new created"
            : "created \(result.createdPaths.count) item(s)"
        log("Master Archive: \(rootURL.path) (\(created)\(result.addedScanTarget ? "; added as scan target" : "")).")
        masterArchiveLog.info("initialize: root=\(rootURL.path, privacy: .public) created=\(result.createdPaths.count) addedTarget=\(result.addedScanTarget)")
        return result
    }

    /// Import / bundle round-trip (codex QA blocker 1): a catalog.json or
    /// bundle carrying a designation seeds ours when we have none. An
    /// existing local designation is never overwritten silently — the
    /// user changes masters explicitly.
    func adoptImportedMasterArchive(_ imported: MasterArchiveDesignation?) {
        guard let imported, masterArchive == nil else { return }
        masterArchive = imported
        log("Adopted the imported Master Archive designation: \(imported.targetPath).")
        reresolveMasterArchiveMount()
    }

    /// v1 clear: forget the designation. The on-disk tree and its
    /// manifest are NOT touched (they are the archive; the app only
    /// forgets which volume it is). Records already promoted keep their
    /// links.
    func clearMasterArchive() {
        guard masterArchive != nil else { return }
        masterArchive = nil
        noteCatalogRecordsMutated()
        saveCatalogDebounced()
        log("Master Archive designation cleared (files on disk untouched).")
    }

    /// Filesystem-only scaffold — the tree + both index files. Pure
    /// function of `rootURL`; returns the paths it CREATED (empty on a
    /// second run). Never truncates or rewrites an existing file.
    /// `nonisolated` so tests can drive it against a temp dir without a
    /// model. (≈ a free function; no shared state.)
    nonisolated static func scaffoldMasterArchive(rootURL: URL) throws -> [String] {
        let fm = FileManager.default
        var created: [String] = []
        func ensureDir(_ url: URL) throws {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
                if !isDir.boolValue {
                    throw CocoaError(.fileWriteFileExists,
                                     userInfo: [NSFilePathErrorKey: url.path])
                }
                return
            }
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            created.append(url.path)
        }
        try ensureDir(rootURL)
        let index = rootURL.appendingPathComponent(MasterArchiveLayout.indexFolder, isDirectory: true)
        try ensureDir(index)
        for bucket in MasterArchiveLayout.buckets {
            try ensureDir(rootURL.appendingPathComponent(bucket, isDirectory: true))
        }
        let manifest = MasterArchiveLayout.manifestURL(rootPath: rootURL.path)
        if !fm.fileExists(atPath: manifest.path) {
            // Header row only — O_EXCL-equivalent via the exists check
            // above plus `withoutOverwriting`, so a race with another
            // writer cannot truncate a manifest that already has rows.
            try Data((MasterArchiveLayout.manifestHeader + "\n").utf8)
                .write(to: manifest, options: [.withoutOverwriting])
            CatalogStore.fullFsync(fileURL: manifest)
            created.append(manifest.path)
        }
        let readme = MasterArchiveLayout.readmeURL(rootPath: rootURL.path)
        if !fm.fileExists(atPath: readme.path) {
            try Data(MasterArchiveLayout.readmeText.utf8)
                .write(to: readme, options: [.withoutOverwriting])
            created.append(readme.path)
        }
        return created
    }

    // MARK: Reverse index

    private var promotionIndexVersion: RecordsVersion {
        RecordsVersion(count: records.count, revision: volumeAggregatesRevision)
    }

    /// The archive copy promoted from `record`, or nil. O(1) after the
    /// per-mutation rebuild — safe for inspector rows and filters.
    func masterArchiveCopy(of record: VideoRecord) -> VideoRecord? {
        archivePromotionIndex.copy(ofSourceID: record.id, in: records,
                                   version: promotionIndexVersion)
    }

    /// The source record an archive copy was promoted from, or nil when
    /// `record` is not an archive copy (or its source is gone).
    func promotionSource(of record: VideoRecord) -> VideoRecord? {
        guard isArchiveCopy(record), let src = record.derivedFrom else { return nil }
        return self.record(forID: src)
    }

    /// True when `record` IS a promoted archive copy.
    func isArchiveCopy(_ record: VideoRecord) -> Bool {
        record.derivationKind == ArchivePromotion.derivationKind
    }

    /// True when `path` lies inside the Master Archive root — canonical,
    /// component-wise (codex QA major c), never a string prefix.
    func isInsideMasterArchive(path: String) -> Bool {
        guard let root = masterArchiveRootPath else { return false }
        return ArchivePathResolver.isInside(path: path, root: root)
    }

    // MARK: Promote — plan + routing

    /// Build the confirmation-sheet plan for `ids` (spec §4). Runs once
    /// per user gesture on the main actor — O(selection), not O(records).
    func buildPromotePlan(recordIDs ids: [UUID]) -> ArchivePromotePlan? {
        guard let root = masterArchiveRootPath else { return nil }
        var entries: [ArchivePromotePlan.Entry] = []
        var skipped: [(id: UUID, filename: String, reason: ArchivePromotePlan.Skip)] = []
        var total: Int64 = 0
        for id in ids {
            guard let rec = record(forID: id) else { continue }
            if rec.isPurged {
                skipped.append((id, rec.filename, .purged)); continue
            }
            if isArchiveCopy(rec) {
                skipped.append((id, rec.filename, .isArchiveCopy)); continue
            }
            if isInsideMasterArchive(path: rec.fullPath) {
                skipped.append((id, rec.filename, .insideArchiveRoot)); continue
            }
            if masterArchiveCopy(of: rec) != nil {
                skipped.append((id, rec.filename, .alreadyPromoted)); continue
            }
            if !VolumeReachability.isReachable(path: rec.fullPath) {
                skipped.append((id, rec.filename, .offline)); continue
            }
            let facts = ArchivePathResolver.facts(for: rec)
            entries.append(.init(recordID: rec.id,
                                 filename: rec.filename,
                                 sizeBytes: rec.sizeBytes,
                                 folder: ArchivePathResolver.folder(for: facts.streamType,
                                                                    hint: facts.dateHint),
                                 dateHint: facts.dateHint,
                                 lowConfidenceDate: facts.dateIsLowConfidence))
            total += rec.sizeBytes
        }
        let free = Self.freeBytes(atPath: root)
        return ArchivePromotePlan(rootPath: root, entries: entries, skipped: skipped,
                                  totalBytes: total, freeBytesAtRoot: free)
    }

    /// Entry point for every "Promote to Archive" gesture: no master →
    /// the alert with the fix-it button; master → the confirmation sheet.
    func requestPromote(recordIDs ids: [UUID]) {
        guard !ids.isEmpty else { return }
        guard masterArchive != nil else {
            pendingPromoteWithoutMaster = ArchivePromoteWithoutMaster(recordIDs: ids)
            return
        }
        guard let plan = buildPromotePlan(recordIDs: ids) else { return }
        pendingPromoteRequest = ArchivePromoteRequest(plan: plan)
    }

    /// statfs-style free space for the volume holding `path`; nil when
    /// it cannot be determined (offline root).
    nonisolated static func freeBytes(atPath path: String) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let free = attrs[.systemFreeSize] as? NSNumber else { return nil }
        return free.int64Value
    }

    // MARK: Promote — per-file catalog step (main actor)

    /// The main-actor half of one promotion (spec §5.6): create the
    /// linked archive record, stamp the source, announce the mutation.
    /// Called by PromoteToArchiveJob AFTER the file is verified, renamed
    /// into place, fsynced, and its manifest row appended — so a record
    /// never exists for a copy that is not fully on disk.
    ///
    /// The archive record IS the job's probe of the destination file
    /// (`probed`: fresh id, path, scan context, ffprobe metadata — the
    /// copy is byte-identical so the probe agrees with the source; the
    /// job probes BEFORE the manifest append because the row needs the
    /// copy's id). Curated fields (people, dates, notes, tags, captions,
    /// transcript) are copied from the source here. `contentHash` keeps
    /// the probe's SEGMENTED signature (the catalog-wide identity key —
    /// a full sha256 in that field would never match anything); the
    /// full-file sha256 lives in the manifest row and the Promote
    /// journey stamp. Returns the new record.
    @discardableResult
    func registerPromotedCopy(source: VideoRecord,
                              destinationURL: URL,
                              relativePath: String,
                              sha256: String,
                              probed copy: VideoRecord,
                              promotedAt: Date = Date()) -> VideoRecord {
        // Self-contained provenance on the COPY (codex QA major b): the
        // source's id, path and volume live on this record, so a later
        // retired-volume cleanup that removes the source record leaves
        // the archive copy still able to say where it came from.
        copy.derivedFrom = source.id
        copy.derivationKind = ArchivePromotion.derivationKind
        copy.originalFullPath = source.fullPath
        copy.originVolume = source.volumeName
        // Full-file fixity — its OWN field (codex QA blocker 3), never
        // `contentHash` (the segmented candidate signature).
        copy.archiveFixity = ArchiveFixity(digest: sha256, verifiedAt: promotedAt,
                                           sizeBytes: copy.sizeBytes)
        copy.starRating = max(source.starRating, 3)
        copy.archiveStage = .masterAssigned
        copy.lifecycleStage = .archived
        copy.mediaDisposition = source.mediaDisposition == .unreviewed ? .important : source.mediaDisposition
        // People / dates / notes / tags carry over — same footage.
        copy.detectedPeople = source.detectedPeople
        copy.suspectedPeople = source.suspectedPeople
        copy.confirmedByUserPeople = source.confirmedByUserPeople
        copy.rejectedPeople = source.rejectedPeople
        copy.userDate = source.userDate
        copy.userDateConfidence = source.userDateConfidence
        copy.inferredRecordDate = source.inferredRecordDate
        copy.inferredDateConfidence = source.inferredDateConfidence
        copy.userNotes = source.userNotes
        copy.tags = source.tags
        copy.sceneCaptions = source.sceneCaptions
        copy.sceneCaptionModel = source.sceneCaptionModel
        copy.sceneCaptionDate = source.sceneCaptionDate
        copy.ocrDateCandidates = source.ocrDateCandidates
        copy.ocrText = source.ocrText
        copy.audioTranscript = source.audioTranscript
        copy.audioTranscriptModel = source.audioTranscriptModel
        copy.audioTranscriptDate = source.audioTranscriptDate
        copy.dossierProcessedAt = source.dossierProcessedAt
        copy.dossierProcessedBy = source.dossierProcessedBy
        copy.avidClipName = source.avidClipName
        copy.avidTapeName = source.avidTapeName

        let stamp = ISO8601DateFormatter().string(from: promotedAt)
        let sourceNote = "Promote \(stamp): promoted to Master Archive as \(relativePath)"
        let copyNote = "Promote \(stamp): promoted from \(source.fullPath) · sha256 \(sha256)"
        source.notes = source.notes.isEmpty ? sourceNote : "\(source.notes)\n\(sourceNote)"
        copy.notes = copy.notes.isEmpty ? copyNote : "\(copy.notes)\n\(copyNote)"

        // Source: stays live; only its stage advances (spec §3).
        if source.archiveStage < .masterAssigned {
            source.archiveStage = .masterAssigned
        }
        if source.starRating < 3 { source.starRating = 3 }
        source.masterLocation = masterArchive?.targetPath ?? source.masterLocation
        copy.masterLocation = source.masterLocation

        if let existing = records.firstIndex(where: { $0.fullPath == destinationURL.path }) {
            records[existing] = copy
        } else {
            records.append(copy)
        }
        searchIndex.update(copy)
        searchIndex.update(source)
        noteCatalogRecordsMutated()
        saveCatalogDebounced()

        masterArchiveLog.info("promote: \(source.filename, privacy: .public) → \(relativePath, privacy: .public) (copy \(copy.id.uuidString.prefix(8), privacy: .public))")
        return copy
    }
}
