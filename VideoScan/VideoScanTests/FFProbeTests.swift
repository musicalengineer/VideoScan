import Testing
import Foundation
@testable import VideoScan

// MARK: - FFProbe JSON Decoding Tests

struct FFProbeDecodingTests {

    @Test func decodesMinimalJSON() throws {
        let json = """
        {"streams": [], "format": {"format_name": "mov", "duration": "10.5"}}
        """
        let data = json.data(using: .utf8)!
        let output = try JSONDecoder().decode(FFProbeOutput.self, from: data)
        #expect(output.streams?.isEmpty == true)
        #expect(output.format?.format_name == "mov")
        #expect(output.format?.duration == "10.5")
    }

    @Test func decodesStreamFields() throws {
        let json = """
        {"streams": [{"codec_type": "video", "codec_name": "h264", "width": 1920, "height": 1080,
                       "r_frame_rate": "30000/1001", "channels": null}],
         "format": null}
        """
        let data = json.data(using: .utf8)!
        let output = try JSONDecoder().decode(FFProbeOutput.self, from: data)
        let stream = try #require(output.streams?.first)
        #expect(stream.codec_type == "video")
        #expect(stream.codec_name == "h264")
        #expect(stream.width == 1920)
        #expect(stream.height == 1080)
        #expect(stream.r_frame_rate == "30000/1001")
        #expect(stream.channels == nil)
    }

    @Test func handlesNullTopLevel() throws {
        let json = """
        {"streams": null, "format": null}
        """
        let data = json.data(using: .utf8)!
        let output = try JSONDecoder().decode(FFProbeOutput.self, from: data)
        #expect(output.streams == nil)
        #expect(output.format == nil)
    }
}

// MARK: - Media Fixture Tests (ffprobe integration)

@MainActor
struct FFProbeIntegrationTests {

    static let fixturesDir: String = {
        let thisFile = #filePath
        let repoRoot = URL(fileURLWithPath: thisFile)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repoRoot.appendingPathComponent("tests/fixtures/videos").path
    }()

    private func fixturePath(_ name: String) -> String {
        "\(Self.fixturesDir)/\(name)"
    }

    // MARK: - Video + Audio

