# Testing — categories, dimensions, the gauntlet, the nightly

*Rewritten in place. Consolidated 2026-11-01 (DECISIONS 2026-11-01) from this guide, `guides/gauntlet.md`, `practices/testing_retrospective_2026_07_05.md`, `practices/nightly-metrics-setup.md`, three machine notes from `guides/ops/` and the nightly adversarial review design; each section names its source and date, and every original is under `docs/archive/` with its name kept. The rules themselves (red first, five dimensions, "done") are in `CLAUDE.md` and `docs/PROCESS.md` §4; this guide is the how.*

How VideoScan proves itself: five **categories** of test (what a test is for), five **dimensions** a feature is tested on (logic · scale · media matrix · isolation · sensor, from the 2026-07-05 retrospective), the **lanes** that run them (`scripts/run_sensors.sh` before every merge, `scripts/run_catalog_tests.sh` for catalog work, the full suite and the Release gauntlet on the fleet in an away window, the 02:00 nightly with metrics and the adversarial review — order and gates in `docs/PROCESS.md` §4), and the machines they run on (`docs/guides/operations.md`, PROCESS §8).

## Contents
1. The five test categories · 2. The five dimensions (testing retrospective, 2026-07-05) · 3. The Release gauntlet · 4. Gauntlet: TCC and exit masking · 5. Setting up a test Mac · 6. The M1 MacBook Pro as a test runner · 7. The nightly adversarial review · 8. Metrics: what feeds the metrics page

## 1. The five test categories

*From this guide as it stood before 2026-11-01.*

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
[`testing_retrospective_2026_07_05.md`](testing.md):
logic, scale, media matrix, isolation, and a regression sensor.

### Native Find & Tag coverage

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

### UI smoke isolation and operation

The July UI-testing handoff is retired; these are its durable operational
constraints. Follow the current [Gauntlet guide](testing.md) for broader flows.

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

## 2. The five dimensions — testing retrospective (2026-07-05)

*From `practices/testing_retrospective_2026_07_05.md` (2026-07-05), whole; archived at `docs/archive/practices/`. The checklist below is the "five dimensions" CLAUDE.md rule 8 names.*

### Testing Retrospective — 2026-07-05

Triggered by three same-day escapes, all found in production use rather
than by the 2,353-test suite. Rick's questions: are bugs getting in?
are the unit tests too simplistic? how do we write better tests at
feature time? and how do we get automated integration tests that drive
the real app with real data?

#### The three specimens

| Bug | Class | Why the suite missed it |
|---|---|---|
| Test-host restored REAL scan targets (`restoreScanTargets` ungated; M5/M1 prefs contain `/`) | **Environment boundary** | Tests pass on any machine whose prefs are benign. The failure is code × machine-state, and CI machines were clean. |
| Volumes-window beachball (4 full-catalog sweeps per row per keystroke; 91% of a main-thread sample) | **Cost boundary** | The code is *correct*. No correctness assertion can go red on O(n) work in a view body. |
| Analyze fails on FFV1/Matroska masters (AVFoundation gatekeepers in front of ffmpeg-capable stages) | **Capability boundary** | Fixture monoculture: every media fixture was mp4/mov — formats AVFoundation happens to read. |

**Conclusion: bugs are not getting into function-level logic** — the
suite is good at that. They enter at boundaries the suite holds
constant: the machine, the clock, the media zoo, the cost. This matches
the walker-incident lesson (see `project_complexity_humility`):
integration-boundary bugs escape unit tests *systematically*.

#### Are the unit tests too simplistic?

Not simplistic — **narrow in the dimensions they vary**. They vary
logic inputs thoroughly while holding constant:

1. **Environment** — clean UserDefaults, present volumes, empty caches
2. **Media** — mp4/mov fixtures only (until `test_ffv1_pcm_4s.mkv`)
3. **Cost** — assertions check *what* was computed, never *how much*

#### The feature-test checklist (adopted 2026-07-05)

Applied to every feature/fix from now on (also in CLAUDE.md):

1. **Logic** — the tests we already write
2. **Scale** — if it iterates `records`, exercise at 100k synthetic
   records with an explicit time budget (pattern:
   `VolumeStatusCacheTests.aggregatePassStaysWithinBudgetAtScale`)
3. **Media matrix** — if it opens media files, run across the codec
   matrix: mp4/h264, mov/prores, mkv/ffv1+pcm, mxf, avi/dv. Synthetic
   generation is one ffmpeg line each (see the mkv fixture recipe in
   `MKVDossierPipelineTests.swift`)
4. **Isolation** — if it reads global state (UserDefaults, shared
   caches, real paths), add a poisoned-state test (pattern:
   `ScanTargetRestoreIsolationTests`)
5. **Sensor** — leave one regression sensor behind that pins the fixed
   behavior at production scale

Static tier (planned, not built): custom SwiftLint rule flagging
`records.filter/.contains/.count` inside `*View.swift` /
`*Window.swift` — crude but would have flagged the beachball at commit
time. Tier 1 of `project_bug_prevention_strategy`.

#### Integration tests that drive the real app

Assets already in hand:

- **TestDriver** launches the real app in CI (Smoke/Diagnostic)
- UI carries `accessibilityIdentifier`s (`catalog.row.analyze`,
  `volumeRow.markRetired`, …) — XCUITest-ready
- The test-host isolation seam (2026-07-05) is exactly the plumbing a
  sandboxed launch needs: one `VS_DATA_DIR`-style override and the real
  app boots against a snapshot data directory instead of the live
  catalog
- Catalog snapshot = copying catalog.json + metadata_cache.sqlite —
  cheap; media referenced by it may be offline, which integration
  scenarios must tolerate (or use a curated fixture tree)

##### The ladder (one, then two, then three…)

- **Rung 0 (prerequisite)**: every nightly logs "UI test runner
  hung/timed out" — we already own a UI test target that silently never
  runs. Diagnose and fix the hang first.
- **Rung 1**: launch app on a real-catalog snapshot; search "Donna" →
  assert results; type 20 chars in Volume notes → assert elapsed
  budget. *Catches 2 of today's 3 bugs.*
- **Rung 2**: right-click Analyze on the mkv fixture through the real
  UI; await dossier completion; assert a transcript landed. *Catches
  the third.*
- **Rung 3**: scan fixture tree → Finder-rename files → rescan →
  assert record identity survived (move-rename arc end-to-end).

Cadence: nightly on the M4 alongside TestDriver, not per-commit.
Data: an anonymized/synthetic 100k-record catalog generator plus a
small real-media fixture tree; never the live catalog.

#### Fixed today (all merged to main 2026-07-05)

