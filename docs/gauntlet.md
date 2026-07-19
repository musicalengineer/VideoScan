# The Gauntlet — automated UI regression flows (v1)

"Run the gauntlet" = drive the real app through Rick's five-item spot-test
ritual, automatically, before a human ever spot-tests. Built 2026-07-19 on
branch `feature/gauntlet-v1`.

## What v1 covers

Five independent XCUITest flows in `VideoScan/VideoScanUITests/Gauntlet/`,
each an exact encoding of one item in Rick's ritual:

| Flow | Class | What it proves |
|------|-------|----------------|
| 1 | `Gauntlet01PersonSearchUITests` | Person Finder scan on a synthetic fixture folder completes; results table shows the genuinely-found video; the Match Confidence Floor (default 7) refuses a brief-glimpse video and says so in the job console (exact `belowFloorSummaryLine` wording). |
| 2 | `Gauntlet02CatalogSearchUITests` | Scan-in via Scan All; the catalog search field filters rows in and back out. |
| 3 | `Gauntlet03SetDateUITests` | Inspector "WHEN WAS THIS?": "1992" + Best guess → Date column "1992 (est.)"; "6/14/1992" + I'm sure → canonical "1992-06-14", no (est.); garbage → the friendly rejection line, saved date untouched. |
| 4 | `Gauntlet04BalanceAudioUITests` | Two-pair DV (12-bit camcorder shape): right-click → Balance Audio… → job reaches done in the MFO window and `<stem>_balanced.mov` lands on disk. True-stereo fixture: the sheet explains ("True stereo … Nothing to fix.") and offers NO Balance button. |
| 5 | `Gauntlet05NavigationUITests` | All six tabs, inspector toggle, MFO window from the Window menu, About window shows the live `BuildInfo.summary` (v2.6 + git hash). |

Every flow:

- runs against **per-run temp fixtures** synthesized with ffmpeg. Argument
  construction is pure and unit-tested (`GauntletFixturePlan` in
  VideoScanCore; tests in `VideoScanCore/Tests/.../GauntletFixturePlanTests`);
  the UI runner only spawns ffmpeg (`GauntletFixtures.swift`).
- is **independently runnable** (`./scripts/run_gauntlet.sh <ClassName>`).
- **fails with a screenshot** attached to the .xcresult
  (`GauntletTestCase.record(_:)`).
- is **isolated**: `VS_UI_TEST=1` flips every in-app test-host gate (no
  real catalog, POI store / PF cache / settings / logs all redirected),
  plus the app launches with a throwaway `HOME`/`CFFIXED_USER_HOME` so
  even `@AppStorage` writes land in a per-run sandbox. Real volumes, the
  real catalog, and real prefs are never touched.

### Launch-argument seams

XCUITest can't drive NSOpenPanel, so three transient argument-domain seams
(read ONLY when `TestEnvironment.isTestHost`, never persisted —
`GauntletSeams.swift`) stand in for folder pickers:

- `-gauntletScanTarget <dir>` — pre-adds a catalog scan target (the UI
  still clicks Scan All itself)
- `-gauntletPOIName <name>` / `-gauntletPOIRefPath <dir>` — installs a
  saved POI profile in the (redirected) POI store
- `-gauntletRecentPath <dir>` — surfaces the fixture folder in the Person
  Finder volume picker's "Recent" section

## How to run

