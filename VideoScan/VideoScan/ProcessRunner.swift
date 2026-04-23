import Foundation

/// Cancellation-aware subprocess execution.
/// Wraps `Process` with `withTaskCancellationHandler` so running subprocesses
/// are terminated immediately when the parent task is cancelled.
enum ProcessRunner {

    // MARK: - Capture stdout, discard stderr

    /// Run an executable and return its stdout as a string.
    /// Returns nil on failure or cancellation.
    static func run(executable: String, arguments: [String]) async -> String? {
        let proc = Process()
        proc.executableURL  = URL(fileURLWithPath: executable)
        proc.arguments      = arguments
        let stdoutPipe      = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError  = Pipe()   // discard

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                proc.terminationHandler = { _ in
                    let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(returning: String(data: data, encoding: .utf8))
                }
                do { try proc.run() } catch { continuation.resume(returning: nil) }
            }
        } onCancel: {
            if proc.isRunning { proc.terminate() }
        }
    }

    // MARK: - Capture stdout + stderr

    /// Run an executable and return (stdout, stderr) as strings.
    /// Returns nil stdout on failure or cancellation; stderr is best-effort.
    static func runCapturingStderr(executable: String, arguments: [String]) async -> (stdout: String?, stderr: String) {
        let proc = Process()
        proc.executableURL  = URL(fileURLWithPath: executable)
        proc.arguments      = arguments
        let stdoutPipe      = Pipe()
        let stderrPipe      = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError  = stderrPipe

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                proc.terminationHandler = { _ in
                    let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let stdout = String(data: outData, encoding: .utf8)
                    let stderr = String(data: errData, encoding: .utf8) ?? ""
                    continuation.resume(returning: (stdout, stderr))
                }
                do { try proc.run() } catch { continuation.resume(returning: (nil, error.localizedDescription)) }
            }
        } onCancel: {
            if proc.isRunning { proc.terminate() }
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
        let proc = Process()
        proc.executableURL  = URL(fileURLWithPath: executable)
        proc.arguments      = arguments
        if let env = environment { proc.environment = env }

        let stdoutPipe      = Pipe()
        let stderrPipe      = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError  = stderrPipe

        // Stream stderr asynchronously on a background thread.
        let stderrHandle = stderrPipe.fileHandleForReading
        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else { return }
            for line in text.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { stderrLine(trimmed) }
            }
        }

        // Drain stdout continuously to prevent pipe buffer deadlock.
        // Without this, if the subprocess writes >64KB to stdout before
        // termination, the write blocks and the process hangs forever.
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stdoutCollector = StdoutCollector()
        stdoutHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { stdoutCollector.append(data) }
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                proc.terminationHandler = { _ in
                    stderrHandle.readabilityHandler = nil
                    stdoutHandle.readabilityHandler = nil
                    // Drain any remaining stderr
                    if let tail = String(data: stderrHandle.readDataToEndOfFile(),
                                        encoding: .utf8) {
                        for line in tail.components(separatedBy: "\n") {
                            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !t.isEmpty { stderrLine(t) }
                        }
                    }
                    // Drain any remaining stdout
                    let remaining = stdoutHandle.readDataToEndOfFile()
                    if !remaining.isEmpty { stdoutCollector.append(remaining) }
                    continuation.resume(returning: stdoutCollector.string)
                }
                do { try proc.run() } catch {
                    stderrHandle.readabilityHandler = nil
                    stdoutHandle.readabilityHandler = nil
                    stderrLine("⚠ Could not launch: \(executable) — \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                }
            }
        } onCancel: {
            stderrHandle.readabilityHandler = nil
            stdoutHandle.readabilityHandler = nil
            if proc.isRunning { proc.terminate() }
        }
    }

    /// Thread-safe collector for stdout data arriving via readabilityHandler.
    private class StdoutCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        var string: String? {
            lock.lock()
            let result = String(data: data, encoding: .utf8)
            lock.unlock()
            return result
        }
    }
}
