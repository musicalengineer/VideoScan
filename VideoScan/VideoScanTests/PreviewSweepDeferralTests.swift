// PreviewSweepDeferralTests.swift
// SENSOR for QA MAJOR-1 (2026-07-27): "the volume-click precacher is
// running" must DEFER the background sweep (park + re-poll), NOT make it
// consume the whole plan as per-item skips and report .done with the
// catalog uncovered.
//
// The bug this pins: the precacher-running signal used to flow through
// the per-item `shouldSkipPathNow` predicate, which — being true for
// EVERY path while the precacher ran — walked the entire plan doing
// done+=1/skip+=1 per item (a ~17k main-actor-hop burst) and terminated
// at .done, leaving those records uncovered until relaunch. The fix
// folds it into the PACING PAUSE (`isExternallyBusy`): while busy the
// sweep parks; when it clears the sweep proceeds and covers ALL records.
//
// Self-contained harness (deliberately NOT sharing PreviewSweepService-
// Tests' scaffolding — that file is a separate concern and this sensor
// stands alone): temp cache root, real junk fixtures, scripted executor,
// injected reachability seam (never touches VolumeReachability's SWR
// cache), and a mutable "busy" flag standing in for the precacher.

import Testing
import Foundation
@testable import VideoScan

private final class BusyFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    var isBusy: Bool {
        lock.lock(); defer { lock.unlock() }
        return busy
    }
    func set(_ new: Bool) { lock.lock(); busy = new; lock.unlock() }
}

private final class StartRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return paths.count
    }
    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return paths.isEmpty
    }
    var startedSet: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(paths)
    }
    func note(_ p: String) { lock.lock(); paths.append(p); lock.unlock() }
}

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct PreviewSweepDeferralTests {

    /// Build a self-contained service over N real temp files + a temp
    /// cache root. Returns everything the test needs to drive + assert.
    private func makeService(fileCount: Int,
                             busy: BusyFlag,
                             recorder: StartRecorder)
        throws -> (service: PreviewSweepService, files: [String], cleanup: () -> Void) {
        let base = FileManager.default.temporaryDirectory
        let cacheDir = base.appendingPathComponent("sweep-defer-\(UUID().uuidString)", isDirectory: true)
        let filesDir = base.appendingPathComponent("sweep-defer-media-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)

        var files: [String] = []
        for i in 0..<fileCount {
            let path = filesDir.appendingPathComponent("clip\(i).mp4").path
            try Data("junk-\(i)".utf8).write(to: URL(fileURLWithPath: path))
            files.append(path)
        }
        let candidates = files.map {
            PreviewSweepCandidate(path: $0, container: "QuickTime / MOV",
                                  videoCodec: "h264", likelyUnanalyzable: false,
                                  durationSeconds: 60)
        }
        let diskCache = PreviewDiskCache(rootURL: cacheDir)
        let service = PreviewSweepService()
        service.configure(PreviewSweepService.Configuration(
            diskCache: diskCache,
            failureStore: ThumbnailFailureStore(),
            candidates: { candidates },
            shouldSkipPathNow: { _ in false },   // no per-path skips in this sensor
            isExternallyBusy: { busy.isBusy },
            isReachable: { _ in true },
            thermalState: { .nominal },
            executeItem: { item in
                recorder.note(item.candidate.path)
                return PreviewSweepItemOutcome(stillReady: true)
            },
            workerCount: 1,
            quietSeconds: 0.1,
            pausePollMilliseconds: 20,
            replanDebounceSeconds: 0.05,
            cacheCapBytes: PreviewDiskCache.sizeCapBytes
        ), enabled: true)
        return (service, files, {
            service.stop()
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: filesDir)
        })
    }

    private func waitFor(_ service: PreviewSweepService,
                         timeout: TimeInterval = 8,
                         _ predicate: (PreviewSweepStatus) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(service.status) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate(service.status)
    }

    @Test("SENSOR (MAJOR-1): while the precacher is running the sweep PARKS — no items dispatched, not a terminal skip")
    func precacherRunningParks() async throws {
        let busy = BusyFlag()
        let recorder = StartRecorder()
        busy.set(true)   // precacher already running when the sweep starts
        let (service, _, cleanup) = try makeService(fileCount: 3, busy: busy, recorder: recorder)
        defer { cleanup() }

        service.noteCatalogChanged()

        // Must reach the paused state and stay there — NOT .done.
        #expect(await waitFor(service) { status in
            if case .pausedForInteraction = status { return true }
            return false
        }, "sweep did not park while the precacher was running (status: \(service.status))")

        // Hold the busy flag and confirm it does NOT drain the plan.
        try await Task.sleep(for: .milliseconds(300))
        #expect(recorder.isEmpty,
                "sweep dispatched \(recorder.count) items while parked — MAJOR-1 regressed to per-item skip")
        if case .done = service.status {
            Issue.record("sweep reported .done while the precacher was running — plan was consumed as skips")
        }
    }

    @Test("SENSOR (MAJOR-1): when the precacher STOPS the sweep resumes and covers ALL records")
    func precacherStopResumesFullCoverage() async throws {
        let busy = BusyFlag()
        let recorder = StartRecorder()
        busy.set(true)
        let (service, files, cleanup) = try makeService(fileCount: 4, busy: busy, recorder: recorder)
        defer { cleanup() }

        service.noteCatalogChanged()
        #expect(await waitFor(service) { status in
            if case .pausedForInteraction = status { return true }
            return false
        })
        #expect(recorder.isEmpty)

        // Precacher finishes → the next pacing poll proceeds.
        busy.set(false)

        #expect(await waitFor(service) { status in
            if case .done(let ready, _, let deferred) = status {
                return ready == 4 && deferred == 0
            }
            return false
        }, "sweep did not resume to full coverage after the precacher stopped (status: \(service.status))")
        // Every record covered — nothing dropped by the earlier park.
        #expect(recorder.startedSet == Set(files),
                "records missed after deferral: \(Set(files).subtracting(recorder.startedSet))")
    }
}
