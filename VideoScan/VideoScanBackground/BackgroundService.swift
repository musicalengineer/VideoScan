// BackgroundService.swift — VideoScan Background
//
// Wires the Core pieces into one running service: the supervisor on the
// durable folders under ~/Library/Application Support/VideoScan/background/,
// Backoff on the real Mac (SystemActivitySource), the XPC listener, the log
// at ~/Library/Logs/VideoScan/background.log, and the idle-exit timer.
//
// Memory: the supervisor's bookkeeping (see JobSupervisor) plus one NSXPC
// listener; the NoOp job holds nothing. Logged at start.

import Foundation
import VideoScanCore

final class BackgroundService: @unchecked Sendable {

    /// `--full` (design §3.5 night window): run full-out regardless of idle.
    private let forceFull: Bool
    private let log: BackgroundFileLog
    private let supervisor: JobSupervisor
    private let backoff: Backoff
    private let activity: SystemActivitySource
    private let server: XPCServer
    private let startedAt = Date()
    private var idleTimer: DispatchSourceTimer?

    static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "Rick-Breen.VideoScan.Background"
    static let appBundleIdentifier = BackgroundServiceNames.appBundleIdentifier(helperBundleIdentifier: bundleIdentifier) ?? "Rick-Breen.VideoScan"
    static let machServiceName = BackgroundServiceNames.machServiceName(appBundleIdentifier: appBundleIdentifier)

    /// ~/Library/Application Support/VideoScan/background/
    static var stateRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VideoScan/background", isDirectory: true)
    }

    init(arguments: [String]) {
        forceFull = arguments.contains("--full")
        log = BackgroundFileLog.production()
        let root = Self.stateRoot
        activity = SystemActivitySource(nightWindow: forceFull)
        backoff = Backoff(source: activity)
        supervisor = JobSupervisor(queue: FileJobQueueStore(directory: root.appendingPathComponent("queue", isDirectory: true)),
                                   checkpoints: FileCheckpointStore(directory: root.appendingPathComponent("checkpoints", isDirectory: true)),
                                   factory: DefaultJobFactory(), backoff: backoff, log: log)
        server = XPCServer(machServiceName: Self.machServiceName, supervisor: supervisor, log: log,
                           allowedPeers: [Self.appBundleIdentifier, Self.bundleIdentifier], startedAt: startedAt)
    }

    func start() {
        log.start()
        log.write("service started — \(Self.bundleIdentifier) pid \(ProcessInfo.processInfo.processIdentifier), mach service \(Self.machServiceName), state in \(Self.stateRoot.path), schema \(BackgroundProtocolVersion.current)\(forceFull ? ", --full" : "")")
        activity.start()
        let log = self.log
        Task {
            await backoff.onChange { state in log.write("backoff → \(state.words)") }
            await supervisor.start()
        }
        server.resume()
        installSignalHandlers()
        startIdleTimer()
    }

    /// Every 30 s: exit cleanly when nothing is queued, nothing is active and
    /// 10 idle minutes have passed (IdleExitPolicy; design §3.2).
    private func startIdleTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "\(Self.bundleIdentifier).idle", qos: .utility))
        timer.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(5))
        timer.setEventHandler { [supervisor, log] in
            Task {
                if await supervisor.shouldExitWhenIdle() {
                    log.write("service idle for \(Int(IdleExitPolicy.defaultIdleSeconds)) s with an empty queue — exiting cleanly (launchd restarts it on the next message)")
                    log.close()
                    exit(0)
                }
            }
        }
        timer.resume()
        idleTimer = timer
    }

    /// SIGTERM (launchctl kickstart -k, logout): say so, then go. The
    /// checkpoint already holds every finished unit.
    private func installSignalHandlers() {
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        signal(SIGTERM, SIG_IGN)
        source.setEventHandler { [log] in
            log.write("service received SIGTERM — exiting; queued work resumes from its checkpoints on the next launch")
            log.close()
            exit(0)
        }
        source.resume()
        termSource = source
    }
    private var termSource: DispatchSourceSignal?
}
