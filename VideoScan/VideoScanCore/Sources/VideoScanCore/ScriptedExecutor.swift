// ScriptedExecutor.swift (VideoScanCore)
// The scripted mock for ProcessRunner (CommandExecutor.swift) — Rick's gtest
// mock command-exec, in Swift: rules matched in order on the tool's name and
// its arguments, each answering with a behaviour (output, a written output
// file, a hang, a crash, a launch failure, garbage, streamed lines, a
// delay, a per-call sequence, the real tool, or a closure). Every call is recorded
// (EXPECT_CALL-style assertions read `calls`); a call no rule matches, or
// one that escaped the task tree, is a FAILURE the test reports.
//
//     let mock = ScriptedExecutor(claiming: [scratch.path])
//         .on("ffprobe", .output(stdout: probeJSON))
//         .on("ffmpeg", containing: ["-movflags"], .hang())
//     try await mock.withInstalled { try await engine.run() }
//     #expect(mock.failures.isEmpty)        // tests use the `scoped` helper
//
// WHY IT IS A CORE SOURCE FILE (not a test target): both test bundles must
// use the SAME type the code under test sees — Core tests (`swift test`) and
// the app's VideoScanTests (Xcode). SwiftPM test targets cannot be imported
// by the Xcode test bundle, and a separate test-support library would need
// a new package product wired into the pbxproj and would risk a second copy
// of VideoScanCore (two `ProcessRunner.$executor` keys — a mock the app
// code never sees). As a Core type it costs nothing in production: it does
// no work unless a test binds it, it imports no test framework (failures are
// returned as strings; each test target has a 10-line `scoped` helper that
// turns them into Issue.record), and nothing in the app references it.
//
// FIDELITY. Behaviours that only need a Result shape are simulated (no
// fork): `.output`, `.garbage`, `.writeOutputFile`, `.crash`,
// `.launchFailure`, `.streamLines`. Each is pinned against the real runner
// on a tiny real command by ScriptedExecutorFidelityTests. Behaviours whose
// point is the runner's own timing/signal machinery use a REAL child through
// the real runner with the caller's deadline, grace, control and callbacks:
// `.hang` (the runner's deadline → SIGTERM → SIGKILL → abandon, Pause and
// cancellation are the real machinery; the child answers SIGTERM the way the
// matched tool does — ffmpeg traps it and exits 255, ffprobe dies of it —
// measured on ffmpeg/ffprobe 9.0.2, pinned by the fidelity and review
// tests) and `.passThrough`. Not modelled: a tool wedged in uninterruptible
// I/O that answers nothing until SIGKILL — use `ignoringSIGTERM` for that.
//
// Memory: one `Call` (the argument vector) per command, kept for the
// mock's life — a test issues tens to hundreds; `.writeOutputFile` holds its
// bytes once (callers pass small fixtures, or `.copyToOutputFile` to read a
// file at call time).

import Darwin
import Foundation
import os

// Checked Sendable: every stored property is an immutable Sendable value or
// the lock-guarded state (C++: all members const or behind one mutex).
public final class ScriptedExecutor: CommandExecutor, CommandEscapeSink, Sendable {

    /// One recorded command.
    public struct Call: Sendable, CustomStringConvertible {
        public let executable: String
        public let arguments: [String]
        public let environment: [String: String]?
        public var tool: String { (executable as NSString).lastPathComponent }
        public var commandLine: String {
            ([executable] + arguments).map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
        }
        public var description: String { commandLine }
    }

