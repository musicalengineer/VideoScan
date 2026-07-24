// RebuildAudioFixTests.swift
// LOGIC dimension for the "Rebuild Audio Track" repair verb (GH #128) —
// the PURE decision tables in RebuildAudioFix. The ffmpeg argument
// vector is asserted as EXACT STRINGS (the CombineEngineArgsTests
// convention): the whole point of the rebuild is that the picture is
// never re-encoded, so `-c:v copy` and the absence of any video encoder
// are the contract, not an implementation detail.

import Testing
import Foundation
@testable import VideoScan

@Suite("RebuildAudioFix — pure rules")
struct RebuildAudioFixTests {

    // MARK: ffmpeg argument vector

    @Test func ffmpegArgsExactVector() {
        let args = RebuildAudioFix.ffmpegArgs(input: "/in/tape.mov",
                                              output: "/in/tape_RepairedAudio.mov.vs-partial.mov")
        // Pinned verbatim. (≈ EXPECT_EQ on the whole argv in gtest.)
        #expect(args == [
            "-hide_banner", "-nostdin", "-y",
            "-i", "/in/tape.mov",
            "-map", "0:v?",
            "-map", "0:a:0",
            "-c:v", "copy",
            "-c:a", "pcm_s16le",
            "-map_metadata", "0",
            "-progress", "pipe:2",
            "/in/tape_RepairedAudio.mov.vs-partial.mov",
        ])
    }

    @Test func videoIsStreamCopiedNeverReEncoded() {
        let args = RebuildAudioFix.ffmpegArgs(
            input: "/in/a.avi", output: "/in/out.mov",
            inputArgs: ["-r", "30000/1001"])
        // Every -c:v in the vector must be immediately followed by
        // "copy" — no video encoder may ever appear.
        for (i, a) in args.enumerated() where a == "-c:v" {
            #expect(args[i + 1] == "copy", "-c:v must be copy, got \(args[i + 1])")
        }
        #expect(args.contains("copy"))
        let videoEncoderTokens = ["libx264", "libx265", "h264_videotoolbox",
                                  "hevc_videotoolbox", "prores", "mpeg4",
                                  "-crf", "-preset", "-b:v", "-vf"]
        for token in videoEncoderTokens {
            #expect(!args.contains(token), "video re-encode flag \(token) leaked into the rebuild args")
        }
        // The one audio codec the rebuild ever writes.
        let ca = args.firstIndex(of: "-c:a")
        #expect(ca != nil && args[ca! + 1] == "pcm_s16le")
    }

    @Test func inputArgsPrecedeTheInput() {
        let args = RebuildAudioFix.ffmpegArgs(
            input: "/in/clip.dv", output: "/out.mov",
            inputArgs: ["-r", "30000/1001"])
        let r = args.firstIndex(of: "-r")
        let i = args.firstIndex(of: "-i")
        #expect(r != nil && i != nil && r! < i!,
                "the raw-DV -r override is an INPUT option — it must come before -i")
    }

    // MARK: Raw-DV input override

    @Test func rawDVInputArgsUseProbedRate() {
        #expect(RebuildAudioFix.inputArgs(containerFormat: "dv",
                                          rFrameRate: "30000/1001")
                == ["-r", "30000/1001"])
        #expect(RebuildAudioFix.inputArgs(containerFormat: "dv",
                                          rFrameRate: "25/1")
                == ["-r", "25/1"])
    }

    @Test func degenerateRateProducesNoOverride() {
        // ffprobe reports "0/0" on some broken elementary streams —
        // better to let ffmpeg guess than to force nonsense.
        #expect(RebuildAudioFix.inputArgs(containerFormat: "dv",
                                          rFrameRate: "0/0").isEmpty)
        #expect(RebuildAudioFix.inputArgs(containerFormat: "dv",
                                          rFrameRate: nil).isEmpty)
        #expect(RebuildAudioFix.inputArgs(containerFormat: "dv",
                                          rFrameRate: "garbage").isEmpty)
    }

    @Test func nonDVContainersGetNoOverride() {
        // DV video INSIDE QuickTime/AVI is not raw DV.
        for fmt in ["mov,mp4,m4a,3gp,3g2,mj2", "avi", "matroska,webm", "mxf", ""] {
            #expect(RebuildAudioFix.inputArgs(containerFormat: fmt,
                                              rFrameRate: "30000/1001").isEmpty,
                    "container \(fmt) must not get the raw-DV -r override")
        }
    }

    // MARK: Output naming

    @Test func repairedNameIsAlwaysMovBesideSource() {
        let u = RebuildAudioFix.repairedOutputURL(
            forSourcePath: "/Volumes/T/tape7.mxf", fileExists: { _ in false })
        #expect(u.path == "/Volumes/T/tape7_RepairedAudio.mov",
                "output is ALWAYS .mov (pcm_s16le rides QuickTime), beside the source")
        // Extension swap, not append — no double extensions.
        let u2 = RebuildAudioFix.repairedOutputURL(
            forSourcePath: "/a/clip.old.mov", fileExists: { _ in false })
        #expect(u2.lastPathComponent == "clip.old_RepairedAudio.mov")
    }

    @Test func uniquifyCountersAreFinderStyle() {
        var taken: Set<String> = []
        func next() -> URL {
            RebuildAudioFix.repairedOutputURL(
                forSourcePath: "/t/x.mp4", fileExists: { taken.contains($0) })
        }
        let first = next()
        #expect(first.lastPathComponent == "x_RepairedAudio.mov")
        taken.insert(first.path)
        let second = next()
        #expect(second.lastPathComponent == "x_RepairedAudio 2.mov",
                "counter starts at 2, Finder-style")
        taken.insert(second.path)
        #expect(next().lastPathComponent == "x_RepairedAudio 3.mov")
    }

    // MARK: Post-repair contract

    private func observed(audioStreams: Int = 1,
                          audioCodec: String = "pcm_s16le",
                          videoCodec: String? = "h264") -> AudioVerifyShape {
        var s = AudioVerifyShape()
        s.audioStreams = audioStreams
        s.audioCodec = audioCodec
        s.videoCodec = videoCodec
        return s
    }

    @Test func outputContractAcceptsTheExactPromise() {
        #expect(RebuildAudioFix.outputMismatch(
            observed: observed(), sourceVideoCodec: "h264") == nil)
        // Audio-only source: no video codec to preserve.
        #expect(RebuildAudioFix.outputMismatch(
            observed: observed(videoCodec: nil), sourceVideoCodec: nil) == nil)
        #expect(RebuildAudioFix.outputMismatch(
            observed: observed(), sourceVideoCodec: "") == nil,
            "empty source codec means unknown — no video check possible")
    }

    @Test func outputContractRejectsBreaches() {
        #expect(RebuildAudioFix.outputMismatch(
            observed: observed(audioStreams: 0), sourceVideoCodec: "h264")
            == "output carries 0 audio stream(s), expected exactly 1")
        #expect(RebuildAudioFix.outputMismatch(
            observed: observed(audioStreams: 2), sourceVideoCodec: "h264")
            == "output carries 2 audio stream(s), expected exactly 1")
        #expect(RebuildAudioFix.outputMismatch(
            observed: observed(audioCodec: "aac"), sourceVideoCodec: "h264")
            == "output audio codec is aac, expected pcm_s16le")
        #expect(RebuildAudioFix.outputMismatch(
            observed: observed(audioCodec: ""), sourceVideoCodec: "h264")
            == "output audio codec is unknown, expected pcm_s16le")
        #expect(RebuildAudioFix.outputMismatch(
            observed: observed(videoCodec: "mpeg2video"), sourceVideoCodec: "h264")
            == "video codec changed (h264 → mpeg2video)",
            "a changed video codec means the picture was re-encoded — the one forbidden thing")
        #expect(RebuildAudioFix.outputMismatch(
            observed: observed(videoCodec: nil), sourceVideoCodec: "h264")
            == "video codec changed (h264 → none)")
    }

    // MARK: Truncated-audio guard (QA finding 2)

    private func shortAudioShape(audio: Double, video: Double) -> AudioVerifyShape {
        var s = observed()
        s.audioDurationSeconds = audio
        s.videoDurationSeconds = video
        s.containerDurationSeconds = max(audio, video)
        return s
    }

    @Test func truncatedAudioFailsAgainstThePicture() {
        // The QA F2 shape: video stream-copied full length (6 s),
        // audio decode died at 2 s — container duration (longest
        // track) matches the source, so ONLY this rule catches it.
        let mismatch = RebuildAudioFix.truncatedAudioMismatch(
            observed: shortAudioShape(audio: 2, video: 6), sourceDuration: 6)
        #expect(mismatch != nil)
        #expect(mismatch?.contains("died partway") == true)
    }

    @Test func matchedDurationsPass() {
        #expect(RebuildAudioFix.truncatedAudioMismatch(
            observed: shortAudioShape(audio: 6, video: 6), sourceDuration: 6) == nil)
        // Same >10% boundary as the diagnosis rule: exactly 10% shorter
        // must NOT fire (rules stay consistent across diagnose/repair).
        #expect(RebuildAudioFix.truncatedAudioMismatch(
            observed: shortAudioShape(audio: 90, video: 100), sourceDuration: 100) == nil)
        #expect(RebuildAudioFix.truncatedAudioMismatch(
            observed: shortAudioShape(audio: 89, video: 100), sourceDuration: 100) != nil)
    }

    @Test func unknownAudioDurationNeverFires() {
        // 0 = ffprobe didn't report a stream duration — never
        // manufacture a verification failure from a guess (mov/pcm
        // outputs always report it, so this stays theoretical).
        #expect(RebuildAudioFix.truncatedAudioMismatch(
            observed: shortAudioShape(audio: 0, video: 6), sourceDuration: 6) == nil)
    }

    @Test func audioOnlyOutputComparesAgainstSourceDuration() {
        // No video stream (audio-only source): the picture target falls
        // back to the SOURCE duration, so a half-length rebuilt track
        // still fails.
        var s = observed(videoCodec: nil)
        s.audioDurationSeconds = 3
        s.videoDurationSeconds = 0
        s.containerDurationSeconds = 3
        #expect(RebuildAudioFix.truncatedAudioMismatch(
            observed: s, sourceDuration: 10) != nil)
        s.audioDurationSeconds = 10
        s.containerDurationSeconds = 10
        #expect(RebuildAudioFix.truncatedAudioMismatch(
            observed: s, sourceDuration: 10) == nil)
    }

    // MARK: Free space

    @Test func requiredFreeBytesFormula() {
        // source + worst-case stereo 48k/16 PCM (192 KB/s) + 64 MB cushion.
        #expect(RebuildAudioFix.requiredFreeBytes(sourceBytes: 1_000_000,
                                                  durationSeconds: 10)
                == 1_000_000 + 1_920_000 + (64 << 20))
        // Unknown duration must not go negative.
        #expect(RebuildAudioFix.requiredFreeBytes(sourceBytes: 500,
                                                  durationSeconds: -3)
                == 500 + (64 << 20))
    }

    @Test func derivationKindAndCodecConstants() {
        // Persisted provenance strings — pinned (they land in catalog.json).
        #expect(RebuildAudioFix.derivationKind == "rebuildAudio")
        #expect(RebuildAudioFix.outputAudioCodec == "pcm_s16le")
        #expect(RebuildAudioFix.durationToleranceSeconds == 1.0)
    }
}
