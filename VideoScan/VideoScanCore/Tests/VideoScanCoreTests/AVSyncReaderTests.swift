// AVSyncReaderTests.swift — the A/V sync reader's isolation and truth
// dimensions (CLAUDE.md rule 8):
//
//   Isolation — a bogus ffmpeg path, a 0-byte file, a sound-only file, a
//               picture-only file and a truncated file are named outcomes,
//               never crashes; nothing is written beside the input; a cancel
//               returns promptly.
//   Truth     — the sound is read on the FILE's timeline: a sound stream that
//               starts 0.5 s into the container (timestamps, not samples)
//               reads 500 ms late, never "in sync" (the decoder's
//               alignToFileStart; without it ffmpeg's raw PCM starts at the
//               first sound sample and the shift vanishes).
//   Logic     — the exact ffmpeg argv; showinfo lines from this instance only.

import Foundation
import Testing
@testable import VideoScanCore

@Suite(.scratchCleanup)
struct AVSyncReaderTests {

    // MARK: Logic — argv and parsing

    @Test("the picture argv: one video stream, scaled inside the decoder, passthrough timing, stdout")
    func pictureArguments() {
        let args = AVSyncSignalReader.pictureArguments(path: "/x/y.mov")
        #expect(args.last == "-")
        #expect(!args.contains("-y"))
        let joined = args.joined(separator: " ")
        for part in ["-nostdin", "-i /x/y.mov", "-map 0:v:0", "-an -sn -dn",
                     "-vf scale=32:18:flags=area,format=gray,showinfo@vsmotion", "-fps_mode passthrough",
                     "-f rawvideo -"] {
            #expect(joined.contains(part), "\(part)")
        }
    }

    @Test("the sound argv aligns to the file's time zero only when asked; the default is unchanged")
    func soundArguments() {
        let aligned = AudioPCMDecoder.arguments(path: "/x", window: .whole, sampleRate: 8_000, maxSeconds: 60,
                                                alignToFileStart: true).joined(separator: " ")
        #expect(aligned.contains("measure_overall=none,aresample=async=1:first_pts=0"))
        let plain = AudioPCMDecoder.arguments(path: "/x", window: .whole, sampleRate: 8_000, maxSeconds: 60)
        #expect(!plain.joined(separator: " ").contains("aresample"))
    }

    @Test("showinfo frame lines: this instance's prefix only, pts_time parsed, garbage refused")
    func frameTimeParsing() {
        let prefix = "[showinfo@vsmotion @ "
        let line = "[showinfo@vsmotion @ 0x7b] n:  12 pts:  12012 pts_time:0.4004  duration: 1001 fmt:gray"
        #expect(AVSyncSignalReader.frameTime(line: line, prefix: prefix) == 0.4004)
        #expect(AVSyncSignalReader.frameTime(line: "[showinfo@other @ 0x7b] n: 1 pts_time:9.0", prefix: prefix) == nil)
        #expect(AVSyncSignalReader.frameTime(line: "    title: [showinfo@vsmotion @ x] n: 1 pts_time:9", prefix: prefix) == nil)
        #expect(AVSyncSignalReader.frameTime(line: "[showinfo@vsmotion @ 0x7b] config in time_base: 1/30", prefix: prefix) == nil)
        #expect(AVSyncSignalReader.frameTime(line: "[showinfo@vsmotion @ 0x7b] n: 1 pts_time:nan dur", prefix: prefix) == nil)
    }

    @Test("the picture sink cuts a byte stream into frames at any chunking")
    func pictureSinkChunking() {
        let sink = PictureSink(frameBytes: 4)
        // Three frames: [0,0,0,0] [4,4,4,4] [4,4,4,0], delivered in odd chunks.
        let bytes: [UInt8] = [0, 0, 0, 0, 4, 4, 4, 4, 4, 4, 4, 0]
        for chunk in [bytes[0..<3], bytes[3..<9], bytes[9..<12]] { sink.append(Data(chunk)) }
        let (_, changes) = sink.take()
        #expect(changes == [0, 4, 1])
    }

    // MARK: Isolation