    @Test func probeMP4VideoAudio() async {
        let model = VideoScanModel()
        let url = URL(fileURLWithPath: fixturePath("test_video_audio.mp4"))
        let (output, stderr) = await model.runFFProbe(url: url)
        #expect(output != nil, "ffprobe should parse MP4: \(stderr)")

        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: output!, into: rec)
        #expect(rec.streamType == .videoAndAudio)
        #expect(rec.videoCodec == "h264")
        #expect(!rec.resolution.isEmpty)
        #expect(rec.durationSeconds > 4.0 && rec.durationSeconds < 6.0)
        #expect(!rec.audioCodec.isEmpty)
    }

    @Test func probeMOVVideoAudio() async {
        let model = VideoScanModel()
        let url = URL(fileURLWithPath: fixturePath("test_video_audio.mov"))
        let (output, stderr) = await model.runFFProbe(url: url)
        #expect(output != nil, "ffprobe should parse MOV: \(stderr)")

        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: output!, into: rec)
        #expect(rec.streamType == .videoAndAudio)
        #expect(rec.videoCodec == "h264")
        #expect(rec.durationSeconds > 4.0)
    }

    @Test func probeMKVVideoAudio() async {
        let model = VideoScanModel()
        let url = URL(fileURLWithPath: fixturePath("test_video_audio.mkv"))
        let (output, stderr) = await model.runFFProbe(url: url)
        #expect(output != nil, "ffprobe should parse MKV: \(stderr)")

        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: output!, into: rec)
        #expect(rec.streamType == .videoAndAudio)
        #expect(rec.videoCodec == "h264")
    }

    @Test func probeMXFVideoAudio() async {
        let model = VideoScanModel()
        let url = URL(fileURLWithPath: fixturePath("test_video_audio.mxf"))
        let (output, stderr) = await model.runFFProbe(url: url)
        #expect(output != nil, "ffprobe should parse MXF: \(stderr)")

        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: output!, into: rec)
        #expect(rec.streamType == .videoAndAudio)
        #expect(rec.videoCodec == "mpeg2video")
        #expect(rec.durationSeconds > 4.0)
        #expect(!rec.audioCodec.isEmpty)
    }

    // MARK: - Video Only

    @Test func probeMP4VideoOnly() async {
        let model = VideoScanModel()
        let url = URL(fileURLWithPath: fixturePath("test_video_only.mp4"))
        let (output, stderr) = await model.runFFProbe(url: url)
        #expect(output != nil, "ffprobe should parse video-only MP4: \(stderr)")

        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: output!, into: rec)
        #expect(rec.streamType == .videoOnly)
        #expect(rec.videoCodec == "h264")
        #expect(rec.audioCodec.isEmpty)
    }

    @Test func probeMXFVideoOnly() async {
        let model = VideoScanModel()
        let url = URL(fileURLWithPath: fixturePath("test_video_only.mxf"))
        let (output, stderr) = await model.runFFProbe(url: url)
        #expect(output != nil, "ffprobe should parse video-only MXF: \(stderr)")

        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: output!, into: rec)
        #expect(rec.streamType == .videoOnly)
        #expect(rec.videoCodec == "mpeg2video")
        #expect(rec.audioCodec.isEmpty)
    }

    // MARK: - Audio Only

    @Test func probeM4AAudioOnly() async {
        let model = VideoScanModel()
        let url = URL(fileURLWithPath: fixturePath("test_audio_only.m4a"))
        let (output, stderr) = await model.runFFProbe(url: url)
        #expect(output != nil, "ffprobe should parse M4A: \(stderr)")

        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: output!, into: rec)
        #expect(rec.streamType == .audioOnly)
        #expect(rec.audioCodec == "aac")
        #expect(rec.videoCodec.isEmpty)
    }

    @Test func probeWAVAudioOnly() async {
        let model = VideoScanModel()
        let url = URL(fileURLWithPath: fixturePath("test_audio_only.wav"))
        let (output, stderr) = await model.runFFProbe(url: url)
        #expect(output != nil, "ffprobe should parse WAV: \(stderr)")

        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: output!, into: rec)
        #expect(rec.streamType == .audioOnly)
        #expect(!rec.audioCodec.isEmpty)
        #expect(rec.videoCodec.isEmpty)
    }

    // MARK: - Real Avid MXF files (skipped if not present)

    @Test func probeAvidMXFVideoOnly() async {
        let path = fixturePath("video-only-test-1.mxf")
        guard FileManager.default.fileExists(atPath: path) else { return }

        let model = VideoScanModel()
        let url = URL(fileURLWithPath: path)
        let (output, stderr) = await model.runFFProbe(url: url)
        #expect(output != nil, "ffprobe should parse Avid video MXF: \(stderr)")

        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: output!, into: rec)
        #expect(rec.streamType == .videoOnly)
        #expect(!rec.videoCodec.isEmpty)
        #expect(rec.audioCodec.isEmpty)
        #expect(rec.durationSeconds > 0)
    }

    @Test func probeAvidMXFAudioOnly() async {
        let path = fixturePath("audio-only-test-1.mxf")
        guard FileManager.default.fileExists(atPath: path) else { return }

        let model = VideoScanModel()
        let url = URL(fileURLWithPath: path)
        let (output, stderr) = await model.runFFProbe(url: url)
        #expect(output != nil, "ffprobe should parse Avid audio MXF: \(stderr)")

        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: output!, into: rec)
        #expect(rec.streamType == .audioOnly)
        #expect(!rec.audioCodec.isEmpty)
        #expect(rec.videoCodec.isEmpty)
    }

    // MARK: - Full probeFile pipeline

    @Test func probeFilePipelineMP4() async {
        let model = VideoScanModel()
        let url = URL(fileURLWithPath: fixturePath("test_video_audio.mp4"))
        let rec = await model.probeFile(url: url)
        #expect(rec.filename == "test_video_audio.mp4")
        #expect(rec.ext == "MP4")
        #expect(rec.streamType == .videoAndAudio)
        #expect(rec.fullPath == url.path)
        #expect(rec.sizeBytes > 0)
        #expect(rec.durationSeconds > 4.0)
        #expect(!rec.partialMD5.isEmpty)
    }

    @Test func probeFilePipelineMXF() async {
        let model = VideoScanModel()
        let url = URL(fileURLWithPath: fixturePath("test_video_audio.mxf"))
        let rec = await model.probeFile(url: url)
        #expect(rec.filename == "test_video_audio.mxf")
        #expect(rec.ext == "MXF")
        #expect(rec.streamType == .videoAndAudio)
        #expect(rec.sizeBytes > 0)
    }

    @Test func probeFileNonexistent() async {
        let model = VideoScanModel()
        let url = URL(fileURLWithPath: "/nonexistent/file_\(UUID()).mp4")
        let rec = await model.probeFile(url: url)
        #expect(rec.streamType == .ffprobeFailed || rec.streamType == .noStreams)
    }
}

