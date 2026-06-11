import Testing
import Foundation
@testable import VideoScan

// MARK: - AllFramesRipPlannerTests
//
// Locks in the ffmpeg argv per sampling mode and the estimate math for
// "Extract Frames…" (verb split 2026-06-10). The planner is pure — no
// Process, no I/O — so these run instantly. The estimate tests matter
// because the options sheet's disk-bomb guard is only as good as this
// arithmetic; the argv tests catch a silent flag regression (e.g.
// losing -fps_mode passthrough, which would drop dup frames on VFR
// sources and undercount vs. the estimate).

struct AllFramesRipPlannerTests {

    private let dest = URL(fileURLWithPath: "/tmp/clip-allframes", isDirectory: true)

    private func args(_ sampling: AllFramesRipPlanner.Sampling) -> [String] {
        AllFramesRipPlanner.buildArgs(inputPath: "/tmp/clip.dv",
                                      destinationDir: dest,
                                      sampling: sampling)
    }

    private func consecutive(_ a: [String], _ first: String, _ second: String) -> Bool {
        for i in a.indices.dropLast() where a[i] == first && a[i + 1] == second {
            return true
        }
        return false
    }

    // MARK: - argv

    @Test
    func everyFrameUsesPassthroughAndNoFilter() {
        let a = args(.everyFrame)
        #expect(consecutive(a, "-fps_mode", "passthrough"))
        #expect(!a.contains("-vf"), "every-frame mode must not insert a filter")
    }

    @Test
    func everyNthBuildsEscapedSelectFilter() {
        let a = args(.everyNth(step: 10))
        // The \, is filtergraph escaping — a bare comma would split the
        // chain. Process passes argv verbatim, so the literal backslash
        // must be IN the string.
        #expect(consecutive(a, "-vf", "select=not(mod(n\\,10))"))
        #expect(consecutive(a, "-fps_mode", "vfr"))
    }

    @Test
    func framesPerSecondUsesFpsFilter() {
        let a = args(.framesPerSecond(fps: 2))
        #expect(consecutive(a, "-vf", "fps=2"))
        #expect(!a.contains("-fps_mode"), "fps filter mode relies on default fps_mode")
    }

    @Test
    func commonFlagsPresentInAllModes() {
        for sampling: AllFramesRipPlanner.Sampling in
            [.everyFrame, .everyNth(step: 5), .framesPerSecond(fps: 1)] {
            let a = args(sampling)
            #expect(a.first == "-y")
            #expect(a.contains("-nostdin"))
            #expect(consecutive(a, "-i", "/tmp/clip.dv"))
            #expect(consecutive(a, "-progress", "pipe:1"))
            #expect(a.contains("-nostats"))
            #expect(a.last == "/tmp/clip-allframes/frame_%06d.png")
        }
    }

    @Test
    func destinationDirNameNeverCollidesWithFacialRipper() {
        // FrameRipper writes "<stem>-frames"; this verb must not.
        #expect(AllFramesRipPlanner.destinationDirName(forStem: "clip") == "clip-allframes")
    }

    // MARK: - sourceFPS parsing

    @Test
    func parsesDecimalAndFractionAndRejectsJunk() {
        #expect(AllFramesRipPlanner.sourceFPS(fromCatalogString: "29.97") == 29.97)
        let ntsc = AllFramesRipPlanner.sourceFPS(fromCatalogString: "30000/1001")
        #expect(ntsc != nil && abs(ntsc! - 29.97) < 0.01)
        #expect(AllFramesRipPlanner.sourceFPS(fromCatalogString: " 25 ") == 25)
        #expect(AllFramesRipPlanner.sourceFPS(fromCatalogString: "") == nil)
        #expect(AllFramesRipPlanner.sourceFPS(fromCatalogString: "n/a") == nil)
        #expect(AllFramesRipPlanner.sourceFPS(fromCatalogString: "30/0") == nil)
        #expect(AllFramesRipPlanner.sourceFPS(fromCatalogString: "0") == nil)
        #expect(AllFramesRipPlanner.sourceFPS(fromCatalogString: "-25") == nil)
    }

    // MARK: - frame estimates

    @Test
    func estimatesRicksTenMinuteDVReference() {
        // Rick's reference point: 10-min DV @ 29.97 ≈ 18k frames.
        let frames = AllFramesRipPlanner.estimatedFrames(durationSeconds: 600,
                                                         sourceFPS: 29.97,
                                                         sampling: .everyFrame)
        #expect(frames == 17_982)
    }

    @Test
    func everyNthDividesAndFpsModeIgnoresSourceRate() {
        #expect(AllFramesRipPlanner.estimatedFrames(durationSeconds: 600,
                                                    sourceFPS: 30,
                                                    sampling: .everyNth(step: 10)) == 1_800)
        // framesPerSecond needs only duration — nil sourceFPS is fine.
        #expect(AllFramesRipPlanner.estimatedFrames(durationSeconds: 600,
                                                    sourceFPS: nil,
                                                    sampling: .framesPerSecond(fps: 1)) == 600)
    }

    @Test
    func missingMetadataYieldsNilNotZero() {
        // nil drives the sheet's "unknown" label + indeterminate row —
        // 0 would render a bogus "~0 frames" estimate.
        #expect(AllFramesRipPlanner.estimatedFrames(durationSeconds: 600,
                                                    sourceFPS: nil,
                                                    sampling: .everyFrame) == nil)
        #expect(AllFramesRipPlanner.estimatedFrames(durationSeconds: 0,
                                                    sourceFPS: 30,
                                                    sampling: .everyFrame) == nil)
        #expect(AllFramesRipPlanner.estimatedFrames(durationSeconds: .nan,
                                                    sourceFPS: 30,
                                                    sampling: .everyFrame) == nil)
    }

    @Test
    func shortClipClampsToAtLeastOneFrame() {
        #expect(AllFramesRipPlanner.estimatedFrames(durationSeconds: 0.01,
                                                    sourceFPS: 30,
                                                    sampling: .everyFrame) == 1)
    }

    // MARK: - disk estimates

    @Test
    func dvFrameByteEstimateMatchesReferencePoint() {
        // 720×480 × 3 B/px × 0.45 ≈ 466 KB/frame; ×18k ≈ 8 GB —
        // the "several GB" sanity anchor from the sheet header.
        let perFrame = AllFramesRipPlanner.estimatedBytesPerFrame(resolution: "720x480")
        #expect(perFrame == 466_560)
        let total = AllFramesRipPlanner.estimatedTotalBytes(frames: 17_982,
                                                            resolution: "720x480")
        // Homogeneous Int64 comparison — #expect's operand capture
        // mis-resolves a heterogeneous Int64? == Int and fails on
        // equal values.
        let expected: Int64 = 17_982 * 466_560
        #expect(total == expected)
    }

    @Test
    func byteEstimateHandlesCaseAndJunkResolutions() {
        #expect(AllFramesRipPlanner.estimatedBytesPerFrame(resolution: "1920X1080") != nil)
        #expect(AllFramesRipPlanner.estimatedBytesPerFrame(resolution: "") == nil)
        #expect(AllFramesRipPlanner.estimatedBytesPerFrame(resolution: "audio only") == nil)
        #expect(AllFramesRipPlanner.estimatedBytesPerFrame(resolution: "0x0") == nil)
        #expect(AllFramesRipPlanner.estimatedTotalBytes(frames: nil,
                                                        resolution: "720x480") == nil)
    }
}
