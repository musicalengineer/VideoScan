// GauntletFixturePlan.swift
//
// PURE ffmpeg-invocation planning for the Gauntlet UI-regression suite
// (docs/gauntlet.md). No I/O, no Process — just argument construction and
// the sampling arithmetic the flows rely on, so every fixture the Gauntlet
// synthesizes is unit-testable here (`swift test` in VideoScanCore) while
// the UI-test runner (VideoScanUITests/GauntletFixtures.swift) does the
// actual spawning.
//
// Lives in VideoScanCore because it's the one module BOTH the unit-test
// target and the UI-test runner link — app-target test-support files
// (BalanceAudioTestSupport et al.) are invisible to the UI bundle.
//
// C++ analogy: this is the command-line *builder* split from the
// process-spawner, exactly like separating argv assembly from execvp so
// the argv logic gets covered without forking.
//
// Conventions (match BalanceAudioTestSupport / CleanupTestMedia):
//   * every output filename carries the `test_` prefix
//   * durations stay tiny (seconds) — fixtures are generated per run
//   * DV two-pair fixtures use the DVCPRO50 profile: ffmpeg's dv muxer
//     rejects consumer 32 kHz PCM outright, and the STREAM SHAPE
//     (dvvideo + two pcm_s16le stereo pairs) is what the probe/job read.

import Foundation

public enum GauntletFixturePlan {

    /// One planned ffmpeg run. `arguments` excludes the ffmpeg binary
    /// path, the `-y -hide_banner -loglevel error` boilerplate, and the
    /// trailing output path — the runner owns those.
    public struct Invocation: Equatable {
        public let outputFilename: String
        public let arguments: [String]
        public init(outputFilename: String, arguments: [String]) {
            self.outputFilename = outputFilename
            self.arguments = arguments
        }
    }

    // MARK: - Audio expressions (aevalsrc per-channel)

    public static let programTone = "0.5*sin(440*2*PI*t)"
    public static let programTone2 = "0.5*sin(987*2*PI*t)"
    public static let silentPair = "0|0"
    public static var rightOnlyPair: String { "0|\(programTone)" }
    public static var leftOnlyPair: String { "\(programTone)|0" }
    public static var trueStereoPair: String { "\(programTone)|\(programTone2)" }

    // MARK: - Person-search fixtures (flow 1)

    /// A video whose first `faceSeconds` show a still reference photo and
    /// whose remainder is a synthetic test pattern (no face). With the
    /// SAME photo loaded as the person's reference, Vision's feature-print
    /// distance on the photo segment is ~0 — a guaranteed match — so the
    /// hit count is controlled entirely by `faceSeconds`:
    ///
    ///   faceSeconds == totalSeconds → hits ≈ sampledFrames → FOUND
    ///   brief faceSeconds on a long clip → hits < floor    → REFUSED
    ///
    /// The photo is scaled/padded to 640×480 so face detection has
    /// comfortable resolution; both segments get setsar=1 so concat
    /// doesn't reject mismatched sample aspect ratios.
    public static func faceTimelineVideo(photoPath: String,
                                         label: String,
                                         faceSeconds: Double,
                                         totalSeconds: Double,
                                         fps: Int = 25) -> Invocation {
        precondition(faceSeconds > 0 && totalSeconds >= faceSeconds)
        let name = "test_gauntlet_face_\(label).mp4"
        let scalePad = "scale=640:480:force_original_aspect_ratio=decrease,"
            + "pad=640:480:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=\(fps),format=yuv420p"

        if faceSeconds == totalSeconds {
            // Single-segment: the photo the whole way through.
            return Invocation(outputFilename: name, arguments: [
                "-loop", "1", "-framerate", "\(fps)",
                "-t", trim(faceSeconds), "-i", photoPath,
                "-vf", scalePad,
                "-c:v", "libx264", "-preset", "ultrafast"
            ])
        }
        let patternSeconds = totalSeconds - faceSeconds
        let filter = "[0:v]\(scalePad)[face];"
            + "[1:v]setsar=1,format=yuv420p[fill];"
            + "[face][fill]concat=n=2:v=1:a=0[v]"
        return Invocation(outputFilename: name, arguments: [
            "-loop", "1", "-framerate", "\(fps)",
            "-t", trim(faceSeconds), "-i", photoPath,
            "-f", "lavfi",
            "-i", "testsrc=duration=\(trim(patternSeconds)):size=640x480:rate=\(fps)",
            "-filter_complex", filter,
            "-map", "[v]",
            "-c:v", "libx264", "-preset", "ultrafast"
        ])
    }

    // MARK: - Catalog fixtures (flows 2/3)

