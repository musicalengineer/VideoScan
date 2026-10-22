// VideoScanModel+PruneApply.swift
// "Move N copies to the Trash" — the one apply path for the one prune plan
// (docs/design/pruneplan_simple_2026-10-21.md). "Archived — what next?" and
// Triage ▸ Clean up ▸ Excess copies both start a PruneApplyJob, which runs
// these three steps; `applyPrune` runs them back to back (tests).
//
//   1. `preparePrune` — at the batch's TURN, never at enqueue: a FRESH plan;
//      a checked copy goes on only if the plan the person saw offered it
//      AND the fresh plan still offers it against the same archive file and
//      digest at the same path (I5). Anything else is held, named. A copy
//      the batch before already moved is skipped, named, never read.
//   2. `pruneOneCopy` — ONE copy, in order: the live catalog (active, same
//      path, the one bulk-delete gate, Archive backup, A/V pair, the archive
//      file still the verified one); the archive file read in full ONCE per
//      archive file per batch; the copy read in full; both digests equal the
//      archive's verified digest (I1); then the ONE Trash routine,
//      `deleteConfirmedJunk(… mode: .toTrash …)`, behind a JunkDeletionGuard
//      that re-checks the proof in the live catalog and both stat stamps on
//      disk immediately before the file's own Trash.
//   3. `finishPrune` — ONE `approval` ledger line per batch with the ACTUAL
//      count; the Trash routine writes a `copyTrashed` line per file moved.
//
// This file adds NO file operation of its own, and has no mode parameter:
// the Trash is the only destination (I3). Notes, stars and tags are not
// carried: they are keyed by the whole-file digest (CatalogCommit.digest),
// and R1 requires the copy's digest to BE the archive file's (I8).
//
// Outcomes (PruneCopyResult): trashed · held(reason) · failed(error) ·
// alreadyMissing · skippedOffline. Only `trashed` means the file left.
//
// Memory: O(copies in the batch); whole-file reads stream in 1 MiB blocks
// off the main actor.

import Foundation
import VideoScanCore

extension VideoScanModel {

    struct PruneApplyOutcome: Equatable {
        var trashed = 0
        var trashedBytes: Int64 = 0
        var alreadyMissing = 0
        var skippedOffline = 0
        /// Copies read in full and found byte-identical to the archive file.
        var verified = 0
        /// Archive files read in full (once each per batch).
        var archiveReads = 0
        /// "filename — reason" for copies that were not moved.
        var held: [String] = []
        /// "filename — error" for copies the Trash routine could not move.
        var failed: [String] = []
        /// Checked here, but the batch before in the queue already moved them.
        var movedByEarlierBatch = 0

        var summary: String {
            var parts = ["Moved \(trashed) cop\(trashed == 1 ? "y" : "ies") to the Trash (\(MediaBytes.display(trashedBytes)))"]
            if movedByEarlierBatch > 0 { parts.append("\(movedByEarlierBatch) already moved by the batch before") }
            if verified > 0 { parts.append("\(verified) read in full and matched the archive") }
            if archiveReads > 0 { parts.append("\(archiveReads) archive cop\(archiveReads == 1 ? "y" : "ies") read in full") }
            if alreadyMissing > 0 { parts.append("\(alreadyMissing) already gone") }
            if skippedOffline > 0 { parts.append("\(skippedOffline) on a drive that isn't connected") }
            if !held.isEmpty { parts.append("\(held.count) held back") }
            if !failed.isEmpty { parts.append("\(failed.count) could not be moved") }
            return parts.joined(separator: " · ")
        }

        /// Fold one copy's result in.
        mutating func absorb(_ o: PruneCopyOutcome, item: PruneItem) {
            if o.readInFull { verified += 1 }
            if o.archiveReadInFull { archiveReads += 1 }
            switch o.result {
            case .trashed(let bytes): trashed += 1; trashedBytes += bytes
            case .held(let why): held.append("\(item.filename) — \(why)")
            case .failed(let why): failed.append("\(item.filename) — \(why)")
            case .alreadyMissing: alreadyMissing += 1
            case .skippedOffline: skippedOffline += 1
            }
        }
    }

    /// One copy the pipeline will work through, with the archive file it was
    /// offered against.
    struct PruneItem: Sendable, Identifiable, Equatable {
        var id: UUID { copyID }
        let copyID: UUID
        let filename: String
        let path: String
        let sizeBytes: Int64
        let archiveID: UUID
        let archivePath: String
        let archiveFilename: String
        let archiveDigest: String
    }

