import Foundation
import Testing
@testable import VideoScan

// MARK: - CaptionRunner stage-6a tests
//
// Exercises the engine wiring: pick a short fixture video, pick a
// handful of timestamps, run them through `MLXVLMCaptionRunner.caption`,
// and assert the round-trip is shaped right.
//
// The "real VLM" test (`captionsThreeFramesEndToEnd`) is GATED behind
// `VS_RUN_VLM=1` — same pattern the ArcFace MLE5 stress suite uses
// (see ArcFaceMLE5ProvocationTests.swift). First-call cost on this
// suite is steep:
//   * ~3 GB HuggingFace download of Qwen2.5-VL-3B-Instruct-4bit
//     weights (one-time, into the user's HF cache)
//   * ~30-90s cold model load even after weights are cached
//   * ~3-10s inference per frame
//
// Standard `xcodebuild test` sweeps must NOT pay that cost. The full
// suite runs hundreds of tests; an unguarded VLM test would either
// time out (>2 min limit) or stall CI hosts. The gated test only runs
// when a developer explicitly opts in.
//
// A small stub-mode test runs unconditionally — it verifies the
// runner protocol compiles and the error type is wired without
// touching MLX. Good enough to keep the file alive in CI even when
// VS_RUN_VLM is not set.

@Suite("Caption Runner — stage 6a engine wiring")
struct CaptionRunnerTests {

    // MARK: - Always-on: stub Python runner

    /// Verifies the Python subprocess stub still throws .notImplemented
    /// — quick smoke that the protocol/error wiring is intact. Cheap,
    /// runs on every full suite sweep.
    @Test("python subprocess runner throws notImplemented")
    func pythonStubReturnsNotImplemented() async throws {
        let runner = PythonSubprocessCaptionRunner(
            pythonPath: "/usr/bin/python3",
            scriptPath: "/dev/null/scripts/vlm_caption.py"
        )
        #expect(runner.modelID == "python-vlm-qwen25vl-3b-4bit")

        do {
            _ = try await runner.caption(
                videoPath: "/dev/null/nonexistent.mp4",
                atTimestamps: [0.5]
            )
            Issue.record("Python stub should have thrown .notImplemented")
        } catch let err as CaptionRunnerError {
            switch err {
            case .notImplemented(let engine):
                #expect(engine == "PythonSubprocess")
            default:
                Issue.record("Expected .notImplemented, got: \(err)")
            }
        }
    }

    // MARK: - VLM-gated: real model inference

    /// Real end-to-end MLX VLM run. Loads the model, extracts 3 frames
    /// from the test_face_3s.mp4 fixture, runs Qwen2.5-VL on each, and
    /// asserts captions came back with non-empty text at the right
    /// timestamps.
    ///
    /// Gated behind VS_RUN_VLM=1 — see suite header comment for cost
    /// rationale.
    // .timeLimit set generously: first-run hits a ~3GB HuggingFace
    // download which can take 5-10 minutes on home broadband.
    // Subsequent runs (model cached) finish in ~10 seconds. Swift
    // Testing's .timeLimit aborts the test if it overruns, which is
    // what we want — better than letting it spin indefinitely.
    @Test(
        "MLXVLM captions 3 frames end-to-end (VS_RUN_VLM=1)",
        .disabled(
            if: ProcessInfo.processInfo.environment["VS_RUN_VLM"] != "1",
            "VLM end-to-end suite — set VS_RUN_VLM=1 to enable (downloads ~3GB on first run)."
        ),
        .timeLimit(.minutes(10))
    )
    func captionsThreeFramesEndToEnd() async throws {
        let fixturesDir = testFixturesDir()
        let videoPath = fixturesDir + "/test_face_3s.mp4"

        // Sanity-check the fixture is where we think it is.
        #expect(FileManager.default.fileExists(atPath: videoPath),
                "Fixture not found at \(videoPath) — repo layout drift?")

        let runner = MLXVLMCaptionRunner()
        #expect(runner.modelID == "qwen2.5-vl-3b-4bit")

        // Three timestamps inside the 3-second clip. Avoid the very
        // first/last 5% the way the Python prototype does — those are
        // usually black or partial frames.
        let timestamps: [Double] = [0.3, 1.5, 2.7]

        let captions = try await runner.caption(
            videoPath: videoPath,
            atTimestamps: timestamps
        )

        // The protocol allows fewer captions than timestamps if some
        // frames fail to decode. For a known-good 3s MP4 fixture all
        // three should land.
        #expect(captions.count == timestamps.count,
                "Expected \(timestamps.count) captions, got \(captions.count). Print them: \(captions)")

        for (i, cap) in captions.enumerated() {
            #expect(!cap.text.isEmpty, "Caption \(i) has empty text: \(cap)")
            // Timestamps should round-trip in order. Allow a small
            // tolerance for the frame generator's tolerance window.
            if i < timestamps.count {
                let expected = timestamps[i]
                #expect(abs(cap.timestamp - expected) < 0.5,
                        "Caption \(i) timestamp drift: expected ~\(expected), got \(cap.timestamp)")
            }
        }

        // Surface real captions in the test log — Rick wants proof the
        // VLM actually produced something instead of a stub string.
        for cap in captions {
            print("  [\(String(format: "%.2f", cap.timestamp))s] \(cap.text)")
        }
    }
}
