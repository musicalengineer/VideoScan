// JobSupervisorFailFastTests.swift — the supervisor's fail-fast rule
// (JobSupervisor.Configuration.failFastUnits, FailureStreak; 2026-11-03: a
// missing ffmpeg failed 523 of 523 era units and the job ended "finished").
//   LOGIC      N identical systemic failures in a row → failed, the words in
//              the OUTCOME, the rest never tried, the queue file removed;
//              a success or different words start the count over; failures
//              the job calls non-systemic never stop it; a repeat failure is
//              logged as "the same error as unit N" (the words said once).
//   ISOLATION  a START refusal still keeps its queue file (refuse, never
//              erase); EraJob's own classification (timeouts and worker
//              deaths are per file); a Mac with no ffmpeg refuses the era
//              job at START through the supervisor, with zero units run.
// No media, no model.

import Foundation
import Testing
@testable import VideoScanCore

/// A job whose unit i throws `script[i]` (nil = done).
struct ScriptedFailureJob: BackgroundJob {
    let title = "Scripted job"
    let script: [String?]
    let systemic: Bool
    let recorder: UnitRecorder
    var unitCount: Int { script.count }
    func runUnit(_ index: Int) async throws -> UnitOutcome {
        recorder.begin()
        if let words = script[index] { recorder.abort(); throw Refusal(words) }
        recorder.end(index)
        return .done
    }
    func failureIsSystemic(_ error: any Error) -> Bool { systemic }
}

struct ScriptedFailureFactory: JobFactory {
    static let kind = JobKind(rawValue: "scripted")
    let script: [String?]
    var systemic = true
    let recorder: UnitRecorder
    func makeJob(for request: JobRequest) throws -> any BackgroundJob {
        ScriptedFailureJob(script: script, systemic: systemic, recorder: recorder)
    }
}

@Suite("JobSupervisor — fail fast (2026-11-03)")
struct JobSupervisorFailFastTests {

    static func run(_ script: [String?], systemic: Bool = true) async -> (log: InMemoryBackgroundLog, recorder: UnitRecorder,
                                                                          queue: InMemoryJobQueueStore, state: JobRunState?) {
        let log = InMemoryBackgroundLog()
        let recorder = UnitRecorder()
        let queue = InMemoryJobQueueStore()
        let supervisor = JobSupervisor(queue: queue, checkpoints: InMemoryCheckpointStore(),
                                       factory: ScriptedFailureFactory(script: script, systemic: systemic, recorder: recorder),
                                       backoff: BackgroundFixtures.fullBackoff(), log: log, configuration: BackgroundFixtures.fastConfiguration())
        let request = JobRequest(kind: ScriptedFailureFactory.kind, requestedBy: "test")
        _ = await supervisor.enqueue(request)
        await supervisor.drain()
        return (log, recorder, queue, await supervisor.snapshot(request.id)?.state)
    }

    @Test func fiveIdenticalSystemicFailuresStopTheJobAndTheOutcomeNamesThem() async {
        let r = await Self.run(Array(repeating: "ffmpeg missing", count: 8) as [String?])
        guard case .failed(let reason)? = r.state else { Issue.record("state \(String(describing: r.state))"); return }
        #expect(reason.contains("ffmpeg missing") && reason.contains("units 0–4, 5 in a row") && reason.contains("3 not tried"), "\(reason)")
        let outcome = r.log.lines.first { $0.hasPrefix("OUTCOME scripted") } ?? ""
        #expect(outcome.contains("— failed: ") && outcome.contains("0 run · 0 skipped · 5 failed") && !outcome.contains("queue file is kept"), "\(outcome)")
        #expect(r.log.lines.filter { $0.contains("failed: ffmpeg missing") && !$0.hasPrefix("OUTCOME") }.count == 1, "\(r.log.lines)")
        #expect(r.log.lines.filter { $0.contains("failed: the same error as unit 0") }.count == 4)
        #expect(r.queue.list().requests.isEmpty)
        #expect(r.log.startCount == 1 && r.log.outcomeCount == 1)
    }

    @Test func aSuccessOrDifferentWordsStartTheCountOver() async {
        let x: String? = "x"
        let r = await Self.run([x, x, x, x, nil, x, x, x, x, "y", x, x, x, x])
        #expect(r.state == .finished, "never 5 identical in a row")
        #expect(r.recorder.completedUnits == [4])
        #expect(r.log.lines.contains { $0.contains("— finished: 1 run · 0 skipped · 13 failed") }, "\(r.log.lines)")
    }

    @Test func failuresTheJobCallsPerFileNeverStopIt() async {
        let r = await Self.run(Array(repeating: "analyze_clip exceeded 180 s", count: 12) as [String?], systemic: false)
        #expect(r.state == .finished)
        #expect(r.log.lines.contains { $0.contains("— finished: 0 run · 0 skipped · 12 failed") })
        #expect(r.log.lines.filter { $0.contains("the same error as unit 0") }.count == 11, "still said once")
    }

