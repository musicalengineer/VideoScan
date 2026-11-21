// AppLogScopeSeamTests.swift
// The app half of the task-local log seam (VideoScanCore/TaskTreeScope.swift,
// VideoScanApp.swift `appLog`, LogSinks+Test.swift `withAppLog`):
//
//   - two tests that capture the log at the same time never see each
//     other's lines (this suite is deliberately NOT .serialized);
//   - with nothing bound, `appLog` IS the production sink, and what that
//     sink writes for known lines is pinned byte for byte;
//   - the escapes the audit found (StallMonitor's poll task, the MFO
//     Center's OUTCOME hop) keep the scope they were started under.
//
// The Core half (LogCaptureSeamTests) covers the task-local itself, the
// capture's helpers, the cost of the production read and the sensors.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("appLog seam — a test's capture belongs to its own task tree")
struct AppLogScopeIsolationTests {

    /// 24 cases at once, each logging through the real global `appLog`
    /// from its own task and from child tasks.
    @Test("24 concurrent captures through the global appLog: each holds exactly its own lines",
          arguments: 0..<24)
    func concurrentCapturesNeverMix(_ id: Int) async {
        let sink = InMemoryLogSink(name: "case-\(id)")
        let tag = "seam-\(id)-\(UUID().uuidString)"
        await withAppLog(sink) {
            await withTaskGroup(of: Void.self) { group in
                for child in 0..<6 {
                    group.addTask {
                        for n in 0..<40 {
                            appLog.write("\(tag) child \(child) line \(n)")
                            if n % 8 == 0 { await Task.yield() }
                        }
                    }
                }
            }
            appLog.writeBatch(["\(tag) batch 1", "\(tag) batch 2"])
        }
        #expect(sink.count == 6 * 40 + 2)
        #expect(sink.lines.allSatisfy { $0.hasPrefix(tag) }, "another test's line reached this capture")
    }

    @Test("capture A, running beside capture B, sees only A's lines")
    func captureA() async { await oneOfTwo("A") }

    @Test("capture B, running beside capture A, sees only B's lines")
    func captureB() async { await oneOfTwo("B") }

    private func oneOfTwo(_ who: String) async {
        let sink = InMemoryLogSink()
        await withAppLog(sink) {
            for n in 0..<300 {
                appLog.write("two-captures \(who) \(n)")
                if n % 10 == 0 { try? await Task.sleep(for: .milliseconds(1)) }
            }
        }
        #expect(sink.count == 300)
        #expect(sink.lines.allSatisfy { $0.hasPrefix("two-captures \(who) ") })
    }

    @Test("any LogSink can be bound — a custom double receives write and writeBatch as itself")
    func customDoubleIsBoundAsItself() {
        final class Counting: LogSink, @unchecked Sendable {
            let name = "counting"
            var fileURL: URL? { nil }
            private let lock = NSLock()
            private(set) var writes = 0, batches = 0
            func start(append: Bool) {}
            func write(_ line: String) { lock.lock(); writes += 1; lock.unlock() }
            func writeBatch(_ lines: [String]) { lock.lock(); batches += 1; lock.unlock() }
            func flush() {}
            func close() {}
        }
        let sink = Counting()
        withAppLog(sink) {
            #expect(appLog === sink, "the bound sink is what call sites get — not a wrapper")
            appLog.write("one")
            appLog.writeBatch(["two", "three"])
        }
        #expect(sink.writes == 1 && sink.batches == 1)
    }

    @Test("the scope ends with its closure, also on a throw; nesting restores the outer sink")
    func scopeEndsAndNests() {
        struct Boom: Error {}
        let outer = InMemoryLogSink(), inner = InMemoryLogSink()
        withAppLog(outer) {
            appLog.write("a")
            #expect(throws: Boom.self) {
                try withAppLog(inner) { appLog.write("b"); throw Boom() }
            }
            appLog.write("c")
        }
        #expect(outer.lines == ["a", "c"])
        #expect(inner.lines == ["b"])
        #expect(appLog === productionAppLog)
    }

    @Test("a bare Core sink (no LogSink conformance) still receives the lines, through the adapter")
    func bareCoreSinkIsAdapted() {
        final class Bare: TaskScopedLogSink, @unchecked Sendable {
            private let lock = NSLock()
            private(set) var got: [String] = []
            func write(_ line: String) { lock.lock(); got.append(line); lock.unlock() }
        }
        let bare = Bare()
        LogScope.with(bare) {
            appLog.write("x")
            appLog.writeBatch(["y", "z"])
        }
        #expect(bare.got == ["x", "y", "z"])
    }
}

@Suite("appLog seam — production default is unchanged")
struct AppLogProductionDefaultTests {

    @Test("with nothing bound, appLog IS the production sink; under a test host that sink discards")
    func unboundIsTheProductionSink() {
        #expect(LogScope.current == nil)
        #expect(appLog === productionAppLog)
        #expect(productionAppLog is NullLogSink, "a test host must never hold the real videoscan.log")
        #expect(productionAppLog.fileURL == nil)
    }

    /// The exact routing rule production uses, given a real file sink as
    /// "production": unbound → that very object. Then what it writes for
    /// known lines is compared byte for byte (timestamps masked — they are
    /// the only bytes that vary) with the layout videoscan.log has had
    /// since PersistentLog was written.
    @Test("truth: unbound routing returns the production sink itself, and its file output for known lines is byte-for-byte the pinned layout")
    func productionBytesArePinned() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_applog_pin_\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = PersistentLog(name: "videoscan", directory: dir)
        file.start(append: true)

