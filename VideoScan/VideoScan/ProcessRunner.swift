import Darwin
import Foundation
import os

private let processRunnerLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                      category: "process-runner")

/// Resolves filesystem paths for external command-line tools (ffmpeg, ffprobe,
/// Python) that VideoScan shells out to. Single source of truth so hard-coded
/// candidate lists don't spread through the codebase.
///
/// Resolution order for each tool:
///   1. Environment variable override (e.g. `VS_FFMPEG_PATH`) — wins if set
///      AND the path is executable. Lets users point at a non-standard
///      install (Nix, manual build, etc.) without recompiling.
///   2. First executable candidate from the built-in list.
///   3. Fallback string (preserves prior behavior — callers see a "command
///      not found" error rather than an empty-string crash).
///
/// Tested in `ToolLocatorTests`.
enum ToolLocator {
    // MARK: - Env-var override names (public for tests + docs)
    static let ffmpegEnvVar = "VS_FFMPEG_PATH"
    static let ffprobeEnvVar = "VS_FFPROBE_PATH"
    static let pythonEnvVar = "VS_PYTHON_PATH"
    static let python312EnvVar = "VS_PYTHON312_PATH"
    /// MLX-side Python — separate venv (`venv-mlx`) because mlx-whisper
    /// requires numpy>=2 while the dlib face-recognition env is pinned
    /// to numpy<2. Resolved independently from the dlib venv above.
    static let mlxPythonEnvVar = "VS_MLX_PYTHON_PATH"
    /// Path to scripts/whisper_transcribe.py — Whisper transcription
    /// driver run by `PythonSubprocessAudioTranscriber`. Env override
    /// lets test machines / CI point at the shipped script directly.
    static let whisperScriptEnvVar = "VS_WHISPER_SCRIPT_PATH"

    static let ffmpegCandidates = [
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
        "/usr/bin/ffmpeg"
    ]
    static let ffprobeCandidates = [
        "/opt/homebrew/bin/ffprobe",
        "/usr/local/bin/ffprobe",
        "/usr/bin/ffprobe"
    ]
    static let pythonCandidates = [
        NSHomeDirectory() + "/dev/VideoScan/venv/bin/python3",
        FileManager.default.currentDirectoryPath + "/.venv/bin/python",
        FileManager.default.currentDirectoryPath + "/venv/bin/python",
        "/opt/homebrew/bin/python3",
        "/usr/bin/python3"
    ]
    static let python312Candidates = [
        NSHomeDirectory() + "/dev/VideoScan/venv/bin/python3.12",
        FileManager.default.currentDirectoryPath + "/venv/bin/python3.12",
        "/opt/homebrew/bin/python3.12",
        "/usr/local/bin/python3.12"
    ]
    static let mlxPythonCandidates = [
        NSHomeDirectory() + "/dev/VideoScan/venv-mlx/bin/python",
        NSHomeDirectory() + "/dev/VideoScan/venv-mlx/bin/python3",
        FileManager.default.currentDirectoryPath + "/venv-mlx/bin/python"
    ]
    static let whisperScriptCandidates = [
        NSHomeDirectory() + "/dev/VideoScan/scripts/whisper_transcribe.py",
        FileManager.default.currentDirectoryPath + "/scripts/whisper_transcribe.py"
    ]

    static func firstExecutable(
        in candidates: [String],
        fileManager: FileManager = .default
    ) -> String? {
        candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// Resolve a tool path: env-var override (if set & executable) wins,
    /// otherwise first executable candidate, otherwise the supplied fallback.
    /// Exposed for tests; production accessors below use a default environment.
    static func resolve(
        envVar: String,
        candidates: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        fallback: String
    ) -> String {
        if let override = environment[envVar],
           !override.isEmpty,
           fileManager.isExecutableFile(atPath: override) {
            return override
        }
        if let found = firstExecutable(in: candidates, fileManager: fileManager) {
            return found
        }
        return fallback
    }

    static var ffmpegPath: String {
        resolve(envVar: ffmpegEnvVar, candidates: ffmpegCandidates, fallback: ffmpegCandidates[0])
    }

    static var ffprobePath: String {
        resolve(envVar: ffprobeEnvVar, candidates: ffprobeCandidates, fallback: ffprobeCandidates[0])
    }

    /// pythonPath returns "" if nothing resolves — callers gate on this
    /// (rather than failing when the binary doesn't exist).
    static var pythonPath: String {
        resolve(envVar: pythonEnvVar, candidates: pythonCandidates, fallback: "")
    }

    static var python312Path: String {
        resolve(envVar: python312EnvVar, candidates: python312Candidates, fallback: python312Candidates[0])
    }

    /// MLX venv Python — empty if not present. Used by the Whisper
    /// transcription subprocess (mlx-whisper) and any future MLX-side
    /// Python script that can't be ported to mlx-swift yet.
    static var mlxPythonPath: String {
        resolve(envVar: mlxPythonEnvVar, candidates: mlxPythonCandidates, fallback: "")
    }

    /// Path to the Whisper transcription script. Empty if not findable
    /// — caller must gate. Same shape as `pythonPath` (returns "" on
    /// miss rather than fabricating a path that won't exist).
    static var whisperScriptPath: String {
        // File-existence check, not executable bit — .py files aren't
        // executable, the Python interpreter is.
        if let override = ProcessInfo.processInfo.environment[whisperScriptEnvVar],
           !override.isEmpty,
           FileManager.default.fileExists(atPath: override) {
            return override
        }
        for candidate in whisperScriptCandidates where FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }
        return ""
    }
}

