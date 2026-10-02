# Gauntlet phase-1 validation — 2026-09-27

Branch: `feature/release-gauntlet`, based on `fcfb8ce7`. Claude review is required before merge. No merge or main push was performed.

## Delivered files

- `scripts/run_gauntlet.sh`
- `scripts/gauntlet/Runner.swift`
- `scripts/gauntlet/inventory.swift`
- `scripts/gauntlet/manifest.json`
- `scripts/gauntlet/publish.swift`
- `docs/index.html`
- `docs/gauntlet.md`
- `tests/test_gauntlet_runner.py`
- `tests/test_gauntlet_publish.py`

## Verification

Twenty new runner/publisher/dashboard tests passed, zero skipped. Thirteen existing dashboard/metrics tests passed. After the real build exposed account-cache lookup, the poisoned-cache regression test passed again (1 test, 5.589 seconds). Shell syntax and `git diff --check` passed.

The commit hook then identified excessive complexity in the runner's main function. A behavior-preserving decomposition into helpers passed Swift typechecking, SwiftLint (zero errors; 13 force-unwrap/sorted-first warnings), and all 12 runner tests again in 53.983 seconds. Transcript: `/private/tmp/gauntlet-phase1-refactor-tests.txt`.

All orchestration tests use fake xcodebuild/xcresulttool processes in scratch repositories. Their result fixture is simulated evidence, not an app-test pass. They exercise failure continuation, exit codes, count floors, unassigned/blocked inventory, symlink refusal, environment isolation, watchdog timeouts and surviving descendants, durable publication, and dashboard rendering.

Two QA findings were fixed and pinned: an ordinary child exit could leave process-group descendants; deleting manifest blocked entries could falsely mark a subset passed. The dashboard sorting concern was declined after verifying that `allTdRows.sort(...)` precedes the Gauntlet filter.

Full control-plane test transcript:

```text
Machine: none. Control-plane tests only; Swift CLI compilation without optimization. xcodebuild/xcrun fake. No app builds or real test stages.
test_build_failure_blocks_stages_and_records_code (test_gauntlet_runner.GauntletRunnerTests.test_build_failure_blocks_stages_and_records_code) ... ok
test_dry_run_prints_plan_without_building_or_writing_results (test_gauntlet_runner.GauntletRunnerTests.test_dry_run_prints_plan_without_building_or_writing_results) ... ok
test_exited_leader_with_live_descendant_blocks_next_stage (test_gauntlet_runner.GauntletRunnerTests.test_exited_leader_with_live_descendant_blocks_next_stage) ... ok
test_failure_preserves_exit_and_continues_using_one_build (test_gauntlet_runner.GauntletRunnerTests.test_failure_preserves_exit_and_continues_using_one_build) ... ok
test_missing_structured_counts_and_skips_fail (test_gauntlet_runner.GauntletRunnerTests.test_missing_structured_counts_and_skips_fail) ... ok
test_omitted_blocked_assignment_projection_fails_preflight (test_gauntlet_runner.GauntletRunnerTests.test_omitted_blocked_assignment_projection_fails_preflight) ... ok
test_poisoned_home_and_roots_replaced_in_child_and_xctestrun (test_gauntlet_runner.GauntletRunnerTests.test_poisoned_home_and_roots_replaced_in_child_and_xctestrun) ... ok
test_symlink_results_root_refused_before_build (test_gauntlet_runner.GauntletRunnerTests.test_symlink_results_root_refused_before_build) ... ok
test_timeout_preserves_124_and_cannot_pass (test_gauntlet_runner.GauntletRunnerTests.test_timeout_preserves_124_and_cannot_pass) ... ok
test_ui_not_run_cannot_be_reported_as_pass (test_gauntlet_runner.GauntletRunnerTests.test_ui_not_run_cannot_be_reported_as_pass) ... ok
test_unassigned_test_fails_before_build (test_gauntlet_runner.GauntletRunnerTests.test_unassigned_test_fails_before_build) ... ok
test_zero_and_below_floor_fail (test_gauntlet_runner.GauntletRunnerTests.test_zero_and_below_floor_fail) ... ok
test_dashboard_separates_nightly_and_keeps_blocked_stage_duration (test_gauntlet_publish.GauntletDashboardTests.test_dashboard_separates_nightly_and_keeps_blocked_stage_duration) ... ok
test_dry_run_sanitizes_private_fields_and_forces_honest_ui (test_gauntlet_publish.GauntletPublishTests.test_dry_run_sanitizes_private_fields_and_forces_honest_ui) ... ok
test_failed_git_publication_keeps_queue (test_gauntlet_publish.GauntletPublishTests.test_failed_git_publication_keeps_queue) ... ok
test_invalid_identity_refused_before_queue_write (test_gauntlet_publish.GauntletPublishTests.test_invalid_identity_refused_before_queue_write) ... ok
test_queue_only_is_durable_and_sanitized (test_gauntlet_publish.GauntletPublishTests.test_queue_only_is_durable_and_sanitized) ... ok
test_symlink_lock_refused_without_touching_target (test_gauntlet_publish.GauntletPublishTests.test_symlink_lock_refused_without_touching_target) ... ok
test_symlink_queue_refused_without_touching_target (test_gauntlet_publish.GauntletPublishTests.test_symlink_queue_refused_without_touching_target) ... ok
test_untrusted_machine_commit_and_negative_times_are_sanitized (test_gauntlet_publish.GauntletPublishTests.test_untrusted_machine_commit_and_negative_times_are_sanitized) ... ok

----------------------------------------------------------------------
Ran 20 tests in 48.186s

OK
```

