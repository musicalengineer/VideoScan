// NotificationStormSensorTests.swift
// Sensors for the notification storm that froze the CI test host
// (fix/ci-red-5, CI run 36223041786).
//
// What happened: scale_confirmRoundOver100kRecordsWithinBudget ran
// pfConfirmRound over 100k synthetic records. Its control pool calls
// VolumeReachability.isReachable on ~99k unique internal paths; each was a
// cache miss whose background probe "changed" the answer and posted
// reachabilityDidChange — ~99k posts. Every post fanned out to the
// never-removed probe-change observer of every VideoScanModel the run had
// built, each spawning a main-actor Task. XCTest's spindump: 42.98 GB
// footprint on a 7 GB VM, process suspended, main thread in Task.init
// from that observer. The next @MainActor test (alphabetical plan) —
// UnifiedReviewSessionTests.isolation_… — hit its 1-minute limit and the
// host was restarted, so the run never produced a complete summary.
//
// Two sensors, both red on 442fdc73:
//   1. PRODUCTION-SCALE burst: 100k reachability changes produce a
//      handful of repaint posts, not one per key.
//   2. SOURCE: every block observer VideoScanModel registers is handed to
//      its NotificationObserverBag (NotificationCenter retains block
//      observers until removeObserver — they do NOT die with the model).

import Foundation
import Testing
@testable import VideoScan

@Suite("Notification storm sensors (CI run 36223041786)", .serialized)
struct NotificationStormSensorTests {

    /// Counts reachabilityDidChange deliveries. Lock-guarded: posts arrive
    /// on the main queue while the test body runs on the pool.
    final class PostCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    @Test(.timeLimit(.minutes(2)))
    func reachabilityBurstOf100kChangesPostsAFewRepaintsNotOnePerKey() async throws {
        let counter = PostCounter()
        let token = NotificationCenter.default.addObserver(
            forName: VolumeReachability.reachabilityDidChange,
            object: nil, queue: nil
        ) { _ in counter.bump() }
        defer { NotificationCenter.default.removeObserver(token) }

        // Unique, never-existing INTERNAL paths: keyed by full path, missed
        // with the optimistic default (true), probed false → one "change"
        // per key. Unique per run so no other test's cache entries (or a
        // re-run's) can pre-fill them — the process-wide cache is shared.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs-reach-storm-\(UUID().uuidString)").path
        let keys = 100_000
        for i in 0..<keys {
            _ = VolumeReachability.isReachable(path: "\(base)/k\(i).mov")
        }
        // Every probe landed (barrier on the probe queue) — off the
        // cooperative pool's caller, since the barrier blocks.
        await Task.detached { VolumeReachability.awaitPendingProbesForTesting() }.value
        // Let the trailing coalesced post fire and the main queue drain.
        try await Task.sleep(for: .milliseconds(600))

        let posts = counter.value
        // Before the fix: exactly one post per key (≥ 100,000). After: one
        // per 100 ms burst window. 1,000 is far above any honest burst
        // (100 s of continuous change) and far below the storm.
        #expect(posts < 1_000,
                "\(keys) reachability changes produced \(posts) reachabilityDidChange posts — each one is a main-actor Task per live VideoScanModel; coalesce them")
        // Truthfulness: the burst DID change answers, so at least one
        // repaint must still go out (coalescing must never swallow the last).
        #expect(posts >= 1, "a burst of real changes must still repaint at least once")
    }

    @Test func everyVideoScanModelBlockObserverIsOwnedByItsBag() throws {
        let appDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()            // VideoScanTests/
            .deletingLastPathComponent()            // VideoScan/ (project dir)
            .appendingPathComponent("VideoScan")
        let files = try FileManager.default.contentsOfDirectory(atPath: appDir.path)
            .filter { $0.hasPrefix("VideoScanModel") && $0.hasSuffix(".swift") }
            .sorted()
        #expect(files.count > 10, "sensor found \(files.count) VideoScanModel*.swift files — did the sources move? Update the path deliberately.")

        var totalRegistrations = 0
        for name in files {
            let source = try String(contentsOf: appDir.appendingPathComponent(name), encoding: .utf8)
            let registrations = occurrences(of: "addObserver(", in: source)
            let owned = occurrences(of: "notificationObservers.add(", in: source)
            totalRegistrations += registrations
            #expect(registrations == owned,
                    "\(name): \(registrations) addObserver( call(s) but \(owned) handed to notificationObservers — a block observer not in the bag outlives its model and keeps running (CI run 36223041786: 42.98 GB)")
        }
        // The six known call sites (2 lifecycle, 3 volume, 1 archive-snapshot
        // loop that registers 3) must still be seen — a sensor that finds
        // nothing proves nothing.
        #expect(totalRegistrations >= 6,
                "found only \(totalRegistrations) addObserver( calls in VideoScanModel*.swift")
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        var count = 0
        var search = haystack[...]
        while let r = search.range(of: needle) {
            count += 1
            search = search[r.upperBound...]
        }
        return count
    }
}