    @Test("a missing ffmpeg is a named failure")
    func missingFFmpeg() async {
        let reader = AVSyncSignalReader(ffmpegPath: "/nonexistent/test_ffmpeg")
        await #expect(throws: AVSyncSignalReader.Failure.ffmpegMissing(path: "/nonexistent/test_ffmpeg")) {
            _ = try await reader.read(path: "/dev/null", expectedDurationSeconds: 1)
        }
    }

    @Test("0-byte, sound-only, picture-only and truncated files are named failures; nothing is written beside them")
    func badInputs() async throws {
        let dir = try TestScratch.unique("test_avsync_reader_")
        let empty = dir.appendingPathComponent("empty.mov")
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        let source = try AVSyncFixtures.makeSource(in: dir, seconds: 30, seed: 9)
        let full = try await AVSyncFixtures.encodeOriginal(source, format: .mp4H264, in: dir, name: "full")
        let soundOnly = dir.appendingPathComponent("sound.m4a")
        try await AVSyncFixtures.run(["-nostdin", "-v", "error", "-i", full.path, "-vn", "-c:a", "copy", "-y",
                                      soundOnly.path])
        let pictureOnly = dir.appendingPathComponent("picture.mp4")
        try await AVSyncFixtures.run(["-nostdin", "-v", "error", "-i", full.path, "-an", "-c:v", "copy", "-y",
                                      pictureOnly.path])
        let truncated = dir.appendingPathComponent("truncated.mp4")
        let data = try Data(contentsOf: full)
        try data.prefix(data.count / 3).write(to: truncated)
        let before = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()

        let reader = AVSyncSignalReader()
        do {
            _ = try await reader.read(path: empty.path, expectedDurationSeconds: 30)
            Issue.record("a 0-byte file must fail")
        } catch let failure as AVSyncSignalReader.Failure {
            #expect(!failure.words.isEmpty)
        }
        await #expect(throws: AVSyncSignalReader.Failure.noPicture) {
            _ = try await reader.read(path: soundOnly.path, expectedDurationSeconds: 30)
        }
        await #expect(throws: AVSyncSignalReader.Failure.sound(.noAudioStream)) {
            _ = try await reader.read(path: pictureOnly.path, expectedDurationSeconds: 30)
        }
        // A truncated mp4 (no moov atom) cannot be opened: a named failure.
        do {
            _ = try await reader.read(path: truncated.path, expectedDurationSeconds: 30)
            Issue.record("a truncated mp4 must fail")
        } catch let failure as AVSyncSignalReader.Failure {
            #expect(!failure.words.isEmpty)
        }
        let after = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(before == after, "the reader writes nothing beside its inputs")
    }

    @Test("a cancelled read returns promptly (the ffmpeg children are killed)")
    func cancellation() async throws {
        let dir = try TestScratch.unique("test_avsync_cancel_")
        let source = try AVSyncFixtures.makeSource(in: dir, seconds: 600, seed: 21)
        let long = try await AVSyncFixtures.encodeOriginal(source, format: .mkvFFV1, in: dir, name: "long")
        let clock = ContinuousClock()
        let task = Task { try await AVSyncSignalReader().read(path: long.path, expectedDurationSeconds: 600) }
        try await Task.sleep(for: .milliseconds(300))
        let start = clock.now
        task.cancel()
        let result = await task.result
        let waited = clock.now - start
        #expect(waited < .seconds(8), "cancel took \(waited)")
        if case .success = result { Issue.record("a cancelled read must not return evidence") }
    }

    // MARK: Truth — the file's timeline

    @Test("a sound stream that starts 0.5 s into the file reads 500 ms late, never in sync")
    func soundStartsLateInContainer() async throws {
        let dir = try TestScratch.unique("test_avsync_timeline_")
        let source = try AVSyncFixtures.makeSource(in: dir, seconds: 60, seed: 0x71E)
        let original = try await AVSyncFixtures.encodeOriginal(source, format: .movProRes, in: dir)
        // Same samples, same frames: only the sound stream's start time moves
        // (stream copy with -itsoffset on the sound input).
        let shifted = dir.appendingPathComponent("shifted.mov")
        try await AVSyncFixtures.run(["-nostdin", "-v", "error", "-i", original.path, "-itsoffset", "0.5",
                                      "-i", original.path, "-map", "0:v", "-map", "1:a", "-c", "copy", "-y",
                                      shifted.path])
        let report = try await AVSyncFixtures.measure(original: original, processed: shifted, seconds: 60)
        AVSyncFixtures.note("sound stream starts 0.5 s into the container", expected: "-500 ms", report: report)
        guard case let .offset(shift) = report.verdict else {
            Issue.record("expected 500 ms late: \(AVSyncFixtures.describe(report))")
            return
        }
        #expect(abs(shift + 500) <= 5, "\(AVSyncFixtures.describe(report))")
        #expect(report.sentence == "sound 500 ms late against the picture, the same through the whole file")
    }
}
