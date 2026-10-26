// FindMasterJob.swift — Provenance ▸ Find Master (by sound), the MFO JOB.
// Design: docs/design/provenance_retroactive_2026_10_26.md §Phase A.
//
// ONE SENTENCE: open the sound-print sidecar, build the catalog-wide sound
// index off the main actor, ask AudioMasterFinder about each selected file,
// and publish the answers — writing NOTHING but log lines.
//
// Shape: the PairCompareJob/ShowAgainJob pattern — the job owns its results
// (no feature store, no `extension VideoScanModel`, rule 12). The main actor
// orchestrates; each heavy step (open + build, one search) runs in a
// detached task (C++: a worker thread the UI thread awaits).
//
// Pause/Stop: `FindMasterGate` is checked once per sidecar row while the
// index builds (a pause BLOCKS the worker there) and between queries. Stop
// finishes nothing half-way: the OUTCOME says how many were searched and
// how many never started.
//
// Writes: none. No catalog write, no sidecar write, no ledger event. The
// sidecar is opened only if it exists (never created). Log lines go to the
// injected sink (production: catalog.log + videoscan.log + OSLog).
//
// MEMORY: the index while the job runs (≈ 270 MB for today's 27 M landmarks;
// refused past ≈ 867 MB), freed when the run ends (the engine is dropped);
// the answers (a few hundred bytes per found content) stay with the row.

import Combine
import Foundation
import SwiftUI
import VideoScanCore

/// Pause / stop flags shared with the worker thread. (For Rick: a
/// std::condition_variable + two bools behind one mutex.)
final class FindMasterGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var paused = false
    private var stopped = false

    func pause() { condition.withLock { paused = true } }
    func resume() { condition.withLock { paused = false; condition.broadcast() } }
    func stop() { condition.withLock { stopped = true; paused = false; condition.broadcast() } }
    var isPaused: Bool { condition.withLock { paused } }
    var isStopped: Bool { condition.withLock { stopped } }

    /// Worker side: blocks while paused; true when stopped.
    func checkpoint() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while paused && !stopped { condition.wait() }
        return stopped
    }
}

/// The off-main half: the store and the index, built and searched on a
/// worker. Value type; the store is the one connection (its own lock).
struct FindMasterEngine: Sendable {
    let store: AudioFingerprintStore
    let index: AudioCatalogIndex
    let report: AudioCatalogIndex.BuildReport
    let buildSeconds: Double

    static func open(directory: URL, gate: FindMasterGate,
                     progress: @escaping @Sendable (Int, Int) -> Void) throws -> FindMasterEngine {
        let store = try AudioCatalogIndex.openSidecar(directory: directory)
        let clock = ContinuousClock()
        let start = clock.now
        let (index, report) = try AudioCatalogIndex.build(store: store, progress: progress,
                                                          isCancelled: { gate.checkpoint() })
        return FindMasterEngine(store: store, index: index, report: report,
                                buildSeconds: TimingBudget.seconds(clock.now - start))
    }

    /// One query: its print from the sidecar, then the finder. nil = the
    /// sidecar holds no print for the key (the stamp is ahead of it).
    func search(_ key: AudioFingerprintStore.Key) -> AudioMasterSearch? {
        guard let print = try? store.fingerprint(for: key) else { return nil }
        return AudioMasterFinder.find(query: print, queryKey: key, in: index,
                                      load: { try? store.fingerprint(for: $0) })
    }
}

/// One selected file's answer, as the detail view shows it.
struct FindMasterResult: Identifiable, Equatable {
    enum Outcome: Equatable {
        case found([AudioMasterCandidate], searched: Int)
        case noneFound(searched: Int)
        case refused(FindMasterRefusalReason)
    }
    let recordID: UUID
    let name: String
    let outcome: Outcome
    var id: UUID { recordID }
}

@MainActor
final class FindMasterJob: @MainActor MediaFileOperationJob, MediaFileOperationOwnDetail {

    let id = UUID()
    let kind: MediaFileOperationKind = .findMaster
    let startedAt = Date()
    let plan: FindMasterPlan
    let sidecarDirectory: URL
    /// The one log door (tests capture it).
    let note: (String) -> Void
    /// Reveal a record in the Catalog (the detail view's button).
    let reveal: (UUID) -> Void
    let canPause = true

