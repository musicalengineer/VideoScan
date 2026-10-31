// JobSupervisorIsolationTests.swift — poisoned state (design §6 isolation):
// a kill mid-unit, a corrupt checkpoint, a full disk.
//
// Dimensions: ISOLATION. Real files for the kill case (the checkpoint and
// queue folders are what survive a kill -9), in-memory with fault injection
// for disk-full.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("JobSupervisor — ISOLATION: kill, corrupt checkpoint, disk full")
struct JobSupervisorIsolationTests {

    @Test("killed mid-unit: a second supervisor on the same folders resumes and no completed unit runs twice")
    func killMidUnit() async throws {
        let dir = try BackgroundFixtures.scratch("kill")
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = FileJobQueueStore(directory: dir.appendingPathComponent("queue"))
        let checkpoints = FileCheckpointStore(directory: dir.appendingPathComponent("checkpoints"))
        let recorder = UnitRecorder()
        let log = InMemoryBackgroundLog()
        let request = RecordingFactory.request()

        // Process 1: units 0…3 complete, unit 4 never returns; the process dies.
        let first = JobSupervisor(queue: queue, checkpoints: checkpoints,
                                  factory: RecordingFactory(recorder: recorder, units: 8, hangAt: 4),
                                  backoff: BackgroundFixtures.fullBackoff(), log: log, configuration: BackgroundFixtures.fastConfiguration())
        _ = await first.enqueue(request)
        #expect(await BackgroundFixtures.waitUntil { recorder.completedUnits.count == 4 })
        await first.abandonForTest()
        #expect(queue.contains(request.id), "the queue file survives the kill")
        guard case .found(let cp) = checkpoints.load(request.id) else { Issue.record("no checkpoint after 4 units"); return }
        #expect(cp.completedUnits == 4)

        // Process 2 on the same folders.
        let second = JobSupervisor(queue: queue, checkpoints: checkpoints,
                                   factory: RecordingFactory(recorder: recorder, units: 8),
                                   backoff: BackgroundFixtures.fullBackoff(), log: log, configuration: BackgroundFixtures.fastConfiguration())
        await second.start()
        await second.drain()

        #expect(recorder.completedUnits == [0, 1, 2, 3, 4, 5, 6, 7], "each unit completed exactly once across both lives")
        #expect(log.lines.contains { $0.hasPrefix("OUTCOME recording \(request.id) — interrupted at 4 of 8") })
        #expect(log.lines.filter { $0.hasPrefix("START recording \(request.id)") }.count == 2)
        #expect(log.lines.filter { $0.hasPrefix("OUTCOME recording \(request.id)") }.count == 2, "every START has its OUTCOME")
        #expect(!queue.contains(request.id))
        #expect(checkpoints.load(request.id) == .none)
    }

    @Test("a corrupt checkpoint restarts the job from zero and the log says so")
    func corruptCheckpoint() async throws {
        let dir = try BackgroundFixtures.scratch("corrupt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = FileJobQueueStore(directory: dir.appendingPathComponent("queue"))
        let checkpointDir = dir.appendingPathComponent("checkpoints")
        let checkpoints = FileCheckpointStore(directory: checkpointDir)
        let request = RecordingFactory.request()
        try queue.put(request)
        try FileManager.default.createDirectory(at: checkpointDir, withIntermediateDirectories: true)
        try Data("{\"schema\":1,\"kind\":\"JobCheckpoint\",\"body\":{\"jobID\":".utf8)
            .write(to: checkpointDir.appendingPathComponent("\(request.id).json"))

        let recorder = UnitRecorder()
        let log = InMemoryBackgroundLog()
        let supervisor = JobSupervisor(queue: queue, checkpoints: checkpoints, factory: RecordingFactory(recorder: recorder, units: 5),
                                       backoff: BackgroundFixtures.fullBackoff(), log: log, configuration: BackgroundFixtures.fastConfiguration())
        await supervisor.start()
        await supervisor.drain()

        #expect(recorder.completedUnits == [0, 1, 2, 3, 4])
        #expect(log.lines.contains { $0.contains("checkpoint for \(request.id) is unreadable") && $0.contains("restarts from zero") }, "\(log.lines)")
        #expect(log.lines.contains { $0.hasPrefix("OUTCOME recording \(request.id) — finished: 5 run") })
    }

    @Test("disk full on the checkpoint: the job ends paused(disk), the OUTCOME says so, the queue file is intact")
    func diskFull() async throws {
        struct DiskFull: Error, CustomStringConvertible { var description: String { "ENOSPC: no space left on device" } }
        let queue = InMemoryJobQueueStore()
        let checkpoints = InMemoryCheckpointStore()
        let recorder = UnitRecorder()
        let log = InMemoryBackgroundLog()
        let supervisor = JobSupervisor(queue: queue, checkpoints: checkpoints, factory: RecordingFactory(recorder: recorder, units: 10, sleepPerUnit: .milliseconds(5)),
                                       backoff: BackgroundFixtures.fullBackoff(), log: log, configuration: BackgroundFixtures.fastConfiguration())
        let request = RecordingFactory.request()
        _ = await supervisor.enqueue(request)
        #expect(await BackgroundFixtures.waitUntil { recorder.completedUnits.count >= 2 })
        checkpoints.saveError = DiskFull()
        await supervisor.drain()

        let snapshot = await supervisor.snapshot(request.id)
        #expect(snapshot?.state == .paused(reason: "disk"))
        #expect(queue.contains(request.id), "the request is still queued for the next launch")
        let outcome = log.lines.filter { $0.hasPrefix("OUTCOME recording \(request.id) — paused (disk)") }
        #expect(outcome.count == 1, "\(log.lines)")
        #expect(outcome.first?.contains("ENOSPC") == true)
        #expect(recorder.completedUnits.count < 10, "the job did not run on past the failed checkpoint")
    }
}
