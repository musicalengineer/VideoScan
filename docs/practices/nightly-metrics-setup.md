# Metrics: what feeds the metrics page

Rewritten 2026-10-02 when the one metrics page replaced the old dashboard. The
previous version of this file described the TestDriver 2 AM job
(`.claude/scripts/nightly-testdriver.sh`), which stopped running in June 2026
and was removed; it is in git history if ever needed.

**The page:** https://musicalengineer.github.io/VideoScan/ (source `docs/index.html`,
served by GitHub Pages from `main:/docs`). It is static: at load it fetches the
`metrics` branch from raw.githubusercontent.com and the public GitHub Actions
API. No login, works from a phone. Anything older than 36 hours is marked STALE;
a metric with no data says "no data yet", never zero.

## Streams on the `metrics` branch

| File | Written by | When |
|---|---|---|
| `metrics/history.jsonl` | `.github/workflows/ci.yml` running `scripts/collect_metrics.sh` | every push to main |
| `metrics/static_analysis.jsonl`, `metrics/nightly_findings_latest.json` | `.github/workflows/nightly-analysis.yml` (aggregate job) | GitHub nightly |
| `metrics/testdriver.jsonl` | `scripts/nightly_local_tests.sh` (launchd `com.videoscan.nightly-tests`), TestDriver's Publish, the gauntlet | 2 AM nightly; ad hoc |
| `metrics/coverage.jsonl` | `tools/publish_metrics.py`, called by `tools/nightly_coverage.py` | after the 4 AM coverage run |
| `metrics/adversarial.jsonl` | `tools/publish_metrics.py`, called by `tools/adversarial_nightly.py confirm` | after the 05:30 confirm |
| `metrics/codex_reviews.jsonl` | `tools/publish_metrics.py` (parses `docs/reviews/codex/*.md` headers) | with either of the two above |
| `metrics/search_benchmarks.jsonl` | `scripts/publish_search_benchmarks.py` | when the benchmark is run |
| `metrics/complexity.jsonl`, `metrics/complexity_debt_latest.json`, `metrics/complexity_baseline_proposed.json` | `nightly-analysis.yml` `complexity` job → `aggregate` (`scripts/complexity_metrics.py`) | GitHub nightly |

## Complexity and tech debt (2026-10-05, GH #281)

- **Nightly (report only).** `scripts/complexity_metrics.py` runs lizard 1.22.1 over
  Swift (`VideoScan/VideoScan`, `VideoScanCore/Sources`, `swift_cli`) and Python
  (`scripts`, `tools`). Per folder (same keys as `swift_by_folder`): functions, mean
  CCN, CCN > 15, NLOC > 80, files > 800 lines; totals; top 15; duplication (lizard
  `-Eduplicate`, pure Python). The ratchet lists NEW offenders (CCN > 15 or NLOC > 80,
  not on the baseline) and WORSE ones; the morning digest prints them plus any gate
  override from the last 48 h. Stock lizard ignores Swift computed properties; the
  script teaches it `var body: some View {` so SwiftUI bodies are measured.
- **Gate (blocking).** `scripts/complexity_gate.py --staged` in the pre-commit hook and
  `--all` in CI preflight: a function over CCN 30 / 300 lines that is new or worse than
  the baseline, or a new `swiftlint:disable` of cyclomatic_complexity /
  function_body_length / file_length / type_body_length, fails. Escape hatch:
  `COMPLEXITY_OVERRIDE="reason" git commit …`, appended to
  `ci/baselines/complexity_overrides.jsonl` (staged into the commit; CI honors it).
- **Baseline.** One committed file, `ci/baselines/complexity_debt.json`. It only shrinks:
  the nightly publishes the shrunk proposal; `python3 scripts/complexity_metrics.py
  --shrink-baseline` applies it locally for a commit. Re-grow only deliberately with
  `--update-baseline`.
- After pulling this change, run `scripts/install-git-hooks.sh` once per clone: the
  hook in `.git/hooks` is a copy.

Why `coverage_logic_pct` / `swiftlint_*` in `history.jsonl` looked broken: coverage is
deliberately off in ci.yml (`-enableCodeCoverage NO`, 2026-09-26), and
`collect_metrics.sh` turned "no data" into `0` (fixed: now null). SwiftLint left ci.yml
on 2026-06-02 (5d2e9c23); its nightly count is `swiftlint_strict` in
`static_analysis.jsonl`, so the per-push fields are null by design.

## The local publisher (`tools/publish_metrics.py`)

Coverage and the adversarial ledger exist only on the M4, so one publisher pushes
a sanitized copy of them.

- **Privacy gate.** The repo and page are public. Every row is checked against an
  allowlist schema before anything is written: numbers, dates, source-folder
  names, tool names and severity keys only. Finding titles, paths, test names,
  hosts and person names never leave the machine. A row that fails the gate stops
  the whole publish (exit 3).
- **Git.** It works only in its own detached worktree,
  `~/Library/Caches/VideoScan/metrics-publish-wt`. The main checkout is asked
  only to `worktree prune` and `worktree add` (to create it). It pushes
  `HEAD:refs/heads/metrics` and never forces it; on a rejected push it refetches and
  retries.
- **Logs.** The last stdout line is `OUTCOME …`; the callers write it to
  `coverage.log` and `adversarial_review.log`.

```bash
python3 tools/publish_metrics.py --dry-run          # show exactly what would be published
python3 tools/publish_metrics.py                    # publish now
VIDEOSCAN_PUBLISH_METRICS=0 …                       # turn it off for one run
```

Tests: `tests/test_publish_metrics.py` (privacy proof, fake-git seam, one real-git
round trip against a local bare repo) and `tests/test_metrics_dashboard.py`
(runs the page's script under node).

## Morning digest

`scripts/morning_metrics.sh` (run by `.claude/scripts/session_morning_hook.sh`)
prints the per-host test table from the same branch in the terminal.
