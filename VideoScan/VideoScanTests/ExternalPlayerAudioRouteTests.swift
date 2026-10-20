// ExternalPlayerAudioRouteTests.swift
// GH #332 (P0, Rick 2026-10-17): videos played from the Archive tab had
// no sound. The Archive door has no in-app player — it hands each file to
// QuickTime Player or VLC through `MediaOpener.open`, which chose from a
// codec allow-list alone. "mp3" was on it for every QuickTime container,
// but AVFoundation (QuickTime Player's engine) reads 0 audio tracks for
// MP3 inside MPEG-4 (.mp4/.m4v) — so an archived .m4v opened in QuickTime
// SILENTLY, with no words. (The other 13 container·codec pairs in the
// archive decode with sound in the player the door picks — pinned below.)
//
// Pins (five dimensions; media matrix is the load-bearing one):
//   * LOGIC  — `PlaybackAudioMismatch.checkedChoice`: QuickTime only when
//     AVFoundation reads the catalog's audio track; else VLC with a line,
//     or (no VLC) the system handler with words a person must read.
//     `preferredPlayer` refuses mp3 in mp4/m4v, keeps mp3 in mov.
//   * MEDIA MATRIX — one synthetic `test_` fixture (440 Hz tone) per
//     archive pair; the TRUTH invariant: whenever the door would launch
//     QuickTime, AVFoundation decodes AUDIBLE sound from that file.
//   * ISOLATION — `hasVLC` and the track count are injected; no app is
//     launched, no real path read.
//   * SENSOR — the Archive door goes through MediaOpener.open with a
//     report sink, and MediaOpener.open routes through checkedChoice.
//   * SCALE — n/a: per-click, no `records` iteration.

import Testing
import Foundation
import AVFoundation
import VideoScanCore
@testable import VideoScan

private func record(ext: String, video: String, audio: String,
                    path: String = "/tmp/test_route.bin") -> VideoRecord {
    let rec = VideoRecord()
    rec.ext = ext.uppercased()
    rec.videoCodec = video
    rec.audioCodec = audio
    rec.streamTypeRaw = (audio.isEmpty ? StreamType.videoOnly : StreamType.videoAndAudio).rawValue
    rec.fullPath = path
    rec.filename = (path as NSString).lastPathComponent
    return rec
}

// MARK: - Logic

@Suite("External player audio route — logic")
@MainActor
struct ExternalPlayerAudioRouteLogicTests {

    private let url = URL(fileURLWithPath: "/tmp/test_route.bin")

    @Test func mp3InMpeg4IsNeverQuickTimeButMp3InMovIs() {
        #expect(MediaOpener.preferredPlayer(container: "m4v", videoCodec: "h264", audioCodec: "mp3", hasVLC: true) == .vlc)
        #expect(MediaOpener.preferredPlayer(container: "MP4", videoCodec: "h264", audioCodec: "mp3", hasVLC: true) == .vlc)
        #expect(MediaOpener.preferredPlayer(container: "m4v", videoCodec: "h264", audioCodec: "mp3", hasVLC: false) == .systemDefault)
        #expect(MediaOpener.preferredPlayer(container: "mov", videoCodec: "h264", audioCodec: "mp3", hasVLC: true) == .quickTime)
    }

    /// The runtime check on its own — independent of the allow-list: a
    /// QuickTime-routed file whose sound AVFoundation cannot read goes to
    /// VLC, and the line says why.
    @Test func quickTimeWithNoReadableTrackGoesToVLCWithALine() async {
        let rec = record(ext: "mov", video: "h264", audio: "aac", path: "/tmp/test_silent.mov")
        let check = await PlaybackAudioMismatch.checkedChoice(for: rec, url: url, hasVLC: true) { _ in 0 }
        #expect(check.choice == .vlc)
        #expect(check.note?.needsAttention == false)
        #expect(check.note?.words.contains("QuickTime can't play its AAC sound in MOV") == true)
        #expect(check.note?.words.contains("opened in VLC") == true)
        #expect(check.note?.path == "/tmp/test_silent.mov")
    }

    @Test func noVLCMeansWordsAPersonMustRead() async {
        let rec = record(ext: "mov", video: "h264", audio: "aac")
        let check = await PlaybackAudioMismatch.checkedChoice(for: rec, url: url, hasVLC: false) { _ in 0 }
        #expect(check.choice == .systemDefault)
        #expect(check.note?.needsAttention == true)
        #expect(check.note?.words.contains("plays in QuickTime: no — QuickTime can't play its AAC sound in MOV") == true)
    }

