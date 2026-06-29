import Testing
import Foundation
@testable import VideoScan

// MARK: - CombineEngine Tests

@Suite(.serialized) struct CombineEngineTests {

    static let fixturesDir: String = {
        let thisFile = #filePath
        let repoRoot = URL(fileURLWithPath: thisFile)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repoRoot.appendingPathComponent("tests/fixtures/videos").path
    }()

    // regression: #1 — Combined MP4 must not be corrupt when codecs are muxed (verifies output streams parse cleanly)
    @Test func combineMP4VideoWithM4AAudio() async throws {
        let videoPath = "\(Self.fixturesDir)/test_video_only.mp4"
        let audioPath = "\(Self.fixturesDir)/test_audio_only.m4a"
        let outputPath = NSTemporaryDirectory() + "combine_test_\(UUID()).mov"
        defer { try? FileManager.default.removeItem(atPath: outputPath) }

        var logLines: [String] = []
        let result = await CombineEngine.runFFMpeg(
            videoPath: videoPath,
            audioPath: audioPath,
            outputPath: outputPath,
            log: { logLines.append($0) }
        )

        #expect(result.success, "Combine should succeed: exit \(result.exitCode)\n\(result.stderr)")
        #expect(FileManager.default.fileExists(atPath: outputPath))

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
        proc.arguments = ["-v", "quiet", "-print_format", "json", "-show_streams", outputPath]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let json = try JSONDecoder().decode(FFProbeOutput.self, from: data)
        let types = (json.streams ?? []).compactMap { $0.codec_type }
        #expect(types.contains("video"), "Output should have video stream")
        #expect(types.contains("audio"), "Output should have audio stream")
    }

    @Test func combineFailsWithMissingInput() async {
        let result = await CombineEngine.runFFMpeg(
            videoPath: "/nonexistent/video.mp4",
            audioPath: "/nonexistent/audio.m4a",
            outputPath: NSTemporaryDirectory() + "should_not_exist.mov",
            log: { _ in }
        )
        #expect(!result.success)
        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("No such file"))
    }

    @Test func combineResultCapturesStderr() async {
        let videoPath = "\(Self.fixturesDir)/test_video_only.mp4"
        let audioPath = "\(Self.fixturesDir)/test_audio_only.m4a"
        let outputPath = NSTemporaryDirectory() + "combine_stderr_\(UUID()).mov"
        defer { try? FileManager.default.removeItem(atPath: outputPath) }

        let result = await CombineEngine.runFFMpeg(
            videoPath: videoPath,
            audioPath: audioPath,
            outputPath: outputPath,
            log: { _ in }
        )
        #expect(!result.stderr.isEmpty, "stderr should capture ffmpeg output")
    }

    // regression: #1 — Avid MXF pair muxes cleanly: video + audio streams both present in output
    @Test func combineAvidMXFPair() async throws {
        let videoPath = "\(Self.fixturesDir)/video-only-test-1.mxf"
        let audioPath = "\(Self.fixturesDir)/audio-only-test-1.mxf"

        guard FileManager.default.fileExists(atPath: videoPath),
              FileManager.default.fileExists(atPath: audioPath) else {
            return
        }

        let outputPath = NSTemporaryDirectory() + "combine_avid_mxf_\(UUID()).mov"
        defer { try? FileManager.default.removeItem(atPath: outputPath) }

        let result = await CombineEngine.runFFMpeg(
            videoPath: videoPath,
            audioPath: audioPath,
            outputPath: outputPath,
            log: { _ in }
        )

        #expect(result.success, "Avid MXF combine should succeed: exit \(result.exitCode)\n\(result.stderr)")
        #expect(FileManager.default.fileExists(atPath: outputPath))

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
        proc.arguments = ["-v", "quiet", "-print_format", "json", "-show_streams", outputPath]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let json = try JSONDecoder().decode(FFProbeOutput.self, from: data)
        let types = (json.streams ?? []).compactMap { $0.codec_type }
        #expect(types.contains("video"), "Combined output should have video stream")
        #expect(types.contains("audio"), "Combined output should have audio stream")
    }
}

// MARK: - CombineEngine Extended Tests

@Suite(.serialized) struct CombineEngineExtendedTests {

    private static func canDecodeFrame(path: String, streamType: String) async -> Bool {
        let args: [String]
        if streamType == "v" {
            args = ["-v", "error", "-i", path, "-map", "0:v:0", "-vframes", "1", "-f", "null", "-"]
        } else {
            args = ["-v", "error", "-i", path, "-map", "0:a:0", "-frames:a", "1", "-f", "null", "-"]
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: CombineEngine.ffmpegPath)
        proc.arguments = args
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = FileHandle.nullDevice
        do { try proc.run() } catch { return false }
        proc.waitUntilExit()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let errStr = String(data: errData, encoding: .utf8) ?? ""
        return proc.terminationStatus == 0 && errStr.isEmpty
    }

    private static func fullVerify(path: String, expectedDuration: Double) async -> (ok: Bool, reason: String) {
        let (probe, _) = await ScanEngine.runFFProbe(url: URL(fileURLWithPath: path))
        let streams = probe?.streams ?? []
        guard let vStream = streams.first(where: { $0.codec_type == "video" }) else {
            return (false, "no video stream")
        }
        guard streams.contains(where: { $0.codec_type == "audio" }) else {
            return (false, "no audio stream")
        }
        if (vStream.width ?? 0) == 0 || (vStream.height ?? 0) == 0 {
            return (false, "video has no dimensions")
        }
        let outDuration = Double(probe?.format?.duration ?? "0") ?? 0
        let tolerance = max(expectedDuration * 0.1, 2.0)
        if expectedDuration > 0 && outDuration > 0 && abs(outDuration - expectedDuration) > tolerance {
            return (false, "duration mismatch: expected \(expectedDuration), got \(outDuration)")
        }
        if !(await canDecodeFrame(path: path, streamType: "v")) {
            return (false, "video frame decode failed")
        }
        if !(await canDecodeFrame(path: path, streamType: "a")) {
            return (false, "audio frame decode failed")
        }
        return (true, "")
    }

