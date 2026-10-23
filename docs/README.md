# VideoScan documentation

Rick's charter, eight living files rewritten in place, and reference guides. Everything else is history under `archive/`.

| Read it when | File |
|---|---|
| First, and whenever direction is in doubt | [`Purpose-and-Charter.md`](Purpose-and-Charter.md) — Rick's purpose, the tabs, INGEST → MANAGE → ARCHIVE, process expectations, in his words (Rick edits this; agents don't) |
| Starting any session | [`STATUS.md`](STATUS.md) — this week's theme, what is in flight, next steps, open rulings |
| Before touching code | [`ARCHITECTURE.md`](ARCHITECTURE.md) — INGEST → MANAGE → ARCHIVE, tabs, subsystems, data-risk map |
| Before changing a module | [`DESIGN.md`](DESIGN.md) — the contracts each module keeps |
| Before merging, reviewing, or planning the week | [`PROCESS.md`](PROCESS.md) — merge gate, tests, Codex, rhythm, machines |
| Before proposing something "new" | [`DECISIONS.md`](DECISIONS.md) — dated rulings; settled is settled |
| When an idea arrives mid-task | [`BACKLOG.md`](BACKLOG.md) — park it in one line |
| To remember why | [`project_goals.md`](project_goals.md) — Rick's seven goals and Hallie's purpose |
| Standing rules for every agent | [`../CLAUDE.md`](../CLAUDE.md) (and `../AGENTS.md`, which points to it) |

## Reference guides (`guides/`)
Read on demand; correct but not load-bearing for every task. `source_layout.md`, `media-archive.md`, `testing.md`, `gauntlet.md`, `Avid-Format-Reverse-Engineering.md`, `archive_angel_policy.md`, `date_inference_catchup_and_propagation.md`, `drive_health.md`, `notes_authorship.md`, `gedcom.md`, `hallie.md` (paused), `facial-recognition.md` (frozen), and `guides/ops/` (test-Mac setup, gauntlet TCC, M1 runner, lldb control, storage layout, TB5 diagnostics, Python paths, complexity counter). The catalog schema is `design/catalog_sqlite_schema_v1.sql` (+ `_checks.sql`); a reader's page over it is on the docs-to-write list in `BACKLOG.md`.

## Current designs (`design/`) and research (`research/`)
One file per approved design still being built; retired to `archive/` when built or dropped. `design/October_Design_Retrospective.md` is the long form of `ARCHITECTURE.md` and holds Rick's open design questions.

## Practices (`practices/`)
`swift_playbook.md` (patterns and the in-repo exemplars), `testing_retrospective_2026_07_05.md` (the five dimensions), `invariants/` (what the nightly adversarial review attacks).

## Reviews (`reviews/`)
`BRIEF_TEMPLATE.md` for Codex briefs. Verdicts live in PRs and commits; a review record Rick wants kept is one file per area, overwritten.

## Archive (`archive/`)
Retired documents live in git history, not in the tree: `archive/INDEX-2026-10-reset.md` lists every file retired on 2026-10-23 and why; `git show pre-reset-2026-10-23:<path>` prints any of them. `archive/RETIRED.txt` is the machine-readable list the docs link checker consults, and `archive/retired-2026-10-reset.zip` (gitignored) is a convenience copy.
