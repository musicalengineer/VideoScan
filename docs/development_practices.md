# Development Practices — VideoScan

**Last updated:** 2026-05-04
**Scope:** the development rhythm, testing strategy, and the unit-test reference for VideoScan. Branching/agent-coordination specifics live in [`features_and_branches.md`](features_and_branches.md); logging convention is in the same file.

This document replaces the prior `unit_tests.md`.

---

## TL;DR

- **Default mode**: small steps, TDD where the test is cheap, build-only otherwise. Regression-test-by-revert for every real bug.
- **Rapid Dev mode** (Rick says "RD"): build-only, no auto tests, fast iteration. Run the suite at end-of-day or start-of-day as a clean-slate bookend.
- **Regression discipline**: every fixed bug gets a test that has been *seen to fail* on the broken code. No exceptions.
- **Coverage as a tool, not a goal**: drive coverage on the logic-critical modules; ignore the headline number.
- **Concurrency is the recurring bug class**: run Thread Sanitizer on CI and stress-test the major mutable structures.

---

## The Daily Rhythm

| Mode | When | Behavior |
|---|---|---|
| **Normal** | Default, when correctness matters more than velocity | Small steps, ask before large changes, run tests on bug fixes, full suite at EOD/AM. |
| **RD (Rapid Dev)** | When Rick says "RD" or context is iterative UI/visual work | Streamlined prompts, build-only, no auto tests, calibrate ahead. Tests resume in Normal mode. |

These map to the memory entries `feedback_no_tests_rapid_dev.md` and `feedback_rapid_dev_mode.md`. RD is for fast prototype loops; the agent should *not* run tests during RD unless asked.

### When to write a test

- **Fixing a bug.** Always. Use the regression-test-by-revert pattern (see below).
- **Adding a non-trivial logic function** (parser, state machine, scoring algorithm, persistence path). Test it.
- **Touching a module that has zero coverage and is logic-critical.** Add at least one test before the change.

### When *not* to write a test

- Pure UI/SwiftUI views — covered by manual visual testing.
- Pass-through wrappers around third-party APIs (Vision, ffmpeg, dlib, CoreML, AVFoundation).
- Wall-clock or network behavior.
- Anything in RD mode.

---

## Testing Philosophy

VideoScan is a personal media app, but the discipline is deliberately modelled on safety-critical software practice — the kind of work Rick did in medical and industrial-controls shops for decades. The aim isn't maximum test count or a shiny coverage number; it's to reveal a process that would hold up in environments where silent failures hurt people.

### What we actually want to measure

Coverage-% is a weak metric on its own. A project at 90% coverage can still ship a serious bug if the tests never exercise the failure mode. And a project at 20% coverage can be rock-solid in the paths that matter if every known regression is locked down by a purpose-built test.

The better question is: **of the bugs we've found in this codebase, how many have a test that would have caught them the moment someone reverted the fix?** That number is usually much smaller than coverage — and far more meaningful.

### Test *our* logic, not other people's

Don't test Apple Vision, Swift standard library, ffmpeg, dlib, CoreML, or Apple Photos. Those are someone else's problem. Write tests for the code we wrote:

- Metadata extraction + parsing (ffprobe JSON → VideoRecord)
- Duplicate detection scoring
- Correlator matching audio-only + video-only pairs
- Combine engine's mux command construction
- Catalog state transitions
- Scan phase lifecycle
- Face-match scoring distance math
- Settings propagation into jobs
- Lifecycle stage promotion logic (when implemented)

Skip:
- SwiftUI view layout
- Third-party library behavior
- File I/O (except via fixtures)
- Wall-clock / network-dependent behavior

### The regression-test-by-revert pattern

This is the workflow used for every real bug:

1. **Find the bug** (reproducer in hand).
2. **Fix it** in the code.
3. **Write a unit test** that exercises the buggy path.
4. **Revert the fix** — run the test and confirm it FAILS.
5. **Restore the fix** — confirm the test PASSES.
6. **Commit fix + test together**, with the test tagged as a regression:

   ```swift
   // regression: empty MXF tracks silently skipped (issue #42)
   @Test func probeReportsEmptyTracks() { ... }
   ```

Step 4 is non-negotiable. A test that has never failed on the broken code is not yet trusted — you don't know whether it actually catches the bug or just passes coincidentally. Many codebases accumulate thousands of tests that have never once failed, and no one knows which of them are real.

This is the discipline that separates defensive unit tests from theater.

### Why this matters even for a home-video app

