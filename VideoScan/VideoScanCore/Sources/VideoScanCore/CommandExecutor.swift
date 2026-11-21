// CommandExecutor.swift (VideoScanCore)
// The seam under ProcessRunner (Rick 2026-11-20: "my mock command-exec
// could return errors and pretend to hang, etc., which allowed for catching
// lots of negative test cases and error handling").
//
// Every `ProcessRunner.run* / runProcess` call builds one `CommandRequest`
// and hands it to `ProcessRunner.executor`. In production that is always
// `RealCommandExecutor` — today's runProcess body, moved, unchanged. A test
// swaps it for ONE task tree:
//
//     await ProcessRunner.$executor.withValue(mock) { try await job.run() }
//
// (`ScriptedExecutor.withInstalled` wraps exactly that.)
//
// For Rick (C++): `CommandExecutor` is the pure-virtual `ICommandExec` you
// mocked with gtest; `@TaskLocal` is a `thread_local` that follows the
// coroutine — and every child task it starts — instead of the OS thread, so
// two tests running in parallel each see their own mock and never each
// other's. There is deliberately NO global setter: a process-wide
// "set the executor" is exactly the VS_FFMPEG_PATH problem this replaces
// (one global ⇒ every suite that touches it must be `.serialized`).
//
// ESCAPES. A TaskLocal reaches child tasks (`async let`, task groups,
// `Task {}`) but NOT `Task.detached`, GCD/OperationQueue blocks, Process
// termination handlers or NotificationCenter callbacks. A call made there
// from inside a mocked test would silently run the REAL tool. The guard
// below catches that: a ScriptedExecutor "claims" strings unique to its test
// (its scratch directory); the real executor, while any claim is live,
// refuses a command whose executable or arguments contain a claimed string
// and reports it to the claiming mock as a test failure. With no mock alive
// (production, and every test that does not use one) the registry is empty
// and the check is one uncontended lock + `isEmpty` per child launch —
// nothing next to a fork/exec.

import Foundation
import os

/// Everything `ProcessRunner.runProcess` takes, as one Sendable value.
/// Field meanings are documented on `ProcessRunner.runProcess`.
public struct CommandRequest: Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]?
    public var stdoutLine: (@Sendable (String) -> Void)?
    public var stderrLine: (@Sendable (String) -> Void)?
    public var stdoutData: (@Sendable (Data) -> Void)?
    public var stdoutLimitBytes: Int?
    public var stderrLimitBytes: Int?
    public var deadlineSeconds: Double?
    public var killGraceSeconds: Double
    public var control: ProcessControl?

    public init(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        stdoutLine: (@Sendable (String) -> Void)? = nil,
        stderrLine: (@Sendable (String) -> Void)? = nil,
        stdoutData: (@Sendable (Data) -> Void)? = nil,
        stdoutLimitBytes: Int? = nil,
        stderrLimitBytes: Int? = 256 * 1024,
        deadlineSeconds: Double? = nil,
        killGraceSeconds: Double = ProcessRunner.defaultKillGraceSeconds,
        control: ProcessControl? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.stdoutLine = stdoutLine
        self.stderrLine = stderrLine
        self.stdoutData = stdoutData
        self.stdoutLimitBytes = stdoutLimitBytes
        self.stderrLimitBytes = stderrLimitBytes
        self.deadlineSeconds = deadlineSeconds
        self.killGraceSeconds = killGraceSeconds
        self.control = control
    }

    /// The executable's file name (`ffprobe` for `/opt/homebrew/bin/ffprobe`).
    public var tool: String { (executable as NSString).lastPathComponent }

    /// A printable command line, for failure messages and logs.
    public var commandLine: String {
        ([executable] + arguments).map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
    }
}

/// Runs one child process. `ProcessRunner`'s static entry points delegate
/// here; see the file header for how a test substitutes one.
public protocol CommandExecutor: Sendable {
    func run(_ request: CommandRequest) async -> ProcessRunner.Result
}

/// Production: fork/exec through `ProcessRunner.realRunProcess` (the body
/// `runProcess` had before the seam, unchanged).
public struct RealCommandExecutor: CommandExecutor {
    public init() {}

