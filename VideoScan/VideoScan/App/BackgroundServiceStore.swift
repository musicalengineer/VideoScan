// BackgroundServiceStore.swift — Settings ▸ Background's Content Analysis
// rows: the one place the app turns VideoScan Background on and off
// (docs/design/background_service.md §13 caveat, §14.2).
//
// The control since 2026-11-09 (Rick): one heading — "Background Content
// Analysis: <state> (<build date>)" — and one button, Start / Stop / Restart
// (BackgroundServicePresentation.control). Stop means off until Start; the
// helper's own menu bar Quit is unchanged. `setEnabled` stays the one engine.
//
// Two jobs since 2026-11-04 (Rick: the helper owns its schedule): register /
// unregister the launchd agent and show launchd's REAL status
// (SMAppService.status, never assumed); show the helper's own job line — its
// era job, a hold after a failure, or its own plan size — from what its XPC
// `status` answers. The app schedules NOTHING: no recount, no enqueue
// (BackgroundSettingsSensorTests pins it).
//
// A feature store behind a seam (rule 12, #337): the app owns ONE; nothing
// here extends VideoScanModel. Every outside call is a closure a test
// replaces: ServiceManagement, the XPC status call, the persisted flag, the log.
//
// Truth (rule 1): every word on the two lines comes from an answer —
// launchd's status or the helper's status reply. "running" is never said
// from the flag (BackgroundServicePresentation, tested).
//
// Memory: one status reply (a few KB).
//
// (For Rick: a controller with constructor-injected dependencies — closures
// instead of interfaces.)

import Combine
import Foundation
import ServiceManagement
import VideoScanCore

@MainActor
final class BackgroundServiceStore: ObservableObject {

    nonisolated static let defaultsKey = BackgroundServiceRegistrar.enabledDefaultsKey
    /// How often launchd and the helper are asked while VideoScan runs (the
    /// problem lines are logged on change, never per poll).
    nonisolated static let statusInterval: Duration = .seconds(600)
    nonisolated static let visiblePollInterval: Duration = .seconds(5)

    @Published private(set) var enabled: Bool
    /// nil until launchd has been asked once.
    @Published private(set) var launchdStatus: SMAppService.Status?
    /// The helper's last answer; nil when off, not asked, or not answering.
    @Published private(set) var service: ServiceStatus?
    @Published private(set) var serviceProblem: String?
    /// The last refusal of Start, for the job line.
    @Published private(set) var lastNote: String?
    /// Quit from the helper's menu bar in this boot (BackgroundQuitMarker):
    /// while set, the status poll does not ask the helper (asking would make
    /// launchd start it, only for it to exit again).
    @Published private(set) var quit: BackgroundQuitMarker?
    private(set) var refreshCount = 0
    /// A Start / Stop / Restart is in flight: the button is disabled.
    @Published private(set) var busy = false

    // MARK: Seams (production in `production(...)`; tests inject)

    var agent: () -> any BackgroundAgentService
    var askStatus: () async -> Result<ServiceStatus, Refusal>
    var persist: (Bool) -> Void
    var isViewer: () -> Bool
    /// The build flavour, injectable so tests (which run Debug) can say Release.
    var isReleaseBuild: () -> Bool = { true }
    /// The build id of the helper bundled in THIS app (JobSchedule.buildID of
    /// its executable). Compared with the running helper's `ServiceStatus.build`:
    /// a rebuild leaves the old helper running until a re-tick (Fable 11/04).
    var bundledHelperBuild: () -> String? = { nil }
    /// The helper's quit marker for this boot (nil: none, stale or torn).
    var readQuit: () -> BackgroundQuitMarker? = { nil }
    /// Removes the marker; returns it when there was a readable one.
    var clearQuit: () -> BackgroundQuitMarker? = { nil }
    /// Restart waits this long between unregister and register, so launchd
    /// has let go of the old helper (a person's off-and-on took about this).
    var restartPause: Duration = .seconds(1)
    var log: (String) -> Void

    /// Why Start may not turn the helper on here — nil when it may.
    var registrationRefusal: String? {
        BackgroundServiceRegistrar.registrationRefusal(isViewer: isViewer(), isReleaseBuild: isReleaseBuild())
    }

