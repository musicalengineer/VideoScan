# Nightly cloud pass: review / test / harden / refactor (2026-10-06 → 2026-11-04)

Rick starts ONE cloud session each evening (claude.ai/code, repo
musicalengineer/VideoScan) with the same line every night:

    Run docs/briefs/cloud/NIGHTLY.md

**Session: what to do.** Read `docs/briefs/cloud/README.md` (standing rules:
read-only, one report, branch `cloud/<id>`, header shape, hard-to-refute bar, 45-min box).
If the paste names a row ID (e.g. `… row N1007-D-Hallie-rewrite-eval`), run that row. Otherwise pick **tonight's row** below: the row dated today (US Eastern). If that row is
already marked done in `docs/reviews/cloud/LEDGER.md`, or tonight has no row, take the
earliest row that isn't done. Follow that row's theme checklist (below) over that row's scope.
Report path: `docs/reviews/cloud/<id>.md`. Ignore the rows' order otherwise.

Why: rapid dev with many new ideas piles up tech debt (Rick, 2026-10-05). The
nights pay it down, with the riskiest code first. Areas are weighted by 30-day churn × data risk.
In the morning the Manager on the Mac fetches the branch, has `qa` verify every finding,
and puts the survivors into Rick's morning triage. Fixes and refactors are applied on the Mac,
on a branch, with tests, after Rick's go. The cloud session never changes code.

## Themes

**R: Review (adversarial).** Attack the area's invariants: data can't be lost,
overwritten, misfiled or silently left inconsistent; failures surface; the UI
never states something the action won't do. Use the README finding format.

**T: Test.** (1) For the 10–15 most important guards in scope, name the test that
goes red if the guard line is deleted; a guard with no such test is a finding,
with the test to add. (2) Vacuous tests: assertions that can't fail, `try?`
swallowing, silent early returns, source sensors matching comments.
(3) The five-dimension checklist in CLAUDE.md (logic, scale 100k, media matrix,
isolation, sensor): which recent features in scope are missing a dimension?

**H: Harden.** Error paths and limits: swallowed errors on write paths;
unbounded memory or O(records) work on the main actor or in view bodies; missing
cancellation; process/ffmpeg calls without timeout or exit-code check; actor
reentrancy across `await` where state is read before and used after; files left
half-written; force-unwraps and `try!` on input or disk data; logs leaking media paths.

**D: Debt / refactor plan.** Measure, then plan. Don't edit code.
0. **Don't `pip install lizard`:** the cloud network blocks PyPI, and stock lizard misreads Swift
   regex literals and `#` strings anyway. Use the M4's numbers, measured nightly with those fixes:
   `ci/baselines/complexity_debt.json` (EVERY offender, CCN > 15 or > 80 lines, with CCN and length;
   refreshed by the 2 AM job) and `git fetch origin metrics` then
   `git show origin/metrics:metrics/complexity.jsonl | tail -1` (per-folder debt, top 15, NEW
   offenders). New offenders in tonight's scope come first: they're the cheapest debt to pay.
1. From those, list the scope's functions with CCN > 15 or length > 80, and files > 800 lines.
2. Find duplicated logic (two functions that answer the same question differently
   are the debt that bites: the C01-F1 class), dead code (no callers: grep),
   leftover `TEMPORARY`/diag code, stale TODOs, flags that are always on.
3. Write a **ranked refactor plan**: for each item, the behavior-preserving steps,
   the pinning tests that must exist BEFORE the move, the risk, and the size (S/M/L).
   Top 5 only in detail; the rest as a one-line backlog.
4. **Design, not just mechanics (Rick 10/7: "not a slave to a low CCN").** For each of the top 5,
   name the real concept the split follows (an enum with associated values, a value type, a focused
   protocol, a pure function, an actor that owns state), cite the canonical source it rests on
   (Swift API Design Guidelines, The Swift Programming Language, Swift Concurrency, SwiftUI data
   flow, Apple sample code, NetNewsWire), and sketch the before/after type and function signatures.
   A step1/step2 chunking, a closure-lookup table hiding branches, or access widened just to split
   a file is a **rejected** plan, even if CCN falls. The gate blocks any rise in Σ max(0, CCN−15)
   across the touched files, so an honest split (52 → 26 + 26) passes.

## Schedule
(Tag format: `N<MMDD>-<theme>-<area>`.)

