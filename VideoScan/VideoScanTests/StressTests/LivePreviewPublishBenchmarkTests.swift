import Testing
import Foundation
import Combine
import CoreGraphics
@testable import VideoScan

// MARK: - Live preview publish-pattern micro-benchmark
//
// Question: does coalescing the 3 per-frame live-preview @Published props
// (frame / matched / unmatched) into a single @Published struct actually
// reduce work, or does Combine/SwiftUI coalesce them anyway and make the
// combine a structural no-op?
//
// Two synthetic ObservableObject classes mirror the EXACT publish patterns
// from the production code so the test isolates the variable. Both fire
// through the real ThrottledMainActorUpdate actor with interval=0 (no
// throttle) to maximize signal.
//
// Measured per pattern, N=10000 iterations:
//   - objectWillChange notification count (mechanical: 3N expected for 3-prop
//     pattern, N expected for 1-struct pattern)
//   - wall time (signals whether the per-send overhead is CPU-meaningful)
//
// What this does NOT measure: SwiftUI Layout cost. There is no rendered
// view in this test target, so any savings downstream of the notification
// require a separate harness (real window + display-link counter).

@MainActor
private final class JobBefore: ObservableObject {
    @Published var liveFrame: CGImage?
    @Published var liveMatchedRects: [CGRect] = []
    @Published var liveUnmatchedRects: [CGRect] = []
}

@MainActor
private final class JobAfter: ObservableObject {
    struct LivePreview: Equatable {
        var frame: CGImage?
        var matched: [CGRect] = []
        var unmatched: [CGRect] = []
    }
    @Published var livePreview: LivePreview = .init()
}

@MainActor
struct LivePreviewPublishBenchmarkTests {

    static let N = 10_000

