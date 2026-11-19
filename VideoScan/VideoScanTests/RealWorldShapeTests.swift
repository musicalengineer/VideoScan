// RealWorldShapeTests.swift
// The shapes real family media showed the engines, rebuilt synthetically so the
// suite meets them without the corpus (coverage report 2026-11-18: the 234-file
// real corpus reached 27 lines the suite never ran — all of them here).
//
//   1. Unopenable-file wording: the stderr shapes ffprobe gives for files it
//      cannot open (Avid video halves, needs-reformat files, odd containers),
//      and the I/O shapes that must never be blamed on the file.
//   2. Probe JSON with keys missing or null: the fallbacks of
//      VerifyVideoRules.facts and VerifyAudioProbe.shape.
//   3. Frame rate: a header that disagrees with the measured rate, a file that
//      states none, an MPEG-2 elementary stream with no average rate.
//   4. A truncated header (an mp4 cut before its index) and a file that is
//      not media at all, through the real probe (ffmpeg-made, no family content).
//   5. The walker meeting system folders on a real-shaped volume.
//
// Dimensions: LOGIC (1–3, pure), MEDIA (4, real ffprobe on generated files),
// ISOLATION (5, a temp tree). No real media, no paths of real files.

import Testing
import Foundation
@testable import VideoScan

@Suite("Real-world shapes — unopenable wording")
struct RealWorldUnopenableTests {

    @Test("ffprobe's content complaints name the file's trouble and blame the file", arguments: [
        ("[mov,mp4,m4a,3gp,3g2,mj2 @ 0x1] moov atom not found\n/x/a.mp4: Invalid data found when processing input",
         "index is missing"),
        ("/x/a.MXF: Invalid data found when processing input", "not a readable video"),
        ("[mxf @ 0x1] Could not find codec parameters for stream 0 (Video: none): unknown codec", "picture format could not be worked out"),
    ])
    func contentComplaints(stderr: String, phrase: String) {
        #expect(VerifyVideoRules.stderrBlamesContent(stderr))
        #expect(VerifyVideoRules.unopenableDetail(fromProbeStderr: stderr).contains(phrase))
    }

    @Test("a file cut short (end of file) blames the file")
    func endOfFile() {
        let stderr = "[mov,mp4,m4a,3gp,3g2,mj2 @ 0x1] stream 1, offset 0x30: partial file\n/x/a.mov: End of file"
        #expect(VerifyVideoRules.stderrBlamesContent(stderr))
        #expect(!VerifyVideoRules.unopenableDetail(fromProbeStderr: stderr).isEmpty)
    }

    @Test("an I/O shape is never the file's fault, even beside a content complaint", arguments: [
        "/x/a.mov: Input/output error",
        "/x/a.mov: Operation timed out",
        "/x/a.mov: Permission denied",
        "/x/a.mov: No such file or directory",
        "[mov @ 0x1] moov atom not found\n/x/a.mov: Input/output error",
    ])
    func ioIsNotBlamed(stderr: String) {
        #expect(!VerifyVideoRules.stderrBlamesContent(stderr))
    }

    @Test("an unknown complaint keeps its first line; silence says ffprobe could not read it")
    func fallbackWording() {
        #expect(VerifyVideoRules.unopenableDetail(fromProbeStderr: "") == "ffprobe could not read it")
        let odd = VerifyVideoRules.unopenableDetail(fromProbeStderr: "Unsupported codec with id 0 for input stream 0\nsecond line")
        #expect(odd.contains("Unsupported codec"))
        #expect(!odd.contains("second line"))
        #expect(!VerifyVideoRules.stderrBlamesContent("Unsupported codec with id 0 for input stream 0"))
    }
}

@Suite("Real-world shapes — probe JSON with keys missing")
struct RealWorldProbeJSONTests {

    @Test("an empty report: no picture, no sound, every number zero")
    func emptyReport() throws {
        let f = try VerifyVideoRules.facts(fromProbeJSON: Data("{}".utf8))
        #expect(!f.hasVideo)
        #expect(f.containerFormat.isEmpty && f.containerDurationSeconds == 0 && f.fileSizeBytes == 0)
        let s = try VerifyAudioProbe.shape(fromProbeJSON: Data("{}".utf8))
        #expect(s.audioStreams == 0 && s.videoCodec == nil && s.containerFormat.isEmpty)
    }

    @Test("a picture stream that says nothing about itself (an Avid video half's shape)")
    func bareVideoStream() throws {
        let json = #"{"streams":[{"codec_type":"video"}],"format":{"format_name":"mxf","duration":"12.5"}}"#
        let f = try VerifyVideoRules.facts(fromProbeJSON: Data(json.utf8))
        #expect(f.hasVideo)
        #expect(f.videoCodec.isEmpty && f.width == 0 && f.rFrameRate == 0 && f.avgFrameRate == 0)
        #expect(f.frameCount == nil)
        #expect(f.videoDurationSeconds == 12.5, "the picture takes the container's length when its own is missing")
        #expect(f.audioDurationSeconds == 0)
    }