- `983d4c3` test-host restore isolation (+ regression tests)
- `ee6dc98`/`a9fc171` Volumes-window beachball → VolumeStatusCache
  (+ parity, isolation, perf-sensor tests)
- `2cdb4d4` mkv/FFV1 Analyze → ffmpeg fallbacks (+ media-matrix seed
  fixture and tests)

## 3. The Release gauntlet

*From `guides/gauntlet.md` (approved 2026-09-27; updated through 2026-10-18), whole; archived at `docs/archive/guides/`. PROCESS §8 (2026-10-31) makes the M4 the default testbed.*

### Release Gauntlet — phase 1

Approved by Rick on 2026-09-27. Run only during a declared away window:

```bash
/Users/rickb/dev/VideoScan-wt-gauntlet/scripts/run_gauntlet.sh --away --machine m4
/Users/rickb/dev/VideoScan-wt-gauntlet/scripts/run_gauntlet.sh --away --machine m4 --dry-run
/Users/rickb/dev/VideoScan-wt-gauntlet/scripts/run_gauntlet.sh --away --machine m4 --only unit,regression
```

`--dry-run` prints the plan without building or launching tests. `--only`
leaves excluded stages explicitly incomplete. Machine routing is recorded;
it does not SSH to another machine. Invoke the command on the intended host.
The worker runs under `caffeinate -dimsu` during actual execution.
`--queue-only` records the sanitized metrics row locally without contacting
the remote. `--manifest PATH` supports an explicitly reviewed narrow check;
it still must account for the complete source inventory.

Phase 1 performs one Release `build-for-testing` using `VideoScan-CI`, then
uses the resulting `.xctestrun` for each selected Xcode stage, serially:
unit → regression → integration → performance → Hallie → stress → UI.
Each stage has its own log and `.xcresult`. Tests are never rebuilt between
stages. Child exit codes, monotonic elapsed time and structured XCTest
counts determine the verdict; a successful shell exit with zero tests is a
failure. Ordinary failures do not stop the remaining stages. Watchdog
termination escalates across the child process group.

**UI not run (phase 2)** is part of every phase-1 result and dashboard.
A blocked, unselected, or not-run stage prevents an all-passed summary.
Phase 1 establishes orchestration and a useful non-UI subset, not a claim
that every repository test is already safe to execute unattended.

#### Inventory and deliberate gaps

`scripts/gauntlet/manifest.json` explicitly assigns every discovered test
source file and its test declarations to exactly one stage. Swift app/UI
suites, standalone package tests, Python tests and shell suites are included.
The inventory scans source trees while excluding generated/build/fixture
folders. Validation rejects added/deleted tests, missing/duplicate assignments,
invalid stage names, selector/assignment disagreement, selectors crossing a
blocked fragment or another stage, and floors below source declaration counts.
Parameterized cases may exceed their declaration floor at runtime.

Inspect the inventory without an app build:

```bash
/usr/bin/swift -module-cache-path /private/tmp/gauntlet-swift-cache \
  /Users/rickb/dev/VideoScan-wt-gauntlet/scripts/gauntlet/inventory.swift \
  --validate /Users/rickb/dev/VideoScan-wt-gauntlet \
  /Users/rickb/dev/VideoScan-wt-gauntlet/scripts/gauntlet/manifest.json
```

New tests require a reviewed manifest assignment; the runner never guesses a
stage for an unfamiliar test. `scripts/gauntlet/manifest_drift.py` catches the
commonest drift early: the pre-commit hook (`--staged`) refuses a commit that
adds a test file without a stage in the staged manifest, and CI preflight
(`--all`) does the same over the whole tree. It only checks that each test
file is assigned; declaration lists, suites, selectors and floors are still
`inventory.swift --validate`'s job. An `assignments[].blocked_reason` and matching
`stages[].blocked` entry explain each unadapted test. Normal hosted suites
without direct filesystem/global-state dependencies are selected; tests with
unadapted positive gates, real data, persistence, or shared process state are
held back for a confinement audit. This is conservative source screening,
not an OS sandbox or proof of transitive purity.

The generated-media benchmark reuses the same built test bundle. Its manifest
sets every benchmark configuration variable explicitly, redirects its results
file into the run, and requires Homebrew ffmpeg/ffprobe. It uses the isolated
temporary directory for synthetic media. ProcessRunner stress exercises bounded
pipe floods and exit-code propagation without touching an archive.
Fixture-media stress remains blocked because it resolves persisted Donna/Ma
profiles and reference photographs; it needs an isolated profile fixture.
Adversarial model-loading stress requires a separate model/cache audit.

Hallie's safe source suites are distinct from the **strict replay** and
**advisory live testbed** modes. Both modes are explicitly blocked pending a
versioned isolated tree snapshot and log adapter; neither silently falls back
to the live tree. Advisory results, when adapted, will be `clean` or `flagged`,
never counted as verified passes. Python/shell suites remain assigned but
blocked until component build/count adapters are available.

**Package adapter (2026-10-18).** VideoScanCore package suites run too. When a
selected stage lists `package_selectors`, the runner does ONE
`swift build --build-tests -c release -Xswiftc -enable-testing` (the tests use `@testable import`; `swift test` adds it itself, `swift build` does not) of `VideoScan/VideoScanCore` into
`<run>/PackageBuild` (isolated environment, `package-build.log`), then per
stage one `swift test --skip-build -c release` with one `--filter
VideoScanCoreTests\.<Suite>/` per selector (`<stage>-package.log`). `swift
test` writes no result bundle, so counts come from the console with the
nightly's per-test rules (one ✔/✘/━/➜ or XCTest `Test Case` line per test;
issue lines and run summaries never count; no run summary at all = counts
unavailable). The package part has its own `package_expected_floor`; its
counts add to the stage's, its verdict is kept under `package`, and a package
failure, known issue, skip, build failure or missing summary keeps the stage
from passing. `inventory.swift --validate` requires `package_selectors` to
equal `VideoScanCoreTests.<suite>` for exactly the stage's unblocked package
assignments, refuses a suite split across a blocked file or another stage,
and only accepts package files under `VideoScan/VideoScanCore/Tests/`.
Sensors: `tests/test_gauntlet_package_adapter.py`.

#### Isolation

Every run creates separate App Support, catalog, preferences, cache, logs,
temporary, archive, and fixture roots. The canonical-path write allowlist
rejects writes outside these roots and symlinks escaping them; preflight
refuses the run if roots cannot be created and verified. Test-host environment
variables and patched `.xctestrun` entries carry the isolated roots.
SwiftPM and Clang module caches also receive explicit per-run paths because
their default cache lookup can ignore an overridden `HOME`.
Production data at `/Volumes/FamilyArchive`, the real catalog, and the real
log files are not fixtures.