    /// What a matched command does.
    public enum Behaviour: Sendable {
        /// Exit with `exit`, having written `stdout` / `stderr` (delivered to
        /// the line/data callbacks and capped by the request's limits, as
        /// the real pipes would be).
        case output(stdout: String = "", stderr: String = "", exit: Int32 = 0)
        /// Exit 0 with output no parser should believe (truncated JSON,
        /// binary noise, the wrong tool's words).
        case garbage(stdout: String)
        /// Write `bytes` at the OUTPUT PATH — by ffmpeg convention the last
        /// argument (after `-y`) — then exit like `.output`.
        case writeOutputFile(Data, stderr: String = "", exit: Int32 = 0)
        /// The same, copying a fixture file read at call time (e.g. a real
        /// clip of a chosen length made once by the test).
        case copyToOutputFile(URL, stderr: String = "", exit: Int32 = 0)
        /// Never finish on its own: a REAL child (`/bin/sh` + `/bin/sleep`)
        /// under the real runner, so the request's deadline, kill grace,
        /// Pause control and task cancellation go through the real
        /// machinery (`timedOut`, the SIGTERM/SIGKILL stages, abandon).
        /// How the child answers SIGTERM: `exitOnTERM` if given; otherwise
        /// what the matched tool really does — ffmpeg traps TERM and exits
        /// 255, anything else (ffprobe, python, sleep) dies of it (exit 15).
        /// `ignoringSIGTERM` makes the child need the SIGKILL stage (a tool
        /// stuck past SIGTERM). `stderr` is written first (a tool that
        /// printed, then stopped).
        case hang(stderr: String = "", ignoringSIGTERM: Bool = false, exitOnTERM: Int32? = nil)
        /// Killed by `signal` (the real runner reports the signal number as
        /// the exit code; stdout is empty, not nil — the child did run).
        case crash(signal: Int32, stderr: String = "")
        /// The executable could not be started (`Process.run()` threw):
        /// launched = false, exit -1, stdout nil, the error's words.
        case launchFailure
        /// Emit `lines` one at a time — the first at once, then `interval`
        /// apart — on stdout (or stderr), then exit. Cancellation or the request's deadline stops
        /// it with the SIGTERM shape (exit 15; `timedOut` for the deadline).
        case streamLines([String], interval: Duration = .zero, toStderr: Bool = false, exit: Int32 = 0)
        /// Wait `delay` (a slow tool, a long transcode), then behave as
        /// `then` — typically `.passThrough`. Cancelled while waiting, it
        /// ends with the SIGTERM shape (exit 15), as a real child killed
        /// by the runner's cancel does. `then` must not be a `.sequence`.
        indirect case after(Duration, then: Behaviour)
        /// One element per call to this rule (fail, then succeed …); the
        /// last element repeats. Elements must not themselves be sequences.
        case sequence([Behaviour])
        /// Run the real tool through the real runner.
        case passThrough
        /// Anything else (wait on a test-controlled gate, assert on the
        /// request, …).
        case custom(@Sendable (CommandRequest) async -> ProcessRunner.Result)
    }

    private struct Rule: Sendable {
        let tool: String
        let needles: [String]
        let predicate: (@Sendable ([String]) -> Bool)?
        let behaviour: Behaviour

        func matches(_ call: Call) -> Bool {
            (tool == "*" || call.tool == tool)
                && needles.allSatisfy { needle in call.arguments.contains { $0.contains(needle) } }
                && (predicate?(call.arguments) ?? true)
        }
    }

    private struct State {
        var rules: [Rule] = []
        var served: [Int: Int] = [:]          // rule index → calls answered (for .sequence)
        var calls: [Call] = []
        var failures: [String] = []
    }

    // (C++: a std::mutex-guarded struct; withLock is a lock_guard scope.)
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let claims: [String]

    /// `claiming`: strings unique to this test (its scratch directory, a
    /// fixture stem). While installed, a REAL command that contains one is
    /// treated as having escaped the mocked task tree (see
    /// CommandExecutor.swift): refused, and reported in `failures`.
    public init(claiming claims: [String] = []) {
        self.claims = claims
    }

    // MARK: - Rules

