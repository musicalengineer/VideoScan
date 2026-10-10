// CopiesAdviceTrash.swift
// "Move This Copy to Trash…" on the Copies & Advice card, through the
// duplicates engine (codex delete-engines F2, 2026-10-09).
//
//   "Move this one copy to the Trash, but only if the copy I'm keeping is
//    really there, with the same bytes, at the moment it moves."
//
// The card's advice is a verdict from moments ago — the keeper it names
// can vanish or change before the Trash. So the card does not trash the
// file itself: it hands ONE reviewed pick (this copy, the path the card
// showed, the card's keeper — the archive copy when that is the keeper) to
// the duplicates engine's reviewed path (`reviewedDuplicateBatch` →
// `startReviewedDeleteDuplicates`), which proves the keeper at the move
// (whole-file digest + identity, never an alias of the target) and holds
// the copy, with its reason, when anything changed. The card then shows
// the engine's own outcome line.
//
// Only a Safe advice whose keeper is an exact copy (same bytes, verified,
// on disk, not this file) offers a pick; anything else moves nothing.

import Foundation

extension CopiesAdvice {

    /// The ONE pick the card may hand to Delete Duplicates, or nil: Safe
    /// BECAUSE an exact copy is proven — the keeper is not this file, its
    /// bytes match by whole-file digest, and it is on disk now.
    var keeperProvenTrashPick: ReviewedDuplicatePick? {
        guard offersTrash, keeperID != recordID,
              let this = rows.first(where: { $0.isThis }),
              let keeper = rows.first(where: { $0.id == keeperID }),
              keeper.match == .verified, keeper.presence == .present else { return nil }
        return ReviewedDuplicatePick(recordID: recordID, path: this.fullPath, keeperID: keeperID)
    }
}

/// What became of the card's one copy, in the engine's words.
struct CopiesAdviceTrashOutcome: Equatable, Sendable {
    /// The engine's result line ("Moved 1 (41 GB) to the Trash", "Moved 0
    /// (Zero KB) to the Trash · 1 held back"), or why nothing was started.
    let line: String
    /// Every reason the copy stayed (empty when it moved).
    let reasons: [String]
    let moved: Bool

    /// The card's one sentence.
    var cardText: String {
        reasons.isEmpty ? line : line + " — " + reasons.joined(separator: "; ")
    }
}

extension VideoScanModel {

    /// Hand the card's one copy to Delete Duplicates' reviewed path and wait
    /// for its outcome. `start` launches the batch (the window's Media File
    /// Operations centre; a test runs the jobs directly). Nothing here
    /// touches a file.
    func trashCopyThroughDuplicates(_ advice: CopiesAdvice,
                                    start: (DeleteDuplicatesBatch) -> DeleteDuplicatesBatchRun) async
        -> CopiesAdviceTrashOutcome {
        guard let pick = advice.keeperProvenTrashPick else {
            return CopiesAdviceTrashOutcome(line: "Nothing was moved — \(advice.verdict.sentence)",
                                            reasons: [], moved: false)
        }
        log("Copies & Advice: Move This Copy to Trash — \(advice.header.filename), keeper proven at the move (Delete Duplicates)")
        let batch = await reviewedDuplicateBatch([pick])
        let run = start(batch)
        await run.task?.value
        let report = run.outcomeReport
        let reasons = report.rows.filter { $0.kind != .moved && !$0.reason.isEmpty }.map(\.reason)
        return CopiesAdviceTrashOutcome(line: report.line, reasons: reasons, moved: report.count(.moved) == 1)
    }
}