    /// A copy the batch will not even try, with why.
    struct PruneHeldCopy: Sendable, Equatable {
        let copyID: UUID
        let filename: String
        let sizeBytes: Int64
        let reason: String
        var line: String { "\(filename) — \(reason)" }
    }

    /// The batch, ready to run.
    struct PrunePrepared {
        var items: [PruneItem] = []
        var held: [PruneHeldCopy] = []
        /// Checked copies the batch before in the queue already moved.
        var movedEarlier: [PruneHeldCopy] = []
        static let nothing = PrunePrepared()
    }

    nonisolated static let pruneMovedEarlierReason = "already moved to the Trash by the batch before"

    // MARK: Step 1 — prepare (I5)

    /// The person's checks against the plan they saw AND a fresh plan. Pure;
    /// O(rows shown + rows in the fresh plan). Ids that were never a row of
    /// the shown plan are ignored — nothing unlisted is ever moved.
    nonisolated static func pruneTargets(shown: PrunePlan, selected: Set<UUID>, fresh: PrunePlan,
                                         movedEarlier: Set<UUID> = []) -> PrunePrepared {
        var out = PrunePrepared()
        let now = fresh.locator()
        for item in shown.items {
            for row in item.rows where selected.contains(row.id) {
                let held = { (why: String) in
                    PruneHeldCopy(copyID: row.id, filename: row.filename, sizeBytes: row.sizeBytes, reason: why)
                }
                if movedEarlier.contains(row.id) {
                    out.movedEarlier.append(held(pruneMovedEarlierReason))
                } else if let why = pruneChange(row, in: item, now: now[row.id]) {
                    out.held.append(held(why))
                } else if let digest = item.digest {
                    out.items.append(PruneItem(copyID: row.id, filename: row.filename, path: row.fullPath,
                                               sizeBytes: row.sizeBytes, archiveID: item.archive.id,
                                               archivePath: item.archive.fullPath,
                                               archiveFilename: item.archive.filename, archiveDigest: digest))
                }
            }
        }
        return out
    }

    /// nil = the fresh plan still offers this row exactly as it was shown.
    private nonisolated static func pruneChange(_ row: PrunePlan.Row, in item: PrunePlan.Item,
                                        now: PrunePlan.Located?) -> String? {
        if let reason = row.reason { return "was never offered: \(reason.text)" }
        guard let now else { return "changed since the list was shown: no longer listed" }
        if let reason = now.row.reason { return "changed since the list was shown: \(reason.text)" }
        guard now.item.archive.id == item.archive.id, now.item.archive.fullPath == item.archive.fullPath,
              now.item.digest == item.digest, now.row.fullPath == row.fullPath else {
            return "changed since the list was shown: it no longer matches the same archive file"
        }
        return nil
    }

    /// The fresh plan and the person's checks → the copies to work through.
    /// `batch` is the scope the shown plan was built for (nil = the catalog).
    func preparePrune(shown: PrunePlan, selected: Set<UUID>, batch: Set<UUID>?,
                      movedEarlier: Set<UUID> = []) async -> PrunePrepared {
        guard !isReadOnly else {
            log("Archived — what next?: Apply refused — read-only viewer mode.")
            return .nothing
        }
        guard !selected.isEmpty else {
            log("Archived — what next?: nothing checked — nothing to move.")
            return .nothing
        }
        let fresh = await prunePlan(batch: batch)
        let prepared = Self.pruneTargets(shown: shown, selected: selected, fresh: fresh, movedEarlier: movedEarlier)
        for m in prepared.movedEarlier { log("Archived — what next?: skipped \(m.line)") }
        for h in prepared.held { log("Archived — what next?: held back \(h.line)") }
        return prepared
    }

    // MARK: Step 2 — one copy

    enum PruneCopyResult: Sendable, Equatable {
        case trashed(bytes: Int64)
        case held(String)
        case failed(String)
        case alreadyMissing
        case skippedOffline

        /// Non-nil when the MOVE itself went wrong — an error, not a
        /// decision (codex #1642: "an error drops the line too, only a
        /// normal finish hands on"). A HOLD is a decision and is nil.
        var errorText: String? {
            switch self {
            case .failed(let why): return why
            case .alreadyMissing: return "vanished during the move — the catalog cannot say where it went"
            case .skippedOffline: return "its drive was disconnected during the move"
            case .trashed, .held: return nil
            }
        }
    }

    struct PruneCopyOutcome: Sendable, Equatable {
        let result: PruneCopyResult
        /// The copy was read in full and matched the archive file.
        var readInFull = false
        /// The archive file was read in full for this copy (first of its batch).
        var archiveReadInFull = false

