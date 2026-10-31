// JobSupervisor.swift — VideoScanCore/Background
//
// The work queue at the heart of VideoScan Background (design §3): one job
// at a time per LANE, each job a loop over units, Backoff consulted and
// pause/stop honoured between units, a checkpoint rewritten after every
// unit, START/OUTCOME through the injected log (hard rule 5 — nothing runs
// silently; counts: units run · skipped · failed).
//
// Everything durable is in the two stores; everything the supervisor
// itself holds is rebuildable from them, so a `kill -9` of the process
// costs at most the unit in flight. On the next start, a job found with a
// checkpoint gets an OUTCOME line ("interrupted at N of M") before it
// resumes from that checkpoint, so the log never shows a START without an
// OUTCOME (design §6 sensor 5).
//
// Concurrency shape: one actor. Each lane has one Task (created inside the
// actor, so it inherits the actor's isolation); the unit itself runs on the
// cooperative pool because `BackgroundJob.runUnit` is a nonisolated async
// call — the actor is free to answer `status` while a unit runs.
//
// Memory: `runs` holds every known job (≈ 300 B each; a 100k-request queue
// is ≈ 30 MB and is the design's stated scale). Finished jobs are kept for
// the status list up to `finishedHistoryLimit`, then dropped oldest first.
//
// C++ reading: a thread-pool with one worker per named lane and a
// write-ahead checkpoint; `Task` ≈ std::jthread with cooperative cancel.

import Foundation

