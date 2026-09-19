// VideoScanModel+PruneApply.swift
// "Archived — what next?" → Apply (promote-and-prune stage 2, turned on
// 2026-09-19). Rick: "we should be deleting dups if user wants once a file
// is promoted." Until today Apply was a disabled button with an empty
// action — the dry run he ruled on 9/12 — and after a week of real batches
// it now acts.
//
// This is a DELETE path, so like ⌘⌫ (VideoScanModel+TrashSelection) it
// adds NO file-deletion code of its own. It is a plan in front of the ONE
// existing Trash routine, `deleteConfirmedJunk(_:mode:)`, which already
// leaves Master Archive files alone, skips offline drives, stamps
// purgedAt + .trashed, publishes, and writes a `copyTrashed` Media Ledger
// line per file that actually left the disk.
//
// What the plan adds, because this is the one delete that runs on files
// the user did not pick one by one:
//   1. FRESH PLAN — the plan is recomputed with the same options at the
//      moment of Apply; only copies in BOTH the plan the user saw and the
//      fresh one go. A note added, a drive unplugged, an attestation
//      withdrawn since the sheet opened → that copy is held, and named.
//   2. ON-DISK SAFETY, per copy, just before it goes: the family's archive
//      copy exists at its recorded size; the kept working copy (if the
//      user asked to keep one) exists at its recorded size; the copy
//      itself is still its recorded size (a file rewritten in place is a
//      different file). Any failure holds the copy, with the reason.
//   3. An `approval` ledger line: "Rick approved N copies to Trash".
// The PrunePlan rules themselves (fixity-verified archive copy, online,
// no human note, not a pair member, not a version, never inside the
// archive) are PrunePlan.compute's, unchanged.
//
// Memory: O(copies in the batch's families). Disk checks are stat calls
// off the main actor; no file content is read.

import Foundation
import VideoScanCore

extension VideoScanModel {

    struct PruneApplyOutcome: Equatable {
        var trashed = 0
        var trashedBytes: Int64 = 0
        var alreadyMissing = 0
        var skippedOffline = 0
        /// "filename — reason" for copies Apply would not touch.
        var held: [String] = []
        /// "filename — error" for copies the Trash routine could not move.
        var failed: [String] = []

        var summary: String {
            var parts = ["Moved \(trashed) cop\(trashed == 1 ? "y" : "ies") to the Trash (\(MediaBytes.display(trashedBytes)))"]
            if alreadyMissing > 0 { parts.append("\(alreadyMissing) already gone") }
            if skippedOffline > 0 { parts.append("\(skippedOffline) on a drive that isn't connected") }
            if !held.isEmpty { parts.append("\(held.count) held back — changed since the plan was shown") }
            if !failed.isEmpty { parts.append("\(failed.count) could not be moved") }
            return parts.joined(separator: " · ")
        }
    }

    /// Which copies from the plan the user saw may go: those the fresh
    /// plan still puts in the Trash. The rest are held.
    nonisolated static func pruneTargets(shown: PrunePlan, fresh: PrunePlan)
        -> (go: [PrunePlan.CopyRef], held: [PrunePlan.CopyRef]) {
        let stillTrash = Set(fresh.trashFiles.map(\.id))
        var go: [PrunePlan.CopyRef] = [], held: [PrunePlan.CopyRef] = []
        for copy in shown.trashFiles {
            if stillTrash.contains(copy.id) { go.append(copy) } else { held.append(copy) }
        }
        return (go, held)
    }

    /// One copy's on-disk safety check, as plain paths and sizes so it can
    /// run off the main actor.
    struct PruneDiskCheck: Sendable {
        let copyID: UUID
        let filename: String
        let path: String
        let size: Int64
        let archivePath: String?
        let archiveSize: Int64
        let keeperPath: String?
        let keeperSize: Int64
    }

