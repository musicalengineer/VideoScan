// BackgroundService.swift — VideoScan Background
//
// Wires the Core pieces into one running service: the supervisor on the
// durable folders under ~/Library/Application Support/VideoScan/background/,
// Backoff on the real Mac (thermal, memory), the XPC listener, the log at
// ~/Library/Logs/VideoScan/background.log, and THE SCHEDULE (Rick
// 2026-11-04): the era job planned by the helper itself — at start, every
// 10 minutes, and when the catalog generation changes — never by the app.
// No idle exit: launchd keeps the helper up while it is registered.
//
// Memory: the supervisor's bookkeeping (see JobSupervisor) plus one NSXPC
// listener; a plan count holds one EraCandidate per video file while it runs
// (≈ 200 B each, 100k files ≈ 20 MB) and drops it.

import Foundation
import VideoScanCore

final class BackgroundService: @unchecked Sendable {

    private let log: BackgroundFileLog
    private let supervisor: JobSupervisor
    private let backoff: Backoff
    private let activity: SystemActivitySource
    private let server: XPCServer
    private let startedAt = Date()

    static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "Rick-Breen.VideoScan.Background"
    static let appBundleIdentifier = BackgroundServiceNames.appBundleIdentifier(helperBundleIdentifier: bundleIdentifier) ?? "Rick-Breen.VideoScan"
    static let machServiceName = BackgroundServiceNames.machServiceName(appBundleIdentifier: appBundleIdentifier)

    /// ~/Library/Application Support/VideoScan/background/
    static var stateRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VideoScan/background", isDirectory: true)
    }

    init(arguments: [String]) {
        log = BackgroundFileLog.production()
        let root = Self.stateRoot
        activity = SystemActivitySource()
        backoff = Backoff(source: activity)
        // One supervisor per state root: a hand run (`--run era`) that is still
        // alive keeps this service to status-only until it finishes (StateRootLock.swift).
        supervisor = JobSupervisor(queue: FileJobQueueStore(directory: root.appendingPathComponent("queue", isDirectory: true)),
                                   checkpoints: FileCheckpointStore(directory: root.appendingPathComponent("checkpoints", isDirectory: true)),
                                   factory: DefaultJobFactory(stateRoot: root, log: log), backoff: backoff, log: log,
                                   ownership: FileStateRootLock(root: root, owner: "service \(Self.bundleIdentifier)"),
                                   schedule: Self.schedule(stateRoot: root, catalog: DefaultJobFactory.productionCatalogURL))
        server = XPCServer(machServiceName: Self.machServiceName, supervisor: supervisor, log: log,
                           allowedPeers: [Self.appBundleIdentifier, Self.bundleIdentifier], startedAt: startedAt)
    }

    /// The era job, scheduled by the helper (Rick 2026-11-04). The plan size
    /// is EraPlanner's own unit list — the one engine the job freezes at START.
    static func schedule(stateRoot: URL, catalog: URL) -> JobSchedule {
        let era = JobSchedule.Kind(
            kind: .era,
            planSize: {
                let journal = ObservationJournal(directory: stateRoot.appendingPathComponent("journal", isDirectory: true))
                return try EraPlanner.plan(catalogURL: catalog, journal: journal, signer: SeatedApproach.eraA2.signer, limit: nil,
                                           jobID: JobID(), isReadable: { FileManager.default.isReadableFile(atPath: $0) }).units.count
            },
            makeRequest: { EraJob.request(limit: nil, repoPath: EraCLIArguments.defaultRepo, requestedBy: "schedule") })
        return JobSchedule(kinds: [era], generation: { BackgroundCatalogAccess.generation(at: catalog) },
                           buildID: JobSchedule.buildID(), holds: ScheduleHoldStore.beside(stateRoot: stateRoot))
    }

    /// Quit from the menu bar in this boot (Rick 2026-11-08): log one line and
    /// return true — main.swift then exits 0 and launchd leaves it down. Called
    /// before `init`, so a held-down launch takes no state-root lock and starts
    /// no listener. A stale or torn marker is logged and the service runs.
    static func quitHoldsUsDown() -> Bool {
        let log = BackgroundFileLog.production()
        let store = BackgroundQuitStore.production()
        switch store.read() {
        case .none:
            return false
        case .active(let m):
            log.start()
            log.write("service not starting — quit from the menu bar at \(m.quitWords()) (pid \(ProcessInfo.processInfo.processIdentifier)); it starts again when VideoScan opens or the Mac restarts")
            log.close()
            return true
        case .stale(let m):
            log.start()
            log.write("quit marker from an earlier boot (quit at \(m.quitWords())) removed — starting")
            log.close()
            return false
        case .unreadable(let why):
            log.start()
            log.write("quit marker unreadable (\(why)) — starting anyway")
            log.close()
            return false
        case .noBootTime:
            log.start()
            log.write("quit marker present but the boot time could not be read — starting anyway")
            log.close()
            return false
        }
    }

    func start() {
        log.start()
        log.write("service started — \(Self.bundleIdentifier) pid \(ProcessInfo.processInfo.processIdentifier), mach service \(Self.machServiceName), state in \(Self.stateRoot.path), schema \(BackgroundProtocolVersion.current), build \(JobSchedule.buildID())")
        activity.start()
        let log = self.log
        Task {
            await backoff.onChange { state in log.write("backoff → \(state.words)") }
            await supervisor.start()
        }
        server.resume()
        installSignalHandlers()
    }

    /// SIGTERM (launchctl kickstart -k, logout): say so, then go. The
    /// checkpoint already holds every finished unit.
    private func installSignalHandlers() {
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        signal(SIGTERM, SIG_IGN)
        source.setEventHandler { [log, supervisor] in
            log.write("service received SIGTERM — exiting 0 (launchd leaves it down); work resumes from its checkpoints at the next launch")
            // A clean exit is not a crash: clear the in-flight marks first, so
            // three restarts never quarantine a unit (Fable review 11/04).
            // ExitTimeOut (30 s) bounds this before launchd sends SIGKILL.
            Task {
                await supervisor.prepareForExit()
                log.close()
                exit(0)
            }
        }
        source.resume()
        termSource = source
    }
    private var termSource: DispatchSourceSignal?

    /// The menu bar's Quit (Rick 2026-11-08): write the marker that keeps the
    /// helper down for this boot, then the same clean exit as SIGTERM. A
    /// marker that cannot be written still quits, and says the helper may come
    /// back at VideoScan's next status check.
    func quit() {
        let store = BackgroundQuitStore.production()
        do {
            let m = try store.write()
            log.write("menu bar: Quit — quit at \(m.quitWords()); exiting 0, stays down until VideoScan opens or the Mac restarts; work resumes from its checkpoints")
        } catch {
            log.write("menu bar: Quit — the quit marker was not written (\(error.localizedDescription)); exiting 0, but VideoScan's next status check may start it again")
        }
        Task { [supervisor, log] in
            await supervisor.prepareForExit()
            log.close()
            exit(0)
        }
    }

    /// The menu bar item (Rick 2026-11-03). Main thread, after `start()`.
    @MainActor func installMenuBar() {
        let controller = StatusMenuController(supervisor: supervisor, startedAt: startedAt, log: log,
                                              quit: { [weak self] in self?.quit() })
        controller.start()
        menuBar = controller
    }
    private var menuBar: AnyObject?
}
