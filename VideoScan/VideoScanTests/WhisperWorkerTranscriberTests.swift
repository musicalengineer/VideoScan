import Foundation
import Testing
@testable import VideoScan

// MARK: - WhisperWorkerTranscriber tests
//
// Persistent Whisper worker (perf item 1, 2026-07-14): one Python
// process per BATCH instead of one per file. Everything here runs
// against FAKE worker scripts (tiny /usr/bin/python3 programs emitting
// canned NDJSON) — no mlx, no venv-mlx, no model download, ever.
//
// Five-dimension coverage:
//   Logic      — framing, id matching, empty transcript, unicode/space
//                paths, clean-EOF shutdown (positive) + preflight gate,
//                ok:false responses (negative)
//   Scale      — 200 requests through one worker inside a time budget
//   Sensor     — the scale test asserts EXACTLY 1 spawn: that single
//                number IS the regression sensor for this whole item
//                (888 spawns × ~5 s model load = 1.18 h in one nightly)
//   Negative   — worker crash → respawn+retry; double crash →
//                .subprocessFailed; hang → deadline kill; garbage /
//                unknown-id → kill+respawn; cancellation; latch
//   Integration— real CaptionOrchestrator dossier path with the fake
//                worker + stub VLM runner
//   Isolation  — env-var poisoning for the new ToolLocator entry via
//                injected environments (never the real one); test-host
//                guard pinned against auto-resolution

// MARK: - Fake worker scripts

/// Writes a fake NDJSON worker to a fresh temp dir and returns
/// (scriptPath, cleanup). All fakes ignore argv (the transcriber
/// passes `--model <id>`), read requests from stdin, and exit 0 on
/// EOF — same contract as the real scripts/whisper_worker.py.
private func writeFakeWorker(_ body: String) throws -> (script: String, dir: URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperWorkerTests_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let script = dir.appendingPathComponent("fake_worker.py")
    try body.write(to: script, atomically: true, encoding: .utf8)
    return (script.path, dir)
}

private let systemPython = "/usr/bin/python3"

/// Happy-path echo worker: responds `transcript::<path>`, or "" for
/// paths containing "silent". Exercises framing + id matching + JSON
/// escaping (unicode / spaces round-trip through the path echo).
private let echoWorkerBody = """
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    req = json.loads(line)
    p = req.get("path", "")
    text = "" if "silent" in p else "transcript::" + p
    print(json.dumps({"id": req.get("id"), "ok": True, "text": text}, ensure_ascii=False), flush=True)
"""

/// Answers exactly one request per process, then dies (exit 1).
private let dieAfterOneBody = """
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    req = json.loads(line)
    print(json.dumps({"id": req["id"], "ok": True, "text": "transcript::" + req["path"]}), flush=True)
    sys.exit(1)
"""

/// Dies WITHOUT responding for paths containing "poison"; echoes
/// otherwise. A poisoned file kills every respawn, so the retry
/// budget (1) is exhausted deterministically.
private let poisonBody = """
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    req = json.loads(line)
    if "poison" in req.get("path", ""):
        sys.exit(1)
    print(json.dumps({"id": req["id"], "ok": True, "text": "transcript::" + req["path"]}), flush=True)
"""

/// Never responds for paths containing "hang" (sleeps); echoes others.
private let hangBody = """
import json, sys, time
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    req = json.loads(line)
    if "hang" in req.get("path", ""):
        time.sleep(3600)
    print(json.dumps({"id": req["id"], "ok": True, "text": "transcript::" + req["path"]}), flush=True)
"""

/// Responds with a WRONG id for paths containing "garble" (protocol
/// error → the parent must recycle the worker); echoes others.
private let garbleBody = """
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    req = json.loads(line)
    if "garble" in req.get("path", ""):
        print(json.dumps({"id": "totally-unrelated-id", "ok": True, "text": "bogus"}), flush=True)
    else:
        print(json.dumps({"id": req["id"], "ok": True, "text": "transcript::" + req["path"]}), flush=True)
"""

