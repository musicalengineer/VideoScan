#!/usr/bin/env python3
"""corpus_select.py — which real files grow the M4's real-data corpus, and the corpus manifest.

DECISIONS 2026-11-17 ("The M4 holds a real-data test corpus") and 2026-11-19 (the corpus
may rest on the M4's SSD and on the Crucial X10). v1's 234 files were chosen by a script
that was never kept; this is the v2 choice, kept, so it can be run again and argued with.

    corpus_select.py select --catalog <catalog .backup> --exclude <corpus-manifest-v1.json> --out <folder>
    corpus_select.py manifest --v1 <corpus-manifest-v1.json> --selection <selection.json> --out <corpus-manifest-v2.json>
    corpus_select.py grow --catalog <newer catalog .backup> --manifest <corpus-manifest-v2.json> --out <folder>

select — THE RULES (each one is a test in tests/test_corpus_select.py):
  1. from the catalog's live rows (removal_state IS NULL), every distinct content_digest
     that is not already in the corpus (`--exclude`, the v1 manifest);
  2. one readable path per digest: a regular file this process can read; a path outside
     /Volumes/FamilyArchive/ (the Master Archive volume) is preferred; then the smallest
     path (text order);
  3. a file under SPLIT_BYTES (8 GB, decimal) goes to the EXTERNAL root (the Crucial X10);
  4. of the files at or over 8 GB, the smallest of each (container, video_codec,
     audio_codec) stratum — ties broken by the catalog's row order, the digest's first live
     row — are taken smallest first until the next would take the INTERNAL root (the M4's
     SSD) past INTERNAL_BUDGET (250 GB); the rest of the large files are not taken.
  The catalog is opened read-only and immutable: nothing is written beside it.
  It writes into <folder>: selection.json ({"external"|"internal": [[digest, path, size]…]}),
  v2_<root>.sha (`<sha256>  Volumes/<Vol>/…`, the copy's place under that root's media
  folder; `shasum -a 256 -c` from there) and v2_<root>.files (rsync --files-from, from /).

manifest — v1's rows (root internal) followed by the selection's rows, each
  {"sha256", "path" (the original), "size", "why" (its stratum), "root" (internal|external)}:
  the `corpus-manifest-v2.json` scripts/corpus_run.py reads. A digest twice is refused.

grow — the corpus grows (DECISIONS 2026-11-19, the manifest is a wish list): the same rules over a
  newer catalog .backup, with every digest already in the manifest excluded, the internal budget
  reduced by the large files already chosen and their (container, video, audio) strata counted
  as covered. Writes into <folder>: corpus-manifest-v2.json — the current rows UNCHANGED (nothing
  is ever removed, whatever the newer catalog says) followed by the new ones — and the selection,
  SHA-256 lists and rsync lists of the NEW files only. Grown twice over the same backup: nothing new.

PRIVACY. What this prints is counts and bytes only. Its outputs hold real paths: they are
written to the folder named, which must not be in the repository (refused), and are
copied to the M4 by hand; they never go into git.

Memory: one tuple per live catalog row (~11k rows: a few MB). Python 3.9 is the floor.
"""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
import urllib.parse
from collections import defaultdict
from pathlib import Path
from typing import Callable, Dict, Iterable, List, Optional, Tuple

SPLIT_BYTES = 8_000_000_000                       # rule 3: under this, the external root
INTERNAL_BUDGET = 250_000_000_000                 # rule 4: the internal root's share of the SSD
ARCHIVE_PREFIX = "/Volumes/FamilyArchive/"        # rule 2: a copy here is the last choice
WHY_EXTERNAL = "v2 every content under 8 GB"
WHY_INTERNAL = "v2 large, one per container and codecs"
REPO = Path(__file__).resolve().parents[1]

# (rowid, digest, full_path, size, container, video_codec, audio_codec)
Row = Tuple[int, str, str, int, Optional[str], Optional[str], Optional[str]]
Pick = Tuple[str, str, int]                        # (digest, path, size)