The point isn't that VideoScan will kill anyone. It's that the process of accumulating proven regression tests, one bug at a time, is the same process that makes medical-software reviews go smoothly. Every test in the suite should have a story: *this test exists because of this bug, and it has been seen to fail on the broken code.* That story is what a regulator or a surgeon or a post-mortem review wants to see — and it's what tells Rick, six months from now, that the test suite is worth trusting instead of rubber-stamping.

> "We don't want to rat-hole on metrics, but we want to keep on top of spaghetti code and regressions." — Rick, 2026-04-23.

---

## Testing Strategy — Beyond Coverage

The bugs that have actually hurt this project are not, mostly, bugs that line-coverage would have caught. The Copy Metadata exclusivity crash (2026-05-04) ran the affected `writeToDisk` code path on every save, but the bug was a concurrency race — invisible to single-threaded tests.

So the question to ask isn't *"what's our coverage number?"* — it's *"what classes of bug are we leaving on the table, and what's the cheapest tool for each?"*

### Bug-class map

| Bug class | Recent example | What catches it |
|---|---|---|
| Concurrency race | Copy Metadata exclusivity abort | **Thread Sanitizer (TSan)** in CI; stress tests with concurrent reads/writes |
| Format parsing | CRLF in cluster_summary.csv (silent 0-row parse) | **Real-input fixture tests** — feed the parser actual files from the wild |
| Silent failure | PersonFinder stuck 13h, no logs | **Logging convention** + observability, not test coverage |
| State machine | "Stuck in extraction," "no results visible during compile" | **Scenario tests** that walk the full lifecycle and assert invariants at each transition |
| Resource leak / OOM | Vision check gap, dlib bypass | **Soak tests** with memory watermarks |
| Filesystem edge case | Offline-volume hang, missing files | **Mock-fs fixtures** + adversarial-input tests |

Coverage helps for category 2, less for the others. So we deliberately target *each class* with the right tool, rather than chasing a blanket coverage number.

### Concrete recommendations, ordered by value-per-hour

#### 1. Synthetic catalog fixture *(highest leverage, ~half-day to build)*

The thing the project most lacks today: **realistic-shape data for tests**. Real video files are expensive to fake, but catalog-level data is just records. Build:

```swift
enum CatalogTestFixture {
    static func makeCatalog(
        records: Int = 1000,
        pairedFraction: Double = 0.2,      // 20% have audio/video pairs
        duplicateFraction: Double = 0.1,   // 10% have copies on other volumes
        peopleDetected: Int = 5,           // POIs distributed across records
        spanningDecades: ClosedRange<Int> = 1980...2020
    ) -> [VideoRecord]
}
```

This unlocks tests we can't currently write at meaningful scale:

- Round-trip: save catalog → load → identical?
- Correlation on 1000 records → pairs match expected count?
- DuplicateDetector on planted duplicates → finds all?
- Lifecycle stage transitions on a populated catalog → no records fall off?
- JSON encoder under concurrent mutation (the Copy Metadata bug class)?

Cost: ~half a day to build, returns multi-day savings every time someone writes a test.

#### 2. Thread Sanitizer (TSan) on the test scheme *(~1 hour to wire)*

Apple's TSan catches data races at runtime. Enable it as a build option on the test scheme — every CI run does both a normal test and a TSan test. Catches races like the Copy Metadata bug *without* needing to deterministically provoke them.

Cost: ~1 hour to wire. Tests run 3–5× slower under TSan; only on CI, so no developer impact.

#### 3. Concurrency stress tests for mutable shared-state structures

The major `class` types holding mutable state shared between background work and UI deserve targeted stress tests:

| Class | Risk | Existing isolation |
|---|---|---|
| `VideoRecord` | High — many writers, UI reads continuously | None (plain class) — caused the Copy Metadata bug |
| `ScanJob` | High — `@Published` fields written from background tasks during scan | None visible |
| `DashboardState.consoleLines` | Medium — multiple log writers, UI tail-reads | `@MainActor` — likely OK if all writers respect it |
| `IdentifyFamilyModel.consoleLines` | Medium — Python subprocess stdout writes here | `@MainActor` |
| `PersonFinderModel.savedProfiles` | Medium — written on POI promotion, read on render | `@MainActor` |

Audit pattern for each: read every write site, confirm it's reachable only from the expected actor; for non-actor-isolated classes (`VideoRecord`), decide between making the class `@MainActor`, making writes go through a serialized accessor, or copying-on-read at boundaries.

Multi-day effort but high-leverage. Best done as one focused branch.

#### 4. State-machine tests for the major flows

