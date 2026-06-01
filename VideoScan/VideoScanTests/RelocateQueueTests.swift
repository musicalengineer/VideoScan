import Testing
import Foundation
@testable import VideoScan

// MARK: - RelocateQueueTests
//
// Coverage for the §3 Relocate Job Queue (docs/relocate_volume_plan.md):
// non-modal enqueue, serial execution, cancel-queued, clear-completed,
// summary-dismiss-advances-queue, isRelocating computed semantics.
//
// Hermetic — /tmp workspaces, never touches /Volumes or the real
// catalog dir. Pattern matches the other Relocate test suites.

@Suite(.serialized) @MainActor
struct RelocateQueueTests {

    // MARK: - Fixtures

    private static func makeWorkspace() throws -> (root: URL, source: URL, dest: URL, catalog: URL) {
        let root = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("vs-relocate-queue-\(UUID().uuidString)",
                                    isDirectory: true)
        let source = root.appendingPathComponent("source")
        let dest = root.appendingPathComponent("dest")
        let catalog = root.appendingPathComponent("catalog")
        let fm = FileManager.default
        for url in [source, dest, catalog] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return (root, source, dest, catalog)
    }

    @discardableResult
    private func writeFile(at url: URL, bytes: Int) throws -> (size: Int64, md5: String) {
        var buf = Data(count: bytes)
        for i in 0..<bytes { buf[i] = UInt8((i &* 17) % 251) }
        try buf.write(to: url)
        return (Int64(bytes), FileHasher.partialMD5(path: url.path))
    }

    private func makeRecord(fullPath: String, size: Int64, md5: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (fullPath as NSString).lastPathComponent
        r.fullPath = fullPath
        r.directory = (fullPath as NSString).deletingLastPathComponent
        r.sizeBytes = size
        r.partialMD5 = md5
        return r
    }

    /// Build a model with one tiny in-scope record and a destination.
    /// Returns the model plus the workspace so the caller can keep
    /// adding sources or destinations for multi-job tests.
    private func makeOneJobModel(
        ws: (root: URL, source: URL, dest: URL, catalog: URL)
    ) throws -> (model: VideoScanModel, src: URL, options: RelocateOptions) {
        let src = ws.source.appendingPathComponent("a-\(UUID().uuidString).bin")
        let (sa, ha) = try writeFile(at: src, bytes: 256)
        let rec = makeRecord(fullPath: src.path, size: sa, md5: ha)

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: ws.catalog)
        model.records = [rec]
        model.catalogStore.saveNow(records: model.records)

