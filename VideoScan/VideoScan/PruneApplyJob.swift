// PruneApplyJob.swift
// "Archived — what next?" → "Move N to Trash" as a Media File Operation
// (Rick 2026-09-20: "the app blocks when post-promote delete of big
// files, can't do anything, must wait"). The checklist's Apply reads
// every duplicate in full before it goes — minutes per file on a tape
// capture — and it used to do that behind the sheet, modally. Rule of the
// app: nothing long runs behind a modal; long work is a Media File
// Operation. So the sheet now hands its plan + the person's checks to
// this job and closes; the job runs the SAME pipeline `applyPrune` runs
// (VideoScanModel+PruneApply: prepare → one copy at a time → finish), one
// file at a time, with Pause/Stop between files, progress by bytes
// verified, every held copy named in the row's detail and in the log,
// and the approval ledger line written at the end with the actual counts.
//
// One file in flight, always. Two would only be safe with both on SSD,
// and the delete-safety rule outranks the speed-up for now — the archive
// copy's evidence is shared across the batch (one read), so the cost per
// copy is one read of the copy itself.
//
// Stop: the file being checked is left where it is ("stopped" — its
// verdict is thrown away), files already moved stay moved, the rest are
// left alone. Quit is the same as Stop (nothing here is half-done: a
// Trash is one atomic move per file, and there is no plan on disk to
// resume). Pause takes effect between files.
//
// Queue, not refuse (Rick 2026-09-22: "blocked UI so you have to wait —
// goes against best practices for UI"). A second batch started while one
// runs used to be refused, and the sheet stayed open until the first
// finished. Now it is QUEUED: its row says "Waiting — starts after …",
// the sheet closes, and batches run strictly one after another, oldest
// first. Nothing about a waiting batch is decided early — its fresh plan,
// the live record re-lookups, the PruneProof and the byte-for-byte reads
// all happen when ITS turn comes, exactly as for a batch started alone. A
// copy the batch before already moved is skipped, named "already moved to
// the Trash by the batch before" — never read, never counted twice. And a
// copy this batch LEFT UNCHECKED that the batch before moved (or that went
// missing / offline while it waited) holds every checked copy in its
// family: the survivors the person confirmed are not all there any more
// (rule 7 in VideoScanModel+PruneApply). Stop on a waiting batch just
// takes it out of the line (nothing was started, so there is nothing to
// put back); Quit does the same. Every batch logs queued / started / done
// (or taken out of the line) with its file count and bytes, to
// videoscan.log, the catalog log, and os_log (Rick-Breen.VideoScan).
//
// (For Rick: the same shape as DeleteDuplicatesJob — an ObservableObject
// the MFO window renders, a Task that runs the loop, a flag the off-main
// reads poll for Stop. ≈ a worker thread with an atomic<bool> stop flag.)

import Combine
import Foundation
import os
import VideoScanCore

private let pruneApplyLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "pruneApply")

/// A Stop flag the off-main reads can poll. `Task.detached` (which the
/// pipeline uses for its whole-file reads) does NOT inherit the job
/// task's cancellation, so the job's Stop must reach the reads by hand.
final class PruneCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

/// The subtitle's numbers — pure, table-testable. Progress is by BYTES
/// verified (a 40 GB tape and a 4 MB clip are not the same step); the
/// ETA is bytes left at the rate so far, counted over unpaused seconds.
struct PruneApplyProgress: Equatable, Sendable {
    var total = 0
    var settled = 0
    var trashed = 0
    var held = 0
    var failed = 0
    var totalBytes: Int64 = 0
    var settledBytes: Int64 = 0
    /// Unpaused seconds spent on the settled files.
    var workSeconds: Double = 0

    var fraction: Double {
        if totalBytes > 0 { return min(1, Double(settledBytes) / Double(totalBytes)) }
        return total > 0 ? min(1, Double(settled) / Double(total)) : 0
    }

    var bytesPerSecond: Double? {
        guard workSeconds > 0, settledBytes > 0 else { return nil }
        return Double(settledBytes) / workSeconds
    }

    /// Seconds left at the rate so far; nil until a file has settled, and
    /// nil once no bytes remain.
    var secondsRemaining: Double? {
        guard settled >= 1, totalBytes > settledBytes, let bps = bytesPerSecond, bps > 0 else { return nil }
        return Double(totalBytes - settledBytes) / bps
    }

