// HoldoutReadAheadTests.swift
// Coverage for the holdout read-ahead + spindle keepalive
// (fix/review-sheet-performance, 2026-07-26). Everything here runs
// against the injectable seams (fake ReviewFileToucher, fake thumbnail
// renderer) — no real disk except one RealReviewFileToucher smoke on
// temp fixtures (ISOLATION dimension of the feature-test checklist).
//
// SENSORS pinned here:
//   1. STRICT serialization — never more than one file touched at once
//      (parallel seeks collapse HDD throughput). This is THE regression
//      sensor for the branch: peak concurrent toucher calls == 1.
//   2. Session warm-skip — a path warmed once is not re-read.
//   3. schedule() supersedes — a re-schedule cancels the previous
//      batch's remaining entries (rapid navigation must not queue up
//      stale read-ahead work behind the current item).
//   4. Thumbnail cache FIFO-evicts at maxCachedThumbnails (bounded
//      memory rule).
//   5. Keepalive ticks follow setCurrentPath, stop() halts, start() is
//      idempotent (no second leaked ticker).
// SCALE: schedule() with 10k entries is an O(1) enqueue, not a blocking
// walk of the list.

import CoreGraphics
import Foundation
import Testing
@testable import VideoScan

/// Lock-guarded recording fake — no disk, thread-safe, Sendable.
private final class FakeToucher: ReviewFileToucher, @unchecked Sendable {
    private let lock = NSLock()
    private var warmedPaths: [String] = []
    private var touchedPaths: [String] = []
    private var active = 0
    private var peakActive = 0
    /// Simulated per-file read time (blocking, like a real HDD read).
    let warmDelay: TimeInterval

    init(warmDelay: TimeInterval = 0) { self.warmDelay = warmDelay }

    func warmHeadAndTail(path: String, headBytes: Int, tailBytes: Int) throws {
        lock.lock()
        active += 1
        peakActive = max(peakActive, active)
        lock.unlock()
        if warmDelay > 0 { Thread.sleep(forTimeInterval: warmDelay) }
        lock.lock()
        active -= 1
        warmedPaths.append(path)
        lock.unlock()
    }

    func keepAliveTouch(path: String, readBytes: Int) throws {
        lock.lock()
        touchedPaths.append(path)
        lock.unlock()
    }

    var warms: [String] { lock.lock(); defer { lock.unlock() }; return warmedPaths }
    var touches: [String] { lock.lock(); defer { lock.unlock() }; return touchedPaths }
    var peak: Int { lock.lock(); defer { lock.unlock() }; return peakActive }
}

/// A toucher whose every warm call BLOCKS until the test releases it —
/// lets tests hold a batch mid-file deterministically (no sleep races).
/// For Rick: a counting semaphore used as a hand-cranked valve.
private final class GatedToucher: ReviewFileToucher, @unchecked Sendable {
    private let lock = NSLock()
    private var startedPaths: [String] = []
    private var finishedPaths: [String] = []
    private let gate = DispatchSemaphore(value: 0)

    func warmHeadAndTail(path: String, headBytes: Int, tailBytes: Int) throws {
        lock.lock(); startedPaths.append(path); lock.unlock()
        // Timeout so a broken prefetcher fails the test instead of
        // hanging the suite.
        _ = gate.wait(timeout: .now() + 5)
        lock.lock(); finishedPaths.append(path); lock.unlock()
    }

    func keepAliveTouch(path: String, readBytes: Int) throws {}

    /// Let exactly one blocked (or future) warm call proceed.
    func release() { gate.signal() }

    var started: [String] { lock.lock(); defer { lock.unlock() }; return startedPaths }
    var finished: [String] { lock.lock(); defer { lock.unlock() }; return finishedPaths }
}

private func tinyCGImage() -> CGImage {
    let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                        bytesPerRow: 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return ctx.makeImage()!
}

