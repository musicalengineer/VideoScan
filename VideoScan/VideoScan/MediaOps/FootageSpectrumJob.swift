// FootageSpectrumJob.swift
// "Compare Footage…" as a Media File Operations job (Footage Spectrum trial,
// 2026-10-03; docs/design/footage_spectrum_design_2026-10-03.md). A person
// chose 2–8 videos; the job runs scripts/footage_spectrum.py over them once
// and the Footage Spectrum window shows the page it writes.
//
//   collapsed row  [SPECTRUM] Reading 2 of 5 · clip.mov · about 1:10 left  ▬▬▬▬  Stop
//   finished       Compared 5 videos — 3 the same footage, 1 close, 1 different   [Open]
//   expanded       each video with its verdict, and what was left out and why
//
// Lifecycle:
//   1. prune run folders older than 14 days (the cache folder only)
//   2. write <root>/runs/<id>/sets.json
//   3. hold the per-volume read gates of every file (MediaVolumeGate, the
//      same queue Compare waits in), then launch the helper ONCE
//   4. ESTIMATE / PROGRESS lines → row text, bar, time left; one log line
//      per file; DONE → finished + page; ERROR / non-zero exit → failed
//
// Stop terminates the helper (Task cancellation → ProcessRunner SIGTERM →
// SIGKILL; the helper takes its ffmpeg down with it) and leaves the cache
// intact. Not pausable: a pass is one ffmpeg per file, and a re-run is
// instant from the cache. Quit = Stop; nothing to resume.
//
// READ-ONLY on media. This file opens nothing for writing except the run's
// own sets.json (written atomically under the store root).
//
// Event ordering: the helper's stdout arrives on a ProcessRunner thread.
// Lines go into a lock-guarded FIFO and are handled on the main actor in
// order; after the helper exits the job drains the FIFO itself BEFORE it
// judges the outcome, so a DONE line can never lose a race with the exit
// (the FindPersonJob lesson, without the counters).
//
// Memory: the FIFO holds lines not yet handled — a few hundred bytes each,
// handled within a main-actor turn; the detail list is one line per chosen
// video (≤ 8 plus what was left out).
//
// (For Rick: `@MainActor` ≈ "every member runs on the UI thread";
// `Task { … }` ≈ a coroutine on that thread; `withPermit` ≈ a counting
// semaphore's acquire/release around the body, released on cancellation too.)

import Combine
import Foundation
import os

private let spectrumJobLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "fileOps")

/// Lock-guarded FIFO of helper stdout lines (filled off-main, drained on main).
final class FootageSpectrumLineQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock(); lines.append(line); lock.unlock()
    }

    func takeAll() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let out = lines
        lines.removeAll(keepingCapacity: true)
        return out
    }
}

@MainActor
final class FootageSpectrumJob: @MainActor MediaFileOperationJob {

    // MARK: Identity

    let id = UUID()
    let kind: MediaFileOperationKind = .compareFootage
    let startedAt = Date()

    /// nil when the run was refused before a plan existed.
    let plan: FootageSpectrumPlan?
    /// What the person asked for (the window's title, Compare Again's ids).
    let requestTitle: String
    let requestedIDs: [UUID]
    let preferredFirst: UUID?
    let store: FootageSpectrumStore

    private let tools: Result<FootageSpectrumTools, FootageSpectrumRefusal>
    private let gates: [MediaVolumeGate]
    private let launcher: FootageSpectrumHelper.Launcher

    /// Console + catalog.log (the model's `log`). videoscan.log is `appLog`.
    var console: ((String) -> Void)?
    /// Tests turn the 14-day prune off (it reads the real clock).
    var pruneOnStart = true

    let canPause = false

    // MARK: Published state

    @Published private(set) var state: MediaFileOperationState = .running {
        didSet { if !state.isActive, finishedAt == nil { finishedAt = Date() } }
    }
    @Published private(set) var finishedAt: Date?
    @Published private(set) var subtitleText = "Starting…"
    @Published private(set) var fractionValue = 0.0
    @Published private(set) var isIndeterminateValue = true
    /// The page, once the helper has written it.
    @Published private(set) var pageURL: URL?
    /// One line per chosen video, then what was left out.
    @Published private(set) var detailLines: [DetailLine] = []

    struct DetailLine: Identifiable, Equatable {
        /// The member's or left-out file's record id — two offline copies
        /// with one name and one reason are still two rows (QA P3-2).
        let id: UUID
        var label: String
        var text: String
        var isLeftOut: Bool
    }

    var title: String { plan?.title ?? requestTitle }
    var subtitle: String {
        if let label = waitingForVolumeLabel {
            return VolumeGateBoard.describeWait(label: label, root: waitingForVolumeRoot ?? "")
        }
        return subtitleText
    }
    var fraction: Double { fractionValue }
    var isIndeterminate: Bool { waitingForVolumeLabel != nil || isIndeterminateValue }

