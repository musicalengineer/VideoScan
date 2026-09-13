# Codex restart handoff — September 13, 2026

Rick is restarting Codex. This note preserves completed work and outstanding
reviews; it does not start an autonomous monitoring loop or authorize new changes.

## Resume here

1. Read this note and `AGENTS.md`; check `python3 tools/team-channel.py inbox --agent codex`.
2. Post-merge reviews remain outstanding: Hallie routing `81ac3f7e`, People UUID
   final delta `9a8fb4c4`, and date cleanup final delta `4a267e31`.
3. Do not describe those final deltas as independently approved by Codex. Claude
   merged them on his own review. Review focused deltas/tests before suggesting
   another real-model replay.
4. No replay is currently running. Rick's full visible replay completed; do not
   restart it automatically. Do not launch UI work on the M4 without a current
   user-authorized window. Rick is active again.

Source snapshot at handoff: main `926e8d31` (merge of Hallie routing `81ac3f7e`).
The pre-existing, unrelated dirty file remains untouched:
`VideoScan/VideoScan.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
Do not restore, stage or overwrite it.

## Completed overnight assessment

Report is merged on main: [refactoring_assessment_2026_09_13.md](refactoring_assessment_2026_09_13.md).
Review history: [overnight_reviews_2026_09_12.md](overnight_reviews_2026_09_12.md).

Top ten: People identity/storage; Hallie turn/session ownership; ConfirmPersonSheet;
catalog mutation/projections/actions; date/dossier provenance; tree lifecycle/photo
edits; Archive Angel job/sweep; FamilyAssetStore; HallieLineageQuestion; replay/grading.
Recommendation: finish correctness fixes, then choose two bounded extractions—not
ten simultaneous rewrites. The report is pinned to main `01d94091`, not current main.

Independent harness unit check then: 52 passed. No coverage percentage claimed.
Report branch `docs/overnight-refactor-assessment-20260912` was merged by Claude.

Important operational honesty: Codex's active session ended at 23:01 after report
delivery (#1444). Later review messages were not handled until Rick resumed in
the morning. No reliable scheduled wake/background review was installed.

## Full visible Hallie replay — DONE

Rick explicitly authorized M4 execution and chose a live Terminal transcript.
Run: **10:19:48–10:31:53 September 13**, all **418/418** nightly questions completed.

| Lane | Completed | Result | Runtime |
| --- | ---: | --- | ---: |
| Strict | 31/31 | 28 pass, 3 fail | 66 s |
| Advisory | 387/387 | 60 flagged, 327 unflagged | 658 s |

Both processes exited 0, no timeouts, missing answers or unmatched turns.
Strict grading correctly exited 1. Advisory unflagged is NOT semantic correctness.
This was the full nightly corpus, not every additional corpus in the repository.

Artifacts:
`/Users/rickb/Library/Logs/VideoScan/hallie-eval/visible-20260913-1020/`

- `live.log`: compact live transcript (long answers shortened by the watcher).
- `strict.jsonl`, `advisory.jsonl`: complete paired answers and run metadata.
- `strict.graded.jsonl`, `advisory.graded.jsonl`: per-question flags.
- `strict.summary.json`, `advisory.summary.json`: completion and grading counts.
- Strict run ID: `hallie-eval-20260913T101948-bbcb480e`.
- Advisory run ID: `hallie-eval-20260913T102055-01444377`.

Model: resident `qwen3.8:27b-mlx`, `http://127.0.0.1:11434`; composition ON,
actions/playback OFF, no profile or knowledge writes. Binary:
`/Volumes/XcodeRAM/VideoScan-awdqzabjhjsdepacsmfxmodpxedx/Build/Products/Debug/VideoScan.app/Contents/MacOS/VideoScan`.
Its mtime remained `2026-09-13 10:16:08`. Claude attributes it to Rick's Xcode
build of `4defbdaa`, qualified by possible local edits. `buildSHA` is intentionally
null. Harness `git` is checkout-at-completion (strict `4defbdaa`, advisory
`ec3935f6`), not an independently verified binary source revision.

Temporary operational scripts, ignored by git:
`codex-worktrees/hallie-live-run/run.sh` and `Watch-Hallie-Live.command`.
Runner exec session 69768 completed. A Terminal tail viewer may remain open;
Control-C closes that viewer, not an active replay. No test/model process needs
stopping for this restart.

UI tool initialization failed under sandbox (OpenSSL config read permission);
osascript/ps also unavailable. Terminal launch succeeded using its explicit app
path. Do not attempt permission workarounds. Existing shell replay worked within
the sandbox, and Rick could also use the supplied `tail -n +1 -F .../live.log`.

## Observations delivered to Claude

All sent in #1460 and consolidated at Rick's request in **#1463**:

- Strict-004: “whom did he marry” after John Hastings → video search.
- Strict-005: “tell me all about Edward III” → video search.
- Strict-015: “tell me about his parents” after Nathaniel Caleb Parker → video search.
- Advisory `lv260907-002`: highest royalty/title query → generic tree statistics,
  yet ZERO grader flags. Both routing and expectation quality need attention.
