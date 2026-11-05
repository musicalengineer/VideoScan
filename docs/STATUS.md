# Status — rewritten, never appended

*Updated 2026-11-04 (Wednesday evening). Rick corrects this file; agents read it at session start.*

## Read first (five minutes)
0. **Evening 11/04 — the era job's endless loop is fixed (branch `fix/era-unrippable-retry-loop`).**
   - **What Rick saw:** the helper at full speed with nothing to show for it. `background.log` 18:37–18:50 told the story. Run 1 found an era for 0 of 523 files, said "no usable era" for 121, and left 402 as "retried next run". The schedule then re-planned the same 402 within seconds, and it would have done so forever. Those 402 never rip a frame: Avid MXF essences (audio-only, raw video), QuickTime reference movies, `.m4p`.
   - **The cause:** a file with no verdict was retried every run with no limit. Timeouts and worker deaths had no memory across runs either. No test asked whether the service ever finishes; one test even locked in the unlimited retry.
   - **The fix:** a file with no verdict gets 3 tries (`EraAttemptStore`, `background/attempts/era.jsonl`, append-only). The third try writes one `era.none` line, "gave up after 3 tries: <why>", and the planner skips the file from then on. When frames won't rip, the reason carries ffmpeg's own words (`bench.py` `ReasonedRipper`). Every try and every give-up writes one line to `background.log`.
   - **"The file, or the Mac?"** (`EraCanary`): a try counts against a file only when the Mac is shown to work. ffmpeg must rip a synthetic clip at START, and again before any "no frame would decode" try; if it can't, the job is refused, so a broken `brew upgrade` can't give up good files. Before a timeout, death or unanswered try is counted, the model must answer that clip. If it doesn't, nothing is counted and the job holds.
   - **Tests:** 17 new.
     - `EraJobConvergenceTests` (13). The real schedule must settle a mixed catalog (plan 0, idle, ≤ 3 analyses per file); before the fix it never settled. The real-media matrix runs mp4, mov, mkv, mxf and avi/dv through bench.py's real ripper with a fake model.
     - `EraJobRetryReviewTests` (4), from the reviewer: broken ffmpeg, a timeout-only plan, the OUTCOME words, and scale.
     - Plus 3 Python tests on the rip reason.
     - Every red was seen before its fix.
   - **Lanes on the final tree:** background Core suites 212 / 0 · bench.py Python 185 / 0 · sensor lane GREEN 679 · Debug build OK · gauntlet inventory 0 errors. The new suites sit in the gauntlet regression stage (floor +17).
   - **Not covered:** a worker killed by the OS for memory (SIGKILL / jetsam) still counts as a try if the model then answers the synthetic clip. The worker doesn't record the exit signal yet. Open item below.
1. **11/04 day:** the helper owns its schedule (DECISIONS 11/04). There's no keyboard backoff on the Ultra: the worker runs at utility QoS. Pause/Resume is in the menu bar, and a pause survives a restart.
2. **11/03:** team signing (#415 test pending), the Release-only gate, the menu bar item, the Catalog/Content split, sound attempts v15 (#416 closed), and the checklist audit (merged `f393a3ba`).

## Spot tests for Rick (Release, to install the new helper)
- **Rebuild Release, then Resume the era job in the menu bar** (you paused it at dinner). With the current catalog the first run plans the 402, and every file that won't rip logs "no verdict, try 1 of 3". After the third run they are "GAVE UP after 3 tries", and the plan is 0. Check `~/Library/Logs/VideoScan/background.log`.
  - Each run takes about 11 minutes. The schedule re-plans when the catalog generation changes, or every 10 minutes.
- **Spot-check one give-up:** the inspector shows no Machine era line for it (era.none is never an era). Its reason is in the log line.
- **#415 at the same time:** the rebuild should keep the helper running with no re-tick.

## Waiting on Rick
- **Checklist proposal:** under TESTED, add "**Does it settle?** For any retry, schedule or loop: what bounds it, and is there a test that it finishes?" This needs your OK, since it's a PROCESS change.
- **#415**, see above.
- **M4 Ollama:** set `OLLAMA_HOST` so the Ultra can use it over TB5 (needs its Ollama restarted).
- **The catalog lane is RED by its own rule on 7 `withKnownIssue` tests** (#356, #358, #338/#357 family). For the gauntlet this is ruled (DECISIONS 2026-11-05: such a run is AMBER); does the same rule apply to `run_catalog_tests.sh`?
- Carried over: #327's two rulings; #332; the older defaults list (git `bb39167a:docs/STATUS.md`).

## Next
1. The worker records its exit signal, so a memory kill (jetsam) is never counted as a try against a file (from the 11/04 review).
2. The `CaptionRunnerError error 2` lines on Avid MXF at 17:57 in `videoscan.log`: the dossier engine likely has the same class of problem. Check whether it loops too.
3. Content Analysis results sheet (BACKLOG 11/04).
4. #418: the two P2s from schema B.
5. Helper throughput, and jobs on the M4 over TB5 (BACKLOG 11/03).
6. #413 (P1), #412, #408.

## In flight / cleanup
- `fix/era-unrippable-retry-loop`: delete it and its worktree (`~/dev/VideoScan-wt/era-retry`, DerivedData `~/dev/VideoScan-wt/.dd-era-retry`, scratch build `~/dev/VideoScan-wt/.build-core-era-retry`) after Rick's spot test (PROCESS §3).
- Open: #384 · #389 · #377 · #379 · #380 · #381 · #338 · #339 · #337 (VideoScanModel split).

## Dates
- 2026-11-05: cloud session credits expire. Mid-November: grade A in every module. 2026-12 soft / 2027-01 target: Public view link for family (Charter §5).
