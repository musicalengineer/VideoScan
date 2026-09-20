// VideoScanModel+PruneApply.swift
// "Archived — what next?" → Apply (promote-and-prune stage 2, turned on
// 2026-09-19). Rick: "we should be deleting dups if user wants once a file
// is promoted." Until then Apply was a disabled button with an empty
// action — the dry run he ruled on 9/12 — and after a week of real batches
// it acts.
//
// 2026-09-20 — the sheet became a per-copy CHECKLIST ("I want to see a
// list of dups and decide which ones to delete, maybe leave one behind,
// maybe not"). The bar ADVISES; the person's checks are the truth. So
// Apply takes `selected` — the copy record ids the person checked — and
// no longer intersects "the plan the user saw" with "the fresh plan's
// trash": a family the bar does not cover (★★★ with no cloud copy
// attested) used to hide its copies; now they are offered, and a choice
// that goes against the bar is recorded as such (`override` on the
// approval line) rather than refused.
//
// This is a DELETE path, so like ⌘⌫ (VideoScanModel+TrashSelection) it
// adds NO file-deletion code of its own. It is a plan in front of the ONE
// existing Trash routine, `deleteConfirmedJunk(_:mode:)`, which already
// leaves Master Archive files alone, skips offline drives, stamps
// purgedAt + .trashed, publishes, and writes a `copyTrashed` Media Ledger
// line per file that actually left the disk.
//
// What the plan adds, because this is the one delete that runs on files
// the user did not pick one by one in the table:
//   1. FRESH PLAN — the plan is recomputed with the same options at the
//      moment of Apply; a checked copy may go only if the fresh plan still
//      offers it as CHECKABLE: `isCandidate` (online, no note, not a
//      version or a pair member, not inside the archive) in a family with
//      a FIXITY-VERIFIED archive copy. A note added, a drive unplugged,
//      an archive copy that lost its fixity since the sheet opened → that
//      copy is held, and named with the fresh reason.
//   2. ON-DISK SAFETY, per copy, just before it goes: the family's archive
//      copy exists at its recorded size; the plan's kept working copy (if
//      one is kept and NOT itself checked) exists at its recorded size;
//      the copy itself is still its recorded size (a file rewritten in
//      place is a different file). Any failure holds the copy, with the
//      reason.
//   3. An `approval` ledger line: "Rick approved N copies to Trash" — with
//      `override` when the choice went against the bar ("2 copies — ★★★ /
//      Important — no cloud or off-site copy attested").
// The PrunePlan rules themselves (fixity-verified archive copy, online,
// no human note, not a pair member, not a version, never inside the
// archive) are PrunePlan.compute's, unchanged. Unchecked copies are NEVER
// moved, even when the plan's default would have trashed them: the
// selection is the truth.
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
        /// Copies that went against the bar (from the approval's `override`).
        var overrideCount = 0
        /// "filename — reason" for copies Apply would not touch.
        var held: [String] = []
        /// "filename — error" for copies the Trash routine could not move.
        var failed: [String] = []

        var summary: String {
            var parts = ["Moved \(trashed) cop\(trashed == 1 ? "y" : "ies") to the Trash (\(MediaBytes.display(trashedBytes)))"]
            if overrideCount > 0 { parts.append("\(overrideCount) against the bar you set") }
            if alreadyMissing > 0 { parts.append("\(alreadyMissing) already gone") }
            if skippedOffline > 0 { parts.append("\(skippedOffline) on a drive that isn't connected") }
            if !held.isEmpty { parts.append("\(held.count) held back — changed since the list was shown") }
            if !failed.isEmpty { parts.append("\(failed.count) could not be moved") }
            return parts.joined(separator: " · ")
        }
    }

    /// A copy held back, with why.
    struct PruneHeld: Equatable {
        let copy: PrunePlan.CopyRef
        let reason: String
        var line: String { "\(copy.filename) — \(reason)" }
    }

    /// Which of the copies the person checked may go: those the FRESH plan
    /// still offers as checkable. Order = the rows of the plan the person
    /// saw. A checked id that the shown plan never offered (not a
    /// checkable row) is held, not trusted; one the fresh plan no longer
    /// knows is held too.
    nonisolated static func pruneTargets(shown: PrunePlan, selected: Set<UUID>, fresh: PrunePlan)
        -> (go: [PrunePlan.CopyRef], held: [PruneHeld]) {
        guard !selected.isEmpty else { return ([], []) }
        var freshRows: [UUID: PrunePlan.CopyRow] = [:]
        for family in fresh.families { for row in family.rows { freshRows[row.id] = row } }
        var go: [PrunePlan.CopyRef] = [], held: [PruneHeld] = []
        for family in shown.families {
            for row in family.rows where selected.contains(row.id) {
                guard row.checkable else {
                    held.append(PruneHeld(copy: row.copy, reason: "was never offered: \(row.reasonText ?? "not a candidate")"))
                    continue
                }
                guard let now = freshRows[row.id] else {
                    held.append(PruneHeld(copy: row.copy, reason: "no longer in the plan"))
                    continue
                }
                if now.checkable {
                    go.append(now.copy)
                } else {
                    held.append(PruneHeld(copy: now.copy,
                                          reason: "changed since the list was shown: \(now.reasonText ?? "no longer a candidate")"))
                }
            }
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

    /// Apply the person's checklist. `shown` is the plan the sheet listed,
    /// `selected` the copy record ids checked in it. `mode` is always
    /// `.toTrash` from the sheet; tests pass `.permanent` so fixtures never
    /// reach the real Trash.
    func applyPrune(shown: PrunePlan, selected: Set<UUID>, recordIDs: [UUID], options: PrunePlan.Options,
                    batchID: String?, mode: JunkDeletionMode = .toTrash) async -> PruneApplyOutcome {
        var outcome = PruneApplyOutcome()
        guard !isReadOnly else {
            log("Archived — what next?: Apply refused — read-only viewer mode.")
            return outcome
        }
        guard !selected.isEmpty else {
            log("Archived — what next?: nothing checked — nothing to move.")
            return outcome
        }
        let fresh = await prunePlan(for: recordIDs, options: options)
        let (go, changed) = Self.pruneTargets(shown: shown, selected: selected, fresh: fresh)
        outcome.held = changed.map(\.line)

        // Family context from the FRESH plan: the kept working copy to
        // protect on disk — unless the person checked it too (then there
        // is no keeper, and the confirmation said so in words).
        let goIDs = Set(go.map(\.id))
        var keeperOf: [UUID: PrunePlan.CopyRef] = [:]
        for family in fresh.families {
            guard let keeper = family.keeper, !goIDs.contains(keeper.id) else { continue }
            for row in family.rows where row.checkable { keeperOf[row.id] = keeper }
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
        // The approval, before the files move: what Rick said yes to, and
        // whether it went against the bar (judged on the FRESH plan, over
        // the copies that actually go).
        let judged = fresh.selection(Set(targets.map(\.id)))
        outcome.overrideCount = judged.overrideCount
        let bytes = targets.reduce(Int64(0)) { $0 + $1.sizeBytes }
        var detail: [String: String] = [
            MediaLedgerEvent.Detail.count: String(targets.count),
            MediaLedgerEvent.Detail.bytes: String(bytes),
            MediaLedgerEvent.Detail.files: targets.map(\.filename).joined(separator: "\n"),
            MediaLedgerEvent.Detail.action: mode == .toTrash ? "trash" : "delete",
        ]
        if let against = judged.overrideText {
            detail[MediaLedgerEvent.Detail.barOverride] = against
            log("Archived — what next?: against the bar — \(against)")
        }
        if let only = judged.archiveOnlySentence {
            log("Archived — what next?: \(only)")
        }
        ledgerAppend([ledgerEvent(.approval, for: targets[0], by: .rick, batchID: batchID, detail: detail)])

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