    mutating func settle(bytes: Int64, seconds: Double, result: VideoScanModel.PruneCopyResult) {
        settled += 1
        settledBytes += max(0, bytes)
        workSeconds += max(0, seconds)
        switch result {
        case .trashed: trashed += 1
        case .held: held += 1
        case .failed: failed += 1
        case .alreadyMissing, .skippedOffline: break
        }
    }

    /// "verified 3 of 12 · 2 moved to Trash · 1 held · about 4 min left".
    /// Counts first, then only the numbers that exist yet.
    func subtitle(paused: Bool = false, stopping: Bool = false) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        func n(_ v: Int) -> String { f.string(from: NSNumber(value: v)) ?? "\(v)" }
        var parts = ["verified \(n(settled)) of \(n(total))"]
        if trashed > 0 { parts.append("\(n(trashed)) moved to Trash") }
        if held > 0 { parts.append("\(n(held)) held") }
        if failed > 0 { parts.append("\(n(failed)) failed") }
        if stopping {
            parts.append("stopping after this file")
        } else if paused {
            parts.append("paused")
        } else if let eta = secondsRemaining, settled < total {
            parts.append(DeleteDuplicatesRate.etaText(seconds: eta))
        }
        return parts.joined(separator: " · ")
    }
}

@MainActor
final class PruneApplyJob: @MainActor MediaFileOperationJob {

    /// One line of the row's detail: file · size · state · reason.
    struct Row: Identifiable, Equatable, Sendable {
        enum Status: Equatable, Sendable {
            case pending, verifying, trashed, held, failed, alreadyMissing, skippedOffline, stopped
            /// Named by this batch, but the batch before in the queue
            /// already moved it — skipped, never read, never counted twice.
            case movedEarlier
        }
        let id: UUID
        let filename: String
        let path: String
        let sizeBytes: Int64
        var status: Status
        var note: String
    }

    let id = UUID()
    let kind: MediaFileOperationKind = .pruneCopies
    let startedAt = Date()

    /// Row reason for a copy the batch before in the queue already moved.
    static let movedEarlierReason = VideoScanModel.pruneMovedEarlierReason

    /// Bytes of the copies the person checked, as the sheet listed them —
    /// for the queued / started log lines (the done line has the actual).
    let selectedBytes: Int64
    /// When the batch was put in the line (nil = it never waited).
    private(set) var queuedAt: Date?

    /// FIFO order of batches, independent of the window's list order.
    /// (≈ a C++ static member counter; main-actor only, so no atomics.)
    private static var nextSequence = 0
    let sequence: Int

    weak var model: VideoScanModel?
    let shown: PrunePlan
    let selected: Set<UUID>
    let recordIDs: [UUID]
    let options: PrunePlan.Options
    let batchID: String?
    let mode: VideoScanModel.JunkDeletionMode
    let hooks: VideoScanModel.PruneVerifyHooks

    @Published private(set) var rows: [Row] = []
    @Published private(set) var state: MediaFileOperationState = .running {
        didSet { if !state.isActive, finishedAt == nil { finishedAt = Date() } }
    }
    @Published private(set) var finishedAt: Date?
    @Published private(set) var subtitleText = "Working out what may go…"
    @Published private(set) var fractionValue: Double = 0
    @Published private(set) var isIndeterminateValue = true
    @Published private(set) var isPausedValue = false
    private(set) var wasRefused = false

    /// True while this batch waits its turn behind another (nothing has
    /// been read, checked or moved). Cleared the moment it starts.
    @Published private(set) var isQueued = false
    /// Stopped (or quit) while still waiting — nothing was ever started.
    private(set) var droppedWhileQueued = false
    /// Copies the batches before this one in the queue moved — handed
    /// over when this batch starts; skipped with `movedEarlierReason`.
    private(set) var movedEarlier: Set<UUID> = []
    /// Copies THIS batch moved (handed on to the batch after it).
    private(set) var trashedIDs: Set<UUID> = []
    /// Called once the batch has fully settled (its task returned, or it
    /// was dropped while waiting) — the center starts the next in line.
    var onSettled: (() -> Void)?

    /// The tally — the same struct `applyPrune` returns; valid once the
    /// job is terminal (partial while it runs).
    private(set) var outcome = VideoScanModel.PruneApplyOutcome()
    private(set) var progress = PruneApplyProgress()

    /// Internal so tests can `await job.task?.value`.
    private(set) var task: Task<Void, Never>?
    private var pauseWaiter: CheckedContinuation<Void, Never>?
    private let cancelFlag = PruneCancelFlag()