    /// The heading and the button, from the same answers as the two lines.
    /// Stop is never refused (Codex 11/03 F4: enabled from Release, then
    /// opened in Debug or as a viewer, OFF must stay reachable).
    var control: BackgroundServicePresentation.Control {
        BackgroundServicePresentation.control(enabled: enabled, launchd: launchdStatus, service: service,
                                              serviceProblem: serviceProblem, refusal: registrationRefusal,
                                              bundledBuild: bundledHelperBuild(), quit: quit)
    }

    private var cycle: Task<Void, Never>?
    private var visible: Task<Void, Never>?

    init(enabled: Bool,
         agent: @escaping () -> any BackgroundAgentService,
         askStatus: @escaping () async -> Result<ServiceStatus, Refusal>,
         persist: @escaping (Bool) -> Void,
         isViewer: @escaping () -> Bool,
         log: @escaping (String) -> Void) {
        self.enabled = enabled
        self.agent = agent
        self.askStatus = askStatus
        self.persist = persist
        self.isViewer = isViewer
        self.log = log
    }

    /// The real thing: the defaults flag the registrar reads at launch,
    /// SMAppService, the XPC client.
    static func production(defaults: UserDefaults = .standard,
                           isViewer: @escaping () -> Bool,
                           log: @escaping (String) -> Void) -> BackgroundServiceStore {
        let store = BackgroundServiceStore(
            enabled: defaults.bool(forKey: defaultsKey),
            agent: { SMAppService.agent(plistName: BackgroundServiceRegistrar.plistName) },
            askStatus: { await BackgroundServiceClient().status() },
            persist: { defaults.set($0, forKey: defaultsKey) },
            isViewer: isViewer,
            log: log)
        store.isReleaseBuild = { BackgroundServiceRegistrar.isReleaseBuild }
        let helper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LoginItems/VideoScan Background.app/Contents/MacOS/VideoScan Background")
        let bundled = FileManager.default.fileExists(atPath: helper.path) ? JobSchedule.buildID(executable: helper) : nil
        // Only the Release build registers the helper, so only it can call the running one older.
        store.bundledHelperBuild = { BackgroundServiceRegistrar.isReleaseBuild ? bundled : nil }
        let quitStore = BackgroundQuitStore.production()
        store.readQuit = { quitStore.active() }
        store.clearQuit = { quitStore.clear() }
        return store
    }

    // MARK: Start / Stop / Restart (the Settings button)

