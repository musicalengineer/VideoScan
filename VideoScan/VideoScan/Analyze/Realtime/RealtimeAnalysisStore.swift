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
        /// Files with tries and no verdict — AnalysisResultsReport's one rule
        /// (Codex F6); a refusal carries the words (an unreadable or over-cap
        /// attempts file).
        var trying: @Sendable () async -> Result<Int, Refusal>
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
        let journal = ObservationJournal(directory: EraPlanner.journalDirectory(stateRoot: stateRoot))
        let cursor = HelperJournalCursor(directory: journal.directory)
        let reader = MachineCounterReader()
        let repository = model.catalogCutover.committer?.repository
        let signer = SeatedApproach.eraA2.signer
        // "Trying" = AnalysisResultsReport.inProgress — the Results sheet's rule
        // (a verdict in the catalog or the journal excludes the entry); read
        // only when the try entries changed, through the session's reader.
        let trying = TryingCounter(
            signer: signer,
            readAttempts: { TryingCounter.readAttempts(stateRoot: stateRoot) },
            answered: { snapshot in
                guard let repository else { throw Refusal("catalog.sqlite is not open in this session — there is nothing to read") }
                let inJournal = EraPlanner.answeredInJournal(journal, signer: signer)
                return try await repository.read {
                    try AnalysisResultsReport.inProgress(reader: $0, signer: signer, attempts: snapshot, inJournal: inJournal).count
                }
            })
        let runner = AnalyzeRunner(model: model, orchestrator: orchestrator, center: nil)
        let sources = Sources(
            inApp: { [weak orchestrator] in orchestrator.map(inApp(from:)) ?? RealtimeAnalysisState.InApp() },
            helperEnabled: { BackgroundServiceRegistrar.isEnabled },
            helperStatus: { await BackgroundServiceClient().status() },
            journal: { await cursor.refresh() },
            trying: { await trying.count() },
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
                                       hasCaptions: l.hasCaptions, isVideoOnly: l.isVideoOnly)
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
        let trying = sources.trying
        let signer = sources.seatedSigner
        let words = sources.journalWords()
        return Task.detached(priority: .utility) { [weak self] in
            let reply: Result<ServiceStatus, Refusal>? = enabled ? await status() : nil
            var h = Self.helper(from: reply, enabled: enabled, seatedSigner: signer, previous: previous)
            h.tally = await journal()
            switch await trying() {
            case .success(let count):
                h.triesInProgress = count
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

// MARK: - "Trying": AnalysisResultsReport's rule, read only when the tries changed

/// Files with tries and no verdict, by the ONE rule the Results sheet uses
/// (`AnalysisResultsReport.inProgress`: an entry whose content already has a
/// verdict in the catalog or the journal is not in progress — Codex F6).
/// The catalog + journal read runs only when the signer's try entries
/// changed since the last count; an unchanged attempts log costs one replay.
/// The attempts file is read through the read-only snapshot and refused
/// past `attemptsFileCap` (Codex F9: bounded work, unavailable with a reason).
///
/// Memory: one snapshot (≈ 200 B per entry) and the last count.
/// (For Rick: a memoised lookup behind a mutex — an actor.)
actor TryingCounter {
    static let attemptsFileCap = 32 << 20

    private let signer: String
    private let readAttempts: @Sendable () -> Result<EraAttemptSnapshot, Refusal>
    private let answered: @Sendable (EraAttemptSnapshot) async throws -> Int
    private var last: (entries: [String: EraAttempt], count: Int)?
    /// Catalog + journal reads made (tests: unchanged tries read nothing).
    private(set) var reads = 0

    init(signer: String,
         readAttempts: @escaping @Sendable () -> Result<EraAttemptSnapshot, Refusal>,
         answered: @escaping @Sendable (EraAttemptSnapshot) async throws -> Int) {
        self.signer = signer
        self.readAttempts = readAttempts
        self.answered = answered
    }

    /// The attempts snapshot, refused when the file is over the cap.
    static func readAttempts(stateRoot: URL) -> Result<EraAttemptSnapshot, Refusal> {
        let url = EraAttemptStore.url(stateRoot: stateRoot)
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
           size.intValue > attemptsFileCap {
            return .failure(Refusal("the try counts at \(url.path) are \(size.intValue >> 20) MB, over the window's "
                                    + "\(attemptsFileCap >> 20) MB cap — not read"))
        }
        return AnalysisResultsReport.readAttempts(stateRoot: stateRoot)
    }

    func count() async -> Result<Int, Refusal> {
        let snapshot: EraAttemptSnapshot
        switch readAttempts() {
        case .failure(let refusal): return .failure(refusal)
        case .success(let s): snapshot = s
        }
        let entries = snapshot.attempts(signer: signer)
        if entries.isEmpty { return .success(0) }
        if let last, last.entries == entries { return .success(last.count) }
        do {
            reads += 1
            let count = try await answered(snapshot)
            last = (entries, count)
            return .success(count)
        } catch let refusal as Refusal {
            return .failure(refusal)
        } catch {
            return .failure(Refusal("the verdicts could not be read (\(error))"))
        }
    }
}
