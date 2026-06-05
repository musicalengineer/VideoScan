import Foundation

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
    static func runCapturingStderr(executable: String, arguments: [String]) async -> (stdout: String?, stderr: String) {
        let result = await runProcess(executable: executable, arguments: arguments)
        return (result.stdout, result.stderr)
    }

    /// Run an executable while draining stdout and stderr continuously.
    /// This is the safe default for ffmpeg/ffprobe/Python subprocesses: a child
    /// that writes more than the OS pipe buffer cannot block waiting for us to
    /// read after termination.
    static func runProcess(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        stderrLine: (@Sendable (String) -> Void)? = nil,
        stderrLimitBytes: Int = 256 * 1024
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

        let stdoutCollector = DataCollector()
        let stderrCollector = DataCollector(limitBytes: stderrLimitBytes)
        let stderrStreamer = LineStreamer(lineHandler: stderrLine)
        let completion = CompletionBox<Result>()
        let launchState = ProcessLaunchState()

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        stdoutHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { stdoutCollector.append(data) }
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
                    if !remainingOut.isEmpty { stdoutCollector.append(remainingOut) }

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
                    if launchState.isCancelled, proc.isRunning {
                        proc.terminate()
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
