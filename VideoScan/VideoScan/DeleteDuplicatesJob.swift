// DeleteDuplicatesJob.swift
// Delete Duplicates as a Media File Operation (Rick 2026-09-20).
//
// What Rick saw: "Delete 2,992 files from SanDisk" showed only
// "Verifying 1 of 2,992" and read BOTH files of every pair in full —
// hours, nothing to look at. What he asked for: (1) use the precomputed
// hash ids; (2) if bytes must be compared, read only the file being
// deleted; (3) a DELETE row in the MFO window with "2 of N", "3 deleted",
// and a click that lists the files. Earlier the same day: quit + resume,
// pause, a time estimate. That evening: "implement the single-read
// design, SSD parallelism and the copy-count tiering" — and, from his
// test drive, a Pause that lets him quit cleanly.
//
// The decision (feedback_delete_safety_principle, unchanged): prove the
// surviving copy at the moment of deletion; refuse over guess; log and
// ledger every file; never auto-delete. So:
//   • the file being DELETED is always read in full, now — ONCE, in its
//     quarantine folder, after it was moved there and its full identity
//     (ctime included) baselined (SignatureVerification path 3). The
//     two-read shape (verify in place, re-read in quarantine) remains only
//     for the first pair of a keeper that has no usable stored fixity;
//   • the KEEPER is read at most once ever — the first pair reads it and
//     stores a whole-file fixity (digest + stat stamp) on its record; every
//     later pair stats the keeper and, if the stamp reproduces, compares
//     the duplicate's fresh digest against the stored one;
//   • there is NO both-sides-stored, nothing-read path — `contentHash` and
//     `partialMD5` never authorise a delete (design #320);
//   • COPY-COUNT TIER, decided per pair from the fresh catalog on the
//     COUNT alone (the archive is not required — Rick, late 2026-09-20):
//     with three or more verified copies remaining (the keeper just
//     verified, archive copies online with this digest, siblings whose
//     stored fixity reproduces) the file is unlinked; with exactly two it
//     goes to the drive's Trash; with fewer it is put back untouched.
//     "Prefer the Trash for every duplicate" forces the Trash.
//
// ONE PAIR, TWO DISK PHASES. Phase 1 (detached): hold — move the file
// into an owner-only quarantine folder named from this plan + row, hash
// it there once, compare with the keeper's stored digest, stat the
// family's other copies for the tier. Back on the main actor the plan
// RECORDS that folder, the file's stamp there and the tier, and is saved
// — so a crash between the move and the unlink leaves a plan that names
// exactly where the file is (codex 1593 blocker 2). Phase 2 (detached):
// re-read the file in quarantine when phase 1 did not (the uncached-
// keeper fallback), re-stat the file and the keeper, and THEN — as the
// gate's final verdict, with nothing between it and the unlink — re-stat
// EVERY copy the tier was counted on (codex 1611: the save is an await,
// and a counted sibling can be rewritten or pulled under it; codex 1619
// #1: so can the fallback's full re-read, which may take minutes), re-
// decide the tier from what still holds — permanent → Trash, or put back
// when fewer than two remain, the row naming the copy that changed —
// then unlink or move to the Trash. Then the catalog settles (carry-over,
// row removal, ledger, log), the row is updated and the plan saved again.
//
// PARALLELISM: pairs whose duplicate lives on an SSD may run two at a
// time; on anything else (HDD, RAID, network, unknown) one at a time —
// two sequential readers on one spinning disk thrash it. A weighted slot
// gate (capacity 2; SSD pair = 1, other = 2) on the main actor keeps the
// rule; an HDD pair never overlaps anything. Plan saves stay ordered
// (one writer, generations taken on the main actor). Memory: at most two
// 1 MiB hash buffers in flight.
//
// Before EVERY pair the catalog is asked again whether the row is still
// authorised (`VideoScanModel.authorizeDuplicateDeletion`) — after a
// pause, a resume, anything: a cached yes is never acted on (#3).
//
// PAUSE waits for the pair(s) in flight to reach a safe boundary (put
// back or gone), then holds with the plan saved: "Paused at N of M". A
// paused job with nothing in flight is not a reason to warn on quit —
// the plan is on disk, the next launch offers it. STOP (the row's button
// and Cancel All) keeps the rest for later by default: the pair in flight
// is put back, the plan stays resumable and is offered at once; only
// "Stop and discard the rest" files the plan as cancelled. QUIT mid-pair
// offers "Finish this file, then quit" (the pair lands, the plan is
// saved at the boundary) or "Stop now" (the pair is put back); either way
// the plan is suspended, never abandoned (#5). "Finish this file" is a
// PERMISSION, and a later Stop / Quit / deadline REVOKES it (codex 1606
// #2): the latch is cleared and the stop flag set before any await can
// return, so phase 2 never starts after a forced stop — the file goes
// back. What happened to the file in flight is recorded on the job
// (`interruptedFileOutcomes`) so the quit path logs what it OBSERVED,
// never what it hoped (codex 1606, "Stop now").
//
// A file a put-back could not return (the original path was occupied)
// leaves its row settled but STRANDED: the plan is never filed as done,
// stays offered as "N files waiting to be put back", and the Put Back
// action (or the next resume) retries only the move home — no
// verification, no deletion authority (codex 1606 #3).
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
    /// The family's other copies, for the copy-count tier.
    let tierCandidates: DeletionTierCandidates
}

enum DeleteDuplicatesDiskOutcome: Sendable {
    /// Phase 1 done: verified and in quarantine, not yet removed; the
    /// tier facts were gathered with the file's digest in hand.
    case quarantined(QuarantineTicket, facts: DeletionTierFacts)
    case deleted(bytes: Int64, proof: VerifiedDuplicate)
    case trashed(bytes: Int64, location: String, proof: VerifiedDuplicate)
    case refused(reason: String, cancelled: Bool)
    /// The tier said too few verified copies would remain: put back
    /// untouched (or never moved), not a refusal, the row keeps its
    /// disposition. `facts` carry the count for the row.
    case leftAlone(reason: String, facts: DeletionTierFacts)
    case failed(reason: String)
    case retained(path: String, reason: String)
}

/// Phase 1's result: the outcome, plus the keeper's fresh whole-file
/// fixity when path 1 read it — WHATEVER the verdict. A refused first
/// pair (a look-alike) must not cost the next pair a second read of the
/// same keeper (codex follow-up P2 #6).
struct DeleteDuplicatesPhaseOne: Sendable {
    let outcome: DeleteDuplicatesDiskOutcome
    let learnedKeeperFixity: ContentFixity?
}

/// Phase 2's result: the outcome, the decision the file ACTUALLY went by
/// and the facts behind it. When the removal boundary's re-check dropped
/// a counted copy (codex 1611), `evidenceChanged` is true, `decision` is
/// the re-decided tier (reason naming the copy) and `facts` is what still
/// held — the row and the ledger take these over the ones saved with the
/// ticket. Otherwise they are the phase-one values, untouched.
struct DeleteDuplicatesPhaseTwo: Sendable {
    let outcome: DeleteDuplicatesDiskOutcome
    let decision: DeletionTierDecision
    let facts: DeletionTierFacts
    let evidenceChanged: Bool
}

/// A locked slot for the fixity the gate reports from the disk thread.
private final class FixityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ContentFixity?
    var value: ContentFixity? { lock.withLock { stored } }
    func set(_ f: ContentFixity) { lock.withLock { stored = f } }
}

enum DeleteDuplicatesDiskWorker {
    /// Phase 1, outside the main actor. With a usable stored keeper
    /// fixity: move first, hash once in quarantine (path 3). Without one:
    /// read both files once at their paths (path 1), then quarantine —
    /// the unlink step re-reads, as before. Carries only immutable value
    /// snapshots — never VideoRecord instances.
    static func verifyAndQuarantine(_ item: DeleteDuplicatesWorkItem,
                                    hooks: SignatureVerification.Hooks) -> DeleteDuplicatesPhaseOne {
        let box = FixityBox()
        var observing = hooks
        let downstream = hooks.didComputeKeeperFixity
        observing.didComputeKeeperFixity = { fixity in
            box.set(fixity)
            downstream?(fixity)
        }
        let outcome = phaseOne(item, hooks: observing)
        return DeleteDuplicatesPhaseOne(outcome: outcome, learnedKeeperFixity: box.value)
    }

