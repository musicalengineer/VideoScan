import Testing
import Combine
import SwiftUI
import Foundation
@testable import VideoScan

// MARK: - Media File Operations tests (2026-06-10)
//
// Phase 1 of the Media File Operations window:
//
//   - MediaFileOperationsCenter — list registry (newest-first ordering,
//     finished cap, runningCount, clearFinished).
//   - PairCompareJob — state mapping from comparator state + the
//     explicit wasCancelled flag (never sniffed from statusText).
//   - MediaVolumeGatePolicy — PURE per-volume slot policy (HDD=1,
//     SSD/internal unrestricted, unclassified=2). Injected mediaTech —
//     no real volumes touched.
//   - Badge/kind mapping for the row UI.
//
// Per the project's safety-critical testing policy: positive AND
// negative coverage for each behavior.

// MARK: - Fake job

/// Minimal protocol conformer so center list tests don't need real
/// comparisons. State is settable so tests can flip running→finished.
@MainActor
private final class FakeOperationJob: MediaFileOperationJob {
    let id = UUID()
    let kind: MediaFileOperationKind
    let title: String
    var subtitle: String = ""
    var fraction: Double = 0
    var isIndeterminate = false
    let startedAt = Date()
    var finishedAt: Date?

    @Published var settableState: MediaFileOperationState
    var state: MediaFileOperationState { settableState }

    var cancelCallCount = 0

    init(kind: MediaFileOperationKind = .compare,
         title: String = "fake",
         state: MediaFileOperationState = .running) {
        self.kind = kind
        self.title = title
        self.settableState = state
    }

    func cancel() {
        cancelCallCount += 1
        settableState = .cancelled
    }
}

// MARK: - Center list logic

@MainActor
@Suite("MediaFileOperationsCenter list logic")
struct MediaFileOperationsCenterTests {

    @Test func jobsAreNewestFirst() {
        let center = MediaFileOperationsCenter()
        let first = FakeOperationJob(title: "first")
        let second = FakeOperationJob(title: "second")
        let third = FakeOperationJob(title: "third")
        center.add(first)
        center.add(second)
        center.add(third)
        #expect(center.jobs.map { $0.id } == [third.id, second.id, first.id])
    }

    @Test func runningCountCountsOnlyActiveStates() {
        let center = MediaFileOperationsCenter()
        center.add(FakeOperationJob(state: .running))
        center.add(FakeOperationJob(state: .cancelling))   // active too
        center.add(FakeOperationJob(state: .finished(summary: "ok")))
        center.add(FakeOperationJob(state: .failed(message: "boom")))
        center.add(FakeOperationJob(state: .cancelled))
        #expect(center.runningCount == 2)
    }

    @Test func clearFinishedKeepsActiveJobs() {
        let center = MediaFileOperationsCenter()
        let running = FakeOperationJob(state: .running)
        center.add(FakeOperationJob(state: .finished(summary: "done")))
        center.add(running)
        center.add(FakeOperationJob(state: .cancelled))
        center.clearFinished()
        #expect(center.jobs.count == 1)
        #expect(center.jobs.first?.id == running.id)
    }

    // Negative: clearFinished on an all-active list removes nothing.
    @Test func clearFinishedIsNoOpWhenAllActive() {
        let center = MediaFileOperationsCenter()
        center.add(FakeOperationJob(state: .running))
        center.add(FakeOperationJob(state: .running))
        center.clearFinished()
        #expect(center.jobs.count == 2)
    }

    @Test func finishedJobsAreCappedAtFifty() {
        let center = MediaFileOperationsCenter()
        for i in 0..<60 {
            center.add(FakeOperationJob(title: "job\(i)",
                                        state: .finished(summary: "ok")))
        }
        #expect(center.jobs.count == MediaFileOperationsCenter.finishedCap)
        // Newest survive — the last-added job is still at the front.
        #expect(center.jobs.first?.title == "job59")
        // Oldest were dropped.
        #expect(!center.jobs.contains(where: { $0.title == "job0" }))
    }

