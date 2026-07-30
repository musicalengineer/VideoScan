// PreviewHelperSupervisorTests.swift
// Stage 2 lifecycle — Logic + Isolation dimensions for the DETACHED
// out-of-process preview helper. Everything here is pure or fake-driven:
// NO real process is ever spawned.
//   - PreviewHelperSupervisor.decide: exhaustive over all 12
//     (event × enabled × isRunning) combos.
//   - PreviewHelperCoordinator: decision → side effect, verified with a
//     fake spawner/stopper (no posix_spawn).
//   - PreviewHelperInstance: the running-state probe, including the
//     poisoned/stale pidfile isolation case.
//   - HelperIdleExitPolicy: the helper's self-exit decision.

import XCTest
import Darwin
@testable import VideoScanCore

// MARK: - Fakes

private final class FakeSpawner: PreviewHelperSpawning, @unchecked Sendable {
    struct Call: Equatable { let exe: String; let args: [String]; let log: String }
    private(set) var calls: [Call] = []
    var nextPID: pid_t = 4242
    var throwError: Error?

    func spawnDetached(executableURL: URL, arguments: [String], logFileURL: URL) throws -> pid_t {
        if let throwError { throw throwError }
        calls.append(Call(exe: executableURL.path, args: arguments, log: logFileURL.path))
        return nextPID
    }
}

private final class FakeStopper: PreviewHelperStopping, @unchecked Sendable {
    private(set) var stopped: [pid_t] = []
    func stop(pid: pid_t) { stopped.append(pid) }
}

// MARK: - Decision table (Logic)

final class PreviewHelperSupervisorTests: XCTestCase {

    private let sup = PreviewHelperSupervisor()

    func testLaunchRespawnsOnlyWhenEnabledAndNotRunning() {
        XCTAssertEqual(sup.decide(enabled: true,  isRunning: false, event: .launch), .spawn)
        XCTAssertEqual(sup.decide(enabled: true,  isRunning: true,  event: .launch), .none)
        XCTAssertEqual(sup.decide(enabled: false, isRunning: false, event: .launch), .none)
        // Never stop on launch — a helper that survived quit keeps going.
        XCTAssertEqual(sup.decide(enabled: false, isRunning: true,  event: .launch), .none)
    }

    func testToggleOnSpawnsOnlyWhenEnabledAndNotRunning() {
        XCTAssertEqual(sup.decide(enabled: true,  isRunning: false, event: .toggleOn), .spawn)
        XCTAssertEqual(sup.decide(enabled: true,  isRunning: true,  event: .toggleOn), .none)
        // Defensive: flag off means don't spawn even on a toggleOn event.
        XCTAssertEqual(sup.decide(enabled: false, isRunning: false, event: .toggleOn), .none)
        XCTAssertEqual(sup.decide(enabled: false, isRunning: true,  event: .toggleOn), .none)
    }

    func testToggleOffStopsOnlyWhenRunning() {
        XCTAssertEqual(sup.decide(enabled: false, isRunning: true,  event: .toggleOff), .stop)
        XCTAssertEqual(sup.decide(enabled: false, isRunning: false, event: .toggleOff), .none)
        // Even if the flag is (inconsistently) still true, a toggleOff stops.
        XCTAssertEqual(sup.decide(enabled: true,  isRunning: true,  event: .toggleOff), .stop)
        XCTAssertEqual(sup.decide(enabled: true,  isRunning: false, event: .toggleOff), .none)
    }

