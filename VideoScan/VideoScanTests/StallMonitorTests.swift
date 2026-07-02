import Testing
import Foundation
@testable import VideoScan

// MARK: - StallMonitorTests
//
// Proving tests for the MFO progress-based stall watchdog (punch-list #6,
// Rick 2026-06-30). The safety-critical core is the PURE decision logic:
//   - ticks within the threshold keep the op alive,
//   - silence past the threshold trips exactly one kill,
//   - the kill latches (a late tick can't un-stall a killed op).
//
// These run on an explicit injected clock (literal timestamps) — NO real
// multi-minute delays. One fast live-loop test (sub-second, tiny threshold)
// proves the production poll loop actually invokes onStall.
//
// Companion: this is what would have killed the 14 h `framemd5` hang on
// /Volumes/LaCieWorkspace in ~5 min instead of blocking app quit overnight.

struct StallMonitorTests {

    private func makeMonitor(threshold: Double) -> StallMonitor {
        // onStall unused in pure-decision tests; the live-loop test uses its
        // own instance with a real handler.
        StallMonitor(label: "test", thresholdSeconds: threshold) { _ in }
    }

    // MARK: Pure decision: ticks keep it alive

    @Test func ticksWithinThresholdKeepAlive() {
        let m = makeMonitor(threshold: 300)   // 5 min
        // Born at t=0 (clock() default in tests is monotonic, but we drive
        // the decision with explicit timestamps so init time is irrelevant
        // once we recordTick).
        m.recordTick(at: 0)
        #expect(!m.evaluateStall(at: 100))    // 100s of silence < 300
        m.recordTick(at: 100)                 // progress resets the timer
        #expect(!m.evaluateStall(at: 350))    // only 250s since last tick
        m.recordTick(at: 350)
        #expect(!m.evaluateStall(at: 600))    // 250s since last tick
    }

    // MARK: Pure decision: silence past threshold trips kill

    @Test func silencePastThresholdTripsKill() {
        let m = makeMonitor(threshold: 300)
        m.recordTick(at: 0)
        #expect(!m.evaluateStall(at: 299))    // just under
        #expect(m.evaluateStall(at: 300))     // exactly at threshold fires
    }

    @Test func silenceWellPastThresholdFires() {
        let m = makeMonitor(threshold: 300)
        m.recordTick(at: 1000)
        // The 14h incident shape: huge gap with no progress.
        #expect(m.evaluateStall(at: 1000 + 14 * 3600))
    }

    // MARK: Latching — a late tick can't revive a killed op

    @Test func killLatchesAndIgnoresLateTick() {
        let m = makeMonitor(threshold: 300)
        m.recordTick(at: 0)
        #expect(m.evaluateStall(at: 400))     // fired
        m.recordTick(at: 401)                 // late tick — must be ignored
        #expect(m.evaluateStall(at: 401))     // still stalled (latched)
        #expect(m.evaluateStall(at: 0))       // even an earlier time stays fired
    }

    @Test func evaluateStallIsIdempotentlyTrueOnceFired() {
        let m = makeMonitor(threshold: 60)
        m.recordTick(at: 0)
        #expect(m.evaluateStall(at: 60))
        // Repeated evaluation never flips back to false.
        for t in stride(from: 60.0, to: 70.0, by: 1.0) {
            #expect(m.evaluateStall(at: t))
        }
    }

    // MARK: Threshold clamping (bounded-time guarantee)

    @Test func thresholdClampedToCeiling() {
        // Ask for an hour; the 10-min ceiling must clamp it so the op can't
        // hang longer than the bound regardless of caller intent.
        let m = StallMonitor(label: "test", thresholdSeconds: 3600) { _ in }
        m.recordTick(at: 0)
        #expect(!m.evaluateStall(at: StallMonitor.maxStallThresholdSeconds - 1))
        #expect(m.evaluateStall(at: StallMonitor.maxStallThresholdSeconds))
    }

    @Test func thresholdClampedToFloor() {
        // A 0 (or negative) threshold would fire instantly and kill healthy
        // ops; it must clamp up to the 1s floor.
        let m = StallMonitor(label: "test", thresholdSeconds: 0) { _ in }
        m.recordTick(at: 0)
        #expect(!m.evaluateStall(at: 0.5))    // under the 1s floor
        #expect(m.evaluateStall(at: 1.0))
    }

    @Test func defaultThresholdIsFiveMinutes() {
        #expect(StallMonitor.defaultStallThresholdSeconds == 300)
        #expect(StallMonitor.maxStallThresholdSeconds == 600)
    }

