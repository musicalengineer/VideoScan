// PreviewHelperSupervisor.swift (VideoScanCore)
// Stage 2 (2026-07-29): lifecycle for the DETACHED out-of-process preview
// helper (videoscan-preview-sweep). Rick's chosen approach is a detached
// CHILD PROCESS (NOT SMAppService — the project signs "Sign to Run Locally"
// only, so SMAppService's Developer-ID requirement is out). The helper is
// spawned by the app but reparented to launchd so it OUTLIVES app quit;
// nothing auto-starts it at reboot (no launchd job) — the next app launch
// re-checks the flag and respawns.
//
// Design mandate (composition + testable seams): the PURE lifecycle
// decision (`PreviewHelperSupervisor.decide`) is separated from every side
// effect. Spawning, stopping, the running-state probe, and locating the
// binary are all injectable protocols/closures, so the whole coordinator is
// unit-testable WITHOUT spawning a single real process.
//
// For Rick (C++ analogies):
//   - `enum` with associated-value-free cases ≈ a plain C enum; `Equatable`
//     ≈ a compiler-generated `operator==`.
//   - The protocols below ≈ pure-virtual interface classes; the app injects
//     concrete impls, tests inject fakes (dependency injection, no globals).
//   - `posix_spawn` + `POSIX_SPAWN_SETSID` ≈ fork/setsid/exec in one call:
//     the child becomes a session leader with no controlling terminal, so a
//     parent (the app) exiting can't take it down.

import Foundation
import Darwin

// MARK: - Events + actions (the decision alphabet)

/// What just happened that might change the helper's desired state.
public enum PreviewHelperEvent: Equatable, Sendable {
    /// The app finished launching (or the model wired the sweep). Respawn
    /// the helper if the flag is ON and one isn't already running.
    case launch
    /// User turned the sweep ON in Settings.
    case toggleOn
    /// User turned the sweep OFF in Settings.
    case toggleOff
}

/// The side effect the supervisor decided on. Pure value — the coordinator
/// (or a test) turns it into a real spawn/stop.
public enum PreviewHelperAction: Equatable, Sendable {
    /// Start a detached helper.
    case spawn
    /// Signal the running helper to exit (SIGTERM to the pidfile's pid).
    case stop
    /// Do nothing (already in the desired state).
    case none
}

// MARK: - Supervisor (PURE decision logic)

/// The whole lifecycle policy in one pure function. No I/O, no processes —
/// just `(enabled, isRunning, event) -> action`. Exhaustively unit-tested
/// over all 12 combos.
public struct PreviewHelperSupervisor: Sendable {

    public init() {}

    /// - Parameters:
    ///   - enabled: the persisted `previewSweepEnabled` flag AFTER the event
    ///     was applied (for a toggle, the new value).
    ///   - isRunning: whether a LIVE helper currently holds the pidfile.
    ///   - event: what triggered this decision.
    ///
    /// Decision table:
    ///
    ///   event      | enabled | isRunning | action
    ///   -----------|---------|-----------|-------
    ///   launch     |  false  |    any    | none    (flag off → leave alone)
    ///   launch     |  true   |   false   | spawn   (respawn on relaunch)
    ///   launch     |  true   |   true    | none    (already warming)
    ///   toggleOn   |  false  |    any    | none    (defensive: flag says off)
    ///   toggleOn   |  true   |   false   | spawn
    ///   toggleOn   |  true   |   true    | none    (already warming)
    ///   toggleOff  |   any   |   false   | none    (nothing to stop)
    ///   toggleOff  |   any   |   true    | stop    (kill it regardless of flag)
    ///
    /// Note: `launch` NEVER stops a running helper — a helper that survived
    /// the previous quit must keep going (the whole point of detaching).
    public func decide(enabled: Bool,
                       isRunning: Bool,
                       event: PreviewHelperEvent) -> PreviewHelperAction {
        switch event {
        case .launch, .toggleOn:
            guard enabled else { return .none }
            return isRunning ? .none : .spawn
        case .toggleOff:
            return isRunning ? .stop : .none
        }
    }
}

// MARK: - Running-state probe (isolation-safe)