For each phase-driven model (PersonFinderModel, IdentifyFamilyModel, VideoScanModel), drive it through every state transition and assert invariants:

- "after `start` is called, status == .scanning within X seconds"
- "after scan completes, results are non-empty AND status == .compiling"
- "after compile completes, status == .done AND compiledVideoPaths.count > 0"
- "cancel from any state lands on .cancelled, no orphan tasks"

Cost: ~1–2 days per model. Catches the "stuck in extraction" / "results not visible" class of bug.

#### 5. Coverage targets *where it matters*

Skip the 80% blanket. Instead pick the **logic-critical modules** and target 80% there:

- VideoScanModel + extracted modules
- PersonFinderModel
- IdentifyFamilyModel
- CatalogStore + BundleExportImport
- CorrelationScorer, DuplicateDetector, CombineEngine, ArcFaceEngine

Views stay low (UI testing is a separate exercise). The CI metrics dashboard already supports per-file thresholds.

### Continuous testing using the M4 Max compute budget

These run on schedule, alert on regression, cost zero human attention:

- **TSan on every CI run** (already free if step 2 above is wired).
- **Nightly stress job**: runs concurrency tests at higher iteration counts (hours instead of seconds).
- **Weekly soak job**: loads a synthetic 50K-record catalog and exercises save/load/correlate cycles continuously for hours, watching memory + crash counts.

---

## Running Tests Locally

```bash
# Full test suite (unit + UI tests)
xcodebuild test -project VideoScan/VideoScan.xcodeproj -scheme VideoScan -destination 'platform=macOS'

# Unit tests only (faster, no UI tests)
xcodebuild test -project VideoScan/VideoScan.xcodeproj -scheme VideoScan -destination 'platform=macOS' -only-testing:VideoScanTests

# Quiet mode (just pass/fail summary)
xcodebuild test -project VideoScan/VideoScan.xcodeproj -scheme VideoScan -destination 'platform=macOS' -quiet

# A single test class or test
xcodebuild test-without-building -project VideoScan/VideoScan.xcodeproj -scheme VideoScan -destination 'platform=macOS' -only-testing:VideoScanTests/CatalogStoreConcurrencyTests
```

### Where local results live

- **Terminal output**: streams to stdout as tests run.
- **Xcode derived data**: `~/Library/Developer/Xcode/DerivedData/VideoScan-*/Logs/Test/`
- **Result bundle** (if you add `-resultBundlePath`): saves as `.xcresult` openable in Xcode for detailed results + code coverage.

### Running tests on the MBP (remote)

The MBP is a remote test runner; SSH'd `xcodebuild test` requires the `launchctl submit` recipe documented in `feedback_mbp_fast_user_switching.md` to bind the Aqua bootstrap. Direct `ssh ... xcodebuild test` aborts at `childPID > 0` — known and worked around. **MBP is reserved 2:30–4 PM daily**; ask before running tests outside that window.

---

## CI (GitHub Actions)

CI runs automatically on every push to `main` and on pull requests. Manually triggerable from the Actions tab.

**Results location**: https://github.com/musicalengineer/VideoScan/actions

Each run shows:
- Build status (pass/fail)
- Test results with pass/fail per test case
- Code coverage summary (in the step summary)
- Downloadable `TestResults.xcresult` artifact (retained 14 days)

### CI Environment

| Item | Value |
|------|-------|
| Runner | `macos-15` |
| Xcode | 16 (`/Applications/Xcode_16.app`) |
| Local Xcode | 26.4 (Tahoe) |
| Deployment target override | `MACOSX_DEPLOYMENT_TARGET=15.0` |
| Code signing | Disabled (`CODE_SIGNING_ALLOWED=NO`) |

### Why CI was failing (fixed April 17–18, 2026)

Four issues prevented CI from passing, fixed across commits `1c92f1a`–`33018b6`:

