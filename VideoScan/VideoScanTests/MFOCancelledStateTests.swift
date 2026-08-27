import Testing
import Combine
import Foundation
@testable import VideoScan

// MARK: - MFO cancel → Cancelled, never Failed (Rick 2026-08-26)
//
// "If I cancel any MFO verb/job it shouldn't say 'Failed' with a red x
// but 'Cancelled' maybe with a blue x or a square."
//
// Two bug shapes were live:
//
//   1. DERIVED-STATE jobs (compare / extract faces / extract frames)
//      computed `state` as lastError → wasCancelled → …, so the
//      SIGTERM'd ffmpeg's non-zero exit (recorded as `lastError` while
//      the Task unwound) repainted the user's Stop as a red Failed.
//   2. STORED-STATE jobs checked cancel in their happy path but a typed
//      catch clause (VerifyAudio's `probeFailed`), or a cancel landing
//      between a check and a later `finish(failed:)`, still ended
//      `.failed`. Fix: every `finish(failed:)` diverts to the cancelled
//      terminal when `state.cancelWasRequested`.
//
// Pinned here, positive AND negative:
//   - state → label/symbol/tint mapping (pure)
//   - derived jobs: cancel then late error → .cancelled; error BEFORE
//     cancel still .failed; stall still wins
//   - stored jobs, per kind reachable without a live orchestrator /
//     archive: cancel mid-run with an injected long-running child that
//     exits non-zero on SIGTERM (or an override that throws a typed
//     error after cancel) → .cancelled, no "FAILED" OUTCOME line,
//     outputs cleaned per the job's contract; a genuine failure still
//     → .failed (regression guard)
//
// Suites that swap `appLog` or spawn children are `.serialized`.

// MARK: - Pure badge mapping

@Suite("MediaFileOperationState.badge — Cancelled is not Failed")
struct MFOStateBadgeTests {

    @Test func cancelledIsBlueStopNotRedX() {
        let b = MediaFileOperationState.cancelled.badge
        #expect(b.label == "Cancelled")
        #expect(b.symbol == "stop.circle.fill")
        #expect(b.tint == .blue)
        #expect(b.tint != .red)
        #expect(b.symbol != "xmark.octagon", "the octagon is the failure glyph")
    }

    @Test func failedStaysRedX() {
        let b = MediaFileOperationState.failed(message: "ffmpeg exit 255").badge
        #expect(b.label == "Failed")
        #expect(b.symbol == "xmark.circle.fill")
        #expect(b.tint == .red)
    }

    @Test func cancellingReadsCancellingWithEllipsis() {
        let b = MediaFileOperationState.cancelling.badge
        #expect(b.label == "Cancelling…")
        #expect(b.symbol == nil, "in-flight rows show the progress bar, not a glyph")
        #expect(b.tint == .orange)
    }

    @Test func finishedAndRunning() {
        #expect(MediaFileOperationState.finished(summary: "ok").badge
                == .init(label: "Done", symbol: "checkmark.circle.fill", tint: .green))
        #expect(MediaFileOperationState.running.badge.symbol == nil)
    }

    @Test func cancelWasRequestedCoversOnlyTheTwoCancelStates() {
        #expect(MediaFileOperationState.cancelling.cancelWasRequested)
        #expect(MediaFileOperationState.cancelled.cancelWasRequested)
        #expect(!MediaFileOperationState.running.cancelWasRequested)
        #expect(!MediaFileOperationState.finished(summary: "x").cancelWasRequested)
        #expect(!MediaFileOperationState.failed(message: "x").cancelWasRequested)
    }

    /// The OUTCOME line for a cancelled job must not carry "FAILED".
    @Test func cancelledOutcomeLineNeverSaysFailed() {
        for kind in MediaFileOperationKind.allCases {
            let line = MediaFileOperationsCenter.terminalSummaryLine(
                verb: kind.logVerb, title: "x.mov", state: .cancelled, wasRefused: false)
            #expect(line == "\(kind.logVerb) cancelled: x.mov")
            #expect(!(line?.contains("FAILED") ?? true))
        }
    }
}

// MARK: - Derived-state jobs

@MainActor
@Suite("Derived-state jobs — a late engine error never outranks cancel")
struct MFODerivedStateCancelTests {

    private func rec(_ path: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (path as NSString).lastPathComponent
        r.fullPath = path
        return r
    }