## Dry run

```bash
/Users/rickb/dev/VideoScan-wt-gauntlet/scripts/run_gauntlet.sh --away --machine m4 --dry-run
```

```text
GAUNTLET DRY RUN machine=m4 configuration=Release
Inventory: valid
Isolation: per-run home, App Support, catalog, preferences, caches, logs, archive, fixtures; canonical write allowlist
Build: ONE xcodebuild build-for-testing -scheme VideoScan -testPlan VideoScan-CI -configuration Release -derivedDataPath <run>/DerivedData
unit: test-without-building selectors=257 expected_floor=2028 blocked=480
regression: test-without-building selectors=2 expected_floor=6 blocked=31
integration: test-without-building selectors=1 expected_floor=6 blocked=18
performance: test-without-building selectors=16 expected_floor=54 blocked=12
hallie: test-without-building selectors=149 expected_floor=1045 blocked=55
stress: test-without-building selectors=2 expected_floor=9 blocked=8
ui: UI not run (phase 2)
Results: /Users/rickb/Library/Logs/VideoScan/gauntlet/<run-id>/result.json; history.jsonl; metrics publication queued on failure
```

## Real narrow check — blocked before tests

The approved small check selected only the four pure `MediaDispositionRawValueContractTests` tests with a 60-second stage watchdog. No test or app launched. There were two brief build attempts: the first exposed a SwiftPM module-cache write outside the per-run roots (now redirected and regression-tested); the second reached SwiftPM's sandbox startup and failed with:

```text
xcodebuild: error: Could not resolve package dependencies:
  sandbox-exec: sandbox_apply: Operation not permitted
```

This session cannot complete real Release verification. No sandbox bypass was attempted. Build exit 74 was preserved, unit was blocked, UI was not_run with reason phase 2, history was appended, and the sanitized metrics row was queued without network publication.

Full, unmodified result: [`result.json`](/Users/rickb/Library/Logs/VideoScan/gauntlet/phase1-validation/real/2026-09-27T23-01-04Z-CB9F310C/result.json). Build log: [`build.log`](/Users/rickb/Library/Logs/VideoScan/gauntlet/phase1-validation/real/2026-09-27T23-01-04Z-CB9F310C/build.log). The projection below omits only root paths and long blocked-suite/mode inventories; it preserves all verdicts and counts.