    /// Add a rule: `tool` is the executable's file name (`"*"` for any);
    /// every string in `containing` must occur in some argument; `where`
    /// sees the whole argument vector. Rules are tried in the order added.
    @discardableResult
    public func on(_ tool: String, containing needles: [String] = [],
                   where predicate: (@Sendable ([String]) -> Bool)? = nil,
                   _ behaviour: Behaviour) -> ScriptedExecutor {
        state.withLock { $0.rules.append(Rule(tool: tool, needles: needles, predicate: predicate, behaviour: behaviour)) }
        return self
    }

    // MARK: - Assertions

    /// Every command this mock answered or refused, in order.
    public var calls: [Call] {
        state.withLock { $0.calls }
    }

    /// The calls to one tool, optionally filtered by argument substrings.
    public func calls(to tool: String, containing needles: [String] = []) -> [Call] {
        calls.filter { call in
            call.tool == tool && needles.allSatisfy { needle in call.arguments.contains { $0.contains(needle) } }
        }
    }

    /// Unmatched calls and escapes, each with its command line. Empty = clean.
    public var failures: [String] {
        state.withLock { $0.failures }
    }

    // MARK: - Scope

    /// Bind this mock as `ProcessRunner.executor` for `body`'s task tree
    /// and arm the escape guard for its claims. Never global: a parallel
    /// test outside this tree keeps its own executor.
    public func withInstalled<R>(
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> R
    ) async rethrows -> R {
        for vague in claims where !CommandExecutorEscapeGuard.isSpecific(vague) {
            fail("ScriptedExecutor: claim \(vague.debugDescription) is too vague to be this test's own (want an absolute path of 3+ components or 16+ characters) — not claimed; it would refuse other tests' real commands")
        }
        let id = CommandExecutorEscapeGuard.claim(claims, for: self)
        defer { CommandExecutorEscapeGuard.release(id) }
        return try await ProcessRunner.$executor.withValue(self) {
            try await body()
        }
    }

    func recordEscape(_ request: CommandRequest) {
        let call = Call(executable: request.executable, arguments: request.arguments, environment: request.environment)
        state.withLock {
            $0.calls.append(call)
            $0.failures.append("a command ESCAPED the mocked task tree (Task.detached, a GCD/OperationQueue block or a callback?) and was refused: \(call.commandLine)")
        }
    }

    // MARK: - CommandExecutor

    public func run(_ request: CommandRequest) async -> ProcessRunner.Result {
        let call = Call(executable: request.executable, arguments: request.arguments,
                        environment: request.environment)
        let behaviour: Behaviour? = state.withLock { state in
            state.calls.append(call)
            guard let index = state.rules.firstIndex(where: { $0.matches(call) }) else {
                state.failures.append("ScriptedExecutor: no rule matches this command: \(call.commandLine)")
                return nil
            }
            guard case .sequence(let steps) = state.rules[index].behaviour else { return state.rules[index].behaviour }
            let n = state.served[index, default: 0]
            state.served[index] = n + 1
            guard !steps.isEmpty else { return nil }
            let step = steps[min(n, steps.count - 1)]
            if case .sequence = step {
                state.failures.append("ScriptedExecutor: a .sequence inside a .sequence is not supported (rule \(index)): \(call.commandLine)")
                return nil
            }
            return step
        }

        guard let behaviour else {
            return ProcessRunner.Result(stdout: nil, stderr: "ScriptedExecutor: no rule for \(call.commandLine)", exitCode: -1)
        }
        // The real runner's entry guard: a task cancelled before the launch
        // never starts the child.
        guard !Task.isCancelled else {
            return ProcessRunner.Result(stdout: nil, stderr: "cancelled", exitCode: -1)
        }
        return await perform(behaviour, request)
    }

    // MARK: - Behaviours