public actor JobSupervisor {

    public struct Configuration: Sendable {
        /// How often a paused loop re-asks Backoff / the pause flag.
        public var pausePollInterval: Duration = .milliseconds(500)
        /// Progress pushes per job are no closer than this (design §3.3: 4/s).
        public var progressMinInterval: Duration = .milliseconds(250)
        public var finishedHistoryLimit = 50
        public init() {}
    }

    public static let userPauseReason = "user"

    private struct Run {
        var request: JobRequest
        var state: JobRunState = .queued
        var checkpoint: JobCheckpoint?
        var title: String
        var startedAt: Date?
        var finishedAt: Date?
        var pauseRequested = false
        var stopRequested = false
    }

    private let queue: any JobQueueStore
    private let checkpoints: any CheckpointStore
    private let factory: any JobFactory
    private let backoff: Backoff
    private let log: any BackgroundLogSink
    private let configuration: Configuration
    private let clock = ContinuousClock()

    private var runs: [JobID: Run] = [:]
    /// Queue order: oldest first.
    private var order: [JobID] = []
    private var finishedOrder: [JobID] = []
    private var laneTasks: [String: Task<Void, Never>] = [:]
    private var lastActivity: ContinuousClock.Instant
    private var progressSink: (@Sendable (JobProgressSnapshot) -> Void)?
    private var lastPush: [JobID: ContinuousClock.Instant] = [:]
    /// Pushes delivered to the sink — the 4/s test counts them.
    public private(set) var progressPushCount = 0

    public init(queue: any JobQueueStore, checkpoints: any CheckpointStore, factory: any JobFactory,
                backoff: Backoff, log: any BackgroundLogSink, configuration: Configuration = Configuration()) {
        self.queue = queue
        self.checkpoints = checkpoints
        self.factory = factory
        self.backoff = backoff
        self.log = log
        self.configuration = configuration
        self.lastActivity = clock.now
    }

    // MARK: - Lifecycle

    /// Scan the queue folder and register every request (design §3.4) —
    /// without starting a lane. `start()` is `plan()` + lanes; the scale
    /// test times this alone. Returns how many were planned.
    @discardableResult
    public func plan() -> Int {
        let (requests, ignored) = queue.list()
        for line in ignored { log.write("queue: ignored \(line)") }
        var added = 0
        for request in requests where runs[request.id] == nil {
            var run = Run(request: request, title: request.kind.rawValue)
            switch checkpoints.load(request.id) {
            case .found(let cp):
                run.checkpoint = cp
                // The START this job had is matched by an OUTCOME here, before it resumes.
                log.write("OUTCOME \(request.kind) \(request.id) — interrupted at \(cp.completedUnits) of \(cp.totalUnits) (found at relaunch: \(cp.unitsRun) run · \(cp.unitsSkipped) skipped · \(cp.unitsFailed) failed); resuming from the checkpoint")
            case .corrupt(let words):
                log.write("checkpoint for \(request.id) is unreadable (\(words)) — the job restarts from zero")
                checkpoints.remove(request.id)
            case .none:
                break
            }
            runs[request.id] = run
            order.append(request.id)
            added += 1
        }
        touch()
        return added
    }

    /// `plan()` then run every lane that has work.
    public func start() {
        plan()
        kickLanes()
    }

    /// Wait until every lane is idle (tests; the CLI never needs it).
    public func drain() async {
        while let task = laneTasks.values.first {
            await task.value
        }
    }

    /// Simulates the process dying: cancels every lane without writing
    /// anything. Units already checkpointed stay; the unit in flight is lost
    /// exactly as under `kill -9`. Test seam.
    public func abandonForTest() {
        for task in laneTasks.values { task.cancel() }
        laneTasks.removeAll()
    }

    public func setProgressSink(_ sink: (@Sendable (JobProgressSnapshot) -> Void)?) {
        progressSink = sink
    }

    // MARK: - Verbs (XPC)

    public func enqueue(_ request: JobRequest) -> EnqueueReply {
        touch()
        if runs[request.id] != nil { return .refused(Refusal("job \(request.id) is already known")) }
        do {
            _ = try factory.makeJob(for: request)
        } catch {
            let words = (error as? Refusal)?.words ?? String(describing: error)
            log.write("enqueue refused: \(words)")
            return .refused(Refusal(words))
        }
        do {
            try queue.put(request)
        } catch {
            let words = "could not write the queue file for \(request.id): \(error)"
            log.write("enqueue refused: \(words)")
            return .refused(Refusal(words))
        }
        runs[request.id] = Run(request: request, title: request.kind.rawValue)
        order.append(request.id)
        log.write("queued \(request.kind) \(request.id) (lane \(request.lane), by \(request.requestedBy))")
        kickLanes()
        return .accepted(request.id)
    }

    @discardableResult
    public func pause(_ id: JobID) -> Bool {
        touch()
        guard var run = runs[id], run.state.isActive else { return false }
        run.pauseRequested = true
        if run.state == .running { run.state = .pausing }
        runs[id] = run
        log.write("pause requested for \(run.request.kind) \(id)")
        return true
    }

    @discardableResult
    public func resume(_ id: JobID) -> Bool {
        touch()
        guard var run = runs[id], run.state.isActive else { return false }
        run.pauseRequested = false
        runs[id] = run
        log.write("resume requested for \(run.request.kind) \(id)")
        return true
    }

    @discardableResult
    public func stop(_ id: JobID) -> Bool {
        touch()
        guard var run = runs[id], run.state.isActive else { return false }
        run.stopRequested = true
        runs[id] = run
        log.write("stop requested for \(run.request.kind) \(id)")
        if run.state == .queued { finish(id, as: .stopped, elapsed: nil) }
        return true
    }

    public func status(processIdentifier: Int32, startedAt: Date) async -> ServiceStatus {
        touch()
        let state = await backoff.refresh()
        return ServiceStatus(processIdentifier: processIdentifier, startedAt: startedAt, backoff: state,
                             jobs: order.compactMap { snapshot($0) }, idleSeconds: idleSeconds)
    }

    public func snapshot(_ id: JobID) -> JobProgressSnapshot? {
        guard let run = runs[id] else { return nil }
        let cp = run.checkpoint
        let completed = cp?.completedUnits ?? 0
        let total = cp?.totalUnits ?? 0
        return JobProgressSnapshot(
            id: id, kind: run.request.kind, lane: run.request.lane, title: run.title,
            subtitle: total > 0 ? "unit \(completed) of \(total) — \(run.state.words)" : run.state.words,
            completedUnits: completed, totalUnits: total,
            skippedUnits: cp?.unitsSkipped ?? 0, failedUnits: cp?.unitsFailed ?? 0,
            state: run.state, startedAt: run.startedAt, finishedAt: run.finishedAt)
    }

    // MARK: - Idle

    /// Seconds since a unit finished or a verb arrived.
    public var idleSeconds: Double {
        let d = clock.now - lastActivity
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    public var activeJobCount: Int { runs.values.filter { $0.state.isActive }.count }

    /// `IdleExitPolicy` over this supervisor's state (design §3.2).
    public func shouldExitWhenIdle(threshold: Double = IdleExitPolicy.defaultIdleSeconds) -> Bool {
        let queued = queue.list().requests.count
        return IdleExitPolicy.shouldExit(idleSeconds: idleSeconds, queueEmpty: queued == 0,
                                         activeJobs: activeJobCount, threshold: threshold)
    }

    private func touch() { lastActivity = clock.now }

    // MARK: - Lanes

    private func kickLanes() {
        let lanes = Set(order.compactMap { runs[$0] }.filter { $0.state == .queued }.map(\.request.lane))
        for lane in lanes where laneTasks[lane] == nil {
            laneTasks[lane] = Task { await self.runLane(lane) }
        }
    }

    private func nextQueued(in lane: String) -> JobID? {
        order.first { id in
            guard let run = runs[id] else { return false }
            return run.state == .queued && run.request.lane == lane
        }
    }

    private func runLane(_ lane: String) async {
        while !Task.isCancelled, let id = nextQueued(in: lane) {
            await run(id)
        }
        laneTasks[lane] = nil
    }

    // MARK: - One job

    /// What a hold between units decided.
    private enum HoldOutcome {
        case proceed(BackoffState)
        case stop
        case killed
    }

    private func run(_ id: JobID) async {
        guard let job = instantiate(id), var run = runs[id] else { return }
        let request = run.request
        var cp = run.checkpoint ?? JobCheckpoint(jobID: id, totalUnits: job.unitCount)
        let resumed = run.checkpoint != nil
        run.title = job.title
        run.state = .running
        run.startedAt = Date()
        run.checkpoint = cp
        runs[id] = run
        let began = clock.now
        log.write("START \(request.kind) \(id) — \(cp.totalUnits) units, lane \(request.lane), by \(request.requestedBy)"
                  + (resumed ? ", resuming at unit \(cp.completedUnits)" : ""))
        push(id, force: true)

        while cp.completedUnits < cp.totalUnits {
            switch await holdBetweenUnits(id, cp) {
            case .killed: return
            case .stop: return conclude(id, cp, began: began, stopped: true)
            case .proceed(let state):
                if state == .trickle {
                    try? await Task.sleep(for: backoff.trickleInterval)
                    if Task.isCancelled { return }
                }
            }
            if await performUnit(job, &cp, id) == .killed { return }
            guard persist(cp, id) else { return }
        }
        conclude(id, cp, began: began, stopped: runs[id]?.stopRequested == true)
    }

    /// The factory's job for `id`, or the refusal written as START…refused.
    private func instantiate(_ id: JobID) -> (any BackgroundJob)? {
        guard let run = runs[id] else { return nil }
        do {
            return try factory.makeJob(for: run.request)
        } catch {
            let words = (error as? Refusal)?.words ?? String(describing: error)
            log.write("START \(run.request.kind) \(id) — refused: \(words)")
            finish(id, as: .failed(reason: words), elapsed: nil)
            return nil
        }
    }

    /// Between units: honour a user pause, then Backoff (design §3.5). Returns
    /// once the job may run a unit, or should stop, or the process is gone.
    private func holdBetweenUnits(_ id: JobID, _ cp: JobCheckpoint) async -> HoldOutcome {
        guard let kind = runs[id]?.request.kind.rawValue else { return .killed }
        let place = "at \(cp.completedUnits) of \(cp.totalUnits)"
        if let early = await holdForUserPause(id, kind: kind, place: place) { return early }
        return await holdForBackoff(id, kind: kind, place: place)
    }

    /// Pause/stop from the verbs. nil means "carry on".
    private func holdForUserPause(_ id: JobID, kind: String, place: String) async -> HoldOutcome? {
        if Task.isCancelled { return .killed }
        if runs[id]?.stopRequested == true { return .stop }
        guard runs[id]?.pauseRequested == true else { return nil }
        setState(id, .paused(reason: Self.userPauseReason))
        log.write("\(kind) \(id) paused by user \(place)")
        push(id, force: true)
        while runs[id]?.pauseRequested == true, runs[id]?.stopRequested != true, !Task.isCancelled {
            try? await Task.sleep(for: configuration.pausePollInterval)
        }
        if Task.isCancelled { return .killed }
        if runs[id]?.stopRequested == true { return .stop }
        setState(id, .running)
        log.write("\(kind) \(id) resumed \(place)")
        return nil
    }

    /// The Mac's say (thermal, memory): wait out a Backoff pause.
    private func holdForBackoff(_ id: JobID, kind: String, place: String) async -> HoldOutcome {
        var state = await backoff.refresh()
        guard case .paused(let reason) = state else { return .proceed(state) }
        setState(id, .paused(reason: reason))
        log.write("\(kind) \(id) paused (\(reason)) \(place)")
        push(id, force: true)
        while state.isPaused, runs[id]?.stopRequested != true, !Task.isCancelled {
            try? await Task.sleep(for: configuration.pausePollInterval)
            state = await backoff.refresh()
        }
        if Task.isCancelled { return .killed }
        if runs[id]?.stopRequested == true { return .stop }
        setState(id, .running)
        log.write("\(kind) \(id) resumed (backoff \(state.words)) \(place)")
        return .proceed(state)
    }

    private enum UnitEnd { case recorded, killed }

    /// Run unit `cp.completedUnits` and count it (done / skipped / failed).
    /// A cancellation (the process "dying") records nothing.
    private func performUnit(_ job: any BackgroundJob, _ cp: inout JobCheckpoint, _ id: JobID) async -> UnitEnd {
        let index = cp.completedUnits
        do {
            switch try await job.runUnit(index) {
            case .done: cp.unitsRun += 1
            case .skipped: cp.unitsSkipped += 1
            }
        } catch is CancellationError {
            return .killed
        } catch {
            cp.unitsFailed += 1
            log.write("\(runs[id]?.request.kind.rawValue ?? "?") \(id) unit \(index) failed: \(error)")
        }
        if Task.isCancelled { return .killed }
        cp.completedUnits += 1
        cp.updatedAt = Date()
        return .recorded
    }

    /// Write the checkpoint — the proof of the unit. Without it the unit is
    /// not done: leave the queue file, say why, end the job paused(disk).
    private func persist(_ cp: JobCheckpoint, _ id: JobID) -> Bool {
        runs[id]?.checkpoint = cp
        do {
            try checkpoints.save(cp)
        } catch {
            let kind = runs[id]?.request.kind.rawValue ?? "?"
            setState(id, .paused(reason: BackoffState.diskReason))
            log.write("OUTCOME \(kind) \(id) — paused (disk) at \(cp.completedUnits) of \(cp.totalUnits): checkpoint could not be written (\(error)); \(cp.unitsRun) run · \(cp.unitsSkipped) skipped · \(cp.unitsFailed) failed")
            push(id, force: true)
            return false
        }
        touch()
        push(id, force: false)
        return true
    }

    /// The OUTCOME line and the terminal transition.
    private func conclude(_ id: JobID, _ cp: JobCheckpoint, began: ContinuousClock.Instant, stopped: Bool) {
        let kind = runs[id]?.request.kind.rawValue ?? "?"
        let elapsed = clock.now - began
        let counts = "\(cp.unitsRun) run · \(cp.unitsSkipped) skipped · \(cp.unitsFailed) failed in \(Self.seconds(elapsed))"
        if stopped {
            log.write("OUTCOME \(kind) \(id) — stopped at \(cp.completedUnits) of \(cp.totalUnits): \(counts)")
            finish(id, as: .stopped, elapsed: elapsed)
        } else {
            log.write("OUTCOME \(kind) \(id) — finished: \(counts)")
            finish(id, as: .finished, elapsed: elapsed)
        }
    }

    private func setState(_ id: JobID, _ state: JobRunState) {
        runs[id]?.state = state
    }

    /// Terminal transition: the queue file and checkpoint go (the job is
    /// over), the run stays in the status list for a while.
    private func finish(_ id: JobID, as state: JobRunState, elapsed: Duration?) {
        guard var run = runs[id] else { return }
        run.state = state
        run.finishedAt = Date()
        runs[id] = run
        queue.remove(id)
        checkpoints.remove(id)
        touch()
        push(id, force: true)
        finishedOrder.append(id)
        while finishedOrder.count > configuration.finishedHistoryLimit {
            let old = finishedOrder.removeFirst()
            runs[old] = nil
            lastPush[old] = nil
            order.removeAll { $0 == old }
        }
    }

    private func push(_ id: JobID, force: Bool) {
        guard let sink = progressSink, let snapshot = snapshot(id) else { return }
        let now = clock.now
        if !force, let last = lastPush[id], now - last < configuration.progressMinInterval { return }
        lastPush[id] = now
        progressPushCount += 1
        sink(snapshot)
    }

    private static func seconds(_ d: Duration) -> String {
        let s = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        return String(format: "%.1f s", s)
    }
}