    // MARK: Live poll loop actually fires onStall (fast — sub-second)

    @Test func liveLoopFiresOnStall() async {
        // Injected clock that jumps far past the (tiny) threshold so the
        // poll loop sees a stall on its first wake — no real waiting.
        final class Clock: @unchecked Sendable {
            private let lock = NSLock()
            private var t: Double = 0
            func set(_ v: Double) { lock.lock(); t = v; lock.unlock() }
            func now() -> Double { lock.lock(); defer { lock.unlock() }; return t }
        }
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var fired = false
            private var silent: Double = 0
            func fire(_ s: Double) { lock.lock(); fired = true; silent = s; lock.unlock() }
            var didFire: Bool { lock.lock(); defer { lock.unlock() }; return fired }
            var silentFor: Double { lock.lock(); defer { lock.unlock() }; return silent }
        }
        let clock = Clock()
        let flag = Flag()
        let m = StallMonitor(label: "live-test",
                             thresholdSeconds: 1,
                             pollIntervalSeconds: 0.02,
                             clock: { clock.now() },
                             onStall: { flag.fire($0) })
        clock.set(0)
        m.start()
        clock.set(1000)   // simulate 1000s of silence
        // Poll cadence is 20ms; give it a handful of cycles. Bounded, fast.
        for _ in 0..<50 where !flag.didFire {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        m.stop()
        #expect(flag.didFire)
        #expect(flag.silentFor >= 1000)
    }

    @Test func liveLoopDoesNotFireWhileTicking() async {
        final class Clock: @unchecked Sendable {
            private let lock = NSLock()
            private var t: Double = 0
            func advance(_ d: Double) { lock.lock(); t += d; lock.unlock() }
            func now() -> Double { lock.lock(); defer { lock.unlock() }; return t }
        }
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var fired = false
            func fire() { lock.lock(); fired = true; lock.unlock() }
            var didFire: Bool { lock.lock(); defer { lock.unlock() }; return fired }
        }
        let clock = Clock()
        let flag = Flag()
        // Threshold 1s, but we tick every ~advance well under it.
        let m = StallMonitor(label: "live-alive",
                             thresholdSeconds: 1,
                             pollIntervalSeconds: 0.02,
                             clock: { clock.now() },
                             onStall: { _ in flag.fire() })
        m.start()
        // Advance time in 0.1s steps, ticking each step — never 1s silent.
        for _ in 0..<10 {
            clock.advance(0.1)
            m.tick()
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        m.stop()
        #expect(!flag.didFire)
    }

    // MARK: start() atomicity — one loop, one token, no leak (harden-jul01)
    //
    // Regression for the latent start() race: the running-check was under
    // the lock but the token acquisition and pollTask assignment were NOT,
    // so concurrent start() calls could each spawn a poll loop and the
    // second's ProcessInfo activity token overwrote (leaked) the first.
    // Latent today (all call sites are single-actor) but a landmine for any
    // future multi-context caller. The lifecycle counters make the race
    // deterministic to observe: loopsSpawned > 1 after a concurrent hammer
    // is the RED.

    @Test func concurrentStartsSpawnExactlyOneLoopAndOneToken() {
        // DispatchQueue.concurrentPerform launches genuinely parallel
        // threads with tight simultaneity (a TaskGroup staggers too much to
        // land in the µs-wide race window). 50 rounds × 16 threads makes the
        // unfixed race reproduce reliably; a correct monitor spawns exactly
        // one loop and one token in EVERY round. Constant clock at 0 with
        // threshold 60 → the loop never stalls during the test.
        for round in 0..<50 {
            let m = StallMonitor(label: "race-test",
                                 thresholdSeconds: 60,
                                 pollIntervalSeconds: 0.02,
                                 clock: { 0 },
                                 onStall: { _ in })
            DispatchQueue.concurrentPerform(iterations: 16) { _ in m.start() }

            let running = m.lifecycleCountersForTesting
            #expect(running.loopsSpawned == 1,
                    "round \(round): \(running.loopsSpawned) poll loops spawned")
            #expect(running.tokensBegun == 1,
                    "round \(round): \(running.tokensBegun) activity tokens begun")
            #expect(m.isRunningForTesting)