    private func compareJob() -> PairCompareJob {
        PairCompareJob(recordA: rec("/tmp/a.mov"), recordB: rec("/tmp/b.mov"), gates: [])
    }
    private func extractJob() -> ExtractFramesJob {
        ExtractFramesJob(record: rec("/tmp/clip.mov"),
                         destinationParent: FileManager.default.temporaryDirectory,
                         gates: [])
    }
    private func ripJob() -> RipAllFramesJob {
        RipAllFramesJob(record: rec("/tmp/clip.mov"),
                        destinationParent: FileManager.default.temporaryDirectory,
                        gates: [], options: AllFramesRipper.Options())
    }

    // The bug: Stop → SIGTERM → child exits non-zero → engine records
    // lastError → row said Failed.
    @Test func compareCancelThenFfmpegErrorIsCancelled() {
        let job = compareJob()
        job.comparator.isRunning = true
        job.cancel()
        #expect(job.state == .cancelling)
        job.comparator.lastError = "ffmpeg exited with status 255"
        job.comparator.isRunning = false
        #expect(job.state == .cancelled, "got \(job.state)")
        #expect(job.subtitle == "Cancelled")
        #expect(job.state.badge.label == "Cancelled")
    }

    @Test func extractCancelThenDecodeErrorIsCancelled() {
        let job = extractJob()
        job.ripper.isRunning = true
        job.cancel()
        job.ripper.lastError = "Couldn't read video"
        job.ripper.isRunning = false
        #expect(job.state == .cancelled, "got \(job.state)")
        #expect(job.subtitle.hasPrefix("Cancelled"))
    }

    @Test func ripAllFramesCancelThenFfmpegErrorIsCancelled() {
        let job = ripJob()
        job.ripper.isRunning = true
        job.cancel()
        job.ripper.lastError = "ffmpeg exited with status 255"
        job.ripper.isRunning = false
        #expect(job.state == .cancelled, "got \(job.state)")
        #expect(job.subtitle.hasPrefix("Cancelled"))
    }

    // Regression: an error that landed BEFORE the user pressed Stop is a
    // real failure — cancel() on a terminal row is a no-op.
    @Test func errorBeforeCancelStaysFailed() {
        let c = compareJob()
        c.comparator.lastError = "Couldn't read a.mov"
        c.cancel()
        #expect(!c.wasCancelled)
        #expect(c.state == .failed(message: "Couldn't read a.mov"))

        let e = extractJob()
        e.ripper.lastError = "Zero-duration video."
        e.cancel()
        #expect(e.state == .failed(message: "Zero-duration video."))

        let r = ripJob()
        r.ripper.lastError = "no video stream"
        r.cancel()
        #expect(r.state == .failed(message: "no video stream"))
    }

    // Regression: the stall watchdog is a genuine failure with an
    // attributed reason — it must keep winning over everything but a
    // verdict, and a cancel AFTER the stall can't soften it.
    @Test func stallStillRendersFailed() {
        let job = compareJob()
        job.comparator.isRunning = true
        job.handleStall(silentFor: 120)
        guard case .failed(let msg) = job.state else {
            Issue.record("expected .failed, got \(job.state)")
            return
        }
        #expect(msg.hasPrefix("Stalled"))
        job.cancel()   // no-op on a terminal row
        #expect(!job.wasCancelled)
        if case .failed = job.state {} else { Issue.record("stall lost to cancel") }
    }

    @Test func cancelBeforeStartIsCancelled() {
        let c = compareJob(); c.cancel(); #expect(c.state == .cancelled)
        let e = extractJob(); e.cancel(); #expect(e.state == .cancelled)
        let r = ripJob();     r.cancel(); #expect(r.state == .cancelled)
    }
}

// MARK: - Stored-state jobs