    /// The button's one entry: what was pressed is logged, then the verb,
    /// then launchd and the helper are asked again so the heading is true.
    func perform(_ action: BackgroundServicePresentation.Action) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        log("background service: \(action.rawValue) pressed in Settings")
        switch action {
        case .start: startService()
        case .stop: setEnabled(false)
        case .restart:
            guard registrationRefusal == nil else {
                // Never stop what this build may not start again.
                startService()
                break
            }
            setEnabled(false)
            if let serviceProblem {
                log("background service: Restart stopped at Stop — \(serviceProblem); not started again")
                break
            }
            try? await Task.sleep(for: restartPause)
            setEnabled(true)
        }
        await refresh()
    }

    /// Start: off → on (the engine below); already on but quit from the menu
    /// bar or dropped by launchd → clear the quit marker and register again.
    private func startService() {
        guard enabled else { setEnabled(true); return }
        if let refusal = registrationRefusal {
            lastNote = refusal
            log("background service: not turned on — \(refusal)")
            return
        }
        clearQuitMarker(reason: "Start was pressed")
        let a = agent()
        if a.status != .enabled {
            BackgroundServiceRegistrar.registerIfEnabled(enabled: true, service: { a }, log: log)
        }
        launchdStatus = a.status
    }

    // MARK: The engine

    /// On / off: persist, then register or unregister (one log
    /// line each, with launchd's answer) — and nothing else. The helper plans
    /// its own work once launchd starts it.
    func setEnabled(_ on: Bool) {
        // Turning it OFF is always allowed; turning it ON needs the gate.
        if on, let refusal = registrationRefusal {
            lastNote = refusal
            log("background service: not turned on — \(refusal)")
            return
        }
        guard on != enabled else { return }
        enabled = on
        persist(on)
        lastNote = nil
        let a = agent()
        if on {
            clearQuitMarker(reason: "Start was pressed")
            BackgroundServiceRegistrar.registerIfEnabled(enabled: true, service: { a }, log: log)
            launchdStatus = a.status
            Task { await refresh() }
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

    /// launchd's status; when on and launchd agrees, the helper's status.
    func refresh() async {
        refreshCount += 1
        launchdStatus = agent().status
        quit = enabled ? readQuit() : nil
        if quit != nil {
            service = nil
            serviceProblem = nil
        } else if enabled, launchdStatus == .enabled {
            switch await askStatus() {
            case .success(let s): service = s; serviceProblem = nil
            case .failure(let r): service = nil; serviceProblem = r.words
            }
        } else {
            service = nil
        }
        noteProblems()
    }

    // MARK: Problems → the log, once per change (Codex 11/03 F6)

    /// The words last logged per problem; nil = none showing.
    private var saidProblem: [String: String] = [:]

    /// Every problem the two Settings lines can show — launchd's states, "not
    /// answering", a failed unregister, the registration gate, a hold — is
    /// logged when it appears, when its words change, and when it clears;
    /// never per poll.
    private func noteProblems() {
        note("helper", BackgroundServicePresentation.helperProblem(enabled: enabled, launchd: launchdStatus,
                                                                    service: service, problem: serviceProblem,
                                                                    refusal: registrationRefusal, bundledBuild: bundledHelperBuild()))
        note("registration", registrationRefusal.map { "Start is refused here — \($0)" })
        note("hold", service?.holds?.first.map { "\($0.kind) \($0.words)" })
    }

    private func note(_ key: String, _ words: String?) {
        let was = saidProblem[key]
        guard words != was else { return }
        saidProblem[key] = words
        if let words {
            log("background service: \(words)")
        } else if let was {
            log("background service: cleared — \(was)")
        }
    }

    // MARK: Cycles

    /// Opening VideoScan starts the helper again (Rick 2026-11-08): the
    /// marker goes, and the next status ask lets launchd start it.
    private func clearQuitMarker(reason: String) {
        if let was = clearQuit() {
            log("background service: quit from its menu bar at \(was.quitWords()) — cleared (\(reason)); the helper starts again")
        }
        quit = nil
    }

    /// At launch: clear a menu bar Quit, one refresh now, then every 10 minutes.
    func start() {
        guard cycle == nil else { return }
        clearQuitMarker(reason: "VideoScan opened")
        cycle = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: Self.statusInterval)
            }
        }
    }

    func stop() {
        cycle?.cancel()
        cycle = nil
        stopVisiblePolling()
    }

    /// While the Settings pane is on screen: the two lines every 5 s.
    func startVisiblePolling() {
        guard visible == nil else { return }
        visible = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: Self.visiblePollInterval)
            }
        }
    }

    func stopVisiblePolling() {
        visible?.cancel()
        visible = nil
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
        /// The job line: the helper's era job, a hold, or the helper's plan size.
        var job: String
    }

    /// A viewer's job line (Codex 11/03 F1): nothing is counted here.
    static let viewerJob = "Content analysis: the master runs content analysis — this Mac is a viewer, so nothing is counted here"

    static let loginItems = "System Settings ▸ General ▸ Login Items"

    /// `refusal`: why this build may not turn the helper on (the gate) — the
    /// "Fix:" then names a verb this build CAN do (reviewer 11/03).
    static func lines(enabled: Bool, launchd: SMAppService.Status?, service: ServiceStatus?, serviceProblem: String?,
                      lastNote: String?, viewer: Bool = false, refusal: String? = nil, bundledBuild: String? = nil,
                      quit: BackgroundQuitMarker? = nil) -> Lines {
        if enabled, let quit, !viewer {
            return Lines(helper: quitHelperLine(quit), helperIsUp: false, needsApproval: false, job: quitJobLine)
        }
        return Lines(helper: helper(enabled: enabled, launchd: launchd, service: service, problem: serviceProblem, refusal: refusal,
                                    bundledBuild: bundledBuild),
                     helperIsUp: service != nil,
                     needsApproval: enabled && launchd == .requiresApproval,
                     job: job(enabled: enabled, service: service, lastNote: lastNote, viewer: viewer))
    }

    /// Quit from the helper's own menu bar: Rick's choice, not a problem.
    static func quitHelperLine(_ quit: BackgroundQuitMarker, now: Date = Date()) -> String {
        "VideoScan Background: quit from its menu bar at \(quit.quitWords(now: now)) — starts again when VideoScan next opens "
            + "or the Mac restarts (to start it now: press Start)"
    }

    static let quitJobLine = "Content analysis: stopped — VideoScan Background was quit; work resumes where it stopped"

    /// The helper line when it shows a problem — nil when it is healthy or
    /// plainly off, or still asking (transient). The store logs exactly these
    /// words on appear / change / clear (F6).
    static func helperProblem(enabled: Bool, launchd: SMAppService.Status?, service: ServiceStatus?, problem: String?,
                              refusal: String? = nil, bundledBuild: String? = nil) -> String? {
        let words = helper(enabled: enabled, launchd: launchd, service: service, problem: problem, refusal: refusal,
                           bundledBuild: bundledBuild)
        if !enabled { return launchd == .enabled ? words : nil }
        if isOlder(service, than: bundledBuild) { return words }
        switch launchd {
        case nil: return nil
        case .enabled?: return service == nil && problem != nil ? words : nil
        default: return words
        }
    }

    /// The fix for "not registered": Start, when this build may use it;
    /// otherwise the build that may (here the button only stops).
    static func reregisterFix(refusal: String?) -> String {
        guard let refusal else { return "Fix: press Start" }
        if refusal == BackgroundServiceRegistrar.viewerRefusal {
            return "Fix: on the master's Release build, press Start (this Mac is a viewer)"
        }
        return "Fix: in the Release build (scheme VideoScan-Release), press Start"
    }

    // MARK: The heading and its button (Rick 2026-11-09)

    /// The one button's verb; the raw value is its title.
    enum Action: String, Equatable, Sendable {
        case start = "Start", stop = "Stop", restart = "Restart"
    }

    struct Control: Equatable {
        /// "running" only from the helper's own answer (rule 1).
        var state: String
        /// "built Nov 9, 2026 at 8:41 PM" — nil when no build is known.
        var build: String?
        var action: Action
        /// Start where this build may not start it (viewer, Debug).
        var actionDisabled: Bool

        var heading: String { "\(Control.name): \(state)" + (build.map { " (\($0))" } ?? "") }
        static let name = "Background Content Analysis"
    }

    static func buildWords(_ buildID: String?, format: (Date) -> String) -> String? {
        buildID.flatMap(JobSchedule.buildDate(of:)).map { "built \(format($0))" }
    }

    /// State, build date and verb. The build date is the RUNNING helper's
    /// when it answered; otherwise the one inside this app ("this app's").
    static func control(enabled: Bool, launchd: SMAppService.Status?, service: ServiceStatus?, serviceProblem: String?,
                        refusal: String?, bundledBuild: String?, quit: BackgroundQuitMarker? = nil,
                        format: (Date) -> String = { $0.formatted(date: .abbreviated, time: .shortened) }) -> Control {
        let mine = buildWords(bundledBuild, format: format).map { "this app's helper: \($0)" }
        let stopped = Control(state: "stopped", build: mine, action: .start, actionDisabled: refusal != nil)
        guard enabled else {
            var c = stopped
            if launchd == .enabled, serviceProblem != nil { c.state = "Stop failed" }
            return c
        }
        // A quit marker only where Start can undo it; a viewer or a Debug
        // build keeps Stop (unregister) reachable instead.
        if quit != nil, refusal == nil { return stopped }
        func up(_ state: String, _ build: String?) -> Control {
            Control(state: state, build: build, action: .stop, actionDisabled: false)
        }
        switch launchd {
        case nil: return up("checking…", mine)
        case .notRegistered?: return stopped
        case .requiresApproval?: return up("waiting for your approval", mine)
        case .notFound?: return up("the helper is missing from this build", nil)
        case .enabled?:
            return registered(service: service, serviceProblem: serviceProblem, mayStart: refusal == nil,
                              bundledBuild: bundledBuild, mine: mine, format: format)
        case .some(let other): return up(BackgroundServiceRegistrar.statusWords(other), mine)
        }
    }

    /// launchd says enabled: what the helper's own answer (or silence) means.
    /// Restart only where this build may start it again (`mayStart`).
    private static func registered(service: ServiceStatus?, serviceProblem: String?, mayStart: Bool,
                                   bundledBuild: String?, mine: String?, format: (Date) -> String) -> Control {
        let again: Action = mayStart ? .restart : .stop
        guard let service else {
            return serviceProblem != nil
                ? Control(state: "not answering", build: mine, action: again, actionDisabled: false)
                : Control(state: "checking…", build: mine, action: .stop, actionDisabled: false)
        }
        let running = buildWords(service.build, format: format)
        guard isOlder(service, than: bundledBuild) else {
            return Control(state: "running", build: running, action: .stop, actionDisabled: false)
        }
        let both = [running, mine].compactMap { $0 }.joined(separator: "; ")
        return Control(state: "running an older build", build: both.isEmpty ? nil : both, action: again, actionDisabled: false)
    }

    /// The running helper is another build than the one in this app.
    static func isOlder(_ service: ServiceStatus?, than bundledBuild: String?) -> Bool {
        guard let running = service?.build, let bundledBuild else { return false }
        return running != bundledBuild
    }

    private static func helper(enabled: Bool, launchd: SMAppService.Status?, service: ServiceStatus?, problem: String?,
                               refusal: String?, bundledBuild: String? = nil) -> String {
        let name = "VideoScan Background: "
        guard enabled else {
            if launchd == .enabled, let problem {
                return name + "still enabled in launchd — turning it off failed (\(problem)); press Start, then Stop again"
            }
            return name + (launchd == .enabled ? "off — still listed in \(loginItems) until the app unregisters it" : "off")
        }
        switch launchd {
        case nil: return name + "asking launchd…"
        case .notRegistered?: return name + "not registered — " + reregisterFix(refusal: refusal)
        case .requiresApproval?: return name + "waiting for your approval in \(loginItems)"
        case .notFound?: return name + "the helper is missing from this build"
        case .enabled?:
            if let service, isOlder(service, than: bundledBuild) {
                return name + "older helper running (pid \(service.processIdentifier)) — press Restart to start this build's"
            }
            if let service {
                return name + "running · pid \(service.processIdentifier) · \(service.backoff.words)"
            }
            if let problem { return name + "enabled · not answering (\(problem))" }
            return name + "enabled · asking…"
        case .some(let other): return name + BackgroundServiceRegistrar.statusWords(other)
        }
    }

    private static func job(enabled: Bool, service: ServiceStatus?, lastNote: String?, viewer: Bool) -> String {
        // A viewer first (Codex closing #3): a helper left registered from its
        // master days may still list a job; the master runs content analysis.
        if viewer { return viewerJob }
        // A hold first (Codex #236 F5): a kept request of a held kind sits
        // "queued" and must not hide why nothing runs.
        if let hold = service?.holds?.first(where: { $0.kind == .era }) {
            return "Machine era (8B): \(hold.words) (Resume is in the VideoScan Background menu bar item)"
        }
        if let era = service?.jobs.filter({ $0.kind == .era && $0.state.isActive })
            .max(by: { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }) {
            let counts = era.totalUnits > 0 ? "\(era.completedUnits.formatted()) of \(era.totalUnits.formatted())" : era.subtitle
            return "\(era.title): \(counts) · \(era.stateWords)"
        }
        guard enabled else {
            return "Content analysis: off" + (lastNote.map { " — \($0)" } ?? " — press Start to analyze in the background")
        }
        guard let service else { return "Content analysis: the helper is not answering — no plan to show" }
        guard let left = service.planned?[JobKind.era.rawValue] else { return "Content analysis: the helper has not planned yet" }
        if left == 0 { return "Content analysis: nothing left to analyze (the helper's plan)" }
        return "Content analysis: \(left.formatted()) files to analyze (the helper's plan)"
    }
}
