// ScriptedExecutorFidelityTests.swift — every ScriptedExecutor behaviour
// produces the Result the REAL runner produces for the same situation,
// pinned side by side against tiny real commands (/bin/sh, /bin/sleep).
// If Foundation or the runner ever changes a shape (the exit code of a
// signalled child, the never-launched words, the deadline flag), these go
// red before any mocked test can start lying.
//
// Timing: the hang rows use 0.3–0.4 s deadlines and a 0.3 s kill grace;
// the whole suite runs in ~2 s, in parallel. The REAL children sleep an
// hour, not seconds: under a heavily loaded machine the runner's deadline
// (a utility-QoS work item) can fire many seconds late — seen 2026-11-20 at
// load 49, a 0.4 s deadline on `sleep 30` never fired before the child
// exited by itself — and a short real child would then "win" the race and
// make the comparison about scheduling, not about the Result shape.

import Darwin
import Foundation
import Testing
@testable import VideoScanCore

@Suite("ScriptedExecutor — each behaviour matches the real runner")
struct ScriptedExecutorFidelityTests {

    /// The fields a caller can observe, plus what the callbacks saw.
    struct Shape: Equatable, CustomStringConvertible {
        var stdout: String?
        var stderr: String
        var exitCode: Int32
        var timedOut: Bool
        var launched: Bool
        var outLines: [String]
        var errLines: [String]
        var dataBytes: Int
        var description: String {
            "stdout=\(stdout.debugDescription) stderr=\(stderr.debugDescription) exit=\(exitCode) timedOut=\(timedOut) launched=\(launched) out=\(outLines) err=\(errLines) data=\(dataBytes)"
        }
    }

    static func shape(_ executable: String, _ arguments: [String], deadline: Double? = nil, grace: Double = 0.3,
                      stdoutLimit: Int? = nil, stderrLimit: Int? = 256 * 1024) async -> Shape {
        let out = LineBox(), err = LineBox()
        let bytes = ByteCounter()
        let r = await ProcessRunner.runProcess(
            executable: executable, arguments: arguments,
            stdoutLine: { out.add($0) }, stderrLine: { err.add($0) }, stdoutData: { bytes.add($0.count) },
            stdoutLimitBytes: stdoutLimit, stderrLimitBytes: stderrLimit,
            deadlineSeconds: deadline, killGraceSeconds: grace)
        return Shape(stdout: r.stdout, stderr: r.stderr, exitCode: r.exitCode, timedOut: r.timedOut, launched: r.launched,
                     outLines: out.all, errLines: err.all, dataBytes: bytes.total)
    }

    static func mocked(_ behaviour: ScriptedExecutor.Behaviour, deadline: Double? = nil, grace: Double = 0.3,
                       stdoutLimit: Int? = nil, stderrLimit: Int? = 256 * 1024,
                       executable: String = "/opt/homebrew/bin/ffmpeg") async -> Shape {
        let mock = ScriptedExecutor().on("*", behaviour)
        return await mock.scoped {
            await shape(executable, ["-i", "x"], deadline: deadline, grace: grace, stdoutLimit: stdoutLimit, stderrLimit: stderrLimit)
        }
    }

    static func sh(_ script: String, deadline: Double? = nil, stdoutLimit: Int? = nil, stderrLimit: Int? = 256 * 1024) async -> Shape {
        await shape("/bin/sh", ["-c", script], deadline: deadline, stdoutLimit: stdoutLimit, stderrLimit: stderrLimit)
    }

    @Test(".output: stdout, stderr, exit code, line callbacks and the data callback as the real pipes deliver them")
    func outputMatchesReal() async {
        let real = await Self.sh("printf '  a  \\n\\nb\\npartial'; printf 'e1\\n e2 \\n' >&2; exit 3")
        let mock = await Self.mocked(.output(stdout: "  a  \n\nb\npartial", stderr: "e1\n e2 \n", exit: 3))
        #expect(mock == real, "mock: \(mock)\nreal: \(real)")
    }