    private var refused = false
    var wasRefused: Bool { refused }
    /// The Center would not take the job at all (a remote viewer) — no row,
    /// no window; the caller says why (QA P3-5).
    private(set) var refusedOnViewer = false

    /// Refuse a job the Center did not register: it never starts, and the
    /// reason goes to videoscan.log and the console here because no Center
    /// OUTCOME watcher will see it.
    func refuseToStart(reason: String) {
        guard state == .running, task == nil else { return }
        refused = true
        refusedOnViewer = true
        subtitleText = reason
        state = .failed(message: reason)
        let line = "\(kind.logVerb) refused: \(title) — \(reason)"
        appLog.write(line)
        console?(line)
    }

    // MARK: Run bookkeeping

    private(set) var task: Task<Void, Never>?
    private let queue = FootageSpectrumLineQueue()
    private var cancelRequested = false
    private var stallReason: String?
    private var stallMonitor: StallMonitor?
    private var waitingForVolumeLabel: String?
    private var waitingForVolumeRoot: String?
    private var estimates: [Double] = []
    private var helperStartedAt: Date?
    private var loggedFile = 0
    private var doneEvent: FootageSpectrumProtocol.Done?
    private var errorEvent: FootageSpectrumProtocol.Failure?
    /// Lines the helper sent that were understood (test hook).
    private(set) var handledEvents = 0

    // MARK: Init

    init(plan: FootageSpectrumPlan,
         requestedIDs: [UUID],
         preferredFirst: UUID?,
         tools: Result<FootageSpectrumTools, FootageSpectrumRefusal>,
         store: FootageSpectrumStore,
         gates: [MediaVolumeGate],
         launcher: @escaping FootageSpectrumHelper.Launcher) {
        self.plan = plan
        self.requestTitle = plan.title
        self.requestedIDs = requestedIDs
        self.preferredFirst = preferredFirst
        self.tools = tools
        self.store = store
        self.gates = gates
        self.launcher = launcher
        self.detailLines = plan.members.enumerated().map { i, m in
            DetailLine(id: m.id, label: m.label, text: i == plan.referenceIndex ? "the reference — waiting" : "waiting",
                       isLeftOut: false)
        } + plan.leftOut.map { DetailLine(id: $0.id, label: $0.filename, text: $0.reason, isLeftOut: true) }
    }

    /// A run refused before anything started (fewer than two readable
    /// videos): a row that says why, written once to the log as "refused".
    init(refusedTitle: String, requestedIDs: [UUID], reason: String, store: FootageSpectrumStore) {
        self.plan = nil
        self.requestTitle = refusedTitle
        self.requestedIDs = requestedIDs
        self.preferredFirst = nil
        self.tools = .failure(FootageSpectrumRefusal(reason: reason))
        self.store = store
        self.gates = []
        self.launcher = { _, _ in FootageSpectrumHelper.Exit(code: -1, stderrTail: "") }
        self.refused = true
        self.subtitleText = reason
        self.state = .failed(message: reason)
        self.finishedAt = Date()
    }

    // MARK: Start / cancel

    func start() {
        guard task == nil, state == .running, plan != nil else { return }
        task = Task { [weak self] in
            await self?.run()
        }
    }

    func cancel() {
        guard state.isActive, !cancelRequested, stallReason == nil else { return }
        cancelRequested = true
        state = .cancelling
        subtitleText = "Cancelling…"
        spectrumJobLog.info("compare footage cancel requested: \(self.title, privacy: .public)")
        if let task {
            task.cancel()
        } else {
            finish(cancelled: true)
        }
    }

    // MARK: Run

    private func run() async {
        guard let plan else { return }
        let found: FootageSpectrumTools
        switch tools {
        case .failure(let refusal):
            finish(failed: refusal.reason)
            return
        case .success(let t):
            found = t
        }
        if pruneOnStart {
            let store = self.store
            await Task.detached(priority: .utility) { store.pruneOldRuns() }.value
        }
        do {
            try store.prepare(run: id)
            try FootageSpectrumSets.json(for: plan).write(to: store.setsFile(id), options: .atomic)
        } catch {
            finish(failed: "Could not prepare the comparison's folder: \(error.localizedDescription)")
            return
        }
        guard !cancelRequested, !Task.isCancelled else {
            finish(cancelled: true)
            return
        }
        await runHoldingGates(gates[...], tools: found)
        // Cancelled while queued for a drive: nothing ran.
        if state.isActive { finish(cancelled: true) }
    }