class Refused(Exception):
    """A precondition said no. The message carries no path."""


def readable(path: str) -> bool:
    return os.path.isfile(path) and os.access(path, os.R_OK)


def catalog_rows(catalog: Path) -> List[Row]:
    """The live rows, read through an immutable read-only open (no sidecar is ever made)."""
    for suffix in ("-wal", "-journal"):
        if os.path.exists(str(catalog) + suffix):
            raise Refused(f"refused: the catalog has a {suffix} file beside it — give it a finished .backup")
    uri = "file:" + urllib.parse.quote(str(Path(catalog).resolve())) + "?immutable=1"
    conn = sqlite3.connect(uri, uri=True)
    try:
        return conn.execute(
            "SELECT rowid, content_digest, full_path, size_bytes, container, video_codec, audio_codec FROM files "
            "WHERE removal_state IS NULL AND content_digest IS NOT NULL AND full_path IS NOT NULL ORDER BY rowid").fetchall()
    finally:
        conn.close()


def select(rows: Iterable[Row], excluded: Iterable[str],
           can_read: Callable[[str], bool] = readable, budget: int = INTERNAL_BUDGET,
           covered: Iterable[Tuple[str, str, str]] = ()) -> Dict[str, List[Pick]]:
    """The rules above, as a pure function of the rows (`can_read` is the one question asked of the
    disk). `budget` and `covered` (strata already in the corpus) are `grow`'s."""
    skip = {d.lower() for d in excluded}
    by_digest: Dict[str, List[Row]] = defaultdict(list)
    for row in rows:
        if row[1].lower() not in skip:
            by_digest[row[1]].append(row)
    chosen: Dict[str, Tuple[Row, int]] = {}        # digest -> (its row, the digest's first live rowid)
    for digest, group in by_digest.items():
        candidates = [r for r in group if can_read(r[2])]
        if not candidates:
            continue
        preferred = [r for r in candidates if not r[2].startswith(ARCHIVE_PREFIX)] or candidates
        chosen[digest] = (min(preferred, key=lambda r: r[2]), min(r[0] for r in group))
    external = sorted(((d, row[2], int(row[3])) for d, (row, _) in chosen.items() if int(row[3]) < SPLIT_BYTES),
                      key=lambda p: p[0])
    strata: Dict[Tuple[str, str, str], Tuple[int, int, Row]] = {}
    done = set(covered)
    for digest, (row, first) in chosen.items():
        if int(row[3]) < SPLIT_BYTES:
            continue
        key = (row[4] or "", row[5] or "", row[6] or "")
        if key in done:
            continue
        if key not in strata or (int(row[3]), first) < strata[key][:2]:
            strata[key] = (int(row[3]), first, row)
    internal: List[Pick] = []
    total = 0
    for size, _, row in sorted(strata.values(), key=lambda s: s[:2]):
        if total + size > budget:
            break
        total += size
        internal.append((row[1], row[2], size))
    return {"external": external, "internal": internal}


def copy_place(original: str) -> str:
    """Where a copy sits under its root's media folder: the original path less its leading slash."""
    if not original.startswith("/Volumes/") or ".." in original.split("/"):
        raise Refused("refused: a chosen path is not an absolute /Volumes path")
    return original.lstrip("/")


def write_selection(selection: Dict[str, List[Pick]], out: Path) -> None:
    out = Path(out)
    if out.resolve() == REPO or REPO in out.resolve().parents:
        raise Refused("refused: the selection names real files — write it outside the repository")
    out.mkdir(parents=True, exist_ok=True)
    (out / "selection.json").write_text(json.dumps({k: [list(p) for p in v] for k, v in selection.items()}) + "\n")
    for root, picks in selection.items():
        (out / f"v2_{root}.sha").write_text("".join(f"{d}  {copy_place(p)}\n" for d, p, _ in picks))
        (out / f"v2_{root}.files").write_text("".join(f"{copy_place(p)}\n" for _, p, _ in picks))


