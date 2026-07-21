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

    @Test func probeMP4VideoAudio() async throws {
        let model = VideoScanModel()
        let url = URL(fileURLWithPath: fixturePath("test_video_audio.mp4"))
        let (maybeOutput, stderr) = await model.runFFProbe(url: url)
        let output = try #require(maybeOutput, "ffprobe should parse MP4: \(stderr)")

        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: output, into: rec)
        #expect(rec.streamType == .videoAndAudio)
        #expect(rec.videoCodec == "h264")
        #expect(!rec.resolution.isEmpty)
        #expect(rec.durationSeconds > 4.0 && rec.durationSeconds < 6.0)
        #expect(!rec.audioCodec.isEmpty)
    }

    @Test func probeMOVVideoAudio() async throws {
        let model = VideoScanModel()
        let url = URL(fileURLWithPath: fixturePath("test_video_audio.mov"))
        let (maybeOutput, stderr) = await model.runFFProbe(url: url)
        let output = try #require(maybeOutput, "ffprobe should parse MOV: \(stderr)")

        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: output, into: rec)
        #expect(rec.streamType == .videoAndAudio)
        #expect(rec.videoCodec == "h264")
        #expect(rec.durationSeconds > 4.0)
    }

    @Test func probeMKVVideoAudio() async throws {
        let model = VideoScanModel()
        let url = URL(fileURLWithPath: fixturePath("test_video_audio.mkv"))
        let (maybeOutput, stderr) = await model.runFFProbe(url: url)
        let output = try #require(maybeOutput, "ffprobe should parse MKV: \(stderr)")

        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: output, into: rec)
        #expect(rec.streamType == .videoAndAudio)
        #expect(rec.videoCodec == "h264")
    }

    @Test func probeMXFVideoAudio() async throws {
        let model = VideoScanModel()
        let url = URL(fileURLWithPath: fixturePath("test_video_audio.mxf"))
        let (maybeOutput, stderr) = await model.runFFProbe(url: url)
        let output = try #require(maybeOutput, "ffprobe should parse MXF: \(stderr)")

        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: output, into: rec)
        #expect(rec.streamType == .videoAndAudio)
        #expect(rec.videoCodec == "mpeg2video")
        #expect(rec.durationSeconds > 4.0)
        #expect(!rec.audioCodec.isEmpty)
    }

    // MARK: - Video Only

    @Test func probeMP4VideoOnly() async throws {
        let model = VideoScanModel()
        let url = URL(fileURLWithPath: fixturePath("test_video_only.mp4"))
        let (maybeOutput, stderr) = await model.runFFProbe(url: url)
        let output = try #require(maybeOutput, "ffprobe should parse video-only MP4: \(stderr)")

        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: output, into: rec)
        #expect(rec.streamType == .videoOnly)
        #expect(rec.videoCodec == "h264")
        #expect(rec.audioCodec.isEmpty)
    }

    @Test func probeMXFVideoOnly() async throws {
        let model = VideoScanModel()
        let url = URL(fileURLWithPath: fixturePath("test_video_only.mxf"))
        let (maybeOutput, stderr) = await model.runFFProbe(url: url)
        let output = try #require(maybeOutput, "ffprobe should parse video-only MXF: \(stderr)")

        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: output, into: rec)
        #expect(rec.streamType == .videoOnly)
        #expect(rec.videoCodec == "mpeg2video")
        #expect(rec.audioCodec.isEmpty)
    }

    // MARK: - Audio Only

    @Test func probeM4AAudioOnly() async throws {
        let model = VideoScanModel()
        let url = URL(fileURLWithPath: fixturePath("test_audio_only.m4a"))
        let (maybeOutput, stderr) = await model.runFFProbe(url: url)
        let output = try #require(maybeOutput, "ffprobe should parse M4A: \(stderr)")

        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: output, into: rec)
        #expect(rec.streamType == .audioOnly)
        #expect(rec.audioCodec == "aac")
        #expect(rec.videoCodec.isEmpty)
    }

    @Test func probeWAVAudioOnly() async throws {
        let model = VideoScanModel()
        let url = URL(fileURLWithPath: fixturePath("test_audio_only.wav"))
        let (maybeOutput, stderr) = await model.runFFProbe(url: url)
        let output = try #require(maybeOutput, "ffprobe should parse WAV: \(stderr)")

        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: output, into: rec)
        #expect(rec.streamType == .audioOnly)
        #expect(!rec.audioCodec.isEmpty)
        #expect(rec.videoCodec.isEmpty)
    }

    // MARK: - Attached-pic cover art (real ffmpeg fixture)
    //
    // Media-matrix / escaped-bug boundary for fix/attached-pic-classify.
    // Synthesizes a REAL iTunes-shaped file — an mp3 audio stream plus an
    // embedded cover image flagged disposition.attached_pic — with ffmpeg, then
    // runs it through the live runFFProbe → extractMetadata path. Before the
    // fix this cataloged as .videoAndAudio; it must catalog as .audioOnly.
    // Self-contained: fixture is generated in a temp dir and deleted after.

    @Test func probeMP3WithAttachedCoverArtIsAudioOnly() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("test_attachedpic_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let tonePath  = dir.appendingPathComponent("test_tone.mp3").path
        let coverPath = dir.appendingPathComponent("test_cover.jpg").path
        let outPath   = dir.appendingPathComponent("test_cover_art.mp3").path

        // 1) short sine tone -> mp3
        let mk1 = await ProcessRunner.runCapturingStderr(
            executable: ToolLocator.ffmpegPath,
            arguments: ["-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
                        "-c:a", "libmp3lame", tonePath])
        // 2) a solid-color square still -> jpg (1200x1200, like real album art)
        let mk2 = await ProcessRunner.runCapturingStderr(
            executable: ToolLocator.ffmpegPath,
            arguments: ["-y", "-f", "lavfi", "-i", "color=c=blue:s=1200x1200:d=1",
                        "-frames:v", "1", coverPath])
        // 3) mux audio + cover, flag the image stream as attached_pic
        let mk3 = await ProcessRunner.runCapturingStderr(
            executable: ToolLocator.ffmpegPath,
            arguments: ["-y", "-i", tonePath, "-i", coverPath,
                        "-map", "0:a", "-map", "1", "-c", "copy",
                        "-disposition:v:0", "attached_pic", outPath])

        guard fm.fileExists(atPath: outPath) else {
            // ffmpeg unavailable / lame missing — don't fail the classifier test
            // on a toolchain gap. Surface the stderr for diagnosis.
            Issue.record("Could not synthesize attached_pic fixture: \(mk1.stderr)\n\(mk2.stderr)\n\(mk3.stderr)")
            return
        }

        // Sanity: the muxed file really carries an attached_pic video stream.
        let model = VideoScanModel()
        let url = URL(fileURLWithPath: outPath)
        let (maybeOutput, stderr) = await model.runFFProbe(url: url)
        let output = try #require(maybeOutput, "ffprobe should parse cover-art mp3: \(stderr)")
        let coverStream = output.streams?.first { $0.codec_type == "video" }
        #expect(coverStream?.disposition?.attached_pic == 1,
                "fixture must carry a real attached_pic video stream")

        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: output, into: rec)
        #expect(rec.streamType == .audioOnly,
                "audio file with embedded cover art must catalog as audioOnly, not video")
        #expect(!rec.audioCodec.isEmpty)
        #expect(rec.videoCodec.isEmpty)
    }

    // MARK: - Real Avid MXF files (skipped if not present)

    @Test func probeAvidMXFVideoOnly() async throws {
        let path = fixturePath("video-only-test-1.mxf")
        guard FileManager.default.fileExists(atPath: path) else { return }

        let model = VideoScanModel()
        let url = URL(fileURLWithPath: path)
        let (maybeOutput, stderr) = await model.runFFProbe(url: url)
        let output = try #require(maybeOutput, "ffprobe should parse Avid video MXF: \(stderr)")

        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: output, into: rec)
        #expect(rec.streamType == .videoOnly)
        #expect(!rec.videoCodec.isEmpty)
        #expect(rec.audioCodec.isEmpty)
        #expect(rec.durationSeconds > 0)
    }

    @Test func probeAvidMXFAudioOnly() async throws {
        let path = fixturePath("audio-only-test-1.mxf")
        guard FileManager.default.fileExists(atPath: path) else { return }

        let model = VideoScanModel()
        let url = URL(fileURLWithPath: path)
        let (maybeOutput, stderr) = await model.runFFProbe(url: url)
        let output = try #require(maybeOutput, "ffprobe should parse Avid audio MXF: \(stderr)")

        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: output, into: rec)
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

    // MARK: - attached_pic cover art (fix/attached-pic-classify)
    //
    // ffprobe reports embedded album art (iTunes MP3/M4A) as a "video" stream
    // with disposition.attached_pic == 1 (a single still mjpeg/png, often
    // square like 1200x1200). These must NOT count as real video, or a pure
    // audio file pollutes the video catalog. Proven live on a Nine Inch Nails
    // purchased MP3: mp3 audio + two mjpeg 1200x1200 attached_pic streams.

    @Test func audioWithAttachedCoverArtClassifiedAudioOnly() throws {
        // The escaped-bug shape: mp3 audio + attached_pic mjpeg cover art.
        let probe = try Self.probe("""
        {"format": {"format_name": "mp3", "duration": "217.0"},
         "streams": [
           {"codec_type": "audio", "codec_name": "mp3", "channels": 2, "sample_rate": "44100"},
           {"codec_type": "video", "codec_name": "mjpeg", "width": 1200, "height": 1200,
            "disposition": {"attached_pic": 1}},
           {"codec_type": "video", "codec_name": "mjpeg", "width": 1200, "height": 1200,
            "disposition": {"attached_pic": 1}}
         ]}
        """)
        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: probe, into: rec)
        #expect(rec.streamTypeRaw == StreamType.audioOnly.rawValue)
        #expect(rec.audioCodec == "mp3")
        // No cover-art stream should have leaked into the video fields.
        #expect(rec.videoCodec.isEmpty)
        #expect(rec.resolution.isEmpty)
    }

    @Test func realVideoWithAttachedPicZeroStaysVideoAndAudio() throws {
        // Regular video whose disposition.attached_pic == 0 must still count.
        let probe = try Self.probe("""
        {"format": {"format_name": "mov,mp4,m4a", "duration": "12.5"},
         "streams": [
           {"codec_type": "video", "codec_name": "h264", "width": 1920, "height": 1080,
            "r_frame_rate": "30000/1001", "disposition": {"attached_pic": 0}},
           {"codec_type": "audio", "codec_name": "aac", "channels": 2, "sample_rate": "48000"}
         ]}
        """)
        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: probe, into: rec)
        #expect(rec.streamTypeRaw == StreamType.videoAndAudio.rawValue)
        #expect(rec.videoCodec == "h264")
        #expect(rec.resolution == "1920x1080")
    }

    @Test func coverArtBeforeRealVideoDoesNotShadowRealStream() throws {
        // Mis-order guard: ffprobe can list the attached_pic cover art FIRST,
        // ahead of the genuine video stream. The classifier must skip the cover
        // art and still latch onto the real h264 track — its codec and dims must
        // land in the record, and the 1200x1200 cover dims must NOT leak.
        // (C++ analogy: like asserting the loop picks the right element and its
        // fields, not just that a bool flag flipped.)
        let probe = try Self.probe("""
        {"format": {"format_name": "mov,mp4,m4a", "duration": "12.5"},
         "streams": [
           {"codec_type": "video", "codec_name": "mjpeg", "width": 1200, "height": 1200,
            "disposition": {"attached_pic": 1}},
           {"codec_type": "video", "codec_name": "h264", "width": 1920, "height": 1080,
            "r_frame_rate": "30000/1001", "disposition": {"attached_pic": 0}},
           {"codec_type": "audio", "codec_name": "aac", "channels": 2, "sample_rate": "48000"}
         ]}
        """)
        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: probe, into: rec)
        #expect(rec.streamTypeRaw == StreamType.videoAndAudio.rawValue)
        #expect(rec.videoCodec == "h264")
        #expect(rec.resolution == "1920x1080")
        #expect(rec.audioCodec == "aac")
    }

    @Test func coverArtOnlyNoAudioIsNotPlayableVideo() throws {
        // A file whose ONLY "video" stream is attached_pic cover art and has no
        // audio stream must NOT be classified as having playable video.
        let probe = try Self.probe("""
        {"format": {"format_name": "image2"},
         "streams": [
           {"codec_type": "video", "codec_name": "mjpeg", "width": 1200, "height": 1200,
            "disposition": {"attached_pic": 1}}
         ]}
        """)
        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: probe, into: rec)
        #expect(rec.streamTypeRaw != StreamType.videoOnly.rawValue)
        #expect(rec.streamTypeRaw != StreamType.videoAndAudio.rawValue)
        // No audio + only cover art → the classifier reports no playable streams.
        #expect(rec.streamTypeRaw == StreamType.noStreams.rawValue)
        #expect(rec.videoCodec.isEmpty)
        // Contract pin: the fix flips such a file's "Is Playable" — before the
        // attached_pic guard a lone cover-art still read as playable video.
        // Downstream UI/CSV surface this string, so pin it deliberately: a
        // noStreams record reports "No streams", never "Yes".
        #expect(rec.isPlayable == "No streams")
    }

    @Test func streamWithoutDispositionStillDecodesAsVideo() throws {
        // Defensiveness: a video stream with no "disposition" object at all must
        // still decode and still count as video (attached_pic stays nil != 1).
        let probe = try Self.probe("""
        {"format": null,
         "streams": [{"codec_type": "video", "codec_name": "prores", "width": 1280, "height": 720}]}
        """)
        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: probe, into: rec)
        #expect(rec.streamTypeRaw == StreamType.videoOnly.rawValue)
        #expect(rec.videoCodec == "prores")
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
