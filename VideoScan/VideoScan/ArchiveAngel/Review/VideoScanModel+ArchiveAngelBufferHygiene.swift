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
//     (codex #1572 — `forgetArchiveAngelCompanions`), AFTER the removal
//     and only for files confirmed gone (codex review 2026-09-20 #4).
// A promoted / discarded leftover (its failed rows' folders) is folder +
// log only: its rows were decided long ago.
//
// What it REFUSES (QA 2026-09-19 review + codex review 2026-09-20,
// `Refusal`):
//   • a folder that is not `<parent>/batch-…`, a folder that is itself a
//     symlink, or one whose canonical path is not directly under the
//     buffer (#3: an alias to a live or external batch used to pass the
//     lexical guard) — this is the entry point that deletes, so the path
//     is checked before anything else;
//   • a batch whose folder is already gone (a stale snapshot: the card's
//     row before the refresh lands, the sheet's own copy) — nothing is
//     written, nothing is resurrected;
//   • a batch a job in this app is working on (`ArchiveAngelLiveBatches`)
//     — including one whose removal is still in flight;
//   • a batch whose CURRENT plan.json cannot be read (#1) — the caller's
//     snapshot is never a substitute; an unreadable batch is preserved
//     (audit #7, ArchiveAngelPlan.swift);
//   • a batch whose plan.json says `.promoting` (a stranded promote is
//     settled by `settleStrandedPromotions` on the next refresh).
// IDEMPOTENT: the plan is RELOADED from disk before anything is written;
// a snapshot that says `.ready` for a batch already `.discarded` on disk
// gets no second half-skip and no plan save — folder and companions only.
// ORDER (#2): the `.discarded` plan is SAVED first; the `angelCleared`
// ledger lines are written only after a successful save. A failed save is
// an explicit `error` — no ledger line, no companion retired, no removal
// scheduled — and a retry finds the plan still `.ready` on disk, so it
// writes the lines exactly once.
//
// Main-actor cost: bookkeeping only (#10). The folder size comes from
// the caller (the card row already has it); when the caller has none
// (the review sheet's Discard) the walk runs in the detached removal
// task, never here. The removal runs AFTER the bookkeeping, logs when it
// is done, and then hops back to the main actor to retire the companion
// records of the files that are confirmed gone — the verb returns with
// the removal SCHEDULED, and `removal` is the task tests await. Clear all
// retires companions in ONE catalog pass for every batch it cleared.
//
// (For Rick: `Task.detached` ≈ handing the delete to a worker thread;
// `await MainActor.run { … }` inside it ≈ posting the bookkeeping back to
// the UI thread once the worker is done.)

import Foundation
import VideoScanCore

struct ArchiveAngelBatchClearOutcome: Sendable {
    enum Refusal: Equatable, Sendable {
        case live
        case promoting
        /// The folder is already gone — a stale snapshot; nothing to do.
        case gone
        /// The path is not `<buffer>/batch-…` (or is an alias); the guard's reason.
        case notABatchFolder(String)
        /// The current plan.json cannot be read — preserved, never cleared
        /// from a snapshot (audit #7 policy).
        case unreadable(String)
        var text: String {
            switch self {
            case .live: return "a job in this app is working on it"
            case .promoting: return "a promote is in flight"
            case .gone: return "its folder is already gone"
            case .notABatchFolder(let why): return why
            case .unreadable(let why): return "its plan.json can't be read (\(why)) — left in place, not cleared"
            }
        }
    }

    /// What the detached removal reported once it finished.
    struct Removal: Equatable, Sendable {
        /// true = the folder is gone.
        var removed: Bool
        /// Bytes that came back (the caller's figure, or the walk done off-main).
        var bytesFreed: Int64
        /// Catalogued companion records retired — only for files confirmed
        /// gone. 0 when Clear all retires them in its single pass.
        var companionsRetired: Int
        var failure: String?
    }

