// ArchiveAngelSeamScopeTests.swift
// The two Archive Angel test seams are task-local since 2026-11-21 (they
// were process-global statics, which forced ArchiveAngelWholeJobTests
// `.serialized` and made every Clear probe filter by folder):
//
//   ArchiveAngelPlanWriter.injectedFailure   plan.json "disk full" fault
//   ArchiveAngelClearSeam.diskProbe          Clear's off-main disk phases
//
// What is proven here:
//   - parallel tests with DIFFERENT bindings (and tests with none) never
//     see each other's, through the one shared writer and the real Clear;
//   - the fault still reaches a save the job performs in a DETACHED task
//     (capture-and-pass), exactly as the global did;
//   - unbound, nothing is injected and nothing is probed.
// The source half (no app source binds either; the globals are gone) is
// in GlobalTestHookRetiredSensorTests.
//
// (C++: `@TaskLocal` is a thread_local that follows the coroutine and its
// children; `$name.withValue(x) { … }` is the RAII scope that installs it.)

import Foundation
import os
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Archive Angel seams — a binding belongs to its own task tree")
struct ArchiveAngelSeamScopeTests {

    /// Every case's batch folder carries this token and every bound case's
    /// fault matches ON it, so a fault that leaked would hit every other
    /// case's batch.
    private static let sharedToken = "angel-seam-scope"

    private static func batchDir(_ id: Int) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_\(sharedToken)_\(id)_\(UUID().uuidString.prefix(8))", isDirectory: true)
            .appendingPathComponent("batch-\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Plan writer fault

    /// 24 cases at once through `ArchiveAngelPlanWriter.shared`. Case n
    /// binds "fail after n % 4 writes" for ANY batch whose path holds the
    /// shared token; every third case binds nothing. Each sees exactly its
    /// own number of good writes.
    @Test("24 concurrent plan-writer cases: each fails after exactly its own count; an unbound case never fails",
          arguments: 0..<24)
    func planWriterFaultIsPerTaskTree(_ id: Int) async throws {
        let dir = try Self.batchDir(id)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let plan = ArchiveAngelPlan(batchDir: dir.path, requestedCount: 1, makeLossless: false, entries: [])
        let bound = id % 3 != 0
        let allowed = id % 4

        func writesUntilFailure() async -> Int {
            var good = 0
            for generation in 1...6 {
                do {
                    _ = try await ArchiveAngelPlanWriter.shared.write(plan, generation: UInt64(generation))
                    good += 1
                } catch { break }
                await Task.yield()   // let the other cases interleave
            }
            return good
        }

        if bound {
            let fault = ArchiveAngelPlanWriter.InjectedFailure(batchNameContains: Self.sharedToken, afterWrites: allowed)
            let good = await ArchiveAngelPlanWriter.$injectedFailure.withValue(fault) { await writesUntilFailure() }
            #expect(good == allowed, "case \(id) bound \(allowed) good writes and saw \(good)")
            #expect(ArchiveAngelPlanWriter.injectedFailure == nil, "the binding outlived its scope")
        } else {
            #expect(ArchiveAngelPlanWriter.injectedFailure == nil, "another case's fault is visible here")
            #expect(await writesUntilFailure() == 6, "an unbound case was failed by another case's fault")
        }
    }

    /// The fault is read by the CALLER of `write`: a child task sees its
    /// parent's, a detached task sees none unless the value is handed in.
    @Test func theFaultReachesChildTasksAndIsHandedAcrossADetach() async throws {
        let dir = try Self.batchDir(100)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let plan = ArchiveAngelPlan(batchDir: dir.path, requestedCount: 1, makeLossless: false, entries: [])
        let fault = ArchiveAngelPlanWriter.InjectedFailure(batchNameContains: dir.path, afterWrites: 0)
        let writer = ArchiveAngelPlanWriter()

        try await ArchiveAngelPlanWriter.$injectedFailure.withValue(fault) {
            let child = Task { try await writer.write(plan, generation: 1) }
            await #expect(throws: CocoaError.self, "a child task inherits the fault") { try await child.value }

            let bare = Task.detached { try await writer.write(plan, generation: 2) }
            let wroteBare = try await bare.value
            #expect(wroteBare, "a bare detached task inherits nothing — which is why the job passes it")

            let carried = Task.detached { try await ArchiveAngelJob.savePlanOffMain(plan, generation: 3, injecting: fault) }
            await #expect(throws: CocoaError.self, "handed in, it reaches the write") { try await carried.value }
        }
    }

    // MARK: The job's detached save (capture-and-pass)

    @MainActor
    private func cancelledEmptyJob(_ label: String) throws -> (job: ArchiveAngelJob, sb: MasterArchiveTestSupport.Sandbox) {
        let sb = try MasterArchiveTestSupport.makeSandbox(label)
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.scanTargets = []
        model.previewSweep.stop()
        model.archiveAngel.sweep.stop()
        model.masterArchive = MasterArchiveDesignation(targetPath: sb.archiveVolume.path,
                                                       rootPath: sb.archiveRoot.path, volumeUUID: nil)
        let buffer = sb.root.appendingPathComponent("Buffer", isDirectory: true)
        try FileManager.default.createDirectory(at: buffer, withIntermediateDirectories: true)
        // No record qualifies: the job picks nothing, saves once and ends.
        let job = ArchiveAngelJob(model: model, center: MediaFileOperationsCenter(), count: 1, makeLossless: false,
                                  bufferRoot: buffer, explicitRecordIDs: [UUID()])
        return (job, sb)
    }

    private static let cancelledSaveLine = "could not save the cancelled batch"

    /// A Stop pressed as the job starts: its one loop save fails under the
    /// bound fault, the job settles as cancelled, and the settle's save —
    /// performed in a DETACHED task — fails too and says so. As a global
    /// the fault reached that task by being global; as a task-local it is
    /// read on the tree and handed in.
    @Test @MainActor
    func theJobsDetachedSettleSaveStillSeesTheFault() async throws {
        let (job, sb) = try cancelledEmptyJob("seam_detached_bound"); defer { sb.cleanup() }
        let sink = InMemoryLogSink(name: "seam-detached-bound")
        let fault = ArchiveAngelPlanWriter.InjectedFailure(batchNameContains: sb.root.path, afterWrites: 0)
        await withAppLog(sink) {
            await ArchiveAngelPlanWriter.$injectedFailure.withValue(fault) {
                job.start()
                job.cancel()
                await job.task?.value
                await job.cleanupTask?.value
            }
        }
        guard case .cancelled = job.state else { Issue.record("fixture: the job ended \(job.state)"); return }
        #expect(sink.contains(Self.cancelledSaveLine),
                "the detached settle save did not see the fault: \(sink.lines.suffix(6))")
        #expect(!FileManager.default.fileExists(atPath: job.plan.planURL.path), "a failed save wrote plan.json")
    }

