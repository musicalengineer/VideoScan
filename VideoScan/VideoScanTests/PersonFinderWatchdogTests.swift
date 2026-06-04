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
}
