# Unit Tests — VideoScan

## Running Tests Locally

```bash
# Full test suite (unit + UI tests)
xcodebuild test -project VideoScan/VideoScan.xcodeproj -scheme VideoScan -destination 'platform=macOS'

# Unit tests only (faster, no UI tests)
xcodebuild test -project VideoScan/VideoScan.xcodeproj -scheme VideoScan -destination 'platform=macOS' -only-testing:VideoScanTests

# Quiet mode (just pass/fail summary)
xcodebuild test -project VideoScan/VideoScan.xcodeproj -scheme VideoScan -destination 'platform=macOS' -quiet
```

### Where are local results?

- **Terminal output**: results stream to stdout as tests run
- **Xcode derived data**: `~/Library/Developer/Xcode/DerivedData/VideoScan-*/Logs/Test/`
- **Result bundle** (if you add `-resultBundlePath`): saves as `.xcresult` which you can open in Xcode for detailed results + code coverage

## CI (GitHub Actions)

CI runs automatically on every push to `main` and on pull requests. You can also trigger it manually from the GitHub Actions tab.

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

1. **Swift concurrency strictness** (`1c92f1a`): In `CombineSheet.swift`, a `@Sendable` closure called `model.log(msg)` directly (a `@MainActor`-isolated method). Xcode 26.4 (local) treats this as a warning; Xcode 16 (CI) treats it as a hard error. Fix: wrap in `Task { @MainActor in ... }`.

2. **Build step masking** (`bc89d52`): The build step piped through `xcpretty || true`, which masked build failures. Changed to `tee` + explicit `BUILD FAILED` grep check.