    /// Belt-and-suspenders: enumerate ALL 12 combos so a future edit to the
    /// switch can't silently change one.
    func testExhaustiveDecisionTable() {
        let expected: [(PreviewHelperEvent, Bool, Bool, PreviewHelperAction)] = [
            (.launch,    true,  false, .spawn), (.launch,    true,  true,  .none),
            (.launch,    false, false, .none),  (.launch,    false, true,  .none),
            (.toggleOn,  true,  false, .spawn), (.toggleOn,  true,  true,  .none),
            (.toggleOn,  false, false, .none),  (.toggleOn,  false, true,  .none),
            (.toggleOff, true,  false, .none),  (.toggleOff, true,  true,  .stop),
            (.toggleOff, false, false, .none),  (.toggleOff, false, true,  .stop),
        ]
        for (event, enabled, running, want) in expected {
            XCTAssertEqual(sup.decide(enabled: enabled, isRunning: running, event: event), want,
                           "\(event) enabled=\(enabled) running=\(running)")
        }
    }
}

// MARK: - Coordinator (decision → side effect, fakes)

final class PreviewHelperCoordinatorTests: XCTestCase {

    private func makeCoordinator(
        spawner: FakeSpawner,
        stopper: FakeStopper,
        running: @escaping () -> pid_t?,
        exe: URL = URL(fileURLWithPath: "/opt/helper/videoscan-preview-sweep"),
        exeThrows: Error? = nil
    ) -> PreviewHelperCoordinator {
        PreviewHelperCoordinator(
            spawner: spawner,
            stopper: stopper,
            runningPID: running,
            executableProvider: { if let exeThrows { throw exeThrows }; return exe },
            arguments: { ["--watch", "--idle-exit", "300"] },
            logFileURL: URL(fileURLWithPath: "/tmp/previewsweepd.log"))
    }

    func testLaunchEnabledNotRunningSpawns() {
        let spawner = FakeSpawner(), stopper = FakeStopper()
        let coord = makeCoordinator(spawner: spawner, stopper: stopper, running: { nil })
        XCTAssertEqual(coord.handle(event: .launch, enabled: true), .spawn)
        XCTAssertEqual(spawner.calls.count, 1)
        XCTAssertEqual(spawner.calls.first?.args, ["--watch", "--idle-exit", "300"])
        XCTAssertTrue(stopper.stopped.isEmpty)
    }

    func testLaunchAlreadyRunningDoesNothing() {
        let spawner = FakeSpawner(), stopper = FakeStopper()
        let coord = makeCoordinator(spawner: spawner, stopper: stopper, running: { 999 })
        XCTAssertEqual(coord.handle(event: .launch, enabled: true), .none)
        XCTAssertTrue(spawner.calls.isEmpty)
    }

    func testToggleOffRunningSendsStopToThePidfilePID() {
        let spawner = FakeSpawner(), stopper = FakeStopper()
        let coord = makeCoordinator(spawner: spawner, stopper: stopper, running: { 777 })
        XCTAssertEqual(coord.handle(event: .toggleOff, enabled: false), .stop)
        XCTAssertEqual(stopper.stopped, [777])
        XCTAssertTrue(spawner.calls.isEmpty)
    }

    func testToggleOffProbesOnceAndStopsOriginallyValidatedPID() {
        let spawner = FakeSpawner(), stopper = FakeStopper()
        var probeCount = 0
        let coord = makeCoordinator(spawner: spawner, stopper: stopper, running: {
            probeCount += 1
            return probeCount == 1 ? 777 : 888
        })

        XCTAssertEqual(coord.handle(event: .toggleOff, enabled: false), .stop)
        XCTAssertEqual(probeCount, 1, "toggle-off must carry one validated PID")
        XCTAssertEqual(stopper.stopped, [777])
    }

    func testToggleOffNotRunningDoesNothing() {
        let spawner = FakeSpawner(), stopper = FakeStopper()
        let coord = makeCoordinator(spawner: spawner, stopper: stopper, running: { nil })
        XCTAssertEqual(coord.handle(event: .toggleOff, enabled: false), .none)
        XCTAssertTrue(stopper.stopped.isEmpty)
    }

