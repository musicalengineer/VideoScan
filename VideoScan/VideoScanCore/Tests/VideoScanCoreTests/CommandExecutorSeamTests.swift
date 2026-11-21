// CommandExecutorSeamTests.swift — the ProcessRunner seam itself
// (CommandExecutor.swift, ScriptedExecutor.swift; Rick 2026-11-20).
//
//   LOGIC      production default is the real executor; rules match in
//              order; calls are recorded with args and env; .sequence
//              answers per call; an unmatched call is a failure that prints
//              the command line.
//   ISOLATION  a mock is task-local: 64 concurrent task trees with 64
//              different mocks never see each other's answers, and two
//              @Tests running in parallel with different mocks never cross;
//              child tasks (`async let`, groups, `Task {}`) inherit it.
//   ESCAPE     a call that leaves the task tree (Task.detached, GCD) while a
//              mock claims its arguments is refused and reported — never run
//              for real; outside a scope the claim is gone.
// Parallel by design: no suite here is serialized.

import Darwin
import Foundation
import Testing
@_spi(Testing) @testable import VideoScanCore   // SPI: ProcessRunner.Result.init for .custom answers

@Suite("CommandExecutor seam — default, rules, recording")
struct CommandExecutorSeamTests {

    @Test("production default: outside any scope ProcessRunner.executor is the real one, and it really runs")
    func productionDefaultIsReal() async {
        #expect(ProcessRunner.executor is RealCommandExecutor)
        let r = await ProcessRunner.runProcess(executable: "/bin/echo", arguments: ["seam-real"])
        #expect(r.launched && r.exitCode == 0 && r.stdout == "seam-real\n")
    }

    @Test("inside a scope every static entry point reaches the mock; after it, the real one again")
    func everyEntryPointDelegates() async {
        let mock = ScriptedExecutor().on("ffprobe", .output(stdout: "{}\n", stderr: "warn\n"))
        await mock.scoped {
            #expect(ProcessRunner.executor is ScriptedExecutor)
            #expect(await ProcessRunner.run(executable: "/x/ffprobe", arguments: ["a"]) == "{}\n")
            let both = await ProcessRunner.runCapturingStderr(executable: "/x/ffprobe", arguments: ["b"])
            #expect(both.stdout == "{}\n" && both.stderr == "warn\n")
            let lines = LineBox()
            let streamed = await ProcessRunner.runStreaming(executable: "/x/ffprobe", arguments: ["c"]) { lines.add($0) }
            #expect(streamed == "{}\n" && lines.all == ["warn"])
            let full = await ProcessRunner.runProcess(executable: "/x/ffprobe", arguments: ["d"])
            #expect(full.launched && full.succeeded)
        }
        #expect(mock.calls.map(\.arguments) == [["a"], ["b"], ["c"], ["d"]])
        #expect(ProcessRunner.executor is RealCommandExecutor)
    }

    @Test("rules match in order on tool name and argument substrings; calls record executable, args and env")
    func rulesMatchInOrderAndCallsAreRecorded() async {
        let mock = ScriptedExecutor()
            .on("ffmpeg", containing: ["-movflags"], .output(stdout: "mux"))
            .on("ffmpeg", where: { $0.first == "-i" }, .output(stdout: "decode"))
            .on("*", .output(stdout: "any"))
        await mock.scoped {
            #expect(await ProcessRunner.run(executable: "/a/ffmpeg", arguments: ["-i", "x", "-movflags", "+faststart"]) == "mux")
            #expect(await ProcessRunner.run(executable: "/a/ffmpeg", arguments: ["-i", "x"]) == "decode")
            #expect(await ProcessRunner.run(executable: "/a/ffprobe", arguments: ["-i", "x"]) == "any")
            _ = await ProcessRunner.runProcess(executable: "/a/python3", arguments: ["s.py"], environment: ["K": "V"])
        }
        #expect(mock.calls(to: "ffmpeg").count == 2)
        #expect(mock.calls(to: "ffmpeg", containing: ["-movflags"]).count == 1)
        #expect(mock.calls.last?.environment == ["K": "V"])
        #expect(mock.calls.last?.commandLine == "/a/python3 s.py")
    }

    @Test(".sequence answers one element per call and repeats the last (fail, fail, then succeed)")
    func sequenceAnswersPerCall() async {
        let mock = ScriptedExecutor().on("ffprobe", .sequence([
            .crash(signal: SIGSEGV), .output(stderr: "busy", exit: 1), .output(stdout: "ok")]))
        let exits = await mock.scoped {
            var exits: [Int32] = []
            for _ in 0..<5 { exits.append(await ProcessRunner.runProcess(executable: "/x/ffprobe", arguments: []).exitCode) }
            return exits
        }
        #expect(exits == [SIGSEGV, 1, 0, 0, 0])
    }

