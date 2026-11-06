// RealtimeAnalysisStore.swift — the Realtime Content Analysis window's state
// (Rick 2026-11-05 evening). A feature store behind a seam (rule 12, #337):
// the WINDOW CONTROLLER owns one, built by `production(model:orchestrator:)`;
// nothing here extends VideoScanModel and the model holds nothing new. Every
// outside call is a closure a test replaces (`Sources`).
//
// What it does, on a ≤2 Hz tick while the window is open:
//   * copies the orchestrator's counters and lanes into `state.inApp` (cheap:
//     two small array copies — the same values DossierDashboardSnapshot carries,
//     plus the five live counters);
//   * samples the machine counters through `MachineCounterReader` (an actor:
//     the kernel calls never run on the main actor);
//   * every `helperEvery` seconds, in ONE detached task, asks the helper for
//     its XPC status (only when enabled — asking starts it), folds its journal
//     through HelperJournalCursor (read-only, incremental) and replays its try
//     counts through EraAttemptStore.snapshot (read-only, never compacts).
// Publishes are equality-gated: a tick that changed nothing sends nothing.
//
// Pause / Resume / Stop go through AnalyzeRunner — the one engine the Content
// Analysis panel's dossier rows use (rule 4) — never a second code path.
//
// Logging: one line when the window opens and closes, one when the helper's
// availability changes; never per tick.
//
// Memory: one RealtimeAnalysisState (< 32 KB) plus the cursor's read buffer
// while a refresh runs.
//
// (For Rick: a controller with constructor-injected closures; `Task.detached`
// ≈ a worker thread that does not inherit the UI thread.)

import Combine
import Foundation
import VideoScanCore

@MainActor
final class RealtimeAnalysisStore: ObservableObject {

    struct Sources {
        var inApp: @MainActor () -> RealtimeAnalysisState.InApp
        var helperEnabled: @MainActor () -> Bool
        var helperStatus: @Sendable () async -> Result<ServiceStatus, Refusal>
        var journal: @Sendable () async -> HelperJournalTally
        var attempts: @Sendable () -> Result<EraAttemptSnapshot, Refusal>
        var machine: @Sendable () async -> MachineSample
        var journalWords: @MainActor () -> String?
        var note: @MainActor (String) -> Void
        var pause: @MainActor () -> Void
        var resume: @MainActor () -> Void
        var stop: @MainActor () -> Void
        var seatedSigner: String
        var now: @Sendable () -> Date
    }

    @Published private(set) var state = RealtimeAnalysisState()
    /// Published changes (tests: the equality gate).
    private(set) var publishes = 0
    /// Full ticks run (tests).
    private(set) var ticks = 0

    let sources: Sources
    /// The dossier door for "click a file → its dossier"; nil = no dossier (tests).
    let dossiers: FileDossierLoader?
    let tick: Duration
    let helperEvery: Duration

    private var loop: Task<Void, Never>?
    private var helperTask: Task<RealtimeAnalysisState.Helper, Never>?
    private var lastHelperAt: Date?
    private var lastAvailabilityWords: String?

    init(sources: Sources, dossiers: FileDossierLoader? = nil,
         tick: Duration = .milliseconds(500), helperEvery: Duration = .seconds(5)) {
        self.sources = sources
        self.dossiers = dossiers
        self.tick = tick
        self.helperEvery = helperEvery
    }

    // MARK: Production

