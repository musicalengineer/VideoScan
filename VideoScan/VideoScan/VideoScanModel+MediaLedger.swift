// VideoScanModel+MediaLedger.swift
// The model half of promote-and-prune stage 2 (Rick 2026-09-12,
// docs/promote_and_prune_workflow_design.md):
//
//   - LEDGER WRITERS at the existing hooks — one small builder
//     (`ledgerEvent`) and per-verb helpers the existing methods call
//     after their own work: Promote completion (archived, one per file,
//     batch id), recordAttestation (attestation), Tidy / Remove from
//     Catalog / Put Back (setAside / putBack), Inspector place + date
//     edits (placeSet / dateSet), Delete Confirmed Junk + Discard
//     (copyTrashed / copyDeleted), Restore / Undo (restored). Nothing
//     existing is removed or changed; the ledger is additive.
//   - SNAPSHOTS: `archiveCopySnapshots()` is the ONE main-actor pass
//     over `records` that captures the Sendable facts the pure
//     ArchiveCopyFamilies / PrunePlan read; everything after it runs on
//     the cooperative pool (`@concurrent`).
//   - `batchProtection(for:)` — the protection line for a Promote batch,
//     off-main (the completion chip and the sheet).
//   - `prunePlan(for:options:)` — the dry-run plan for the sheet: families
//     by content + provenance, and the "might be copies" pass (name-
//     related records outside the family) in the same off-main call.
//   - `hashToConfirm(recordIDs:)` (v3, 2026-09-20) — the sheet's "Hash to
//     confirm": the segmented content hash for the records named, off-
//     main, stored on the record and written through to the probe cache
//     so a rescan never erases it; the sheet re-plans afterwards.
//   - `logArchivedWhatNextPlan(_:batchID:)` — one line per family in the
//     log when the sheet opens, so "why couldn't I select X" is always
//     answerable.
//   - `offerArchivedWhatNext(...)` — sets the sheet driver ONCE per batch.
//
// TWO FACTS, NOT ONE (2026-09-21 — Rick: "'M4drive' was said 'not
// connected' in some cases which is weird. So I could only delete some
// videos."): the boot volume is named M4drive, and `VolumeReachability
// .isReachable(path:)` answers "does this FILE exist" for internal paths.
// A row whose file had been moved or deleted outside the app (13 in the
// live catalog: 8 Angel buffer companions from batches cleared before the
// companion-retirement fix, 5 ~/Movies files) read as "drive not
// connected". Now the snapshot's `isOnline` is the VOLUME
// (`VolumeReachability.isVolumeReachable` — the mount root, never the
// file), and `fileExists` is a stat of the working copies in the batch's
// families, taken OFF the main actor inside the same `@concurrent` call
// that builds the plan (never O(records) stats on main). PrunePlan turns
// `isOnline && !fileExists` into `.fileMissing`: listed, disabled, never a
// copy for the tier / keeper / device counts, and removable from the
// catalog right there (`removeMissingCopiesFromCatalog` — the existing
// purge tombstone, a `setAside` "removed-from-catalog" ledger line,
// nothing on disk).
//
// (For Rick: `Task { … }` inherits the main actor; the `@concurrent`
// static functions are what actually leave it — the same discipline as
// VideoScanModel+BackupAttestations.)

import Foundation

// MARK: - The "Archived — what next?" sheet driver

/// Everything the sheet needs, captured when the batch finished (a value;
/// the sheet re-reads live records only through the model).
struct ArchivedWhatNextRequest: Identifiable {
    enum Source: Equatable { case promoteBatch, tidyBacklog }
    let id = UUID()
    let batchID: String
    /// The batch's records (sources for a Promote batch; the outside-
    /// archive copies for the Tidy backlog). Families are keyed by content.
    let recordIDs: [UUID]
    let fileCount: Int
    let totalBytes: Int64
    /// "FamilyArchive" — the archive volume's display label.
    let archiveLabel: String
    let protection: ProtectionSummary
    let source: Source
}

