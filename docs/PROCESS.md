# How work moves — VideoScan

Short on purpose. `CLAUDE.md` holds the hard rules; this is the procedure around them. Changes to this file go through Rick.

## 1. Roles and sessions

| Who | Owns |
|---|---|
| Rick | Direction, workflow and UI/UX (Apple HIG and best-in-class references), archival policy, spot tests, tie-breaks, waivers. Builds and runs the app himself. |
| Claude (the working session) | Implementation, models, algorithms, code quality, tests. Reads the code it changes. Research → propose → proceed on internals; stop and ask only for the escalation list (§6). |
| `reviewer` agent | Read-only, fresh context: behaviour findings as RED tests + Swift design grade. Never edits production code. |
| `worker` agents | Parallel, file-disjoint tasks and the night shift, each in its own worktree. Same rules as the working session. |
| Codex | Independent reviewer (other model family) for data-risk paths; test help. Runs headless via `tools/codex_review.py`. |

**One developer, not a manager.** The working session does the work and understands the code. It delegates only when tasks are file-disjoint or when a fresh, uninvolved reader is the point (review). It never hands a cold agent a task it has not scoped against the code itself.

**One task per session.** Start a session with the task; finish with a merge or a `docs/STATUS.md` update; `/clear`. Anything over a couple of files starts in plan mode: shape first (which types own which state, which module, which seam), then code. If Rick floats an idea mid-task, it goes to `docs/BACKLOG.md` in one line and the task continues.

## 2. The merge gate

A branch merges to `main` when all of these hold (Rick may waive any to break a logjam):

1. **Fresh main first.** Merge latest `main` into the branch; the suite is green there.
2. **Tests exist.** Feature → the five dimensions that apply. Fix → a regression test seen red on the broken code, then green (red/green table in the commit or PR).
3. **Sensor lane GREEN** on the exact tree being merged: `scripts/run_sensors.sh --derived-data <dd>`. Catalog work also runs `scripts/run_catalog_tests.sh`. A zero-test run is red.
4. **Independent review** on data-risk code (map: `docs/ARCHITECTURE.md` §Data-risk): the `safety-critical` skill was followed and a scoped Codex pass closed (each finding fixed with a pinning test, or declined in writing). Other code: `reviewer` agent when the change is large; otherwise tests plus Rick's spot test.
5. **Rick's spot test** of the affected surface for anything he can see.

Docs-only commits (`docs/`) and metrics/CI publishes go straight to `main`. Everything that touches code takes the gate.

## 2a. The change checklist (Rick 2026-11-03)

Pre-flight questions before a code commit, not a gate: asked so an interruption can't make us skip one, because
doing it right first is faster. End the commit message with `Checklist: ✓`, or `Checklist: ✓ — skipped <item> (why)`.
What the hooks already enforce (sensor lane, complexity, SwiftLint, gauntlet manifest) is not on the list.

1. **CLEAN.** Is the code cohesive and clean, or does it add tech debt? KISS.
2. **REVIEWED.** Has it been adversarially reviewed? Fresh eyes (the `reviewer` agent), and Codex where data is at risk (§5).
3. **TESTED.** Is it testable, are tests written, do they pass? Is the real call site exercised, not just the unit? A regression test goes red, then green.
4. **WORKFLOW.** Especially for UI/UX: does it keep the workflow natural, or could it confuse the user? Do the build, run or spot-test steps given to Rick actually work?
5. **LOGGING.** Does it log the right amount? Every failure the user can see is also logged, with why and where.
6. **PERFORMANCE.** Does it leverage the silicon (unified memory, GPU/ANE, parallel lanes, another Mac over TB5), with a measured number where speed matters?
7. **TRUE.** Is it true to the feature and to the facts on the ground (the database, the disks)? Every fact shown comes from evidence, and no path can lose or misfile media.

## 3. Git

