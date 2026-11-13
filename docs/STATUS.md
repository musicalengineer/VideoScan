# Status — rewritten, never appended

*Updated 2026-11-12 23:00 (Thursday; #470 merged this afternoon; this evening Check Media's continuity fix, sound over time per channel, and the sound fault matrix with three fixes it drove). Rick corrects this file; agents read it at session start.*

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
   guard skips only when today's green run was for the commit `main` is at.
2. **Sound, #470 — merged 11/12 (`3434eceff`), not yet on the testbed.** A sound decode that ends early (ffmpeg
   exits 0 on a file whose tail is missing) now reads "not checked" with its numbers — "the sound decode stopped
   early — N s of the M s the file's header states did not decode". Verify Audio stores nothing for it; the Promote
   sound gate refuses it whether or not "Archive anyway" is ticked (DECISIONS 2026-11-11). Short = more than 1 s
   AND more than 2 % missing. Each ffmpeg levels pass now names its filter with a fresh random tag and reads only
   that filter's lines, so nothing a file prints can stand in for the measurement (closes #471). Codex: #286 fix
   (3), #287 fix (2), #288 merge (0). Proof in the merge commit: 5 tests red unfixed, 622 audio tests and the
   sensor lane (744) green, and 158 real catalogued files read-only — 0 wrongly called short (largest real gap
   0.17 s). **What it does not catch, by design:** raw dv states no sound length (AVI was closed 11/12, Next item 2);
   a Matroska track that starts late reads "not checked" (refused, the safe side); a decode that stops in
   the last 2 % or last second. First testbed run on it: the M5 Ultra's 02:00 nightly of 11/13.
3. **State of `main` on the testbed BEFORE #470, after the night's ten merges (all on `29a0495e5`, the docs commit on top of
   the last merge `a6d957a5d`).** M4 full testbed, kicked by hand 23:05, done 01:15: suite **GREEN** (13,664
   passed, 0 failed, 67 skipped of 13,731; Core 2,577 passed, 0 failed), gauntlet **AMBER** (34 min: 7 known
   issues, all in regression, the same 7 as the afternoon run; 907 unadapted suites; ui not run — the expected
   state), script tests **GREEN** (2,110 passed). M5 Ultra deep gauntlet (`m4_run.sh deep --host ultra`, 23:05,
   32 min): **AMBER**, 0 failures (unit 4,584, regression 917, hallie 1,116, performance 83 passed); 8 known
   issues — the M4's 7 plus one timing miss, catalog search '1990s' at 100k rows 56.5 ms against a 50 ms budget
   (GH #208's band; 'donna' and 'mark dan grampa' sat at 47.9 and 49.7 ms, so that budget has no margin on the
   Ultra; no merge of the night touches search). M5 Ultra 02:00 nightly of 11/12 on `a9e613015` (the same code,
   one STATUS commit later): **GREEN**, 13,667 passed, 0 failed, 65 skipped of 13,732; Core 2,577 passed, 0
   failed; Hallie replay strict 56 of 56. Before the night, for comparison: M4
   11/11 16:12 on `343bdd7b9` suite GREEN 13,586 passed; every merge of the night also passed the sensor lane on
   its exact tree (744 tests: 719 app, 25 Core).