    /// The real thing: this session's orchestrator, VideoScan Background over
    /// XPC (when enabled), the helper's state folder beside the catalog, the
    /// host's counters, the one log sink, the dossier door.
    static func production(model: VideoScanModel, orchestrator: CaptionOrchestrator) -> RealtimeAnalysisStore {
        let stateRoot = URL(fileURLWithPath: model.catalogStore.fileLocation).deletingLastPathComponent()
            .appendingPathComponent("background", isDirectory: true)
        let cursor = HelperJournalCursor(directory: EraPlanner.journalDirectory(stateRoot: stateRoot))
        let reader = MachineCounterReader()
        let runner = AnalyzeRunner(model: model, orchestrator: orchestrator, center: nil)
        let sources = Sources(
            inApp: { [weak orchestrator] in orchestrator.map(inApp(from:)) ?? RealtimeAnalysisState.InApp() },
            helperEnabled: { BackgroundServiceRegistrar.isEnabled },
            helperStatus: { await BackgroundServiceClient().status() },
            journal: { await cursor.refresh() },
            attempts: { AnalysisResultsReport.readAttempts(stateRoot: stateRoot) },
            machine: { await reader.sample() },
            journalWords: { [weak model] in model?.journalApplier.counts.map(JournalApplierWords.statusLine) },
            note: { [weak model] line in
                model?.log("Realtime Content Analysis: " + line)
                appLog.write("[realtime-ca] " + line)
            },
            pause: { runner.pause(.sceneCaptions) },
            resume: { runner.resume(.sceneCaptions) },
            stop: { runner.stop(.sceneCaptions) },
            seatedSigner: SeatedApproach.eraA2.signer,
            now: { Date() })
        return RealtimeAnalysisStore(sources: sources, dossiers: FileDossierLoader.production(model: model))
    }

    // MARK: The one mapping from the orchestrator (truth-tested)

    static func inApp(from o: CaptionOrchestrator) -> RealtimeAnalysisState.InApp {
        var s = RealtimeAnalysisState.InApp()
        switch o.currentStatus {
        case .idle:
            s.phase = .idle
        case .running(_, let currentFile, let eta):
            s.phase = o.paused ? .paused : .analyzing
            s.currentFile = currentFile
            s.etaSeconds = eta
        case .cancelling:
            s.phase = .stopping
        case .finished:
            s.phase = .finished
        }
        s.currentIndex = o.liveCurrentIndex
        s.total = o.liveTotal
        s.captioned = o.liveCaptioned
        s.transcribed = o.liveTranscribed
        s.transcriptFailures = o.transcriptFailures
        s.failed = o.liveFailed
        s.skipped = o.liveSkipped
        s.volumePrefix = o.currentVolumePrefix
        s.lanes = o.activeLanes.map { l in
            RealtimeAnalysisState.Lane(id: l.id, filename: l.filename, path: l.path, recordID: l.recordID,
                                       stage: l.stageName, verb: l.verb, startedAt: l.startedAt,
                                       framesPlanned: l.framesPlanned, clipSeconds: l.clipSeconds,
                                       hasCaptions: l.hasCaptions, isVideoOnly: l.isVideoOnly)
        }
        s.recent = o.recentActivity.map { c in
            RealtimeAnalysisState.Output(id: c.id, filename: c.filename, path: c.path, recordID: c.recordID,
                                         syncedAt: c.syncedAt, vlmSeconds: c.vlmSeconds, whisperSeconds: c.whisperSeconds,
                                         note: c.note, isVideoOnly: c.isVideoOnly, hasCaptions: c.hasCaptions,
                                         hasTranscript: c.hasTranscript, transcriptFailed: c.transcriptFailed,
                                         sceneCount: c.output?.sceneCount ?? 0,
                                         firstCaption: c.output?.firstCaption,
                                         transcriptExcerpt: c.output?.transcriptExcerpt)
        }
        return s
    }

    /// The helper pane from one XPC answer (pure; tests pin the words).
    nonisolated static func helper(from reply: Result<ServiceStatus, Refusal>?, enabled: Bool, seatedSigner: String,
                       previous: RealtimeAnalysisState.Helper) -> RealtimeAnalysisState.Helper {
        var h = previous
        h.modelShortName = MachineEraResolver.modelShortName(by: seatedSigner)
        guard enabled else {
            h.availability = .disabled
            h.backoffWords = nil
            h.era = nil
            h.planned = nil
            return h
        }
        switch reply {
        case .none:
            h.availability = .silent("no answer")
        case .failure(let refusal):
            h.availability = .silent(refusal.words)
            h.era = nil
            h.planned = nil
            h.backoffWords = nil
        case .success(let status):
            h.availability = .answered
            h.backoffWords = status.backoff.words
            h.planned = status.planned?[JobKind.era.rawValue]
            let eras = status.jobs.filter { $0.kind == .era }
            let newest = eras.first { $0.state.isActive }
                ?? eras.max { ($0.finishedAt ?? $0.startedAt ?? .distantPast) < ($1.finishedAt ?? $1.startedAt ?? .distantPast) }
            h.era = newest.map {
                RealtimeAnalysisState.HelperJob(stateWords: $0.stateWords, completedUnits: $0.completedUnits,
                                                totalUnits: $0.totalUnits, startedAt: $0.startedAt)
            }
        }
        return h
    }