    var title: String {
        let n = rows.isEmpty ? selected.count : rows.count
        return "Move \(n) cop\(n == 1 ? "y" : "ies") to the Trash"
    }
    var subtitle: String { subtitleText }
    var fraction: Double { fractionValue }
    var isIndeterminate: Bool { isIndeterminateValue }
    /// A waiting batch has nothing to pause; it can only be stopped.
    var canPause: Bool { !isQueued }
    var isPaused: Bool { isPausedValue }

    init(model: VideoScanModel, shown: PrunePlan, selected: Set<UUID>, recordIDs: [UUID],
         options: PrunePlan.Options, batchID: String?,
         mode: VideoScanModel.JunkDeletionMode = .toTrash,
         hooks: VideoScanModel.PruneVerifyHooks = .live) {
        self.model = model
        self.shown = shown
        self.selected = selected
        self.recordIDs = recordIDs
        self.options = options
        self.batchID = batchID
        self.mode = mode
        self.hooks = hooks
        Self.nextSequence += 1
        self.sequence = Self.nextSequence
        var bytes: Int64 = 0
        for family in shown.families {
            for row in family.rows where selected.contains(row.id) { bytes += row.copy.sizeBytes }
        }
        self.selectedBytes = bytes
    }

    // MARK: Log lines (pure — pinned by tests)

    /// "2 copies, 83 GB".
    nonisolated static func sizeClause(count: Int, bytes: Int64) -> String {
        "\(count) cop\(count == 1 ? "y" : "ies"), \(MediaBytes.display(bytes))"
    }

    /// videoscan.log, when a batch is put in the line.
    nonisolated static func queuedLine(title: String, count: Int, bytes: Int64, behind: String) -> String {
        "trash copies queued: \(title) — \(sizeClause(count: count, bytes: bytes)) — waits for \(behind); nothing is checked or moved until then"
    }

    /// The START line's plan clause (after "trash copies: <title> — ").
    nonisolated static func startPlan(count: Int, bytes: Int64, waitedSeconds: Double?) -> String {
        var text = "\(sizeClause(count: count, bytes: bytes)) — verify each copy against its archive copy, then move it to the Trash"
        if let w = waitedSeconds { text += " (waited \(Int(w.rounded())) s in line; every copy is checked now, at its turn)" }
        return text
    }

    /// videoscan.log, when a waiting batch is taken out of the line.
    nonisolated static func droppedLine(title: String, count: Int, bytes: Int64, forQuit: Bool) -> String {
        "trash copies taken out of the line\(forQuit ? " (quit)" : ""): \(title) — \(sizeClause(count: count, bytes: bytes)) — nothing was started, nothing to put back"
    }

    /// A cancelled row for a batch that never started is clutter — it
    /// leaves the list (the "trash copies cancelled:" line is still logged).
    var vanishesWhenCancelled: Bool { droppedWhileQueued }

    // MARK: Lifecycle

    /// Idempotent — a second call is a no-op. `onSettled` runs after the
    /// pipeline has fully returned (ledger line written), never before.
    func start() {
        guard task == nil, state.isActive else { return }
        isQueued = false
        isIndeterminateValue = true
        subtitleText = "Working out what may go…"
        task = Task { [weak self] in
            guard let self else { return }
            await self.run()
            self.onSettled?()
        }
    }

    /// Park this batch behind the one running. Its row says what it waits
    /// for; nothing else happens until `start()`.
    func enqueue(behind runningTitle: String, ahead: Int) {
        guard task == nil, state.isActive else { return }
        isQueued = true
        queuedAt = Date()
        // Not a spinner: nothing is happening yet, and the row says so.
        isIndeterminateValue = false
        fractionValue = 0
        setWaitingSubtitle(behind: runningTitle, ahead: ahead)
        let line = Self.queuedLine(title: title, count: selected.count, bytes: selectedBytes, behind: runningTitle)
        appLog.write(line)
        model?.log("Archived — what next?: \(line)")
        pruneApplyLog.notice("prune QUEUED \(self.selected.count, privacy: .public) copies \(self.selectedBytes, privacy: .public) bytes behind=\(runningTitle, privacy: .public)")
    }

