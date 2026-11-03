// BackgroundServiceStore.swift — Settings ▸ Background's Content Analysis
// rows: the one place the app turns VideoScan Background on and off
// (docs/design/background_service.md §2 caveat, §3.2; STATUS Next 0,
// Rick 2026-11-02).
//
// Three jobs, in Rick's words: register / unregister the launchd agent and
// show launchd's REAL status (SMAppService.status, never assumed); show the
// helper's own job line (what its XPC `status` answers, as the Previews and
// Find People lines do for their helpers); when on and work is left, enqueue
// the era job (until today only the CLI could).
//
// A feature store behind a seam (rule 12, #337): the app owns ONE; nothing
// here extends VideoScanModel. Every outside call is a closure a test
// replaces: ServiceManagement, the XPC client, the work count, the persisted
// flag, the log, the clock.
//
// Truth (rule 1): every word on the two lines comes from an answer —
// launchd's status, the helper's status reply, a count run against the
// catalog and the journal, or a checkpoint file's `updatedAt`. "running" is
// never said from the flag (BackgroundServicePresentation, tested).
//
// The enqueue rule (`shouldEnqueue`, pure): enabled AND not a viewer AND launchd says enabled
// AND the helper answered AND no era job is active in that answer AND the
// FRESH count says files are left AND no run outside the service (a
// `--run era` started by hand: its checkpoint touched within 15 minutes AND
// the state-root lock held by that `--run`) is live. Decided only in a cycle that recounted — launch,
// toggle-on, every 10 minutes — never from a stale count, so a finished job
// is not re-queued five seconds later on the old number.
//
// Memory: one status reply (a few KB) and one count; the plan the count
// builds (≈ 5k candidates, ~1 MB) lives inside the detached task and is
// dropped with it.
//
// (For Rick: a controller with constructor-injected dependencies — closures
// instead of interfaces — and one pure decision function the tests hit
// directly.)

import Combine
import Foundation
import ServiceManagement
import VideoScanCore

/// What a recount found (built off the main actor).
struct BackgroundWorkCount: Equatable, Sendable {
    /// Video contents with no era line by the seated signer, readable now
    /// (EraPlanner's own unit list — the one engine).
    var filesLeft: Int
    /// A checkpoint under the service's folder touched within the window
    /// that is NOT one of the helper's own jobs: a run started by hand.
    var foregroundRun: JobCheckpoint?
}

@MainActor
final class BackgroundServiceStore: ObservableObject {

    nonisolated static let defaultsKey = BackgroundServiceRegistrar.enabledDefaultsKey
    /// A checkpoint touched this recently belongs to a live run.
    nonisolated static let foregroundRunWindow: TimeInterval = 15 * 60
    nonisolated static let recountInterval: Duration = .seconds(600)
    nonisolated static let visiblePollInterval: Duration = .seconds(5)

    @Published private(set) var enabled: Bool
    /// nil until launchd has been asked once.
    @Published private(set) var launchdStatus: SMAppService.Status?
    /// The helper's last answer; nil when off, not asked, or not answering.
    @Published private(set) var service: ServiceStatus?
    @Published private(set) var serviceProblem: String?
    @Published private(set) var work: BackgroundWorkCount?
    @Published private(set) var workProblem: String?
    /// The last enqueue's words (accepted id or refusal), for the job line.
    @Published private(set) var lastNote: String?
    private(set) var refreshCount = 0
    private(set) var enqueueCount = 0

    // MARK: Seams (production in `production(...)`; tests inject)

    var agent: () -> any BackgroundAgentService
    var askStatus: () async -> Result<ServiceStatus, Refusal>
    var enqueueRequest: (JobRequest) async -> Result<EnqueueReply, Refusal>
    /// The helper's job ids, so its own checkpoints are not read as a hand run.
    var countWork: ([JobID]) async -> Result<BackgroundWorkCount, Refusal>
    /// The live hand run, re-read on every refresh (a few small files and one
    /// flock probe — no catalog work), so the line drops it when it exits.
    var findHandRun: ([JobID]) -> JobCheckpoint?
    var makeRequest: () -> JobRequest
    var persist: (Bool) -> Void
    var isViewer: () -> Bool
    var log: (String) -> Void

    private var cycle: Task<Void, Never>?
    private var visible: Task<Void, Never>?

