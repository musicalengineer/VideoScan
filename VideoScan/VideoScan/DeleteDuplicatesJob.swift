// DeleteDuplicatesJob.swift
// Delete Duplicates as a Media File Operation (Rick 2026-09-20).
//
// What Rick saw: "Delete 2,992 files from SanDisk" showed only
// "Verifying 1 of 2,992" and read BOTH files of every pair in full —
// hours, nothing to look at. What he asked for: (1) use the precomputed
// hash ids; (2) if bytes must be compared, read only the file being
// deleted; (3) a DELETE row in the MFO window with "2 of N", "3 deleted",
// and a click that lists the files. Earlier the same day: quit + resume,
// pause, a time estimate.
//
// The decision (feedback_delete_safety_principle, unchanged): prove the
// surviving copy at the moment of deletion; refuse over guess; log and
// ledger every file; never auto-delete. So:
//   • the file being DELETED is always read in full, now — twice, in
//     fact: once to verify it, once more after it has been moved into
//     quarantine (codex 1593 blocker 1: a same-length rewrite through an
//     open descriptor with the mtime put back used to pass the post-move
//     check, because the move itself bumps ctime and ctime was ignored);
//   • the KEEPER is read at most once ever — the first pair reads it and
//     stores a whole-file fixity (digest + stat stamp) on its record; every
//     later pair stats the keeper and, if the stamp reproduces, compares
//     the duplicate's fresh digest against the stored one
//     (`SignatureVerification.verifyAgainstStoredKeeper`);
//   • there is NO both-sides-stored, nothing-read path — `contentHash` and
//     `partialMD5` never authorise a delete (design #320).
//
// ONE PAIR, TWO DISK PHASES. Phase 1 (detached): verify, then move the
// file into an owner-only quarantine folder named from this plan + row.
// Back on the main actor the plan RECORDS that folder and the file's
// stamp there and is saved — so a crash between the move and the unlink
// leaves a plan that names exactly where the file is (codex 1593 blocker
// 2: recovery used to guess by basename across any sibling quarantine and
// then remove the whole folder recursively). Phase 2 (detached): re-read,
// re-check, unlink. Then the catalog settles (carry-over, row removal,
// ledger, log), the row is updated and the plan saved again.
//
// Before EVERY pair the catalog is asked again whether the row is still
// authorised (`VideoScanModel.authorizeDuplicateDeletion`) — after a
// pause, a resume, anything: a cached yes is never acted on (#3).
//
// Pause waits between pairs. Stop leaves what is done done and the rest
// counted, not done. QUIT is different (#5): the run is suspended, the
// row in flight goes back to pending, the plan stays in place unfinished
// and is offered to resume at the next launch.
//
// (For Rick: `@MainActor final class` ≈ a class whose every member is
// touched only on the UI thread; the disk work is handed to
// `Task.detached` ≈ a worker thread, and the result awaited.)

import Combine
import Foundation
import os
import VideoScanCore

private let deleteDupLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "deleteDuplicates")

// MARK: - Off-main work item + outcome

struct DeleteDuplicatesWorkItem: Sendable {
    let path: String
    let keeperPath: String
    let keeperFilename: String
    /// The keeper's stored whole-file fixity, if it has one.
    let keeperFixity: ContentFixity?
    /// The quarantine folder name for THIS row (plan + row ids), so a
    /// crash leaves a folder the plan can name even before it is saved.
    let quarantineDirectoryName: String
}

enum DeleteDuplicatesDiskOutcome: Sendable {
    /// Phase 1 done: verified and moved into quarantine, not yet removed.
    case quarantined(QuarantineTicket)
    case deleted(bytes: Int64, proof: VerifiedDuplicate)
    case refused(reason: String, cancelled: Bool)
    case failed(reason: String)
    case retained(path: String, reason: String)
}

enum DeleteDuplicatesDiskWorker {
    /// Phase 1, outside the main actor: verify against the stored keeper
    /// (or read both once), then move the verified inode into quarantine.
    /// Carries only immutable value snapshots — never VideoRecord
    /// instances.
    static func verifyAndQuarantine(_ item: DeleteDuplicatesWorkItem,
                                    hooks: SignatureVerification.Hooks) -> DeleteDuplicatesDiskOutcome {
        switch SignatureVerification.verifyAgainstStoredKeeper(keeperPath: item.keeperPath,
                                                               keeperFixity: item.keeperFixity,
                                                               duplicatePath: item.path,
                                                               hooks: hooks) {
        case .failure(let failure):
            return .refused(reason: duplicateRefusalNote(failure, keeper: item.keeperFilename),
                            cancelled: failure == .cancelled)
        case .success(let proof):
            switch SignatureVerification.quarantine(proof, directoryName: item.quarantineDirectoryName, hooks: hooks) {
            case .quarantined(let ticket): return .quarantined(ticket)
            case .refused(let failure):
                return .refused(reason: duplicateRefusalNote(failure, keeper: item.keeperFilename),
                                cancelled: failure == .cancelled)
            case .failed(let reason): return .failed(reason: reason)
            case .retainedQuarantine(let path, let reason):
                return .retained(path: path, reason: reason)
            }
        }
    }

    /// Phase 2: re-read the quarantined file, re-check every identity,
    /// unlink.
    static func deleteQuarantined(_ ticket: QuarantineTicket, keeperFilename: String,
                                  hooks: SignatureVerification.Hooks) -> DeleteDuplicatesDiskOutcome {
        map(SignatureVerification.deleteQuarantined(ticket, hooks: hooks), proof: ticket.proof, keeper: keeperFilename)
    }

