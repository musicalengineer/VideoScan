import Testing
import Foundation
@testable import VideoScan

// MARK: - pfShouldAbortForWatchdog
//
// Companion to pfClampNominalFps. Defense-in-depth for the corrupt-
// metadata trap: even if fps clamping misses some pathology, a wall-
// clock budget on each file ensures we never spin for hours on one
// item. Budget formula: max(60s, 10× media duration). The 10× factor
// comfortably accommodates slow disks + slow Vision passes on legit
// content; 60s floor protects very short clips from being aborted
// by ANE warmup overhead.
//
// Companion incident: DickyTheBoysDadBreen-1985.mp4 wall-clocked 3h
// 48m on a 71s clip — budget would have been 710s = 11.8 min, abort
// would fire ~22% in.

struct PersonFinderWatchdogTests {

    @Test func underBudgetDoesNotAbort() {
        // 5s of work on a 71s clip — well within budget (710s).
        #expect(!pfShouldAbortForWatchdog(elapsedSecs: 5, mediaSecs: 71))
        // Right at the budget edge for 71s clip — should NOT abort yet
        // (strict-greater semantics).
        #expect(!pfShouldAbortForWatchdog(elapsedSecs: 710, mediaSecs: 71))
    }

    @Test func overBudgetAborts() {
        // 13min wall on a 71s clip → budget=710s → abort.
        #expect(pfShouldAbortForWatchdog(elapsedSecs: 800, mediaSecs: 71))
        // Catches the Dicky incident exactly: 89min at 25% → 710s
        // budget would fire long before 89min.
        #expect(pfShouldAbortForWatchdog(elapsedSecs: 5340, mediaSecs: 71))
    }

    @Test func shortClipFloorIs60s() {
        // 1-second clip: 10× rule gives 10s, but 60s floor protects
        // against ANE warmup variance + AVAssetReader setup overhead.
        #expect(!pfShouldAbortForWatchdog(elapsedSecs: 30, mediaSecs: 1))
        #expect(!pfShouldAbortForWatchdog(elapsedSecs: 60, mediaSecs: 1))
        #expect(pfShouldAbortForWatchdog(elapsedSecs: 65, mediaSecs: 1))
    }

    @Test func longClipUses10xRule() {
        // 5min clip → budget = max(60, 50min) = 50min.
        let fiveMin = 300.0
        #expect(!pfShouldAbortForWatchdog(elapsedSecs: 1000, mediaSecs: fiveMin))
        #expect(!pfShouldAbortForWatchdog(elapsedSecs: 3000, mediaSecs: fiveMin))
        #expect(pfShouldAbortForWatchdog(elapsedSecs: 3001, mediaSecs: fiveMin))
    }

    @Test func zeroMediaDurationUses60sFloor() {
        // Defensive: a clip with no duration should still time-out at
        // 60s rather than hang forever.
        #expect(!pfShouldAbortForWatchdog(elapsedSecs: 30, mediaSecs: 0))
        #expect(pfShouldAbortForWatchdog(elapsedSecs: 61, mediaSecs: 0))
    }

    // MARK: Absolute ceiling (2026-08-07 — the P216 incident)

    @Test func absoluteCeilingCapsLongMedia() {
        // A 2h10m FFV1 mkv earned a 21h40m budget under the bare 10×
        // rule — P216_2.mkv legally ground 4 h in-app and again
        // daemon-side the same day. The 2 h ceiling ends any single
        // clip's claim on the run; error verdicts are retried next run.
        let twoHoursTen = 7800.0
        #expect(pfWatchdogAbsoluteCeilingSecs == 7200)
        #expect(!pfShouldAbortForWatchdog(elapsedSecs: 7200, mediaSecs: twoHoursTen))
        #expect(pfShouldAbortForWatchdog(elapsedSecs: 7201, mediaSecs: twoHoursTen))
        // Even absurd metadata (a "24-hour" clip) cannot raise the cap.
        #expect(pfShouldAbortForWatchdog(elapsedSecs: 7201, mediaSecs: 86_400))
    }

    // MARK: Abort must never become a cache entry (codex #290)

    @Test func watchdogAbortedResultIsNeverCacheable() {
        // The blocker shape: a ceiling abort broke the frame loop and
        // the partial (possibly false-no-hit) result was cached as
        // complete — permanently. The store gate refuses aborted
        // results; uncached files re-scan next run.
        let aborted = pfVideoResult(
            filename: "p216.mkv", filePath: "/v/p216.mkv",
            durationSeconds: 7800, fps: 2, totalHits: 0, segments: [],
            facesDetected: 12, watchdogAborted: true)
        #expect(!PersonFinderCache.shouldStore(result: aborted))

        let complete = pfVideoResult(
            filename: "ok.mov", filePath: "/v/ok.mov",
            durationSeconds: 60, fps: 2, totalHits: 3, segments: [],
            facesDetected: 40)
        #expect(PersonFinderCache.shouldStore(result: complete))
    }

    @Test func abortLogsUseTheCappedBudget() {
        // The log line must print the REAL budget (codex #292: it
        // printed the uncapped 10x figure — 21h40m for a 2h10m clip).
        #expect(pfWatchdogBudgetSecs(mediaSecs: 7800) == 7200)
        #expect(pfWatchdogBudgetSecs(mediaSecs: 71) == 710)
        #expect(pfWatchdogBudgetSecs(mediaSecs: 0) == 60)
    }

    @Test func ceilingDoesNotShortenNormalBudgets() {
        // The 10× rule still governs everything below the cap: a 10min
        // clip keeps its 100min budget untouched.
        #expect(!pfShouldAbortForWatchdog(elapsedSecs: 5999, mediaSecs: 600))
        #expect(pfShouldAbortForWatchdog(elapsedSecs: 6001, mediaSecs: 600))
    }
}