    let batchID: String
    var refusal: Refusal?
    /// Folder bytes coming back once the removal lands — the caller's
    /// figure. 0 when refused, and 0 until the removal has measured the
    /// folder when the caller had no figure (see `Removal.bytesFreed`).
    var bytesFreed: Int64 = 0
    /// Undecided rows that got an `angelCleared` line (0 on a repeat).
    var rowsReturned: Int = 0
    /// The removal was handed to a detached task; `removal` says how it went.
    var removalScheduled = false
    /// nil when refused or when the plan save failed.
    var removal: Task<Removal, Never>?
    /// The plan could not be saved `.discarded`: nothing was written to
    /// the ledger, no companion was retired, no removal was scheduled.
    var error: String?

    var cleared: Bool { refusal == nil && error == nil && removalScheduled }
}

/// Clear all's answer: one outcome per batch, and `finished` — every
/// removal awaited, then the ONE companion pass (its count).
struct ArchiveAngelBatchClearAllOutcome: Sendable {
    var outcomes: [ArchiveAngelBatchClearOutcome]
    var finished: Task<Int, Never>
}

extension VideoScanModel {

    /// Clear one batch from the buffer. `reason` is the human line for the
    /// plan log, the ledger and the app log ("discarded by you in the
    /// review sheet", "Clear all from the buffer card"). `bytes` is the
    /// folder size the caller already knows (nil = the removal task walks
    /// it, off the main actor). `remove` is a test seam for a failing
    /// removal; production never passes it — the path guard runs before it
    /// either way. `retireCompanions` is false only from Clear all, which
    /// retires them in one pass afterwards.
    @discardableResult
    func clearArchiveAngelBatch(_ snapshot: ArchiveAngelPlan, reason: String, bytes: Int64? = nil,
                                at now: Date = Date(),
                                remove: (@Sendable (ArchiveAngelPlan) throws -> Void)? = nil,
                                retireCompanions: Bool = true)
    -> ArchiveAngelBatchClearOutcome {
        var out = ArchiveAngelBatchClearOutcome(batchID: snapshot.batchID)
        let fm = FileManager.default
        let parent = URL(fileURLWithPath: snapshot.batchDir).standardizedFileURL.deletingLastPathComponent()

        // Safeguards first — the path (lexical, symlink, canonical), then
        // the state on disk.
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
        // The truth is plan.json, not the caller's copy (idempotence), and
        // a copy is never a substitute for it (#1).
        var plan = snapshot
        if out.refusal == nil {
            do {
                plan = try ArchiveAngelPlanStore.load(batchDir: snapshot.batchDir)
            } catch {
                out.refusal = .unreadable(error.localizedDescription)
            }
        }
        if out.refusal == nil, plan.status == .promoting {
            out.refusal = .promoting
        }
        if let refusal = out.refusal {
            note("Archive Angel: not clearing \(snapshot.batchID) — \(refusal.text)")
            return out
        }

        out.bytesFreed = bytes ?? 0

        // An undecided batch: the decision, durably, before anything is
        // deleted — and before the ledger hears of it (#2).
        var undecided: [UUID] = []
        if plan.status == .ready || plan.status == .preparing {
            undecided = plan.entries.filter { $0.status == .ready }.map(\.id)
            plan.status = .discarded
            plan.finishedAt = plan.finishedAt ?? now
            plan.log.append("Cleared from the buffer — \(reason); \(undecided.count) undecided row(s) returned to the pool")
            guard ArchiveAngelPlanStore.saveLogged(plan, context: "clearing the batch") else {
                out.error = "could not save plan.json as discarded — nothing was cleared; try again"
                note("Archive Angel: not clearing \(plan.batchID) — \(out.error ?? ""); the folder, its records and the ledger are untouched")
                return out
            }
            ledgerAngelAttention(.angelCleared, recordIDs: undecided, batchID: plan.batchID, reason: reason, at: now)
            out.rowsReturned = undecided.count
        }

        // The files, off the main actor. Live while it runs, so a second
        // Clear, the settle and the hygiene report all see "busy". The
        // companion records go AFTER the files, and only for files that
        // are confirmed gone (#4).
        let remover: @Sendable (ArchiveAngelPlan) throws -> Void = remove
            ?? { try ArchiveAngelPlanStore.removeBatchFolder($0, bufferRoot: parent) }
        let batchID = plan.batchID, known = bytes, planForRemoval = plan
        let companionReason = "batch cleared — \(reason)"
        ArchiveAngelLiveBatches.begin(plan.batchDir)
        out.removal = Task.detached(priority: .utility) { [weak self] in
            defer { ArchiveAngelLiveBatches.end(planForRemoval.batchDir) }
            // The walk the caller did not do (#10): here, never on main.
            let freed = known ?? ArchiveAngelPlanStore.folderBytes(planForRemoval.batchDir, fm: .default)
            let failure: String?
            do { try remover(planForRemoval); failure = nil } catch { failure = error.localizedDescription }
            let retired = await MainActor.run { () -> Int in
                guard let self else { return 0 }
                if let failure {
                    self.note("Archive Angel: could not remove the buffer folder of \(batchID) — \(failure)")
                } else {
                    self.note("Archive Angel: removed the buffer folder of \(batchID) — \(MediaBytes.display(freed)) back")
                }
                guard retireCompanions else { return 0 }
                return self.forgetArchiveAngelCompanions(batchDir: planForRemoval.batchDir, reason: companionReason, at: now)
            }
            return ArchiveAngelBatchClearOutcome.Removal(removed: failure == nil, bytesFreed: freed,
                                                         companionsRetired: retired, failure: failure)
        }
        out.removalScheduled = true

        note("Archive Angel: clearing \(plan.batchID) — "
             + (known.map { "\(MediaBytes.display($0)) coming back" } ?? "measuring the folder")
             + (out.rowsReturned > 0 ? ", \(out.rowsReturned) undecided row(s) returned to the pool" : "")
             + "; originals untouched — \(reason)")
        return out
    }

