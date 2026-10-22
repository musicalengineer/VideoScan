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
//   - `offerArchivedWhatNext(...)` — sets the sheet driver ONCE per batch.
//
// The plan the sheet shows, the protection line and Tidy's backlog live in
// VideoScanModel+PrunePlan.swift (the one prune plan, 2026-10-21).

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
        guard ArchiveAngel.attentionKinds.contains(kind) else { return nil }
        let by: MediaLedgerEvent.Actor = kind == .angelProposed ? .angel : .rick
        var events: [MediaLedgerEvent] = []
        let byID = records(forIDs: recordIDs)
        for id in recordIDs {
            guard let rec = byID[id] else { continue }
            var detail: [String: String] = [:]
            if let reason, !reason.isEmpty { detail[MediaLedgerEvent.Detail.reason] = reason }
            if let score = scores[id] { detail[MediaLedgerEvent.Detail.score] = String(score) }
            events.append(ledgerEvent(kind, for: rec, by: by, at: at, batchID: batchID, detail: detail))
        }
        guard !events.isEmpty else { return nil }
        archiveAngel.noteAttention(events)
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
}