/// Reads the helper's pidfile to answer "is a LIVE helper running?" from
/// ANOTHER process (the app). A valid instance must BOTH hold the pidfile's
/// flock and have a live recorded pid. The lock check prevents a stale
/// pidfile whose numeric pid was reused by an unrelated process from being
/// mistaken for the helper.
public enum PreviewHelperInstance {

    /// The live helper's pid, or nil when no live instance holds it.
    /// `isAlive` is injected so tests can poison the pidfile (pid present
    /// but not alive) without spawning anything.
    public static func runningPID(
        pidfileURL: URL,
        isAlive: (pid_t) -> Bool = PreviewHelperInstance.processIsAlive,
        isLockHeld: (URL) -> Bool = PreviewHelperInstance.pidfileLockIsHeld
    ) -> pid_t? {
        guard isLockHeld(pidfileURL),
              let data = try? Data(contentsOf: pidfileURL),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = pid_t(trimmed), pid > 0 else { return nil }
        return isAlive(pid) ? pid : nil
    }

    /// Convenience boolean form.
    public static func isRunning(
        pidfileURL: URL,
        isAlive: (pid_t) -> Bool = PreviewHelperInstance.processIsAlive,
        isLockHeld: (URL) -> Bool = PreviewHelperInstance.pidfileLockIsHeld
    ) -> Bool {
        runningPID(pidfileURL: pidfileURL, isAlive: isAlive, isLockHeld: isLockHeld) != nil
    }

    /// Nonblocking `try_lock()` probe on the same inter-process mutex the
    /// helper holds for its lifetime. Acquiring it ourselves means idle.
    public static func pidfileLockIsHeld(_ pidfileURL: URL) -> Bool {
        let fd = open(pidfileURL.path, O_RDWR)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK || errno == EAGAIN
    }

    /// `kill(pid, 0)` probes existence without delivering a signal.
    ///   0     → the process exists and we may signal it (alive).
    ///   EPERM → it exists but is owned by someone else (still alive).
    ///   ESRCH → no such process (dead / stale pid).
    public static func processIsAlive(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}

// MARK: - Side-effect seams (injected)

/// Spawns the helper as a DETACHED child (survives parent exit).
public protocol PreviewHelperSpawning: Sendable {
    /// - Returns: the child pid.
    /// - Throws: if the spawn fails (missing binary, exec error).
    func spawnDetached(executableURL: URL,
                       arguments: [String],
                       logFileURL: URL) throws -> pid_t
}

/// Stops a running helper.
public protocol PreviewHelperStopping: Sendable {
    func stop(pid: pid_t)
}

/// Errors from the real launcher.
public enum PreviewHelperSpawnError: Error, Equatable {
    /// `posix_spawn` returned a non-zero errno.
    case spawnFailed(errno: Int32)
    /// The requested executable isn't an executable file.
    case notExecutable(path: String)
}

// MARK: - Real launcher (posix_spawn + setsid)

/// Production spawner/stopper. Uses `posix_spawn` with `POSIX_SPAWN_SETSID`
/// so the child starts in a NEW session (own process group, no controlling
/// terminal) — that is what lets it outlive the GUI app that launched it.
/// stdin ← /dev/null, stdout+stderr → the helper log (append), so no fd is
/// inherited from the app and progress is captured for `tail`.
///
/// Memory footprint: constant — a handful of `strdup`'d argv strings, all
/// freed before return. No media buffering here (that's the helper's job,
/// and it streams).
public struct PosixSpawnHelperLauncher: PreviewHelperSpawning, PreviewHelperStopping {
    private let pidfileURL: URL?

    public init(pidfileURL: URL? = nil) {
        self.pidfileURL = pidfileURL
    }