    private static func phaseOne(_ item: DeleteDuplicatesWorkItem,
                                 hooks: SignatureVerification.Hooks) -> DeleteDuplicatesDiskOutcome {
        // Before moving or reading anything: with the keeper's digest
        // already known (a usable stored fixity), the family's other copies
        // can be stat'ed now. If fewer than two verified copies could
        // remain, the file is left where it is — no move, no read (QA #5:
        // an offline archive copy is found out here, not after a hash).
        // The decision after the hash is still the one that counts.
        if let fixity = item.keeperFixity, fixity.isUsableForVerification {
            let pre = DeletionTierFacts.gather(item.tierCandidates, digest: fixity.digest)
            if pre.remainingVerifiedCopies < DeletionTierDecision.minimumForTrash {
                return .leftAlone(reason: DeletionTierDecision.decide(facts: pre, preferTrash: false).reason, facts: pre)
            }
        }
        switch SignatureVerification.holdForSingleRead(keeperPath: item.keeperPath, keeperFixity: item.keeperFixity,
                                                       duplicatePath: item.path,
                                                       directoryName: item.quarantineDirectoryName, hooks: hooks) {
        case .held(let hold):
            switch SignatureVerification.verifyHeld(hold, hooks: hooks) {
            case .verified(let ticket):
                return .quarantined(ticket, facts: DeletionTierFacts.gather(item.tierCandidates, digest: ticket.proof.fullHash))
            case .refused(let failure):
                return .refused(reason: duplicateRefusalNote(failure, keeper: item.keeperFilename),
                                cancelled: failure == .cancelled)
            case .retainedQuarantine(let path, let reason):
                return .retained(path: path, reason: reason)
            }
        case .keeperFixityUnusable:
            switch SignatureVerification.verify(keeperPath: item.keeperPath, duplicatePath: item.path, hooks: hooks) {
            case .failure(let failure):
                return .refused(reason: duplicateRefusalNote(failure, keeper: item.keeperFilename),
                                cancelled: failure == .cancelled)
            case .success(let proof):
                switch SignatureVerification.quarantine(proof, directoryName: item.quarantineDirectoryName, hooks: hooks) {
                case .quarantined(let ticket):
                    return .quarantined(ticket, facts: DeletionTierFacts.gather(item.tierCandidates, digest: proof.fullHash))
                case .refused(let failure):
                    return .refused(reason: duplicateRefusalNote(failure, keeper: item.keeperFilename),
                                    cancelled: failure == .cancelled)
                case .failed(let reason): return .failed(reason: reason)
                case .retainedQuarantine(let path, let reason):
                    return .retained(path: path, reason: reason)
                }
            }
        case .refused(let failure):
            return .refused(reason: duplicateRefusalNote(failure, keeper: item.keeperFilename),
                            cancelled: failure == .cancelled)
        case .failed(let reason): return .failed(reason: reason)
        case .retainedQuarantine(let path, let reason): return .retained(path: path, reason: reason)
        }
    }

    /// Phase 2: re-read the file in quarantine when phase 1 did not (the
    /// uncached-keeper fallback), re-check the file's and the keeper's
    /// identity, and — as the gate's FINAL verdict, after all hashing and
    /// in the same synchronous stretch as the removal, no await between —
    /// re-stat every copy the tier was counted on and re-decide it from
    /// what still holds (codex 1611; moved after the re-read for codex
    /// 1619 #1). When the evidence no longer reaches two, the file is put
    /// back untouched and the outcome says which copy changed. `decided`
    /// is the tier recorded before the save; it is what the file goes by
    /// when every stamp reproduces. Stat only — the keeper is never read
    /// here.
    static func deleteQuarantined(_ ticket: QuarantineTicket, decided: DeletionTierDecision,
                                  facts: DeletionTierFacts, preferTrash: Bool,
                                  keeperFilename: String,
                                  hooks: SignatureVerification.Hooks) -> DeleteDuplicatesPhaseTwo {
        guard let decidedTier = decided.tier else {
            // Never reached — the caller releases a nil tier itself — but
            // a nil tier must never default to an unlink.
            return DeleteDuplicatesPhaseTwo(
                outcome: release(ticket, reason: decided.reason, keeperFilename: keeperFilename, leftAlone: facts),
                decision: decided, facts: facts, evidenceChanged: false)
        }
        let recorded: SignatureVerification.Disposal = decidedTier == .trash ? .trash : .permanent
        // Set by the final verdict when a counted copy no longer holds:
        // the re-decided tier and the facts behind it. A non-escaping
        // closure may write a local of its caller (for Rick: a lambda
        // capturing by reference).
        var boundary: (decision: DeletionTierDecision, facts: DeletionTierFacts)?
        let result = SignatureVerification.deleteQuarantined(ticket, disposal: recorded, hooks: hooks) {
            let now = facts.recheck()
            guard !now.droppedAtBoundary.isEmpty else {
                // Every counted copy still reproduces its stamp: the
                // recorded tier stands.
                return .proceed(recorded)
            }
            let redecided = DeletionTierDecision.decide(facts: now, preferTrash: preferTrash)
            guard let tier = redecided.tier else {
                // Below two: back to its original path, untouched. Not a
                // refusal of the PAIR — the duplicate is still identical to
                // the keeper — so the row is left alone and keeps its
                // disposition; the reason names the copy that changed.
                let reason = "evidence changed before removal: " + redecided.reason
                boundary = (DeletionTierDecision(tier: nil, remainingVerifiedCopies: redecided.remainingVerifiedCopies,
                                                 reason: reason), now)
                return .putBack(reason: reason)
            }
            let prefix = tier == decided.tier ? "re-checked before removal — " : "downgraded before removal — "
            boundary = (DeletionTierDecision(tier: tier, remainingVerifiedCopies: redecided.remainingVerifiedCopies,
                                             reason: prefix + redecided.reason), now)
            return .proceed(tier == .trash ? .trash : .permanent)
        }
        var outcome = map(result, proof: ticket.proof, keeper: keeperFilename)
        guard let boundary else {
            return DeleteDuplicatesPhaseTwo(outcome: outcome, decision: decided, facts: facts, evidenceChanged: false)
        }
        if boundary.decision.tier == nil, case .refused(_, true) = outcome {
            // The put-back the verdict asked for succeeded: left alone,
            // not refused (a failed put-back stays `.retained`, named).
            outcome = .leftAlone(reason: boundary.decision.reason, facts: boundary.facts)
        }
        return DeleteDuplicatesPhaseTwo(outcome: outcome, decision: boundary.decision, facts: boundary.facts,
                                        evidenceChanged: true)
    }

    /// Put a quarantined file back without deleting it (the plan could not
    /// record the quarantine, the run is stopping, or the tier said no).
    static func release(_ ticket: QuarantineTicket, reason: String, keeperFilename: String,
                        leftAlone facts: DeletionTierFacts? = nil) -> DeleteDuplicatesDiskOutcome {
        let outcome = map(SignatureVerification.releaseQuarantine(ticket, reason: reason),
                          proof: ticket.proof, keeper: keeperFilename)
        if let facts, case .refused(_, true) = outcome { return .leftAlone(reason: reason, facts: facts) }
        return outcome
    }