    /// Changed 2026-11-04 (Codex #235 F6): a short job every unit of which
    /// failed with the same systemic words runs to its end (no early stop) and
    /// then says FAILED — "finished" let a one-file plan retry forever.
    @Test func fewerUnitsThanTheThresholdRunAllThenSayFailed() async {
        let r = await Self.run(["z", "z", "z"])
        #expect(r.state == .failed(reason: "all 3 unit(s) failed with the same error: z"))
        let mixed = await Self.run(["z", nil, "z"])
        #expect(mixed.state == .finished, "one unit succeeded: not a systemic failure of the job")
    }

    @Test func theFailureStreakIsAPureValue() {
        var s = FailureStreak()
        s.record("a", unit: 3, systemic: true)
        s.record("a", unit: 4, systemic: true)
        #expect(s.words == "a" && s.length == 2 && s.firstUnit == 3 && s.repeats("a") == 3 && s.repeats("b") == nil)
        s.record("b", unit: 5, systemic: false)
        #expect(s.words == nil && s.length == 0 && s.repeats("b") == 5)
    }

    /// Codex #232 F6: a same-word failure the job calls per-file breaks the
    /// systemic run — [T, T, F, T, T, T] is a run of 3 starting at unit 3, not 5.
    @Test func aPerFileFailureBreaksTheSystemicRunEvenWithTheSameWords() {
        var s = FailureStreak()
        for (unit, systemic) in [true, true, false, true, true, true].enumerated() { s.record("w", unit: unit, systemic: systemic) }
        #expect(s.length == 3 && s.streakStart == 3, "length \(s.length) from \(s.streakStart)")
        #expect(s.repeats("w") == 0, "the log still says 'the same error as unit 0'")
    }
}

@Suite("EraJob — what can stop it, and a Mac with no ffmpeg", .serialized)
struct EraJobFailFastTests {

    @Test func timeoutsAndWorkerDeathsArePerFileEverythingElseIsSystemic() async throws {
        let fixture = try await EraFixture.catalog([EraFixture.File(n: 1, path: "/synthetic/1970/a.mov")])
        defer { fixture.remove() }
        let job = try EraJob(EraFixture.setup(fixture, root: try EraFixture.stateRoot()))
        defer { Task { await job.end() } }
        #expect(!job.failureIsSystemic(PythonClipWorkerError.timeout(method: "analyze_clip", seconds: 180)))
        #expect(!job.failureIsSystemic(PythonClipWorkerError.died(method: "analyze_clip", stderrTail: "")))
        #expect(job.failureIsSystemic(PythonClipWorkerError.workerError(type: "FileNotFoundError", message: "[Errno 2] No such file or directory: 'ffmpeg'")))
        #expect(job.failureIsSystemic(PythonClipWorkerError.protocolError("x")))
        #expect(job.failureIsSystemic(Refusal("the worker could not load the model (x)")))
    }

    /// A factory that builds the era job exactly as DefaultJobFactory does,
    /// on a Mac where no ffmpeg is executable.
    struct NoFFmpegFactory: JobFactory {
        let root: URL
        let catalog: URL
        let model: URL
        func makeJob(for request: JobRequest) throws -> any BackgroundJob {
            try EraJob(try EraJob.setup(for: request, stateRoot: root, catalogURL: catalog,
                                        environment: EraEnvironmentFixture.launchd, fileManager: NoExecutablesFileManager()))
        }
    }

    @Test func noFFmpegIsRefusedAtStartInWordsNeverOncePerFile() async throws {
        let fixture = try await EraFixture.catalog((1...3).map { EraFixture.File(n: $0, path: "/synthetic/19\(70 + $0)/a.mov") })
        defer { fixture.remove() }
        let root = try EraFixture.stateRoot()
        let model = try EraEnvironmentFixture.modelDir()
        let request = EraEnvironmentFixture.request(model: model)
        // Enqueue (the app's path) is refused in words…
        let factory = NoFFmpegFactory(root: root, catalog: fixture.url, model: model)
        let log = InMemoryBackgroundLog()
        let queue = InMemoryJobQueueStore()
        let supervisor = JobSupervisor(queue: queue, checkpoints: InMemoryCheckpointStore(), factory: factory,
                                       backoff: BackgroundFixtures.fullBackoff(), log: log, configuration: BackgroundFixtures.fastConfiguration())
        guard case .refused(let refusal) = await supervisor.enqueue(request) else { Issue.record("accepted with no ffmpeg"); return }
        #expect(refusal.words.hasPrefix("era: ffmpeg is not on this Mac — looked at VS_FFMPEG_PATH (unset), /opt/homebrew/bin/ffmpeg"), "\(refusal.words)")
        #expect(refusal.words.hasSuffix("refused at START, not once per file"))
        // …and a queue file already on disk (queued before ffmpeg went) is refused at START: no unit runs.
        let queued = JobSupervisor(queue: InMemoryJobQueueStore([request]), checkpoints: InMemoryCheckpointStore(), factory: factory,
                                   backoff: BackgroundFixtures.fullBackoff(), log: log, configuration: BackgroundFixtures.fastConfiguration())
        await queued.start()
        await queued.drain()
        #expect(log.lines.contains { $0.hasPrefix("START era \(request.id) — refused: era: ffmpeg is not on this Mac") }, "\(log.lines)")
        #expect(!log.lines.contains { $0.contains(" unit ") && $0.contains("failed") }, "never per unit: \(log.lines)")
        #expect(try EraFixture.lines(root).isEmpty)
    }
}
