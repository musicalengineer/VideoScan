# Status — rewritten, never appended

*Updated 2026-11-11 01:00 (Wednesday, after the night of 11/10: eleven merges for Rick's spot test). Rick corrects this file; agents read it at session start.*

## Read first (five minutes)
0. **How work moves (PROCESS §2 item 1, Rick 2026-11-06).** Rick works on and spot-tests `main` only. A feature merges
   to `main` without waiting to be asked once its checklist, its own tests, the touched suites and the sensor lane are
   green — as ONE `--no-ff` merge commit (undo: `git revert -m 1 <merge>`) — then its branch, worktree and DerivedData
   are removed. Data-risk code (CLAUDE.md rule 10) still gets its Codex pass first. Run testbed scripts from an
   up-to-date worktree of `main`, never from Rick's checkout.
1. **The testbed schedule (DECISIONS 2026-11-05).** M5 Ultra 02:00 nightly suite; M4 14:00 the FULL testbed (app suite,
   deep gauntlet, the testbed's own Python tests, all published, then one "done" line in
   `~/Library/Logs/VideoScan/testbed_latest.txt` on the M4). M4 04:00 coverage, 04:30 Swift 6 analysis lane, 05:30
   adversarial confirm. Weekly sanitizers on the M4: address Sat 07:00, thread Sun 05:00. Kick a full M4 run by hand:
   `ssh ricksm4.local 'launchctl kickstart gui/$(id -u)/com.videoscan.nightly-tests'` (about 2 h 10 min). The 14:00
   guard now skips only when today's green run was for the commit `main` is at (`9aa5924a4`).
2. **State of `main` on the testbed.** M4 full run finished 11/11 00:06 on `9aa5924a4`: app suite **GREEN**, 13,533 of
   13,600 passed, 0 failed; gauntlet **AMBER** (7 known issues, 902 unadapted suites, ui not run — the expected
   state); script tests **GREEN**, 2,079 passed. **Not yet covered by a full run:** the Verify Audio merge
   (`78c90ac37`), which landed after that run started; its own suites and the sensor lane were green. The 14:00 run of
   11/11 covers it.
3. **Merged the night of 11/10, for Rick's spot test (Debug is fine; none of it is about speed):**
   - `c30850610` **Promote sound gate.** Promote measures the sound of the proven bytes every time; it reads no
     stored verdict and stores none. Refusals: no audio track, half of a pair, silent, damaged, could not check. The
     only stored input is the owner tag "Silent — checked". "Archive anyway" passes only a file whose sound could not
     be checked, and logs it (Rick 11/10: keep the override). Codex pass done (`docs/reviews/codex.md`); recovery
     adoptions are not gated, declined with the reason there.
   - `78c90ac37` **Verify Audio tells the truth (#467, #468, closed).** A sound verdict is stored only when the
     measurement supports it; "not checked" is said, never OK or damaged. Check Media, Repair…, Balance Audio and
     Archive Angel read it the same way.
   - **Observations** (the C module): `092064a2c` a newer search or load always wins over an older one still running
     (one `LatestWins` helper, was hand-rolled counters); `8bb9feaca` the frame index job reports each file as
     indexed, unreadable or deferred, and writes through one writer; `b51f9819e` catalog rows are typed enums, not
     strings compared in the views.
   - **Testbed:** `a50d561b3` the sensor lane validates the gauntlet manifest first (#400, closed); `33121a067` a
     known sanitizer finding is suppressed with its issue and reason, a test-only finding is grey, red means a new
     product finding; `9aa5924a4` the guard change in item 1.
   - `c40e8dd1b` #263 item 1: a test fixture that carried a real birth date now carries an invented one.
4. **Sanitizer triage, #469 (merged 11/11):** a relaunched test host is explained only by the report printed
   immediately before it (by place in the log, no test line between), else it is red "host crashed" with the
   running test named. Re-read with this rule, the M4's 10/31–11/08 logs attribute all 27 relaunches to #463 and
   #423. The earlier attempt (`fix/469-sanitizer-host-crash`, local branch, unmerged) is superseded. **Watch
   Saturday 11/14's address run:** the one run made with the #463 suppression in force showed no host exit but a
   second report one frame down (`NSObject.hpp:112`), which the suppression does not cover — so Saturday may
   read red "findings" for it. Widening the suppression is a #463 decision.
5. **P0/P1:** open P0 — #332, #327 (both wait on Rick). Still bugs — #423, #413, #412, #357, #356, #351, #344, #339,
   #338. Look fixed in the code, close after Rick's check — #327, #354, #353, #342, #345 (one real-data check). Not
   bugs as filed — #360, #343, #337. Notes: `.scratch/p0-p1-triage-2026-11-10.md`.

## Next (in order)
1. **Observations, what is left for an A in design:** the `mockup:` parameter stays in the production views for now —
   the offscreen renderer that makes Rick's mockup PNGs cannot draw a text field, button or scroll view, so the
   views carry static stand-ins (tried 11/11; removing it needs a different mockup tool, Rick's call); one read
   door for a session; a Frames window re-opened while Index Frames runs is not handed the job's later saves.
   Done 11/11: the frame index is latest-wins and comes from the job's own snapshot, not a second disk read.
   Test coverage is 41.6 % (the C).
2. **Sound, what the two merges left (#470):** the Check Media card still says OK when sound was not checked; a
   truncated decode that exits 0 is not caught. The production-shape sound-gate test needs a `.backup` of the live
   catalog and has not run.
3. **Sanitizers:** read Saturday 11/14's address run (item 4 above) and decide #463's suppression; narrow the #423
   suppression after the 11/15 thread run. A script test leaves `sleep 300` processes behind (which one: unknown).
4. **Testbed, carried (BACKLOG 11/10 lines):** the M4 adversarial review has been off since 11/07 (`claude` exits 1
   there); Core tests fail inside the M4's 04:00 coverage build (timing); the Ultra's nightly builds Rick's checkout
   instead of a clean clone of `main`; the warning ratchet cannot see a warning behind a warm build; the M4's catalog
   copy is still schema 14.
5. **#434** rescans throw away known whole-file hashes and re-hash unchanged files (TB per rescan). Catalog writer →
   rule 8 writer tests + production-shape test on a `.backup` + Codex pass before merge.
6. **Open P1s that need more than a fix:** #344 (needs a schema change — Rick approves), #338 (data-risk, Codex pass).
7. **`tools/claude_review.py`**: a fresh-context reviewer on the Console key, twin of `tools/codex_review.py`, code and
   diffs only (rule 13), per-review cost cap. Parked until Rick says to spend the credit.
8. Carried: #263 items 2 and 3; #435, #436, #439, #418, #408, #463; the worker records its exit signal;
   `CaptionRunnerError` on Avid MXF.

## Waiting on Rick
- **Spot test of item 3.** By eye only: the Frames Search button greys while a search runs and comes back; the sound
  gate's refusals on real files; the wording where sound was not checked.
- **Sound gate:** should "Archive anyway" also pass a file measured silent? (Today no; tag it "Silent — checked".)
- **The archive sound check's findings:** the unplayable `Mark's-Bday-1984…` file; the silent CapeCodAndMuseum1991
  files, and whether to check the July recapture `CapeCod_1991-06-21_NV12`; the one-sided files.
- **#263:** rewrite git history to remove the old fixture date, or leave it? (Advice: leave it.)
- **Triage:** close #327, #354, #353, #342, #345 after a look; #332; #415; #161.
- **Realtime viewer questions:** (1) should Stop confirm first? (2) helper counts: today, last 24 h, or since start?
- **"Gone" tile wording/icon** (Realtime Catalog Scan).
- **Notifications:** allow Script Editor notifications on the Ultra, or pick another route for the 14:00 done line.
- Carried: the "Does it settle?" checklist line; M4 `OLLAMA_HOST`; whether `run_catalog_tests.sh` follows the AMBER
  rule; #327's two rulings.

## Ideas parked (BACKLOG)
- A stable installed home for the app and its background helper (Rick 11/09).
- Make Public and Show in Photos; Publish adds an optional linked Apple Photos import (Rick 11/09).
- Mutation testing, incremental (Rick 11/08).
- Layer 3's north star (Rick 2026-11-06): the family's story told by evidence, answerable by plain questions.

## Dates
- Mid-November: grade B or better in every module (two at C: Observations, People; People is left alone for now, Rick
  11/10). 2026-12 soft / 2027-01 target: Public view link for family (Charter §5).
