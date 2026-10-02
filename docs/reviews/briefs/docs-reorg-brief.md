Codex implementation task — reorganize docs/ (Rick approved 2026-10-01). You EDIT in this worktree (branch chore/docs-reorg); you do not push, merge, or touch anything outside this worktree.

Goal: docs/ has ~150 tracked files, ~125 loose at the top level. Sort by kind so current docs stand out; retire finished ones to an archive. History must survive (use `git mv` only — never delete, never rewrite content beyond link/path fixes).

Target layout:
- docs/README.md — the index, regenerated: one line per doc grouped by folder, newest first within design/reviews.
- docs/guides/ — living theme guides (hallie.md, media-archive.md, testing.md, development.md, facial-recognition.md, source_layout.md, documentation-map.md, …).
- docs/practices/ — process and policy: software_dev_policy, overnight_themes, review/adversarial process, testing retrospectives, branching; create practices/invariants/ empty with a README placeholder (tonight's work fills it).
- docs/design/ — feature designs and plans (*_design_*, *_plan*, roadmaps), including existing docs/design/.
- docs/research/ — source surveys and API notes (irish_*, uk_scotland_*, familysearch_api_notes, existing docs/research/).
- docs/reviews/codex/ — codex-review-*.md; docs/reviews/briefs/ — merge docs/reviews/briefs/ and docs/reviews/briefs/; docs/reviews/qa/ — test-gap audits, QA reports; docs/reviews/adversarial/ — empty with README placeholder.
- docs/ops/ — morning reports, nightly notes, incident write-ups, perf/metrics/analysis snapshots (fold existing docs/perf, docs/metrics, docs/analysis, docs/poi-cycles under ops/ unless a script writes there — see below).
- docs/archive/2026-Q3/ (and 2026-Q2 etc. by the file's last-commit date) — superseded designs, handoffs, codex reviews whose cycle is closed AND older than 30 days, one-off reports. When unsure, keep it current (not archived) and list it in the report.
- Leave docs/team-channel/ where it is. Leave data files (*.jsonl, *.json, *.csv, dashboards) where code/tests read them unless you update every reader.

Mandatory reference rewrite: after the moves, `git grep` the WHOLE repo (Swift, Python, shell, plists, workflows, CLAUDE.md, .claude/, tests, scripts, tools) for every moved path and fix it. Special care:
- tools/codex_review.py writes `docs/reviews/codex/codex-review-<slug>-<date>.md` and reads briefs — change its default output dir to docs/reviews/codex/ and keep its tests green (pytest).
- Hallie test corpora / testbeds read under docs/ (e.g. docs/hallie_testbed.jsonl) — prefer leaving data files in place over moving them.
- Nightly scripts, morning hook (.claude/scripts/session_morning_hook.sh), metrics scripts, workflows.
- Swift tests that read docs (SourceTree helpers) — grep VideoScanTests and VideoScanCore/Tests for "docs/".

Add a link-check test: tests/test_docs_links.py (pytest, stdlib) that (a) scans all tracked *.md, *.py, *.sh, *.swift, *.yml, *.plist and CLAUDE.md for `docs/<path>` references and relative markdown links inside docs/, and fails on any target that does not exist; (b) has an allowlist file for intentional historical citations (e.g. the 9/16 documentation-map's retired-file list). Make it pass.

Verification you must run: `venv/bin/python -m pytest -q tests/` (report counts; pre-existing failures named, not fixed); the link check; `git status` clean after commit. Do NOT run xcodebuild or launch the app. If a Swift test reads a moved doc path, update the path string and say so (Claude will run the Swift suites).

Do not explore or change anything that is not a docs path or a reference to one. No content edits to docs beyond fixing links. Public repo: do not add any personal data.

Commit in logical steps (moves; reference rewrite; link-check test; README index), messages ending with 'Co-Authored-By: Codex <noreply@openai.com>'.

Final message: a report with (1) counts per destination folder, (2) every file archived, (3) every file you were unsure about and where you put it, (4) every reference rewritten outside docs/ (file list), (5) test results with counts.