    private static func map(_ result: SignatureVerification.DeletionResult, proof: VerifiedDuplicate,
                            keeper: String) -> DeleteDuplicatesDiskOutcome {
        switch result {
        case .deleted(let bytes): return .deleted(bytes: bytes, proof: proof)
        case .trashed(let bytes, let location): return .trashed(bytes: bytes, location: location, proof: proof)
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
    /// True only at a safe boundary: pause requested AND nothing in flight.
    @Published private(set) var isPausedValue = false
    private(set) var wasRefused = false

    /// The old verb's result tuple — valid once the job is terminal.
    /// `deleted` counts files that left their place (unlinked or trashed);
    /// `bytesFreed` counts only what came back NOW (permanent).
    private(set) var result: (deleted: Int, failed: Int, skipped: Int, bytesFreed: Int64) = (0, 0, 0, 0)

    /// Internal so tests (and the model verb) can `await job.task?.value`.
    private(set) var task: Task<Void, Never>?
    /// The detached disk phase of each pair in flight (its cancel), so
    /// Stop / Quit can cancel them.
    private var workers: [UUID: () -> Void] = [:]
    private var workerTokens: [UUID: UUID] = [:]
    /// The main-actor task driving each pair in flight (settle + save).
    private var pairTasks: [UUID: Task<Void, Never>] = [:]
    private var inFlight: Set<UUID> = []
    /// The most pairs that were ever in flight together (tests read it).
    private(set) var peakInFlight = 0
    private var pauseWaiter: CheckedContinuation<Void, Never>?
    private var pauseRequested = false
    private var rate = DeleteDuplicatesRate()
    private var saveGeneration: UInt64 = 0
    /// A plan.json write failed: the run stops after the current pair —
    /// a resume nobody can trust is worse than none (the Angel's audit #5).
    private var planSaveFailed = false
    /// The app is quitting: suspend, don't abandon (#5).
    private(set) var quitRequested = false
    /// Quit chose "Finish this file, then quit": the pair(s) in flight
    /// land normally, nothing new starts. A PERMISSION — revoked by any
    /// later Stop / Quit / deadline (codex 1606 #2), never left standing.
    private(set) var finishInFlightForQuit = false
    /// What became of each file that was in flight when the run was
    /// interrupted — "put back at …" or "could not put back — …" — in
    /// the order they settled. The quit path logs these, observed.
    private(set) var interruptedFileOutcomes: [String] = []
    /// Stop (default): put the pair in flight back, keep the plan
    /// resumable and offer it at once.
    private(set) var stopKeepingPlan = false
    /// Stop and discard the rest: the old abandon — the plan is filed as
    /// cancelled.
    private(set) var discardRequested = false
    private var tally = PairTally()
    private var settledSinceCheckpoint = 0
    private var batchID = ""
    /// Slot gate: capacity 2; an SSD pair takes 1, anything else takes 2.
    private var slotsInUse = 0
    private var slotWaiters: [CheckedContinuation<Void, Never>] = []
    static let slotCapacity = 2
    /// Volume classification for the slot weight. nil → the model's scan
    /// targets (longest prefix). Tests inject.
    var mediaTechForPath: ((String) -> VolumeMediaTech)?
    /// Test seam: runs just before the final save (finding #6 regression
    /// makes that save fail and checks the last good plan stays put).
    var testHookBeforeFinalSave: (@MainActor () -> Void)?
    /// Test seam: runs right after the quarantine ticket has been saved
    /// and BEFORE phase 2 is scheduled (codex follow-up P1 #4: a Stop /
    /// Quit landing exactly here must put the file back, never unlink).
    var testHookAfterQuarantineSaved: (@MainActor (DeleteDuplicatesPlan.Entry) -> Void)?

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
    /// The row's button flips to Resume as soon as the pause is asked for
    /// — "Pausing…" then "Paused at N of M" in the subtitle.
    var isPaused: Bool { pauseRequested }
    /// Nothing in flight, the plan saved: the quit guard leaves this job
    /// alone (Rick 2026-09-20 evening test drive: "pausing … should allow
    /// quitting when paused, not requiring stop").
    var isQuiescentForQuit: Bool { state.isActive && isPausedValue && inFlight.isEmpty }
    /// True while at least one pair is between "moved" and "settled".
    var isMidPair: Bool { !inFlight.isEmpty }
    var inFlightCount: Int { inFlight.count }

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
            // offered now, not at the next launch (#8) — including THIS
            // plan after a Stop that kept it. `run` has released the
            // model's re-entry flag by here.
            self.model?.checkForUnfinishedDeleteDuplicatesPlans(root: self.planRoot)
        }
    }

    func refuseToStart(reason: String) {
        guard task == nil, state.isActive else { return }
        wasRefused = true
        finish(failed: reason)
        task = Task {}
    }

    /// Stop (the row's button, Cancel All, a cancelled caller): the pair in
    /// flight is put back, what is done stays done, and the REST IS KEPT —
    /// the plan stays resumable and is offered at once (Rick 2026-09-20
    /// evening). `cancel(discardingRemaining: true)` is the old abandon.
    func cancel() { cancel(discardingRemaining: false) }

    func cancel(discardingRemaining: Bool) {
        guard state.isActive else { return }
        // Revoke "finish this file" FIRST (codex 1606 #2): the release
        // gate after the ticket save and the newborn-worker cancel both
        // read this latch, and a Stop that lands during that save has no
        // worker to cancel — the cleared latch is what stops phase 2.
        finishInFlightForQuit = false
        if discardingRemaining {
            discardRequested = true
            subtitleText = "Stopping — files already deleted stay deleted, the rest are left alone…"
        } else {
            stopKeepingPlan = true
            subtitleText = "Stopping — the file being checked is put back; the rest is kept to resume later…"
        }
        state = .cancelling
        cancelWorkers()
        wakeAll()
    }

    /// Quit, "Stop now": same interruption as Stop on disk (the pair in
    /// flight is put back, nothing half-done), but the plan is SUSPENDED —
    /// the row in flight returns to pending, nothing is skipped, the plan
    /// stays unfinished in place and is offered to resume at the next launch.
    func stopForQuit() {
        guard state.isActive else { return }
        // A forced stop after "finish this file" (the quit deadline, or
        // "Stop now" chosen after it) revokes the permission before any
        // await returns (codex 1606 #2).
        finishInFlightForQuit = false
        quitRequested = true
        state = .cancelling
        subtitleText = "Quitting — files already deleted stay deleted; the rest will be offered to resume at the next launch…"
        cancelWorkers()
        wakeAll()
    }

    /// Quit, "Finish this file, then quit": nothing new starts, the
    /// pair(s) in flight land (deleted / trashed / refused), the plan is
    /// saved at that boundary, then the run suspends exactly as a quit
    /// does.
    func finishCurrentFileThenSuspendForQuit() {
        guard state.isActive else { return }
        quitRequested = true
        finishInFlightForQuit = true
        state = .cancelling
        subtitleText = inFlight.isEmpty
            ? "Quitting — the plan is kept and will be offered to resume at the next launch…"
            : "Finishing the current file, then quitting — \(progressText())"
        wakeAll()
    }

    /// Pause takes effect at the next safe boundary: the file(s) being
    /// read right now are finished (or put back) first, nothing is
    /// half-done. Never a Stop.
    func pause() {
        guard state == .running, !pauseRequested else { return }
        pauseRequested = true
        if inFlight.isEmpty {
            enterPausedState()
        } else {
            publishProgress()
            model?.log("  Delete Duplicates on \(volumeName): pausing — will hold after the current file\(inFlight.count == 1 ? "" : "s").")
        }
    }

    func resume() {
        guard pauseRequested else { return }
        pauseRequested = false
        isPausedValue = false
        model?.log("  Delete Duplicates on \(volumeName): resumed.")
        publishProgress()
        wakeAll()
    }

    private func enterPausedState() {
        guard pauseRequested, !isPausedValue, state == .running else { return }
        isPausedValue = true
        publishProgress()
        model?.log("  Delete Duplicates on \(volumeName): paused at \(progressText()) — plan kept; quit is safe, Resume continues.")
    }

    /// The quit guard's log line for a paused, idle job.
    var pausedForQuitLogLine: String {
        "delete duplicates paused at \(progressText()) — plan kept, resume at next launch"
    }

    /// What the quit path OBSERVED after a stop (codex 1606, "Stop now"):
    /// whether the run has settled, and what became of each file that was
    /// in flight — put back at its path, or could not be put back and
    /// where it sits. Never a promise.
    var quitOutcomeLine: String {
        let settled = state.isActive ? "still settling (\(inFlight.count) in flight)" : "settled"
        let files = interruptedFileOutcomes.isEmpty
            ? (state.isActive ? "no file has settled yet" : "no file was in flight")
            : interruptedFileOutcomes.joined(separator: "; ")
        return "delete duplicates on \(volumeName) \(settled) at \(progressText()) — \(files); plan kept for resume"
    }

