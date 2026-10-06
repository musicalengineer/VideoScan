# Release Gauntlet — phase 1

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

## Inventory and deliberate gaps

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
never counted as verified passes. Standalone package and Python/shell suites
remain assigned but blocked until component build/count adapters are available.

## Isolation

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

## Results and publication

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

## Phase 2 UI flow inventory

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