    /// Put a quarantined file back without deleting it (the plan could not
    /// record the quarantine, or the run is stopping).
    static func release(_ ticket: QuarantineTicket, reason: String, keeperFilename: String) -> DeleteDuplicatesDiskOutcome {
        map(SignatureVerification.releaseQuarantine(ticket, reason: reason), proof: ticket.proof, keeper: keeperFilename)
    }

    private static func map(_ result: SignatureVerification.DeletionResult, proof: VerifiedDuplicate,
                            keeper: String) -> DeleteDuplicatesDiskOutcome {
        switch result {
        case .deleted(let bytes): return .deleted(bytes: bytes, proof: proof)
        case .refused(let failure):
            return .refused(reason: duplicateRefusalNote(failure, keeper: keeper), cancelled: failure == .cancelled)
        case .failed(let reason): return .failed(reason: reason)
        case .retainedQuarantine(let path, let reason): return .retained(path: path, reason: reason)
        }
    }
}

// MARK: - The job

@MainActor
final class DeleteDuplicatesJob: @MainActor MediaFileOperationJob {

    let id = UUID()
    let kind: MediaFileOperationKind = .deleteDuplicates
    let startedAt = Date()

    weak var model: VideoScanModel?
    let volumePath: String
    let hooks: SignatureVerification.Hooks
    let planRoot: URL
    /// Set when this job resumes a plan found at launch.
    private let resumingPlan: DeleteDuplicatesPlan?

    /// The plan — nil until prepared (fresh run) or re-validated (resume).
    @Published private(set) var plan: DeleteDuplicatesPlan?
    @Published private(set) var state: MediaFileOperationState = .running {
        didSet { if !state.isActive, finishedAt == nil { finishedAt = Date() } }
    }
    @Published private(set) var finishedAt: Date?
    @Published private(set) var subtitleText = "Choosing what to delete…"
    @Published private(set) var fractionValue: Double = 0
    @Published private(set) var isIndeterminateValue = true
    @Published private(set) var isPausedValue = false
    private(set) var wasRefused = false

    /// The old verb's result tuple — valid once the job is terminal.
    private(set) var result: (deleted: Int, failed: Int, skipped: Int, bytesFreed: Int64) = (0, 0, 0, 0)

    /// Internal so tests (and the model verb) can `await job.task?.value`.
    private(set) var task: Task<Void, Never>?
    private var currentWorker: Task<DeleteDuplicatesDiskOutcome, Never>?
    private var pauseWaiter: CheckedContinuation<Void, Never>?
    private var rate = DeleteDuplicatesRate()
    private var saveGeneration: UInt64 = 0
    /// A plan.json write failed: the run stops after the current pair —
    /// a resume nobody can trust is worse than none (the Angel's audit #5).
    private var planSaveFailed = false
    /// The app is quitting: suspend, don't abandon (#5).
    private(set) var quitRequested = false
    /// Test seam: runs just before the final save (finding #6 regression
    /// makes that save fail and checks the last good plan stays put).
    var testHookBeforeFinalSave: (@MainActor () -> Void)?

    var volumeName: String { URL(fileURLWithPath: volumePath).lastPathComponent }
    var title: String {
        if let plan {
            let f = NumberFormatter(); f.numberStyle = .decimal
            let n = f.string(from: NSNumber(value: plan.entries.count)) ?? "\(plan.entries.count)"
            return "Delete \(n) file\(plan.entries.count == 1 ? "" : "s") from \(volumeName)"
        }
        return "Delete duplicates on \(volumeName)"
    }
    var subtitle: String { subtitleText }
    var fraction: Double { fractionValue }
    var isIndeterminate: Bool { isIndeterminateValue }
    var canPause: Bool { true }
    var isPaused: Bool { isPausedValue }

    /// A fresh run on `volumePath`.
    init(model: VideoScanModel, volumePath: String,
         hooks: SignatureVerification.Hooks = .live,
         planRoot: URL = DeleteDuplicatesPlanStore.defaultRoot) {
        self.model = model
        self.volumePath = volumePath
        self.hooks = hooks
        self.planRoot = planRoot
        self.resumingPlan = nil
    }

    /// Resume a plan found at launch — every remaining row is re-validated
    /// before anything is read.
    init(model: VideoScanModel, resuming plan: DeleteDuplicatesPlan,
         hooks: SignatureVerification.Hooks = .live,
         planRoot: URL = DeleteDuplicatesPlanStore.defaultRoot) {
        self.model = model
        self.volumePath = plan.volumePath
        self.hooks = hooks
        self.planRoot = planRoot
        self.resumingPlan = plan
        self.plan = plan
        self.subtitleText = "Checking \(plan.remainingCount) remaining file(s) against the catalog…"
    }

    // MARK: Lifecycle

