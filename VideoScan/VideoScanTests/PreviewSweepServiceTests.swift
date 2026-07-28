// PreviewSweepServiceTests.swift
// ISOLATION + SENSOR dimensions for the background preview sweep
// (2026-07-27). Everything injected: temp cache roots, unique temp
// candidate files, scripted executor, injected reachability (codex's
// isReachable seam — these tests must never touch the VolumeReachability
// SWR cache, the cross-test poison trap hit 2026-07-26), injected
// thermal state.
//
// The pinned sensors:
//   - OFF by default / sweep NEVER starts while disabled.
//   - Interactive preemption: an interaction during a run pauses
//     dispatch — no new item starts until the quiet window elapses.
//   - Cache-cap stop: writes reaching the cap end the run with the
//     honest "cache full" status instead of thrash-looping.
//   - Thermal park; failure-store rules (genuine recorded, unreachable
//     never); known failures excluded at plan time.

import Testing
import Foundation
@testable import VideoScan

// MARK: - Scripted executor / thermal box (tiny lock-boxes)

private final class ExecRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var startedPaths: [String] = []
    private var releaseAll = true
    private var releasedPaths = Set<String>()
    private var outcomes: [String: PreviewSweepItemOutcome] = [:]
    private var defaultOutcome = PreviewSweepItemOutcome(stillReady: true)
    // Live/high-water executor concurrency — a SECOND overlapping sweep
    // (the churn hazard) would push this above workerCount even though
    // each individual sweep respects its own bound. (For Rick: like a
    // std::atomic<int> in-flight counter with a recorded max.)
    private var liveConcurrency = 0
    private var maxConcurrencySeen = 0

    var started: [String] {
        lock.lock(); defer { lock.unlock() }
        return startedPaths
    }

    var maxConcurrency: Int {
        lock.lock(); defer { lock.unlock() }
        return maxConcurrencySeen
    }

    /// Bracket one executor invocation for the concurrency high-water mark.
    func enter() {
        lock.lock()
        liveConcurrency += 1
        maxConcurrencySeen = max(maxConcurrencySeen, liveConcurrency)
        lock.unlock()
    }

    func leave() {
        lock.lock(); liveConcurrency -= 1; lock.unlock()
    }

    func noteStart(_ path: String) {
        lock.lock(); startedPaths.append(path); lock.unlock()
    }

    func holdAll() {
        lock.lock(); releaseAll = false; lock.unlock()
    }

    func release(_ path: String) {
        lock.lock(); releasedPaths.insert(path); lock.unlock()
    }

    func releaseEverything() {
        lock.lock(); releaseAll = true; lock.unlock()
    }

    func canFinish(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return releaseAll || releasedPaths.contains(path)
    }

    func setOutcome(_ outcome: PreviewSweepItemOutcome, forPath path: String) {
        lock.lock(); outcomes[path] = outcome; lock.unlock()
    }

    func outcome(forPath path: String) -> PreviewSweepItemOutcome {
        lock.lock(); defer { lock.unlock() }
        return outcomes[path] ?? defaultOutcome
    }
}

/// Mutable skip-set box so tests can mark a path "interactively owned"
/// AFTER the harness (and its UUID-named files) exist.
private final class SkipBox: @unchecked Sendable {
    private let lock = NSLock()
    private var paths = Set<String>()
    var skipAll = false
    func insert(_ path: String) {
        lock.lock(); paths.insert(path); lock.unlock()
    }
    func contains(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return skipAll || paths.contains(path)
    }
}

/// Mutable candidate-set box so churn tests can swap the "catalog" the
/// plan snapshot reads BETWEEN replans — the debounce must coalesce onto
/// the LAST value, never a stale one.
private final class CandidateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [PreviewSweepCandidate] = []
    func set(_ v: [PreviewSweepCandidate]) {
        lock.lock(); value = v; lock.unlock()
    }
    func get() -> [PreviewSweepCandidate] {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

private final class ThermalBox: @unchecked Sendable {
    private let lock = NSLock()
    private var state: ProcessInfo.ThermalState = .nominal
    var current: ProcessInfo.ThermalState {
        lock.lock(); defer { lock.unlock() }
        return state
    }
    func set(_ new: ProcessInfo.ThermalState) {
        lock.lock(); state = new; lock.unlock()
    }
}

/// Mutable "external work is running" flag (stands in for the volume-
/// click precacher's isRunning). Drives the MAJOR-1 deferral test.
private final class BusyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    var isBusy: Bool {
        lock.lock(); defer { lock.unlock() }
        return busy
    }
    func set(_ new: Bool) {
        lock.lock(); busy = new; lock.unlock()
    }
}