        static func held(_ why: String, archiveReadInFull: Bool = false) -> PruneCopyOutcome {
            PruneCopyOutcome(result: .held(why), archiveReadInFull: archiveReadInFull)
        }
    }

    /// Per-batch evidence (I1): archive files read in full IN THIS BATCH, and
    /// those whose read failed (their copies are held without another read).
    @MainActor
    final class PruneBatchState {
        fileprivate var archiveReadings: [UUID: PruneArchiveReading] = [:]
        fileprivate var archiveProblem: [UUID: String] = [:]
        init() {}
    }

    /// Everything that happens to ONE copy (see the header). Any doubt at
    /// any step holds the copy, named. `hooks.shouldCancel` is honoured
    /// before every read and again before the move.
    func pruneOneCopy(_ item: PruneItem, batch: PruneBatchState,
                      hooks: PruneVerifyHooks = .live) async -> PruneCopyOutcome {
        let rec: VideoRecord
        switch pruneLiveRecord(item) {
        case .success(let live): rec = live
        case .failure(let hold): return .held(hold.text)
        }
        let archive = await pruneArchiveReading(item, batch: batch, hooks: hooks)
        let archiveRead = archive.readNow
        guard case .success(let reading) = archive.result else {
            return .held(archive.result.holdText, archiveReadInFull: archiveRead)
        }
        let verdict = await Task.detached(priority: .userInitiated) {
            Self.pruneCandidateProof(item, archive: reading, hooks: hooks)
        }.value
        guard case .success(let proof) = verdict else {
            return .held(verdict.holdText, archiveReadInFull: archiveRead)
        }
        log("Archived — what next?: \(item.filename) read in full — byte-identical to \(item.archiveFilename)")
        hooks.beforeMutation?(item.path)
        guard !hooks.shouldCancel() else {
            return PruneCopyOutcome(result: .held("stopped before it was moved"), readInFull: true,
                                    archiveReadInFull: archiveRead)
        }
        let result = await pruneMove(rec, proof: proof, hooks: hooks)
        return PruneCopyOutcome(result: result, readInFull: true, archiveReadInFull: archiveRead)
    }

    /// The live catalog, before a byte is read: the copy is the same active
    /// row at the same path; the one bulk-delete rule, the Archive backup
    /// marks and the A/V pairing do not hold it; its archive file is still
    /// the active, verified file it was offered against.
    private func pruneLiveRecord(_ item: PruneItem) -> Result<VideoRecord, PruneHold> {
        guard let rec = record(forID: item.copyID), rec.removal == nil else {
            return .failure(PruneHold("no longer an active catalog record"))
        }
        guard rec.fullPath == item.path else { return .failure(PruneHold("moved in the catalog since the list was shown")) }
        let archiveVolume = archiveVolumeProtection()
        if let refusal = bulkDeleteRefusal(rec, volume: archiveVolume) {
            return .failure(PruneHold(Self.bulkDeleteRefusalNote(refusal, volume: archiveVolume?.label ?? "the archive volume")))
        }
        if let why = pruneLiveHold(rec) { return .failure(PruneHold(why)) }
        guard let archive = record(forID: item.archiveID), archive.removal == nil,
              archive.fullPath == item.archivePath, Self.verifiedArchiveDigest(archive) == item.archiveDigest else {
            return .failure(PruneHold("its archive copy is no longer the verified file the list showed"))
        }
        return .success(rec)
    }

    /// The holds that can appear while a batch runs (R4's Archive backup
    /// mark, R5), asked of the LIVE record. nil = nothing holds it.
    private func pruneLiveHold(_ rec: VideoRecord) -> String? {
        if archiveBackupProtection().verdict(forPath: rec.fullPath) != nil { return PruneReason.driveProtected.text }
        return CatalogScopePolicy.isPairProtected(rec) ? PruneReason.pairHalf.text : nil
    }

    /// The archive file's full read for this batch — taken once and reused
    /// (I1); a failed read holds every later copy of it without another read
    /// (a cancel is the copy's alone). `readNow` = this call did the read.
    private func pruneArchiveReading(_ item: PruneItem, batch: PruneBatchState, hooks: PruneVerifyHooks) async
        -> (result: Result<PruneArchiveReading, PruneHold>, readNow: Bool) {
        if let done = batch.archiveReadings[item.archiveID] { return (.success(done), false) }
        if let why = batch.archiveProblem[item.archiveID] { return (.failure(PruneHold(why)), false) }
        log("Archived — what next?: reading \(item.archiveFilename) (archive copy) in full…")
        let result = await Task.detached(priority: .userInitiated) {
            Self.readArchiveInFull(id: item.archiveID, path: item.archivePath, digest: item.archiveDigest, hooks: hooks)
        }.value
        switch result {
        case .success(let reading): batch.archiveReadings[item.archiveID] = reading
        case .failure(let hold): if !hooks.shouldCancel() { batch.archiveProblem[item.archiveID] = hold.text }
        }
        return (result, true)
    }