            m.stop()
            let final = m.lifecycleCountersForTesting
            #expect(final.tokensEnded == final.tokensBegun,
                    "round \(round): begun \(final.tokensBegun) ended \(final.tokensEnded) — token leak")
            #expect(!m.isRunningForTesting)              // loop handle gone
        }
    }

    @Test func repeatedSequentialStartIsNoOp() {
        let m = StallMonitor(label: "idempotent-test",
                             thresholdSeconds: 60,
                             pollIntervalSeconds: 0.02,
                             clock: { 0 },
                             onStall: { _ in })
        m.start()
        m.start()   // must be a no-op while running
        m.start()
        let c = m.lifecycleCountersForTesting
        #expect(c.loopsSpawned == 1)
        #expect(c.tokensBegun == 1)
        m.stop()
        #expect(m.lifecycleCountersForTesting.tokensEnded == 1)
    }

    @Test func restartAfterStopSpawnsFreshLoopAndToken() {
        // stop() must fully reset so a later start() works — pins that the
        // fix didn't turn "idempotent while running" into "once, ever".
        let m = StallMonitor(label: "restart-test",
                             thresholdSeconds: 60,
                             pollIntervalSeconds: 0.02,
                             clock: { 0 },
                             onStall: { _ in })
        m.start()
        m.stop()
        m.start()
        let c = m.lifecycleCountersForTesting
        #expect(c.loopsSpawned == 2)
        #expect(c.tokensBegun == 2)
        #expect(c.tokensEnded == 1)
        #expect(m.isRunningForTesting)
        m.stop()
        #expect(m.lifecycleCountersForTesting.tokensEnded == 2)
        #expect(!m.isRunningForTesting)
    }
}

// MARK: - Attribution (#6.4) + atomic output helpers (#6.3)

struct StallAttributionTests {

    @Test func internalPathReportsFileError() {
        // A /Users path has no /Volumes root → can't be a volume drop;
        // attribution must say file/device error, not "unreachable".
        let s = StallMonitor.attribution(forPaths: ["/Users/rickb/Movies/a.mov"])
        #expect(s.contains("file/device"))
        #expect(!s.lowercased().contains("unreachable"))
    }

    @Test func unmountedVolumeReportsUnreachable() {
        // A volume name that cannot be mounted on a test host → unreachable.
        let bogus = "/Volumes/VS_NoSuchVolume_ZZZ_\(UUID().uuidString)/clip.mxf"
        let s = StallMonitor.attribution(forPaths: [bogus])
        #expect(s.contains("UNREACHABLE"))
        #expect(s.contains("VS_NoSuchVolume_ZZZ"))
    }

    @Test func emptyPathsTreatedAsFileError() {
        let s = StallMonitor.attribution(forPaths: [])
        #expect(s.contains("file/device"))
    }
}

struct ReformatAtomicOutputTests {

    @Test func partialURLPreservesExtensionAndIsSibling() {
        let out = URL(fileURLWithPath: "/tmp/dir/clip.vs.hevc.20260630-101010.mp4")
        let partial = ReformatJob.partialURL(for: out)
        // Same directory (atomic rename requires same filesystem).
        #expect(partial.deletingLastPathComponent() == out.deletingLastPathComponent())
        // Final extension preserved so ffmpeg still infers the muxer.
        #expect(partial.pathExtension == "mp4")
        // Carries the partial marker, and is NOT the final name.
        #expect(partial.lastPathComponent.contains("vs-partial"))
        #expect(partial.path != out.path)
    }

    @Test func partialURLForMkv() {
        let out = URL(fileURLWithPath: "/tmp/clip.vs.preserve.mkv")
        let partial = ReformatJob.partialURL(for: out)
        #expect(partial.pathExtension == "mkv")
        #expect(partial.lastPathComponent.contains("vs-partial"))
    }

    @Test func atomicPublishMovesPartialToFinal() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vs-atomic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let finalURL = dir.appendingPathComponent("out.mp4")
        let partialURL = ReformatJob.partialURL(for: finalURL)
        try "complete-encode".write(to: partialURL, atomically: true, encoding: .utf8)

        try ReformatJob.atomicPublish(from: partialURL.path, to: finalURL.path)

        #expect(FileManager.default.fileExists(atPath: finalURL.path))
        #expect(!FileManager.default.fileExists(atPath: partialURL.path))
        #expect(try String(contentsOf: finalURL, encoding: .utf8) == "complete-encode")
    }

    @Test func atomicPublishReplacesExistingFinal() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vs-atomic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let finalURL = dir.appendingPathComponent("out.mp4")
        let partialURL = ReformatJob.partialURL(for: finalURL)
        try "stale".write(to: finalURL, atomically: true, encoding: .utf8)
        try "fresh".write(to: partialURL, atomically: true, encoding: .utf8)

        try ReformatJob.atomicPublish(from: partialURL.path, to: finalURL.path)
        #expect(try String(contentsOf: finalURL, encoding: .utf8) == "fresh")
    }
}
