// PreviewCachePoisonSensorTests.swift
// REGRESSION SENSORS for the QA blocker fixed in e6c5a28 (branch
// perf/preview-routing, 2026-07-26):
//
//   THE BUG — ThumbnailPrecache's generateOne used `try?`, which
//   collapsed EVERY error from renderThumbnailCGImage into "this file is
//   bad". Clicking volume B while volume A prewarmed cancelled A's run;
//   ProcessRunner SIGTERMed the in-flight ffmpeg rips; the resulting
//   CancellationError / exit -1 was recorded via recordFailure against
//   the file's UNCHANGED (mtime, size) — so perfectly good files showed
//   "NO PREVIEW" for the rest of the session with no self-invalidation
//   possible.
//
//   THE FIX — do/catch with an explicit skip for
//   `error is CancellationError || Task.isCancelled`, plus
//   renderPreviewFrameViaFFmpeg now runs `try Task.checkCancellation()`
//   right after each runProcess return (a SIGTERMed rip surfaces as
//   CancellationError, never noFrameProduced). Both catch sites also
//   skip PreviewFrameError.ffmpegUnavailable (environment failure, not
//   a fact about the file — QA minor; see the gap note at the bottom).
//
// TEST TECHNIQUE — determinism matters here: the sensor must catch the
// prewarm MID-RIP, or the old code's early `if Task.isCancelled` check
// would dodge the poisoned recordFailure and the sensor would pass
// vacuously against the bug it exists to catch. A FIFO (mkfifo) does
// it: ffmpeg blocks forever reading a pipe that never delivers data, so
// the cancellation window is as wide as we need, and we confirm via
// pgrep that ffmpeg is actually running before cancelling.
// (For Rick: mkfifo(2) named pipe — reader blocks until a writer shows
// up, which never happens; SIGTERM is the only way out.)
//
// Verified against the OLD code: with `try?` in generateOne, the
// cancelled rip's error (CancellationError from the loop-top check)
// was swallowed and recordFailure ran → the poisoning sensor below
// flips red. On the fixed code it stays green.

import Testing
import Foundation
import Darwin
@testable import VideoScan

@Suite("Preview negative-cache poisoning sensors",
       .serialized,
       .timeLimit(.minutes(3)),
       .enabled(if: TestMediaGenerator.isAvailable))
@MainActor
struct PreviewCachePoisonSensorTests {

    // MARK: - Fixtures

