import Foundation
import os

// MARK: - StallMonitor
//
// Progress-based stall watchdog for long-running Media File Operations
// (MFO) ffmpeg ops — framemd5/verify, transcode, reformat, perceptual
// compare. Punch-list #6 (Rick 2026-06-30).
//
// WHY (the incident): a Compare/archive-verify `ffmpeg -f framemd5` op on
// /Volumes/LaCieWorkspace wedged for 14 HOURS (ELAPSED 14:03, CPU 0:11,
// 0%) when the volume slept/stalled mid-read. It blocked app quit and left
// ZERO trace in any log — found only via `ps`. The same stale-fd condition
// produces the "bad file handle"/EBADF errors Rick sees.
//
// DESIGN STANCE (Rick, firm): the app must TOLERATE volumes that sleep or
// stall. We do NOT disable disk sleep and we do NOT demand the hardware
// behave. The guarantee is narrower and achievable: every op COMPLETES or
// FAILS CLEANLY with good diagnostics in BOUNDED time.
//
// WHY PROGRESS-BASED, NOT WALL-CLOCK: a legitimate 8 TB LaCie analysis runs
// for HOURS but makes CONTINUOUS progress (ffmpeg keeps emitting `-progress`
// blocks). A wedged op flatlines — 0% CPU, no frame advance, no progress
// output. So we reset a stall-timer on EVERY progress tick and only kill
// after NO progress for `thresholdSeconds`. A healthy multi-hour job never
// trips it; the 14 h hang dies in ~5 minutes.
//
// HOW THE KILL HAPPENS: this monitor does NOT own the ffmpeg `Process`.
// On stall it invokes `onStall`, and each MFO job's handler calls
// `task.cancel()`. That reaches `ProcessRunner`'s existing cancellation
// path, which already escalates SIGTERM → SIGKILL → abandon. Reusing that
// machinery keeps the core ProcessRunner/scan path untouched (scope was
// explicitly MFO-only). The same path runs on app-quit (cancelAll →
// job.cancel → task.cancel), so a wedged op can never block quit again.
//
// TESTABILITY: the decision logic (`recordTick(at:)` / `evaluateStall(at:)`)
// is pure and clock-agnostic — unit-tested in StallMonitorTests with literal
// timestamps, no real delays. The live `start()` poll loop and the power
// assertion are production-only and never run in those pure tests.
//
// Memory: holds nothing but two Doubles, a Bool, a few counters, and the
// poll Task. The onStall closure captures the job weakly. Worst-case
// footprint is a few dozen bytes.
//
// C++ analogy: a software watchdog timer you "kick" on each unit of
// forward progress; if it isn't kicked within the timeout it fires the
// reset handler. Here the kick is `tick()` and the reset is `onStall`.

/// File-scope logger — the detached poll task logs through this.
/// Shares the `fileOps` category with the MFO jobs it guards.
private let stallLog = Logger(subsystem: "Rick-Breen.VideoScan",
                              category: "fileOps")

/// A progress-fed watchdog. Kick it with `tick()` whenever the watched op
/// shows forward progress (an ffmpeg `-progress` line, a comparator
/// publish, …). If `thresholdSeconds` elapse with NO tick, `onStall` fires
/// exactly once.
///
/// `@unchecked Sendable`: all mutable state is guarded by `lock`; the
/// closures are `@Sendable`. (≈ a C++ class with an internal mutex.)
final class StallMonitor: @unchecked Sendable {

    // MARK: Tunables (named constants — see #6.1)

    /// Default no-progress window before we declare a stall and kill.
    /// 5 min: long enough that no legitimate progressing op is ever near
    /// it (real ffmpeg emits progress multiple times per second), short
    /// enough that the 14 h hang dies fast.
    static let defaultStallThresholdSeconds: Double = 5 * 60

    /// Hard ceiling on the threshold (#6.1 "10 max"). Even a caller that
    /// asks for more is clamped here — bounded-time is the guarantee.
    static let maxStallThresholdSeconds: Double = 10 * 60

    /// How often the poll loop checks for silence. Far smaller than the
    /// threshold so the kill lands within ~one interval of the deadline.
    static let defaultPollIntervalSeconds: Double = 15

    // MARK: State (lock-guarded)

    private let lock = NSLock()
    private let thresholdSeconds: Double
    private let pollIntervalSeconds: Double
    /// Monotonic seconds source. Injectable so tests are deterministic and
    /// production uses a clock immune to wall-clock jumps (NTP, DST).
    private let clock: @Sendable () -> Double
    /// Human label for the op ("preservation verify (video)", "reformat",
    /// "perceptual compare") — only used in log lines.
    private let label: String
    private let onStall: @Sendable (Double) -> Void

    private var lastTickAt: Double
    /// Latched once the stall fires so `onStall` runs at most once and a
    /// late tick can't "un-stall" a killed op.
    private var fired = false
    private var pollTask: Task<Void, Never>?
    /// Power-assertion token (production only) — see the "Power assertion"
    /// section below. Begun in `start()` under the SAME lock hold as the
    /// running-check and `pollTask` assignment, so a racing second `start()`
    /// can never overwrite (leak) it.
    private var activityToken: NSObjectProtocol?