    private func progressText() -> String {
        guard let plan else { return "0 of 0" }
        let c = plan.counts
        let f = NumberFormatter(); f.numberStyle = .decimal
        func n(_ v: Int) -> String { f.string(from: NSNumber(value: v)) ?? "\(v)" }
        return "\(n(c.settled)) of \(n(c.total))"
    }

    private func cancelWorkers() {
        for cancel in workers.values { cancel() }
    }

    private func wakeAll() {
        pauseWaiter?.resume()
        pauseWaiter = nil
        let waiters = slotWaiters
        slotWaiters = []
        for w in waiters { w.resume() }
    }

    private var stopRequested: Bool { state.cancelWasRequested || Task.isCancelled }

    /// The quarantine folder for one row: named from the plan and the row
    /// so it is unique per attempt and derivable at resume even when the
    /// crash beat the save that records it.
    nonisolated static func quarantineDirectoryName(planID: UUID, entryID: UUID) -> String {
        SignatureVerification.quarantineDirectoryPrefix + planID.uuidString.prefix(8) + "-" + entryID.uuidString
    }

    /// SSD → 1 of 2 slots (two pairs may overlap); anything else → both
    /// slots (one at a time; unknown counts as HDD).
    nonisolated static func slotWeight(for tech: VolumeMediaTech) -> Int {
        tech == .ssd ? 1 : slotCapacity
    }

    private func mediaTech(for path: String) -> VolumeMediaTech {
        if let mediaTechForPath { return mediaTechForPath(path) }
        return model?.mediaTech(forPath: path) ?? .unknown
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

        var prepared: DeleteDuplicatesPlan
        if let resumed = resumingPlan {
            prepared = await revalidateForResume(resumed, model: model)
        } else {
            guard let fresh = await model.prepareDuplicateDeletion(onVolume: volumePath) else {
                finish(success: "Nothing to delete")
                return
            }
            prepared = fresh
        }
        prepared.startedAt = prepared.startedAt ?? Date()
        self.plan = prepared
        isIndeterminateValue = false
        // The ordered writer remembers the last generation it wrote for
        // this plan id for the life of the process; a same-process resume
        // must continue from there or every save would be dropped as
        // stale (QA MINOR 4).
        saveGeneration = await DeleteDuplicatesPlanWriter.shared.lastGeneration(for: prepared.id)

        guard !prepared.entries.isEmpty else {
            // The old "(0, 0, skipped, 0)" — nothing to run, nothing to save.
            result = (0, 0, prepared.skippedBeforePlan, 0)
            finish(success: "No duplicates to delete on \(volumeName)"
                   + (prepared.skippedBeforePlan > 0 ? " — \(prepared.skippedBeforePlan) skipped" : ""))
            return
        }
        await savePlan(context: "plan made")
        publishProgress()

        tally = PairTally()
        settledSinceCheckpoint = 0
        batchID = "dupdelete-\(prepared.id.uuidString.prefix(8))"

        await dispatchPairs(model: model)

        // Drain: every pair in flight settles (deleted, trashed, refused,
        // or put back) before the run decides how it ended.
        while let pending = pairTasks.values.first {
            await pending.value
        }
        await finishRun(model: model)
    }

    /// The dispatch loop. EVERY deletion is gated on a full read of the
    /// file about to go, performed in its quarantine folder immediately
    /// before the remove, against the keeper's whole-file digest (stored
    /// on first use, checked by stat stamp after that). See
    /// SignatureVerification.swift for why.
    private func dispatchPairs(model: VideoScanModel) async {
        var cursor = 0
        while let current = plan, cursor < current.entries.count {
            let entry = current.entries[cursor]
            if entry.status.isSettled { cursor += 1; continue }
            await waitWhilePaused()
            if stopRequested || planSaveFailed { break }
            // A keeper without a usable stored fixity is read in full by
            // its first pair; that pair runs ALONE (both slots) so a
            // second pair cannot read the same keeper again beside it.
            // Every later pair of that keeper stats it and may overlap.
            let keeperHasFixity = model.record(forID: entry.keeperID)?.contentFixity?.isUsableForVerification == true
            let weight = keeperHasFixity ? Self.slotWeight(for: mediaTech(for: entry.path)) : Self.slotCapacity
            await acquireSlots(weight)
            if pauseRequested || stopRequested || planSaveFailed {
                // Asked to hold / stop while waiting for a slot: give it
                // back and re-check this same row from the top.
                releaseSlots(weight)
                continue
            }
            cursor += 1

            // LIVE authorization, this instant — never the plan's or the
            // preflight's answer (#3).
            let record: VideoRecord
            let keeper: VideoRecord
            switch model.authorizeDuplicateDeletion(entry: entry, volumePath: volumePath,
                                                    crossVolumeMode: current.crossVolumeMode,
                                                    stage: "before deletion") {
            case .authorized(let r, let k):
                record = r; keeper = k
            case .skip(let note, let line):
                mutatePlan { $0.set(entry.id, .skipped, note: note) }
                model.log("  " + line)
                releaseSlots(weight)
                continue
            case .refuse(let note):
                tally.refused += 1
                let mutated = model.noteRefusedDuplicate(expectedID: entry.id, expectedPath: entry.path,
                                                         filename: entry.filename, reason: note)
                tally.catalogMutated = tally.catalogMutated || mutated
                mutatePlan { $0.set(entry.id, .refused, note: note) }
                releaseSlots(weight)
                continue
            }

            // COPY-COUNT TIER: the family's other copies, from the fresh
            // catalog; the disk is asked about them once the digest is in
            // hand. The archive is not required (Rick, late 2026-09-20).
            let alsoPending = Set(current.entries.filter { !$0.status.isSettled && $0.id != entry.id }.map(\.id))
            let candidates = model.deletionTierCandidates(record: record, keeper: keeper, excluding: alsoPending)

            mutatePlan { $0.set(entry.id, .verifying) }
            model.duplicateStatus = "Verifying duplicate \((plan?.counts.settled ?? 0) + 1) of \(current.entries.count)…"
            let item = DeleteDuplicatesWorkItem(
                path: entry.path, keeperPath: keeper.fullPath, keeperFilename: keeper.filename,
                keeperFixity: keeper.contentFixity,
                quarantineDirectoryName: Self.quarantineDirectoryName(planID: current.id, entryID: entry.id),
                tierCandidates: candidates)
            inFlight.insert(entry.id)
            peakInFlight = max(peakInFlight, inFlight.count)
            // The pair runs as its own main-actor task so a second SSD pair
            // can be dispatched while this one's disk phases are awaited.
            // The pre-await SNAPSHOT of the row (immutable facts for the
            // log and the ledger line) is taken inside, before any await:
            // never the live instance (#4).
            pairTasks[entry.id] = Task { @MainActor [weak self] in
                await self?.runPair(entry: entry, record: record, keeper: keeper, item: item, weight: weight)
            }
        }
    }