    @Test func capDoesNotEvictActiveJobs() {
        let center = MediaFileOperationsCenter()
        let running = FakeOperationJob(title: "long-runner", state: .running)
        center.add(running)
        for i in 0..<60 {
            center.add(FakeOperationJob(title: "job\(i)",
                                        state: .finished(summary: "ok")))
        }
        // 50 finished + the active one, which must never be trimmed.
        #expect(center.jobs.count == MediaFileOperationsCenter.finishedCap + 1)
        #expect(center.jobs.contains(where: { $0.id == running.id }))
    }

    @Test func cancelAllReachesOnlyActiveJobs() {
        let center = MediaFileOperationsCenter()
        let active = FakeOperationJob(state: .running)
        let done = FakeOperationJob(state: .finished(summary: "ok"))
        center.add(active)
        center.add(done)
        center.cancelAll()
        #expect(active.cancelCallCount == 1)
        #expect(done.cancelCallCount == 0)
        #expect(center.runningCount == 0)
    }
}

// MARK: - PairCompareJob state mapping

@MainActor
@Suite("PairCompareJob state mapping")
struct PairCompareJobStateTests {

    private func makeJob(pathA: String = "/tmp/a.mov",
                         pathB: String = "/tmp/b.mov") -> PairCompareJob {
        let a = VideoRecord()
        a.filename = "a.mov"
        a.fullPath = pathA
        let b = VideoRecord()
        b.filename = "b.mov"
        b.fullPath = pathB
        return PairCompareJob(recordA: a, recordB: b, gates: [])
    }

    @Test func freshJobIsRunning() {
        let job = makeJob()
        #expect(job.state == .running)
        #expect(job.state.isActive)
        #expect(job.kind == .compare)
    }

    @Test func verdictMapsToFinishedWithTitleSummary() {
        let job = makeJob()
        job.comparator.verdict = .exactDuplicates
        #expect(job.state == .finished(summary: PairCompareVerdict.exactDuplicates.title))
        #expect(!job.state.isActive)
    }

    @Test func errorMapsToFailed() {
        let job = makeJob()
        job.comparator.lastError = "Couldn't read \"a.mov\""
        #expect(job.state == .failed(message: "Couldn't read \"a.mov\""))
    }

    @Test func cancelWhileComparatorRunningIsCancelling() {
        let job = makeJob()
        job.comparator.isRunning = true
        job.cancel()
        #expect(job.wasCancelled)
        #expect(job.state == .cancelling)
        #expect(job.state.isActive)   // still unwinding
        // ...and once the comparator's run loop exits:
        job.comparator.isRunning = false
        #expect(job.state == .cancelled)
        #expect(!job.state.isActive)
    }

    @Test func cancelBeforeStartIsImmediatelyCancelled() {
        let job = makeJob()
        job.cancel()
        #expect(job.state == .cancelled)
    }

    // Negative: a verdict that landed before cancel wins — the work IS
    // done, and cancel() on a non-active job is a no-op.
    @Test func cancelAfterVerdictDoesNotOverrideFinished() {
        let job = makeJob()
        job.comparator.verdict = .differentMedia
        job.cancel()
        #expect(!job.wasCancelled)
        #expect(job.state == .finished(summary: PairCompareVerdict.differentMedia.title))
    }

    @Test func comparePauseIsOffInPhaseOne() {
        let job = makeJob()
        #expect(job.canPause == false)
        #expect(job.isPaused == false)
    }

    @Test func titleJoinsBothFilenames() {
        let job = makeJob()
        #expect(job.title == "a.mov vs b.mov")
    }

    // MARK: End-to-end: two concurrent jobs reach terminal states
    // independently. Pair 1 is two byte-identical temp files (Tier 1
    // verdict — no ffmpeg needed); pair 2 references a missing file
    // (Tier 0 stat failure). Both run at once through the center.
    @Test func twoConcurrentJobsReachTerminalStatesIndependently() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaFileOpsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let bytes = Data(repeating: 0x42, count: 64 * 1024)
        let dupA = dir.appendingPathComponent("dupA.bin").path
        let dupB = dir.appendingPathComponent("dupB.bin").path
        FileManager.default.createFile(atPath: dupA, contents: bytes)
        FileManager.default.createFile(atPath: dupB, contents: bytes)

