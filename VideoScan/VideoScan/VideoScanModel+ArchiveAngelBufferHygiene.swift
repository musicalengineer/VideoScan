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
// What it REFUSES (QA 2026-09-19 review, `Refusal`):
//   • a folder that is not `<parent>/batch-…` — this is the entry point
//     that deletes, so the path is checked before anything else;
//   • a batch whose folder is already gone (a stale snapshot: the card's
//     row before the refresh lands, the sheet's own copy) — nothing is
//     written, nothing is resurrected;
//   • a batch a job in this app is working on (`ArchiveAngelLiveBatches`)
//     — including one whose removal is still in flight;
//   • a batch whose plan.json says `.promoting` (a stranded promote is
//     settled by `settleStrandedPromotions` on the next refresh).
// IDEMPOTENT: the plan is RELOADED from disk before the ledger lines; a
// snapshot that says `.ready` for a batch already `.discarded` on disk
// gets no second half-skip and no plan save — folder and companions only.
//
// Main-actor cost: bookkeeping only. The folder size comes from the
// caller (the card row already has it; the walk is the fallback), and the
// removal runs in a detached task AFTER the bookkeeping, logging when it
// is done — the verb returns with the removal SCHEDULED, and `removal`
// is the task tests await.
//
// (For Rick: `Task.detached` ≈ handing the delete to a worker thread;
// `await MainActor.run { … }` inside it ≈ posting the log line back to
// the UI thread.)

import Foundation
import VideoScanCore

struct ArchiveAngelBatchClearOutcome: Sendable {
    enum Refusal: Equatable, Sendable {
        case live
        case promoting
        /// The folder is already gone — a stale snapshot; nothing to do.
        case gone
        /// The path is not `<buffer>/batch-…`; the guard's reason.
        case notABatchFolder(String)
        var text: String {
            switch self {
            case .live: return "a job in this app is working on it"
            case .promoting: return "a promote is in flight"
            case .gone: return "its folder is already gone"
            case .notABatchFolder(let why): return why
            }
        }
    }

    let batchID: String
    var refusal: Refusal?
    /// Folder bytes coming back once the removal lands (0 when refused).
    var bytesFreed: Int64 = 0
    /// Undecided rows that got an `angelCleared` line (0 on a repeat).
    var rowsReturned: Int = 0
    /// Catalogued companion records retired.
    var companionsRetired: Int = 0
    /// The removal was handed to a detached task; `removal` says how it went.
    var removalScheduled = false
    /// true = the folder is gone. nil when refused.
    var removal: Task<Bool, Never>?
    var error: String?

    var cleared: Bool { refusal == nil && removalScheduled }
}

extension VideoScanModel {