- “search the family tree for a title like king” treated the title phrase as a name.
- Catalog-count follow-ups about the 90s/80s lost their count context.
- “play the longest video in the archive” failed to resolve an “archive” anchor.
- Question challenging the photo request for Thankful Pratt returned only her birth date.
- “show me” after Rick's biography failed to act on the preceding context.
- Positives: maternal birthplace trails to Europe, including “materanl” typo,
  answered. Complete replay ran without the overnight watchdog problem.

These are observations, not all root-caused defects. No production code was changed
by the replay. Claude has the exact saved questions and answers.

## Claude's latest routing change — REVIEW PENDING

#1462: commit `81ac3f7e`, merged as `926e8d31`.

- Deterministic spouse-sentence route for who/whom did he/she/name marry/wed,
  or who was … married to; they/my refused, WHEN retained for marriage-date route.
- Biography opener accepts tell me/us all/more/everything about; identity oracle
  must still reject media/topic phrases. “What do you know about” intentionally unchanged.
- About + pronoun-possessed kin phrases route deterministically; biography detector
  steps aside. Preserve neighboring-route precedence.
- Owner reports new 11-test `HallieStrictReplayFamilyIntentTests`, red 10/11 before;
  1,405 tests / 146 Hallie+Archivist suites green; Python eval tests 50 green.
- Corpus edits: `lv260907-010` gets followsPrevious, `lv260907-028` no longer guessed
  catalog, marriage question added as `lv260913-001`. Review expectation changes
  separately from code so wrong answers are not blessed.
- Pre-existing quirk, NOT fixed: “who did my grandmother marry” becomes kinshipNamed
  grandmother / name Marry through HallieKinshipApposition. Claude offered ownership;
  no new implementation assignment was made by Codex.

## People and date final deltas — REVIEW PENDING

Claude merged both on the morning of September 13, after delivering late-night
deltas without receiving a Codex verdict. Prior explicit HOLD findings prompted:

People `9a8fb4c4` (merge `3e915900`), owner reports 761 tests / 56 suites:
UUID mismatch import refusal; present-but-missing active UUID refusal; ambiguity
guards at actual label/holdout write sinks; unique-only legacy kinship upgrade;
quarantined deletion refused before any job/storage action; migration internal
absolute symlinks rebased with crash-resume/rollback tests. Inspect real repeated
operations as well as first refusal, and actual sink/identity boundaries.
Worktree: `/private/tmp/VideoScan-uuidpoi` if still present.

Date `4a267e31` (merge `9d4407b1`), owner reports 157 tests / 18 suites:
cleanup walks provenance to the earned origin with cycle/missing-link handling;
dependent bad descendants cleared; recovery sidecars unique and no-overwrite.
Automatic on-load cleanup is data-sensitive. No live repair by Codex authorized
or performed. Separate dossier partial-MD5 evidence copying remains a known concern.
Worktree: `/private/tmp/VideoScan-datefix` if still present.

Already APPROVED: attestation off-main log/journal and timestamp/tie ordering
`cd801d16` (merged `8b88c1a4`); exact delete-plan safety (merged `01d94091`);
earlier photo-preserving People rename (Claude reviewed, merged `984bb560`).

## Nightly failure — corrected diagnosis

Log: `/Users/rickb/Library/Logs/VideoScan/nightly_test_20260913_020005.log`.
M4, source `55eeef39`, Debug build 1,482 s. Swift Testing summary:
7,359 tests / 1,030 suites; one unexpected stale place-wording assertion, fixed
in `4defbdaa`. Aggregate partial result row: 7,438 pass / 1 fail / 57 skip.
Watchdog expired at 7,200 s; Hallie lane never ran because the script exited first.

Claude #1452 initially blamed a 100k name-route XCTest. **That claim was retracted
in #1458.** The XCTest bundle passed at 02:26 (confirmed in log); Swift Testing
summary printed around 02:42; runner persisted until 04:24. Claude's agent reports
test-host PID 94139 stuck exiting in kernel proc_exit; that process diagnosis was
not independently verified by Codex (ps blocked). Do not repeat the false test-hang
attribution. Claude requested a spindump before any reboot.

`ec3935f6` lowers timeout to 2,700 s = **45 minutes**, despite its commit subject
saying 30. A lower timeout alone still does not make the Hallie lane run. Independent
lane scheduling and a teardown-idle watchdog remain separate follow-ups.

## Team-channel / coordination state

All messages through #1462 addressed to Codex were handled/acknowledged.
Last substantive outgoing message: #1463 (observations requested by Rick).
Inbox was empty at restart preparation. Use normal numbered acknowledgments on
resume. Peer proposals are context, not authorization. No standing overnight
polling/scheduled wake is active.

Existing native agent names from this session: `date_inference_review`,
`gallery_security_review`, `scan_target_projection_review`. Do not assume their
processes or memory survive a restarted session; this file and saved artifacts
are the durable source.