    public func spawnDetached(executableURL: URL,
                              arguments: [String],
                              logFileURL: URL) throws -> pid_t {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw PreviewHelperSpawnError.notExecutable(path: executableURL.path)
        }
        // Make sure the log directory exists (best-effort; open below is the
        // real gate).
        try? FileManager.default.createDirectory(
            at: logFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        // File actions: rewire the child's stdio BEFORE exec.
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        // 0: stdin ← /dev/null (never inherit the app's stdin).
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        // 1: stdout → log (append). 2: stderr dup'd onto it.
        posix_spawn_file_actions_addopen(&fileActions, 1, logFileURL.path,
                                         O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&fileActions, 1, 2)

        // Attributes: SETSID → new session ⇒ detached from the app's
        // process group / (absent) controlling terminal ⇒ survives quit.
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

        // argv: [path, args..., NULL]. strdup because posix_spawn wants
        // mutable C strings; every allocation is freed on the way out.
        let argv = [executableURL.path] + arguments
        var cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgv.append(nil)
        defer { for p in cArgv where p != nil { free(p) } }

        var pid: pid_t = 0
        // environ: inherit the app's environment so the helper can find
        // ffmpeg on PATH (and honor VS_FFMPEG_PATH if the app set it).
        let rc = posix_spawn(&pid, executableURL.path, &fileActions, &attr, &cArgv, environ)
        guard rc == 0 else { throw PreviewHelperSpawnError.spawnFailed(errno: rc) }
        return pid
    }

    /// Stop a running helper with SIGTERM → grace-poll → SIGKILL escalation.
    ///
    /// SIGTERM is the clean path: the helper's watch loop is cooperative and
    /// terminates on SIGTERM's default disposition. But a TRULY hung helper
    /// (the rare case NOT already covered by ProcessRunner's deadline-bounded
    /// ffmpeg wedge) can ignore SIGTERM, so we poll for a grace window and
    /// escalate to SIGKILL — mirroring ProcessRunner's own SIGTERM → SIGKILL
    /// policy so both paths reap a wedged child the same way.
    ///
    /// The helper is DETACHED (reparented to launchd via POSIX_SPAWN_SETSID),
    /// so the app is NOT its parent: there's no zombie to reap, and
    /// `kill(pid, 0)` correctly reports ESRCH (aliveness = false) once it's
    /// gone.
    ///
    /// Non-blocking: the grace poll runs on a utility background queue so the
    /// (main-actor) settings toggle-off that triggers this never stalls the
    /// UI thread. Worst-case footprint: one detached work item holding a
    /// single `pid_t` for up to `graceSeconds`; no buffers.
    public func stop(pid: pid_t) {
        let pidfileURL = self.pidfileURL
        DispatchQueue.global(qos: .utility).async {
            PosixSpawnHelperLauncher.escalateStop(
                pid: pid,
                isAlive: { candidate in
                    guard let pidfileURL else {
                        return PreviewHelperInstance.processIsAlive(candidate)
                    }
                    return PosixSpawnHelperLauncher.isExpectedInstance(
                        pid: candidate, pidfileURL: pidfileURL)
                },
                term: { kill($0, SIGTERM) },
                kill9: { kill($0, SIGKILL) },
                sleep: { Thread.sleep(forTimeInterval: $0) }
            )
        }
    }

    /// Identity gate shared by TERM/KILL escalation and direct safety tests.
    /// Production's default probe requires the pidfile flock, exact PID, and
    /// live process; injection keeps the equality rule deterministic in tests.
    static func isExpectedInstance(
        pid: pid_t,
        pidfileURL: URL,
        runningPID: (URL) -> pid_t? = {
            PreviewHelperInstance.runningPID(pidfileURL: $0)
        }
    ) -> Bool {
        runningPID(pidfileURL) == pid
    }

    /// PURE, injectable stop escalation — the testable core of `stop(pid:)`.
    /// No real processes or wall-clock sleeps: every side effect is a seam,
    /// so tests drive clean/wedged/already-dead outcomes with counting fakes.
    ///
    /// Logic: send SIGTERM once, then poll `isAlive` every `pollInterval` for
    /// up to `graceSeconds`, returning as soon as the process is gone. If it
    /// is still alive when the grace window lapses, send SIGKILL once.
    ///
    /// - Note: the poll count is a fixed integer derived from
    ///   `graceSeconds / pollInterval` rather than a floating `elapsed <
    ///   grace` accumulator, so iteration count is deterministic (no 0.1
    ///   float-drift) — which the wedged-case test pins.
    static func escalateStop(
        pid: pid_t,
        graceSeconds: Double = 3.0,
        pollInterval: Double = 0.1,
        isAlive: (pid_t) -> Bool,
        term: (pid_t) -> Void,
        kill9: (pid_t) -> Void,
        sleep: (Double) -> Void
    ) {
        // Production's isAlive seam also validates the held flock and exact
        // pidfile PID, before TERM, after every sleep, and before KILL.
        guard isAlive(pid) else { return }
        term(pid)
        let steps = max(1, Int((graceSeconds / pollInterval).rounded()))
        for _ in 0..<steps {
            sleep(pollInterval)
            if !isAlive(pid) { return }
        }
        if isAlive(pid) { kill9(pid) }
    }
}

// MARK: - Standard paths

/// Canonical on-disk locations for the detached helper. Pidfile is the SAME
/// file the helper's `SingleInstanceLock` writes (so the app's running-probe
/// and the helper's single-instance guard agree).
public enum PreviewHelperPaths {

