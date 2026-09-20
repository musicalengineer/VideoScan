// ArchiveAngelJob.swift
// Archive Angel — Stage 1 as an MFO job (docs/archive_angel_design.md §3–§5).
//
// Consider N candidates → prepare each one's companions in the buffer →
// stop for review. The plan (`plan.json` in the batch folder) is saved
// after every step, so a quit or crash leaves a recoverable batch.
//
// Guardrails (codex #1239 / my #1240):
//   • identity is captured per entry (contentHash / size / mtime) for
//     Promote's re-check;
//   • a companion counts as DONE only when its sub-job finished AND the
//     file exists with size > 0 — partial outputs are never counted;
//   • cancel stops the current sub-job and leaves what was prepared
//     as `.ready`, the rest `.pending`, plan status `.preparing`.
//
// Cancel vs skip (Rick 2026-09-13): `cancel()` ends the JOB — sub-job and
// task both cancelled, the batch settles. `skip(entryID:)` ends ONE ROW —
// only that row's sub-job is cancelled, the row becomes `.skipped`, its
// partial companions are deleted, and the loop carries on with the next
// entry. The job's state is never touched by a skip.
//
// Originals are never copied here. Every media-writing step is an
// existing job (Verify Audio, Balance Audio, Transcode) launched through
// the Center with the buffer as its output — nothing new touches ffmpeg.

import Combine
import Foundation
import OSLog
import VideoScanCore

private let angelLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "archiveAngel")

@MainActor
final class ArchiveAngelJob: @MainActor MediaFileOperationJob {

    let id = UUID()
    let kind: MediaFileOperationKind = .archiveAngel
    let startedAt = Date()

    weak var model: VideoScanModel?
    weak var center: MediaFileOperationsCenter?

    let bufferRoot: URL
    let requestedCount: Int
    let makeLossless: Bool
    /// "Prepare with Archive Angel" from the catalog (Rick 2026-09-11):
    /// exactly these records, no pick. The hard floor still applies —
    /// a 40-second clip is refused with its reason, never silently — but
    /// nothing else is ranked or dropped.
    let explicitRecordIDs: [UUID]?

    /// The batch plan — rewritten (and saved) after every step.
    @Published private(set) var plan: ArchiveAngelPlan

    @Published private(set) var state: MediaFileOperationState = .running {
        didSet { if !state.isActive, finishedAt == nil { finishedAt = Date() } }
    }
    @Published private(set) var finishedAt: Date?
    @Published private(set) var subtitleText = "Walking the catalog…"
    @Published private(set) var fractionValue: Double = 0
    @Published private(set) var isIndeterminateValue = true
    private(set) var wasRefused = false

    /// Internal so tests can `await job.task?.value`.
    private(set) var task: Task<Void, Never>?
    /// The Verify / Balance / Transcode job currently running for an
    /// entry — cancelled together with this job, and cancelled ALONE when
    /// that one entry is skipped.
    private var currentSubJob: (any MediaFileOperationJob)?
    /// The entry the preparation loop is holding right now (nil between
    /// entries). `skip(entryID:)` uses it to tell "this is the live one,
    /// the loop will clean up after me" from "nobody is holding it, I clean
    /// up myself".
    private(set) var preparingEntryID: UUID?

    var title: String {
        explicitRecordIDs == nil
            ? "Archive Angel — consider \(requestedCount)"
            : "Archive Angel — prepare \(requestedCount) selected"
    }
    var subtitle: String { subtitleText }
    var fraction: Double { fractionValue }
    var isIndeterminate: Bool { isIndeterminateValue }

    init(model: VideoScanModel, center: MediaFileOperationsCenter,
         count: Int, makeLossless: Bool, bufferRoot: URL,
         explicitRecordIDs: [UUID]? = nil) {
        self.model = model
        self.center = center
        let wanted = max(1, explicitRecordIDs?.count ?? count)
        self.requestedCount = wanted
        self.makeLossless = makeLossless
        self.bufferRoot = bufferRoot
        self.explicitRecordIDs = explicitRecordIDs
        let dir = ArchiveAngelPlanStore.newBatchDir(bufferRoot: bufferRoot)
        self.plan = ArchiveAngelPlan(batchDir: dir, requestedCount: wanted, makeLossless: makeLossless)
    }

    /// The catalog's "Prepare with Archive Angel": every requested record
    /// that clears the hard floor becomes a pick, best score first; the
    /// rest are counted by reason so the finish line can say why. Rows
    /// already in a prepared batch are refused as such. Pure.
    ///
    /// Deliberately NOT run through `markDerivatives` (codex #1345): the
    /// user chose these rows, so a "_balanced" export they picked on
    /// purpose is not displaced by a same-folder original they did not
    /// pick. The HARD floors still apply, and since the projection's
    /// `archivedCopyExists` now follows provenance, an explicitly
    /// selected version of something archived is refused as
    /// `.duplicateArchived` — the same answer the to-do view gives by
    /// hiding it (the catalog's Prepare item pre-filters on
    /// `pfNotYetArchived`, so such a row normally never reaches here).
    nonisolated static func explicitSelection(
        ids: [UUID], inFlight: Set<UUID>, now: Date = Date(),
        project: (UUID) -> ArchiveAngelCandidate?
    ) -> ArchiveAngelSelection {
        var picks: [ArchiveAngelPick] = []
        var rejected: [ArchiveAngelRejection: Int] = [:]
        var seen = Set<UUID>()
        for id in ids where seen.insert(id).inserted {
            guard var candidate = project(id) else { continue }
            if inFlight.contains(id) { rejected[.inAnotherBatch, default: 0] += 1; continue }
            // The person chose this row: attention memory (resting,
            // fatigue) does not apply to an explicit pick.
            candidate.attention = .none
            candidate.familySkips = 0
            switch ArchiveAngelScorer.verdict(candidate, now: now) {
            case .eligible(let score, let evidence):
                picks.append(.init(candidate: candidate, score: score, evidence: evidence))
            case .rejected(let reason):
                rejected[reason, default: 0] += 1
            }
        }
        picks.sort { $0.score > $1.score }
        return ArchiveAngelSelection(picks: picks, overflow: 0, rejected: rejected)
    }