/// Cancellation-aware subprocess execution.
/// Wraps `Process` with `withTaskCancellationHandler` so running subprocesses
/// are terminated immediately when the parent task is cancelled.
enum ProcessRunner {
    struct Result: Sendable {
        let stdout: String?
        let stderr: String
        let exitCode: Int32

        var succeeded: Bool { exitCode == 0 && stdout != nil }
    }

    // MARK: - Capture stdout, discard stderr

    /// Run an executable and return its stdout as a string.
    /// Returns nil on failure or cancellation.
    static func run(executable: String, arguments: [String]) async -> String? {
        await runProcess(executable: executable, arguments: arguments).stdout
    }

    // MARK: - Capture stdout + stderr

    /// Run an executable and return (stdout, stderr) as strings.
    /// Returns nil stdout on failure or cancellation; stderr is best-effort.
    /// `deadlineSeconds` (optional) bounds the subprocess itself — see
    /// `runProcess` for the SIGTERM → SIGKILL → abandon escalation.
    static func runCapturingStderr(
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
    static let defaultKillGraceSeconds: Double = 5.0

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
    static func runProcess(
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

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        stdoutHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stdoutCollector.append(data)
                stdoutStreamer.append(data)
            }
        }
        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stderrCollector.append(data)
                stderrStreamer.append(data)
            }
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                completion.setContinuation(continuation)
                proc.terminationHandler = { process in
                    stdoutHandle.readabilityHandler = nil
                    stderrHandle.readabilityHandler = nil

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

                    completion.resume(
                        Result(
                            stdout: stdoutCollector.string,
                            stderr: stderrCollector.string ?? "",
                            exitCode: process.terminationStatus
                        )
                    )
                }
                guard !Task.isCancelled else {
                    stdoutHandle.readabilityHandler = nil
                    stderrHandle.readabilityHandler = nil
                    completion.resume(Result(stdout: nil, stderr: "cancelled", exitCode: -1))
                    return
                }
                guard launchState.markLaunchingUnlessCancelled() else {
                    stdoutHandle.readabilityHandler = nil
                    stderrHandle.readabilityHandler = nil
                    completion.resume(Result(stdout: nil, stderr: "cancelled", exitCode: -1))
                    return
                }
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
                            completion: completion
                        )
                    }
                    if launchState.isCancelled, proc.isRunning {
                        proc.terminate()
                        escalateAfterTerminate(
                            proc: proc, executable: executable,
                            killGraceSeconds: killGraceSeconds,
                            stdoutHandle: stdoutHandle, stderrHandle: stderrHandle,
                            completion: completion, reason: "cancelled"
                        )
                    }
                } catch {
                    stdoutHandle.readabilityHandler = nil
                    stderrHandle.readabilityHandler = nil
                    completion.resume(Result(stdout: nil, stderr: error.localizedDescription, exitCode: -1))
                }
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
                    completion: completion, reason: "cancelled"
                )
            }
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
        completion: CompletionBox<Result>
    ) {
        let tool = (executable as NSString).lastPathComponent
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + afterSeconds) {
            guard proc.isRunning else { return }
            processRunnerLog.warning("\(tool, privacy: .public) pid \(proc.processIdentifier) exceeded \(afterSeconds, format: .fixed(precision: 0), privacy: .public)s deadline — sending SIGTERM")
            proc.terminate()
            escalateAfterTerminate(
                proc: proc, executable: executable,
                killGraceSeconds: killGraceSeconds,
                stdoutHandle: stdoutHandle, stderrHandle: stderrHandle,
                completion: completion, reason: "deadline \(Int(afterSeconds))s"
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
        reason: String
    ) {
        let tool = (executable as NSString).lastPathComponent
        let queue = DispatchQueue.global(qos: .utility)
        queue.asyncAfter(deadline: .now() + killGraceSeconds) {
            guard proc.isRunning else { return }
            processRunnerLog.warning("\(tool, privacy: .public) pid \(proc.processIdentifier) ignored SIGTERM (\(reason, privacy: .public)) — sending SIGKILL")
            kill(proc.processIdentifier, SIGKILL)
            queue.asyncAfter(deadline: .now() + killGraceSeconds) {
                guard proc.isRunning else { return }
                processRunnerLog.error("\(tool, privacy: .public) pid \(proc.processIdentifier) survived SIGKILL (uninterruptible I/O?) — abandoning process and resuming caller")
                stdoutHandle.readabilityHandler = nil
                stderrHandle.readabilityHandler = nil
                completion.resume(Result(stdout: nil,
                                         stderr: "timed out (\(reason)); process unkillable, abandoned",
                                         exitCode: -1))
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
    static func runStreaming(
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