/// Poll for an async-completing condition — the prefetcher is fire-and-
/// forget by design, so tests observe rather than await.
private func eventually(timeout: TimeInterval = 5,
                        _ condition: @escaping () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@Suite("Holdout Read-Ahead")
struct HoldoutReadAheadTests {

    @Test func prefetch_warmsEntriesAndSkipsAlreadyWarmed() async {
        let toucher = FakeToucher()
        let p = HoldoutReviewPrefetcher(toucher: toucher,
                                        renderThumbnail: { _, _ in nil })
        p.schedule(entries: [
            .init(path: "/T/a.mov", meta: nil, wantsThumbnail: false),
            .init(path: "/T/b.mov", meta: nil, wantsThumbnail: false),
        ])
        #expect(await eventually { toucher.warms.count == 2 })

        // Re-schedule with an overlap — only the NEW path is read again.
        p.schedule(entries: [
            .init(path: "/T/a.mov", meta: nil, wantsThumbnail: false),
            .init(path: "/T/c.mov", meta: nil, wantsThumbnail: false),
        ])
        #expect(await eventually { toucher.warms.count == 3 })
        // Give any (wrong) extra work a moment to appear, then pin.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(toucher.warms == ["/T/a.mov", "/T/b.mov", "/T/c.mov"])
        p.cancelAll()
    }

    @Test func prefetch_neverTouchesTwoFilesConcurrently() async {
        // Slow fake reads + immediate re-schedule: the second batch must
        // WAIT for the in-flight file, not seek against it.
        let toucher = FakeToucher(warmDelay: 0.05)
        let p = HoldoutReviewPrefetcher(toucher: toucher,
                                        renderThumbnail: { _, _ in nil })
        p.schedule(entries: [
            .init(path: "/T/a.mov", meta: nil, wantsThumbnail: false),
            .init(path: "/T/b.mov", meta: nil, wantsThumbnail: false),
        ])
        p.schedule(entries: [
            .init(path: "/T/c.mov", meta: nil, wantsThumbnail: false),
            .init(path: "/T/d.mov", meta: nil, wantsThumbnail: false),
        ])
        // At least the second batch completes (the first may be
        // cancelled between files — that's fine and by design).
        #expect(await eventually { toucher.warms.contains("/T/d.mov") })
        #expect(toucher.peak == 1, "parallel HDD seeks — serialization broken")
        p.cancelAll()
    }

    @Test func prefetch_preGeneratesThumbnailForNextItemOnly() async {
        let toucher = FakeToucher()
        let rendered = FakeToucher()   // reuse as a thread-safe recorder
        let p = HoldoutReviewPrefetcher(
            toucher: toucher,
            renderThumbnail: { path, _ in
                try? rendered.keepAliveTouch(path: path, readBytes: 0)
                return tinyCGImage()
            })
        p.schedule(entries: [
            .init(path: "/T/next.mov", meta: nil, wantsThumbnail: true),
            .init(path: "/T/later.mov", meta: nil, wantsThumbnail: false),
        ])
        #expect(await eventually { p.cachedThumbnail(for: "/T/next.mov") != nil })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(rendered.touches == ["/T/next.mov"])
        #expect(p.cachedThumbnail(for: "/T/later.mov") == nil)
        p.cancelAll()
    }

    @Test func keepalive_touchesCurrentFileUntilStopped() async {
        let toucher = FakeToucher()
        let k = HoldoutSpindleKeepalive(toucher: toucher, intervalSeconds: 0.05)
        k.setCurrentPath("/T/current.mov")
        k.start()
        #expect(await eventually { toucher.touches.count >= 2 })
        #expect(toucher.touches.allSatisfy { $0 == "/T/current.mov" })
        k.stop()
        try? await Task.sleep(for: .milliseconds(150))
        let after = toucher.touches.count
        try? await Task.sleep(for: .milliseconds(200))
        #expect(toucher.touches.count == after, "keepalive kept ticking after stop()")
    }

    @Test func keepalive_noPathMeansNoTouches() async {
        let toucher = FakeToucher()
        let k = HoldoutSpindleKeepalive(toucher: toucher, intervalSeconds: 0.05)
        k.start()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(toucher.touches.isEmpty)
        k.stop()
    }

    // MARK: - Thumbnail cache (miss/hit, FIFO eviction)

    @Test func thumbnailCache_missBeforeRenderHitAfter() async {
        let p = HoldoutReviewPrefetcher(toucher: FakeToucher(),
                                        renderThumbnail: { _, _ in tinyCGImage() })
        // Cold cache: miss, and a miss must not fabricate an entry.
        #expect(p.cachedThumbnail(for: "/T/next.mov") == nil)
        p.schedule(entries: [
            .init(path: "/T/next.mov", meta: nil, wantsThumbnail: true),
        ])
        #expect(await eventually { p.cachedThumbnail(for: "/T/next.mov") != nil })
        // Hit is stable across repeated reads (no consume-on-read).
        #expect(p.cachedThumbnail(for: "/T/next.mov") != nil)
        // A path never scheduled stays a miss.
        #expect(p.cachedThumbnail(for: "/T/never.mov") == nil)
        p.cancelAll()
    }

    @Test func thumbnailCache_evictsOldestBeyondCap() async {
        // maxCachedThumbnails + 3 rendered thumbnails: the FIRST three
        // (oldest) must be evicted, the newest cap-many retained. The
        // cap is the memory rule — the cache CANNOT grow unbounded.
        let cap = HoldoutReviewPrefetcher.maxCachedThumbnails
        let total = cap + 3
        let p = HoldoutReviewPrefetcher(toucher: FakeToucher(),
                                        renderThumbnail: { _, _ in tinyCGImage() })
        let paths = (0..<total).map { "/T/evict/\($0).mov" }
        p.schedule(entries: paths.map {
            .init(path: $0, meta: nil, wantsThumbnail: true)
        })
        // Serial pipeline: the LAST path rendering means all are done.
        #expect(await eventually(timeout: 10) { p.cachedThumbnail(for: paths[total - 1]) != nil })
        for path in paths.prefix(3) {
            #expect(p.cachedThumbnail(for: path) == nil,
                    "\(path) should have been FIFO-evicted at cap \(cap)")
        }
        for path in paths.suffix(cap) {
            #expect(p.cachedThumbnail(for: path) != nil,
                    "\(path) should still be cached (within the newest \(cap))")
        }
        p.cancelAll()
    }

    // MARK: - schedule() supersedes

    @Test func schedule_secondScheduleCancelsFirstBatchRemainder() async {
        // Deterministic supersede pin: batch 1 blocks on its first file;
        // batch 2 arrives; releasing the valve lets batch 1's in-flight
        // file finish, after which batch 1 must STOP (cancelled between
        // files) and batch 2 must run. b and c are never touched.
        let toucher = GatedToucher()
        let p = HoldoutReviewPrefetcher(toucher: toucher,
                                        renderThumbnail: { _, _ in nil })
        p.schedule(entries: [
            .init(path: "/T/a.mov", meta: nil, wantsThumbnail: false),
            .init(path: "/T/b.mov", meta: nil, wantsThumbnail: false),
            .init(path: "/T/c.mov", meta: nil, wantsThumbnail: false),
        ])
        #expect(await eventually { toucher.started == ["/T/a.mov"] })

        p.schedule(entries: [
            .init(path: "/T/x.mov", meta: nil, wantsThumbnail: false),
        ])
        toucher.release()   // a completes; batch 1 sees cancellation
        #expect(await eventually { toucher.started.contains("/T/x.mov") })
        toucher.release()   // x completes
        #expect(await eventually { toucher.finished.contains("/T/x.mov") })

        // Give any (wrong) survivor of batch 1 a moment to appear.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!toucher.started.contains("/T/b.mov"),
                "superseded batch kept running after re-schedule")
        #expect(!toucher.started.contains("/T/c.mov"),
                "superseded batch kept running after re-schedule")
        p.cancelAll()
    }

    // MARK: - Scale (checklist dimension 2)

    @Test func schedule_tenThousandEntriesEnqueuesInstantly() async {
        // schedule() is an O(1) enqueue: cancel-previous + spawn one
        // task. It must NOT walk/touch the entry list synchronously —
        // the UI calls it on the main actor after every navigation.
        // Budget 250 ms — orders of magnitude above the real cost (one
        // Task creation) but far below any O(n)-blocking failure mode
        // with 10k entries × 1 ms per touch.
        let toucher = FakeToucher(warmDelay: 0.001)
        let p = HoldoutReviewPrefetcher(toucher: toucher,
                                        renderThumbnail: { _, _ in nil })
        let entries = (0..<10_000).map {
            HoldoutReviewPrefetcher.Entry(path: "/T/scale/\($0).mov",
                                          meta: nil, wantsThumbnail: false)
        }
        let clock = ContinuousClock()
        let elapsed = clock.measure { p.schedule(entries: entries) }
        #expect(elapsed < .milliseconds(250),
                "schedule() blocked for \(elapsed) — must be O(1) enqueue, not O(entries)")
        p.cancelAll()
    }

    // MARK: - Keepalive: redirect + idempotent start

    @Test func keepalive_setCurrentPathMidRunRedirectsTicks() async {
        let toucher = FakeToucher()
        let k = HoldoutSpindleKeepalive(toucher: toucher, intervalSeconds: 0.05)
        k.setCurrentPath("/T/one.mov")
        k.start()
        #expect(await eventually { toucher.touches.contains("/T/one.mov") })

        k.setCurrentPath("/T/two.mov")
        #expect(await eventually { toucher.touches.contains("/T/two.mov") })
        // From the moment a tick touched the NEW path, the old path must
        // never be touched again (each tick reads the current path).
        let oneCount = toucher.touches.filter { $0 == "/T/one.mov" }.count
        try? await Task.sleep(for: .milliseconds(200))
        #expect(toucher.touches.filter { $0 == "/T/one.mov" }.count == oneCount,
                "keepalive kept touching the OLD path after setCurrentPath")
        k.stop()
    }

    @Test func keepalive_startIsIdempotentNoSecondTicker() async {
        // If a second start() spawned a second ticker, the task handle
        // would be overwritten and stop() could only cancel the newer
        // one — the first would tick forever. Pin: start-start-stop
        // goes fully quiet.
        let toucher = FakeToucher()
        let k = HoldoutSpindleKeepalive(toucher: toucher, intervalSeconds: 0.05)
        k.setCurrentPath("/T/current.mov")
        k.start()
        k.start()   // must be a no-op
        #expect(await eventually { toucher.touches.count >= 2 })
        k.stop()    // ONE stop must halt everything
        try? await Task.sleep(for: .milliseconds(150))
        let after = toucher.touches.count
        try? await Task.sleep(for: .milliseconds(250))
        #expect(toucher.touches.count == after,
                "a leaked second ticker survived stop() — start() is not idempotent")
    }

    @Test func realToucher_readsHeadAndTailOfRealFile() throws {
        // One real-disk smoke: 8 MB temp file, warm 2 MB head + tail —
        // must not throw, must handle a file smaller than head+tail too.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("readahead-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = dir.appendingPathComponent("big.bin")
        try Data(count: 8 * 1024 * 1024).write(to: big)
        let small = dir.appendingPathComponent("small.bin")
        try Data(count: 1024).write(to: small)

        let t = RealReviewFileToucher()
        try t.warmHeadAndTail(path: big.path,
                              headBytes: HoldoutReviewPrefetcher.headBytes,
                              tailBytes: HoldoutReviewPrefetcher.tailBytes)
        try t.warmHeadAndTail(path: small.path,
                              headBytes: HoldoutReviewPrefetcher.headBytes,
                              tailBytes: HoldoutReviewPrefetcher.tailBytes)
        try t.keepAliveTouch(path: big.path,
                             readBytes: HoldoutSpindleKeepalive.touchBytes)
        // Missing file throws rather than hanging.
        #expect(throws: Error.self) {
            try t.warmHeadAndTail(path: dir.appendingPathComponent("gone.bin").path,
                                  headBytes: 1024, tailBytes: 1024)
        }
    }
}