    /// A plain, boring video+audio clip with a distinctive filename —
    /// what the catalog-search and set-a-date flows scan and filter on.
    public static func catalogClip(label: String,
                                   seconds: Double = 2.0) -> Invocation {
        Invocation(outputFilename: "test_gauntlet_\(label).mp4", arguments: [
            "-f", "lavfi",
            "-i", "testsrc=duration=\(trim(seconds)):size=320x240:rate=25",
            "-f", "lavfi",
            "-i", "aevalsrc=\(programTone)|\(programTone):s=48000:d=\(trim(seconds))",
            "-map", "0:v:0", "-map", "1:a:0",
            "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "128k"
        ])
    }

    // MARK: - Balance Audio fixtures (flow 4)

    /// Real .dv container in the DVCPRO50 profile with TWO stereo PCM
    /// pairs — the 12-bit DV camcorder shape. `pair1`/`pair2` are aevalsrc
    /// "L|R" expression sets (e.g. `rightOnlyPair` + `silentPair` for the
    /// fixable case Rick's spot test uses).
    public static func twoPairDV(label: String,
                                 pair1: String,
                                 pair2: String,
                                 seconds: Double = 2.0) -> Invocation {
        Invocation(outputFilename: "test_gauntlet_2pair_\(label).dv", arguments: [
            "-f", "lavfi",
            "-i", "testsrc=duration=\(trim(seconds)):size=720x480:rate=30000/1001",
            "-f", "lavfi",
            "-i", "aevalsrc=\(pair1):s=48000:d=\(trim(seconds))",
            "-f", "lavfi",
            "-i", "aevalsrc=\(pair2):s=48000:d=\(trim(seconds))",
            "-map", "0:v", "-map", "1:a", "-map", "2:a",
            "-c:v", "dvvideo", "-pix_fmt", "yuv422p",
            "-c:a", "pcm_s16le"
        ])
    }

    /// True-stereo mov (decorrelated tones per channel) — the fixture the
    /// refusal assertion uses: Balance Audio must explain, not offer a fix.
    public static func trueStereoMov(label: String,
                                     seconds: Double = 2.0) -> Invocation {
        Invocation(outputFilename: "test_gauntlet_stereo_\(label).mov", arguments: [
            "-f", "lavfi",
            "-i", "testsrc=duration=\(trim(seconds)):size=320x240:rate=25",
            "-f", "lavfi",
            "-i", "aevalsrc=\(trueStereoPair):s=48000:d=\(trim(seconds))",
            "-map", "0:v:0", "-map", "1:a:0",
            "-c:v", "libx264", "-preset", "ultrafast",
            "-c:a", "pcm_s16le"
        ])
    }

    // MARK: - Match-floor arithmetic (flow 1 pre-flight)

    /// Mirror of the sampling estimate inside the app's match-confidence
    /// floor (PersonFinderModel.matchFloorDecision): how many frames a
    /// scan at `frameStep` samples from a clip. The Gauntlet uses this to
    /// PROVE its fixture durations put one video above and one below the
    /// floor before ever launching the app.
    public static func estimatedSampledFrames(durationSeconds: Double,
                                              fps: Double,
                                              frameStep: Int) -> Int {
        guard durationSeconds > 0, fps > 0, frameStep > 0 else { return 0 }
        return Int((durationSeconds * fps / Double(frameStep)).rounded(.down))
    }

    /// Expected face-match hits when the face occupies the FIRST
    /// `faceSeconds` of the clip (the faceTimelineVideo layout).
    public static func expectedFaceHits(faceSeconds: Double,
                                        fps: Double,
                                        frameStep: Int) -> Int {
        estimatedSampledFrames(durationSeconds: faceSeconds,
                               fps: fps, frameStep: frameStep)
    }

    /// True when a faceTimelineVideo with these parameters should be
    /// REFUSED by a floor of `floor` (hits below floor, but the clip is
    /// long enough that the short-clip any-hit fallback does NOT engage).
    public static func shouldBeRefusedByFloor(faceSeconds: Double,
                                              totalSeconds: Double,
                                              fps: Double,
                                              frameStep: Int,
                                              floor: Int) -> Bool {
        let sampled = estimatedSampledFrames(durationSeconds: totalSeconds,
                                             fps: fps, frameStep: frameStep)
        let hits = expectedFaceHits(faceSeconds: faceSeconds,
                                    fps: fps, frameStep: frameStep)
        return sampled >= floor && hits > 0 && hits < floor
    }

    // MARK: - Helpers

    /// "2.0" → "2", "1.5" → "1.5" — keeps ffmpeg args tidy and the
    /// expectations in tests stable.
    private static func trim(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }
}