    /// Nil when the copy may go; otherwise why not.
    nonisolated static func pruneDiskProblem(_ c: PruneDiskCheck, fileManager fm: FileManager = .default) -> String? {
        func size(_ path: String) -> Int64? {
            ((try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value
        }
        guard let archivePath = c.archivePath else { return "its archive copy is not in the catalog" }
        guard let archived = size(archivePath) else { return "its archive copy is not on disk" }
        guard archived == c.archiveSize else { return "its archive copy is not the size the catalog recorded" }
        if let keeper = c.keeperPath {
            guard let kept = size(keeper) else { return "the working copy to keep is not on disk" }
            guard kept == c.keeperSize else { return "the working copy to keep is not the size the catalog recorded" }
        }
        // Missing is the Trash routine's "already gone"; a different size
        // is a different file now.
        if let now = size(c.path), now != c.size { return "it changed on disk since it was cataloged" }
        return nil
    }

    /// Apply the plan the user saw. `mode` is always `.toTrash` from the
    /// sheet; tests pass `.permanent` so fixtures never reach the real Trash.
    func applyPrune(shown: PrunePlan, recordIDs: [UUID], options: PrunePlan.Options,
                    batchID: String?, mode: JunkDeletionMode = .toTrash) async -> PruneApplyOutcome {
        var outcome = PruneApplyOutcome()
        guard !isReadOnly else {
            log("Archived — what next?: Apply refused — read-only viewer mode.")
            return outcome
        }
        let fresh = await prunePlan(for: recordIDs, options: options)
        let (go, changed) = Self.pruneTargets(shown: shown, fresh: fresh)
        outcome.held = changed.map { "\($0.filename) — the plan changed since it was shown" }

        // Family context from the FRESH plan: the keeper to protect.
        var keeperOf: [UUID: PrunePlan.CopyRef] = [:]
        for family in fresh.families {
            for copy in family.trash { if let keeper = family.keeper { keeperOf[copy.id] = keeper } }
        }
        var checks: [PruneDiskCheck] = []
        var recordsByID: [UUID: VideoRecord] = [:]
        for copy in go {
            guard let rec = record(forID: copy.id), rec.purgedAt == nil else {
                outcome.held.append("\(copy.filename) — no longer an active catalog record")
                continue
            }
            recordsByID[copy.id] = rec
            let archive = archivedCopy(of: rec)
            let keeper = keeperOf[copy.id].flatMap { record(forID: $0.id) }
            checks.append(PruneDiskCheck(copyID: copy.id, filename: copy.filename, path: rec.fullPath,
                                         size: rec.sizeBytes, archivePath: archive?.fullPath,
                                         archiveSize: archive?.sizeBytes ?? 0,
                                         keeperPath: keeper?.fullPath, keeperSize: keeper?.sizeBytes ?? 0))
        }
        let problems = await Task.detached(priority: .userInitiated) {
            checks.compactMap { c in Self.pruneDiskProblem(c).map { (c.copyID, c.filename, $0) } }
        }.value
        let refused = Set(problems.map(\.0))
        outcome.held += problems.map { "\($0.1) — \($0.2)" }
        let targets = checks.filter { !refused.contains($0.copyID) }.compactMap { recordsByID[$0.copyID] }

        for line in outcome.held { log("Archived — what next?: held back \(line)") }
        guard !targets.isEmpty else {
            log("Archived — what next?: " + outcome.summary)
            return outcome
        }
        // The approval, before the files move: what Rick said yes to.
        let bytes = targets.reduce(Int64(0)) { $0 + $1.sizeBytes }
        ledgerAppend([ledgerEvent(.approval, for: targets[0], by: .rick, batchID: batchID, detail: [
            MediaLedgerEvent.Detail.count: String(targets.count),
            MediaLedgerEvent.Detail.bytes: String(bytes),
            MediaLedgerEvent.Detail.files: targets.map(\.filename).joined(separator: "\n"),
            MediaLedgerEvent.Detail.action: mode == .toTrash ? "trash" : "delete",
        ])])

        // The ONE existing Trash routine does every file operation.
        let result = await deleteConfirmedJunk(targets, mode: mode)
        let failedIDs = Set(result.failed.map { $0.record.id })
        outcome.trashed = result.succeeded
        outcome.trashedBytes = targets.filter { !failedIDs.contains($0.id) && $0.purgedAt != nil }
            .reduce(0) { $0 + $1.sizeBytes }
        outcome.alreadyMissing = result.alreadyMissing
        outcome.skippedOffline = result.skippedOffline
        outcome.failed = result.failed.map { "\($0.record.filename) — \($0.error.localizedDescription)" }
        log("Archived — what next?: " + outcome.summary)
        return outcome
    }
}