```json
{
  "binary_sha256": null,
  "branch": "feature/release-gauntlet",
  "build_exit_code": 74,
  "build_s": 4.090830208006082,
  "commit": "fcfb8ce756d5a55b19b4af54557f1e68a2a9e77a",
  "configuration": "Release",
  "dirty": true,
  "elapsed_s": 4.3325994170154445,
  "inventory_errors": [],
  "machine": "m4",
  "publish": "queued",
  "reason": "build exit 74",
  "run_id": "2026-09-27T23-01-04Z-CB9F310C",
  "schema": 1,
  "stages": [
    {
      "artifacts": [],
      "elapsed_s": 0,
      "exit_code": null,
      "expected": 4,
      "failed": null,
      "incomplete": 1,
      "name": "unit",
      "passed": null,
      "reason": "build exit 74",
      "skipped": null,
      "status": "blocked"
    },
    {
      "artifacts": [],
      "elapsed_s": 0,
      "exit_code": null,
      "expected": 6,
      "failed": null,
      "incomplete": 1,
      "name": "regression",
      "passed": null,
      "reason": "not selected",
      "skipped": null,
      "status": "not_run"
    },
    {
      "artifacts": [],
      "elapsed_s": 0,
      "exit_code": null,
      "expected": 6,
      "failed": null,
      "incomplete": 1,
      "name": "integration",
      "passed": null,
      "reason": "not selected",
      "skipped": null,
      "status": "not_run"
    },
    {
      "artifacts": [],
      "elapsed_s": 0,
      "exit_code": null,
      "expected": 54,
      "failed": null,
      "incomplete": 1,
      "name": "performance",
      "passed": null,
      "reason": "not selected",
      "skipped": null,
      "status": "not_run"
    },
    {
      "artifacts": [],
      "elapsed_s": 0,
      "exit_code": null,
      "expected": 1045,
      "failed": null,
      "incomplete": 1,
      "name": "hallie",
      "passed": null,
      "reason": "not selected",
      "skipped": null,
      "status": "not_run"
    },
    {
      "artifacts": [],
      "elapsed_s": 0,
      "exit_code": null,
      "expected": 9,
      "failed": null,
      "incomplete": 1,
      "name": "stress",
      "passed": null,
      "reason": "not selected",
      "skipped": null,
      "status": "not_run"
    },
    {
      "artifacts": [],
      "elapsed_s": 0,
      "exit_code": null,
      "expected": 1,
      "failed": null,
      "incomplete": 1,
      "name": "ui",
      "passed": null,
      "reason": "phase 2",
      "skipped": null,
      "status": "not_run"
    }
  ],
  "status": "failed",
  "ts": "2026-09-27T23:01:04Z"
}
```

## Claude / Rick follow-up

1. Claude reviews the branch. Many suites remain explicitly blocked: standalone package/Python/shell adapters, real-data or unaudited stateful tests, fixture-media/profile stress, and Hallie strict/advisory replay (needs an isolated versioned tree/log adapter). Source screening of selected hosted suites is conservative, not proof of transitive write confinement.
2. In a declared away window, repeat the small real check from a terminal where Xcode can start its package sandbox:

```bash
/Users/rickb/dev/VideoScan-wt-gauntlet/scripts/run_gauntlet.sh --away --machine m4 --only unit --manifest /Users/rickb/Library/Logs/VideoScan/gauntlet/phase1-validation/narrow-manifest.json --results-root /Users/rickb/Library/Logs/VideoScan/gauntlet/phase1-validation/real --queue-only
```

3. After review, normal away invocation:

```bash
/Users/rickb/dev/VideoScan-wt-gauntlet/scripts/run_gauntlet.sh --away --machine m4
```

The full phase-1 command intentionally cannot report all passed: UI is **not run (phase 2)** and blocked adapters remain visible. Phase 2 includes the sparse fixture archive disk image, app/subprocess boundary validation and fifteen UI flows; #14 is Archive Lock / Unlock / Remove.
