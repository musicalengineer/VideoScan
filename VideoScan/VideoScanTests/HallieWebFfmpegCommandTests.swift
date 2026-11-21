// HallieWebFfmpegCommandTests.swift — the two production ffmpeg runners of
// the Hallie web server (HallieWebProxyCache.ffmpeg, HallieWebPosterCache.ffmpeg)
// go through ProcessRunner (2026-11-21; they were hand-rolled Process()
// sites), so a ScriptedExecutor answers them.
//
//   COMMAND   the exact command line: ToolLocator's ffmpeg + plan.arguments,
//             the app's own environment
//   FAILURE   nonzero exit (the last stderr line / the exit code), a crash,
//             a launch failure — each thrown, none read as success; and
//             through the cache: failed status, no partial, no proxy/poster
// The state machines themselves are HallieWebProxyTests' (fake runner).
// Parallel by design: each test has its own scratch directory and mock.

import Foundation
import Testing
@testable import VideoScan
@_spi(Testing) import VideoScanCore

@Suite("Hallie web — the production ffmpeg runners through the executor seam", .timeLimit(.minutes(1)))
struct HallieWebFfmpegCommandTests {

    /// A scratch directory (the mock's claim) or nil when ffmpeg is not
    /// installed: both runners refuse before spawning then, so there is no
    /// command to pin.
    func scratch() throws -> URL? {
        guard FileManager.default.isExecutableFile(atPath: ToolLocator.ffmpegPath) else {
            Issue.record("ffmpeg not found — the production runners refuse before any command")
            return nil
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hallie-web-cmd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Proxy

    @Test("COMMAND (proxy): ffmpeg is issued once with exactly plan.arguments and the app's environment")
    func proxyCommandLine() async throws {
        guard let dir = try scratch() else { return }
        defer { try? FileManager.default.removeItem(at: dir) }
        let plan = HallieWebProxyPlan(sourcePath: dir.appendingPathComponent("tape.dv").path,
                                      outputPath: dir.appendingPathComponent(".x.partial.mp4").path, height: 720)
        let mock = ScriptedExecutor(claiming: [dir.path]).on("ffmpeg", .writeOutputFile(Data("proxy".utf8)))
        try await mock.scoped { try await HallieWebProxyCache.ffmpeg(plan) }
        #expect(mock.calls.count == 1)
        #expect(mock.calls.first?.executable == ToolLocator.ffmpegPath)
        #expect(mock.calls.first?.arguments == plan.arguments)
        #expect(mock.calls.first?.arguments == [
            "-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-i", plan.sourcePath,
            "-vf", "scale=-2:'min(720,ih)',format=yuv420p",
            "-c:v", "h264_videotoolbox", "-q:v", "65", "-profile:v", "main",
            "-c:a", "aac", "-b:a", "128k", "-ac", "2", "-movflags", "+faststart", "-f", "mp4", plan.outputPath,
        ])
        #expect(mock.calls.first?.environment == nil)
    }

    @Test("FAILURE (proxy): a nonzero exit throws ffmpeg's last stderr line with its exit code; silence is named by the code")
    func proxyNonzeroExit() async throws {
        guard let dir = try scratch() else { return }
        defer { try? FileManager.default.removeItem(at: dir) }
        let plan = HallieWebProxyPlan(sourcePath: dir.appendingPathComponent("tape.dv").path,
                                      outputPath: dir.appendingPathComponent("out.mp4").path, height: 720)
        let loud = ScriptedExecutor(claiming: [dir.path])
            .on("ffmpeg", .output(stderr: "[dv @ 0x1] warning\n\(plan.sourcePath): Invalid data found when processing input\n", exit: 183))
        await loud.scoped {
            do {
                try await HallieWebProxyCache.ffmpeg(plan)
                Issue.record("a failed encode returned normally")
            } catch {
                let e = error as NSError
                #expect(e.domain == "HallieWebProxy" && e.code == 183)
                #expect(e.localizedDescription == "\(plan.sourcePath): Invalid data found when processing input")
            }
        }
        let silent = ScriptedExecutor(claiming: [dir.path]).on("ffmpeg", .crash(signal: 9))
        await silent.scoped {
            do {
                try await HallieWebProxyCache.ffmpeg(plan)
                Issue.record("a killed encode returned normally")
            } catch {
                let e = error as NSError
                #expect(e.code == 9 && e.localizedDescription == "exit 9")
            }
        }
    }

    @Test("FAILURE (proxy): an ffmpeg that cannot be started throws, in words")
    func proxyLaunchFailure() async throws {
        guard let dir = try scratch() else { return }
        defer { try? FileManager.default.removeItem(at: dir) }
        let plan = HallieWebProxyPlan(sourcePath: dir.appendingPathComponent("tape.dv").path,
                                      outputPath: dir.appendingPathComponent("out.mp4").path, height: 720)
        let mock = ScriptedExecutor(claiming: [dir.path]).on("ffmpeg", .launchFailure)
        await mock.scoped {
            do {
                try await HallieWebProxyCache.ffmpeg(plan)
                Issue.record("an unlaunchable ffmpeg returned normally")
            } catch {
                #expect((error as NSError).code == 3)
                #expect(error.localizedDescription.hasPrefix("ffmpeg could not be started: "), "\(error.localizedDescription)")
            }
        }
    }