    init(enabled: Bool,
         agent: @escaping () -> any BackgroundAgentService,
         askStatus: @escaping () async -> Result<ServiceStatus, Refusal>,
         enqueueRequest: @escaping (JobRequest) async -> Result<EnqueueReply, Refusal>,
         countWork: @escaping ([JobID]) async -> Result<BackgroundWorkCount, Refusal>,
         findHandRun: @escaping ([JobID]) -> JobCheckpoint?,
         makeRequest: @escaping () -> JobRequest,
         persist: @escaping (Bool) -> Void,
         isViewer: @escaping () -> Bool,
         log: @escaping (String) -> Void) {
        self.enabled = enabled
        self.agent = agent
        self.askStatus = askStatus
        self.enqueueRequest = enqueueRequest
        self.countWork = countWork
        self.findHandRun = findHandRun
        self.makeRequest = makeRequest
        self.persist = persist
        self.isViewer = isViewer
        self.log = log
    }

    /// The real thing: the defaults flag the registrar reads at launch,
    /// SMAppService, the XPC client, the catalog beside `catalogURL()`.
    static func production(defaults: UserDefaults = .standard,
                           catalogURL: @escaping () -> URL?,
                           isViewer: @escaping () -> Bool,
                           log: @escaping (String) -> Void) -> BackgroundServiceStore {
        BackgroundServiceStore(
            enabled: defaults.bool(forKey: defaultsKey),
            agent: { SMAppService.agent(plistName: BackgroundServiceRegistrar.plistName) },
            askStatus: { await BackgroundServiceClient().status() },
            enqueueRequest: { await BackgroundServiceClient().enqueue($0) },
            countWork: productionCountWork(catalogURL: catalogURL),
            findHandRun: productionFindHandRun(catalogURL: catalogURL),
            makeRequest: { EraJob.request(limit: nil, repoPath: EraCLIArguments.defaultRepo, requestedBy: "app") },
            persist: { defaults.set($0, forKey: defaultsKey) },
            isViewer: isViewer,
            log: log)
    }

    /// The count against the catalog at `catalogURL()` (the service folder
    /// sits beside it), run detached at utility priority.
    static func productionCountWork(catalogURL: @escaping () -> URL?) -> ([JobID]) async -> Result<BackgroundWorkCount, Refusal> {
        { known in
            guard let catalog = catalogURL() else { return .failure(Refusal("no catalog is open")) }
            let root = stateRoot(beside: catalog)
            return await Task.detached(priority: .utility) {
                Self.count(catalogURL: catalog, stateRoot: root, knownJobs: known, now: Date())
            }.value
        }
    }

    static func productionFindHandRun(catalogURL: @escaping () -> URL?) -> ([JobID]) -> JobCheckpoint? {
        { known in
            guard let catalog = catalogURL() else { return nil }
            return foregroundRun(stateRoot: stateRoot(beside: catalog), knownJobs: known, now: Date())
        }
    }

    /// The service's folder sits beside the catalog.
    nonisolated static func stateRoot(beside catalog: URL) -> URL {
        catalog.deletingLastPathComponent().appendingPathComponent("background", isDirectory: true)
    }

    // MARK: The toggle

    /// The checkbox's setter: persist, register or unregister (one log line
    /// each, with launchd's answer), then a recounting refresh when on.
    func setEnabled(_ on: Bool) {
        guard !isViewer() else {
            lastNote = "This Mac is a viewer — the master runs content analysis"
            return
        }
        guard on != enabled else { return }
        enabled = on
        persist(on)
        let a = agent()
        if on {
            BackgroundServiceRegistrar.registerIfEnabled(enabled: true, service: { a }, log: log)
            launchdStatus = a.status
            Task { await refresh(recount: true) }
        } else {
            // A failed unregister is kept in words (codex-1102 F6): launchd
            // still runs the helper, so the line must not say plain "off".
            let failure = BackgroundServiceRegistrar.unregister(service: { a }, log: log)
            launchdStatus = a.status
            service = nil
            serviceProblem = failure.map { "unregister failed — \($0)" }
        }
    }

    // MARK: Refresh

    /// launchd's status; when on and launchd agrees, the helper's status;
    /// with `recount`, the work count and — if the rule says so — one enqueue.
    ///
    /// One recount at a time (codex-1102 F3): a recount asked for while one
    /// is in flight (the launch cycle and the toggle's Task interleave at
    /// every `await`) runs once more AFTER it, on a fresh status — so it sees
    /// the era job the first one queued. Bounded: a rerun happens only when
    /// another caller asked during the run (10-minute cycle, toggles).
    func refresh(recount: Bool) async {
        refreshCount += 1
        await readStatus()
        recheckHandRun()
        guard recount else { return }
        guard !recounting else { recountAgain = true; return }
        recounting = true
        defer { recounting = false }
        var rerun = false
        repeat {
            if rerun { await readStatus() }
            recountAgain = false
            await recountOnce()
            rerun = recountAgain
        } while rerun
    }

    private var recounting = false
    private var recountAgain = false

