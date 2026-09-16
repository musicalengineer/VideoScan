# VideoScan testing categories

VideoScan uses five complementary test categories. A feature may need more
than one; these are purposes, not mutually exclusive directories.

1. **Unit** — one pure function, value type, state transition, or injected
   seam. Fast and deterministic; no real app or media decoder is required.
2. **Regression** — a permanent sensor for a specific escaped defect. Its
   name/comment states the prior failure and its assertion pins the corrected
   behavior.
3. **Integration** — multiple production components exercised together,
   including real ffmpeg/AVFoundation I/O or the real app through XCUITest.
   The Gauntlet is the UI integration/regression layer.
4. **Performance** — repeatable timing or resource measurements that publish
   a baseline (records/s, files/s, MB/s, frames/s, memory) and, where stable,
   enforce a deliberately documented budget. Use Release for production
   parity.
5. **Stress** — high repetition, concurrency, corpus size, or resource
   pressure intended to expose leaks, races, stalls, and nonlinear behavior.
   Stress tests are opt-in and run on an assigned fleet machine.

Every feature/fix also follows the orthogonal five-dimension checklist in
[`testing_retrospective_2026_07_05.md`](testing_retrospective_2026_07_05.md):
logic, scale, media matrix, isolation, and a regression sensor.

## Native Find & Tag coverage

- `RecipeScoringTests` — unit pins for face-tier gates, centroid math, top-K
  aggregation, AUC, and deterministic era-gallery construction.
- `NativeRecipeMediaMatrixTests` — regression/integration coverage using real
  synthetic media: MP4/H.264, MOV, MKV, MKV/FFV1+PCM, MXF, AVI, raw DV, MPEG
  transport stream, and WebM. Catalog-eligible media must yield sampled frames;
  a nonexistent file must remain an honest error.
- `NativeRecipeMediaStressTests` — opt-in 100-scan mixed-container loop with
  files/s, MB/s, and sampled-frames/s output plus an adjustable time budget.

Enable the stress test with its fleet-local marker (environment variables set
on `xcodebuild` are not automatically inherited by the macOS test host):

```bash
mkdir -p /tmp/vs-codex-stress
touch /tmp/vs-codex-stress/native-recipe-stress-enabled
xcodebuild test \
  -project VideoScan/VideoScan.xcodeproj \
  -scheme VideoScan-Release \
  -only-testing:VideoScanTests/NativeRecipeMediaStressTests
```

Optional `KEY=value` overrides go in
`/tmp/vs-codex-stress/native-recipe-stress.conf`:
`VIDEOSCAN_NATIVE_RECIPE_STRESS_COUNT` and
`VIDEOSCAN_NATIVE_RECIPE_STRESS_BUDGET_SECONDS`.

Run this on an explicitly assigned noninteractive fleet machine. Do not launch
the app or UI tests on Rick's active M4.

## UI smoke isolation and operation

The July UI-testing handoff is retired; these are its durable operational
constraints. Follow the current [Gauntlet guide](gauntlet.md) for broader flows.

- Rick's M4 is interactive until he explicitly declares a quiet window. Route
  app-host tests, UI tests and smoke runs to an assigned M5/M1 or an authorized
  quiet window. An app-host XCTest run can launch VideoScan too.
- The UI test must inject `VS_UI_TEST=1` into the **app's launch environment**.
  This isolates app state and prevents normal stale-RAM-disk cleanup from
  interfering with production scratch mounts. Use synthetic fixtures and
  isolated defaults, caches, catalog and logs; never the family's live archive.
- `scripts/run_ui_smoke.sh` enables the smoke runner through
  `TEST_RUNNER_VS_UI_SMOKE=1`. `VS_UI_SMOKE_DERIVED_DATA` selects dedicated build
  output and `VS_UI_SMOKE_TIMEOUT` controls the watchdog (default 900 seconds).
  Exit 0 means success, 2 means timeout, and 3 means Accessibility/TCC blockage;
  preserve the log and distinguish blockage from a product regression.
- Use XCUITest or an explicitly authorized normal app launch in the proper
  graphical session. Launching an app binary directly from a shell is not a
  substitute for that environment. TCC authorization is machine/session state,
  not something a previous successful build proves.
- Headless nightlies must exclude UI suites unless explicitly routed to an
  unlocked, authorized UI runner. A green build does not prove UI execution.

These notes preserve the safety lessons from `codex-ui-testing-handoff.md`;
its old feature-branch checkout commands and historical pass counts are obsolete.
