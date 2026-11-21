// LogCaptureSeamTests.swift
// The task-local log seam (Sources/VideoScanCore/TaskTreeScope.swift):
// a sink bound for one task tree is seen by that tree and by no other; the
// scope survives the escapes it is carried across and is lost (loudly, to
// the default) across the ones it is not; the capture's helpers behave.

import Foundation
import Testing
@testable import VideoScanCore

/// What production's `appLog` does, in miniature: the scoped sink, else a default.
private func logLine(_ line: String, default fallback: LogCapture) {
    (LogScope.current ?? fallback).write(line)
}

@Suite("LogCapture seam — a scoped sink belongs to one task tree")
struct LogCaptureSeamTests {

    /// 32 cases run at once; each binds its own capture and logs from its
    /// own task and from child tasks while the others do the same.
    @Test("32 concurrent scopes: every capture holds exactly its own lines, in none of the others'",
          arguments: 0..<32)
    func concurrentScopesNeverMix(_ id: Int) async {
        let mine = LogCapture(name: "case-\(id)")
        let stray = LogCapture(name: "default")
        let tag = "case-\(id)-\(UUID().uuidString)"
        await mine.scoped {
            await withTaskGroup(of: Void.self) { group in
                for child in 0..<8 {
                    group.addTask {
                        for n in 0..<50 {
                            logLine("\(tag) child \(child) line \(n)", default: stray)
                            if n % 10 == 0 { await Task.yield() }
                        }
                    }
                }
            }
            logLine("\(tag) parent", default: stray)
        }
        #expect(mine.count == 8 * 50 + 1)
        #expect(mine.lines.allSatisfy { $0.hasPrefix(tag) }, "a line from another case reached this capture")
        #expect(stray.lines.isEmpty, "a scoped line fell through to the default")
        #expect(LogScope.current == nil, "the binding ended with its closure")
    }

    @Test("nested scopes: the inner sink wins inside, the outer one is back after")
    func nestedScopesRestore() {
        let outer = LogCapture(), inner = LogCapture(), stray = LogCapture()
        outer.scoped {
            logLine("a", default: stray)
            inner.scoped { logLine("b", default: stray) }
            logLine("c", default: stray)
        }
        logLine("d", default: stray)
        #expect(outer.lines == ["a", "c"])
        #expect(inner.lines == ["b"])
        #expect(stray.lines == ["d"])
    }

    @Test("a throwing body still ends the scope")
    func throwingBodyEndsTheScope() {
        struct Boom: Error {}
        let mine = LogCapture()
        #expect(throws: Boom.self) { try mine.scoped { throw Boom() } }
        #expect(LogScope.current == nil)
    }

    // MARK: Escapes

    @Test("a bare Task.detached does NOT inherit the scope — the line goes to the default (which is why the helper exists)")
    func bareDetachedLosesTheScope() async {
        let mine = LogCapture(), stray = LogCapture()
        await mine.scoped {
            await Task.detached { logLine("escaped", default: stray) }.value
            await Task { logLine("child", default: stray) }.value
        }
        #expect(mine.lines == ["child"])
        #expect(stray.lines == ["escaped"])
    }

    @Test("TaskTreeScope.detached keeps the log sink AND the executor (one helper, both seams)")
    func detachedHelperCarriesBothSeams() async {
        let mine = LogCapture(), stray = LogCapture()
        let mock = ScriptedExecutor()
        mock.on("echo", .output(stdout: "mocked\n"))
        let out: String? = await mock.scoped {
            await mine.scoped {
                await TaskTreeScope.detached(priority: .utility) {
                    logLine("from detached", default: stray)
                    return await ProcessRunner.run(executable: "/bin/echo", arguments: ["real"])
                }.value
            }
        }
        #expect(out == "mocked\n")
        #expect(mine.lines == ["from detached"])
        #expect(stray.lines.isEmpty)
    }

    @Test("ProcessRunner.detachedKeepingExecutor is the same helper: it carries the log sink too")
    func executorHelperCarriesTheLogSink() async {
        let mine = LogCapture(), stray = LogCapture()
        await mine.scoped {
            await ProcessRunner.detachedKeepingExecutor { logLine("x", default: stray) }.value
        }
        #expect(mine.lines == ["x"])
        #expect(stray.lines.isEmpty)
    }

