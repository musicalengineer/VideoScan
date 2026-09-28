# Gauntlet design — codex proposal (2026-09-27)

Read-only design task via codex exec (64,537 tokens). Brief: see bottom. Status: PROPOSAL — awaiting Rick's approval of phase 1.

Use **one expanded `scripts/run_gauntlet.sh`**, invoked when Rick leaves:

```bash
./scripts/run_gauntlet.sh --away --machine m4
```

It owns the M4 until completion, runs without agents or paid inference, and reports incomplete execution honestly. Hallie still uses local model inference; literal “zero inference tokens” would exclude its live testbed.

**1. One-time setup**

Run from the terminal Rick will use:

```bash
sudo /usr/bin/automationmodetool enable-automationmode-without-authentication
sudo /usr/sbin/DevToolsSecurity -enable
/usr/bin/automationmodetool
/usr/sbin/DevToolsSecurity -status
```

The first removes authentication when XCTest enables Automation Mode; “disabled” while idle is acceptable if authentication is no longer required. The second removes debugger/performance-tool password prompts for administrators/developers. These are separate gates. Commands match the installed man pages and [Apple’s documented DTS guidance](https://developer.apple.com/forums/thread/693850).

In System Settings → Privacy & Security, grant the launching terminal Accessibility and approve requested Automation permissions; approve the XCTest helper if prompted. Do one attended fixture-only UI launch to settle permissions.

For every run, the script wraps its worker in:

```bash
/usr/bin/caffeinate -dimsu <gauntlet-worker-command>
```

This holds display, system, and disk sleep assertions. It **does not unlock the screen or defeat explicit locking**. Leave the GUI session unlocked; disable automatic screen-saver/locking for the away window. No permanent `pmset` change is necessary. Restore ordinary locking afterward.

**2. Runner and results**

Choose the script over TestDriver CLI. [TestDriver’s registry](/Users/rickb/dev/VideoScan/TestDriver/Sources/TestDriver/Tests/VideoScanTests.swift) mixes Debug/Release, repeats suites, and invokes `xcodebuild test` per entry. Its publisher also excludes feature-branch runs.

Create an aggregate test plan containing app tests and safe UI tests. Build once:

```bash
xcodebuild build-for-testing \
  -project VideoScan/VideoScan.xcodeproj -scheme VideoScan \
  -testPlan VideoScan-All -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$run_dd"
```

`VideoScan-All` is proposed. Every subsequent Xcode stage uses that build’s `.xctestrun` with `test-without-building`, explicit selectors, separate `.xcresult`, and serial execution. Pin Hallie and executable-based integration tests to that exact Release executable; record its hash.

Order: **unit → regression → integration → performance → Hallie strict/advisory → stress → UI**.

A checked-in manifest assigns every discovered test once, records positive gates and expected counts, and fails on unassigned tests or unexpected skips. Include Python via [run_python_tests.sh](/Users/rickb/dev/VideoScan/scripts/run_python_tests.sh), standalone package tests in Release, and shell harness tests. Those test their own components, not literally the app executable.

Adapt [generated-media performance](/Users/rickb/dev/VideoScan/scripts/run_generated_media_perf.sh), [fixture stress](/Users/rickb/dev/VideoScan/scripts/run_fixture_media_stress.sh), and [adversarial stress](/Users/rickb/dev/VideoScan/scripts/run_adversarial_stress.sh) to reuse products and isolated configuration.

Reuse the process-group watchdog from [nightly_local_tests.sh](/Users/rickb/dev/VideoScan/scripts/nightly_local_tests.sh). Capture child return codes directly; never infer success from log text or `| tail`. Continue after ordinary failures. Build failure blocks dependent stages; unreaped processes stop execution as contaminated. Signals/timeouts still finalize results.

Use monotonic stage/total timers. Store logs, screenshots, results, and atomic `result.json` beneath:

`~/Library/Logs/VideoScan/gauntlet/<run-id>/`

Append to `gauntlet/history.jsonl`. Schema:

```json
{
  "schema": 1, "run_id": "...", "ts": "...",
  "commit": "...", "branch": "...", "dirty": false,
  "machine": "m4", "configuration": "Release", "binary_sha256": "...",
  "status": "failed", "elapsed_s": 5432, "build_s": 180,
  "stages": [{
    "name": "unit", "status": "passed", "exit_code": 0,
    "elapsed_s": 210, "expected": 100, "passed": 100,
    "failed": 0, "skipped": 0, "incomplete": 0,
    "reason": null, "artifacts": ["unit.xcresult"]
  }]
}
```

Extract counts from structured results; unknown counts stay null. Record Hallie advisory results as clean/flagged, not verified passes.

Extract/reuse nightly `publish_row` and its pending queue; publish sanitized additive rows to `metrics/testdriver.jsonl`, tagged `source=gauntlet`. Extend [docs/index.html](/Users/rickb/dev/VideoScan/docs/index.html) with stage/total trends, latest counts, and failures. Separate Gauntlet rows from nightly averages; failed publication remains queued.

One final line:

`GAUNTLET FAILED sha=abc123 total=90m32s unit=PASS … ui=FAIL results=<path> publish=queued`

**3. UI coverage**

Use a **mix**, retaining [existing Gauntlet tests](/Users/rickb/dev/VideoScan/VideoScanUITests/Gauntlet/GauntletBase.swift):

- XCUITest genuinely clicks every menu/context-menu entry, keyboard shortcut, and sheet.
- Extend [GauntletSeams.swift](/Users/rickb/dev/VideoScan/VideoScan/GauntletSeams.swift) for fixture selection, state inspection, and bounded completion signals. Any scripted actions call production handlers; they do not count as click coverage.
- Use identifiers, menu titles where necessary, predicate waits, small UI catalogs, failure screenshots, and no retries that erase failures.

Maintain a verb→test inventory; fifteen flows are the starting set:

1. Scan/add target/cancel/rescan.
2. Search/filter/sort/select.
3. Update… and options.
4. Walk Tree.
5. Initialize fixture archive.
6. Promote, verify manifest/index/ledger.
7. Duplicate discovery/filtering.
8. Delete duplicates picker, forecast/dry-run, cancel.
9. ⌘O opening and cancellation.
10. Rename, collision, cancellation.
11. Correlate and combine MXF pairs.
12. Balance Audio and stereo rejection.
13. Set date: exact, estimated, invalid.
14. Person Finder: reference, scan, cancel, confidence floor.
15. Hallie ask plus tabs, inspector, MFO, Settings, About.

Generate `test_*` MP4/H.264, MOV/ProRes, MKV/FFV1+PCM, MXF, AVI/DV fixtures. Assert hashes, streams, catalog state, persistence after relaunch, and ledger entries.

**4. Safety**

[VS_UI_TEST detection](/Users/rickb/dev/VideoScan/VideoScan/TestEnvironment.swift) plus fake HOME is **not filesystem confinement**. Require explicit per-run App Support, preferences, catalog, cache, logs, archive, and fixture-volume roots; disable real sync/bookmarks.

Add canonical-path write allowlisting, rejecting symlink escapes, plus OS-enforced write confinement for test hosts, app, and subprocesses. Validate confinement independently for XCTest-launched processes. Refuse execution if protection cannot be established. Preserve production persistence into isolated stores rather than suppressing it.

Convert [CombineWorkflowUITests.swift](/Users/rickb/dev/VideoScan/VideoScanUITests/CombineWorkflowUITests.swift), which explicitly reads the real catalog, before inclusion. Hallie needs isolated logs and a copied, versioned tree snapshot; its current replay defaults require adaptation.

**5. Delivery and ownership**

**Phase 1: ≤1 day** for runner, timing, existing safe non-UI adapters, JSON/history, and dashboard. Expose unsafe/unadapted tests as blocked; this milestone cannot claim “all tests passed.”

**Phase 2: 4–7 days** for confinement validation, persistence seams, legacy conversion, fifteen UI flows, and verb inventory; additional days depend on remaining verbs.

Risks: Release build duration, Hallie corpus runtime, TCC resets, UI typing, confinement compatibility. One–two hours is a target; budget exhaustion reports incomplete.

Rick supplies an attended setup window and workflow priorities. Claude supplies the authoritative suite inventory, fixture/tree requirements, and missing `docs/codex-ui-testing-handoff.md`. I would implement this on `feature/release-gauntlet`, including failure-injection and isolation tests. No files were changed or builds/tests run.

## Brief

DESIGN TASK (not a code review). Read-only; do not build or run anything; do not modify files. Output a design proposal to stdout (Markdown, under 1,200 words).

Rick (project owner) wants: "Run the Gauntlet" — ONE command he gives when he leaves for 1–2 hours that runs ALL tests against the RELEASE binary on the M4 (his own Mac, screen unlocked, awake), including a UI click-through that exercises every menu verb / context-menu item / sheet the way he does by hand, and records wall-clock time per subsystem and total, into a history with a small trend dashboard. Simple. It may hog the M4; it must not burn LLM tokens (no agents in the loop while it runs).

Stages he named: unit, regression, integration, performance, Hallie (strict + advisory testbed), stress, UI. Timing per stage + total, git sha, pass/fail counts.

Known history — read these first (and only what you need beyond them):
- docs/gauntlet.md, scripts/run_gauntlet.sh, docs/codex-ui-testing-handoff.md (your own earlier write-up), TestDriver/ (a Swift package harness: xcodebuild runner + metrics publishing; Rick abandoned its UI), the VideoScanUITests target, scripts/nightly_local_tests.sh, scripts/nightly_hallie_replay.sh, the metrics dashboard publisher (GitHub Pages under docs/metrics or wherever the nightly publishes).
- The old walls: (1) the UI-test password prompt — this M4 reports "Automation Mode is disabled. This device requires user authentication to enable Automation Mode." (`automationmodetool`); (2) "Timed out while enabling automation mode" when the screen is locked/asleep (testmanagerd needs an unlocked GUI session); (3) Accessibility/Automation TCC grant for the launching terminal; (4) `| tail` masking exit codes; (5) a UI test once grabbed Rick's mouse while he worked (so the Gauntlet only runs when he says he's away).

