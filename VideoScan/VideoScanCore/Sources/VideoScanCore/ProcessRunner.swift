// ProcessRunner.swift (VideoScanCore)
// Cancellation-aware subprocess execution — the single shell-out primitive
// for VideoScan. Lifted VERBATIM from the app target (2026-07-28, Stage 1
// of the out-of-process preview helper) so BOTH the app and the CLI helper
// invoke ffmpeg/ffprobe/Python through ONE runner instead of duplicating a
// Process wrapper (the project's ExecuteShellCommand-through-one-module
// rule). The app keeps every existing `ProcessRunner.*` call site working
// via `@_exported import VideoScanCore` (VideoScanCoreExports.swift); only
// the access level changed (internal → public) — behavior, threading, the
// fd-lifecycle state machine, and the deadline/kill escalation are all
// identical, and the app's ProcessRunnerFdLifecycleTests / *StressTests /
// *ConsolidationTests continue to pin them.
//
// For Rick: this was `enum ProcessRunner` in the app's ProcessRunner.swift;
// it moved down into the domain package so the CLI (which links only
// VideoScanCore, not the app) can shell out through the same code. The
// private helper boxes (PipeLifecycle, DeadlineFlag, …) stay private — no
// test reaches them directly.

import Darwin
import Foundation
import os

private let processRunnerLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                      category: "process-runner")

/// Cancellation-aware subprocess execution.
/// Wraps `Process` with `withTaskCancellationHandler` so running subprocesses
/// are terminated immediately when the parent task is cancelled.
public enum ProcessRunner {
    public struct Result: Sendable {
        public let stdout: String?
        public let stderr: String
        public let exitCode: Int32
        /// True when THIS run's `deadlineSeconds` expired and the runner
        /// itself signalled the child (GH #136). Exit codes alone cannot
        /// carry this: ffmpeg traps SIGTERM and exits nonzero exactly like
        /// a genuine decode failure, so without this flag "we killed it at
        /// our own deadline" and "the tool failed on the file" are
        /// indistinguishable — which is how a healthy 63.7 GB archive got
        /// a persisted "undecodable audio" damage verdict. Defaults false;
        /// callers that don't care see no change (additive).
        ///
        /// RACE NOTE: `timedOut` can be true alongside `exitCode == 0` —
        /// the child may finish in the instant between the deadline
        /// firing and the SIGTERM landing. Consumers must gate on a
        /// nonzero exit FIRST and only then consult `timedOut`;
        /// `succeeded` already answers correctly for that race.
        public var timedOut: Bool = false

        public var succeeded: Bool { exitCode == 0 && stdout != nil }
    }

    // MARK: - Capture stdout, discard stderr

    /// Run an executable and return its stdout as a string.
    /// Returns nil on failure or cancellation.
    public static func run(executable: String, arguments: [String]) async -> String? {
        await runProcess(executable: executable, arguments: arguments).stdout
    }

    // MARK: - Capture stdout + stderr

    /// Run an executable and return (stdout, stderr) as strings.
    /// Returns nil stdout on failure or cancellation; stderr is best-effort.
    /// `deadlineSeconds` (optional) bounds the subprocess itself — see
    /// `runProcess` for the SIGTERM → SIGKILL → abandon escalation.
    public static func runCapturingStderr(
        executable: String,
        arguments: [String],
        deadlineSeconds: Double? = nil
    ) async -> (stdout: String?, stderr: String) {
        let result = await runProcess(executable: executable, arguments: arguments,
                                      deadlineSeconds: deadlineSeconds)
        return (result.stdout, result.stderr)
    }

    /// Default SIGTERM → SIGKILL grace period for deadline/cancellation
    /// escalation. Long enough for ffmpeg/ffprobe to flush and exit cleanly
    /// on SIGTERM; short enough that a wedged child can't stall a scan.
    public static let defaultKillGraceSeconds: Double = 5.0