    @Test("an unmatched call is a failure that prints the command line, and returns the never-launched shape")
    func unmatchedCallFails() async {
        let mock = ScriptedExecutor().on("ffprobe", .output())
        let r = await mock.withInstalled {
            await ProcessRunner.runProcess(executable: "/opt/homebrew/bin/ffmpeg", arguments: ["-i", "/v/a b.mov"])
        }
        #expect(!r.launched && r.exitCode == -1 && r.stdout == nil)
        #expect(mock.failures == ["ScriptedExecutor: no rule matches this command: /opt/homebrew/bin/ffmpeg -i '/v/a b.mov'"])
    }

    @Test("a nested .sequence is refused as a failure, not guessed")
    func nestedSequenceIsAFailure() async {
        let mock = ScriptedExecutor().on("x", .sequence([.sequence([.output()])]))
        let r = await mock.withInstalled { await ProcessRunner.runProcess(executable: "/x", arguments: []) }
        #expect(!r.launched)
        #expect(mock.failures.count == 1 && mock.failures[0].contains("inside a .sequence"))
    }

    @Test(".custom sees the whole request and answers for it")
    func customSeesTheRequest() async {
        let mock = ScriptedExecutor().on("ffmpeg", .custom { req in
            ProcessRunner.Result(stdout: "deadline=\(req.deadlineSeconds ?? -1) grace=\(req.killGraceSeconds)",
                                 stderr: "", exitCode: 0, launched: true)
        })
        let out = await mock.scoped {
            await ProcessRunner.runProcess(executable: "/b/ffmpeg", arguments: [], deadlineSeconds: 7, killGraceSeconds: 2).stdout
        }
        #expect(out == "deadline=7.0 grace=2.0")
    }
}

@Suite("CommandExecutor seam — task-local isolation under concurrency")
struct CommandExecutorIsolationTests {

    /// One task tree's whole conversation: direct, `async let`, a task
    /// group, and an unstructured `Task {}` — all must answer with `tag`.
    static func answers(in tag: String) async -> [String] {
        async let child = ProcessRunner.run(executable: "/t/tool", arguments: ["child"])
        let grouped = await withTaskGroup(of: String?.self) { group in
            for _ in 0..<3 { group.addTask { await ProcessRunner.run(executable: "/t/tool", arguments: ["group"]) } }
            var all: [String?] = []
            for await r in group { all.append(r) }
            return all
        }
        let unstructured = await Task { await ProcessRunner.run(executable: "/t/tool", arguments: ["task"]) }.value
        let direct = await ProcessRunner.run(executable: "/t/tool", arguments: ["direct"])
        return ([direct, await child, unstructured] + grouped).map { $0 ?? "nil" }
    }

    @Test("64 concurrent task trees, 64 mocks: every answer comes from the tree's own mock")
    func concurrentTreesNeverCross() async {
        let mocks = (0..<64).map { i in ScriptedExecutor().on("tool", .output(stdout: "m\(i)")) }
        let results = await withTaskGroup(of: (Int, [String]).self) { group in
            for (i, mock) in mocks.enumerated() {
                group.addTask { (i, await mock.scoped { await Self.answers(in: "m\(i)") }) }
            }
            var out: [Int: [String]] = [:]
            for await (i, answers) in group { out[i] = answers }
            return out
        }
        for i in 0..<64 {
            #expect(results[i] == Array(repeating: "m\(i)", count: 6), "tree \(i) saw \(results[i] ?? [])")
            #expect(mocks[i].calls.count == 6, "tree \(i)'s mock answered \(mocks[i].calls.count) calls")
        }
    }

    // Two @Tests that Swift Testing runs in parallel (the suite is not
    // serialized), each hammering its own mock for a while. If the binding
    // were global, one would read the other's answer.
    static func hammer(_ tag: String) async -> Set<String> {
        let mock = ScriptedExecutor().on("*", .output(stdout: tag))
        return await mock.scoped {
            var seen = Set<String>()
            for _ in 0..<400 {
                seen.insert(await ProcessRunner.run(executable: "/p/ffprobe", arguments: []) ?? "nil")
                await Task.yield()
            }
            return seen
        }
    }

