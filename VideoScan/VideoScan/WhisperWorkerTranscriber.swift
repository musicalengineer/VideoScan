import Foundation
import os

// MARK: - Whisper worker transcriber
//
// Persistent-worker sibling of PythonSubprocessAudioTranscriber. The
// per-file transcriber spawns a fresh `python whisper_transcribe.py`
// process for EVERY file, and each process reloads the whisper-medium
// weights (~244 MB, ~5 s) before doing any work — the 2026-07-14 perf
// diagnosis measured 888 spawns × ~5 s = 1.18 h of pure model reload
// in one nightly batch. This implementation keeps ONE
// `scripts/whisper_worker.py` process alive across the batch and
// talks to it over an NDJSON stdio protocol:
//
//   request  (worker stdin):  {"id":"<uuid>","path":"...","language":null}
//   response (worker stdout): {"id":"<uuid>","ok":true,"text":"..."}
//                          or {"id":"<uuid>","ok":false,"error":"..."}
//
// One line per message; the worker's stdout is protocol-pure (all of
// its diagnostics go to stderr, which we relay to the app log).
//
// Lifecycle contract:
//   * Lazy spawn on the first transcribe() of a batch.
//   * SIGTERM → 2 s grace → SIGKILL on: batch settle (the orchestrator
//     calls `shutdown()`), the 120 s idle timeout, a per-request
//     deadline expiry, and task cancellation.
//   * Worker crash mid-request → respawn + retry that file ONCE;
//     a second failure throws `.subprocessFailed` (the orchestrator's
//     per-file catch banks the VLM-only dossier and continues).
//   * Deadline expiry kills the worker (we cannot interrupt a
//     transcription in-process), throws `.deadlineExceeded`, and the
//     NEXT file lazily respawns. Deadline kills never retry.
//   * A response whose id doesn't match the in-flight request (or
//     isn't JSON at all) is a protocol error: kill + respawn.
//
// `actor` ≈ a class with an implicit mutex around all members — every
// method runs serialized on the actor's executor, so the handle /
// counters need no locks. BUT actor methods are re-entrant across
// `await` suspension points (unlike a held std::mutex), so a semaphore
// (`gate`) additionally serializes whole transcribe() calls: two
// concurrent callers must not interleave their request/response pairs
// on the single worker pipe.
//
// Worst-case memory footprint (Swift side): one buffered response line
// capped at 8 MB (transcripts are KB-scale; the cap is a runaway-worker
// guard) + a 64 KB stderr line-assembly buffer. The Python side holds
// the model weights + one file's decoded PCM, same as the per-file
// script — but only ONE such process instead of one per file.

private let workerLog = Logger(subsystem: "Rick-Breen.VideoScan",
                               category: "transcription")

// MARK: - Wire types

private struct WorkerRequest: Encodable {
    let id: String
    let path: String
    let language: String?
}

private struct WorkerResponse: Decodable {
    let id: String?
    let ok: Bool
    let text: String?
    let error: String?
}

/// Worker-side anomaly that is worth ONE respawn+retry (crash mid-
/// request, stdin write failure, protocol garbage). Internal control
/// flow only — it never escapes transcribe(); after the retry budget
/// is spent it is converted to `.subprocessFailed`.
private struct WorkerTransientError: Error {
    let message: String
}

// MARK: - Line channel (worker stdout → awaiting request)

