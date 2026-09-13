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
//   - `prunePlan(for:options:)` — the dry-run plan for the sheet.
//   - `offerArchivedWhatNext(...)` — sets the sheet driver ONCE per batch.
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
    @discardableResult
    func ledgerCopyRemoved(_ recs: [VideoRecord], permanent: Bool, by: MediaLedgerEvent.Actor,
                           at: Date = Date(), batchID: String? = nil) -> Task<Void, Never>? {
        ledgerAppend(recs.map {
            ledgerEvent(permanent ? .copyDeleted : .copyTrashed, for: $0, by: by, at: at, batchID: batchID,
                        detail: [MediaLedgerEvent.Detail.volume: $0.volumeName,
                                 MediaLedgerEvent.Detail.mode: permanent ? "permanent" : "trash"])
        })
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

    /// The Sendable facts about every active record — what the pure
    /// families / protection / prune code reads. O(records) value
    /// capture on the main actor (the Tidy dry-run does the same); the
    /// heavy work happens off it. `isOnline` is injectable so tests never
    /// touch a volume.
    func archiveCopySnapshots(isOnline: (VideoRecord) -> Bool = { VolumeReachability.isReachable(path: $0.fullPath) })
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
        for r in records where !r.isPurged {
            let archiveCopy = isArchiveCopy(r)
            let inside = !archiveCopy && isInsideMasterArchive(path: r.fullPath)
            let volume = r.volumeName
            let facts = volumes[volume]
            let online = isOnline(r)
            let isVersion = !archiveCopy && r.derivedFrom != nil
                && !(r.derivationKind.map { Self.repairDerivationKinds.contains($0) } ?? false)
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
                hasHumanNote: !r.userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                starRating: r.starRating,
                disposition: r.mediaDisposition,
                attestations: r.backupAttestations,
                volumeIsConnectedWorking: !(archiveCopy || inside)
                    && (facts?.connectedWorking ?? (online && volume != archiveVolume && !volume.isEmpty)),
                volumeFreeBytes: facts?.free,
                isPurged: r.isPurged))
        }
        return out
    }

    // MARK: Protection (off-main)

    /// The protection line for a batch — snapshot on main, group +
    /// summarize on the cooperative pool.
    func batchProtection(for recordIDs: [UUID],
                         isOnline: (VideoRecord) -> Bool = { VolumeReachability.isReachable(path: $0.fullPath) }) async -> ProtectionSummary {
        let snaps = archiveCopySnapshots(isOnline: isOnline)
        return await Self.protectionOffMain(batch: Set(recordIDs), snapshots: snaps)
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func protectionOffMain(batch: Set<UUID>, snapshots: [ArchiveCopySnapshot]) async -> ProtectionSummary {
        ArchiveCopyFamilies.protection(families: ArchiveCopyFamilies.group(batch: batch, snapshots: snapshots))
    }

    // MARK: Prune plan (off-main, dry run)

    /// The importance bar as Settings has it (defaults until edited).
    var importanceBar: ImportanceBar { ImportanceBar.load(defaults: .standard) }

    /// The dry-run plan for the sheet.
    func prunePlan(for recordIDs: [UUID], options: PrunePlan.Options,
                   isOnline: (VideoRecord) -> Bool = { VolumeReachability.isReachable(path: $0.fullPath) }) async -> PrunePlan {
        let snaps = archiveCopySnapshots(isOnline: isOnline)
        return await Self.prunePlanOffMain(batch: Set(recordIDs), snapshots: snaps, options: options)
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func prunePlanOffMain(batch: Set<UUID>, snapshots: [ArchiveCopySnapshot],
                                             options: PrunePlan.Options) async -> PrunePlan {
        PrunePlan.compute(families: ArchiveCopyFamilies.group(batch: batch, snapshots: snapshots), options: options)
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
        // Content keys that have a fixity-verified archive copy.
        var verifiedKeys = Set<String>()
        var verifiedSources = Set<UUID>()
        for s in snapshots where (s.isArchiveCopy || s.isInsideArchiveRoot) && s.fixityVerified {
            if !s.contentKey.isEmpty { verifiedKeys.insert(s.contentKey) }
            if let src = s.promotedFromID { verifiedSources.insert(src) }
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