extension VideoScanModel {

    // MARK: Event builders

    /// The family key for a record — the ledger's `contentKey`.
    nonisolated static func ledgerContentKey(for rec: VideoRecord) -> String {
        MediaLedgerEvent.contentKey(contentHash: rec.contentHash, partialMD5: rec.partialMD5,
                                    sizeBytes: rec.sizeBytes)
    }

    /// One ledger line for `rec`. Pure value; nothing is written here.
    func ledgerEvent(_ kind: MediaLedgerEvent.Kind, for rec: VideoRecord,
                     by: MediaLedgerEvent.Actor, at: Date = Date(),
                     batchID: String? = nil, detail: [String: String] = [:]) -> MediaLedgerEvent {
        MediaLedgerEvent(at: at, event: kind, recordID: rec.id,
                         contentKey: Self.ledgerContentKey(for: rec),
                         filename: rec.filename, fullPath: rec.fullPath, by: by,
                         batchID: batchID, detail: detail)
    }

    /// Hand a batch to the ledger's ordered off-main worker. Returns the
    /// flush task (tests await it). Never blocks the caller.
    @discardableResult
    func ledgerAppend(_ events: [MediaLedgerEvent]) -> Task<Void, Never>? {
        mediaLedger.append(events)
    }

    // MARK: Hooks (called by the existing verbs AFTER their own work)

    /// Inspector "Where was this?" saved or cleared a place.
    @discardableResult
    func noteUserPlaceEdited(_ rec: VideoRecord, by: MediaLedgerEvent.Actor = .rick) -> Task<Void, Never>? {
        ledgerAppend([ledgerEvent(.placeSet, for: rec, by: by, detail: [
            MediaLedgerEvent.Detail.place: rec.userPlace ?? "",
            MediaLedgerEvent.Detail.confidence: rec.userPlace == nil ? "" : (rec.userPlaceConfidence ?? UserPlaceConfidence.estimated.rawValue),
        ])])
    }

    /// Inspector "When was this?" saved or cleared a date.
    @discardableResult
    func noteUserDateEdited(_ rec: VideoRecord, by: MediaLedgerEvent.Actor = .rick) -> Task<Void, Never>? {
        ledgerAppend([ledgerEvent(.dateSet, for: rec, by: by, detail: [
            MediaLedgerEvent.Detail.date: rec.userDate ?? "",
            MediaLedgerEvent.Detail.confidence: rec.userDate == nil ? "" : (rec.userDateConfidence ?? UserDateConfidence.estimated.rawValue),
        ])])
    }

    /// Tidy / Remove from Catalog set records aside (reason = the
    /// CatalogScopePolicy raw key, or "removed-from-catalog" for a purge).
    @discardableResult
    func ledgerSetAside(_ recs: [VideoRecord], reason: String, by: MediaLedgerEvent.Actor,
                        at: Date = Date(), batchID: String? = nil) -> Task<Void, Never>? {
        ledgerAppend(recs.map {
            ledgerEvent(.setAside, for: $0, by: by, at: at, batchID: batchID,
                        detail: [MediaLedgerEvent.Detail.reason: reason])
        })
    }

    /// Put Back / Undo Tidy.
    @discardableResult
    func ledgerPutBack(_ recs: [VideoRecord], by: MediaLedgerEvent.Actor = .rick,
                       at: Date = Date()) -> Task<Void, Never>? {
        ledgerAppend(recs.map { ledgerEvent(.putBack, for: $0, by: by, at: at) })
    }

    /// Restore / Undo purge.
    @discardableResult
    func ledgerRestored(_ recs: [VideoRecord], by: MediaLedgerEvent.Actor = .rick,
                        at: Date = Date()) -> Task<Void, Never>? {
        ledgerAppend(recs.map { ledgerEvent(.restored, for: $0, by: by, at: at) })
    }