/// Thread-safe NDJSON line assembler bridging the GCD readability
/// handler to an awaiting task. `nextLine()` suspends until a full
/// line arrives; returns nil on EOF (worker exited / was killed).
/// Exactly one waiter at a time by construction (requests are
/// serialized by the transcriber's gate).
final class WorkerLineChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var lines: [String] = []
    private var finished = false
    private var waiter: CheckedContinuation<String?, Never>?

    /// Runaway-worker guard: a correct worker emits KB-scale lines. If
    /// the pending (un-newlined) buffer passes this, we stop appending
    /// — the eventual line will fail JSON decoding upstream and the
    /// worker gets recycled as a protocol error. Bounded memory.
    private let maxBufferedBytes: Int

    init(maxBufferedBytes: Int = 8 * 1024 * 1024) {
        self.maxBufferedBytes = maxBufferedBytes
    }

    func append(_ data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        if buffer.count < maxBufferedBytes {
            buffer.append(data)
        }
        var resumeWaiter: CheckedContinuation<String?, Never>?
        var resumeLine: String?
        // Split complete lines off the front of the buffer.
        while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            let line = String(data: lineData, encoding: .utf8) ?? ""
            lines.append(line)
        }
        if waiter != nil, !lines.isEmpty {
            resumeWaiter = waiter
            waiter = nil
            resumeLine = lines.removeFirst()
        }
        lock.unlock()
        resumeWaiter?.resume(returning: resumeLine)
    }

    /// EOF / worker death. Idempotent. A pending waiter is resumed with
    /// any leftover partial line (shouldn't happen with a correct
    /// worker) or nil.
    func finish() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        if !buffer.isEmpty {
            let tail = String(data: buffer, encoding: .utf8) ?? ""
            buffer = Data()
            if !tail.isEmpty { lines.append(tail) }
        }
        let resumeWaiter = waiter
        waiter = nil
        // Only POP a line if someone is actually waiting for it — a
        // line queued with no waiter must stay queued for the next
        // nextLine() call (a response landing just before EOF would
        // otherwise be silently dropped; caught by the framing test).
        var resumeLine: String?
        if resumeWaiter != nil, !lines.isEmpty {
            resumeLine = lines.removeFirst()
        }
        lock.unlock()
        resumeWaiter?.resume(returning: resumeLine)
    }

    /// Await the next complete line; nil == EOF.
    func nextLine() async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            lock.lock()
            if !lines.isEmpty {
                let line = lines.removeFirst()
                lock.unlock()
                cont.resume(returning: line)
                return
            }
            if finished {
                lock.unlock()
                cont.resume(returning: nil)
                return
            }
            // Single-waiter contract; if it's ever violated, fail the
            // older waiter safely rather than leaking its continuation.
            let displaced = waiter
            waiter = cont
            lock.unlock()
            displaced?.resume(returning: nil)
        }
    }
}

// MARK: - Worker handle

/// One spawned worker process + its pipes. Reference type shared with
/// GCD handlers, the deadline watcher, and cancellation handlers, so
/// all mutation is behind a lock. The `killCause` records WHY the
/// worker was killed so the EOF observed by the awaiting request can
/// be classified (deadline vs cancel vs crash) after the fact — the
/// same one-writer-then-barrier pattern as AudioTranscriber's
/// KillReason.
final class WhisperWorkerHandle: @unchecked Sendable {

    enum KillCause: String { case deadline, cancelled, shutdown }

    let process: Process
    let pid: Int32
    let stdinHandle: FileHandle
    let stdoutHandle: FileHandle
    let stderrHandle: FileHandle
    let lines: WorkerLineChannel

    private let lock = NSLock()
    private var _killCause: KillCause?

    init(process: Process,
         stdinHandle: FileHandle,
         stdoutHandle: FileHandle,
         stderrHandle: FileHandle,
         lines: WorkerLineChannel) {
        self.process = process
        self.pid = process.processIdentifier
        self.stdinHandle = stdinHandle
        self.stdoutHandle = stdoutHandle
        self.stderrHandle = stderrHandle
        self.lines = lines
    }

    var isRunning: Bool { process.isRunning }

    var killCause: KillCause? {
        lock.lock(); defer { lock.unlock() }
        return _killCause
    }

    /// SIGTERM now, SIGKILL after `grace` if the worker lingers — the
    /// same escalation AudioTranscriber uses. First cause wins (e.g. a
    /// deadline kill racing a cancel keeps the deadline attribution).
    /// Safe to call multiple times; signals to an already-reaped pid
    /// are no-ops.
    func kill(cause: KillCause, grace: Double) {
        lock.lock()
        if _killCause == nil { _killCause = cause }
        lock.unlock()
        workerLog.notice("whisper worker pid \(self.pid) kill (\(cause.rawValue, privacy: .public)) — sending SIGTERM")
        Darwin.kill(pid, SIGTERM)
        let pid = self.pid
        let proc = process
        Task.detached {
            try? await Task.sleep(for: .seconds(grace))
            if proc.isRunning {
                workerLog.warning("whisper worker pid \(pid) ignored SIGTERM — sending SIGKILL")
                Darwin.kill(pid, SIGKILL)
            }
        }
    }

    /// Detach GCD handlers. Called exactly once, from the actor's
    /// tearDown. The pipe fds are released when the Pipe objects
    /// deallocate with this handle — deliberately NOT closed by hand
    /// (see ProcessRunner's crash-race saga for why closing a fd under
    /// a live readabilityHandler is a hard-crash hazard).
    func detachHandlers() {
        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        try? stdinHandle.close()
    }
}