        let options = RelocateOptions(
            sourceVolumeRootPath: ws.source.path,
            destinationRoot: ws.dest,
            maxConcurrency: 1,
            dryRun: false,
            skipAlreadyRelocated: true
        )
        return (model, src, options)
    }

    /// Spin until `pendingRelocateSummary != nil` (the canonical
    /// "current job's work is done" signal under the queue). Mirrors
    /// the helper in the other Relocate test files.
    private func waitForCurrentJobDone(_ model: VideoScanModel,
                                        timeout: TimeInterval = 30) async {
        let deadline = Date().addingTimeInterval(timeout)
        while model.pendingRelocateSummary == nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    /// Spin until the job with `id` reaches the given status. Used to
    /// wait for queue-advance without depending on the current job's
    /// summary being still up.
    private func waitForJobStatus(_ model: VideoScanModel,
                                   id: UUID,
                                   _ predicate: @escaping @Sendable (RelocateJobStatus) -> Bool,
                                   timeout: TimeInterval = 30) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let j = model.relocateQueue.first(where: { $0.id == id }),
               predicate(j.status) {
                return
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    // MARK: - 1. enqueueRelocate_idle_immediatelyStartsTheJob

    @Test
    func enqueueRelocate_idle_immediatelyStartsTheJob() async throws {
        let ws = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }
        let (model, _, options) = try makeOneJobModel(ws: ws)

        let id = model.enqueueRelocate(
            sourceRootPath: options.sourceVolumeRootPath,
            destinationRoot: options.destinationRoot,
            options: options
        )
        let jobID = try #require(id)
        // The job's status flips synchronously on the same actor turn
        // (startNextQueuedJobIfIdle is called inline). It should be at
        // least .reconciling by the time enqueue returns. After the
        // first await we may see .copying or .awaitingDone.
        let initial = try #require(model.relocateQueue.first { $0.id == jobID })
        #expect(initial.status != .queued, "Idle enqueue should auto-start, not park as queued")

        await waitForCurrentJobDone(model)
        #expect(model.relocateQueue.first { $0.id == jobID }?.status == .awaitingDone)
        #expect(model.pendingRelocateSummary != nil)
    }

    // MARK: - 2. enqueueRelocate_busy_keepsJobInQueuedState

    @Test
    func enqueueRelocate_busy_keepsJobInQueuedState() async throws {
        let ws = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }
        let (model, _, optionsA) = try makeOneJobModel(ws: ws)

        // A second source dir so the two jobs don't collide in scope.
        let sourceB = ws.root.appendingPathComponent("source-b")
        try FileManager.default.createDirectory(at: sourceB, withIntermediateDirectories: true)
        let srcB = sourceB.appendingPathComponent("b.bin")
        let (sb, hb) = try writeFile(at: srcB, bytes: 512)
        model.records.append(makeRecord(fullPath: srcB.path, size: sb, md5: hb))

        // Fire A first, then B before A's summary lands.
        let aID = try #require(model.enqueueRelocate(
            sourceRootPath: optionsA.sourceVolumeRootPath,
            destinationRoot: optionsA.destinationRoot,
            options: optionsA
        ))
        let optionsB = RelocateOptions(
            sourceVolumeRootPath: sourceB.path,
            destinationRoot: ws.dest,
            maxConcurrency: 1,
            dryRun: false,
            skipAlreadyRelocated: true
        )
        let bID = try #require(model.enqueueRelocate(
            sourceRootPath: optionsB.sourceVolumeRootPath,
            destinationRoot: optionsB.destinationRoot,
            options: optionsB
        ))

        // B parks as .queued — A is still in flight.
        #expect(model.relocateQueue.first { $0.id == bID }?.status == .queued)
        #expect(model.relocateQueue.first { $0.id == aID }?.isInFlight == true)
        #expect(model.queuedCount == 1)
    }

    // MARK: - 3. firstJobCompletes_secondJobAutoStarts

    @Test
    func firstJobCompletes_secondJobAutoStarts() async throws {
        let ws = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }
        let (model, _, optionsA) = try makeOneJobModel(ws: ws)

        let sourceB = ws.root.appendingPathComponent("source-b")
        try FileManager.default.createDirectory(at: sourceB, withIntermediateDirectories: true)
        let srcB = sourceB.appendingPathComponent("b.bin")
        let (sb, hb) = try writeFile(at: srcB, bytes: 128)
        model.records.append(makeRecord(fullPath: srcB.path, size: sb, md5: hb))

        let aID = try #require(model.enqueueRelocate(
            sourceRootPath: optionsA.sourceVolumeRootPath,
            destinationRoot: optionsA.destinationRoot,
            options: optionsA
        ))
        let optionsB = RelocateOptions(
            sourceVolumeRootPath: sourceB.path,
            destinationRoot: ws.dest,
            maxConcurrency: 1,
            dryRun: false,
            skipAlreadyRelocated: true
        )
        let bID = try #require(model.enqueueRelocate(
            sourceRootPath: optionsB.sourceVolumeRootPath,
            destinationRoot: optionsB.destinationRoot,
            options: optionsB
        ))

        // Wait for A's summary, dismiss it. That fires queue-advance →
        // B should auto-start.
        await waitForCurrentJobDone(model)
        #expect(model.relocateQueue.first { $0.id == aID }?.status == .awaitingDone)
        model.acknowledgeRelocateSummary()
        #expect(model.relocateQueue.first { $0.id == aID }?.status == .complete)

        await waitForJobStatus(model, id: bID, { $0 != .queued })
        let bStatus = model.relocateQueue.first { $0.id == bID }?.status
        #expect(bStatus != .queued, "B did not auto-start after A's dismiss")

        // And B should run to summary too.
        await waitForCurrentJobDone(model)
        #expect(model.relocateQueue.first { $0.id == bID }?.status == .awaitingDone)
    }

    // MARK: - 4. cancelRelocateJob_queuedJob_removesIt

    @Test
    func cancelRelocateJob_queuedJob_marksItCanceled() async throws {
        let ws = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }
        let (model, _, optionsA) = try makeOneJobModel(ws: ws)

        let sourceB = ws.root.appendingPathComponent("source-b")
        try FileManager.default.createDirectory(at: sourceB, withIntermediateDirectories: true)
        let srcB = sourceB.appendingPathComponent("b.bin")
        let (sb, hb) = try writeFile(at: srcB, bytes: 128)
        model.records.append(makeRecord(fullPath: srcB.path, size: sb, md5: hb))

        _ = try #require(model.enqueueRelocate(
            sourceRootPath: optionsA.sourceVolumeRootPath,
            destinationRoot: optionsA.destinationRoot,
            options: optionsA
        ))
        let optionsB = RelocateOptions(
            sourceVolumeRootPath: sourceB.path,
            destinationRoot: ws.dest,
            maxConcurrency: 1,
            dryRun: false,
            skipAlreadyRelocated: true
        )
        let bID = try #require(model.enqueueRelocate(
            sourceRootPath: optionsB.sourceVolumeRootPath,
            destinationRoot: optionsB.destinationRoot,
            options: optionsB
        ))

        // B is queued while A runs. Cancel B.
        let canceled = model.cancelRelocateJob(id: bID)
        #expect(canceled == true)
        #expect(model.relocateQueue.first { $0.id == bID }?.status == .canceled)
        #expect(model.queuedCount == 0)
    }

    // MARK: - 5. cancelRelocateJob_runningJob_isNoOp

    @Test
    func cancelRelocateJob_runningJob_isNoOp() async throws {
        let ws = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }
        let (model, _, options) = try makeOneJobModel(ws: ws)

        let id = try #require(model.enqueueRelocate(
            sourceRootPath: options.sourceVolumeRootPath,
            destinationRoot: options.destinationRoot,
            options: options
        ))

        // Job is at least .reconciling now.
        let canceled = model.cancelRelocateJob(id: id)
        #expect(canceled == false, "v1 has no mid-run cancel")
        let status = model.relocateQueue.first { $0.id == id }?.status
        #expect(status != .canceled)

        // Let it complete cleanly so test cleanup doesn't strand
        // anything.
        await waitForCurrentJobDone(model)
        model.acknowledgeRelocateSummary()
    }

    // MARK: - 6. clearCompletedJobs

    @Test
    func clearCompletedJobs_removesCompleteFailedCanceled_keepsQueuedAndRunning() async throws {
        let ws = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }
        let (model, _, options) = try makeOneJobModel(ws: ws)

        // Job 1: complete. Run + acknowledge.
        let aID = try #require(model.enqueueRelocate(
            sourceRootPath: options.sourceVolumeRootPath,
            destinationRoot: options.destinationRoot,
            options: options
        ))
        await waitForCurrentJobDone(model)
        model.acknowledgeRelocateSummary()
        #expect(model.relocateQueue.first { $0.id == aID }?.status == .complete)

        // Job 2: canceled. Enqueue a second job while idle, but cancel
        // before it starts? Idle enqueue auto-starts — so we instead
        // hand-craft a .canceled entry via the public API path: enqueue
        // while busy, cancel before completion.
        //
        // Spin up B + C while A's already done (A=complete). B will
        // auto-start; C will be queued; cancel C.
        let sourceB = ws.root.appendingPathComponent("source-b")
        let sourceC = ws.root.appendingPathComponent("source-c")
        try FileManager.default.createDirectory(at: sourceB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceC, withIntermediateDirectories: true)
        let srcB = sourceB.appendingPathComponent("b.bin")
        let srcC = sourceC.appendingPathComponent("c.bin")
        let (sb, hb) = try writeFile(at: srcB, bytes: 128)
        let (sc, hc) = try writeFile(at: srcC, bytes: 128)
        model.records.append(makeRecord(fullPath: srcB.path, size: sb, md5: hb))
        model.records.append(makeRecord(fullPath: srcC.path, size: sc, md5: hc))

        let bID = try #require(model.enqueueRelocate(
            sourceRootPath: sourceB.path,
            destinationRoot: ws.dest,
            options: RelocateOptions(sourceVolumeRootPath: sourceB.path,
                                      destinationRoot: ws.dest,
                                      maxConcurrency: 1, dryRun: false,
                                      skipAlreadyRelocated: true)
        ))
        let cID = try #require(model.enqueueRelocate(
            sourceRootPath: sourceC.path,
            destinationRoot: ws.dest,
            options: RelocateOptions(sourceVolumeRootPath: sourceC.path,
                                      destinationRoot: ws.dest,
                                      maxConcurrency: 1, dryRun: false,
                                      skipAlreadyRelocated: true)
        ))
        // B is running, C is queued. Cancel C.
        #expect(model.cancelRelocateJob(id: cID) == true)
        // Queue now: A=.complete, B=running, C=.canceled.
        model.clearCompletedJobs()
        // After: A & C dropped, B retained.
        #expect(!model.relocateQueue.contains(where: { $0.id == aID }))
        #expect(!model.relocateQueue.contains(where: { $0.id == cID }))
        #expect(model.relocateQueue.contains(where: { $0.id == bID }))

        // Let B drain cleanly.
        await waitForCurrentJobDone(model)
        model.acknowledgeRelocateSummary()
    }

    // MARK: - 7. dismissingSummary_advancesQueue

    @Test
    func dismissingSummary_advancesQueue() async throws {
        let ws = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }
        let (model, _, optionsA) = try makeOneJobModel(ws: ws)

        let sourceB = ws.root.appendingPathComponent("source-b")
        try FileManager.default.createDirectory(at: sourceB, withIntermediateDirectories: true)
        let srcB = sourceB.appendingPathComponent("b.bin")
        let (sb, hb) = try writeFile(at: srcB, bytes: 128)
        model.records.append(makeRecord(fullPath: srcB.path, size: sb, md5: hb))

        _ = try #require(model.enqueueRelocate(
            sourceRootPath: optionsA.sourceVolumeRootPath,
            destinationRoot: optionsA.destinationRoot,
            options: optionsA
        ))
        let bID = try #require(model.enqueueRelocate(
            sourceRootPath: sourceB.path,
            destinationRoot: ws.dest,
            options: RelocateOptions(sourceVolumeRootPath: sourceB.path,
                                      destinationRoot: ws.dest,
                                      maxConcurrency: 1, dryRun: false,
                                      skipAlreadyRelocated: true)
        ))

        await waitForCurrentJobDone(model)
        // Pre-dismiss: B is still queued.
        #expect(model.relocateQueue.first { $0.id == bID }?.status == .queued)
        model.acknowledgeRelocateSummary()
        // Post-dismiss: B has advanced (some non-.queued state).
        await waitForJobStatus(model, id: bID, { $0 != .queued })
        let bStatus = model.relocateQueue.first { $0.id == bID }?.status
        #expect(bStatus != .queued, "B should have advanced after A's dismiss")

        // Drain B for cleanup.
        await waitForCurrentJobDone(model)
        model.acknowledgeRelocateSummary()
    }

    // MARK: - 8. isRelocatingComputed_returnsTrueWhileAnyJobInProgress

    @Test
    func isRelocatingComputed_returnsTrueWhileAnyJobInProgress() async throws {
        let ws = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }
        let (model, _, options) = try makeOneJobModel(ws: ws)

        #expect(model.isRelocating == false)
        _ = try #require(model.enqueueRelocate(
            sourceRootPath: options.sourceVolumeRootPath,
            destinationRoot: options.destinationRoot,
            options: options
        ))
        // Immediately after enqueue the runner has flipped to
        // .reconciling — isRelocating is true.
        #expect(model.isRelocating == true)

        await waitForCurrentJobDone(model)
        // .awaitingDone still counts as in-flight per spec.
        #expect(model.isRelocating == true)
        model.acknowledgeRelocateSummary()
        #expect(model.isRelocating == false)
    }

    // MARK: - 9. summaryPersistsOnJobAfterCompletion

    @Test
    func summaryPersistsOnJobAfterCompletion() async throws {
        let ws = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }
        let (model, _, options) = try makeOneJobModel(ws: ws)

        let id = try #require(model.enqueueRelocate(
            sourceRootPath: options.sourceVolumeRootPath,
            destinationRoot: options.destinationRoot,
            options: options
        ))
        await waitForCurrentJobDone(model)
        let beforeDismiss = try #require(model.relocateQueue.first { $0.id == id })
        #expect(beforeDismiss.summary != nil)
        #expect(beforeDismiss.summary?.succeededCount == 1)

        model.acknowledgeRelocateSummary()
        let afterDismiss = try #require(model.relocateQueue.first { $0.id == id })
        #expect(afterDismiss.status == .complete)
        #expect(afterDismiss.summary != nil, "Summary should survive dismissal so the panel's Show summary works")
        #expect(afterDismiss.summary?.succeededCount == 1)
    }

    // MARK: - 10. Notification body formatter (pure)

    @Test
    func notificationBody_formatsSucceededAndElapsed() {
        // Build a complete job by hand so we can drive the formatter
        // without spinning up the full pipeline. The formatter is
        // nonisolated static — pure dependency on the job struct.
        let summary = RelocateSummary(
            isDryRun: false,
            sourceVolumeName: "Maxtor500FW",
            sourceVolumeRootPath: "/Volumes/Maxtor500FW",
            destinationDisplay: "LaCie/from-Maxtor",
            destinationRootPath: "/Volumes/LaCie/from-Maxtor",
            succeededCount: 161,
            bytesCopied: 0,
            adoptedCount: 0,
            safelyRedundantCount: 264,
            safelyRedundantBytes: 0,
            sourceMovesCount: 0,
            manuallyDeletedCount: 0,
            salvageFailedCount: 0,
            skippedCount: 0,
            safelyBackedUpCount: 264,
            degradedOnlyCount: 0,
            salvageFailedPaths: [],
            witnessSamples: [],
            elapsedSeconds: 800,
            averageMBps: 0,
            snapshotPath: nil
        )
        let job = RelocateQueuedJob(
            sourceVolumeRootPath: "/Volumes/Maxtor500FW",
            sourceVolumeName: "Maxtor500FW",
            destinationRoot: URL(fileURLWithPath: "/Volumes/LaCie/from-Maxtor"),
            options: RelocateOptions(
                sourceVolumeRootPath: "/Volumes/Maxtor500FW",
                destinationRoot: URL(fileURLWithPath: "/Volumes/LaCie/from-Maxtor")
            ),
            startedAt: Date(timeIntervalSinceReferenceDate: 0),
            completedAt: Date(timeIntervalSinceReferenceDate: 780),
            status: .complete,
            summary: summary
        )
        let title = VideoScanModel.notificationTitle(for: job)
        let body  = VideoScanModel.notificationBody(for: job)
        #expect(title == "Migrate done: Maxtor500FW")
        #expect(body.contains("161 copied"))
        #expect(body.contains("264 safely backed up"))
        #expect(body.contains("13m"))
    }

    @Test
    func notificationTitle_failedJob() {
        let job = RelocateQueuedJob(
            sourceVolumeRootPath: "/Volumes/Bad",
            sourceVolumeName: "Bad",
            destinationRoot: URL(fileURLWithPath: "/tmp"),
            options: RelocateOptions(
                sourceVolumeRootPath: "/Volumes/Bad",
                destinationRoot: URL(fileURLWithPath: "/tmp")
            ),
            status: .failed(reason: "disk full")
        )
        #expect(VideoScanModel.notificationTitle(for: job) == "Migrate failed: Bad")
        #expect(VideoScanModel.notificationBody(for: job) == "disk full")
    }
}