    public func run(_ request: CommandRequest) async -> ProcessRunner.Result {
        if let refusal = CommandExecutorEscapeGuard.refusal(for: request) { return refusal }
        return await ProcessRunner.realRunProcess(request)
    }
}

extension ProcessRunner {
    /// The executor every ProcessRunner call goes through. Task-local:
    /// bind a mock with `ProcessRunner.$executor.withValue(mock) { … }`;
    /// outside such a scope it is always the real one.
    /// Internal on purpose (review 2026-11-20): only ScriptedExecutor
    /// binds it, through `withInstalled` — no app, helper or CLI source can
    /// swap the executor production commands go through.
    @TaskLocal static var executor: any CommandExecutor = RealCommandExecutor()

    /// `Task.detached` that carries THIS task's scope — the executor AND
    /// the log capture — into the detached task (a detached task inherits
    /// no task-locals). It is `TaskTreeScope.detached` under the name the
    /// shell-out call sites already use: one mechanism for both seams.
    /// Same priority, same isolation (none), same cancellation as
    /// `Task.detached` — in production it re-binds the real executor and
    /// no capture, so behaviour is unchanged; under a test it keeps the
    /// mock instead of escaping to the real tool.
    /// (C++: capturing the thread_local by value into the lambda you hand
    /// to std::thread.)
    public static func detachedKeepingExecutor<Success: Sendable>(
        priority: TaskPriority? = nil,
        operation: sending @escaping () async -> Success
    ) -> Task<Success, Never> {
        TaskTreeScope.detached(priority: priority, operation: operation)
    }
}

/// Receives the commands that escaped a mocked scope (see file header).
protocol CommandEscapeSink: AnyObject, Sendable {
    func recordEscape(_ request: CommandRequest)
}

/// The escape guard's registry: claimed strings → the mock that claimed
/// them. Empty in production. Bounded by the number of live mocks (one
/// small entry per test in flight). Internal: only ScriptedExecutor claims.
enum CommandExecutorEscapeGuard {
    private struct Claim {
        let tokens: [String]
        weak var sink: (any CommandEscapeSink)?
    }

    private static let claims = OSAllocatedUnfairLock<[UUID: Claim]>(initialState: [:])

    /// A claim is honoured only when it is specific enough to be one
    /// test's own: an absolute path of at least three components (a
    /// scratch directory), or any string of 16+ characters. "/", "/tmp" or
    /// "mov" occur in nearly every command line — the process-wide guard
    /// would refuse other tests' real commands (review 2026-11-20).
    static func isSpecific(_ token: String) -> Bool {
        if token.hasPrefix("/"), (token as NSString).pathComponents.filter({ $0 != "/" }).count >= 3 { return true }
        return token.count >= 16
    }

    /// Register the specific `tokens` for `sink` until the returned id is
    /// released; vague ones are dropped (ScriptedExecutor reports them).
    static func claim(_ tokens: [String], for sink: any CommandEscapeSink) -> UUID {
        let id = UUID()
        let usable = tokens.filter(isSpecific)
        claims.withLock { $0[id] = Claim(tokens: usable, sink: sink) }
        return id
    }

    static func release(_ id: UUID) {
        _ = claims.withLock { $0.removeValue(forKey: id) }
    }

    /// Nil (run it) unless a live mock claimed a string in this command —
    /// then the command escaped that mock's task tree: report it and refuse
    /// with the never-launched Result shape.
    static func refusal(for request: CommandRequest) -> ProcessRunner.Result? {
        let sink: (any CommandEscapeSink)? = claims.withLock { table in
            guard !table.isEmpty else { return nil }
            let words = [request.executable] + request.arguments
            for claim in table.values where claim.tokens.contains(where: { token in words.contains { $0.contains(token) } }) {
                return claim.sink
            }
            return nil
        }
        guard let sink else { return nil }
        sink.recordEscape(request)
        return ProcessRunner.Result(stdout: nil,
                                    stderr: "refused: this command escaped a mocked scope (ScriptedExecutor): \(request.commandLine)",
                                    exitCode: -1)
    }
}