/// Reports a per-file failure (ok:false) for paths containing "bad";
/// echoes others. The worker must stay alive across the failure.
private let okFalseBody = """
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    req = json.loads(line)
    if "bad" in req.get("path", ""):
        print(json.dumps({"id": req["id"], "ok": False, "error": "decode failed: fake"}), flush=True)
    else:
        print(json.dumps({"id": req["id"], "ok": True, "text": "transcript::" + req["path"]}), flush=True)
"""

// MARK: - Helpers

private func makeWorkerTranscriber(
    script: String,
    idleTimeoutSeconds: Double = 120,
    killGraceSeconds: Double = 0.3,
    preflightPasses: Bool = true
) -> WhisperWorkerTranscriber {
    WhisperWorkerTranscriber(
        pythonPath: systemPython,
        scriptPath: script,
        idleTimeoutSeconds: idleTimeoutSeconds,
        killGraceSeconds: killGraceSeconds,
        audioPreflight: { path in
            guard preflightPasses else { return false }
            _ = path
            return true
        }
    )
}

/// Poll until `condition` is true or `timeout` elapses. SIGTERM →
/// process reap isn't instantaneous, so worker-death assertions poll.
private func eventually(
    timeout: Double = 4.0,
    _ condition: () async -> Bool
) async -> Bool {
    let start = CFAbsoluteTimeGetCurrent()
    while CFAbsoluteTimeGetCurrent() - start < timeout {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return await condition()
}

private func expectSubprocessFailed(_ error: Error, note: Comment) {
    guard let e = error as? AudioTranscriberError,
          case .subprocessFailed = e else {
        Issue.record("\(note): expected .subprocessFailed, got \(error)")
        return
    }
}

// MARK: - Suite

@Suite("Whisper worker transcriber — persistent NDJSON worker")
struct WhisperWorkerTranscriberTests {

    // MARK: Logic (positive)

    @Test("echo worker: framing + id matching + unicode/space paths, ONE spawn for the batch")
    func echoWorkerTranscribesBatchAndSpawnsOnce() async throws {
        guard FileManager.default.fileExists(atPath: systemPython) else { return }
        let (script, dir) = try writeFakeWorker(echoWorkerBody)
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = makeWorkerTranscriber(script: script)
        defer { Task { await t.shutdown() } }

        // Spaces + non-ASCII deliberately: the path round-trips through
        // JSON both ways, so equality proves the framing is clean.
        let paths = [
            "/tmp/fixtures/plain.mov",
            "/tmp/fixtures/summer picnic 1982.mxf",
            "/tmp/fixtures/família vídeo — café ☕ 1979.mov"
        ]
        for p in paths {
            let text = try await t.transcribe(videoPath: p, deadlineSeconds: 60)
            #expect(text == "transcript::\(p)", "path must round-trip exactly")
        }
        #expect(await t.totalSpawns == 1, "one batch, one worker — that's the whole point")
    }

    @Test("empty transcript (ok:true, text:\"\") comes back as empty string, not an error")
    func emptyTranscriptRoundTrips() async throws {
        guard FileManager.default.fileExists(atPath: systemPython) else { return }
        let (script, dir) = try writeFakeWorker(echoWorkerBody)
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = makeWorkerTranscriber(script: script)
        defer { Task { await t.shutdown() } }

        let text = try await t.transcribe(videoPath: "/tmp/silent_room_tone.mov", deadlineSeconds: 60)
        #expect(text.isEmpty, "silence is a valid answer — writeback layer distinguishes it from 'never ran'")
    }

    @Test("shutdown() terminates the worker (clean EOF exit) and stays reusable")
    func shutdownTerminatesWorker() async throws {
        guard FileManager.default.fileExists(atPath: systemPython) else { return }
        let (script, dir) = try writeFakeWorker(echoWorkerBody)
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = makeWorkerTranscriber(script: script)

        _ = try await t.transcribe(videoPath: "/tmp/a.mov", deadlineSeconds: 60)
        #expect(await t.isWorkerRunning)

        await t.shutdown()
        let died = await eventually { await !t.isWorkerRunning }
        #expect(died, "worker must be gone after batch settle")

        // Not latched: a later batch on the same instance respawns.
        let text = try await t.transcribe(videoPath: "/tmp/b.mov", deadlineSeconds: 60)
        #expect(text == "transcript::/tmp/b.mov")
        #expect(await t.totalSpawns == 2)
        await t.shutdown()
    }

    @Test("audio preflight gate fires BEFORE any spawn (negative)")
    func preflightFailureThrowsBeforeSpawn() async throws {
        guard FileManager.default.fileExists(atPath: systemPython) else { return }
        let (script, dir) = try writeFakeWorker(echoWorkerBody)
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = makeWorkerTranscriber(script: script, preflightPasses: false)

        do {
            _ = try await t.transcribe(videoPath: "/tmp/no-audio.mxf", deadlineSeconds: 60)
            Issue.record("expected .audioUnreadable")
        } catch let e as AudioTranscriberError {
            guard case .audioUnreadable = e else {
                Issue.record("expected .audioUnreadable, got \(e)")
                return
            }
        }
        #expect(await t.totalSpawns == 0, "no-audio files must never cost a worker spawn")
    }

    @Test("missing worker script fails launch cleanly")
    func missingScriptThrowsLaunchFailed() async throws {
        let t = WhisperWorkerTranscriber(
            pythonPath: systemPython,
            scriptPath: "/dev/null/no-such-worker.py",
            audioPreflight: { _ in true }
        )
        do {
            _ = try await t.transcribe(videoPath: "/tmp/a.mov", deadlineSeconds: 60)
            Issue.record("expected .subprocessLaunchFailed")
        } catch let e as AudioTranscriberError {
            guard case .subprocessLaunchFailed(let reason) = e else {
                Issue.record("expected .subprocessLaunchFailed, got \(e)")
                return
            }
            #expect(reason.contains("Worker script missing"))
        }
    }

    // MARK: Scale + spawn sensor

    @Test("REGRESSION SENSOR: 200 files through one batch = exactly 1 spawn, within budget")
    func twoHundredRequestsExactlyOneSpawn() async throws {
        guard FileManager.default.fileExists(atPath: systemPython) else { return }
        let (script, dir) = try writeFakeWorker(echoWorkerBody)
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = makeWorkerTranscriber(script: script)
        defer { Task { await t.shutdown() } }

        let started = CFAbsoluteTimeGetCurrent()
        for i in 0..<200 {
            let p = "/tmp/batch/clip_\(i).mov"
            let text = try await t.transcribe(videoPath: p, deadlineSeconds: 60)
            #expect(text == "transcript::\(p)")
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        // THE sensor for this perf item. If this ever reads 200, the
        // per-file spawner is back and nightly batches re-pay ~5 s of
        // model load per file (1.18 h measured on 2026-07-14).
        #expect(await t.totalSpawns == 1, "200 requests must reuse ONE worker process")
        #expect(elapsed < 30.0, "200 round-trips took \(elapsed)s — protocol overhead has regressed")
    }

    // MARK: Negative — crash recovery

    @Test("worker dies after each response → respawn + retry, every file still transcribed")
    func workerDeathMidBatchRespawnsAndRetries() async throws {
        guard FileManager.default.fileExists(atPath: systemPython) else { return }
        let (script, dir) = try writeFakeWorker(dieAfterOneBody)
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = makeWorkerTranscriber(script: script)
        defer { Task { await t.shutdown() } }

        // Each process answers once then exits: file 1 succeeds on
        // spawn #1; files 2 and 3 each hit a dead/dying worker, get one
        // respawn+retry, and succeed. No file may be lost to a crash.
        for i in 1...3 {
            let p = "/tmp/crashy_\(i).mov"
            let text = try await t.transcribe(videoPath: p, deadlineSeconds: 60)
            #expect(text == "transcript::\(p)", "file \(i) must survive worker churn")
        }
        #expect(await t.totalSpawns == 3, "expected one respawn per post-crash file")
    }

    @Test("worker dies twice on the SAME file → .subprocessFailed, subsequent files fine")
    func doubleCrashOnSameFileThrowsSubprocessFailed() async throws {
        guard FileManager.default.fileExists(atPath: systemPython) else { return }
        let (script, dir) = try writeFakeWorker(poisonBody)
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = makeWorkerTranscriber(script: script)
        defer { Task { await t.shutdown() } }

        let ok1 = try await t.transcribe(videoPath: "/tmp/good_a.mov", deadlineSeconds: 60)
        #expect(ok1 == "transcript::/tmp/good_a.mov")

        do {
            _ = try await t.transcribe(videoPath: "/tmp/poison.mov", deadlineSeconds: 60)
            Issue.record("poisoned file should have failed after the retry budget")
        } catch {
            expectSubprocessFailed(error, note: "double crash")
        }

        // Orchestrator semantics: that file banks VLM-only; the batch
        // moves on. The NEXT file must transcribe on a fresh worker.
        let ok2 = try await t.transcribe(videoPath: "/tmp/good_b.mov", deadlineSeconds: 60)
        #expect(ok2 == "transcript::/tmp/good_b.mov")
    }

    // MARK: Negative — deadline

    @Test("hung worker → deadline kill, .deadlineExceeded, next file OK on a fresh worker")
    func hangHitsDeadlineThenNextFileRecovers() async throws {
        guard FileManager.default.fileExists(atPath: systemPython) else { return }
        let (script, dir) = try writeFakeWorker(hangBody)
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = makeWorkerTranscriber(script: script)
        defer { Task { await t.shutdown() } }

        let started = CFAbsoluteTimeGetCurrent()
        do {
            _ = try await t.transcribe(videoPath: "/tmp/hang_forever.mov", deadlineSeconds: 1.0)
            Issue.record("expected .deadlineExceeded")
        } catch let e as AudioTranscriberError {
            guard case .deadlineExceeded(let secs) = e else {
                Issue.record("expected .deadlineExceeded, got \(e)")
                return
            }
            #expect(secs == 1.0)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        #expect(elapsed < 6.0, "deadline kill took \(elapsed)s — escalation is wedged")

        // Deadline kills do NOT retry the same file, but the next file
        // must lazily respawn and succeed. (Path must NOT contain
        // "hang" — the fake keys its behavior off the path.)
        let text = try await t.transcribe(videoPath: "/tmp/next_clip.mov", deadlineSeconds: 60)
        #expect(text == "transcript::/tmp/next_clip.mov")
        #expect(await t.totalSpawns == 2, "exactly one respawn after the deadline kill")
    }

    // MARK: Negative — protocol errors

    @Test("unknown-id response → kill + respawn; persistent garbage → .subprocessFailed; batch continues")
    func garbageResponseRecyclesWorkerAndBatchContinues() async throws {
        guard FileManager.default.fileExists(atPath: systemPython) else { return }
        let (script, dir) = try writeFakeWorker(garbleBody)
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = makeWorkerTranscriber(script: script)
        defer { Task { await t.shutdown() } }

        let ok1 = try await t.transcribe(videoPath: "/tmp/fine_1.mov", deadlineSeconds: 60)
        #expect(ok1 == "transcript::/tmp/fine_1.mov")

        // "garble" draws a wrong-id response from EVERY process, so the
        // one respawn+retry also garbles → the file fails, the pipe
        // state is never trusted after garbage (worker recycled twice).
        do {
            _ = try await t.transcribe(videoPath: "/tmp/garble_me.mov", deadlineSeconds: 60)
            Issue.record("wrong-id responses should have exhausted the retry budget")
        } catch {
            expectSubprocessFailed(error, note: "garbage response")
        }

        let ok2 = try await t.transcribe(videoPath: "/tmp/fine_2.mov", deadlineSeconds: 60)
        #expect(ok2 == "transcript::/tmp/fine_2.mov")
        #expect(await t.totalSpawns == 3, "spawn per garbage recycle + one for the recovery file")
    }

    @Test("ok:false response is a per-file failure — worker survives, no retry")
    func okFalseResponseDoesNotKillWorker() async throws {
        guard FileManager.default.fileExists(atPath: systemPython) else { return }
        let (script, dir) = try writeFakeWorker(okFalseBody)
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = makeWorkerTranscriber(script: script)
        defer { Task { await t.shutdown() } }

        _ = try await t.transcribe(videoPath: "/tmp/fine.mov", deadlineSeconds: 60)
        do {
            _ = try await t.transcribe(videoPath: "/tmp/bad_media.mov", deadlineSeconds: 60)
            Issue.record("expected .subprocessFailed from the worker's error report")
        } catch let e as AudioTranscriberError {
            guard case .subprocessFailed(_, let tail) = e else {
                Issue.record("expected .subprocessFailed, got \(e)")
                return
            }
            #expect(tail.contains("decode failed"))
        }
        _ = try await t.transcribe(videoPath: "/tmp/fine_after.mov", deadlineSeconds: 60)

        // A worker that ANSWERS (even with a failure) is healthy —
        // recycling it would re-pay the model load for nothing.
        #expect(await t.totalSpawns == 1, "ok:false must not recycle the worker")
    }

    // MARK: Negative — cancellation

    @Test("task cancellation SIGTERMs the worker and surfaces CancellationError")
    func cancellationKillsWorker() async throws {
        guard FileManager.default.fileExists(atPath: systemPython) else { return }
        let (script, dir) = try writeFakeWorker(hangBody)
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = makeWorkerTranscriber(script: script)
        defer { Task { await t.shutdown() } }

        let job = Task {
            try await t.transcribe(videoPath: "/tmp/hang_cancel.mov", deadlineSeconds: 300)
        }
        try? await Task.sleep(for: .milliseconds(400))
        job.cancel()

        do {
            _ = try await job.value
            Issue.record("expected CancellationError")
        } catch is CancellationError {
            // expected — orchestrator banks VLM-only on this path
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
        let died = await eventually { await !t.isWorkerRunning }
        #expect(died, "cancelled transcription must not leave a live worker")
    }

    @Test("terminateWorkerNow() latches: in-flight throws CancellationError, no respawn after")
    func terminateWorkerNowLatches() async throws {
        guard FileManager.default.fileExists(atPath: systemPython) else { return }
        let (script, dir) = try writeFakeWorker(hangBody)
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = makeWorkerTranscriber(script: script)

        let job = Task {
            try await t.transcribe(videoPath: "/tmp/hang_stop.mov", deadlineSeconds: 300)
        }
        try? await Task.sleep(for: .milliseconds(400))
        t.terminateWorkerNow()   // what cancel()/drainForShutdown() call

        do {
            _ = try await job.value
            Issue.record("expected CancellationError from the orchestrator-stop kill")
        } catch is CancellationError {
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }

        // Latched dead: a shutdown-time kill must never be answered
        // with a fresh model load.
        do {
            _ = try await t.transcribe(videoPath: "/tmp/late.mov", deadlineSeconds: 60)
            Issue.record("latched transcriber must refuse new work")
        } catch is CancellationError {
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
        #expect(await t.totalSpawns == 1, "no respawn after the latch")
        let died = await eventually { await !t.isWorkerRunning }
        #expect(died)
    }

    // MARK: Idle timeout

    @Test("idle timeout kills the worker; the next file respawns transparently")
    func idleTimeoutKillsThenRespawns() async throws {
        guard FileManager.default.fileExists(atPath: systemPython) else { return }
        let (script, dir) = try writeFakeWorker(echoWorkerBody)
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = makeWorkerTranscriber(script: script, idleTimeoutSeconds: 0.5)
        defer { Task { await t.shutdown() } }

        _ = try await t.transcribe(videoPath: "/tmp/idle_a.mov", deadlineSeconds: 60)
        let died = await eventually(timeout: 5.0) { await !t.isWorkerRunning }
        #expect(died, "idle worker should be reaped after the timeout")

        let text = try await t.transcribe(videoPath: "/tmp/idle_b.mov", deadlineSeconds: 60)
        #expect(text == "transcript::/tmp/idle_b.mov")
        #expect(await t.totalSpawns == 2)
    }

    // MARK: Framing unit (no subprocess)

    @Test("line channel: chunk splits, queued lines, partial tail at EOF, nil after")
    func lineChannelFraming() async {
        let ch = WorkerLineChannel()
        // One response split across chunk boundaries + a second whole
        // line in the same chunk — GCD hands us arbitrary splits.
        ch.append(Data("{\"id\":\"a\"".utf8))
        ch.append(Data(",\"ok\":true}\n{\"id\":\"b\"}\n".utf8))
        #expect(await ch.nextLine() == "{\"id\":\"a\",\"ok\":true}")
        #expect(await ch.nextLine() == "{\"id\":\"b\"}")

        ch.append(Data("partial-tail-no-newline".utf8))
        ch.finish()
        #expect(await ch.nextLine() == "partial-tail-no-newline",
                "EOF flushes the partial tail so diagnostics aren't lost")
        #expect(await ch.nextLine() == nil, "then EOF forever")
        #expect(await ch.nextLine() == nil)
    }

    // MARK: Isolation — ToolLocator env poisoning (injected env only)

    @Test("VS_WHISPER_WORKER_SCRIPT_PATH: override wins, poisoned override falls through, empty ignored")
    func toolLocatorWorkerScriptResolution() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperWorkerToolLocator_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("whisper_worker.py").path
        let override = dir.appendingPathComponent("override_worker.py").path
        FileManager.default.createFile(atPath: real, contents: Data("#".utf8))
        FileManager.default.createFile(atPath: override, contents: Data("#".utf8))

        // Valid override wins over candidates.
        #expect(ToolLocator.resolveExistingFile(
            envVar: ToolLocator.whisperWorkerScriptEnvVar,
            candidates: [real],
            environment: [ToolLocator.whisperWorkerScriptEnvVar: override]
        ) == override)

        // Poisoned override (nonexistent path) must fall through.
        #expect(ToolLocator.resolveExistingFile(
            envVar: ToolLocator.whisperWorkerScriptEnvVar,
            candidates: [real],
            environment: [ToolLocator.whisperWorkerScriptEnvVar: "/nope/poisoned.py"]
        ) == real)

        // Empty override ignored.
        #expect(ToolLocator.resolveExistingFile(
            envVar: ToolLocator.whisperWorkerScriptEnvVar,
            candidates: [real],
            environment: [ToolLocator.whisperWorkerScriptEnvVar: ""]
        ) == real)

        // Nothing anywhere → "" (callers gate on empty; no fabricated path).
        #expect(ToolLocator.resolveExistingFile(
            envVar: ToolLocator.whisperWorkerScriptEnvVar,
            candidates: ["/nope/a.py"],
            environment: [:]
        ).isEmpty)

        // Shape pins: env-var name is persisted in launchd plists /
        // docs, and the candidate list must point at the repo script.
        #expect(ToolLocator.whisperWorkerScriptEnvVar == "VS_WHISPER_WORKER_SCRIPT_PATH")
        #expect(ToolLocator.whisperWorkerScriptCandidates.allSatisfy {
            $0.hasSuffix("scripts/whisper_worker.py")
        })
        // The refactored per-file entry still resolves through the same
        // core — its env var must be unchanged.
        #expect(ToolLocator.whisperScriptEnvVar == "VS_WHISPER_SCRIPT_PATH")
    }
}

