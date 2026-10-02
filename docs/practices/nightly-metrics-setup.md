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