| Night | ID | Theme | Scope |
|---|---|---|---|
| 10-06 | N1006-D-next-refactors | D | Plan the NEXT local refactors (GH #281): `Archive/CopyFamilyAssessor.swift` (`assess` CCN 57) and `Catalog/CatalogAudit.swift` (`run` CCN 66). Both data-adjacent: list every guard and the pinning test that must exist before the split. (Catalog table is being refactored locally tonight, R1; don't plan it.) |
| 10-07 | N1007-D-Hallie-rewrite-eval | D | **Evaluate rewrite vs. refactor** of the Hallie question parsers: `HallieLineageQuestion.swift` (`get` CCN 93, `detectShape` 88), `HalliePersonaQuestion.init` (72), `HallieTurnExecutor+Relationship.executeRelationship` (50). Deliver: (1) what the corpora pin (`tests/hallie_eval_corpus.json`, `archivist_golden_answers.json`, `hallie_interaction_corpus.json`, `hallie_live_misses_corpus.json`): which parser branches no corpus entry reaches; (2) a sketch of a table-driven design (pattern → intent as data) with the same interface; (3) a back-to-back plan: old and new run side by side on every corpus entry, disagreements logged, switch when there are none; (4) a recommendation, rewrite or refactor, with a size estimate. **Python-runnable:** you may run scripts that read the corpora. |
| 10-07b | N1007-R-MediaOps-prune | R | MediaOps prune / relocate / purges / soft delete / junk + trash selection (the data-risk list in docs/guides/source_layout.md) |
| 10-07c | N1007-P-swift-playbook | P | **Draft `docs/practices/swift_playbook.md`** (Rick 10/7: "a good template for just about every kind of coding job"). For each job this app does repeatedly (long MFO operation; list/table over 100k records; ffmpeg/ffprobe call; SQLite/ledger write; settings pane; background analyzer/cycler; a decision with several outcomes; a Hallie query path), give: the pattern, a 15–30 line Swift skeleton, the canonical source it follows (named, as in theme D step 4), the smells to avoid, and the **best existing in-repo example** (file:line) plus the worst one that should migrate. Measure, don't guess: grep for each job's current implementations. One page per job, C++ analogies for Rick. This one writes a doc, not a report: commit it on `cloud/<id>` at that path. |
| 10-07d | N1007-D-Catalog-over-30 | D | Every **Catalog/** (+ `Model/`) function with CCN > 30 in `ci/baselines/complexity_debt.json`, aiming for zero over 30 before the M5 Ultra. Theme D in full, step 4 for every function, not just the top 5. Skip whatever a merged branch already changed (check `git log -- <file>` since 10-05). |
| 10-08 | N1008-T-Archive | T | `Archive/` and its tests |
| 10-08b | N1008-T-CheckMedia | T | The Check Media merge `df616324` (design doc `docs/design/check_media_and_menu_cleanup_2026_10_07.md`): every quick/full check rule in `CheckMediaRules` + `VerifyVideoRules`/`VerifyAudioRules` it reuses. For each threshold: which test goes red if it's deleted or loosened? A healthy file it could wrongly flag (a 120 fps phone clip, 4K HEVC at 100 Mbit/s, DV, a 1-frame still video, a VFR iPhone .mov, audio-only)? A broken file it could miss? Also check every reader of `audioVerify*`/`videoVerify*` (listed in the doc) still sees what it saw before. **Python-runnable:** you may write ffmpeg-free Python that re-implements a rule to probe edge values. |
| 10-08c | N1008-D-MediaVolumeGateHold | D | Plan moving the 7 MFO jobs that each copy the per-volume gate/pause code onto the shared `MediaVolumeGateHold` (added in `df616324`). Theme D in full with step 4: list each copy and how it differs (the differences ARE the risk), the pinning tests needed before each move, and the order (lowest data risk first). |
| 10-09 | N1009-D-Core | D | `VideoScan/VideoScanCore/Sources/` (highest Swift churn) |
| 10-10 | N1010-H-Volumes | H | `Volumes/` (scan engine, checkpoints, reachability, retire/delete scan target) |
| 10-11 | N1011-D-PrunePlan | D | Plan the refactor of `PrunePlan.plan` (CCN 52, data-risk: prune) and its file: every guard, its pinning test, behaviour-preserving steps. App Swift only (Rick 10/6: support scripts aren't measured) |
| 10-12 | N1012-R-FamilyTree-writes | R | FamilyTree pull/refresh + CyberBrain writers (source_layout data-risk list) |
| 10-13 | N1013-D-FamilyTree | D | `FamilyTree/` |
| 10-14 | N1014-H-MediaOps-jobs | H | MediaOps jobs that are not deletion: combine, transcode, trim, reformat, rebuild audio, rescue copy, publishers |
| 10-15 | N1015-T-MediaOps-delete | T | Delete Duplicates / Steward / prune tests |
| 10-16 | N1016-D-ArchiveAngel | D | `VideoScan/VideoScan/ArchiveAngel/` (high churn) |
| 10-17 | N1017-H-Archive | H | `Archive/` |
| 10-18 | N1018-D-MediaOps | D | `MediaOps/` |
| 10-19 | N1019-R-week | R | everything merged on main 10-12..10-18 under the data-risk folders (`git log`) |
| 10-20 | N1020-D-People | D | `People/` |
| 10-21 | N1021-H-Catalog | H | `Catalog/` (+ `Model/`) |
| 10-22 | N1022-D-Hallie-core | D | `Hallie/` top level (no sub-folders) |
| 10-23 | N1023-T-Volumes-Catalog | T | Volumes + Catalog tests |
| 10-24 | N1024-D-Hallie-subs | D | `Hallie/Voice`, `Hallie/Web`, `Hallie/Shell`, `Hallie/LLM` |
| 10-25 | N1025-H-People | H | `People/` |
| 10-26 | N1026-R-week | R | merged 10-19..10-25 under data-risk folders |
| 10-27 | N1027-D-Media | D | `Media/` + `Shared/` + `App/` |
| 10-28 | N1028-H-FamilyTree | H | `FamilyTree/` |
| 10-29 | N1029-D-small | D | `Steward/`, `FootageGroups/`, `Analyze/`, `FamilyMusic/`, `ModelsUI/` |
| 10-30 | N1030-T-python | T | `tests/*.py` vs `scripts/`, `tools/` (may RUN pytest) |
| 10-31 | N1031-H-Hallie | H | `Hallie/` |
| 11-01 | N1101-R-week | R | merged 10-26..10-31 under data-risk folders |
| 11-02 | N1102-D-whole | D | whole app: cross-folder duplication and the debt trend vs the first D nights |
| 11-03 | N1103-T-whole | T | the 15 most important guards in the app; is each pinned? |
| 11-04 | N1104-R-final | R | merged 11-01..11-03 + anything still open from earlier nights |

### Pipeline (Rick 2026-10-05)
Cloud D nights plan the next refactor; the M4 executes it the following night
(local brief in `docs/briefs/local/`, refactor → testing → qa, branch only); Rick
spot-tests the module in the morning, then it merges. Goal: the worst #281 offenders
refactored before the M5 Ultra arrives.

### Catalog note (R1, refactored locally 10-05; Rick 2026-10-05)
The Catalog window grew fast and was never refactored; arrow-key focus took
four commits to fix today. Spot measurements (lizard 1.22, 10-05):
`CatalogContent+Table.swift` `rowContextMenu` CCN 81 / 489 lines;
`CatalogView+VolumeTable.swift` `volumeContextCatalogSection` CCN 36 / 182 lines;
`CatalogHelpers.swift` holds 34 `@State` and the files table's `@FocusState`; the
volume table has no focus handling at all; Stage 0 measured `tableWithCatalogTriggers` at
21.7 s type-check. Note lizard undercounts SwiftUI computed `body`/`some View`
properties, so read those by eye.

**The behaviour the refactor must make easy (acceptance spec):** two panes,
volumes and files. A single click in a pane gives that pane the keyboard
and highlights its row; ↑/↓ then move within THAT pane only; double-click opens.
Today ↑/↓ always moves the files even after a click in the volume pane. The plan
should end with one focus owner (e.g. an `enum Pane` `@FocusState` that both tables
bind to), the selection/focus state collected out of `CatalogHelpers`, the giant
context menus split by section, and the modifier chain broken up. Also: the Analyze
tab (`AnalyzeCoverage.swift:291`, `AnalyzeReclaimable.swift:173`) still uses
longest-root-first drive matching while Delete uses first-in-list
(`VideoScanModel.duplicateVolumeRoot`): two answers to one question; include it.

The Manager may rewrite rows that haven't run yet, based on what earlier nights
found. If the cost per night or the share of findings that survive verification
looks poor after a week, the program pauses and the Manager asks Rick.