    @Published private(set) var state: MediaFileOperationState = .running {
        didSet { if !state.isActive, finishedAt == nil { finishedAt = Date() } }
    }
    @Published private(set) var finishedAt: Date?
    @Published private(set) var subtitleText = "Starting…"
    @Published private(set) var fractionValue: Double = 0
    @Published private(set) var isIndeterminateValue = true
    @Published private(set) var isPaused = false
    @Published private(set) var results: [FindMasterResult] = []
    @Published private(set) var buildReport: AudioCatalogIndex.BuildReport?
    private(set) var wasRefused = false
    private(set) var tally = FindMasterAnswer.Tally()
    /// Internal so tests can `await job.task?.value`.
    private(set) var task: Task<Void, Never>?
    let gate = FindMasterGate()
    /// Test seam: runs on the main actor after each query's answer lands.
    var afterQuery: ((Int) -> Void)?

    var title: String {
        plan.selectedCount == 1 ? "Find Master — \(plan.queries.first?.name ?? plan.refusals.first?.name ?? "")"
            : "Find Master — \(plan.selectedCount.formatted()) files"
    }
    var subtitle: String { subtitleText }
    var fraction: Double { fractionValue }
    var isIndeterminate: Bool { isIndeterminateValue }
    var detailView: AnyView { AnyView(FindMasterDetailView(job: self)) }

    init(plan: FindMasterPlan, sidecarDirectory: URL, note: @escaping (String) -> Void,
         reveal: @escaping (UUID) -> Void = { _ in }) {
        self.plan = plan
        self.sidecarDirectory = sidecarDirectory
        self.note = note
        self.reveal = reveal
    }

    // MARK: Lifecycle

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    func cancel() {
        guard state.isActive else { return }
        state = .cancelling
        subtitleText = "Stopping…"
        gate.stop()
    }

    func pause() {
        guard state == .running, !isPaused else { return }
        isPaused = true
        gate.pause()
        subtitleText = "Paused — " + subtitleText
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        gate.resume()
        subtitleText = subtitleText.replacingOccurrences(of: "Paused — ", with: "")
    }

    // MARK: Run

    private func run() async {
        let clock = ContinuousClock()
        let begin = clock.now
        note(FindMasterAnswer.startLine(files: plan.selectedCount))
        for r in plan.refusals {
            results.append(FindMasterResult(recordID: r.recordID, name: r.name, outcome: .refused(r.reason)))
            note(FindMasterAnswer.refusalLine(name: r.name, reason: r.reason))
            tally.refused += 1
        }
        guard !plan.queries.isEmpty else { return finish(seconds: TimingBudget.seconds(clock.now - begin)) }
        guard let engine = await openEngine() else { return }
        await searchAll(engine)
        finish(seconds: TimingBudget.seconds(clock.now - begin))
    }

