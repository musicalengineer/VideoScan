// VideoScanModel+ArchiveAngelBufferHygiene.swift
// THE ONE WAY an Archive Angel batch leaves the buffer by a person's
// decision (curation Phase 2, Rick 2026-09-19). The review sheet's
// "Discard batch…", the hygiene card's Clear and Clear all, and the start
// sheet's banner all land here — Rick's wrapper-over-N-call-sites rule:
// one entry point, the safeguards, the logging, the red/green.
//
// What a clear IS (docs/archive_angel_curation_direction.md, Phase 2):
//   • only the Angel's DERIVED copies go — companions in the batch folder,
//     regenerable; the originals on their source volumes are never touched;
//   • the buffer space comes back;
//   • the undecided rows (status `.ready`) return to the pool with an
//     `angelCleared` ledger line each — half a skip in the attention
//     memory (Phase 1). Skipped, promoted and failed rows were decided
//     already and get no line;
//   • the plan is saved `.discarded` BEFORE the folder is removed, so the
//     decision is durable even if the removal fails;
//   • the catalogued companion records are retired with the files
//     (codex #1572 — `forgetArchiveAngelCompanions`).
// A promoted / discarded leftover (its failed rows' folders) is folder +
// log only: its rows were decided long ago.
//
// What it REFUSES: a batch a job in this app is working on
// (`ArchiveAngelLiveBatches`), and a batch whose plan says `.promoting`
// (a stranded promote is settled by `settleStrandedPromotions` on the next
// refresh — never cleared under it).

import Foundation
import VideoScanCore

struct ArchiveAngelBatchClearOutcome: Equatable, Sendable {
    enum Refusal: Equatable, Sendable {
        case live
        case promoting
        var text: String {
            switch self {
            case .live: return "a job in this app is working on it"
            case .promoting: return "a promote is in flight"
            }
        }
    }

    let batchID: String
    var refusal: Refusal?
    /// Folder bytes measured before removal (0 when refused).
    var bytesFreed: Int64 = 0
    /// Undecided rows that got an `angelCleared` line.
    var rowsReturned: Int = 0
    /// Catalogued companion records retired.
    var companionsRetired: Int = 0
    var folderRemoved = false
    var error: String?

    var cleared: Bool { refusal == nil && folderRemoved }
}

extension VideoScanModel {

    /// Clear one batch from the buffer. `reason` is the human line for the
    /// plan log, the ledger and the app log ("discarded by you in the
    /// review sheet", "Clear all from the buffer card"). `remove` is a
    /// test seam for a failing removal; production never passes it.
    @discardableResult
    func clearArchiveAngelBatch(_ plan: ArchiveAngelPlan, reason: String, at now: Date = Date(),
                                remove: (ArchiveAngelPlan) throws -> Void = ArchiveAngelPlanStore.removeBatchFolder)
    -> ArchiveAngelBatchClearOutcome {
        var out = ArchiveAngelBatchClearOutcome(batchID: plan.batchID)

        // Safeguards first.
        if ArchiveAngelLiveBatches.isLive(plan.batchDir) {
            out.refusal = .live
        } else if plan.status == .promoting {
            out.refusal = .promoting
        }
        if let refusal = out.refusal {
            note("Archive Angel: not clearing \(plan.batchID) — \(refusal.text)")
            return out
        }

        out.bytesFreed = ArchiveAngelPlanStore.folderBytes(plan.batchDir, fm: .default)

        // An undecided batch: the decision, durably, before anything is deleted.
        var plan = plan
        if plan.status == .ready || plan.status == .preparing {
            let undecided = plan.entries.filter { $0.status == .ready }.map(\.id)
            ledgerAngelAttention(.angelCleared, recordIDs: undecided, batchID: plan.batchID, reason: reason, at: now)
            out.rowsReturned = undecided.count
            plan.status = .discarded
            plan.finishedAt = plan.finishedAt ?? now
            plan.log.append("Cleared from the buffer — \(reason); \(undecided.count) undecided row(s) returned to the pool")
            ArchiveAngelPlanStore.saveLogged(plan, context: "clearing the batch")
        }

        // Records go with their files (codex #1572), then the files.
        out.companionsRetired = forgetArchiveAngelCompanions(batchDir: plan.batchDir, reason: "batch cleared — \(reason)", at: now)
        do {
            try remove(plan)
            out.folderRemoved = true
        } catch {
            out.error = error.localizedDescription
            note("Archive Angel: could not remove the buffer folder of \(plan.batchID) — \(error.localizedDescription)")
        }

        note("Archive Angel: cleared \(plan.batchID) — \(MediaBytes.display(out.bytesFreed)) back"
             + (out.rowsReturned > 0 ? ", \(out.rowsReturned) undecided row(s) returned to the pool" : "")
             + (out.companionsRetired > 0 ? ", \(out.companionsRetired) companion record(s) retired" : "")
             + (out.folderRemoved ? "" : " (folder NOT removed)")
             + "; originals untouched — \(reason)")
        return out
    }

    /// Clear several rows (the card's Clear all). Refusals and failures
    /// are in the outcomes; nothing stops the loop.
    @discardableResult
    func clearArchiveAngelBatches(_ plans: [ArchiveAngelPlan], reason: String) -> [ArchiveAngelBatchClearOutcome] {
        let outcomes = plans.map { clearArchiveAngelBatch($0, reason: reason) }
        let freed = outcomes.reduce(Int64(0)) { $0 + ($1.cleared ? $1.bytesFreed : 0) }
        let done = outcomes.filter(\.cleared).count
        if plans.count > 1 {
            note("Archive Angel: cleared \(done) of \(plans.count) batches — \(MediaBytes.display(freed)) back — \(reason)")
        }
        return outcomes
    }

    /// The hygiene verb's one log call: the console AND videoscan.log.
    private func note(_ line: String) {
        log(line)
        appLog.write(line)
    }
}