    /// Temp dir containing a FIFO disguised as an mkv — routes
    /// .ffmpegDirect ("Matroska / WebM"), and the rip blocks on it
    /// until SIGTERMed.
    private func makeFIFOWorkspace() throws -> (dir: URL, fifoPath: String) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_gen_poison_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fifoPath = dir.appendingPathComponent("blocking.mkv").path
        guard mkfifo(fifoPath, 0o600) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        return (dir, fifoPath)
    }

    /// True while an ffmpeg child whose command line mentions `needle`
    /// is alive. pgrep -f matches the full argv, and the UUID in the
    /// fifo path makes the needle collision-proof against parallel
    /// suites.
    private nonisolated func ffmpegAlive(matching needle: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", needle]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Poll until ffmpeg is observably mid-rip on `needle` (or fail).
    private func waitForRipInFlight(_ needle: String) async throws {
        var started = false
        for _ in 0..<100 {   // up to 10 s — spawn is normally < 100 ms
            if ffmpegAlive(matching: needle) { started = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(started,
                     "ffmpeg never started ripping the fifo — did the mkv route stop going ffmpegDirect?")
    }

    private func makeRecord(path: String) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = (path as NSString).lastPathComponent
        r.container = "Matroska / WebM"
        r.videoCodec = "ffv1"
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        return r
    }

    // MARK: - THE sensor (QA blocker)

    /// Cancel a prewarm MID-RIP (the volume A → volume B click) and
    /// assert the negative cache stays empty. On the old `try?` code the
    /// SIGTERMed rip's error was recorded as a file failure against the
    /// unchanged (mtime, size) — this test flips red there; do not
    /// weaken it by cancelling before the rip starts.
    @Test("cancelled prewarm must not poison the negative cache")
    func cancelledPrewarmDoesNotPoisonCache() async throws {
        let ws = try makeFIFOWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.dir) }

        let model = VideoScanModel()
        let store = model.thumbnailFailureStore
        let precacher = ThumbnailPrecacher()

        precacher.start(volumeLabel: "poison-sensor",
                        candidates: [makeRecord(path: ws.fifoPath)],
                        concurrency: 1,
                        model: model)
        // The window must be MID-RIP, observably — see file header.
        try await waitForRipInFlight(ws.fifoPath)
        #expect(!store.isKnownFailure(atPath: ws.fifoPath),
                "sanity: nothing recorded while the rip is still in flight")

        precacher.cancel(reason: "test: user clicked volume B")

        // The cancelled run's catch site executes within ~100 ms of the
        // SIGTERM landing; give it a generous 3 s to (wrongly) record,
        // failing fast the moment anything appears.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if store.isKnownFailure(atPath: ws.fifoPath) { break }  // fail fast
            try await Task.sleep(for: .milliseconds(100))
        }
        // swiftlint:disable:next empty_count
        #expect(store.count == 0,
                "cancellation poisoned the negative cache — a good file would show NO PREVIEW all session")
        #expect(!store.isKnownFailure(atPath: ws.fifoPath))
    }

    // MARK: - Render-tier contract pin

    /// A cancelled render must surface CancellationError — never
    /// noFrameProduced. This is the contract the precacher's catch-site
    /// skip relies on: if a SIGTERMed rip ever reports itself as a
    /// "real" decode failure again, the poisoning returns even with the
    /// do/catch in place. Pins the `try Task.checkCancellation()` after
    /// each runProcess return (the old code only checked at loop top,
    /// leaving the second-seek attempt able to fall through to
    /// noFrameProduced).
    @Test("cancelled render throws CancellationError, not noFrameProduced")
    func cancelledRenderThrowsCancellation() async throws {
        let ws = try makeFIFOWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.dir) }

        let render = Task {
            try await VideoScanModel.renderThumbnailCGImage(
                path: ws.fifoPath,
                container: "Matroska / WebM",
                videoCodec: "ffv1",
                likelyUnanalyzable: false)
        }
        try await waitForRipInFlight(ws.fifoPath)
        render.cancel()

        switch await render.result {
        case .success:
            Issue.record("a rip of a never-delivering fifo cannot succeed")
        case .failure(let error):
            #expect(error is CancellationError,
                    "cancelled render must say CancellationError, got: \(error)")
            #expect((error as? PreviewFrameError) != .noFrameProduced,
                    "noFrameProduced from a cancelled rip is exactly the poisoning input the blocker fixed")
        }
    }

    // MARK: - Positive control (sensor is not vacuous)

    /// The fix must not overshoot: a GENUINE decode failure (garbage
    /// bytes in an .mkv) must still land in the negative cache via the
    /// same generateOne catch site — otherwise the "NO PREVIEW" state
    /// and the one-stat retry suppression silently die. Safety-critical
    /// rule: every negative sensor ships with its positive twin.
    @Test("genuine decode failure still records in the negative cache")
    func genuineFailureStillRecords() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_gen_poison_pos_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let junkPath = dir.appendingPathComponent("garbage.mkv").path
        try Data(repeating: 0x5A, count: 4096).write(to: URL(fileURLWithPath: junkPath))

        let model = VideoScanModel()
        let store = model.thumbnailFailureStore
        let precacher = ThumbnailPrecacher()

        precacher.start(volumeLabel: "poison-sensor-positive",
                        candidates: [makeRecord(path: junkPath)],
                        concurrency: 1,
                        model: model)

        // Both seek attempts fail fast on garbage; allow up to 10 s for
        // the run to finish and record.
        var recorded = false
        for _ in 0..<100 {
            if store.isKnownFailure(atPath: junkPath) { recorded = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(recorded,
                "a real decode failure must still be remembered — the cancellation fix has overshot")
    }

    // MARK: - Known gap (QA minor: ffmpegUnavailable)
    //
    // Both catch sites also skip PreviewFrameError.ffmpegUnavailable.
    // That branch is NOT sensor-covered: it only fires when
    // ToolLocator.ffmpegPath resolves to nothing executable, and
    // ToolLocator's env-var override deliberately falls back to the
    // Homebrew candidates when the override isn't executable — so with
    // ffmpeg installed (a hard requirement of this suite and half the
    // repo) the error is unreachable from tests without a production
    // seam. An injectable ffmpeg path on renderThumbnailCGImage (the
    // BalanceAudioJob ffmpegPathOverride pattern) would make it a
    // three-line test; flagged to the Manager rather than shipping a
    // test that fakes the condition without touching the real guard.
}
