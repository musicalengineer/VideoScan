// PersistentLogRotationGzipTests.swift — log rotation's `/usr/bin/gzip` goes
// through ProcessRunner (2026-11-21; it was a hand-rolled Process() started
// and never waited for), so a ScriptedExecutor answers it.
//
//   COMMAND   one gzip, on exactly the dated archive beside the log
//   FAILURE   gzip fails / cannot start / hangs: the failure stays contained —
//             rotation still happened, the plain archive is kept whole, the
//             fresh log takes lines, nothing is dropped, start() does not wait
// Parallel by design: each test has its own scratch directory and mock.

import Foundation
import Testing
@testable import VideoScan
@_spi(Testing) import VideoScanCore

@Suite("PersistentLog — rotation's gzip through the executor seam", .timeLimit(.minutes(1)))
struct PersistentLogRotationGzipTests {

    struct Bench {
        let dir: URL
        let log: PersistentLog
        let oldBytes: Data

        init() throws {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("log-rotation-gzip-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            log = PersistentLog(name: "rotating", directory: dir)
            log.rotationThresholdBytes = 1024
            // An oversized log from an "earlier launch".
            oldBytes = Data((0..<80).map { "earlier launch line \($0) ........................\n" }.joined().utf8)
            try oldBytes.write(to: log.url)
        }
        var archives: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0 != "rotating.log" }.sorted()
        }
        func cleanup() { try? FileManager.default.removeItem(at: dir) }
    }

    static func waitForGzip(_ mock: ScriptedExecutor) async {
        for _ in 0..<1000 where mock.calls(to: "gzip").isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test("COMMAND: an oversized log is renamed to a dated archive and gzip is issued once, on exactly that archive")
    func theCommandLine() async throws {
        let b = try Bench()
        defer { b.cleanup() }
        let mock = ScriptedExecutor(claiming: [b.dir.path]).on("gzip", .output())
        await mock.scoped {
            b.log.start(append: true)
            b.log.write("first line after rotation")
            b.log.close()
            await Self.waitForGzip(mock)
        }
        #expect(mock.calls.count == 1)
        let call = try #require(mock.calls.first)
        #expect(call.executable == "/usr/bin/gzip")
        #expect(call.environment == nil)
        #expect(call.arguments.count == 1)
        let archive = try #require(call.arguments.first)
        #expect((archive as NSString).deletingLastPathComponent == b.dir.path)
        #expect((archive as NSString).lastPathComponent.wholeMatch(of: /rotating-\d{8}-\d{6}\.log/) != nil, "\(archive)")
        #expect(try Data(contentsOf: URL(fileURLWithPath: archive)) == b.oldBytes, "the archive is the old log, whole")
        let fresh = try String(contentsOf: b.log.url, encoding: .utf8)
        #expect(fresh.contains("first line after rotation") && !fresh.contains("earlier launch line"))
    }

    @Test("FAILURE: gzip fails, cannot start or hangs — contained: the plain archive is kept, the fresh log works, nothing is dropped",
          arguments: ["exit", "launch", "hang"])
    func gzipFailureIsContained(_ how: String) async throws {
        let b = try Bench()
        defer { b.cleanup() }
        let behaviour: ScriptedExecutor.Behaviour = how == "exit" ? .output(stderr: "gzip: No space left on device\n", exit: 1)
            : how == "launch" ? .launchFailure
            // A gate, not a real hung child: the production deadline is 10 minutes.
            : .custom { _ in
                try? await Task.sleep(for: .milliseconds(400))
                return ProcessRunner.Result(stdout: "", stderr: "", exitCode: 15, timedOut: true, launched: true)
            }
        let mock = ScriptedExecutor(claiming: [b.dir.path]).on("gzip", behaviour)
        await mock.scoped {
            b.log.start(append: true)                    // returns at once: gzip is never waited for
            b.log.write("still logging")
            #expect(b.archives.count == 1, "rotation did not happen: \(b.archives)")
            await Self.waitForGzip(mock)
            b.log.write("and after gzip was asked")
            b.log.close()
        }
        #expect(mock.calls.count == 1, "no retry storm")
        #expect(b.log.droppedLineCount == 0)
        #expect(b.archives.count == 1 && b.archives[0].hasSuffix(".log"), "\(b.archives)")
        #expect(try Data(contentsOf: b.dir.appendingPathComponent(b.archives[0])) == b.oldBytes,
                "a failed gzip must leave the plain archive whole")
        let fresh = try String(contentsOf: b.log.url, encoding: .utf8)
        #expect(fresh.contains("still logging") && fresh.contains("and after gzip was asked"))
    }
}
