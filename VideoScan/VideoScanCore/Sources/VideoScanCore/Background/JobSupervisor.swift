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
// Fail fast (2026-11-03): `failFastUnits` units in a row failing with the
// same words, each `failureIsSystemic`, end the job `.failed` with those
// words in its OUTCOME; a repeat failure is logged as "the same error as
// unit N", so the words are said once (`FailureStreak`).
//
// One supervisor per state root (2026-11-02): before it adopts or accepts a
// job the supervisor claims the root through `StateRootOwnership`. A hand
// run and the launchd service share the folders; whichever claims first
// runs the jobs, the other serves status, refuses enqueue, and asks again
// every `ownerRetryInterval` until the holder is gone (`StateRootLock.swift`).
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
        /// How long a `.deferred` unit waits before it is asked again.
        public var deferRetryInterval: Duration = .seconds(30)
        /// How often a supervisor that does not own its state root asks again.
        public var ownerRetryInterval: Duration = .seconds(30)
        /// Fail fast (2026-11-03: a missing ffmpeg failed 523 of 523 era
        /// units over 44 minutes, logged 523 times, and ended "finished"):
        /// this many units in a row that fail with the SAME words, each one
        /// `failureIsSystemic`, stop the job as failed. 5 because: it costs
        /// ≤ 5 units (≈ 25 s at that failure's 5 s/unit, after one model load)
        /// instead of the whole plan; a per-file failure names its file, so
        /// five identical words in a row are the environment or the worker,
        /// not five bad files (the per-file failures whose words carry no
        /// path — timeouts, worker deaths — are not systemic); and five, not
        /// two, rides out a one-off hiccup (a worker respawn) mid-night.
        public var failFastUnits = 5
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
        /// paused(disk): no lane owns it until `resume` re-queues it.
        var parked = false
        /// The last `.deferred` unit's reason while the job is still waiting
        /// for it (checklist F3, 2026-11-03); cleared when a unit records or
        /// the state changes. Published as `JobProgressSnapshot.waiting`.
        var waiting: String?
    }

    private let queue: any JobQueueStore
    private let checkpoints: any CheckpointStore
    private let factory: any JobFactory
    private let backoff: Backoff
    private let log: any BackgroundLogSink
    private let configuration: Configuration
    private let ownership: any StateRootOwnership
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
    /// Why this supervisor is not running jobs — the holder's words — or nil
    /// while it owns the root (tests and the status line read it).
    public private(set) var ownershipRefusal: String?
    private var ownerRetry: Task<Void, Never>?

    public init(queue: any JobQueueStore, checkpoints: any CheckpointStore, factory: any JobFactory,
                backoff: Backoff, log: any BackgroundLogSink, configuration: Configuration = Configuration(),
                ownership: any StateRootOwnership = UncontestedStateRoot()) {
        self.queue = queue
        self.checkpoints = checkpoints
        self.factory = factory
        self.backoff = backoff
        self.log = log
        self.configuration = configuration
        self.ownership = ownership
        self.lastActivity = clock.now
    }

    deinit { ownership.release() }

    // MARK: - Ownership

    /// True once this process owns the state root. Logs the holder's words
    /// once per change, never once per poll.
    private func claimRoot() -> Bool {
        switch ownership.claim() {
        case .success:
            if ownershipRefusal != nil {
                log.write("state root is free — this process owns it now")
                ownershipRefusal = nil
            }
            return true
        case .failure(let refusal):
            if ownershipRefusal != refusal.words {
                log.write("not running jobs: \(refusal.words); serving status only, asking again every \(configuration.ownerRetryInterval.components.seconds) s")
                ownershipRefusal = refusal.words
            }
            return false
        }
    }

    private func scheduleOwnerRetry() {
        guard ownerRetry == nil else { return }
        let interval = configuration.ownerRetryInterval
        ownerRetry = Task { [weak self] in
            try? await Task.sleep(for: interval)
            await self?.retryOwnership()
        }
    }

    private func retryOwnership() {
        ownerRetry = nil
        guard !Task.isCancelled else { return }
        start()
    }

    // MARK: - Lifecycle

    /// Scan the queue folder and register every request (design §3.4) —
    /// without starting a lane. `start()` is `plan()` + lanes; the scale
    /// test times this alone. Returns how many were planned.
    @discardableResult
    public func plan() -> Int {
        guard claimRoot() else { return 0 }
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

    /// `plan()` then run every lane that has work. Without the root it plans
    /// nothing and tries again after `ownerRetryInterval`.
    public func start() {
        plan()
        guard ownershipRefusal == nil else { scheduleOwnerRetry(); return }
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
        ownerRetry?.cancel()
        ownerRetry = nil
        // The kernel drops a dead process's flock; this stands in for that.
        ownership.release()
    }

    public func setProgressSink(_ sink: (@Sendable (JobProgressSnapshot) -> Void)?) {
        progressSink = sink
    }

    // MARK: - Verbs (XPC)

    public func enqueue(_ request: JobRequest) -> EnqueueReply {
        touch()
        if runs[request.id] != nil { return .refused(Refusal("job \(request.id) is already known")) }
        guard claimRoot() else {
            let words = "enqueue refused: \(ownershipRefusal ?? "the state root is owned by another process")"
            log.write(words)
            return .refused(Refusal(words))
        }
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
        // Resume before the pause landed: the row must not keep saying "pausing…".
        if run.state == .pausing { run.state = .running }
        if run.parked {
            // A disk-full pause has no lane; queue it again and a lane picks it up
            // from its checkpoint (review 2026-10-30, fix 1).
            run.parked = false
            run.state = .queued
            runs[id] = run
            log.write("resume requested for \(run.request.kind) \(id) — re-queued after its disk pause")
            kickLanes()
            return true
        }
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
        // Nobody will revisit a queued or parked job: end it here.
        if run.state == .queued || run.parked { finish(id, as: .stopped, checkpoint: run.checkpoint, elapsed: nil) }
        return true
    }

    /// The service's answer. Reading it is NOT activity (checklist F5,
    /// 2026-11-03): the helper's own menu bar reads it every 5 s, and a
    /// `touch()` here kept `idleSeconds` near zero forever, so an empty
    /// service never exited. A message from a client (the app over XPC) says
    /// so with `noteClientActivity()` — XPCServer does, before it asks.
    public func status(processIdentifier: Int32, startedAt: Date) async -> ServiceStatus {
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
            state: run.state, startedAt: run.startedAt, finishedAt: run.finishedAt,
            waiting: run.state == .running || run.state == .pausing ? run.waiting : nil)
    }

    // MARK: - Idle

    /// Seconds since a unit finished or a verb arrived.
    public var idleSeconds: Double {
        let d = clock.now - lastActivity
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    public var activeJobCount: Int { runs.values.filter { $0.state.isActive }.count }

    /// Active jobs that hold the service up. A job parked by a full disk does
    /// not: the next launch finds its checkpoint and resumes it.
    private var holdingJobCount: Int { runs.values.filter { $0.state.isActive && !$0.parked }.count }

    /// `IdleExitPolicy` over this supervisor's state (design §3.2). The cheap
    /// checks first; the queue folder is decoded only when they say "maybe".
    public func shouldExitWhenIdle(threshold: Double = IdleExitPolicy.defaultIdleSeconds) -> Bool {
        guard holdingJobCount == 0, idleSeconds >= threshold else { return false }
        // A queue file whose job this build refused (kept: it is the app's intent)
        // or parked is not pending work.
        let pending = queue.list().requests.filter { request in
            guard let run = runs[request.id] else { return true }
            return run.state.isActive && !run.parked
        }
        return IdleExitPolicy.shouldExit(idleSeconds: idleSeconds, queueEmpty: pending.isEmpty,
                                         activeJobs: holdingJobCount, threshold: threshold)
    }

    private func touch() { lastActivity = clock.now }

    /// A client spoke (the app's XPC status poll — 60 s while VideoScan runs
    /// with the service on, 5 s while Settings is open). That is activity:
    /// exiting under a client that asks again within the minute would only
    /// trade one process for a relaunch (launchd starts the helper on the
    /// next message) and flicker the menu item. With VideoScan closed nobody
    /// asks, and the idle exit runs (F5).
    public func noteClientActivity() { touch() }

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
        let detail = job.startDetail
        log.write("START \(request.kind) \(id) — \(cp.totalUnits) units, lane \(request.lane), by \(request.requestedBy)"
                  + (resumed ? ", resuming at unit \(cp.completedUnits)" : "") + (detail.isEmpty ? "" : "; \(detail)"))
        push(id, force: true)
        // The checkpoint exists from START, so a kill during unit 0 still lets the
        // relaunch write this START's OUTCOME (review 2026-10-30, fix 3a).
        guard persist(cp, id) else { return }

        var turn = Turn()
        while cp.completedUnits < cp.totalUnits {
            switch await step(job, &cp, id, &turn) {
            case .killed: return
            case .stop: return await end(job, id, as: .stopped, cp, began)
            case .failFast(let reason): return await end(job, id, as: .failed(reason: reason), cp, began)
            case .next: continue
            }
        }
        await end(job, id, as: runs[id]?.stopRequested == true ? .stopped : .finished, cp, began)
    }

    private enum Step { case next, stop, killed, failFast(String) }

    /// What one job's loop carries from unit to unit: the wait it last said,
    /// and the run of identical systemic failures (fail fast).
    private struct Turn {
        var deferredSaid: String?
        var streak = FailureStreak()
    }

    /// One unit's turn: the hold between units (pause / stop / Backoff and
    /// the trickle cadence), the unit, then its checkpoint — or, for a
    /// `.deferred` unit, a wait and no checkpoint (said once per reason).
    private func step(_ job: any BackgroundJob, _ cp: inout JobCheckpoint, _ id: JobID, _ turn: inout Turn) async -> Step {
        switch await holdBetweenUnits(id, cp) {
        case .killed: return .killed
        case .stop: return .stop
        case .proceed(let state):
            if state == .trickle {
                try? await Task.sleep(for: backoff.trickleInterval)
                if Task.isCancelled { return .killed }
            }
        }
        switch await performUnit(job, &cp, id, &turn.streak) {
        case .killed: return .killed
        case .deferred(let reason):
            noteWait(id, reason: reason, at: cp, said: &turn.deferredSaid)
            try? await Task.sleep(for: configuration.deferRetryInterval)
            return Task.isCancelled ? .killed : .next
        case .recorded:
            turn.deferredSaid = nil
            runs[id]?.waiting = nil
        }
        guard persist(cp, id) else { return .killed }
        if let words = turn.streak.words, turn.streak.length >= max(1, configuration.failFastUnits) {
            return .failFast("units \(turn.streak.streakStart)–\(cp.completedUnits - 1), \(turn.streak.length) in a row, all failed with the same error, "
                             + "so the job stopped (\(cp.totalUnits - cp.completedUnits) not tried; nothing was written for them, the next plan holds them all): \(words)")
        }
        return .next
    }

    /// A unit came back `.deferred`: say the wait once per reason in the log,
    /// and publish it on the row (`waiting`) once, so no surface reads the
    /// job as working while no unit can start (F3).
    private func noteWait(_ id: JobID, reason: String, at cp: JobCheckpoint, said: inout String?) {
        if said != reason {
            let kind = runs[id]?.request.kind.rawValue ?? "?"
            log.write("\(kind) \(id) waits at \(cp.completedUnits) of \(cp.totalUnits): \(reason)")
            said = reason
        }
        guard runs[id]?.waiting != reason else { return }
        runs[id]?.waiting = reason
        push(id, force: true)
    }

    /// The job's own release and words, then the one terminal door.
    private func end(_ job: any BackgroundJob, _ id: JobID, as state: JobRunState, _ cp: JobCheckpoint, _ began: ContinuousClock.Instant) async {
        await job.end()
        let detail = await job.outcomeDetail()
        finish(id, as: state, checkpoint: cp, elapsed: clock.now - began, detail: detail)
    }

    /// The factory's job for `id`, or the refusal written as START…refused.
    private func instantiate(_ id: JobID) -> (any BackgroundJob)? {
        guard let run = runs[id] else { return nil }
        do {
            return try factory.makeJob(for: run.request)
        } catch {
            let words = (error as? Refusal)?.words ?? String(describing: error)
            log.write("START \(run.request.kind) \(id) — refused: \(words)")
            finish(id, as: .failed(reason: words), checkpoint: nil, elapsed: nil, keepQueueFile: true)
            return nil
        }
    }

    /// Between units: honour a user pause, then Backoff (design §3.5). Returns
    /// once the job may run a unit, or should stop, or the process is gone.
    private func holdBetweenUnits(_ id: JobID, _ cp: JobCheckpoint) async -> HoldOutcome {
        guard let kind = runs[id]?.request.kind.rawValue else { return .killed }
        let place = "at \(cp.completedUnits) of \(cp.totalUnits)"
        while true {
            if let early = await holdForUserPause(id, kind: kind, place: place) { return early }
            let outcome = await holdForBackoff(id, kind: kind, place: place)
            // A pause asked for during the Mac's hold is honoured before any unit runs.
            guard case .proceed = outcome, runs[id]?.pauseRequested == true else { return outcome }
        }
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

    private enum UnitEnd { case recorded, killed, deferred(String) }

    /// Run unit `cp.completedUnits` and count it (done / skipped / failed).
    /// A cancellation (the process "dying") records nothing. A failure that
    /// repeats the one before it word for word is logged as "the same error
    /// as unit N", so a run of them says its words once.
    private func performUnit(_ job: any BackgroundJob, _ cp: inout JobCheckpoint, _ id: JobID, _ streak: inout FailureStreak) async -> UnitEnd {
        let index = cp.completedUnits
        do {
            switch try await job.runUnit(index) {
            case .done: cp.unitsRun += 1
            case .skipped: cp.unitsSkipped += 1
            case .deferred(let reason): return Task.isCancelled ? .killed : .deferred(reason)
            }
            streak = FailureStreak()
        } catch is CancellationError where Task.isCancelled {
            return .killed
        } catch {
            cp.unitsFailed += 1
            let words = String(describing: error)
            let kind = runs[id]?.request.kind.rawValue ?? "?"
            if let first = streak.repeats(words) {
                log.write("\(kind) \(id) unit \(index) failed: the same error as unit \(first)")
            } else {
                log.write("\(kind) \(id) unit \(index) failed: \(words)")
            }
            streak.record(words, unit: index, systemic: job.failureIsSystemic(error))
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
            runs[id]?.parked = true
            log.write("OUTCOME \(kind) \(id) — paused (disk) at \(cp.completedUnits) of \(cp.totalUnits): checkpoint could not be written (\(error)); \(cp.unitsRun) run · \(cp.unitsSkipped) skipped · \(cp.unitsFailed) failed")
            push(id, force: true)
            return false
        }
        touch()
        push(id, force: false)
        return true
    }

    private func setState(_ id: JobID, _ state: JobRunState) {
        runs[id]?.state = state
        runs[id]?.waiting = nil
    }

    /// THE terminal transition — the one door every job leaves through, and
    /// the one place the OUTCOME line is written (≈ the RAII guard's
    /// destructor: a START cannot end without it). The checkpoint goes; the
    /// queue file goes too, except for a job this build REFUSED at START
    /// (`keepQueueFile`) — that file is the app's intent and is kept for a
    /// build that knows the kind (refuse, never erase). A job that failed fast
    /// mid-run is not a refusal: its file goes, or every relaunch would
    /// resurrect it beside the fresh job the app queues on its next recount.
    /// The run stays in the status list for a while.
    private func finish(_ id: JobID, as state: JobRunState, checkpoint cp: JobCheckpoint?, elapsed: Duration?, detail: String = "",
                        keepQueueFile: Bool = false) {
        guard var run = runs[id] else { return }
        run.state = state
        run.finishedAt = Date()
        run.parked = false
        run.waiting = nil
        runs[id] = run
        log.write(Self.outcomeLine(kind: run.request.kind.rawValue, id: id, state: state, checkpoint: cp, elapsed: elapsed,
                                   queueFileKept: keepQueueFile)
                  + (detail.isEmpty ? "" : "; \(detail)"))
        if !keepQueueFile { queue.remove(id) }
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

    /// The OUTCOME line for a terminal state, with the counts when there are any.
    static func outcomeLine(kind: String, id: JobID, state: JobRunState, checkpoint cp: JobCheckpoint?, elapsed: Duration?,
                            queueFileKept: Bool = true) -> String {
        let counts = cp.map { "\($0.unitsRun) run · \($0.unitsSkipped) skipped · \($0.unitsFailed) failed" } ?? "0 run · 0 skipped · 0 failed"
        let time = elapsed.map { " in \(seconds($0))" } ?? ""
        switch state {
        case .finished:
            return "OUTCOME \(kind) \(id) — finished: \(counts)\(time)"
        case .stopped:
            let place = cp.map { "at \($0.completedUnits) of \($0.totalUnits)" } ?? "before it started"
            return "OUTCOME \(kind) \(id) — stopped \(place): \(counts)\(time)"
        case .failed(let reason):
            return "OUTCOME \(kind) \(id) — failed: \(reason); \(counts)\(time)" + (queueFileKept ? "; the queue file is kept" : "")
        case .queued, .running, .pausing, .paused:
            return "OUTCOME \(kind) \(id) — \(state.words): \(counts)\(time)"
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

/// The run of failures one job is in. Two runs, both reset by a success or
/// different words: the run of IDENTICAL words (`firstUnit`, for the log's
/// "the same error as unit N"), and inside it the run of identical SYSTEMIC
/// failures (`streakStart`, `length`) that fail fast counts — a same-word
/// failure the job calls per-file breaks that one (Codex #232 F6). Pure
/// value; the supervisor keeps one per job loop (C++: a small struct passed
/// by reference).
struct FailureStreak: Equatable {
    private(set) var lastWords: String?
    private(set) var firstUnit = 0
    private(set) var streakStart = 0
    private(set) var length = 0

    /// The words of a systemic run in progress, else nil.
    var words: String? { length >= 1 ? lastWords : nil }

    /// The unit the identical-words run began at, when `words` repeats it exactly.
    func repeats(_ words: String) -> Int? { lastWords == words ? firstUnit : nil }

    mutating func record(_ words: String, unit: Int, systemic: Bool) {
        if lastWords != words {
            self = FailureStreak(lastWords: words, firstUnit: unit, streakStart: unit, length: systemic ? 1 : 0)
        } else if !systemic {
            length = 0
        } else {
            if length == 0 { streakStart = unit }
            length += 1
        }
    }
}