    /// Acquire each gate in order (recursing so `withPermit` releases even
    /// on cancellation), then run the helper while holding all of them —
    /// the same shape as PairCompareJob.
    private func runHoldingGates(_ remaining: ArraySlice<MediaVolumeGate>, tools: FootageSpectrumTools) async {
        guard let gate = remaining.first else {
            waitingForVolumeLabel = nil
            waitingForVolumeRoot = nil
            await runHelper(tools)
            return
        }
        waitingForVolumeLabel = gate.label
        waitingForVolumeRoot = gate.root
        objectWillChange.send()
        let holder = "Compare footage \(title)"
        let jobID = id
        do {
            try await gate.semaphore.withPermit { [weak self] in
                await MainActor.run { VolumeGateBoard.shared.claim(root: gate.root, jobID: jobID, name: holder) }
                await self?.runHoldingGates(remaining.dropFirst(), tools: tools)
                await MainActor.run { VolumeGateBoard.shared.clear(root: gate.root, jobID: jobID) }
            }
        } catch {
            waitingForVolumeLabel = nil
            spectrumJobLog.info("compare footage \(self.id, privacy: .public) cancelled while waiting for \(gate.root, privacy: .public)")
        }
    }

    private func runHelper(_ tools: FootageSpectrumTools) async {
        guard !cancelRequested, !Task.isCancelled else { return }
        let invocation = FootageSpectrumHelper.Invocation(tools: tools, setsFile: store.setsFile(id),
                                                          outputPage: store.pageFile(id), cacheDir: store.cacheDir)
        helperStartedAt = Date()
        subtitleText = "Looking at \(plan?.members.count ?? 0) videos…"
        let monitor = StallMonitor(label: "compare footage \(title)") { [weak self] silentFor in
            Task { @MainActor [weak self] in self?.handleStall(silentFor: silentFor) }
        }
        stallMonitor = monitor
        monitor.start()
        let lines = queue
        let exit = await launcher(invocation) { [weak self] line in
            lines.append(line)
            Task { @MainActor [weak self] in self?.drainLines() }
        }
        monitor.stop()
        stallMonitor = nil
        drainLines()
        settle(exit)
    }

    // MARK: Lines

    func drainLines() {
        for line in queue.takeAll() {
            stallMonitor?.tick()
            guard let event = FootageSpectrumProtocol.parse(line) else { continue }
            handledEvents += 1
            handle(event)
        }
    }

    private func handle(_ event: FootageSpectrumProtocol.Event) {
        guard state.isActive else { return }
        switch event {
        case .estimate(let files, _):
            estimates = files.sorted { $0.file < $1.file }.map(\.seconds)
            isIndeterminateValue = false
        case .progress(let p):
            isIndeterminateValue = false
            let position = FootageSpectrumETA.Position(file: p.file, fraction: p.fraction, phase: p.phase)
            fractionValue = FootageSpectrumETA.overallFraction(estimates: estimates, at: position)
            let elapsed = Date().timeIntervalSince(helperStartedAt ?? Date())
            let left = FootageSpectrumETA.secondsLeft(estimates: estimates, at: position, elapsed: elapsed)
            subtitleText = FootageSpectrumWords.rowText(p, timeLeft: FootageSpectrumETA.text(secondsLeft: left))
            if p.phase == .reading, p.file != loggedFile {
                loggedFile = p.file
                markReading(label: p.label)
                let member = plan?.members.first { $0.label == p.label }
                let place = member.map { "\($0.volumeLabel.isEmpty ? "" : "\($0.volumeLabel) · ")\($0.filename)" } ?? p.label
                say("\(kind.logVerb): \(title) — reading \(p.file) of \(p.of) · \(place)")
            }
        case .done(let d):
            doneEvent = d
        case .error(let e):
            errorEvent = e
        }
    }

    private func markReading(label: String) {
        guard let i = detailLines.firstIndex(where: { $0.label == label && !$0.isLeftOut }) else { return }
        if detailLines[i].text.hasSuffix("waiting") {
            detailLines[i].text = detailLines[i].text.replacingOccurrences(of: "waiting", with: "reading…")
        }
    }

    // MARK: Outcome

    private func settle(_ exit: FootageSpectrumHelper.Exit) {
        guard state.isActive else { return }
        if let stallReason {
            finish(failed: stallReason)
            return
        }
        if cancelRequested || Task.isCancelled {
            finish(cancelled: true)
            return
        }
        if let d = doneEvent, exit.code == 0 {
            let page = store.pageFile(id)
            guard FileManager.default.fileExists(atPath: page.path) else {
                finish(failed: "The comparison finished but its page was not written.")
                return
            }
            applyResults(d.results, skipped: d.skipped)
            pageURL = page
            fractionValue = 1
            finish(summary: FootageSpectrumWords.summary(files: d.files, summary: d.summary,
                                                         leftOut: (plan?.leftOut.count ?? 0) + d.skipped.count))
            return
        }
        if let e = errorEvent {
            applyResults([], skipped: e.skipped)
            finish(failed: e.missing.map(FootageSpectrumWords.missingDependency) ?? "Compare Footage could not finish: \(e.message)")
            return
        }
        let tail = exit.stderrTail.isEmpty ? "" : " — \(exit.stderrTail)"
        finish(failed: "The comparison helper stopped without finishing (exit \(exit.code))\(tail)")
    }