    // MARK: Lifecycle

    func start() {
        guard loop == nil else { return }
        var opened = state
        opened.openedAt = sources.now()
        publish(opened)
        sources.note("opened")
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshNow()
                try? await Task.sleep(for: self.tick)
            }
        }
    }

    func stop() {
        guard loop != nil else { return }
        loop?.cancel()
        loop = nil
        helperTask?.cancel()
        helperTask = nil
        sources.note("closed")
    }

    /// One tick: the in-app copy, a machine sample, and (on its cadence) the
    /// helper refresh. A slow XPC answer never stalls a tick: the helper task
    /// lands its result in `pendingHelper` and the next tick folds it in.
    /// Tests pass `waitForHelper: true` to fold it in on this tick.
    func refreshNow(waitForHelper: Bool = false) async {
        ticks += 1
        var next = state
        next.inApp = sources.inApp()
        let sampledAt = sources.now()
        next.machine.apply(await sources.machine(), at: sampledAt)
        if helperTask == nil, lastHelperAt.map({ sampledAt.timeIntervalSince($0) >= TimingBudget.seconds(helperEvery) }) ?? true {
            lastHelperAt = sampledAt
            helperTask = helperRefresh(previous: next.helper)
        }
        if waitForHelper, let task = helperTask {
            pendingHelper = await task.value
            helperTask = nil
        }
        if let landed = pendingHelper {
            next.helper = landed
            pendingHelper = nil
        }
        publish(next)
    }

    /// A helper refresh that finished between ticks.
    private var pendingHelper: RealtimeAnalysisState.Helper?

    /// Runs the three helper reads off the main actor and parks the result.
    private func helperRefresh(previous: RealtimeAnalysisState.Helper) -> Task<RealtimeAnalysisState.Helper, Never> {
        let enabled = sources.helperEnabled()
        let status = sources.helperStatus
        let journal = sources.journal
        let attempts = sources.attempts
        let signer = sources.seatedSigner
        let words = sources.journalWords()
        return Task.detached(priority: .utility) { [weak self] in
            let reply: Result<ServiceStatus, Refusal>? = enabled ? await status() : nil
            var h = Self.helper(from: reply, enabled: enabled, seatedSigner: signer, previous: previous)
            h.tally = await journal()
            switch attempts() {
            case .success(let snapshot):
                h.triesInProgress = snapshot.attempts(signer: signer).count
                h.triesProblem = nil
            case .failure(let refusal):
                h.triesInProgress = nil
                h.triesProblem = refusal.words
            }
            h.journalWords = words
            let landed = h
            await MainActor.run { [weak self] in
                guard let self, self.helperTask != nil else { return }
                self.pendingHelper = landed
                self.helperTask = nil
            }
            return landed
        }
    }

    private func publish(_ next: RealtimeAnalysisState) {
        guard next != state else { return }
        if next.helper.availability != state.helper.availability {
            let words: String
            switch next.helper.availability {
            case .disabled: words = "VideoScan Background is off in Settings — its pane shows the journal only"
            case .silent(let why): words = "VideoScan Background did not answer — \(why)"
            case .answered: words = "VideoScan Background answered"
            }
            if words != lastAvailabilityWords {
                lastAvailabilityWords = words
                sources.note(words)
            }
        }
        state = next
        publishes += 1
    }

    // MARK: Actions (the one engine: AnalyzeRunner → the orchestrator)

    func pause() { sources.pause() }
    func resume() { sources.resume() }
    func stopAnalysis() { sources.stop() }
}
