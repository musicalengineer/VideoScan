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

    var started: [String] {
        lock.lock(); defer { lock.unlock() }
        return startedPaths
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
    func insert(_ path: String) {
        lock.lock(); paths.insert(path); lock.unlock()
    }
    func contains(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return paths.contains(path)
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

// MARK: - Harness

@MainActor
private final class SweepHarness {
    let service = PreviewSweepService()
    let recorder = ExecRecorder()
    let thermal = ThermalBox()
    let skipBox = SkipBox()
    let failureStore = ThumbnailFailureStore()
    let cacheDir: URL
    let filesDir: URL
    let diskCache: PreviewDiskCache
    private(set) var files: [String] = []

    init(fileCount: Int,
         enabled: Bool,
         workerCount: Int = 1,
         quietSeconds: Double = 0.5,
         cacheCap: Int64 = PreviewDiskCache.sizeCapBytes,
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
        let candidates = files.map {
            PreviewSweepCandidate(path: $0,
                                  container: "QuickTime / MOV",
                                  videoCodec: "h264",
                                  likelyUnanalyzable: false,
                                  durationSeconds: 60)
        }
        let recorder = self.recorder
        let thermal = self.thermal
        let skipBox = self.skipBox
        service.configure(PreviewSweepService.Configuration(
            diskCache: diskCache,
            failureStore: failureStore,
            candidates: { candidates },
            shouldSkipPathNow: { skipBox.contains($0) },
            isReachable: reachable,
            thermalState: { thermal.current },
            executeItem: { item in
                recorder.noteStart(item.candidate.path)
                while !recorder.canFinish(item.candidate.path) {
                    try await Task.sleep(for: .milliseconds(10))
                }
                return recorder.outcome(forPath: item.candidate.path)
            },
            workerCount: workerCount,
            quietSeconds: quietSeconds,
            pausePollMilliseconds: 20,
            replanDebounceSeconds: 0.05,
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
        #expect(await h.waitFor { $0 == .done(ready: 3, unpreviewable: 0) })
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
        #expect(await h.waitFor { $0 == .done(ready: 1, unpreviewable: 1) })
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
        #expect(await h.waitFor { $0 == .done(ready: 1, unpreviewable: 1) })
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
}