    /// Idempotent — a second call is a no-op.
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            await self.run()
            // Whatever this run did, the next unfinished plan (if any) is
            // offered now, not at the next launch (#8). `run` has released
            // the model's re-entry flag by here.
            self.model?.checkForUnfinishedDeleteDuplicatesPlans(root: self.planRoot)
        }
    }

    func refuseToStart(reason: String) {
        guard task == nil, state.isActive else { return }
        wasRefused = true
        finish(failed: reason)
        task = Task {}
    }

    /// Stop: the pair in flight is cancelled (its file stays), what is done
    /// stays done, the rest is counted as not done — as the old loop did.
    func cancel() {
        guard state.isActive else { return }
        state = .cancelling
        subtitleText = "Stopping — files already deleted stay deleted, the rest are left alone…"
        currentWorker?.cancel()
        task?.cancel()
        wakeIfPaused()
    }

    /// Quit: same interruption as Stop on disk (the pair in flight is put
    /// back, nothing half-done), but the plan is SUSPENDED — the row in
    /// flight returns to pending, nothing is skipped, the plan stays
    /// unfinished in place and is offered to resume at the next launch.
    func stopForQuit() {
        guard state.isActive else { return }
        quitRequested = true
        state = .cancelling
        subtitleText = "Quitting — files already deleted stay deleted; the rest will be offered to resume at the next launch…"
        currentWorker?.cancel()
        task?.cancel()
        wakeIfPaused()
    }

    /// Pause takes effect BETWEEN pairs: the file being read right now is
    /// finished (or refused) first, nothing is half-done.
    func pause() {
        guard state == .running, !isPausedValue else { return }
        isPausedValue = true
        publishProgress()
        model?.log("  Delete Duplicates on \(volumeName): paused — will stop after the current file.")
    }

    func resume() {
        guard isPausedValue else { return }
        isPausedValue = false
        model?.log("  Delete Duplicates on \(volumeName): resumed.")
        publishProgress()
        wakeIfPaused()
    }

    private func wakeIfPaused() {
        pauseWaiter?.resume()
        pauseWaiter = nil
    }

    private var stopRequested: Bool { state.cancelWasRequested || Task.isCancelled }

    /// The quarantine folder for one row: named from the plan and the row
    /// so it is unique per attempt and derivable at resume even when the
    /// crash beat the save that records it.
    nonisolated static func quarantineDirectoryName(planID: UUID, entryID: UUID) -> String {
        SignatureVerification.quarantineDirectoryPrefix + planID.uuidString.prefix(8) + "-" + entryID.uuidString
    }

    // MARK: Run

    private func run() async {
        guard let model else { finish(failed: "The catalog went away before the job started."); return }

        // The verb's own gates, with the verb's own words.
        guard !model.isReadOnly else {
            model.duplicateStatus = "Deletion unavailable in viewer mode"
            model.log("\nREFUSED duplicate deletion on \(volumePath): this Mac is in read-only viewer mode.")
            wasRefused = true
            finish(failed: "This Mac is in read-only viewer mode — nothing can be deleted here.")
            return
        }
        guard !model.isDeletingDuplicates else {
            model.log("\nREFUSED duplicate deletion on \(volumePath): another duplicate deletion is already running.")
            wasRefused = true
            finish(failed: "Another Delete Duplicates run is already going — let it finish or stop it first.")
            return
        }
        model.isDeletingDuplicates = true
        defer { model.isDeletingDuplicates = false }

        var plan: DeleteDuplicatesPlan
        if let resumed = resumingPlan {
            plan = await revalidateForResume(resumed, model: model)
        } else {
            guard let prepared = await model.prepareDuplicateDeletion(onVolume: volumePath) else {
                finish(success: "Nothing to delete")
                return
            }
            plan = prepared
        }
        plan.startedAt = plan.startedAt ?? Date()
        self.plan = plan
        isIndeterminateValue = false
        // The ordered writer remembers the last generation it wrote for
        // this plan id for the life of the process; a same-process resume
        // must continue from there or every save would be dropped as
        // stale (QA MINOR 4).
        saveGeneration = await DeleteDuplicatesPlanWriter.shared.lastGeneration(for: plan.id)

        guard !plan.entries.isEmpty else {
            // The old "(0, 0, skipped, 0)" — nothing to run, nothing to save.
            result = (0, 0, plan.skippedBeforePlan, 0)
            finish(success: "No duplicates to delete on \(volumeName)"
                   + (plan.skippedBeforePlan > 0 ? " — \(plan.skippedBeforePlan) skipped" : ""))
            return
        }
        await savePlan(context: "plan made")
        publishProgress()

        var tally = PairTally()
        var settledSinceCheckpoint = 0
        let batchID = "dupdelete-\(plan.id.uuidString.prefix(8))"

        // EVERY deletion is gated on a full read of the file about to go,
        // performed HERE, immediately before the remove, against the
        // keeper's whole-file digest (stored on first use, checked by
        // stat stamp after that). See SignatureVerification.swift for why.
        for index in plan.entries.indices where !plan.entries[index].status.isSettled {
            await waitWhilePaused()
            if stopRequested || planSaveFailed { break }
            let entry = plan.entries[index]

            // LIVE authorization, this instant — never the plan's or the
            // preflight's answer (#3).
            let record: VideoRecord
            let keeper: VideoRecord
            switch model.authorizeDuplicateDeletion(entry: entry, volumePath: volumePath,
                                                    crossVolumeMode: plan.crossVolumeMode,
                                                    stage: "before deletion") {
            case .authorized(let r, let k):
                record = r; keeper = k
            case .skip(let note, let line):
                plan.set(entry.id, .skipped, note: note)
                model.log("  " + line)
                self.plan = plan
                continue
            case .refuse(let note):
                tally.refused += 1
                let mutated = model.noteRefusedDuplicate(expectedID: entry.id, expectedPath: entry.path,
                                                         filename: entry.filename, reason: note)
                tally.catalogMutated = tally.catalogMutated || mutated
                plan.set(entry.id, .refused, note: note)
                self.plan = plan
                continue
            }

            plan.set(entry.id, .verifying)
            self.plan = plan
            model.duplicateStatus = "Verifying duplicate \(plan.counts.settled + 1) of \(plan.entries.count)…"
            // The pre-await SNAPSHOT of the row (immutable facts for the
            // log and the ledger line): never the live instance (#4).
            let preAwait = record.snapshotClone()
            let item = DeleteDuplicatesWorkItem(
                path: entry.path, keeperPath: keeper.fullPath, keeperFilename: keeper.filename,
                keeperFixity: keeper.contentFixity,
                quarantineDirectoryName: Self.quarantineDirectoryName(planID: plan.id, entryID: entry.id))
            let pairStarted = Date()

            // Phase 1: verify + quarantine.
            var outcome = await runDetached { [hooks] in
                DeleteDuplicatesDiskWorker.verifyAndQuarantine(item, hooks: hooks)
            }
            if case .quarantined(let ticket) = outcome {
                // Record WHERE the file is before it can be removed (#2).
                plan.setQuarantined(entry.id, directory: ticket.quarantineDirectory, stamp: ticket.baseline)
                self.plan = plan
                await savePlan(context: "quarantined \(entry.filename)")
                if planSaveFailed {
                    // Nobody could find it after a crash: put it back and stop.
                    let keeperName = keeper.filename
                    outcome = await runDetached {
                        DeleteDuplicatesDiskWorker.release(ticket, reason: "plan could not be saved after quarantine",
                                                           keeperFilename: keeperName)
                    }
                } else {
                    // Phase 2: re-read, re-check, unlink.
                    let keeperName = keeper.filename
                    outcome = await runDetached { [hooks] in
                        DeleteDuplicatesDiskWorker.deleteQuarantined(ticket, keeperFilename: keeperName, hooks: hooks)
                    }
                }
                plan.clearQuarantine(entry.id)
            }
            let seconds = Date().timeIntervalSince(pairStarted)

            settle(outcome, entry: entry, keeper: keeper, preAwait: preAwait, batchID: batchID,
                   plan: &plan, tally: &tally, model: model)

            rate.add(bytes: entry.sizeBytes, seconds: seconds)
            self.plan = plan
            publishProgress()
            await savePlan(context: "after \(entry.filename)")
            // QA minor 4: checkpoint every N settled pairs so a crash
            // mid-batch loses at most N carry-overs / fixities (the
            // notification drives the debounced save).
            settledSinceCheckpoint += 1
            if tally.catalogMutated, settledSinceCheckpoint >= VideoScanModel.deletionCheckpointEvery {
                settledSinceCheckpoint = 0
                NotificationCenter.default.post(name: .videoScanCatalogMutated, object: nil)
            }
        }

        if tally.catalogMutated {
            NotificationCenter.default.post(name: .videoScanCatalogMutated, object: nil)
        }

        // QUIT: suspend. Nothing is skipped, the plan stays unfinished in
        // place (never under done/), and the next launch offers it (#5).
        if quitRequested {
            let remaining = plan.remainingCount
            plan.log.append("Suspended by quit with \(remaining) remaining — offered to resume at the next launch")
            self.plan = plan
            result = (tally.deleted, tally.failed, plan.skippedBeforePlan, tally.bytesFreed)
            model.log("\nDelete Duplicates on \(volumeName) suspended for quit: \(tally.deleted) deleted, \(remaining) remaining — the run will be offered to resume at the next launch.")
            model.duplicateStatus = "\(tally.deleted) deleted — \(remaining) remaining, resume offered at next launch"
            if !(await savePlan(context: "suspended for quit")) {
                model.log("  The suspended plan could not be saved — the last saved plan stays in place and will be offered instead.")
            }
            finishSuspended(remaining: remaining)
            return
        }

        // Stop / save failure: the rest is counted, not done.
        let stopped = stopRequested || planSaveFailed
        if stopped {
            let reason = planSaveFailed
                ? "stopped — the plan could not be saved, so the rest was left alone"
                : "cancelled before verification"
            let left = plan.skipRemaining(reason: reason)
            tally.failed += left
            if !planSaveFailed {
                model.log("  Duplicate deletion cancelled before verification completed")
            }
        }

        let (deleted, failed, refused, bytesFreed) = (tally.deleted, tally.failed, tally.refused, tally.bytesFreed)
        let freed = ByteCountFormatter.string(fromByteCount: bytesFreed, countStyle: .file)
        let completion = "\(deleted) deleted, \(failed) failed, \(refused) refused by verification, "
            + "\(plan.skippedBeforePlan) skipped, \(freed) freed (\(plan.summaryLine))"
        if plan.crossVolumeMode {
            model.log("\n" + WorkingCopyCleanupText.logSummary(volume: volumeName, detail: "complete — " + completion))
        } else {
            model.log("\nDuplicate deletion complete: " + completion)
        }
        if refused > 0 {
            model.log("  \(refused) file(s) were NOT identical to their keeper despite matching "
                + "on hash/name/duration — they are marked Review and left on disk.")
        }
        model.duplicateStatus = "\(deleted) deleted, \(freed) freed"
        result = (deleted, failed, plan.skippedBeforePlan, bytesFreed)

        plan.finishedAt = Date()
        plan.outcome = planSaveFailed ? "stopped (plan not saved)" : (stopRequested ? "cancelled" : "completed")
        plan.log.append(completion)
        self.plan = plan
        testHookBeforeFinalSave?()
        // The plan is filed under done/ ONLY when its terminal state is on
        // disk (#6). A failed final save leaves the last good plan.json
        // where it is — still discoverable — and says so.
        if await savePlan(context: "finished", final: true) {
            fileDone(plan)
        } else {
            model.log("  Delete Duplicates: the finished plan could not be saved — the last saved plan stays in place under \(DeleteDuplicatesPlanStore.directory(for: plan.id, root: planRoot).path) and is not filed as done.")
        }

        let summary = "\(deleted) deleted · \(freed) freed"
            + (refused > 0 ? " · \(refused) refused" : "")
            + (failed > 0 ? " · \(failed) not done" : "")
        if planSaveFailed {
            finish(failed: "Stopped after \(deleted) deleted — the plan could not be saved (\(summary))")
        } else if state.cancelWasRequested || Task.isCancelled {
            finishCancelled()
        } else {
            finish(success: summary)
        }
    }

    /// The run's counters (the old loop's five locals).
    private struct PairTally {
        var deleted = 0
        var failed = 0
        var refused = 0
        var bytesFreed: Int64 = 0
        var catalogMutated = false
    }

    /// The catalog + plan side of one pair's outcome: counters, the row's
    /// status and note, the keeper's fixity, the ledger line, the log.
    private func settle(_ outcome: DeleteDuplicatesDiskOutcome, entry: DeleteDuplicatesPlan.Entry,
                        keeper: VideoRecord, preAwait: VideoRecord, batchID: String,
                        plan: inout DeleteDuplicatesPlan, tally: inout PairTally, model: VideoScanModel) {
        switch outcome {
        case .quarantined:
            // Unreachable — phase 2 always settles a ticket.
            tally.failed += 1
            plan.set(entry.id, .failed, note: "left in quarantine (internal: phase 2 did not run)")
        case .refused(let reason, let cancelled):
            if cancelled && quitRequested {
                // Suspended, not decided: back to pending for the resume.
                plan.set(entry.id, .pending, note: "interrupted by quit — will be re-checked at resume")
                model.log("  Quit while verifying \(entry.filename) — left alone; it will be offered to resume at the next launch")
            } else if cancelled && planSaveFailed {
                tally.failed += 1
                plan.set(entry.id, .skipped, note: "the plan could not be saved after quarantine — put back and left alone")
                model.log("  Put back \(entry.filename): the plan could not be saved after quarantine — left alone")
            } else if cancelled {
                // Not done, not refused: the file is untouched and
                // keeps its disposition; it counts with the rest.
                tally.failed += 1
                plan.set(entry.id, .skipped, note: "cancelled during verification — left alone")
                model.log("  Stopped while verifying \(entry.filename) — left alone")
            } else {
                tally.refused += 1
                let mutated = model.noteRefusedDuplicate(expectedID: entry.id, expectedPath: entry.path,
                                                         filename: entry.filename, reason: reason)
                tally.catalogMutated = tally.catalogMutated || mutated
                plan.set(entry.id, .refused, note: reason)
            }
        case .failed(let reason):
            tally.failed += 1
            model.log("  FAILED to delete \(entry.filename): \(reason)")
            plan.set(entry.id, .failed, note: reason)
        case .retained(let path, let reason):
            tally.failed += 1
            model.log("  RETAINED safely at \(path): \(reason)")
            plan.set(entry.id, .failed, note: "retained safely at \(path): \(reason)")
        case .deleted(let bytes, let proof):
            tally.bytesFreed += bytes
            tally.deleted += 1
            // The keeper was read in full for this pair: keep its
            // fixity so the next pair with this keeper only stats it.
            if proof.keeperReadInFull {
                model.storeContentFixity(recordID: keeper.id, path: keeper.fullPath,
                                         fixity: proof.keeperFixity)
                tally.catalogMutated = true
            }
            let mutated = model.settleDeletedDuplicate(
                expectedID: entry.id, expectedPath: entry.path, preAwait: preAwait,
                keeperID: keeper.id, keeperPath: keeper.fullPath, keeperFilename: keeper.filename,
                isWorkingCopy: entry.isWorkingCopy, batchID: batchID,
                keeperMatchedByStoredFixity: !proof.keeperReadInFull)
            tally.catalogMutated = tally.catalogMutated || mutated
            plan.set(entry.id, .deleted, note: "verified identical to \(keeper.filename)",
                     keeperMatchedByStoredFixity: !proof.keeperReadInFull)
        }
    }

    /// One detached disk phase, tracked as `currentWorker` so Stop / Quit
    /// can cancel it.
    private func runDetached(_ work: @escaping @Sendable () -> DeleteDuplicatesDiskOutcome) async -> DeleteDuplicatesDiskOutcome {
        let worker = Task.detached(priority: .userInitiated) { work() }
        currentWorker = worker
        let outcome = await worker.value
        currentWorker = nil
        return outcome
    }

    // MARK: Resume re-validation

    /// Every remaining row must still be what the plan says: the record is
    /// active at the same path, still an extra copy in the same group with
    /// the same keeper, the keeper reachable and unchanged since the plan
    /// (stat stamp), and not a Master Archive file. Anything else is
    /// refused (or skipped when the record is gone) and named. The safety
    /// snapshot is retaken when the catalog was saved after it.
    ///
    /// A row the crash left IN QUARANTINE (status `.verified`, the plan
    /// names the folder) is put back first — from THAT folder only, only
    /// if the file there still reproduces the recorded stamp, and the
    /// folder is removed only if empty — then re-verified like any other.
    func revalidateForResume(_ input: DeleteDuplicatesPlan, model: VideoScanModel) async -> DeleteDuplicatesPlan {
        var plan = input
        plan.resumeCount += 1
        model.log("\nResuming Delete Duplicates on \(plan.volumeName): \(plan.remainingCount) of \(plan.entries.count) remaining — re-checking every one against the catalog first…")
        let now = Date()
        var refusedNow = 0
        var skippedNow = 0
        // Every stat and directory listing in ONE detached pass (QA MINOR
        // 5): keeper stamps, which targets are gone, and the quarantine
        // folder the plan names for each of those (QA MINOR 6, #2).
        let unsettled = plan.entries.filter { !$0.status.isSettled }
        let facts = await Self.resumeDiskFacts(planID: plan.id, entries: unsettled)
        for i in plan.entries.indices where !plan.entries[i].status.isSettled {
            let e = plan.entries[i]
            func skip(_ why: String, log line: String) {
                plan.entries[i].status = .skipped
                plan.entries[i].note = why
                plan.entries[i].settledAt = now
                skippedNow += 1
                model.log("  " + line)
            }
            func refuse(_ why: String) {
                plan.entries[i].status = .refused
                plan.entries[i].note = why
                plan.entries[i].settledAt = now
                refusedNow += 1
                model.noteRefusedDuplicate(expectedID: e.id, expectedPath: e.path, filename: e.filename, reason: why)
            }
            switch model.authorizeDuplicateDeletion(entry: e, volumePath: plan.volumePath,
                                                    crossVolumeMode: plan.crossVolumeMode, stage: "at resume") {
            case .skip(let note, let line):
                skip(note, log: line); continue
            case .refuse(let note):
                refuse(note); continue
            case .authorized:
                break
            }
            // A crash between the quarantine move and the unlink leaves the
            // file in the folder the plan names (or the folder this plan +
            // row would have used): put it back and let this run verify it
            // properly. That folder is consulted FIRST — whatever now sits
            // at the original path is not the file that was verified, and
            // an occupied path refuses the restore rather than re-verifying
            // the newcomer. No named folder and the file gone → it left
            // before the crash; a decision, not a refusal, so the row is
            // not re-marked. A same-named file in some OTHER quarantine
            // folder is only reported — never moved, never removed.
            if let orphan = facts.quarantined[e.path] {
                switch Self.restoreQuarantined(orphan.url, to: e.path, expectedStamp: orphan.recordedStamp,
                                               expectedSize: e.sizeBytes) {
                case .success(let directoryRemoved):
                    let folder = orphan.url.deletingLastPathComponent().lastPathComponent
                    model.log("  Restored \(e.filename) from \(folder) (a crash left it in quarantine) — it will be verified again before anything is removed"
                              + (directoryRemoved ? "" : "; the quarantine folder was not empty and was left in place"))
                    plan.log.append("Restored \(e.filename) from quarantine at resume")
                    plan.entries[i].quarantineDirectory = nil
                    plan.entries[i].quarantinedStamp = nil
                    plan.entries[i].status = .pending
                case .failure(let error):
                    refuse("left in quarantine at \(orphan.url.path) — not put back: \(error.description)")
                    continue
                }
            } else if facts.missingTargets.contains(e.path) {
                if let elsewhere = facts.possibleOrphans[e.path], !elsewhere.isEmpty {
                    model.log("  \(e.filename) is gone from \(e.path); a same-named file sits in \(elsewhere.joined(separator: ", ")) — not this run's quarantine, left alone (put it back by hand if it is yours)")
                }
                skip("gone before the crash — nothing on disk at this path",
                     log: "Skipped \(e.filename): gone before the crash — nothing on disk at \(e.path)")
                continue
            } else if e.status == .verified {
                // The plan said "in quarantine" but nothing is in the
                // folder and the file is at its path: the crash landed
                // after a restore. Re-verify.
                plan.entries[i].quarantineDirectory = nil
                plan.entries[i].quarantinedStamp = nil
                plan.entries[i].status = .pending
            }
            guard let stamp = facts.keeperStamps[e.keeperPath] else {
                refuse("keeper \(e.keeperFilename) is not reachable — refused at resume"); continue
            }
            if let planned = e.keeperStamp, planned != stamp {
                refuse("keeper \(e.keeperFilename) changed since the plan was made — refused at resume"); continue
            }
        }
        if refusedNow > 0 || skippedNow > 0 {
            plan.log.append("Resume re-check: \(refusedNow) refused, \(skippedNow) skipped")
            model.log("  Resume re-check: \(refusedNow) refused, \(skippedNow) skipped — the rest still match the plan.")
        }
        // The safety snapshot must be at least as new as the catalog it
        // protects. Retake it when the catalog was saved since; if that
        // fails, the working-copy rows are refused (fail safe, as at the
        // first run).
        if plan.crossVolumeMode, plan.snapshotPath != nil,
           Self.snapshotIsStale(snapshotPath: plan.snapshotPath, takenAt: plan.snapshotTakenAt,
                                catalogLocation: model.catalogStore.fileLocation) {
            model.duplicateStatus = "Writing safety snapshot…"
            if let snap = await model.snapshotCatalogAsync(prefix: "pre-dup-crossvolume") {
                plan.snapshotPath = snap
                plan.snapshotTakenAt = Date()
                plan.log.append("Safety snapshot retaken at resume: \(snap)")
                model.log("\nPre-delete safety snapshot retaken (catalog saved since the plan): \(snap)")
            } else {
                var dropped = 0
                for i in plan.entries.indices where !plan.entries[i].status.isSettled && plan.entries[i].isWorkingCopy {
                    plan.entries[i].status = .refused
                    plan.entries[i].note = "safety snapshot could not be retaken — working copy left alone"
                    plan.entries[i].settledAt = Date()
                    dropped += 1
                }
                model.log("\n⚠️ Could not retake the pre-delete safety snapshot — leaving \(dropped) working cop\(dropped == 1 ? "y" : "ies") alone; only same-drive extras will be removed.")
            }
        }
        return plan
    }

    /// What the resume re-check needs from disk, gathered off the main
    /// actor in one pass: a stamp per reachable keeper, the targets that
    /// are no longer at their path, and — for those — the file in the
    /// quarantine folder the plan names (or, when the crash beat the save
    /// that names it, the folder this plan + row would have used). Any
    /// OTHER sibling quarantine holding the same basename is listed under
    /// `possibleOrphans` for the log only.
    struct ResumeDiskFacts: Sendable {
        struct Quarantined: Sendable {
            let url: URL
            /// The stamp the plan recorded, when it got to record one.
            let recordedStamp: FileIdentityStamp?
        }
        var keeperStamps: [String: FileIdentityStamp] = [:]
        var missingTargets: Set<String> = []
        var quarantined: [String: Quarantined] = [:]
        var possibleOrphans: [String: [String]] = [:]
    }

    static let quarantinePrefix = SignatureVerification.quarantineDirectoryPrefix

    nonisolated static func resumeDiskFacts(planID: UUID, entries: [DeleteDuplicatesPlan.Entry]) async -> ResumeDiskFacts {
        let rows = entries.map { (path: $0.path, keeperPath: $0.keeperPath, entryID: $0.id,
                                  recorded: $0.quarantineDirectory, stamp: $0.quarantinedStamp) }
        return await Task.detached(priority: .userInitiated) {
            var facts = ResumeDiskFacts()
            let fm = FileManager.default
            for path in Set(rows.map(\.keeperPath)) where !path.isEmpty {
                if let stamp = FileIdentityStamp.capture(path: path) { facts.keeperStamps[path] = stamp }
            }
            var listed: [String: [String]] = [:]   // parent dir → quarantine folder names
            for row in rows {
                let parent = (row.path as NSString).deletingLastPathComponent
                let name = (row.path as NSString).lastPathComponent
                // The quarantine folders that are THIS row's, checked
                // whether or not the original path is occupied:
                // 1. the folder the plan recorded;
                // 2. the folder this plan + row would have used (the crash
                //    beat the save that records it).
                var candidates: [(dir: String, stamp: FileIdentityStamp?)] = []
                if let recorded = row.recorded { candidates.append((recorded, row.stamp)) }
                let derived = (parent as NSString).appendingPathComponent(
                    quarantineDirectoryName(planID: planID, entryID: row.entryID))
                if derived != row.recorded { candidates.append((derived, nil)) }
                var found = false
                for candidate in candidates {
                    let url = URL(fileURLWithPath: candidate.dir, isDirectory: true).appendingPathComponent(name)
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                        facts.quarantined[row.path] = ResumeDiskFacts.Quarantined(url: url, recordedStamp: candidate.stamp)
                        found = true
                        break
                    }
                }
                if found { continue }
                guard !fm.fileExists(atPath: row.path) else { continue }
                facts.missingTargets.insert(row.path)
                // Report-only: same basename in any other sibling quarantine.
                let folders = listed[parent] ?? {
                    let names = ((try? fm.contentsOfDirectory(atPath: parent)) ?? [])
                        .filter { $0.hasPrefix(quarantinePrefix) }
                    listed[parent] = names
                    return names
                }()
                let ours = Set(candidates.map { ($0.dir as NSString).lastPathComponent })
                let others = folders.filter { !ours.contains($0) }.filter { folder in
                    fm.fileExists(atPath: (parent as NSString).appendingPathComponent(folder + "/" + name))
                }
                if !others.isEmpty { facts.possibleOrphans[row.path] = others }
            }
            return facts
        }.value
    }

    enum RestoreError: Error, Equatable, CustomStringConvertible {
        case originalPathOccupied
        case notTheQuarantinedFile(String)
        case moveFailed(String)

        var description: String {
            switch self {
            case .originalPathOccupied: return "the original path is occupied"
            case .notTheQuarantinedFile(let why): return "the file in quarantine is not the one this run put there (\(why))"
            case .moveFailed(let why): return "could not move it back: \(why)"
            }
        }
    }

    /// True when the file in quarantine is the one the plan recorded:
    /// inode, size, mtime and kernel ctime all reproduce. The device
    /// number is NOT compared — an external drive remounted after a
    /// reboot can come back under another one; APFS inode numbers do not
    /// change.
    nonisolated static func quarantineIdentityMatches(recorded: FileIdentityStamp, current: FileIdentityStamp) -> Bool {
        recorded.inode == current.inode && recorded.size == current.size
            && recorded.mtimeNs == current.mtimeNs && recorded.ctimeNs == current.ctimeNs
    }

    /// Move an orphaned quarantined file back to its original path. Only
    /// the file the plan put there: with a recorded stamp it must
    /// reproduce (`quarantineIdentityMatches`); without one (the crash
    /// beat the save) the size must be the plan's. Never overwrites: an
    /// occupied original path is an error. The quarantine folder is then
    /// removed ONLY if empty (`rmdir`) — anything else in it is not ours;
    /// the Bool says whether it went.
    nonisolated static func restoreQuarantined(_ quarantined: URL, to originalPath: String,
                                               expectedStamp: FileIdentityStamp?,
                                               expectedSize: Int64) -> Result<Bool, RestoreError> {
        let fm = FileManager.default
        guard let current = FileIdentityStamp.capture(path: quarantined.path) else {
            return .failure(.notTheQuarantinedFile("cannot stat it"))
        }
        if let expectedStamp {
            guard quarantineIdentityMatches(recorded: expectedStamp, current: current) else {
                return .failure(.notTheQuarantinedFile("identity differs from the recorded stamp"))
            }
        } else {
            guard current.size == expectedSize else {
                return .failure(.notTheQuarantinedFile("size \(current.size) ≠ planned \(expectedSize)"))
            }
        }
        guard !fm.fileExists(atPath: originalPath) else {
            return .failure(.originalPathOccupied)
        }
        do {
            try fm.moveItem(at: quarantined, to: URL(fileURLWithPath: originalPath))
        } catch {
            return .failure(.moveFailed(error.localizedDescription))
        }
        let directory = quarantined.deletingLastPathComponent()
        let removed = (try? SignatureVerification.removeEmptyDirectory(directory)) != nil
        return .success(removed)
    }

    /// True when the snapshot is missing or older than the catalog file's
    /// last modification. Pure over paths + dates; nil snapshot = stale.
    nonisolated static func snapshotIsStale(snapshotPath: String?, takenAt: Date?,
                                            catalogLocation: String,
                                            fileManager fm: FileManager = .default) -> Bool {
        guard let snapshotPath, fm.fileExists(atPath: snapshotPath) else { return true }
        let catalogModified = (try? fm.attributesOfItem(atPath: catalogLocation))?[.modificationDate] as? Date
        let snapshotModified = (try? fm.attributesOfItem(atPath: snapshotPath))?[.modificationDate] as? Date
        guard let catalogModified else { return false }   // no catalog file yet: nothing newer to protect
        let snapshotAt = snapshotModified ?? takenAt ?? .distantPast
        return catalogModified > snapshotAt
    }

    // MARK: Pause plumbing

    private func waitWhilePaused() async {
        while isPausedValue && !stopRequested {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                pauseWaiter = c
            }
        }
    }

    // MARK: Progress / plan persistence

    private func publishProgress() {
        guard let plan else { return }
        let counts = plan.counts
        fractionValue = counts.fraction
        subtitleText = DeleteDuplicatesRate.subtitle(counts: counts, rate: rate, paused: isPausedValue)
    }

    private func nextSaveGeneration() -> UInt64 { saveGeneration += 1; return saveGeneration }

    /// Save through the ordered writer. A failure is logged and, unless
    /// this is the final save, stops the run after the current pair.
    /// Returns whether the plan reached disk.
    @discardableResult
    private func savePlan(context: String, final: Bool = false) async -> Bool {
        guard let plan else { return false }
        let generation = nextSaveGeneration()
        let root = planRoot
        do {
            try await DeleteDuplicatesPlanWriter.shared.write(plan, root: root, generation: generation)
            return true
        } catch {
            model?.log("  Delete Duplicates: could not save the plan (\(context)) — \(error.localizedDescription)")
            deleteDupLog.error("plan save failed (\(context, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            if !final { planSaveFailed = true }
            return false
        }
    }

    /// A finished plan moves to done/ (kept for the log, never deleted).
    private func fileDone(_ plan: DeleteDuplicatesPlan) {
        do {
            try DeleteDuplicatesPlanStore.moveToDone(plan, root: planRoot)
        } catch {
            model?.log("  Delete Duplicates: could not file the finished plan under done/ — \(error.localizedDescription)")
        }
    }

    // MARK: Terminal transitions

    private func finish(success summary: String) {
        guard state.isActive else { return }
        state = .finished(summary: summary)
        subtitleText = summary
        fractionValue = 1
        isIndeterminateValue = false
        isPausedValue = false
    }

    private func finish(failed message: String) {
        guard state.isActive else { return }
        if state.cancelWasRequested { finishCancelled(); return }
        state = .failed(message: message)
        subtitleText = message
        isIndeterminateValue = false
        isPausedValue = false
    }

    private func finishCancelled() {
        guard state.isActive else { return }
        state = .cancelled
        subtitleText = "Stopped — \(result.deleted) deleted, the rest left alone"
        isIndeterminateValue = false
        isPausedValue = false
    }

    private func finishSuspended(remaining: Int) {
        guard state.isActive else { return }
        state = .cancelled
        subtitleText = "Suspended for quit — \(result.deleted) deleted; \(remaining) remaining will be offered to resume at the next launch"
        isIndeterminateValue = false
        isPausedValue = false
    }
}