    /// How the run ended: suspended (Quit / Stop), or completed /
    /// discarded / stopped-by-save-failure with the summary, the log, the
    /// plan filed under done/ (unless a row is still stranded in
    /// quarantine — then the plan stays in place and says so).
    private func finishRun(model: VideoScanModel) async {
        if tally.catalogMutated {
            NotificationCenter.default.post(name: .videoScanCatalogMutated, object: nil)
        }
        guard var finalPlan = plan else { finish(failed: "The plan went away mid-run."); return }

        // QUIT / STOP: suspend. Nothing is skipped, the plan stays
        // unfinished in place (never under done/), and it is offered —
        // at once after a Stop, at the next launch after a Quit (#5).
        if quitRequested || stopKeepingPlan {
            let remaining = finalPlan.remainingCount
            let how = quitRequested ? "quit" : "Stop"
            finalPlan.log.append("Suspended by \(how) with \(remaining) remaining — offered to resume "
                                 + (quitRequested ? "at the next launch" : "now, or at the next launch"))
            self.plan = finalPlan
            result = (tally.removed, tally.failed, finalPlan.skippedBeforePlan + tally.leftAlone, tally.bytesFreed)
            let freed = DeleteDuplicatesRate.freedText(counts: finalPlan.counts, trashVolumes: finalPlan.trashVolumes)
            model.log("\nDelete Duplicates on \(volumeName) suspended for \(how): \(tally.removed) deleted, \(remaining) remaining — "
                      + (quitRequested ? "the run will be offered to resume at the next launch."
                         : "kept; Resume in Media File Operations, or at the next launch.")
                      + (freed.isEmpty ? "" : " (\(freed))"))
            model.duplicateStatus = "\(tally.removed) deleted — \(remaining) remaining, resume offered"
            if !(await savePlan(context: "suspended for \(how)")) {
                model.log("  The suspended plan could not be saved — the last saved plan stays in place and will be offered instead.")
            }
            finishSuspended(remaining: remaining, quit: quitRequested)
            return
        }

        // Discard / save failure: the rest is counted, not done.
        let stopped = stopRequested || planSaveFailed
        if stopped {
            let reason = planSaveFailed
                ? "stopped — the plan could not be saved, so the rest was left alone"
                : "cancelled before verification"
            let left = finalPlan.skipRemaining(reason: reason)
            tally.failed += left
            if !planSaveFailed {
                model.log("  Duplicate deletion cancelled before verification completed")
            }
        }

        let counts = finalPlan.counts
        let (deleted, trashed, failed, refused, leftAlone) =
            (tally.deleted, tally.trashed, tally.failed, tally.refused, tally.leftAlone)
        let freedNow = ByteCountFormatter.string(fromByteCount: tally.bytesFreed, countStyle: .file)
        let freedText = DeleteDuplicatesRate.freedText(counts: counts, trashVolumes: finalPlan.trashVolumes)
        var completion = "\(deleted) deleted, "
        if trashed > 0 { completion += "\(trashed) to the Trash, " }
        completion += "\(failed) failed, \(refused) refused by verification, \(finalPlan.skippedBeforePlan) skipped, "
        if leftAlone > 0 { completion += "\(leftAlone) left alone (too few verified copies would remain), " }
        completion += (freedText.isEmpty ? "\(freedNow) freed" : freedText) + " (\(finalPlan.summaryLine))"
        if finalPlan.crossVolumeMode {
            model.log("\n" + WorkingCopyCleanupText.logSummary(volume: volumeName, detail: "complete — " + completion))
        } else {
            model.log("\nDuplicate deletion complete: " + completion)
        }
        if refused > 0 {
            model.log("  \(refused) file(s) were NOT identical to their keeper despite matching "
                + "on hash/name/duration — they are marked Review and left on disk.")
        }
        if leftAlone > 0 {
            model.log("  \(leftAlone) file(s) were left alone because fewer than two verified copies would remain — verify or archive another copy of the family first, then run again.")
        }
        model.duplicateStatus = trashed > 0
            ? "\(deleted + trashed) deleted, \(freedText)"
            : "\(deleted) deleted, \(freedNow) freed"
        result = (deleted + trashed, failed, finalPlan.skippedBeforePlan + leftAlone, tally.bytesFreed)

        finalPlan.finishedAt = Date()
        finalPlan.outcome = planSaveFailed ? "stopped (plan not saved)" : (stopRequested ? "cancelled" : "completed")
        finalPlan.log.append(completion)
        self.plan = finalPlan
        testHookBeforeFinalSave?()
        // A row whose file could not be put back at resume is still in a
        // quarantine folder the plan names: such a plan is NEVER filed
        // under done/ — it stays where the next launch and Rick can find
        // it (codex follow-up P1 #5).
        let stranded = finalPlan.entries.filter { $0.quarantineDirectory != nil }
        // The plan is filed under done/ ONLY when its terminal state is on
        // disk (#6). A failed final save leaves the last good plan.json
        // where it is — still discoverable — and says so.
        if !stranded.isEmpty {
            _ = await savePlan(context: "finished with \(stranded.count) stranded", final: true)
            model.log("  Delete Duplicates: \(stranded.count) file(s) are still in quarantine and could not be put back — the plan stays under \(DeleteDuplicatesPlanStore.directory(for: finalPlan.id, root: planRoot).path) and is not filed as done; it will be offered with a Put Back action (here, and at the next launch): "
                      + stranded.map { "\($0.filename) in \($0.quarantineDirectory ?? "?")" }.joined(separator: "; "))
        } else if await savePlan(context: "finished", final: true) {
            fileDone(finalPlan)
        } else {
            model.log("  Delete Duplicates: the finished plan could not be saved — the last saved plan stays in place under \(DeleteDuplicatesPlanStore.directory(for: finalPlan.id, root: planRoot).path) and is not filed as done.")
        }

        var summaryParts = ["\(deleted) deleted"]
        if trashed > 0 { summaryParts.append("\(trashed) to the Trash") }
        summaryParts.append(freedText.isEmpty ? "\(freedNow) freed" : freedText)
        if refused > 0 { summaryParts.append("\(refused) refused") }
        if failed > 0 { summaryParts.append("\(failed) not done") }
        if leftAlone > 0 { summaryParts.append("\(leftAlone) left alone") }
        let summary = summaryParts.joined(separator: " · ")
        if planSaveFailed {
            finish(failed: "Stopped after \(deleted + trashed) deleted — the plan could not be saved (\(summary))")
        } else if state.cancelWasRequested || Task.isCancelled {
            finishCancelled()
        } else {
            finish(success: summary)
        }
    }

