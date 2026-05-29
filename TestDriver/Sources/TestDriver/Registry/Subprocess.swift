// Subprocess.swift
//
// Async wrapper around Process. Drains stdout/stderr CONCURRENTLY while
// the child runs — without this, xcodebuild test (multi-MB output)
// fills the 64KB pipe buffer, blocks on write, and the parent waits
// forever in waitUntilExit(). Closed issue #56 covers the same bug
// class for VideoScan's own subprocess runner.
//
// Lines are forwarded to optional callbacks as they arrive, so the
// UI can show live progress instead of a frozen "running…" badge.

import Foundation
import os.lock

struct SubprocessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let durationSeconds: Double
    let timedOut: Bool

    var didSucceed: Bool { exitCode == 0 && !timedOut }
}

/// Thread-safe buffer that owns its own lock. Readability handlers fire
/// on FileHandle-owned dispatch queues; this lets multiple of them
/// append safely while the consumer drains lines.
final class PipeBuffer: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var buffer: String = ""
    private var carry: String = ""

    func append(_ chunk: String, lineHandler: (@Sendable (String) -> Void)?) {
        lock.withLock {
            buffer += chunk
            carry += chunk
            // Emit any complete lines.
            while let nl = carry.firstIndex(of: "\n") {
                let line = String(carry[..<nl])
                carry.removeSubrange(...nl)
                lineHandler?(line)
            }
        }
    }

    /// Drains any pending carry-over (no trailing newline). Returns the
    /// full transcript collected so far.
    func flush(lineHandler: (@Sendable (String) -> Void)?) -> String {
        lock.withLock {
            if !carry.isEmpty {
                lineHandler?(carry)
                carry = ""
            }
            return buffer
        }
    }
}

enum Subprocess {
    /// Run `executable` with `arguments`. stdout / stderr are drained
    /// concurrently with execution; full transcripts are captured AND
    /// every line is forwarded to the optional `stdoutLine` / `stderrLine`
    /// callbacks as it arrives.
    static func run(
        _ executable: String,
        _ arguments: [String],
        timeoutSeconds: TimeInterval? = nil,
        stdoutLine: (@Sendable (String) -> Void)? = nil,
        stderrLine: (@Sendable (String) -> Void)? = nil
    ) async -> SubprocessResult {
        let started = Date()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let outBuf = PipeBuffer()
        let errBuf = PipeBuffer()

        // Install readability handlers — these fire on a background dispatch
        // queue owned by the FileHandle subsystem each time the kernel says
        // bytes are ready. Without these, the child blocks on the next write
        // once the 64KB pipe buffer fills.
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            if let s = String(data: data, encoding: .utf8) {
                outBuf.append(s, lineHandler: stdoutLine)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            if let s = String(data: data, encoding: .utf8) {
                errBuf.append(s, lineHandler: stderrLine)
            }
        }

        TermLog.log("subproc", "launch: \(executable) \(arguments.joined(separator: " "))")
        do {
            try proc.run()
        } catch {
            TermLog.log("subproc", "launch FAILED: \(error.localizedDescription)")
            return SubprocessResult(
                exitCode: -1,
                stdout: "",
                stderr: "Failed to launch \(executable): \(error.localizedDescription)",
                durationSeconds: Date().timeIntervalSince(started),
                timedOut: false
            )
        }
        TermLog.log("subproc", "launched pid=\(proc.processIdentifier)")

        // Resume-once latch so the continuation can be tripped from any of:
        //   1. terminationHandler (child exited cleanly)
        //   2. timeout watcher (we killed it)
        //   3. a defensive watchdog if neither fires
        // Foundation's `proc.waitUntilExit()` is known to park forever when
        // a child exits with bytes still buffered in its stdout/stderr
        // pipes — the wait expects the pipe reader to drain to EOF, but
        // a racy readabilityHandler can miss the final readable event and
        // leave the wait permanently parked. Using terminationHandler
        // bypasses that wait entirely.
        let resumeLock = OSAllocatedUnfairLock<Bool>(initialState: false)
        nonisolated(unsafe) var didTimeout = false

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let resumeOnce: @Sendable () -> Void = {
                let shouldResume = resumeLock.withLock { resumed -> Bool in
                    guard !resumed else { return false }
                    resumed = true
                    return true
                }
                if shouldResume { cont.resume() }
            }

            proc.terminationHandler = { _ in
                resumeOnce()
            }

            if let timeoutSeconds {
                Task.detached {
                    try? await Task.sleep(for: .seconds(timeoutSeconds))
                    if proc.isRunning {
                        didTimeout = true
                        proc.terminate()
                        // Give terminate() a moment to land; if the child
                        // is wedged in the kernel, force-kill so the
                        // terminationHandler is guaranteed to fire.
                        try? await Task.sleep(for: .seconds(2))
                        if proc.isRunning {
                            kill(proc.processIdentifier, SIGKILL)
                        }
                    }
                    // Belt-and-suspenders: if terminationHandler somehow
                    // didn't run (Foundation bug), unblock the wait anyway.
                    try? await Task.sleep(for: .seconds(1))
                    resumeOnce()
                }
            }
        }

        // Tear down handlers so the FileHandles don't fire after we return.
        // Stash references first so the synchronous drain below can read
        // any bytes that arrived between the last readability event and
        // the child exit.
        let outFH = outPipe.fileHandleForReading
        let errFH = errPipe.fileHandleForReading
        outFH.readabilityHandler = nil
        errFH.readabilityHandler = nil

        // Synchronous drain of anything the readability handlers missed.
        // After terminationHandler fires there's no writer, so these reads
        // return immediately at EOF — they CANNOT hang the way
        // waitUntilExit could.
        if let tail = try? outFH.readToEnd(), !tail.isEmpty,
           let s = String(data: tail, encoding: .utf8) {
            outBuf.append(s, lineHandler: stdoutLine)
        }
        if let tail = try? errFH.readToEnd(), !tail.isEmpty,
           let s = String(data: tail, encoding: .utf8) {
            errBuf.append(s, lineHandler: stderrLine)
        }

        let finalOut = outBuf.flush(lineHandler: stdoutLine)
        let finalErr = errBuf.flush(lineHandler: stderrLine)
        let exit = didTimeout ? Int32(-1) : proc.terminationStatus
        TermLog.log("subproc", "exit=\(exit) timedOut=\(didTimeout) duration=\(String(format: "%.1f", Date().timeIntervalSince(started)))s")

        return SubprocessResult(
            exitCode: exit,
            stdout: finalOut,
            stderr: finalErr,
            durationSeconds: Date().timeIntervalSince(started),
            timedOut: didTimeout
        )
    }
}
