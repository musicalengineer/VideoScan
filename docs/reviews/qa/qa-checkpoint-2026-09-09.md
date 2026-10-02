# QA execution checkpoint — September 9, 2026

Rick assigned Codex the QA lane while Rick and Claude develop. No interactive
M4 app/test launch. This is an in-progress checkpoint, not a green-main claim.

## Confirmed

- GitHub CI 34296771692 built b06c5570 successfully. XCTest reported one
  100k surname-roster budget failure. Subsequent Swift Testing reported other
  aggregate/keyword/publish-budget and media-render failures. The test step
  timed out after 20 minutes; the earlier 137-test count is only the XCTest
  portion, not the entire run.
- M4 nightly September 9 timed out during its build at 1,800 seconds. No tests
  or Hallie replay ran. The saved build log is `/tmp/nightly-build-output.log`.
  It contains warnings and BUILD INTERRUPTED, not an identified compiler error.
  Cause remains unproven; no blanket timeout increase or cache deletion done.
- CI's failure counter counted the numeric output of `grep -c`, hiding real
  failures after subtracting the canary. Commit 23e6e89e fixes that and adds a
  completion/exit/infrastructure gate; 11 headless tests pass. Independent
  static review GO. Conservative infrastructure diagnostics may need refinement
  against future actual Xcode output; do not disable the completion gate.
- Nightly's runner-hang exception could publish green. Commit ee04544f changes
  that verdict to failed while preserving the reason key. Harness 41/41 pass.
- Hallie preflight harness: 4/4 pass. M5 Ollama 0.32.14 lists qwen3.8:27b.

## M5 baseline execution

Pinned source **b06c5570**, Xcode **26.6 / 17F113**, Debug, arm64. This is NOT
the later 57f573d9 performance-budget patch and NOT a Release performance claim.

- Worktree `/Users/rickb/dev/VideoScan-qa-20260909` (detached).
- DerivedData `/private/tmp/videoscan-qa-20260909-dd`.
- Build-for-testing succeeded.
- Focused FamilyTreeModelReuseTests: **10 passed, 0 failed**, 6.752 seconds.
- Full non-UI suite launched in Aqua as `videoscan.qa.full.20260909`, with a
  3,600-second process-group watchdog. Log `/private/tmp/videoscan-qa-20260909-full.log`;
  xcresult uses the same prefix plus `-full.xcresult`. Final marker is
  `QA_XCODEBUILD_EXIT=`; no completed verdict yet at this checkpoint.
- Sequential Hallie replay is queued as `videoscan.qa.replay.20260909`. It
  waits for full-suite exit 0 or 65; infrastructure timeout blocks replay.
  Both strict/advisory corpora, qwen3.8:27b at localhost, 1,800-second replay
  budget, the pinned binary, and no-actions harness. Output JSON:
  `/private/tmp/videoscan-qa-20260909-replay.json`; per-query files in
  `/private/tmp/videoscan-qa-20260909-hallie`. No replay result yet.

M1 is `ricksm1.local`, not `ricksmacbookpro.local`. Two pre-existing VideoScan
test hosts were observed; left untouched. Claude confirmed no M5/M1 jobs owned
by him today. No production archive files or preferences intentionally changed.

## Next verification

Read both completed test-framework summaries and xcresult, then inspect Hallie
query-level outcomes (pass/fail/incomplete separately). Review against latest
main before making any current-main claim. CodeQL workflow green does not prove
coverage: Claude reports 82/1,311 files in the earlier run; attempt 8 is pending.