    /// Clear several batches (the card's Clear all). `bytes` by batch id
    /// — what the rows already measured. Refusals and failures are in the
    /// outcomes; nothing stops the loop, and no removal runs inline here.
    /// The companion records of every cleared batch are retired in ONE
    /// catalog pass once every removal has landed (#10) — `finished`.
    @discardableResult
    func clearArchiveAngelBatches(_ plans: [ArchiveAngelPlan], bytes: [String: Int64] = [:],
                                  reason: String, at now: Date = Date(),
                                  remove: (@Sendable (ArchiveAngelPlan) throws -> Void)? = nil)
    -> ArchiveAngelBatchClearAllOutcome {
        let outcomes = plans.map {
            clearArchiveAngelBatch($0, reason: reason, bytes: bytes[$0.batchID], at: now, remove: remove,
                                   retireCompanions: false)
        }
        let known = outcomes.reduce(Int64(0)) { $0 + ($1.cleared ? $1.bytesFreed : 0) }
        let done = outcomes.filter(\.cleared).count
        if plans.count > 1 {
            note("Archive Angel: clearing \(done) of \(plans.count) batches — \(MediaBytes.display(known)) coming back — \(reason)")
        }
        let clearedDirs = zip(plans, outcomes).filter { $0.1.cleared }.map { $0.0.batchDir }
        let removals = outcomes.compactMap(\.removal)
        let companionReason = "batch cleared — \(reason)"
        let finished = Task { [weak self] () -> Int in
            for r in removals { _ = await r.value }
            guard let self, !clearedDirs.isEmpty else { return 0 }
            return self.forgetArchiveAngelCompanions(batchDirs: clearedDirs, reason: companionReason, at: now)
        }
        return ArchiveAngelBatchClearAllOutcome(outcomes: outcomes, finished: finished)
    }

    /// The hygiene verb's one log call: the console AND videoscan.log.
    private func note(_ line: String) {
        log(line)
        appLog.write(line)
    }
}