    // MARK: Lifecycle counters (lock-guarded; test introspection)
    //
    // Cheap integers written under `lock` alongside the state they shadow.
    // They pin the atomicity contract of start()/stop(): exactly ONE poll
    // loop per start/stop cycle, and every activity token begun is ended.
    // (StallMonitorTests hammers start() concurrently and asserts on these.)
    private var loopsSpawned = 0
    private var activityTokensBegun = 0
    private var activityTokensEnded = 0

    /// Snapshot of the lifecycle counters (test introspection only).
    var lifecycleCountersForTesting: (loopsSpawned: Int, tokensBegun: Int, tokensEnded: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (loopsSpawned, activityTokensBegun, activityTokensEnded)
    }

    /// True while a poll-loop handle is held (test introspection only).
    var isRunningForTesting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pollTask != nil
    }

    // MARK: Init

    /// - Parameters:
    ///   - label: diagnostic name for the op (log lines only).
    ///   - thresholdSeconds: no-progress window before firing. Clamped to
    ///     `[1, maxStallThresholdSeconds]`.
    ///   - pollIntervalSeconds: poll cadence for the live loop.
    ///   - clock: monotonic seconds source (injectable for tests).
    ///   - onStall: called once, off the main actor, with the observed
    ///     seconds-since-last-tick. Handlers hop to their actor and
    ///     `task.cancel()`.
    init(label: String,
         thresholdSeconds: Double = StallMonitor.defaultStallThresholdSeconds,
         pollIntervalSeconds: Double = StallMonitor.defaultPollIntervalSeconds,
         clock: @escaping @Sendable () -> Double = { StallMonitor.monotonicSeconds },
         onStall: @escaping @Sendable (Double) -> Void) {
        // Clamp: never below 1 s (a 0 threshold would fire instantly),
        // never above the 10-min ceiling.
        self.thresholdSeconds = min(max(thresholdSeconds, 1), StallMonitor.maxStallThresholdSeconds)
        self.pollIntervalSeconds = max(pollIntervalSeconds, 0.01)
        self.clock = clock
        self.label = label
        self.onStall = onStall
        self.lastTickAt = clock()
    }

    /// Monotonic seconds from the kernel uptime clock. Immune to wall-clock
    /// adjustments (NTP, manual set) that could otherwise make a healthy op
    /// look stalled or hide a real stall.
    static var monotonicSeconds: Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    // MARK: Pure decision core (unit-tested, no threading, no I/O)

    /// Kick the watchdog: record forward progress at time `now`. A tick
    /// after the stall already fired is ignored (the op is being killed).
    func recordTick(at now: Double) {
        lock.lock()
        if !fired { lastTickAt = now }
        lock.unlock()
    }

    /// True iff the op has been silent for at least `thresholdSeconds` as of
    /// `now`. LATCHES — once it returns true it keeps returning true, so the
    /// caller fires `onStall` exactly once. Pure; safe to call from tests.
    func evaluateStall(at now: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return true }
        if now - lastTickAt >= thresholdSeconds {
            fired = true
            return true
        }
        return false
    }

    /// Seconds elapsed since the last tick as of `now` (for logging).
    func secondsSinceLastTick(at now: Double) -> Double {
        lock.lock()
        defer { lock.unlock() }
        return now - lastTickAt
    }

    /// Convenience kick using the injected clock.
    func tick() { recordTick(at: clock()) }

    // MARK: Live driver (production)

    /// Start watching. Takes a bounded power assertion (so App Nap / sudden
    /// termination can't silence the watchdog mid-op) and launches the poll
    /// loop. Idempotent AND race-safe: a second `start()` while running is a
    /// no-op even from another thread.
    ///
    /// The running-check, activity-token acquisition, and `pollTask`
    /// assignment are ONE critical section. (≈ C++: the whole test-and-set
    /// lives inside the mutex. The earlier version checked under the lock
    /// but assigned after releasing it — classic TOCTOU: two racers could
    /// each spawn a poll loop, and the loser's `beginActivity` token
    /// overwrote the winner's, leaking it.) `ProcessInfo.beginActivity` and
    /// `Task.detached` are both non-reentrant here (neither calls back into
    /// the monitor), so holding the lock across them is deadlock-free; the
    /// detached task doesn't run synchronously.
    func start() {
        lock.lock()
        guard pollTask == nil else {
            lock.unlock()
            return
        }
        lastTickAt = clock()
        // A start() begins a FRESH watch: clear the fired latch. The
        // latch guarantees onStall fires exactly once PER WATCH — but
        // skip-and-continue consumers (FindPersonJob wedge-skip,
        // GH #156) legitimately stop()+start() after a fire, and
        // without this reset the latch made every subsequent poll fire
        // instantly while recordTick was ignored — the 2026-08-06
        // false-wedge cascade (healthy files abandoned every 15 s for
        // the rest of the run).
        fired = false

        // Power assertion — see the "Power assertion" section below for the
        // option rationale. Taken under the lock so exactly one token can
        // ever be live per start/stop cycle.
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.background, .suddenTerminationDisabled, .automaticTerminationDisabled],
            reason: "VideoScan MFO long op: \(label)")
        activityTokensBegun += 1

        // `pollIntervalSeconds` is immutable — capture it by value so the
        // sleep at the top of each pass never needs (and never retains)
        // `self`. `[weak self]` + per-iteration `guard let` means the loop
        // holds the monitor strongly only for the microseconds of each
        // stall check, not for the loop's whole lifetime.
        let interval = pollIntervalSeconds
        loopsSpawned += 1
        pollTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                // Re-weaken every pass: the strong binding below is scoped
                // to this iteration, so if the owner drops the monitor the
                // loop exits on its next wake instead of pinning it forever.
                guard let self else { return }
                let now = self.clock()
                if self.evaluateStall(at: now) {
                    let silent = self.secondsSinceLastTick(at: now)
                    stallLog.error("STALL: \(self.label, privacy: .public) — no progress for \(silent, format: .fixed(precision: 0), privacy: .public)s (threshold \(self.thresholdSeconds, format: .fixed(precision: 0), privacy: .public)s) → invoking kill handler")
                    self.onStall(silent)
                    return
                }
            }
        }
        lock.unlock()

        stallLog.info("power assertion taken (\(self.label, privacy: .public)): App Nap suppressed, sudden/auto-termination disabled (sleep NOT disabled)")
    }

    /// Stop watching: cancel the poll loop and release the power assertion.
    /// Idempotent — safe to call from a `defer` after a normally-completing
    /// op as well as after a stall.
    ///
    /// `pollTask` and `activityToken` are captured-and-cleared in ONE
    /// critical section, mirroring `start()`. (The earlier version used two
    /// separate lock holds — clear `pollTask`, then a second lock inside
    /// `endActivityToken()`. A `start()` racing into the gap saw
    /// `pollTask == nil`, began token #2 overwriting still-live token #1 —
    /// leaked, App Nap suppressed forever — and this tail then ended
    /// token #2, leaving the new poll loop running with no assertion.
    /// Pinned by `interleavedStopStartPairsNeverLeakToken`.) The cancel and
    /// `endActivity` side effects run outside the lock; neither re-enters
    /// the monitor.
    func stop() {
        lock.lock()
        let task = pollTask
        pollTask = nil
        let token = activityToken
        activityToken = nil
        if token != nil { activityTokensEnded += 1 }
        lock.unlock()
        task?.cancel()
        if let token {
            ProcessInfo.processInfo.endActivity(token)
            stallLog.info("power assertion released (\(self.label, privacy: .public))")
        }
    }

    // MARK: Power assertion (#7 optional — taken/released are logged)
    //
    // Rick's stance: do NOT disable disk/system sleep. So we deliberately do
    // NOT pass `.idleSystemSleepDisabled` / `.idleDisplaySleepDisabled`. We
    // use `.background` (suppresses App Nap so a backgrounded VideoScan keeps
    // servicing the poll loop on schedule) plus the termination guards (a
    // long, expensive transcode/verify shouldn't be sudden- or
    // automatically-terminated out from under us). The hardware is still
    // free to sleep — and the watchdog is exactly what makes that safe.
    //
    // Acquisition lives inline in `start()` and release inline in `stop()` —
    // each inside the SAME critical section as its `pollTask` transition, so
    // the token and the loop handle can never disagree about lifecycle.

    // MARK: Post-mortem attribution (#6.4)

    /// After a stall-kill / I/O error, classify the likely cause WITHOUT
    /// hanging: did the source volume drop out (unmount/sleep/SMB drop), or
    /// is the volume still mounted and the file/device read itself failing
    /// (EIO/EBADF)? These are indistinguishable to the user today.
    ///
    /// Bounded by construction: `VolumeReachability.currentMountedRoots()`
    /// reads the kernel mount table (getmntinfo MNT_NOWAIT) — in-memory,
    /// microseconds, never statfs's the device, so it can't itself spin up a
    /// sleeping HDD or block on a dead mount. Pure-ish string result for
    /// logging + the failure message.
    static func attribution(forPaths paths: [String]) -> String {
        let roots = paths
            .map { MediaVolumeGatePolicy.volumeRoot(forPath: $0) }
            .filter { $0.hasPrefix("/Volumes/") }
        guard !roots.isEmpty else {
            return "internal volume still mounted — likely a file/device read error (EIO/EBADF), not a volume drop"
        }
        let mounted = VolumeReachability.currentMountedRoots()
        let unreachable = roots.filter { !mounted.contains($0) }
        if unreachable.isEmpty {
            let list = roots.joined(separator: ", ")
            return "volume(s) \(list) still mounted — file/device read error (EIO/EBADF) mid-op, not a volume drop"
        }
        let list = unreachable.joined(separator: ", ")
        return "volume(s) \(list) became UNREACHABLE mid-op (unmounted / slept / dropped out)"
    }
}
