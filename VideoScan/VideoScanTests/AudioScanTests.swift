// AudioScanTests.swift
// Regression for the audio discovery gap: standalone audio files (wav, aif,
// mp3, …) were never cataloged because discovery only admitted video
// extensions. The "Scan For Audio Files" option admits them.
//
// Red/green: audioScanDiscoversWav FAILS before the fix (scanAudioFiles not
// honored) and PASSES after.

import Testing
import Foundation
@testable import VideoScan

@Suite("Audio file discovery — Scan For Audio Files")
struct AudioScanTests {

    private let videoExtensions: Set<String> = ["mov", "mp4", "mxf"]
    private let audioExtensions: Set<String> = ["wav", "aif", "mp3"]

    /// Temp dir: a video file, two audio files, a non-media file.
    private func makeFixture() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vs_audio_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bytes = Data(repeating: 0, count: 16)
        try bytes.write(to: dir.appendingPathComponent("clip.mov"))
        try bytes.write(to: dir.appendingPathComponent("song.wav"))
        try bytes.write(to: dir.appendingPathComponent("voice.aif"))
        try bytes.write(to: dir.appendingPathComponent("notes.txt"))
        return dir
    }

    @Test("Default scan skips audio files (current behavior, preserved)")
    func defaultScanSkipsAudio() async throws {
        let dir = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let found = await FilesystemWalker.walkDirectory(
            root: dir.path, videoExtensions: videoExtensions,
            skipDirs: [], skipBundleExtensions: [], skipSmallFiles: false,
            probeExtensionless: false, audioExtensions: audioExtensions,
            scanAudioFiles: false
        )
        let names = Set(found.map { $0.lastPathComponent })
        #expect(names.contains("clip.mov"))
        #expect(!names.contains("song.wav"))
        #expect(!names.contains("voice.aif"))
    }

    @Test("Audio scan discovers audio files alongside video")
    func audioScanDiscoversAudio() async throws {
        let dir = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let found = await FilesystemWalker.walkDirectory(
            root: dir.path, videoExtensions: videoExtensions,
            skipDirs: [], skipBundleExtensions: [], skipSmallFiles: false,
            probeExtensionless: false, audioExtensions: audioExtensions,
            scanAudioFiles: true
        )
        let names = Set(found.map { $0.lastPathComponent })
        #expect(names.contains("song.wav"), "audio files must be discovered when scanAudioFiles is on")
        #expect(names.contains("voice.aif"))
        #expect(names.contains("clip.mov"), "additive: video is still scanned")
        #expect(!names.contains("notes.txt"))
    }

    @Test("Audio + extensionless toggles combine additively")
    func audioAndExtensionlessCombine() async throws {
        let dir = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(repeating: 0, count: 16).write(to: dir.appendingPathComponent("t2-v"))
        let found = await FilesystemWalker.walkDirectory(
            root: dir.path, videoExtensions: videoExtensions,
            skipDirs: [], skipBundleExtensions: [], skipSmallFiles: false,
            probeExtensionless: true, audioExtensions: audioExtensions,
            scanAudioFiles: true
        )
        let names = Set(found.map { $0.lastPathComponent })
        #expect(names.contains("clip.mov"))   // video
        #expect(names.contains("song.wav"))   // audio
        #expect(names.contains("t2-v"))       // extensionless
        #expect(!names.contains("notes.txt"))
    }
}
