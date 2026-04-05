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
                do    { try proc.run() }
                catch { continuation.resume(returning: nil) }
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
        // Each newline-terminated chunk is split and forwarded to the callback.
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

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                proc.terminationHandler = { _ in
                    stderrHandle.readabilityHandler = nil
                    // Drain any remaining stderr
                    if let tail = String(data: stderrHandle.readDataToEndOfFile(),
                                        encoding: .utf8) {
                        for line in tail.components(separatedBy: "\n") {
                            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !t.isEmpty { stderrLine(t) }
                        }
                    }
                    let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(returning: String(data: stdout, encoding: .utf8))
                }
                do    { try proc.run() }
                catch {
                    stderrHandle.readabilityHandler = nil
                    continuation.resume(returning: nil)
                }
            }
        } onCancel: {
            stderrHandle.readabilityHandler = nil
            if proc.isRunning { proc.terminate() }
        }
    }
}