    // MARK: Lifecycle

    /// Why this job must not start (nil = go). Mirrors Promote's gates.
    func preflight(model: VideoScanModel) -> String? {
        if model.isReadOnly {
            return "This catalog is open read-only — Archive Angel cannot prepare files here."
        }
        if model.masterArchive == nil {
            return "No Master Archive is designated yet — initialize one first (Archive tab)."
        }
        return nil
    }

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

    /// STOP THE WHOLE JOB. Cancels the live sub-job AND this job's task, so
    /// `stopRequested` turns true, the loop breaks and the batch settles
    /// (`finishCancelled`). Contrast `skip(entryID:)`, which cancels only
    /// the sub-job and leaves the job running.
    func cancel() {
        guard state.isActive else { return }
        state = .cancelling
        subtitleText = "Cancelling — prepared candidates stay reviewable…"
        currentSubJob?.cancel()
        task?.cancel()
    }

    private var stopRequested: Bool { state.cancelWasRequested || Task.isCancelled }
    /// A plan.json write failed: the job is already `.failed` with the
    /// reason, and nothing after it may run or report success (audit #5).
    private var planSaveFailed = false
    /// Orders this job's plan.json saves (ArchiveAngelPlanWriter).
    private var saveGeneration: UInt64 = 0
    /// When the current preparation step began (set by prepare's progress()).
    private var stepStartedAt: Date?
    private func nextSaveGeneration() -> UInt64 { saveGeneration += 1; return saveGeneration }

    // MARK: Skip one entry (Rick 2026-09-13: "just skip this file for this
    // batch is fine. skip.")
    //
    // A skip is NOT a cancel. Nothing here touches `state` or `task`, so
    // `stopRequested` stays false: the batch keeps running and moves to the
    // next entry. The only thing cancelled is the sub-job of the row being
    // skipped. The decision lives in the plan (`EntryStatus.skipped`),
    // which is saved immediately, so it survives a quit and a settle.
    //
    // Scope: THIS batch only. No disposition, tag or catalog field is
    // written — a later batch may propose the file again.

    /// The detached half of the last non-live skip or the cancel settle
    /// (removal → plan save → companion reconciliation). Internal so
    /// tests can await it; production never needs to.
    private(set) var cleanupTask: Task<Void, Never>?

    /// Skip `id` for this batch. Valid from `.pending`, `.preparing` and
    /// `.ready`; anything else (already promoted, failed or skipped) is
    /// refused and returns false. Once the job is over, only a row still
    /// WAITING for buffer space may be skipped (codex review 2026-09-20
    /// #11): it never needed the job, and the batch it sits in is the one
    /// on disk.
    @discardableResult
    func skip(entryID id: UUID, now: Date = Date()) -> Bool {
        guard state.isActive else { return skipAfterFinish(entryID: id, now: now) }
        // The transition itself lives on the plan (pure, unit-tested); the
        // job only does the side effects.
        guard let (idx, before) = plan.skipEntry(id: id, now: now, note: Self.skipNoteMaker(for: plan, id: id)) else { return false }
        let filename = plan.entries[idx].filename
        note("Archive Angel: you skipped \(filename) — out of this batch (it was \(before.rawValue)); "
             + "nothing was written to the catalog record; the Angel remembers the pass (ledger) and "
             + "will rank it lower next time")
        // Phase 1 attention memory: the pass is a ledger line, not a
        // catalog field — the scorer reads it back as fatigue.
        model?.ledgerAngelAttention(.angelSkipped, recordIDs: [id], batchID: plan.batchID, reason: "skip", at: now)

        if preparingEntryID == id {
            // The live one. Stop ONLY its sub-job; the loop notices the
            // `.skipped` status when the sub-job unwinds, deletes the
            // partial companions and continues with the next entry. The
            // buffer folder must NOT be deleted here — ffmpeg may still
            // have the file open.
            currentSubJob?.cancel()
            subtitleText = "Skipping \(filename)…"
        } else {
            // Nobody is holding it: reclaim its buffer space and persist
            // the decision now. Both hops are off the main actor. Its
            // catalogued companions are retired AFTER the removal, and
            // only when their files are confirmed gone (codex #1572;
            // review 2026-09-20 #4).
            let snapshot = plan
            let entry = plan.entries[idx]
            let generation = nextSaveGeneration()
            cleanupTask = Task.detached(priority: .utility) { [weak self] in
                ArchiveAngelPlanStore.removeEntryFolder(snapshot, entry: entry)
                do { try await Self.savePlanOffMain(snapshot, generation: generation) } catch {
                    appLog.write("Archive Angel: could not save the skip of \(entry.filename) — \(error.localizedDescription)")
                }
                await MainActor.run {
                    self?.model?.forgetArchiveAngelCompanions(of: [entry], in: snapshot, reason: "skipped by you", at: now)
                }
            }
        }
        return true
    }