    /// Clear one batch from the buffer. `reason` is the human line for the
    /// plan log, the ledger and the app log ("discarded by you in the
    /// review sheet", "Clear all from the buffer card"). `bytes` is the
    /// folder size the caller already knows (nil = walk it here). `remove`
    /// is a test seam for a failing removal; production never passes it —
    /// the path guard runs before it either way.
    @discardableResult
    func clearArchiveAngelBatch(_ snapshot: ArchiveAngelPlan, reason: String, bytes: Int64? = nil,
                                at now: Date = Date(),
                                remove: (@Sendable (ArchiveAngelPlan) throws -> Void)? = nil)
    -> ArchiveAngelBatchClearOutcome {
        var out = ArchiveAngelBatchClearOutcome(batchID: snapshot.batchID)
        let fm = FileManager.default
        let parent = URL(fileURLWithPath: snapshot.batchDir).standardizedFileURL.deletingLastPathComponent()

        // Safeguards first — the path, then the state on disk.
        do {
            try ArchiveAngelPlanStore.checkBatchFolder(snapshot.batchDir, bufferRoot: parent)
        } catch {
            out.refusal = .notABatchFolder(error.localizedDescription)
        }
        if out.refusal == nil, !fm.fileExists(atPath: snapshot.batchDir) {
            out.refusal = .gone
        }
        if out.refusal == nil, ArchiveAngelLiveBatches.isLive(snapshot.batchDir) {
            out.refusal = .live
        }
        // The truth is plan.json, not the caller's copy (idempotence).
        var plan = (try? ArchiveAngelPlanStore.load(batchDir: snapshot.batchDir)) ?? snapshot
        if out.refusal == nil, plan.status == .promoting {
            out.refusal = .promoting
        }
        if let refusal = out.refusal {
            note("Archive Angel: not clearing \(snapshot.batchID) — \(refusal.text)")
            return out
        }

        out.bytesFreed = bytes ?? ArchiveAngelPlanStore.folderBytes(plan.batchDir, fm: fm)

        // An undecided batch: the decision, durably, before anything is deleted.
        if plan.status == .ready || plan.status == .preparing {
            let undecided = plan.entries.filter { $0.status == .ready }.map(\.id)
            ledgerAngelAttention(.angelCleared, recordIDs: undecided, batchID: plan.batchID, reason: reason, at: now)
            out.rowsReturned = undecided.count
            plan.status = .discarded
            plan.finishedAt = plan.finishedAt ?? now
            plan.log.append("Cleared from the buffer — \(reason); \(undecided.count) undecided row(s) returned to the pool")
            ArchiveAngelPlanStore.saveLogged(plan, context: "clearing the batch")
        }

        // Records go with their files (codex #1572) …
        out.companionsRetired = forgetArchiveAngelCompanions(batchDir: plan.batchDir, reason: "batch cleared — \(reason)", at: now)

        // … then the files, off the main actor. Live while it runs, so a
        // second Clear, the settle and the hygiene report all see "busy".
        let remover: @Sendable (ArchiveAngelPlan) throws -> Void = remove
            ?? { try ArchiveAngelPlanStore.removeBatchFolder($0, bufferRoot: parent) }
        let batchID = plan.batchID, freed = out.bytesFreed, planForRemoval = plan
        ArchiveAngelLiveBatches.begin(plan.batchDir)
        out.removal = Task.detached(priority: .utility) { [weak self] in
            defer { ArchiveAngelLiveBatches.end(planForRemoval.batchDir) }
            let failure: String?
            do { try remover(planForRemoval); failure = nil } catch { failure = error.localizedDescription }
            await MainActor.run {
                if let failure {
                    self?.note("Archive Angel: could not remove the buffer folder of \(batchID) — \(failure)")
                } else {
                    self?.note("Archive Angel: removed the buffer folder of \(batchID) — \(MediaBytes.display(freed)) back")
                }
            }
            return failure == nil
        }
        out.removalScheduled = true

        note("Archive Angel: clearing \(plan.batchID) — \(MediaBytes.display(out.bytesFreed)) coming back"
             + (out.rowsReturned > 0 ? ", \(out.rowsReturned) undecided row(s) returned to the pool" : "")
             + (out.companionsRetired > 0 ? ", \(out.companionsRetired) companion record(s) retired" : "")
             + "; originals untouched — \(reason)")
        return out
    }

    /// Clear several batches (the card's Clear all). `bytes` by batch id
    /// — what the rows already measured. Refusals and failures are in the
    /// outcomes; nothing stops the loop, and no removal runs inline here.
    @discardableResult
    func clearArchiveAngelBatches(_ plans: [ArchiveAngelPlan], bytes: [String: Int64] = [:],
                                  reason: String) -> [ArchiveAngelBatchClearOutcome] {
        let outcomes = plans.map { clearArchiveAngelBatch($0, reason: reason, bytes: bytes[$0.batchID]) }
        let freed = outcomes.reduce(Int64(0)) { $0 + ($1.cleared ? $1.bytesFreed : 0) }
        let done = outcomes.filter(\.cleared).count
        if plans.count > 1 {
            note("Archive Angel: clearing \(done) of \(plans.count) batches — \(MediaBytes.display(freed)) coming back — \(reason)")
        }
        return outcomes
    }

    /// The hygiene verb's one log call: the console AND videoscan.log.
    private func note(_ line: String) {
        log(line)
        appLog.write(line)
    }
}