// MARK: - Harness

@MainActor
private final class SweepHarness {
    let service = PreviewSweepService()
    let recorder = ExecRecorder()
    let thermal = ThermalBox()
    let skipBox = SkipBox()
    let candidateBox = CandidateBox()
    let busyBox = BusyBox()
    let failureStore = ThumbnailFailureStore()
    let cacheDir: URL
    let filesDir: URL
    let diskCache: PreviewDiskCache
    private(set) var files: [String] = []

    /// Build a value candidate for one of the harness's real temp files.
    func candidate(_ index: Int) -> PreviewSweepCandidate {
        PreviewSweepCandidate(path: files[index],
                              container: "QuickTime / MOV",
                              videoCodec: "h264",
                              likelyUnanalyzable: false,
                              durationSeconds: 60)
    }

    init(fileCount: Int,
         enabled: Bool,
         workerCount: Int = 1,
         quietSeconds: Double = 0.5,
         cacheCap: Int64 = PreviewDiskCache.sizeCapBytes,
         replanDebounce: Double = 0.05,
         reachable: @escaping @Sendable (String) -> Bool = { _ in true }) throws {
        let base = FileManager.default.temporaryDirectory
        cacheDir = base.appendingPathComponent("sweep-cache-\(UUID().uuidString)", isDirectory: true)
        filesDir = base.appendingPathComponent("sweep-media-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
        diskCache = PreviewDiskCache(rootURL: cacheDir)

        // Real (junk-content) files so the plan's stat/keying pass works;
        // the scripted executor never decodes them. Unique paths per
        // harness — no shared global state anywhere.
        for i in 0..<fileCount {
            let path = filesDir.appendingPathComponent("clip\(i).mp4").path
            try Data("junk-\(i)".utf8).write(to: URL(fileURLWithPath: path))
            files.append(path)
        }
        // Default catalog = every generated file; churn tests overwrite
        // this via candidateBox.set before their replan bursts.
        candidateBox.set(files.map {
            PreviewSweepCandidate(path: $0,
                                  container: "QuickTime / MOV",
                                  videoCodec: "h264",
                                  likelyUnanalyzable: false,
                                  durationSeconds: 60)
        })
        let recorder = self.recorder
        let thermal = self.thermal
        let skipBox = self.skipBox
        let candidateBox = self.candidateBox
        let busyBox = self.busyBox
        service.configure(PreviewSweepService.Configuration(
            diskCache: diskCache,
            failureStore: failureStore,
            candidates: { candidateBox.get() },
            shouldSkipPathNow: { skipBox.contains($0) },
            isExternallyBusy: { busyBox.isBusy },
            isReachable: reachable,
            thermalState: { thermal.current },
            executeItem: { item in
                recorder.noteStart(item.candidate.path)
                recorder.enter()
                defer { recorder.leave() }
                while !recorder.canFinish(item.candidate.path) {
                    try await Task.sleep(for: .milliseconds(10))
                }
                return recorder.outcome(forPath: item.candidate.path)
            },
            workerCount: workerCount,
            quietSeconds: quietSeconds,
            pausePollMilliseconds: 20,
            replanDebounceSeconds: replanDebounce,
            cacheCapBytes: cacheCap
        ), enabled: enabled)
    }

    func cleanup() {
        service.stop()
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.removeItem(at: filesDir)
    }

    /// Poll the service status until `predicate` or timeout.
    func waitFor(timeout: TimeInterval = 10,
                 _ predicate: (PreviewSweepStatus) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(service.status) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate(service.status)
    }

    /// Poll until the recorder saw `count` starts (or timeout).
    func waitForStarts(_ count: Int, timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if recorder.started.count >= count { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return recorder.started.count >= count
    }
}

// MARK: - Tests

@MainActor
@Suite(.timeLimit(.minutes(3)))
struct PreviewSweepServiceTests {

    // MARK: Disabled-by-default sensors

    @Test("SENSOR: sweep never starts while disabled — catalog signals are ignored")
    func neverStartsWhenDisabled() async throws {
        let h = try SweepHarness(fileCount: 2, enabled: false)
        defer { h.cleanup() }

        h.service.noteCatalogChanged()
        // Well past the 50 ms replan debounce.
        try await Task.sleep(for: .milliseconds(400))

        #expect(h.recorder.started.isEmpty, "executor ran while the checkbox was OFF")
        #expect(h.service.status == .idle)
        #expect(!h.service.isSweeping)
        // And the cache stayed untouched.
        let cacheContents = try FileManager.default.contentsOfDirectory(atPath: h.cacheDir.path)
        #expect(cacheContents.isEmpty)
    }

    @Test("checkbox gating: setEnabled(true) starts, setEnabled(false) stops to idle")
    func enableStartsDisableStops() async throws {
        let h = try SweepHarness(fileCount: 2, enabled: false)
        defer { h.cleanup() }

        h.service.setEnabled(true)
        #expect(await h.waitFor { if case .done = $0 { return true }; return false })
        #expect(h.recorder.started.count == 2)

        h.service.setEnabled(false)
        #expect(h.service.status == .idle)
        #expect(!h.service.isSweeping)
    }

    // MARK: Happy path

    @Test("a full run lands .done with honest counts")
    func runsToDone() async throws {
        let h = try SweepHarness(fileCount: 3, enabled: true, workerCount: 2)
        defer { h.cleanup() }

        h.service.noteCatalogChanged()
        #expect(await h.waitFor { $0 == .done(ready: 3, unpreviewable: 0, deferred: 0) })
        #expect(Set(h.recorder.started) == Set(h.files))
        #expect(!h.service.isSweeping, "task handle must clear after a natural finish")
    }

    // MARK: Interactive preemption sensor

    @Test("SENSOR: an interactive request during the sweep pauses dispatch until the quiet window elapses")
    func interactivePreemption() async throws {
        // Generous quiet window (1.5 s) so a loaded host can observe the
        // paused state well before it can expire — flake guard.
        let h = try SweepHarness(fileCount: 2, enabled: true,
                                 workerCount: 1, quietSeconds: 1.5)
        defer { h.cleanup() }
        h.recorder.holdAll()

        h.service.noteCatalogChanged()
        #expect(await h.waitForStarts(1), "first item never started")

        // User browses while item 1 is mid-rip.
        h.service.noteUserInteraction()
        h.recorder.release(h.files[0])

        // The sweep must go to paused — and hold item 2 back.
        #expect(await h.waitFor { status in
            if case .pausedForInteraction = status { return true }
            return false
        }, "sweep did not pause for the interactive request")
        try await Task.sleep(for: .milliseconds(300))   // inside the quiet window
        #expect(h.recorder.started.count == 1,
                "item 2 started during the interactive quiet window")