    /// A row parked for buffer space reads "waiting", never "failed".
    private static func skipNoteMaker(for plan: ArchiveAngelPlan, id: UUID)
    -> (ArchiveAngelPlan.EntryStatus, Date) -> String {
        let wasWaiting = plan.entries.first(where: { $0.id == id })?.isBufferShort == true
        return { was, when in
            if wasWaiting {
                return Self.skipNote(was: .pending, at: when)
                    .replacingOccurrences(of: "while it was pending", with: "while it was waiting for buffer space")
            }
            return Self.skipNote(was: was, at: when)
        }
    }

    /// Skip after the job finished or was cancelled (#11): the batch on
    /// disk is the truth now — it may have been promoted or cleared from
    /// the Archive tab since — so it is reloaded, the row must still be
    /// waiting for buffer space there, and the batch must be `.ready` and
    /// not in another job's hands. The transition, the save and the
    /// ledger line all still happen; there is no sub-job to cancel and no
    /// folder to reclaim (a waiting row never wrote one).
    private func skipAfterFinish(entryID id: UUID, now: Date) -> Bool {
        let filename = plan.entries.first(where: { $0.id == id })?.filename ?? id.uuidString
        guard !ArchiveAngelLiveBatches.isLive(plan.batchDir) else {
            note("Archive Angel: can't skip \(filename) — a job in this app is working on the batch"); return false
        }
        var fresh: ArchiveAngelPlan
        do { fresh = try ArchiveAngelPlanStore.load(batchDir: plan.batchDir) } catch {
            note("Archive Angel: can't skip \(filename) — the batch's plan.json can't be read (\(error.localizedDescription))")
            return false
        }
        guard fresh.status == .ready else {
            note("Archive Angel: can't skip \(filename) — the batch is \(fresh.status.rawValue) now, not open for decisions")
            return false
        }
        guard let current = fresh.entries.first(where: { $0.id == id }), current.isBufferShort else {
            note("Archive Angel: can't skip \(filename) — the job is over and the row is not waiting for buffer space; decide it in the review")
            return false
        }
        guard fresh.skipEntry(id: id, now: now, note: Self.skipNoteMaker(for: fresh, id: id)) != nil else { return false }
        plan = fresh   // the published copy follows the disk
        note("Archive Angel: you skipped \(filename) — out of this batch (it was waiting for buffer space); "
             + "nothing was written to the catalog record; the Angel remembers the pass (ledger) and "
             + "will rank it lower next time")
        model?.ledgerAngelAttention(.angelSkipped, recordIDs: [id], batchID: fresh.batchID, reason: "skip", at: now)
        let generation = nextSaveGeneration()
        let snapshot = fresh
        cleanupTask = Task.detached(priority: .utility) {
            do { try await Self.savePlanOffMain(snapshot, generation: generation) } catch {
                appLog.write("Archive Angel: could not save the skip of \(filename) — \(error.localizedDescription)")
            }
        }
        return true
    }

    nonisolated static func skipNote(was: ArchiveAngelPlan.EntryStatus, at when: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        let where_ = was == .ready ? "after it was prepared" : "while it was \(was.rawValue)"
        return "Skipped by you at \(f.string(from: when)) \(where_) — not in this batch"
    }

    /// True once the user has skipped the entry the loop is working on.
    private func wasSkipped(_ idx: Int) -> Bool {
        plan.entries.indices.contains(idx) && plan.entries[idx].status == .skipped
    }

    private let skipStepNote = "You skipped this file — this step was stopped"

    // MARK: Run

