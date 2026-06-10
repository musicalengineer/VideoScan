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
private final class FakeOperationJob: @MainActor MediaFileOperationJob {
    let id = UUID()
    let kind: MediaFileOperationKind
    let title: String
    var subtitle: String = ""
    var fraction: Double = 0
    var isIndeterminate = false
    let startedAt = Date()

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
        #expect(MediaFileOperationKind.extract.badgeText == "Extract")
    }

    @Test func badgeColorMapping() {
        #expect(MediaFileOperationKind.combine.badgeColor == .green)
        #expect(MediaFileOperationKind.compare.badgeColor == .blue)
        #expect(MediaFileOperationKind.extract.badgeColor == .orange)
    }

    // The verdict chip colors must keep matching the retired sheet's
    // palette (green/blue/orange/yellow).
    @Test func verdictChipColors() {
        #expect(PairCompareVerdict.exactDuplicates.displayColor == .green)
        #expect(PairCompareVerdict.sameContentDifferentContainer.displayColor == .blue)
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