    private func readStatus() async {
        launchdStatus = agent().status
        if enabled, launchdStatus == .enabled {
            switch await askStatus() {
            case .success(let s): service = s; serviceProblem = nil
            case .failure(let r): service = nil; serviceProblem = r.words
            }
        } else {
            service = nil
        }
    }

    /// The hand run on the line is re-read every refresh (codex-1102 F5), so
    /// it goes when the run's lock does; the count stands until the next recount.
    private func recheckHandRun() {
        guard work != nil else { return }
        work?.foregroundRun = findHandRun(service?.jobs.map(\.id) ?? [])
    }

    /// Decides on THIS count only (codex-1102 F4): a failed count clears the
    /// old one rather than letting it stand in for a fresh one.
    private func recountOnce() async {
        let fresh: BackgroundWorkCount
        switch await countWork(service?.jobs.map(\.id) ?? []) {
        case .success(let c): fresh = c; work = c; workProblem = nil
        case .failure(let r): work = nil; workProblem = r.words; return
        }
        if Self.shouldEnqueue(enabled: enabled, viewer: isViewer(), launchd: launchdStatus, service: service, work: fresh) {
            await enqueueEra()
        }
    }

    /// Pure: the six conditions in the file header. A viewer never queues
    /// (codex-1102 F1: the toggle refused on a viewer, but a flag left on from
    /// its master days still queued on every launch recount).
    nonisolated static func shouldEnqueue(enabled: Bool, viewer: Bool, launchd: SMAppService.Status?,
                                          service: ServiceStatus?, work: BackgroundWorkCount?) -> Bool {
        guard enabled, !viewer, launchd == .enabled, let service, let work else { return false }
        guard work.filesLeft > 0, work.foregroundRun == nil else { return false }
        return !service.jobs.contains { $0.kind == .era && $0.state.isActive }
    }

    private func enqueueEra() async {
        enqueueCount += 1
        let left = work?.filesLeft ?? 0
        switch await enqueueRequest(makeRequest()) {
        case .success(.accepted(let id)):
            lastNote = "queued era \(id)"
            log("background service: enqueued era \(id) — \(left.formatted()) files left, requested by the app")
        case .success(.refused(let r)):
            lastNote = r.words
            log("background service: era refused — \(r.words)")
        case .failure(let r):
            lastNote = r.words
            log("background service: enqueue failed — \(r.words)")
        }
        // The job line shows it as soon as the helper lists it.
        if case .success(let s) = await askStatus() { service = s; serviceProblem = nil }
    }

    // MARK: Cycles

    /// At launch: one recounting refresh now, then every 10 minutes
    /// (recounting only while on — off, only launchd's status is read).
    func start() {
        guard cycle == nil else { return }
        cycle = Task { [weak self] in
            var first = true
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh(recount: first || self.enabled)
                first = false
                try? await Task.sleep(for: Self.recountInterval)
            }
        }
    }

    func stop() {
        cycle?.cancel()
        cycle = nil
        stopVisiblePolling()
    }

    /// While the Settings pane is on screen: the two lines every 5 s, no
    /// count, no enqueue.
    func startVisiblePolling() {
        guard visible == nil else { return }
        visible = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh(recount: false)
                try? await Task.sleep(for: Self.visiblePollInterval)
            }
        }
    }

    func stopVisiblePolling() {
        visible?.cancel()
        visible = nil
    }

    // MARK: The count (off the main actor; pure over its inputs)

    /// Files left = EraPlanner's own unit list for the seated signer (the
    /// same plan the helper freezes at START), plus any hand-started run.
    nonisolated static func count(catalogURL: URL, stateRoot: URL, knownJobs: [JobID], now: Date) -> Result<BackgroundWorkCount, Refusal> {
        let journal = ObservationJournal(directory: stateRoot.appendingPathComponent("journal", isDirectory: true))
        do {
            let plan = try EraPlanner.plan(catalogURL: catalogURL, journal: journal, signer: SeatedApproach.eraA2.signer,
                                           limit: nil, jobID: JobID(), isReadable: { FileManager.default.isReadableFile(atPath: $0) })
            let run = foregroundRun(stateRoot: stateRoot, knownJobs: knownJobs, now: now)
            return .success(BackgroundWorkCount(filesLeft: plan.units.count, foregroundRun: run))
        } catch {
            return .failure((error as? Refusal) ?? Refusal(String(describing: error)))
        }
    }

    /// The newest checkpoint under `checkpoints/` touched within the window
    /// whose job the helper does not list, while a `--run` holds the root's
    /// lock — a `--run era` by hand. A
    /// checkpoint that cannot be read is skipped (isolation: a torn file is
    /// not a run).
    nonisolated static func foregroundRun(stateRoot: URL, knownJobs: [JobID], now: Date) -> JobCheckpoint? {
        let folder = stateRoot.appendingPathComponent("checkpoints", isDirectory: true)
        let store = FileCheckpointStore(directory: folder)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let known = Set(knownJobs)
        var newest: JobCheckpoint?
        for name in names where name.hasSuffix(".json") {
            let id = JobID(rawValue: String(name.dropLast(5)))
            guard !known.contains(id), case .found(let c) = store.load(id) else { continue }
            guard now.timeIntervalSince(c.updatedAt) < foregroundRunWindow, c.updatedAt <= now.addingTimeInterval(60) else { continue }
            if newest.map({ c.updatedAt > $0.updatedAt }) ?? true { newest = c }
        }
        // A checkpoint is past progress; the live process is the evidence:
        // a `--run` holding the state-root lock (codex-1102 F5). Probed only
        // when a candidate exists (StateRootLock.holder documents the probe).
        guard newest != nil, let holder = FileStateRootLock.holder(of: stateRoot),
              FileStateRootLock.isHandRun(holder: holder) else { return nil }
        return newest
    }
}