Local (any machine you're *sitting at* — UI tests own the screen):

```bash
./scripts/run_gauntlet.sh                         # all five flows
./scripts/run_gauntlet.sh Gauntlet04BalanceAudioUITests   # one flow
```

The exact xcodebuild line the script wraps (Debug per the build-mode
policy — the Gauntlet validates flows, not the optimizer):

```bash
xcodebuild test \
  -project VideoScan/VideoScan.xcodeproj \
  -scheme VideoScan \
  -testPlan VideoScan-Gauntlet \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$TMPDIR/videoscan-gauntlet-dd" \
  TEST_RUNNER_VS_GAUNTLET=1
```

The `VideoScan-Gauntlet` test plan sets `VS_GAUNTLET=1` on the runner;
without it every flow self-skips (same positive-gate pattern as
SmokeUITests / `VS_UI_SMOKE`). The CI plan is untouched — units stay
unit-only.

### Remote on the M1 (the primary execution target)

Same recipe as the MBP test runner (see `docs/development_practices.md`
§ "Running tests on the MBP" and memory `feedback_mbp_fast_user_switching`):
**sync via git only** (never rsync), and wrap the run in `launchctl submit`
so it binds the Aqua bootstrap — a bare `ssh … xcodebuild test` aborts at
`childPID > 0`:

```bash
# 1. Push the branch from the dev machine (when it's ready to share),
#    then on the M1:
ssh ricksm1.local 'cd ~/dev/VideoScan && git fetch && git checkout feature/gauntlet-v1 && git pull'

# 2. Submit the run into the M1's GUI session:
ssh ricksm1.local 'launchctl submit -l com.videoscan.gauntlet -o /tmp/gauntlet.out -e /tmp/gauntlet.err -- \
      /Users/rickb/dev/VideoScan/scripts/run_gauntlet.sh'

# 3. Watch:
ssh ricksm1.local 'tail -f /tmp/gauntlet.out'
# 4. Clean up the job label afterwards:
ssh ricksm1.local 'launchctl remove com.videoscan.gauntlet'
```

Prerequisites on the M1: logged-in **unlocked** GUI session (UI tests are
interactive/daytime only — the 2AM-locked-screen automation timeout is a
known failure class), Automation/Accessibility TCC granted to the runner
once, Homebrew ffmpeg installed.

## Machine policy

- **M1 = primary.** Gauntlet changes validate on the M1 first.
- **M4 only midnight–10:00 or a window Rick declares.** Two reasons:
  Rick is usually working on it (a UI test steals the pointer), and the
  M4's `testmanagerd` UI-runner bootstrap has been flaky — a hang there
  is an environment problem, not a code signal. Design around it; don't
  debug it on the M4.
- Never on a machine with someone at the keyboard.

## Known limitations (v1)

- **SwiftUI TextField typing** (flows 2/3) is the flakiest XCUITest
  primitive on macOS 26.5 (documented in CombineWorkflowUITests). The
  helpers use click + ⌘A + retype — the most robust variant found — but
  if a flow flakes on the M1, suspect the typing step first.
- **Menu items match by title, not identifier** — SwiftUI Buttons in
  Menus render as NSMenuItems and `accessibilityIdentifier` doesn't
  propagate (Xcode 26.3 / macOS 26.5). Renaming a menu item is a
  (deliberate) Gauntlet-visible change.
- Flow 1 depends on Vision detecting a face in the repo fixture photo
  (`tests/fixtures/photos/DonnaFaceDetectionTest.png`, override with
  `VS_GAUNTLET_PHOTO`). The photo-on-screen fixture makes matching
  near-exact (feature-print distance ≈ 0 against itself), so threshold
  drift won't flake it — but a Vision OS-update regression will show
  here first, which is a feature.
- The two-pair DV fixture is DVCPRO50-profile (ffmpeg's dv muxer rejects
  consumer 32 kHz PCM — the very bug that forces balanced raw-DV output
  into QuickTime). Stream SHAPE matches consumer 12-bit DV, which is
  what the probe and job read.

## Roadmap

- **v2: person-eval accuracy benchmark integration** — wire the graded
  find-Donna corpus (POI ratchet) in as a gauntlet stage with a minimum
  accuracy bar, so "run the gauntlet" also answers "did recognition get
  worse?".
- **v2: stress flows** — 100k-record synthetic catalog navigation,
  scan-while-searching, MFO queue saturation (per the feature-test
  checklist's Scale dimension).
- Promote flow 1's console assertion to also verify the
  `floorProvenanceLine` in videoscan.log once the log-dir handshake
  between runner and app is formalized.
- Candidate: fold the Combine pair flow (CombineWorkflowUITests, real
  catalog) into a fixture-based gauntlet stage.
