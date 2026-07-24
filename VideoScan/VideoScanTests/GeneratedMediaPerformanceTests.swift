import AVFoundation
import Foundation
import Testing
@testable import VideoScan

// Opt-in generated-media benchmarks. These intentionally print measurements
// instead of asserting timing thresholds, because machine load and thermal
// state make strict pass/fail performance tests noisy.
@MainActor
@Suite("Generated Media Performance Benchmarks", .serialized)
struct GeneratedMediaPerformanceTests {

    nonisolated static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["VIDEOSCAN_PERF"] == "1"
            || FileManager.default.fileExists(atPath: "/tmp/videoscan_perf_enabled")
    }

    private static var defaultFileCount: Int {
        envInt("VIDEOSCAN_PERF_FILE_COUNT", default: 12)
    }

    private static var defaultDuration: Double {
        envDouble("VIDEOSCAN_PERF_DURATION", default: 1.5)
    }

    // Large corpora (run_generated_media_perf.sh --file-count 1000) blow past a
    // fixed 10-minute budget, so the limit is tunable per invocation.
    private static var timeLimitMinutes: Int {
        envInt("VIDEOSCAN_PERF_TIME_LIMIT_MIN", default: 10)
    }

    @Test(
        .disabled(if: !isEnabled, "Set VIDEOSCAN_PERF=1 to run generated-media benchmarks"),
        .timeLimit(.minutes(timeLimitMinutes))
    )
    func catalogProbeThroughputColdAndWarmCache() async throws {
        guard TestMediaGenerator.isAvailable else { return }

        let fileCount = Self.defaultFileCount
        let paths = try Self.generateCorpus(
            count: fileCount,
            duration: Self.defaultDuration,
            resolution: "640x360",
            frameRate: 24
        )
        defer { TestMediaGenerator.cleanup(paths) }

        let model = VideoScanModel()
        let concurrencyValues = Self.concurrencyValues(maximum: min(32, max(1, fileCount)))

        Self.emit("VIDEOSCAN_PERF catalog probe corpus: \(fileCount) file(s), \(Self.defaultDuration)s, 640x360")
        for concurrency in concurrencyValues {
            let cold = await Self.timeProbeBatch(
                paths: paths,
                concurrency: concurrency,
                model: model,
                skipHashing: true
            )
            let warm = await Self.timeProbeBatch(
                paths: paths,
                concurrency: concurrency,
                model: model,
                skipHashing: true
            )
            Self.printProbeResult(label: "catalog probe", concurrency: concurrency, cold: cold, warm: warm)
        }
    }

    @Test(
        .disabled(if: !isEnabled, "Set VIDEOSCAN_PERF=1 to run generated-media benchmarks"),
        .timeLimit(.minutes(timeLimitMinutes))
    )
    func framePrefetcherDecodeThroughput() async throws {
        guard TestMediaGenerator.isAvailable else { return }

        let path = try TestMediaGenerator.generate(
            container: "mp4",
            streams: .videoOnly,
            duration: max(Self.defaultDuration, 4.0),
            resolution: "1280x720",
            frameRate: 30,
            prefix: "videoscan_perf_prefetch"
        )
        defer { TestMediaGenerator.cleanup(path) }

        let (reader, output, fps) = try await Self.makeReader(path: path)
        let prefetcher = FramePrefetcher(
            reader: reader,
            trackOutput: output,
            frameInterval: 1.0 / fps,
            bufferCapacity: 8
        )

        let start = CFAbsoluteTimeGetCurrent()
        var frames = 0
        var decodeSeconds = 0.0
        for await frame in prefetcher.frames() {
            frames += 1
            decodeSeconds += frame.decodeSeconds
            prefetcher.releaseSlot()
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let fpsMeasured = Double(frames) / max(elapsed, 0.001)
        let avgDecodeMs = decodeSeconds / Double(max(frames, 1)) * 1000

        Self.emit(String(format:
            "VIDEOSCAN_PERF frame prefetch: %d frames in %.3fs = %.1f fps, avg decode %.2fms/frame",
            frames, elapsed, fpsMeasured, avgDecodeMs
        ))

        #expect(frames > 0)
    }

    @Test(
        .disabled(if: !isEnabled, "Set VIDEOSCAN_PERF=1 to run generated-media benchmarks"),
        .timeLimit(.minutes(timeLimitMinutes))
    )
    func generatedMediaCleanupRemovesBenchmarkFiles() throws {
        guard TestMediaGenerator.isAvailable else { return }

        let paths = try Self.generateCorpus(
            count: 3,
            duration: 0.5,
            resolution: "320x180",
            frameRate: 12
        )
        #expect(paths.allSatisfy { FileManager.default.fileExists(atPath: $0) })

        TestMediaGenerator.cleanup(paths)
        #expect(paths.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
    }

    private static func generateCorpus(
        count: Int,
        duration: Double,
        resolution: String,
        frameRate: Int
    ) throws -> [String] {
        var paths: [String] = []
        paths.reserveCapacity(count)
        do {
            for idx in 0..<count {
                let streams: StreamConfig = idx % 5 == 0 ? .videoOnly : .videoAndAudio
                let path = try TestMediaGenerator.generate(
                    container: idx % 4 == 0 ? "mov" : "mp4",
                    streams: streams,
                    duration: duration,
                    resolution: resolution,
                    frameRate: frameRate,
                    prefix: "videoscan_perf_probe"
                )
                paths.append(path)
            }
            return paths
        } catch {
            TestMediaGenerator.cleanup(paths)
            throw error
        }
    }

    private static func makeReader(path: String) async throws -> (AVAssetReader, AVAssetReaderTrackOutput, Double) {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw PerfBenchmarkError(message: "Generated file has no video track")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw PerfBenchmarkError(message: "AVAssetReader failed to start")
        }
        return (reader, output, Double(try await track.load(.nominalFrameRate)))
    }

    private static func timeProbeBatch(
        paths: [String],
        concurrency: Int,
        model: VideoScanModel,
        skipHashing: Bool
    ) async -> (seconds: Double, records: Int, playable: Int) {
        let start = CFAbsoluteTimeGetCurrent()
        let records = await probeBatch(
            paths: paths,
            concurrency: concurrency,
            model: model,
            skipHashing: skipHashing
        )
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let playable = records.filter { $0.streamType != .ffprobeFailed }.count
        return (elapsed, records.count, playable)
    }

    private static func probeBatch(
        paths: [String],
        concurrency: Int,
        model: VideoScanModel,
        skipHashing: Bool
    ) async -> [VideoRecord] {
        guard !paths.isEmpty else { return [] }
        let limit = max(1, concurrency)
        var results = [VideoRecord]()
        results.reserveCapacity(paths.count)

        await withTaskGroup(of: VideoRecord.self) { group in
            var submitted = 0
            for _ in 0..<min(limit, paths.count) {
                let path = paths[submitted]
                group.addTask {
                    await model.probeFile(
                        url: URL(fileURLWithPath: path),
                        skipHashing: skipHashing
                    )
                }
                submitted += 1
            }

            for await record in group {
                results.append(record)
                if submitted < paths.count {
                    let path = paths[submitted]
                    group.addTask {
                        await model.probeFile(
                            url: URL(fileURLWithPath: path),
                            skipHashing: skipHashing
                        )
                    }
                    submitted += 1
                }
            }
        }
        return results
    }

    private static func printProbeResult(
        label: String,
        concurrency: Int,
        cold: (seconds: Double, records: Int, playable: Int),
        warm: (seconds: Double, records: Int, playable: Int)
    ) {
        let coldRate = Double(cold.records) / max(cold.seconds, 0.001)
        let warmRate = Double(warm.records) / max(warm.seconds, 0.001)
        Self.emit(String(format:
            "VIDEOSCAN_PERF %@ c=%02d cold %.3fs %.1f files/s (%d playable) | warm %.3fs %.1f files/s (%d playable)",
            label, concurrency, cold.seconds, coldRate, cold.playable,
            warm.seconds, warmRate, warm.playable
        ))
    }

    private static func concurrencyValues(maximum: Int) -> [Int] {
        [1, 4, 8, 16, 24, 32]
            .filter { $0 <= maximum }
            .reduce(into: []) { values, next in
                if !values.contains(next) { values.append(next) }
            }
    }

    private static func envInt(_ name: String, default defaultValue: Int) -> Int {
        guard let raw = ProcessInfo.processInfo.environment[name],
              let value = Int(raw), value > 0 else {
            return configInt(name, default: defaultValue)
        }
        return value
    }

    private static func envDouble(_ name: String, default defaultValue: Double) -> Double {
        guard let raw = ProcessInfo.processInfo.environment[name],
              let value = Double(raw), value > 0 else {
            return configDouble(name, default: defaultValue)
        }
        return value
    }

    private static func configInt(_ name: String, default defaultValue: Int) -> Int {
        let path = "/tmp/\(name.lowercased())"
        guard let raw = try? String(contentsOfFile: path).trimmingCharacters(in: .whitespacesAndNewlines),
              let value = Int(raw), value > 0 else {
            return defaultValue
        }
        return value
    }

    private static func configDouble(_ name: String, default defaultValue: Double) -> Double {
        let path = "/tmp/\(name.lowercased())"
        guard let raw = try? String(contentsOfFile: path).trimmingCharacters(in: .whitespacesAndNewlines),
              let value = Double(raw), value > 0 else {
            return defaultValue
        }
        return value
    }

    // Per-run results path so concurrent invocations can't clobber each other;
    // the fixed /tmp path remains as fallback for direct xcodebuild invocations.
    private static var metricsURL: URL {
        if let path = ProcessInfo.processInfo.environment["VIDEOSCAN_PERF_RESULTS"],
           !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: "/tmp/videoscan_perf_results.txt")
    }

    private static func emit(_ line: String) {
        print(line)
        let data = Data((line + "\n").utf8)
        if FileManager.default.fileExists(atPath: metricsURL.path),
           let handle = try? FileHandle(forWritingTo: metricsURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: metricsURL)
        }
    }
}

private struct PerfBenchmarkError: Error {
    let message: String
}

private extension TestMediaGenerator {
    static func cleanup(_ paths: [String]) {
        for path in paths {
            cleanup(path)
        }
    }
}