The phase-1 guard confines runner-owned writes. Environment redirection is
not OS-enforced confinement for arbitrary test code, so unadapted suites stay
blocked. Phase 2 adds a throwaway sparse disk image (`hdiutil`) mounted under
a Gauntlet-specific name as the fixture archive volume, plus end-to-end
write-boundary checks through the app and its subprocesses. Keep this simple;
add no heavier OS sandbox unless a test demonstrates a leak.

##### What "isolation audit" means (checklist, 2026-10-18)

A suite blocked with "filesystem/global-state/subprocess isolation audit
pending" is unblocked once its source has been read against these points:

1. **Catalog / App Support** — no `applicationSupportDirectory`, no write
   through `CatalogStore.shared` (test hosts make it inert); stores and
   ledgers are built on a per-test folder (`ShowAgainSandbox`,
   `CutoverScene`, `CatalogStore(directory:)`).
2. **Preferences** — no `UserDefaults.standard` writes (the runner's `HOME`
   and `CFFIXED_USER_HOME` redirect them anyway; suites must not rely on it).
3. **Volumes** — `/Volumes/...` strings are synthetic record paths only;
   nothing under `/Volumes` is opened, stat'ed for a verdict or written.
4. **Temp** — every folder or file name carries a UUID (Swift Testing runs a
   suite's tests in parallel in one process); `TMPDIR` is the run's own.
5. **Subprocesses** — only fixed system tools (`/usr/bin/sqlite3`,
   `/usr/bin/python3`, Homebrew ffmpeg/ffprobe) on sandbox paths.
6. **No machine data, no skips** — the runner fails a stage on any skip; a
   test that reads real data or skips elsewhere moves to its own suite and
   stays blocked as a machine/real-data dependency.

2026-10-18: the catalog cutover and SQLite suites passed this audit and run
in `regression` (CatalogCutover* B1–B2.7 + Regression, P0Truth*,
AdvRescanEditDuringScan) and `unit` (CatalogPurge, CatalogStoreAsyncSave,
CatalogStoreHardening, CatalogLockRobustness, and since the second pass VerifyCatalog, CatalogStatusFreshness — and ImportToSQLite / ImportToSQLiteQuit until those suites were retired with Import to SQLite on 2026-10-20; what they held for code that stays is in CatalogPhaseHoldAndQuitTests). The two real-backup sensors
moved to `CatalogLockRealBackupTests` (blocked). The VideoScanCore catalog
suites (Store/, Commit/, Import/, Load/, CatalogFreshness,
FileBackedCatalogSource — 40 files) passed the same screen (per-test
`StoreFixture` UUID folders, synthetic `/Volumes` paths, `#filePath` source
sensors only) and run through the package adapter in `unit`, `regression`
and `performance`; `CatalogDiskFullTests` attaches its own hdiutil image
under the run's `TMPDIR`. `regression` now requires
Homebrew ffmpeg/ffprobe (P0 truth's media matrix). `P0TruthRegressionTests`
carries one tracked `withKnownIssue` (GH #327 case 5, a silent header read as
sound); the runner reports known issues as failures by design, so the
`regression` stage reads failed until that surface lands.

#### Results and publication

Local artifacts live at
`~/Library/Logs/VideoScan/gauntlet/<run-id>/`: `result.json`, stage logs,
individual `.xcresult` bundles, and the single derived-data tree. The parent
`history.jsonl` retains run history. Results include source revision and dirty
state, machine, Release binary hash, build/stage/total durations, counts,
exit codes, status and incomplete reasons.

The existing metrics pipeline receives a sanitized additive row tagged
`source=gauntlet`; failed publication stays queued for retry. The dashboard
separates Gauntlet stage/total timing and pass/fail history from nightly
averages and displays **UI not run (phase 2)**. Local fixture paths and test
output are not published as metrics.
The local `pending-metrics.jsonl` is drained on the next publication attempt.
If even durable queue creation fails, the result says `queue_failed` rather
than claiming a queued row; retry that result with `scripts/gauntlet/publish.swift`.

#### Phase 2 UI flow inventory

Real XCUITest clicks cover menus, context menus, shortcuts and sheets.
Fixture-picker seams call production handlers but do not count as click
coverage. Tests assert file hashes/streams, catalog persistence and ledger
outcomes, with failure screenshots and bounded waits.

1. Scan/add target/cancel/rescan.
2. Search/filter/sort/select.
3. Update… and options.
4. Walk Tree.
5. Initialize fixture archive.
6. Promote; verify manifest, index and ledger.
7. Duplicate discovery and filtering.
8. Delete duplicates picker, forecast/dry-run, cancel.
9. ⌘O opening and cancellation.
10. Rename, collision and cancellation.
11. Correlate and combine MXF pairs.
12. Balance Audio and stereo rejection.
13. Set date: exact, estimated and invalid.
14. **Archive Lock / Unlock / Remove.**
15. Hallie ask plus tabs, inspector, MFO, Settings and About.

Person Finder is demoted from the initial fifteen flows. Existing
`Gauntlet01PersonSearchUITests` remains inventoried as phase-2 UI work.
Synthetic `test_*` fixtures must cover MP4/H.264, MOV/ProRes, MKV/FFV1+PCM,
MXF and AVI/DV. Convert legacy Combine UI tests away from the real catalog
before enabling them.

UI setup belongs to an attended phase-2 window: automation authorization,
Developer Tools access, Accessibility/Automation grants, an unlocked GUI
session and a fixture-only launch. `caffeinate` does not unlock the screen.
Never launch UI tests on the M4 while Rick is using it. Claude reviews this
branch before any merge; phase 1 does not authorize a main-branch merge.

## 4. Gauntlet: TCC and exit masking

*From `guides/ops/gauntlet_tcc_and_exit_masking.md` (operational notes 2026-07-20 → 2026-10-05, moved out of Claude memory on 2026-10-23), whole.*

<!-- moved from Claude memory (reference_gauntlet_tcc_and_exit_masking) on 2026-10-23; operational reference, rewrite in place -->

Merged from: project_gauntlet_testing_vision.md, reference_release_unit_tests_need_testability.md (2026-10-05)

Two operational gotchas confirmed 2026-07-20 while trying to pre-validate main with the gauntlet:

0. **Gauntlet can't run UNATTENDED OVERNIGHT — needs an unlocked, awake desktop (confirmed 2026-07-20 ~23:xx).** Even WITH Rick's Terminal TCC grant that made it work in the afternoon, overnight runs exit 3 ("Timed out while enabling automation mode") consistently (not flaky — two attempts, single-flow probe too). Root cause: XCUITest/`testmanagerd` needs an active, UNLOCKED GUI session; when the M4 screen is locked/asleep overnight it can't enable automation mode. Claude can't unlock the screen. So UI automation is a "Rick-present / screen-unlocked" activity, NOT an overnight-unattended one — schedule gauntlet runs during Rick's active windows (afternoon/evening), or Rick must leave the session unlocked + `caffeinate -d`. Non-UI work (unit tests, builds, the 2AM nightly `xcodebuild test`) runs fine overnight regardless.

1. **Gauntlet (XCUITest) won't run from the Claude Code terminal on the M4.**
   `scripts/run_gauntlet.sh` exits **3** with "✗ AUTOMATION PERMISSION NEEDED — Grant Accessibility/Automation to this terminal in System Settings › Privacy & Security." The terminal/session Claude runs in lacks the Automation/Accessibility TCC grant, so `testmanagerd` can't enable automation mode (same root cause as the `VideoScanUITests-Runner` "Timed out while enabling automation mode" seen in unit runs). Needs Rick to grant it interactively, OR run on a machine/terminal that already has it. Policy is **M1-first** anyway (M4 testmanagerd bootstrap is flaky); the gauntlet UI-test track is codex-owned — delegate M1 runs to codex. See [[project_gauntlet_testing_vision]].

2. **`| tail` (or any pipe) masks the real exit code.** `run_gauntlet.sh ... 2>&1 | tail -40; echo $?` reports **tail's** exit (0), not the script's (3). The testing agent hit the identical trap with a piped `xcodebuild`. When a piped command's exit code matters, use `set -o pipefail`, capture `${PIPESTATUS[0]}`, or read the tool's own printed status line — never trust `$?` after a pipe.


**2026-09-27 — the password wall is gone on the M4:** Rick ran `sudo automationmodetool enable-automationmode-without-authentication` ("succeeded"). `automationmodetool` now reports automation mode does not require authentication. Remaining constraint: an UNLOCKED, awake GUI session (the Gauntlet runs only when Rick says he's away; `caffeinate -dimsu` for the run). Codex was asked for a Gauntlet design the same day (docs/guides/testing.md + codex proposal).

---
#### From project_gauntlet_testing_vision.md

Stated 2026-07-13. Rick's testing north star: "hey my AI friends, run my app through the gauntlet" — automated test categories that mimic his spot-testing (real mouse-click-level operations, full Release build, real data, weird/typical-human usage patterns), so that all-categories-green = ready for his human spot test, and his pass = ship. Rationale: unit tests exercise modules, not interactions; his manual spot-testing keeps finding boundary bugs but is very time-consuming and generates artificial video files.

Categories he named: (1) regression/integration tests mimicking mouse clicks (UI tests re-enabled locally), (2) stress tests, (3) accuracy benchmarks — "find Donna in these videos" against clearcut known ground truth, measuring recognition accuracy (ties to feature/person-recognition-evaluator branch + the codex evaluator NSApplication bug), (4) a mini report published into the metrics dashboard.

**Division of labor:** codex owns the UI-testing track (challenges hit re-enabling UI tests; wrote it up in docs — see `codex-ui-testing-handoff.md` (retired 2026-09-16; in git history) in repo). Rick told codex NOT to bump into Claude; codex uses worktrees; Claude+Rick sometimes work directly on main. Standing guardrail applies: check git state before edits, ask about foreign changes.

Connects to: GH #105–#108 integration-test ladder, testing retrospective 2026-07-05 (boundary bugs), TestDriver harness (natural gauntlet home — already Release + metrics publishing), [[complexity-humility]]. Claude's suggested alternative if XCUITest keeps fighting: app-internal scriptable "driver mode" channel invoking the same actions as buttons — most integration coverage, far less flake.


**2026-09-27 revival:** automation-mode password removed on the M4 (Rick ran automationmodetool + DevToolsSecurity). Codex designed it (docs/design/gauntlet-design-codex-2026-09-27.md) and is building PHASE 1 on feature/release-gauntlet: one scripts/run_gauntlet.sh --away, one Release build, timed stages unit→regression→integration→performance→hallie→stress→(ui = phase 2), manifest that fails on unassigned/zero-count tests, result.json + history.jsonl + dashboard trend. Claude's 3 changes: Person Finder flow → Archive Lock/Unlock/Remove; simple confinement (sparse disk image + path allowlist); honest "UI not run". **Rick: first run = a ~15-min SUBSET he watches (proves it + settles permissions), then the dinner-length full run. Long term the thorough Gauntlet lives on the M5 Ultra (96 GB) so it doesn't hog the M4.**

---
#### From reference_release_unit_tests_need_testability.md

`xcodebuild test -configuration Release … -only-testing:VideoScanTests` fails at compile time: the VideoScanCore package is built without `-enable-testing` in Release, so the test target cannot import it. Add `ENABLE_TESTABILITY=YES` to the command line — optimizer stays on (-O, whole-module). With it, 2026-09-25 main 44708097: 9,009 tests in 945 s on the M5, only the pre-existing RecoveryOutcomeContractTests failure.

**Why:** the build-mode policy says Release for production-parity test runs, but CI and nightly use Debug, so the gap was never hit.
**How to apply:** any Release unit-test run (gauntlet, perf baselines) passes ENABLE_TESTABILITY=YES. UI gauntlet still needs an UNLOCKED desktop ([[reference_gauntlet_tcc_and_exit_masking]]). M1 timing budgets fail under load (Spotlight/Screen Sharing); judge budgets on the M5.

## 5. Setting up a test Mac — automation mode and Xcode first launch

*From `guides/ops/test_mac_setup_automation_mode.md` (diagnosed 2026-10-21), whole.*

<!-- moved from Claude memory (reference_test_mac_setup_automation_mode) on 2026-10-23; operational reference, rewrite in place -->

Diagnosed 2026-10-21. The M5 nightly reported "zero-tests-ran: test-rc=65" because the APP's test host (not the UI-test target, which is already skipped) hung for 120 s: "Timed out … initiating control session with daemon"; "The test runner hung before establishing connection".

The cause was setup, not code:
1. `automationmodetool` said "requires user authentication". The M4 has had it password-free since 9/27; the M5 never had. Rick often saw the "allow testbed" dialog, which had already timed out by the time he saw it.
2. Xcode 27.1 was updated without first-launch: `xcodebuild -checkFirstLaunchStatus` gave rc 69, and the log said "CoreSimulator is out of date".

**Fix (Rick ran it at a real terminal, 10/21):**
`sudo automationmodetool enable-automationmode-without-authentication && sudo xcodebuild -runFirstLaunch`
Verify without sudo: `automationmodetool` (expect "DOES NOT REQUIRE"), and `xcodebuild -checkFirstLaunchStatus` (expect rc 0).

3. **Metal Toolchain:** since Xcode 27.1 it's a separate download. Without it, mlx-swift's .metal files fail and every gauntlet stage is BLOCKED (build rc 65). Install it with `xcodebuild -downloadComponent MetalToolchain` (no sudo; a few minutes) and verify with `xcrun -f metal`.

**How to apply:**
- Add both steps to the Ultra setup and to any new test Mac.
- Re-run first-launch after every Xcode update.
- `sudo` cannot prompt for a password through `!` in Claude Code (no TTY); Rick must run it in a real Terminal.

Related: [[reference_gauntlet_tcc_and_exit_masking]], [[project_m5_ultra_migration]].

## 6. The M1 MacBook Pro as a test runner

*From `guides/ops/mbp_test_runner.md` (2026-06-01 → 2026-10-05), whole. The M4 is the default testbed since 2026-10-31 (PROCESS §8); the M1 takes overflow.*

<!-- moved from Claude memory (reference_mbp_test_runner) on 2026-10-23; operational reference, rewrite in place -->

Merged from: feedback_mbp_fast_user_switching.md (2026-10-05)
Remote test machine: M1 Max MacBook Pro
- Hostname: ricksm1.local (verified 2026-06-01; previous `ricksmacbookpro.local` no longer resolves on the network)
- User: rickb
- Repo path on MBP: `~/dev/VideoScan` (matches Mac Studio; verified 2026-06-01 — older `~/developer/VideoScan` path is gone)
- SSH: `ssh rickb@ricksm1.local`
- Use for: xcodebuild test runs to avoid stealing focus on Mac Studio

#### Workflow — sync code via git, never rsync

Rick's hard rule: **use git push/pull via origin, do not rsync working trees.**
Confirmed 2026-05-02 after I tried rsync — got bounced.

Standard sequence to run tests on a feature branch:
1. Local: commit on the feature branch (ask first per CLAUDE.md unless explicitly authorized).
2. Local: `git push -u origin <branch>`.
3. MBP: `ssh rickb@ricksm1.local 'cd ~/dev/VideoScan && git fetch origin <branch> && git checkout <branch>'`.
4. MBP: `xcodebuild test -project VideoScan/VideoScan.xcodeproj -scheme VideoScan -destination "platform=macOS" -only-testing:VideoScanTests` (skip UI tests per test-etiquette memory).

**Why git over rsync:** clear history of what was tested, no working-tree drift between machines, and the MBP can be left dirty-free at HEAD of whatever branch was last checked out.

**Why:** dual-monitor focus stealing on Mac Studio when xcodebuild runs UI tests; MBP isolates that.
**How to apply:** any time tests should run remotely, commit + push + ssh-fetch — never rsync the working tree.

#### When NOT to use the MBP for tests

Rick uses the MBP for non-VideoScan work too. Established 2026-05-04:
- **2:30–4 PM daily**: MBP is reserved for Rick's own use (lunch + afternoon).
  Do NOT run xcodebuild tests on the MBP during this window.
- **Outside that window**: still ASK before running tests on the MBP unless
  Rick has just said it's free for a specific time. Don't assume availability.
- The Mac Studio is always fine for tests (focus-steal cost accepted when
  Rick isn't actively working on it).

Future: Rick is getting a new M5 in May 2026; once that's set up the M1 MBP
will be less central as a test runner. This rule applies until then; revisit
when the M5 lands.

**2026-08-29 gotcha:** app-hosted `xcodebuild test` over ssh on ricksm1 FAILS when the console user is `donna` (fast user switching): rickb has no GUI launchd domain → testmanagerd "Failed to establish communication with the test runner". Symptom earlier: "Executed 0 tests" tails. Use `ricksm5.local` (rickb has a GUI session) or wait for rickb to be the console user on the M1. Headless Core `swift test` is unaffected.

---
#### From feedback_mbp_fast_user_switching.md

Symptom: `ssh rickb@ricksmacbookpro.local 'xcodebuild test ...'` exits 134 with
`DVTAssertions: ASSERTION FAILURE in IDELaunchServicesLauncher.m:418 — Assertion
failed: childPID > 0`. Build phase succeeds, "Testing started" prints, then the
test runner spawn aborts.

Root cause: Xcode 26.x's IDELaunchServicesLauncher needs the user's *Aqua* launchd
domain to spawn the app-hosted test runner. SSH sessions land in a different
launchd domain. Even with rickb on the foreground console, direct invocation
fails. `caffeinate -is`, `ssh -t`, and clean DerivedData do not help.

**Fix (verified working, recipe from claude-4-6 on 2026-05-02):** wrap the
xcodebuild call in `launchctl submit`, which schedules it via launchd and runs
it in the right context.

```bash
# From Mac Studio over SSH — kick off (returns immediately):
ssh rickb@ricksmacbookpro.local 'launchctl submit -l com.videoscan.test -- bash -c "cd ~/developer/VideoScan && xcodebuild test -project VideoScan/VideoScan.xcodeproj -scheme VideoScan -destination \"platform=macOS\" -only-testing:VideoScanTests > /tmp/unit_test_output.txt 2>&1"'

# Poll for completion (blocks until done):
ssh rickb@ricksmacbookpro.local 'while ! grep -q "TEST SUCCEEDED\|TEST FAILED" /tmp/unit_test_output.txt 2>/dev/null; do sleep 10; done; grep -c "passed" /tmp/unit_test_output.txt; grep "TEST SUCCEEDED\|TEST FAILED" /tmp/unit_test_output.txt; launchctl remove com.videoscan.test 2>/dev/null'
```

For full suite including UI tests, drop `-only-testing:VideoScanTests`.

**Why:** Verified empirically 2026-05-02 — five direct-SSH attempts failed identically.
**How to apply:** Always wrap MBP-side xcodebuild test in `launchctl submit -l <label> -- bash -c "..."`,
then poll a log file for the SUCCEEDED/FAILED line. Direct `ssh ... xcodebuild test` is broken.
Skip the MBP entirely if Rick is using it (background videos, etc.) — run on Mac Studio.

## 7. The nightly adversarial review

*From `design/nightly_adversarial_review_design_2026-10-01.md`, whole. It was written as a proposal; it is built (`tools/adversarial_nightly.py`, its invariants in `docs/practices/invariants.md`, sensor `tests/test_invariants_coverage.py`). The status words inside are the 10/01 text.*

### Nightly adversarial review — design (PROPOSED, 2026-10-01)

Status: **PROPOSED** — awaiting Rick's approval. Author: Claude (Manager) via Plan agent. No code yet.

#### Summary
1. A launchd job on the M4 (not GitHub) reviews each day's merges to local `main` — GH never sees unpushed work, and the claude/codex logins live there.
2. Scope = data-risk + truthfulness files touched since the last successful run, pure renames/tests/docs dropped; nothing in scope → one line, exit 0.
3. Per-folder invariants live in `docs/archive/practices/invariants/<Folder>.md` (not in source folders — synced-group/resource clash risk).
4. `tools/adversarial_nightly.py` auto-builds the brief in the #230 brief's shape and output contract; reuses `codex_review.py`'s parser and cycle records.
5. Tier A nightly: headless `claude -p`, Opus 5.5, effort high (xhigh for data-risk), read-only tools, dollar cap.
6. Tier B: codex only for P0/P1 in data-risk folders (≤1/night, ≤4/week) + one bundled Sunday sweep.
7. Every P1/P2 carries a drafted red test; a 05:30 sandboxed scratch worktree runs them and labels each finding `confirmed-red` / `unconfirmed`.
8. Output: untracked review doc + ledger row; after a shadow week, `adversarial-review` issues; a 🔴/🟢/⚪ morning-brief line; Manager closes or declines each finding.
9. Failed nights are never silent: START/OUTCOME log, `failed` phase in review-cycles.json, morning 🔴; findings-per-dollar logged every run.
10. Rollout: shadow 10-02 → 10-08, then filing. Keep/kill = kept P1/P2 per week (closed against a pinning test) + precision.

#### 1. Trigger and scope
- **Placement:** two LaunchAgents on the M4, cloned from `com.videoscan.nightly-review.plist` (same PATH, `Nice 10`, log `~/Library/Logs/VideoScan/adversarial_review_launchd.log`):
  - `com.videoscan.adversarial-review` 00:30 — Tier A (cloud-side, light on the M4, done before the 02:00 nightly).
  - `com.videoscan.adversarial-confirm` 05:30 — red tests → Tier B → filing (after `nightly_guarded.sh` ~02:00–03:30 and `nightly_review.sh` 04:30).
  - No M1/M5 failover (they may be asleep/away).
- **Range:** `state/last_sha..main`, baseline advanced only on success (copied from `nightly_review.sh`), so a failed night carries its SHAs forward.
- **Files:** `git diff --name-status -M90% <range>` → drop pure renames (R100; the 09-29 layout move would otherwise flood scope), `*Tests*`, `docs/`, non-Swift → intersect with `paths:` globs in `docs/archive/practices/invariants/*.md`.
- **Buckets:** data-risk (docs/guides/developer.md §Data-risk + `CyberBrainWriter.swift`); truth (Hallie answer/executor, date resolution, Core genealogy incl. `Gedcom*`, `*Kinship*`, `LineageTrail`, `LifeAndTimes/`).
- **Load (14-day sample):** 0–5 data-risk and 0–15 truth files/day; about half of nights have something in scope.
- **Gap found:** source_layout did not list `RecordFinderFiling.swift` / `ResearchStore.swift` — where codex found the #230 P1s. Add a pytest sensor `tests/test_invariants_coverage.py`: any Swift file in a data-risk folder that writes via `FileManager` / `write(to:)` / `CyberBrainWriter` must match a glob.

#### 2. Auto-generated brief (`tools/adversarial_nightly.py brief`)
- **Invariants files:** `docs/archive/practices/invariants/{Archive,MediaOps,FamilyTree,ArchiveAngelPromote,Volumes,Hallie,Dates,Genealogy}.md` — YAML front matter (`tier`, `paths`), numbered invariants (ARCH-1…), and "Known and accepted (do not report)". Seed from existing briefs (#230's 7 → FT-1..7).
- **Brief sections (order of the #230 brief):** (a) range + merge subjects; (b) files in scope with changed `func` names + "do not explore outside"; (c) callers via `git grep -n -w`, ≤8/symbol, read-only; (d) invariants + known-accepted; (e) already-reported fingerprints (open issues, prior review docs touching the same files); (f) tests already run (latest metrics testdriver row for main + "green" clauses of merge subjects); (g) coverage/logging directive; (h) privacy line; (i) output contract.
- **Output contract:** existing `Credits spent: … | Finding count: N` first line and `Verdict:` line (so `codex_review.parse_output()` / `validate_brief()` work unchanged), plus per finding `### F<n> — P<0-3> — <title>`, `- File:`, `- Invariant:`, `- Key: <path>#<symbol>#<ID>`, and a ```swift red test tagged `// target:` and `// test: Suite/testName`; "read, no findings" per clean file.
- **Size cap:** ≤12 files per brief; split into ≤3 briefs by folder; overflow listed as "NOT REVIEWED" (visible, never dropped).

#### 3. Tiering
- **Tier A** (verified: `~/.local/bin/claude` 2.1.287, claude.ai OAuth login; not on launchd PATH → absolute path). cwd = detached scratch worktree at head:
  `~/.local/bin/claude -p --model claude-opus-5-5 --effort high --restricted --tools "Read,Grep,Glob" --strict-mcp-config --permission-mode dontAsk --no-session-persistence --max-budget-usd 10 --output-format json < brief.md` (`--effort xhigh` for data-risk).
  - `--restricted` ignores project settings, so the SessionStart morning hook does not fire at 00:30 and eat Rick's morning digest. No `--bare` (API-key only; this account is OAuth).
- **Tier B:** `tools/codex_review.py --title "adv <date>" --range … --brief <codex brief> --doc docs/reviews/adversarial/<date>-codex.md --timeout 1800`. Gate: P0/P1 in data-risk; ≤1/night, ≤4/week; Sunday 05:30 bundled weekly sweep if the week touched data-risk. Codex brief = Tier A brief + "claims to confirm or refute (with red-test outcome)" + "find what this reviewer missed".
  - **Policy change needed:** CLAUDE.md's codex spend policy says Rick triggers each pass; gated nightly/weekly passes would need to be pre-approved there (Rick's call).
- **Dedupe:** fingerprint = sha1(path + symbol + invariant ID), no line numbers; `<!-- adv-fp:<hash> -->` in issue bodies; checked against `gh issue list --label adversarial-review --state all`, `docs/reviews/adversarial/declined.jsonl`, and prior review docs by file+symbol → "dup of #N".

#### 4. Output
- **Doc:** `docs/reviews/adversarial/<YYYY-MM-DD>.md` (header like `write_doc()`: range, tier, model/effort, tokens, notional $, findings by severity, confirmed-red, verdict; then findings, then brief). Written untracked; the Manager commits it with triage decisions — no unattended commits to main. Each run is recorded via `codex_review.new_cycle/update_cycle` for the status line.
- **Issues:** via the nightly findings→issues tool (in progress in parallel) with labels `adversarial-review` + `confirmed-red|unconfirmed`; bodies scrubbed of names, outside paths, transcriptions.
- **Morning brief:** ~15 lines in `.claude/scripts/session_morning_hook.sh` reading `~/Library/Logs/VideoScan/adversarial-review/latest.json`: `🔴 2 P1 (1 confirmed-red), 1 P2 → doc`, `🔴 FAILED: <reason>`, `🔴 did not run`, `🟢 clean, N files`, `⚪ nothing in scope`.
- **Triage:** `adversarial_nightly.py close --fp <h> --test <Suite/test> --sha <fix>` / `decline --fp <h> --reason "…"`.

#### 5. Verifying claims (05:30)
- Each drafted test → its own `AdvDraft_<hash8>.swift` in a fresh scratch worktree at head. Core: `swift test --package-path … --filter`. App: one batched `build-for-testing` / `test-without-building -only-testing:VideoScanTests/<Suite>/<test>` with its own derivedData, wrapped in the process-group watchdog lifted from `nightly_local_tests.sh`.
- `confirmed-red` = compiled and failed at an `#expect`/`#require` naming the claim; `unconfirmed` = passed / didn't compile / crashed / timed out (reason recorded).
- **Safety:** static lint rejects drafts mentioning `/Volumes`, `applicationSupportDirectory`, `homeDirectoryForCurrentUser`, `FamilyArchive`, `00_Index`, `Process(`, `URLSession`, or absolute paths outside `temporaryDirectory`; `sandbox-exec` profile `scripts/adversarial/redtest.sb` denies writes to `/Volumes`, App Support/VideoScan, `~/Pictures`, archive roots, and non-loopback network; 10 min/test, 60 min total; skip if `nightly_local_tests.sh` still runs or a `(VideoScan)` exit corpse exists; no UI tests, no app launch; worktree removed, at the latest by 09:30.

#### 6. Budgets, stop rules, failures
- Tier A ≤$10/brief notional × ≤3 briefs; 40 min wall clock per brief; Tier B per its caps; all done by 09:30.
- Stop rules: >5 P1 in one run → treat as noisy, skip Tier B, flag; 3 failed nights in a row → self-disable (flag file) + morning 🔴 "disabled".
- START/OUTCOME to `~/Library/Logs/VideoScan/adversarial_review.log` (one sink). Ledger `~/Library/Logs/VideoScan/adversarial-review/ledger.jsonl`: date, range, tier, model, effort, files, tokens, cost/credits, findings by P, confirmed-red, later kept/declined → findings per dollar.
- Failure: `failed` phase, morning 🔴, baseline not advanced; a job that never fires is caught by the missing OUTCOME line.

#### 7. Rollout and keep/kill
- Shadow 10-02 → 10-08: doc + ledger + morning line only; no issues, no codex. Turn on filing + Tier B on 10-09 if the shadow docs read sanely.
- Metric (reviewed with the end-of-October codex policy review): kept P1/P2 per week and precision = kept / (kept + declined). Keep at ≥1 kept P1/P2 per week and ≥40% precision; drop to weekly or kill after two zero-kept weeks or precision <25%. Also track later codex/QA misses in files the nightly reviewed.

#### Not verified on this machine
- `claude -p` with OAuth under a LaunchAgent (keychain access while locked); `total_cost_usd` meaning on a subscription and weekly-limit accounting; `--restricted` with OAuth; `sandbox-exec` with xcodebuild/SwiftPM (module caches in ~/Library may need allows); findings→issues tool interface (in progress); codex credits (not exposed); whether `.md` in synced groups gets bundled. No headless claude/codex call was made during design.

#### Critical files
`tools/codex_review.py`, `tools/model-fitness/nightly_review.sh` (+ its plist), `docs/guides/developer.md`, `.claude/scripts/session_morning_hook.sh`, `scripts/nightly_local_tests.sh`, `docs/reviews/briefs/230-filing-brief.md`, `docs/reviews/codex/codex-review-record-finder-filing-2026-10-01.md`.

## 8. Metrics: what feeds the metrics page

*From `practices/nightly-metrics-setup.md` (rewritten 2026-10-02; sections to 2026-10-07), whole.*

### Metrics: what feeds the metrics page

Rewritten 2026-10-02 when the one metrics page replaced the old dashboard. The
previous version of this file described the TestDriver 2 AM job
(`.claude/scripts/nightly-testdriver.sh`), which stopped running in June 2026
and was removed; it is in git history if ever needed.

**The page:** https://musicalengineer.github.io/VideoScan/ (source `docs/index.html`,
served by GitHub Pages from `main:/docs`). It is static: at load it fetches the
`metrics` branch from raw.githubusercontent.com and the public GitHub Actions
API. No login, works from a phone. Anything older than 36 hours is marked STALE;
a metric with no data says "no data yet", never zero.

#### Streams on the `metrics` branch

| File | Written by | When |
|---|---|---|
| `metrics/history.jsonl` | `.github/workflows/ci.yml` running `scripts/collect_metrics.sh` | every push to main |
| `metrics/static_analysis.jsonl`, `metrics/nightly_findings_latest.json` | `.github/workflows/nightly-analysis.yml` (aggregate job) | GitHub nightly |
| `metrics/testdriver.jsonl` | `scripts/nightly_local_tests.sh` (launchd `com.videoscan.nightly-tests`), TestDriver's Publish, the gauntlet | 2 AM nightly; ad hoc |
| (same rows, additive `core_*` fields, 2026-10-18) | the nightly's VideoScanCore lane: `swift test -c release` on the package before the app build — `core_status`, `core_reason`, `core_passed/failed/skipped/total`, `core_known_issue_tests`, `core_elapsed_s`, `core_rc`, `core_failed_names`; a red Core lane turns the row red with reason `core-<why>` | 2 AM nightly |
| `metrics/coverage.jsonl` | `tools/publish_metrics.py`, called by `tools/nightly_coverage.py` | after the 4 AM coverage run |
| `metrics/adversarial.jsonl` | `tools/publish_metrics.py`, called by `tools/adversarial_nightly.py confirm` | after the 05:30 confirm |
| `metrics/codex_reviews.jsonl` | `tools/publish_metrics.py` (parses `docs/reviews/codex/*.md` headers) | with either of the two above |
| `metrics/search_benchmarks.jsonl` | `scripts/publish_search_benchmarks.py` | when the benchmark is run |
| `metrics/complexity.jsonl`, `metrics/complexity_debt_latest.json`, `metrics/complexity_baseline_proposed.json` | `nightly-analysis.yml` `complexity` job → `aggregate` (`scripts/complexity_metrics.py`) | GitHub nightly |
| `metrics/exposure.jsonl`, `metrics/exposure_new_latest.json`, `metrics/exposure_files_latest.json`, `metrics/problem_files_latest.json` | same job (`scripts/exposure_metrics.py`, `scripts/problem_files.py`) → `aggregate`, privacy-gated by `tools/publish_metrics.py --validate` | GitHub nightly |

#### Complexity and tech debt (2026-10-05, GH #281)

- **Nightly (report only).** `scripts/complexity_metrics.py` runs lizard 1.22.1 over
  Swift (`VideoScan/VideoScan`, `VideoScanCore/Sources`, `swift_cli`) and Python
  (`scripts`, `tools`). Per folder (same keys as `swift_by_folder`): functions, mean
  CCN, CCN > 15, NLOC > 80, files > 800 lines; totals; top 15; duplication (lizard
  `-Eduplicate`, pure Python). The ratchet lists NEW offenders (CCN > 15 or NLOC > 80,
  not on the baseline) and WORSE ones; the morning digest prints them plus any gate
  override from the last 48 h. Stock lizard ignores Swift computed properties; the
  script teaches it `var body: some View {` so SwiftUI bodies are measured.
- **Gate (blocking).** `scripts/complexity_gate.py --staged` in the pre-commit hook and
  `--all` in CI preflight: a function over CCN 30 / 300 lines that is new or worse than
  the baseline, or a new `swiftlint:disable` of cyclomatic_complexity /
  function_body_length / file_length / type_body_length, fails. Escape hatch:
  `COMPLEXITY_OVERRIDE="reason" git commit …`, appended to
  `ci/baselines/complexity_overrides.jsonl` (staged into the commit; CI honors it).
- **CCN 15 excess ratchet (blocking, 2026-10-07).** Functions over CCN 15 went 277 → 345
  in ten nights while the count over 30 stayed flat. CCN is one signal for flagging a
  module, not a target to obey, so the ratchet watches the EXCESS, the sum of
  max(0, CCN − 15), not the number of functions over 15. Splitting `PrunePlan.plan`
  (CCN 52, excess 37) into two honest 26s brings it to 22 and passes; a 40 plus a 20
  (25 + 5 = 30) passes too. Pre-commit: the touched files' total excess may not rise from
  HEAD to the staged copy (`RATCHET`; moving a function between touched files or
  splitting a file passes), and no function above 15 may grow, even if another one in the
  same commit shrank more (`RATCHET-WORSE`). CI: the whole tree's total excess may not
  exceed `ci/baselines/complexity_ccn15_excess.json` (2,403 on 2026-10-07). The same
  `COMPLEXITY_OVERRIDE` covers it and records the excess it let in, which CI credits back.
- **Baseline.** `ci/baselines/complexity_debt.json`, plus the CCN 15 total excess in
  `ci/baselines/complexity_ccn15_excess.json`. Both only shrink: the 2 AM nightly
  (`scripts/complexity_baseline_nightly.py`) commits the shrink; `python3
  scripts/complexity_metrics.py --shrink-baseline` applies it locally. Re-grow only
  deliberately with `--update-baseline` / `--update-ccn15-excess`, and say why in the commit.
- After pulling this change, run `scripts/install-git-hooks.sh` once per clone: the
  hook in `.git/hooks` is a copy.

##### Splitting a function

CCN is a signal, not the goal. When the gate asks for a function to be split, split it
along a real concept: an enum whose cases carry the branching, a value type that owns
its own rules, a focused protocol, or a pure function that makes one named decision
(`shouldKeep`, `pickKeeper`). A table of cases (pattern → action as data) often replaces
a long `switch`/`if` ladder outright. Each piece should be testable on its own and named
for WHAT it decides, not WHEN it runs. Never cut a function into `step1` / `step2` /
`part3` helpers that pass the same half-dozen locals around: CCN drops on paper and the
code gets harder to read.

#### Over-exposure and problem files (2026-10-07)

- **Over-exposure (report only, no gate).** `scripts/exposure_metrics.py` finds internal
  declarations in app Swift that could be `private` (used only in their own file) or were
  widened for a `T+*.swift` split (used only from files extending the same type). Tests
  that `@testable import` count as users. Rules, skips and the collision policy are in
  the script's docstring. Ratchet: `ci/baselines/exposure_baseline.json`, shrink-only
  (`--shrink-baseline`; regrow deliberately with `--update-baseline`). NEW ones are 🔴 in
  the morning digest.
- **Problem files.** `scripts/problem_files.py` joins complexity offenders (baseline),
  tonight's new/worse, file length, the exposure counts and 7-day churn into one score
  (formula in its docstring); the digest prints the top 15 and the nightly refactor picks
  from it.
- Both run in the `complexity` job; `aggregate` publishes `metrics/exposure.jsonl`,
  `exposure_new_latest.json`, `exposure_files_latest.json` and
  `problem_files_latest.json` only after `tools/publish_metrics.py --validate` passes.

Why `coverage_logic_pct` / `swiftlint_*` in `history.jsonl` looked broken: coverage is
deliberately off in ci.yml (`-enableCodeCoverage NO`, 2026-09-26), and
`collect_metrics.sh` turned "no data" into `0` (fixed: now null). SwiftLint left ci.yml
on 2026-06-02 (5d2e9c23); its nightly count is `swiftlint_strict` in
`static_analysis.jsonl`, so the per-push fields are null by design.

#### The local publisher (`tools/publish_metrics.py`)

Coverage and the adversarial ledger exist only on the M4, so one publisher pushes
a sanitized copy of them.

- **Privacy gate.** The repo and page are public. Every row is checked against an
  allowlist schema before anything is written: numbers, dates, source-folder
  names, tool names and severity keys only. Finding titles, paths, test names,
  hosts and person names never leave the machine. A row that fails the gate stops
  the whole publish (exit 3).
- **Git.** It works only in its own detached worktree,
  `~/Library/Caches/VideoScan/metrics-publish-wt`. The main checkout is asked
  only to `worktree prune` and `worktree add` (to create it). It pushes
  `HEAD:refs/heads/metrics` and never forces it; on a rejected push it refetches and
  retries.
- **Logs.** The last stdout line is `OUTCOME …`; the callers write it to
  `coverage.log` and `adversarial_review.log`.

```bash
python3 tools/publish_metrics.py --dry-run          # show exactly what would be published
python3 tools/publish_metrics.py                    # publish now
VIDEOSCAN_PUBLISH_METRICS=0 …                       # turn it off for one run
```

Tests: `tests/test_publish_metrics.py` (privacy proof, fake-git seam, one real-git
round trip against a local bare repo) and `tests/test_metrics_dashboard.py`
(runs the page's script under node).

#### Morning digest

`scripts/morning_metrics.sh` (run by `.claude/scripts/session_morning_hook.sh`)
prints the per-host test table from the same branch in the terminal.