    @Test("parallel test A sees only mock A")
    func parallelA() async { #expect(await Self.hammer("A") == ["A"]) }

    @Test("parallel test B sees only mock B")
    func parallelB() async { #expect(await Self.hammer("B") == ["B"]) }

    @Test("parallel test C runs the REAL executor while A and B are mocked, and is not refused")
    func parallelReal() async {
        for _ in 0..<20 {
            let r = await ProcessRunner.runProcess(executable: "/bin/echo", arguments: ["real-C"])
            #expect(r.launched && r.stdout == "real-C\n")
        }
    }

    @Test("a nested scope shadows the outer mock and restores it on exit")
    func nestedScopesShadow() async {
        let outer = ScriptedExecutor().on("*", .output(stdout: "outer"))
        let inner = ScriptedExecutor().on("*", .output(stdout: "inner"))
        let seen = await outer.scoped {
            let a = await ProcessRunner.run(executable: "/x", arguments: [])
            let b = await inner.scoped { await ProcessRunner.run(executable: "/x", arguments: []) }
            let c = await ProcessRunner.run(executable: "/x", arguments: [])
            return [a, b, c]
        }
        #expect(seen == ["outer", "inner", "outer"])
    }
}

@Suite("CommandExecutor seam — the escape guard")
struct CommandExecutorEscapeGuardTests {

    static func scratchToken() -> String { "/tmp/vs-escape-\(UUID().uuidString)" }

    @Test("Task.detached inside a mocked scope: a command naming a claimed path is refused and reported, never run")
    func detachedEscapeIsCaught() async {
        let token = Self.scratchToken()
        let mock = ScriptedExecutor(claiming: [token]).on("*", .output(stdout: "mocked"))
        let r = await mock.withInstalled {
            await Task.detached {
                await ProcessRunner.runProcess(executable: "/bin/echo", arguments: ["\(token)/out.mov"])
            }.value
        }
        #expect(!r.launched && r.exitCode == -1 && r.stdout == nil, "the escaped command ran: \(r)")
        #expect(r.stderr.contains("escaped a mocked scope"))
        #expect(mock.failures.count == 1 && mock.failures[0].contains("ESCAPED") && mock.failures[0].contains("\(token)/out.mov"),
                "\(mock.failures)")
    }

    @Test("a GCD block inside a mocked scope is caught the same way")
    func dispatchEscapeIsCaught() async {
        let token = Self.scratchToken()
        let mock = ScriptedExecutor(claiming: [token]).on("*", .output())
        let r: ProcessRunner.Result = await mock.withInstalled {
            await withCheckedContinuation { done in
                DispatchQueue.global().async {
                    Task.detached { done.resume(returning: await ProcessRunner.runProcess(executable: token + "/ffprobe", arguments: [])) }
                }
            }
        }
        #expect(!r.launched)
        #expect(mock.failures.contains { $0.contains("ESCAPED") })
    }

    @Test("a structured child (async let) is NOT an escape: it reaches the mock")
    func structuredChildIsNotAnEscape() async {
        let token = Self.scratchToken()
        let mock = ScriptedExecutor(claiming: [token]).on("*", .output(stdout: "mocked"))
        let out = await mock.scoped {
            async let r = ProcessRunner.run(executable: "/bin/echo", arguments: [token])
            return await r
        }
        #expect(out == "mocked")
    }

    @Test("ProcessRunner.detachedKeepingExecutor: detached work keeps the mock (the fix for the three escapes found in the audit)")
    func detachedKeepingExecutorCarriesTheMock() async {
        let token = Self.scratchToken()
        let mock = ScriptedExecutor(claiming: [token]).on("*", .output(stdout: "mocked"))
        let out = await mock.scoped {
            await ProcessRunner.detachedKeepingExecutor(priority: .utility) {
                await ProcessRunner.run(executable: "/bin/echo", arguments: [token])
            }.value
        }
        #expect(out == "mocked")
        // Outside any scope it is a plain detached task on the real executor.
        let real = await ProcessRunner.detachedKeepingExecutor { await ProcessRunner.run(executable: "/bin/echo", arguments: ["r"]) }.value
        #expect(real == "r\n")
    }

    @Test("after the scope ends the claim is released: the same command runs for real")
    func claimIsReleasedAfterTheScope() async {
        let token = Self.scratchToken()
        let mock = ScriptedExecutor(claiming: [token]).on("*", .output())
        await mock.scoped { _ = await ProcessRunner.run(executable: "/x", arguments: []) }
        let r = await ProcessRunner.runProcess(executable: "/bin/echo", arguments: [token])
        #expect(r.launched && r.stdout == token + "\n")
        #expect(mock.failures.isEmpty)
    }

    @Test("an empty claim claims nothing (it would match every command) and is reported as too vague")
    func emptyClaimIsIgnored() async {
        let mock = ScriptedExecutor(claiming: [""]).on("*", .output())
        let r = await mock.withInstalled {
            await Task.detached { await ProcessRunner.runProcess(executable: "/bin/echo", arguments: ["free"]) }.value
        }
        #expect(r.launched && r.stdout == "free\n")
        #expect(mock.failures.count == 1 && mock.failures[0].contains("too vague"), "\(mock.failures)")
    }

    @Test("claim specificity: absolute paths of 3+ components or 16+ characters only")
    func claimSpecificity() {
        for ok in ["/tmp/a/b", "/private/var/folders", "test_negmx_tape.mov-1"] { #expect(CommandExecutorEscapeGuard.isSpecific(ok), "\(ok)") }
        for vague in ["", "/", "/tmp", "/tmp/x", "mov", "test_stallmux_"] { #expect(!CommandExecutorEscapeGuard.isSpecific(vague), "\(vague)") }
    }

    @Test(".passThrough runs the real tool even with claimed arguments (it is the mock's own call, not an escape)")
    func passThroughIsNotAnEscape() async {
        let token = Self.scratchToken()
        let mock = ScriptedExecutor(claiming: [token]).on("echo", .passThrough)
        let out = await mock.scoped { await ProcessRunner.run(executable: "/bin/echo", arguments: [token]) }
        #expect(out == token + "\n")
    }
}

@Suite("CommandExecutor seam — sensors")
struct CommandExecutorSensorTests {

    static let videoScanDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // VideoScanCoreTests/
        .deletingLastPathComponent()   // Tests/
        .deletingLastPathComponent()   // VideoScanCore/
        .deletingLastPathComponent()   // VideoScan/ (project dir)

    /// A fake tool behind a process-global env var is what forced suites to
    /// be `.serialized`, and under parallel testing it let one suite's fake
    /// answer another suite's encode (seen 2026-11-20: a failed encode
    /// "published", a fake that never ran). Tests mock through the seam.
    static let forbidden = ["setenv(ToolLocator.ffmpegEnvVar", "setenv(ToolLocator.ffprobeEnvVar",
                            "setenv(FFmpegLocator.ffmpegEnvVar", "setenv(FFmpegLocator.ffprobeEnvVar",
                            "setenv(\"VS_FFMPEG_PATH\"", "setenv(\"VS_FFPROBE_PATH\""]

    static func offenders(in text: String) -> [String] { forbidden.filter { text.contains($0) } }

    @Test("sensor: no test swaps ffmpeg/ffprobe by setenv — they use ScriptedExecutor")
    func noTestSetsTheToolEnvVars() throws {
        var read = 0
        var hits: [String] = []
        for dir in ["VideoScanTests", "VideoScanCore/Tests"] {
            let root = Self.videoScanDir.appendingPathComponent(dir, isDirectory: true)
            let walk = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let url as URL in walk where url.pathExtension == "swift" && url.lastPathComponent != "CommandExecutorSeamTests.swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                read += 1
                for word in Self.offenders(in: text) { hits.append("\(url.lastPathComponent): \(word)") }
            }
        }
        #expect(read > 1_000, "the sensor read only \(read) files")
        #expect(hits.isEmpty, "\(hits)")
        #expect(Self.offenders(in: "setenv(ToolLocator.ffmpegEnvVar, fake.path, 1)") == ["setenv(ToolLocator.ffmpegEnvVar"],
                "the rule catches its own mutation")
    }

    @Test("sensor: no app (non-test) source mints a ProcessRunner.Result or uses the ScriptedExecutor mock")
    func appSourcesNeverUseTheMock() throws {
        let app = Self.videoScanDir.appendingPathComponent("VideoScan", isDirectory: true)
        let walk = try #require(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil))
        var read = 0
        var hits: [String] = []
        for case let url as URL in walk where url.pathExtension == "swift" {
            read += 1
            let code = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            for line in code where line.contains("ScriptedExecutor") || line.contains("ProcessRunner.Result(") {
                hits.append("\(url.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(read > 500, "the sensor read only \(read) app files")
        #expect(hits.isEmpty, "\(hits)")
    }

    @Test("sensor: the three detached shell-outs found by the escape audit carry the executor")
    func auditedDetachedSitesKeepTheExecutor() throws {
        let app = Self.videoScanDir.appendingPathComponent("VideoScan", isDirectory: true)
        for rel in ["MediaOps/CombineEngine.swift", "People/PersonFinderCompilation.swift",
                    "Media/VideoScanModel+EmbeddedDateBackfill.swift"] {
            let text = try String(contentsOf: app.appendingPathComponent(rel), encoding: .utf8)
            #expect(text.contains("ProcessRunner.detachedKeepingExecutor"), "\(rel)")
        }
    }
}

/// Thread-safe line collector for callbacks.
final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}