        let present = dir.appendingPathComponent("present.bin").path
        FileManager.default.createFile(atPath: present, contents: bytes)
        let missing = dir.appendingPathComponent("does-not-exist.bin").path

        func record(_ path: String) -> VideoRecord {
            let r = VideoRecord()
            r.filename = (path as NSString).lastPathComponent
            r.fullPath = path
            return r
        }

        let center = MediaFileOperationsCenter()
        let dupJob = center.startCompare(recordA: record(dupA),
                                         recordB: record(dupB))
        let failJob = center.startCompare(recordA: record(present),
                                          recordB: record(missing))
        #expect(center.runningCount == 2)

        await dupJob.task?.value
        await failJob.task?.value

        #expect(dupJob.state == .finished(summary: PairCompareVerdict.exactDuplicates.title))
        if case .failed = failJob.state {
            // expected
        } else {
            Issue.record("expected .failed, got \(failJob.state)")
        }
        #expect(center.runningCount == 0)
        // Newest-first: the second-started job is the first row.
        #expect(center.jobs.map { $0.id } == [failJob.id, dupJob.id])
    }
}

// MARK: - Per-volume gate policy (pure)

@Suite("MediaVolumeGatePolicy")
struct MediaVolumeGatePolicyTests {

    @Test func hddAllowsExactlyOneReader() {
        #expect(MediaVolumeGatePolicy.compareSlots(mediaTech: .hdd,
                                                   isInternalPath: false) == 1)
    }

    @Test func ssdIsUnrestricted() {
        #expect(MediaVolumeGatePolicy.compareSlots(mediaTech: .ssd,
                                                   isInternalPath: false) == nil)
    }

    // Internal paths are unrestricted regardless of classification —
    // even a (mis)classified HDD tech on an internal path.
    @Test func internalPathIsUnrestricted() {
        for tech in VolumeMediaTech.allCases {
            #expect(MediaVolumeGatePolicy.compareSlots(mediaTech: tech,
                                                       isInternalPath: true) == nil)
        }
    }

    @Test func unclassifiedAllowsTwo() {
        #expect(MediaVolumeGatePolicy.compareSlots(mediaTech: .unknown,
                                                   isInternalPath: false) == 2)
    }

    @Test func networkAndCloudAreGentle() {
        #expect(MediaVolumeGatePolicy.compareSlots(mediaTech: .network,
                                                   isInternalPath: false) == 2)
        #expect(MediaVolumeGatePolicy.compareSlots(mediaTech: .cloud,
                                                   isInternalPath: false) == 2)
    }

    @Test func raidVariantsFallBackToTwo() {
        for tech: VolumeMediaTech in [.raid0, .raid1, .raid5, .raid10] {
            #expect(MediaVolumeGatePolicy.compareSlots(mediaTech: tech,
                                                       isInternalPath: false) == 2)
        }
    }

    @Test func volumeRootForExternalPath() {
        #expect(MediaVolumeGatePolicy.volumeRoot(
            forPath: "/Volumes/MyBook3Terabytes/family/tape7.mxf")
            == "/Volumes/MyBook3Terabytes")
    }

    @Test func volumeRootForInternalPath() {
        #expect(MediaVolumeGatePolicy.volumeRoot(
            forPath: "/Users/rickb/Movies/clip.mov") == "/")
    }

    // Negative: a bare "/Volumes/" prefix with no volume name must not
    // produce a bogus root.
    @Test func volumeRootForBareVolumesPath() {
        #expect(MediaVolumeGatePolicy.volumeRoot(forPath: "/Volumes/") == "/")
    }
}

// MARK: - Badge / kind mapping

@Suite("MediaFileOperationKind badges")
struct MediaFileOperationKindTests {

