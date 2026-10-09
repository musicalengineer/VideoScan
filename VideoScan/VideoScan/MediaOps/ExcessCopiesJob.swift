// ExcessCopiesJob.swift
// Triage ▸ CLEAN UP ▸ Excess copies ▸ "Move N copies to Trash" as a Media
// File Operation (CLAUDE.md "Long operations": anything over a minute is an
// MFO job). It runs the same steps as `applyExcess` — prepare (the one plan,
// re-asked now) → one copy at a time through `pruneOneCopy` → the approval
// line — with Pause/Stop between files, progress by bytes read, and every
// copy's result and reason in the row's detail.
//
// One at a time: a second request while one runs is refused, not queued —
// the lane's list is recomputed after each run, so there is nothing to wait
// for. Stop leaves the file being read where it is, keeps what already
// moved, and leaves the rest alone; Quit is the same as Stop (one atomic
// Trash move per file, no plan on disk to resume).
//
// (For Rick: the PruneApplyJob shape — an ObservableObject the MFO window
// renders, a Task running the loop, a lock-guarded flag the off-main reads
// poll for Stop ≈ a worker thread with an atomic<bool>.)

import Combine
import Foundation
import os
import SwiftUI
import VideoScanCore

private let excessJobLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "excessCopies")

@MainActor
final class ExcessCopiesJob: @MainActor MediaFileOperationJob {

    let id = UUID()
    let kind: MediaFileOperationKind = .pruneCopies
    let startedAt = Date()

    weak var model: VideoScanModel?
    /// The plan the confirmation showed — the most this job may ever move.
    let shown: ExcessCopiesPlan
    let env: VideoScanModel.ExcessLaneEnvironment
    let hooks: VideoScanModel.PruneVerifyHooks

    @Published private(set) var rows: [PruneApplyJob.Row] = []
    @Published private(set) var state: MediaFileOperationState = .running {
        didSet { if !state.isActive, finishedAt == nil { finishedAt = Date() } }
    }
    @Published private(set) var finishedAt: Date?
    @Published private(set) var subtitleText = "Working out what may go…"
    @Published private(set) var fractionValue: Double = 0
    @Published private(set) var isIndeterminateValue = true
    @Published private(set) var isPausedValue = false
    private(set) var wasRefused = false

    private(set) var outcome = VideoScanModel.PruneApplyOutcome()
    private(set) var progress = PruneApplyProgress()
    /// Internal so tests can `await job.task?.value`.
    private(set) var task: Task<Void, Never>?
    private var pauseWaiter: CheckedContinuation<Void, Never>?
    private let cancelFlag = PruneCancelFlag()

    var title: String {
        let n = shown.offeredCount
        return "Move \(n) excess cop\(n == 1 ? "y" : "ies") to the Trash"
    }
    var subtitle: String { subtitleText }
    var fraction: Double { fractionValue }
    var isIndeterminate: Bool { isIndeterminateValue }
    var canPause: Bool { true }
    var isPaused: Bool { isPausedValue }

    init(model: VideoScanModel, shown: ExcessCopiesPlan,
         env: VideoScanModel.ExcessLaneEnvironment = .live,
         hooks: VideoScanModel.PruneVerifyHooks = .live) {
        self.model = model
        self.shown = shown
        self.env = env
        self.hooks = hooks
    }

    // MARK: Lifecycle

    func start() {
        guard task == nil, state.isActive else { return }
        task = Task { [weak self] in await self?.run() }
    }

    func refuseToStart(reason: String) {
        guard task == nil, state.isActive else { return }
        wasRefused = true
        finish(failed: reason)
        task = Task {}
    }

    func cancel() {
        guard state.isActive else { return }
        state = .cancelling
        cancelFlag.set()
        subtitleText = progress.subtitle(paused: false, stopping: true)
        task?.cancel()
        wakeIfPaused()
    }

    func pause() {
        guard state == .running, !isPausedValue else { return }
        isPausedValue = true
        publishProgress()
        model?.log("\(VideoScanModel.excessLogPrefix): paused — will stop after the current file.")
    }

