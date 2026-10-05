# Nightly cloud pass: review / test / harden / refactor (2026-10-06 → 2026-11-04)

Rick starts ONE cloud session each evening (claude.ai/code, repo
musicalengineer/VideoScan) with the same line every night:

    Run docs/briefs/cloud/NIGHTLY.md

**Session: what to do.** Read `docs/briefs/cloud/README.md` (standing rules:
read-only, one report, branch `cloud/<id>`, header shape, hard-to-refute bar, 45-min box).
Then pick **tonight's row** below: the row dated today (US Eastern). If that row is
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
1. `pip install lizard` and run it on the scope: list functions with CCN > 15 or
   length > 80 lines, and files > 800 lines.
2. Find duplicated logic (two functions that answer the same question differently
   are the debt that bites: the C01-F1 class), dead code (no callers: grep),
   leftover `TEMPORARY`/diag code, stale TODOs, flags that are always on.
3. Write a **ranked refactor plan**: for each item, the behavior-preserving steps,
   the pinning tests that must exist BEFORE the move, the risk, and the size (S/M/L).
   Top 5 only in detail; the rest as a one-line backlog.

## Schedule
(Tag format: `N<MMDD>-<theme>-<area>`.)

| Night | ID | Theme | Scope |
|---|---|---|---|
| 10-06 | N1006-D-ArchiveAngel | D | `VideoScan/VideoScan/ArchiveAngel/` (high churn) |
| 10-07 | N1007-R-MediaOps-prune | R | MediaOps prune / relocate / purges / soft delete / junk + trash selection (the data-risk list in docs/guides/source_layout.md) |
| 10-08 | N1008-T-Archive | T | `Archive/` and its tests |
| 10-09 | N1009-D-Core | D | `VideoScan/VideoScanCore/Sources/` (highest Swift churn) |
| 10-10 | N1010-H-Volumes | H | `Volumes/` (scan engine, checkpoints, reachability, retire/delete scan target) |
| 10-11 | N1011-D-python | D | `scripts/`, `tools/` (highest churn overall; may RUN pytest/ruff) |
| 10-12 | N1012-R-FamilyTree-writes | R | FamilyTree pull/refresh + CyberBrain writers (source_layout data-risk list) |
| 10-13 | N1013-D-FamilyTree | D | `FamilyTree/` |
| 10-14 | N1014-H-MediaOps-jobs | H | MediaOps jobs that are not deletion: combine, transcode, trim, reformat, rebuild audio, rescue copy, publishers |
| 10-15 | N1015-T-MediaOps-delete | T | Delete Duplicates / Steward / prune tests |
| 10-16 | N1016-D-Catalog | D | `Catalog/` |
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

The Manager may rewrite rows that haven't run yet, based on what earlier nights
found. If the cost per night or the share of findings that survive verification
looks poor after a week, the program pauses and the Manager asks Rick.