    @Test func anUnreadableAssetIsNotQuickTime() async {
        struct Boom: Error {}
        let rec = record(ext: "mov", video: "prores", audio: "pcm_s24le")
        let check = await PlaybackAudioMismatch.checkedChoice(for: rec, url: url, hasVLC: true) { _ in throw Boom() }
        #expect(check.choice == .vlc)
        #expect(check.note != nil)
    }

    @Test func aReadableTrackStaysQuickTimeQuietly() async {
        let rec = record(ext: "mov", video: "hevc", audio: "aac")
        let check = await PlaybackAudioMismatch.checkedChoice(for: rec, url: url, hasVLC: true) { _ in 1 }
        #expect(check == PlaybackAudioMismatch.RouteCheck(choice: .quickTime, note: nil))
    }

    /// VLC / default routes and video-only files do no I/O at all.
    @Test func nonQuickTimeAndVideoOnlyNeverTouchTheFile() async {
        var calls = 0
        let mkv = record(ext: "mkv", video: "ffv1", audio: "pcm_s32le")
        let a = await PlaybackAudioMismatch.checkedChoice(for: mkv, url: url, hasVLC: true) { _ in calls += 1; return 0 }
        #expect(a == PlaybackAudioMismatch.RouteCheck(choice: .vlc, note: nil))
        let silent = record(ext: "mov", video: "h264", audio: "")
        let b = await PlaybackAudioMismatch.checkedChoice(for: silent, url: url, hasVLC: true) { _ in calls += 1; return 0 }
        #expect(b == PlaybackAudioMismatch.RouteCheck(choice: .quickTime, note: nil))
        #expect(calls == 0)
    }
}

// MARK: - Media matrix (real ffmpeg + real AVFoundation, the archive's pairs)

@Suite("External player audio route — media matrix", .serialized)
@MainActor
struct ExternalPlayerAudioRouteMediaMatrixTests {

    struct Pair: Sendable, CustomTestStringConvertible {
        let name: String, ext: String, video: String, audio: String
        let videoArgs: [String], audioArgs: [String], muxArgs: [String]
        var testDescription: String { "\(ext) · \(video) · \(audio)" }
    }

    private static let dv = ["-c:v", "dvvideo", "-s", "720x480", "-r", "30000/1001", "-pix_fmt", "yuv411p"]
    private static let x264 = ["-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p"]

