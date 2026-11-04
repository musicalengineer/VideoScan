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
// The helper owns its schedule (Rick 2026-11-04): with a `JobSchedule`, the
// owner plans by itself — at start, every `planInterval`, and when the
// catalog generation changes — enqueues each scheduled kind that has work and
// no active job, and HOLDS a kind whose job failed until Resume, a new build
// or a catalog change (`JobSchedule.swift`). No energy backoff: units run back
// to back; only Pause, a hold, or the Mac's own thermal / memory pause stop them.
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
        /// A unit found in flight at this many relaunches (the helper died
        /// inside it each time — a crash loop launchd only throttles) is
        /// quarantined: counted failed and skipped. 3: one crash is bad luck,
        /// three on the same file is the file.
        public var crashQuarantineAttempts = 3
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
    /// When a unit last finished or a job ended (`ServiceStatus.idleSeconds`).
    private var lastActivity: ContinuousClock.Instant
    private var progressSink: (@Sendable (JobProgressSnapshot) -> Void)?
    private var lastPush: [JobID: ContinuousClock.Instant] = [:]
    /// Pushes delivered to the sink — the 4/s test counts them.
    public private(set) var progressPushCount = 0
    /// Why this supervisor is not running jobs — the holder's words — or nil
    /// while it owns the root (tests and the status line read it).
    public private(set) var ownershipRefusal: String?
    private var ownerRetry: Task<Void, Never>?

    // The schedule (nil: a hand run or a test that only enqueues).
    private let schedule: JobSchedule?
    private var scheduleTask: Task<Void, Never>?
    private var lastPlanAt: ContinuousClock.Instant?
    private var lastGeneration: Int?
    /// Scheduled kinds Rick paused (paused.json): a restart keeps them paused.
    private var pausedKinds: Set<JobKind> = []
    /// Kinds whose job just ended: the next tick re-measures the plan (so the
    /// size shown is current) but does not queue — a plan that did not shrink
    /// would otherwise re-run the same job back to back (Fable review 11/04).
    private var measureOnly: Set<JobKind> = []
    /// Every hold record, active or released-by-catalog (`holds.json`).
    private var holds: [ScheduleHold] = []
    private var holdsLoaded = false
    /// The last plan size per kind (status: "N files to analyze").
    private var planned: [String: Int] = [:]
    /// Words last logged per kind for a plan that could not be made.
    private var planProblem: [String: String] = [:]
    /// Scheduling ticks that planned (tests).
    public private(set) var planCount = 0

    public init(queue: any JobQueueStore, checkpoints: any CheckpointStore, factory: any JobFactory,
                backoff: Backoff, log: any BackgroundLogSink, configuration: Configuration = Configuration(),
                ownership: any StateRootOwnership = UncontestedStateRoot(), schedule: JobSchedule? = nil) {
        self.queue = queue
        self.checkpoints = checkpoints
        self.factory = factory
        self.backoff = backoff
        self.log = log
        self.configuration = configuration
        self.ownership = ownership
        self.schedule = schedule
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
        for request in onePerScheduledKind(requests) where runs[request.id] == nil {
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
        return added
    }

    /// At most one request per scheduled kind is adopted (a dead `--run era`
    /// can leave a second one; Codex #236 F3, #241 F4): an already-known one,
    /// else one with a checkpoint, else the oldest. The others are logged and
    /// their files removed.
    private func onePerScheduledKind(_ requests: [JobRequest]) -> [JobRequest] {
        guard schedule != nil else { return requests }
        var keep: [JobKind: JobID] = [:]
        for kind in Set(requests.map(\.kind)) where isScheduled(kind) {
            let mine = requests.filter { $0.kind == kind }
            keep[kind] = runs.first { $0.value.request.kind == kind && $0.value.state.isActive }?.key
                ?? (mine.first { checkpoints.load($0.id) != .none } ?? mine[0]).id
        }
        return requests.filter { request in
            guard let kept = keep[request.kind], kept != request.id, runs[request.id] == nil else { return true }
            log.write("queue: \(request.kind) \(request.id) is a second request of a scheduled kind — removed (\(kept) is kept)")
            queue.remove(request.id)
            checkpoints.remove(request.id)
            return false
        }
    }

    /// `plan()` then run every lane that has work, then the schedule's loop.
    /// Without the root it plans nothing and tries again after `ownerRetryInterval`.
    public func start() {
        plan()
        guard ownershipRefusal == nil else { scheduleOwnerRetry(); return }
        loadHolds()        // before any lane: an adopted request of a held kind must not start (Codex #235 F3)
        // A paused kind stays paused across a restart (Rick 11/04).
        for (id, run) in runs where pausedKinds.contains(run.request.kind) && run.state.isActive { runs[id]?.pauseRequested = true }
        kickLanes()
        startSchedule()
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
        scheduleTask?.cancel()
        scheduleTask = nil
        ownerRetry?.cancel()
        ownerRetry = nil
        // The kernel drops a dead process's flock; this stands in for that.
        ownership.release()
    }

    public func setProgressSink(_ sink: (@Sendable (JobProgressSnapshot) -> Void)?) {
        progressSink = sink
    }

    // MARK: - Verbs (XPC)

    /// The XPC / CLI verb. A scheduled kind is the helper's own business
    /// (Rick 11/04): refused here; only the schedule admits it.
    public func enqueue(_ request: JobRequest) -> EnqueueReply {
        if isScheduled(request.kind) {
            let words = "enqueue refused: VideoScan Background schedules \(request.kind) itself (use --run \(request.kind) for a hand run)"
            log.write(words)
            return .refused(Refusal(words))
        }
        return admit(request)
    }

    /// Admission: ownership, the job's own refusal (factory), the queue file.
    private func admit(_ request: JobRequest) -> EnqueueReply {
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
        var run = Run(request: request, title: request.kind.rawValue)
        run.pauseRequested = pausedKinds.contains(request.kind)
        runs[request.id] = run
        order.append(request.id)
        log.write("queued \(request.kind) \(request.id) (lane \(request.lane), by \(request.requestedBy))" + (run.pauseRequested ? " — paused, as its kind is" : ""))
        kickLanes()
        return .accepted(request.id)
    }

    @discardableResult
    public func pause(_ id: JobID) -> Bool {
        guard var run = runs[id], run.state.isActive else { return false }
        run.pauseRequested = true
        if run.state == .running { run.state = .pausing }
        runs[id] = run
        log.write("pause requested for \(run.request.kind) \(id)")
        if isScheduled(run.request.kind), pausedKinds.insert(run.request.kind).inserted { savePaused() }
        return true
    }

    @discardableResult
    public func resume(_ id: JobID) -> Bool {
        // Resume on a held kind's failed job (the menu's line) releases the hold.
        if let hold = holds.first(where: { $0.jobID == id }) {
            releaseHold(hold.kind, words: "Resume")
            return true
        }
        guard var run = runs[id], run.state.isActive else { return false }
        run.pauseRequested = false
        if pausedKinds.remove(run.request.kind) != nil { savePaused() }
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
        guard var run = runs[id], run.state.isActive else { return false }
        run.stopRequested = true
        runs[id] = run
        log.write("stop requested for \(run.request.kind) \(id)")
        // Nobody will revisit a queued or parked job: end it here.
        if run.state == .queued || run.parked { finish(id, as: .stopped, checkpoint: run.checkpoint, elapsed: nil) }
        return true
    }

    /// The service's answer, with the holds and the last plan sizes.
    public func status(processIdentifier: Int32, startedAt: Date) async -> ServiceStatus {
        let state = await backoff.refresh()
        var status = ServiceStatus(processIdentifier: processIdentifier, startedAt: startedAt, backoff: state,
                                   jobs: order.compactMap { snapshot($0) }, idleSeconds: idleSeconds)
        if let schedule {
            status.holds = holds
            status.planned = planned
            status.build = schedule.buildID
        }
        return status
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

    /// Seconds since a unit finished or a job ended (the helper never exits
    /// on idle since 2026-11-04; this is information, not a trigger).
    public var idleSeconds: Double {
        let d = clock.now - lastActivity
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    public var activeJobCount: Int { runs.values.filter { $0.state.isActive }.count }

    private func touch() { lastActivity = clock.now }

    // MARK: - The schedule (Rick 2026-11-04)

    private func startSchedule() {
        guard let schedule, scheduleTask == nil else { return }
        let poll = schedule.pollInterval
        scheduleTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.scheduleTick()
                try? await Task.sleep(for: poll)
            }
        }
    }

    /// One look: read the generation, release what a new build releases, and
    /// plan when due (first tick, `planInterval` since the last plan, a
    /// generation change, a finished job, or a released hold).
    public func scheduleTick() async {
        guard let schedule, claimRoot() else { return }   // never plan for a root another process owns (Codex #235 F8)
        loadHolds()
        // An unreadable generation (nil) is not evidence of a change (Codex #235 F7): keep the last known one.
        let generation = schedule.generation() ?? lastGeneration
        let changed = generation != nil && lastGeneration != nil && generation != lastGeneration
        if changed {
            log.write("schedule: catalog generation \(lastGeneration.map(String.init) ?? "unknown") → \(generation.map(String.init) ?? "unknown") — planning")
        }
        lastGeneration = generation
        releaseOtherBuilds(schedule.buildID)
        let due = lastPlanAt.map { clock.now - $0 >= schedule.planInterval } ?? true
        guard due || changed else { return }
        lastPlanAt = clock.now
        planCount += 1
        for kind in schedule.kinds { await planKind(kind) }
    }

    private func planKind(_ k: JobSchedule.Kind) async {
        // A held kind is measured even with a retained (adopted) request of it
        // queued: only the measurement can release it (Codex #241 F3).
        let heldBefore = holds.first { $0.kind == k.kind }?.jobID
        if heldBefore == nil, hasActiveJob(k.kind) { return }
        guard let size = await planSize(k) else { return }
        // The hold may have changed during the await (Resume, a new refusal):
        // this measurement belongs to the hold it started under, or to none (#241 F2).
        guard holds.first(where: { $0.kind == k.kind })?.jobID == heldBefore else { return }
        // A held kind is planned too: a different plan size is new work, and
        // new work releases the hold (Fable review 11/04). The first plan after
        // the hold sets the size it is measured against.
        if let i = holds.firstIndex(where: { $0.kind == k.kind }) {
            guard let was = holds[i].planSize else { holds[i].planSize = size; saveHolds(); return }
            guard size != was else { return }
            release(k.kind, words: "the work changed (the plan went from \(was) to \(size) units)")
        }
        if measureOnly.remove(k.kind) != nil { return }
        // Re-check after the await: the actor is re-entrant there, and a second
        // tick (Resume releases a hold and plans at once) may have queued the kind.
        guard size > 0, !isBusy(k.kind) else { return }
        let request = k.makeRequest()
        if case .refused(let refusal) = admit(request) {
            hold(k.kind, jobID: request.id, reason: refusal.words)
        }
    }

    /// The kind's plan size, off the actor (a plan reads the catalog, ≈ 1 s at
    /// 100k rows; status must still answer). nil when it could not plan (said once).
    private func planSize(_ k: JobSchedule.Kind) async -> Int? {
        let name = k.kind.rawValue
        do {
            let plan = k.planSize
            let size = try await Task.detached(priority: .utility) { try plan() }.value
            if planProblem.removeValue(forKey: name) != nil { log.write("schedule: planning \(name) works again") }
            if planned[name] != size { log.write("schedule: plan \(name) — \(size) unit(s) to do") }
            planned[name] = size
            return size
        } catch {
            let words = (error as? Refusal)?.words ?? String(describing: error)
            if planProblem[name] != words { log.write("schedule: could not plan \(name) — \(words)") }
            planProblem[name] = words
            planned[name] = nil
            return nil
        }
    }

    /// A release means "try again, fresh" (Codex #236 F3, #238 F1, #239): an
    /// adopted queued request of the kind (and its checkpoint) is dropped —
    /// its OUTCOME is already in the log — and the release's plan queues ONE
    /// new job with a fresh checkpoint, counts and frozen plan.
    private func dropRetainedWork(_ kind: JobKind) {
        for (id, run) in runs where run.request.kind == kind && run.state == .queued {
            queue.remove(id)
            checkpoints.remove(id)
            runs[id] = nil
            order.removeAll { $0 == id }
            log.write("schedule: \(kind) \(id) — its old work item is dropped with the hold (\(run.checkpoint.map { "at \($0.completedUnits) of \($0.totalUnits)" } ?? "never started")); the release plans fresh work")
        }
    }

    private func hasActiveJob(_ kind: JobKind) -> Bool {
        runs.values.contains { $0.request.kind == kind && $0.state.isActive }
    }

    /// Held, or a job of the kind is active: the schedule leaves it alone.
    private func isBusy(_ kind: JobKind) -> Bool {
        holds.contains { $0.kind == kind } || hasActiveJob(kind)
    }

    private func isScheduled(_ kind: JobKind) -> Bool {
        schedule?.kinds.contains { $0.kind == kind } ?? false
    }

    /// holds.json and paused.json, once per process. Unreadable fails closed:
    /// every scheduled kind held (or paused) until Resume or a new build.
    private func loadHolds() {
        guard !holdsLoaded, let schedule else { return }
        holdsLoaded = true
        switch schedule.holds.load() {
        case .success(let h):
            holds = h
            for hold in h { log.write("schedule: \(hold.kind) is \(hold.words)") }
        case .failure(let r):
            log.write("schedule: \(r.words) — holding every scheduled kind until Resume or a new build")
            holds = schedule.kinds.map {
                ScheduleHold(kind: $0.kind, jobID: JobID(), reason: "the holds file was unreadable", build: schedule.buildID)
            }
            // COPY the torn file aside (kept, never deleted), then publish these
            // over it atomically: a crash at any point leaves the torn file (fail
            // closed again) or the new holds, never no file (Codex #236 F4, #237 F2).
            let url = schedule.holds.url
            let aside = url.appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))")
            do {
                try FileManager.default.copyItem(at: url, to: aside)
                log.write("schedule: the unreadable holds file is kept at \(aside.path)")
                saveHolds()
            } catch {
                log.write("schedule: could not copy the unreadable holds file aside (\(error)) — it stays; the holds last for this process")
            }
        }
        switch schedule.holds.loadPaused() {
        case .success(let kinds): pausedKinds = Set(kinds)
        case .failure(let r):
            log.write("schedule: \(r.words) — every scheduled kind starts paused; Resume clears it")
            pausedKinds = Set(schedule.kinds.map(\.kind))
        }
    }

    private func saveHolds() {
        do { try schedule?.holds.save(holds) } catch {
            log.write("schedule: could not write the holds file (\(error)) — the hold lasts until this process ends")
        }
    }

    private func savePaused() {
        do { try schedule?.holds.savePaused(pausedKinds.sorted { $0.rawValue < $1.rawValue }) } catch {
            log.write("schedule: could not write the paused file (\(error)) — the pause lasts until this process ends")
        }
    }

    /// A scheduled kind failed: hold it, measured against the next plan.
    private func hold(_ kind: JobKind, jobID: JobID, reason: String) {
        guard let schedule, isScheduled(kind) else { return }
        loadHolds()
        holds.removeAll { $0.kind == kind }
        let h = ScheduleHold(kind: kind, jobID: jobID, reason: reason, build: schedule.buildID)
        holds.append(h)
        saveHolds()
        log.write("schedule: \(kind) \(h.words)")
    }

    private func release(_ kind: JobKind, words: String) {
        measureOnly.remove(kind)
        holds.removeAll { $0.kind == kind }
        saveHolds()
        log.write("schedule: hold on \(kind) released — \(words)")
        dropRetainedWork(kind)
        lastPlanAt = nil
        kickLanes()
    }

    /// A hold made by another build says nothing about this one.
    private func releaseOtherBuilds(_ build: String) {
        for h in holds where h.build != build { release(h.kind, words: "a new build (\(build))") }
    }

    /// Rick pressed Resume: forget the hold and plan now.
    public func releaseHold(_ kind: JobKind, words: String) {
        guard claimRoot() else { return }
        loadHolds()
        guard holds.contains(where: { $0.kind == kind }) else { return }
        release(kind, words: words)
        Task { await self.scheduleTick() }
    }

    /// SIGTERM (unregister, logout, `launchctl kickstart -k`): a clean exit is
    /// not a crash — stop the lanes and clear every in-flight mark, so three
    /// restarts never quarantine a unit (Fable review 11/04). The unit in
    /// flight runs again at the next launch.
    public func prepareForExit() {
        for task in laneTasks.values { task.cancel() }
        laneTasks.removeAll()
        scheduleTask?.cancel()
        scheduleTask = nil
        for (id, run) in runs {
            guard var cp = run.checkpoint, cp.inFlightUnit != nil else { continue }
            cp.inFlightUnit = nil
            cp.inFlightAttempts = nil
            runs[id]?.checkpoint = cp
            try? checkpoints.save(cp)
        }
    }

    // MARK: - Lanes

    private func kickLanes() {
        let held = Set(holds.map(\.kind))
        let lanes = Set(order.compactMap { runs[$0] }.filter { $0.state == .queued && !held.contains($0.request.kind) }.map(\.request.lane))
        for lane in lanes where laneTasks[lane] == nil {
            laneTasks[lane] = Task { await self.runLane(lane) }
        }
    }

    private func nextQueued(in lane: String) -> JobID? {
        order.first { id in
            guard let run = runs[id] else { return false }
            return run.state == .queued && run.request.lane == lane && !holds.contains { $0.kind == run.request.kind }
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

        var turn = Turn(streak: FailureStreak(cp), failFastUnits: max(1, configuration.failFastUnits))
        // A streak that already reached fail fast before a crash ends the job
        // now, before another unit could reset it (Codex #237 F1).
        if turn.reachedFailFast {
            return await end(job, id, as: .failed(reason: "\(turn.streak.length) units in a row failed with the same error before a relaunch: \(turn.streak.words ?? "")"), cp, began)
        }
        while cp.completedUnits < cp.totalUnits {
            switch await step(job, &cp, id, &turn) {
            case .killed: return
            case .stop: return await end(job, id, as: .stopped, cp, began)
            case .failFast(let reason): return await end(job, id, as: .failed(reason: reason), cp, began)
            case .next: continue
            }
        }
        await end(job, id, as: turn.verdict(stopRequested: runs[id]?.stopRequested == true, cp), cp, began)
    }

    private enum Step { case next, stop, killed, failFast(String) }

    /// What one job's loop carries from unit to unit: the run of identical
    /// systemic failures (fail fast).
    private struct Turn {
        var streak: FailureStreak
        var failFastUnits: Int

        var reachedFailFast: Bool { streak.words != nil && streak.length >= failFastUnits }

        /// How a loop that ran to the end of its plan ends, from the
        /// checkpoint's counts and streak (so it survives a relaunch, #236 F2):
        /// a restored fail-fast streak, or ZERO progress — every unit failed,
        /// nothing written, systemic or not (Fable review 11/04: a job of only
        /// timeouts "finished" and was re-planned forever) — is a failure.
        func verdict(stopRequested: Bool, _ cp: JobCheckpoint) -> JobRunState {
            if stopRequested { return .stopped }
            if reachedFailFast, let words = streak.words {
                return .failed(reason: "\(streak.length) units in a row failed with the same error: \(words)")
            }
            guard cp.unitsRun == 0, cp.unitsSkipped == 0, cp.totalUnits > 0, cp.unitsFailed == cp.totalUnits else { return .finished }
            return .failed(reason: "all \(cp.totalUnits) unit(s) failed; nothing written" + (streak.words.map { " (last error: \($0))" } ?? ""))
        }
    }

    /// One unit's turn: the hold between units (pause / stop / the Mac's
    /// thermal or memory pause), the unit, then its checkpoint. No cadence:
    /// units run back to back (Rick 2026-11-04 — the worker runs at utility
    /// QoS, so interactive work wins the CPU without a sleep here).
    private func step(_ job: any BackgroundJob, _ cp: inout JobCheckpoint, _ id: JobID, _ turn: inout Turn) async -> Step {
        switch await holdBetweenUnits(id, cp) {
        case .killed: return .killed
        case .stop: return .stop
        case .proceed: break
        }
        switch await beginUnit(job, &cp, id) {
        case .killed: return .killed
        case .quarantined: return .next
        case .begin: break
        }
        guard await performUnit(job, &cp, id, &turn.streak) else { return .killed }
        turn.streak.save(into: &cp)
        cp.inFlightUnit = nil
        cp.inFlightAttempts = nil
        guard persist(cp, id) else { return .killed }
        if let words = turn.streak.words, turn.streak.length >= max(1, configuration.failFastUnits) {
            return .failFast("units \(turn.streak.streakStart)–\(cp.completedUnits - 1), \(turn.streak.length) in a row, all failed with the same error, "
                             + "so the job stopped (\(cp.totalUnits - cp.completedUnits) not tried; nothing was written for them, the next plan holds them all): \(words)")
        }
        return .next
    }

    /// The job's own release and words, then the one terminal door.
    private func end(_ job: any BackgroundJob, _ id: JobID, as state: JobRunState, _ cp: JobCheckpoint, _ began: ContinuousClock.Instant) async {
        await job.end()
        let detail = await job.outcomeDetail()
        finish(id, as: state, checkpoint: cp, elapsed: clock.now - began, detail: detail)
        // Only now, with the checkpoint gone, may the job forget its frozen plan:
        // a checkpoint without its plan would resume unit N of a different list (Codex #239 F1).
        await job.forget()
    }

    /// The factory's job for `id`, or the refusal written as START…refused.
    private func instantiate(_ id: JobID) -> (any BackgroundJob)? {
        guard let run = runs[id] else { return nil }
        do {
            return try factory.makeJob(for: run.request)
        } catch {
            let words = (error as? Refusal)?.words ?? String(describing: error)
            log.write("START \(run.request.kind) \(id) — refused: \(words)")
            finish(id, as: .failed(reason: words), checkpoint: nil, elapsed: nil)
            return nil
        }
    }

    /// Between units: honour a user pause, then the Mac's pause. Returns
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

    private enum Begin { case begin, quarantined, killed }

    /// Write-ahead: mark unit `cp.completedUnits` in flight before it runs. A
    /// unit already in flight `crashQuarantineAttempts` times — every process
    /// that ran it died — is counted failed and skipped instead (in words).
    private func beginUnit(_ job: any BackgroundJob, _ cp: inout JobCheckpoint, _ id: JobID) async -> Begin {
        let index = cp.completedUnits
        let attempts = cp.inFlightUnit == index ? (cp.inFlightAttempts ?? 0) : 0
        if attempts >= max(1, configuration.crashQuarantineAttempts) {
            let kind = runs[id]?.request.kind.rawValue ?? "?"
            // Its output may already be durable (killed after the journal append):
            // then it is done, not failed (Codex #235 F9).
            let written = await job.unitIsAlreadyRecorded(index)
            log.write("\(kind) \(id) unit \(index) was in flight when the helper died \(attempts) times — quarantined: "
                      + (written ? "its output is already in the journal, counted skipped" : "counted failed, not run again in this job (the next plan includes it)"))
            if written { cp.unitsSkipped += 1 } else { cp.unitsFailed += 1 }
            cp.completedUnits += 1
            cp.inFlightUnit = nil
            cp.inFlightAttempts = nil
            cp.updatedAt = Date()
            return persist(cp, id) ? .quarantined : .killed
        }
        cp.inFlightUnit = index
        cp.inFlightAttempts = attempts + 1
        return persist(cp, id) ? .begin : .killed
    }

    /// Run unit `cp.completedUnits` and count it (done / skipped / failed);
    /// false when the process is "dying" (a cancellation records nothing). A
    /// failure that repeats the one before it word for word is logged as "the
    /// same error as unit N", so a run of them says its words once.
    private func performUnit(_ job: any BackgroundJob, _ cp: inout JobCheckpoint, _ id: JobID, _ streak: inout FailureStreak) async -> Bool {
        let index = cp.completedUnits
        do {
            switch try await job.runUnit(index) {
            case .done: cp.unitsRun += 1
            case .skipped: cp.unitsSkipped += 1
            }
            streak = FailureStreak()
        } catch is CancellationError where Task.isCancelled {
            return false
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
        if Task.isCancelled { return false }
        cp.completedUnits += 1
        cp.updatedAt = Date()
        return true
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
    }

    /// THE terminal transition — the one door every job leaves through, and
    /// the one place the OUTCOME line is written (≈ the RAII guard's
    /// destructor: a START cannot end without it). The checkpoint and the
    /// queue file go (since 2026-11-04 the app enqueues nothing, so no queue
    /// file is anyone's kept intent). A FAILED scheduled kind is held
    /// (JobSchedule.swift); any end of a scheduled kind re-plans at the next
    /// tick, so the plan size shown is never the one from before the job.
    /// The run stays in the status list for a while.
    private func finish(_ id: JobID, as state: JobRunState, checkpoint cp: JobCheckpoint?, elapsed: Duration?, detail: String = "") {
        guard var run = runs[id] else { return }
        run.state = state
        run.finishedAt = Date()
        run.parked = false
        runs[id] = run
        // The hold is durable FIRST — before the OUTCOME line and before the
        // queue file and checkpoint go (Codex #235 F1, #236 F2).
        if case .failed(let reason) = state { hold(run.request.kind, jobID: id, reason: reason) }
        log.write(Self.outcomeLine(kind: run.request.kind.rawValue, id: id, state: state, checkpoint: cp, elapsed: elapsed)
                  + (detail.isEmpty ? "" : "; \(detail)"))
        queue.remove(id)
        checkpoints.remove(id)
        if isScheduled(run.request.kind) {
            // The plan size shown must be re-measured now (Fable review 11/04) —
            // measured, not re-queued: the next interval or commit queues.
            measureOnly.insert(run.request.kind)
            lastPlanAt = nil
        }
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
    static func outcomeLine(kind: String, id: JobID, state: JobRunState, checkpoint cp: JobCheckpoint?, elapsed: Duration?) -> String {
        let counts = cp.map { "\($0.unitsRun) run · \($0.unitsSkipped) skipped · \($0.unitsFailed) failed" } ?? "0 run · 0 skipped · 0 failed"
        let time = elapsed.map { " in \(seconds($0))" } ?? ""
        switch state {
        case .finished:
            return "OUTCOME \(kind) \(id) — finished: \(counts)\(time)"
        case .stopped:
            let place = cp.map { "at \($0.completedUnits) of \($0.totalUnits)" } ?? "before it started"
            return "OUTCOME \(kind) \(id) — stopped \(place): \(counts)\(time)"
        case .failed(let reason):
            return "OUTCOME \(kind) \(id) — failed: \(reason); \(counts)\(time)"
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

    init(lastWords: String? = nil, firstUnit: Int = 0, streakStart: Int = 0, length: Int = 0) {
        self.lastWords = lastWords
        self.firstUnit = firstUnit
        self.streakStart = streakStart
        self.length = length
    }

    /// The streak a checkpoint carried across a relaunch (none: a clean one).
    init(_ cp: JobCheckpoint) {
        self.init(lastWords: cp.streakWords, firstUnit: cp.streakFirstUnit ?? 0, streakStart: cp.streakStart ?? 0,
                  length: cp.streakLength ?? 0)
    }

    func save(into cp: inout JobCheckpoint) {
        cp.streakWords = lastWords
        cp.streakFirstUnit = lastWords == nil ? nil : firstUnit
        cp.streakStart = lastWords == nil ? nil : streakStart
        cp.streakLength = lastWords == nil ? nil : length
    }

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
