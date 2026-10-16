// PlaybackAudioMismatchTests.swift
// Bug (Rick 2026-10-16): MP3 sound inside an M4V/MP4 plays SILENTLY in
// the app. ffprobe says stream 0 = mp3 44.1 kHz stereo, the catalog says
// Video+Audio, the sound print found 76k landmarks, Verify Media says ok
// — but `AVURLAsset.loadTracks(withMediaType: .audio)` returns 0 tracks
// (AVFoundation does not read MP3 in an MPEG-4 container), so the in-app
// player played with no sound and said nothing.
//
// Pins:
//   * SOURCE SENSOR (red on the old code): every in-app AVPlayer start in
//     CatalogHelpers consults the mismatch check.
//   * LOGIC: `PlaybackAudioMismatch.words(catalogCodec:avAudioTracks:)` —
//     a notice only when the catalog has a codec AND AVFoundation found
//     no track; names the real codec.
//   * MEDIA MATRIX (real ffmpeg, synthetic `test_*` fixtures): mp3-in-m4v
//     → 0 AV tracks + the notice; aac-in-mp4 and pcm-in-mov → 1 track, no
//     notice; mp3-in-mkv → the existing "not playable" route (never an
//     AVPlayer, so never this notice).

import Testing
import Foundation
import AVFoundation
import VideoScanCore
@testable import VideoScan

// MARK: - Source sensor

@Suite("Playback audio mismatch — source sensor")
struct PlaybackAudioMismatchSourceSensors {

    private static var app: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan", isDirectory: true)
    }

    private static func code(_ rel: String) throws -> [String] {
        try String(contentsOf: app.appendingPathComponent(rel), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    /// The preview player has two local starts (viewer `.local` and the
    /// ordinary path); both must run the audio check after `AVPlayer(url:)`.
    @Test func everyLocalAVPlayerStartChecksTheAudioTracks() throws {
        let lines = try Self.code("Catalog/CatalogHelpers.swift")
        let starts = lines.filter { $0.contains("AVPlayer(url:") }.count
        let checks = lines.filter { $0.contains("checkPlaybackAudio(") }.count
        #expect(starts >= 2, "the preview player's AVPlayer starts moved — update the sensor")
        #expect(checks >= 2,
                "CatalogHelpers starts an AVPlayer \(starts)× but checks the audio tracks \(checks)× — an MP3-in-MP4 file plays silently with no notice")
        #expect(lines.contains { $0.contains("PlaybackAudioMismatch") },
                "the in-app player never consults PlaybackAudioMismatch")
    }

    /// codex P2 (2026-10-16): a late check published without a playback
    /// identity, so the first file's notice could land over the second
    /// file's player. Every `AVPlayer(url:)` start — local or stream —
    /// numbers the player (`playerStarted()`, directly or inside
    /// `checkPlaybackAudio`) within the lines that follow it.
    @Test func everyPlayerStartIsNumbered() throws {
        let lines = try Self.code("Catalog/CatalogHelpers.swift")
        let starts = lines.indices.filter { lines[$0].contains("AVPlayer(url:") }
        try #require(!starts.isEmpty, "the preview player's AVPlayer starts moved — update the sensor")
        for start in starts {
            let window = lines[start..<min(start + 6, lines.count)]
            #expect(window.contains { $0.contains("checkPlaybackAudio(") || $0.contains("playerStarted()") },
                    "an AVPlayer start at line \(start + 1) is not numbered — a late audio check can speak for it")
        }
    }
}

// MARK: - Late checks (codex P2, 2026-10-16)

@Suite("Playback audio mismatch — a late check never speaks for the current player")
@MainActor
struct PlaybackAudioCheckerTests {

    /// Two starts; the FIRST check finishes last. Its words belong to a
    /// player that is gone — dropped, never published over the second
    /// file (which AVFoundation read fine).
    @Test func aCheckThatFinishesAfterTheNextStartIsStale() async {
        let checker = PlaybackAudioChecker()
        let first = checker.playerStarted()
        let second = checker.playerStarted()
        let (gate, open) = AsyncStream<Void>.makeStream()
        let late = Task { @MainActor in
            await checker.outcome(ticket: first, catalogCodec: "mp3", url: URL(fileURLWithPath: "/a.m4v")) { _ in
                for await _ in gate { break }
                return 0
            }
        }
        let current = await checker.outcome(ticket: second, catalogCodec: "aac", url: URL(fileURLWithPath: "/b.mp4")) { _ in 1 }
        #expect(current == .fine)
        open.yield(())
        open.finish()
        #expect(await late.value == .stale, "a check started under an earlier player never publishes")
    }

