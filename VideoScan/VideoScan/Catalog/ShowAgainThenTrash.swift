// ShowAgainThenTrash.swift
// The Review… sheet's ONE Apply (Rick 2026-10-11): show every reviewed file
// again, then move the files of the ticked rows to the Trash — through the
// EXISTING Delete Duplicates engine, never a new delete path.
//
//   1. Show Again runs as its own MFO job, exactly as before (label only,
//      the pre-show-again snapshot, the receipt, Put the labels back).
//   2. When it has finished with its labels changed and saved (or nothing
//      to do), the picks that still stand (`ShowAgainTrashPicks.eligible`)
//      are frozen by `reviewedDuplicateBatch` and handed to
//      `startReviewedDeleteDuplicates` — one MFO job per drive, each with
//      its START / per-file / OUTCOME lines and its DeletionAudit receipt.
//      That engine re-proves every file with a full SHA-256 of it AND its
//      keeper at the move, never takes a keeper, refuses the Master Archive
//      and its volume, and moves to the Trash only. A file that fails any of
//      it is held and reported, not moved.
//   3. Anything else — Show Again refused, stopped, or its save not
//      confirmed — and NOTHING moves; the console says why.
//
// This file never moves a file itself: it decides WHICH picks the engine
// is asked about. (The four ShowAgain*.swift sources stay label-only; their
// sensor test reads them.)

import Foundation

/// Which ticked picks may go to the engine after the Show Again run. Pure.
enum ShowAgainTrashPicks {

    /// A pick stands only when its file was really shown again by THIS run,
    /// and its keeper is not left hidden behind the label (a keeper that was
    /// labelled must have been shown again too — the copy that stays must
    /// be visible in the Catalog).
    nonisolated static func eligible(_ picks: [ReviewedDuplicatePick], shown: Set<UUID>,
                                     labelled: Set<UUID>) -> [ReviewedDuplicatePick] {
        picks.filter { pick in
            shown.contains(pick.recordID) && (!labelled.contains(pick.keeperID) || shown.contains(pick.keeperID))
        }
    }

    /// The Show Again outcomes after which the Trash step may start.
    nonisolated static func mayProceed(after outcome: VideoScanModel.ShowAgainRunResult.Outcome) -> Bool {
        switch outcome {
        case .shown, .nothingToDo: return true
        case .refused, .stopped, .saveUnconfirmed: return false
        }
    }
}

extension MediaFileOperationsCenter {

    /// Start Show Again for `reviewed`; when it finishes, hand the ticked
    /// `picks` that still stand to Delete Duplicates' reviewed path.
    /// `startTrash` is the seam tests replace (default: this centre's
    /// `startReviewedDeleteDuplicates`). Returns the Show Again job and the
    /// task that waits for it.
    @discardableResult
    func startShowAgainThenTrash(model: VideoScanModel, reviewed: ShowAgainPlan, picks: [ReviewedDuplicatePick],
                                 startTrash: (@MainActor (DeleteDuplicatesBatch) -> DeleteDuplicatesBatchRun)? = nil)
        -> (job: ShowAgainJob, chain: Task<DeleteDuplicatesBatchRun?, Never>) {
        let job = startShowAgain(model: model, reviewed: reviewed)
        let labelled = Set(reviewed.items.map(\.id))
        // `[weak self]` ≈ a non-owning pointer: the chain never keeps the
        // centre alive; if it is gone the engine reports "went away".
        let start: @MainActor (DeleteDuplicatesBatch) -> DeleteDuplicatesBatchRun = startTrash ?? { [weak self] batch in
            guard let self else { return DeleteDuplicatesBatchRun(batch: DeleteDuplicatesBatch(plans: [])) }
            return self.startReviewedDeleteDuplicates(batch, model: model)
        }
        let chain = Task { @MainActor () -> DeleteDuplicatesBatchRun? in
            await job.task?.value
            return await model.showAgainTrashAfter(job: job, picks: picks, labelled: labelled, start: start)
        }
        return (job, chain)
    }
}

extension VideoScanModel {

    /// Step 2 of the Apply, after the Show Again job has finished: freeze
    /// the picks that still stand and start the engine. Logs through the one
    /// sink. Returns the engine's batch run, or nil when nothing was started.
    func showAgainTrashAfter(job: ShowAgainJob, picks: [ReviewedDuplicatePick], labelled: Set<UUID>,
                             start: @MainActor (DeleteDuplicatesBatch) -> DeleteDuplicatesBatchRun) async -> DeleteDuplicatesBatchRun? {
        guard !picks.isEmpty else { return nil }
        let p = ShowAgainLines.prefix
        guard let result = job.result, ShowAgainTrashPicks.mayProceed(after: result.outcome) else {
            showAgainNote("\(p): move to the Trash NOT started — Show Again did not finish cleanly, so none of the \(picks.count.formatted()) ticked file(s) moved.")
            return nil
        }
        let shown = Set(result.shown.map(\.id))
        let go = ShowAgainTrashPicks.eligible(picks, shown: shown, labelled: labelled)
        let dropped = picks.count - go.count
        if dropped > 0 {
            showAgainNote("\(p): \(dropped.formatted()) ticked file(s) stay — not shown again by this run, or the copy that stays is still hidden.")
        }
        guard !go.isEmpty else {
            showAgainNote("\(p): move to the Trash NOT started — no ticked file still stands.")
            return nil
        }
        showAgainNote("\(p): handing \(go.count.formatted()) ticked file(s) to Delete Duplicates — each is checked byte for byte against the copy that stays before it moves to the Trash; anything that doesn't match stays.")
        let batch = await reviewedDuplicateBatch(go)
        return start(batch)
    }
}