    func testSpawnFailureIsSwallowedNotCrashed() {
        // A missing binary must NOT crash the app — the decision is still
        // .spawn, but no pid is recorded and nothing throws to the caller.
        let spawner = FakeSpawner(), stopper = FakeStopper()
        let coord = makeCoordinator(spawner: spawner, stopper: stopper, running: { nil },
                                    exeThrows: PreviewHelperLocator.NotFound(searched: ["/nope"]))
        XCTAssertEqual(coord.handle(event: .toggleOn, enabled: true), .spawn)
        XCTAssertTrue(spawner.calls.isEmpty, "resolver threw → no spawn attempt recorded")
    }

    func testIsHelperRunningReflectsProbe() {
        let spawner = FakeSpawner(), stopper = FakeStopper()
        var live: pid_t? = nil
        let coord = makeCoordinator(spawner: spawner, stopper: stopper, running: { live })
        XCTAssertFalse(coord.isHelperRunning)
        live = 55
        XCTAssertTrue(coord.isHelperRunning)
    }
}

// MARK: - Running-state probe (Isolation)

final class PreviewHelperInstanceTests: XCTestCase {

    private func tempPidfile(_ contents: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pidfile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(".previewsweepd.lock")
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func identity(pid: Int32 = 2222,
                          path: String = "/Helpers/videoscan-preview-sweep",
                          seconds: UInt64 = 100,
                          microseconds: UInt64 = 200) -> PreviewHelperProcessIdentity {
        PreviewHelperProcessIdentity(pid: pid,
                                     executablePath: path,
                                     startSeconds: seconds,
                                     startMicroseconds: microseconds)
    }

    private func tempIdentityFile(_ value: PreviewHelperProcessIdentity) throws -> URL {
        let data = try XCTUnwrap(value.encoded())
        return try tempPidfile(String(decoding: data, as: UTF8.self))
    }

    func testMissingPidfileIsNotRunning() {
        let missing = URL(fileURLWithPath: "/no/such/\(UUID().uuidString)/.previewsweepd.lock")
        XCTAssertNil(PreviewHelperInstance.runningPID(pidfileURL: missing))
        XCTAssertFalse(PreviewHelperInstance.isRunning(pidfileURL: missing))
    }

    func testGarbagePidfileIsNotRunning() throws {
        let url = try tempPidfile("not-a-number\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertNil(PreviewHelperInstance.runningPID(
            pidfileURL: url, isAlive: { _ in true }, isLockHeld: { _ in true }))
    }

    func testValidHeldIdentityReportsRunning() throws {
        let expected = identity()
        let url = try tempIdentityFile(expected)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertEqual(PreviewHelperInstance.runningPID(
            pidfileURL: url,
            isAlive: { $0 == expected.pid },
            isLockHeld: { _ in true },
            identityForPID: { _ in expected }), expected.pid)
    }

    func testSamePIDDifferentStartTokenFailsClosed() throws {
        let recorded = identity(seconds: 100)
        let reused = identity(seconds: 101)
        let url = try tempIdentityFile(recorded)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertNil(PreviewHelperInstance.runningPID(
            pidfileURL: url,
            isAlive: { _ in true },
            isLockHeld: { _ in true },
            identityForPID: { _ in reused }))
    }

    func testWrongExecutableFailsClosed() throws {
        let recorded = identity(path: "/Helpers/videoscan-preview-sweep")
        let unrelated = identity(path: "/usr/bin/unrelated")
        let url = try tempIdentityFile(recorded)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertNil(PreviewHelperInstance.runningPID(
            pidfileURL: url,
            isAlive: { _ in true },
            isLockHeld: { _ in true },
            identityForPID: { _ in unrelated }))
    }

