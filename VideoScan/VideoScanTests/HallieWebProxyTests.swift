import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

/// Access copies for the iPad (Saturday 2026-08-22). The state machine is
/// tested with a fake runner; one real-ffmpeg test covers the media matrix
/// (DV, FFV1/MKV, ProRes/MOV — the shapes the Cape tapes actually take).
struct HallieWebProxyTests {

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hallie-proxy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func thePlanIsExactlyTheFfmpegLineWeMean() {
        let plan = HallieWebProxyPlan(sourcePath: "/v/tape.dv", outputPath: "/p/x.partial.mp4", height: 720)
        #expect(plan.arguments == [
            "-hide_banner", "-nostdin", "-loglevel", "error", "-y",
            "-i", "/v/tape.dv",
            "-vf", "scale=-2:'min(720,ih)',format=yuv420p",
            "-c:v", "h264_videotoolbox", "-q:v", "65", "-profile:v", "main",
            "-c:a", "aac", "-b:a", "128k", "-ac", "2",
            "-movflags", "+faststart",
            "-f", "mp4", "/p/x.partial.mp4",
        ])
        let defaults = UserDefaults(suiteName: "HallieWebProxyTests.\(UUID().uuidString)")!
        #expect(HallieWebProxyPlan.height(defaults) == 720, "default is 720p")
        defaults.set(1080, forKey: HallieWebProxyPlan.heightKey)
        #expect(HallieWebProxyPlan.height(defaults) == 1080)
        defaults.set(17, forKey: HallieWebProxyPlan.heightKey)
        #expect(HallieWebProxyPlan.height(defaults) == 720, "nonsense falls back")
        #expect(HallieWebProxyPlan.directory(defaults).path.hasSuffix("VideoScan/web-proxies"))
        defaults.set("/Volumes/Projects/proxies", forKey: HallieWebProxyPlan.directoryKey)
        #expect(HallieWebProxyPlan.directory(defaults).path == "/Volumes/Projects/proxies")
    }

    @Test func ensureStartsOnceThenReportsReadyAndNeverLeavesAPartial() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runs = Counter()
        let cache = HallieWebProxyCache(directory: dir, runner: { plan in
            await runs.bump()
            try await Task.sleep(for: .milliseconds(150))
            try Data("proxy".utf8).write(to: URL(fileURLWithPath: plan.outputPath))
        })
        let id = UUID()
        let first = await cache.ensure(recordID: id, sourcePath: "/v/a.dv", volumeRoot: "/Volumes/A", volumeIsSpinningDisk: false)
        guard case .preparing = first else { Issue.record("should be preparing, got \(first)"); return }
        let second = await cache.ensure(recordID: id, sourcePath: "/v/a.dv", volumeRoot: "/Volumes/A", volumeIsSpinningDisk: false)
        guard case .preparing = second else { Issue.record("a second ask must not start a second encode"); return }
        try await Task.sleep(for: .milliseconds(600))
        guard case .ready(let url) = await cache.status(for: id) else { Issue.record("should be ready"); return }
        #expect(url.lastPathComponent == "\(id.uuidString).mp4")
        #expect(await runs.value == 1)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".") }
        #expect(leftovers.isEmpty, "no partial left behind: \(leftovers)")
    }

    @Test func aFailedEncodeIsReportedAndRetriable() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let attempts = Counter()
        let cache = HallieWebProxyCache(directory: dir, runner: { plan in
            let n = await attempts.bump()
            if n == 1 { throw NSError(domain: "t", code: 9, userInfo: [NSLocalizedDescriptionKey: "Invalid data found"]) }
            try Data("ok".utf8).write(to: URL(fileURLWithPath: plan.outputPath))
        })
        let id = UUID()
        _ = await cache.ensure(recordID: id, sourcePath: "/v/bad.mxf", volumeRoot: "/Volumes/A", volumeIsSpinningDisk: false)
        try await Task.sleep(for: .milliseconds(300))
        guard case .failed(let why) = await cache.status(for: id) else { Issue.record("should have failed"); return }
        #expect(why == "Invalid data found")
        // Asking again retries.
        _ = await cache.ensure(recordID: id, sourcePath: "/v/bad.mxf", volumeRoot: "/Volumes/A", volumeIsSpinningDisk: false)
        try await Task.sleep(for: .milliseconds(300))
        guard case .ready = await cache.status(for: id) else { Issue.record("retry should succeed"); return }
    }

    @Test func aSpinningDiskGetsOneEncodeAtATimeAndAnSSDTwo() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gauge = Gauge()
        let cache = HallieWebProxyCache(directory: dir, maxConcurrent: 2, runner: { plan in
            await gauge.enter(plan.sourcePath)
            try await Task.sleep(for: .milliseconds(250))
            await gauge.leave(plan.sourcePath)
            try Data("ok".utf8).write(to: URL(fileURLWithPath: plan.outputPath))
        })
        for i in 0..<3 {
            _ = await cache.ensure(recordID: UUID(), sourcePath: "/Volumes/HDD/t\(i).dv",
                                   volumeRoot: "/Volumes/HDD", volumeIsSpinningDisk: true)
        }
        for i in 0..<3 {
            _ = await cache.ensure(recordID: UUID(), sourcePath: "/Volumes/SSD/s\(i).mxf",
                                   volumeRoot: "/Volumes/SSD", volumeIsSpinningDisk: false)
        }
        try await Task.sleep(for: .seconds(2))
        #expect(await gauge.peak(prefix: "/Volumes/HDD") == 1, "HDD: one reader at a time")
        #expect(await gauge.peak(prefix: "/Volumes/SSD") <= 2)
        #expect(await gauge.peakTotal <= 3, "global cap (2 in flight + the one admitted by the volume rule)")
    }

    @Test func realFfmpegMakesSafariPlayableProxiesForTheTapeShapes() async throws {
        let ffmpeg = ToolLocator.ffmpegPath
        guard FileManager.default.isExecutableFile(atPath: ffmpeg) else {
            Issue.record("ffmpeg not found — media-matrix test skipped"); return
        }
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Media matrix: the shapes the Cape tapes actually take.
        let fixtures: [(name: String, args: [String])] = [
            // DV demands 48 kHz stereo PCM; the muxer rejects anything else.
            ("test_tape.dv",  ["-c:v", "dvvideo", "-pix_fmt", "yuv411p", "-s", "720x480", "-r", "29.97",
                               "-c:a", "pcm_s16le", "-ar", "48000", "-ac", "2", "-f", "dv"]),
            ("test_ffv1.mkv", ["-c:v", "ffv1", "-c:a", "pcm_s16le", "-f", "matroska"]),
            ("test_prores.mov", ["-c:v", "prores_ks", "-profile:v", "0", "-c:a", "pcm_s16le", "-f", "mov"]),
        ]
        for fixture in fixtures {
            let out = dir.appendingPathComponent(fixture.name)
            let gen = Process()
            gen.executableURL = URL(fileURLWithPath: ffmpeg)
            gen.arguments = ["-hide_banner", "-loglevel", "error", "-y",
                             "-f", "lavfi", "-i", "testsrc=size=640x480:rate=30",
                             "-f", "lavfi", "-i", "sine=frequency=440",
                             "-t", "1", "-shortest"] + fixture.args + [out.path]
            let err = Pipe(); gen.standardError = err
            try gen.run(); gen.waitUntilExit()
            let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            #expect(gen.terminationStatus == 0, "fixture \(fixture.name): \(stderr)")
        }
        let cache = HallieWebProxyCache(directory: dir.appendingPathComponent("proxies"), height: 360)
        var ids: [(UUID, String)] = []
        for fixture in fixtures {
            let id = UUID()
            ids.append((id, fixture.name))
            _ = await cache.ensure(recordID: id, sourcePath: dir.appendingPathComponent(fixture.name).path,
                                   volumeRoot: dir.path, volumeIsSpinningDisk: false)
        }
        let deadline = Date().addingTimeInterval(60)
        for (id, name) in ids {
            while Date() < deadline {
                if case .preparing = await cache.status(for: id) { try await Task.sleep(for: .milliseconds(200)); continue }
                break
            }
            guard case .ready(let url) = await cache.status(for: id) else {
                Issue.record("\(name): \(await cache.status(for: id))"); continue
            }
            // Prove it is what Safari wants: H.264 video + AAC audio in MP4, faststart (moov before mdat).
            let probe = Process()
            probe.executableURL = URL(fileURLWithPath: ToolLocator.ffprobePath)
            probe.arguments = ["-v", "error", "-show_entries", "stream=codec_name", "-of", "csv=p=0", url.path]
            let pipe = Pipe(); probe.standardOutput = pipe
            try probe.run(); probe.waitUntilExit()
            let codecs = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            #expect(codecs.contains("h264"), "\(name): \(codecs)")
            #expect(codecs.contains("aac"), "\(name): \(codecs)")
            let head = try FileHandle(forReadingFrom: url).read(upToCount: 64 * 1024) ?? Data()
            let moov = head.range(of: Data("moov".utf8))?.lowerBound ?? Int.max
            let mdat = head.range(of: Data("mdat".utf8))?.lowerBound ?? Int.max
            #expect(moov < mdat, "\(name): faststart puts moov first")
        }
    }
}

private actor Counter {
    private(set) var value = 0
    @discardableResult func bump() -> Int { value += 1; return value }
}

private actor Gauge {
    private var active: [String: Int] = [:]
    private var peaks: [String: Int] = [:]
    private var total = 0
    private(set) var peakTotal = 0
    private func root(_ path: String) -> String { String(path.split(separator: "/").prefix(2).joined(separator: "/")) }
    func enter(_ path: String) {
        let r = "/" + root(path)
        active[r, default: 0] += 1
        peaks[r] = max(peaks[r] ?? 0, active[r]!)
        total += 1; peakTotal = max(peakTotal, total)
    }
    func leave(_ path: String) {
        active["/" + root(path), default: 1] -= 1
        total -= 1
    }
    func peak(prefix: String) -> Int { peaks[prefix] ?? 0 }
}
