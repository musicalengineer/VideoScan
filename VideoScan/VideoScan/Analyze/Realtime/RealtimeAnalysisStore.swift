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
//     through HelperJournalReader (read-only, bounded, from byte 0). No "tries in
//     progress" (Codex re-review, Rick's KISS): that needs the catalog plus
//     every journal day file; the Results sheet owns it.
// Publishes are equality-gated: a tick that changed nothing sends nothing.
//
// Pause / Resume / Stop go through AnalyzeRunner — the one engine the Content
// Analysis panel's dossier rows use (rule 4) — never a second code path.
//
// "Analyze the N left" (Rick 2026-11-06): N and the steps come from the
// coverage report Catalog Status ▸ Content reads (AnalyzeLeftPlan); each step
// is AnalyzeRunner.runNow — the panel's own Run now. ONE START line (N, what is
// left, the steps) and ONE OUTCOME line when every engine it started is idle
// again (each engine writes its own START / OUTCOME as always). Stop during
// such a run also takes this run's still-queued drives out of the dossier
// queue, so Stop means stop.
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
        var machine: @Sendable () async -> MachineSample
        var journalWords: @MainActor () -> String?
        var note: @MainActor (String) -> Void
        var pause: @MainActor () -> Void
        var resume: @MainActor () -> Void
        var stop: @MainActor () -> Void
        var seatedSigner: String
        var now: @Sendable () -> Date
        /// What is left (O(analyzers + drives) from the cached report).
        var left: @MainActor () -> AnalyzeLeftPlan = { AnalyzeLeftPlan() }
        /// Start one step — AnalyzeRunner.runNow in production.
        var runStep: @MainActor (AnalyzeLeftPlan.Step) -> Void = { _ in }
        /// Whether an engine is running (AnalyzeRunner.isRunning, plus the
        /// dossier queue's waiting drives).
        var isRunning: @MainActor (AnalyzeCycler) -> Bool = { _ in false }
        /// Take a drive this run queued out of the dossier queue (Stop).
        var dequeue: @MainActor (String) -> Void = { _ in }
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
    static func production(model: VideoScanModel, orchestrator: CaptionOrchestrator,
                           center: MediaFileOperationsCenter?) -> RealtimeAnalysisStore {
        let stateRoot = URL(fileURLWithPath: model.catalogStore.fileLocation).deletingLastPathComponent()
            .appendingPathComponent("background", isDirectory: true)
        let journalDirectory = EraPlanner.journalDirectory(stateRoot: stateRoot)
        let reader = MachineCounterReader()
        // The center lets a Full Hashes / Sound Prints step start its MFO job
        // exactly as the panel does; nil only where no center exists.
        let runner = AnalyzeRunner(model: model, orchestrator: orchestrator, center: center)
        let sources = Sources(
            inApp: { [weak orchestrator] in orchestrator.map(inApp(from:)) ?? RealtimeAnalysisState.InApp() },
            helperEnabled: { BackgroundServiceRegistrar.isEnabled },
            helperStatus: { await BackgroundServiceClient().status() },
            journal: { HelperJournalReader.read(directory: journalDirectory) },
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
            now: { Date() },
            left: { [weak model] in AnalyzeLeftPlan.make(model?.analyzeCoverageSnapshot.report ?? AnalyzeCoverageReport()) },
            runStep: { step in runner.runNow(step.cycler, volume: step.volume, source: Self.source) },
            isRunning: { [weak orchestrator] c in
                // Between two queued drives the batch is briefly not active;
                // a drive still waiting (and reachable) keeps the run open.
                guard c.isDossierStage, let o = orchestrator else { return runner.isRunning(c) }
                return runner.isRunning(c) || o.queueDispatchInFlight
                    || o.queuedVolumePrefixes.contains { !o.parkedVolumePrefixes.contains($0) }
            },
            dequeue: { [weak orchestrator] prefix in orchestrator?.dequeueAnalyze(volumePrefix: prefix) })
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
        s.done = o.liveCaptioned
        s.captioned = o.liveWithCaptions
        s.transcribed = o.liveTranscribed
        s.noSpeech = o.liveNoSpeech
        s.transcriptFailures = o.transcriptFailures
        s.failed = o.liveFailed
        s.skipped = o.liveSkipped
        // A finished pass shows its own terminal counts (Codex F4): the
        // status carries them; the live counters are reset at every empty pass.
        if case .finished(let captioned, let skipped, let failed) = o.currentStatus {
            s.done = captioned
            s.skipped = skipped
            s.failed = failed
        }
        s.volumePrefix = o.currentVolumePrefix
        s.lanes = o.activeLanes.map { l in
            RealtimeAnalysisState.Lane(id: l.id, filename: l.filename, path: l.path, recordID: l.recordID,
                                       stage: l.stageName, verb: l.verb, startedAt: l.startedAt,
                                       framesPlanned: l.framesPlanned, clipSeconds: l.clipSeconds,
                                       hasCaptions: l.hasCaptions, isVideoOnly: l.isVideoOnly,
                                       noSpeech: l.noSpeech, extractionDone: l.extractionDone)
        }
        s.recent = o.recentActivity.map { c in
            RealtimeAnalysisState.Output(id: c.id, filename: c.filename, path: c.path, recordID: c.recordID,
                                         syncedAt: c.syncedAt, vlmSeconds: c.vlmSeconds, whisperSeconds: c.whisperSeconds,
                                         note: c.note, isVideoOnly: c.isVideoOnly, hasCaptions: c.hasCaptions,
                                         hasTranscript: c.hasTranscript, transcriptFailed: c.transcriptFailed,
                                         sceneCount: c.output?.sceneCount ?? 0,
                                         firstCaption: c.output?.firstCaption,
                                         transcriptExcerpt: c.output?.transcriptExcerpt,
                                         noSpeech: c.noSpeech, banked: c.output?.banked ?? true)
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
        foldLeft(into: &next, now: sampledAt)
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
        let signer = sources.seatedSigner
        let words = sources.journalWords()
        return Task.detached(priority: .utility) { [weak self] in
            // The journal first (local, bounded, fast) and landed at once, so a
            // slow XPC answer never holds the counts back (re-review 2, finding 2).
            var h = previous
            h.tally = await journal()
            h.journalWords = words
            let partial = h
            await MainActor.run { [weak self] in
                guard let self, self.helperTask != nil else { return }
                self.pendingHelper = partial
            }
            let reply: Result<ServiceStatus, Refusal>? = enabled ? await status() : nil
            let landed = Self.helper(from: reply, enabled: enabled, seatedSigner: signer, previous: h)
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
            case .unknown: words = "VideoScan Background not read yet"
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

    func stopAnalysis() {
        sources.stop()
        guard let run = leftRun else { return }
        let queued = run.steps.compactMap { $0.cycler.isDossierStage ? $0.volume : nil }
        queued.forEach(sources.dequeue)
        if !queued.isEmpty {
            sources.note("\(Self.logTitle) — Stop: \(queued.count) drive(s) this run queued are taken out of the queue")
        }
    }

    // MARK: "Analyze the N left"

    static let source = "realtime window"
    static let logTitle = "Analyze the left"
    /// After the last start, an engine whose flag flips a beat later (the
    /// dossier queue's hand-off) is given this long before "finished".
    static let settleSeconds: TimeInterval = 3

    /// The run this window started, until its engines are idle again.
    private struct LeftRun {
        var files: Int
        var steps: [AnalyzeLeftPlan.Step]
        var startedAt: Date
        var lastBusyAt: Date
    }
    private var leftRun: LeftRun?

    /// Start every step of the CURRENT plan (read now, not from the last
    /// tick). Refused — and logged — while anything runs or nothing is left.
    /// Returns the plan it started (empty when refused).
    @discardableResult
    func analyzeTheLeft() -> AnalyzeLeftPlan {
        var next = state
        let now = sources.now()
        foldLeft(into: &next, now: now)
        publish(next)
        let plan = next.left
        guard next.canAnalyzeLeft else {
            sources.note("\(Self.logTitle) — not started: "
                         + (plan.isEmpty ? "nothing left to analyze" : "an analyzer is already running"))
            return AnalyzeLeftPlan()
        }
        let where_ = plan.steps.map { step in
            step.cycler.isDossierStage
                ? "Scene Captions / OCR / Transcribe on " + (step.volume.map { VolumeReachability.displayLabel(forPath: $0) } ?? "all reachable")
                : step.cycler.title
        }.joined(separator: "; ")
        sources.note("\(Self.logTitle) — START — \(plan.files.formatted()) file(s) left (\(plan.breakdown)); "
                     + "steps: \(where_) (\(Self.source))")
        leftRun = LeftRun(files: plan.files, steps: plan.steps, startedAt: now, lastBusyAt: now)
        plan.steps.forEach(sources.runStep)
        var running = state
        running.leftRunActive = true
        publish(running)
        return plan
    }

    /// The tick's part: the plan, whether its engines are busy, and the
    /// run's end (ONE OUTCOME line) once they have all been idle a while.
    private func foldLeft(into next: inout RealtimeAnalysisState, now: Date) {
        let plan = sources.left()
        next.left = plan
        let watched = leftRun.map { Set($0.steps.map(\.cycler)) } ?? plan.cyclers
        let busy = watched.contains { sources.isRunning($0) }
        next.leftEnginesBusy = busy
        if var run = leftRun {
            if busy { run.lastBusyAt = now; leftRun = run }
            let quiet = now.timeIntervalSince(max(run.startedAt, run.lastBusyAt))
            if !busy, quiet >= Self.settleSeconds {
                let titles = Set(run.steps.map { $0.cycler.isDossierStage ? "Scene Captions / OCR / Transcribe" : $0.cycler.title })
                sources.note("\(Self.logTitle) — OUTCOME — the analyzers it started are idle (\(titles.sorted().joined(separator: ", "))); "
                             + "\(run.files.formatted()) were left at START; each analyzer's own OUTCOME line says what it did")
                leftRun = nil
            }
        }
        next.leftRunActive = leftRun != nil
    }
}

