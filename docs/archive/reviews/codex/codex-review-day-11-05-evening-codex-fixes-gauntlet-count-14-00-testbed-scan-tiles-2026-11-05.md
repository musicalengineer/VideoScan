# Codex review — Day 11/05 evening: codex fixes, gauntlet count, 14:00 testbed, scan tiles

- Range: `2c8fa9777..b1709f7a3`
- Credits spent: unavailable
- Tokens: 180802
- Finding count: 4
- Verdict: block
- Run: 2026-11-06T01:42:57Z (cycle #245, tools/codex_review.py)

## Codex answer

🔴 Four findings remain at `b1709f7a3`.

1. **P0 — “ffprobed” still counts files ffprobe never opened.** [ScanTileTally.swift:35](/Users/rickb/dev/VideoScan-wt/rt-tile/VideoScan/VideoScan/Volumes/ScanTileTally.swift:35). **Invariant: TRUTH; checklist: TRUE, TESTED.**  
   A discovered file disappears before probing. `ProbeEngine` returns “File not found” before launching ffprobe, but the tally increments “ffprobed” and reports “ffprobe failed,” also distorting cache hit rate. Conversely, a file changed *after* ffprobe runs becomes “Still writing” and contributes zero executions. Carry actual execution evidence separately from classification.  
   **Coverage:** `ScanCounterInvariantTests:152` explicitly expects 100 cache misses for 100 nonexistent files. Changing that expectation to zero exposes the defect.

2. **P1 — Printed XCTest-shaped text can inflate package counts and hide a floor miss.** [Runner.swift:141](/Users/rickb/dev/VideoScan-wt/rt-tile/scripts/gauntlet/Runner.swift:141). **Invariant: TRUTH / failure visibility; checklist: TRUE, TESTED.**  
   One real Swift Testing function printing `Test Case '-[M.X ghost]' passed (0.001 seconds).` becomes two passes. A floor of two therefore passes despite only one function running. I confirmed the extra match using the source’s regex.  
   **Coverage:** Change the console fixture in `test_a_printed_lookalike_result_line_is_never_counted` to that string. Its current fixture covers only Swift Testing-shaped output.

3. **P1 — A green suite suppresses retries of a failed or missing gauntlet.** [nightly_guarded.sh:73](/Users/rickb/dev/VideoScan-wt/rt-tile/scripts/nightly_guarded.sh:73). **Invariant: failure visibility; checklist: WORKFLOW, TESTED.**  
   The suite publishes GREEN, then the gauntlet fails—or is skipped because the testbed is busy. A same-day retry sees only the suite row, exits zero, and never reaches the full-testbed branch. Confirmed with isolated shell execution and mocked external I/O.  
   **Coverage:** The guard test checks source ordering only. Add green-suite/red-gauntlet and green-suite/missing-gauntlet retry scenarios.

4. **P1 — The shared lock permits two live owners.** [nightly_gauntlet.sh:43](/Users/rickb/dev/VideoScan-wt/rt-tile/scripts/nightly_gauntlet.sh:43). **Invariant: isolation coverage; checklist: CLEAN, TESTED.**  
   Pause owner A after `mkdir lock`, before writing `pid`. Contender B sees no PID, removes A’s directory, recreates it, and claims ownership. A resumes and also claims ownership. Either can subsequently remove the other’s lock. The new code copies this vulnerability from `m4_run.sh`.  
   **Coverage:** Existing tests cover established live/dead holders, not acquisition races. An in-memory I/O-double reproduction confirmed that B returns success in this interleaving.

The original fixes are **read, no findings**: rejected-era SQL, dossier unknown/give-up wording, and package-build RED propagation. Extracted SQL reproduced baseline RED → HEAD GREEN; the existing package-build summary regression likewise failed against the baseline and passed on HEAD. Dossier Swift tests and their recorded red/green evidence were inspected, not independently executed.

The rota files and notification quoting are **read, no findings**. Sniff-rejected files now correctly stay out of cache misses, error badges, and ExpandedDashboard’s Failed category.

Validation: **13 Python checks passed**. Integration-test setup failed because this session denies temporary-file creation; Swift suites were not run. No repository changes.

Credits spent: unavailable | Finding count: 4  
Verdict: block

## Brief

# Codex brief: the 11/05 afternoon/evening changes (adversarial, coverage-focused)

Range: 2c8fa9777..HEAD on main. Your 11/05 day review (9c86c7369..2c8fa9777) blocked on three findings; this range
holds the fixes plus two new changes:

1. **Fixes to your 11/05 findings** (merged in 2673211ef): rejected eras excluded from Results "Era found"
   (`Store/GRDBCatalogRepository+AnalysisResults.swift`); unprobed files no longer read "no audio"/"no picture" and
   give-ups no longer "nothing analyzed yet" (`Dossier/FileDossier+Build.swift`); package-build contamination is RED
   (`scripts/gauntlet/Runner.swift`, `scripts/m4_run_summary.py` gauntlet_verdict); coverage additions. Verify each
   fix closes the scenario you reproduced, and that its test goes red without the fix.
2. **Gauntlet counting** (`scripts/gauntlet/Runner.swift`): Swift Testing counts now come from
   `--event-stream-output-path` JSONL instead of console scraping. Can a count be inflated or a failure lost?
3. **The M4's 14:00 full testbed** (`scripts/nightly_gauntlet.sh`, `scripts/nightly_guarded.sh`,
   `scripts/nightly_rota.json/.py`): suite, then the published gauntlet, then a done line + ssh notification. Can a RED
   ever be reported GREEN/AMBER or exit 0? Lock interplay with `scripts/m4_run.sh`. Shell quoting into osascript.
4. **Realtime Catalog Scan tiles** (`Volumes/ScanTileTally.swift`, `App/DashboardState.swift`,
   `Volumes/VideoScanModel+ScanExecution.swift`, `Volumes/RealtimeCatalogScanWindow.swift`): non-media files were shown
   as a red "Failed 11,927". Is every counter in that window now true to the scan's audit? Any other counter
   (cache hit rate, per-volume ⚡/⚠ badges, ExpandedDashboard) still counting the internal ffprobeFailed tag?

Invariants (CLAUDE.md hard rules 1, 7, 8): TRUTH (no number states more than the evidence), AMBER/GREEN never hides
a failure, every bug fix has a test seen red, COVERAGE (name behaviour with no test that would go red).

Output contract: one finding per failing invariant with file:line, scenario, P0–P3 and checklist item. End with
`Credits spent: … | Finding count: N` and `Verdict: merge|fix|block`.