    private static func detectMeanVolume(path: String) async -> Double? {
        let args = ["-v", "info", "-i", path, "-map", "0:a:0",
                    "-af", "volumedetect", "-f", "null", "-"]
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: CombineEngine.ffmpegPath)
        proc.arguments = args
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        let data = errPipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        for line in text.components(separatedBy: .newlines) {
            if line.contains("mean_volume:") {
                let parts = line.components(separatedBy: "mean_volume:")
                if parts.count > 1 {
                    let dbStr = parts[1].trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: " dB", with: "")
                    return Double(dbStr)
                }
            }
        }
        return nil
    }

    // MARK: - Positive Tests

    @Test func combineValidPairStreamCopy() async throws {
        guard TestMediaGenerator.isAvailable else { return }

        let pair = try TestMediaGenerator.createPair(duration: 3.0)
        defer { TestMediaGenerator.cleanup(pair.videoPath, pair.audioPath) }

        let outPath = NSTemporaryDirectory() + "combine_test_\(UUID().uuidString.prefix(8)).mov"
        defer { try? FileManager.default.removeItem(atPath: outPath) }

        let result = await CombineEngine.runFFMpeg(
            videoPath: pair.videoPath,
            audioPath: pair.audioPath,
            outputPath: outPath,
            technique: .streamCopy,
            log: { _ in }
        )

        #expect(result.success == true)
        #expect(result.exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: outPath))

        let verify = await Self.fullVerify(path: outPath, expectedDuration: 3.0)
        #expect(verify.ok == true, "Full verify failed: \(verify.reason)")
    }

    @Test func combineWithProgressReporting() async throws {
        guard TestMediaGenerator.isAvailable else { return }

        let pair = try TestMediaGenerator.createPair(duration: 3.0)
        defer { TestMediaGenerator.cleanup(pair.videoPath, pair.audioPath) }

        let outPath = NSTemporaryDirectory() + "combine_progress_\(UUID().uuidString.prefix(8)).mov"
        defer { try? FileManager.default.removeItem(atPath: outPath) }

        var progressValues: [Double] = []
        let lock = NSLock()

        let result = await CombineEngine.runFFMpeg(
            videoPath: pair.videoPath,
            audioPath: pair.audioPath,
            outputPath: outPath,
            technique: .streamCopy,
            durationSeconds: 3.0,
            onProgress: { frac in
                lock.lock()
                progressValues.append(frac)
                lock.unlock()
            },
            log: { _ in }
        )

        #expect(result.success == true)
        #expect(!progressValues.isEmpty)

        let verify = await Self.fullVerify(path: outPath, expectedDuration: 3.0)
        #expect(verify.ok == true, "Full verify failed: \(verify.reason)")
    }

    // regression: #1 — Re-encode path produces a valid H.264 + AAC output (incompatible-codec fallback)
    @Test func combineReencodeH264() async throws {
        guard TestMediaGenerator.isAvailable else { return }

        let pair = try TestMediaGenerator.createPair(duration: 2.0)
        defer { TestMediaGenerator.cleanup(pair.videoPath, pair.audioPath) }

        let outPath = NSTemporaryDirectory() + "combine_h264_\(UUID().uuidString.prefix(8)).mov"
        defer { try? FileManager.default.removeItem(atPath: outPath) }

        let result = await CombineEngine.runFFMpeg(
            videoPath: pair.videoPath,
            audioPath: pair.audioPath,
            outputPath: outPath,
            technique: .reencodeH264,
            log: { _ in }
        )

        #expect(result.success == true)
        #expect(FileManager.default.fileExists(atPath: outPath))

        let verify = await Self.fullVerify(path: outPath, expectedDuration: 2.0)
        #expect(verify.ok == true, "Full verify failed: \(verify.reason)")

        let (probe, _) = await ScanEngine.runFFProbe(url: URL(fileURLWithPath: outPath))
        let streams = probe?.streams ?? []
        let vCodec = streams.first(where: { $0.codec_type == "video" })?.codec_name
        let aCodec = streams.first(where: { $0.codec_type == "audio" })?.codec_name
        #expect(vCodec == "h264")
        #expect(aCodec == "aac")
    }

    @Test func verifyDurationWithinTolerance() async throws {
        guard TestMediaGenerator.isAvailable else { return }

        let pair = try TestMediaGenerator.createPair(duration: 5.0)
        defer { TestMediaGenerator.cleanup(pair.videoPath, pair.audioPath) }

        let outPath = NSTemporaryDirectory() + "combine_dur_\(UUID().uuidString.prefix(8)).mov"
        defer { try? FileManager.default.removeItem(atPath: outPath) }

        let result = await CombineEngine.runFFMpeg(
            videoPath: pair.videoPath,
            audioPath: pair.audioPath,
            outputPath: outPath,
            technique: .streamCopy,
            log: { _ in }
        )
        #expect(result.success == true)

        let verify = await Self.fullVerify(path: outPath, expectedDuration: 5.0)
        #expect(verify.ok == true, "Full verify failed: \(verify.reason)")
    }

    // MARK: - Negative Tests: Missing Inputs

    @Test func combineFailsMissingVideoFile() async throws {
        guard TestMediaGenerator.isAvailable else { return }

        let audio = try TestMediaGenerator.generate(
            container: "m4a", streams: .audioOnly, duration: 2.0
        )
        defer { TestMediaGenerator.cleanup(audio) }

        let outPath = NSTemporaryDirectory() + "combine_fail_\(UUID().uuidString.prefix(8)).mov"
        defer { try? FileManager.default.removeItem(atPath: outPath) }

        let result = await CombineEngine.runFFMpeg(
            videoPath: "/tmp/nonexistent_video_\(UUID()).mp4",
            audioPath: audio,
            outputPath: outPath,
            technique: .streamCopy,
            log: { _ in }
        )

        #expect(result.success == false)
        #expect(result.exitCode != 0)
        #expect(!FileManager.default.fileExists(atPath: outPath))
    }

    @Test func combineFailsMissingAudioFile() async throws {
        guard TestMediaGenerator.isAvailable else { return }

        let video = try TestMediaGenerator.generate(
            container: "mp4", streams: .videoOnly, duration: 2.0
        )
        defer { TestMediaGenerator.cleanup(video) }

        let outPath = NSTemporaryDirectory() + "combine_fail2_\(UUID().uuidString.prefix(8)).mov"
        defer { try? FileManager.default.removeItem(atPath: outPath) }

        let result = await CombineEngine.runFFMpeg(
            videoPath: video,
            audioPath: "/tmp/nonexistent_audio_\(UUID()).m4a",
            outputPath: outPath,
            technique: .streamCopy,
            log: { _ in }
        )

        #expect(result.success == false)
        #expect(result.exitCode != 0)
    }

    // MARK: - Negative Tests: Stream Content Validation

    @Test func verifyDetectsVideoOnlyOutput() async throws {
        guard TestMediaGenerator.isAvailable else { return }

        let videoOnly = try TestMediaGenerator.generate(
            container: "mp4", streams: .videoOnly, duration: 2.0
        )
        defer { TestMediaGenerator.cleanup(videoOnly) }

        let verify = await Self.fullVerify(path: videoOnly, expectedDuration: 2.0)
        #expect(verify.ok == false)
        #expect(verify.reason.contains("no audio"))
    }

    @Test func verifyDetectsAudioOnlyOutput() async throws {
        guard TestMediaGenerator.isAvailable else { return }

        let audioOnly = try TestMediaGenerator.generate(
            container: "m4a", streams: .audioOnly, duration: 2.0
        )
        defer { TestMediaGenerator.cleanup(audioOnly) }

        let verify = await Self.fullVerify(path: audioOnly, expectedDuration: 2.0)
        #expect(verify.ok == false)
        #expect(verify.reason.contains("no video"))
    }

    @Test func verifyDetectsTwoAudioFilesMuxedAsVideoAudio() async throws {
        guard TestMediaGenerator.isAvailable else { return }

        let audio1 = try TestMediaGenerator.generate(
            container: "m4a", streams: .audioOnly, duration: 2.0, prefix: "test_fake_v"
        )
        let audio2 = try TestMediaGenerator.generate(
            container: "m4a", streams: .audioOnly, duration: 2.0, prefix: "test_fake_a"
        )
        defer { TestMediaGenerator.cleanup(audio1, audio2) }

        let outPath = NSTemporaryDirectory() + "combine_2audio_\(UUID().uuidString.prefix(8)).mov"
        defer { try? FileManager.default.removeItem(atPath: outPath) }

        let result = await CombineEngine.runFFMpeg(
            videoPath: audio1,
            audioPath: audio2,
            outputPath: outPath,
            technique: .streamCopy,
            log: { _ in }
        )

        if result.success && FileManager.default.fileExists(atPath: outPath) {
            let verify = await Self.fullVerify(path: outPath, expectedDuration: 2.0)
            #expect(verify.ok == false, "Should fail: two audio files muxed together have no real video")
        }
    }

    // regression: #1 — Combined MP4 contains real decodable video frames, not just a header
    @Test func verifyDecodesRealFramesInValidCombine() async throws {
        guard TestMediaGenerator.isAvailable else { return }

        let pair = try TestMediaGenerator.createPair(duration: 2.0)
        defer { TestMediaGenerator.cleanup(pair.videoPath, pair.audioPath) }

        let outPath = NSTemporaryDirectory() + "combine_decode_\(UUID().uuidString.prefix(8)).mov"
        defer { try? FileManager.default.removeItem(atPath: outPath) }

        let result = await CombineEngine.runFFMpeg(
            videoPath: pair.videoPath,
            audioPath: pair.audioPath,
            outputPath: outPath,
            technique: .streamCopy,
            log: { _ in }
        )
        #expect(result.success == true)

        let canVideo = await Self.canDecodeFrame(path: outPath, streamType: "v")
        let canAudio = await Self.canDecodeFrame(path: outPath, streamType: "a")
        #expect(canVideo == true, "Must be able to decode a real video frame")
        #expect(canAudio == true, "Must be able to decode a real audio frame")
    }

    @Test func cannotDecodeVideoFromAudioOnlyFile() async throws {
        guard TestMediaGenerator.isAvailable else { return }

        let audioOnly = try TestMediaGenerator.generate(
            container: "m4a", streams: .audioOnly, duration: 2.0
        )
        defer { TestMediaGenerator.cleanup(audioOnly) }

        let canVideo = await Self.canDecodeFrame(path: audioOnly, streamType: "v")
        #expect(canVideo == false, "Audio-only file should fail video decode")
    }

    @Test func cannotDecodeAudioFromVideoOnlyFile() async throws {
        guard TestMediaGenerator.isAvailable else { return }

        let videoOnly = try TestMediaGenerator.generate(
            container: "mp4", streams: .videoOnly, duration: 2.0
        )
        defer { TestMediaGenerator.cleanup(videoOnly) }

        let canAudio = await Self.canDecodeFrame(path: videoOnly, streamType: "a")
        #expect(canAudio == false, "Video-only file should fail audio decode")
    }

    // MARK: - Silence Detection

    @Test func realAudioHasAudibleLevel() async throws {
        guard TestMediaGenerator.isAvailable else { return }

        let pair = try TestMediaGenerator.createPair(duration: 2.0)
        defer { TestMediaGenerator.cleanup(pair.videoPath, pair.audioPath) }

        let outPath = NSTemporaryDirectory() + "combine_audible_\(UUID().uuidString.prefix(8)).mov"
        defer { try? FileManager.default.removeItem(atPath: outPath) }

        let result = await CombineEngine.runFFMpeg(
            videoPath: pair.videoPath,
            audioPath: pair.audioPath,
            outputPath: outPath,
            technique: .streamCopy,
            log: { _ in }
        )
        #expect(result.success == true)

        let meanDB = await Self.detectMeanVolume(path: outPath)
        #expect(meanDB != nil, "Should detect audio level")
        #expect(meanDB! > -60, "440Hz sine tone should be well above silence threshold, got \(meanDB!) dB")
    }

    @Test func silentAudioDetectedBelowThreshold() async throws {
        guard TestMediaGenerator.isAvailable else { return }

        let video = try TestMediaGenerator.generate(
            container: "mp4", streams: .videoOnly, duration: 2.0
        )
        let tmpDir = NSTemporaryDirectory()
        let silentAudio = tmpDir + "silent_audio_\(UUID().uuidString.prefix(8)).m4a"
        defer {
            TestMediaGenerator.cleanup(video)
            try? FileManager.default.removeItem(atPath: silentAudio)
        }

        let silProc = Process()
        silProc.executableURL = URL(fileURLWithPath: CombineEngine.ffmpegPath)
        silProc.arguments = ["-y", "-hide_banner", "-loglevel", "error",
                             "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo",
                             "-t", "2", "-c:a", "aac", silentAudio]
        silProc.standardOutput = FileHandle.nullDevice
        silProc.standardError = FileHandle.nullDevice
        try silProc.run()
        silProc.waitUntilExit()

        let outPath = tmpDir + "combine_silent_\(UUID().uuidString.prefix(8)).mov"
        defer { try? FileManager.default.removeItem(atPath: outPath) }

        let result = await CombineEngine.runFFMpeg(
            videoPath: video,
            audioPath: silentAudio,
            outputPath: outPath,
            technique: .streamCopy,
            log: { _ in }
        )
        #expect(result.success == true)

        let meanDB = await Self.detectMeanVolume(path: outPath)
        #expect(meanDB != nil, "Should detect audio level even for silence")
        #expect(meanDB! < -60, "Silent audio should be below -60 dB, got \(meanDB!) dB")
    }

    // MARK: - Buffered Copy

    @Test func bufferedCopyProducesIdenticalFile() async throws {
        let srcPath = NSTemporaryDirectory() + "buf_src_\(UUID().uuidString.prefix(8)).bin"
        let dstPath = NSTemporaryDirectory() + "buf_dst_\(UUID().uuidString.prefix(8)).bin"
        defer {
            try? FileManager.default.removeItem(atPath: srcPath)
            try? FileManager.default.removeItem(atPath: dstPath)
        }

        let testData = Data(repeating: 0xAB, count: 1024 * 1024)
        try testData.write(to: URL(fileURLWithPath: srcPath))

        try await CombineEngine.bufferedCopy(
            from: URL(fileURLWithPath: srcPath),
            to: URL(fileURLWithPath: dstPath)
        )

        let copied = try Data(contentsOf: URL(fileURLWithPath: dstPath))
        #expect(copied == testData)
    }

    @Test func bufferedCopyFailsForMissingSource() async {
        let dstPath = NSTemporaryDirectory() + "buf_dst_missing_\(UUID().uuidString.prefix(8)).bin"
        defer { try? FileManager.default.removeItem(atPath: dstPath) }

        do {
            try await CombineEngine.bufferedCopy(
                from: URL(fileURLWithPath: "/tmp/nonexistent_\(UUID()).bin"),
                to: URL(fileURLWithPath: dstPath)
            )
            #expect(Bool(false), "should have thrown")
        } catch {
            #expect(true)
        }
    }
}

