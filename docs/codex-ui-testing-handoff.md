# UI Testing — handoff to codex (2026-07-07)

Rick's direction: codex owns the UI-testing track from here. Claude Code built the
first working scaffold; this doc is the starting state.

## What exists and works

Branch **`feature/ui-smoke-test` @ `8dbbeb9`** (based on `d140cab` = origin/main,
not pushed, not merged). First-ever passing UI test for this app:

- `VideoScan/VideoScanUITests/SmokeUITests.swift` — one test,
  `testLaunchAboutBoxAndQuit`: launch → main window + tab strip → About via app
  menu → About window content rendered (`about.title` accessibility id) → close →
  terminate. Passed in 14.9s on RicksM4 (Xcode 26.6, Debug).
- `VideoScan/VideoScan-UI.xctestplan` — UI-only test plan; `VideoScan-CI.xctestplan`
  is untouched and must stay unit-only.
- `scripts/run_ui_smoke.sh` — builds + runs just the smoke test. Exit 0 = pass,
  3 = Automation/TCC permission needed (prints instructions), 2 = watchdog timeout
  (default 900s, `VS_UI_SMOKE_TIMEOUT`). Derived data defaults to
  `$TMPDIR/videoscan-ui-smoke-dd` (`VS_UI_SMOKE_DERIVED_DATA` to override) — never
  use the shared default DerivedData or /Volumes/XcodeRAM.

## Isolation mechanism (do not weaken)

Two env vars, two processes:

- **`VS_UI_TEST=1`** — injected into the app under test via `launchEnvironment`.
  Wired into `TestEnvironment.detect` and its five mirrored detectors
  (`VideoScanModel.isRunningTests`, `MetadataCache`, `ScanJobsStorage`,
  `PersonFinderModel`, `appLogIsRunningUnderTests`). Arms every settings-pollution
  gate: no catalog.json load/save, no UserDefaults scan-target persist, temp
  sandboxed caches, inert CatalogSync, NullLogSink. The app launches with an empty
  catalog (also keeps the AX tree small/fast). `main.swift`'s test-HOST gate
  deliberately does NOT check it, so the full UI comes up.
- **`VS_UI_SMOKE=1`** — set on the runner by the UI test plan; `SmokeUITests`
  self-skips without it. This is why the CI plan can stay byte-for-byte unchanged
  yet can never accidentally run the smoke test.

The catalog on this machine has ~103k real records. A UI test that touches real
UserDefaults / Application Support / catalog.json is a P0 bug class here
(documented "settings pollution" incidents). Everything new must launch the app
with `VS_UI_TEST=1`.

## Known hazards

- **NEVER exec the app binary directly** (added 2026-07-10 after two SIGABRT
  core dumps at 21:15). Running
  `.../VideoScan.app/Contents/MacOS/VideoScan` straight from an agent/CLI
  context aborts inside HIServices `_RegisterApplication` before any app code
  runs — a GUI process launched outside a proper Aqua/LaunchServices context
  can't register with the WindowServer. Crash reports:
  `~/Library/Logs/DiagnosticReports/VideoScan-2026-07-10-211520*.ips`
  (parentProc: codex). Launch ONLY via XCUITest (`XCUIApplication.launch()`
  with `launchEnvironment["VS_UI_TEST"] = "1"`) or, for a manual smoke outside
  the test harness, `open -W <path>/VideoScan.app` — LaunchServices gives it a
  real GUI session. Same failure class as the MBP nightly's
  "launchctl submit for Aqua bootstrap" rule.
- **RAM-disk reap**: `AppDelegate` normally runs `RAMDisk.cleanupStaleMounts()` at
  launch and quit, which force-detaches every `/Volumes/VideoScan_Temp*` —
  including one owned by a concurrently running production instance. Under UI
  tests this is skipped (`TestEnvironment.isTestHost` guards). Keep it that way.
- **Nightly**: `scripts/nightly_local_tests.sh` passes
  `-skip-testing:VideoScanUITests` (commit `d140cab`) because the 2AM launchd job
  runs against a locked screen and the runner times out "enabling automation mode"
  after 60s. UI tests are interactive/daytime only unless that constraint changes.
  Leave the nightly skip alone.
- **TCC**: on RicksM4 automation is already granted (the smoke run needed no
  prompt). On other hosts the first run may prompt or fail with
  "Timed out while enabling automation mode" — the run script exits 3 with
  instructions.
- **Old UI test classes**: four classes predate this work and are skip-listed in
  the CI plan since 2026-05-29. Two are dead Xcode boilerplate, two are
  real-catalog end-to-end monsters that have NEVER run. Don't revive them as-is;
  anything real should be rebuilt on the `VS_UI_TEST` isolation pattern.
- Project uses synchronized file groups — adding test files needs no pbxproj
  surgery.

## Rick's roadmap for this track

1. **Next test (integration)**: launch → select a volume → type a search → click a
   video → right-click → Analyze → extract frames → delete the resulting frames →
   quit. Must run against a small fixture volume (see `tests/fixtures/videos/`),
   never the real archives, and must be non-destructive outside its own outputs.
2. **Regression UI tests** — pin fixed bugs at the UI level.
3. **Integration proof** — the app works as a whole.
4. **Performance/stress** — launch, kick an expensive operation, assert a time
   budget and no crash.

Repo test doctrine (CLAUDE.md "Feature-test checklist") applies: logic / scale /
media matrix / isolation / sensor.

## To try it

```
git checkout feature/ui-smoke-test
./scripts/run_ui_smoke.sh
```
