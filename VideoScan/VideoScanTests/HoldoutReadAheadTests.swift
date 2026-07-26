// HoldoutReadAheadTests.swift
// Stub coverage for the holdout read-ahead + spindle keepalive
// (fix/review-sheet-performance, 2026-07-26). Proves the injectability
// seams work (fake ReviewFileToucher, fake thumbnail renderer, no real
// disk) and pins the two behaviors that matter for the HDD:
//   1. STRICT serialization — never more than one file touched at once
//      (parallel seeks collapse HDD throughput).
//   2. Session warm-skip — a path warmed once is not re-read.
// The testing agent extends from here (scale/media-matrix dimensions).

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