- `~/dev/VideoScan` is Rick's checkout. Agents work in a `git worktree` with its own `-derivedDataPath`; the worktree and its DerivedData are removed after merge.
- Branch for anything beyond a one-line tweak: `feature/…`, `fix/…`, `refactor/…`, `test/…`, `experiment/…`.
- Push `main` without asking. Never force-push or rewrite history (CLAUDE.md rule 11). No routine "merge `main` into the branch" step: good tests make it overkill (Rick, 2026-11-04); use judgement on a long-lived branch.
- Conventional, honest commit messages (`feat:`, `fix:`, `test:`, `docs:`, `refactor:`). A fix's message carries its red/green table.
- Never delete files; move to `.trash/`. Rick empties it.
- Tag before anything structural: `git tag pre-<thing>-<date>`.
- CLEANUP after merge, after merging a branch which passes all related tests and/or gets the OK from Rick should be deleted, worktrees etc, deleted.

## 4. Testing

- **Five categories** (`docs/guides/testing.md`): unit · regression sensor · integration (gauntlet) · performance · stress.
- **Five dimensions per change** (`docs/guides/testing.md`): logic · scale (100k synthetic rows, explicit budget) · media matrix (mp4/h264, mov/prores, mkv/ffv1+pcm, mxf, avi/dv) · isolation (poisoned state; never real prefs/paths) · a production-scale sensor.
- **Red first, always.** Fix → test → revert fix → see red → restore → commit both. A test that never failed is theater. Reviewers deliver reproducible findings as the red test, not prose.
- **Severe bugs** also get a production-shape test on a `.backup` copy of the live catalog and a selector in the gauntlet regression stage (`scripts/gauntlet/manifest.json`), never `blocked`.
- **Lanes:** `run_sensors.sh` (pre-merge, ~70 s) → `run_catalog_tests.sh` (catalog work) → full Debug suite on the fleet → Release gauntlet in the away window → 02:00 nightly (metrics, complexity gate, adversarial review). GitHub CI is lint/static/metrics only; Apple-silicon hardware is the authority for test results.
- **Every lane prints a number a person can audit** (tests executed, failures named). No number means red: zero tests ran is red, a build failure in a confirm step is red, a `| tail` that hid the exit code is red.
- Don't test Apple's frameworks or SwiftUI layout. Test our logic: parsers, scoring, state machines, persistence, the commit door.
- **Static signal, every commit:** strictest compiler settings and Swift 6 strict concurrency, SwiftLint, Periphery, the complexity gate (CCN 30 / 300 lines blocks; CCN-15 excess ratchets down) and per-module grades A–D on the metrics page. An F never reaches the repo (Charter §3.1). Coverage is measured, not targeted.

## 5. Review and Codex

- A code path that refuses and names another engine ("needs the dedicated X") must call that engine, with a test that goes through to it.
- **When Codex:** paths where a miss costs data (delete/move/rewrite of media, ledger, archive, fixity, resume/recovery, catalog commit). UI, wording, ranking heuristics, docs, tests-only: `reviewer` agent + Rick.
- **Cheap tiers first:** compiler + strict concurrency + SwiftLint → `reviewer` agent → Codex. One Codex pass per batch of merged SHAs, never per commit.
- **Brief shape** (keeps Codex inside the fence): SHA range · exact files/functions · the invariant to attack · test evidence already run · output contract (`Credits spent: … | Finding count: N`, `Verdict: merge|fix|block`) · "do not explore outside these files." Template: `docs/reviews/codex.md`.
- **Loop rule:** fix each finding red-first; **close a finding against the invariant, not the example** (a "narrower case remains open" keeps the batch blocked); stop when findings fall to P2 and the core path is covered; file what's left as issues. After two rounds landing in machinery the one-sentence workflow didn't need, re-scope smaller.
- **Where it lands:** the verdict and closure go in the PR/commit; `docs/reviews/<area>.md` is overwritten with the latest state only when Rick wants a record. No per-pass files.
- Codex's instructions are `AGENTS.md`, which points at `CLAUDE.md`; both agents read one rulebook.

## 6. Escalate to Rick before
New dependencies · any schema change (additive only, through a migration; Rick approves the DDL — CLAUDE.md rule 6) · threading-model changes · replacing `ExecuteShellCommand`/`ProcessRunner` · anything touching recovered MXF pair data · log paths or formats · anything irreversible against the live catalog or the archive · removing a feature. Everything else: research, propose, proceed.

## 7. Rhythm