// MARK: - Integration: real dossier path with the fake worker

@MainActor
@Suite("Whisper worker — CaptionOrchestrator dossier integration")
struct WhisperWorkerDossierIntegrationTests {

    private func makeRecord(fullPath: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (fullPath as NSString).lastPathComponent
        r.fullPath = fullPath
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.durationSeconds = 3.0
        r.lifecycleStage = .cataloged
        return r
    }

    private func makeReachableTarget(at path: String) -> CatalogScanTarget {
        let t = CatalogScanTarget(searchPath: path)
        t.isReachable = true
        return t
    }

    @Test("pipelined dossier batch: per-file transcripts bank, ONE spawn, worker dead after settle")
    func dossierBatchOneWorkerKilledOnSettle() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else { return }
        let (script, dir) = try writeFakeWorker(echoWorkerBody)
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = VideoScanModel()
        let tmp = NSTemporaryDirectory()
        var paths: [String] = []
        var recs: [VideoRecord] = []
        for i in 0..<3 {
            let p = tmp + "vs-worker-dossier-\(i).mp4"
            FileManager.default.createFile(atPath: p, contents: Data("x".utf8))
            paths.append(p)
            recs.append(makeRecord(fullPath: p))
        }
        defer { for p in paths { try? FileManager.default.removeItem(atPath: p) } }
        model.records = recs
        model.scanTargets = [makeReachableTarget(at: tmp)]

