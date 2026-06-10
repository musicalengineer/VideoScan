import Testing
import Foundation
@testable import VideoScan

// MARK: - ExtractFramesJob tests (phase 2, 2026-06-10)
//
// "Extract Frames…" migrated from its own modal sheet into the Media
// File Operations window. Coverage mirrors the phase-1 PairCompareJob
// suite in MediaFileOperationsTests.swift:
//
//   - State mapping from ripper state + the explicit wasCancelled flag
//     (never sniffed from statusText).
//   - Two-phase progress fraction (sampling 0…0.5, saving 0.5…1.0 —
//     carried over from the retired FrameRipperSheet).
//   - Center bookkeeping via startExtract (add, runningCount,
//     clearFinished, terminal state through the real task path).
//
// Per the project's safety-critical testing policy: positive AND
// negative coverage for each behavior. No real video decode here —
// the state machine is driven through the ripper's @Published fields
// (same technique as driving comparator.verdict in the compare tests);
// the one end-to-end test uses a missing file so the real task path
// fails fast (sub-second, no Vision model load).

@MainActor
@Suite("ExtractFramesJob state mapping")
struct ExtractFramesJobStateTests {

    private func makeJob(path: String = "/tmp/clip.mov") -> ExtractFramesJob {
        let rec = VideoRecord()
        rec.filename = (path as NSString).lastPathComponent
        rec.fullPath = path
        return ExtractFramesJob(
            record: rec,
            destinationParent: URL(fileURLWithPath: "/tmp", isDirectory: true),
            gates: [])
    }

    @Test func freshJobIsRunning() {
        let job = makeJob()
        #expect(job.state == .running)
        #expect(job.state.isActive)
        #expect(job.kind == .extract)
        #expect(job.title == "clip.mov")
    }

    @Test func destinationMapsToFinishedWithFrameCount() {
        let job = makeJob()
        job.ripper.framesSaved = 12
        job.ripper.completedDestination = URL(fileURLWithPath: "/tmp/clip-frames")
        #expect(job.state == .finished(summary: "12 frames saved"))
        #expect(!job.state.isActive)
    }

    @Test func singleFrameSummaryIsSingular() {
        let job = makeJob()
        job.ripper.framesSaved = 1
        job.ripper.completedDestination = URL(fileURLWithPath: "/tmp/clip-frames")
        #expect(job.state == .finished(summary: "1 frame saved"))
    }

    @Test func errorMapsToFailed() {
        let job = makeJob()
        job.ripper.lastError = "Zero-duration video."
        #expect(job.state == .failed(message: "Zero-duration video."))
    }

    // Negative: an error wins over a destination (e.g. folder created
    // but the rip then failed) — never report a failed rip as finished.
    @Test func errorWinsOverDestination() {
        let job = makeJob()
        job.ripper.completedDestination = URL(fileURLWithPath: "/tmp/clip-frames")
        job.ripper.lastError = "Couldn't read video"
        if case .failed = job.state {
            // expected
        } else {
            Issue.record("expected .failed, got \(job.state)")
        }
    }

    @Test func cancelWhileRipperRunningIsCancelling() {
        let job = makeJob()
        job.ripper.isRunning = true
        job.cancel()
        #expect(job.wasCancelled)
        #expect(job.state == .cancelling)
        #expect(job.state.isActive)   // still unwinding
        // ...and once the ripper's loop exits:
        job.ripper.isRunning = false
        #expect(job.state == .cancelled)
        #expect(!job.state.isActive)
    }

    @Test func cancelBeforeStartIsImmediatelyCancelled() {
        let job = makeJob()
        job.cancel()
        #expect(job.state == .cancelled)
    }

    // Cancel mid-save: the ripper sets completedDestination even when
    // cancelled (so Reveal works on the partial output) — the state
    // must still be .cancelled, and the subtitle must say the saved
    // frames were kept on disk.
    @Test func cancelMidSaveStaysCancelledAndNotesKeptFrames() {
        let job = makeJob()
        job.ripper.isRunning = true
        job.cancel()
        job.ripper.framesSaved = 7
        job.ripper.completedDestination = URL(fileURLWithPath: "/tmp/clip-frames")
        job.ripper.isRunning = false
        #expect(job.state == .cancelled)
        #expect(job.subtitle.contains("7"))
        #expect(job.subtitle.contains("kept"))
        #expect(job.subtitle.contains("clip-frames"))
    }

    // Negative: cancel with nothing saved says so.
    @Test func cancelWithNothingSavedSaysNoFrames() {
        let job = makeJob()
        job.cancel()
        #expect(job.subtitle == "Stopped — no frames saved")
    }

