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
    var canPause: Bool { true }
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

    /// Stop: the file being checked is left alone, files already moved
    /// stay moved, the rest are left alone.
    func cancel() {
        guard state.isActive else { return }
        state = .cancelling
        cancelFlag.set()
        subtitleText = progress.subtitle(paused: false, stopping: true)
        task?.cancel()
        wakeIfPaused()
    }

    /// Quit = Stop. Nothing here is half-done (one atomic move per file)
    /// and there is no plan on disk to resume, so a suspension would be
    /// a cancel with a longer name.
    func stopForQuit() { cancel() }

    /// Pause takes effect BETWEEN files: the file being checked is
    /// finished (or held) first, nothing is half-done.
    func pause() {
        guard state == .running, !isPausedValue else { return }
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
        let n = selected.count
        model.log("\nArchived — what next?: Trashing \(n) cop\(n == 1 ? "y" : "ies") in Media File Operations — each is checked byte-for-byte against the archive first.")
        pruneApplyLog.notice("prune BEGIN \(n, privacy: .public) checked copies")

        let prepared = await model.preparePrune(shown: shown, selected: selected, recordIDs: recordIDs, options: options)
        outcome.held = prepared.held.map(\.line)
        rows = prepared.held.map { Row(id: $0.copyID, filename: $0.filename, path: "", sizeBytes: $0.sizeBytes,
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
            if case .trashed = one.result, let rec = model.record(forID: item.copyID) { trashedRecords.append(rec) }
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
        pruneApplyLog.notice("prune DONE trashed=\(self.outcome.trashed, privacy: .public) held=\(self.outcome.held.count, privacy: .public) failed=\(self.outcome.failed.count, privacy: .public) stopped=\(self.stopRequested, privacy: .public)")
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
    /// button). One at a time: a second request while one runs is parked
    /// as refused with the reason — two batches could name the same copy.
    /// `mode` is `.toTrash` from the sheet; tests pass `.permanent` so
    /// fixtures never reach the real Trash.
    @discardableResult
    func startPruneApply(shown: PrunePlan, selected: Set<UUID>, recordIDs: [UUID],
                         options: PrunePlan.Options, batchID: String?,
                         model: VideoScanModel,
                         mode: VideoScanModel.JunkDeletionMode = .toTrash) -> PruneApplyJob {
        let job = PruneApplyJob(model: model, shown: shown, selected: selected, recordIDs: recordIDs,
                                options: options, batchID: batchID, mode: mode)
        guard add(job) else { return job }
        let duplicate = jobs.contains { other in
            other.id != job.id && other.state.isActive && other is PruneApplyJob
        }
        if duplicate {
            job.refuseToStart(reason: "An \"Archived — what next?\" batch is already going — let it finish or stop it first. Nothing was started.")
            return job
        }
        job.start()
        appLog.write(Self.startSummaryLine(verb: job.kind.logVerb, title: job.title,
                                           plan: "verify each copy against its archive copy, then move it to the Trash"))
        return job
    }

    /// True while a "Move to Trash" batch is live.
    var hasActivePruneApply: Bool {
        jobs.contains { $0.state.isActive && $0 is PruneApplyJob }
    }

    /// The quit path, after `stopAllForQuit()`: wait (bounded) for a live
    /// "Move to Trash" job to settle. Stop cancels the reads through the
    /// job's flag, so what remains is at most ONE detached trashItem that
    /// was already past its guard — and its purgedAt stamp + ledger line
    /// land only when the job's task returns (QA 2026-09-20 MINOR: a
    /// terminateNow right after Stop lost both). Returns whether it
    /// settled within `deadline`.
    func waitForPruneApplyToSettle(deadline: TimeInterval) async -> Bool {
        let started = Date()
        while hasActivePruneApply, Date().timeIntervalSince(started) < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return !hasActivePruneApply
    }
}