    /// The control: the same Stop with nothing bound saves and says nothing.
    @Test @MainActor
    func unboundTheSameSettleSaves() async throws {
        let (job, sb) = try cancelledEmptyJob("seam_detached_unbound"); defer { sb.cleanup() }
        let sink = InMemoryLogSink(name: "seam-detached-unbound")
        await withAppLog(sink) {
            job.start()
            job.cancel()
            await job.task?.value
            await job.cleanupTask?.value
        }
        guard case .cancelled = job.state else { Issue.record("fixture: the job ended \(job.state)"); return }
        #expect(!sink.contains(Self.cancelledSaveLine), "\(sink.lines.suffix(6))")
    }

    // MARK: Clear's disk probe

    /// 12 Clears at once, each on its own model and batch. Even cases bind
    /// a probe; odd ones bind none. A bound probe hears exactly its own
    /// batch's two phases — with the global, every probe heard every Clear.
    @Test("12 concurrent Clears: a bound probe hears only its own batch; unbound Clears are heard by nobody",
          arguments: 0..<12)
    @MainActor
    func clearProbeIsPerTaskTree(_ id: Int) async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("seam_clear_\(id)"); defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.scanTargets = []
        model.previewSweep.stop()
        model.archiveAngel.sweep.stop()
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        let batchDir = sb.root.appendingPathComponent("buffer/batch-seam-\(id)").path
        try FileManager.default.createDirectory(atPath: batchDir, withIntermediateDirectories: true)
        var plan = ArchiveAngelPlan(batchDir: batchDir, requestedCount: 1, makeLossless: false, entries: [])
        plan.status = .ready
        try ArchiveAngelPlanStore.save(plan)

        let heard = OSAllocatedUnfairLock(initialState: [String]())
        let probe: @Sendable (String, String) -> Void = { phase, dir in
            heard.withLock { $0.append("\(phase) \(dir)") }
            Thread.sleep(forTimeInterval: 0.02)   // hold the phase open so the cases overlap
        }
        let out: ArchiveAngelBatchClearOutcome
        if id.isMultiple(of: 2) {
            out = await ArchiveAngelClearSeam.$diskProbe.withValue(probe) {
                await model.clearArchiveAngelBatch(plan, reason: "seam scope \(id)")
            }
            #expect(heard.withLock { $0 } == ["path \(batchDir)", "plan \(batchDir)"], "\(heard.withLock { $0 })")
        } else {
            #expect(ArchiveAngelClearSeam.diskProbe == nil, "another case's probe is visible here")
            out = await model.clearArchiveAngelBatch(plan, reason: "seam scope \(id)")
            #expect(heard.withLock { $0 }.isEmpty)
        }
        #expect(out.cleared, "bound or not, the Clear itself is unchanged: \(String(describing: out.refusal)) \(out.error ?? "")")
        #expect(await out.removal?.value.removed == true)
        #expect(ArchiveAngelClearSeam.diskProbe == nil, "the binding outlived its scope")
    }
}
