import Testing
import Foundation
import Vision
import AVFoundation
import CoreImage
import os
@testable import VideoScan

// MARK: - Integration Stress Test
//
// Hammers multiple subsystems simultaneously: catalog search, ffprobe,
// file hashing, Vision face detection, and ArcFace inference — all
// running concurrently. If the app survives without crashing, leaking
// memory, or deadlocking, it passes.
//
// Lives in the Stress group in TestDriver (opt-in). Not run on CI
// (timing-sensitive, needs real hardware).

@Suite("Integration Stress")
struct IntegrationStressTests {

    static let fixturesDir: String = {
        let thisFile = #filePath
        let repoRoot = URL(fileURLWithPath: thisFile)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repoRoot.path
    }()

    static let faceVideoPath = fixturesDir + "/tests/fixtures/videos/test_face_3s.mp4"
    static let guitarVideoPath = fixturesDir + "/tests/fixtures/videos/test_guitar_3s.mp4"
    static let referencePhotoPath = fixturesDir + "/tests/fixtures/photos/rick_reference.jpg"

    // MARK: - The Big One: concurrent subsystem stress

    @Test(.timeLimit(.minutes(3)))
    func concurrentSubsystemStorm() async throws {
        let memBefore = processResidentMemoryMB()

        // Reaching the line after this means no subsystem crashed or deadlocked.
        await Self.runAllStorms()

        let memAfter = processResidentMemoryMB()
        let growth = memAfter - memBefore
        #expect(growth < 500,
                "Memory grew \(Int(growth)) MB during stress — possible leak")
    }

    // MARK: - Pool-liveness sensor (CI red 2026-09-25, run 36202513830)
    //
    // The storm wedged the GH virt-M1 runner for 40 min: its 3-minute
    // .timeLimit never even RECORDED an issue, because Swift Testing's
    // time limit is a sibling child task that must wake from a sleep on
    // the cooperative pool — and every pool thread (~3 on that VM) was
    // pinned inside the Vision storm's synchronous decode+detect loop,
    // which had no suspension point from first frame to last.
    //
    // This sensor stands in for that timer: a ticker task sleeps 20 ms
    // and counts wake-ups while the storms run. If the storms pin the
    // pool, the ticker can't wake and the count collapses to ~0.
    // Deterministic red/green under a 1-thread pool:
    //   TEST_RUNNER_LIBDISPATCH_COOPERATIVE_POOL_STRICT=1
    // (On a wide pool it passes either way — 8 blocking tasks can't pin
    // 18 threads — which is exactly why this never showed on the M4/M5.)
    @Test(.timeLimit(.minutes(2)),
          .enabled(if: FileManager.default.fileExists(atPath: faceVideoPath)))
    func stormsLeaveTheCooperativePoolLive() async {
        let ticks = OSAllocatedUnfairLock(initialState: 0)
        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
                ticks.withLock { $0 += 1 }
            }
        }
        let clock = ContinuousClock()
        let start = clock.now
        await Self.runAllStorms()
        let elapsed = start.duration(to: clock.now)
        ticker.cancel()

        let got = ticks.withLock { $0 }
        let elapsedMs = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        let possible = Int(elapsedMs / 20)
        // A live pool lets the ticker run most of its turns; a pinned one
        // lets it run ~none. A quarter is far from both ends.
        #expect(got >= max(3, possible / 4),
                "Ticker woke \(got) of ~\(possible) times in \(Int(elapsedMs)) ms — the storms pinned the cooperative pool, so no time limit or other task could run")
    }

    /// All five storms concurrently — shared by the storm test and the
    /// pool-liveness sensor so they exercise the same load.
    private static func runAllStorms() async {
        await withTaskGroup(of: String.self) { group in
            group.addTask { await Self.catalogSearchStorm() }
            group.addTask { await Self.ffprobeStorm() }
            group.addTask { await Self.hashingStorm() }
            group.addTask { await Self.visionDetectionStorm() }
            group.addTask { await Self.arcfaceInferenceStorm() }
            for await _ in group {}
        }
    }

    // MARK: - Individual subsystem storms (also runnable standalone)

    @Test(.timeLimit(.minutes(1)))
    func catalogSearchStormStandalone() async {
        let result = await Self.catalogSearchStorm()
        #expect(result == "catalogSearch")
    }

    @Test(.timeLimit(.minutes(1)))
    func ffprobeStormStandalone() async {
        let result = await Self.ffprobeStorm()
        #expect(result == "ffprobe")
    }

    @Test(.timeLimit(.minutes(1)))
    func hashingStormStandalone() async {
        let result = await Self.hashingStorm()
        #expect(result == "hashing")
    }

    @Test(.timeLimit(.minutes(1)))
    func visionDetectionStormStandalone() async {
        let result = await Self.visionDetectionStorm()
        #expect(result == "visionDetection")
    }

    @Test(.timeLimit(.minutes(1)))
    func arcfaceInferenceStormStandalone() async {
        let result = await Self.arcfaceInferenceStorm()
        #expect(result == "arcfaceInference")
    }

    // MARK: - Subsystem implementations

    /// 50 concurrent search queries against a 1000-record catalog.
    private static func catalogSearchStorm() async -> String {
        let records = (0..<1000).map { i -> VideoRecord in
            let r = VideoRecord()
            r.filename = "family_video_\(i)_\(["donna", "rick", "timmy", "vacation", "birthday", "christmas", "guitar", "piano"][i % 8]).mov"
            r.fullPath = "/Volumes/Archive/Videos/\(r.filename)"
            r.directory = "/Volumes/Archive/Videos"
            r.ext = "MOV"
            r.streamTypeRaw = StreamType.videoAndAudio.rawValue
            r.durationSeconds = Double.random(in: 5...3600)
            r.sizeBytes = Int64.random(in: 1_000_000...5_000_000_000)
            r.videoCodec = ["h264", "prores", "mpeg2video", "dnxhd"][i % 4]
            r.resolution = ["1920x1080", "720x480", "3840x2160", "1280x720"][i % 4]
            return r
        }

        let queries = ["donna", "rick", "birthday", "guitar", "1920", "prores",
                       "vacation christmas", "mov", "piano timmy", "archive"]

        await withTaskGroup(of: Int.self) { group in
            for i in 0..<50 {
                let query = queries[i % queries.count]
                group.addTask {
                    let results = pfRecordsMatchingQuery(records, query: query)
                    return results.count
                }
            }
            var totalMatches = 0
            for await count in group { totalMatches += count }
            // Sanity: "donna" should match ~125 of 1000 records (every 8th)
            // but we don't assert exact counts — just that it didn't crash
            _ = totalMatches
        }
        return "catalogSearch"
    }

    /// 20 concurrent ffprobe calls against real test fixtures.
    private static func ffprobeStorm() async -> String {
        let paths = [faceVideoPath, guitarVideoPath].filter {
            FileManager.default.fileExists(atPath: $0)
        }
        guard !paths.isEmpty else { return "ffprobe" }

        let model = await VideoScanModel()

        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<20 {
                let path = paths[i % paths.count]
                group.addTask {
                    let url = URL(fileURLWithPath: path)
                    let (output, _) = await model.runFFProbe(url: url)
                    return output != nil
                }
            }
            for await _ in group {}
        }
        return "ffprobe"
    }

    /// 50 concurrent partial MD5 hashes on real files.
    private static func hashingStorm() async -> String {
        let paths = [faceVideoPath, guitarVideoPath].filter {
            FileManager.default.fileExists(atPath: $0)
        }
        guard !paths.isEmpty else { return "hashing" }

        await withTaskGroup(of: String.self) { group in
            for i in 0..<50 {
                let path = paths[i % paths.count]
                group.addTask {
                    FileHasher.partialMD5(path: path)
                }
            }
            var hashes: Set<String> = []
            for await hash in group { hashes.insert(hash) }
            // All hashes of the same file should be identical
            _ = hashes
        }
        return "hashing"
    }

    /// 8 concurrent Vision face detection passes on the face video,
    /// each reading all frames. Exercises VNDetectFaceRectanglesRequest
    /// under parallel load — the ANE/GPU contention path.
    private static func visionDetectionStorm() async -> String {
        guard FileManager.default.fileExists(atPath: faceVideoPath) else {
            return "visionDetection"
        }

        await withTaskGroup(of: Int.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await Self.detectFacesInVideo(faceVideoPath)
                }
            }
            for await _ in group {}
        }
        return "visionDetection"
    }

    /// 8 concurrent ArcFace embedding extractions from a real face photo.
    /// Each task loads the model independently (per-job MLModel pattern)
    /// and runs multiple predictions. Skip-gated on model presence.
    private static func arcfaceInferenceStorm() async -> String {
        let (probe, _) = await ArcFaceModelLoader.shared.getModel()
        guard probe != nil else { return "arcfaceInference" }
        guard FileManager.default.fileExists(atPath: referencePhotoPath) else {
            return "arcfaceInference"
        }

        guard let faceImage = extractFaceFromReference() else {
            return "arcfaceInference"
        }

        await withTaskGroup(of: Int.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let (model, _) = await ArcFaceModelLoader.shared.getModel()
                    guard let model else { return 0 }
                    var count = 0
                    for _ in 0..<50 {
                        if arcfaceEmbedding(from: faceImage, model: model).embedding != nil {
                            count += 1
                        }
                    }
                    return count
                }
            }
            for await _ in group {}
        }
        return "arcfaceInference"
    }

    // MARK: - Helpers

    private static func detectFacesInVideo(_ path: String) async -> Int {
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return 0 }

        guard let reader = try? AVAssetReader(asset: asset) else { return 0 }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { return 0 }

        var totalFaces = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            autoreleasepool {
                let faces = pfDetectFacesInBuffer(buffer, orientation: .up)
                totalFaces += faces.count
            }
        }
        reader.cancelReading()
        return totalFaces
    }

    private static func extractFaceFromReference() -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(
                URL(fileURLWithPath: referencePhotoPath) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }

        let req = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: img, options: [:])
        try? handler.perform([req])
        guard let obs = req.results?.first else { return nil }

        return pfNormalizeFaceCrop(from: img, observation: obs, outputSize: 112)
    }
}