// MARK: - External kill box

/// Lock-guarded mailbox so `terminateWorkerNow()` — called
/// synchronously from the MainActor lifecycle (cancel /
/// drainForShutdown) — can reach the current worker without hopping
/// onto the actor. Once latched, the transcriber refuses to (re)spawn:
/// a shutdown-time kill must not be answered with a fresh model load.
private final class ExternalKillBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: WhisperWorkerHandle?
    private var latched = false

    func update(_ handle: WhisperWorkerHandle?) {
        lock.lock()
        self.handle = handle
        lock.unlock()
    }

    var isLatched: Bool {
        lock.lock(); defer { lock.unlock() }
        return latched
    }

    /// Latch + hand back whatever is running so the caller can kill it.
    func latchAndTake() -> WhisperWorkerHandle? {
        lock.lock()
        latched = true
        let h = handle
        handle = nil
        lock.unlock()
        return h
    }
}

// MARK: - Stderr relay

/// Assembles the worker's stderr into lines and relays them to the app
/// log. Bounded: a partial line (e.g. a HuggingFace download progress
/// bar that only emits \r) is capped so it can't grow without limit.
private final class WorkerStderrRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""
    private let pendingCap = 64 * 1024

    func append(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        pending += text
        var parts = pending.components(separatedBy: "\n")
        pending = parts.removeLast()
        if pending.count > pendingCap {
            pending = String(pending.suffix(pendingCap))
        }
        lock.unlock()
        for line in parts {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { appLog.write("whisper-worker: \(trimmed)") }
        }
    }
}

// MARK: - Transcriber actor