    /// Every container · audio codec pair in FamilyArchive/30_Video
    /// (GH #332), with the video codec the archive carries. qdm2 (and
    /// svq3) cannot be ENCODED by ffmpeg, so that one file is covered by
    /// the logic suite's unreadable-asset case, not a fixture.
    static let pairs: [Pair] = [
        Pair(name: "mov_hevc_aac", ext: "mov", video: "hevc", audio: "aac",
             videoArgs: ["-c:v", "libx265", "-preset", "ultrafast", "-tag:v", "hvc1", "-pix_fmt", "yuv420p"], audioArgs: ["-c:a", "aac"], muxArgs: []),
        Pair(name: "mov_h264_aac", ext: "mov", video: "h264", audio: "aac", videoArgs: x264, audioArgs: ["-c:a", "aac"], muxArgs: []),
        Pair(name: "mov_prores_pcm_s16be", ext: "mov", video: "prores", audio: "pcm_s16be",
             videoArgs: ["-c:v", "prores_ks"], audioArgs: ["-c:a", "pcm_s16be"], muxArgs: []),
        Pair(name: "mov_dv_pcm_s16be", ext: "mov", video: "dvvideo", audio: "pcm_s16be", videoArgs: dv, audioArgs: ["-c:a", "pcm_s16be"], muxArgs: []),
        Pair(name: "mov_prores_pcm_s24le", ext: "mov", video: "prores", audio: "pcm_s24le",
             videoArgs: ["-c:v", "prores_ks"], audioArgs: ["-c:a", "pcm_s24le"], muxArgs: []),
        Pair(name: "mov_prores_pcm_s16le", ext: "mov", video: "prores", audio: "pcm_s16le",
             videoArgs: ["-c:v", "prores_ks"], audioArgs: ["-c:a", "pcm_s16le"], muxArgs: []),
        Pair(name: "mov_prores_pcm_s32le", ext: "mov", video: "prores", audio: "pcm_s32le",
             videoArgs: ["-c:v", "prores_ks"], audioArgs: ["-c:a", "pcm_s32le"], muxArgs: []),
        Pair(name: "mkv_ffv1_pcm_s32le", ext: "mkv", video: "ffv1", audio: "pcm_s32le", videoArgs: ["-c:v", "ffv1"], audioArgs: ["-c:a", "pcm_s32le"], muxArgs: []),
        Pair(name: "mkv_ffv1_pcm_s16le", ext: "mkv", video: "ffv1", audio: "pcm_s16le", videoArgs: ["-c:v", "ffv1"], audioArgs: ["-c:a", "pcm_s16le"], muxArgs: []),
        Pair(name: "mkv_ffv1_pcm_s16be", ext: "mkv", video: "ffv1", audio: "pcm_s16be", videoArgs: ["-c:v", "ffv1"], audioArgs: ["-c:a", "pcm_s16be"], muxArgs: []),
        Pair(name: "mkv_ffv1_aac", ext: "mkv", video: "ffv1", audio: "aac", videoArgs: ["-c:v", "ffv1"], audioArgs: ["-c:a", "aac"], muxArgs: []),
        Pair(name: "mkv_ffv1_flac", ext: "mkv", video: "ffv1", audio: "flac", videoArgs: ["-c:v", "ffv1"], audioArgs: ["-c:a", "flac"], muxArgs: []),
        Pair(name: "dv_dv_pcm_s16le", ext: "dv", video: "dvvideo", audio: "pcm_s16le", videoArgs: dv, audioArgs: ["-c:a", "pcm_s16le"], muxArgs: []),
        Pair(name: "mp4_h264_aac", ext: "mp4", video: "h264", audio: "aac", videoArgs: x264, audioArgs: ["-c:a", "aac"], muxArgs: []),
        Pair(name: "m4v_h264_aac", ext: "m4v", video: "h264", audio: "aac", videoArgs: x264, audioArgs: ["-c:a", "aac"], muxArgs: []),
        Pair(name: "m4v_h264_mp3", ext: "m4v", video: "h264", audio: "mp3", videoArgs: x264, audioArgs: ["-c:a", "libmp3lame"], muxArgs: ["-f", "mp4"]),
        Pair(name: "mpg_mpeg2_mp2", ext: "mpg", video: "mpeg2video", audio: "mp2",
             videoArgs: ["-c:v", "mpeg2video"], audioArgs: ["-c:a", "mp2"], muxArgs: ["-f", "vob"]),
    ]

    private func build(_ p: Pair, in dir: URL) throws -> String {
        let out = dir.appendingPathComponent("test_\(p.name).\(p.ext)").path
        let isDV = p.videoArgs.contains("dvvideo")
        let size = isDV ? "720x480" : "320x240"
        let rate = isDV ? "30000/1001" : "25"
        try CleanupTestMedia.runFFmpeg([
            "-f", "lavfi", "-i", "testsrc=duration=2:size=\(size):rate=\(rate)",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=2:sample_rate=48000",
            "-map", "0:v:0", "-map", "1:a:0", "-ac", "2", "-shortest"
        ] + p.videoArgs + p.audioArgs + p.muxArgs, output: out)
        return out
    }