    /// The ONE Trash routine moves the file, behind the proof's guard: the
    /// live catalog on main just before the hop, the network probe and both
    /// stat stamps immediately before the file's own Trash.
    private func pruneMove(_ rec: VideoRecord, proof: PruneProof, hooks: PruneVerifyHooks) async -> PruneCopyResult {
        let isNetwork = hooks.isNetworkMount
        let fileGuard = JunkDeletionGuard(
            authorize: { [weak self] live in
                guard let self else { return "the catalog went away — nothing moved" }
                return self.pruneProofProblemInCatalog(proof, record: live)
                    ?? self.pruneLiveHold(live).map { "\($0) — nothing moved" }
            },
            beforeRemoval: { path in
                guard path == proof.path else { return "was never read in this batch — nothing moved" }
                if isNetwork(path) { return "\(PruneReason.driveProtected.text) (a network drive) — nothing moved" }
                return Self.pruneProofProblemOnDisk(proof)
            },
            remove: hooks.removeFile)
        let mode: JunkDeletionMode = .toTrash
        let result = await deleteConfirmedJunk([rec], mode: mode, reason: .prune, guard: fileGuard)
        if let refused = result.refused.first {
            log("Archived — what next?: held back at the last moment: \(rec.filename) — \(refused.reason)")
        }
        return Self.pruneCopyResult(result, bytes: rec.sizeBytes)
    }

    /// The Trash routine's answer for ONE record, as this copy's result.
    private nonisolated static func pruneCopyResult(_ result: JunkDeletionResult, bytes: Int64) -> PruneCopyResult {
        if let refused = result.refused.first { return .held(refused.reason) }
        if let failure = result.failed.first { return .failed(failure.error.localizedDescription) }
        if result.succeeded == 1 { return .trashed(bytes: bytes) }
        if result.alreadyMissing == 1 { return .alreadyMissing }
        if result.skippedOffline == 1 { return .skippedOffline }
        return .held("the Trash routine did not move it")
    }

    // MARK: Step 3 — finish

    /// The approval line, once per batch, with the ACTUAL counts. Nothing
    /// moved → no approval.
    func finishPrune(trashed: [VideoRecord], batchID: String?) {
        guard let first = trashed.first else { return }
        let bytes = trashed.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let detail: [String: String] = [
            MediaLedgerEvent.Detail.count: String(trashed.count),
            MediaLedgerEvent.Detail.bytes: String(bytes),
            MediaLedgerEvent.Detail.files: trashed.map(\.filename).joined(separator: "\n"),
            MediaLedgerEvent.Detail.action: "trash",
        ]
        ledgerAppend([ledgerEvent(.approval, for: first, by: .rick, batchID: batchID, detail: detail)])
    }

    // MARK: The three steps back to back

    /// Apply the person's checks in one await (tests; the sheet and the pane
    /// start a PruneApplyJob, which runs the same steps). `shown` is the plan
    /// the person saw, `batch` its scope.
    func applyPrune(shown: PrunePlan, selected: Set<UUID>, batch: Set<UUID>?, batchID: String?,
                    hooks: PruneVerifyHooks = .live) async -> PruneApplyOutcome {
        var outcome = PruneApplyOutcome()
        let prepared = await preparePrune(shown: shown, selected: selected, batch: batch)
        outcome.held = prepared.held.map(\.line)
        let state = PruneBatchState()
        var trashed: [VideoRecord] = []
        for item in prepared.items {
            let one = await pruneOneCopy(item, batch: state, hooks: hooks)
            outcome.absorb(one, item: item)
            if case .trashed = one.result, let rec = record(forID: item.copyID) { trashed.append(rec) }
            if case .held(let why) = one.result { log("Archived — what next?: held back \(item.filename) — \(why)") }
        }
        finishPrune(trashed: trashed, batchID: batchID)
        if !selected.isEmpty, !isReadOnly { log("Archived — what next?: " + outcome.summary) }
        return outcome
    }
}

extension Result where Failure == VideoScanModel.PruneHold {
    /// The hold's words ("" for a success — never asked then).
    fileprivate var holdText: String {
        if case .failure(let hold) = self { return hold.text }
        return ""
    }
}