    /// One pair, start to settled, on the main actor with the disk phases
    /// awaited off it. Removes itself from `inFlight` / `pairTasks` and
    /// releases its slots at the end; the pause boundary is checked here.
    private func runPair(entry: DeleteDuplicatesPlan.Entry, record: VideoRecord, keeper: VideoRecord,
                         item: DeleteDuplicatesWorkItem, weight: Int) async {
        defer {
            pairTasks[entry.id] = nil
        }
        guard let model, plan != nil else {
            inFlight.remove(entry.id); releaseSlots(weight); return
        }
        let preAwait = record.snapshotClone()
        let pairStarted = Date()
        var decision: DeletionTierDecision?
        let trashVolume = VolumeReachability.volumeName(forPath: entry.path)

        // Phase 1: hold + hash once (or verify twice on the first pair of
        // a keeper without a fixity) + the tier facts.
        let phaseOne = await runDetached(entryID: entry.id) { [hooks] in
            DeleteDuplicatesDiskWorker.verifyAndQuarantine(item, hooks: hooks)
        }
        var outcome = phaseOne.outcome
        // The keeper was read in full by this pair: publish its fixity to
        // the catalog NOW, whatever this pair's verdict, so the next pair
        // with this keeper only stats it (P2 #6).
        if let learned = phaseOne.learnedKeeperFixity, keeper.contentFixity != learned,
           model.storeContentFixity(recordID: keeper.id, path: keeper.fullPath, fixity: learned) {
            tally.catalogMutated = true
        }
        if case .quarantined(let ticket, let facts) = outcome {
            // COPY-COUNT TIER, part 2 — with the digest in hand.
            let decided = DeletionTierDecision.decide(
                facts: facts, preferTrash: model.duplicateKeeperSettings.preferTrashForEveryDuplicate)
            decision = decided
            // Record WHERE the file is and how it will go before it can be
            // removed (#2).
            mutatePlan {
                $0.setQuarantined(entry.id, directory: ticket.quarantineDirectory, stamp: ticket.baseline)
                $0.setTier(entry.id, decided, trashVolume: trashVolume, hasVerifiedArchive: facts.hasVerifiedArchive,
                           evidence: facts.countedCopies)
            }
            await savePlan(context: "quarantined \(entry.filename)")
            testHookAfterQuarantineSaved?(entry)
            let keeperName = keeper.filename
            if planSaveFailed {
                // Nobody could find it after a crash: put it back and stop.
                outcome = await runDetached(entryID: entry.id) {
                    DeleteDuplicatesDiskWorker.release(ticket, reason: "plan could not be saved after quarantine",
                                                       keeperFilename: keeperName)
                }
            } else if stopRequested && !finishInFlightForQuit {
                // A Stop / Quit landed while the ticket was being saved —
                // no worker was running to cancel. Re-check the latch
                // BEFORE phase 2 exists: the file goes back, never on
                // (codex follow-up P1 #4). A forced stop that REVOKED
                // "finish this file" during the save lands here too: the
                // latch is false again, the stop flag set (codex 1606 #2).
                outcome = await runDetached(entryID: entry.id) {
                    DeleteDuplicatesDiskWorker.release(ticket, reason: "stopped after quarantine",
                                                       keeperFilename: keeperName)
                }
            } else if let tier = decided.tier {
                // Phase 2: re-stat the counted copies and re-decide (codex
                // 1611), re-check the file and the keeper, unlink or move
                // to the Trash.
                let preferTrash = model.duplicateKeeperSettings.preferTrashForEveryDuplicate
                let phaseTwo = await runDetached(entryID: entry.id) { [hooks] in
                    DeleteDuplicatesDiskWorker.deleteQuarantined(ticket, decided: decided, facts: facts,
                                                                 preferTrash: preferTrash,
                                                                 keeperFilename: keeperName, hooks: hooks)
                }
                outcome = phaseTwo.outcome
                if phaseTwo.evidenceChanged {
                    // The count the file goes by is the boundary's, not the
                    // save's: the row, the log and (through `decision`) the
                    // ledger line say so, naming the copy that changed.
                    decision = phaseTwo.decision
                    mutatePlan {
                        $0.setTier(entry.id, phaseTwo.decision, trashVolume: trashVolume,
                                   hasVerifiedArchive: phaseTwo.facts.hasVerifiedArchive,
                                   evidence: phaseTwo.facts.countedCopies)
                    }
                    let went: String
                    if case .retained = outcome {
                        went = "put-back failed, retained in quarantine"
                    } else {
                        went = phaseTwo.decision.tier.map(\.label) ?? "put back"
                    }
                    let line = "\(entry.filename) re-checked before removal: \(tier.label) → \(went) — "
                        + phaseTwo.facts.droppedAtBoundary.joined(separator: "; ")
                    model.log("  " + line)
                    deleteDupLog.notice("\(line, privacy: .public)")
                }
            } else {
                // Too few verified copies would remain: put it back, untouched.
                let reason = decided.reason
                outcome = await runDetached(entryID: entry.id) {
                    DeleteDuplicatesDiskWorker.release(ticket, reason: reason, keeperFilename: keeperName, leftAlone: facts)
                }
            }
            // A RETAINED file is still in the folder the plan names: keep
            // naming it, so the plan is never filed as done with it there
            // (QA #1). Anything else has left the folder (gone, trashed, or
            // put back at its path).
            if case .retained = outcome {} else {
                mutatePlan { $0.clearQuarantine(entry.id) }
            }
        }
        let seconds = Date().timeIntervalSince(pairStarted)
        let concurrency = inFlight.count

        settle(outcome, entry: entry, keeper: keeper, preAwait: preAwait, decision: decision,
               trashVolume: trashVolume, model: model)

        rate.add(bytes: entry.sizeBytes, seconds: seconds, concurrency: concurrency)
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
        inFlight.remove(entry.id)
        releaseSlots(weight)
        // The safe boundary: nothing in flight and the plan on disk.
        if pauseRequested, inFlight.isEmpty { enterPausedState() }
        if finishInFlightForQuit, inFlight.isEmpty { publishProgress() }
    }

    private func mutatePlan(_ body: (inout DeleteDuplicatesPlan) -> Void) {
        guard var p = plan else { return }
        body(&p)
        plan = p
    }

    /// The run's counters (the old loop's five locals).
    private struct PairTally {
        var deleted = 0
        var trashed = 0
        var failed = 0
        var refused = 0
        var leftAlone = 0
        var bytesFreed: Int64 = 0
        var bytesTrashed: Int64 = 0
        var catalogMutated = false
        var removed: Int { deleted + trashed }
    }

    /// The catalog + plan side of one pair's outcome: counters, the row's
    /// status and note, the keeper's fixity, the ledger line, the log.
    private func settle(_ outcome: DeleteDuplicatesDiskOutcome, entry: DeleteDuplicatesPlan.Entry,
                        keeper: VideoRecord, preAwait: VideoRecord, decision: DeletionTierDecision?,
                        trashVolume: String, model: VideoScanModel) {
        switch outcome {
        case .quarantined:
            // Unreachable — phase 2 always settles a ticket.
            tally.failed += 1
            mutatePlan { $0.set(entry.id, .failed, note: "left in quarantine (internal: phase 2 did not run)") }
        case .refused(let reason, let cancelled):
            settleRefused(reason: reason, cancelled: cancelled, entry: entry, model: model)
        case .leftAlone(let reason, let facts):
            tally.leftAlone += 1
            mutatePlan {
                $0.set(entry.id, .skipped, note: reason)
                $0.setTier(entry.id, DeletionTierDecision(tier: nil, remainingVerifiedCopies: facts.remainingVerifiedCopies, reason: reason),
                           hasVerifiedArchive: facts.hasVerifiedArchive)
            }
            model.log("  Left alone \(entry.filename): \(reason)")
        case .failed(let reason):
            tally.failed += 1
            model.log("  FAILED to delete \(entry.filename): \(reason)")
            mutatePlan { $0.set(entry.id, .failed, note: reason) }
        case .retained(let path, let reason):
            tally.failed += 1
            model.log("  RETAINED safely at \(path): \(reason)")
            mutatePlan { $0.set(entry.id, .failed, note: "retained safely at \(path): \(reason)") }
            if stopRequested {
                interruptedFileOutcomes.append("could not put back \(entry.filename) — retained at \(path): \(reason)")
            }
        case .deleted(let bytes, let proof):
            tally.bytesFreed += bytes
            tally.deleted += 1
            settleRemoved(entry: entry, keeper: keeper, preAwait: preAwait, proof: proof, tier: .permanent,
                          decision: decision, trashVolume: nil, model: model)
            mutatePlan {
                $0.set(entry.id, .deleted, note: "verified identical to \(keeper.filename)",
                       keeperMatchedByStoredFixity: !proof.keeperReadInFull)
            }
        case .trashed(let bytes, _, let proof):
            tally.bytesTrashed += bytes
            tally.trashed += 1
            settleRemoved(entry: entry, keeper: keeper, preAwait: preAwait, proof: proof, tier: .trash,
                          decision: decision, trashVolume: trashVolume, model: model)
            mutatePlan {
                $0.set(entry.id, .trashed,
                       note: "verified identical to \(keeper.filename) — \(DeletionTierText.inTheTrashOf(trashVolume))",
                       keeperMatchedByStoredFixity: !proof.keeperReadInFull)
            }
        }
    }

    private func settleRefused(reason: String, cancelled: Bool, entry: DeleteDuplicatesPlan.Entry, model: VideoScanModel) {
        if cancelled && (quitRequested || stopKeepingPlan) {
            // Suspended, not decided: back to pending for the resume.
            let how = quitRequested ? "quit" : "Stop"
            mutatePlan { $0.set(entry.id, .pending, note: "interrupted by \(how) — will be re-checked at resume") }
            model.log("  \(quitRequested ? "Quit" : "Stopped") while verifying \(entry.filename) — put back; it will be re-checked at resume")
            interruptedFileOutcomes.append("put back \(entry.filename) at \(entry.path)")
        } else if cancelled && planSaveFailed {
            tally.failed += 1
            mutatePlan { $0.set(entry.id, .skipped, note: "the plan could not be saved after quarantine — put back and left alone") }
            model.log("  Put back \(entry.filename): the plan could not be saved after quarantine — left alone")
        } else if cancelled {
            // Not done, not refused: the file is untouched and
            // keeps its disposition; it counts with the rest.
            tally.failed += 1
            mutatePlan { $0.set(entry.id, .skipped, note: "cancelled during verification — left alone") }
            model.log("  Stopped while verifying \(entry.filename) — left alone")
            interruptedFileOutcomes.append("put back \(entry.filename) at \(entry.path)")
        } else {
            tally.refused += 1
            let mutated = model.noteRefusedDuplicate(expectedID: entry.id, expectedPath: entry.path,
                                                     filename: entry.filename, reason: reason)
            tally.catalogMutated = tally.catalogMutated || mutated
            mutatePlan { $0.set(entry.id, .refused, note: reason) }
        }
    }

