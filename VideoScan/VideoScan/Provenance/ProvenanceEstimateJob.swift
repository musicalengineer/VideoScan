// ProvenanceEstimateJob.swift — "Estimate Provenance…", the MFO JOB
// (DECISIONS 2026-11-10; design docs/design/provenance.md §C2).
//
// One sentence: a row in Media File Operations around
// ProvenanceEstimateStore.run — progress, Pause / Stop between chunks, and
// the finished row's one-line count. The ENGINE is the store's (rule 4); this
// file owns only the row's state. START / per-content / OUTCOME lines go
// through the store's one log sink; the Center adds its own start and
// terminal summary lines to videoscan.log.
//
// An on-demand command: nothing starts it at launch.
//
// No media is opened and no name or date is written: the run reads the
// records' stored facts and appends inferred assertion rows only.
//
// Memory: the store's run (one fact per archived video, one proposal per
// classified content) for the length of the run; the row keeps one Tally.
//
// (For Rick: a thin adapter — the job is the progress-bar object, the store
// is the worker it calls.)

import Combine
import Foundation
import VideoScanCore

@MainActor
final class ProvenanceEstimateJob: @MainActor MediaFileOperationJob {

    let id = UUID()
    let kind: MediaFileOperationKind = .estimateProvenance
    let startedAt = Date()
    let title = ProvenanceEstimateWords.jobTitle
    private let store: ProvenanceEstimateStore

    @Published private(set) var state: MediaFileOperationState = .running {
        didSet { if !state.isActive, finishedAt == nil { finishedAt = Date() } }
    }
    @Published private(set) var finishedAt: Date?
    @Published private(set) var subtitleText = "Reading the archived videos' facts…"
    @Published private(set) var fractionValue: Double = 0
    @Published private(set) var isIndeterminateValue = true
    @Published private(set) var isPaused = false
    private(set) var wasRefused = false
    private(set) var tally: ProvenanceEstimateStore.Tally?
    /// Internal so tests can `await job.task?.value`.
    private(set) var task: Task<Void, Never>?
    private var stopRequested = false

    var subtitle: String { subtitleText }
    var fraction: Double { fractionValue }
    var isIndeterminate: Bool { isIndeterminateValue }
    var canPause: Bool { state == .running }

    init(store: ProvenanceEstimateStore) {
        self.store = store
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    /// Refused before anything ran (another run is active).
    func refuseToStart(reason: String) {
        guard task == nil, state.isActive else { return }
        wasRefused = true
        state = .failed(message: reason)
        subtitleText = reason
        isIndeterminateValue = false
        task = Task {}
    }

    func cancel() {
        guard state.isActive else { return }
        state = .cancelling
        subtitleText = "Stopping after this chunk…"
        isPaused = false
        stopRequested = true
    }

    func pause() { if state == .running { isPaused = true } }
    func resume() { isPaused = false }

    private func run() async {
        let outcome = await store.run(checkpoint: { [weak self] in
            // Wait out a pause between chunks; true = stop.
            while let self, self.isPaused, !self.stopRequested {
                try? await Task.sleep(for: .milliseconds(100))
            }
            return self?.stopRequested ?? true
        }, progress: { [weak self] done, total in
            guard let self else { return }
            self.isIndeterminateValue = false
            self.fractionValue = total > 0 ? Double(done) / Double(total) : 1
            self.subtitleText = "Recording estimates — \(done) of \(total)"
        })
        isIndeterminateValue = false
        switch outcome {
        case .finished(let tally):
            self.tally = tally
            fractionValue = 1
            let summary = ProvenanceEstimateStore.summary(tally)
            subtitleText = summary
            state = .finished(summary: summary)
        case .stopped(let tally):
            self.tally = tally
            subtitleText = "Stopped — " + ProvenanceEstimateStore.summary(tally)
            state = .cancelled
        case .refused(let why):
            wasRefused = true
            let words = "Refused — \(why). Nothing was written."
            subtitleText = words
            state = .failed(message: words)
        }
    }
}

extension MediaFileOperationsCenter {
    /// Start ONE Estimate Provenance run. Refused (parked, nothing started)
    /// while another is active.
    @discardableResult
    func startEstimateProvenance(store: ProvenanceEstimateStore) -> ProvenanceEstimateJob {
        let job = ProvenanceEstimateJob(store: store)
        guard add(job) else { return job }
        if jobs.contains(where: { $0.id != job.id && $0.state.isActive && $0 is ProvenanceEstimateJob }) {
            job.refuseToStart(reason: "Estimate Provenance is already running — wait for it to finish (or stop it). Nothing was started.")
            return job
        }
        job.start()
        appLog.write(Self.startSummaryLine(verb: job.kind.logVerb, title: job.title,
                                           plan: "read the stored facts of every archived video; record provisional role, carrier and capture setup — no media read, no name or date written"))
        return job
    }
}
