#!/usr/bin/env python3
"""Parse a generated-media benchmark results file and publish one JSONL row
to metrics/benchmarks.jsonl on the metrics branch.

Usage:
  scripts/publish_bench_metrics.py /path/to/results.txt [--dry-run]

Normally invoked via scripts/run_generated_media_perf.sh --publish, which
passes the per-run results file. Refuses to publish if the results contain no
measurements. Uses a DETACHED worktree for the metrics branch — the nightly
job keeps a permanent worktree checked out on `metrics`, so never
`git checkout -B metrics` from here.
"""

from __future__ import annotations

import argparse
import datetime
import json
import re
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
METRICS_FILE = "metrics/benchmarks.jsonl"

CORPUS_RE = re.compile(
    r"VIDEOSCAN_PERF catalog probe corpus: (\d+) file\(s\), ([\d.]+)s, (\S+)"
)
PROBE_RE = re.compile(
    r"VIDEOSCAN_PERF catalog probe c=(\d+) "
    r"cold ([\d.]+)s ([\d.]+) files/s \((\d+) playable\) \| "
    r"warm ([\d.]+)s ([\d.]+) files/s \((\d+) playable\)"
)
PREFETCH_RE = re.compile(
    r"VIDEOSCAN_PERF frame prefetch: (\d+) frames in ([\d.]+)s = ([\d.]+) fps, "
    r"avg decode ([\d.]+)ms/frame"
)


def git(*args: str, cwd: Path = ROOT) -> str:
    return subprocess.run(
        ["git", *args], cwd=cwd, check=True, capture_output=True, text=True
    ).stdout.strip()


def parse_results(path: Path) -> dict:
    row: dict = {"probe": []}
    for line in path.read_text().splitlines():
        if match := CORPUS_RE.search(line):
            row["fileCount"] = int(match.group(1))
            row["fileDuration"] = float(match.group(2))
            row["resolution"] = match.group(3)
        elif match := PROBE_RE.search(line):
            row["probe"].append({
                "concurrency": int(match.group(1)),
                "coldSeconds": float(match.group(2)),
                "coldFilesPerSec": float(match.group(3)),
                "coldPlayable": int(match.group(4)),
                "warmSeconds": float(match.group(5)),
                "warmFilesPerSec": float(match.group(6)),
                "warmPlayable": int(match.group(7)),
            })
        elif match := PREFETCH_RE.search(line):
            row["prefetch"] = {
                "frames": int(match.group(1)),
                "seconds": float(match.group(2)),
                "fps": float(match.group(3)),
                "avgDecodeMs": float(match.group(4)),
            }
    if not row["probe"] and "prefetch" not in row:
        raise SystemExit(
            f"error: no benchmark measurements parsed from {path} — refusing to publish"
        )
    return row


def build_row(results_path: Path) -> dict:
    row = {
        "schemaVersion": 1,
        "ts": datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z"),
        "host": socket.gethostname().split(".")[0],
        "sha": git("rev-parse", "--short", "HEAD"),
        "branch": git("rev-parse", "--abbrev-ref", "HEAD"),
    }
    row.update(parse_results(results_path))
    return row


def publish(row: dict) -> None:
    subprocess.run(
        ["git", "fetch", "origin", "metrics", "--quiet"], cwd=ROOT, check=False
    )
    # Base on local metrics branch if it's strictly ahead of origin (nightly
    # may have unpushed rows); otherwise origin/metrics.
    base = "origin/metrics"
    try:
        git("merge-base", "--is-ancestor", "origin/metrics", "refs/heads/metrics")
        if git("rev-parse", "refs/heads/metrics") != git("rev-parse", "origin/metrics"):
            base = "refs/heads/metrics"
    except subprocess.CalledProcessError:
        pass

    with tempfile.TemporaryDirectory() as wt:
        git("worktree", "add", "--detach", wt, base, "--quiet")
        try:
            wt_path = Path(wt)
            target = wt_path / METRICS_FILE
            target.parent.mkdir(exist_ok=True)
            with target.open("a") as handle:
                handle.write(json.dumps(row, separators=(",", ":")) + "\n")
            git("add", METRICS_FILE, cwd=wt_path)
            git(
                "commit", "-m",
                f"bench: {row['sha']} {row['host']} "
                f"{row.get('fileCount', '?')}x{row.get('fileDuration', '?')}s [skip ci]",
                "--quiet", cwd=wt_path,
            )
            git("push", "origin", "HEAD:metrics", "--quiet", cwd=wt_path)
        finally:
            subprocess.run(
                ["git", "worktree", "remove", wt, "--force"],
                cwd=ROOT, check=False, capture_output=True,
            )
            subprocess.run(["git", "worktree", "prune"], cwd=ROOT, check=False)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("results", type=Path, help="benchmark results file")
    parser.add_argument(
        "--dry-run", action="store_true",
        help="print the row without pushing",
    )
    args = parser.parse_args()

    if not args.results.is_file():
        raise SystemExit(f"error: results file not found: {args.results}")

    row = build_row(args.results)
    print(json.dumps(row, indent=2))
    if args.dry_run:
        print("dry run — not published", file=sys.stderr)
        return
    publish(row)
    print(f"published to origin/metrics {METRICS_FILE}", file=sys.stderr)


if __name__ == "__main__":
    main()
