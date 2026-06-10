#!/usr/bin/env python3
"""Bundle metadata extractor.

Walks every iMovie Events / iMovie Project / iPhoto Library / Photos
Library / FCP bundle reachable on the currently-mounted volumes and
extracts structured metadata about each video asset. Matches against
catalog.json records by filename and emits JSONL deltas to
/Volumes/Crucial2TB/dossier-deltas/bundle-meta.jsonl, which the
merger picks up on its next poll.

Rick 2026-06-08: the dossier pipeline gives us VLM + Whisper + OCR
signals, but it misses the structured ground truth that's been sitting
in Apple's own libraries the whole time — capture timestamps from
EXIF / camera metadata, event names that describe what the user
was filming, user-edited titles. This script pulls those in.

What we extract, by source:

  iPhoto Library (.apdb)  → RKMaster: capture date, original filename,
                            relative path, parent event/album
  Modern Photos Library   → ZASSET: capture date, duration, filename
  iMovie Events           → clip filenames like
                            clip-2003-06-05 19;19;09.dv literally
                            embed the capture timestamp
  iMovie HD project XML   → individual clip names + capture dates
  iMovie Library flexolibrary → ditto via SQLite under the bundle
  FCP fcpbundle           → CurrentVersion.fcpevent XML

Matching strategy:

  Each catalog record has a fullPath; we build a filename-only index
  catalog_by_filename: {basename: [records]} once at startup. Each
  bundle record looks up by basename and writes a delta for every
  catalog match (handles duplicates across volumes naturally).

Output delta fields:

  inferredRecordDate         — the bundle's capture timestamp
  inferredDateConfidence     — 0.85 (high; these are camera-recorded,
                              far more reliable than file mtime)
  inferredDateSource         — \"iphoto\" / \"photos\" / \"imovie-event\"
                              / \"imovie-project\" / \"fcp\"

We deliberately do NOT set dossierProcessedAt — bundle metadata is
NOT dossier work. The dial stays honest. Per docs/database_design.md.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import sqlite3
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path
from typing import Iterable, Iterator

DEFAULT_CATALOG = Path("~/Library/Application Support/VideoScan/catalog.json").expanduser()
DEFAULT_OUTPUT = Path("/Volumes/Crucial2TB/dossier-deltas/bundle-meta.jsonl")

# Apple's Cocoa absolute time epoch (2001-01-01 UTC) → Unix epoch offset.
COCOA_EPOCH_OFFSET = 978307200

# Bundle-extension predicates — used by the walker to know what to descend.
IMOVIE_PROJECT_SUFFIX = ".iMovieProject"
IMOVIE_LIBRARY_SUFFIX = ".imovielibrary"
IPHOTO_LIBRARY_SUFFIX = " iPhoto Library"   # actually "iPhoto Library" as bundle dir
PHOTOS_LIBRARY_SUFFIX = ".photoslibrary"
FCP_BUNDLE_SUFFIX = ".fcpbundle"
IMOVIE_EVENTS_DIR = "iMovie Events.localized"


def cocoa_to_iso(seconds_since_2001: float | int | None) -> str | None:
    """Convert an Apple Cocoa absolute time (seconds since 2001-01-01 UTC)
    to ISO 8601. Returns None for invalid inputs."""
    if seconds_since_2001 is None:
        return None
    try:
        u = float(seconds_since_2001) + COCOA_EPOCH_OFFSET
        if u < 0 or u > 4102444800:  # < 1970 or > 2100, parse junk
            return None
        return dt.datetime.fromtimestamp(u, tz=dt.timezone.utc).isoformat()
    except (TypeError, ValueError):
        return None


def iso_year_in_range(iso: str | None, lo: int, hi: int) -> bool:
    if not iso or len(iso) < 4:
        return False
    try:
        y = int(iso[:4])
        return lo <= y <= hi
    except ValueError:
        return False


# ---------------------------------------------------------------------------
# Source: iMovie Events.localized — filenames like clip-2003-06-05 19;19;09.dv

# Pattern: clip-YYYY-MM-DD HH;MM;SS.<ext>  (semicolons because colons are
# illegal in HFS+ filenames; iMovie substituted ; for :).
IMOVIE_EVENT_CLIP_RE = re.compile(
    r"^clip-(\d{4})-(\d{2})-(\d{2})[ _](\d{2});(\d{2});(\d{2})"
)


def extract_imovie_event_clips(events_dir: Path) -> Iterator[tuple[str, str, str]]:
    """Yield (basename, iso_date, event_name) for every clip-YYYY-...dv
    style file under an iMovie Events.localized dir. Walks subdirs (each
    is an event)."""
    if not events_dir.exists():
        return
    for event_dir in events_dir.iterdir():
        if not event_dir.is_dir():
            continue
        event_name = event_dir.name
        for f in event_dir.rglob("*"):
            if not f.is_file():
                continue
            m = IMOVIE_EVENT_CLIP_RE.match(f.name)
            if not m:
                continue
            y, mo, d, hh, mm, ss = m.groups()
            try:
                t = dt.datetime(int(y), int(mo), int(d),
                                int(hh), int(mm), int(ss),
                                tzinfo=dt.timezone.utc)
                iso = t.isoformat()
            except ValueError:
                continue
            yield (f.name, iso, event_name)


# ---------------------------------------------------------------------------
# Source: iPhoto Library .apdb (SQLite, RKMaster table)

def extract_iphoto_library(library_dir: Path) -> Iterator[tuple[str, str, str]]:
    """Yield (basename, iso_capture_date, source_label) from an iPhoto
    library's Library.apdb. Resilient: missing DB or unexpected schema
    yields nothing rather than crashing."""
    db = library_dir / "Database" / "apdb" / "Library.apdb"
    if not db.exists():
        return
    label = f"iphoto:{library_dir.name}"
    try:
        conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        cur = conn.execute(
            "SELECT fileName, imageDate, imagePath FROM RKMaster "
            "WHERE imageDate IS NOT NULL"
        )
        for filename, image_date, _img_path in cur:
            iso = cocoa_to_iso(image_date)
            if not iso or not filename:
                continue
            yield (filename, iso, label)
    except sqlite3.Error:
        return
    finally:
        try:
            conn.close()
        except Exception:
            pass


# ---------------------------------------------------------------------------
# Source: modern Photos Library .photoslibrary (Photos.sqlite, ZASSET)

def extract_photos_library(library_dir: Path) -> Iterator[tuple[str, str, str]]:
    """Yield (basename, iso_capture_date, source_label) from a modern
    Photos library."""
    db = library_dir / "database" / "Photos.sqlite"
    if not db.exists():
        return
    label = f"photos:{library_dir.name}"
    try:
        conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        # ZASSET.ZFILENAME, ZASSET.ZDATECREATED (Cocoa time), ZASSET.ZKIND (1=video)
        try:
            cur = conn.execute(
                "SELECT ZFILENAME, ZDATECREATED, ZKIND FROM ZASSET "
                "WHERE ZDATECREATED IS NOT NULL"
            )
        except sqlite3.OperationalError:
            return
        for filename, zdate, _kind in cur:
            iso = cocoa_to_iso(zdate)
            if not iso or not filename:
                continue
            yield (filename, iso, label)
    except sqlite3.Error:
        return
    finally:
        try:
            conn.close()
        except Exception:
            pass


# ---------------------------------------------------------------------------
# Source: iMovie HD project (.iMovieProject) — XML at <name>.iMovieProj

def extract_imovie_project(project_dir: Path) -> Iterator[tuple[str, str, str]]:
    """Yield (basename, iso_capture_date, source_label) from an iMovie HD
    project. Looks for the .iMovieProj XML file and reads <CLIP>
    elements with their cameraDate / recordingDate attributes."""
    label = f"imovie-project:{project_dir.name}"
    candidates = list(project_dir.glob("*.iMovieProj"))
    if not candidates:
        return
    proj_file = candidates[0]
    try:
        tree = ET.parse(proj_file)
    except (ET.ParseError, OSError):
        return
    # iMovie HD's XML uses CLIP elements; date keys vary by version.
    for clip in tree.iter():
        # Look for any element with a date-like attribute.
        name = clip.attrib.get("clipName") or clip.attrib.get("name")
        date = (clip.attrib.get("cameraDate")
                or clip.attrib.get("recordingDate")
                or clip.attrib.get("dateString"))
        if not name or not date:
            continue
        # Date might be a Cocoa time string or ISO; try both.
        iso = None
        try:
            iso = cocoa_to_iso(float(date))
        except ValueError:
            # Could be an ISO string already
            if len(date) >= 4 and date[:4].isdigit():
                iso = date
        if not iso:
            continue
        yield (name, iso, label)


# ---------------------------------------------------------------------------
# Walker: discover bundles under a root path (no recursion INTO bundles).

def discover_bundles(root: Path, *, max_depth: int = 7) -> dict[str, list[Path]]:
    """Walk filesystem under `root` looking for bundles by name suffix.
    Doesn't descend into bundles (treats them as leaves). Returns a dict
    keyed by source type → list of bundle paths."""
    out: dict[str, list[Path]] = defaultdict(list)
    def walk(p: Path, depth: int):
        if depth > max_depth:
            return
        # Identify what kind of bundle this is, if any.
        name = p.name
        if name.endswith(IMOVIE_PROJECT_SUFFIX):
            out["imovie-project"].append(p)
            return  # don't descend
        if name.endswith(IMOVIE_LIBRARY_SUFFIX):
            out["imovie-library"].append(p)
            return
        if name == "iPhoto Library":
            out["iphoto-library"].append(p)
            return
        if name.endswith(PHOTOS_LIBRARY_SUFFIX):
            out["photos-library"].append(p)
            return
        if name.endswith(FCP_BUNDLE_SUFFIX):
            out["fcp-bundle"].append(p)
            return
        if name == IMOVIE_EVENTS_DIR:
            out["imovie-events"].append(p)
            return  # extractor walks events itself
        # Recurse if directory
        try:
            if p.is_dir():
                for kid in p.iterdir():
                    walk(kid, depth + 1)
        except (PermissionError, OSError):
            pass
    walk(root, 0)
    return dict(out)


# ---------------------------------------------------------------------------
# Catalog matching: build filename → [records] index once

def build_catalog_filename_index(catalog_path: Path) -> dict[str, list[dict]]:
    """Return {basename_lowercase: [records]} for fast filename lookup."""
    catalog = json.loads(catalog_path.read_text())
    index: dict[str, list[dict]] = defaultdict(list)
    for rec in catalog.get("records", []):
        fn = rec.get("filename") or ""
        if fn:
            index[fn.lower()].append(rec)
    return dict(index)


# ---------------------------------------------------------------------------
# Main pipeline

def emit_deltas(
    extracted: Iterable[tuple[str, str, str]],
    catalog_index: dict[str, list[dict]],
    *,
    confidence: float = 0.85,
) -> list[dict]:
    """For each (basename, iso_date, source_label) tuple, look up
    matching catalog records by filename and emit a delta per match.

    Deduplication: if multiple extracted entries point to the same
    catalog fullPath with different dates, the first wins (extractor
    order is bundle-walk order — typically the highest-priority source
    first). Caller is responsible for ordering sources.
    """
    seen_paths: set[str] = set()
    now = dt.datetime.now(dt.timezone.utc).isoformat()
    deltas: list[dict] = []
    for basename, iso, label in extracted:
        for rec in catalog_index.get(basename.lower(), ()):
            full = rec.get("fullPath")
            if not full or full in seen_paths:
                continue
            seen_paths.add(full)
            # Don't overwrite an existing inferredRecordDate UNLESS we'd
            # be replacing it with stronger evidence — for v1, skip if
            # already present. The dossier worker's date triangulation
            # is also high-confidence and shouldn't be clobbered.
            if rec.get("inferredRecordDate"):
                continue
            deltas.append({
                "fullPath": full,
                "host": "bundle-meta",
                "ts": now,
                "fields": {
                    "inferredRecordDate": iso,
                    "inferredDateConfidence": confidence,
                },
                # Source label for audit only — not a catalog field, kept
                # in the JSONL line as a sibling so the merger ignores it
                # but logs can use it.
                "_source": label,
            })
    return deltas


def write_deltas_jsonl(deltas: Iterable[dict], path: Path) -> int:
    path.parent.mkdir(parents=True, exist_ok=True)
    count = 0
    with path.open("a") as f:
        for d in deltas:
            # Strip the _source field from the delta proper before writing
            # (the merger only cares about fullPath / host / fields).
            line = {k: v for k, v in d.items() if not k.startswith("_")}
            f.write(json.dumps(line, ensure_ascii=False) + "\n")
            count += 1
    return count


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--roots", nargs="*",
                    default=["/Volumes/LaCieWorkspace",
                             "/Volumes/MyBook3Terabytes",
                             "/Volumes/MediaExpansion",
                             "/Volumes/RicksBackups",
                             "/Volumes/Crucial2TB"],
                    help="Filesystem roots to walk for bundles.")
    ap.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG)
    ap.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    ap.add_argument("--confidence", type=float, default=0.85)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--year-filter",
                    help="Only emit deltas whose extracted date is in this range. "
                         "Format: \"YYYY..YYYY\" (e.g. 1991..1993).")
    args = ap.parse_args()

    print(f"loading catalog: {args.catalog}")
    catalog_index = build_catalog_filename_index(args.catalog)
    print(f"  indexed {sum(len(v) for v in catalog_index.values())} records "
          f"across {len(catalog_index)} unique filenames")

    yr_lo, yr_hi = 0, 9999
    if args.year_filter and ".." in args.year_filter:
        try:
            a, b = args.year_filter.split("..")
            yr_lo, yr_hi = int(a), int(b)
            print(f"  year filter: {yr_lo}..{yr_hi}")
        except ValueError:
            pass

    print("discovering bundles...")
    all_bundles: dict[str, list[Path]] = defaultdict(list)
    for root_str in args.roots:
        root = Path(root_str)
        if not root.exists():
            continue
        bundles = discover_bundles(root)
        for kind, paths in bundles.items():
            all_bundles[kind].extend(paths)
            print(f"  {root_str}: {kind} × {len(paths)}")

    # Extract per source. Order matters for dedup: highest-confidence
    # source first.
    sources_in_order = [
        ("photos-library", extract_photos_library),
        ("iphoto-library", extract_iphoto_library),
        ("imovie-events",  lambda d: extract_imovie_event_clips(d)),
        ("imovie-project", extract_imovie_project),
    ]
    all_extracted: list[tuple[str, str, str]] = []
    for kind, fn in sources_in_order:
        for bundle in all_bundles.get(kind, []):
            try:
                for item in fn(bundle):
                    if iso_year_in_range(item[1], yr_lo, yr_hi):
                        all_extracted.append(item)
            except Exception as e:
                print(f"  WARN extracting from {bundle}: {e}")

    print(f"\nextracted {len(all_extracted)} metadata items across all sources")

    deltas = emit_deltas(all_extracted, catalog_index, confidence=args.confidence)
    print(f"matched {len(deltas)} catalog records (no overwrites)")

    # Per-source breakdown for the user.
    source_counts: dict[str, int] = defaultdict(int)
    for d in deltas:
        source_counts[d.get("_source", "?")] += 1
    if source_counts:
        print("  per source:")
        for s, c in sorted(source_counts.items(), key=lambda x: -x[1])[:10]:
            print(f"    {s}: {c}")

    # Year histogram
    year_hist: dict[int, int] = defaultdict(int)
    for d in deltas:
        iso = d["fields"]["inferredRecordDate"]
        if iso and len(iso) >= 4 and iso[:4].isdigit():
            year_hist[int(iso[:4])] += 1
    if year_hist:
        print("  year histogram (top 15):")
        for y, c in sorted(year_hist.items(), key=lambda x: -x[1])[:15]:
            print(f"    {y}: {c}")

    if args.dry_run:
        print("\n(dry run — no JSONL written)")
        return 0

    n = write_deltas_jsonl(deltas, args.output)
    print(f"\nwrote {n} delta(s) to {args.output}")
    print("merger will pick them up on its next poll cycle (~60s).")
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
