// ArchiveAngelSeamScopeTests.swift
// The two Archive Angel test seams are task-local since 2026-11-21 (they
// were process-global statics, which forced ArchiveAngelWholeJobTests
// `.serialized` and made every Clear probe filter by folder):
//
//   ArchiveAngelPlanWriter.injectedFailure   plan.json "disk full" fault
//   ArchiveAngelClearSeam.diskProbe          Clear's off-main disk phases
//
// What is proven here:
//   - sibling tasks holding DIFFERENT bindings (and none) at the same
//     moment — a counted rendezvous, not a hope — each see only their
//     own, through the one shared writer and the real Clear; the same
//     harness pointed at a global reads 23 of 24 wrong;
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

    /// What one party of a rendezvous saw.
    private struct Seen: Sendable {
        let id: Int
        /// What it could read while ALL parties held their bindings.
        let atRendezvous: ArchiveAngelPlanWriter.InjectedFailure?
        let goodWrites: Int
    }

    /// The fault case `id` binds: "fail after id % 4 writes" for ANY batch
    /// whose path holds the shared token. Every third case binds nothing.
    private static func fault(_ id: Int) -> ArchiveAngelPlanWriter.InjectedFailure? {
        id % 3 == 0 ? nil : .init(batchNameContains: sharedToken, afterWrites: id % 4)
    }

    /// 24 sibling tasks through `ArchiveAngelPlanWriter.shared`. Each makes
    /// its binding and WAITS until all 24 hold theirs (SeamRendezvous);
    /// only then does each read the seam and write. So 16 different faults
    /// and 8 "no fault" are in force at the same moment, on purpose, and
    /// each task sees exactly its own.
    @Test("24 plan-writer bindings held at once: each task reads its own fault and fails after exactly its own count",
          .timeLimit(.minutes(1)))
    func planWriterFaultIsPerTaskTree() async throws {
        let parties = 24
        let gate = SeamRendezvous(parties: parties)
        let dirs = try (0..<parties).map { try Self.batchDir($0) }
        defer { dirs.forEach { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) } }

        let seen = await withTaskGroup(of: Seen.self, returning: [Seen].self) { group in
            for id in 0..<parties {
                let plan = ArchiveAngelPlan(batchDir: dirs[id].path, requestedCount: 1, makeLossless: false, entries: [])
                group.addTask {
                    // Unbound cases pass through the same code with no binding made.
                    func party() async -> Seen {
                        await gate.arrive()                       // … until all 24 are here
                        let visible = ArchiveAngelPlanWriter.injectedFailure
                        var good = 0
                        for generation in 1...6 {
                            do {
                                _ = try await ArchiveAngelPlanWriter.shared.write(plan, generation: UInt64(generation))
                                good += 1
                            } catch { break }
                        }
                        await gate.leave()
                        return Seen(id: id, atRendezvous: visible, goodWrites: good)
                    }
                    guard let fault = Self.fault(id) else { return await party() }
                    return await ArchiveAngelPlanWriter.$injectedFailure.withValue(fault) { await party() }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        #expect(await gate.peakHeld == parties, "the bindings did not overlap — the test proved nothing")
        #expect(seen.count == parties)
        for s in seen {
            #expect(s.atRendezvous == Self.fault(s.id), "task \(s.id) read another task's fault while all were held")
            #expect(s.goodWrites == (Self.fault(s.id)?.afterWrites ?? 6),
                    "task \(s.id) got \(s.goodWrites) good writes")
        }
        #expect(ArchiveAngelPlanWriter.injectedFailure == nil, "a binding outlived its scope")
    }

    /// The harness itself, pointed at a GLOBAL bound the old way (assign,
    /// run, reset): with every party held at the rendezvous, all but the
    /// last assignment are overwritten, so nearly every party reads someone
    /// else's value. This is what the test above would report if the seam
    /// were a process-global again — the proof that it can go red.
    @Test("the rendezvous convicts a process-global: 24 parties, one variable, 23 read the wrong value",
          .timeLimit(.minutes(1)))
    func theRendezvousConvictsAGlobal() async {
        let parties = 24
        let gate = SeamRendezvous(parties: parties)
        let global = OSAllocatedUnfairLock<Int?>(initialState: nil)   // the old `static var`
        let wrong = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for id in 0..<parties {
                group.addTask {
                    global.withLock { $0 = id }                   // Type.hook = mine
                    await gate.arrive()
                    let visible = global.withLock { $0 }
                    await gate.leave()
                    return visible != id
                }
            }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(await gate.peakHeld == parties)
        #expect(wrong == parties - 1, "one variable holds one value: only the last writer reads its own (\(wrong) wrong)")
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

    /// 12 Clears, each on its own model and batch, as sibling tasks. Even
    /// ones bind a probe, odd ones none; each WAITS until all 12 are inside
    /// their scope (SeamRendezvous) and only then Clears. With six
    /// different probes in force at the same moment, a bound probe hears
    /// exactly its own batch's two phases and nobody hears an unbound Clear.
    @Test("12 Clear bindings held at once: a bound probe hears only its own batch; unbound Clears are heard by nobody",
          .timeLimit(.minutes(1)))
    @MainActor
    func clearProbeIsPerTaskTree() async throws {
        let parties = 12
        let gate = SeamRendezvous(parties: parties)
        struct Party {
            let sb: MasterArchiveTestSupport.Sandbox
            let model: VideoScanModel
            let plan: ArchiveAngelPlan
            let heard = OSAllocatedUnfairLock(initialState: [String]())
        }
        var made: [Party] = []
        defer { made.forEach { $0.sb.cleanup() } }
        for id in 0..<parties {
            let sb = try MasterArchiveTestSupport.makeSandbox("seam_clear_\(id)")
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
            made.append(Party(sb: sb, model: model, plan: plan))
        }
        let all = made

        // Unstructured tasks, not a task group: every party lives on the
        // main actor (the model's), and a Task made here inherits nothing
        // bound — each makes its own binding inside.
        // (probe visible at the rendezvous?, cleared, removed)
        var tasks: [Task<(Bool, Bool, Bool), Never>] = []
        for id in 0..<parties {
            let p = all[id]
            tasks.append(Task { @MainActor in
                func party() async -> (Bool, Bool, Bool) {
                    await gate.arrive()                       // … until all 12 are here
                    let visible = ArchiveAngelClearSeam.diskProbe != nil
                    let out = await p.model.clearArchiveAngelBatch(p.plan, reason: "seam scope \(id)")
                    await gate.leave()
                    let removed = await out.removal?.value.removed == true
                    return (visible, out.cleared, removed)
                }
                guard id.isMultiple(of: 2) else { return await party() }
                let heard = p.heard
                let probe: @Sendable (String, String) -> Void = { phase, dir in
                    heard.withLock { $0.append("\(phase) \(dir)") }
                }
                return await ArchiveAngelClearSeam.$diskProbe.withValue(probe) { await party() }
            })
        }
        var results: [Int: (Bool, Bool, Bool)] = [:]
        for (id, task) in tasks.enumerated() { results[id] = await task.value }

        #expect(await gate.peakHeld == parties, "the bindings did not overlap — the test proved nothing")
        for id in 0..<parties {
            let bound = id.isMultiple(of: 2)
            let r = try #require(results[id])
            #expect(r.0 == bound, "task \(id) \(bound ? "lost its probe" : "saw another task's probe") while all were held")
            #expect(r.1 && r.2, "bound or not, the Clear itself is unchanged (task \(id))")
            let heard = all[id].heard.withLock { $0 }
            let dir = all[id].plan.batchDir
            #expect(heard == (bound ? ["path \(dir)", "plan \(dir)"] : []), "task \(id) heard \(heard)")
        }
        #expect(ArchiveAngelClearSeam.diskProbe == nil, "a binding outlived its scope")
    }
}