    @Test("null and unparseable values fall back, and a zero frame count is unknown, not zero")
    func nullsAndJunk() throws {
        let json = #"""
        {"streams":[{"codec_type":"video","codec_name":"mpeg2video","r_frame_rate":"0/0","avg_frame_rate":null,
                     "nb_frames":"0","duration":"N/A","bit_rate":"N/A","width":null},
                    {"codec_type":"audio","codec_name":"pcm_s24le","channels":null,"sample_rate":"N/A","duration":null}],
         "format":{"format_name":"mpegvideo","duration":"N/A","size":null}}
        """#
        let f = try VerifyVideoRules.facts(fromProbeJSON: Data(json.utf8))
        #expect(f.hasVideo && f.videoCodec == "mpeg2video")
        #expect(f.frameCount == nil && f.videoDurationSeconds == 0 && f.videoBitRate == 0 && f.width == 0)
        let s = try VerifyAudioProbe.shape(fromProbeJSON: Data(json.utf8))
        #expect(s.audioStreams == 1 && s.audioCodec == "pcm_s24le")
        #expect(s.audioChannels == 0 && s.audioSampleRateHz == nil)
        #expect(s.audioBitDepth == 24, "the depth comes from the codec name when the stream does not say")
        #expect(s.audioDurationSeconds == 0, "the sound's length stays unknown, never guessed")
    }

    @Test("audio only, several sound tracks: the first track is the one described")
    func severalSoundTracks() throws {
        let json = #"""
        {"streams":[{"codec_type":"audio","codec_name":"pcm_s16le","channels":1,"sample_rate":"48000","duration":"60"},
                    {"codec_type":"audio","codec_name":"pcm_s16le","channels":1,"sample_rate":"48000","duration":"60"},
                    {"codec_type":"data","codec_name":"none"}],
         "format":{"format_name":"mxf","duration":"60","size":"5760000"}}
        """#
        let s = try VerifyAudioProbe.shape(fromProbeJSON: Data(json.utf8))
        #expect(s.audioStreams == 2 && s.audioChannels == 1 && s.audioSampleRateHz == 48_000)
        #expect(s.videoCodec == nil && s.videoDurationSeconds == 0)
        #expect(!(try VerifyVideoRules.facts(fromProbeJSON: Data(json.utf8))).hasVideo)
    }
}

@Suite("Real-world shapes — frame rate: header vs measured")
struct RealWorldFrameRateTests {

    private func stream(r: String, avg: String, frames: String? = nil, duration: String = "60") -> String {
        let count = frames.map { #","nb_frames":"\#($0)""# } ?? ""
        return #"""
        {"streams":[{"index":0,"codec_name":"mpeg2video","codec_type":"video","width":720,"height":480,
          "r_frame_rate":"\#(r)","avg_frame_rate":"\#(avg)","duration":"\#(duration)"\#(count),"disposition":{"attached_pic":0}}],
         "format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2","duration":"\#(duration)","size":"60000000"}}
        """#
    }

    @Test("a header that says 30 fps over frames that average 12 is a warning that names both")
    func headerDisagreesWithAverage() throws {
        let check = CheckMediaRules.checkFrameRate(try CheckMediaFixtures.quick(stream(r: "30/1", avg: "12/1")))
        #expect(check.verdict == .warning)
        #expect(check.sentence.contains("30") && check.sentence.contains("12"))
    }

    @Test("a file that states no rate at all is a warning, not a crash or an OK")
    func noRateAnywhere() throws {
        let check = CheckMediaRules.checkFrameRate(try CheckMediaFixtures.quick(stream(r: "0/0", avg: "0/0")))
        #expect(check.verdict == .warning)
        #expect(check.sentence.contains("doesn't say"))
    }

    @Test("an MPEG-2 elementary stream: a declared rate and no average reads as the declared rate")
    func elementaryStreamNoAverage() throws {
        let check = CheckMediaRules.checkFrameRate(try CheckMediaFixtures.quick(stream(r: "30000/1001", avg: "0/0")))
        #expect(check.verdict == .ok)
        #expect(check.sentence.contains("29.97"))
    }

    @Test("header and average within 1.5× of each other agree (DV's 29.97 vs a 30 header)")
    func closeEnoughAgrees() throws {
        let check = CheckMediaRules.checkFrameRate(try CheckMediaFixtures.quick(stream(r: "30/1", avg: "30000/1001", frames: "1798")))
        #expect(check.verdict == .ok)
    }

    @Test("timestamps with fewer than two sampled frames are not run, with a reason")
    func timestampsWithoutEvidence() throws {
        let one = MediaPacketScan.summarize(windows: [[MediaPacketRow(pts: 0, dts: 0, duration: 0.033, size: 1000, pos: 0)]], tail: [])
        let check = CheckMediaRules.checkTimestamps(try CheckMediaFixtures.quick(stream(r: "30/1", avg: "30/1"), packets: one))
        #expect(check.verdict == .notRun(reason: "the frame timings could not be sampled"))
        let none = CheckMediaRules.checkTimestamps(try CheckMediaFixtures.quick(stream(r: "30/1", avg: "30/1")))
        #expect(none.verdict == .notRun(reason: "the frame timings could not be sampled"))
    }
}

@Suite("Real-world shapes — a header that cannot be read (media)", .serialized)
struct RealWorldTruncatedHeaderTests {

    @Test("an mp4 cut before its index is unopenable by its own fault, in words", .timeLimit(.minutes(2)))
    func truncatedMP4() async throws {
        try #require(VerifyVideoTestMedia.toolsAvailable)
        let dir = try VerifyVideoTestMedia.makeScratchDir("rwtrunc")
        defer { try? FileManager.default.removeItem(at: dir) }
        let whole = dir.appendingPathComponent("whole.mp4").path
        try CleanupTestMedia.runFFmpeg(["-f", "lavfi", "-i", "testsrc=duration=3:size=160x120:rate=25",
                                        "-c:v", "mpeg4", "-f", "mp4"], output: whole)
        let data = try Data(contentsOf: URL(fileURLWithPath: whole))
        let cut = dir.appendingPathComponent("cut.mp4").path
        try data.prefix(data.count / 2).write(to: URL(fileURLWithPath: cut))   // the index (moov) is at the end: gone

        guard case .failure(let skip) = await CheckMediaProbe.facts(path: cut) else {
            Issue.record("a file with no index must not yield facts")
            return
        }
        #expect(skip.reason.contains("index is missing"), "\(skip.reason)")
        guard case .unopenable(let detail, let size) = try await CheckMediaProbe.quick(path: cut) else {
            Issue.record("the quick tier must call it unopenable, not throw or measure")
            return
        }
        #expect(detail.contains("index is missing"))
        #expect(size == Int64(data.count / 2))
        guard case .success = await CheckMediaProbe.facts(path: whole) else {
            Issue.record("the whole file must still probe — the fixture is sound")
            return
        }
    }

    @Test("a file that is not media at all is unopenable as not readable video", .timeLimit(.minutes(1)))
    func notMedia() async throws {
        try #require(VerifyVideoTestMedia.toolsAvailable)
        let dir = try VerifyVideoTestMedia.makeScratchDir("rwjunk")
        defer { try? FileManager.default.removeItem(at: dir) }
        let junk = dir.appendingPathComponent("junk.mxf").path
        try Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 13) }).write(to: URL(fileURLWithPath: junk))
        guard case .unopenable(let detail, _) = try await CheckMediaProbe.quick(path: junk) else {
            Issue.record("random bytes must be unopenable")
            return
        }
        #expect(!detail.isEmpty)
    }
}

@Suite("Real-world shapes — the walker meets system folders")
struct RealWorldWalkerTests {

    /// A volume as a real drive looks: Finder's hidden folders (never even listed —
    /// the walker skips hidden entries), the visible system trees a backed-up Mac
    /// leaves at a drive's top (`Library`, `Applications`, `automount`), and media.
    @Test("system folders are skipped and counted; hidden ones are never listed; the media beside them is found")
    func systemFoldersSkipped() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rwwalk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for rel in [".Spotlight-V100/Store-V2/a.mov", ".Trashes/501/b.mov", "automount/c.mov",
                    "Library/Caches/d.mov", "Applications/e.mov", "Tapes/clip.mov", "f.mov"] {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        let options = ScanOptions()                      // the defaults: system trees skipped
        let audit = DiscoveryAuditCollector(scanRoot: root.path, volumeName: "T")
        let found = await FilesystemWalker.walkDirectory(
            root: root.path, videoExtensions: ["mov"], skipDirs: options.skipDirs(),
            skipBundleExtensions: options.skipBundleExtensions(), skipSmallFiles: false, audit: audit)
        #expect(Set(found.map(\.lastPathComponent)) == ["clip.mov", "f.mov"])
        let snapshot = audit.finish(cataloged: 0)
        #expect(snapshot.skippedSystemTreeDirs == 3, "automount, Library, Applications (got \(snapshot.skippedSystemTreeDirs))")
        #expect(snapshot.skippedEditorCacheDirs == 0)
        #expect(snapshot.filesAdmitted == 2)
    }
}
