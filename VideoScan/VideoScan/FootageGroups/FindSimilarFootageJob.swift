// FindSimilarFootageJob.swift
// "Find Similar Footage" as a Media File Operation (Rick 2026-09-23:
// "walks the catalog and records in metadata which files are probably the
// same footage … allow me to review media more quickly and stop seeing the
// same old videos over and over").
//
// Phases, each reported honestly on the row:
//   1. Reading catalog metadata      main actor, one pass      (≈5%)
//   2. Checking stored digests       @concurrent, stat only    (≈5%)
//   3. Linking evidence              @concurrent               (≈40%)
//   4. Forming groups + ranking      @concurrent               (≈20%)
//   5. Recording groups in catalog   main actor, unit-aligned slices (≈30%)
// Pause takes effect at the next phase boundary or apply slice (each phase
// is well under a second on the real catalog); Stop likewise — records
// already written keep their answers (they are complete answers, and the
// next run rewrites any that change). The per-run summary goes to the
// console, the MFO row, and videoscan.log (the Center's START/OUTCOME
// lines). No media is read; no file is touched (phase 2 is a `stat`).
//
// ONE RUN AT A TIME, NOTHING DROPPED (codex #1674 F4). A request while a
// run is active is QUEUED behind it (it starts when that run ends), never
// refused. A run notes the person's decision revision when it reads the
// catalog; if an answer ("Not the same" …) arrives before its apply, the
// run DISCARDS its stale result (logged) and queues a fresh run of its own
// scope — a paused run can never write back a group the person rejected.
//
// (For Rick: `@Published` ≈ a member whose setter notifies observers;
// `Task { … }` started from this @MainActor class inherits the main actor,
// which is why the heavy phases are the model's `@concurrent` statics.)

import Combine
import Foundation
import VideoScanCore
import os

private let footageJobLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "findSimilarFootage")

@MainActor
final class FindSimilarFootageJob: @MainActor MediaFileOperationJob {

    let id = UUID()
    let kind: MediaFileOperationKind = .findSimilarFootage
    let startedAt = Date()
    let scope: FootageScope
    private weak var model: VideoScanModel?
    /// Where a follow-up run is queued (nil for a job started directly).
    weak var center: MediaFileOperationsCenter?
    /// The run this one waits for (queued behind it). Released once it ends.
    var predecessor: FindSimilarFootageJob?

    @Published private(set) var state: MediaFileOperationState = .running {
        didSet { if !state.isActive, finishedAt == nil { finishedAt = Date() } }
    }
    @Published private(set) var finishedAt: Date?
    @Published private(set) var subtitleText = "Waiting to start…"
    @Published private(set) var fractionValue: Double = 0
    @Published private(set) var isPausedValue = false
    private(set) var wasRefused = false
    /// True when the person answered while this run was in flight and its
    /// result was thrown away (a fresh run was queued).
    private(set) var discardedStale = false
    /// The fresh run queued by a discard (tests and the log read it).
    private(set) var followUp: FindSimilarFootageJob?
    /// The finished run's numbers (tests and the log read it).
    private(set) var summary: FootageRunSummary?
    /// The run Task — internal so tests can await it.
    private(set) var task: Task<Void, Never>?

    var title: String { "Find Similar Footage — \(scope.title)" }
    var subtitle: String { subtitleText }
    var fraction: Double { fractionValue }
    var isIndeterminate: Bool { false }
    var canPause: Bool { state == .running }
    var isPaused: Bool { isPausedValue }

    init(scope: FootageScope, model: VideoScanModel) {
        self.scope = scope
        self.model = model
    }

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

    func cancel() {
        guard state.isActive else { return }
        state = .cancelling
        isPausedValue = false
        subtitleText = "Stopping — answers already recorded are kept…"
        task?.cancel()
    }

    func pause() {
        guard state == .running, !isPausedValue else { return }
        isPausedValue = true
        subtitleText = "Paused — resumes at the next step"
    }

    func resume() {
        guard isPausedValue else { return }
        isPausedValue = false
        subtitleText = "Resuming…"
    }

    /// Wait out a pause; false when the job was stopped meanwhile.
    private func checkpoint() async -> Bool {
        while isPausedValue && !Task.isCancelled && state == .running {
            try? await Task.sleep(for: .milliseconds(200))
        }
        return !Task.isCancelled && state == .running
    }

    /// Queued: wait until the run ahead ends (polling, so a Stop here is
    /// prompt). False when this job was stopped while waiting.
    private func waitForPredecessor() async -> Bool {
        guard let ahead = predecessor else { return true }
        subtitleText = "Queued — starts when the run in progress ends"
        while ahead.state.isActive, !Task.isCancelled, state == .running {
            try? await Task.sleep(for: .milliseconds(100))
        }
        predecessor = nil
        return !Task.isCancelled && state == .running
    }

    // MARK: Run

