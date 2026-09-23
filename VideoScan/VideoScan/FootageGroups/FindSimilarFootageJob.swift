// FindSimilarFootageJob.swift
// "Find Similar Footage" as a Media File Operation (Rick 2026-09-23:
// "walks the catalog and records in metadata which files are probably the
// same footage … allow me to review media more quickly and stop seeing the
// same old videos over and over").
//
// Phases, each reported honestly on the row:
//   1. Reading catalog metadata      main actor, one pass      (≈5%)
//   2. Linking evidence              @concurrent               (≈45%)
//   3. Forming groups + ranking      @concurrent               (≈20%)
//   4. Recording groups in catalog   main actor, 2,000-record slices (≈30%)
// Pause takes effect at the next phase boundary or apply slice (each phase
// is well under a second on the real catalog); Stop likewise — records
// already written keep their answers (they are complete answers, and the
// next run rewrites any that change). The per-run summary goes to the
// console, the MFO row, and videoscan.log (the Center's START/OUTCOME
// lines). No media is read; no file is touched.
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

    @Published private(set) var state: MediaFileOperationState = .running {
        didSet { if !state.isActive, finishedAt == nil { finishedAt = Date() } }
    }
    @Published private(set) var finishedAt: Date?
    @Published private(set) var subtitleText = "Waiting to start…"
    @Published private(set) var fractionValue: Double = 0
    @Published private(set) var isPausedValue = false
    private(set) var wasRefused = false
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

    // MARK: Run

    private func run() async {
        let t0 = Date()
        guard let model else { finish(failed: "Lost the catalog"); return }
        guard !model.isReadOnly else {
            wasRefused = true
            finish(failed: "The catalog is read-only on this Mac — nothing was changed.")
            return
        }
        let options = FootageGrouping.Options()

        subtitleText = "Reading catalog metadata…"
        let inputs = model.footageInputs()
        fractionValue = 0.05
        guard await checkpoint() else { finish(cancelled: ()); return }

        subtitleText = "Linking evidence across \(inputs.count.formatted()) records…"
        let (prepared, edges, stats) = await VideoScanModel.footagePrepareAndLink(inputs, options: options)
        fractionValue = 0.50
        guard await checkpoint() else { finish(cancelled: ()); return }

        subtitleText = "Forming groups from \(edges.count.formatted()) links…"
        let result = await VideoScanModel.footageGroup(prepared, edges: edges, options: options,
                                                       stats: stats, now: Date())
        fractionValue = 0.70
        guard await checkpoint() else { finish(cancelled: ()); return }

        let touched = VideoScanModel.footageTouchedIDs(result: result, inputs: inputs, scope: scope)
        subtitleText = "Recording \(result.stats.groups.formatted()) groups in the catalog…"
        let applied = await model.applyFootage(result, touched: touched,
                                               progress: { [weak self] f in self?.fractionValue = 0.70 + 0.30 * f },
                                               checkpoint: { [weak self] in await self?.checkpoint() ?? false })

        var s = Self.summarize(result, touched: touched, scope: scope)
        s.recordsChanged = applied.changed
        s.recordsCleared = applied.cleared
        s.elapsed = Date().timeIntervalSince(t0)
        summary = s
        model.log(s.line)
        footageJobLog.info("\(s.line, privacy: .public)")
        if applied.stopped { finish(cancelled: ()); return }
        finish(success: s.line)
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
    /// Start "Find Similar Footage". One run at a time: a second request
    /// while one is active is parked as refused (never silently dropped).
    @discardableResult
    func startFindSimilarFootage(scope: FootageScope, model: VideoScanModel) -> FindSimilarFootageJob {
        let job = FindSimilarFootageJob(scope: scope, model: model)
        guard add(job) else { return job }
        let duplicate = jobs.contains { other in
            other.id != job.id && other.state.isActive && other is FindSimilarFootageJob
        }
        if duplicate {
            job.refuseToStart(reason: "Find Similar Footage is already running — let it finish or stop it first. Nothing was started.")
            return job
        }
        job.start()
        appLog.write(Self.startSummaryLine(verb: job.kind.logVerb, title: job.title,
                                           plan: "catalog metadata only — no media read"))
        return job
    }
}
