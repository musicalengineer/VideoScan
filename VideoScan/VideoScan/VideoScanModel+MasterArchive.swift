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
        /// Archival readiness (ArchiveReadiness, 2026-08-16): playable /
        /// audio / format / date + warnings. Computed once per plan entry.
        let readiness: ArchiveReadiness
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
    /// "Archive anyway (I know this file)" — the user's explicit override
    /// that lets un-probeable entries through (Rick: never block except
    /// un-probeable, and even that within reason). Set by the sheet.
    var allowUnprobeable: Bool = false

    // MARK: Readiness counters (O(selection))
    var audioNotVerifiedCount: Int { entries.filter { $0.readiness.audio == .notVerified }.count }
    var audioProblemCount: Int { entries.filter { if case .verifiedProblem = $0.readiness.audio { return true }; return false }.count }
    var atRiskFormatCount: Int { entries.filter { if case .atRisk = $0.readiness.format { return true }; return false }.count }
    var dateWarningCount: Int { entries.filter { $0.readiness.date != .known }.count }
    var unprobeableCount: Int { entries.filter { $0.readiness.blocking }.count }

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
    /// Archive totals for the sidebar panel: promoted copies whose full-file
    /// fixity was recorded (i.e. verified at promotion), and their bytes.
    private(set) var verifiedCount = 0
    private(set) var verifiedBytes: Int64 = 0
    /// Copies present in the catalog WITHOUT a fixity record — should be
    /// zero; anything here was cataloged by rescan, not by Promote.
    private(set) var unverifiedCount = 0
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

    struct Totals: Equatable {
        var verified: Int
        var verifiedBytes: Int64
        var unverified: Int
    }
    func totals(in records: [VideoRecord], version: RecordsVersion) -> Totals {
        rebuildIfNeeded(records, version: version)
        return Totals(verified: verifiedCount, verifiedBytes: verifiedBytes, unverified: unverifiedCount)
    }

    private func rebuildIfNeeded(_ records: [VideoRecord], version: RecordsVersion) {
        if builtFor == version { return }
        rebuildCount += 1
        copyBySource.removeAll(keepingCapacity: true)
        sourceByCopy.removeAll(keepingCapacity: true)
        verifiedCount = 0; verifiedBytes = 0; unverifiedCount = 0
        for rec in records where rec.derivationKind == ArchivePromotion.derivationKind && !rec.isPurged {
            if rec.archiveFixity != nil {
                verifiedCount += 1
                verifiedBytes += rec.sizeBytes
            } else {
                unverifiedCount += 1
            }
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

    /// Volume-identity refusal (codex R3 blocker 1): when the designation
    /// carries a volume UUID and its root path is reachable, the volume
    /// mounted there NOW must carry the SAME UUID. A different disk mounted
    /// at the same path (or a volume that no longer reports a UUID) is a
    /// hard refusal for every write path — Initialize on that path is fine
    /// (it re-designates), promotion is not. nil = identity OK / not
    /// checkable (no UUID recorded, or root offline).
    func masterArchiveIdentityRefusal() -> String? {
        guard let d = masterArchive, let expected = d.volumeUUID,
              FileManager.default.fileExists(atPath: d.rootPath) else { return nil }
        let current = MasterArchiveDesignation.volumeUUID(forPath: d.targetPath)
        guard current != expected else { return nil }
        let label = VolumeReachability.displayLabel(forPath: d.targetPath)
        let seen = current.map { "volume UUID \($0)" } ?? "a volume that reports no UUID"
        return "The volume mounted at \(label) (\(d.targetPath)) is NOT the Master Archive volume — it has \(seen), but the archive was initialized on volume UUID \(expected). Nothing will be written there. Connect the real archive volume, or re-run Initialize on this one to make it the master."
    }

    /// Volume-UUID-first re-resolution (codex QA R1 blocker 1 + R3
    /// blocker 1). Called at load, on every mount notification, and after
    /// an import. Outcomes:
    ///   - root reachable AND UUID matches (or no UUID recorded) → fine;
    ///   - root reachable but UUID differs → look for the REAL volume by
    ///     UUID under /Volumes and rehome to it; if it is not mounted, the
    ///     designation stays but `masterArchiveIdentityMismatch` is set
    ///     (the UI shows it; every write path refuses via
    ///     `masterArchiveIdentityRefusal`);
    ///   - root unreachable → look for the volume by UUID and rehome.
    func reresolveMasterArchiveMount() {
        masterArchiveIdentityMismatch = nil
        guard let current = masterArchive, let uuid = current.volumeUUID else { return }
        let fm = FileManager.default
        let rootExists = fm.fileExists(atPath: current.rootPath)
        if rootExists, MasterArchiveDesignation.volumeUUID(forPath: current.targetPath) == uuid { return }
        // The stored target may be a folder inside a volume — recover the
        // volume-relative tail so a rename keeps the sub-folder.
        let mounts = (try? fm.contentsOfDirectory(atPath: "/Volumes")) ?? []
        for name in mounts {
            let mountPath = "/Volumes/\(name)"
            guard MasterArchiveDesignation.volumeUUID(forPath: mountPath) == uuid else { continue }
            let oldComps = URL(fileURLWithPath: current.targetPath).standardizedFileURL.pathComponents
            // "/Volumes/<old>/<tail…>" → keep <tail…> under the new mount.
            let tail = oldComps.count > 3 ? Array(oldComps[3...]) : []
            var newURL = URL(fileURLWithPath: mountPath, isDirectory: true)
            for comp in tail { newURL.appendPathComponent(comp) }
            let rehomed = current.rehomed(to: newURL.path)
            guard fm.fileExists(atPath: rehomed.rootPath),
                  !Self.samePath(rehomed.targetPath, current.targetPath) else { continue }
            masterArchive = rehomed
            noteCatalogRecordsMutated()
            saveCatalogDebounced()
            log("Master Archive volume found at \(rehomed.targetPath) (same volume UUID; was \(current.targetPath)).")
            masterArchiveLog.notice("rehomed master archive \(current.targetPath, privacy: .public) → \(rehomed.targetPath, privacy: .public)")
            return
        }
        if rootExists, let refusal = masterArchiveIdentityRefusal() {
            masterArchiveIdentityMismatch = refusal
            log("Master Archive: \(refusal)")
            masterArchiveLog.error("master archive identity mismatch at \(current.targetPath, privacy: .public)")
        }
    }

    /// The designated CatalogScanTarget's id, or nil.
    var masterArchiveTargetID: UUID? { masterArchiveTarget?.id }

    /// The master's scan target resolved by STABLE identity (codex R3
    /// major 8): canonical path first, then any target whose mounted
    /// volume carries the designation's UUID. nil = cannot be resolved —
    /// callers that need the retired/role state must REFUSE, not proceed
    /// (unknown state is not "not retired").
    func resolvedMasterArchiveTarget() -> CatalogScanTarget? {
        if let byPath = masterArchiveTarget { return byPath }
        guard let uuid = masterArchive?.volumeUUID else { return nil }
        return scanTargets.first { t in
            !t.searchPath.isEmpty && t.isReachable
                && MasterArchiveDesignation.volumeUUID(forPath: t.searchPath) == uuid
        }
    }

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
        // Read-only viewer (codex R3 blocker 2): no scaffold, no designation
        // — same refusal every other write path makes.
        if isReadOnly {
            log("Initialize Master Archive refused — this Mac is a read-only viewer of the catalog.")
            throw MasterArchiveError.refused("This Mac is a read-only viewer of the catalog — the Master Archive can only be initialized on the master Mac.")
        }
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
        masterArchiveIdentityMismatch = nil
        noteCatalogRecordsMutated()
        saveCatalogDebounced()

        // Finder marker (best-effort; never fails Initialize).
        let badged = MasterArchiveIcon.apply(volumeOrFolderPath: targetPath, archiveRootPath: rootURL.path)
        if !badged.isEmpty { masterArchiveLog.info("initialize: Finder icon set on \(badged.count) path(s)") }

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
        guard let current = masterArchive else { return }
        MasterArchiveIcon.remove(volumeOrFolderPath: current.targetPath, archiveRootPath: current.rootPath)
        masterArchive = nil
        noteCatalogRecordsMutated()
        saveCatalogDebounced()
        log("Master Archive designation cleared (files on disk untouched).")
    }

    /// Filesystem-only scaffold — the tree + both index files. Pure
    /// function of `rootURL`; returns the paths it CREATED (empty on a
    /// second run). Never truncates or rewrites an existing file.
    /// Descriptor-relative (codex R3 blocker 3): the target directory is
    /// opened O_DIRECTORY|O_NOFOLLOW and everything below it is
    /// mkdirat/openat from that descriptor — a symlink standing in for
    /// the root, `00_Index`, a bucket, or an index file is REFUSED, never
    /// followed. Index files are created O_EXCL|O_NOFOLLOW, F_FULLFSYNC'd,
    /// and the index directory fsynced (failures throw).
    /// `nonisolated` so tests can drive it against a temp dir without a
    /// model. (≈ a free function; no shared state.)
    nonisolated static func scaffoldMasterArchive(rootURL: URL) throws -> [String] {
        var created: [String] = []
        let root = PathScope.normalize(rootURL.standardizedFileURL.path)
        let parent = (root as NSString).deletingLastPathComponent
        let rootName = (root as NSString).lastPathComponent
        let parentFD = try ArchivePromoteEngine.openDirectory(parent)
        defer { close(parentFD) }
        // Root folder: create-if-missing, then open through the parent fd.
        if ArchivePromoteEngine.FileIdentity.at(dirfd: parentFD, name: rootName) == nil {
            guard mkdirat(parentFD, rootName, 0o755) == 0 || errno == EEXIST else {
                throw ArchivePromoteEngine.Failure.createFailed(root, errno: errno)
            }
            created.append(root)
        }
        let rootFD = try ArchivePromoteEngine.descend(from: parentFD, components: [rootName],
                                                      create: false, displayRoot: parent)
        defer { close(rootFD) }
        // Buckets + index folder: mkdirat + openat(O_NOFOLLOW) each.
        for folder in [MasterArchiveLayout.indexFolder] + MasterArchiveLayout.buckets {
            let existed = ArchivePromoteEngine.FileIdentity.at(dirfd: rootFD, name: folder) != nil
            let fd = try ArchivePromoteEngine.descend(from: rootFD, components: [folder],
                                                      create: true, displayRoot: root)
            close(fd)
            if !existed { created.append(root + "/" + folder) }
        }
        guard ArchivePromoteEngine.barriers.fsync(rootFD) == 0 else {
            throw ArchivePromoteEngine.Failure.durabilityBarrierFailed("fsync on \(root)")
        }
        let indexFD = try ArchivePromoteEngine.descend(from: rootFD, components: [MasterArchiveLayout.indexFolder],
                                                       create: false, displayRoot: root)
        defer { close(indexFD) }
        if try ArchivePromoteEngine.createIndexFileIfMissing(
            indexFD: indexFD, name: MasterArchiveLayout.manifestFilename,
            contents: Data((MasterArchiveLayout.manifestHeader + "\n").utf8)) {
            created.append(MasterArchiveLayout.manifestURL(rootPath: root).path)
        }
        if try ArchivePromoteEngine.createIndexFileIfMissing(
            indexFD: indexFD, name: MasterArchiveLayout.readmeFilename,
            contents: Data(MasterArchiveLayout.readmeText.utf8)) {
            created.append(MasterArchiveLayout.readmeURL(rootPath: root).path)
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

    /// Sidebar totals: verified (fixity-recorded) archive copies + bytes,
    /// and any copies lacking fixity. O(1) after the per-mutation rebuild.
    var masterArchiveTotals: ArchivePromotionIndex.Totals {
        archivePromotionIndex.totals(in: records, version: promotionIndexVersion)
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
                                 lowConfidenceDate: facts.dateIsLowConfidence,
                                 readiness: ArchiveReadiness.assess(record: rec)))
            total += rec.sizeBytes
        }
        let free = Self.freeBytes(atPath: root)
        return ArchivePromotePlan(rootPath: root, entries: entries, skipped: skipped,
                                  totalBytes: total, freeBytesAtRoot: free)
    }

    /// Every plan-time skip becomes a durable decisions-log line AND a
    /// console line naming the file and the reason — so "I promoted five,
    /// four landed" is answerable from the logs, not from memory.
    private func recordPromoteSkips(_ plan: ArchivePromotePlan) {
        guard !plan.skipped.isEmpty else { return }
        let now = Date()
        var entries: [ArchivePromoteDecisions.Entry] = []
        for skip in plan.skipped {
            let rec = record(forID: skip.id)
            var detail: String?
            if skip.reason == .alreadyPromoted, let rec, let copy = masterArchiveCopy(of: rec) {
                detail = copy.fullPath
            }
            let reason = Self.skipReasonLabel(skip.reason)
            entries.append(.init(at: now, recordID: skip.id, filename: skip.filename,
                                 sourcePath: rec?.fullPath ?? "", decision: "skipped",
                                 reason: reason, detail: detail))
            log("promote: skipped \(skip.filename) — \(reason)\(detail.map { " (\($0))" } ?? "")")
        }
        let root = plan.rootPath
        let batch = entries
        Task.detached(priority: .utility) {
            _ = ArchivePromoteDecisions.record(batch, rootPath: root)
        }
    }

    nonisolated static func skipReasonLabel(_ reason: ArchivePromotePlan.Skip) -> String {
        switch reason {
        case .alreadyPromoted: return "already in the Master Archive"
        case .isArchiveCopy: return "is itself an archive copy"
        case .insideArchiveRoot: return "already lives inside the archive tree"
        case .purged: return "record is purged"
        case .offline: return "source volume offline"
        }
    }

    /// Entry point for every "Promote to Archive" gesture: no master →
    /// the alert with the fix-it button; master → the confirmation sheet.
    func requestPromote(recordIDs ids: [UUID]) {
        guard !ids.isEmpty else { return }
        if isReadOnly {
            log("Promote refused — this Mac is a read-only viewer of the catalog.")
            return
        }
        guard masterArchive != nil else {
            pendingPromoteWithoutMaster = ArchivePromoteWithoutMaster(recordIDs: ids)
            return
        }
        if let refusal = masterArchiveIdentityRefusal() {
            masterArchiveIdentityMismatch = refusal
            log("Promote refused — \(refusal)")
            return
        }
        guard let plan = buildPromotePlan(recordIDs: ids) else { return }
        recordPromoteSkips(plan)
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
                              promotedAt: Date = Date(),
                              readiness: ArchiveReadiness? = nil) -> VideoRecord {
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
        let readinessNote = readiness.map { " · readiness: \($0.summary)" } ?? ""
        let copyNote = "Promote \(stamp): promoted from \(source.fullPath) · sha256 \(sha256)\(readinessNote)"
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

    /// Source-gone registration (codex R3 major 7): the archive copy is
    /// verified, in the manifest and on disk, but its SOURCE record has
    /// left the catalog (retired-volume cleanup, purge). The copy must
    /// STILL become a self-contained catalog record from journal/manifest
    /// provenance: `derivedFrom` keeps the (now unresolvable) source id,
    /// `originalFullPath` / `originVolume` come from the journal, fixity is
    /// the verified digest, dates/people/rating come from the manifest row
    /// when it has them. Returns the new record.
    @discardableResult
    func registerOrphanPromotedCopy(sourceID: UUID,
                                    sourcePath: String,
                                    destinationURL: URL,
                                    relativePath: String,
                                    sha256: String,
                                    probed copy: VideoRecord,
                                    manifestRow: [String]? = nil,
                                    promotedAt: Date = Date()) -> VideoRecord {
        copy.derivedFrom = sourceID
        copy.derivationKind = ArchivePromotion.derivationKind
        copy.originalFullPath = sourcePath
        copy.originVolume = VolumeReachability.volumeName(forPath: sourcePath)
        copy.archiveFixity = ArchiveFixity(digest: sha256, verifiedAt: promotedAt, sizeBytes: copy.sizeBytes)
        copy.starRating = 3
        copy.archiveStage = .masterAssigned
        copy.lifecycleStage = .archived
        copy.mediaDisposition = .important
        copy.masterLocation = masterArchive?.targetPath ?? ""
        if let row = manifestRow, row.count >= 12 {
            // record_date "1992-07-15" / "1992-07-xx" / "1992-xx-xx" → user date at that precision.
            let date = row[8]
            let parts = date.split(separator: "-").map(String.init)
            if let y = parts.first, y.count == 4, Int(y) != nil {
                var canonical = y
                if parts.count > 1, parts[1] != "xx" { canonical += "-" + parts[1] }
                if parts.count > 2, parts[2] != "xx", canonical.count == 7 { canonical += "-" + parts[2] }
                if let c = UserDateEntry.canonicalize(canonical) {
                    copy.userDate = c
                    copy.userDateConfidence = row[9] == "user-known" ? UserDateConfidence.known.rawValue
                                                                     : UserDateConfidence.estimated.rawValue
                }
            }
            let people = row[10].split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !people.isEmpty { copy.detectedPeople = people }
            if let stars = Int(row[11]) { copy.starRating = max(3, stars) }
        }
        let stamp = ISO8601DateFormatter().string(from: promotedAt)
        let note = "Promote \(stamp): promoted from \(sourcePath) (source record \(sourceID.uuidString) no longer in the catalog) · sha256 \(sha256)"
        copy.notes = copy.notes.isEmpty ? note : "\(copy.notes)\n\(note)"

        if let existing = records.firstIndex(where: { $0.fullPath == destinationURL.path }) {
            records[existing] = copy
        } else {
            records.append(copy)
        }
        searchIndex.update(copy)
        noteCatalogRecordsMutated()
        saveCatalogDebounced()
        masterArchiveLog.notice("promote: cataloged orphan archive copy \(relativePath, privacy: .public) (source \(sourceID.uuidString.prefix(8), privacy: .public) gone)")
        return copy
    }
}
