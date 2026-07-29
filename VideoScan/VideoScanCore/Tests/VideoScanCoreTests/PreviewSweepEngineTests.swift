// PreviewSweepEngineTests.swift
// Drives the extracted PreviewSweepEngine DIRECTLY with all-fake
// dependencies (no app, no VideoScanModel, no real ffmpeg) — proving the
// engine is fully decoupled and composable, the whole point of the Stage-0
// extraction. The exhaustive behavioral sensors (interactive preemption,
// thermal park, poison matrix, churn coalescing) live in the app's
// PreviewSweepServiceTests, which exercise this same engine through the
// thin service adapter; these pin the engine's core contract in isolation.

import XCTest
import CoreGraphics
@testable import VideoScanCore

final class PreviewSweepEngineTests: XCTestCase {

    // MARK: - Fakes

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var statuses: [PreviewSweepStatus] = []
        private(set) var finished = false
        private var started: [String] = []
        func publish(_ s: PreviewSweepStatus) { lock.lock(); statuses.append(s); lock.unlock() }
        func finish() { lock.lock(); finished = true; lock.unlock() }
        func noteStart(_ p: String) { lock.lock(); started.append(p); lock.unlock() }
        var last: PreviewSweepStatus? { lock.lock(); defer { lock.unlock() }; return statuses.last }
        var startedPaths: [String] { lock.lock(); defer { lock.unlock() }; return started }
    }

    private final class FakeCache: PreviewCache, @unchecked Sendable {
        let listing: [(name: String, size: Int64)]
        init(listing: [(name: String, size: Int64)] = []) { self.listing = listing }
        func currentListing() -> [(name: String, size: Int64)] { listing }
        func store(_ image: CGImage, path: String, mtime: TimeInterval, size: Int64,
                   tier: PreviewCacheTier) -> Int64 { 0 }
        func storeFilmstrip(_ frames: [(offsetSeconds: Double, image: CGImage)],
                            path: String, mtime: TimeInterval, size: Int64) -> Int64 { 0 }
    }

    private final class FakeFailureStore: PreviewSweepFailureStore, @unchecked Sendable {
        private let lock = NSLock()
        private var known: Set<String>
        private(set) var recorded: [String] = []
        init(known: Set<String> = []) { self.known = known }
        func isKnownFailure(atPath path: String) -> Bool {
            lock.lock(); defer { lock.unlock() }; return known.contains(path)
        }
        func recordFailure(forPath path: String) {
            lock.lock(); recorded.append(path); lock.unlock()
        }
    }

    private func makeFiles(_ n: Int) -> [String] {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engine-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (0..<n).map { i in
            let p = dir.appendingPathComponent("clip\(i).mp4").path
            try? Data("x\(i)".utf8).write(to: URL(fileURLWithPath: p))
            return p
        }
    }

    private func candidates(_ paths: [String]) -> [PreviewSweepCandidate] {
        paths.map { PreviewSweepCandidate(path: $0, container: "QuickTime / MOV",
                                          videoCodec: "h264", likelyUnanalyzable: false,
                                          durationSeconds: 60) }
    }

    private func engine(paths: [String],
                        cache: FakeCache,
                        failures: FakeFailureStore,
                        collector: Collector,
                        cacheCap: Int64 = .max,
                        executor: @escaping PreviewSweepExecutor) -> PreviewSweepEngine {
        let cand = candidates(paths)
        return PreviewSweepEngine(
            plan: { cand },
            cache: cache,
            failureStore: failures,
            thermalState: { .nominal },
            lastInteraction: { nil },
            isExternallyBusy: { false },
            shouldSkipPathNow: { _ in false },
            executeItem: executor,
            publishOnMain: { collector.publish($0) },
            finishOnMain: { collector.finish() },
            workerCount: 2,
            quietSeconds: 0.5,
            pausePollMilliseconds: 20,
            cacheCapBytes: cacheCap)
    }

    // MARK: - Tests

    func testHappyPathCoversAllRecordsAndReportsDone() async {
        let paths = makeFiles(4)
        let collector = Collector()
        let eng = engine(paths: paths, cache: FakeCache(), failures: FakeFailureStore(),
                         collector: collector) { item in
            collector.noteStart(item.candidate.path)
            return PreviewSweepItemOutcome(stillReady: true)
        }
        await eng.run()
        XCTAssertEqual(collector.last, .done(ready: 4, unpreviewable: 0, deferred: 0))
        XCTAssertEqual(Set(collector.startedPaths), Set(paths))
        XCTAssertTrue(collector.finished)
    }

    func testKnownFailuresExcludedAtPlanTime() async {
        let paths = makeFiles(3)
        let collector = Collector()
        let failures = FakeFailureStore(known: [paths[0]])
        let eng = engine(paths: paths, cache: FakeCache(), failures: failures,
                         collector: collector) { item in
            collector.noteStart(item.candidate.path)
            return PreviewSweepItemOutcome(stillReady: true)
        }
        await eng.run()
        // paths[0] is a known failure → excluded at plan time, counted
        // unpreviewable, never dispatched.
        XCTAssertEqual(collector.last, .done(ready: 2, unpreviewable: 1, deferred: 0))
        XCTAssertFalse(collector.startedPaths.contains(paths[0]))
    }

    func testGenuineFailureRecordedToStore() async {
        let paths = makeFiles(2)
        let collector = Collector()
        let failures = FakeFailureStore()
        let eng = engine(paths: paths, cache: FakeCache(), failures: failures,
                         collector: collector) { item in
            item.candidate.path == paths[0]
                ? PreviewSweepItemOutcome(stillFailedGenuinely: true)
                : PreviewSweepItemOutcome(stillReady: true)
        }
        await eng.run()
        XCTAssertEqual(collector.last, .done(ready: 1, unpreviewable: 1, deferred: 0))
        XCTAssertEqual(failures.recorded, [paths[0]])
    }

    func testCacheAlreadyAtCapStopsWithoutExecuting() async {
        let paths = makeFiles(2)
        let collector = Collector()
        // A listing whose bytes already exceed the (tiny) cap.
        let cache = FakeCache(listing: [("junk.bin", 10_000)])
        let eng = engine(paths: paths, cache: cache, failures: FakeFailureStore(),
                         collector: collector, cacheCap: 1_000) { item in
            collector.noteStart(item.candidate.path)
            return PreviewSweepItemOutcome(stillReady: true)
        }
        await eng.run()
        if case .cacheFull(let done, _)? = collector.last {
            XCTAssertEqual(done, 0)
        } else {
            XCTFail("expected .cacheFull, got \(String(describing: collector.last))")
        }
        XCTAssertTrue(collector.startedPaths.isEmpty)
    }
}
