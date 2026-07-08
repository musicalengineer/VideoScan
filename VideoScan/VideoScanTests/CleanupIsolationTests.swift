// CleanupIsolationTests.swift
// ISOLATION dimension for Clean Up Video (feature-test checklist item 4):
// the cleanup path reads global state (UserDefaults-backed perfSettings
// for the RAM-disk budget, the shared RAM disk, the filesystem), so it
// gets poisoned-state coverage:
//
//   1. A full CleanupJob run must leave the user's REAL state untouched:
//      no writes to ~/Library/Application Support/VideoScan, no new/
//      changed perf_*/cleanup UserDefaults keys, and every file the job
//      creates confined to temp (the settings-pollution class — see
//      MetadataCacheIsolationTests / TestIsolationTests for the pattern).
//   2. The RAM-disk budget gate: a 2 h SD source's output estimate
//      EXCEEDS a 16 GB RAM-disk budget (pinned numerically), and
//      behaviorally the job's scratch falls back to the system temp dir —
//      no RAM disk is ever mounted by a test.
//   3. A CleanupJob whose model has been deallocated (the job holds it
//      weak) still completes cleanly: renders to temp scratch, publishes
//      the output, and simply skips catalog registration.

import Testing
import Foundation
@testable import VideoScan

@Suite(.serialized) @MainActor
struct CleanupIsolationTests {

    // MARK: Real-state snapshot helpers