4. **The night of 11/11: the workspace cleanup (Rick's theme).** Ten branches from 11/08 brought current with
   `main` (each was 107+ commits behind), reviewed, proven and merged one at a time, each as one `--no-ff` merge;
   every branch, worktree and DerivedData removed after its merge. Nothing here changes what Rick sees except the
   words noted. Each merge commit carries its own table and counts.
   - **Codex fixes (the 11/09 sweep), each re-proven by mutating the fix back on the merged tree:**
     `ff25f8c73` gauntlet retention removes only the runner's own summarized runs, history appends are locked and
     rolled back on failure (9 tests red unfixed; 157 passed). `2f3de98fd` an Analyze / Transcribe / Captions row
     ends on what THIS run wrote (one test added in the merge: an older stamp on the asked-for channel is not this
     run's work). `71863733d` the Background quit marker is unlinked as one file, never a tree, and a failed clear
     is said (the log line now says "press Start"; the checkbox is gone). `b069c21f3` a future-dated check is no
     proof; Update waits for checks and writers it did not start, saves before its check, claims a check only on
     evidence (228 app + 110 Core).
   - **Refactors, behaviour unchanged, each proven by its characterization suite run against main's OLD function
     and against the split, plus one mutation seen red:** `6bd7de3b1` `floorFires` (CCN 33 → 6), `511509086`
     `Sweep.perform` (39 → 5), `eba4b3ab7` `selectFromEvidence` (39 → 7), `c6f2179fb`
     `ArchiveVolumeProtection.make` (31 → 6; data-risk: the 11/08 Codex pass, 0 findings, covers it — the merged
     file is byte-identical to the one reviewed), `4320de57a` `prepare` (37 → 9), `a6d957a5d`
     `Promoter.promote` (35 → 10; data-risk: a new Codex pass on the merged result, cycle #285, merge, 0
     findings). CCN-15 excess 1605 → 1481; debt entries 360 → 354. Verdicts: `docs/reviews/codex.md`.
   - **Two things the merges turned up, fixed in them:** the `prepare` golden's "already verified" scenario was
     stale on `main` itself (its injected diagnosis has no measurement, which since #467/#468 stores nothing) —
     the fixture now runs the real sound check and the golden was re-recorded on main's unsplit code; and no test
     pinned that the access copy is cut from the BALANCED companion ("cut it from the original" passed all 617
     Angel tests) — a test now does.
   - **Also:** `docs/design/hallie-full-audio.md` committed, parked (Rick's brief of 11/08); the two cloud briefs
     BACKLOG scheduled for retirement after 11/05 removed to stay under the 30-doc ceiling (tag
     `pre-prune-2026-11-11`); `archive-grades-combined` (a trial merge of the six refactors, no code of its own;
     tip `8a9463811`) and `codex-sweep` worktrees removed; three already-merged local branches deleted.
     Evidence logs of the night and of the retired worktrees: `.scratch/night-2026-11-11/`.
   - **Left alone:** `fix/469-sanitizer-host-crash` (local, 1 commit, superseded by what merged on 11/11 — Rick
     deletes it or says keep); the `ultra-testbed` worktree (`m4_run.sh --host ultra` uses it).
5. **Sanitizer triage, #469 (merged 11/11):** a relaunched test host is explained only by the report printed
   immediately before it, else it is red "host crashed" with the running test named. **Watch Saturday 11/14's
   address run:** the one run made with the #463 suppression in force showed a second report one frame down
   (`NSObject.hpp:112`), which the suppression does not cover — Saturday may read red "findings" for it. Widening
   the suppression is a #463 decision.
6. **P0/P1:** open P0 — #332, #327 (both wait on Rick). Still bugs — #423, #413, #412, #357, #356, #351, #344, #339,
   #338. Look fixed in the code, close after Rick's check — #327, #354, #353, #342, #345 (one real-data check). Not
   bugs as filed — #360, #343, #337. Notes: `.scratch/p0-p1-triage-2026-11-10.md`.

## Next (in order)
1. **Observations, what is left for an A in design:** the `mockup:` parameter stays in the production views for now —
   the offscreen renderer that makes Rick's mockup PNGs cannot draw a text field, button or scroll view, so the
   views carry static stand-ins (tried 11/11; removing it needs a different mockup tool, Rick's call); one read
   door for a session; a Frames window re-opened while Index Frames runs is not handed the job's later saves.
   Done 11/11: the frame index is latest-wins and comes from the job's own snapshot, not a second disk read.
   Test coverage is 41.6 % (the C).
2. **Sound: the fault matrix (Rick 11/12: "create a matrix with test cases to demonstrate all the reasonable
   cases … backed up by evidence and testing").** `SoundFaultMatrixTests` generates 19 kinds of wrong sound in
   5 containers (mov, mp4, mkv, mxf, avi; tones, no family media) and takes each file through the real Promote
   sound gate and Check Media's sound rows. Each of the 94 cells is pinned to one class, and the totals here are
   pinned by `theTableAddsUp`: **26 refused at the gate, 57 promoted with a Check Media Warning or Problem,
   11 promoted with nothing said** (it was 24 before the three changes below). A healthy file is clean in all 5.
   This is a count of fault KINDS, each weighted the same — not a probability about the collection.
   **Refused:** no sound track; silent or under −60 dBFS all through; file cut at 60 % (all 5 containers);
   sound half as long as the picture (mov, mp4); 10 % of the bytes zeroed (mp4, mkv, mxf, avi).
   **Flagged in Check Media, still promotes:** one channel dead all through, or dying halfway, or out 12 s;
   both channels dying halfway or out 12 s; a 50 ms dropout; clipping; DC offset; an inverted channel; very quiet;
   hiss only; sound half as long as the picture in mkv and avi.
   **The 11 not caught:** mains hum only, 5 cells (level is present; telling hum from programme needs a spectrum
   measure — BACKLOG); one channel out for 5 s, 5 cells (under the 10 s rule, by design); zeroed bytes in a PCM
   mov, 1 cell (decodes as 3 s of digital silence: longer than a dropout's 2 s, shorter than a 10 s stop).
   **Built for it 11/12:** (a) every channel quiet for 10 s or more, in a track that has sound, is a Warning on
   the continuity row ("The sound stops on every channel for 15 s from 00:00:15") — it was evidence only. On 88
   real files with sound, 8 have such a stretch (3 mid-file, 6 to the end), so about 1 real file in 11 will show
   it; the constant and the words are Rick's. (b) AVI: the header's PCM sample count is the stated sound length,
   so a cut-short AVI reads "not checked" and is refused like the other containers (all 38 catalogued AVI files
   decoded in full: 0 called short). (c) Check Media compares picture and sound lengths in mkv (DURATION tags)
   and avi; every catalogued mkv and avi header read: one real mkv is flagged, 61 min of sound on a 96 min picture.
   **Shelved, not merged:** AVFoundation as a second decoder at the gate. Over 73 real mov/mp4 files and 46
   generated fault cells it never disagreed with ffmpeg once, so there is no example of "two decoders disagree"
   to show; the work is a patch in `.scratch/470-sound-slice2-2026-11-12/second-decoder-shelved.patch`.
   **For Rick to rule:** should "sound shorter than the picture" in mkv/avi also be a stored Damaged verdict and
   a Promote refusal, as it is for mov/mp4 (one real file affected)? Should a 10 s stop on every channel, or one
   dead side, be more than a Warning?
   **Cannot be caught from the file alone:** a raw DV, MPEG or transport-stream file cut short before it was
   catalogued; a file re-wrapped after it lost sound (its header is consistent); wrong speed or pitch from a
   mislabelled rate outside the known ratios; sound out of step with the picture. Still open from #470: rows
   stored damaged before #468's fix; full cards saved before `78c90ac37`; the production-shape sound-gate test
   on a `.backup` of the live catalog has not run.
3. **Second-opinion tools on both Macs:** `sox_ng`, `mediaconch`, `qcli`, `gpac` (MP4Box), `bento4`, `libebur128`;
   Rick's bmx clone at `~/dev/bmx` is reference code for reading MXF. None is in a test yet.
4. **Sanitizers:** read Saturday 11/14's address run (item 4 above) and decide #463's suppression; narrow the #423
   suppression after the 11/15 thread run. A script test leaves `sleep 300` processes behind (which one: unknown).
5. **Testbed, carried (BACKLOG 11/10 lines):** the M4 adversarial review has been off since 11/07 (`claude` exits 1
   there); Core tests fail inside the M4's 04:00 coverage build (timing); the Ultra's nightly builds Rick's checkout
   instead of a clean clone of `main`; the warning ratchet cannot see a warning behind a warm build; the M4's catalog
   copy is still schema 14.
6. **#434** rescans throw away known whole-file hashes and re-hash unchanged files (TB per rescan). Catalog writer →
   rule 8 writer tests + production-shape test on a `.backup` + Codex pass before merge.
7. **Open P1s that need more than a fix:** #344 (needs a schema change — Rick approves), #338 (data-risk, Codex pass).
8. **`tools/claude_review.py`**: a fresh-context reviewer on the Console key, twin of `tools/codex_review.py`, code and
   diffs only (rule 13), per-review cost cap. Parked until Rick says to spend the credit.
9. Carried: #263 items 2 and 3; #435, #436, #439, #418, #408, #463; the worker records its exit signal;
   `CaptionRunnerError` on Avid MXF.

## Waiting on Rick
- **Open Codex findings the 11/09 sweep left for you** (unchanged by the merges; detail in each merge commit):
  gauntlet N1/N2 — the retention ownership proof can be forged by someone already inside
  `~/Library/Logs/VideoScan/gauntlet`: is that threat in scope? (also N5, N6, F4, F6, F7). Analyze #272 #2 — an
  Analyze that banked captions but no transcript ends as success with "no transcript" said: success or failure?
  Background — when the quit marker cannot be cleared the log says so but the Settings heading stops saying
  "quit"; F1 Quit does not drain an in-flight journal batch; F4 the activity poll still launches the quit helper.
  Catalog check — C1, C6 (both about a BACKWARD clock step), C7, #272 #4.
- **`fix/469-sanitizer-host-crash`:** delete the superseded local branch?
- **`run_catalog_tests.sh` prints RED with 0 failures** (Core: 5 known-issue tests and 1 env-gated skip are not
  counted toward its floor of 433). Already carried below as "the AMBER rule" question; seen again 11/11.
- **Spot test of item 3.** By eye only: the Frames Search button greys while a search runs and comes back; the sound
  gate's refusals on real files (now including a file cut short: "the sound decode stopped early"); the wording where sound was not checked.
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