    /// Append a line to /tmp/livePreviewBench.log — xcodebuild test buffers
    /// stdout, so file logging is the reliable way to surface measurements.
    static func logLine(_ s: String) {
        let line = s + "\n"
        let path = "/tmp/livePreviewBench.log"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        } else {
            try? line.data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
        }
    }

    @Test func threeSeparatePropsFireOneNotificationPerAssignment() async {
        let job = JobBefore()
        var notifications = 0
        let sub = job.objectWillChange.sink { _ in notifications += 1 }
        defer { sub.cancel() }

        let throttle = ThrottledMainActorUpdate(intervalSecs: 0)
        let img: CGImage? = nil
        let rects: [CGRect] = []

        for _ in 0..<Self.N {
            await throttle.update {
                job.liveFrame = img
                job.liveMatchedRects = rects
                job.liveUnmatchedRects = rects
            }
        }

        // Allow any deferred Combine sends to settle before reading the counter.
        await MainActor.run { }

        Self.logLine("BEFORE: \(notifications) notifications for \(Self.N) fires (= \(Double(notifications) / Double(Self.N)) per fire)")
        // Mechanical: 3 @Published assignments → 3 objectWillChange.send() calls.
        #expect(notifications == 3 * Self.N)
    }

    @Test func singleStructPropFiresOneNotificationPerAssignment() async {
        let job = JobAfter()
        var notifications = 0
        let sub = job.objectWillChange.sink { _ in notifications += 1 }
        defer { sub.cancel() }

        let throttle = ThrottledMainActorUpdate(intervalSecs: 0)
        let img: CGImage? = nil
        let rects: [CGRect] = []

        for _ in 0..<Self.N {
            await throttle.update {
                job.livePreview = JobAfter.LivePreview(frame: img, matched: rects, unmatched: rects)
            }
        }

        await MainActor.run { }

        Self.logLine("AFTER:  \(notifications) notifications for \(Self.N) fires (= \(Double(notifications) / Double(Self.N)) per fire)")
        #expect(notifications == Self.N)
    }

    @Test func wallTimeBeforePattern() async {
        let job = JobBefore()
        let throttle = ThrottledMainActorUpdate(intervalSecs: 0)
        let img: CGImage? = nil
        let rects: [CGRect] = []

        let t0 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<Self.N {
            await throttle.update {
                job.liveFrame = img
                job.liveMatchedRects = rects
                job.liveUnmatchedRects = rects
            }
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - t0
        let iterPerSec = Double(Self.N) / elapsed
        Self.logLine("BEFORE wall-time: \(Self.N) fires in \(String(format: "%.4f", elapsed))s = \(String(format: "%.0f", iterPerSec)) fires/s")
        // No #expect; this is a measurement, not a correctness gate. Compare
        // against the AFTER number in the test report.
    }

    @Test func wallTimeAfterPattern() async {
        let job = JobAfter()
        let throttle = ThrottledMainActorUpdate(intervalSecs: 0)
        let img: CGImage? = nil
        let rects: [CGRect] = []

        let t0 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<Self.N {
            await throttle.update {
                job.livePreview = JobAfter.LivePreview(frame: img, matched: rects, unmatched: rects)
            }
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - t0
        let iterPerSec = Double(Self.N) / elapsed
        Self.logLine("AFTER  wall-time: \(Self.N) fires in \(String(format: "%.4f", elapsed))s = \(String(format: "%.0f", iterPerSec)) fires/s")
    }
}

// MARK: - appendLog batching benchmark
//
// Question: does the 200ms flush window in ScanJob.appendLog actually coalesce
// many per-line @Published invalidations into one per-batch invalidation on
// `consoleLines`? Verified by counting objectWillChange notifications during
// a rapid append burst.

@MainActor
struct AppendLogBatchingBenchmarkTests {

    @Test func rapidAppendLogCoalescesIntoSinglePublishPerWindow() async throws {
        let job = ScanJob(searchPath: "/tmp")
        var notifications = 0
        let sub = job.objectWillChange.sink { _ in notifications += 1 }
        defer { sub.cancel() }

        // 100 rapid log lines — synchronous, no awaits between them so they
        // all land within a single 200 ms flush window.
        for i in 0..<100 {
            job.appendLog("line \(i)")
        }
        let immediateNotifications = notifications

        // Wait for the flush — 200 ms window + slack.
        try await Task.sleep(for: .milliseconds(400))
        let afterFlush = notifications

        LivePreviewPublishBenchmarkTests.logLine("appendLog: 100 calls fired \(immediateNotifications) immediate + \(afterFlush - immediateNotifications) flush notifications (= \(afterFlush) total)")

        // Immediate path: appendLog only mutates pendingConsoleLines (not
        // @Published), so we expect 0 sends during the append burst.
        #expect(immediateNotifications == 0, "appendLog mutates non-@Published buffer; expected 0 immediate sends, got \(immediateNotifications)")

        // After flush: one append(contentsOf:) on consoleLines fires one
        // objectWillChange send. (No overflow trim needed at 100 lines.)
        #expect(afterFlush <= 2, "Expected ≤2 total notifications after flush; got \(afterFlush)")
        #expect(job.consoleLines.count == 100, "All buffered lines should land in consoleLines")
    }

    @Test func appendLogDuringScanDoesNotLeavePendingLinesAfterStop() async throws {
        let job = ScanJob(searchPath: "/tmp")
        for i in 0..<10 {
            job.appendLog("scan line \(i)")
        }
        // Simulate the producer side calling stop before the 200 ms flush
        // fires — drain must still happen.
        job.startElapsedTimer()
        job.stopElapsedTimer()

        #expect(job.consoleLines.count == 10, "stopElapsedTimer should drain pending console lines")
    }
}

// MARK: - Pause-aware elapsed timer correctness
//
// Verifies the new pauseElapsedTimer / resumeElapsedTimer behavior: paused
// time must not accumulate into elapsedSecs. Tolerance is generous to avoid
// flakes from MainActor scheduling — we care about the structural property
// "paused interval excluded", not millisecond precision.

@MainActor
struct ElapsedTimerPauseTests {

    @Test func pauseElapsedTimerFreezesAccumulator() async throws {
        let job = ScanJob(searchPath: "/tmp")
        job.startElapsedTimer()
        try await Task.sleep(for: .milliseconds(200))
        job.pauseElapsedTimer()
        let pausedAt = job.elapsedSecs
        // Slept 200ms before pause; accumulator should be ~0.2s. Generous
        // tolerance — MainActor scheduling adds jitter.
        // (Note: elapsedSecs isn't refreshed by pauseElapsedTimer itself;
        // the next timer tick or stop call writes it. Re-check after stop.)

        try await Task.sleep(for: .milliseconds(300))
        // Stop without resuming: elapsedSecs should reflect only the pre-pause time.
        job.stopElapsedTimer()
        let finalElapsed = job.elapsedSecs

        // The 300ms of paused sleep MUST NOT be in the final number.
        // Generous bound: pre-pause was ~200ms; allow 100..400ms range.
        #expect(finalElapsed >= 0.100, "elapsed too small (\(finalElapsed)s) — pre-pause work was lost")
        #expect(finalElapsed <= 0.400, "elapsed too large (\(finalElapsed)s) — paused time leaked in (pausedAt=\(pausedAt)s)")
    }

    @Test func resumeElapsedTimerContinuesAccumulator() async throws {
        let job = ScanJob(searchPath: "/tmp")
        job.startElapsedTimer()
        try await Task.sleep(for: .milliseconds(200))
        job.pauseElapsedTimer()

        try await Task.sleep(for: .milliseconds(300))  // paused time — excluded
        job.resumeElapsedTimer()

        try await Task.sleep(for: .milliseconds(200))
        job.stopElapsedTimer()
        let finalElapsed = job.elapsedSecs

        // Live time: 200ms pre-pause + 200ms post-resume = ~400ms.
        // Paused 300ms must be excluded. Expected range ~300..600ms.
        #expect(finalElapsed >= 0.250, "elapsed too small (\(finalElapsed)s) — resumed work was not counted")
        #expect(finalElapsed <= 0.700, "elapsed too large (\(finalElapsed)s) — paused 300ms leaked in")
    }
}
