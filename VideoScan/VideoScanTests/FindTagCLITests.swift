import Testing
import Foundation
@testable import VideoScan

// FindTagCLI unit tests (2026-08-06) — the daemon-side halves that
// don't need a process: argument grammar, the human-settled filter,
// and the per-clip watchdog race. The watchdog tests are the daemon
// counterpart of codex's in-app GH #156 suite: they pin that a wedged
// clip is abandoned and that a LATE completion is discarded rather
// than delivered anywhere (misattribution impossible by construction —
// the continuation and once-flag are locals of the call).
struct FindTagCLITests {

    // MARK: Argument parsing

    @Test func parseDefaultsAndOverrides() throws {
        let defaults = try FindTagCLI.parse(["--find-tag"])
        #expect(defaults.person == "Donna")
        #expect(defaults.resume)
        #expect(defaults.stallSeconds == 300)
        #expect(defaults.limit == nil)

        let opts = try FindTagCLI.parse([
            "--find-tag", "--person", "Tim", "--limit", "5",
            "--no-resume", "--stall-seconds", "60",
            "--path-prefix", "/Volumes/X",
            "--catalog", "/tmp/cat.json",
        ])
        #expect(opts.person == "Tim")
        #expect(opts.limit == 5)
        #expect(!opts.resume)
        #expect(opts.stallSeconds == 60)
        #expect(opts.pathPrefix == "/Volumes/X")
        #expect(opts.catalogURL.path == "/tmp/cat.json")
    }

    @Test func parseRejectsBadInput() {
        #expect(throws: FindTagCLI.ParseError.self) {
            _ = try FindTagCLI.parse(["--limit", "zero"])
        }
        #expect(throws: FindTagCLI.ParseError.self) {
            _ = try FindTagCLI.parse(["--stall-seconds", "5"])   // under 10s floor
        }
        #expect(throws: FindTagCLI.ParseError.self) {
            _ = try FindTagCLI.parse(["--frobnicate"])
        }
        #expect(throws: FindTagCLI.ParseError.self) {
            _ = try FindTagCLI.parse(["--person"])               // missing value
        }
    }

    // MARK: Human-settled filter

    @Test func humanSettledSkipsConfirmedAndRejected() {
        let rejected = VideoRecord()
        rejected.rejectedPeople = ["donna"]
        #expect(FindTagCLI.isHumanSettled(rejected, person: "Donna"))

        let confirmed = VideoRecord()
        confirmed.confirmedByUserPeople = [ConfirmedTag(name: "DONNA", confirmedAt: Date())]
        #expect(FindTagCLI.isHumanSettled(confirmed, person: "Donna"))

        let untouched = VideoRecord()
        untouched.rejectedPeople = ["Tim"]
        #expect(!FindTagCLI.isHumanSettled(untouched, person: "Donna"))
    }

    // MARK: Watchdog race (fast — injected poll cadence, no media)

    /// Scripted RecipeScoring: sleeps `delay`, then returns `verdict`.
    /// Never touches CoreML/ffmpeg.
    actor ScriptedScorer: RecipeScoring {
        let delay: Double
        let verdict: RecipeClipScore
        init(delay: Double, verdict: RecipeClipScore) {
            self.delay = delay
            self.verdict = verdict
        }
        func prepare(galleryRoot: URL) async throws -> Int { 1 }
        func score(clip: URL) async -> RecipeClipScore {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            return verdict
        }
    }

    @Test func healthyClipReturnsItsVerdict() async {
        let scorer = ScriptedScorer(
            delay: 0.02, verdict: RecipeClipScore(score: 0.7))
        let beats = FindTagCLI.BeatBox()
        let result = await FindTagCLI.scoreWithWatchdog(
            scorer: scorer, clip: URL(fileURLWithPath: "/tmp/a.mov"),
            beats: beats, stallSeconds: 5, pollSeconds: 0.01)
        #expect(result?.score == 0.7)
    }

    @Test func wedgedClipIsAbandonedAsNil() async {
        // Scorer "hangs" (1s ≫ the 0.05s stall bar) and emits no beats;
        // the watchdog must return nil in ~stallSeconds, not wait out
        // the scorer.
        let scorer = ScriptedScorer(
            delay: 1.0, verdict: RecipeClipScore(score: 0.9))
        let beats = FindTagCLI.BeatBox()
        let began = CFAbsoluteTimeGetCurrent()
        let result = await FindTagCLI.scoreWithWatchdog(
            scorer: scorer, clip: URL(fileURLWithPath: "/tmp/wedge.mov"),
            beats: beats, stallSeconds: 0.05, pollSeconds: 0.01)
        let elapsed = CFAbsoluteTimeGetCurrent() - began
        #expect(result == nil)
        #expect(elapsed < 0.6, "abandon must not wait for the wedged scorer")
    }

    @Test func beatsKeepASlowClipAlive() async {
        // Slow but ALIVE: beats every 0.02s hold off a 0.1s stall bar
        // even though the scorer takes 0.3s total — starvation ≠ stall.
        let scorer = ScriptedScorer(
            delay: 0.3, verdict: RecipeClipScore(score: 0.5))
        let beats = FindTagCLI.BeatBox()
        let beater = Task {
            while !Task.isCancelled {
                beats.note()
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        defer { beater.cancel() }
        let result = await FindTagCLI.scoreWithWatchdog(
            scorer: scorer, clip: URL(fileURLWithPath: "/tmp/slow.mov"),
            beats: beats, stallSeconds: 0.1, pollSeconds: 0.01)
        #expect(result?.score == 0.5)
    }

    @Test func lateCompletionAfterAbandonIsDiscardedSafely() async {
        // The daemon-side stale-completion pin: abandon fires first,
        // the scorer completes later, and that late value must be
        // DROPPED (OnceFlag already claimed) — never resumed twice,
        // never delivered anywhere else. Surviving the wait past the
        // scorer's completion without a crash/second-resume trap is
        // the assertion.
        let scorer = ScriptedScorer(
            delay: 0.15, verdict: RecipeClipScore(score: 0.9))
        let beats = FindTagCLI.BeatBox()
        let result = await FindTagCLI.scoreWithWatchdog(
            scorer: scorer, clip: URL(fileURLWithPath: "/tmp/late.mov"),
            beats: beats, stallSeconds: 0.03, pollSeconds: 0.01)
        #expect(result == nil)                       // abandoned
        try? await Task.sleep(nanoseconds: 250_000_000)   // let it complete late
        // No crash, no double-resume: the CheckedContinuation would
        // trap on a second resume, failing this test loudly.
    }
}