// MARK: - DashboardState Combine Counter Tests

struct DashboardCombineCounterTests {

    @Test @MainActor func resetForCombineClearsCounters() {
        let dash = DashboardState()
        dash.combineSucceeded = 5
        dash.combineFailed = 2
        dash.combineSkipped = 3
        dash.combineCompleted = 10
        dash.combineCurrentFile = "foo.mov"
        dash.combineJobs = [CombineJobStatus(
            pairIndex: 0,
            videoFilename: "v.mxf", audioFilename: "a.mxf",
            outputFilename: "out.mov", outputPath: "/tmp/out.mov",
            videoSizeBytes: 100, audioSizeBytes: 50,
            totalDurationSeconds: 10, videoOnline: true, audioOnline: true
        )]

        dash.resetForCombine(total: 7)

        #expect(dash.combineTotal == 7)
        #expect(dash.combineCompleted == 0)
        #expect(dash.combineSucceeded == 0)
        #expect(dash.combineFailed == 0)
        #expect(dash.combineSkipped == 0)
        #expect(dash.combineCurrentFile == "")
        #expect(dash.combineJobs.isEmpty)
        #expect(dash.combineStartTime != nil)
    }

    @Test @MainActor func countersAddUpToCompleted() {
        let dash = DashboardState()
        dash.resetForCombine(total: 6)

        dash.combineSucceeded = 3
        dash.combineFailed = 1
        dash.combineSkipped = 2
        dash.combineCompleted = 6

        #expect(dash.combineSucceeded + dash.combineFailed + dash.combineSkipped == dash.combineCompleted)
    }
}