    @Test func badgeTextMapping() {
        #expect(MediaFileOperationKind.combine.badgeText == "Combine")
        #expect(MediaFileOperationKind.compare.badgeText == "Compare")
        // Verb split 2026-06-10: .extract (Vision facial rip) says
        // "Faces" so it reads distinctly next to .ripFrames "Frames".
        #expect(MediaFileOperationKind.extract.badgeText == "Faces")
        #expect(MediaFileOperationKind.ripFrames.badgeText == "Frames")
    }

    @Test func badgeColorMapping() {
        #expect(MediaFileOperationKind.combine.badgeColor == .green)
        #expect(MediaFileOperationKind.compare.badgeColor == .blue)
        #expect(MediaFileOperationKind.extract.badgeColor == .orange)
        #expect(MediaFileOperationKind.ripFrames.badgeColor == .purple)
    }

    // The verdict chip colors must keep matching the retired sheet's
    // palette (green/blue/orange/yellow), plus teal for the perceptual
    // verdict — meaning-wise it sits between blue (packet-identical)
    // and orange (different).
    @Test func verdictChipColors() {
        #expect(PairCompareVerdict.exactDuplicates.displayColor == .green)
        #expect(PairCompareVerdict.sameContentDifferentContainer.displayColor == .blue)
        #expect(PairCompareVerdict.samePerceptualContent.displayColor == .teal)
        #expect(PairCompareVerdict.differentMedia.displayColor == .orange)
        #expect(PairCompareVerdict.sameFile.displayColor == .yellow)
    }
}

// MARK: - State helper

@Suite("MediaFileOperationState.isActive")
struct MediaFileOperationStateTests {

    @Test func activeStates() {
        #expect(MediaFileOperationState.running.isActive)
        #expect(MediaFileOperationState.cancelling.isActive)
    }

    @Test func terminalStates() {
        #expect(!MediaFileOperationState.finished(summary: "ok").isActive)
        #expect(!MediaFileOperationState.failed(message: "x").isActive)
        #expect(!MediaFileOperationState.cancelled.isActive)
    }
}

// MARK: - Duration clock (regression 2026-07-07)
//
// Bug: the operations window rendered `Text(job.startedAt, style:
// .relative)` on EVERY row regardless of state — a self-updating
// counter that never stops, so a 5-minute job read "45 min" when
// glanced at 40 minutes later. Fix: jobs stamp `finishedAt` at their
// terminal transition and `MediaFileOperationClock` freezes the
// duration there. The clock is PURE (injected `now`) so these tests
// evaluate it at a simulated wall-clock 40+ minutes after completion.

@Suite("MediaFileOperationClock — duration freezing")
struct MediaFileOperationClockTests {

    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// The exact bug report: a 5-minute job read 40 minutes later must
    /// say 5 minutes, not 45.
    @Test func finishedJobReadsRunDurationNotWallClock() {
        let d = MediaFileOperationClock.duration(
            state: .finished(summary: "ok"),
            startedAt: t0,
            finishedAt: t0.addingTimeInterval(300),
            at: t0.addingTimeInterval(2700))
        #expect(d == 300)
    }

    @Test func failedJobDurationIsFrozen() {
        let d = MediaFileOperationClock.duration(
            state: .failed(message: "boom"),
            startedAt: t0,
            finishedAt: t0.addingTimeInterval(42),
            at: t0.addingTimeInterval(2700))
        #expect(d == 42)
    }

    @Test func cancelledJobDurationIsFrozen() {
        let d = MediaFileOperationClock.duration(
            state: .cancelled,
            startedAt: t0,
            finishedAt: t0.addingTimeInterval(7),
            at: t0.addingTimeInterval(2700))
        #expect(d == 7)
    }

    // Positive counterpart: ACTIVE jobs keep ticking live.
    @Test func runningJobTicksLive() {
        let d = MediaFileOperationClock.duration(
            state: .running, startedAt: t0, finishedAt: nil,
            at: t0.addingTimeInterval(120))
        #expect(d == 120)
    }

