# Codex — the standing verdict per area

*One file, overwritten in place (CLAUDE.md: "a kept verdict is one file per area"; DECISIONS 2026-11-01). Written 2026-11-01 from the 28 pass transcripts of 2026-10-25 → 2026-11-01, which moved to `docs/archive/reviews/codex/` the same day; older passes (2026-09-07 → 2026-10-23) were retired on 2026-10-23 and are in git history (`git show pre-reset-2026-10-23:<path>`). `tools/codex_review.py` still writes a new pass to `docs/reviews/codex/` by default; when a pass closes, fold its line in here and move the transcript to the archive.*

How to read a row: the **last recorded verdict** is the one the newest transcript in that area printed (`Verdict: merge | fix | block`), and **closure** is what the transcript's own `## Closed` section, or the transcript that followed it, says. Where no closure is recorded, the row says so; it does not guess. Per PROCESS §5 a verdict and its closure also go in the PR or commit.

| Area | Passes (date) | Last recorded verdict | Closure, as recorded | Transcripts |
|---|---|---|---|---|
| Day 11/05 evening (codex fixes, gauntlet count, 14:00 testbed, scan tiles) | 4 (11/05, cycles #245 `2c8fa9777..b1709f7a3`, #246 re-review of `39cd17304`, #248 re-review of `79b47ae61`, #251 re-review of `8b542eaad`) | **block** (4: 1 P0, 3 P1) → **block** (5: 1 P0, 4 P1) → **block** (4: P0 "Gone" also fired on permission denied; P1 the lock lease ended with the shell while its work lived on; P1 the outer timeout dropped launch evidence; P2 a contaminated `swift test list` still launched tests) → **block** (4: P0 the second stat turned EACCES into "gone after the probe" → Still writing, zero errors; P1 the nightly watchdog's Popen dropped fd 9; P1 the m4_run caller checked out the SHA and booted the agent out before the host held the lock; P1 the severe-fix suites were `blocked` in the gauntlet) | Closed on `fix/codex-1105-evening`, all seventeen red-first. Round 4: `ScanFileStat.read` (stat(2) errno: gone vs inaccessible) drives the second stat too — inaccessible after ffprobe is "Not accessible" with launch evidence kept; the watchdog passes fd 9 on; the caller's steps are additive (per-run `bin/<stamp>`, per-run agent label, no bootout of a live agent) and the host checks the worktree out under the lock; ScanStillBeingWrittenTests + ProbeTimeoutRegressionTests execute in the regression stage (floor 446 → 471); the four Python suites stay blocked on GH #436 (no Python adapter in the gauntlet). Round 1: `ProbeOutcome.ffprobeRan`/`fileNotFound`, the "Gone" tile; XCTest from the runner's serial protocol; guard needs suite AND gauntlet rows, `--gauntlet-only`; one lock protocol. Round 2: `ffprobeRan` is `ProcessRunner.Result.launched`; a kernel `fcntl.flock` via `scripts/testbed_lock.py`; XCTest tally cross-checked against `swift test list` (outermost `All|Selected tests` bracket, last summary wins, disagreement = RED); the guard judges the latest row per kind. Round 3: stat(2) errno decides — only ENOENT/ENOTDIR is Gone, EACCES/EIO is "Not accessible" (an error with its reason, and still the unmount trail); the lock lives on the shell's fd 9 (`exec 9>>flock`, helper flocks the inherited fd and exits), so the kernel holds it until the last process holding the fd exits — the gauntlet in its own session included (`run_bounded` passes fd 9 on); the timeout race awaits the cancelled probe for its `launched`; a contaminated listing returns before launching tests. No fifth pass run | `docs/archive/reviews/codex/codex-review-day-11-05-evening-codex-fixes-gauntlet-count-14-00-testbed-scan-tiles-2026-11-05.md`, `…/codex-review-re-review-fixes-to-the-11-05-evening-findings-2026-11-05.md`, `…/codex-review-re-review-2-fixes-to-the-11-05-evening-findings-2026-11-05.md`, `…/codex-review-re-review-3-fixes-to-the-11-05-evening-findings-2026-11-05.md` |
| Realtime Content Analysis viewer (`feat/realtime-ca-viewer`) | 4 (11/05) | block (9) → block (6) → block (pass 3: 5 — a regrown day file kept as live, helper zeros before any read, an empty extraction still "ripping", a refused GPU entry dropped, a /dev/zero day file read forever) → **block** (final pass: 3 — P0 "Caption Videos" (`runBatch`) fed no lanes, rows or captions count; P2 a FIFO day file blocked `open()`; P2 the no-speech counter unasserted); zero tests executed by Codex (read-only sandbox) | Round 1: all 9 closed red-first (`VideoScanTests/RealtimeContentAnalysisCodexTests.swift`). Round 2: 3, 4, 5 closed red-first; 1, 2, 6 closed by dropping the "trying" tile (Rick's KISS). Round 3: all 5 closed — the incremental cursor replaced by a bounded re-fold from byte 0 (O_NOFOLLOW, regular file, 64 MB cap, bounded read loop), helper state unknown until evidence, an explicit `extractionDone` lane fact, GPU any-refused → absent; 1–3 seen red on `ceedb17e2`. Final pass: all 3 closed red-first — `runBatch` opens/closes a lane and completes through `completeDossierLane` (banking unchanged), `O_NONBLOCK` before the S_IFREG check, no-speech asserted after a real completion, a refused bank and an empty pass (red by mutation) | `codex-review-realtime-content-analysis-viewer-2026-11-05.md`, `codex-review-re-review-realtime-content-analysis-viewer-2026-11-05.md`, `codex-review-re-review-2-realtime-content-analysis-viewer-2026-11-05.md`, `codex-review-re-review-3-realtime-content-analysis-viewer-final-2026-11-05.md` |
| Checklist audit 11/03 (background, status split, count) | 8 closing passes (11/03) | fix (4 findings) → … → **merge** (0 findings) | Closed by `528d0746`, merged `f393a3ba` | `docs/archive/reviews/codex/codex-review-checklist-audit-11-03-closing-2026-11-03.md` |
| Background step 1 — journal applier (commit door for observations) | 1 (11/01) | **fix** — 10 findings (3 P1, 7 P2) | Closed by `caafc68d`: 10 of 10 fixed red-first; no re-review run | `codex-review-background-step-1-journal-applier-2026-11-01.md` |
| The 10/31 day (Confirmed Date filter table, timing judge, gated pause test) | 1 (10/31) | **merge** — one P2 | Closed by `33a41214`: the P2 fixed (reference-only wrapper records a hang off the reference run) | `codex-review-day-2026-10-31.md` |
| #401 scan location volume (Delete count vs removal planner) | 2 (10/30) + 5 (11/02, the strict rule: `VolumeIdentity.agree`, location memory, planner/apply/cleanup dialog) | 10/30: fix → **merge**; 11/02: block (3 P1) → block (1 P1, 2 P2) → block (1 P1) → block (1 P1) → **merge** (0 findings, cycle #213) | 10/30 cycle superseded by the closing pass; 11/02: every finding closed red-first (`449a4dbf`, `1a38a305`, `5abe84b1`, `dd072959`), merged `1d26583c`, #401 closed | `codex-review-401-scan-location-volume-2026-10-30.md`, `…-closing-2026-10-30.md`; 11/02 transcripts in `.scratch/reviews/codex-review-401-strict*-2026-11-02.md` (PROCESS §9) |
| `disk_check` (disk selection, remount safety) | 5 (10/29) | block → fix ×4 | Closed by `b3013d9d`: all 11 findings across 5 rounds pinned by tests; loop stopped at P2 | `codex-review-disk-check-2026-10-29.md`, `…-closing-…`, `…-closing2-…`, `…-closing3-…`, `…-closing4-2026-10-29.md` |
| Test-host guard on `MasterArchiveIcon` (#162) | 2 (10/28) | fix (1 P1) → **merge** | P1 fixed in `6c2226ef` (any `..` refused); closing pass merge | `test-host-icon-guard.md` |
| `TimingBudget` tier-aware busy rule | 1 (10/27) | **merge** (0) | — | `codex-review-timingbudget-tier-aware-busy-rule-2026-10-27.md` |
| Disk-full ballast fd leak (test-only) | 1 (10/27) | **merge** (0) | — | `codex-review-diskfull-ballast-fd-leak-test-only-2026-10-27.md` |
| Provenance ▸ Set Role (`provenance_roles` v13 and its one writer) | 2 (10/26) | fix (2) → **merge** (0) | F1 and F2 closed in the closing pass | `codex-review-provenance-set-role-2026-10-26.md`, `…-closing-2026-10-26.md` |
| Migrate safe-words + Trash only-copy re-check (adversarial P2 of 10/26) | 4 (10/26) | block ×3 → **merge** (round 4, 0) | Round 4: `2fc64fa34` closes the stale-source adoption P0; no new data-loss risk in `2a5bcde69..2fc64fa34` | `codex-review-adversarial-p2-2026-10-26.md`, `…-closing-…`, `…-round3-…`, `…-round4-2026-10-26.md` |
| Catalog open: checks in the writer's first lock, nothing deleted (#387); restore a missing `-wal` (#386) | 2 (10/26) | block (5) → **merge** (closing, 0) | F1/F4/F5 closed by the closing pass; #389 excluded as requested | `codex-review-store-open-387-386-2026-10-26.md`, `…-closing-2026-10-26.md` |
| Committer lost writes (#141 F2/F3 → #143 → #145) | 3 (10/25–10/26) | **block** (round 3: same-content inserts can still overwrite saved curation; scalar edits can still disappear or produce a false hold) | **No closure recorded.** STATUS 2026-11-01: branch `fix/committer-lost-writes-codex141` parked | `codex-review-committer-lost-writes-2026-10-25.md`, `codex-review-committer-refuse-and-name-2026-10-25.md`, `codex-review-committer-round3-2026-10-26.md` |
| Catalog store consistency and durability (#141 F1/F4/F6) | 3 (10/25) | **block** (third pass, F6 admission: cleanup can unlink live SQLite sidecars; admission can let an unchecked state reach a writer) | **No closure recorded in these transcripts.** The store-open work (#387/#386) that followed on 10/26 closed merge; whether it closes F6 is not written down — check before relying on it | `codex-review-catalog-store-consistency-2026-10-25.md`, `codex-review-store-durability-closing-2026-10-25.md`, `codex-review-store-durability-third-2026-10-25.md` |
| Editor render caches + Tidy set-aside (#383) | 1 (10/25) | **fix** (3: symlinked roots bypass exclusion; filename/size collisions; resume omits cache skips from its audit) | No closing pass recorded; round-2 pins are in `VideoScanTests/EditorCacheCodexRound2Tests.swift`; DECISIONS 2026-10-25 (two lines) rule the policy | `codex-review-383-editor-caches-2026-10-25.md` |
| Swift 6 language mode — data-risk isolation edits (stages 5–7) and the flip (stage 8) | 2 (10/25) | **merge**, **merge** (0, 0) | Stage 8 verdict asked for the exact-HEAD sensor run to finish GREEN | `codex-review-swift-6-stage-5-7-data-risk-isolation-edits-2026-10-25.md`, `codex-review-swift-6-stage-8-flip-2026-10-25.md` |

**Open on the record (needs a closing pass or a written decline):** committer lost writes (block), store durability F6 admission (block), #383 editor caches (fix). Everything else above ends at merge or at a recorded closure.

All transcripts are under [`../archive/reviews/codex/`](../archive/reviews/codex/), names unchanged.

## The brief template

*Moved here on 2026-11-01 from `reviews/BRIEF_TEMPLATE.md` (now `docs/archive/reviews/BRIEF_TEMPLATE.md`) (text unchanged except the contracts pointer, which now names `docs/ARCHITECTURE.md` §10, where `DESIGN.md`'s contracts went).*

# Codex review brief — <title>

*Copy to `.scratch/briefs/<slug>.md`, fill in, run `python3 tools/codex_review.py --title "<title>" --range <a>..<b> --brief <path>`. The brief is not committed; the verdict and closure go in the PR or commit.*

**Workflow in one sentence (the user's words):** <e.g. "move the extra copies of promoted files to the Trash">

**Range:** `<sha>..<sha>` on branch `<name>` · **Worktree:** `<abs path>`

**In scope (read these and their direct callers; nothing else):**
- `<path>` — `<functions>`
- `<path>`

**Invariants to attack** (one line each; cite `docs/ARCHITECTURE.md` §10 "Contracts"):
1. <e.g. "Prove the surviving copy exists and matches by full SHA-256 at the moment of the move to the Trash; show me a path where it doesn't.">
2.
3.

**Evidence already run:** <suites and counts; sensor lane line; red/green table reference>

**Known and accepted (do not report):** <deliberate limitations, with who accepted them>

**Output contract:**
```
Credits spent: <amount> | Finding count: <N>
Verdict: merge | fix | block — <one sentence>
```
Then findings ranked by data-loss risk, each with `file:line`, a reproduction, and a RED test where possible. For every in-scope file with nothing to report write "read, no findings." Do not explore outside the files above unless a finding requires it, and say so.