/// A fake ffmpeg that behaves like the real one under Stop: blocks until
/// SIGTERM, then exits NON-ZERO (ffmpeg traps TERM and exits 255). Any
/// job that reads that exit as a failure after the user cancelled has
/// the bug.
@discardableResult
private func writeTrappingFFmpeg(in dir: URL) throws -> URL {
    let script = dir.appendingPathComponent("trapping-ffmpeg.sh")
    try """
    #!/bin/sh
    trap 'kill $SLEEPER 2>/dev/null; exit 255' TERM INT
    /bin/sleep 60 &
    SLEEPER=$!
    wait $SLEEPER
    exit 0

    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                          ofItemAtPath: script.path)
    return script
}

/// Block until the surrounding Task is cancelled (an override standing in
/// for a long probe/render), then throw `error` — modelling the typed
/// error a killed child surfaces while the job unwinds.
private func blockUntilCancelledThenThrow(_ error: Error) async throws -> Never {
    while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    throw error
}

private struct GenericRenderError: Error {}

private func partialDebris(in dir: URL) -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return names.filter { $0.contains(".vs-partial.") }
}

private func makeScratch(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("test_mfo_cancel_\(label)_\(UUID().uuidString.prefix(8))",
                                isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Let the Center's deferred terminal watcher write its OUTCOME line.
@MainActor
private func drainMainActor(until condition: () -> Bool) async {
    for i in 0..<400 {
        if condition() { return }
        if i % 40 == 39 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        } else {
            await Task.yield()
        }
    }
}

@MainActor
@Suite("Stored-state jobs — cancel mid-run ends Cancelled, never Failed", .serialized)
struct MFOStoredStateCancelTests {

    // MARK: Verify Audio — typed probe error thrown after cancel

    @Test("verify audio: probeFailed thrown after Stop → Cancelled; OUTCOME line says cancelled, never FAILED")
    func verifyAudioCancelThenProbeFailed() async throws {
        let name = "test_mfo_cancel_\(UUID().uuidString.prefix(8)).mov"
        let rec = VideoRecord()
        rec.filename = name
        rec.fullPath = "/Volumes/T/\(name)"
        rec.streamTypeRaw = StreamType.videoAndAudio.rawValue
        let model = VideoScanModel()
        model.records = [rec]

        // Manual appLog swap (withAppLog is synchronous; this test awaits
        // across the swap). Restored in defer — RAII-style scope guard.
        let sink = InMemoryLogSink()
        let previousLog = appLog
        appLog = sink
        defer { appLog = previousLog }

        let job = VerifyAudioJob(record: rec, model: model, diagnoseOverride: { _ in
            try await blockUntilCancelledThenThrow(
                AudioVerifyProbeError.probeFailed("ffmpeg exited with status 255"))
        })
        let center = MediaFileOperationsCenter()
        center.add(job)
        job.start()
        try await Task.sleep(nanoseconds: 100_000_000)
        job.cancel()
        #expect(job.state == .cancelling)
        await job.task?.value
        await drainMainActor { sink.lines.contains { $0.contains(name) && $0.contains("cancelled") } }

        #expect(job.state == .cancelled, "got \(job.state) — \(job.subtitle)")
        #expect(job.finishedAt != nil)
        #expect(rec.audioVerifyStatus.isEmpty, "a cancelled probe is not a verdict")
        let mine = sink.lines.filter { $0.contains(name) }
        #expect(mine.contains { $0.hasPrefix("verify audio cancelled:") }, "\(mine)")
        #expect(!mine.contains { $0.contains("FAILED") }, "no FAILED line for a cancel: \(mine)")
    }

    // Regression: the same typed error WITHOUT a cancel is a real failure.
    @Test func verifyAudioGenuineProbeFailureStaysFailed() async throws {
        let rec = VideoRecord()
        rec.filename = "test_mfo_genuine.mov"
        rec.fullPath = "/Volumes/T/test_mfo_genuine.mov"
        rec.streamTypeRaw = StreamType.videoAndAudio.rawValue
        let model = VideoScanModel()
        model.records = [rec]
        let job = VerifyAudioJob(record: rec, model: model, diagnoseOverride: { _ in
            throw AudioVerifyProbeError.probeFailed("ffmpeg exited with status 1")
        })
        job.start()
        await job.task?.value
        guard case .failed(let msg) = job.state else {
            Issue.record("expected .failed, got \(job.state)")
            return
        }
        #expect(msg.contains("status 1"))
        #expect(job.state.badge.tint == .red)
    }

    // MARK: Clean Up — engine throws a generic (non-Cancellation) error after Stop

    private struct BlockingCleanupEngine: CleanupRecipeEngine {
        let engineID = "blocking-test-engine"
        func canExecute(_ recipe: CleanupRecipe) -> Bool { true }
        func render(recipe: CleanupRecipe, source: CleanupSource, scratchDirectory: URL,
                    progress: @escaping @Sendable (CleanupProgress) -> Void) async throws -> URL {
            progress(CleanupProgress(phase: "Blocking render", fraction: 0.1))
            try await blockUntilCancelledThenThrow(GenericRenderError())
        }
    }

    @Test("cleanup: generic render error after Stop → Cancelled, nothing published", .timeLimit(.minutes(2)))
    func cleanupCancelThenGenericError() async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let dir = try makeScratch("cleanup")
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = try CleanupTestMedia.generate(
            into: dir, name: "test_cleanup_cancel.mp4", duration: 1.0,
            size: "320x240", rate: "25", videoCodec: "libx264",
            extraVideoArgs: ["-preset", "ultrafast"], audioCodec: "aac")
        let model = VideoScanModel()
        let source = makeCleanupSourceRecord(path: src, durationSeconds: 1.0, fieldOrder: "tt")
        model.records = [source]
        let job = CleanupJob(record: source, recipe: CleanupRecipeRegistry.vhsQuickClean,
                             model: model, engine: BlockingCleanupEngine())
        job.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        job.cancel()
        await job.task?.value

        #expect(job.state == .cancelled, "got \(job.state) — \(job.subtitle)")
        #expect(!FileManager.default.fileExists(atPath: job.outputURL.path))
        #expect(partialDebris(in: dir).isEmpty)
        #expect(model.records.count == 1, "no catalog row for a cancelled cleanup")
    }

    // MARK: Balance Audio — SIGTERM'd ffmpeg exits 255

    @Test("balance audio: injected ffmpeg exits 255 on SIGTERM after Stop → Cancelled", .timeLimit(.minutes(2)))
    func balanceCancelWithTrappingFFmpeg() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try BalanceAudioTestMedia.makeScratchDir("mfo_cancel")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try BalanceAudioTestMedia.generate(into: dir, channelCase: .leftOnly, wrapper: .mp4H264Aac)
        let analysis = try await AudioBalanceProbe.analyze(path: path)
        let model = VideoScanModel()
        let record = makeBalanceSourceRecord(path: path,
                                             durationSeconds: analysis.shape.durationSeconds,
                                             audioCodec: analysis.shape.audioCodec)
        model.records = [record]
        let fake = try writeTrappingFFmpeg(in: dir)

        let job = BalanceAudioJob(record: record, analysis: analysis, model: model,
                                  ffmpegPathOverride: fake.path)
        job.start()
        try await Task.sleep(nanoseconds: 500_000_000)   // child is blocked in sleep
        #expect(job.state == .running)
        job.cancel()
        await job.task?.value

        #expect(job.state == .cancelled, "got \(job.state) — \(job.subtitle)")
        #expect(!FileManager.default.fileExists(atPath: job.outputURL.path))
        #expect(partialDebris(in: dir).isEmpty)
    }

    // Regression: the same non-zero exit WITHOUT a cancel is a real failure.
    @Test("balance audio: genuine ffmpeg failure still renders Failed", .timeLimit(.minutes(2)))
    func balanceGenuineFailureStaysFailed() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try BalanceAudioTestMedia.makeScratchDir("mfo_fail")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try BalanceAudioTestMedia.generate(into: dir, channelCase: .leftOnly, wrapper: .mp4H264Aac)
        let analysis = try await AudioBalanceProbe.analyze(path: path)
        let model = VideoScanModel()
        let record = makeBalanceSourceRecord(path: path,
                                             durationSeconds: analysis.shape.durationSeconds,
                                             audioCodec: analysis.shape.audioCodec)
        model.records = [record]
        let job = BalanceAudioJob(record: record, analysis: analysis, model: model,
                                  ffmpegPathOverride: "/usr/bin/false")
        job.start()
        await job.task?.value
        guard case .failed = job.state else {
            Issue.record("expected .failed, got \(job.state)")
            return
        }
        #expect(job.state.badge.label == "Failed")
    }

    // MARK: Rebuild Audio — SIGTERM'd ffmpeg exits 255

    @Test("rebuild audio: injected ffmpeg exits 255 on SIGTERM after Stop → Cancelled", .timeLimit(.minutes(2)))
    func rebuildCancelWithTrappingFFmpeg() async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let dir = try makeScratch("rebuild")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try CleanupTestMedia.generate(
            into: dir, name: "test_rebuild_cancel.mp4", duration: 2.0,
            size: "320x240", rate: "25", videoCodec: "libx264",
            extraVideoArgs: ["-preset", "ultrafast"], audioCodec: "aac")
        let d = try await VerifyAudioProbe.diagnose(path: path)
        let model = VideoScanModel()
        let record = makeBalanceSourceRecord(path: path,
                                             durationSeconds: d.shape.containerDurationSeconds,
                                             audioCodec: d.shape.audioCodec)
        model.records = [record]
        let fake = try writeTrappingFFmpeg(in: dir)

        let job = RebuildAudioJob(record: record, reason: "test", shape: d.shape, model: model,
                                  ffmpegPathOverride: fake.path)
        job.start()
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(job.state == .running)
        job.cancel()
        await job.task?.value

        #expect(job.state == .cancelled, "got \(job.state) — \(job.subtitle)")
        #expect(!FileManager.default.fileExists(atPath: job.outputURL.path))
        #expect(partialDebris(in: dir).isEmpty)
    }

    // MARK: Transcode / Reformat — real ffmpeg on a synthetic fixture,
    // Stop right after start. Whatever the race (cancel before spawn,
    // during, or after a fast exit), the ONLY acceptable terminal is
    // .cancelled with nothing at the output path.

    @Test("transcode: Stop right after start → Cancelled, no output", .timeLimit(.minutes(2)))
    func transcodeCancelIsCancelled() async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let dir = try makeScratch("transcode")
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = try CleanupTestMedia.generate(
            into: dir, name: "test_transcode_cancel.mp4", duration: 6.0,
            size: "640x480", rate: "30", videoCodec: "libx264",
            extraVideoArgs: ["-preset", "ultrafast"], audioCodec: "aac")
        let record = makeCleanupSourceRecord(path: src, durationSeconds: 6.0, fieldOrder: "progressive")
        let model = VideoScanModel()
        model.records = [record]
        let out = dir.appendingPathComponent("test_transcode_cancel_out.mov")
        let job = TranscodeJob(record: record, preset: .editing, outputURL: out, model: model)
        job.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        job.cancel()
        await job.task?.value

        #expect(job.state == .cancelled, "got \(job.state) — \(job.subtitle)")
        #expect(!FileManager.default.fileExists(atPath: out.path))
        #expect(partialDebris(in: dir).isEmpty)
        #expect(model.records.count == 1)
    }

    @Test("reformat: Stop right after start → Cancelled, no output", .timeLimit(.minutes(2)))
    func reformatCancelIsCancelled() async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let dir = try makeScratch("reformat")
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = try CleanupTestMedia.generate(
            into: dir, name: "test_reformat_cancel.mp4", duration: 6.0,
            size: "640x480", rate: "30", videoCodec: "libx264",
            extraVideoArgs: ["-preset", "ultrafast"], audioCodec: "aac")
        let record = makeCleanupSourceRecord(path: src, durationSeconds: 6.0, fieldOrder: "progressive")
        let model = VideoScanModel()
        model.records = [record]
        let job = ReformatJob(record: record, model: model, orchestrator: nil)
        job.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        job.cancel()
        await job.task?.value

        #expect(job.state == .cancelled, "got \(job.state) — \(job.subtitle)")
        #expect(!FileManager.default.fileExists(atPath: job.outputURL.path))
        #expect(partialDebris(in: dir).isEmpty)
    }
}

// MARK: - Stall recorded BEFORE Stop stays Failed (codex gate 2026-08-26)
//
// The stored-state watchdogs record their reason and cancel the Task
// while `state` stays `.running`. If Stop was clicked before the run
// epilogue, `cancel()` used to flip `.cancelling` and the 06b8ce2f
// diversion in `finish(failed:)` then reported a KNOWN stall as
// "Cancelled". `MFOTerminalCause` makes the first cause explicit.
//
// Per kind, three shapes:
//   - stall then Stop → .failed with the stall message, never Cancelled;
//     and Stop after a stall never shows "Cancelling…" (the row stays
//     "Stalled — stopping…")
//   - Stop then late error → .cancelled (regression from 06b8ce2f)
//   - plain stall → .failed
//
// Balance / Rebuild / Cleanup fire the stall while the injected child is
// genuinely blocked (the real mid-run shape). Transcode / Reformat / Trim
// have no ffmpeg override, so the stall is fired right after start() —
// on the main actor the run Task cannot begin until this test suspends,
// so the ordering is deterministic and the epilogue's "stall first"
// ladder is what is under test, whatever ffmpeg then does.

@Suite("MFOTerminalCause — set-once ledger")
struct MFOTerminalCauseTests {
    @Test func firstRecordWinsAndLaterOnesAreRefused() {
        // (#expect captures its expression by value, so the mutating
        // `record` is called outside the macro.)
        var cause = MFOTerminalCause()
        #expect(cause.first == nil && !cause.isStall && !cause.isCancel)
        let stallWon = cause.record(.stall(reason: "Stalled — x"))
        #expect(stallWon)
        let lateCancelWon = cause.record(.cancel)
        #expect(!lateCancelWon, "a Stop after a stall is refused")
        #expect(cause.stallReason == "Stalled — x")
        #expect(cause.isStall && !cause.isCancel)

        var other = MFOTerminalCause()
        let cancelWon = other.record(.cancel)
        #expect(cancelWon)
        let lateStallWon = other.record(.stall(reason: "late"))
        #expect(!lateStallWon, "a stall after a Stop is refused")
        #expect(other.isCancel && other.stallReason == nil)
    }
}

@MainActor
@Suite("Stored-state jobs — a stall recorded before Stop stays Failed", .serialized)
struct MFOStallBeforeStopTests {

    private func expectStalledFailure(_ state: MediaFileOperationState, _ label: String) {
        guard case .failed(let msg) = state else {
            Issue.record("\(label): expected .failed(Stalled…), got \(state)")
            return
        }
        #expect(msg.hasPrefix("Stalled"), "\(label): \(msg)")
    }

    // MARK: Balance Audio

    @Test("balance: stall then Stop → Failed with the stall reason", .timeLimit(.minutes(2)))
    func balanceStallThenStop() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try BalanceAudioTestMedia.makeScratchDir("mfo_stall_stop")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try BalanceAudioTestMedia.generate(into: dir, channelCase: .leftOnly, wrapper: .mp4H264Aac)
        let analysis = try await AudioBalanceProbe.analyze(path: path)
        let model = VideoScanModel()
        let record = makeBalanceSourceRecord(path: path,
                                             durationSeconds: analysis.shape.durationSeconds,
                                             audioCodec: analysis.shape.audioCodec)
        model.records = [record]
        let fake = try writeTrappingFFmpeg(in: dir)
        let job = BalanceAudioJob(record: record, analysis: analysis, model: model,
                                  ffmpegPathOverride: fake.path)
        job.start()
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(job.state == .running)
        job.handleStall(silentFor: 120)
        #expect(job.state == .running, "the watchdog leaves state alone until the epilogue")
        #expect(job.subtitle == "Stalled — stopping…")
        job.cancel()
        #expect(job.state == .running, "Stop after a stall must not become Cancelling")
        #expect(job.subtitle == "Stalled — stopping…")
        await job.task?.value
        expectStalledFailure(job.state, "balance")
        #expect(!FileManager.default.fileExists(atPath: job.outputURL.path))
        #expect(partialDebris(in: dir).isEmpty)
    }

    @Test("balance: plain stall → Failed", .timeLimit(.minutes(2)))
    func balancePlainStall() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try BalanceAudioTestMedia.makeScratchDir("mfo_stall")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try BalanceAudioTestMedia.generate(into: dir, channelCase: .leftOnly, wrapper: .mp4H264Aac)
        let analysis = try await AudioBalanceProbe.analyze(path: path)
        let model = VideoScanModel()
        let record = makeBalanceSourceRecord(path: path,
                                             durationSeconds: analysis.shape.durationSeconds,
                                             audioCodec: analysis.shape.audioCodec)
        model.records = [record]
        let fake = try writeTrappingFFmpeg(in: dir)
        let job = BalanceAudioJob(record: record, analysis: analysis, model: model,
                                  ffmpegPathOverride: fake.path)
        job.start()
        try await Task.sleep(nanoseconds: 500_000_000)
        job.handleStall(silentFor: 120)
        await job.task?.value
        expectStalledFailure(job.state, "balance")
    }

    // MARK: Rebuild Audio

    @Test("rebuild: stall then Stop → Failed with the stall reason", .timeLimit(.minutes(2)))
    func rebuildStallThenStop() async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let dir = try makeScratch("rebuild_stall")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try CleanupTestMedia.generate(
            into: dir, name: "test_rebuild_stall.mp4", duration: 2.0,
            size: "320x240", rate: "25", videoCodec: "libx264",
            extraVideoArgs: ["-preset", "ultrafast"], audioCodec: "aac")
        let d = try await VerifyAudioProbe.diagnose(path: path)
        let model = VideoScanModel()
        let record = makeBalanceSourceRecord(path: path,
                                             durationSeconds: d.shape.containerDurationSeconds,
                                             audioCodec: d.shape.audioCodec)
        model.records = [record]
        let fake = try writeTrappingFFmpeg(in: dir)
        let job = RebuildAudioJob(record: record, reason: "test", shape: d.shape, model: model,
                                  ffmpegPathOverride: fake.path)
        job.start()
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(job.state == .running)
        job.handleStall(silentFor: 120)
        job.cancel()
        #expect(job.state == .running, "Stop after a stall must not become Cancelling")
        await job.task?.value
        expectStalledFailure(job.state, "rebuild")
        #expect(!FileManager.default.fileExists(atPath: job.outputURL.path))
        #expect(partialDebris(in: dir).isEmpty)

        // Plain stall, same harness.
        let plain = RebuildAudioJob(record: record, reason: "test", shape: d.shape, model: model,
                                    ffmpegPathOverride: fake.path)
        plain.start()
        try await Task.sleep(nanoseconds: 500_000_000)
        plain.handleStall(silentFor: 120)
        await plain.task?.value
        expectStalledFailure(plain.state, "rebuild plain")
    }

    // MARK: Clean Up

    private struct BlockingCleanupEngine: CleanupRecipeEngine {
        let engineID = "blocking-test-engine"
        func canExecute(_ recipe: CleanupRecipe) -> Bool { true }
        func render(recipe: CleanupRecipe, source: CleanupSource, scratchDirectory: URL,
                    progress: @escaping @Sendable (CleanupProgress) -> Void) async throws -> URL {
            progress(CleanupProgress(phase: "Blocking render", fraction: 0.1))
            try await blockUntilCancelledThenThrow(GenericRenderError())
        }
    }

    @Test("cleanup: stall then Stop → Failed with the stall reason; plain stall → Failed", .timeLimit(.minutes(2)))
    func cleanupStallThenStop() async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let dir = try makeScratch("cleanup_stall")
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = try CleanupTestMedia.generate(
            into: dir, name: "test_cleanup_stall.mp4", duration: 1.0,
            size: "320x240", rate: "25", videoCodec: "libx264",
            extraVideoArgs: ["-preset", "ultrafast"], audioCodec: "aac")
        let model = VideoScanModel()
        let source = makeCleanupSourceRecord(path: src, durationSeconds: 1.0, fieldOrder: "tt")
        model.records = [source]

        let job = CleanupJob(record: source, recipe: CleanupRecipeRegistry.vhsQuickClean,
                             model: model, engine: BlockingCleanupEngine())
        job.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        job.handleStall(silentFor: 120)
        job.cancel()
        #expect(job.state == .running, "Stop after a stall must not become Cancelling")
        await job.task?.value
        expectStalledFailure(job.state, "cleanup")
        #expect(model.records.count == 1)

        let plain = CleanupJob(record: source, recipe: CleanupRecipeRegistry.vhsQuickClean,
                               model: model, engine: BlockingCleanupEngine())
        plain.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        plain.handleStall(silentFor: 120)
        await plain.task?.value
        expectStalledFailure(plain.state, "cleanup plain")
    }

    // MARK: Transcode / Reformat / Trim — stall fired before the run Task begins

    @Test("transcode: stall then Stop → Failed, no output; plain stall → Failed", .timeLimit(.minutes(2)))
    func transcodeStallThenStop() async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let dir = try makeScratch("transcode_stall")
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = try CleanupTestMedia.generate(
            into: dir, name: "test_transcode_stall.mp4", duration: 2.0,
            size: "320x240", rate: "25", videoCodec: "libx264",
            extraVideoArgs: ["-preset", "ultrafast"], audioCodec: "aac")
        let record = makeCleanupSourceRecord(path: src, durationSeconds: 2.0, fieldOrder: "progressive")
        let model = VideoScanModel()
        model.records = [record]

        let out = dir.appendingPathComponent("test_transcode_stall_out.mov")
        let job = TranscodeJob(record: record, preset: .editing, outputURL: out, model: model)
        job.start()
        job.handleStall(phase: "transcode encode", silentFor: 120)
        job.cancel()
        #expect(job.state == .running, "Stop after a stall must not become Cancelling")
        await job.task?.value
        expectStalledFailure(job.state, "transcode")
        #expect(!FileManager.default.fileExists(atPath: out.path))
        #expect(partialDebris(in: dir).isEmpty)
        #expect(model.records.count == 1)

        let out2 = dir.appendingPathComponent("test_transcode_stall_out2.mov")
        let plain = TranscodeJob(record: record, preset: .editing, outputURL: out2, model: model)
        plain.start()
        plain.handleStall(phase: "transcode encode", silentFor: 120)
        await plain.task?.value
        expectStalledFailure(plain.state, "transcode plain")
        #expect(!FileManager.default.fileExists(atPath: out2.path))
    }

    @Test("reformat: stall then Stop → Failed, no output; plain stall → Failed", .timeLimit(.minutes(2)))
    func reformatStallThenStop() async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let dir = try makeScratch("reformat_stall")
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = try CleanupTestMedia.generate(
            into: dir, name: "test_reformat_stall.mp4", duration: 2.0,
            size: "320x240", rate: "25", videoCodec: "libx264",
            extraVideoArgs: ["-preset", "ultrafast"], audioCodec: "aac")
        let record = makeCleanupSourceRecord(path: src, durationSeconds: 2.0, fieldOrder: "progressive")
        let model = VideoScanModel()
        model.records = [record]

        let job = ReformatJob(record: record, model: model, orchestrator: nil)
        job.start()
        job.handleStall(inputPath: src, silentFor: 120)
        job.cancel()
        #expect(job.state == .running, "Stop after a stall must not become Cancelling")
        await job.task?.value
        expectStalledFailure(job.state, "reformat")
        #expect(!FileManager.default.fileExists(atPath: job.outputURL.path))
        #expect(partialDebris(in: dir).isEmpty)

        let plain = ReformatJob(record: record, model: model, orchestrator: nil)
        plain.start()
        plain.handleStall(inputPath: src, silentFor: 120)
        await plain.task?.value
        expectStalledFailure(plain.state, "reformat plain")
        #expect(!FileManager.default.fileExists(atPath: plain.outputURL.path))
    }

    @Test("trim: stall then Stop → Failed, no output; Stop → Cancelled; plain stall → Failed", .timeLimit(.minutes(2)))
    func trimStallThenStopAndPlainStop() async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let dir = try makeScratch("trim_stall")
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = try CleanupTestMedia.generate(
            into: dir, name: "test_trim_stall.mp4", duration: 4.0,
            size: "320x240", rate: "25", videoCodec: "libx264",
            extraVideoArgs: ["-preset", "ultrafast"], audioCodec: "aac")
        let record = makeCleanupSourceRecord(path: src, durationSeconds: 4.0, fieldOrder: "progressive")
        let model = VideoScanModel()
        model.records = [record]

        let job = TrimJob(record: record, range: TrimRange(inSeconds: 1.0, outSeconds: 3.0), model: model)
        job.start()
        job.handleStall(silentFor: 120)
        job.cancel()
        #expect(job.state == .running, "Stop after a stall must not become Cancelling")
        await job.task?.value
        expectStalledFailure(job.state, "trim")
        #expect(!FileManager.default.fileExists(atPath: job.outputURL.path))
        #expect(partialDebris(in: dir).isEmpty)
        #expect(model.records.count == 1)

        // Regression (06b8ce2f shape for Trim): a plain Stop is Cancelled.
        let stopped = TrimJob(record: record, range: TrimRange(inSeconds: 1.0, outSeconds: 3.0), model: model)
        stopped.start()
        stopped.cancel()
        #expect(stopped.state == .cancelling)
        await stopped.task?.value
        #expect(stopped.state == .cancelled, "got \(stopped.state) — \(stopped.subtitle)")
        #expect(!FileManager.default.fileExists(atPath: stopped.outputURL.path))

        let plain = TrimJob(record: record, range: TrimRange(inSeconds: 1.0, outSeconds: 3.0), model: model)
        plain.start()
        plain.handleStall(silentFor: 120)
        await plain.task?.value
        expectStalledFailure(plain.state, "trim plain")
    }

    // MARK: Find Person — the finish ladder, no engine

    @Test func findPersonStallThenStopIsFailedAndStopThenErrorIsCancelled() {
        let model = VideoScanModel()
        let rec = VideoRecord()
        rec.filename = "test_find_stall.mov"
        rec.fullPath = "/Volumes/T/test_find_stall.mov"

        // Stall then Stop → the stall reason, never Cancelled.
        let job = FindPersonJob(person: "Donna", records: [rec], model: model)
        #expect(job.state == .running)
        job.handleStall(silentFor: 315)
        #expect(job.state == .running)
        job.cancel()
        #expect(job.state == .running, "Stop after a stall must not become Cancelling")
        job.finishRun(failure: nil)
        guard case .failed(let msg) = job.state else {
            Issue.record("find person: expected .failed, got \(job.state)"); return
        }
        #expect(msg.contains("recipe engine stalled"), "\(msg)")
        #expect(job.subtitle == msg)

        // Stop then a late engine error → Cancelled (06b8ce2f regression).
        let stopped = FindPersonJob(person: "Donna", records: [rec], model: model)
        stopped.cancel()
        #expect(stopped.state == .cancelling)
        stopped.finishRun(failure: "engine exited 1 while unwinding")
        #expect(stopped.state == .cancelled, "got \(stopped.state)")
        #expect(stopped.subtitle.hasPrefix("Cancelled"))

        // Plain stall → Failed.
        let plain = FindPersonJob(person: "Donna", records: [rec], model: model)
        plain.handleStall(silentFor: 315)
        plain.finishRun(failure: nil)
        if case .failed(let m) = plain.state { #expect(m.contains("stalled")) }
        else { Issue.record("find person plain stall: got \(plain.state)") }

        // A stall arriving AFTER the Stop is ignored — cancel owns it.
        let late = FindPersonJob(person: "Donna", records: [rec], model: model)
        late.cancel()
        late.handleStall(silentFor: 315)
        late.finishRun(failure: nil)
        #expect(late.state == .cancelled, "got \(late.state)")
    }
}