    /// `.cancelling` is still active (task unwinding) — live clock.
    @Test func cancellingJobTicksLive() {
        let d = MediaFileOperationClock.duration(
            state: .cancelling, startedAt: t0, finishedAt: nil,
            at: t0.addingTimeInterval(65))
        #expect(d == 65)
    }

    // Negative: clock skew / bad stamp must never show a negative
    // duration.
    @Test func negativeIntervalsClampToZero() {
        #expect(MediaFileOperationClock.duration(
            state: .running, startedAt: t0, finishedAt: nil,
            at: t0.addingTimeInterval(-5)) == 0)
        #expect(MediaFileOperationClock.duration(
            state: .cancelled, startedAt: t0,
            finishedAt: t0.addingTimeInterval(-5),
            at: t0.addingTimeInterval(2700)) == 0)
    }

    @Test func formatMatchesCombineSectionShape() {
        #expect(MediaFileOperationClock.format(5) == "5s")
        #expect(MediaFileOperationClock.format(312) == "5m 12s")
        #expect(MediaFileOperationClock.format(3900) == "1h 5m")
    }

    @Test func textFormatsFrozenTerminalDuration() {
        let s = MediaFileOperationClock.text(
            state: .finished(summary: "ok"),
            startedAt: t0,
            finishedAt: t0.addingTimeInterval(312),
            at: t0.addingTimeInterval(2700))
        #expect(s == "5m 12s")
    }
}

// MARK: - finishedAt stamping (regression 2026-07-07, model side)
//
// The clock can only freeze if every conformer actually stamps
// `finishedAt` at its terminal transition — including jobs that were
// already terminal before the window ever rendered (the stamp lives in
// the MODEL, not the view, precisely for that case).

@MainActor
@Suite("MediaFileOperationJob finishedAt stamping")
struct MediaFileOperationFinishedAtTests {

    private func record(_ path: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (path as NSString).lastPathComponent
        r.fullPath = path
        return r
    }

    /// Derived-state job (PairCompareJob) run to a REAL `.finished`
    /// via two byte-identical temp files (Tier 1 — no ffmpeg), then
    /// the duration is read at a simulated now 40 minutes later: it
    /// must equal the stamped run duration, not the inflated one.
    @Test func compareJobStampsFinishedAtAndClockFreezes() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MFOClockTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data(repeating: 0x42, count: 64 * 1024)
        let a = dir.appendingPathComponent("a.bin").path
        let b = dir.appendingPathComponent("b.bin").path
        FileManager.default.createFile(atPath: a, contents: bytes)
        FileManager.default.createFile(atPath: b, contents: bytes)

        let job = PairCompareJob(recordA: record(a), recordB: record(b),
                                 gates: [])
        job.start()
        await job.task?.value

        #expect(!job.state.isActive)
        let stamped = try #require(job.finishedAt)
        let runDuration = stamped.timeIntervalSince(job.startedAt)
        #expect(runDuration >= 0)
        #expect(runDuration < 60)   // a 64 KB Tier-1 compare is seconds at most