    @Test("FAILURE (proxy, through the cache): a failed encode is `failed` with the reason — no proxy, no partial; a good one is ready")
    func proxyCacheEndToEnd() async throws {
        guard let dir = try scratch() else { return }
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = HallieWebProxyCache(directory: dir)
        let bad = UUID(), good = UUID()
        let mock = ScriptedExecutor(claiming: [dir.path])
            .on("ffmpeg", containing: ["broken.dv"], .writeOutputFile(Data("half".utf8), stderr: "moov atom not found\n", exit: 1))
            .on("ffmpeg", .writeOutputFile(Data("proxy".utf8)))
        await mock.scoped {
            _ = await cache.ensure(recordID: bad, sourcePath: dir.appendingPathComponent("broken.dv").path,
                                   volumeRoot: "/Volumes/A", volumeIsSpinningDisk: false)
            _ = await cache.ensure(recordID: good, sourcePath: dir.appendingPathComponent("fine.dv").path,
                                   volumeRoot: "/Volumes/B", volumeIsSpinningDisk: false)
            for _ in 0..<1000 {
                let (a, b) = (await cache.status(for: bad), await cache.status(for: good))
                if case .preparing = a {} else if case .preparing = b {} else { break }
                try? await Task.sleep(for: .milliseconds(5))
            }
            #expect(await cache.status(for: bad) == .failed("moov atom not found"))
            #expect(await cache.status(for: good) == .ready(cache.proxyURL(for: good)))
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(names == ["\(good.uuidString).mp4"], "the failed encode left something behind: \(names)")
        #expect(mock.calls.count == 2)
    }

    // MARK: Poster

    @Test("COMMAND (poster): ffmpeg is issued once with exactly plan.arguments and the app's environment")
    func posterCommandLine() async throws {
        guard let dir = try scratch() else { return }
        defer { try? FileManager.default.removeItem(at: dir) }
        let plan = HallieWebPosterPlan(sourcePath: dir.appendingPathComponent("tape.mxf").path,
                                       outputPath: dir.appendingPathComponent(".x.partial.jpg").path, offsetSeconds: 3)
        let mock = ScriptedExecutor(claiming: [dir.path]).on("ffmpeg", .writeOutputFile(Data([0xFF, 0xD8])))
        try await mock.scoped { try await HallieWebPosterCache.ffmpeg(plan) }
        #expect(mock.calls.count == 1)
        #expect(mock.calls.first?.executable == ToolLocator.ffmpegPath)
        #expect(mock.calls.first?.arguments == [
            "-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-ss", "3.0", "-i", plan.sourcePath,
            "-frames:v", "1", "-vf", "scale=-2:'min(360,ih)'", "-q:v", "4", "-f", "image2", plan.outputPath,
        ])
        #expect(mock.calls.first?.environment == nil)
    }

    @Test("FAILURE (poster): nonzero exit, a crash and a launch failure each throw — none is read as a still",
          arguments: ["exit", "crash", "launch"])
    func posterFailures(_ how: String) async throws {
        guard let dir = try scratch() else { return }
        defer { try? FileManager.default.removeItem(at: dir) }
        let plan = HallieWebPosterPlan(sourcePath: dir.appendingPathComponent("tape.mxf").path,
                                       outputPath: dir.appendingPathComponent("out.jpg").path, offsetSeconds: 0)
        let behaviour: ScriptedExecutor.Behaviour = how == "exit" ? .output(stderr: "Invalid data\n", exit: 69)
            : how == "crash" ? .crash(signal: 11) : .launchFailure
        let mock = ScriptedExecutor(claiming: [dir.path]).on("ffmpeg", behaviour)
        await mock.scoped {
            do {
                try await HallieWebPosterCache.ffmpeg(plan)
                Issue.record("\(how): returned normally")
            } catch {
                let e = error as NSError
                #expect(e.domain == "HallieWebPoster")
                #expect(e.code == (how == "exit" ? 69 : how == "crash" ? 11 : 3))
            }
        }
    }

    @Test("FAILURE (poster, through the cache): a failed still is marked failed and leaves no partial")
    func posterCacheEndToEnd() async throws {
        guard let dir = try scratch() else { return }
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = HallieWebPosterCache(directory: dir)
        let id = UUID()
        let mock = ScriptedExecutor(claiming: [dir.path])
            .on("ffmpeg", .writeOutputFile(Data("half a jpeg".utf8), exit: 1))
        await mock.scoped {
            #expect(await cache.poster(for: id, sourcePath: dir.appendingPathComponent("tape.mxf").path, durationSeconds: 60) == nil)
            for _ in 0..<1000 where !(await cache.isFailed(id)) { try? await Task.sleep(for: .milliseconds(5)) }
            #expect(await cache.isFailed(id))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        #expect(mock.calls.count == 1)
    }
}