        let vlm = StubDossierRunner(modelID: "stub-d-worker")
        let orch = CaptionOrchestrator(runnerFactory: { vlm })
        let worker = makeWorkerTranscriber(script: script)

        await orch.startCatalogWideDossier(model: model, transcriber: worker)

        guard case .finished(let captioned, let skipped, let failed) = orch.currentStatus else {
            Issue.record("Expected .finished, got \(orch.currentStatus)")
            return
        }
        #expect(captioned == 3)
        #expect(skipped == 0)
        #expect(failed == 0)

        for rec in recs {
            #expect(rec.audioTranscript == "transcript::\(rec.fullPath)",
                    "\(rec.filename) transcript must bank through the real applyDossier path")
            #expect(rec.audioTranscriptModel == worker.modelID)
            #expect(rec.dossierProcessedAt != nil)
        }

        // The two contract points of this whole feature:
        #expect(await worker.totalSpawns == 1, "3 files, 1 worker process")
        let died = await eventually { await !worker.isWorkerRunning }
        #expect(died, "batch settle must terminate the worker (settleWhisperWorker)")
        #expect(orch.activeWhisperWorker == nil, "lifecycle reference must be cleared on settle")
    }

    @Test("orchestrator cancel() kills the worker mid-batch")
    func cancelKillsWorkerMidBatch() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else { return }
        let (script, dir) = try writeFakeWorker(hangBody)
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = VideoScanModel()
        let tmp = NSTemporaryDirectory()
        // "hang" in the filename → the fake worker never answers, so
        // the batch wedges exactly the way the BT-music-video incident
        // did — cancel() must cut through it.
        let p = tmp + "vs-worker-hang-cancel.mp4"
        FileManager.default.createFile(atPath: p, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(atPath: p) }
        let rec = makeRecord(fullPath: p)
        model.records = [rec]
        model.scanTargets = [makeReachableTarget(at: tmp)]

        let vlm = StubDossierRunner(modelID: "stub-d-cancel")
        let orch = CaptionOrchestrator(runnerFactory: { vlm })
        let worker = makeWorkerTranscriber(script: script)

        let batch = Task {
            await orch.startCatalogWideDossier(model: model, transcriber: worker)
        }
        // Wait until the worker is actually mid-transcription.
        let spawned = await eventually { await worker.isWorkerRunning }
        #expect(spawned, "worker should be transcribing the hang file")

        orch.cancel()
        await batch.value

        let died = await eventually { await !worker.isWorkerRunning }
        #expect(died, "cancel() must terminate the worker subprocess")
        // VLM-only banking on cancel: extraction landed, transcript didn't.
        #expect(rec.dossierProcessedAt != nil, "VLM result must still bank when whisper is cancelled")
        #expect(rec.audioTranscript == nil || rec.audioTranscript?.isEmpty == true)
    }

    // MARK: Isolation — test-host guard

    @Test("test-host guard: nil transcriber does NOT auto-resolve the worker script (which exists in this repo)")
    func testHostGuardBlocksAutoResolution() async {
        // NEW risk this feature adds: scripts/whisper_worker.py ships
        // in the repo, so on any dev box with venv-mlx the resolution
        // closure WOULD now build a real worker — the isTestHost guard
        // is the only thing between this suite and a 244 MB model load.
        let model = VideoScanModel()
        let tmp = NSTemporaryDirectory()
        let p = tmp + "vs-worker-guard.mp4"
        FileManager.default.createFile(atPath: p, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(atPath: p) }
        let rec = makeRecord(fullPath: p)
        model.records = [rec]
        model.scanTargets = [makeReachableTarget(at: tmp)]

        let vlm = StubDossierRunner(modelID: "stub-d-guard")
        let orch = CaptionOrchestrator(runnerFactory: { vlm })

        await orch.startCatalogWideDossier(model: model, transcriber: nil)

        #expect(rec.audioTranscriptModel == nil,
                "no transcriber may auto-resolve inside a test host")
        #expect(rec.dossierProcessedBy?.contains("+") != true,
                "stack id must be VLM-only — a '+' means a real transcriber was resolved")
    }
}
