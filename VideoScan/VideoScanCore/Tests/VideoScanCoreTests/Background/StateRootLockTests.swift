// StateRootLockTests.swift — one supervisor per state root (regression,
// 2026-11-02): launchd started the helper while a hand run (`--run era`)
// was at unit 2,840 of 4,709 over the same folders, and the helper adopted
// the hand run's queued job ("interrupted at 2840 … resuming from the
// checkpoint") — two workers over one checkpoint.
//
// Dimensions: LOGIC (the lock's words), ISOLATION (two supervisors on one
// root, the holder dies, the second takes over). Real files: flock is the
// mechanism under test. Two `open`s in one process contend exactly as two
// processes do (flock is per open-file-description), so the test needs no
// second process.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("StateRootLock — one supervisor per state root")
struct StateRootLockTests {

    @Test("a second supervisor over the same root adopts nothing while the first is alive, then takes over when it dies")
    func secondSupervisorWaitsForTheFirst() async throws {
        let dir = try BackgroundFixtures.scratch("owner")
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = FileJobQueueStore(directory: dir.appendingPathComponent("queue"))
        let checkpoints = FileCheckpointStore(directory: dir.appendingPathComponent("checkpoints"))
        let recorder = UnitRecorder()
        let gate = UnitGate()
        let handLog = InMemoryBackgroundLog()
        let serviceLog = InMemoryBackgroundLog()
        let request = GatedFactory.request()

        // The hand run: unit 0 completes, unit 1 waits at the gate — the job is live.
        let hand = JobSupervisor(queue: queue, checkpoints: checkpoints,
                                 factory: GatedFactory(recorder: recorder, gate: gate, units: 3, heldUnit: 1),
                                 backoff: BackgroundFixtures.fullBackoff(), log: handLog,
                                 configuration: BackgroundFixtures.fastConfiguration(),
                                 ownership: FileStateRootLock(root: dir, owner: "cli --run era"))
        guard case .accepted = await hand.enqueue(request) else { Issue.record("the hand run was refused"); return }
        #expect(await BackgroundFixtures.waitUntil { gate.isHeld })

        // launchd starts the service over the same folders.
        var config = BackgroundFixtures.fastConfiguration()
        config.ownerRetryInterval = .milliseconds(50)
        let service = JobSupervisor(queue: queue, checkpoints: checkpoints,
                                    factory: GatedFactory(recorder: recorder, gate: gate, units: 3, heldUnit: -1),
                                    backoff: BackgroundFixtures.fullBackoff(), log: serviceLog,
                                    configuration: config,
                                    ownership: FileStateRootLock(root: dir, owner: "service"))
        await service.start()

        #expect(await service.activeJobCount == 0, "the service must not adopt a job another process is running")
        let refusal = await service.ownershipRefusal
        #expect(refusal?.contains("pid \(ProcessInfo.processInfo.processIdentifier)") == true, "the refusal names the holder: \(refusal ?? "nil")")
        #expect(refusal?.contains("cli --run era") == true)
        #expect(serviceLog.lines.contains { $0.hasPrefix("not running jobs: ") && $0.contains("one VideoScan Background per state root") })
        #expect(!serviceLog.lines.contains { $0.hasPrefix("START") }, "no START from the service while the hand run holds the root")
        let status = await service.status(processIdentifier: 1, startedAt: Date())
        #expect(status.jobs.isEmpty, "status shows no job it does not run")

        // The app asks the service to queue work meanwhile: refused in the holder's words.
        guard case .refused(let words) = await service.enqueue(GatedFactory.request()) else {
            Issue.record("enqueue must be refused while another process owns the root"); return
        }
        #expect(words.words.hasPrefix("enqueue refused: "))
        #expect(words.words.contains("cli --run era"))

        // The hand run dies mid-unit (kill -9: the kernel drops its flock).
        await hand.abandonForTest()
        gate.open()

        // The service's retry claims the root and resumes from the checkpoint.
        #expect(await BackgroundFixtures.waitUntil { serviceLog.lines.contains { $0.hasPrefix("state root is free") } })
        #expect(await BackgroundFixtures.waitUntil { recorder.completedUnits.count == 3 })
        await service.drain()
        #expect(recorder.completedUnits == [0, 1, 2], "every unit completed exactly once across both processes")
        #expect(serviceLog.lines.contains { $0.hasPrefix("OUTCOME gated \(request.id) — interrupted at 1 of 3") })
        #expect(serviceLog.lines.contains { $0.hasPrefix("START gated \(request.id)") && $0.contains("resuming at unit 1") })
        #expect(await service.ownershipRefusal == nil)
    }

    @Test("the lock names its holder; a released lock is free again")
    func lockWordsNameTheHolder() throws {
        let dir = try BackgroundFixtures.scratch("lock-words")
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = FileStateRootLock(root: dir, owner: "cli --run era")
        let second = FileStateRootLock(root: dir, owner: "service")

        guard case .success = first.claim() else { Issue.record("the first claim fails"); return }
        #expect(first.isHeld)
        guard case .success = first.claim() else { Issue.record("a second claim by the holder is not idempotent"); return }

        guard case .failure(let refusal) = second.claim() else { Issue.record("the second claimant got the lock"); return }
        #expect(!second.isHeld)
        #expect(refusal.words.contains(dir.path))
        #expect(refusal.words.contains("pid \(ProcessInfo.processInfo.processIdentifier) · cli --run era · since "))
        #expect(refusal.words.hasSuffix("one VideoScan Background per state root"))

        first.release()
        #expect(!first.isHeld)
        guard case .success = second.claim() else { Issue.record("a released lock stays taken"); return }
        #expect(second.isHeld)
        let contents = try String(contentsOf: second.url, encoding: .utf8)
        #expect(contents.contains("· service · since "), "the file names the new holder: \(contents)")
    }

    @Test("an uncontested root (in-memory stores) changes nothing: start plans and runs as before")
    func uncontestedRootIsTransparent() async {
        let recorder = UnitRecorder()
        let log = InMemoryBackgroundLog()
        let supervisor = JobSupervisor(queue: InMemoryJobQueueStore(), checkpoints: InMemoryCheckpointStore(),
                                       factory: RecordingFactory(recorder: recorder, units: 2),
                                       backoff: BackgroundFixtures.fullBackoff(), log: log,
                                       configuration: BackgroundFixtures.fastConfiguration())
        guard case .accepted = await supervisor.enqueue(RecordingFactory.request()) else { Issue.record("refused"); return }
        await supervisor.drain()
        #expect(recorder.completedUnits == [0, 1])
        #expect(await supervisor.ownershipRefusal == nil)
        #expect(!log.lines.contains { $0.hasPrefix("not running jobs") })
    }
}