    /// "Waiting — starts after Move 2 copies to the Trash" (+ how many
    /// other waiting batches go first). Refreshed by the center when the
    /// line moves.
    func setWaitingSubtitle(behind runningTitle: String, ahead: Int) {
        guard isQueued else { return }
        subtitleText = Self.waitingSubtitle(behind: runningTitle, ahead: ahead)
    }

    nonisolated static func waitingSubtitle(behind runningTitle: String, ahead: Int) -> String {
        var text = "Waiting — starts after \(runningTitle)"
        if ahead > 0 { text += " and \(ahead) more waiting batch\(ahead == 1 ? "" : "es")" }
        return text
    }

    /// Copies the batches before this one moved; handed over at start.
    func inheritMovedEarlier(_ ids: Set<UUID>) {
        guard task == nil else { return }
        movedEarlier.formUnion(ids)
    }

    func refuseToStart(reason: String) {
        guard task == nil, state.isActive else { return }
        wasRefused = true
        finish(failed: reason)
        task = Task {}
    }

    /// Stop: the file being checked is left alone, files already moved
    /// stay moved, the rest are left alone. A WAITING batch is simply
    /// taken out of the line — nothing was started, nothing is touched.
    func cancel() { cancel(forQuit: false) }

    private func cancel(forQuit: Bool) {
        guard state.isActive else { return }
        if isQueued, task == nil {
            let line = Self.droppedLine(title: title, count: selected.count, bytes: selectedBytes, forQuit: forQuit)
            appLog.write(line)
            model?.log("Archived — what next?: \(line)")
            pruneApplyLog.notice("prune DROPPED-WHILE-QUEUED \(self.selected.count, privacy: .public) copies quit=\(forQuit, privacy: .public)")
            droppedWhileQueued = true
            isQueued = false
            state = .cancelled
            subtitleText = "Taken out of the line — nothing was started"
            isIndeterminateValue = false
            onSettled?()
            return
        }
        state = .cancelling
        cancelFlag.set()
        subtitleText = progress.subtitle(paused: false, stopping: true)
        task?.cancel()
        wakeIfPaused()
    }

    /// Quit = Stop. Nothing here is half-done (one atomic move per file)
    /// and there is no plan on disk to resume, so a suspension would be
    /// a cancel with a longer name.
    func stopForQuit() { cancel(forQuit: true) }

    /// Pause takes effect BETWEEN files: the file being checked is
    /// finished (or held) first, nothing is half-done.
    func pause() {
        guard state == .running, !isPausedValue, !isQueued else { return }
        isPausedValue = true
        publishProgress()
        model?.log("Archived — what next?: paused — will stop after the current file.")
    }

    func resume() {
        guard isPausedValue else { return }
        isPausedValue = false
        model?.log("Archived — what next?: resumed.")
        publishProgress()
        wakeIfPaused()
    }

    private func wakeIfPaused() {
        pauseWaiter?.resume()
        pauseWaiter = nil
    }

    private var stopRequested: Bool { state.cancelWasRequested || cancelFlag.isSet }