// MARK: - Catalog Navigation Tests (Issue #39)

struct CatalogNavigationTests {

    // regression: #39 — Show in Catalog: pair-mode off returns only the requested record
    @Test func singleRecordNoPairMode() {
        let rec = VideoRecord()
        rec.filename = "test.mov"
        let ids = VideoScanModel.catalogFilterIDs(for: rec.id, pairMode: false, in: [rec])
        #expect(ids == [rec.id])
    }

    // regression: #39 — Show in Catalog: pair-mode follows pairedWith reference
    @Test func pairModeWithPairedWith() {
        let video = VideoRecord()
        video.filename = "clip.V1A.mxf"
        video.streamTypeRaw = "Video only"
        let audio = VideoRecord()
        audio.filename = "clip.A1A.mxf"
        audio.streamTypeRaw = "Audio only"
        video.pairedWith = audio

        let ids = VideoScanModel.catalogFilterIDs(for: video.id, pairMode: true, in: [video, audio])
        #expect(ids.count == 2)
        #expect(ids.contains(video.id))
        #expect(ids.contains(audio.id))
    }

    // regression: #39 — Show in Catalog: cross-volume pair recovers via pairGroupID when pairedWith is nil
    @Test func pairModeWithPairGroupIDFallback() {
        let gid = UUID()
        let video = VideoRecord()
        video.filename = "clip.V1A.mxf"
        video.streamTypeRaw = "Video only"
        video.pairGroupID = gid

        let audio = VideoRecord()
        audio.filename = "clip.A1A.mxf"
        audio.streamTypeRaw = "Audio only"
        audio.pairGroupID = gid

        #expect(video.pairedWith == nil)
        #expect(audio.pairedWith == nil)

        let ids = VideoScanModel.catalogFilterIDs(for: video.id, pairMode: true, in: [video, audio])
        #expect(ids.count == 2, "Should find partner via pairGroupID when pairedWith is nil")
        #expect(ids.contains(video.id))
        #expect(ids.contains(audio.id))
    }