    func testLegacyPIDOnlyRecordFailsClosedEvenWhenPIDIsLiveAndLockHeld() throws {
        let url = try tempPidfile("2222\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertNil(PreviewHelperInstance.runningPID(
            pidfileURL: url,
            isAlive: { _ in true },
            isLockHeld: { _ in true },
            identityForPID: { _ in self.identity() }))
    }

    /// A live unrelated process whose PID happens to match stale text must
    /// not be reported or signaled when no helper owns the flock.
    func testUnlockedPidfileRejectsReusedLivePID() throws {
        let url = try tempPidfile("\(getpid())\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertNil(PreviewHelperInstance.runningPID(pidfileURL: url))
    }


    func testStopIdentityPredicateRequiresHeldLockSameLivePID() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stop-identity-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent(".previewsweepd.lock")
        let lock = try XCTUnwrap(SingleInstanceLock.acquire(at: url))
        var released = false
        defer {
            if !released { lock.release() }
            try? FileManager.default.removeItem(at: dir)
        }

        XCTAssertTrue(PosixSpawnHelperLauncher.isExpectedInstance(
            pid: getpid(), pidfileURL: url))

        let changedHandle = try FileHandle(forWritingTo: url)
        try changedHandle.truncate(atOffset: 0)
        try changedHandle.write(contentsOf: Data("\(getppid())\n".utf8))
        try changedHandle.close()
        XCTAssertFalse(PosixSpawnHelperLauncher.isExpectedInstance(
            pid: getpid(), pidfileURL: url), "changed pidfile PID must fail identity")

        let deadHandle = try FileHandle(forWritingTo: url)
        try deadHandle.truncate(atOffset: 0)
        try deadHandle.write(contentsOf: Data("999998\n".utf8))
        try deadHandle.close()
        XCTAssertFalse(PosixSpawnHelperLauncher.isExpectedInstance(
            pid: 999_998, pidfileURL: url), "dead pid must fail even while lock is held")

        lock.release()
        released = true
        XCTAssertFalse(PosixSpawnHelperLauncher.isExpectedInstance(
            pid: getpid(), pidfileURL: url), "lost lock must fail identity")
    }

    func testRealHeldLockReportsRunning() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("held-pidfile-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent(".previewsweepd.lock")
        let lock = try XCTUnwrap(SingleInstanceLock.acquire(at: url))
        defer {
            lock.release()
            try? FileManager.default.removeItem(at: dir)
        }
        XCTAssertEqual(PreviewHelperInstance.runningPID(pidfileURL: url), getpid())
    }

    /// The default aliveness probe: our OWN pid is unquestionably alive;
    /// a very high, never-allocated pid is not.
    func testProcessIsAliveDefaultProbe() {
        let me = getpid()
        XCTAssertTrue(PreviewHelperInstance.processIsAlive(me))
        // PID_MAX on Darwin is 99999; this is guaranteed unused.
        XCTAssertFalse(PreviewHelperInstance.processIsAlive(999_998))
    }
}

// MARK: - Idle-exit policy

final class HelperIdleExitPolicyTests: XCTestCase {

    func testExitsOnlyWhenWarmUnchangedAndPastGrace() {
        let policy = HelperIdleExitPolicy(idleGraceSeconds: 300)
        XCTAssertTrue(policy.shouldExit(cacheWarm: true, catalogUnchanged: true, idleElapsedSeconds: 300))
        XCTAssertTrue(policy.shouldExit(cacheWarm: true, catalogUnchanged: true, idleElapsedSeconds: 331))
        // Not yet past the grace window.
        XCTAssertFalse(policy.shouldExit(cacheWarm: true, catalogUnchanged: true, idleElapsedSeconds: 299))
        // Cache still has deferred work — keep running.
        XCTAssertFalse(policy.shouldExit(cacheWarm: false, catalogUnchanged: true, idleElapsedSeconds: 999))
        // Catalog changed — keep running.
        XCTAssertFalse(policy.shouldExit(cacheWarm: true, catalogUnchanged: false, idleElapsedSeconds: 999))
    }

    func testZeroGraceNeverExits() {
        let policy = HelperIdleExitPolicy(idleGraceSeconds: 0)
        XCTAssertFalse(policy.shouldExit(cacheWarm: true, catalogUnchanged: true, idleElapsedSeconds: 1_000_000))
    }
}

// MARK: - Stop escalation (SIGTERM → grace → SIGKILL)

