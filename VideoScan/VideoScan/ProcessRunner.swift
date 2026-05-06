import Foundation

enum ToolLocator {
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

    static func firstExecutable(
        in candidates: [String],
        fileManager: FileManager = .default
    ) -> String? {
        candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    static var ffmpegPath: String {
        firstExecutable(in: ffmpegCandidates) ?? ffmpegCandidates[0]
    }

    static var ffprobePath: String {
        firstExecutable(in: ffprobeCandidates) ?? ffprobeCandidates[0]
    }

    static var pythonPath: String {
        firstExecutable(in: pythonCandidates) ?? ""
    }

    static var python312Path: String {
        firstExecutable(in: python312Candidates) ?? python312Candidates[0]
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
                do {
                    try proc.run()
                } catch {
                    stdoutHandle.readabilityHandler = nil
                    stderrHandle.readabilityHandler = nil
                    completion.resume(Result(stdout: nil, stderr: error.localizedDescription, exitCode: -1))
                }
            }
        } onCancel: {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            if proc.isRunning {
                proc.terminate()
            } else {
                completion.resume(Result(stdout: nil, stderr: "cancelled", exitCode: -1))
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

    private final class CompletionBox<T>: @unchecked Sendable {
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
}
