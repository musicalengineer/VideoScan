// MKVDossierPipelineTests.swift
// Regression tests for the 2026-07-05 "Analyze fails on mkv masters" bug.
//
// Rick's digitized-tape masters are FFV1 + PCM in Matroska — the correct
// lossless archival choice, and a container/codec pair AVFoundation cannot
// open AT ALL. Right-click Analyze failed in ~1 s on every new capture:
//   [18:34:45] Dossier: done — 0 processed, 0 skipped, 1 failed in 0.9s
// Two AVFoundation gatekeepers were the whole problem — the tools behind
// them (ffmpeg frame ripping, mlx-whisper's internal ffmpeg decode) handle
// these files perfectly, proven by hand on DanBurnsWyoming1995.mkv:
//   1. extractFramesForCaptioning: AVAssetImageGenerator can't open the
//      asset → CaptionRunnerError.videoUnreadable → whole file "failed".
//   2. audioTrackIsPresent: AVURLAsset.loadTracks sees no tracks in mkv
//      → .audioUnreadable → transcript never attempted.
//
// RED (pre-fix): both mkv tests below fail — videoUnreadable /
// audioUnreadable against the FFV1+PCM fixture. GREEN: both fall back to
// ffmpeg/ffprobe when AVFoundation can't read the container. The mp4
// sanity tests pin the existing AVFoundation fast path on both sides of
// the fix.
//
// Fixture: tests/fixtures/videos/test_ffv1_pcm_4s.mkv — 4 s, 320×240 FFV1,
// pcm_s32le, generated with ffmpeg testsrc2+sine (same codec recipe as
// the real captures; no family media in the repo).

import Testing
import Foundation
import CoreGraphics
@testable import VideoScan

@Suite struct MKVDossierPipelineTests {

    private var mkvPath: String { testFixturesDir() + "/test_ffv1_pcm_4s.mkv" }
    private var mp4Path: String { testFixturesDir() + "/test_face_3s.mp4" }

    // MARK: - Frame extraction (caption/VLM leg)

    @Test func captionFrameExtractionWorksOnFFV1MKV() async throws {
        let results = try await extractFramesForCaptioning(
            from: URL(fileURLWithPath: mkvPath),
            atTimestamps: [0.5, 2.0, 3.5]
        )
        #expect(results.count == 3, "One slot per requested timestamp")
        let successes = results.filter { $0.frame.isSuccess }
        #expect(successes.count == 3,
                "Every frame of an FFV1/Matroska master must decode (RED pre-fix: videoUnreadable — AVFoundation can't open mkv)")
        if case .success(let cg) = results[0].frame {
            #expect(cg.width == 320 && cg.height == 240,
                    "Decoded frame must be the video's native resolution")
        }
    }

    @Test func captionFrameExtractionStillWorksOnMP4() async throws {
        // Sanity pin: the AVFoundation fast path must keep serving
        // AVFoundation-friendly containers, before AND after the fix.
        let results = try await extractFramesForCaptioning(
            from: URL(fileURLWithPath: mp4Path),
            atTimestamps: [0.5, 1.5]
        )
        #expect(results.filter { $0.frame.isSuccess }.count == 2)
    }

    @Test func frameExtractionStillThrowsForMissingFile() async {
        // The fallback must not swallow the real failure mode: a file
        // that no tool can read still throws videoUnreadable.
        await #expect(throws: CaptionRunnerError.self) {
            _ = try await extractFramesForCaptioning(
                from: URL(fileURLWithPath: testFixturesDir() + "/does_not_exist.mkv"),
                atTimestamps: [1.0]
            )
        }
    }

    // MARK: - Audio preflight (whisper leg)

    @Test func audioPreflightDetectsPCMAudioInMKV() async throws {
        let present = try await audioTrackIsPresent(at: mkvPath)
        #expect(present,
                "FFV1+pcm_s32le mkv HAS audio — the preflight must say so (RED pre-fix: audioUnreadable — AVURLAsset can't see inside mkv)")
    }

    @Test func audioPreflightStillWorksOnMP4() async throws {
        let present = try await audioTrackIsPresent(at: mp4Path)
        #expect(present, "AVFoundation fast path must keep working on mp4")
    }

    @Test func audioPreflightStillThrowsForMissingFile() async {
        await #expect(throws: AudioTranscriberError.self) {
            _ = try await audioTrackIsPresent(at: testFixturesDir() + "/does_not_exist.mkv")
        }
    }
}