    private func waitWhilePaused() async {
        while isPausedValue && !stopRequested {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                pauseWaiter = c
            }
        }
    }

    // MARK: Run

    private func run() async {
        guard let model else { finish(failed: "The catalog went away before the job started."); return }
        guard !model.isReadOnly else {
            wasRefused = true
            finish(failed: "Read-only viewer — nothing is moved from here.")
            return
        }
        // Stopped in the instant between its turn coming and the task
        // running (a quit's stop-all): nothing to do, nothing touched.
        if stopRequested { finishCancelled(); return }
        let n = selected.count
        model.log("\nArchived — what next?: Trashing \(n) cop\(n == 1 ? "y" : "ies") in Media File Operations — each is checked byte-for-byte against the archive first.")
        pruneApplyLog.notice("prune BEGIN \(n, privacy: .public) checked copies \(self.selectedBytes, privacy: .public) bytes inherited-moved=\(self.movedEarlier.count, privacy: .public)")

        // The fresh plan and every per-copy check happen HERE, at this
        // batch's turn — never when it was queued.
        let prepared = await model.preparePrune(shown: shown, selected: selected, recordIDs: recordIDs,
                                                options: options, movedEarlier: movedEarlier)
        outcome.held = prepared.held.map(\.line)
        outcome.movedByEarlierBatch = prepared.movedEarlier.count
        rows = prepared.movedEarlier.map { Row(id: $0.copyID, filename: $0.filename, path: "", sizeBytes: $0.sizeBytes,
                                               status: .movedEarlier, note: $0.reason) }
            + prepared.held.map { Row(id: $0.copyID, filename: $0.filename, path: "", sizeBytes: $0.sizeBytes,
                                       status: .held, note: $0.reason) }
            + prepared.items.map { Row(id: $0.copyID, filename: $0.filename, path: $0.path, sizeBytes: $0.sizeBytes,
                                       status: .pending, note: "") }
        progress.total = prepared.items.count
        progress.totalBytes = prepared.items.reduce(0) { $0 + $1.sizeBytes }
        isIndeterminateValue = false
        publishProgress()
        guard !prepared.items.isEmpty else {
            model.log("Archived — what next?: " + outcome.summary)
            if stopRequested { finishCancelled() } else { finish(success: outcome.summary) }
            return
        }

        // The pipeline's reads poll the job's Stop flag as well as the
        // caller's hook (tests).
        var jobHooks = hooks
        let flag = cancelFlag
        let outer = hooks.shouldCancel
        jobHooks.shouldCancel = { flag.isSet || outer() }

        let batch = VideoScanModel.PruneBatchState()
        var trashedRecords: [VideoRecord] = []
        for (i, item) in prepared.items.enumerated() {
            await waitWhilePaused()
            if stopRequested {
                markStopped(from: i, items: prepared.items)
                break
            }
            setRow(item.copyID, status: .verifying, note: "")
            let started = Date()
            let one = await model.pruneOneCopy(item, batch: batch, mode: mode, hooks: jobHooks)
            outcome.absorb(one, item: item)
            if case .trashed = one.result {
                trashedIDs.insert(item.copyID)
                if let rec = model.record(forID: item.copyID) { trashedRecords.append(rec) }
            }
            switch one.result {
            case .trashed:          setRow(item.copyID, status: .trashed, note: one.readInFull ? "byte-identical to the archive copy" : (item.kind.isVersion ? "a version — on provenance" : "trusted on its promotion stamp"))
            case .held(let why):    setRow(item.copyID, status: .held, note: why)
                                    model.log("Archived — what next?: held back \(item.filename) — \(why)")
            case .failed(let why):  setRow(item.copyID, status: .failed, note: why)
            case .alreadyMissing:   setRow(item.copyID, status: .alreadyMissing, note: "already gone")
            case .skippedOffline:   setRow(item.copyID, status: .skippedOffline, note: "drive not connected")
            }
            progress.settle(bytes: item.sizeBytes, seconds: -started.timeIntervalSinceNow, result: one.result)
            publishProgress()
        }

        outcome.overrideCount = model.finishPrune(fresh: prepared.fresh, trashed: trashedRecords, batchID: batchID, mode: mode)
        model.log("Archived — what next?: " + outcome.summary)
        pruneApplyLog.notice("prune DONE trashed=\(self.outcome.trashed, privacy: .public) bytes=\(self.outcome.trashedBytes, privacy: .public) movedEarlier=\(self.outcome.movedByEarlierBatch, privacy: .public) held=\(self.outcome.held.count, privacy: .public) failed=\(self.outcome.failed.count, privacy: .public) stopped=\(self.stopRequested, privacy: .public)")
        if stopRequested { finishCancelled() } else { finish(success: outcome.summary) }
    }

    private func setRow(_ id: UUID, status: Row.Status, note: String) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].status = status
        rows[i].note = note
    }

    private func markStopped(from index: Int, items: [VideoScanModel.PruneItem]) {
        for item in items[index...] { setRow(item.copyID, status: .stopped, note: "stopped — left alone") }
        let left = items.count - index
        model?.log("Archived — what next?: stopped — \(left) cop\(left == 1 ? "y" : "ies") left alone.")
    }

    private func publishProgress() {
        fractionValue = progress.fraction
        subtitleText = progress.subtitle(paused: isPausedValue, stopping: state.cancelWasRequested)
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
        subtitleText = "Stopped — \(outcome.trashed) moved to Trash, the rest left alone"
        isIndeterminateValue = false
        isPausedValue = false
    }
}

// MARK: - Center hook

extension MediaFileOperationsCenter {