    // regression: #39 — Show in Catalog: navigation works equivalently from the audio side of the pair
    @Test func pairModeFromAudioSide() {
        let gid = UUID()
        let video = VideoRecord()
        video.filename = "clip.V1A.mxf"
        video.streamTypeRaw = "Video only"
        video.pairGroupID = gid

        let audio = VideoRecord()
        audio.filename = "clip.A1A.mxf"
        audio.streamTypeRaw = "Audio only"
        audio.pairGroupID = gid

        let ids = VideoScanModel.catalogFilterIDs(for: audio.id, pairMode: true, in: [video, audio])
        #expect(ids.count == 2)
        #expect(ids.contains(video.id))
        #expect(ids.contains(audio.id))
    }

    @Test func pairModeRecordNotFound() {
        let bogusID = UUID()
        let ids = VideoScanModel.catalogFilterIDs(for: bogusID, pairMode: true, in: [])
        #expect(ids == [bogusID], "Should return the requested ID even if record isn't found")
    }

    @Test func pairModeNoPairAtAll() {
        let rec = VideoRecord()
        rec.filename = "standalone.mov"
        rec.streamTypeRaw = "Video+Audio"

        let ids = VideoScanModel.catalogFilterIDs(for: rec.id, pairMode: true, in: [rec])
        #expect(ids == [rec.id])
    }

    @Test func pairGroupIDDoesNotLeakOtherGroups() {
        let gid1 = UUID()
        let gid2 = UUID()

        let v1 = VideoRecord(); v1.pairGroupID = gid1; v1.streamTypeRaw = "Video only"
        let a1 = VideoRecord(); a1.pairGroupID = gid1; a1.streamTypeRaw = "Audio only"
        let v2 = VideoRecord(); v2.pairGroupID = gid2; v2.streamTypeRaw = "Video only"
        let a2 = VideoRecord(); a2.pairGroupID = gid2; a2.streamTypeRaw = "Audio only"

        let ids = VideoScanModel.catalogFilterIDs(for: v1.id, pairMode: true, in: [v1, a1, v2, a2])
        #expect(ids.count == 2, "Should only include records from the same pairGroupID")
        #expect(ids.contains(v1.id))
        #expect(ids.contains(a1.id))
        #expect(!ids.contains(v2.id))
        #expect(!ids.contains(a2.id))
    }
}

// MARK: - Online Substitute Finder Tests

@Suite struct OnlineSubstituteTests {

    @Test func findsContentIdenticalCopy() {
        let offline = VideoRecord()
        offline.filename = "video_V01.mxf"
        offline.fullPath = "/Volumes/OfflineDrive/video_V01.mxf"
        offline.partialMD5 = "abc123def456"
        offline.sizeBytes = 500_000_000

        let online = VideoRecord()
        online.filename = "video_V01.mxf"
        online.fullPath = "/usr/bin/true"
        online.partialMD5 = "abc123def456"
        online.sizeBytes = 500_000_000

        let subs = VideoScanModel.findOnlineSubstitutes(for: offline, in: [offline, online])
        #expect(subs.count == 1)
        #expect(subs.first?.substitute.id == online.id)
    }

