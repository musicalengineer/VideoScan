import Darwin
import Foundation

struct CodexQueueCommand: Equatable {
    let executableURL: URL
    let arguments: [String]
}

private final class BoundedProcessOutput: @unchecked Sendable {
    // Codex queue normally emits one line. This cap prevents a broken CLI from
    // growing the menu app without bound while still draining its pipe fully.
    private static let maximumBytes = 256 * 1024
    private let lock = NSLock()
    private var data = Data()
    private var discardedBytes = false

    func append(_ newData: Data) {
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, Self.maximumBytes - data.count)
        data.append(newData.prefix(remaining))
        if newData.count > remaining { discardedBytes = true }
    }

    func string() -> String {
        lock.lock()
        defer { lock.unlock() }
        var value = String(data: data, encoding: .utf8) ?? ""
        if discardedBytes { value += "\n[output truncated]" }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum CodexWake {
    static let binaryOverrideEnvironmentKey = "VIDEOSCAN_CODEX_BIN"
    static let defaultMessage = "Please read and respond to your pending VideoScan team-channel messages."
    static let defaultTimeout: TimeInterval = 5

    static func findExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory(),
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> URL? {
        var candidates: [String] = []
        if let override = environment[binaryOverrideEnvironmentKey], !override.isEmpty {
            candidates.append((override as NSString).expandingTildeInPath)
        }
        candidates.append(homeDirectory + "/.local/bin/codex")
        candidates.append(homeDirectory + "/.codex/packages/standalone/current/bin/codex")
        return candidates.first(where: isExecutable).map { URL(fileURLWithPath: $0) }
    }

    static func command(
        threadTarget: String,
        message: String = defaultMessage,
        executableURL: URL
    ) -> CodexQueueCommand? {
        let target = threadTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        return CodexQueueCommand(
            executableURL: executableURL,
            arguments: ["queue", "--thread", target, "--message", message]
        )
    }

    static func wake(
        threadTarget: String,
        message: String = defaultMessage,
        timeout: TimeInterval = defaultTimeout,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> (ok: Bool, output: String) {
        guard let executableURL = findExecutable(environment: environment) else {
            return (false, "Codex CLI not found. Set \(binaryOverrideEnvironmentKey) or install Codex in ~/.local/bin.")
        }
        guard let command = command(threadTarget: threadTarget, message: message, executableURL: executableURL) else {
            return (false, "Enter a Codex session UUID or exact session name.")
        }

        // The runner waits on a child process, so it must never inherit the
        // @MainActor used by MonitorModel (roughly the macOS UI thread).
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: run(command, timeout: timeout))
            }
        }
    }

    private static func run(_ command: CodexQueueCommand, timeout: TimeInterval) -> (ok: Bool, output: String) {
        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = command.arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let output = BoundedProcessOutput()
        let reachedEOF = DispatchSemaphore(value: 0)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                reachedEOF.signal()
            } else {
                output.append(chunk)
            }
        }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return (false, "Could not start Codex: \(error.localizedDescription)")
        }

        let boundedTimeout = max(0.1, timeout)
        if exited.wait(timeout: .now() + boundedTimeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 0.5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 0.5)
            }
            _ = reachedEOF.wait(timeout: .now() + 0.25)
            pipe.fileHandleForReading.readabilityHandler = nil
            return (false, "Codex wake timed out after \(Self.formatted(boundedTimeout)) seconds and was terminated.")
        }

        _ = reachedEOF.wait(timeout: .now() + 0.25)
        pipe.fileHandleForReading.readabilityHandler = nil
        let text = output.string()
        if process.terminationStatus == 0 {
            return (true, text.isEmpty ? "Wake request queued." : text)
        }
        return (false, text.isEmpty ? "Codex exited with status \(process.terminationStatus)." : text)
    }

    private static func formatted(_ seconds: TimeInterval) -> String {
        seconds.rounded() == seconds ? String(Int(seconds)) : String(format: "%.1f", seconds)
    }
}