def manifest(v1_rows: List[dict], selection: Dict[str, List[list]]) -> List[dict]:
    rows, seen = [], set()
    for row in v1_rows:
        rows.append({"sha256": str(row["sha256"]).lower(), "path": row["path"], "size": int(row["size"]),
                     "why": row.get("why", ""), "root": "internal"})
    for root, why in (("internal", WHY_INTERNAL), ("external", WHY_EXTERNAL)):
        for digest, path, size in selection.get(root, []):
            copy_place(path)
            rows.append({"sha256": str(digest).lower(), "path": path, "size": int(size), "why": why, "root": root})
    for row in rows:
        if row["sha256"] in seen:
            raise Refused("refused: one content is listed twice")
        seen.add(row["sha256"])
    return rows


def stratum(row: Row) -> Tuple[str, str, str]:
    return (row[4] or "", row[5] or "", row[6] or "")


def grow(rows: List[Row], current: List[dict], can_read: Callable[[str], bool] = readable) -> Tuple[List[dict], Dict[str, List[Pick]]]:
    """(the grown manifest: `current` unchanged + the new rows, the new files' selection)."""
    have = {str(r["sha256"]).lower() for r in current}
    large = {str(r["sha256"]).lower() for r in current if r.get("why") == WHY_INTERNAL}
    covered = {stratum(row) for row in rows if row[1].lower() in large}
    spent = sum(int(r["size"]) for r in current if r.get("why") == WHY_INTERNAL)
    picked = select(rows, have, can_read, budget=max(0, INTERNAL_BUDGET - spent), covered=covered)
    added = manifest([], picked)
    if any(r["sha256"] in have for r in added):
        raise Refused("refused: a new row names content already in the manifest")
    return [dict(r) for r in current] + added, picked


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="corpus_select.py", description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    choose = sub.add_parser("select")
    choose.add_argument("--catalog", required=True)
    choose.add_argument("--exclude", required=True)
    choose.add_argument("--out", required=True)
    merge = sub.add_parser("manifest")
    merge.add_argument("--v1", required=True)
    merge.add_argument("--selection", required=True)
    merge.add_argument("--out", required=True)
    growing = sub.add_parser("grow")
    growing.add_argument("--catalog", required=True)
    growing.add_argument("--manifest", required=True)
    growing.add_argument("--out", required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "grow":
            current = json.loads(Path(args.manifest).read_text(encoding="utf-8"))
            grown, picked = grow(catalog_rows(Path(args.catalog)), current)
            write_selection(picked, Path(args.out))
            (Path(args.out) / "corpus-manifest-v2.json").write_text(json.dumps(grown, indent=0) + "\n")
            for root in ("external", "internal"):
                print(f"corpus grow: {root} +{len(picked[root])} files, {sum(p[2] for p in picked[root]) / 1e9:.1f} GB")
            print(f"corpus grow: manifest {len(current)} -> {len(grown)} files (none removed)")
        elif args.command == "select":
            excluded = [row["sha256"] for row in json.loads(Path(args.exclude).read_text(encoding="utf-8"))]
            picked = select(catalog_rows(Path(args.catalog)), excluded)
            write_selection(picked, Path(args.out))
            for root in ("external", "internal"):
                print(f"corpus select: {root} {len(picked[root])} files, {sum(p[2] for p in picked[root]) / 1e9:.1f} GB")
        else:
            out = Path(args.out)
            if out.resolve().parent == REPO or REPO in out.resolve().parents:
                raise Refused("refused: the manifest names real files — write it outside the repository")
            rows = manifest(json.loads(Path(args.v1).read_text(encoding="utf-8")),
                            json.loads(Path(args.selection).read_text(encoding="utf-8")))
            out.write_text(json.dumps(rows, indent=0) + "\n")
            counts = defaultdict(int)
            for row in rows:
                counts[row["root"]] += 1
            print(f"corpus manifest: {len(rows)} files — internal {counts['internal']}, external {counts['external']}")
    except Refused as refusal:
        print(f"corpus select: RED {refusal}")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