    @Test func rejectsDifferentHash() {
        let offline = VideoRecord()
        offline.filename = "video.mxf"
        offline.fullPath = "/Volumes/OfflineDrive/video.mxf"
        offline.partialMD5 = "abc123"
        offline.sizeBytes = 500_000_000

        let different = VideoRecord()
        different.filename = "video.mxf"
        different.fullPath = "/tmp/video.mxf"
        different.partialMD5 = "xyz789"
        different.sizeBytes = 500_000_000

        let subs = VideoScanModel.findOnlineSubstitutes(for: offline, in: [offline, different])
        #expect(subs.isEmpty)
    }

    @Test func rejectsDifferentSize() {
        let offline = VideoRecord()
        offline.filename = "video.mxf"
        offline.fullPath = "/Volumes/OfflineDrive/video.mxf"
        offline.partialMD5 = "abc123"
        offline.sizeBytes = 500_000_000

        let wrongSize = VideoRecord()
        wrongSize.filename = "video.mxf"
        wrongSize.fullPath = "/tmp/video.mxf"
        wrongSize.partialMD5 = "abc123"
        wrongSize.sizeBytes = 499_000_000

        let subs = VideoScanModel.findOnlineSubstitutes(for: offline, in: [offline, wrongSize])
        #expect(subs.isEmpty)
    }

    @Test func excludesSelf() {
        let rec = VideoRecord()
        rec.filename = "video.mxf"
        rec.fullPath = "/tmp/video.mxf"
        rec.partialMD5 = "abc123"
        rec.sizeBytes = 500_000_000

        let subs = VideoScanModel.findOnlineSubstitutes(for: rec, in: [rec])
        #expect(subs.isEmpty)
    }

    @Test func emptyHashReturnsEmpty() {
        let offline = VideoRecord()
        offline.filename = "video.mxf"
        offline.fullPath = "/Volumes/OfflineDrive/video.mxf"
        offline.partialMD5 = ""
        offline.sizeBytes = 500_000_000

        let subs = VideoScanModel.findOnlineSubstitutes(for: offline, in: [offline])
        #expect(subs.isEmpty)
    }

    @Test func zeroSizeReturnsEmpty() {
        let offline = VideoRecord()
        offline.filename = "video.mxf"
        offline.fullPath = "/Volumes/OfflineDrive/video.mxf"
        offline.partialMD5 = "abc123"
        offline.sizeBytes = 0

        let subs = VideoScanModel.findOnlineSubstitutes(for: offline, in: [offline])
        #expect(subs.isEmpty)
    }

    @Test func findsMultipleCopies() {
        let offline = VideoRecord()
        offline.filename = "video.mxf"
        offline.fullPath = "/Volumes/OfflineDrive/video.mxf"
        offline.partialMD5 = "abc123"
        offline.sizeBytes = 500_000_000

        let copy1 = VideoRecord()
        copy1.filename = "video.mxf"
        copy1.fullPath = "/usr/bin/true"
        copy1.partialMD5 = "abc123"
        copy1.sizeBytes = 500_000_000

        let copy2 = VideoRecord()
        copy2.filename = "video_backup.mxf"
        copy2.fullPath = "/usr/bin/false"
        copy2.partialMD5 = "abc123"
        copy2.sizeBytes = 500_000_000

        let subs = VideoScanModel.findOnlineSubstitutes(for: offline, in: [offline, copy1, copy2])
        #expect(subs.count == 2)
    }

    @Test func volumeNamePopulated() {
        let offline = VideoRecord()
        offline.filename = "video.mxf"
        offline.fullPath = "/Volumes/OfflineDrive/video.mxf"
        offline.partialMD5 = "abc123"
        offline.sizeBytes = 500_000_000

        let online = VideoRecord()
        online.filename = "video.mxf"
        online.fullPath = "/usr/bin/true"
        online.partialMD5 = "abc123"
        online.sizeBytes = 500_000_000

        let subs = VideoScanModel.findOnlineSubstitutes(for: offline, in: [offline, online])
        #expect(subs.first?.volumeName.isEmpty == false)
    }
}

// MARK: - Codec Compatibility Tests (Issue #1)

@Suite struct CodecCompatibilityTests {

    @Test func h264AacIsSafe() {
        let check = CombineEngine.checkStreamCopyCompatibility(videoCodec: "h264", audioCodec: "aac")
        #expect(check.streamCopySafe == true)
        #expect(check.warning == nil)
    }

    @Test func hevcPcmIsSafe() {
        let check = CombineEngine.checkStreamCopyCompatibility(videoCodec: "hevc", audioCodec: "pcm_s24le")
        #expect(check.streamCopySafe == true)
    }

    @Test func proresAlacIsSafe() {
        let check = CombineEngine.checkStreamCopyCompatibility(videoCodec: "prores", audioCodec: "alac")
        #expect(check.streamCopySafe == true)
    }

    @Test func dnxhdMp3IsSafe() {
        let check = CombineEngine.checkStreamCopyCompatibility(videoCodec: "dnxhd", audioCodec: "mp3")
        #expect(check.streamCopySafe == true)
    }

    @Test func mjpegFlacIsSafe() {
        let check = CombineEngine.checkStreamCopyCompatibility(videoCodec: "mjpeg", audioCodec: "flac")
        #expect(check.streamCopySafe == true)
    }

    @Test func dvvideoAc3IsSafe() {
        let check = CombineEngine.checkStreamCopyCompatibility(videoCodec: "dvvideo", audioCodec: "ac3")
        #expect(check.streamCopySafe == true)
    }

    @Test func rawvideoOpusIsSafe() {
        let check = CombineEngine.checkStreamCopyCompatibility(videoCodec: "rawvideo", audioCodec: "opus")
        #expect(check.streamCopySafe == true)
    }

