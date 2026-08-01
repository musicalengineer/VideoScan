#!/usr/bin/env python3
"""Derive Rick's NEUTRAL blind-review CSV from the private queue skeleton.

Per codex leakage blocker (2026-07-23-1406): Rick's review artifact must
solicit blind ground truth, not confirmation. It therefore carries ONLY:

    reviewId, fullPath, rickConfirm(yes/no), notes

No role, seed rating, selection rationale, status, flags, decade, or any
expected-answer mapping. reviewId is an opaque deterministic digest of the
private case ID; the reviewId -> caseId mapping is written to a separate
grader-private file. Row order is sorted by reviewId, so it is deterministic
but uncorrelated with role or seed rating.

Reads (private, gitignored):
  output/person-eval-private/<date>/label-queue-skeleton.private.json

Writes (private, gitignored):
  output/person-eval-private/<date>/rick-review-neutral.csv    (for Rick)
  output/person-eval-private/<date>/review-id-map.private.csv  (grader-only)

Deterministic: no randomness, no clock reads.
"""

import argparse
import csv
import hashlib
import json
from pathlib import Path

# Fixed digest domain tag. Case IDs live only in private data, so knowing
# this tag does not let anyone recompute the mapping without that data.
ID_DOMAIN = "videoscan-poi-holdout-review-2026"


def review_id(case_id):
    return hashlib.sha256(
        f"{ID_DOMAIN}:{case_id}".encode()).hexdigest()[:12].upper()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo-root", required=True)
    ap.add_argument("--date", required=True, help="YYYY-MM-DD skeleton date")
    args = ap.parse_args()

    priv_dir = (Path(args.repo_root) / "output/person-eval-private"
                / args.date)
    skeleton = json.load(
        open(priv_dir / "label-queue-skeleton.private.json"))

    selected = [c for c in skeleton["cases"] if c.get("selected")]
    rows = sorted(
        ({"reviewId": review_id(c["caseId"]),
          "fullPath": c.get("fullPath") or c.get("_path"),
          "caseId": c["caseId"],
          "role": c["role"]}
         for c in selected),
        key=lambda r: r["reviewId"])

    ids = [r["reviewId"] for r in rows]
    if len(set(ids)) != len(ids):
        raise SystemExit("reviewId digest collision — widen the digest")
    if any(not r["fullPath"] for r in rows):
        raise SystemExit("selected case missing fullPath in private skeleton")

    with open(priv_dir / "rick-review-neutral.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["reviewId", "fullPath", "rickConfirm(yes/no)", "notes"])
        for r in rows:
            w.writerow([r["reviewId"], r["fullPath"], "", ""])

    with open(priv_dir / "review-id-map.private.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["reviewId", "caseId", "role"])
        for r in rows:
            w.writerow([r["reviewId"], r["caseId"], r["role"]])

    print(f"neutral CSV: {len(rows)} rows -> "
          f"{priv_dir / 'rick-review-neutral.csv'}")


if __name__ == "__main__":
    main()