3. **Deployment target mismatch** (`bc89d52`, `0def646`): Project targeted macOS 26.2 (doesn't exist on CI). Lowered to 14.0, then added `#available(macOS 15.0, *)` fallback for `AVAssetExportSession.export(to:as:)`. Later bumped CI override to 15.0 to match the macos-15 runner.

4. **Test host crash on headless runner** (`33018b6`): The app-hosted test target tried to launch the full SwiftUI app, which crashed with "signal trap" on the headless CI runner (no display server). Fix: replaced `@main` attribute with `main.swift` that detects the test environment via `NSClassFromString("XCTestCase")` and runs a minimal `NSApplication.run()` loop instead. Guards were also added to `DashboardState.init()` and `AppDelegate.applicationDidFinishLaunching` to skip timer/cleanup code in test mode.

## Test Categories

### Unit Tests (VideoScanTests)

| Test Suite | Count | What it tests |
|-----------|-------|---------------|
| `RecognitionEngineTests` | 1 | All 4 engine cases exist (Vision, ArcFace, dlib, Hybrid) |
| `FFProbeDecodingTests` | 3 | JSON parsing of ffprobe output |
| `FFProbeIntegrationTests` | 11 | Real ffprobe against test fixtures (MP4, MXF, MOV, MKV, WAV, M4A) |
| `CombineEngineTests` | 4 | ffmpeg muxing of video+audio pairs, error handling |
| `DuplicateDetectorTests` | 3 | Hash-based and metadata-based duplicate detection |
| `DuplicateDeletionSafetyTests` | 1 | Safety checks for duplicate deletion |
| `AsyncSemaphoreTests` | 1 | Concurrency limiting primitive |
| `ScanPhaseTests` | 1 | Scan phase enum completeness |
| `AvbParserTests` | 3 | Avid bin file parser edge cases |
| `MxfBinaryHelperTests` | 2 | MXF BER length decoding |
| `VolumeRootTests` | 2 | Volume name extraction from paths |
| `KeepersByGroupIDTests` | 2 | Duplicate group keeper selection |
| `VolumesWithDeletableDuplicatesTests` | 2 | Cross-volume duplicate safety |
| `CatalogScanTargetStatusExtendedTests` | 2 | Scan target state management |

### Test Fixtures

Located in `tests/fixtures/`:
- `videos/` — small test video/audio files in various formats (MP4, MXF, MOV, MKV, WAV, M4A)
- `photos/` — reference photos for face detection tests

These are checked into git and must stay under reasonable size (see `.gitignore` for size limits).

## Adding New Tests

Tests live in `VideoScan/VideoScanTests/VideoScanTests.swift`. Use Swift Testing framework (`@Test`, `#expect`):

```swift
@Test func myNewTest() {
    let result = someFunction()
    #expect(result == expectedValue)
}
```

For async tests:
```swift
@Test func myAsyncTest() async {
    let result = await someAsyncFunction()
    #expect(result != nil)
}
```

## Testing Philosophy

VideoScan is a personal media app, but the discipline applied here is deliberately
modelled on safety-critical software practice — the kind of work Rick did in medical
and industrial-controls shops for decades. The aim isn't maximum test count or a
shiny coverage number; it's to reveal a process that would hold up in environments
where silent failures hurt people.

### What we actually want to measure

Coverage-% is a weak metric on its own. A project at 90% coverage can still ship a
serious bug if the tests never exercise the failure mode. And a project at 20%
coverage can be rock-solid in the paths that matter if every known regression is
locked down by a purpose-built test.

The better question is: **of the bugs we've found in this codebase, how many have a
test that would have caught them the moment someone reverted the fix?** That number
is usually much smaller than coverage — and far more meaningful.

### Unit tests should focus on *our* logic

Don't test Apple Vision, Swift standard library, ffmpeg, dlib, CoreML, or Apple
Photos. Those are someone else's problem. Write tests for the code we wrote:

- Metadata extraction + parsing (ffprobe JSON → VideoRecord)
- Duplicate detection scoring
- Correlator matching audio-only + video-only pairs
- Combine engine's mux command construction
- Catalog state transitions
- Scan phase lifecycle
- Face-match scoring distance math
- Settings propagation into jobs

Skip:
- SwiftUI view layout
- Third-party library behavior
- File I/O (except via fixtures)
- Wall-clock / network-dependent behavior

### The regression-test-by-revert pattern

This is the workflow we use for every real bug we find:

1. **Find the bug** (reproducer in hand)
2. **Fix it** in the code
3. **Write a unit test** that exercises the buggy path
4. **Revert the fix** — run the test and confirm it FAILS
5. **Restore the fix** — confirm the test PASSES
6. **Commit fix + test together**, with the test tagged as a regression:

   ```swift
   // regression: empty MXF tracks silently skipped (issue #42)
   @Test func probeReportsEmptyTracks() { ... }
   ```

Step 4 is non-negotiable. A test that has never failed on the broken code is not
yet trusted — you don't know whether it actually catches the bug or just passes
coincidentally. Many codebases accumulate thousands of tests that have never once
failed, and no one knows which of them are real.

This is the discipline that separates defensive unit tests from theater.

### How this informs what we measure

The raw coverage-% number will always be noisy on this project — the filter in
`scripts/collect_metrics.sh` is filename-based (`View|Window|Sheet|...` excluded),
which is coarse. A refactor that moves a helper into a view-named file will drop
the number without changing what's actually tested.

More useful metrics, in rough order of importance:

1. **Regression test count** — grep for `// regression:` tags. Every entry is
   proof that a real bug is now locked out by a test that has been seen to fail.
2. **Core-logic coverage** — hand-curated include-list (`VideoScanModel`,
   `PersonFinderModel`, `ScanEngine`, `CatalogStore`, `Correlator`,
   `DuplicateDetector`, `CombineEngine`, etc.). Denominator is "stuff that
   matters," so the number is honest.
3. **SwiftLint warnings** — direct signal of code complexity / file size / force
   unwraps. Goes up when things get worse, down when we clean up.
4. **Periphery findings** — dead code count. High numbers don't necessarily mean
   broken, but they mean the codebase is wider than it needs to be.
5. **Overall xccov coverage** — keep it on the chart, but don't steer by it.

### Why this matters even for a home-video app

The point isn't that VideoScan will kill anyone. It's that the process of
accumulating proven regression tests, one bug at a time, is the same process
that makes medical-software reviews go smoothly. Every test in the suite should
have a story: *this test exists because of this bug, and it has been seen to fail
on the broken code.* That story is what a regulator or a surgeon or a post-mortem
review wants to see — and it's what tells Rick, six months from now, that the
test suite is worth trusting instead of rubber-stamping.

"We don't want to rat-hole on metrics, but we want to keep on top of spaghetti
code and regressions." — Rick, 2026-04-23.