    /// Run an executable while draining stdout and stderr continuously.
    /// This is the safe default for ffmpeg/ffprobe/Python subprocesses: a child
    /// that writes more than the OS pipe buffer cannot block waiting for us to
    /// read after termination.
    ///
    /// - Parameters:
    ///   - stdoutLine: optional per-line callback for stdout (complete lines,
    ///     trimmed, delivered in order). Used by callers that parse progress
    ///     streams (e.g. ffmpeg `-progress pipe:1`).
    ///   - stderrLine: same, for stderr.
    ///   - stdoutLimitBytes / stderrLimitBytes: cap on the *collected* copy
    ///     returned in `Result`. `nil` = unbounded. Line callbacks always see
    ///     the full stream regardless of the cap.
    ///   - deadlineSeconds: optional bound on the *subprocess itself*, not
    ///     just the awaiting task. Task cancellation alone only sends SIGTERM
    ///     — a child blocked in uninterruptible kernel I/O (the classic case:
    ///     ffprobe stuck reading a dead SMB volume) ignores or never receives
    ///     it, its terminationHandler never fires, and the caller awaits
    ///     forever. The deadline escalates: SIGTERM at the deadline, SIGKILL
    ///     after `killGraceSeconds`, and if even SIGKILL can't reap the
    ///     child, the process is abandoned and the caller resumed with a
    ///     timed-out Result.
    ///   - killGraceSeconds: SIGTERM → SIGKILL (→ abandon) grace period.
    ///     One escalation path serves BOTH triggers — task cancellation and
    ///     `deadlineSeconds`. (C analogy: kill(pid, SIGTERM) then
    ///     kill(pid, SIGKILL) after a timeout — some tools trap TERM
    ///     mid-write and linger.)
    public static func runProcess(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        stdoutLine: (@Sendable (String) -> Void)? = nil,
        stderrLine: (@Sendable (String) -> Void)? = nil,
        stdoutLimitBytes: Int? = nil,
        stderrLimitBytes: Int? = 256 * 1024,
        deadlineSeconds: Double? = nil,
        killGraceSeconds: Double = ProcessRunner.defaultKillGraceSeconds
    ) async -> Result {
        guard !Task.isCancelled else {
            return Result(stdout: nil, stderr: "cancelled", exitCode: -1)
        }

        let proc = Process()
        proc.executableURL  = URL(fileURLWithPath: executable)
        proc.arguments      = arguments
        if let environment { proc.environment = environment }

        let stdoutPipe      = Pipe()
        let stderrPipe      = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError  = stderrPipe

        let stdoutCollector = DataCollector(limitBytes: stdoutLimitBytes)
        let stderrCollector = DataCollector(limitBytes: stderrLimitBytes)
        let stdoutStreamer = LineStreamer(lineHandler: stdoutLine)
        let stderrStreamer = LineStreamer(lineHandler: stderrLine)
        let completion = CompletionBox<Result>()
        let launchState = ProcessLaunchState()
        // Set exactly once, when the per-run deadline fires (before the
        // SIGTERM goes out); the terminationHandler copies it into
        // `Result.timedOut`. Task-cancellation kills do NOT set it — only
        // the runner's own deadline does (GH #136).
        let deadlineFlag = DeadlineFlag()

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        // fd-lifecycle box (walker-subtree-loss incident, 2026-07-02): owns
        // the deadline/escalation work items and closes the parent-side pipe
        // fds at the FIRST terminal event. Before this existed, the deadline
        // was a plain un-cancellable asyncAfter closure that pinned both
        // FileHandles (2 fds) for the full deadline — 300 s per ffprobe —
        // after the child had already exited. A fast rescan bursts hundreds
        // of probes inside that window, exhausting the GUI-app default
        // RLIMIT_NOFILE of 256; from then on contentsOfDirectory fails with
        // Cocoa error 256 (the scan walker loses whole subtrees) and new
        // Pipe()/spawn calls fail with EBADF. Pinned by
        // ProcessRunnerFdLifecycleTests.
        let lifecycle = PipeLifecycle(
            readHandles: [stdoutHandle, stderrHandle],
            writeHandles: [stdoutPipe.fileHandleForWriting, stderrPipe.fileHandleForWriting]
        )
        // CRASH-RACE GUARD (QA 2026-07-02): these handlers run on a GCD
        // thread and can be IN FLIGHT at the instant PipeLifecycle closes the
        // read fd (finishAfterChildExit / abandon). On a closed FileHandle,
        // a bare `handle.availableData` raises NSFileHandleOperationException
        // — an uncaught ObjC exception on a dispatch thread, i.e. a hard
        // crash of the whole app. `lifecycle.readAvailableData(from:)` makes
        // the read and the close MUTUALLY EXCLUSIVE (shared lock + state
        // check), so the race cannot occur at all. Do NOT "simplify" these
        // closures to a direct `handle.availableData` — the lifecycle gate
        // is load-bearing. (The throwing `read(upToCount:)` API is NOT a
        // usable alternative: on Darwin it blocks until count-or-EOF, which
        // stalls live progress streaming — verified empirically 2026-07-02.)
        stdoutHandle.readabilityHandler = { handle in
            let data = lifecycle.readAvailableData(from: handle)
            if !data.isEmpty {
                stdoutCollector.append(data)
                stdoutStreamer.append(data)
            }
        }
        stderrHandle.readabilityHandler = { handle in
            // Same crash-race guard as stdout above: reads must go through
            // the lifecycle gate, never a direct `availableData`.
            let data = lifecycle.readAvailableData(from: handle)
            if !data.isEmpty {
                stderrCollector.append(data)
                stderrStreamer.append(data)
            }
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                completion.setContinuation(continuation)
                proc.terminationHandler = makeTerminationHandler(
                    stdoutHandle: stdoutHandle, stderrHandle: stderrHandle,
                    stdoutCollector: stdoutCollector, stderrCollector: stderrCollector,
                    stdoutStreamer: stdoutStreamer, stderrStreamer: stderrStreamer,
                    completion: completion, lifecycle: lifecycle,
                    deadlineFlag: deadlineFlag
                )
                guard !Task.isCancelled, launchState.markLaunchingUnlessCancelled() else {
                    stdoutHandle.readabilityHandler = nil
                    stderrHandle.readabilityHandler = nil
                    lifecycle.finishNeverLaunched()
                    completion.resume(Result(stdout: nil, stderr: "cancelled", exitCode: -1))
                    return
                }
                launchAndArm(
                    proc: proc, executable: executable,
                    deadlineSeconds: deadlineSeconds, killGraceSeconds: killGraceSeconds,
                    stdoutHandle: stdoutHandle, stderrHandle: stderrHandle,
                    completion: completion, lifecycle: lifecycle,
                    launchState: launchState, deadlineFlag: deadlineFlag
                )
            }
        } onCancel: {
            launchState.markCancelled()
            if proc.isRunning {
                proc.terminate()
                // Escalate SIGTERM → SIGKILL (→ abandon) if the child lingers
                // past the grace period. `isRunning` is re-checked at fire
                // time so a child that exited cleanly is never signalled again.
                escalateAfterTerminate(
                    proc: proc, executable: executable,
                    killGraceSeconds: killGraceSeconds,
                    stdoutHandle: stdoutHandle, stderrHandle: stderrHandle,
                    completion: completion, lifecycle: lifecycle,
                    deadlineFlag: deadlineFlag,
                    reason: "cancelled"
                )
            }
        }
    }

    /// Build the Process terminationHandler: drain both pipes, release the
    /// per-run fd lifecycle, resume the caller. Extracted from `runProcess`
    /// purely for function-length hygiene — behavior is identical.
    private static func makeTerminationHandler(
        stdoutHandle: FileHandle,
        stderrHandle: FileHandle,
        stdoutCollector: DataCollector,
        stderrCollector: DataCollector,
        stdoutStreamer: LineStreamer,
        stderrStreamer: LineStreamer,
        completion: CompletionBox<Result>,
        lifecycle: PipeLifecycle,
        deadlineFlag: DeadlineFlag
    ) -> (@Sendable (Process) -> Void) {
        return { process in
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil

            // If the abandon path already closed the handles (child was
            // declared unkillable but eventually exited), the drain below
            // would raise on a closed fd — skip it; the caller was already
            // resumed with the timed-out Result.
            guard lifecycle.beginDraining() else { return }

            let remainingOut = stdoutHandle.readDataToEndOfFile()
            if !remainingOut.isEmpty {
                stdoutCollector.append(remainingOut)
                stdoutStreamer.append(remainingOut)
            }
            stdoutStreamer.finish()

            let remainingErr = stderrHandle.readDataToEndOfFile()
            if !remainingErr.isEmpty {
                stderrCollector.append(remainingErr)
                stderrStreamer.append(remainingErr)
            }
            stderrStreamer.finish()

            // Child exited: cancel any pending deadline/escalation work
            // items and close the parent-side READ fds NOW — not 300 s from
            // now when the deadline block fires.
            lifecycle.finishAfterChildExit()

            completion.resume(
                Result(
                    stdout: stdoutCollector.string,
                    stderr: stderrCollector.string ?? "",
                    exitCode: process.terminationStatus,
                    timedOut: deadlineFlag.didFire
                )
            )
        }
    }

    /// Launch the child and arm the deadline/cancellation escalation.
    /// Extracted from `runProcess` for function-length hygiene.
    private static func launchAndArm(
        proc: Process,
        executable: String,
        deadlineSeconds: Double?,
        killGraceSeconds: Double,
        stdoutHandle: FileHandle,
        stderrHandle: FileHandle,
        completion: CompletionBox<Result>,
        lifecycle: PipeLifecycle,
        launchState: ProcessLaunchState,
        deadlineFlag: DeadlineFlag
    ) {
        do {
            try proc.run()
            if let deadlineSeconds {
                scheduleDeadline(
                    afterSeconds: deadlineSeconds,
                    killGraceSeconds: killGraceSeconds,
                    proc: proc,
                    executable: executable,
                    stdoutHandle: stdoutHandle,
                    stderrHandle: stderrHandle,
                    completion: completion,
                    lifecycle: lifecycle,
                    deadlineFlag: deadlineFlag
                )
            }
            if launchState.isCancelled, proc.isRunning {
                proc.terminate()
                escalateAfterTerminate(
                    proc: proc, executable: executable,
                    killGraceSeconds: killGraceSeconds,
                    stdoutHandle: stdoutHandle, stderrHandle: stderrHandle,
                    completion: completion, lifecycle: lifecycle,
                    deadlineFlag: deadlineFlag,
                    reason: "cancelled"
                )
            }
        } catch {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            // The child never spawned, so every pipe end is still
            // parent-owned — close all four or a misconfigured tool path
            // leaks fds on every attempt.
            lifecycle.finishNeverLaunched()
            completion.resume(Result(stdout: nil, stderr: error.localizedDescription, exitCode: -1))
        }
    }

    // MARK: - Deadline / kill escalation

    /// Fire the subprocess deadline: SIGTERM, then escalate. No-op if the
    /// process already exited (`isRunning` guard) — normal completions never
    /// see any of this.
    private static func scheduleDeadline(
        afterSeconds: Double,
        killGraceSeconds: Double,
        proc: Process,
        executable: String,
        stdoutHandle: FileHandle,
        stderrHandle: FileHandle,
        completion: CompletionBox<Result>,
        lifecycle: PipeLifecycle,
        deadlineFlag: DeadlineFlag
    ) {
        let tool = (executable as NSString).lastPathComponent
        // Cancellable work item, NOT a bare asyncAfter closure: when the
        // child exits normally, finishAfterChildExit() cancels this item so
        // it cannot pin the Process + FileHandles (and their fds) for the
        // remaining deadline (walker-subtree-loss incident, 2026-07-02).
        lifecycle.schedule(on: DispatchQueue.global(qos: .utility), after: afterSeconds) {
            guard proc.isRunning else { return }
            // Mark BEFORE signalling so the terminationHandler (which can
            // run immediately after terminate()) always sees it (GH #136).
            deadlineFlag.markFired()
            processRunnerLog.warning("\(tool, privacy: .public) pid \(proc.processIdentifier) exceeded \(afterSeconds, format: .fixed(precision: 0), privacy: .public)s deadline — sending SIGTERM")
            proc.terminate()
            escalateAfterTerminate(
                proc: proc, executable: executable,
                killGraceSeconds: killGraceSeconds,
                stdoutHandle: stdoutHandle, stderrHandle: stderrHandle,
                completion: completion, lifecycle: lifecycle,
                deadlineFlag: deadlineFlag,
                reason: "deadline \(Int(afterSeconds))s"
            )
        }
    }

    /// After SIGTERM has been sent: SIGKILL once the grace period lapses, and
    /// if the child survives even SIGKILL (stuck in uninterruptible kernel
    /// I/O — e.g. a read against a dead SMB mount, where the kernel can't
    /// deliver any signal until the I/O returns), abandon it: detach the pipe
    /// handlers and resume the caller with a failed Result. Without the
    /// abandon step, terminationHandler never fires and the awaiting task —
    /// and the whole scan behind it — hangs forever.
    ///
    /// PID-reuse safety: SIGKILL is only sent while `proc.isRunning` is true,
    /// i.e. while Foundation still owns the unreaped child, so the pid cannot
    /// yet have been recycled (modulo a microsecond TOCTOU window that is
    /// inherent to kill(2) and accepted here).
    private static func escalateAfterTerminate(
        proc: Process,
        executable: String,
        killGraceSeconds: Double,
        stdoutHandle: FileHandle,
        stderrHandle: FileHandle,
        completion: CompletionBox<Result>,
        lifecycle: PipeLifecycle,
        deadlineFlag: DeadlineFlag,
        reason: String
    ) {
        let tool = (executable as NSString).lastPathComponent
        let queue = DispatchQueue.global(qos: .utility)
        lifecycle.schedule(on: queue, after: killGraceSeconds) {
            guard proc.isRunning else { return }
            processRunnerLog.warning("\(tool, privacy: .public) pid \(proc.processIdentifier) ignored SIGTERM (\(reason, privacy: .public)) — sending SIGKILL")
            kill(proc.processIdentifier, SIGKILL)
            lifecycle.schedule(on: queue, after: killGraceSeconds) {
                guard proc.isRunning else { return }
                processRunnerLog.error("\(tool, privacy: .public) pid \(proc.processIdentifier) survived SIGKILL (uninterruptible I/O?) — abandoning process and resuming caller")
                stdoutHandle.readabilityHandler = nil
                stderrHandle.readabilityHandler = nil
                // Abandon also RELEASES the parent-side read fds — the whole
                // point is that a wedged child must not pin scan resources.
                // beginDraining()/abandon() are mutually exclusive, so a
                // child that exits after abandonment cannot double-drain.
                if lifecycle.abandon() {
                    completion.resume(Result(stdout: nil,
                                             stderr: "timed out (\(reason)); process unkillable, abandoned",
                                             exitCode: -1,
                                             timedOut: deadlineFlag.didFire))
                }
            }
        }
    }

    // MARK: - Stream stderr to callback, capture stdout for structured output

    /// Run an executable, streaming stderr line-by-line to `stderrLine`,
    /// and return the full stdout string when the process exits.
    ///
    /// Designed for tools (e.g. Python recognition scripts) that write
    /// human-readable progress to stderr and machine-readable JSON to stdout.
    /// Returns nil if the process could not be launched or was cancelled.
    public static func runStreaming(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        stderrLine: @escaping @Sendable (String) -> Void
    ) async -> String? {
        let result = await runProcess(
            executable: executable,
            arguments: arguments,
            environment: environment,
            stderrLine: stderrLine
        )
        if result.exitCode == -1, result.stdout == nil, !result.stderr.isEmpty {
            stderrLine("Could not launch: \(executable) — \(result.stderr)")
        }
        return result.stdout
    }

    /// Per-run fd lifecycle: owns the deadline/escalation DispatchWorkItems
    /// and the parent-side pipe FileHandles, and guarantees the fds are
    /// released at the FIRST terminal event instead of when the last
    /// asyncAfter block fires (walker-subtree-loss incident, 2026-07-02 —
    /// see the note in `runProcess` and ProcessRunnerFdLifecycleTests).
    ///
    /// For Rick: a mutex-guarded state machine —
    ///   running → draining → closed   (normal child exit)
    ///   running → closed              (abandon / never launched)
    /// `draining` exists so the abandon block and the terminationHandler can
    /// never both operate on the handles: whoever transitions first wins.
    private final class PipeLifecycle: @unchecked Sendable {
        private enum State { case running, draining, closed }

        private let lock = NSLock()
        /// Serializes readabilityHandler reads against the explicit read-fd
        /// close (crash-race guard, QA 2026-07-02) — separate from `lock` so
        /// a read in progress never blocks state transitions or scheduling.
        private let readLock = NSLock()
        private var state: State = .running
        private var workItems: [DispatchWorkItem] = []
        private let readHandles: [FileHandle]
        private let writeHandles: [FileHandle]

        init(readHandles: [FileHandle], writeHandles: [FileHandle]) {
            self.readHandles = readHandles
            self.writeHandles = writeHandles
        }

        /// Crash-race guard for the readabilityHandler closures: an in-flight
        /// handler invocation can otherwise race the explicit read-fd close
        /// in `finishAfterChildExit()`/`abandon()`, and `availableData` on a
        /// closed FileHandle raises NSFileHandleOperationException — an
        /// uncaught ObjC exception on a GCD thread, i.e. a hard app crash.
        /// Holding `readLock` across BOTH this read and the close (see
        /// `close(alsoWriteEnds:expected:)`) makes them mutually exclusive:
        /// once the state is `.closed` the handler sees it here and returns
        /// empty instead of touching a dead handle. `availableData` cannot
        /// stall the lock: dispatch only invokes the handler when the fd is
        /// readable (data or EOF), so the read returns immediately.
        func readAvailableData(from handle: FileHandle) -> Data {
            readLock.lock()
            defer { readLock.unlock() }
            lock.lock()
            let isClosed = state == .closed
            lock.unlock()
            guard !isClosed else { return Data() }
            return handle.availableData
        }

        /// Schedule a cancellable deadline/escalation block. No-op when the
        /// run already reached a terminal state (e.g. the deadline fired,
        /// SIGTERM worked, terminationHandler finished the run, and only
        /// then the escalation tries to arm the SIGKILL stage).
        func schedule(on queue: DispatchQueue, after seconds: Double,
                      _ body: @escaping @Sendable () -> Void) {
            let item = DispatchWorkItem(block: body)
            lock.lock()
            guard state == .running else {
                lock.unlock()
                return
            }
            workItems.append(item)
            lock.unlock()
            queue.asyncAfter(deadline: .now() + seconds, execute: item)
        }

        /// terminationHandler entry gate: running → draining. Returns false
        /// when the run was already closed (abandoned) — the handles are
        /// gone, so the caller must not touch them.
        func beginDraining() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard state == .running else { return false }
            state = .draining
            return true
        }

        /// Normal child exit (after draining): cancel pending work items and
        /// close the parent-side READ fds. The write ends were handed to the
        /// child at spawn — Foundation already closed the parent's copies,
        /// so they are deliberately NOT touched here (double-close hazard).
        func finishAfterChildExit() {
            close(alsoWriteEnds: false, expected: .draining)
        }

        /// The child never spawned (pre-launch cancel, `run()` throw): every
        /// pipe end is still parent-owned, so all four fds are closed.
        func finishNeverLaunched() {
            close(alsoWriteEnds: true, expected: .running)
        }

        /// Unkillable-child abandonment: release the read fds so a wedged
        /// child cannot pin scan resources. Returns false if the child beat
        /// us to terminationHandler (that path owns cleanup + resume).
        func abandon() -> Bool {
            close(alsoWriteEnds: false, expected: .running)
        }

        @discardableResult
        private func close(alsoWriteEnds: Bool, expected: State) -> Bool {
            lock.lock()
            guard state == expected else {
                lock.unlock()
                return false
            }
            state = .closed
            let items = workItems
            workItems = []
            lock.unlock()
            for item in items { item.cancel() }
            // readLock pairs with readAvailableData(from:): wait out any
            // in-flight readabilityHandler read before closing its fd, and
            // any handler arriving after this sees state == .closed and
            // never touches the handle. (`lock` is NOT held here, so the
            // handler's brief lock/unlock state check cannot deadlock.)
            readLock.lock()
            for handle in readHandles { try? handle.close() }
            readLock.unlock()
            if alsoWriteEnds {
                for handle in writeHandles { try? handle.close() }
            }
            return true
        }
    }

    /// One-way latch: set when THIS run's `deadlineSeconds` expired (GH
    /// #136). Written on the deadline's utility queue, read from the
    /// terminationHandler's GCD thread — hence the lock. (For Rick: a
    /// mutex-guarded bool; std::atomic<bool> would do in C++, but the
    /// repo's convention for these tiny boxes is NSLock.)
    private final class DeadlineFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false

        func markFired() {
            lock.lock()
            fired = true
            lock.unlock()
        }

        var didFire: Bool {
            lock.lock()
            defer { lock.unlock() }
            return fired
        }
    }

    /// Thread-safe collector for pipe data arriving via readabilityHandler.
    private final class DataCollector: @unchecked Sendable {
        private let lock = NSLock()
        private let limitBytes: Int?
        private var data = Data()

        init(limitBytes: Int? = nil) {
            self.limitBytes = limitBytes
        }

        func append(_ chunk: Data) {
            lock.lock()
            if let limitBytes {
                let remaining = max(0, limitBytes - data.count)
                if remaining > 0 {
                    data.append(chunk.prefix(remaining))
                }
            } else {
                data.append(chunk)
            }
            lock.unlock()
        }

        var string: String? {
            lock.lock()
            let result = String(data: data, encoding: .utf8)
            lock.unlock()
            return result
        }
    }

    private final class LineStreamer: @unchecked Sendable {
        private let lock = NSLock()
        private let lineHandler: (@Sendable (String) -> Void)?
        private var pending = ""

        init(lineHandler: (@Sendable (String) -> Void)?) {
            self.lineHandler = lineHandler
        }

        func append(_ data: Data) {
            guard let lineHandler,
                  let text = String(data: data, encoding: .utf8) else { return }
            lock.lock()
            pending += text
            let parts = pending.components(separatedBy: "\n")
            pending = parts.last ?? ""
            let complete = parts.dropLast()
            lock.unlock()

            for line in complete {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { lineHandler(trimmed) }
            }
        }

        func finish() {
            guard let lineHandler else { return }
            lock.lock()
            let tail = pending.trimmingCharacters(in: .whitespacesAndNewlines)
            pending = ""
            lock.unlock()
            if !tail.isEmpty { lineHandler(tail) }
        }
    }

    private final class CompletionBox<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Never>?
        private var result: T?

        func setContinuation(_ continuation: CheckedContinuation<T, Never>) {
            lock.lock()
            if let result {
                self.result = nil
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }

        func resume(_ value: T) {
            lock.lock()
            if let continuation {
                self.continuation = nil
                lock.unlock()
                continuation.resume(returning: value)
            } else if result == nil {
                result = value
                lock.unlock()
            } else {
                lock.unlock()
            }
        }
    }

    private final class ProcessLaunchState: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func markLaunchingUnlessCancelled() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled else { return false }
            return true
        }

        func markCancelled() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock()
            let result = cancelled
            lock.unlock()
            return result
        }
    }
}
