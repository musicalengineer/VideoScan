// Subprocess.swift
//
// Thin async wrapper around `Process` for running external tools
// (defaults, sample, xcodebuild, gh, etc). Used by tests in the
// registry — black-box probing of the target app and its environment.
//
// Captures stdout + stderr separately, returns exit status. No shell
// interpolation: arguments are passed as an array.

import Foundation

struct SubprocessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let durationSeconds: Double

    var didSucceed: Bool { exitCode == 0 }
}

enum Subprocess {
    /// Run `executable` with `arguments`. Returns when the child exits or
    /// the optional timeout fires (in which case the process is terminated
    /// and exitCode = -1).
    static func run(_ executable: String,
                    _ arguments: [String],
                    timeoutSeconds: TimeInterval? = nil) async -> SubprocessResult {
        let started = Date()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            return SubprocessResult(
                exitCode: -1,
                stdout: "",
                stderr: "Failed to launch \(executable): \(error.localizedDescription)",
                durationSeconds: Date().timeIntervalSince(started)
            )
        }

        // Optional timeout — fire a Task that kills the process if it
        // overruns. The wait below returns either way.
        if let timeoutSeconds {
            Task.detached {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                if proc.isRunning {
                    proc.terminate()
                }
            }
        }

        // Drain pipes off-main while waiting.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                proc.waitUntilExit()
                cont.resume()
            }
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return SubprocessResult(
            exitCode: proc.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "",
            durationSeconds: Date().timeIntervalSince(started)
        )
    }
}