    /// A copy left the disk: to the Trash (`permanent == false`) or gone.
    /// `extraDetail` rides along on every line (Delete Duplicates adds
    /// its copy-count tier and the remaining verified copies).
    @discardableResult
    func ledgerCopyRemoved(_ recs: [VideoRecord], permanent: Bool, by: MediaLedgerEvent.Actor,
                           at: Date = Date(), batchID: String? = nil,
                           extraDetail: [String: String] = [:]) -> Task<Void, Never>? {
        ledgerAppend(recs.map {
            var detail = extraDetail
            detail[MediaLedgerEvent.Detail.volume] = $0.volumeName
            detail[MediaLedgerEvent.Detail.mode] = permanent ? "permanent" : "trash"
            return ledgerEvent(permanent ? .copyDeleted : .copyTrashed, for: $0, by: by, at: at, batchID: batchID,
                               detail: detail)
        })
    }

    /// Archive Angel attention memory (Phase 1, 2026-09-19) — ONE entry
    /// point for `angelProposed` / `angelSkipped` / `angelCleared`: the
    /// ledger line (audit), the in-memory summary the scorer reads, and a
    /// poke to the sweep so the grades catch up (debounced). `scores` is
    /// per record id for `angelProposed`. Records no longer in the catalog
    /// are skipped. Returns the flush task (tests await it).
    @discardableResult
    func ledgerAngelAttention(_ kind: MediaLedgerEvent.Kind, recordIDs: [UUID],
                              batchID: String?, reason: String? = nil,
                              scores: [UUID: Int] = [:], at: Date = Date()) -> Task<Void, Never>? {
        guard ArchiveAngelAttentionStore.attentionKinds.contains(kind) else { return nil }
        let by: MediaLedgerEvent.Actor = kind == .angelProposed ? .angel : .rick
        var events: [MediaLedgerEvent] = []
        for id in recordIDs {
            guard let rec = record(forID: id) else { continue }
            var detail: [String: String] = [:]
            if let reason, !reason.isEmpty { detail[MediaLedgerEvent.Detail.reason] = reason }
            if let score = scores[id] { detail[MediaLedgerEvent.Detail.score] = String(score) }
            events.append(ledgerEvent(kind, for: rec, by: by, at: at, batchID: batchID, detail: detail))
        }
        guard !events.isEmpty else { return nil }
        archiveAngelAttention.note(events)
        archiveAngelSweep.noteCatalogChanged()
        return ledgerAppend(events)
    }

    /// recordAttestation's ledger twin (one line per record per answer).
    func ledgerAttestationEvents(_ recs: [VideoRecord], attestation a: BackupAttestation,
                                 by: MediaLedgerEvent.Actor, batchID: String?) -> [MediaLedgerEvent] {
        recs.map {
            ledgerEvent(.attestation, for: $0, by: by, at: a.attestedAt, batchID: batchID, detail: [
                MediaLedgerEvent.Detail.kind: a.kind.rawValue,
                MediaLedgerEvent.Detail.answer: a.answer.token,
                MediaLedgerEvent.Detail.label: a.label ?? "",
            ])
        }
    }

    // MARK: Snapshots (ONE main-actor pass)

    /// The default `isOnline`: is the VOLUME mounted — never "does the
    /// file exist" (2026-09-21). A missing file on the boot disk is a
    /// missing file, not a disconnected drive.
    nonisolated static func volumeIsOnline(_ rec: VideoRecord) -> Bool {
        VolumeReachability.isVolumeReachable(path: rec.fullPath)
    }

