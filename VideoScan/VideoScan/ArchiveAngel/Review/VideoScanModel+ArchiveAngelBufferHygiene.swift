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
// OFF-MAIN I/O (codex #1714 R3, 2026-09-23): the verb is async; the path
// stats, the current plan.json read and its full-fsync `.discarded` save
// run in `@concurrent` helpers, with the batch CLAIMED live for the whole
// span. Only the ledger line and the scheduling stay on the main actor.
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

    /// Test seam (codex #1714 R3): called at the start of each off-main
    /// disk phase with its name ("path", "plan") and the batch folder. A
    /// test records which thread ran it and can stall it (for its own batch
    /// only — suites run in parallel) to stand in for slow storage. Nil in
    /// production; always compiled so Release test runs can set it.
    nonisolated(unsafe) static var clearDiskProbe: (@Sendable (String, String) -> Void)?

    /// What the off-main checks found (codex #1714 R3): the path guards and
    /// the folder's existence (phase 1), then the CURRENT plan.json read and
    /// — for an undecided batch — its `.discarded` save (phase 2).
    enum ClearDiskPhase: Sendable {
        case refused(ArchiveAngelBatchClearOutcome.Refusal)
        /// The plan could not be saved `.discarded`.
        case saveFailed(String)
        /// Ready to remove: the current plan (saved `.discarded` when it was
        /// undecided) and the undecided rows that returned to the pool.
        case ready(ArchiveAngelPlan, undecided: [UUID])
    }

    /// Phase 1, OFF the main actor: the lexical / symlink / canonical path
    /// guard and "is the folder still there" — each a stat on the buffer
    /// volume, which may be slow or hung external storage. `@concurrent`
    /// because in this project a plain `nonisolated async` runs on the
    /// CALLER's actor (Approachable Concurrency) — C++: this is the
    /// std::async(std::launch::async, …) version, not the deferred one.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func clearPathChecks(batchDir: String) async -> ArchiveAngelBatchClearOutcome.Refusal? {
        clearDiskProbe?("path", batchDir)
        let parent = URL(fileURLWithPath: batchDir).standardizedFileURL.deletingLastPathComponent()
        do {
            try ArchiveAngelPlanStore.checkBatchFolder(batchDir, bufferRoot: parent)
        } catch {
            return .notABatchFolder(error.localizedDescription)
        }
        return FileManager.default.fileExists(atPath: batchDir) ? nil : .gone
    }

    /// Phase 2, OFF the main actor, with the batch already CLAIMED (live)
    /// by the caller: read the current plan.json (never the caller's copy,
    /// #1), refuse a promoting one, and save an undecided batch `.discarded`
    /// (a full-fsync write) BEFORE anything is deleted. The ledger is not
    /// touched here — the caller writes it on the main actor only after
    /// `.ready` came back, preserving save-before-ledger (#2).
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func clearPlanPhase(batchDir: String, reason: String, at now: Date) async -> ClearDiskPhase {
        clearDiskProbe?("plan", batchDir)
        var plan: ArchiveAngelPlan
        do {
            plan = try ArchiveAngelPlanStore.load(batchDir: batchDir)
        } catch {
            return .refused(.unreadable(error.localizedDescription))
        }
        if plan.status == .promoting { return .refused(.promoting) }
        guard plan.status == .ready || plan.status == .preparing else { return .ready(plan, undecided: []) }
        let undecided = plan.entries.filter { $0.status == .ready }.map(\.id)
        plan.status = .discarded
        plan.finishedAt = plan.finishedAt ?? now
        plan.log.append("Cleared from the buffer — \(reason); \(undecided.count) undecided row(s) returned to the pool")
        guard ArchiveAngelPlanStore.saveLogged(plan, context: "clearing the batch") else {
            return .saveFailed("could not save plan.json as discarded — nothing was cleared; try again")
        }
        return .ready(plan, undecided: undecided)
    }

    /// Clear one batch from the buffer. `reason` is the human line for the
    /// plan log, the ledger and the app log ("discarded by you in the
    /// review sheet", "Clear all from the buffer card"). `bytes` is the
    /// folder size the caller already knows (nil = the removal task walks
    /// it, off the main actor). `remove` is a test seam for a failing
    /// removal; production never passes it — the path guard runs before it
    /// either way. `retireCompanions` is false only from Clear all, which
    /// retires them in one pass afterwards.
    ///
    /// ASYNC since 2026-09-23 (codex #1714 R3): every stat, the plan.json
    /// read and its full-fsync save run off the main actor, so Clear on a
    /// slow or hung external buffer no longer stalls the UI. The main
    /// actor keeps only the bookkeeping, in the same order as before:
    /// path guards → folder gone → live (now an atomic CLAIM, held from
    /// here until the removal ends, so no job can start on the batch while
    /// its plan is read and saved) → unreadable → promoting → save
    /// `.discarded` → ledger → removal.
    @discardableResult
    func clearArchiveAngelBatch(_ snapshot: ArchiveAngelPlan, reason: String, bytes: Int64? = nil,
                                at now: Date = Date(),
                                remove: (@Sendable (ArchiveAngelPlan) throws -> Void)? = nil,
                                retireCompanions: Bool = true) async
    -> ArchiveAngelBatchClearOutcome {
        var out = ArchiveAngelBatchClearOutcome(batchID: snapshot.batchID)
        let batchDir = snapshot.batchDir
        let parent = URL(fileURLWithPath: batchDir).standardizedFileURL.deletingLastPathComponent()

        // Safeguards first — the path (lexical, symlink, canonical), then
        // the state on disk. Off-main.
        if let refusal = await Self.clearPathChecks(batchDir: batchDir) {
            out.refusal = refusal
        } else if !ArchiveAngelLiveBatches.claim(batchDir) {
            out.refusal = .live
        }
        if let refusal = out.refusal {
            note("Archive Angel: not clearing \(snapshot.batchID) — \(refusal.text)")
            return out
        }

        // Claimed. The truth is plan.json, not the caller's copy
        // (idempotence), and a copy is never a substitute for it (#1); an
        // undecided batch's decision is saved durably before anything is
        // deleted — and before the ledger hears of it (#2).
        let plan: ArchiveAngelPlan
        let undecided: [UUID]
        switch await Self.clearPlanPhase(batchDir: batchDir, reason: reason, at: now) {
        case .refused(let refusal):
            ArchiveAngelLiveBatches.end(batchDir)
            out.refusal = refusal
            note("Archive Angel: not clearing \(snapshot.batchID) — \(refusal.text)")
            return out
        case .saveFailed(let why):
            ArchiveAngelLiveBatches.end(batchDir)
            out.error = why
            note("Archive Angel: not clearing \(snapshot.batchID) — \(why); the folder, its records and the ledger are untouched")
            return out
        case .ready(let current, let rows):
            plan = current
            undecided = rows
        }

        out.bytesFreed = bytes ?? 0
        if !undecided.isEmpty {
            ledgerAngelAttention(.angelCleared, recordIDs: undecided, batchID: plan.batchID, reason: reason, at: now)
            out.rowsReturned = undecided.count
        }

        // The files, off the main actor. The claim taken above is handed to
        // the removal task (its `defer` releases it), so a second Clear, the
        // settle and the hygiene report all see "busy" throughout. The
        // companion records go AFTER the files, and only for files that are
        // confirmed gone (#4).
        let remover: @Sendable (ArchiveAngelPlan) throws -> Void = remove
            ?? { try ArchiveAngelPlanStore.removeBatchFolder($0, bufferRoot: parent) }
        let batchID = plan.batchID, known = bytes, planForRemoval = plan
        let companionReason = "batch cleared — \(reason)"
        out.removal = Task.detached(priority: .utility) { [weak self] in
            defer { ArchiveAngelLiveBatches.end(batchDir) }
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
    /// Batches are cleared one after another, in the order given (each
    /// one's plan I/O off the main actor).
    @discardableResult
    func clearArchiveAngelBatches(_ plans: [ArchiveAngelPlan], bytes: [String: Int64] = [:],
                                  reason: String, at now: Date = Date(),
                                  remove: (@Sendable (ArchiveAngelPlan) throws -> Void)? = nil) async
    -> ArchiveAngelBatchClearAllOutcome {
        var outcomes: [ArchiveAngelBatchClearOutcome] = []
        outcomes.reserveCapacity(plans.count)
        for plan in plans {
            outcomes.append(await clearArchiveAngelBatch(plan, reason: reason, bytes: bytes[plan.batchID], at: now,
                                                         remove: remove, retireCompanions: false))
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