    @Test(".output under the collection caps: stdout/stderr copies truncated exactly like the real collectors")
    func outputCapsMatchReal() async {
        let real = await Self.sh("printf 'abcdefghij'; printf 'ABCDEFGHIJ' >&2", stdoutLimit: 4, stderrLimit: 3)
        let mock = await Self.mocked(.output(stdout: "abcdefghij", stderr: "ABCDEFGHIJ"), stdoutLimit: 4, stderrLimit: 3)
        #expect(mock == real, "mock: \(mock)\nreal: \(real)")
    }

    @Test(".garbage: exit 0 with the bytes on stdout — a success by exit code that a parser must still refuse")
    func garbageMatchesReal() async {
        let real = await Self.sh("printf '{\"streams\": [ {\"codec'")
        let mock = await Self.mocked(.garbage(stdout: "{\"streams\": [ {\"codec"))
        #expect(mock == real, "mock: \(mock)\nreal: \(real)")
    }

    @Test(".crash(signal): the real runner reports the signal number as the exit code, stdout empty (not nil), launched")
    func crashMatchesReal() async {
        for sig in [SIGSEGV, SIGABRT, SIGKILL, SIGBUS] {
            let real = await Self.sh("printf 'last words\\n' >&2; kill -\(sig) $$")
            let mock = await Self.mocked(.crash(signal: sig, stderr: "last words\n"))
            #expect(mock == real, "signal \(sig) — mock: \(mock)\nreal: \(real)")
        }
    }

    @Test(".launchFailure: launched=false, exit -1, stdout nil and Foundation's own words for a missing executable")
    func launchFailureMatchesReal() async {
        let missing = "/nonexistent-\(UUID().uuidString)/ffprobe"
        let real = await Self.shape(missing, ["-i", "x"])
        let mock = await Self.mocked(.launchFailure, executable: missing)
        #expect(mock == real, "mock: \(mock)\nreal: \(real)")
        #expect(!real.launched && real.exitCode == -1 && real.stdout == nil)
    }

    @Test(".hang + deadline: timedOut, SIGTERM's exit 15, launched — the same Result as a real wedged child")
    func hangDeadlineMatchesReal() async {
        let real = await Self.shape("/bin/sleep", ["3600"], deadline: 0.4)
        let mock = await Self.mocked(.hang(), deadline: 0.4)
        #expect(mock == real, "mock: \(mock)\nreal: \(real)")
        #expect(real.timedOut && real.exitCode == SIGTERM && real.launched)
    }

    @Test(".hang(ignoringSIGTERM) + deadline: the runner's SIGKILL stage — exit 9, timedOut")
    func hangIgnoringTermMatchesReal() async {
        let real = await Self.sh("trap '' TERM; exec /bin/sleep 3600", deadline: 0.3)
        let mock = await Self.mocked(.hang(ignoringSIGTERM: true), deadline: 0.3)
        #expect(mock == real, "mock: \(mock)\nreal: \(real)")
        #expect(real.timedOut && real.exitCode == SIGKILL)
    }

    @Test(".hang(stderr:) delivers what the tool printed before it stopped")
    func hangWithWordsMatchesReal() async {
        let real = await Self.sh("printf 'frame=1\\n' >&2; exec /bin/sleep 3600", deadline: 0.4)
        let mock = await Self.mocked(.hang(stderr: "frame=1\n"), deadline: 0.4)
        #expect(mock == real, "mock: \(mock)\nreal: \(real)")
    }

    @Test(".hang + task cancellation: SIGTERM, exit 15, NOT timedOut (only the runner's own deadline sets it)")
    func hangCancelMatchesReal() async {
        func cancelled(_ run: @escaping @Sendable () async -> Shape) async -> Shape {
            let task = Task { await run() }
            try? await Task.sleep(for: .milliseconds(300))
            task.cancel()
            return await task.value
        }
        let real = await cancelled { await Self.shape("/bin/sleep", ["3600"]) }
        let mock = await cancelled { await Self.mocked(.hang()) }
        #expect(mock == real, "mock: \(mock)\nreal: \(real)")
        #expect(!real.timedOut && real.exitCode == SIGTERM)
    }

    @Test("a task cancelled before the call: never launched, 'cancelled' — mock and real alike")
    func preCancelledMatchesReal() async {
        let real = await Task { withUnsafeCurrentTask { $0?.cancel() }; return await Self.shape("/bin/echo", ["x"]) }.value
        let mock = await Task { withUnsafeCurrentTask { $0?.cancel() }; return await Self.mocked(.output(stdout: "x\n")) }.value
        #expect(mock == real, "mock: \(mock)\nreal: \(real)")
        #expect(!real.launched && real.stderr == "cancelled")
    }

