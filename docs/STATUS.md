# Status — rewritten, never appended

*Updated 2026-11-10 (Tuesday ~04:30, after the testbed night). Rick corrects this file; agents read it at session start.*

## Read first (five minutes)
0. **How work moves (PROCESS §2 item 1, Rick 2026-11-06).** Rick works on and spot-tests `main` only. A feature merges
   to `main` without waiting to be asked once its checklist, its own tests, the touched suites and the sensor lane are
   green — as ONE `--no-ff` merge commit (undo: `git revert -m 1 <merge>`) — then its branch, worktree and DerivedData
   are removed. Data-risk code (CLAUDE.md rule 10) still gets its Codex pass first. Run testbed scripts from an
   up-to-date worktree of `main`, never from Rick's checkout.
1. **The testbed schedule (DECISIONS 2026-11-05).** M5 Ultra 02:00 nightly suite; M4 14:00 the FULL testbed: app suite,
   deep gauntlet, then (new 11/10) the testbed's own Python tests, all published, then one "done" line in
   `~/Library/Logs/VideoScan/testbed_latest.txt` on the M4. M4 04:00 coverage, 04:30 Swift 6 analysis lane, 05:30
   adversarial confirm. Kick a full M4 run by hand: `ssh ricksm4.local 'launchctl kickstart
   gui/$(id -u)/com.videoscan.nightly-tests'` (about 2 h 10 min).
2. **State of `main` on the testbed, 11/10 (commit `4dc4eb2a6`):**
   - M4 app suite **GREEN**: 13,393 passed, 0 failed. Gauntlet **AMBER** (7 known issues, 894 unadapted suites, ui not
     run) — AMBER is the expected state until those are adapted; it had been RED four days for two SigLIP tests that
     cannot run in its sandbox (now listed as blocked, with the reason).
   - M5 Ultra nightly: 13,397 passed, **1 failed** — `persistVerdictPathNeverWritesTheRealCatalog()`. A false alarm: the
     only file that moved was `catalog.sqlite-shm`, which the Background helper touches by reading. Fixed in
     `fix/testbed-first-night` (the isolation snapshot no longer counts a `-shm`; the database and `-wal` stay watched).
   - M4 script tests, first run ever: 1,990 passed, **3 failed**, all three the tests' own assumptions (two assumed a
     Mac with no sanitizer logs; one waited a fixed half second for a stub server). Fixed in the same branch.
3. **What the metrics page now does (merged 11/10, `4dc4eb2a6`):** each Mac's row names its failed tests; the gauntlet
   table has a "Why, and which tests" column; a page summary older than the newest published run says BEHIND; the
   Ultra's nightly rebuilds the page summary itself (before, only M4 jobs did, so a failed M4 publish left the page
   stale); a publish retries a transient git failure (5 s, 20 s, 60 s) instead of dropping the row. The Ultra's 02:00
   run of 11/10 still ran the previous script (it pulls after it starts); the first run on the new script is 11/11.
4. **Merged 11/09–11/10 for Rick's spot test (Release):** Settings ▸ Background — "Background Content Analysis
   <state> (<build date>)" with one Start / Stop / Restart button (`25bcbab2e`); Make Public / Make Private, schema
   v1.15 (`0678bdc56`); #422 a journal unit lands all or nothing (`dde3e2b4f`).
5. **P0/P1 triage, 11/10 (19 open; full notes `.scratch/p0-p1-triage-2026-11-10.md`):** still bugs — #423, #413, #412,
   #357, #356, #351, #344, #339, #338. Fixed tonight — #422, #440. Look fixed in the code, close after Rick's check —
   #327, #354, #353, #342, #345 (one real-data check). Not bugs as filed — #360, #343, #337. Needs Rick — #332.

## Next (in order)
1. **Testbed, what tonight did not fix (BACKLOG, 11/10 lines):** the M4 adversarial review has been off since 11/07
   (`claude` exits 1 there); Core tests fail inside the M4's 04:00 coverage build (timing); the Ultra's nightly builds
   Rick's checkout instead of a clean clone of `main`; the warning ratchet cannot see a warning behind a warm build;
   the M4's catalog copy is still schema 14.
2. **Observations module C → A/B** (Rick 11/09; Codex as reviewer, Console API key allowed). Not started.
3. **#434** rescans throw away known whole-file hashes and re-hash unchanged files (TB per rescan). Catalog writer →
   rule 8 writer tests + production-shape test on a `.backup` + Codex pass before merge.
4. **Open P1s that need more than a fix:** #344 (needs a schema change — Rick approves), #338 (data-risk, Codex pass).
5. **`tools/claude_review.py`**: a fresh-context reviewer on the Console key, twin of `tools/codex_review.py`, code and
   diffs only (rule 13), per-review cost cap.
6. Carried: #435, #436 (gauntlet Python adapter; the daily script-tests lane now covers the gap outside the gauntlet),
   #439, #418, #408; the worker records its exit signal; `CaptionRunnerError` on Avid MXF.

## Waiting on Rick
- **Gauntlet policy:** should a skipped test make the gauntlet RED (today's rule), or AMBER with the skip named?
- **Interrupted runs:** a testbed run killed mid-way (the 11/09 macOS update) leaves no row, so the page shows the
  older run with no sign one was lost. A record for it was built and cut after four Codex rounds; wanted, or is
  "BEHIND" enough?
- **Triage:** close #327, #354, #353, #342, #345 after a look; #332.
- **Realtime viewer questions:** (1) should Stop confirm first? (2) helper counts: today, last 24 h, or since start?
- **"Gone" tile wording/icon** (Realtime Catalog Scan).
- **Notifications:** allow Script Editor notifications on the Ultra, or pick another route for the 14:00 done line.
- Carried: the "Does it settle?" checklist line; #415; M4 `OLLAMA_HOST`; whether `run_catalog_tests.sh` follows the
  AMBER rule; #327's two rulings.

## Ideas parked (BACKLOG)
- A stable installed home for the app and its background helper (Rick 11/09).
- Make Public and Show in Photos; Publish adds an optional linked Apple Photos import (Rick 11/09).
- Mutation testing, incremental (Rick 11/08).
- Layer 3's north star (Rick 2026-11-06): the family's story told by evidence, answerable by plain questions.

## Dates
- Mid-November: grade B or better in every module. 2026-12 soft / 2027-01 target: Public view link for family
  (Charter §5).