    /// Start "Move N to Trash" as an MFO job (the sheet's confirmation
    /// button). One at a time — two batches could name the same copy — but
    /// a second request while one runs is QUEUED, not refused (Rick
    /// 2026-09-22): it waits in its row, the sheet closes, and it starts
    /// when the batch before settles, re-checking every copy then.
    /// `mode` is `.toTrash` from the sheet; tests pass `.permanent` so
    /// fixtures never reach the real Trash (and `hooks` to act mid-batch).
    @discardableResult
    func startPruneApply(shown: PrunePlan, selected: Set<UUID>, recordIDs: [UUID],
                         options: PrunePlan.Options, batchID: String?,
                         model: VideoScanModel,
                         mode: VideoScanModel.JunkDeletionMode = .toTrash,
                         hooks: VideoScanModel.PruneVerifyHooks = .live) -> PruneApplyJob {
        let job = PruneApplyJob(model: model, shown: shown, selected: selected, recordIDs: recordIDs,
                                options: options, batchID: batchID, mode: mode, hooks: hooks)
        guard add(job) else { return job }
        // Weak captures ≈ non-owning raw pointers that read nil once the
        // object is gone — the center owns the job, not the other way round.
        job.onSettled = { [weak self, weak job] in
            guard let self, let job else { return }
            self.pruneApplyDidSettle(job)
        }
        let others = pruneApplyJobs.filter { $0.id != job.id && $0.state.isActive }
        guard !others.isEmpty else {
            beginPruneApply(job)
            return job
        }
        let ahead = queuedPruneApplies.filter { $0.id != job.id }.count
        job.enqueue(behind: runningPruneApply?.title ?? "the batch before", ahead: ahead)
        // Defensive: waiting batches but nothing running can only mean a
        // hand-off was missed — start the oldest now rather than stall.
        startNextPruneApplyIfIdle(inheriting: [])
        return job
    }

    /// Every "Move to Trash" job in the list.
    private var pruneApplyJobs: [PruneApplyJob] {
        jobs.compactMap { $0 as? PruneApplyJob }
    }

    /// The batch actually working (started, still active) — at most one.
    var runningPruneApply: PruneApplyJob? {
        pruneApplyJobs.first { $0.state.isActive && !$0.isQueued }
    }

    /// Waiting batches, oldest first (FIFO).
    var queuedPruneApplies: [PruneApplyJob] {
        pruneApplyJobs.filter { $0.state.isActive && $0.isQueued }.sorted { $0.sequence < $1.sequence }
    }

    private func beginPruneApply(_ job: PruneApplyJob) {
        let waited = job.queuedAt.map { Date().timeIntervalSince($0) }
        job.start()
        appLog.write(Self.startSummaryLine(verb: job.kind.logVerb, title: job.title,
                                           plan: PruneApplyJob.startPlan(count: job.selected.count, bytes: job.selectedBytes,
                                                                         waitedSeconds: waited)))
    }

    /// A batch settled (finished, stopped, or dropped while waiting): hand
    /// what the chain has moved so far to the next in line and start it.
    private func pruneApplyDidSettle(_ job: PruneApplyJob) {
        startNextPruneApplyIfIdle(inheriting: job.movedEarlier.union(job.trashedIDs))
    }

    private func startNextPruneApplyIfIdle(inheriting moved: Set<UUID>) {
        defer { refreshPruneQueueSubtitles() }
        guard runningPruneApply == nil, let next = queuedPruneApplies.first else { return }
        next.inheritMovedEarlier(moved)
        beginPruneApply(next)
    }

    private func refreshPruneQueueSubtitles() {
        guard let running = runningPruneApply else { return }
        for (i, waiting) in queuedPruneApplies.enumerated() {
            waiting.setWaitingSubtitle(behind: running.title, ahead: i)
        }
    }

    /// True while a "Move to Trash" batch is live (working or waiting).
    var hasActivePruneApply: Bool {
        jobs.contains { $0.state.isActive && $0 is PruneApplyJob }
    }

    /// The quit path, after `stopAllForQuit()`: wait (bounded) for a live
    /// "Move to Trash" job to settle. Stop cancels the reads through the
    /// job's flag, so what remains is at most ONE detached trashItem that
    /// was already past its guard — and its purgedAt stamp + ledger line
    /// land only when the job's task returns (QA 2026-09-20 MINOR: a
    /// terminateNow right after Stop lost both). Waiting batches were
    /// dropped by the stop (terminal at once), so this waits only for the
    /// one that was running. Returns whether it settled within `deadline`.
    func waitForPruneApplyToSettle(deadline: TimeInterval) async -> Bool {
        let started = Date()
        while hasActivePruneApply, Date().timeIntervalSince(started) < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return !hasActivePruneApply
    }
}