    @Test("TaskTreeScope.current.run re-enters the scope on a GCD queue and in a detached task")
    func snapshotReentersAcrossGCD() async {
        let mine = LogCapture(), stray = LogCapture()
        await mine.scoped {
            let scope = TaskTreeScope.current
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    logLine("gcd bare", default: stray)
                    scope.run { logLine("gcd carried", default: stray) }
                    done.resume()
                }
            }
            await Task.detached { await scope.run { logLine("detached carried", default: stray) } }.value
        }
        #expect(mine.lines == ["gcd carried", "detached carried"])
        #expect(stray.lines == ["gcd bare"])
    }

    /// ProcessRunner delivers stdout/stderr lines on its pipe-reader (GCD)
    /// threads. Every job's line callback hops to the main actor from
    /// there (`Task { @MainActor in … }`) and several log from that hop
    /// (Find Person "scanning n/total", Compare Footage "reading n of m").
    @Test("regression: a child's stdout/stderr/data callbacks — and the Task they start — run under the caller's scope")
    func processCallbacksRunUnderTheCallersScope() async {
        let mine = LogCapture(), stray = LogCapture()
        let hops = LineBox()
        await mine.scoped {
            let result = await ProcessRunner.runProcess(
                executable: "/bin/sh", arguments: ["-c", "echo out-line; echo err-line 1>&2"],
                stdoutLine: { line in
                    logLine("stdout: \(line)", default: stray)
                    Task { logLine("hop from stdout: \(line)", default: stray); hops.add(line) }
                },
                stderrLine: { line in logLine("stderr: \(line)", default: stray) })
            #expect(result.exitCode == 0)
            await ProcessRunner.runProcess(executable: "/bin/echo", arguments: ["raw"],
                                           stdoutData: { data in logLine("data: \(data.count) bytes", default: stray) })
            for _ in 0..<400 where hops.all.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        }
        #expect(stray.lines.isEmpty, "callback lines escaped the capture: \(stray.lines)")
        #expect(Set(mine.lines) == ["stdout: out-line", "hop from stdout: out-line", "stderr: err-line", "data: 4 bytes"], "\(mine.lines)")
    }

    @Test("production: with nothing bound a callback is handed on as it is — no wrapper on the pipe-reader path")
    func productionCallbacksAreNotWrapped() async {
        #expect(TaskTreeScope.current.isProductionDefault)
        #expect(LogCapture().scoped { !TaskTreeScope.current.isProductionDefault })
        #expect(await ScriptedExecutor().scoped { !TaskTreeScope.current.isProductionDefault })
    }

    @Test("outside any scope the snapshot is production's: no sink, the real executor — re-entering changes nothing")
    func productionSnapshotIsInert() {
        let scope = TaskTreeScope.current
        #expect(scope.logSink == nil)
        #expect(scope.executor is RealCommandExecutor)
        scope.run { #expect(LogScope.current == nil) }
    }

    // MARK: The capture's helpers

    @Test("contains / lines(containing:) / lines(matching:) / joined / count / clear")
    func readHelpers() {
        let log = LogCapture()
        ["verify video: a.mov — check", "verify video done: a.mov — ok", "trim done: b.mov — ok"].forEach(log.write)
        #expect(log.contains("a.mov") && !log.contains("c.mov"))
        #expect(log.lines(containing: "a.mov").count == 2)
        #expect(log.lines(matching: { $0.hasPrefix("trim") }) == ["trim done: b.mov — ok"])
        #expect(log.joined.split(separator: "\n").count == 3 && log.count == 3)
        log.clear()
        #expect(log.lines.isEmpty)
    }

    @Test("close() discards later writes; start(append: true) reopens and keeps; start(append: false) empties")
    func lifecycle() {
        let log = LogCapture()
        log.write("one"); log.close(); log.write("dropped")
        #expect(log.lines == ["one"])
        log.start(append: true); log.write("two")
        #expect(log.lines == ["one", "two"])
        log.start(append: false)
        #expect(log.lines.isEmpty)
    }

    @Test("the buffer is bounded: lines past maxLines are counted, not stored")
    func boundedBuffer() {
        let log = LogCapture(maxLines: 100)
        for n in 0..<1_000 { log.write("line \(n)") }
        #expect(log.count == 100)
        #expect(log.droppedCount == 900)
        #expect(log.lines.last == "line 99")
    }

    @Test("waitForLine returns a line logged later by another task, and nil when it never comes")
    func waitForLine() async {
        let log = LogCapture()
        let writer = Task.detached {
            try? await Task.sleep(for: .milliseconds(40))
            log.write("verify video done: late.mov — ok")
        }
        // A generous bound: under a fully loaded machine the writer task can be starved for many seconds.
        let hit = await log.waitForLine(containing: "late.mov", timeout: .seconds(300))
        #expect(hit == "verify video done: late.mov — ok")
        await writer.value
        let miss = await log.waitForLine(containing: "never", timeout: .milliseconds(60))
        #expect(miss == nil, "the wait ends at its timeout")
    }

    @Test("concurrent writers: 16 threads x 2 000 lines all land, none torn")
    func concurrentWriters() {
        let log = LogCapture()
        DispatchQueue.concurrentPerform(iterations: 16) { t in
            for n in 0..<2_000 { log.write("t\(t)-\(n)") }
        }
        #expect(log.count == 32_000)
        #expect(Set(log.lines).count == 32_000)
    }
}

@Suite("LogCapture seam — cost of the production path")
struct LogScopeCostTests {