// MARK: - ScanEngine.extractMetadata Tests

struct ExtractMetadataTests {

    private static func probe(_ json: String) throws -> FFProbeOutput {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(FFProbeOutput.self, from: data)
    }

    @Test func videoAndAudioClassifiedCorrectly() throws {
        let probe = try Self.probe("""
        {
          "format": {"format_name": "mov,mp4,m4a", "duration": "12.5", "bit_rate": "5000000"},
          "streams": [
            {"codec_type": "video", "codec_name": "h264", "width": 1920, "height": 1080,
             "r_frame_rate": "30000/1001"},
            {"codec_type": "audio", "codec_name": "aac", "channels": 2, "sample_rate": "48000"}
          ]
        }
        """)
        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: probe, into: rec)
        #expect(rec.streamTypeRaw == StreamType.videoAndAudio.rawValue)
        #expect(rec.videoCodec == "h264")
        #expect(rec.audioCodec == "aac")
        #expect(rec.resolution == "1920x1080")
        #expect(rec.audioChannels == "2")
        #expect(rec.audioSampleRate == "48000 Hz")
        #expect(rec.durationSeconds == 12.5)
        #expect(rec.totalBitrate == "5000 kbps")
        #expect(rec.isPlayable == "Yes")
    }

    @Test func videoOnlyClassifiedCorrectly() throws {
        let probe = try Self.probe("""
        {"format": null,
         "streams": [{"codec_type": "video", "codec_name": "prores", "width": 1280, "height": 720,
                      "r_frame_rate": "24/1"}]}
        """)
        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: probe, into: rec)
        #expect(rec.streamTypeRaw == StreamType.videoOnly.rawValue)
        #expect(rec.videoCodec == "prores")
        #expect(rec.audioCodec.isEmpty)
        #expect(rec.isPlayable == "Yes")
    }

    @Test func audioOnlyClassifiedCorrectly() throws {
        let probe = try Self.probe("""
        {"format": null,
         "streams": [{"codec_type": "audio", "codec_name": "pcm_s24le", "channels": 2, "sample_rate": "48000"}]}
        """)
        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: probe, into: rec)
        #expect(rec.streamTypeRaw == StreamType.audioOnly.rawValue)
        #expect(rec.audioCodec == "pcm_s24le")
        #expect(rec.videoCodec.isEmpty)
        #expect(rec.isPlayable == "Yes")
    }

    @Test func noStreamsReportsNoStreams() throws {
        let probe = try Self.probe("""
        {"format": {"format_name": "unknown"}, "streams": []}
        """)
        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: probe, into: rec)
        #expect(rec.streamTypeRaw == StreamType.noStreams.rawValue)
        #expect(rec.isPlayable == "No streams")
    }

    @Test func missingResolutionLeavesFieldEmpty() throws {
        let probe = try Self.probe("""
        {"format": null,
         "streams": [{"codec_type": "video", "codec_name": "h264", "width": 0, "height": 0,
                      "r_frame_rate": "30/1"}]}
        """)
        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: probe, into: rec)
        #expect(rec.resolution.isEmpty)
    }

    @Test func timecodeFromFormatTags() throws {
        let probe = try Self.probe("""
        {"format": {"format_name": "mov", "tags": {"timecode": "01:00:00:00"}},
         "streams": [{"codec_type": "video", "codec_name": "h264"}]}
        """)
        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: probe, into: rec)
        #expect(rec.timecode == "01:00:00:00")
    }

    @Test func timecodeFromStreamTagsWhenFormatLacksIt() throws {
        let probe = try Self.probe("""
        {"format": {"format_name": "mov"},
         "streams": [{"codec_type": "video", "codec_name": "h264",
                      "tags": {"timecode": "02:00:00:00"}}]}
        """)
        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: probe, into: rec)
        #expect(rec.timecode == "02:00:00:00")
    }

    @Test func tapeNameFromReelNameTag() throws {
        let probe = try Self.probe("""
        {"format": {"format_name": "mxf", "tags": {"reel_name": "REEL007"}},
         "streams": [{"codec_type": "video", "codec_name": "dnxhd"}]}
        """)
        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: probe, into: rec)
        #expect(rec.tapeName == "REEL007")
    }

    @Test func tapeNameFromAppleReelNameTag() throws {
        let probe = try Self.probe("""
        {"format": {"format_name": "mov",
                    "tags": {"com.apple.quicktime.reelname": "APPLE_REEL"}},
         "streams": [{"codec_type": "video", "codec_name": "h264"}]}
        """)
        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: probe, into: rec)
        #expect(rec.tapeName == "APPLE_REEL")
    }

    @Test func frameRateParsedFromRational() throws {
        let probe = try Self.probe("""
        {"format": null,
         "streams": [{"codec_type": "video", "codec_name": "h264",
                      "r_frame_rate": "30000/1001"}]}
        """)
        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: probe, into: rec)
        #expect(rec.frameRate == "29.97")
    }

    @Test func falsybitRateDoesNotCrash() throws {
        let probe = try Self.probe("""
        {"format": {"format_name": "mov", "bit_rate": "N/A"},
         "streams": [{"codec_type": "video", "codec_name": "h264", "bit_rate": "N/A"}]}
        """)
        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: probe, into: rec)
        #expect(rec.totalBitrate.isEmpty)
        #expect(rec.videoBitrate.isEmpty)
    }

    @Test func multipleVideoStreamsUseFirstOnly() throws {
        let probe = try Self.probe("""
        {"format": null,
         "streams": [
           {"codec_type": "video", "codec_name": "h264", "width": 1920, "height": 1080},
           {"codec_type": "video", "codec_name": "prores", "width": 3840, "height": 2160}
         ]}
        """)
        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: probe, into: rec)
        #expect(rec.videoCodec == "h264")
        #expect(rec.resolution == "1920x1080")
    }
}