    /// The default `fileExists`: one stat. Called off the main actor, for
    /// the working copies of the batch's families only.
    nonisolated static func fileIsOnDisk(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// The Sendable facts about every active record — what the pure
    /// families / protection / prune code reads. O(records) value
    /// capture on the main actor (the Tidy dry-run does the same); the
    /// heavy work happens off it. `isOnline` is injectable so tests never
    /// touch a volume. NOTHING here touches the disk: `fileExists` is
    /// left `true` (unknown) and filled off-main by the callers below.
    ///
    /// v3 (2026-09-20): `derivedFrom` / `derivationKind` ride along so a
    /// version can join its original's family off-main (a cleanup output
    /// has no kind stamp — it is tagged "cleanup" from its recipe id);
    /// `hasHumanNote` reads only lines a PERSON could have written
    /// (ArchiveAngelCandidate.hasHumanNote — 9,977 of 13,842 records
    /// carry ffprobe/recipe text in `userNotes` that nobody typed, and
    /// those must not read as "has your note").
    func archiveCopySnapshots(isOnline: (VideoRecord) -> Bool = VideoScanModel.volumeIsOnline)
    -> [ArchiveCopySnapshot] {
        // Per-volume facts from the scan targets (dozens, one statfs each).
        struct VolumeFacts { var connectedWorking: Bool; var free: Int64? }
        var volumes: [String: VolumeFacts] = [:]
        let archiveVolume = masterArchive.map { VolumeReachability.volumeName(forPath: $0.targetPath) }
        for t in scanTargets where !t.searchPath.isEmpty {
            let name = VolumeReachability.volumeName(forPath: t.searchPath)
            let working = t.isReachable && !t.isRetired && t.role != .archive && !t.isScratchVolume
                && name != archiveVolume
            let free = working ? Self.freeBytes(atPath: t.searchPath) : nil
            if let have = volumes[name] {
                volumes[name] = VolumeFacts(connectedWorking: have.connectedWorking || working,
                                            free: max(have.free ?? -1, free ?? -1) < 0 ? nil : max(have.free ?? -1, free ?? -1))
            } else {
                volumes[name] = VolumeFacts(connectedWorking: working, free: free)
            }
        }
        var out: [ArchiveCopySnapshot] = []
        out.reserveCapacity(records.count)
        // One archive-volume snapshot for the pass (Rick 2026-09-22: a
        // copy elsewhere on FamilyArchive is never offered for the Trash).
        let archiveVolumeGuard = archiveVolumeProtection()
        for r in records where !r.isPurged {
            let archiveCopy = isArchiveCopy(r)
            let inside = !archiveCopy && isInsideMasterArchive(path: r.fullPath)
            let onArchiveVolume = !archiveCopy && !inside
                && bulkDeleteRefusal(r, volume: archiveVolumeGuard) != nil
            let volume = r.volumeName
            let facts = volumes[volume]
            let online = isOnline(r)
            // The ONE repair-kinds set (VideoScanCore) — QA MINOR 4.
            let isVersion = !archiveCopy && r.derivedFrom != nil
                && !(r.derivationKind.map { VideoRecord.repairDerivationKinds.contains($0) } ?? false)
            let kind = r.derivationKind ?? (r.cleanupRecipeID == nil ? nil : "cleanup")
            out.append(ArchiveCopySnapshot(
                id: r.id, filename: r.filename, fullPath: r.fullPath, volumeName: volume,
                sizeBytes: r.sizeBytes,
                contentKey: Self.ledgerContentKey(for: r),
                promotedFromID: archiveCopy ? r.derivedFrom : nil,
                isArchiveCopy: archiveCopy,
                fixityVerified: (archiveCopy || inside) && r.archiveFixity != nil,
                isInsideArchiveRoot: inside,
                isOnline: online,
                isPairMember: CatalogScopePolicy.isPairProtected(r),
                isVersion: isVersion,
                hasHumanNote: ArchiveAngelCandidate.hasHumanNote(r.userNotes),
                starRating: r.starRating,
                disposition: r.mediaDisposition,
                attestations: r.backupAttestations,
                volumeIsConnectedWorking: !(archiveCopy || inside)
                    && (facts?.connectedWorking ?? (online && volume != archiveVolume && !volume.isEmpty)),
                volumeFreeBytes: facts?.free,
                isPurged: r.isPurged,
                derivedFrom: r.derivedFrom,
                derivationKind: kind,
                isOnArchiveVolume: onArchiveVolume))
        }
        return out
    }

    // MARK: Protection (off-main)

    /// The protection line for a batch — snapshot on main, group +
    /// stat the working copies + summarize on the cooperative pool. A
    /// missing file is not a copy.
    func batchProtection(for recordIDs: [UUID],
                         isOnline: (VideoRecord) -> Bool = VideoScanModel.volumeIsOnline,
                         fileExists: @escaping @Sendable (String) -> Bool = VideoScanModel.fileIsOnDisk) async -> ProtectionSummary {
        let snaps = archiveCopySnapshots(isOnline: isOnline)
        return await Self.protectionOffMain(batch: Set(recordIDs), snapshots: snaps, fileExists: fileExists)
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func protectionOffMain(batch: Set<UUID>, snapshots: [ArchiveCopySnapshot],
                                              fileExists: @escaping @Sendable (String) -> Bool = VideoScanModel.fileIsOnDisk) async -> ProtectionSummary {
        let families = ArchiveCopyFamilies.checkingFiles(
            ArchiveCopyFamilies.group(batch: batch, snapshots: snapshots), fileExists: fileExists)
        return ArchiveCopyFamilies.protection(families: families)
    }

    // MARK: Prune plan (off-main, dry run)

    /// The importance bar as Settings has it (defaults until edited).
    var importanceBar: ImportanceBar { ImportanceBar.load(defaults: .standard) }

    /// The dry-run plan for the sheet: families by content + provenance,
    /// the stat of every working copy in them (`fileExists` — injectable
    /// so synthetic-path tests never touch the disk), and the name-related
    /// "might be copies" per family, in ONE off-main pass over the
    /// snapshots.
    func prunePlan(for recordIDs: [UUID], options: PrunePlan.Options,
                   isOnline: (VideoRecord) -> Bool = VideoScanModel.volumeIsOnline,
                   fileExists: @escaping @Sendable (String) -> Bool = VideoScanModel.fileIsOnDisk) async -> PrunePlan {
        let snaps = archiveCopySnapshots(isOnline: isOnline)
        return await Self.prunePlanOffMain(batch: Set(recordIDs), snapshots: snaps, options: options,
                                           fileExists: fileExists)
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func prunePlanOffMain(batch: Set<UUID>, snapshots: [ArchiveCopySnapshot],
                                             options: PrunePlan.Options,
                                             fileExists: @escaping @Sendable (String) -> Bool = VideoScanModel.fileIsOnDisk) async -> PrunePlan {
        // The stat happens HERE, off-main, for the batch's families only
        // (never the whole catalog): a missing file becomes `.fileMissing`.
        let families = ArchiveCopyFamilies.checkingFiles(
            ArchiveCopyFamilies.group(batch: batch, snapshots: snapshots), fileExists: fileExists)
        // Name-relatedness = the Angel's event-family stem: derivative
        // tokens (_trimmed, _balanced, .vs.edit…) and share-out tokens
        // (clip 1, part 2, v3) stripped, case-folded.
        let related = ArchiveCopyFamilies.nameRelated(families: families, snapshots: snapshots,
                                                      baseStem: ArchiveAngelFamily.baseStem)
        return PrunePlan.compute(families: families, related: related, options: options)
    }

    /// One log line per family, written when the sheet opens (and after a
    /// hash-to-confirm re-plan), so the log always says why a copy could
    /// or could not be selected. The header names the missing rows too
    /// ("2 missing (removable)") — the rows a Remove from catalog can
    /// clear.
    func logArchivedWhatNextPlan(_ plan: PrunePlan, batchID: String) {
        let missing = plan.missingCount
        log("Archived — what next? [\(batchID)]: \(plan.families.count) famil\(plan.families.count == 1 ? "y" : "ies"), "
            + "\(plan.checkableCount) checkable cop\(plan.checkableCount == 1 ? "y" : "ies") (\(MediaBytes.display(plan.checkableBytes))), "
            + "\(plan.relatedCount) name-related"
            + (missing > 0 ? ", \(missing) missing (removable)" : ""))
        for f in plan.families { log(f.logLine) }
    }

    // MARK: Remove missing rows from the catalog (2026-09-21)

    /// The sheet's "Remove from catalog" on a missing-file row: the record
    /// is re-checked (active, not archive-side, volume online, file still
    /// NOT on disk — the stat off-main) and then tombstoned through the
    /// ONE existing purge path (`purgeRecords`: `purgedAt`, the undo
    /// banner, a `setAside` "removed-from-catalog" ledger line). Nothing
    /// on disk is touched — there is nothing there. A record whose file
    /// turns out to exist is left alone and named. Returns the count
    /// removed; the sheet re-plans afterwards.
    @discardableResult
    func removeMissingCopiesFromCatalog(recordIDs: [UUID],
                                        fileExists: @escaping @Sendable (String) -> Bool = VideoScanModel.fileIsOnDisk) async -> Int {
        guard !isReadOnly else {
            log("what-next: Remove from catalog refused — read-only viewer mode.")
            return 0
        }
        struct Item: Sendable { let id: UUID; let path: String; let filename: String; let volume: String }
        var items: [Item] = []
        var seen = Set<UUID>()
        for id in recordIDs where seen.insert(id).inserted {
            guard let rec = record(forID: id), !rec.isPurged else { continue }
            guard !isArchiveCopy(rec), !isInsideMasterArchive(path: rec.fullPath) else {
                log("what-next: \(rec.filename) is on the archive side — never removed here")
                continue
            }
            guard VolumeReachability.isVolumeReachable(path: rec.fullPath) else {
                log("what-next: \(rec.filename) kept — \(rec.volumeName) is not connected, so the file may well be there")
                continue
            }
            items.append(Item(id: rec.id, path: rec.fullPath, filename: rec.filename, volume: rec.volumeName))
        }
        guard !items.isEmpty else { return 0 }
        let present: Set<UUID> = await Task.detached(priority: .userInitiated) {
            Set(items.filter { fileExists($0.path) }.map(\.id))
        }.value
        for item in items where present.contains(item.id) {
            log("what-next: \(item.filename) is on \(item.volume) after all — kept in the catalog")
        }
        let gone = items.filter { !present.contains($0.id) }
        guard !gone.isEmpty else { return 0 }
        let n = purgeRecords(ids: Set(gone.map(\.id)))
        noteCatalogRecordsMutated()
        log("what-next: removed \(n) missing row\(n == 1 ? "" : "s") from the catalog — nothing on disk was touched: "
            + gone.prefix(5).map { "\($0.filename) (\($0.volume))" }.joined(separator: ", ")
            + (gone.count > 5 ? " and \(gone.count - 5) more" : ""))
        return n
    }

    // MARK: Hash to confirm (v3)

    /// Compute the segmented content hash for `recordIDs` that have none
    /// (online, active), off-main, one file at a time; store it on the
    /// record and write through to the probe cache (a rescan of an
    /// unchanged file would otherwise hand back an empty signature and
    /// erase it — codex #320.1). Records already hashed are left alone.
    /// Returns the ids that gained a hash. Memory: one 1 MiB window
    /// buffer at a time; nothing is retained.
    @discardableResult
    func hashToConfirm(recordIDs: [UUID]) async -> [UUID] {
        struct Item: Sendable { let id: UUID; let path: String; let filename: String; let volume: String }
        var items: [Item] = []
        var seen = Set<UUID>()
        for id in recordIDs where seen.insert(id).inserted {
            guard let rec = record(forID: id), !rec.isPurged else { continue }
            guard rec.contentHash.isEmpty else { continue }
            guard VolumeReachability.isReachable(path: rec.fullPath) else {
                log("what-next: hash skipped for \(rec.filename) — drive not connected")
                continue
            }
            items.append(Item(id: rec.id, path: rec.fullPath, filename: rec.filename, volume: rec.volumeName))
        }
        guard !items.isEmpty else { return [] }
        let hashed: [(UUID, String)] = await Task.detached(priority: .userInitiated) {
            var out: [(UUID, String)] = []
            out.reserveCapacity(items.count)
            for item in items {
                if Task.isCancelled { break }
                let signature = autoreleasepool { FileHasher.segmentedHash(path: item.path) }
                out.append((item.id, signature))
            }
            return out
        }.value
        let now = Date()
        var changed: [UUID] = []
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        for (id, signature) in hashed {
            guard let item = byID[id] else { continue }
            guard !signature.isEmpty else {
                log("what-next: could not hash \(item.filename) on \(item.volume) — read failed")
                continue
            }
            // Never overwrite: a scan may have filled it in meanwhile.
            guard let rec = record(forID: id), rec.contentHash.isEmpty else { continue }
            rec.contentHash = signature
            rec.contentHashAt = now
            metadataCache.updateContentHash(path: rec.fullPath, hash: signature, at: now)
            changed.append(id)
            log("what-next: hashed \(item.filename) on \(item.volume) → \(signature.prefix(16))…")
        }
        if !changed.isEmpty { saveCatalogDebounced() }
        return changed
    }

    // MARK: The sheet

    /// Present "Archived — what next?" for a finished Promote batch. The
    /// job calls this ONCE, only when every copy landed verified (no
    /// failed file, not cancelled). A sheet already pending is never
    /// replaced mid-read.
    func offerArchivedWhatNext(batchID: String, recordIDs: [UUID], totalBytes: Int64,
                               protection: ProtectionSummary, source: ArchivedWhatNextRequest.Source) {
        guard !recordIDs.isEmpty, pendingArchivedWhatNext == nil else { return }
        pendingArchivedWhatNext = ArchivedWhatNextRequest(
            batchID: batchID, recordIDs: recordIDs, fileCount: recordIDs.count, totalBytes: totalBytes,
            archiveLabel: masterArchive.map { VolumeReachability.displayLabel(forPath: $0.targetPath) } ?? "the Master Archive",
            protection: protection, source: source)
    }

    /// Tidy → "Copies of archived media" → the same sheet for the backlog:
    /// every active record OUTSIDE the archive whose content has a
    /// verified archive copy. Computed off-main; presents when done.
    func offerArchivedWhatNextForBacklog() async {
        let snaps = archiveCopySnapshots()
        let (ids, bytes, protection) = await Self.backlogOffMain(snapshots: snaps)
        offerArchivedWhatNext(batchID: "tidy-\(UUID().uuidString.prefix(8))", recordIDs: ids,
                              totalBytes: bytes, protection: protection, source: .tidyBacklog)
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func backlogOffMain(snapshots: [ArchiveCopySnapshot]) async -> ([UUID], Int64, ProtectionSummary) {
        // Content keys that have a fixity-verified archive copy, and the
        // NON-version sources of one: a promoted trimmed version proves
        // nothing for its original (QA 2026-09-20 BLOCKER — the same rule
        // as PrunePlan's proof).
        var versionIDs = Set<UUID>()
        for s in snapshots where s.isVersion && !s.isArchiveSide { versionIDs.insert(s.id) }
        var verifiedKeys = Set<String>()
        var verifiedSources = Set<UUID>()
        for s in snapshots where s.isArchiveSide && s.fixityVerified {
            if !s.contentKey.isEmpty { verifiedKeys.insert(s.contentKey) }
            if let src = s.promotedFromID, !versionIDs.contains(src) { verifiedSources.insert(src) }
        }
        var ids: [UUID] = []
        var bytes: Int64 = 0
        for s in snapshots where !s.isArchiveCopy && !s.isInsideArchiveRoot && !s.isPurged {
            if verifiedSources.contains(s.id) || (!s.contentKey.isEmpty && verifiedKeys.contains(s.contentKey)) {
                ids.append(s.id)
                bytes += s.sizeBytes
            }
        }
        let families = ArchiveCopyFamilies.group(batch: Set(ids), snapshots: snapshots)
        return (ids, bytes, ArchiveCopyFamilies.protection(families: families))
    }
}
