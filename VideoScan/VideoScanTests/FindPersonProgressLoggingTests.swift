import Foundation
import Testing
@testable import VideoScan

@Suite("Find & Tag progress logging")
struct FindPersonProgressLoggingTests {
    @Test("completed-file line carries the full operational contract")
    func progressLineContract() {
        let line = FindPersonJob.progressLine(
            person: "Donna",
            completed: 9,
            total: 16,
            tagged: 7,
            maybes: 1,
            errors: 1,
            elapsedSeconds: 3_780,
            lastFilename: "archive.mkv",
            lastDetail: "ffmpeg, 13996f, 14504 faces, 10m 27s")

        #expect(line.contains("Find Donna progress: 9/16 (56.2%)"))
        #expect(line.contains("8.6 files/h"))
        #expect(line.contains("ETA 48m 59s") || line.contains("ETA 49m 0s"),
                "ETA should remain within the one-second floating-point boundary")
        #expect(line.contains("7 Donna*, 1 Donna?, 1 error(s)"))
        #expect(line.hasSuffix(
            "last: archive.mkv (ffmpeg, 13996f, 14504 faces, 10m 27s)"))
    }

    @Test("ETA is unknown until throughput is measurable")
    func zeroRateDoesNotClaimZeroETA() {
        let line = FindPersonJob.progressLine(
            person: "Donna", completed: 0, total: 2_988,
            tagged: 0, maybes: 0, errors: 0,
            elapsedSeconds: 0, lastFilename: "first.mov")

        #expect(line.contains("0/2988 (0.0%)"))
        #expect(line.contains("0.0 files/h | ETA —"))
        #expect(!line.lowercased().contains("nan"))
        #expect(!line.lowercased().contains("inf"))
    }

    @Test("batch counters are clamped to honest bounds",
          arguments: [
            (-1, 16, "0/16 (0.0%)"),
            (17, 16, "16/16 (100.0%)"),
            (1, 0, "0/0 (100.0%)")
          ])
    func progressBounds(completed: Int, total: Int, expected: String) {
        let line = FindPersonJob.progressLine(
            person: "Donna", completed: completed, total: total,
            tagged: 0, maybes: 0, errors: 0,
            elapsedSeconds: 60, lastFilename: "clip.mov")
        #expect(line.contains(expected))
    }

    @Test("stall evidence pins batch position and current file")
    func stallContext() {
        #expect(FindPersonJob.stallDescription(
            silentSeconds: 315.9, completed: 40, total: 2_988,
            currentFilename: "damaged-tape.mkv")
            == "no progress for 315s — recipe engine stalled at 40/2988 while scanning damaged-tape.mkv")
        #expect(FindPersonJob.stallDescription(
            silentSeconds: -1, completed: -1, total: -1,
            currentFilename: nil)
            == "no progress for 0s — recipe engine stalled at 0/0")
    }

    @Test("quartile boundaries are monotonic and emitted once")
    func quartileCadence() {
        var logged = 0
        var emitted: [Int] = []
        for fraction in [-0.2, 0, 0.2499, 0.25, 0.26, 0.4999,
                         0.5, 0.74, 0.75, 0.9, 1, 1.2] {
            if let next = FindPersonJob.quartileToLog(
                fraction: fraction, alreadyLogged: logged) {
                emitted.append(next)
                logged = next
            }
        }
        #expect(emitted == [1, 2, 3])
    }

    @Test("a beat that jumps quartiles logs only the highest crossed milestone")
    func quartileJumpPolicy() {
        #expect(FindPersonJob.quartileToLog(
            fraction: 0.80, alreadyLogged: 0) == 3)
        #expect(FindPersonJob.quartileToLog(
            fraction: 0.80, alreadyLogged: 3) == nil)
    }

    @Test("per-clip detail identifies decoder, work, faces, and elapsed time")
    func clipDetailContract() {
        let fallback = RecipeClipScore(
            frameCount: 14_676, gatedFaceCount: 1_564,
            decodeTransport: "ffmpeg")
        #expect(FindPersonJob.clipDetail(
            verdict: fallback, wallSeconds: 646)
            == "ffmpeg, 14676f, 1564 faces, 10m 46s")

        let legacy = RecipeClipScore(frameCount: 3, gatedFaceCount: 0)
        #expect(FindPersonJob.clipDetail(
            verdict: legacy, wallSeconds: 0.4)
            == "native, 3f, 0 faces, 0s")
    }

    @Test("100k progress lines stay within a bounded logging budget")
    func progressFormattingScale() {
        let start = CFAbsoluteTimeGetCurrent()
        var checksum = 0
        for completed in 1...100_000 {
            autoreleasepool {
                let line = FindPersonJob.progressLine(
                    person: "Donna", completed: completed, total: 100_000,
                    tagged: completed / 10, maybes: completed / 20,
                    errors: completed / 1_000,
                    elapsedSeconds: Double(completed) * 0.25,
                    lastFilename: "test_\(completed).mkv",
                    lastDetail: "ffmpeg, 100f, 5 faces, 1s")
                checksum &+= line.utf8.count
            }
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        #expect(checksum > 10_000_000)
        #expect(elapsed < 5,
                "100k progress lines took \(elapsed)s; budget is 5s")
    }
}