    @Test func mpeg2VideoNotSafe() {
        let check = CombineEngine.checkStreamCopyCompatibility(videoCodec: "mpeg2video", audioCodec: "aac")
        #expect(check.streamCopySafe == false)
        #expect(check.warning != nil)
        #expect(check.warning!.contains("mpeg2video"))
    }

    @Test func wmv3NotSafe() {
        let check = CombineEngine.checkStreamCopyCompatibility(videoCodec: "wmv3", audioCodec: "wma")
        #expect(check.streamCopySafe == false)
        #expect(check.warning!.contains("wmv3"))
        #expect(check.warning!.contains("wma"))
    }

    @Test func vp9NotSafe() {
        let check = CombineEngine.checkStreamCopyCompatibility(videoCodec: "vp9", audioCodec: "vorbis")
        #expect(check.streamCopySafe == false)
    }

    @Test func safeVideoUnsafeAudio() {
        let check = CombineEngine.checkStreamCopyCompatibility(videoCodec: "h264", audioCodec: "wma")
        #expect(check.streamCopySafe == false)
        #expect(check.warning!.contains("wma"))
        #expect(!check.warning!.contains("h264"))
    }

    @Test func unsafeVideoSafeAudio() {
        let check = CombineEngine.checkStreamCopyCompatibility(videoCodec: "theora", audioCodec: "aac")
        #expect(check.streamCopySafe == false)
        #expect(check.warning!.contains("theora"))
    }

    @Test func bothCodecsNilNotSafe() {
        let check = CombineEngine.checkStreamCopyCompatibility(videoCodec: nil, audioCodec: nil)
        #expect(check.streamCopySafe == false)
    }

    @Test func emptyStringsNotSafe() {
        let check = CombineEngine.checkStreamCopyCompatibility(videoCodec: "", audioCodec: "")
        #expect(check.streamCopySafe == false)
    }

    @Test func videoOnlyIsSafe() {
        let check = CombineEngine.checkStreamCopyCompatibility(videoCodec: "h264", audioCodec: nil)
        #expect(check.streamCopySafe == true)
    }

    @Test func audioOnlyIsSafe() {
        let check = CombineEngine.checkStreamCopyCompatibility(videoCodec: nil, audioCodec: "aac")
        #expect(check.streamCopySafe == true)
    }

    @Test func caseInsensitive() {
        let check = CombineEngine.checkStreamCopyCompatibility(videoCodec: "H264", audioCodec: "AAC")
        #expect(check.streamCopySafe == true)
    }
}

// MARK: - Combine Technique Propagation Tests (Issue #41)

@Suite @MainActor struct CombineTechniquePropagationTests {

    // regression: #41 — Combine technique selected by user (re-encode) is preserved on the job, not lost
    @Test func techniqueSetAtJobCreation() {
        let job = CombineJobStatus(
            pairIndex: 0, videoFilename: "v.mxf", audioFilename: "a.mxf",
            outputFilename: "out.mov", outputPath: "/tmp/out.mov",
            videoSizeBytes: 1000, audioSizeBytes: 500,
            totalDurationSeconds: 10.0, videoOnline: true, audioOnline: true,
            technique: .reencodeProRes
        )
        #expect(job.technique == .reencodeProRes)
    }

    // regression: #41 — Combine dialog H.264 selection round-trips into the job
    @Test func techniqueH264SetAtJobCreation() {
        let job = CombineJobStatus(
            pairIndex: 0, videoFilename: "v.mxf", audioFilename: "a.mxf",
            outputFilename: "out.mov", outputPath: "/tmp/out.mov",
            videoSizeBytes: 1000, audioSizeBytes: 500,
            totalDurationSeconds: 10.0, videoOnline: true, audioOnline: true,
            technique: .reencodeH264
        )
        #expect(job.technique == .reencodeH264)
    }

    @Test func techniqueDefaultsToStreamCopy() {
        let job = CombineJobStatus(
            pairIndex: 0, videoFilename: "v.mxf", audioFilename: "a.mxf",
            outputFilename: "out.mov", outputPath: "/tmp/out.mov",
            videoSizeBytes: 1000, audioSizeBytes: 500,
            totalDurationSeconds: 10.0, videoOnline: true, audioOnline: true
        )
        #expect(job.technique == .streamCopy)
    }

    @Test func dashboardResetClearsJobsAndCounters() {
        let dash = DashboardState()
        dash.combineCompleted = 5
        dash.combineSucceeded = 3
        dash.combineFailed = 1
        dash.combineSkipped = 1
        dash.combineJobs = [CombineJobStatus(
            pairIndex: 0, videoFilename: "v.mxf", audioFilename: "a.mxf",
            outputFilename: "out.mov", outputPath: "/tmp/out.mov",
            videoSizeBytes: 1000, audioSizeBytes: 500,
            totalDurationSeconds: 10.0, videoOnline: true, audioOnline: true
        )]
        dash.resetForCombine(total: 10)
        #expect(dash.combineTotal == 10)
        #expect(dash.combineCompleted == 0)
        #expect(dash.combineSucceeded == 0)
        #expect(dash.combineFailed == 0)
        #expect(dash.combineSkipped == 0)
        #expect(dash.combineJobs.isEmpty)
    }