// MARK: - Center hook

extension MediaFileOperationsCenter {

    /// Start Delete Duplicates on one volume as an MFO job (the confirm
    /// alert's button). One run at a time; a second request is parked as
    /// refused with the reason.
    @discardableResult
    func startDeleteDuplicates(onVolume volumePath: String, model: VideoScanModel,
                               planRoot: URL = DeleteDuplicatesPlanStore.defaultRoot) -> DeleteDuplicatesJob {
        launchDeleteDuplicates(DeleteDuplicatesJob(model: model, volumePath: volumePath, planRoot: planRoot),
                               model: model, plan: "verify each copy against its keeper, then remove it")
    }

    /// Resume the plan the launch check found (the Resume button). The job
    /// re-validates every remaining row before reading a byte. `planRoot`
    /// must be the root the plan was found under (the default in the app;
    /// tests pass their scratch root).
    @discardableResult
    func resumeDeleteDuplicates(plan: DeleteDuplicatesPlan, model: VideoScanModel,
                                planRoot: URL = DeleteDuplicatesPlanStore.defaultRoot) -> DeleteDuplicatesJob {
        model.pendingDeleteDuplicatesResume = nil
        return launchDeleteDuplicates(DeleteDuplicatesJob(model: model, resuming: plan, planRoot: planRoot),
                                      model: model,
                                      plan: "resume — \(plan.remainingCount) of \(plan.entries.count) remaining, re-checked first")
    }