    /// The behaviours that take time or a real child; the instant ones are
    /// `exitAtOnce`.
    private func perform(_ behaviour: Behaviour, _ request: CommandRequest) async -> ProcessRunner.Result {
        switch behaviour {
        case let .hang(stderr, ignoringSIGTERM, exitOnTERM):
            var child = request
            child.executable = "/bin/sh"
            child.arguments = ["-c", Self.hangScript(ignoringSIGTERM: ignoringSIGTERM,
                                                     exitOnTERM: exitOnTERM ?? Self.termExit(of: request.tool)),
                               "sh", stderr]
            child.environment = nil
            return await ProcessRunner.realRunProcess(child)
        case let .streamLines(lines, interval, toStderr, exit):
            return await stream(lines, interval: interval, toStderr: toStderr, exit: exit, request)
        case let .after(delay, then):
            try? await Task.sleep(for: delay)
            if Task.isCancelled {
                return ProcessRunner.Result(stdout: "", stderr: "", exitCode: SIGTERM, launched: true)
            }
            return await perform(then, request)
        case .passThrough:
            return await ProcessRunner.realRunProcess(request)
        case let .custom(answer):
            return await answer(request)
        case .sequence:
            fail("ScriptedExecutor: unresolved .sequence")
            return ProcessRunner.Result(stdout: nil, stderr: "ScriptedExecutor: unresolved sequence", exitCode: -1)
        case .output, .garbage, .writeOutputFile, .copyToOutputFile, .crash, .launchFailure:
            return exitAtOnce(behaviour, request)
        }
    }