// MARK: - The two lines (pure)

/// What the Settings rows say. Every word traces to an answer; the flag
/// alone never says "running".
enum BackgroundServicePresentation {

    struct Lines: Equatable {
        /// "VideoScan Background: …" — launchd's and the helper's word.
        var helper: String
        /// Green dot only when the helper answered.
        var helperIsUp: Bool
        /// Shown when launchd wants Rick's approval (a button opens Login Items).
        var needsApproval: Bool
        /// The job line: the helper's era job, a hand-started run, or the count.
        var job: String
    }

    static let loginItems = "System Settings ▸ General ▸ Login Items"

    static func lines(enabled: Bool, launchd: SMAppService.Status?, service: ServiceStatus?, serviceProblem: String?,
                      work: BackgroundWorkCount?, workProblem: String?, lastNote: String?,
                      time: (Date) -> String = Self.clock) -> Lines {
        Lines(helper: helper(enabled: enabled, launchd: launchd, service: service, problem: serviceProblem),
              helperIsUp: service != nil,
              needsApproval: enabled && launchd == .requiresApproval,
              job: job(enabled: enabled, service: service, work: work, workProblem: workProblem, lastNote: lastNote, time: time))
    }

    private static func helper(enabled: Bool, launchd: SMAppService.Status?, service: ServiceStatus?, problem: String?) -> String {
        let name = "VideoScan Background: "
        guard enabled else {
            if launchd == .enabled, let problem {
                return name + "still enabled in launchd — turning it off failed (\(problem)); turn the checkbox on and off again"
            }
            return name + (launchd == .enabled ? "off — still listed in \(loginItems) until the app unregisters it" : "off")
        }
        switch launchd {
        case nil: return name + "asking launchd…"
        case .notRegistered?: return name + "not registered — Fix: turn the checkbox off and on"
        case .requiresApproval?: return name + "waiting for your approval in \(loginItems)"
        case .notFound?: return name + "the helper is missing from this build"
        case .enabled?:
            if let service {
                return name + "running · pid \(service.processIdentifier) · \(service.backoff.words) · idle \(Int(service.idleSeconds)) s"
            }
            if let problem { return name + "enabled · not answering (\(problem))" }
            return name + "enabled · asking…"
        case .some(let other): return name + BackgroundServiceRegistrar.statusWords(other)
        }
    }

    private static func job(enabled: Bool, service: ServiceStatus?, work: BackgroundWorkCount?, workProblem: String?,
                            lastNote: String?, time: (Date) -> String) -> String {
        if let run = work?.foregroundRun {
            return "Machine era (8B): \(run.completedUnits.formatted()) of \(run.totalUnits.formatted()) · running outside the service "
                + "(started by hand; last unit \(time(run.updatedAt)))"
        }
        if let era = service?.jobs.filter({ $0.kind == .era }).max(by: { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }) {
            let counts = era.totalUnits > 0 ? "\(era.completedUnits.formatted()) of \(era.totalUnits.formatted())" : era.subtitle
            return "\(era.title): \(counts) · \(era.state.words)"
        }
        if let workProblem { return "Content analysis: could not count — \(workProblem)" }
        guard let work else { return "Content analysis: counting…" }
        if work.filesLeft == 0 { return "Content analysis: nothing left to analyze" }
        let left = "Content analysis: \(work.filesLeft.formatted()) files to analyze"
        if let lastNote, enabled { return left + " · \(lastNote)" }
        return left + (enabled ? " · queued on the next check" : " — turn the checkbox on to analyze them")
    }

    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