    @Test func aCurrentCheckReportsItsWordsOrItsFailure() async {
        let checker = PlaybackAudioChecker()
        let ticket = checker.playerStarted()
        let url = URL(fileURLWithPath: "/a.m4v")
        let notice = await checker.outcome(ticket: ticket, catalogCodec: "mp3", url: url) { _ in 0 }
        #expect(notice == .notice(words: PlaybackAudioMismatch.words(catalogCodec: "mp3", avAudioTracks: 0) ?? "", tracks: 0))
        #expect(await checker.outcome(ticket: ticket, catalogCodec: "mp3", url: url) { _ in 2 } == .fine)
        struct Boom: Error {}
        let failed = await checker.outcome(ticket: ticket, catalogCodec: "mp3", url: url) { _ in throw Boom() }
        guard case .unreadable = failed else {
            Issue.record("an unreadable asset is reported, not hidden: \(failed)")
            return
        }
    }
}

// MARK: - Logic (pure words)

@Suite("Playback audio mismatch — words")
struct PlaybackAudioMismatchTests {

    @Test func mp3WithNoAVTrackIsTheNotice() {
        let words = PlaybackAudioMismatch.words(catalogCodec: "mp3", avAudioTracks: 0)
        #expect(words == "This file's MP3 sound can't be played by QuickTime. Open in IINA/VLC, or make an access copy (AAC).")
    }

    @Test func namesTheRealCodecFromTheCatalog() {
        #expect(PlaybackAudioMismatch.words(catalogCodec: "ac3", avAudioTracks: 0)?.contains("AC-3 sound") == true)
        #expect(PlaybackAudioMismatch.words(catalogCodec: " DTS ", avAudioTracks: 0)?.contains("DTS sound") == true)
        #expect(PlaybackAudioMismatch.words(catalogCodec: "pcm_s16le", avAudioTracks: 0)?.contains("PCM (pcm_s16le) sound") == true)
        #expect(PlaybackAudioMismatch.words(catalogCodec: "unknown", avAudioTracks: 0)?.contains("(unknown codec) sound") == true)
    }

    @Test func noNoticeWhenAVFoundationReadsATrack() {
        #expect(PlaybackAudioMismatch.words(catalogCodec: "aac", avAudioTracks: 1) == nil)
        #expect(PlaybackAudioMismatch.words(catalogCodec: "mp3", avAudioTracks: 1) == nil)
        #expect(PlaybackAudioMismatch.words(catalogCodec: "pcm_s16le", avAudioTracks: 2) == nil)
    }

    @Test func noNoticeWhenTheCatalogHasNoSound() {
        #expect(PlaybackAudioMismatch.words(catalogCodec: "", avAudioTracks: 0) == nil)
        #expect(PlaybackAudioMismatch.words(catalogCodec: "   ", avAudioTracks: 0) == nil)
    }

    @MainActor
    @Test func catalogCodecOwesANoticeForVideoAudioWithAnEmptyCodecField() {
        let r = VideoRecord()
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        #expect(PlaybackAudioMismatch.catalogCodec(of: r) == "unknown")
        r.audioCodec = "mp3"
        #expect(PlaybackAudioMismatch.catalogCodec(of: r) == "mp3")
        let silent = VideoRecord()
        silent.streamTypeRaw = StreamType.videoOnly.rawValue
        #expect(PlaybackAudioMismatch.catalogCodec(of: silent).isEmpty, "video-only: nothing to miss")
    }
}

// MARK: - Media matrix (real ffmpeg, synthetic fixtures, 3 s each)

@Suite("Playback audio mismatch — media matrix", .serialized)
struct PlaybackAudioMismatchMediaMatrixTests {