    /// The instant behaviours — no child, no time passes: the Result of a
    /// child that ran and exited (or was killed by a signal), or of one
    /// that never launched.
    private func exitAtOnce(_ behaviour: Behaviour, _ request: CommandRequest) -> ProcessRunner.Result {
        switch behaviour {
        case let .output(stdout, stderr, exit):
            return Self.exited(exit, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8), request)
        case let .garbage(stdout):
            return Self.exited(0, stdout: Data(stdout.utf8), stderr: Data(), request)
        case let .writeOutputFile(bytes, stderr, exit):
            writeOutput(bytes, request)
            return Self.exited(exit, stdout: Data(), stderr: Data(stderr.utf8), request)
        case let .copyToOutputFile(source, stderr, exit):
            do {
                writeOutput(try Data(contentsOf: source), request)
            } catch {
                fail("ScriptedExecutor: cannot read the fixture \(source.path): \(error.localizedDescription)")
            }
            return Self.exited(exit, stdout: Data(), stderr: Data(stderr.utf8), request)
        case let .crash(signal, stderr):
            return Self.exited(signal, stdout: Data(), stderr: Data(stderr.utf8), request)
        case .launchFailure:
            return ProcessRunner.Result(stdout: nil, stderr: Self.launchFailureWords(request.executable), exitCode: -1)
        default:
            fail("ScriptedExecutor: \(behaviour) is not an instant behaviour")
            return ProcessRunner.Result(stdout: nil, stderr: "ScriptedExecutor: internal routing", exitCode: -1)
        }
    }

    /// How a real tool answers SIGTERM mid-work (measured 2026-11-20,
    /// Homebrew 9.0.2): ffmpeg's handler exits 255; ffprobe and the rest
    /// die of the signal (nil → the runner reports 15).
    static func termExit(of tool: String) -> Int32? {
        tool == "ffmpeg" ? 255 : nil
    }

    /// The hanging child. Dying of TERM: `exec sleep`. Ignoring it: the
    /// SIG_IGN survives exec. Exiting N on TERM: the shell must stay alive
    /// to run its trap, so sleep runs in the background with its fds on
    /// /dev/null (an orphan never holds the runner's pipes open) and the
    /// trap kills it before exiting.
    static func hangScript(ignoringSIGTERM: Bool, exitOnTERM: Int32?) -> String {
        let say = "printf '%s' \"$1\" >&2; "
        if ignoringSIGTERM { return "trap '' TERM; " + say + "exec /bin/sleep 86400" }
        guard let code = exitOnTERM else { return say + "exec /bin/sleep 86400" }
        return "trap 'kill $c 2>/dev/null; exit \(code)' TERM; " + say
            + "/bin/sleep 86400 </dev/null >/dev/null 2>&1 & c=$!; wait $c"
    }

    /// The words `Process.run()` throws for an executable that is not
    /// there (Foundation: NSCocoaErrorDomain / NSFileNoSuchFileError with
    /// the path) — the real never-launched Result carries exactly these.
    static func launchFailureWords(_ executable: String) -> String {
        NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError,
                userInfo: [NSFilePathErrorKey: executable]).localizedDescription
    }

    private func fail(_ words: String) {
        state.withLock { $0.failures.append(words) }
    }

    /// ffmpeg's output path is its last argument.
    private func writeOutput(_ bytes: Data, _ request: CommandRequest) {
        guard let path = request.arguments.last, path.hasPrefix("/") else {
            fail("ScriptedExecutor: .writeOutputFile needs an absolute output path as the last argument: \(request.commandLine)")
            return
        }
        do {
            // Not atomic: ffmpeg writes into the (reserved) file in place.
            try bytes.write(to: URL(fileURLWithPath: path))
        } catch {
            fail("ScriptedExecutor: cannot write \(path): \(error.localizedDescription)")
        }
    }

    /// A child that ran and exited: deliver its output the way the real
    /// pipes do (data callback, trimmed non-empty lines, capped copies).
    private static func exited(_ exit: Int32, stdout: Data, stderr: Data,
                               _ request: CommandRequest) -> ProcessRunner.Result {
        if !stdout.isEmpty { request.stdoutData?(stdout) }
        deliverLines(stdout, to: request.stdoutLine)
        deliverLines(stderr, to: request.stderrLine)
        return ProcessRunner.Result(stdout: String(data: capped(stdout, request.stdoutLimitBytes), encoding: .utf8),
                                    stderr: String(data: capped(stderr, request.stderrLimitBytes), encoding: .utf8) ?? "",
                                    exitCode: exit, launched: true)
    }

    private static func capped(_ data: Data, _ limit: Int?) -> Data {
        guard let limit else { return data }
        return data.prefix(max(0, limit))
    }

    private static func deliverLines(_ data: Data, to handler: (@Sendable (String) -> Void)?) {
        guard let handler, let text = String(data: data, encoding: .utf8) else { return }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { handler(trimmed) }
        }
    }

    private func stream(_ lines: [String], interval: Duration, toStderr: Bool, exit: Int32,
                        _ request: CommandRequest) async -> ProcessRunner.Result {
        let clock = ContinuousClock()
        let started = clock.now
        let deadline = request.deadlineSeconds.map { started + .milliseconds(Int64($0 * 1000)) }
        var out = Data()
        var err = Data()
        for (index, line) in lines.enumerated() {
            // The first line comes at once (as a tool's does), then one per
            // `interval`; the wait ends early at the deadline.
            if index > 0, interval > .zero {
                let wake = clock.now + interval
                try? await Task.sleep(until: deadline.map { min($0, wake) } ?? wake, clock: clock)
            }
            let timedOut = deadline.map { clock.now >= $0 } ?? false
            if Task.isCancelled || timedOut {
                // The runner's SIGTERM: a child that does not trap it exits 15.
                return ProcessRunner.Result(stdout: String(data: Self.capped(out, request.stdoutLimitBytes), encoding: .utf8),
                                            stderr: String(data: Self.capped(err, request.stderrLimitBytes), encoding: .utf8) ?? "",
                                            exitCode: SIGTERM, timedOut: timedOut, launched: true)
            }
            let bytes = Data((line + "\n").utf8)
            if toStderr {
                err.append(bytes)
                Self.deliverLines(bytes, to: request.stderrLine)
            } else {
                out.append(bytes)
                request.stdoutData?(bytes)
                Self.deliverLines(bytes, to: request.stdoutLine)
            }
        }
        return ProcessRunner.Result(stdout: String(data: Self.capped(out, request.stdoutLimitBytes), encoding: .utf8),
                                    stderr: String(data: Self.capped(err, request.stderrLimitBytes), encoding: .utf8) ?? "",
                                    exitCode: exit, launched: true)
    }
}
