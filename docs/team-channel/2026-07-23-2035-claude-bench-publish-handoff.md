---
from: claude
to: codex
re: 2026-07-23-2029-claude-perf-bench-script-hardened.md
date: 2026-07-23T20:35-04:00
---

# Bench metrics publishing built — series is live, handing off to you

Follow-up to the hardening note: the `metrics/benchmarks.jsonl` series now
exists and the first row is published. Rick's directive: you own bench-summary
posting from here.

## What's built (on main, `scripts/`)

- **`publish_bench_metrics.py`** — parses a benchmark results file into one
  JSONL row and appends it to `metrics/benchmarks.jsonl` on `origin/metrics`
  via a **detached** worktree (never checks out the `metrics` branch — the
  nightly job owns a permanent worktree on it). `--dry-run` prints the row
  without pushing. Refuses to publish a results file with no measurements.
- **`run_generated_media_perf.sh --publish`** — runs the benchmarks and, only
  on a fully successful run, publishes the row. So your loop is one command:

  ```
  scripts/run_generated_media_perf.sh --file-count 1000 --duration 10 --time-limit 60 --publish
  ```

## Row schema (v1)

```json
{"schemaVersion":1,"ts":"…Z","host":"RicksM4","sha":"64fd4a1","branch":"main",
 "fileCount":12,"fileDuration":1.5,"resolution":"640x360",
 "probe":[{"concurrency":1,"coldSeconds":…,"coldFilesPerSec":…,"coldPlayable":…,
           "warmSeconds":…,"warmFilesPerSec":…,"warmPlayable":…}],
 "prefetch":{"frames":…,"seconds":…,"fps":…,"avgDecodeMs":…}}
```

Host + sha + corpus params are in every row so numbers stay comparable —
only compare rows with matching host/fileCount/fileDuration. First row
(12×1.5s on M4, sha 64fd4a1) is already on the branch as a shape reference.

## Yours from here

- Re-run the big corpus on the hardened script (see prior note; consider
  1000×10s instead of 1000×100s) and publish rows on whatever cadence you
  land for trend tracking.
- If you extend the schema, bump `schemaVersion` and note it here.
- Optional, your call: chart the series on the GH Pages dashboard and/or fold
  it into `morning_metrics.sh` — nothing reads `benchmarks.jsonl` yet.

— claude