    private var realAppSupportVideoScan: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask)
            .first?.appendingPathComponent("VideoScan", isDirectory: true)
    }

    /// path → "size@mtime" for everything under the real VideoScan
    /// Application Support tree (empty when absent — also a valid state).
    private func appSupportSnapshot() -> [String: String] {
        guard let root = realAppSupportVideoScan,
              let e = FileManager.default.enumerator(atPath: root.path) else { return [:] }
        var snap: [String: String] = [:]
        for case let rel as String in e {
            let full = root.appendingPathComponent(rel).path
            let attrs = (try? FileManager.default.attributesOfItem(atPath: full)) ?? [:]
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            snap[rel] = "\(size)@\(mtime)"
        }
        return snap
    }

    /// The UserDefaults keys the cleanup path could plausibly touch.
    private func defaultsSnapshot() -> [String: String] {
        UserDefaults.standard.dictionaryRepresentation()
            .filter { $0.key.hasPrefix("perf_") || $0.key.lowercased().contains("cleanup") }
            .mapValues { String(describing: $0) }
    }

    // MARK: - 1. Poisoned-state: no real-state reads/writes with teeth

    @Test("a full cleanup job leaves real Application Support and UserDefaults untouched")
    func cleanupJobLeavesRealUserStateUntouched() async throws {
        let dir = try CleanupTestMedia.makeScratchDir("isolation")
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = try TestMediaGenerator.generate(
            container: "mp4", streams: .videoAndAudio, duration: 2.0,
            prefix: "test_cleanup_iso")
        let ownedSrc = dir.appendingPathComponent("test_iso_src.mp4").path
        try FileManager.default.moveItem(atPath: src, toPath: ownedSrc)

        let defaultsBefore = defaultsSnapshot()
        let appSupportBefore = appSupportSnapshot()

        let model = VideoScanModel()
        let source = makeCleanupSourceRecord(path: ownedSrc,
                                             durationSeconds: 0,
                                             fieldOrder: "tt")
        model.records = [source]

        let job = CleanupJob(record: source,
                             recipe: CleanupRecipeRegistry.vhsQuickClean,
                             model: model,
                             engine: StubCleanupEngine())
        job.start()
        await job.task?.value

        guard case .finished = job.state else {
            Issue.record("job did not finish: \(job.state)")
            return
        }
        // Everything the job created is confined to the test-owned dir
        // (output beside the original) — nowhere near real catalog paths.
        #expect(job.outputURL.path.hasPrefix(dir.path),
                "Output escaped the test sandbox: \(job.outputURL.path)")
        #expect(FileManager.default.fileExists(atPath: job.outputURL.path))

        #expect(defaultsSnapshot() == defaultsBefore,
                "Cleanup wrote perf_*/cleanup keys to the REAL UserDefaults — settings-pollution class")
        #expect(appSupportSnapshot() == appSupportBefore,
                "Cleanup touched the real ~/Library/Application Support/VideoScan tree")
    }

    // MARK: - 2a. RAM budget pin: 2 h SD exceeds 16 GB

    @Test("a 2h SD source's output estimate exceeds a 16 GB RAM-disk budget")
    func twoHourSDEstimateExceeds16GBBudget() {
        let estimate = CleanupJob.estimatedOutputBytes(durationSeconds: 7200,
                                                       resolution: "720x480")
        let sixteenGiB: Int64 = 16 * 1_073_741_824
        // The job's gate is 60% of the configured disk — the estimate must
        // clear BOTH the budget and the gate so a 2 h tape can never land
        // on a default-sized RAM disk.
        #expect(estimate > sixteenGiB,
                "2h SD estimate (\(estimate) B) must exceed 16 GiB (\(sixteenGiB) B)")
        #expect(estimate > (sixteenGiB * 6) / 10,
                "2h SD estimate must exceed the 60% RAM-disk admission gate")
    }

    // MARK: - 2b. Scratch behaviorally falls back to system temp

    @Test("over-budget estimates render in system temp and never mount the RAM disk")
    func scratchFallsBackToTempWhenBudgetExceeded() async throws {
        let dir = try CleanupTestMedia.makeScratchDir("isolation_temp")
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = try TestMediaGenerator.generate(
            container: "mp4", streams: .videoAndAudio, duration: 2.0,
            prefix: "test_cleanup_tempfb")
        let ownedSrc = dir.appendingPathComponent("test_tempfb_src.mp4").path
        try FileManager.default.moveItem(atPath: src, toPath: ownedSrc)

        let model = VideoScanModel()
        // A duration whose estimate (~4.7 MB/s × 100,000 s ≈ 470 GB)
        // exceeds ANY configurable RAM-disk budget — deterministic on
        // every machine regardless of the user's perf_ramDiskGB value
        // (which the model restores from real defaults; tests must not
        // write it back — mutating model.perfSettings would).
        let source = makeCleanupSourceRecord(path: ownedSrc,
                                             durationSeconds: 100_000,
                                             fieldOrder: "tt")
        model.records = [source]

        let scratchSeen = CleanupObservationBox<String?>(nil)
        var stub = StubCleanupEngine()
        stub.onRender = { scratchDir, _ in
            scratchSeen.mutate { $0 = scratchDir.path }
        }

        let job = CleanupJob(record: source,
                             recipe: CleanupRecipeRegistry.vhsQuickClean,
                             model: model,
                             engine: stub)
        job.start()
        await job.task?.value

        guard case .finished = job.state else {
            Issue.record("job did not finish: \(job.state)")
            return
        }
        let scratchPath = try #require(scratchSeen.value, "engine never rendered")
        let tempRoot = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath().path
        let resolvedScratch = URL(fileURLWithPath: scratchPath)
            .resolvingSymlinksInPath().path
        #expect(resolvedScratch.hasPrefix(tempRoot),
                "Over-budget scratch must be under system temp; got \(scratchPath)")
        #expect(!scratchPath.contains("/Volumes/"),
                "Over-budget scratch must not sit on a mounted volume (RAM disk)")
        let mountPoint = await model.ramDisk.mountPoint
        #expect(mountPoint == nil,
                "The job mounted a RAM disk despite the estimate exceeding the budget")
        // The job must clean its scratch directory up afterwards.
        #expect(!FileManager.default.fileExists(atPath: scratchPath),
                "Scratch directory leaked: \(scratchPath)")
    }

    // MARK: - 3. Weak model: job outlives a deallocated model

    @Test("a job whose model deallocated mid-flight still completes cleanly")
    func jobWithDeallocatedModelCompletesCleanly() async throws {
        let dir = try CleanupTestMedia.makeScratchDir("isolation_weak")
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = try TestMediaGenerator.generate(
            container: "mp4", streams: .videoAndAudio, duration: 2.0,
            prefix: "test_cleanup_weak")
        let ownedSrc = dir.appendingPathComponent("test_weak_src.mp4").path
        try FileManager.default.moveItem(atPath: src, toPath: ownedSrc)

        let source = makeCleanupSourceRecord(path: ownedSrc,
                                             durationSeconds: 0,
                                             fieldOrder: "tt")

        weak var weakModel: VideoScanModel?
        // Scope the strong reference so it dies at the closure's return —
        // afterwards only the job's weak reference remains. (≈ a C++
        // block-scoped shared_ptr feeding the job a weak_ptr.)
        let job: CleanupJob = {
            let model = VideoScanModel()
            weakModel = model
            return CleanupJob(record: source,
                              recipe: CleanupRecipeRegistry.vhsQuickClean,
                              model: model,
                              engine: StubCleanupEngine())
        }()
        // VideoScanModel.init schedules short-lived @MainActor tasks
        // (search-index load, reachability warmup) that hold self for a
        // beat — give them a bounded window to drain, then REQUIRE the
        // dealloc. If the model never releases, that's a real leak and
        // this test must fail (the nil-model path would be untestable
        // and, worse, unreachable in production teardown too).
        for _ in 0..<100 where weakModel != nil {   // ≤ 5 s
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try #require(weakModel == nil,
                     "VideoScanModel still retained 5 s after release — nil-model path not exercisable (leak?)")

        job.start()
        await job.task?.value

        guard case .finished = job.state else {
            Issue.record("nil-model job must still finish; got \(job.state)")
            return
        }
        // Output published beside the original even with no model (the
        // job only loses catalog registration).
        #expect(FileManager.default.fileExists(atPath: job.outputURL.path))
        #expect(job.outputURL.deletingLastPathComponent().path == dir.path)
    }
}