    /// Production's whole added cost per log line is this read (nil, so the
    /// branch falls straight through to the production sink). Printed so the
    /// number is in the test log; the bound is ~100x looser than the
    /// measurement so a loaded machine cannot make it flap.
    @Test("an unbound LogScope.current read costs well under a microsecond (no lock, no allocation)")
    func unboundReadIsCheap() {
        let iterations = 2_000_000
        var hits = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations where LogScope.current != nil { hits += 1 }
        let ns = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(iterations)
        print(String(format: "LogScope.current (unbound): %.1f ns per read over %d reads", ns, iterations))
        #expect(hits == 0)
        #expect(ns < 2_000, "\(ns) ns per read")
    }
}

@Suite("LogCapture seam — sensors")
struct LogScopeSensorTests {

    static let videoScanDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // VideoScanCoreTests/
        .deletingLastPathComponent()   // Tests/
        .deletingLastPathComponent()   // VideoScanCore/
        .deletingLastPathComponent()   // VideoScan/ (project dir)

    /// Assigning the process-global is what forced `.serialized` and still
    /// raced across suites. `appLog` is get-only now (so this cannot
    /// compile); the sensor names the rule and catches any new settable
    /// global that would bring the pattern back under another spelling.
    static func assignsAppLog(_ line: Substring) -> Bool {
        let code = line.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return code.range(of: #"(^|[^\w.])appLog\s*=[^=]"#, options: .regularExpression) != nil
    }

    @Test("sensor: no test source assigns the global appLog — tests bind a sink with withAppLog")
    func noTestAssignsAppLog() throws {
        var read = 0
        var hits: [String] = []
        for dir in ["VideoScanTests", "VideoScanUITests", "VideoScanCore/Tests"] {
            let root = Self.videoScanDir.appendingPathComponent(dir, isDirectory: true)
            let walk = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let url as URL in walk where url.pathExtension == "swift" && url.lastPathComponent != "LogCaptureSeamTests.swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                read += 1
                for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where Self.assignsAppLog(line) {
                    hits.append("\(url.lastPathComponent):\(n + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(read > 1_000, "the sensor read only \(read) files")
        #expect(hits.isEmpty, "\(hits)")
    }

    @Test("sensor: the rule catches an assignment and ignores reads, comparisons, members and comments")
    func theRuleCatchesItsOwnMutation() {
        #expect(Self.assignsAppLog("        appLog = sink"))
        #expect(Self.assignsAppLog("defer { appLog = previous }"))
        #expect(Self.assignsAppLog("appLog=sink"))
        #expect(!Self.assignsAppLog("let previous = appLog"))
        #expect(!Self.assignsAppLog("if appLog === productionAppLog {"))
        #expect(!Self.assignsAppLog("#expect(appLog == other)"))
        #expect(!Self.assignsAppLog("model.appLog = sink"))
        #expect(!Self.assignsAppLog("// appLog = sink was the old way"))
        #expect(!Self.assignsAppLog("let myappLog = 1"))
    }

    @Test("sensor: appLog is a get-only computed global over one `let` production sink — no settable global exists")
    func appLogIsGetOnly() throws {
        let url = Self.videoScanDir.appendingPathComponent("VideoScan/App/VideoScanApp.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\nvar appLog: LogSink {\n"), "appLog must stay a computed, get-only global")
        #expect(text.contains("\nlet productionAppLog: LogSink = makeDefaultAppLog()\n"))
        #expect(!text.contains("var appLog: LogSink ="), "a stored, assignable appLog is the global this seam replaced")
        #expect(!text.contains("nonisolated(unsafe) var appLog"))
    }

    @Test("sensor: no app or helper (non-test) source binds a log scope or builds a LogCapture")
    func productionNeverBindsAScope() throws {
        var read = 0
        var hits: [String] = []
        for dir in ["VideoScan", "VideoScanBackground", "VideoScanCore/Sources"] {
            let root = Self.videoScanDir.appendingPathComponent(dir, isDirectory: true)
            let walk = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let url as URL in walk where url.pathExtension == "swift" && url.lastPathComponent != "TaskTreeScope.swift" {
                read += 1
                let code = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
                    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                for line in code where line.contains("LogScope.with(") || line.contains("LogCapture(") || line.contains("LogScope.$") {
                    hits.append("\(url.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(read > 700, "the sensor read only \(read) source files")
        #expect(hits.isEmpty, "\(hits)")
    }

    @Test("sensor: the escapes found by the log audit carry the task-tree scope")
    func auditedEscapesCarryTheScope() throws {
        let app = Self.videoScanDir.appendingPathComponent("VideoScan", isDirectory: true)
        let stall = try String(contentsOf: app.appendingPathComponent("Shared/StallMonitor.swift"), encoding: .utf8)
        #expect(stall.contains("pollTask = TaskTreeScope.detached("), "StallMonitor's poll task must keep its starter's scope")
        #expect(!stall.contains("pollTask = Task.detached("))
        let center = try String(contentsOf: app.appendingPathComponent("MediaOps/MediaFileOperations.swift"), encoding: .utf8)
        #expect(center.contains("logScopes[job.id] = TaskTreeScope.current"), "the Center must remember the scope a job was added under")
    }
}