    private func fixture(_ dir: URL, name: String, videoCodec: String, audioCodec: String,
                         rate: String = "48000", outputArgs: [String] = []) throws -> String {
        let out = dir.appendingPathComponent(name).path
        try CleanupTestMedia.runFFmpeg([
            "-f", "lavfi", "-i", "testsrc=duration=3:size=320x240:rate=25",
            "-f", "lavfi", "-i", "aevalsrc=0.5*sin(440*2*PI*t)|0.5*sin(987*2*PI*t):s=\(rate):d=3",
            "-map", "0:v:0", "-map", "1:a:0",
            "-c:v", videoCodec, "-c:a", audioCodec
        ] + outputArgs, output: out)
        return out
    }

    /// THE bug, reproduced: h264 + mp3 in an MPEG-4 container named .m4v
    /// (ffmpeg's ipod muxer refuses mp3, so the mp4 muxer is forced — the
    /// same layout as Rick's file: codec_tag mp4a, codec_name mp3).
    @Test("mp3-in-m4v: AVFoundation reads 0 audio tracks → the notice", .timeLimit(.minutes(2)))
    func mp3InM4v() async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let dir = try CleanupTestMedia.makeScratchDir("mp3m4v")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try fixture(dir, name: "test_mp3_in_m4v.m4v", videoCodec: "libx264", audioCodec: "libmp3lame",
                               rate: "44100", outputArgs: ["-preset", "ultrafast", "-f", "mp4"])
        let tracks = try await PlaybackAudioMismatch.avAudioTrackCount(url: URL(fileURLWithPath: path))
        #expect(tracks == 0, "AVFoundation does not read MP3 in an MPEG-4 container")
        let words = PlaybackAudioMismatch.words(catalogCodec: "mp3", avAudioTracks: tracks)
        #expect(words?.contains("MP3 sound can't be played by QuickTime") == true)
    }

    @Test("aac-in-mp4: 1 track, no notice", .timeLimit(.minutes(2)))
    func aacInMp4() async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let dir = try CleanupTestMedia.makeScratchDir("aacmp4")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try fixture(dir, name: "test_aac_in_mp4.mp4", videoCodec: "libx264", audioCodec: "aac",
                               outputArgs: ["-preset", "ultrafast"])
        let tracks = try await PlaybackAudioMismatch.avAudioTrackCount(url: URL(fileURLWithPath: path))
        #expect(tracks == 1)
        #expect(PlaybackAudioMismatch.words(catalogCodec: "aac", avAudioTracks: tracks) == nil)
    }

    @Test("pcm-in-mov: 1 track, no notice", .timeLimit(.minutes(2)))
    func pcmInMov() async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let dir = try CleanupTestMedia.makeScratchDir("pcmmov")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try fixture(dir, name: "test_pcm_in_mov.mov", videoCodec: "prores", audioCodec: "pcm_s16le")
        let tracks = try await PlaybackAudioMismatch.avAudioTrackCount(url: URL(fileURLWithPath: path))
        #expect(tracks == 1)
        #expect(PlaybackAudioMismatch.words(catalogCodec: "pcm_s16le", avAudioTracks: tracks) == nil)
    }

    /// mkv is the EXISTING "not playable" path: the preview router never
    /// starts an AVPlayer on it (filmstrip instead), and AVFoundation
    /// cannot open it at all — so this notice is never the one shown.
    @Test("mp3-in-mkv: the not-playable route, not this notice", .timeLimit(.minutes(2)))
    func mp3InMkv() async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let dir = try CleanupTestMedia.makeScratchDir("mp3mkv")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try fixture(dir, name: "test_mp3_in_mkv.mkv", videoCodec: "ffv1", audioCodec: "libmp3lame", rate: "44100")
        let route = PreviewFrameRouter.previewRoute(container: "Matroska / WebM", videoCodec: "ffv1", likelyUnanalyzable: false)
        #expect(PreviewPlayAction.forRoute(route) == .filmstrip, "mkv/ffv1 never instantiates an AVPlayer")
        await #expect(throws: (any Error).self, "AVFoundation cannot open Matroska at all") {
            _ = try await PlaybackAudioMismatch.avAudioTrackCount(url: URL(fileURLWithPath: path))
        }
    }
}
