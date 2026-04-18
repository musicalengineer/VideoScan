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