        let routed = AppLogRouting.resolve(scoped: nil, production: file)
        #expect(routed === file, "no wrapper, no tee: the production object itself")

        let start = MediaFileOperationsCenter.startSummaryLine(verb: "verify video", title: "tape 01.mov",
                                                               plan: "check the picture (header, timestamps, full decode)")
        let done = try #require(MediaFileOperationsCenter.terminalSummaryLine(
            verb: "verify video", title: "tape 01.mov", state: .finished(summary: "picture OK"), wasRefused: false))
        let failed = try #require(MediaFileOperationsCenter.terminalSummaryLine(
            verb: "balance audio", title: "tape 02.mov", state: .failed(message: "ffmpeg exited with status 183"), wasRefused: false))
        routed.write(start)
        routed.write(done)
        routed.write(failed)
        routed.writeBatch(["NOT CATALOGED: a.tmp", "NOT CATALOGED: b.tmp"])
        routed.write("unicode — “quoted” café ✓")
        file.close()

        let bytes = try Data(contentsOf: file.url)
        let text = try #require(String(data: bytes, encoding: .utf8))
        let masked = text
            .replacingOccurrences(of: #"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}"#, with: "<DATE TIME>", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^\[\d{2}:\d{2}:\d{2}\] "#, with: "[<TIME>] ", options: .regularExpression)
        let pinned = """
            VideoScan videoscan log — started <DATE TIME>
            ─────────────────────────────────────────────
            [<TIME>] verify video: tape 01.mov — check the picture (header, timestamps, full decode)
            [<TIME>] verify video done: tape 01.mov — picture OK
            [<TIME>] balance audio FAILED: tape 02.mov — ffmpeg exited with status 183
            [<TIME>] NOT CATALOGED: a.tmp
            [<TIME>] NOT CATALOGED: b.tmp
            [<TIME>] unicode — “quoted” café ✓
            ─────────────────────────────────────────────
            Log closed.

            """
        #expect(Data(masked.utf8) == Data(pinned.utf8), "\(masked)")
        #expect(file.synchronizeCount == 5, "four writes + one batch = five fsyncs, as before")
    }

    @Test("bound routing returns the bound sink and writes NOTHING to the production file (instead, not a tee)")
    func boundRoutingBypassesProduction() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_applog_tee_\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = PersistentLog(name: "videoscan", directory: dir)
        file.start(append: true)
        let before = try Data(contentsOf: file.url)

        let sink = InMemoryLogSink()
        let routed = AppLogRouting.resolve(scoped: sink, production: file)
        #expect(routed === sink)
        routed.write("only the capture sees this")
        routed.writeBatch(["nor this", "nor this"])

        #expect(sink.lines == ["only the capture sees this", "nor this", "nor this"])
        #expect(try Data(contentsOf: file.url) == before, "a captured line reached the production file")
        #expect(file.synchronizeCount == 0)
        file.close()
    }
}

@Suite("appLog seam — escapes carry the scope")
struct AppLogScopeEscapeTests {

    /// StallMonitor polls from a detached task and calls `onStall` there;
    /// every MFO job's handler logs its "watchdog:" line from that call.
    @Test("regression: a StallMonitor started under a capture delivers its onStall under that capture")
    func stallMonitorKeepsItsStartersScope() async {
        let sink = InMemoryLogSink()
        let tag = "watchdog-\(UUID().uuidString)"
        let now = LockedDouble(0)
        let monitor = StallMonitor(label: tag, thresholdSeconds: 1, pollIntervalSeconds: 0.01,
                                   clock: { now.value }) { silentFor in
            appLog.write("\(tag) stalled \(Int(silentFor))s")
        }
        await withAppLog(sink) {
            monitor.start()
            now.value = 60          // a minute of silence
            _ = await sink.waitForLine(containing: tag, timeout: .seconds(120))
            monitor.stop()
        }
        #expect(sink.lines(containing: tag) == ["\(tag) stalled 60s"],
                "the watchdog line escaped the capture: \(sink.lines)")
    }

    /// The MFO window forwarder schedules its "open the window" work with
    /// DispatchQueue.main.asyncAfter; that work writes the forward line.
    /// A GCD block inherits no task-locals.
    @MainActor
    @Test("regression: work scheduled through MainQueueForwardScheduler runs under its scheduler's capture")
    func mainQueueForwardSchedulerKeepsTheScope() async {
        let sink = InMemoryLogSink()
        let tag = "window-forward-\(UUID().uuidString)"
        let ran = LockedDouble(0)
        await withAppLog(sink) {
            MainQueueForwardScheduler().schedule(after: 0) {
                appLog.write(tag)
                ran.value = 1
            }
            for _ in 0..<24_000 where ran.value == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        }
        #expect(ran.value == 1, "the scheduled work never ran")
        #expect(sink.lines == [tag], "the forward line escaped the capture: \(sink.lines)")
    }

    @Test("a detached task that logs through the global appLog is carried by TaskTreeScope.detached, lost by Task.detached")
    func detachedThroughTheGlobal() async {
        let sink = InMemoryLogSink()
        await withAppLog(sink) {
            await TaskTreeScope.detached { appLog.write("carried") }.value
            await Task.detached { appLog.write("lost to the NullLogSink") }.value
        }
        #expect(sink.lines == ["carried"])
    }
}

/// A Double behind a lock (the injected monotonic clock).
private final class LockedDouble: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Double
    init(_ v: Double) { stored = v }
    var value: Double {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