    private func run() async {
        guard let model else { finish(failed: "Catalog went away."); return }
        // Live for the whole run, whatever the exit (audit #4): the hour
        // rule must never settle or delete a batch this app is working on.
        let liveDir = plan.batchDir
        ArchiveAngelLiveBatches.begin(liveDir)
        defer { ArchiveAngelLiveBatches.end(liveDir) }
        settleStrandedPromotions(model: model)

        // ── Stage 1a: pick from FRESH evidence (phase 2 sweep) or walk.
        let policy = model.duplicateKeeperPolicy()
        note("Archive Angel: want \(requestedCount), lossless \(makeLossless ? "on" : "off"), buffer \(plan.batchDir)")
        let selection: ArchiveAngelSelection
        let consideredCount: Int
        // Rows already in another batch (preparing / ready / promoting) are
        // not picked again — a second "10" brings the NEXT ten.
        let root = bufferRoot
        let inFlight = await Task.detached(priority: .utility) {
            ArchiveAngelPlanStore.inFlightRecordIDs(bufferRoot: root)
        }.value
        if !inFlight.isEmpty { note("Archive Angel: \(inFlight.count) record(s) already in a prepared batch — skipping them") }
        if let ids = explicitRecordIDs {
            selection = Self.explicitSelection(
                ids: ids, inFlight: inFlight,
                project: { id in model.record(forID: id).map { ArchiveAngelCandidate.project($0, model: model, policy: policy) } })
            consideredCount = ids.count
            note("Archive Angel: preparing \(selection.picks.count) of \(ids.count) selected record(s)")
        } else if let fromEvidence = Self.selectFromEvidence(
            store: model.archiveAngelStore, count: requestedCount, now: Date(), excluding: inFlight,
            attentionChangedAt: model.archiveAngelAttention.lastEventAt,
            project: { id in model.record(forID: id).map { ArchiveAngelCandidate.project($0, model: model, policy: policy) } }) {
            selection = fromEvidence.selection
            consideredCount = model.archiveAngelStore.consideredCount
            let age = max(0, Int(Date().timeIntervalSince(fromEvidence.computedAt) / 60))
            note("Archive Angel: picked from evidence computed \(age) min ago")
        } else {
            // The walk (main actor, in the job's task — never a view body).
            let active = pfActiveRecords(model.records)
            note("Archive Angel: assessing \(active.count) records")
            var candidates: [ArchiveAngelCandidate] = []
            candidates.reserveCapacity(active.count)
            for (i, r) in active.enumerated() {
                candidates.append(ArchiveAngelCandidate.project(r, model: model, policy: policy))
                // O(records) on the main actor: yield every 500 so the UI keeps
                // painting on an 18k-record catalog (no beachball, GH #104 class).
                if i % 500 == 499 {
                    subtitleText = "Considering \(i + 1) of \(active.count) records…"
                    await Task.yield()
                    if stopRequested { finishCancelled(); return }
                }
            }
            if stopRequested { finishCancelled(); return }
            ArchiveAngelScorer.markDerivatives(&candidates)   // T10 H3: same rule as the sweep
            ArchiveAngelScorer.applyFamilyAttention(&candidates)   // Phase 1: same rule as the sweep

            // Spotlight play history for the eligible ones only, off-main.
            let eligiblePaths = candidates.filter { ArchiveAngelScorer.hardFloor($0) == nil }.map(\.fullPath)
            subtitleText = "Reading play history for \(eligiblePaths.count) eligible files…"
            let readings = await Self.readPlayHistoryOffMain(paths: eligiblePaths)
            for i in candidates.indices {
                if let r = readings[candidates[i].fullPath] {
                    candidates[i].useCount = r.useCount
                    candidates[i].lastUsed = r.lastUsed
                }
            }
            if stopRequested { finishCancelled(); return }
            let skipped = candidates.filter { inFlight.contains($0.id) }.count
            var walked = ArchiveAngelScorer.select(candidates.filter { !inFlight.contains($0.id) }, count: requestedCount)
            if skipped > 0 { walked.rejected[.inAnotherBatch, default: 0] += skipped }
            selection = walked
            consideredCount = candidates.count
        }
        plan.consideredCount = consideredCount
        plan.rejected = Dictionary(uniqueKeysWithValues: selection.rejected.map { ($0.key.rawValue, $0.value) })
        plan.overflow = selection.overflow

        // ── Plan entries.
        var entries: [ArchiveAngelPlan.Entry] = []
        for pick in selection.picks {
            guard let rec = model.record(forID: pick.candidate.id) else { continue }
            let facts = ArchivePathResolver.facts(for: rec)
            let people = rec.confirmedByUserPeople.map(\.name) + rec.detectedPeople
            entries.append(.init(
                id: rec.id,
                sourcePath: rec.fullPath,
                filename: rec.filename,
                sizeBytes: rec.sizeBytes,
                sourceContentHash: rec.contentHash,
                sourceModifiedAt: rec.dateModifiedRaw,
                durationSeconds: rec.durationSeconds,
                score: pick.score,
                evidence: pick.evidence,
                proposedName: ArchiveAngelNaming.proposedName(facts: facts, people: people, tags: rec.tags),
                proposedDate: ArchiveAngelNaming.proposedDate(fromFilenamePrefix: facts.dateHint.filenamePrefix)))
        }
        plan.entries = entries
        plan.startedAt = Date()
        // Phase 1 attention memory: every row shown is a ledger line; a
        // later batch ranks it lower and reserves slots for files never shown.
        model.ledgerAngelAttention(.angelProposed, recordIDs: entries.map(\.id), batchID: plan.batchID,
                                   scores: Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.score) }))
        for (n, pick) in selection.picks.enumerated() {
            let why = pick.evidence.prefix(3).map(\.line).joined(separator: " · ")
            note("Archive Angel pick \(n + 1)/\(entries.count) [\(pick.score)] \(pick.candidate.filename) — \(why)")
        }
        let walkLine = "Archive Angel: considered \(consideredCount), \(entries.count) picked, "
            + "\(selection.rejectedTotal) rejected, \(selection.overflow) more would qualify"
        note(walkLine)   // every job line through note(): all four logs (audit P2)

        if entries.isEmpty {
            plan.status = .ready
            plan.finishedAt = Date()
            _ = await savePlan()
            finish(success: "Nothing to recommend — " + topRejections(selection.rejected))
            return
        }
        guard await savePlan() else { return }

        await prepareEntries(model: model)

        if planSaveFailed { return }   // failed with its reason; never "N ready"
        if stopRequested { _ = await savePlan(); finishCancelled(); return }

        plan.status = .ready
        plan.finishedAt = Date()
        let ready = plan.readyCount
        // "7 ready to review · 3 skipped · 412 rejected · 18 more would
        // qualify" — the skips are the user's own, counted apart from
        // rejections and never folded into failures. Noted BEFORE the
        // final save so plan.json carries its own summary (codex #1572).
        let summary = "\(ready) ready to review\(plan.skippedClause)\(plan.bufferShortClause) · \(plan.rejectedTotal) rejected · \(plan.overflow) more would qualify"
        note("Archive Angel: " + summary)
        _ = await savePlan()
        finish(success: summary)
    }

    /// Stage 1b: preparation, one entry at a time. Split out of run() so
    /// each stage stays readable (and under the lint bar); it stops on a
    /// stop request or a failed plan save, and run() decides the ending.
    private func prepareEntries(model: VideoScanModel) async {
        isIndeterminateValue = false
        let total = plan.entries.count
        for idx in plan.entries.indices {
            if stopRequested || planSaveFailed { break }
            // Only unsettled rows are prepared: a resumed batch's `.ready`
            // rows, and any row the user skipped before the loop reached
            // it, are passed over.
            switch plan.entries[idx].loopAction {
            case .passOver: continue            // resumed-ready, promoted, failed
            case .reclaimBuffer:                // skipped before the loop arrived
                _ = await settleSkip(idx, total: total)
                continue
            case .prepare: break                // `break` leaves the switch, not the for
            }
            let entry = plan.entries[idx]

            // Free-space precheck (design §5), per FILE (2026-09-19): one
            // file too big for the buffer used to `break` the whole batch
            // silently. It is left for a later batch with the numbers on
            // its row, and the loop tries the next — smaller files fit.
            let need = ArchiveAngelPlan.bufferNeed(sizeBytes: entry.sizeBytes, lossless: makeLossless)
            let free = await Self.freeBytesOffMain(at: bufferRoot)
            if let short = ArchiveAngelPlan.bufferShortNote(need: need, free: free) {
                // A skip that landed during the probe wins: the user's
                // decision is never overwritten by a verdict.
                if await settleSkip(idx, total: total) { continue }
                plan.entries[idx].status = .failed
                plan.entries[idx].failure = short
                let line = "Archive Angel [\(idx + 1)/\(total)] \(entry.filename) — " + short
                note(line)
                _ = await savePlan()
                continue
            }

            let sourceExists = await Self.fileExistsOffMain(entry.sourcePath)
            // A skip that landed during the two probes above wins: a user's
            // decision is never overwritten by a failure verdict.
            if await settleSkip(idx, total: total) { continue }
            let rec = model.record(forID: entry.id)
            if let reason = Self.unpreparableReason(recordPresent: rec != nil, sourceExists: sourceExists,
                                                    sourcePath: entry.sourcePath) {
                // Named and logged (audit P2): this used to fail silently,
                // and said "missing" for a record that had been removed.
                plan.entries[idx].status = .failed
                plan.entries[idx].failure = reason
                note("Archive Angel [\(idx + 1)/\(total)] \(entry.filename) — not prepared: \(reason)")
                _ = await savePlan()
                continue
            }
            guard let rec else { continue }
            plan.entries[idx].status = .preparing
            preparingEntryID = entry.id
            _ = await savePlan()
            note("Archive Angel [\(idx + 1)/\(total)] \(entry.filename) — preparing (\(ByteCountFormatter.string(fromByteCount: entry.sizeBytes, countStyle: .file)), score \(entry.score))")

            let entryDir = URL(fileURLWithPath: plan.batchDir).appendingPathComponent(entry.id.uuidString, isDirectory: true)
            await Self.ensureDirectoryOffMain(entryDir)
            // The user may have pressed Skip during those two hops.
            if await settleSkip(idx, total: total) { continue }

            await prepare(index: idx, record: rec, entryDir: entryDir, position: idx + 1, total: total)
            preparingEntryID = nil
            // Skipped while preparing: clean up its partial companions and
            // go on. The batch is NOT cancelled — `stopRequested` is false.
            if await settleSkip(idx, total: total) { continue }
            if stopRequested { break }

            // Never a false green (2026-09-19): "ready" only when every step
            // ran to a verdict. A preparation that returned early — its
            // operations center gone, or any future early exit — used to
            // leave four pending steps under a "ready" row.
            if let unfinished = Self.unfinishedStepReason(plan.entries[idx]) {
                plan.entries[idx].status = .failed
                plan.entries[idx].failure = unfinished
                note("Archive Angel [\(idx + 1)/\(total)] \(entry.filename) — not ready: \(unfinished)")
                _ = await savePlan()
                continue
            }
            plan.entries[idx].status = .ready
            let made = plan.entries[idx].companionsMade.map { $0.kind.label.lowercased() }
            note("Archive Angel [\(idx + 1)/\(total)] \(entry.filename) — ready to review"
                 + (made.isEmpty ? " (original only)" : " with " + made.joined(separator: ", ")))
            fractionValue = Double(idx + 1) / Double(total)
            _ = await savePlan()
        }
    }

    /// A promote a quit left `.promoting` must not reserve its rows from
    /// this batch (audit #3).
    private func settleStrandedPromotions(model: VideoScanModel) {
        for line in ArchiveAngelPromoter.settleStrandedPromotions(bufferRoot: bufferRoot, model: model) { note(line) }
    }

    /// The loop's half of a skip: the row is already `.skipped` in the plan
    /// (the button did that), so here we only reclaim the buffer and save.
    /// Returns true when the caller should move to the next entry.
    private func settleSkip(_ idx: Int, total: Int) async -> Bool {
        guard wasSkipped(idx) else { return false }
        preparingEntryID = nil
        let entry = plan.entries[idx]
        await Self.removeEntryFolderOffMain(plan, entry: entry)
        model?.forgetArchiveAngelCompanions(of: [entry], in: plan, reason: "skipped by you")
        fractionValue = Double(idx + 1) / Double(total)
        note("Archive Angel [\(idx + 1)/\(total)] \(entry.filename) — skipped by you; "
             + "its partial companions were removed from the buffer, the batch continues")
        _ = await savePlan()
        return true
    }

    // MARK: Preparation of one entry

    private func prepare(index idx: Int, record rec: VideoRecord, entryDir: URL, position: Int, total: Int) async {
        guard let model, let center else {
            note("Archive Angel [\(position)/\(total)] \(rec.filename) — cannot prepare: the operations center or catalog went away")
            return
        }
        let stem = (rec.filename as NSString).deletingPathExtension
        func progress(_ step: String, _ n: Int) {
            stepStartedAt = Date()   // every step's clock starts with its progress line
            subtitleText = "\(position) of \(total) — \(rec.filename): \(step)"
            fractionValue = (Double(position - 1) + Double(n) / 4.0) / Double(total)
        }

        // a. Verify audio
        progress("verifying audio", 0)
        var diagnosis: AudioVerifyDiagnosis?
        if rec.streamType == .videoOnly {
            step(idx, .verifyAudio, .skipped, note: "No audio track")
        } else if !rec.audioVerifyStatus.isEmpty, let cached = center.verifyDiagnosis(forRecordID: rec.id) {
            // Only with the diagnosis in hand (audit #6): it lives in an
            // in-memory cache, so after a restart it is gone and the file
            // is verified again below rather than assumed fine.
            step(idx, .verifyAudio, .skipped, note: "Already verified: \(rec.audioVerifyStatus)")
            diagnosis = cached
        } else if let vj = center.startVerifyAudio(record: rec, model: model) {
            currentSubJob = vj
            await vj.task?.value
            currentSubJob = nil
            if wasSkipped(idx) {
                step(idx, .verifyAudio, .skipped, note: skipStepNote)
            } else if let d = vj.diagnosis {
                diagnosis = d
                step(idx, .verifyAudio, .done, note: HelperAudioOutcome.from(d).headline)
            } else if case .failed(let m) = vj.state {
                step(idx, .verifyAudio, .failed, note: m)
            } else {
                step(idx, .verifyAudio, .skipped, note: "Verify did not finish")
            }
        } else {
            step(idx, .verifyAudio, .skipped, note: "A verify job for this file is already running")
        }
        _ = await savePlan()
        if stopRequested || wasSkipped(idx) { return }

        // b. Balanced audio — only on a fixable problem.
        progress("balancing audio", 1)
        var balancedRecord: VideoRecord?
        if let d = diagnosis, let analysis = d.balanceAnalysis {
            if let reason = BalanceAudioFix.refusalReason(for: analysis) {
                step(idx, .balanceAudio, .skipped, note: reason)
            } else {
                let ext = BalanceAudioFix.balancedOutputURL(forSourcePath: rec.fullPath,
                                                            containerFormat: analysis.shape.containerFormat,
                                                            fileExists: { _ in false }).pathExtension
                let planned = entryDir.appendingPathComponent("\(stem)_balanced.\(ext)")
                await Self.removeIfPresentOffMain(planned)
                if let bj = center.startBalanceAudio(record: rec, fromDiagnosis: d, model: model, plannedOutput: planned) {
                    currentSubJob = bj
                    await bj.task?.value
                    currentSubJob = nil
                    if wasSkipped(idx) {
                        step(idx, .balanceAudio, .skipped, note: skipStepNote)
                    } else if case .finished = bj.state, let out = bj.publishedURL,
                       await Self.fileSizeOffMain(out) > 0 {
                        let companion = model.records.first { $0.fullPath == out.path }
                        balancedRecord = companion
                        step(idx, .balanceAudio, .done, note: "Audio balanced (\(analysis.classification.rawValue))",
                                              output: Self.relPath(out, in: plan.batchDir))
                        if let i = plan.entries[idx].steps.firstIndex(where: { $0.kind == .balanceAudio }) {
                            plan.entries[idx].steps[i].recordID = companion?.id
                        }
                    } else if case .failed(let m) = bj.state {
                        step(idx, .balanceAudio, .failed, note: "Balance failed: \(m)")
                    } else {
                        step(idx, .balanceAudio, .failed, note: "Balance did not finish")
                    }
                } else {
                    step(idx, .balanceAudio, .skipped, note: "A balance job for this file is already running")
                }
            }
        } else {
            step(idx, .balanceAudio, .skipped,
                 note: Self.balanceSkipNote(hasDiagnosis: diagnosis != nil, videoOnly: rec.streamType == .videoOnly))
        }
        _ = await savePlan()
        if stopRequested || wasSkipped(idx) { return }

        // c. Access copy — always; from the balanced companion when there is one.
        progress("access copy", 2)
        let accessSource = balancedRecord ?? rec
        let accessOut = entryDir.appendingPathComponent("\(stem).vs.archive.mov")
        await Self.removeIfPresentOffMain(accessOut)
        await runTranscode(index: idx, kind: .accessCopy, record: accessSource, preset: .archival,
                           outputURL: accessOut, model: model, center: center,
                           doneNote: balancedRecord == nil ? "HEVC access copy" : "HEVC access copy (from balanced audio)")
        _ = await savePlan()
        if stopRequested || wasSkipped(idx) { return }

        // d. Lossless — only when enabled AND the format is at risk.
        progress("lossless copy", 3)
        let readiness = ArchiveReadiness.assess(record: rec)
        if !makeLossless {
            step(idx, .losslessCopy, .skipped, note: "Lossless off (alpha default)")
        } else if case .atRisk = readiness.format {
            let out = entryDir.appendingPathComponent("\(stem).vs.preserve.mkv")
            await Self.removeIfPresentOffMain(out)
            await runTranscode(index: idx, kind: .losslessCopy, record: rec, preset: .preservation,
                               outputURL: out, model: model, center: center, doneNote: "FFV1 preservation copy")
        } else {
            let codec = rec.videoCodec.isEmpty ? "the" : rec.videoCodec
            step(idx, .losslessCopy, .skipped, note: "Lossless copy not needed — \(codec) original is the preservation master")
        }
        _ = await savePlan()
    }

    private func runTranscode(index idx: Int, kind: ArchiveAngelPlan.StepKind, record: VideoRecord,
                              preset: TranscodePreset, outputURL: URL,
                              model: VideoScanModel, center: MediaFileOperationsCenter,
                              doneNote: String) async {
        let startedAt = Date()
        note("Archive Angel [\(idx + 1)/\(plan.entries.count)] \(plan.entries[idx].filename) — "
             + "\(kind.label.lowercased()): starting \(preset.rawValue) → \(outputURL.lastPathComponent)")
        let tj = center.startTranscode(record: record, preset: preset, outputURL: outputURL, model: model)
        currentSubJob = tj
        await tj.task?.value
        currentSubJob = nil
        if wasSkipped(idx) {
            // The user skipped this file mid-transcode: record the step as
            // SKIPPED. A partial output is irrelevant — the whole entry
            // folder is about to be deleted.
            step(idx, kind, .skipped, note: skipStepNote)
            return
        }
        let outBytes = await Self.fileSizeOffMain(tj.outputURL)
        if case .finished = tj.state, outBytes > 0 {
            let companion = model.records.first { $0.fullPath == tj.outputURL.path }
            step(idx, kind, .done, note: doneNote, output: Self.relPath(tj.outputURL, in: plan.batchDir),
                 startedAt: startedAt, outputBytes: outBytes)
            if let i = plan.entries[idx].steps.firstIndex(where: { $0.kind == kind }) {
                plan.entries[idx].steps[i].recordID = companion?.id
            }
        } else if case .failed(let m) = tj.state {
            step(idx, kind, .failed, note: "\(kind.label) failed: \(m) — original will still be promoted")
        } else if stopRequested {
            step(idx, kind, .failed, note: "\(kind.label) cancelled")
        } else {
            step(idx, kind, .failed, note: "\(kind.label) did not finish — original will still be promoted")
        }
    }

    // MARK: Logging (Rick 2026-09-09: "good logging around archival steps")
    //
    // Every step outcome goes to FOUR places: the app console (model.log),
    // the file log (appLog), OSLog category "archiveAngel", and plan.log so
    // the batch folder tells its own story. Format:
    //   Archive Angel [3/25] 1993_CapeCod.mov — access copy: done — HEVC access copy (41.2 s, 812 MB)

    /// The job's ONE log verb: the console (model), videoscan.log (appLog),
    /// the unified log, and the batch's own plan log — so a line is never in
    /// one place and missing from the others (the buffer-full stop of
    /// 2026-09-19 was only in catalog.log).
    private func note(_ line: String) {
        model?.log(line)
        appLog.write(line)
        angelLog.info("\(line, privacy: .public)")
        plan.log.append(line)
    }

    private func step(_ idx: Int, _ kind: ArchiveAngelPlan.StepKind, _ state: ArchiveAngelPlan.StepState,
                      note text: String, output: String? = nil, startedAt: Date? = nil, outputBytes: Int64 = 0) {
        plan.entries[idx].set(kind, state, note: text, output: output)   // step-helper
        var extra: [String] = []
        if let started = startedAt ?? stepStartedAt {
            let seconds = Date().timeIntervalSince(started)
            if let i = plan.entries[idx].steps.firstIndex(where: { $0.kind == kind }) {
                plan.entries[idx].steps[i].seconds = seconds
            }
            extra.append(String(format: "%.1f s", seconds))
        }
        if outputBytes > 0 { extra.append(ByteCountFormatter.string(fromByteCount: outputBytes, countStyle: .file)) }
        let tail = extra.isEmpty ? "" : " (" + extra.joined(separator: ", ") + ")"
        note("Archive Angel [\(idx + 1)/\(plan.entries.count)] \(plan.entries[idx].filename) — "
             + "\(kind.label.lowercased()): \(state.rawValue) — \(text)\(tail)")
    }

    // MARK: Plan persistence

    /// Save the plan; on failure the job fails (a batch nobody can review
    /// is not a batch). Returns false when it failed.
    /// Why an entry whose preparation returned is NOT ready: a step that
    /// never reached a verdict. Nil when every step is done, skipped or
    /// failed (a failed companion still leaves the original promotable).
    nonisolated static func unfinishedStepReason(_ entry: ArchiveAngelPlan.Entry) -> String? {
        guard let step = entry.steps.first(where: { $0.state == .pending }) else { return nil }
        return "preparation stopped before \(ArchiveAngelStepPresentation.columnTitle(step.kind)) ran — nothing was checked or made after that; prepare it again in a later batch."
    }

    /// Why a picked file cannot be prepared at all, or nil when it can.
    nonisolated static func unpreparableReason(recordPresent: Bool, sourceExists: Bool, sourcePath: String) -> String? {
        if !recordPresent { return "its catalog record was removed after it was picked — nothing to prepare." }
        if !sourceExists {
            return "the source file isn't at \(sourcePath) any more (moved, renamed, or its drive disconnected) — cannot promote."
        }
        return nil
    }

    /// Why the balance step did not run, when there was nothing to balance
    /// or nothing to go on (audit #6, 2026-09-19): "Audio OK" only when a
    /// verify said so — a failed, unfinished or missing verify is never
    /// reported as a clean bill of health.
    nonisolated static func balanceSkipNote(hasDiagnosis: Bool, videoOnly: Bool) -> String {
        if videoOnly { return "No audio track" }
        return hasDiagnosis ? "Audio OK — nothing to fix"
            : "Not balanced — there's no audio check result for this file"
    }

    private func savePlan() async -> Bool {
        do {
            try await Self.savePlanOffMain(plan, generation: nextSaveGeneration())
            return true
        } catch {
            // Audit #5: every later step used to ignore this, keep
            // transcoding, and end with finish(success:) over a stale
            // plan.json. The loop stops at the next file and success can
            // no longer overwrite the failure.
            planSaveFailed = true
            finish(failed: "Could not write plan.json in \(plan.batchDir): \(error.localizedDescription)")
            return false
        }
    }

    private func topRejections(_ rejected: [ArchiveAngelRejection: Int]) -> String {
        let top = rejected.sorted { $0.value > $1.value }.prefix(3)
        if top.isEmpty { return "no unarchived videos found" }
        return top.map { "\($0.value) \($0.key.rawValue.lowercased())" }.joined(separator: ", ")
    }

    private static func relPath(_ url: URL, in batchDir: String) -> String {
        let base = URL(fileURLWithPath: batchDir, isDirectory: true).standardizedFileURL.path + "/"
        let p = url.standardizedFileURL.path
        return p.hasPrefix(base) ? String(p.dropFirst(base.count)) : p
    }

    // MARK: Finish

    private func finish(success: String) {
        guard !planSaveFailed else { return }
        state = .finished(summary: success)
        subtitleText = success
        fractionValue = 1
        isIndeterminateValue = false
    }

    private func finish(failed: String) {
        if state.cancelWasRequested { finishCancelled(); return }
        state = .failed(message: failed)
        subtitleText = failed
        isIndeterminateValue = false
        angelLog.warning("archive angel failed: \(failed, privacy: .public)")
    }

    private func finishCancelled() {
        // GH #177: settle the batch so it is either reviewable (ready rows
        // kept, the rest marked failed) or gone (nothing prepared) — never a
        // `preparing` ghost that hides from the Archive tab and reserves
        // its rows from later batches.
        let unfinished = plan.entries.filter { $0.status.isUnsettled }
        let kept = plan.settleAfterInterruption(reason: "Cancelled before it was prepared")
        let settled = plan
        let generation = nextSaveGeneration()
        let root = bufferRoot   // the delete guard: only <root>/batch-… may go
        // The files below go; their catalog records go AFTER them, and
        // only for files confirmed gone (codex #1572; review 2026-09-20 #4).
        cleanupTask = Task.detached(priority: .utility) { [weak self] in
            do { try await Self.savePlanOffMain(settled, generation: generation) } catch {
                appLog.write("Archive Angel: could not save the cancelled batch — \(error.localizedDescription)")
            }
            if kept { ArchiveAngelPlanStore.reclaimUnfinished(settled, unfinished: unfinished) }
            if !kept {
                do { try ArchiveAngelPlanStore.removeBatchFolder(settled, bufferRoot: root) } catch {
                    appLog.write("Archive Angel: could not remove the cancelled batch's folder — \(error.localizedDescription)")
                }
            }
            await MainActor.run {
                guard let model = self?.model else { return }
                if kept {
                    model.forgetArchiveAngelCompanions(of: unfinished, in: settled, reason: "cancelled before the row was prepared")
                } else {
                    model.forgetArchiveAngelCompanions(batchDir: settled.batchDir, reason: "cancelled — nothing was prepared, batch discarded")
                }
            }
        }
        state = .cancelled
        subtitleText = kept
            ? "Cancelled — \(plan.readyCount) prepared candidates stay reviewable"
            : "Cancelled — nothing was prepared; the batch was discarded"
        isIndeterminateValue = false
    }

    // MARK: Off-main hops
    //
    // `@concurrent`: a bare `nonisolated async` runs on the CALLER's actor
    // (the trap that has bitten this repo 3×).

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func readPlayHistoryOffMain(paths: [String]) async -> [String: ArchiveAngelPlayHistory.Reading] {
        var out: [String: ArchiveAngelPlayHistory.Reading] = [:]
        out.reserveCapacity(paths.count)
        for p in paths {
            if Task.isCancelled { break }
            let r = ArchiveAngelPlayHistory.reading(forPath: p)
            if r.useCount > 0 || r.lastUsed != nil { out[p] = r }
        }
        return out
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func savePlanOffMain(_ plan: ArchiveAngelPlan, generation: UInt64) async throws {
        try await ArchiveAngelPlanWriter.shared.write(plan, generation: generation)
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func freeBytesOffMain(at url: URL) async -> Int64 {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return ArchiveAngelPlanStore.freeBytes(at: url)
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func ensureDirectoryOffMain(_ url: URL) async {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func removeIfPresentOffMain(_ url: URL) async {
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Delete one entry's companions from the buffer (skip / cleanup).
    /// Worst case it removes one entry folder — a handful of files, no
    /// recursion beyond it, nothing read into memory.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func removeEntryFolderOffMain(_ plan: ArchiveAngelPlan,
                                                     entry: ArchiveAngelPlan.Entry) async {
        ArchiveAngelPlanStore.removeEntryFolder(plan, entry: entry)
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func fileExistsOffMain(_ path: String) async -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func fileSizeOffMain(_ url: URL) async -> Int64 {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }
}