    private func run() async {
        guard await waitForPredecessor() else { finish(cancelled: ()); return }
        let t0 = Date()
        guard let model else { finish(failed: "Lost the catalog"); return }
        guard !model.isReadOnly else {
            wasRefused = true
            finish(failed: "The catalog is read-only on this Mac — nothing was changed.")
            return
        }
        let options = FootageGrouping.Options()

        subtitleText = "Reading catalog metadata…"
        let revision = model.footageDecisionRevision
        let snap = model.footageInputsAndProbes()
        fractionValue = 0.05
        guard await checkpoint() else { finish(cancelled: ()); return }

        subtitleText = "Checking \(snap.probes.count.formatted()) stored whole-file digests (stat only)…"
        guard let current = await VideoScanModel.footageCurrentDigests(snap.probes) else {
            finish(cancelled: ()); return
        }
        let inputs = VideoScanModel.markCurrentDigests(snap.inputs, current: current)
        fractionValue = 0.10
        guard await checkpoint() else { finish(cancelled: ()); return }

        subtitleText = "Linking evidence across \(inputs.count.formatted()) records…"
        let (prepared, edges, stats) = await VideoScanModel.footagePrepareAndLink(inputs, options: options)
        fractionValue = 0.50
        guard !stats.cancelled, await checkpoint() else { finish(cancelled: ()); return }

        subtitleText = "Forming groups from \(edges.count.formatted()) links…"
        let result = await VideoScanModel.footageGroup(prepared, edges: edges, options: options,
                                                       stats: stats, now: Date())
        fractionValue = 0.70
        guard !result.stats.cancelled, await checkpoint() else { finish(cancelled: ()); return }

        guard model.footageDecisionRevision == revision else {
            discard(changed: 0, model: model)
            return
        }
        let touched = VideoScanModel.footageTouchedIDs(result: result, inputs: inputs, scope: scope)
        subtitleText = "Recording \(result.stats.groups.formatted()) groups in the catalog…"
        let applied = await model.applyFootage(
            result, touched: touched,
            progress: { [weak self] f in self?.fractionValue = 0.70 + 0.30 * f },
            checkpoint: { [weak self, weak model] in
                guard let self, let model else { return false }
                // A newer answer ends the apply at a unit boundary.
                return await self.checkpoint() && model.footageDecisionRevision == revision
            })
        if model.footageDecisionRevision != revision {
            discard(changed: applied.changed + applied.cleared, model: model)
            return
        }

        var s = Self.summarize(result, touched: touched, scope: scope)
        s.recordsChanged = applied.changed
        s.recordsCleared = applied.cleared
        s.digestsChecked = snap.probes.count
        s.digestsCurrent = current.count
        s.elapsed = Date().timeIntervalSince(t0)
        summary = s
        model.log(s.line)
        footageJobLog.info("\(s.line, privacy: .public)")
        if applied.stopped { finish(cancelled: ()); return }
        finish(success: s.line)
    }

    /// The person answered after this run read the catalog: its result is
    /// stale. Log it, end, and queue a fresh run of the same scope.
    private func discard(changed: Int, model: VideoScanModel) {
        discardedStale = true
        let line = "Find Similar Footage (\(scope.title)): result discarded — you answered while it was running"
            + (changed > 0 ? " (\(changed) record\(changed == 1 ? "" : "s") written before your answer; the fresh run re-answers them)" : "")
            + "; a fresh run is queued"
        model.log(line)
        footageJobLog.info("\(line, privacy: .public)")
        finish(success: "Discarded — you answered while it was running; a fresh run is queued")
        followUp = center?.startFindSimilarFootage(scope: scope, model: model)
    }

    /// The numbers for the groups this scope covers.
    nonisolated static func summarize(_ r: FootageGrouping.Result, touched: Set<UUID>,
                                      scope: FootageScope) -> FootageRunSummary {
        var s = FootageRunSummary(scopeTitle: scope.title)
        for g in r.groups where scope == .catalog || g.memberIDs.contains(where: touched.contains) {
            s.groups += 1
            s.members += g.memberIDs.count
            s.byConfidence[g.confidence, default: 0] += 1
            s.largestGroup = max(s.largestGroup, g.memberIDs.count)
            if !g.originalInCatalog { s.originalNotInCatalog += 1 }
        }
        s.refusedByCap = r.stats.refusedByCap
        s.refusedPossibleChain = r.stats.refusedPossibleChain
        s.refusedByPerson = r.stats.refusedByPerson
        s.refusedByDate = r.stats.refusedByDate
        s.sampledConflicts = r.stats.sampledConflicts
        return s
    }

    // MARK: Finish

    private func finish(success: String) {
        state = .finished(summary: success)
        subtitleText = success
        fractionValue = 1
        isPausedValue = false
    }

    private func finish(failed: String) {
        if state.cancelWasRequested { finish(cancelled: ()); return }
        state = .failed(message: failed)
        subtitleText = failed
        isPausedValue = false
        footageJobLog.warning("find similar footage failed: \(failed, privacy: .public)")
    }

    private func finish(cancelled: Void) {
        state = .cancelled
        subtitleText = "Stopped — answers already recorded are kept"
        isPausedValue = false
    }
}

// MARK: - Starting it

extension MediaFileOperationsCenter {
    /// Start "Find Similar Footage". One run at a time: a request while one
    /// is active is QUEUED behind the newest active run and starts when it
    /// ends (codex #1674 F4 — never refused, never dropped).
    @discardableResult
    func startFindSimilarFootage(scope: FootageScope, model: VideoScanModel) -> FindSimilarFootageJob {
        let job = FindSimilarFootageJob(scope: scope, model: model)
        job.center = self
        // `jobs` is newest-first: the first active one is the tail of the queue.
        let ahead = jobs.first { other in other.state.isActive && other is FindSimilarFootageJob }
            as? FindSimilarFootageJob
        guard add(job) else { return job }
        job.predecessor = ahead
        job.start()
        appLog.write(Self.startSummaryLine(verb: job.kind.logVerb, title: job.title,
                                           plan: ahead == nil ? "catalog metadata only — no media read"
                                                              : "queued behind the run in progress — catalog metadata only"))
        return job
    }
}