    func resume() {
        guard isPausedValue else { return }
        isPausedValue = false
        model?.log("\(VideoScanModel.excessLogPrefix): resumed.")
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
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in pauseWaiter = c }
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
        if stopRequested { finishCancelled(); return }
        model.log("\n" + VideoScanModel.excessStartLine(shown))
        excessJobLog.notice("excess BEGIN \(self.shown.offeredCount, privacy: .public) copies \(self.shown.offeredBytes, privacy: .public) bytes")
        let prepared = await model.prepareExcess(shown: shown, env: env)
        outcome.held = prepared.held.map(\.line)
        rows = prepared.held.map { .init(id: $0.copyID, filename: $0.filename, path: "", sizeBytes: $0.sizeBytes,
                                         status: .held, note: $0.reason) }
            + prepared.items.map { .init(id: $0.copyID, filename: $0.filename, path: $0.path, sizeBytes: $0.sizeBytes,
                                         status: .pending, note: "") }
        progress.total = prepared.items.count
        progress.totalBytes = prepared.items.reduce(0) { $0 + $1.sizeBytes }
        isIndeterminateValue = false
        publishProgress()
        let trashed = await work(prepared.items, model: model)
        model.finishExcess(trashed: trashed, batchID: "excess-\(id.uuidString.prefix(8))")
        model.log("\(VideoScanModel.excessLogPrefix): OUTCOME — " + outcome.summary)
        excessJobLog.notice("excess DONE trashed=\(self.outcome.trashed, privacy: .public) held=\(self.outcome.held.count, privacy: .public) failed=\(self.outcome.failed.count, privacy: .public)")
        if stopRequested { finishCancelled() }
        else if !outcome.failed.isEmpty { finish(failed: "\(outcome.failed.count) could not be moved · " + outcome.summary) }
        else { finish(success: outcome.summary) }
    }

    /// The loop: one file in flight, Stop / Pause between files.
    private func work(_ items: [VideoScanModel.PruneItem], model: VideoScanModel) async -> [VideoRecord] {
        var jobHooks = hooks
        let flag = cancelFlag
        let outer = hooks.shouldCancel
        jobHooks.shouldCancel = { flag.isSet || outer() }
        let batch = VideoScanModel.PruneBatchState()
        var trashed: [VideoRecord] = []
        for (i, item) in items.enumerated() {
            await waitWhilePaused()
            if stopRequested {
                for rest in items[i...] { setRow(rest.copyID, status: .stopped, note: "stopped — left alone") }
                break
            }
            setRow(item.copyID, status: .verifying, note: "")
            let started = Date()
            let one = await model.excessOneCopy(item, batch: batch, env: env, hooks: jobHooks)
            outcome.absorb(one, item: item)
            if case .trashed = one.result, let rec = model.record(forID: item.copyID) { trashed.append(rec) }
            record(one.result, for: item, model: model)
            progress.settle(bytes: item.sizeBytes, seconds: -started.timeIntervalSinceNow, result: one.result)
            publishProgress()
        }
        return trashed
    }

    private func record(_ result: VideoScanModel.PruneCopyResult, for item: VideoScanModel.PruneItem,
                        model: VideoScanModel) {
        switch result {
        case .trashed:            setRow(item.copyID, status: .trashed, note: "byte-identical to the archived file")
        case .held(let why):      setRow(item.copyID, status: .held, note: why)
                                  model.log("\(VideoScanModel.excessLogPrefix): held back \(item.filename) — \(why)")
        case .failed(let why):    setRow(item.copyID, status: .failed, note: why)
                                  model.log("\(VideoScanModel.excessLogPrefix): could not move \(item.filename) — \(why) (it is where it was)")
        case .alreadyMissing:     setRow(item.copyID, status: .alreadyMissing, note: "already gone")
        case .skippedOffline:     setRow(item.copyID, status: .skippedOffline, note: "drive not connected")
        }
    }

    private func setRow(_ id: UUID, status: PruneApplyJob.Row.Status, note: String) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].status = status
        rows[i].note = note
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

// MARK: - Detail (double-click on the row)

struct ExcessCopiesDetailView: View {
    @ObservedObject var job: ExcessCopiesJob

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(job.subtitle).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
            Text("Each copy is read in full and must be byte-identical to its archived file; when it is the last copy outside the archive, the archived file is read in full first. Both are re-checked the instant before the move. Trash only. Anything in doubt is held, and says why.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section(header: PruneApplyTableHeader()) {
                        ForEach(job.rows.prefix(PruneApplyDetailView.visibleCap)) { row in
                            PruneApplyRowView(row: row)
                            Divider()
                        }
                    }
                }
            }
            .frame(maxHeight: 520)
        }
        .padding(14)
        .accessibilityIdentifier("mfo.excessCopies.detail")
    }
}

// MARK: - Center hook

extension MediaFileOperationsCenter {

    /// Start "Move N excess copies to the Trash". Refused while another
    /// excess run is live (the list is recomputed after each run).
    @discardableResult
    func startExcessCopies(shown: ExcessCopiesPlan, model: VideoScanModel,
                           env: VideoScanModel.ExcessLaneEnvironment = .live,
                           hooks: VideoScanModel.PruneVerifyHooks = .live) -> ExcessCopiesJob {
        let job = ExcessCopiesJob(model: model, shown: shown, env: env, hooks: hooks)
        let busy = jobs.contains { $0.state.isActive && $0 is ExcessCopiesJob }
        guard add(job) else { return job }
        if busy {
            job.refuseToStart(reason: "Another excess-copies run is still working — wait for it to finish.")
            return job
        }
        job.start()
        appLog.write(Self.startSummaryLine(verb: job.kind.logVerb, title: job.title,
                                           plan: "\(shown.offeredCount) copies, \(MediaBytes.display(shown.offeredBytes)) — read each in full against its archived file, then move it to the Trash"))
        return job
    }
}