- **Weekly theme.** One `theme:` label and one tracker issue per week; Monday triage picks it from the trackers. Ideas filed mid-week get the label or wait for Monday. `docs/STATUS.md` names the theme.
- **Zero P0 by Friday noon**, every Friday (fix it, prove it is not P0, or say by noon it will miss). **Monday:** every P1 triaged (fix this week or schedule). P0 = integrity loss or an unverified fact shown as truth; P1 = triaged weekly.
- **Modes.** Normal: small steps with tests. **RD** (Rick says "RD"): build-only fast iteration on UI, full suite as the day's bookends. **Night shift:** one theme, one owner, worktrees only, the checkout on `main` by 02:00, nothing deletes overnight except scratch.
- **Session start** shows `docs/STATUS.md`'s header, P0/P1 counts and last night's lane results (`.claude/scripts/session_start.sh`). No ritual questions.

## 8. Machines
Rick's machine (the M5 Ultra from 2026-10-28; the M4 Studio until then) is interactive ~11:00–19:00 ET: rapid dev with Claude, nothing else. No UI automation, app launches, model runs or heavy test loads there without a **declared window** ("having lunch, back in an hour" = one hour of testbed, not more); "I'm going for a walk" is not a window, Rick comes and goes. **The M4 is the default testbed** (Rick, 2026-10-31): full suites, gauntlet, evals, long builds run there — push main first, pull it on the M4, run against that commit, and name the commit in the report. M5 Pro laptop and M1 take overflow. When Rick says "run the gauntlet / the testbed" and names no machine, the M4 is the answer; a one-line "On the M4?" before starting is fine, running on the Ultra by assumption is not. Say which machine a long job uses before it starts. Nightly 02:00 on the rotation; restore the RAM disk before Rick's day.

## 9. Documents
- About 25 live files, about five per area (DECISIONS 2026-11-01); `docs/README.md` is the map and `tests/test_docs_shape.py` keeps the ceiling (30) and the design `Status:` lines honest.
- Living set, rewritten in place: `CLAUDE.md`, `AGENTS.md`, `docs/Purpose-and-Charter.md`, `docs/ARCHITECTURE.md` (with the contracts, §10), `docs/PROCESS.md`, `docs/STATUS.md`, `docs/DECISIONS.md` (append-only, dated), `docs/BACKLOG.md`.
- Reference: `docs/guides/` (developer, testing, operations, the media archive, provenance roles). A guide is written when a reader would otherwise have to read code.
- `docs/design/<subsystem>.md`: one live doc per subsystem, opening with a summary and `Status: built | in flight | parked` and the date; a new approved design joins its subsystem's doc. A design that is superseded or wholly built is deleted when built; git keeps it (tag `pre-prune-<date>` at each prune; `docs/README.md` §Retired documents says how to list and read them). Research notes live in `.scratch/` and are deleted once a design has taken what is true.
- Everything transient (briefs, morning notes, handoffs, review transcripts, cloud routine prompts) lives in `.scratch/` and is not committed. If a doc is wanted a week later, it belongs in the living set.
- Memory (`~/.claude/projects/…/memory/`) holds nothing a session needs to be correct. Rules → this file. State → `STATUS.md`. Rulings → `DECISIONS.md`.

IMPORTANT NOTE: Rick has a lot of ideas, many discussions with Claude, sometimes Codex, possible users, plus all the other normal dev process, of bug fixing, etc., so we tend to accumulate
a lot of docs and other memories so we periodically must prune and delete outdated, superseded, defunct ideas, experiments, etc. Since git stores everything, we should try to keep
our dev and doc files cleaned up, pruned, and only relevant files kept. Software entropy and doc entropy can generate a lot of extra cruft that we don't need, so to combat this we will:
1. Periodically review the docs dir, say once a week, maybe Monday mornings and remove docs we're not using anymore. Like I said we have git.
2. If Rick says the same thing three times in different words, most likely we already have it written down, so don't write it down again.
3. KISS principle on docs, consolidate similar ideas into one larger doc with the same theme rather than having 4-5 docs discussing slightly different themes.
4. We try to keep the doc count to a reasonable number, imagine you're a new experienced engineer who has to wade through all these, have mercy, KISS.
5. PDF Visuals, PPT, or other visual aids are helpful to Rick, as a human, he needs pictures sometimes and reading 25 MD files when a few pictures might help is appreciated.