    /// ~/Library/Application Support/VideoScan/.previewsweepd.lock
    public static func pidfileURL(fileManager: FileManager = .default) -> URL {
        SingleInstanceLock.defaultURL(fileManager: fileManager)
    }

    /// ~/Library/Logs/VideoScan/previewsweepd.log — the helper's stdout/err.
    /// Distinct from videoscan.log (app lifecycle) and catalog.log; format
    /// is just the helper's own progress lines (do NOT reformat).
    public static func logURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("VideoScan", isDirectory: true)
            .appendingPathComponent("previewsweepd.log")
    }
}

// MARK: - Helper binary locator

/// Finds the `videoscan-preview-sweep` executable at runtime. Resolution
/// order (first executable wins):
///   1. `VIDEOSCAN_PREVIEW_HELPER` env override (dev / CI escape hatch).
///   2. The app bundle — `Contents/Helpers/` then `Contents/MacOS/`
///      (where a Stage-3 build phase will copy it for a shippable app).
///   3. Dev fallback — the package's `.build/{debug,release}/` next to the
///      source tree (so a plain `swift build` + Xcode Debug run works with
///      no bundle-copy phase yet).
///
/// Every input is injectable so the four branches are unit-testable with
/// temp dirs and no real bundle.
public enum PreviewHelperLocator {

    public static let helperName = "videoscan-preview-sweep"
    public static let envOverrideKey = "VIDEOSCAN_PREVIEW_HELPER"

    /// Not found anywhere — carries the searched paths for a clear log line.
    public struct NotFound: Error, Equatable {
        public let searched: [String]
        public init(searched: [String]) { self.searched = searched }
    }

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL? = Bundle.main.bundleURL,
        devSearchRoots: [URL] = PreviewHelperLocator.defaultDevSearchRoots(),
        fileManager: FileManager = .default
    ) throws -> URL {
        var searched: [String] = []

        // 1. Env override.
        if let override = environment[envOverrideKey], !override.isEmpty {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            if fileManager.isExecutableFile(atPath: url.path) { return url }
            searched.append("\(url.path) [env \(envOverrideKey), not executable]")
        }

        // 2. App bundle.
        if let bundleURL {
            for sub in ["Contents/Helpers", "Contents/MacOS"] {
                let url = bundleURL
                    .appendingPathComponent(sub, isDirectory: true)
                    .appendingPathComponent(helperName)
                if fileManager.isExecutableFile(atPath: url.path) { return url }
                searched.append(url.path)
            }
        }

        // 3. Dev .build fallback.
        for root in devSearchRoots {
            let url = root.appendingPathComponent(helperName)
            if fileManager.isExecutableFile(atPath: url.path) { return url }
            searched.append(url.path)
        }

        throw NotFound(searched: searched)
    }

    /// Walk up from this source file to the VideoScanCore package dir (the
    /// one holding Package.swift), then offer its common SwiftPM output
    /// dirs. Empty when the source tree isn't reachable (a shipped build on
    /// another machine — which should be using the bundle path anyway).
    public static func defaultDevSearchRoots(
        sourceFile: String = #filePath,
        fileManager: FileManager = .default
    ) -> [URL] {
        var dir = URL(fileURLWithPath: sourceFile).deletingLastPathComponent()
        for _ in 0..<8 {
            if fileManager.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                let build = dir.appendingPathComponent(".build", isDirectory: true)
                return [
                    build.appendingPathComponent("debug", isDirectory: true),
                    build.appendingPathComponent("release", isDirectory: true),
                    build.appendingPathComponent("arm64-apple-macosx/debug", isDirectory: true),
                    build.appendingPathComponent("arm64-apple-macosx/release", isDirectory: true),
                ]
            }
            dir.deleteLastPathComponent()
            if dir.path == "/" { break }
        }
        return []
    }
}