// MARK: - ScanEngine.humanReadableDiagnosis Tests

struct HumanReadableDiagnosisTests {

    @Test func moovAtomNotFoundReportsDamaged() {
        let d = ScanEngine.humanReadableDiagnosis(stderr: "moov atom not found")
        #expect(d.label == "Damaged file")
        #expect(d.detail.contains("moov atom not found"))
    }

    @Test func moovAtomMatchesCaseInsensitively() {
        let d = ScanEngine.humanReadableDiagnosis(stderr: "ERROR: MOOV ATOM NOT FOUND in stream")
        #expect(d.label == "Damaged file")
    }

    @Test func invalidDataReportsDamaged() {
        let d = ScanEngine.humanReadableDiagnosis(stderr: "Invalid data found when processing input")
        #expect(d.label == "Damaged file")
        #expect(d.detail.contains("invalid data found"))
    }

    @Test func endOfFileReportsTruncated() {
        let d = ScanEngine.humanReadableDiagnosis(stderr: "unexpected end of file")
        #expect(d.label == "Truncated file")
        #expect(d.detail.contains("unexpected end of file"))
    }

    @Test func truncatedKeywordReportsTruncated() {
        let d = ScanEngine.humanReadableDiagnosis(stderr: "stream is truncated at byte 12345")
        #expect(d.label == "Truncated file")
    }

    @Test func permissionDeniedReportsAccess() {
        let d = ScanEngine.humanReadableDiagnosis(stderr: "Permission denied opening file")
        #expect(d.label == "Access denied")
    }

    @Test func timeoutReportsNetworkTimeout() {
        let d = ScanEngine.humanReadableDiagnosis(stderr: "read: Operation timed out")
        #expect(d.label == "Network timeout")
    }

    @Test func noSuchFileReportsFileNotFound() {
        let d = ScanEngine.humanReadableDiagnosis(stderr: "open: No such file or directory")
        #expect(d.label == "File not found")
    }

    @Test func emptyStderrReportsUnreadableWithoutDetail() {
        let d = ScanEngine.humanReadableDiagnosis(stderr: "")
        #expect(d.label == "Unreadable file")
        #expect(d.detail.contains("no additional details"))
    }

    @Test func unknownStderrFallsBackToRawStderr() {
        let d = ScanEngine.humanReadableDiagnosis(stderr: "some unrecognized ffmpeg warning")
        #expect(d.label == "Unreadable file")
        #expect(d.detail.contains("some unrecognized ffmpeg warning"))
    }

    @Test func priorityMoovBeforeTruncated() {
        let d = ScanEngine.humanReadableDiagnosis(stderr: "moov atom not found; stream appears truncated")
        #expect(d.label == "Damaged file")
    }
}