    /// Opens the sidecar and builds the index on a worker. nil = refused,
    /// failed or stopped (the terminal state is already set).
    private func openEngine() async -> FindMasterEngine? {
        subtitleText = "Reading sound prints…"
        let directory = sidecarDirectory, gate = gate
        let progress: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            guard done % 256 == 0 || done == total else { return }
            Task { @MainActor [weak self] in self?.buildTick(done: done, total: total) }
        }
        let opened = await Task.detached(priority: .userInitiated) {
            Result { try FindMasterEngine.open(directory: directory, gate: gate, progress: progress) }
        }.value
        switch opened {
        case .success(let engine):
            buildReport = engine.report
            note(FindMasterAnswer.indexLine(engine.report, seconds: engine.buildSeconds))
            return engine
        case .failure(let error) where error is CancellationError:
            stopBeforeSearching()
            return nil
        case .failure(let error):
            wasRefused = true
            let words = "Refused before reading — \(error)"
            note("OUTCOME find master — " + words)
            tally.notStarted = plan.queries.count
            state = .failed(message: words)
            subtitleText = words
            isIndeterminateValue = false
            return nil
        }
    }

    private func buildTick(done: Int, total: Int) {
        guard state == .running, !isPaused, total > 0 else { return }
        isIndeterminateValue = false
        fractionValue = 0.5 * Double(done) / Double(total)
        let pages = max(1, (total / 2 + AudioFingerprintStore.defaultPageSize - 1) / AudioFingerprintStore.defaultPageSize)
        let page = min(pages, ((done % max(1, total / 2)) / AudioFingerprintStore.defaultPageSize) + 1)
        subtitleText = "Reading sound prints — pass \(done <= total / 2 ? 1 : 2) of 2, page \(page) of \(pages)"
    }

    private func searchAll(_ engine: FindMasterEngine) async {
        let total = plan.queries.count
        for (i, query) in plan.queries.enumerated() {
            if await stoppedWhilePaused() {
                tally.notStarted = total - i
                return
            }
            subtitleText = "Searching \(i + 1) of \(total) — \(query.name)"
            let search = await Task.detached(priority: .userInitiated) { engine.search(query.key) }.value
            record(query, search: search, engine: engine)
            fractionValue = 0.5 + 0.5 * Double(i + 1) / Double(total)
            afterQuery?(i + 1)
        }
    }

    /// Between queries: wait out a pause; true when stopped.
    private func stoppedWhilePaused() async -> Bool {
        while gate.isPaused && !gate.isStopped {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return gate.isStopped
    }

    private func record(_ query: FindMasterQuery, search: AudioMasterSearch?, engine: FindMasterEngine) {
        let outcome: FindMasterResult.Outcome
        switch search {
        case nil:
            outcome = .refused(.noSoundPrint)
        case .refused(let refusal)?:
            outcome = .refused(FindMasterAnswer.reason(for: refusal))
        case .noneFound(let searched)?:
            outcome = .noneFound(searched: searched)
        case .found(let found, let searched)?:
            outcome = .found(found, searched: searched)
        }
        results.append(FindMasterResult(recordID: query.recordID, name: query.name, outcome: outcome))
        count(outcome)
        for line in lines(for: query, outcome: outcome) { note(line) }
    }

    func count(_ outcome: FindMasterResult.Outcome) {
        switch outcome {
        case .refused: tally.refused += 1
        case .noneFound: tally.searched += 1; tally.none += 1
        case .found(let found, _):
            tally.searched += 1
            // A file is counted by its best STRONG hit; weak overlaps alone
            // are their own bucket (FindMasterAnswer.isWeak).
            switch FindMasterAnswer.split(found).strong.first?.match.verdict {
            case .sameRecording?: tally.same += 1
            case .containedInMaster?: tally.inside += 1
            case .masterContainedInQuery?: tally.contains += 1
            case .overlap?: tally.shares += 1
            case .inconclusive?, .different?: tally.inconclusive += 1
            case nil: tally.weakOnly += 1
            }
        }
    }

    func lines(for query: FindMasterQuery, outcome: FindMasterResult.Outcome) -> [String] {
        switch outcome {
        case .refused(let reason):
            return [FindMasterAnswer.refusalLine(name: query.name, reason: reason)]
        case .noneFound(let searched):
            return [FindMasterAnswer.queryLine(name: query.name, key: query.key, answer: FindMasterAnswer.noneFound(
                searched: searched, noSoundTrack: plan.noSoundTrackContents, notFingerprinted: plan.notFingerprintedContents))]
        case .found(let found, _):
            let (strong, weak) = FindMasterAnswer.split(found)
            var lines = strong.map { c in
                FindMasterAnswer.queryLine(name: query.name, key: query.key, answer: answer(c))
            }
            if !weak.isEmpty { lines.append(FindMasterAnswer.weakLine(name: query.name, key: query.key, weak: weak)) }
            return lines
        }
    }

    /// The sentence for one found content, naming it from the plan's labels.
    func answer(_ c: AudioMasterCandidate) -> String {
        FindMasterAnswer.sentence(c, other: FindMasterAnswer.name(of: c.key, label: plan.labels[c.key.contentDigest]))
    }

    private func stopBeforeSearching() {
        tally.notStarted = plan.queries.count
        tally.stopped = true
        note(FindMasterAnswer.outcomeLine(tally, seconds: Date().timeIntervalSince(startedAt)))
        state = .cancelled
        subtitleText = FindMasterAnswer.summary(tally, seconds: Date().timeIntervalSince(startedAt))
        isIndeterminateValue = false
    }

    private func finish(seconds: Double) {
        isIndeterminateValue = false
        if gate.isStopped {
            tally.stopped = true
            note(FindMasterAnswer.outcomeLine(tally, seconds: seconds))
            subtitleText = FindMasterAnswer.summary(tally, seconds: seconds)
            state = .cancelled
            return
        }
        fractionValue = 1
        let summary = FindMasterAnswer.summary(tally, seconds: seconds)
        note(FindMasterAnswer.outcomeLine(tally, seconds: seconds))
        subtitleText = summary
        state = .finished(summary: summary)
    }
}

// MARK: - Start

extension MediaFileOperationsCenter {
    /// Start Find Master for a plan. Refused (nothing started) when the
    /// selection is empty.
    @discardableResult
    func startFindMaster(plan: FindMasterPlan, sidecarDirectory: URL, note: @escaping (String) -> Void,
                         reveal: @escaping (UUID) -> Void) -> FindMasterJob {
        let job = FindMasterJob(plan: plan, sidecarDirectory: sidecarDirectory, note: note, reveal: reveal)
        guard add(job) else { return job }
        job.start()
        appLog.write(Self.startSummaryLine(verb: job.kind.logVerb, title: job.title,
                                           plan: "\(plan.queries.count) to search, \(plan.refusals.count) refused before search — sound only; writes nothing"))
        return job
    }
}