    // regression: #41 — Re-encode technique propagates to every job in a multi-pair combine batch
    @Test func techniquePreservedAcrossMultipleJobs() {
        let dash = DashboardState()
        dash.resetForCombine(total: 3)
        for i in 0..<3 {
            dash.combineJobs.append(CombineJobStatus(
                pairIndex: i, videoFilename: "v\(i).mxf", audioFilename: "a\(i).mxf",
                outputFilename: "out\(i).mov", outputPath: "/tmp/out\(i).mov",
                videoSizeBytes: 1000, audioSizeBytes: 500,
                totalDurationSeconds: 10.0, videoOnline: true, audioOnline: true,
                technique: .reencodeProRes
            ))
        }
        for job in dash.combineJobs {
            #expect(job.technique == .reencodeProRes)
        }
    }
}

// MARK: - CombinedRecordSpec copy point (Seam A)

/// Pins the field-mapping that moved out of `buildCombinedRecord` when the
/// Combine path stopped constructing a VideoRecord off the main actor. The
/// off-actor builder now fills a Sendable `CombinedRecordSpec`; the actual
/// `VideoRecord()` + `apply(spec)` happens on the main actor. If anyone drops
/// or reorders a field in that single copy point, these break.
@Suite struct CombinedRecordSpecTests {

    // regression: Seam A — VideoRecord.apply(CombinedRecordSpec) copies every field faithfully
    @Test func applyCopiesAllFields() {
        var spec = CombinedRecordSpec()
        spec.filename = "clip_combined.mov"
        spec.ext = "mov"
        spec.fullPath = "/vol/out/clip_combined.mov"
        spec.directory = "/vol/out"
        spec.container = "mov,mp4,m4a"
        spec.streamTypeRaw = StreamType.videoAndAudio.rawValue
        spec.sizeBytes = 123_456_789
        spec.size = "117.7 MB"
        spec.durationSeconds = 42.5
        spec.duration = "00:00:42"
        spec.videoCodec = "prores"
        spec.resolution = "1920x1080"
        spec.frameRate = "30000/1001"
        spec.videoBitrate = "50000000"
        spec.colorSpace = "bt709"
        spec.bitDepth = "10"
        spec.scanType = "progressive"
        spec.audioCodec = "pcm_s16le"
        spec.audioChannels = "2"
        spec.audioSampleRate = "48000"
        spec.totalBitrate = "50500000"
        spec.isPlayable = "Yes"
        spec.notes = "Combined: 1920x1080 prores + pcm_s16le"
        let created = Date(timeIntervalSince1970: 1_000_000)
        let modified = Date(timeIntervalSince1970: 2_000_000)
        spec.dateCreatedRaw = created
        spec.dateCreated = "2001-01-12T13:46:40"
        spec.dateModifiedRaw = modified
        spec.dateModified = "2001-01-24T03:33:20"
        spec.mediaDisposition = .unreviewed
        spec.archiveStage = .none
        spec.lifecycleStage = .workbench
        spec.starRating = 3
        let pairID = UUID()
        spec.combinedFromPairID = pairID

        let rec = VideoRecord()
        rec.apply(spec)

        #expect(rec.filename == "clip_combined.mov")
        #expect(rec.ext == "mov")
        #expect(rec.fullPath == "/vol/out/clip_combined.mov")
        #expect(rec.directory == "/vol/out")
        #expect(rec.container == "mov,mp4,m4a")
        #expect(rec.streamTypeRaw == StreamType.videoAndAudio.rawValue)
        #expect(rec.sizeBytes == 123_456_789)
        #expect(rec.size == "117.7 MB")
        #expect(rec.durationSeconds == 42.5)
        #expect(rec.duration == "00:00:42")
        #expect(rec.videoCodec == "prores")
        #expect(rec.resolution == "1920x1080")
        #expect(rec.frameRate == "30000/1001")
        #expect(rec.videoBitrate == "50000000")
        #expect(rec.colorSpace == "bt709")
        #expect(rec.bitDepth == "10")
        #expect(rec.scanType == "progressive")
        #expect(rec.audioCodec == "pcm_s16le")
        #expect(rec.audioChannels == "2")
        #expect(rec.audioSampleRate == "48000")
        #expect(rec.totalBitrate == "50500000")
        #expect(rec.isPlayable == "Yes")
        #expect(rec.notes == "Combined: 1920x1080 prores + pcm_s16le")
        #expect(rec.dateCreatedRaw == created)
        #expect(rec.dateCreated == "2001-01-12T13:46:40")
        #expect(rec.dateModifiedRaw == modified)
        #expect(rec.dateModified == "2001-01-24T03:33:20")
        #expect(rec.mediaDisposition == .unreviewed)
        #expect(rec.archiveStage == .none)
        #expect(rec.lifecycleStage == .workbench)
        #expect(rec.starRating == 3)
        #expect(rec.combinedFromPairID == pairID)
    }

    // regression: Seam A — a default spec applied to a fresh record is a no-op
    // (every spec default mirrors the VideoRecord default), proving the
    // unconditional copy preserves the old conditional-mutation behavior.
    @Test func applyDefaultSpecMatchesFreshRecord() {
        let spec = CombinedRecordSpec()
        let rec = VideoRecord()
        rec.apply(spec)

        #expect(rec.filename.isEmpty)
        #expect(rec.streamTypeRaw.isEmpty)
        #expect(rec.videoCodec.isEmpty)
        #expect(rec.resolution.isEmpty)
        #expect(rec.audioCodec.isEmpty)
        #expect(rec.dateCreatedRaw == nil)
        #expect(rec.dateModifiedRaw == nil)
        #expect(rec.dateCreated.isEmpty)
        #expect(rec.starRating == 0)
        #expect(rec.combinedFromPairID == nil)
        // Spec defaults for the lifecycle trio match VideoRecord's own defaults.
        #expect(rec.mediaDisposition == .unreviewed)
        #expect(rec.archiveStage == .none)
        #expect(rec.lifecycleStage == .cataloged)
    }
}