    /// True while a Delete Duplicates run is live — the quit dialog says
    /// what a quit does to it.
    var hasActiveDeleteDuplicates: Bool {
        jobs.contains { $0.state.isActive && $0 is DeleteDuplicatesJob }
    }

    /// The quit dialog's body. A live Delete Duplicates run is suspended,
    /// not abandoned — and the dialog says so (#5).
    static func quitInformativeText(running: Int, deleteDuplicatesActive: Bool) -> String {
        var text = "Quitting now will stop the work in progress. Anything already finished is safe."
        if deleteDuplicatesActive {
            text += "\n\nDelete Duplicates: files already deleted stay deleted; the file being checked is left alone, and the rest of the run is kept and offered to resume at the next launch."
        }
        return text
    }

    private func launchDeleteDuplicates(_ job: DeleteDuplicatesJob, model: VideoScanModel, plan: String) -> DeleteDuplicatesJob {
        guard add(job) else { return job }
        let duplicate = jobs.contains { other in
            other.id != job.id && other.state.isActive && other is DeleteDuplicatesJob
        }
        if duplicate || model.isDeletingDuplicates {
            job.refuseToStart(reason: "A Delete Duplicates run is already going — let it finish or stop it first. Nothing was started.")
            return job
        }
        job.start()
        appLog.write(Self.startSummaryLine(verb: job.kind.logVerb, title: job.title, plan: plan))
        return job
    }
}