1. **Swift concurrency strictness** (`1c92f1a`): A `@Sendable` closure in `CombineSheet.swift` called `model.log(msg)` directly (a `@MainActor`-isolated method). Xcode 26.4 (local) treats it as a warning; Xcode 16 (CI) treats it as a hard error. Fix: wrap in `Task { @MainActor in ... }`.
2. **Build step masking** (`bc89d52`): The build step piped through `xcpretty || true`, masking failures. Changed to `tee` + explicit `BUILD FAILED` grep check.
3. **Deployment target mismatch** (`bc89d52`, `0def646`): Project targeted macOS 26.2 (doesn't exist on CI). Lowered to 14.0, then added `#available(macOS 15.0, *)` fallback for `AVAssetExportSession.export(to:as:)`. CI override later bumped to 15.0 to match the runner.
4. **Test host crash on headless runner** (`33018b6`): The app-hosted test target tried to launch the full SwiftUI app, which crashed with "signal trap" on the headless CI runner. Fix: replaced `@main` with `main.swift` that detects the test environment via `NSClassFromString("XCTestCase")` and runs a minimal `NSApplication.run()` loop instead. Guards added to `DashboardState.init()` and `AppDelegate.applicationDidFinishLaunching` to skip timer/cleanup code in test mode.

---

## Test Categories

Tests live in `VideoScan/VideoScanTests/`, split across multiple files. Each file groups related tests; new tests should be added to the most relevant file or a new file by domain.

| Test file | Domain |
|---|---|
| `BoundaryTests.swift` | Edge cases, overflow, empty-input handling |
| `CatalogStoreConcurrencyTests.swift` | Catalog save/load under concurrent mutation (regression for Copy Metadata crash) |
| `CatalogTests.swift` | Catalog model + persistence |
| `CombineTests.swift` | A/V mux pipeline |
| `CorrelatorTests.swift` | Audio/video pair correlation scoring |
| `DuplicateDetectorTests.swift` | Hash-based + metadata duplicate detection |
| `ExtractedModuleTests.swift` | Tests for refactored helper modules |
| `FFProbeTests.swift` | ffprobe JSON parsing + integration |
| `FormattingTests.swift` | Date/size/duration formatting |
| `MediaAnalyzerTests.swift` | Per-record scoring (junk, keeper, etc.) |
| `ModelTests.swift` | Model invariants + transitions |
| `MxfTests.swift` | Avid MXF / AVB parser |
| `ScanConfigurationTests.swift` | Settings propagation, profile application |
| `ScanEngineTests.swift` | Walk + probe pipeline |
| `TestHelpers.swift` | Shared fixtures and helpers |
| `TestMediaGenerator.swift` | Synthetic media generation for fixtures |
| `VideoScanTests.swift` | Catch-all + legacy tests (gradually being split) |

Counts and exact suites change as tests are added; this list is a navigation aid, not a contract.

### Test Fixtures

Located in `tests/fixtures/`:
- `videos/` — small test video/audio files in various formats (MP4, MXF, MOV, MKV, WAV, M4A)
- `photos/` — reference photos for face detection tests

These are checked into git and must stay under reasonable size (see `.gitignore` for size limits).

---

## Adding New Tests

Use the Swift Testing framework (`@Test`, `#expect`):

```swift
import Testing
@testable import VideoScan

struct MyFeatureTests {
    @Test func myNewTest() {
        let result = someFunction()
        #expect(result == expectedValue)
    }

    @Test func myAsyncTest() async {
        let result = await someAsyncFunction()
        #expect(result != nil)
    }
}
```

For tests touching `@MainActor`-isolated types, mark the struct itself:

```swift
@MainActor
struct CatalogStoreConcurrencyTests { ... }
```

For regression tests, prefix with the convention so they're greppable:

```swift
// regression: empty MXF tracks silently skipped (issue #42)
@Test func probeReportsEmptyTracks() { ... }
```

---

## Useful Metrics, Ranked

The raw coverage-% is noisy on this project (filename-based filter excludes `View|Window|Sheet|...`). Useful metrics in rough order of importance:

1. **Regression test count** — `grep "// regression:"` returns the number of bugs locked out by a test that was seen to fail. Every entry has a story.
2. **Core-logic coverage** — hand-curated include-list (VideoScanModel, PersonFinderModel, ScanEngine, CatalogStore, Correlator, DuplicateDetector, CombineEngine, etc.). Denominator is "stuff that matters," so the number is honest.
3. **TSan clean-runs** — count of consecutive CI runs with no race reports. Drops to zero on regressions.
4. **SwiftLint warnings** — direct signal of complexity / file size / force unwraps.
5. **Periphery findings** — dead code count.
6. **Overall xccov coverage** — keep it on the chart, but don't steer by it.

---

## Cross-references

- Branching, agent coordination, logging conventions: [`features_and_branches.md`](features_and_branches.md).
- Lifecycle/triage data model: [`media_lifecycle_manager.md`](media_lifecycle_manager.md).
- Long-term archival vision: [`media_longterm_plan.md`](media_longterm_plan.md).
- Family-recognition strategy: [`Media_Analyzer.md`](Media_Analyzer.md), `~/.claude/projects/.../memory/project_family_id_plan_5step.md`.
