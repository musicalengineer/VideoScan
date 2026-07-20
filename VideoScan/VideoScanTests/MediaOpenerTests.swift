// MediaOpenerTests.swift
// Media-matrix coverage for MediaOpener.preferredPlayer — the PURE player
// decision function behind the unified double-click (smart QuickTime/VLC
// launch). No app launching here: this exercises the decision only.
//
// Policy under test (see MediaOpener in CatalogHelpers.swift):
//   QuickTime is returned ONLY on a positive three-way match —
//   container ∈ {mov,mp4,m4v,qt}, a known-good video codec, AND an audio
//   codec QuickTime plays with sound (empty = no audio track, also fine).
//   Anything else → VLC when installed, else the system default handler.

import Testing
import Foundation
@testable import VideoScan

@Suite("MediaOpener.preferredPlayer")
struct MediaOpenerPreferredPlayerTests {

    // MARK: Media matrix — QuickTime-friendly

    @Test("mov / h264 / aac → QuickTime")
    func movH264AAC() {
        #expect(MediaOpener.preferredPlayer(
            container: "mov", videoCodec: "h264", audioCodec: "aac",
            hasVLC: true) == .quickTime)
    }

    @Test("mov / prores / pcm_s16le → QuickTime")
    func movProResPCM() {
        #expect(MediaOpener.preferredPlayer(
            container: "mov", videoCodec: "prores", audioCodec: "pcm_s16le",
            hasVLC: true) == .quickTime)
    }

    @Test("mp4 / hevc / aac → QuickTime")
    func mp4HEVCAAC() {
        #expect(MediaOpener.preferredPlayer(
            container: "mp4", videoCodec: "hevc", audioCodec: "aac",
            hasVLC: true) == .quickTime)
    }

    @Test("Video-only (empty audio codec) still QuickTime")
    func videoOnlyQuickTime() {
        #expect(MediaOpener.preferredPlayer(
            container: "mov", videoCodec: "h264", audioCodec: "",
            hasVLC: true) == .quickTime)
    }

    // MARK: Media matrix — must route to VLC

    @Test("mp4 / h264 / ac3 → VLC (QT would open silent)")
    func mp4H264AC3() {
        #expect(MediaOpener.preferredPlayer(
            container: "mp4", videoCodec: "h264", audioCodec: "ac3",
            hasVLC: true) == .vlc)
    }

    @Test("mkv / ffv1 / pcm → VLC")
    func mkvFFV1PCM() {
        #expect(MediaOpener.preferredPlayer(
            container: "mkv", videoCodec: "ffv1", audioCodec: "pcm",
            hasVLC: true) == .vlc)
    }

    @Test("mxf / mpeg2video / pcm → VLC")
    func mxfMPEG2PCM() {
        #expect(MediaOpener.preferredPlayer(
            container: "mxf", videoCodec: "mpeg2video", audioCodec: "pcm",
            hasVLC: true) == .vlc)
    }

    @Test("avi / dvvideo / pcm → VLC")
    func aviDVPCM() {
        #expect(MediaOpener.preferredPlayer(
            container: "avi", videoCodec: "dvvideo", audioCodec: "pcm",
            hasVLC: true) == .vlc)
    }

    @Test("Off-list audio (opus) in a QT container → VLC")
    func mp4H264Opus() {
        #expect(MediaOpener.preferredPlayer(
            container: "mp4", videoCodec: "h264", audioCodec: "opus",
            hasVLC: true) == .vlc)
    }

    // MARK: Uncataloged / unknown fields → VLC (safe default)

    @Test("Empty container and codecs → VLC")
    func allEmpty() {
        #expect(MediaOpener.preferredPlayer(
            container: "", videoCodec: "", audioCodec: "",
            hasVLC: true) == .vlc)
    }

    @Test("Unknown container with otherwise-good codecs → VLC")
    func unknownContainer() {
        #expect(MediaOpener.preferredPlayer(
            container: "webm", videoCodec: "h264", audioCodec: "aac",
            hasVLC: true) == .vlc)
    }

    @Test("Empty video codec (uncataloged) → VLC")
    func emptyVideoCodec() {
        #expect(MediaOpener.preferredPlayer(
            container: "mov", videoCodec: "", audioCodec: "aac",
            hasVLC: true) == .vlc)
    }

    // MARK: VLC absent → system default

    @Test("Non-QT file with hasVLC=false → systemDefault")
    func nonQTNoVLCFallsToSystemDefault() {
        #expect(MediaOpener.preferredPlayer(
            container: "mkv", videoCodec: "ffv1", audioCodec: "pcm",
            hasVLC: false) == .systemDefault)
    }

    @Test("QT-friendly file is still QuickTime even when hasVLC=false")
    func qtFriendlyIgnoresVLCAbsence() {
        #expect(MediaOpener.preferredPlayer(
            container: "mov", videoCodec: "h264", audioCodec: "aac",
            hasVLC: false) == .quickTime)
    }

    // MARK: Normalization (case + whitespace)

    @Test("Uppercase and padded inputs normalize to QuickTime")
    func normalizationQuickTime() {
        #expect(MediaOpener.preferredPlayer(
            container: "  MOV ", videoCodec: "H264", audioCodec: " AAC ",
            hasVLC: true) == .quickTime)
    }

    // MARK: VideoRecord convenience overload

    @Test("VideoRecord overload reads the record's codec fields")
    func recordOverload() {
        let qtRec = VideoRecord()
        qtRec.container = "mp4"
        qtRec.videoCodec = "hevc"
        qtRec.audioCodec = "aac"
        #expect(MediaOpener.preferredPlayer(for: qtRec, hasVLC: true) == .quickTime)

        let vlcRec = VideoRecord()
        vlcRec.container = "mp4"
        vlcRec.videoCodec = "h264"
        vlcRec.audioCodec = "dts"
        #expect(MediaOpener.preferredPlayer(for: vlcRec, hasVLC: true) == .vlc)

        // Fresh record with only a path (the PersonFinder stub case) → VLC.
        let stub = VideoRecord()
        stub.fullPath = "/Volumes/Fake/orphan.mxf"
        #expect(MediaOpener.preferredPlayer(for: stub, hasVLC: true) == .vlc)
    }
}