    @Test(".streamLines: lines arrive in order, interval apart, as callbacks and in the collected copy")
    func streamLinesMatchesReal() async {
        let real = await Self.sh("for l in out_time_us=1 out_time_us=2 progress=end; do echo $l; sleep 0.05; done")
        let started = ContinuousClock.now
        let mock = await Self.mocked(.streamLines(["out_time_us=1", "out_time_us=2", "progress=end"], interval: .milliseconds(50)))
        #expect(ContinuousClock.now - started >= .milliseconds(100), "two 50 ms gaps between three lines")
        // The real child's chunking may differ (one read per line or several
        // lines per read), so the data callback is compared in bytes.
        #expect(mock == real, "mock: \(mock)\nreal: \(real)")
    }

    @Test(".streamLines past the request's deadline: the SIGTERM shape with timedOut, the lines so far kept")
    func streamLinesDeadline() async {
        // Lines an hour apart, deadline 0.3 s: both stop after the first
        // line however late the deadline fires on a loaded machine (seen
        // 2026-11-20 in a full parallel Core run: the runner's 0.3 s
        // deadline fired after more than 20 s).
        let mock = await Self.mocked(.streamLines(["a", "b", "c", "d"], interval: .seconds(3600)), deadline: 0.3)
        #expect(mock.timedOut && mock.exitCode == SIGTERM && mock.launched, "\(mock)")
        #expect(mock.outLines == ["a"] && mock.stdout == "a\n", "\(mock)")
        let real = await Self.sh("for l in a b c d; do echo $l; sleep 3600; done", deadline: 0.3)
        #expect(real.timedOut && real.exitCode == SIGTERM && real.outLines == ["a"], "\(real)")
    }

    @Test(".after(delay, then:) waits, then behaves as told; cancelled while waiting it is the SIGTERM shape, like a real killed child")
    func afterDelaysThenBehaves() async {
        let started = ContinuousClock.now
        let late = await Self.mocked(.after(.milliseconds(150), then: .output(stdout: "done\n")))
        #expect(ContinuousClock.now - started >= .milliseconds(150))
        #expect(late.stdout == "done\n" && late.exitCode == 0 && late.launched)
        let task = Task { await Self.mocked(.after(.seconds(60), then: .output())) }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let killed = await task.value
        let realTask = Task { await Self.sh("exec /bin/sleep 3600") }
        try? await Task.sleep(for: .milliseconds(100))
        realTask.cancel()
        let real = await realTask.value
        #expect(killed == real, "mock: \(killed)\nreal: \(real)")
    }

    @Test(".writeOutputFile writes the bytes at the last argument (ffmpeg's output) and exits as told")
    func writeOutputFileWritesTheLastArgument() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vs-seam-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("o.mov")
        let mock = ScriptedExecutor(claiming: [dir.path])
            .on("ffmpeg", .writeOutputFile(Data(repeating: 7, count: 20_000), stderr: "No space left on device\n", exit: 228))
        let r = await mock.scoped {
            await ProcessRunner.runProcess(executable: "/b/ffmpeg", arguments: ["-i", "in.mov", "-y", out.path])
        }
        #expect(r.exitCode == 228 && r.launched && r.stderr == "No space left on device\n")
        #expect((try? Data(contentsOf: out))?.count == 20_000)
    }

    @Test(".writeOutputFile with no absolute output path is a failure, not a silent no-op")
    func writeOutputFileNeedsAPath() async {
        let mock = ScriptedExecutor().on("ffmpeg", .writeOutputFile(Data([1])))
        _ = await mock.withInstalled { await ProcessRunner.runProcess(executable: "/b/ffmpeg", arguments: ["-i", "x", "pipe:1"]) }
        #expect(mock.failures.count == 1 && mock.failures[0].contains("absolute output path"))
    }
}

final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add(_ n: Int) { lock.lock(); count += n; lock.unlock() }
    var total: Int { lock.lock(); defer { lock.unlock() }; return count }
}
