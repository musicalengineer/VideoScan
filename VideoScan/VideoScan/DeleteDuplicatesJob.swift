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
//   • the file being DELETED is always read in full, now;
//   • the KEEPER is read at most once ever — the first pair reads it and
//     stores a whole-file fixity (digest + stat stamp) on its record; every
//     later pair stats the keeper and, if the stamp reproduces, compares
//     the duplicate's fresh digest against the stored one
//     (`SignatureVerification.verifyAgainstStoredKeeper`);
//   • there is NO both-sides-stored, nothing-read path — `contentHash` and
//     `partialMD5` never authorise a delete (design #320).
//
// One pair at a time, verified and unlinked in a detached task; the main
// actor settles the catalog between pairs (carry-over, row removal, ledger,
// log), updates the row and saves the plan. Pause waits between pairs.
// Stop leaves what is done done and the rest counted, not done.
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
}

enum DeleteDuplicatesDiskOutcome: Sendable {
    case deleted(bytes: Int64, proof: VerifiedDuplicate)
    case refused(reason: String, cancelled: Bool)
    case failed(reason: String)
    case retained(path: String, reason: String)
}

enum DeleteDuplicatesDiskWorker {
    /// Verification and removal, outside the main actor. Carries only
    /// immutable value snapshots — never VideoRecord instances.
    static func run(_ item: DeleteDuplicatesWorkItem,
                    hooks: SignatureVerification.Hooks) -> DeleteDuplicatesDiskOutcome {
        switch SignatureVerification.verifyAgainstStoredKeeper(keeperPath: item.keeperPath,
                                                               keeperFixity: item.keeperFixity,
                                                               duplicatePath: item.path,
                                                               hooks: hooks) {
        case .failure(let failure):
            return .refused(reason: duplicateRefusalNote(failure, keeper: item.keeperFilename),
                            cancelled: failure == .cancelled)
        case .success(let proof):
            switch SignatureVerification.quarantineAndDelete(proof, hooks: hooks) {
            case .deleted(let bytes): return .deleted(bytes: bytes, proof: proof)
            case .refused(let failure):
                return .refused(reason: duplicateRefusalNote(failure, keeper: item.keeperFilename),
                                cancelled: failure == .cancelled)
            case .failed(let reason): return .failed(reason: reason)
            case .retainedQuarantine(let path, let reason):
                return .retained(path: path, reason: reason)
            }
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

        var deleted = 0
        var failed = 0
        var refused = 0
        var bytesFreed: Int64 = 0
        var catalogMutated = false
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

            guard let keeper = model.record(forID: entry.keeperID), !entry.keeperPath.isEmpty else {
                refused += 1
                model.log("  REFUSED \(entry.filename): no keeper to verify against")
                plan.set(entry.id, .refused, note: "no keeper to verify against")
                self.plan = plan
                continue
            }
            // The pre-await snapshot of the row (the old loop's `record`):
            // used for the log and, if the row is replaced during the disk
            // work, for the ledger line.
            guard let record = model.record(forID: entry.id), record.fullPath == entry.path else {
                plan.set(entry.id, .skipped, note: "record no longer in the catalog at this path")
                model.log("  Skipped \(entry.filename): its catalog row is gone or moved")
                self.plan = plan
                continue
            }

            plan.set(entry.id, .verifying)
            self.plan = plan
            model.duplicateStatus = "Verifying duplicate \(plan.counts.settled + 1) of \(plan.entries.count)…"
            let item = DeleteDuplicatesWorkItem(path: entry.path, keeperPath: keeper.fullPath,
                                                keeperFilename: keeper.filename,
                                                keeperFixity: keeper.contentFixity)
            let pairStarted = Date()
            let worker = Task.detached(priority: .userInitiated) { [hooks] in
                DeleteDuplicatesDiskWorker.run(item, hooks: hooks)
            }
            currentWorker = worker
            let outcome = await worker.value
            currentWorker = nil
            let seconds = Date().timeIntervalSince(pairStarted)

            switch outcome {
            case .refused(let reason, let cancelled):
                if cancelled {
                    // Not done, not refused: the file is untouched and
                    // keeps its disposition; it counts with the rest.
                    failed += 1
                    plan.set(entry.id, .skipped, note: "cancelled during verification — left alone")
                    model.log("  Stopped while verifying \(entry.filename) — left alone")
                } else {
                    refused += 1
                    let mutated = model.noteRefusedDuplicate(expectedID: entry.id, expectedPath: entry.path,
                                                             filename: entry.filename, reason: reason)
                    catalogMutated = catalogMutated || mutated
                    plan.set(entry.id, .refused, note: reason)
                }
            case .failed(let reason):
                failed += 1
                model.log("  FAILED to delete \(entry.filename): \(reason)")
                plan.set(entry.id, .failed, note: reason)
            case .retained(let path, let reason):
                failed += 1
                model.log("  RETAINED safely at \(path): \(reason)")
                plan.set(entry.id, .failed, note: "retained safely at \(path): \(reason)")
            case .deleted(let bytes, let proof):
                bytesFreed += bytes
                deleted += 1
                // The keeper was read in full for this pair: keep its
                // fixity so the next pair with this keeper only stats it.
                if proof.keeperReadInFull {
                    model.storeContentFixity(recordID: keeper.id, path: keeper.fullPath,
                                             fixity: proof.keeperFixity)
                    catalogMutated = true
                }
                let mutated = model.settleDeletedDuplicate(
                    expectedID: entry.id, expectedPath: entry.path, preAwait: record,
                    keeperID: keeper.id, keeperPath: keeper.fullPath, keeperFilename: keeper.filename,
                    isWorkingCopy: entry.isWorkingCopy, batchID: batchID,
                    keeperMatchedByStoredFixity: !proof.keeperReadInFull)
                catalogMutated = catalogMutated || mutated
                plan.set(entry.id, .deleted, note: "verified identical to \(keeper.filename)",
                         keeperMatchedByStoredFixity: !proof.keeperReadInFull)
            }

            rate.add(bytes: entry.sizeBytes, seconds: seconds)
            self.plan = plan
            publishProgress()
            await savePlan(context: "after \(entry.filename)")
            // QA minor 4: checkpoint every N settled pairs so a crash
            // mid-batch loses at most N carry-overs / fixities (the
            // notification drives the debounced save).
            settledSinceCheckpoint += 1
            if catalogMutated, settledSinceCheckpoint >= VideoScanModel.deletionCheckpointEvery {
                settledSinceCheckpoint = 0
                NotificationCenter.default.post(name: .videoScanCatalogMutated, object: nil)
            }
        }

        // Stop / save failure: the rest is counted, not done.
        let stopped = stopRequested || planSaveFailed
        if stopped {
            let reason = planSaveFailed
                ? "stopped — the plan could not be saved, so the rest was left alone"
                : "cancelled before verification"
            let left = plan.skipRemaining(reason: reason)
            failed += left
            if !planSaveFailed {
                model.log("  Duplicate deletion cancelled before verification completed")
            }
        }

        if catalogMutated {
            NotificationCenter.default.post(name: .videoScanCatalogMutated, object: nil)
        }

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
        await savePlan(context: "finished", final: true)
        fileDone(plan)

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

    // MARK: Resume re-validation

    /// Every remaining row must still be what the plan says: the record is
    /// active at the same path, still an extra copy in the same group with
    /// the same keeper, the keeper reachable and unchanged since the plan
    /// (stat stamp), and not a Master Archive file. Anything else is
    /// refused (or skipped when the record is gone) and named. The safety
    /// snapshot is retaken when the catalog was saved after it.
    func revalidateForResume(_ input: DeleteDuplicatesPlan, model: VideoScanModel) async -> DeleteDuplicatesPlan {
        var plan = input
        plan.resumeCount += 1
        model.log("\nResuming Delete Duplicates on \(plan.volumeName): \(plan.remainingCount) of \(plan.entries.count) remaining — re-checking every one against the catalog first…")
        let now = Date()
        var refusedNow = 0
        var skippedNow = 0
        // Every stat and directory listing in ONE detached pass (QA MINOR
        // 5): keeper stamps, which targets are gone, and any quarantine
        // folder a crash left beside a target (QA MINOR 6).
        let unsettled = plan.entries.filter { !$0.status.isSettled }
        let facts = await Self.resumeDiskFacts(targetPaths: unsettled.map(\.path),
                                               keeperPaths: unsettled.map(\.keeperPath))
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
            guard let rec = model.record(forID: e.id), !rec.isPurged, rec.fullPath == e.path else {
                skip("record is no longer in the catalog at this path — skipped at resume",
                     log: "Skipped \(e.filename): no longer in the catalog at \(e.path)")
                continue
            }
            // The file itself is gone. A crash between the quarantine move
            // and the unlink leaves it in a sibling
            // `.videoscan-quarantine-<uuid>/`: put it back and let this
            // run verify it properly. No quarantine → it left before the
            // crash; a decision, not a refusal, so the row is not re-marked.
            if facts.missingTargets.contains(e.path) {
                if let orphan = facts.quarantined[e.path] {
                    switch Self.restoreQuarantined(orphan, to: e.path) {
                    case .success:
                        model.log("  Restored \(e.filename) from \(orphan.deletingLastPathComponent().lastPathComponent) (a crash left it in quarantine) — it will be verified again before anything is removed")
                        plan.log.append("Restored \(e.filename) from quarantine at resume")
                    case .failure(let error):
                        refuse("left in quarantine at \(orphan.path) — could not put it back: \(error.localizedDescription)")
                        continue
                    }
                } else {
                    skip("gone before the crash — nothing on disk at this path",
                         log: "Skipped \(e.filename): gone before the crash — nothing on disk at \(e.path)")
                    continue
                }
            }
            guard rec.duplicateDisposition == .extraCopy, let group = rec.duplicateGroupID else {
                refuse("no longer marked as an extra copy — refused at resume"); continue
            }
            guard let keeper = model.record(forID: e.keeperID), !keeper.isPurged,
                  keeper.duplicateDisposition == .keep, keeper.duplicateGroupID == group,
                  keeper.fullPath == e.keeperPath else {
                refuse("keeper \(e.keeperFilename) is no longer this file's keeper — refused at resume"); continue
            }
            guard model.excludingMasterArchiveFiles([rec], verb: "Delete Duplicates").count == 1 else {
                refuse("now lives in the Master Archive — refused at resume"); continue
            }
            guard let stamp = facts.keeperStamps[keeper.fullPath] else {
                refuse("keeper \(keeper.filename) is not reachable — refused at resume"); continue
            }
            if let planned = e.keeperStamp, planned != stamp {
                refuse("keeper \(keeper.filename) changed since the plan was made — refused at resume"); continue
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
    /// are no longer at their path, and — for those — a same-named file
    /// in a sibling `.videoscan-quarantine-*` folder (the crash window
    /// between quarantine move and unlink).
    struct ResumeDiskFacts: Sendable {
        var keeperStamps: [String: FileIdentityStamp] = [:]
        var missingTargets: Set<String> = []
        var quarantined: [String: URL] = [:]
    }

    static let quarantinePrefix = ".videoscan-quarantine-"

    nonisolated static func resumeDiskFacts(targetPaths: [String], keeperPaths: [String]) async -> ResumeDiskFacts {
        await Task.detached(priority: .userInitiated) {
            var facts = ResumeDiskFacts()
            let fm = FileManager.default
            for path in Set(keeperPaths) where !path.isEmpty {
                if let stamp = FileIdentityStamp.capture(path: path) { facts.keeperStamps[path] = stamp }
            }
            var listed: [String: [String]] = [:]   // parent dir → quarantine folder names
            for path in targetPaths where !fm.fileExists(atPath: path) {
                facts.missingTargets.insert(path)
                let parent = (path as NSString).deletingLastPathComponent
                let name = (path as NSString).lastPathComponent
                let folders = listed[parent] ?? {
                    let names = ((try? fm.contentsOfDirectory(atPath: parent)) ?? [])
                        .filter { $0.hasPrefix(quarantinePrefix) }
                    listed[parent] = names
                    return names
                }()
                for folder in folders {
                    let candidate = URL(fileURLWithPath: parent).appendingPathComponent(folder, isDirectory: true)
                        .appendingPathComponent(name)
                    if fm.fileExists(atPath: candidate.path) { facts.quarantined[path] = candidate; break }
                }
            }
            return facts
        }.value
    }

    /// Move an orphaned quarantined file back to its original path and
    /// drop the (then empty) quarantine folder. Never overwrites: an
    /// occupied original path is an error.
    nonisolated static func restoreQuarantined(_ quarantined: URL, to originalPath: String) -> Result<Void, Error> {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: originalPath) else {
            return .failure(CocoaError(.fileWriteFileExists))
        }
        do {
            try fm.moveItem(at: quarantined, to: URL(fileURLWithPath: originalPath))
            try? fm.removeItem(at: quarantined.deletingLastPathComponent())
            return .success(())
        } catch {
            return .failure(error)
        }
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
    private func savePlan(context: String, final: Bool = false) async {
        guard let plan else { return }
        let generation = nextSaveGeneration()
        let root = planRoot
        do {
            try await DeleteDuplicatesPlanWriter.shared.write(plan, root: root, generation: generation)
        } catch {
            model?.log("  Delete Duplicates: could not save the plan (\(context)) — \(error.localizedDescription)")
            deleteDupLog.error("plan save failed (\(context, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            if !final { planSaveFailed = true }
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
