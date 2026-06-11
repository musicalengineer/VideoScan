#!/usr/bin/env python3
"""Propagate dossier fields across byte-identical sibling records.

Many catalog records point at retired volumes (Maxtor750, Seagate2TB,
Mini2TB, etc.) whose content was duplicated to LaCie / MyBook before
the originals were unplugged. Those retired-volume records are stuck
without dossierProcessedAt — the worker can't reach the path, so the
VLM never runs. But the SAME bytes have already been dossier'd on the
LaCie sibling.

This script finds every (partialMD5, sizeBytes) group where:

  - at least one record has dossierProcessedAt set, AND
  - at least one record in the same group does NOT

and emits a JSONL delta copying the dossier-channel fields onto every
undossier'd record in the group. Output goes to
/Volumes/Crucial2TB/dossier-deltas/sibling-propagation.jsonl which the
existing merger consumes on its next 60-second poll.

Correctness invariants (pinned by tests):

  1. partialMD5 must be non-empty AND sizeBytes must match across the
     group. partialMD5 alone is computed on the first 4 MB — for video
     files that's plenty unique in practice, but we belt-and-suspender
     with sizeBytes so we never propagate across truly different files
     that happened to share a 4-MB prefix.
  2. We copy ALL dossier-channel fields atomically (captions,
     transcript, OCR, inferred date, processed-at/by). Partial copies
     would leave a record with a captionDate but no captions.
  3. We tag dossierProcessedBy with the source path so provenance is
     visible: "sibling-prop:/Volumes/LaCieWorkspace/.../clip.mov".
     Rick can grep for "sibling-prop:" to find every propagated record.
  4. If multiple dossier'd siblings exist (e.g. a file on 3 different
     mounted volumes all got VLM'd separately), prefer the one with
     the most recent dossierProcessedAt — newer is more likely to use
     the latest model. Stable tiebreak by alphabetic fullPath.

We deliberately do NOT propagate user-edit fields (notes,
detectedPeople, etc.). Those are user-attached to a specific record;
duplicating them across siblings would muddle audit trails.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import sys
from collections import defaultdict
from pathlib import Path

DEFAULT_CATALOG = Path("~/Library/Application Support/VideoScan/catalog.json").expanduser()
DEFAULT_OUTPUT = Path("/Volumes/Crucial2TB/dossier-deltas/sibling-propagation.jsonl")

# Fields we copy from the chosen source onto each undossier'd sibling.
# Aligned with the dossier channels defined in
# VideoScanModel+RescanPreservation.swift. The merger's schema
# validator (merge_dossier_jsonl.py) already accepts every key here.
DOSSIER_CHANNELS = [
    "sceneCaptions",
    "sceneCaptionModel",
    "sceneCaptionDate",
    "audioTranscript",
    "audioTranscriptModel",
    "audioTranscriptDate",
    "ocrDateCandidates",
    "ocrText",
    "inferredRecordDate",
    "inferredDateConfidence",
    "dossierProcessedAt",
    "dossierProcessedBy",
]


def group_key(rec: dict) -> tuple[str, int] | None:
    """Return the (partialMD5, sizeBytes) group key for a record, or
    None if the record can't be reliably grouped (missing md5 or size).
    """
    md5 = rec.get("partialMD5") or ""
    size = rec.get("sizeBytes")
    if not md5 or not isinstance(size, int) or size <= 0:
        return None
    return (md5, size)


def pick_source(siblings: list[dict]) -> dict | None:
    """Pick the best dossier'd record to propagate FROM. Prefers most
    recent dossierProcessedAt, then alphabetic fullPath as a stable
    tiebreak. Returns None if no sibling is dossier'd."""
    dossiered = [r for r in siblings if r.get("dossierProcessedAt")]
    if not dossiered:
        return None
    # Sort by (-timestamp, fullPath) — newest first, alphabetic ties.
    def sort_key(r):
        ts = r.get("dossierProcessedAt") or ""
        path = r.get("fullPath") or ""
        return (ts, path)
    dossiered.sort(key=sort_key, reverse=True)
    return dossiered[0]