    private func settleRemoved(entry: DeleteDuplicatesPlan.Entry, keeper: VideoRecord, preAwait: VideoRecord,
                               proof: VerifiedDuplicate, tier: DeletionTier, decision: DeletionTierDecision?,
                               trashVolume: String?, model: VideoScanModel) {
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
            keeperMatchedByStoredFixity: !proof.keeperReadInFull,
            tier: tier, remainingVerifiedCopies: decision?.remainingVerifiedCopies,
            trashVolume: trashVolume, tierReason: decision?.reason)
        tally.catalogMutated = tally.catalogMutated || mutated
    }

    /// One detached disk phase, tracked under the row's id so Stop / Quit
    /// can cancel it. A worker started AFTER a Stop / Quit was asked for
    /// (the latch is checked here too) is cancelled at birth — a detached
    /// task inherits nothing, so the latch is carried in by hand (codex
    /// follow-up P1 #4). "Finish this file, then quit" is the one stop
    /// that lets the pair's workers run to their end.
    private func runDetached<T: Sendable>(entryID: UUID,
                                          _ work: @escaping @Sendable () -> T) async -> T {
        let worker = Task.detached(priority: .userInitiated) { work() }
        if stopRequested && !finishInFlightForQuit { worker.cancel() }
        let token = UUID()
        workers[entryID] = { worker.cancel() }
        workerTokens[entryID] = token
        let outcome = await worker.value
        if workerTokens[entryID] == token { workers[entryID] = nil; workerTokens[entryID] = nil }
        return outcome
    }

    // MARK: Slot gate (main actor)

    private func acquireSlots(_ n: Int) async {
        while slotsInUse + n > Self.slotCapacity && !stopRequested {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                slotWaiters.append(c)
            }
        }
        slotsInUse += n
    }

    private func releaseSlots(_ n: Int) {
        slotsInUse = max(0, slotsInUse - n)
        let waiters = slotWaiters
        slotWaiters = []
        for w in waiters { w.resume() }
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
        // Files stranded by an earlier failed put-back are tried again
        // before anything else — the move home only, no verdict (codex
        // 1606 #3). A settled row never re-enters the run.
        if plan.needsRecovery {
            _ = Self.putBackStranded(in: &plan, log: { model.log($0) })
        }
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
            // RECOVERY comes before DELETION authorization (codex follow-up
            // P1 #5): a crash between the quarantine move and the unlink
            // leaves the file in the folder the plan names (or the folder
            // this plan + row would have used). It is put back FIRST,
            // unconditionally — only the recorded folder and stamp are
            // required — and only then does the catalog decide whether the
            // row is still eligible. Before this, a row re-marked Keep (or
            // whose keeper changed) while its file sat in quarantine was
            // settled with the file stranded there. That folder is
            // consulted first — whatever now sits at the original path is
            // not the file that was verified, and an occupied path refuses
            // the restore rather than re-verifying the newcomer. No named
            // folder and the file gone → it left before the crash; a
            // decision, not a refusal, so the row is not re-marked. A
            // same-named file in some OTHER quarantine folder is only
            // reported — never moved, never removed.
            if let orphan = facts.quarantined[e.path] {
                // The obligation goes ON THE ROW before the restore is even
                // tried (codex 1619 #3): a crash that beat the ticket save
                // left a folder the plan never named, and a restore that
                // then fails (the original path occupied) must settle a row
                // that still names the folder — `needsRecovery` true, the
                // plan never filed as done, Put Back offered. The stamp
                // adopted for an unjournaled folder is the one observed
                // now, only when the size is the plan's (the same test the
                // stamp-less restore applies); otherwise it stays nil and
                // the restore refuses on size.
                let foundFolder = orphan.url.deletingLastPathComponent().path
                if plan.entries[i].quarantineDirectory != foundFolder || plan.entries[i].quarantinedStamp == nil {
                    plan.entries[i].quarantineDirectory = foundFolder
                    plan.entries[i].quarantinedStamp = orphan.recordedStamp
                        ?? orphan.observedStamp.flatMap { $0.size == e.sizeBytes ? $0 : nil }
                }
                switch Self.restoreQuarantined(orphan.url, to: e.path, expectedStamp: plan.entries[i].quarantinedStamp,
                                               expectedSize: e.sizeBytes) {
                case .success(let directoryRemoved):
                    let folder = orphan.url.deletingLastPathComponent().lastPathComponent
                    model.log("  Restored \(e.filename) from \(folder) (a crash left it in quarantine) — it will be verified again before anything is removed"
                              + (directoryRemoved ? "" : "; the quarantine folder was not empty and was left in place"))
                    plan.log.append("Restored \(e.filename) from quarantine at resume")
                    plan.entries[i].quarantineDirectory = nil
                    plan.entries[i].quarantinedStamp = nil
                    plan.entries[i].tier = nil
                    plan.entries[i].tierReason = nil
                    plan.entries[i].remainingVerifiedCopies = nil
                    plan.entries[i].status = .pending
                case .failure(let error):
                    // Still in quarantine: the row keeps naming the folder,
                    // and the plan is never filed as done with it there.
                    refuse("left in quarantine at \(orphan.url.path) — not put back: \(error.description)")
                    continue
                }
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
            if facts.quarantined[e.path] != nil {
                // Restored above and still eligible: verified again below.
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
            /// The file's stamp as found in the folder NOW — what the row
            /// adopts when the crash beat the save that records one
            /// (codex 1619 #3).
            let observedStamp: FileIdentityStamp?
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
                        facts.quarantined[row.path] = ResumeDiskFacts.Quarantined(
                            url: url, recordedStamp: candidate.stamp,
                            observedStamp: FileIdentityStamp.capture(path: url.path))
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

    /// What a stat of a stranded file's quarantine path established
    /// (codex 1619 #2): the file is there; it is ABSENT — the drive is
    /// mounted and reachable and the path is simply not on it; or the
    /// question could not be answered — the drive is not mounted, or the
    /// path failed for a reason other than "no such file" — in which
    /// case the obligation is kept, never cleared.
    enum StrandedPresence: Equatable, Sendable {
        case present
        case absent
        case unavailable(String)
    }

    /// Absence is established ONLY on an accessible drive: `volumePath`
    /// must be a directory now and — for a /Volumes/ path — in the
    /// kernel's mount table (an unmounted drive's mount point may linger
    /// as an empty folder); and the stat of the file must fail with
    /// ENOENT / ENOTDIR, not EIO / EACCES / ENXIO. Synchronous: two stats.
    nonisolated static func strandedPresence(of url: URL, volumePath: String, volumeName: String,
                                             mountedRoots: Set<String>? = nil,
                                             volumesRoot: String = "/Volumes/") -> StrandedPresence {
        var info = stat()
        if stat(url.path, &info) == 0 {
            // A directory under the file's name is not the file (moved by
            // hand, something else put there): nothing of ours to put back.
            return (info.st_mode & S_IFMT) == S_IFDIR ? .absent : .present
        }
        let fileErrno = errno
        var root = stat()
        let rootIsDirectory = stat(volumePath, &root) == 0 && (root.st_mode & S_IFMT) == S_IFDIR
        let mounted = rootIsDirectory && (!volumePath.hasPrefix(volumesRoot)
                                          || (mountedRoots ?? VolumeReachability.currentMountedRoots()).contains(volumePath))
        guard mounted else {
            return .unavailable(DeletionTierText.notConnected(volumeName, path: volumePath))
        }
        switch fileErrno {
        case ENOENT, ENOTDIR:
            return .absent
        default:
            return .unavailable("\(url.path) cannot be reached right now (\(String(cString: strerror(fileErrno)))) — try Put Back again once it can")
        }
    }

    /// Retry the put-back of every STRANDED row (settled, file still in
    /// the quarantine folder the plan names) — the move home and nothing
    /// else: only the file this run put there (recorded stamp; size when
    /// the crash beat the save), only onto a free original path, the
    /// folder removed only if empty. A row whose folder no longer holds
    /// the file (moved by hand) is closed with a note — but ONLY when its
    /// absence is established on a mounted, reachable drive (codex 1619
    /// #2): with the drive disconnected the file still exists on it, and
    /// the obligation is kept, the row named, the plan still offered. The
    /// row's status is untouched — recovery is not a verdict. Synchronous:
    /// a handful of stats and renames (codex 1606 #3). `stillStranded`
    /// counts every row still owed, `unavailable` those among them the
    /// drive could not answer for.
    @discardableResult
    nonisolated static func putBackStranded(in plan: inout DeleteDuplicatesPlan,
                                            log: (String) -> Void) -> (restored: Int, stillStranded: Int, unavailable: Int) {
        var restored = 0
        var stillStranded = 0
        var unavailable = 0
        for entry in plan.entries where entry.needsRecovery {
            guard let url = entry.quarantinedFileURL else { continue }
            switch strandedPresence(of: url, volumePath: plan.volumePath, volumeName: plan.volumeName) {
            case .present:
                break
            case .absent:
                let note = "no longer in \(url.deletingLastPathComponent().lastPathComponent) — nothing to put back"
                plan.markRecovered(entry.id, note: note)
                log("  \(entry.filename): \(note) (moved by hand?)")
                continue
            case .unavailable(let why):
                stillStranded += 1
                unavailable += 1
                log("  \(entry.filename) is still owed a put-back to \(entry.path) — \(why)")
                continue
            }
            switch restoreQuarantined(url, to: entry.path, expectedStamp: entry.quarantinedStamp,
                                      expectedSize: entry.sizeBytes) {
            case .success(let directoryRemoved):
                restored += 1
                let note = "put back at \(entry.path)"
                plan.markRecovered(entry.id, note: note)
                log("  Put back \(entry.filename) at \(entry.path) from quarantine"
                    + (directoryRemoved ? "" : " (the quarantine folder was not empty and was left in place)"))
            case .failure(let error):
                stillStranded += 1
                log("  \(entry.filename) is still in quarantine at \(url.path) — not put back: \(error.description)")
            }
        }
        return (restored, stillStranded, unavailable)
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

    /// Holds while a pause is requested. The paused state (nothing in
    /// flight) is entered here when the request arrived between pairs,
    /// or by the last pair to settle otherwise.
    private func waitWhilePaused() async {
        while pauseRequested && !stopRequested {
            if inFlight.isEmpty { enterPausedState() }
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
        if finishInFlightForQuit, state == .cancelling, !inFlight.isEmpty {
            subtitleText = "Finishing the current file, then quitting — \(progressText())"
            return
        }
        subtitleText = DeleteDuplicatesRate.subtitle(counts: counts, rate: rate,
                                                     paused: isPausedValue,
                                                     pausing: pauseRequested && !isPausedValue,
                                                     trashVolumes: plan.trashVolumes)
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
        pauseRequested = false
    }

    private func finish(failed message: String) {
        guard state.isActive else { return }
        if state.cancelWasRequested { finishCancelled(); return }
        state = .failed(message: message)
        subtitleText = message
        isIndeterminateValue = false
        isPausedValue = false
        pauseRequested = false
    }

    private func finishCancelled() {
        guard state.isActive else { return }
        state = .cancelled
        subtitleText = "Stopped — \(result.deleted) deleted, the rest left alone"
        isIndeterminateValue = false
        isPausedValue = false
        pauseRequested = false
    }

    private func finishSuspended(remaining: Int, quit: Bool) {
        guard state.isActive else { return }
        state = .cancelled
        subtitleText = quit
            ? "Suspended for quit — \(result.deleted) deleted; \(remaining) remaining will be offered to resume at the next launch"
            : "Stopped — \(result.deleted) deleted; \(remaining) remaining kept for later (Resume in Media File Operations)"
        isIndeterminateValue = false
        isPausedValue = false
        pauseRequested = false
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

    /// The live Delete Duplicates jobs (at most one).
    var activeDeleteDuplicates: [DeleteDuplicatesJob] {
        jobs.compactMap { $0 as? DeleteDuplicatesJob }.filter { $0.state.isActive }
    }

    /// Paused at a safe boundary with the plan saved: quitting needs no
    /// warning for these.
    var quiescentDeleteDuplicates: [DeleteDuplicatesJob] {
        activeDeleteDuplicates.filter { $0.isQuiescentForQuit }
    }

    /// A Delete Duplicates run with a file between "moved" and "settled"
    /// right now — the quit dialog offers to finish it.
    var hasDeleteDuplicatesMidPair: Bool {
        activeDeleteDuplicates.contains { $0.isMidPair }
    }

    /// Quit chose "Finish this file, then quit": Delete Duplicates jobs
    /// land their pair(s) in flight and suspend; every other live job
    /// gets its ordinary `stopForQuit`.
    func finishInFlightThenSuspendForQuit() {
        let active = jobs.filter { $0.state.isActive }
        guard !active.isEmpty else { return }
        deleteDupLog.info("finishInFlightThenSuspendForQuit: \(active.count) running operation(s)")
        for job in active {
            if let delete = job as? DeleteDuplicatesJob {
                delete.finishCurrentFileThenSuspendForQuit()
            } else {
                job.stopForQuit()
            }
        }
    }

    /// Wait (bounded) for every Delete Duplicates job to leave the active
    /// state after `finishInFlightThenSuspendForQuit`. Past the deadline
    /// the pair(s) in flight are put back (`stopForQuit`) and the wait
    /// continues briefly for that. Returns true when all settled in time.
    func waitForDeleteDuplicatesToSettle(deadline: TimeInterval, grace: TimeInterval = 5) async -> Bool {
        let started = Date()
        while !activeDeleteDuplicates.isEmpty, Date().timeIntervalSince(started) < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if activeDeleteDuplicates.isEmpty { return true }
        deleteDupLog.warning("quit: Delete Duplicates did not finish its file within \(deadline)s — revoking finish, putting it back")
        // Revokes "finish this file" and sets the stop flag on each job
        // BEFORE this function next suspends (codex 1606 #2).
        for job in activeDeleteDuplicates { job.stopForQuit() }
        let graceStart = Date()
        while !activeDeleteDuplicates.isEmpty, Date().timeIntervalSince(graceStart) < grace {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        // Log what was OBSERVED, not what was hoped.
        for line in deleteDuplicatesQuitOutcomeLines { deleteDupLog.notice("quit: \(line, privacy: .public)") }
        return false
    }

    /// After `stopAllForQuit` ("Stop now" / "Quit Anyway"): wait, bounded,
    /// for every Delete Duplicates job to put its file back and save its
    /// plan before the process goes away (codex 1606: the branch used to
    /// return `.terminateNow` with the restore still in flight). Returns
    /// true when all settled in time; the observed outcomes are in
    /// `deleteDuplicatesQuitOutcomeLines` either way.
    func waitForDeleteDuplicatesToStop(deadline: TimeInterval) async -> Bool {
        let started = Date()
        while !activeDeleteDuplicates.isEmpty, Date().timeIntervalSince(started) < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return activeDeleteDuplicates.isEmpty
    }

    /// One observed line per Delete Duplicates job a quit interrupted.
    var deleteDuplicatesQuitOutcomeLines: [String] {
        jobs.compactMap { $0 as? DeleteDuplicatesJob }.filter { $0.quitRequested }.map(\.quitOutcomeLine)
    }

    /// The quit dialog's body. A live Delete Duplicates run is suspended,
    /// not abandoned — and the dialog says so (#5). Mid-pair, it also
    /// explains the three choices.
    static func quitInformativeText(running: Int, deleteDuplicatesActive: Bool, midPair: Bool = false) -> String {
        var text = "Quitting now will stop the work in progress. Anything already finished is safe."
        if deleteDuplicatesActive {
            text += "\n\nDelete Duplicates: files already deleted stay deleted; the file being checked is left alone, and the rest of the run is kept and offered to resume at the next launch."
            if midPair {
                text += "\n\n“Finish this file, then quit” lets the file being checked land first (deleted, or put back), then quits. “Stop now” puts it back untouched and quits."
            }
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
