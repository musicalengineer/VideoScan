#!/usr/bin/env python3
"""working_set_candidates.py — rank catalog records for migration to fast
working storage (SanDisk), READ-ONLY on catalog.json.

There is no search/usage telemetry yet (follow-up: stamp lastAccessedAt /
accessCount on preview/play/reveal). Until then "frequently used" is
approximated from catalog signals that mean a human or a job cared about
the file:

  +3  starRating >= 2            (curated keep/gold)
  +3  confirmedByUserPeople      (human-tagged people)
  +2  detectedPeople/suspectedPeople (Find and Tag / POI hits)
  +2  dossierProcessedAt         (dossier ran: captions/transcript/OCR)
  +1  userNotes / notes present
  +1  duplicateDisposition == Keep (elected keeper)
  -inf: purged, confirmed/suspected junk, extra-copy dup, unreachable
        volume (unless --include-offline), audio-only (unless --audio)

Usage:
  scripts/working_set_candidates.py [--catalog PATH] [--top-gb 500]
        [--min-score 3] [--csv out.csv] [--include-offline] [--audio]

Prints a per-source-volume GB summary and the top candidates; optional CSV
for the Migrate step. Never writes catalog.json.
"""
import argparse, csv, json, os, sys
from collections import defaultdict
from pathlib import Path

DEFAULT_CATALOG = Path("~/Library/Application Support/VideoScan/catalog.json").expanduser()

def vol_of(path: str) -> str:
    parts = path.split("/")
    if len(parts) > 2 and parts[1] == "Volumes":
        return parts[2]
    return "Macintosh HD"

def names(r):
    out = []
    for k in ("confirmedByUserPeople", "detectedPeople", "suspectedPeople"):
        for p in r.get(k) or []:
            out.append(p.get("name", str(p)) if isinstance(p, dict) else str(p))
    return out

def score(r):
    s = 0
    if (r.get("starRating") or 0) >= 2: s += 3
    if r.get("confirmedByUserPeople"): s += 3
    if r.get("detectedPeople") or r.get("suspectedPeople"): s += 2
    if r.get("dossierProcessedAt"): s += 2
    if r.get("userNotes") or r.get("notes"): s += 1
    if (r.get("duplicateDisposition") or "") in ("Keep", "keep", "keeper"): s += 1
    return s

def excluded(r, include_offline, audio):
    if r.get("purgedAt"): return "purged"
    md = (r.get("mediaDisposition") or "")
    if md in ("Confirmed Junk", "Suspected Junk"): return "junk"
    if (r.get("duplicateDisposition") or "") in ("Extra copy", "extraCopy", "extra_copy"): return "extra-copy"
    if not audio and (r.get("streamTypeRaw") or "").lower().startswith("audio"): return "audio-only"
    if not include_offline and not os.path.exists("/Volumes/" + vol_of(r.get("fullPath", ""))) \
       and vol_of(r.get("fullPath", "")) != "Macintosh HD":
        return "offline"
    return None

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG)
    ap.add_argument("--top-gb", type=float, default=500.0, help="stop listing once cumulative GB exceeds this")
    ap.add_argument("--min-score", type=int, default=3)
    ap.add_argument("--csv", type=Path)
    ap.add_argument("--include-offline", action="store_true")
    ap.add_argument("--audio", action="store_true", help="include audio-only records")
    ap.add_argument("--max-file-gb", type=float, default=20.0,
                    help="files above this are listed separately as 'large intermediates', not working set")
    a = ap.parse_args()

    doc = json.load(open(a.catalog))
    recs = doc["records"]
    excl = defaultdict(int)
    cands = []
    for r in recs:
        why = excluded(r, a.include_offline, a.audio)
        if why:
            excl[why] += 1; continue
        sc = score(r)
        if sc < a.min_score:
            excl["low-score"] += 1; continue
        cands.append((sc, r.get("sizeBytes") or 0, r))
    # Working set = many useful clips, not a few giant intermediates:
    # highest score first, then SMALLER files first so more fit.
    big = [t for t in cands if t[1] > a.max_file_gb * 1e9]
    cands = [t for t in cands if t[1] <= a.max_file_gb * 1e9]
    cands.sort(key=lambda t: (-t[0], t[1]))
    big.sort(key=lambda t: -t[1])

    gb = lambda b: b / 1e9
    print(f"catalog: {len(recs):,} records (generation {doc.get('generation')})")
    print("excluded:", ", ".join(f"{k}={v:,}" for k, v in sorted(excl.items())))
    print(f"candidates (score >= {a.min_score}): {len(cands):,}  total {gb(sum(s for _, s, _ in cands)):,.1f} GB\n")

    by_vol = defaultdict(lambda: [0, 0])
    for sc, sz, r in cands:
        v = vol_of(r["fullPath"]); by_vol[v][0] += 1; by_vol[v][1] += sz
    print("per source volume:")
    for v, (n, b) in sorted(by_vol.items(), key=lambda kv: -kv[1][1]):
        print(f"  {v:<28} {n:>7,} files  {gb(b):>9,.1f} GB")

    print(f"\ntop candidates up to {a.top_gb:g} GB (score, GB, path):")
    cum = 0; rows = []
    for sc, sz, r in cands:
        if cum + sz > a.top_gb * 1e9: break
        cum += sz
        rows.append((sc, sz, r))
    for sc, sz, r in rows[:60]:
        print(f"  {sc:>2}  {gb(sz):>6.2f}  {r['fullPath']}")
    if len(rows) > 60:
        print(f"  … {len(rows)-60:,} more (use --csv)")
    print(f"\ncumulative: {len(rows):,} files, {gb(cum):,.1f} GB")
    if big:
        print(f"\nlarge intermediates (> {a.max_file_gb:g} GB each, {gb(sum(s for _, s, _ in big)):,.1f} GB total) — decide separately (archive? re-encode? keep on RAID?):")
        for sc, sz, r in big[:25]:
            print(f"  {sc:>2}  {gb(sz):>7.1f}  {r['fullPath']}")

    if a.csv:
        with open(a.csv, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["score", "size_bytes", "volume", "full_path", "star", "people", "id"])
            for sc, sz, r in rows:
                w.writerow([sc, sz, vol_of(r["fullPath"]), r["fullPath"], r.get("starRating") or 0,
                            ";".join(names(r)),
                            r.get("id")])
        print(f"wrote {a.csv}")

if __name__ == "__main__":
    main()