        // Glance 40 minutes later — the row must still read the run
        // duration.
        let later = stamped.addingTimeInterval(2400)
        let shown = MediaFileOperationClock.duration(
            state: job.state, startedAt: job.startedAt,
            finishedAt: job.finishedAt, at: later)
        #expect(shown == runDuration)
    }

    /// Derived-state job driven to `.failed` (missing file, Tier 0
    /// stat failure) — the failure path must stamp too.
    @Test func compareJobStampsFinishedAtOnFailure() async throws {
        let missing = "/tmp/MFOClockTests-\(UUID().uuidString)-missing.bin"
        let job = PairCompareJob(recordA: record(missing),
                                 recordB: record(missing + "2"),
                                 gates: [])
        job.start()
        await job.task?.value
        if case .failed = job.state {
            #expect(job.finishedAt != nil)
        } else {
            Issue.record("expected .failed, got \(job.state)")
        }
    }

    /// Cancelled BEFORE start(): the job is terminal instantly and no
    /// run Task will ever end — cancel() itself must stamp, otherwise
    /// finishedAt stays nil and the clock would fall back to "now".
    @Test func compareJobCancelledBeforeStartStampsFinishedAt() {
        let job = PairCompareJob(recordA: record("/tmp/x.mov"),
                                 recordB: record("/tmp/y.mov"),
                                 gates: [])
        job.cancel()
        #expect(job.state == .cancelled)
        #expect(job.finishedAt != nil)
    }

    @Test func extractJobCancelledBeforeStartStampsFinishedAt() {
        let job = ExtractFramesJob(record: record("/tmp/x.mov"),
                                   destinationParent: FileManager.default.temporaryDirectory,
                                   gates: [])
        job.cancel()
        #expect(job.state == .cancelled)
        #expect(job.finishedAt != nil)
    }

    @Test func ripAllFramesJobCancelledBeforeStartStampsFinishedAt() {
        let job = RipAllFramesJob(record: record("/tmp/x.mov"),
                                  destinationParent: FileManager.default.temporaryDirectory,
                                  gates: [],
                                  options: AllFramesRipper.Options())
        job.cancel()
        #expect(job.state == .cancelled)
        #expect(job.finishedAt != nil)
    }

    /// Stored-state job (TranscodeJob — same `didSet` hook as
    /// Reformat/Analyze/Cleanup): a missing source fails fast, before
    /// any ffmpeg launch, and the terminal transition must stamp. The
    /// frozen reading at +40 min pins the didSet path end-to-end.
    @Test func transcodeJobStampsFinishedAtOnFailure() async throws {
        let missing = "/tmp/MFOClockTests-\(UUID().uuidString)-missing.mov"
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("MFOClockTests-\(UUID().uuidString).mov")
        let job = TranscodeJob(record: record(missing),
                               preset: .editing,
                               outputURL: out,
                               model: VideoScanModel())
        job.start()
        await job.task?.value

        if case .failed = job.state {
            let stamped = try #require(job.finishedAt)
            let later = stamped.addingTimeInterval(2400)
            let shown = MediaFileOperationClock.duration(
                state: job.state, startedAt: job.startedAt,
                finishedAt: job.finishedAt, at: later)
            #expect(shown == stamped.timeIntervalSince(job.startedAt))
        } else {
            Issue.record("expected .failed, got \(job.state)")
        }
    }

    /// Stored-state job #2 (ReformatJob — identical `didSet` hook):
    /// missing source fails fast before ffmpeg; the terminal
    /// transition must stamp.
    @Test func reformatJobStampsFinishedAtOnFailure() async throws {
        let missing = "/tmp/MFOClockTests-\(UUID().uuidString)-missing.mov"
        let job = ReformatJob(record: record(missing),
                              model: VideoScanModel(),
                              orchestrator: nil)
        job.start()
        await job.task?.value

        if case .failed = job.state {
            #expect(job.finishedAt != nil)
        } else {
            Issue.record("expected .failed, got \(job.state)")
        }
    }

    /// Stored-state job #3 (CleanupJob — identical `didSet` hook):
    /// missing source fails fast at the early guard; stamp must fire
    /// there too. (AnalyzeJob shares the same one-line didSet but
    /// needs a live CaptionOrchestrator to run — the compiler-enforced
    /// protocol member plus these three siblings pin the pattern.)
    @Test func cleanupJobStampsFinishedAtOnFailure() async throws {
        let missing = "/tmp/MFOClockTests-\(UUID().uuidString)-missing.mov"
        let source = makeCleanupSourceRecord(path: missing,
                                             durationSeconds: 0,
                                             fieldOrder: "tt")
        let job = CleanupJob(record: source,
                             recipe: CleanupRecipeRegistry.vhsQuickClean,
                             model: VideoScanModel())
        job.start()
        await job.task?.value

        if case .failed = job.state {
            #expect(job.finishedAt != nil)
        } else {
            Issue.record("expected .failed, got \(job.state)")
        }
    }
}