        // Quiet elapses → sweep resumes and finishes.
        h.recorder.releaseEverything()
        #expect(await h.waitFor { if case .done = $0 { return true }; return false })
        #expect(h.recorder.started.count == 2)
    }

    // MARK: Cache-cap sensor

    @Test("SENSOR: writes reaching the cap stop the sweep with the honest cache-full status")
    func cacheCapStops() async throws {
        let h = try SweepHarness(fileCount: 2, enabled: true,
                                 workerCount: 1, cacheCap: 1_000)
        defer { h.cleanup() }
        // Each item claims to have written 2 KB — past the 1 KB cap
        // after the first.
        for path in h.files {
            h.recorder.setOutcome(PreviewSweepItemOutcome(bytesWritten: 2_000,
                                                          stillReady: true),
                                  forPath: path)
        }

        h.service.noteCatalogChanged()
        #expect(await h.waitFor { status in
            if case .cacheFull(let done, let total) = status {
                return done == 1 && total == 2
            }
            return false
        }, "sweep did not stop at the cache cap (status: \(h.service.status))")
        #expect(h.recorder.started.count == 1, "an item was dispatched past the cap")
    }

    @Test("cache already at cap: run reports cache-full without executing anything")
    func cacheAlreadyFull() async throws {
        let h = try SweepHarness(fileCount: 1, enabled: true, cacheCap: 10)
        defer { h.cleanup() }
        // Pre-fill the cache dir past the tiny cap.
        try Data(repeating: 0, count: 64).write(
            to: h.cacheDir.appendingPathComponent("junk.bin"))

        h.service.noteCatalogChanged()
        #expect(await h.waitFor { status in
            if case .cacheFull(let done, _) = status { return done == 0 }
            return false
        })
        #expect(h.recorder.started.isEmpty)
    }

    // MARK: Thermal park

    @Test("thermal .serious parks the sweep before any item; .nominal resumes it")
    func thermalPause() async throws {
        let h = try SweepHarness(fileCount: 1, enabled: true)
        defer { h.cleanup() }
        h.thermal.set(.serious)

        h.service.noteCatalogChanged()
        #expect(await h.waitFor { status in
            if case .pausedForThermal = status { return true }
            return false
        })
        #expect(h.recorder.started.isEmpty, "an item ripped under thermal pressure")

        h.thermal.set(.nominal)
        #expect(await h.waitFor { if case .done = $0 { return true }; return false })
        #expect(h.recorder.started.count == 1)
    }

    // MARK: Failure rules

    @Test("known ThumbnailFailureStore entries are excluded at plan time and counted unpreviewable")
    func knownFailuresExcluded() async throws {
        let h = try SweepHarness(fileCount: 2, enabled: true)
        defer { h.cleanup() }
        h.failureStore.recordFailure(forPath: h.files[0])

        h.service.noteCatalogChanged()
        // Known failure is excluded at PLAN time (never dispatched), so it
        // counts unpreviewable, not deferred.
        #expect(await h.waitFor { $0 == .done(ready: 1, unpreviewable: 1, deferred: 0) })
        #expect(h.recorder.started == [h.files[1]],
                "a known-failure path was re-attempted")
    }

    @Test("genuine still failure is recorded to the failure store; unreachable skip NEVER is")
    func failureStoreRules() async throws {
        let h = try SweepHarness(fileCount: 3, enabled: true)
        defer { h.cleanup() }
        h.recorder.setOutcome(PreviewSweepItemOutcome(stillFailedGenuinely: true),
                              forPath: h.files[0])
        h.recorder.setOutcome(PreviewSweepItemOutcome(skippedUnreachable: true),
                              forPath: h.files[1])

        h.service.noteCatalogChanged()
        // file2 ready; file0 genuine → unpreviewable; file1 unreachable →
        // deferred (no verdict — the next replan / remount covers it).
        #expect(await h.waitFor { $0 == .done(ready: 1, unpreviewable: 1, deferred: 1) })
        // Exactly ONE entry — the genuine failure. The unreachable skip
        // must not poison (the 2026-07-26 cache-poison class).
        #expect(h.failureStore.count == 1)
        #expect(h.failureStore.isKnownFailure(atPath: h.files[0]))
        #expect(!h.failureStore.isKnownFailure(atPath: h.files[1]))
    }

    // MARK: Coexistence

    @Test("paths owned by an interactive rip are skipped, not fought over")
    func interactiveOwnedPathSkipped() async throws {
        let h = try SweepHarness(fileCount: 2, enabled: true)
        defer { h.cleanup() }
        // Mark file 0 as interactively owned (the model's real closure
        // reports the filmstrip task's path / a running precacher).
        h.skipBox.insert(h.files[0])

        h.service.noteCatalogChanged()
        #expect(await h.waitFor { if case .done = $0 { return true }; return false })
        #expect(h.recorder.started == [h.files[1]],
                "the interactively-owned path was ripped by the sweep")
    }

    // MARK: Coexistence — precacher DEFERS (parks), never a terminal skip

    @Test("SENSOR: the precacher-running signal PARKS the sweep (not a terminal skip); when it clears the sweep covers ALL records")
    func precacherBusyParksThenCovers() async throws {
        // QA MAJOR-1 (2026-07-27): "precacher running" is isExternallyBusy
        // — a pacing PAUSE, NOT the per-item shouldSkipPathNow skip. The
        // old behavior consumed the whole plan as skips and reported .done
        // with the catalog uncovered; this pins the corrected contract.
        // (PreviewSweepDeferralTests owns the same property with its own
        // minimal harness; this is the service-harness behavioral twin so
        // the shared harness exercises isExternallyBusy end-to-end.)
        let h = try SweepHarness(fileCount: 4, enabled: true, workerCount: 2)
        defer { h.cleanup() }
        h.busyBox.set(true)   // precacher already running when the sweep starts

        h.service.noteCatalogChanged()
        // While busy the sweep must PARK — reported as a browse-pause,
        // never reaching a terminal .done — and rip NOTHING.
        #expect(await h.waitFor { status in
            if case .pausedForInteraction = status { return true }
            return false
        }, "precacher-busy did not park the sweep (status: \(h.service.status))")
        try await Task.sleep(for: .milliseconds(200))
        #expect(h.recorder.started.isEmpty,
                "the sweep ripped while the precacher owned the caches")
        if case .done = h.service.status {
            Issue.record("sweep terminated (.done) while busy — the removed wholesale-skip bug")
        }

        // Precacher stops → the sweep resumes and covers ALL records,
        // nothing dropped (ready reaches the eligible total, not 0).
        h.busyBox.set(false)
        #expect(await h.waitFor { $0 == .done(ready: 4, unpreviewable: 0, deferred: 0) })
        #expect(Set(h.recorder.started) == Set(h.files),
                "resumed sweep did not cover the full catalog")
    }

    // MARK: Churn — debounce coalesces onto the LAST catalog

    @Test("SENSOR: a burst of catalog replacements coalesces to ONE sweep on the LAST catalog, never overlapping runs")
    func churnCoalescesToLastCatalog() async throws {
        // 6 real files; the catalog grows 2 → 4 → 6 in a synchronous
        // burst (a live-reload scan appending). A longer debounce than
        // the burst guarantees only the final replan survives.
        let h = try SweepHarness(fileCount: 6, enabled: true,
                                 workerCount: 2, replanDebounce: 0.3)
        defer { h.cleanup() }

        // Burst: each mutation supersedes the previous replan before its
        // debounce fires (no awaits between — microseconds << 300 ms).
        h.candidateBox.set((0..<2).map { h.candidate($0) })
        h.service.noteCatalogChanged()
        h.candidateBox.set((0..<4).map { h.candidate($0) })
        h.service.noteCatalogChanged()
        h.candidateBox.set((0..<6).map { h.candidate($0) })
        h.service.noteCatalogChanged()

        // The single surviving sweep must cover the LAST catalog (all 6),
        // never a stale prefix.
        #expect(await h.waitFor { $0 == .done(ready: 6, unpreviewable: 0, deferred: 0) })
        #expect(Set(h.recorder.started) == Set(h.files),
                "coalesced sweep did not land on the final catalog: \(h.recorder.started.count) started")
        // A second, overlapping sweep would drive executor concurrency
        // above the per-run worker bound.
        #expect(h.recorder.maxConcurrency <= 2,
                "two sweeps ran concurrently (max concurrency \(h.recorder.maxConcurrency))")
        #expect(!h.service.isSweeping)
    }

    // MARK: Cache-cap — honest AND non-thrashing on replan

    @Test("SENSOR: a replan after cache-full re-reports cache-full without a write loop")
    func cacheFullReplanDoesNotThrash() async throws {
        // Cache pre-filled past a tiny cap: the plan sees it at cap and
        // reports cacheFull(done: 0) with ZERO executor work.
        let h = try SweepHarness(fileCount: 2, enabled: true, cacheCap: 10)
        defer { h.cleanup() }
        try Data(repeating: 0, count: 64).write(
            to: h.cacheDir.appendingPathComponent("junk.bin"))

        h.service.noteCatalogChanged()
        #expect(await h.waitFor { status in
            if case .cacheFull(let done, _) = status { return done == 0 }
            return false
        })
        #expect(h.recorder.started.isEmpty)

        // The service must NOT self-schedule a retry: give it a full
        // second and confirm it stays parked at cacheFull, no rips.
        try await Task.sleep(for: .milliseconds(600))
        if case .cacheFull = h.service.status {} else {
            Issue.record("status drifted off cacheFull without an external replan: \(h.service.status)")
        }
        #expect(!h.service.isSweeping)
        #expect(h.recorder.started.isEmpty, "the sweep looped writes at the cap")

        // An EXTERNAL replan (a later scan) re-reports cacheFull honestly
        // — still no write loop.
        h.service.noteCatalogChanged()
        #expect(await h.waitFor { status in
            if case .cacheFull(let done, _) = status { return done == 0 }
            return false
        })
        #expect(h.recorder.started.isEmpty,
                "the post-cap replan started ripping instead of re-reporting")
    }

    // MARK: Failure-store discipline — the full poison matrix

    @Test("SENSOR: only genuine still failures poison the store — unreachable, ffmpeg-missing, and strip-only failures NEVER do")
    func failureStoreFullPoisonMatrix() async throws {
        // Same rigor as PreviewCachePoisonSensorTests: the four non-still
        // classes must leave ThumbnailFailureStore untouched.
        let h = try SweepHarness(fileCount: 4, enabled: true, workerCount: 1)
        defer { h.cleanup() }
        // file0: genuine decode failure on a reachable volume → POISON.
        h.recorder.setOutcome(PreviewSweepItemOutcome(stillFailedGenuinely: true),
                              forPath: h.files[0])
        // file1: volume vanished mid-rip → NO verdict.
        h.recorder.setOutcome(PreviewSweepItemOutcome(skippedUnreachable: true),
                              forPath: h.files[1])
        // file2: ffmpeg missing (environment fact, not a file verdict) → NO verdict.
        h.recorder.setOutcome(PreviewSweepItemOutcome(environmentFailure: true),
                              forPath: h.files[2])
        // file3: still landed, only the strip failed → NO verdict (the
        // still is good; strip-only never poisons — filmstrip rule).
        h.recorder.setOutcome(PreviewSweepItemOutcome(stillReady: true, stripFailed: true),
                              forPath: h.files[3])

        h.service.noteCatalogChanged()
        // ready = the one still that landed (file3); unpreviewable = the
        // one genuine failure (file0); deferred = the two no-verdict
        // classes (file1 unreachable + file2 ffmpeg-missing).
        #expect(await h.waitFor { $0 == .done(ready: 1, unpreviewable: 1, deferred: 2) })

        // EXACTLY the genuine failure is remembered — nothing else.
        #expect(h.failureStore.count == 1, "a non-still failure poisoned the store")
        #expect(h.failureStore.isKnownFailure(atPath: h.files[0]))
        #expect(!h.failureStore.isKnownFailure(atPath: h.files[1]), "unreachable skip poisoned")
        #expect(!h.failureStore.isKnownFailure(atPath: h.files[2]), "ffmpeg-missing poisoned")
        #expect(!h.failureStore.isKnownFailure(atPath: h.files[3]), "strip-only failure poisoned")
    }

    // MARK: Settings-pollution guard — a test-host model NEVER sweeps

    @Test("SENSOR: a freshly constructed VideoScanModel is OFF-by-default and never starts a sweep (the ~200-model isolation guard)")
    func testHostModelNeverSweeps() async throws {
        // The ~200 model-constructing tests depend on this: TestEnvironment
        // .isTestHost forces PreviewSweepSettings pristine-OFF, so init's
        // configurePreviewSweep() wires the service but the launch-resume
        // catalog signal is a no-op. A regression here (e.g. reading the
        // real prefs plist) would silently fan a background sweep out
        // across every unit test — the settings-pollution class.
        let model = VideoScanModel()
        #expect(model.previewSweepSettings.enabled == false,
                "test-host model came up with the sweep ENABLED — pref-plist leak")
        #expect(!model.previewSweep.isSweeping)
        #expect(model.previewSweep.status == .idle)

        // Even an explicit catalog signal (what a scan commit fires) must
        // stay inert while disabled. Well past any plausible debounce.
        model.previewSweep.noteCatalogChanged()
        try await Task.sleep(for: .milliseconds(200))
        #expect(!model.previewSweep.isSweeping, "a disabled test-host model started a sweep")
        #expect(model.previewSweep.status == .idle)
    }
}