    // Negative: a success that landed before cancel wins — the work IS
    // done, and cancel() on a non-active job is a no-op.
    @Test func cancelAfterSuccessDoesNotOverrideFinished() {
        let job = makeJob()
        job.ripper.framesSaved = 30
        job.ripper.completedDestination = URL(fileURLWithPath: "/tmp/clip-frames")
        job.cancel()
        #expect(!job.wasCancelled)
        #expect(job.state == .finished(summary: "30 frames saved"))
    }

    @Test func extractPauseIsOffInPhaseTwo() {
        let job = makeJob()
        #expect(job.canPause == false)
        #expect(job.isPaused == false)
    }
}

// MARK: - Progress fraction

@MainActor
@Suite("ExtractFramesJob progress fraction")
struct ExtractFramesJobFractionTests {

    private func makeJob() -> ExtractFramesJob {
        let rec = VideoRecord()
        rec.filename = "clip.mov"
        rec.fullPath = "/tmp/clip.mov"
        return ExtractFramesJob(
            record: rec,
            destinationParent: URL(fileURLWithPath: "/tmp", isDirectory: true),
            gates: [])
    }

    // Before the duration probe sizes the candidate set, there is no
    // meaningful fraction — the row shows an indeterminate bar.
    @Test func indeterminateUntilCandidateTargetKnown() {
        let job = makeJob()
        #expect(job.isIndeterminate)
        job.ripper.candidateTarget = 60
        #expect(!job.isIndeterminate)
    }

    @Test func samplingPhaseFillsFirstHalf() {
        let job = makeJob()
        job.ripper.candidateTarget = 60
        job.ripper.saveTarget = 30
        job.ripper.framesScanned = 30
        #expect(abs(job.fraction - 0.25) < 0.0001)
        job.ripper.framesScanned = 60
        #expect(abs(job.fraction - 0.5) < 0.0001)
    }

    @Test func savingPhaseFillsSecondHalf() {
        let job = makeJob()
        job.ripper.candidateTarget = 60
        job.ripper.framesScanned = 60
        job.ripper.saveTarget = 30
        job.ripper.framesSaved = 15
        #expect(abs(job.fraction - 0.75) < 0.0001)
        job.ripper.framesSaved = 30
        #expect(abs(job.fraction - 1.0) < 0.0001)
    }

    // Negative: counters past their targets must not push the bar
    // beyond 1.0 (both halves clamp).
    @Test func fractionClampsAtOne() {
        let job = makeJob()
        job.ripper.candidateTarget = 10
        job.ripper.framesScanned = 25
        job.ripper.saveTarget = 10
        job.ripper.framesSaved = 25
        #expect(job.fraction <= 1.0)
    }
}

// MARK: - Center bookkeeping

@MainActor
@Suite("MediaFileOperationsCenter.startExtract")
struct StartExtractCenterTests {

    private func record(_ path: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (path as NSString).lastPathComponent
        r.fullPath = path
        return r
    }

    // End-to-end through the real task path: a missing source file
    // fails fast at the duration probe — no Vision, no decode, well
    // under a second.
    @Test func extractOnMissingFileRegistersAndFailsFast() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtractJobTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let missing = dir.appendingPathComponent("does-not-exist.mov").path
        let center = MediaFileOperationsCenter()
        let job = center.startExtract(record: record(missing),
                                      destinationParent: dir)
        #expect(center.jobs.first?.id == job.id)   // newest-first
        #expect(center.runningCount == 1)
        #expect(job.kind == .extract)

        await job.task?.value

        if case .failed = job.state {
            // expected — unreadable source
        } else {
            Issue.record("expected .failed, got \(job.state)")
        }
        #expect(center.runningCount == 0)

        // ...and clearFinished sweeps it like any other terminal job.
        center.clearFinished()
        #expect(center.jobs.isEmpty)
    }

    // Extract and compare jobs coexist in the same list (the whole
    // point of the single-window rule).
    @Test func extractAndCompareShareTheList() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtractJobTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let bytes = Data(repeating: 0x42, count: 16 * 1024)
        let a = dir.appendingPathComponent("a.bin").path
        let b = dir.appendingPathComponent("b.bin").path
        FileManager.default.createFile(atPath: a, contents: bytes)
        FileManager.default.createFile(atPath: b, contents: bytes)
        let missing = dir.appendingPathComponent("gone.mov").path

        let center = MediaFileOperationsCenter()
        let compare = center.startCompare(recordA: record(a), recordB: record(b))
        let extract = center.startExtract(record: record(missing),
                                          destinationParent: dir)
        #expect(center.jobs.map { $0.id } == [extract.id, compare.id])

        await compare.task?.value
        await extract.task?.value
        #expect(center.runningCount == 0)
    }
}