def compute_propagation_deltas(records: list[dict]) -> list[dict]:
    """Pure function — given a catalog's records list, return the list
    of JSONL delta dicts to write. No IO. Easy to test."""
    groups: dict[tuple[str, int], list[dict]] = defaultdict(list)
    for rec in records:
        key = group_key(rec)
        if key is not None:
            groups[key].append(rec)

    now = dt.datetime.now(dt.timezone.utc).isoformat()
    deltas: list[dict] = []
    for key, siblings in groups.items():
        if len(siblings) < 2:
            continue  # nothing to propagate to
        source = pick_source(siblings)
        if source is None:
            continue  # no sibling has a dossier yet
        # Build a single fields dict from the source's dossier channels.
        # Skip any None values — Codable round-trip can produce nil for
        # fields the original record never set, and we don't want to
        # clobber a target's existing field with null.
        fields: dict = {}
        for k in DOSSIER_CHANNELS:
            v = source.get(k)
            if v is None:
                continue
            fields[k] = v
        # Override dossierProcessedBy with a provenance tag so it's
        # obvious in catalog.json which records came from propagation.
        # Format: "sibling-prop:<source-full-path>"
        src_path = source.get("fullPath") or "?"
        fields["dossierProcessedBy"] = f"sibling-prop:{src_path}"

        if not fields:
            continue  # source had nothing worth copying
        # Emit one delta per undossier'd sibling.
        for sib in siblings:
            if sib.get("dossierProcessedAt"):
                continue  # already has its own dossier; leave it alone
            target_path = sib.get("fullPath")
            if not target_path:
                continue
            deltas.append({
                "fullPath": target_path,
                "host": "sibling-propagation",
                "ts": now,
                "fields": fields,
            })
    return deltas


def write_deltas_jsonl(deltas, path: Path) -> int:
    path.parent.mkdir(parents=True, exist_ok=True)
    count = 0
    with path.open("a") as f:
        for d in deltas:
            f.write(json.dumps(d, ensure_ascii=False) + "\n")
            count += 1
    return count


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG)
    ap.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    ap.add_argument("--dry-run", action="store_true",
                    help="Print stats without writing JSONL.")
    args = ap.parse_args()

    try:
        catalog = json.loads(args.catalog.read_text())
    except Exception as e:
        print(f"ERROR reading {args.catalog}: {e}", file=sys.stderr)
        return 1
    records = catalog.get("records", [])
    print(f"records in catalog: {len(records)}")

    deltas = compute_propagation_deltas(records)
    print(f"propagation deltas: {len(deltas)}")

    # Per-source-volume breakdown — useful sanity check.
    src_vols: dict[str, int] = defaultdict(int)
    for d in deltas:
        src = d["fields"].get("dossierProcessedBy", "")
        if src.startswith("sibling-prop:/Volumes/"):
            parts = src.split("/", 3)
            vol = parts[2] if len(parts) >= 3 else "?"
            src_vols[vol] += 1
    if src_vols:
        print("  source volume of propagation:")
        for v, c in sorted(src_vols.items(), key=lambda kv: -kv[1])[:10]:
            print(f"    {v}: {c}")

    # Per-target-volume breakdown — where do the records being filled in live?
    tgt_vols: dict[str, int] = defaultdict(int)
    for d in deltas:
        path = d.get("fullPath", "")
        if path.startswith("/Volumes/"):
            parts = path.split("/", 3)
            vol = parts[2] if len(parts) >= 3 else "?"
            tgt_vols[vol] += 1
    if tgt_vols:
        print("  target volume (where the undossier'd records live):")
        for v, c in sorted(tgt_vols.items(), key=lambda kv: -kv[1])[:10]:
            print(f"    {v}: {c}")

    if args.dry_run:
        print("\n(dry run — no JSONL written)")
        return 0

    n = write_deltas_jsonl(deltas, args.output)
    print(f"\nwrote {n} delta(s) to {args.output}")
    print("merger will pick them up on its next poll cycle (~60s).")
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