    /// RMS in dBFS of the first audio track as AVFoundation DECODES it;
    /// nil when it reads no track or cannot open the file.
    nonisolated static func avDecodedLevel(_ path: String) async -> Double? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        reader.add(out)
        guard reader.startReading() else { return nil }
        var sumSq = 0.0, n = 0
        while let sb = out.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            var len = 0
            var ptr: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &len, dataPointerOut: &ptr) == noErr,
                  let p = ptr else { continue }
            p.withMemoryRebound(to: Float.self, capacity: len / 4) { f in
                for i in 0..<(len / 4) { sumSq += Double(f[i] * f[i]); n += 1 }
            }
        }
        guard n > 0 else { return nil }
        return 20 * log10(sqrt(sumSq / Double(n)) + 1e-12)
    }

    /// THE invariant (GH #332): a door never launches QuickTime on a file
    /// whose sound QuickTime cannot play. Red on the old allow-list
    /// (m4v · mp3 → QuickTime, AVFoundation decodes nothing).
    @Test("QuickTime only when it decodes the sound", .timeLimit(.minutes(3)), arguments: pairs)
    func quickTimeOnlyWhenItDecodesTheSound(_ p: Pair) async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let dir = try CleanupTestMedia.makeScratchDir("route_\(p.name)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try build(p, in: dir)
        let rec = record(ext: p.ext, video: p.video, audio: p.audio, path: path)
        let check = await PlaybackAudioMismatch.checkedChoice(for: rec, url: URL(fileURLWithPath: path), hasVLC: true)
        if check.choice == .quickTime {
            let level = await Self.avDecodedLevel(path)
            #expect((level ?? -999) > -40,
                    "\(p.testDescription) goes to QuickTime but AVFoundation decodes \(level.map { String(format: "%.1f dB", $0) } ?? "no sound")")
            #expect(check.note == nil)
        } else {
            #expect(check.choice == .vlc, "\(p.testDescription): with VLC installed a non-QuickTime file goes to VLC")
        }
    }

    /// Rick's archived .m4v, reproduced: VLC, and a line that names the
    /// codec and the container.
    @Test("m4v · mp3 → VLC with the words", .timeLimit(.minutes(2)))
    func mp3InM4vGoesToVLCWithWords() async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let dir = try CleanupTestMedia.makeScratchDir("route_mp3m4v")
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = try #require(Self.pairs.first { $0.name == "m4v_h264_mp3" })
        let path = try build(p, in: dir)
        #expect(await Self.avDecodedLevel(path) == nil, "AVFoundation does not read MP3 in MPEG-4 — the fixture still reproduces the bug")
        let rec = record(ext: "m4v", video: "h264", audio: "mp3", path: path)
        let noVLC = await PlaybackAudioMismatch.checkedChoice(for: rec, url: URL(fileURLWithPath: path), hasVLC: false)
        #expect(noVLC.choice == .systemDefault)
        // The allow-list already refuses it, so no note is owed from the
        // runtime check; force the QuickTime candidate to prove the words.
        let forced = PlaybackAudioMismatch.routeNote(rec, why: "QuickTime can't play its MP3 sound in M4V", hasVLC: false)
        #expect(forced.needsAttention)
        #expect(forced.words.contains("plays in QuickTime: no"))
    }

    /// Pairs Rick prefers in QuickTime keep going there (no over-routing).
    @Test("QuickTime-friendly pairs stay QuickTime", .timeLimit(.minutes(3)))
    func friendlyPairsStayQuickTime() async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let dir = try CleanupTestMedia.makeScratchDir("route_friendly")
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["mov_h264_aac", "mov_prores_pcm_s24le", "mov_prores_pcm_s16le", "mp4_h264_aac", "m4v_h264_aac"] {
            let p = try #require(Self.pairs.first { $0.name == name })
            let path = try build(p, in: dir)
            let rec = record(ext: p.ext, video: p.video, audio: p.audio, path: path)
            let check = await PlaybackAudioMismatch.checkedChoice(for: rec, url: URL(fileURLWithPath: path), hasVLC: true)
            #expect(check.choice == .quickTime, "\(p.testDescription)")
        }
    }
}

// MARK: - Sensor (source)

@Suite("External player audio route — source sensor")
struct ExternalPlayerAudioRouteSourceSensor {

    private static var app: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan", isDirectory: true)
    }

    private static func code(_ rel: String) throws -> String {
        try String(contentsOf: app.appendingPathComponent(rel), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }
            .joined(separator: "\n")
    }

    /// MediaOpener.open — the one launch door for the Archive tab and
    /// every other "play" click — decides each player through the audio
    /// check, never the bare allow-list.
    @Test func mediaOpenerOpenRoutesThroughTheAudioCheck() throws {
        let src = try Self.code("Catalog/CatalogHelpers.swift")
        let start = try #require(src.range(of: "static func open(_ records: [VideoRecord]"))
        let end = try #require(src.range(of: "private static func deliver(", range: start.upperBound..<src.endIndex))
        let body = String(src[start.upperBound..<end.lowerBound])
        #expect(body.contains("PlaybackAudioMismatch.checkedChoice("), "MediaOpener.open no longer checks the sound before a QuickTime launch (GH #332)")
        #expect(!body.contains("preferredPlayer("), "MediaOpener.open picks a player from the allow-list alone again — MP3-in-M4V opens silently")
    }

    /// The Archive door hands its files to MediaOpener WITH a report sink,
    /// so every re-route is a line in the console / catalog.log.
    @Test func archiveDoorReportsTheAudioRoute() throws {
        let src = try Self.code("Archive/ArchiveView+Doors.swift")
        #expect(src.contains("MediaOpener.open(targets) { note in"), "the Archive door opens files without the audio-route report")
        #expect(src.contains("model.log(\"Archive Open: \\(note.words)\")"))
        #expect(src.contains("playSoundNotice"), "a file no player can sound must be said on screen")
    }
}