Answer, concretely:
1. The one-time setup Rick must do (e.g. `sudo automationmodetool enable-automationmode-without-authentication`, DevToolsSecurity, TCC grants, `caffeinate -dimsu` for the run, display sleep) — exact commands, and what each removes.
2. The runner: one script (or TestDriver's CLI if it truly fits — say which and why) that builds Release once, runs the stages in order, continues after a stage fails, captures the real exit code per stage, times each stage, writes one JSON result (schema) per run + appends to a history file, and prints one summary line. Where results live; how they reach the dashboard (reuse the existing publisher).
3. The UI stage: how to get real coverage of verbs without flake — XCUITest vs an app-internal "driver mode" (a launch argument that exposes a scripted command channel invoking the same actions as the buttons) vs a mix. Fixture media (synthetic `test_*` files), an isolated catalog/App Support sandbox so it never touches Rick's real catalog or FamilyArchive, and assertions on outcomes (files, catalog state, ledger lines), not just "didn't crash". A first list of the ~15 most valuable UI flows to cover (Rick's real workflows: scan, promote, Update…, Walk Tree, Delete duplicates dry-run, Hallie ask, ⌘O, rename, etc.).
4. Safety: how the Gauntlet guarantees it never writes to /Volumes/FamilyArchive or the real catalog (sandbox App Support, fixture volumes, a guard that refuses to start otherwise).
5. A phased plan (phase 1 = runner + timing + non-UI stages + dashboard in ≤1 day; phase 2 = UI stage), effort per phase, and the risks.
6. What you'd need from Claude/Rick, and what you'd build yourself on your own branch.

Be specific to this repo; cite file paths you read.

## Closed

Closed by `8de375a6` at 2026-09-27T23:05:59Z. codex built phase 1 (161,870 tokens); Claude reviewing + running the narrow real check