    private func applyResults(_ results: [FootageSpectrumProtocol.FileResult],
                              skipped: [FootageSpectrumProtocol.Skipped]) {
        for r in results {
            if let i = detailLines.firstIndex(where: { $0.label == r.label && !$0.isLeftOut }) {
                detailLines[i].text = FootageSpectrumWords.verdictWords(r.verdict, offset: r.offset)
            }
        }
        for s in skipped {
            if let i = detailLines.firstIndex(where: { $0.label == s.label && !$0.isLeftOut }) {
                detailLines[i].text = "left out — \(s.reason)"
                detailLines[i].isLeftOut = true
            }
        }
    }

    func handleStall(silentFor: Double) {
        guard state == .running, stallReason == nil, !cancelRequested else { return }
        let attribution = StallMonitor.attribution(forPaths: plan?.paths ?? [])
        stallReason = "Stalled — no progress for \(Int(silentFor))s. \(attribution)"
        appLog.write("\(kind.logVerb) watchdog: \(title) stalled \(Int(silentFor))s — \(attribution); stopping the helper")
        task?.cancel()
    }

    private func finish(summary: String? = nil, failed: String? = nil, cancelled: Bool = false) {
        guard state.isActive else { return }
        if let failed = stallReason ?? failed {
            state = .failed(message: failed)
            subtitleText = failed
        } else if cancelled || cancelRequested {
            state = .cancelled
            subtitleText = "Stopped — the cache is kept, so comparing again is quick"
        } else {
            let text = summary ?? "Done"
            state = .finished(summary: text)
            subtitleText = text
        }
        waitingForVolumeLabel = nil
        // videoscan.log's OUTCOME line is the Center's (exactly once); the
        // console and catalog.log get the same words here.
        if let line = MediaFileOperationsCenter.terminalSummaryLine(verb: kind.logVerb, title: title,
                                                                     state: state, wasRefused: refused) {
            console?(line)
        }
    }

    private func say(_ line: String) {
        appLog.write(line)
        console?(line)
    }
}

// MARK: - Center dispatch

extension MediaFileOperationsCenter {

    /// Start "Compare Footage…" over `candidates`. Plans (order, cap,
    /// reference, left-out) first; fewer than two readable → a refused row
    /// that says why and nothing runs. Otherwise the job takes the read gates
    /// of every file's volume and runs the helper once.
    @discardableResult
    func startFootageSpectrum(candidates: [FootageSpectrumCandidate],
                              title: String,
                              preferredFirst: UUID? = nil,
                              store: FootageSpectrumStore = FootageSpectrumStore(),
                              tools: Result<FootageSpectrumTools, FootageSpectrumRefusal> = FootageSpectrumHelper.locate(),
                              launcher: @escaping FootageSpectrumHelper.Launcher = FootageSpectrumHelper.processRunnerLauncher,
                              console: ((String) -> Void)? = nil) -> FootageSpectrumJob {
        let ids = candidates.map(\.id)
        switch FootageSpectrumPlanner.plan(candidates: candidates, title: title, preferredFirst: preferredFirst) {
        case .failure(let refusal):
            let job = FootageSpectrumJob(refusedTitle: title, requestedIDs: ids, reason: refusal.reason, store: store)
            job.console = console
            add(job)
            console?("compare footage refused: \(title) — \(refusal.reason)")
            return job
        case .success(let plan):
            let job = FootageSpectrumJob(plan: plan, requestedIDs: ids, preferredFirst: preferredFirst, tools: tools,
                                         store: store, gates: gatePlan(forPaths: plan.paths), launcher: launcher)
            job.console = console
            guard add(job) else {
                job.refuseToStart(reason: "Compare Footage runs on the Mac that holds the catalog — this one is a viewer.")
                return job
            }
            let left = plan.leftOut.isEmpty ? "" : " · \(plan.leftOut.count) left out"
            let line = Self.startSummaryLine(verb: job.kind.logVerb, title: job.title,
                                             plan: "read \(plan.members.count) videos (reference: \(plan.reference.filename))\(left) → the spectrum page")
            appLog.write(line)
            console?(line)
            job.start()
            return job
        }
    }
}