// MARK: - Idle-exit policy (helper self-termination)

/// Decides when the detached helper should exit ON ITS OWN so it isn't a
/// forever-resident process. Pure — the watch loop feeds it observations.
/// The helper exits only once the cache is fully warm (last pass left no
/// deferred work) AND the catalog has been unchanged for the grace window.
/// Any deferred work or catalog change resets the clock.
public struct HelperIdleExitPolicy: Sendable {

    /// Seconds of "warm + unchanged" before self-exit. 0 ⇒ never exit
    /// (pure `--watch`).
    public let idleGraceSeconds: Double

    public init(idleGraceSeconds: Double = 300) {
        self.idleGraceSeconds = idleGraceSeconds
    }

    /// Should the helper exit now?
    public func shouldExit(cacheWarm: Bool,
                           catalogUnchanged: Bool,
                           idleElapsedSeconds: Double) -> Bool {
        guard idleGraceSeconds > 0 else { return false }
        return cacheWarm && catalogUnchanged && idleElapsedSeconds >= idleGraceSeconds
    }
}

// MARK: - Coordinator (decision → side effect, all seams injected)

/// Glues the pure `PreviewHelperSupervisor` to the injected side effects.
/// Holds no AppKit/UI state; the app wraps it with real dependencies +
/// logging, tests wrap it with fakes. `handle` is the one entry point the
/// app calls on launch and on each settings toggle.
///
/// Thread-note: intended to be driven from the main actor (the settings
/// toggle + launch hook are main-actor). It performs blocking file reads
/// (the tiny pidfile) and a `posix_spawn`, both sub-millisecond.
public final class PreviewHelperCoordinator {

    private let supervisor = PreviewHelperSupervisor()
    private let spawner: any PreviewHelperSpawning
    private let stopper: any PreviewHelperStopping
    /// The live helper's pid (nil ⇒ not running). Injected so tests drive
    /// running-state without a real process; the app supplies the pidfile
    /// probe.
    private let runningPID: () -> pid_t?
    /// Resolves the helper binary lazily (only when we actually spawn).
    private let executableProvider: () throws -> URL
    /// Arguments for a fresh spawn (catalog path, watch/interval, idle-exit).
    private let arguments: () -> [String]
    private let logFileURL: URL
    private let log: (String) -> Void

    public init(spawner: any PreviewHelperSpawning,
                stopper: any PreviewHelperStopping,
                runningPID: @escaping () -> pid_t?,
                executableProvider: @escaping () throws -> URL,
                arguments: @escaping () -> [String],
                logFileURL: URL,
                log: @escaping (String) -> Void = { _ in }) {
        self.spawner = spawner
        self.stopper = stopper
        self.runningPID = runningPID
        self.executableProvider = executableProvider
        self.arguments = arguments
        self.logFileURL = logFileURL
        self.log = log
    }

    /// Is a live helper currently running? (Convenience for the app's
    /// coexistence gate.)
    public var isHelperRunning: Bool { runningPID() != nil }

    /// Apply an event: decide, then perform the side effect. Returns the
    /// action taken (for tests / diagnostics).
    @discardableResult
    public func handle(event: PreviewHelperEvent, enabled: Bool) -> PreviewHelperAction {
        // Carry the single validated PID through the decision and stop path;
        // do not reopen a race by performing a second initial probe.
        let livePID = runningPID()
        let action = supervisor.decide(enabled: enabled,
                                       isRunning: livePID != nil,
                                       event: event)
        switch action {
        case .spawn:
            do {
                let exe = try executableProvider()
                let pid = try spawner.spawnDetached(executableURL: exe,
                                                    arguments: arguments(),
                                                    logFileURL: logFileURL)
                log("preview helper: spawned detached pid \(pid) (\(exe.lastPathComponent))")
            } catch {
                log("preview helper: spawn failed — \(error)")
            }
        case .stop:
            if let pid = livePID {
                stopper.stop(pid: pid)
                log("preview helper: sent SIGTERM to pid \(pid)")
            }
        case .none:
            break
        }
        return action
    }
}