actor WhisperWorkerTranscriber: AudioTranscriber {

    /// Same model, same weights, same output as the per-file Python
    /// transcriber — the worker is purely a spawn-count optimization,
    /// so provenance stamps stay identical (and the dashboard's
    /// stage-name mapping keys off "whisper" either way).
    nonisolated let modelID: String = "python-whisper-medium-mlx-q4"

    private let pythonPath: String
    private let scriptPath: String
    private let hfModel: String
    private let idleTimeoutSeconds: Double
    private let killGraceSeconds: Double
    /// Injectable audio preflight — production default is the shared
    /// `audioTrackIsPresent` gate (unchanged from the per-file path);
    /// tests stub it so fake workers don't need real audio fixtures.
    private let audioPreflight: @Sendable (String) async throws -> Bool

    private var handle: WhisperWorkerHandle?
    private var idleTask: Task<Void, Never>?
    /// Bumped at the start of every request; the idle timer captures
    /// the value at scheduling time and only fires if it still matches
    /// (i.e. no request arrived in between).
    private var requestGeneration = 0

    /// Test seam / regression sensor: total worker processes spawned
    /// over this instance's lifetime. The whole point of this type is
    /// that a happy-path batch of N files reads 1 here, not N.
    private(set) var totalSpawns = 0

    /// True while a live worker process exists. Test seam.
    var isWorkerRunning: Bool { handle?.isRunning ?? false }

    /// Serializes whole transcribe() calls across actor re-entrancy —
    /// one request/response pair in flight on the pipe at a time.
    private let gate = AsyncSemaphore(limit: 1)

    private nonisolated let killBox = ExternalKillBox()

    init(
        pythonPath: String,
        scriptPath: String,
        hfModel: String = "mlx-community/whisper-medium-mlx-q4",
        idleTimeoutSeconds: Double = 120,
        killGraceSeconds: Double = 2.0,
        audioPreflight: @escaping @Sendable (String) async throws -> Bool
            = { try await audioTrackIsPresent(at: $0) }
    ) {
        self.pythonPath = pythonPath
        self.scriptPath = scriptPath
        self.hfModel = hfModel
        self.idleTimeoutSeconds = idleTimeoutSeconds
        self.killGraceSeconds = killGraceSeconds
        self.audioPreflight = audioPreflight
    }

    // MARK: AudioTranscriber

    func transcribe(videoPath: String, deadlineSeconds: Double?) async throws -> String {
        try await gate.withPermit {
            try await self.serializedTranscribe(videoPath: videoPath,
                                                deadlineSeconds: deadlineSeconds)
        }
    }

    // MARK: Lifecycle (called by the orchestrator)

    /// Batch settled: terminate the worker (SIGTERM → grace → SIGKILL)
    /// and drop the handle. The actor stays usable — a later batch that
    /// reuses this instance lazily respawns.
    func shutdown() {
        idleTask?.cancel()
        idleTask = nil
        guard let h = handle else { return }
        workerLog.notice("whisper worker pid \(h.pid) shutdown — batch settled")
        h.kill(cause: .shutdown, grace: killGraceSeconds)
        tearDown(h)
    }

    /// Synchronous, callable from any isolation: kill the worker NOW
    /// and latch the instance dead — used by the orchestrator's
    /// cancel() / drainForShutdown(), which must not wait for an actor
    /// hop while a hung transcription blocks the batch task. After
    /// this, every in-flight or future transcribe() throws
    /// CancellationError (the orchestrator banks VLM-only).
    nonisolated func terminateWorkerNow() {
        guard let h = killBox.latchAndTake() else { return }
        workerLog.notice("whisper worker pid \(h.pid) terminate — orchestrator cancel/shutdown")
        h.kill(cause: .cancelled, grace: 2.0)
    }

    // MARK: - Serialized request path

    private func serializedTranscribe(videoPath: String,
                                      deadlineSeconds: Double?) async throws -> String {
        requestGeneration += 1
        idleTask?.cancel()
        idleTask = nil
        defer { scheduleIdleShutdown() }

        try Task.checkCancellation()
        if killBox.isLatched { throw CancellationError() }

        // Fail-fast audio gate — unchanged from the per-file path: no
        // point holding (or spawning) a model-loaded worker for a file
        // we can't hand audio to.
        let hasAudio = try await audioPreflight(videoPath)
        guard hasAudio else {
            throw AudioTranscriberError.audioUnreadable(path: videoPath)
        }

        // Retry budget: worker-side anomalies (crash mid-request,
        // protocol garbage) get exactly one respawn+retry. Deadline
        // expiry, cancellation, launch failures, and worker-reported
        // per-file errors propagate immediately.
        var lastTransient: WorkerTransientError?
        for attempt in 0..<2 {
            try Task.checkCancellation()
            if killBox.isLatched { throw CancellationError() }
            do {
                return try await performRequest(videoPath: videoPath,
                                                deadlineSeconds: deadlineSeconds)
            } catch let transient as WorkerTransientError {
                lastTransient = transient
                if attempt == 0 {
                    workerLog.warning("whisper worker anomaly (\(transient.message, privacy: .public)) — respawning for one retry of \((videoPath as NSString).lastPathComponent, privacy: .public)")
                }
            }
        }
        throw AudioTranscriberError.subprocessFailed(
            exitCode: -1,
            stderrTail: lastTransient?.message ?? "worker failed twice"
        )
    }

    private func performRequest(videoPath: String,
                                deadlineSeconds: Double?) async throws -> String {
        let h = try ensureWorker()
        let filename = (videoPath as NSString).lastPathComponent
        let requestID = UUID().uuidString

        let request = WorkerRequest(id: requestID, path: videoPath, language: nil)
        var payload: Data
        do {
            payload = try JSONEncoder().encode(request)  // single line — JSON escapes newlines
        } catch {
            throw AudioTranscriberError.underlying(error)
        }
        payload.append(UInt8(ascii: "\n"))
        do {
            try h.stdinHandle.write(contentsOf: payload)
        } catch {
            // Broken pipe: worker died between requests. Transient —
            // eligible for the one respawn+retry.
            tearDown(h)
            throw WorkerTransientError(message: "stdin write failed: \(error.localizedDescription)")
        }

        // Deadline watcher: we cannot interrupt a transcription inside
        // the worker, so expiry kills the whole process (the next file
        // lazily respawns). Cancelled on normal completion.
        let grace = killGraceSeconds
        let deadlineTask: Task<Void, Never>? = deadlineSeconds.map { dl in
            Task { [h] in
                try? await Task.sleep(for: .seconds(dl))
                guard !Task.isCancelled else { return }
                workerLog.warning("whisper worker exceeded \(dl, format: .fixed(precision: 0), privacy: .public)s deadline for \(filename, privacy: .public) — killing worker")
                h.kill(cause: .deadline, grace: grace)
            }
        }
        defer { deadlineTask?.cancel() }

        // Await the response line; onCancel kills the worker via the
        // Sendable handle (PID-capture pattern — the closure never
        // touches actor state), which closes the pipe and unblocks the
        // await with EOF.
        let line: String? = await withTaskCancellationHandler {
            await h.lines.nextLine()
        } onCancel: {
            h.kill(cause: .cancelled, grace: grace)
        }

        guard let line else {
            // EOF — classify by who pulled the trigger.
            tearDown(h)
            switch h.killCause {
            case .deadline:
                throw AudioTranscriberError.deadlineExceeded(seconds: deadlineSeconds ?? 0)
            case .cancelled, .shutdown:
                throw CancellationError()
            case nil:
                throw WorkerTransientError(message: "worker pid \(h.pid) exited mid-request")
            }
        }
        try Task.checkCancellation()

        guard let response = try? JSONDecoder().decode(WorkerResponse.self,
                                                       from: Data(line.utf8)),
              response.id == requestID else {
            // Garbage or stale/unknown id: the pipe state is untrusted
            // from here on — recycle the worker. Transient (one retry).
            workerLog.error("whisper worker protocol error — unexpected response line (\(line.prefix(120), privacy: .public))")
            h.kill(cause: .shutdown, grace: grace)
            tearDown(h)
            throw WorkerTransientError(message: "protocol error: unexpected response line")
        }

        guard response.ok else {
            // Worker answered, file-level failure (missing file, decode
            // error). Definitive — the worker stays alive, no retry.
            throw AudioTranscriberError.subprocessFailed(
                exitCode: 1,
                stderrTail: response.error ?? "worker reported failure"
            )
        }
        return response.text ?? ""
    }

    // MARK: - Worker process management

    private func ensureWorker() throws -> WhisperWorkerHandle {
        if let h = handle, h.isRunning { return h }
        if let h = handle { tearDown(h) }  // stale dead handle
        if killBox.isLatched { throw CancellationError() }

        guard FileManager.default.fileExists(atPath: pythonPath) else {
            throw AudioTranscriberError.subprocessLaunchFailed(
                reason: "Python interpreter missing: \(pythonPath)")
        }
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            throw AudioTranscriberError.subprocessLaunchFailed(
                reason: "Worker script missing: \(scriptPath)")
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = ["-u", scriptPath, "--model", hfModel]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        // mlx-whisper shells out to ffmpeg internally — same Homebrew
        // PATH fix as PythonSubprocessAudioTranscriber.
        env["PATH"] = augmentedPathWithHomebrew(
            inheriting: ProcessInfo.processInfo.environment["PATH"]
        )
        proc.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        let lines = WorkerLineChannel()
        let stderrRelay = WorkerStderrRelay()
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        stdoutHandle.readabilityHandler = { fh in
            let data = fh.availableData
            if data.isEmpty {
                fh.readabilityHandler = nil
                lines.finish()
            } else {
                lines.append(data)
            }
        }
        stderrHandle.readabilityHandler = { fh in
            let data = fh.availableData
            if data.isEmpty {
                fh.readabilityHandler = nil
            } else {
                stderrRelay.append(data)
            }
        }
        proc.terminationHandler = { _ in
            lines.finish()
        }

        do {
            try proc.run()
        } catch {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            throw AudioTranscriberError.subprocessLaunchFailed(
                reason: error.localizedDescription)
        }

        let h = WhisperWorkerHandle(process: proc,
                                    stdinHandle: stdinPipe.fileHandleForWriting,
                                    stdoutHandle: stdoutHandle,
                                    stderrHandle: stderrHandle,
                                    lines: lines)
        handle = h
        killBox.update(h)
        totalSpawns += 1
        workerLog.notice("whisper worker spawned pid \(h.pid) (spawn #\(self.totalSpawns) for this batch)")
        appLog.write("Whisper worker started (pid \(h.pid)) — model loads once, stays warm for the batch")
        return h
    }

    /// Drop a dead/killed handle. Idempotent per handle; only clears
    /// the actor's slot if it still points at that handle (a respawn
    /// may already have replaced it).
    private func tearDown(_ h: WhisperWorkerHandle) {
        h.detachHandlers()
        if handle === h {
            handle = nil
            killBox.update(nil)
        }
    }

    // MARK: - Idle timeout

    private func scheduleIdleShutdown() {
        guard handle != nil else { return }
        let generation = requestGeneration
        let timeout = idleTimeoutSeconds
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            await self?.idleKill(ifStillGeneration: generation)
        }
    }

    private func idleKill(ifStillGeneration generation: Int) {
        guard generation == requestGeneration, let h = handle else { return }
        workerLog.notice("whisper worker pid \(h.pid) idle for \(Int(self.idleTimeoutSeconds))s — terminating")
        h.kill(cause: .shutdown, grace: killGraceSeconds)
        tearDown(h)
    }
}