/// Unit-tests the PURE `PosixSpawnHelperLauncher.escalateStop`. No real
/// processes and no real sleep: an injected sleep just advances a counter,
/// so every case is deterministic with zero wall-clock waits.
final class PreviewHelperStopEscalationTests: XCTestCase {

    /// Records every seam call for assertions.
    private final class Seams {
        var termCalls: [pid_t] = []
        var kill9Calls: [pid_t] = []
        var sleepCount = 0
        /// Feeds `isAlive` a scripted sequence; the last value repeats once
        /// the script is exhausted.
        var aliveScript: [Bool]
        private var aliveIndex = 0

        init(alive: [Bool]) { self.aliveScript = alive }

        func isAlive(_ pid: pid_t) -> Bool {
            let v = aliveIndex < aliveScript.count ? aliveScript[aliveIndex] : (aliveScript.last ?? false)
            aliveIndex += 1
            return v
        }
    }

    private func run(_ seams: Seams, grace: Double = 3.0, poll: Double = 0.1) {
        PosixSpawnHelperLauncher.escalateStop(
            pid: 4242,
            graceSeconds: grace,
            pollInterval: poll,
            isAlive: { seams.isAlive($0) },
            term: { seams.termCalls.append($0) },
            kill9: { seams.kill9Calls.append($0) },
            sleep: { _ in seams.sleepCount += 1 }
        )
    }

    /// Clean stop: alive once (still winding down), then gone → SIGTERM only.
    func testCleanStopSigtermOnlyNoKill9() {
        let seams = Seams(alive: [true, false])
        run(seams)
        XCTAssertEqual(seams.termCalls, [4242], "SIGTERM sent exactly once")
        XCTAssertTrue(seams.kill9Calls.isEmpty, "clean exit must not escalate to SIGKILL")
        XCTAssertEqual(seams.sleepCount, 1, "polled once, saw it exit, stopped")
    }

    /// Wedged: never dies → SIGTERM, full grace window, then one SIGKILL.
    /// Poll iterations are bounded by graceSeconds / pollInterval.
    func testWedgedEscalatesToKill9AfterGrace() {
        let seams = Seams(alive: [true])   // always alive
        run(seams, grace: 3.0, poll: 0.1)
        XCTAssertEqual(seams.termCalls, [4242], "SIGTERM sent first")
        XCTAssertEqual(seams.kill9Calls, [4242], "SIGKILL sent once after grace")
        XCTAssertEqual(seams.sleepCount, 30, "poll count bounded by grace/pollInterval")
    }

    func testIdentityChangeDuringGracePreventsKillEscalation() {
        let url = URL(fileURLWithPath: "/injected/helper.lock")
        var validatedPIDs: [pid_t?] = [4242, 7777]
        var termCalls: [pid_t] = []
        var killCalls: [pid_t] = []
        var sleepCount = 0

        PosixSpawnHelperLauncher.escalateStop(
            pid: 4242,
            graceSeconds: 1,
            pollInterval: 1,
            isAlive: { expected in
                PosixSpawnHelperLauncher.isExpectedInstance(
                    pid: expected,
                    pidfileURL: url,
                    runningPID: { _ in validatedPIDs.removeFirst() })
            },
            term: { termCalls.append($0) },
            kill9: { killCalls.append($0) },
            sleep: { _ in sleepCount += 1 })

        XCTAssertEqual(termCalls, [4242])
        XCTAssertEqual(sleepCount, 1)
        XCTAssertTrue(killCalls.isEmpty, "changed identity must cancel escalation")
    }

    /// Already dead before we ever poll: SIGTERM is harmless, no SIGKILL,
    /// no sleeping.
    func testAlreadyDeadNoSignal() {
        let seams = Seams(alive: [false])
        run(seams)
        XCTAssertTrue(seams.termCalls.isEmpty, "identity lost before TERM must not signal")
        XCTAssertTrue(seams.kill9Calls.isEmpty)
        XCTAssertEqual(seams.sleepCount, 0)
    }
}