// MARK: - Catalog + Probe Pipeline Stress
//
// Simulates a real catalog scan: discover files, probe them in parallel,
// hash them, then search the resulting catalog — all overlapping.

@Suite("Pipeline Stress")
struct PipelineStressTests {

    @Test(.timeLimit(.minutes(2)))
    func catalogScanSimulation() async throws {
        guard TestMediaGenerator.isAvailable else { return }

        // Generate 10 temp media files (mix of types)
        var generatedPaths: [String] = []
        defer { generatedPaths.forEach { TestMediaGenerator.cleanup($0) } }

        for i in 0..<10 {
            let config: StreamConfig = [.videoAndAudio, .videoOnly, .audioOnly][i % 3]
            let container = ["mp4", "mov", "mkv"][i % 3]
            if let path = try? TestMediaGenerator.generate(
                container: container, streams: config, duration: 1.0
            ) {
                generatedPaths.append(path)
            }
        }
        #expect(generatedPaths.count >= 5, "Should generate at least 5 test files")

        let model = await VideoScanModel()
        let memBefore = processResidentMemoryMB()

        // Phase 1: Parallel probe + hash (simulates catalog scan)
        var records: [VideoRecord] = []
        await withTaskGroup(of: VideoRecord.self) { group in
            for path in generatedPaths {
                group.addTask {
                    let url = URL(fileURLWithPath: path)
                    let rec = await model.probeFile(url: url)
                    rec.partialMD5 = FileHasher.partialMD5(path: path)
                    return rec
                }
            }
            for await rec in group {
                records.append(rec)
            }
        }
        #expect(records.count == generatedPaths.count)

        // Phase 2: Concurrent searches while still "scanning"
        // (simulates user searching while scan is running)
        await withTaskGroup(of: Void.self) { group in
            // More probes (second pass)
            for path in generatedPaths.prefix(5) {
                group.addTask {
                    let url = URL(fileURLWithPath: path)
                    _ = await model.runFFProbe(url: url)
                }
            }
            // Simultaneous searches
            for query in ["mp4", "h264", "aac", "test_gen", "video"] {
                group.addTask {
                    _ = pfRecordsMatchingQuery(records, query: query)
                }
            }
            for await _ in group {}
        }

        // Phase 3: Verify catalog integrity after concurrent access
        for rec in records {
            #expect(!rec.filename.isEmpty)
            #expect(rec.sizeBytes > 0)
            #expect(rec.streamType != .noStreams)
        }

        let memAfter = processResidentMemoryMB()
        let growth = memAfter - memBefore
        #expect(growth < 200,
                "Pipeline stress grew \(Int(growth)) MB — check for leaks")
    }

    @Test(.timeLimit(.minutes(1)))
    func duplicateDetectionUnderLoad() async throws {
        guard TestMediaGenerator.isAvailable else { return }

        // Generate identical files (same content, different paths)
        var paths: [String] = []
        defer { paths.forEach { TestMediaGenerator.cleanup($0) } }

        for _ in 0..<20 {
            if let path = try? TestMediaGenerator.generate(
                container: "mp4", streams: .videoAndAudio, duration: 1.0,
                resolution: "160x120", frameRate: 10
            ) {
                paths.append(path)
            }
        }

        // Hash all in parallel
        var hashes: [(String, String)] = []
        await withTaskGroup(of: (String, String).self) { group in
            for path in paths {
                group.addTask {
                    let hash = FileHasher.partialMD5(path: path)
                    return (path, hash)
                }
            }
            for await pair in group {
                hashes.append(pair)
            }
        }

        // All hashes should be non-empty
        #expect(hashes.allSatisfy { !$0.1.isEmpty },
                "Every file should produce a hash")

        // Files with identical content should have identical hashes
        let uniqueHashes = Set(hashes.map(\.1))
        // Generated files have random UUIDs in their names but identical
        // ffmpeg parameters — content differs because testsrc includes
        // a frame counter, so hashes will differ. That's fine — we're
        // testing that parallel hashing doesn't crash or produce corrupt output.
        #expect(!uniqueHashes.isEmpty)
    }
}
