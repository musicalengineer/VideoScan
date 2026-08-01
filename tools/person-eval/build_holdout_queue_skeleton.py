#!/usr/bin/env python3
"""Build the sealed-holdout LABEL-QUEUE SKELETON from Rick's in-app labels.

POI restart lane (Claude P1, 2026-07-23; codex handoff
docs/team-channel/2026-07-23-1213-codex-poi-c4-c6-execution-handoff.md,
corrected per 2026-07-23-1406-codex-poi-p1-leakage-blocker.md).

Reads (all read-only, none committed):
  - ~/Library/Application Support/VideoScan/validation_labels.json  (186 seed labels)
  - ~/Library/Application Support/VideoScan/catalog.json            (lineage fields)
  - /Volumes/CrucialX10/DonnaTestVideos/**                          (C4 training pool)
  - output/person-eval-private/2026-07-11/donna-development-arcface.json
                                                                     (6 dev cases)
  - ~/Library/Application Support/VideoScan/POI/donna/              (reference images)

Writes:
  PRIVATE (gitignored output/person-eval-private/<date>/) — ALL per-case data:
  - label-queue-skeleton.private.json   candidate list, selections, roles,
                                        seed ratings, lineage, flags, paths
  - grader-provenance-queue.csv         full prefilled queue (grader-only
                                        provenance; NOT Rick's review artifact)
  - training-lineage-ledger.private.json  per-file training inventory with
                                        unresolved lineage marked

  COMMITTED (docs/poi-holdout/) — AGGREGATE ONLY:
  - label-queue-summary.generated.json  counts only. The methodology doc
                                        label-queue-summary.md is authored.
                                        Neither may contain case IDs,
                                        selections, roles, ratings, basenames,
                                        hashes, dates, media metadata, volumes,
                                        source signals, or per-file inventory.

  Rick's neutral blind-review CSV is derived separately by
  tools/person-eval/make_neutral_review_csv.py from the private skeleton.

Discipline:
  - This tool produces a REVIEW QUEUE, not truth labels. Rick's confirmations
    and the final sealed holdout remain grader-only (codex custody).
  - Exclusion here is ADVISORY-CONSERVATIVE: exact-hash/path matches are
    excluded outright; anything that merely might share a source recording is
    FLAGGED unresolved, never silently included or dropped. Codex enforces the
    final forbidden-source ledger; hash equality alone is never treated as
    proof that two files are different source recordings.
  - Training files absent from the catalog have UNRESOLVED lineage: source
    isolation is NOT claimed until codex clears the forbidden-source ledger.
  - Deterministic: no randomness, no clock reads except the --date argument.
"""

import argparse
import csv
import json
import re
from collections import defaultdict
from pathlib import Path

APP_SUPPORT = Path.home() / "Library/Application Support/VideoScan"
TRAINING_DIR = Path("/Volumes/CrucialX10/DonnaTestVideos")
MEDIA_EXTS = {".mov", ".mp4", ".avi", ".mts", ".m4v", ".mkv", ".mxf", ".mpg"}
DURATION_SIBLING_TOLERANCE_S = 2.0
TARGET_POS = 18
TARGET_NEG = 18
MAX_RICK_NEGATIVES = 3


def load_json(path):
    with open(path) as f:
        return json.load(f)


def stem(name):
    return Path(name).stem.lower()


def year_of(record, path_str):
    raw = (record or {}).get("dateCreatedRaw") or ""
    m = re.match(r"(\d{4})", raw)
    if m and m.group(1) != "1904":
        return int(m.group(1))
    m = re.search(r"(19[5-9]\d|20[0-2]\d)", path_str)
    return int(m.group(1)) if m else None


def decade_of(year):
    return f"{year - year % 10}s" if year else "unknown"


def build(repo_root, date_tag):
    labels = load_json(APP_SUPPORT / "validation_labels.json")
    catalog = load_json(APP_SUPPORT / "catalog.json")["records"]
    dev = load_json(repo_root / "output/person-eval-private/2026-07-11/"
                    "donna-development-arcface.json")["cases"]

    by_path = {r["fullPath"]: r for r in catalog}
    by_hash = defaultdict(list)
    for r in catalog:
        if r.get("partialMD5"):
            by_hash[r["partialMD5"]].append(r)

    # ---- Forbidden-source seed sets -------------------------------------
    training_files = sorted(
        p for p in TRAINING_DIR.rglob("*") if p.suffix.lower() in MEDIA_EXTS
    )
    training = []
    for p in training_files:
        rec = by_path.get(str(p))
        training.append({
            "basename": p.name,
            "sizeBytes": p.stat().st_size,
            "partialMD5": (rec or {}).get("partialMD5"),
            "durationSeconds": (rec or {}).get("durationSeconds"),
            "inCatalog": rec is not None,
            "lineageStatus": "resolved" if rec is not None else "UNRESOLVED",
        })
    training_hashes = {t["partialMD5"] for t in training if t["partialMD5"]}
    training_durations = [t["durationSeconds"] for t in training
                          if t["durationSeconds"]]

    dev_hashes = {c["sourceGroup"].split("hash:")[-1] for c in dev}
    dev_paths = {c["video"] for c in dev}

    ref_dir = APP_SUPPORT / "POI" / "donna"
    ref_stems = {stem(p.name) for p in ref_dir.iterdir()
                 if p.suffix.lower() in {".jpg", ".jpeg", ".png"}}

    # Expand forbidden hashes to every same-bytes catalog path so identical
    # backup copies of a training/dev source are also excluded.
    forbidden_hashes = training_hashes | dev_hashes
    forbidden_paths = set(dev_paths)
    for h in forbidden_hashes:
        for r in by_hash.get(h, []):
            forbidden_paths.add(r["fullPath"])

    # ---- Candidate pool from the 186 seed labels ------------------------
    def role(lbl):
        if lbl["person"] == "Donna" and lbl["rating"] == "Definitely":
            return "positive"
        if lbl["person"] == "Donna" and lbl["rating"] == "No":
            return "negative"
        if lbl["person"] == "Rick" and lbl["rating"] == "Definitely":
            return "negative-family-male"
        return None

    # Detect conflicting seed labels on the same path.
    ratings_per_path = defaultdict(set)
    for lbl in labels:
        ratings_per_path[lbl["recordPath"]].add((lbl["person"], lbl["rating"]))
    conflicted = {
        p for p, rs in ratings_per_path.items()
        if {("Donna", "Definitely"), ("Donna", "No")} <= rs
    }

    rows, out_of_scope = [], 0
    for lbl in sorted(labels, key=lambda l: l["id"]):
        r = role(lbl)
        if r is None:
            out_of_scope += 1
            continue
        path = lbl["recordPath"]
        rec = by_path.get(path)
        h = (rec or {}).get("partialMD5")
        dur = (rec or {}).get("durationSeconds")

        flags = []
        status = "eligible"
        if path in conflicted:
            flags.append("conflicting-seed-labels")
        if rec is None:
            flags.append("not-in-current-catalog")
        if path in forbidden_paths or (h and h in forbidden_hashes):
            status = "excluded"
            flags.append("dev-case-source" if (path in dev_paths
                         or (h and h in dev_hashes))
                         else "training-source-exact-match")
        else:
            if dur and any(abs(dur - t) <= DURATION_SIBLING_TOLERANCE_S
                           for t in training_durations):
                flags.append("duration-sibling-of-training-clip")
            if stem(path) in ref_stems:
                flags.append("reference-image-stem-collision")
            if any(f in flags for f in (
                    "duration-sibling-of-training-clip",
                    "reference-image-stem-collision",
                    "not-in-current-catalog",
                    "conflicting-seed-labels")):
                status = "unresolved"

        rows.append({
            "caseId": lbl["id"],
            "role": r,
            "seedPerson": lbl["person"],
            "seedRating": lbl["rating"],
            "seedLabeledAt": lbl["labeledAt"],
            "seedSignals": lbl.get("signals", []),
            "basename": Path(path).name,
            "volume": path.split("/")[2] if path.startswith("/Volumes/") else "home",
            "lineage": {
                "partialMD5": h,
                "sizeBytes": (rec or {}).get("sizeBytes"),
                "durationSeconds": dur,
                "container": (rec or {}).get("container"),
                "videoCodec": (rec or {}).get("videoCodec"),
                "resolution": (rec or {}).get("resolution"),
                "dateCreatedRaw": (rec or {}).get("dateCreatedRaw"),
                "sourceHost": (rec or {}).get("sourceHost"),
            },
            "decade": decade_of(year_of(rec, path)),
            "status": status,
            "flags": flags,
            "fullPath": path,
        })

    # ---- One case per true source recording -----------------------------
    # Same partialMD5 => same bytes => one case. Same (stem,size) likewise.
    # Same stem with DIFFERENT bytes may be a re-encode of the same
    # recording: keep the first, flag the group unresolved.
    def dedupe(rows):
        seen_hash, seen_stem_size, kept_by_stem = {}, {}, {}
        for row in rows:
            h = row["lineage"]["partialMD5"]
            key_ss = (stem(row["basename"]), row["lineage"]["sizeBytes"])
            s = stem(row["basename"])
            if h and h in seen_hash:
                row["status"] = "duplicate"
                row["flags"].append(f"same-bytes-as:{seen_hash[h]}")
            elif key_ss in seen_stem_size:
                row["status"] = "duplicate"
                row["flags"].append(f"same-stem-size-as:{seen_stem_size[key_ss]}")
            elif s in kept_by_stem:
                prior = kept_by_stem[s]
                row["flags"].append(f"stem-sibling-of:{prior['caseId']}")
                prior.setdefault("flags", []).append(
                    f"stem-sibling-of:{row['caseId']}")
                if row["status"] == "eligible":
                    row["status"] = "unresolved"
                if prior["status"] == "eligible":
                    prior["status"] = "unresolved"
            else:
                if h:
                    seen_hash[h] = row["caseId"]
                seen_stem_size[key_ss] = row["caseId"]
                kept_by_stem[s] = row
        return rows

    dedupe(rows)

    # ---- Balanced selection from clean-eligible cases -------------------
    def spread_by_decade(cands, target):
        buckets = defaultdict(list)
        for c in cands:
            buckets[c["decade"]].append(c)
        picked, order = [], sorted(buckets)
        while len(picked) < target and any(buckets[d] for d in order):
            for d in order:
                if buckets[d] and len(picked) < target:
                    picked.append(buckets[d].pop(0))
        return picked

    eligible = [r for r in rows if r["status"] == "eligible"]
    pos = [r for r in eligible if r["role"] == "positive"]
    neg_d = [r for r in eligible if r["role"] == "negative"]
    neg_r = [r for r in eligible if r["role"] == "negative-family-male"]

    sel_pos = spread_by_decade(pos, TARGET_POS)
    sel_neg_r = neg_r[:MAX_RICK_NEGATIVES]
    sel_neg = spread_by_decade(neg_d, TARGET_NEG - len(sel_neg_r)) + sel_neg_r
    for r in sel_pos + sel_neg:
        r["selected"] = True

    summary = {
        "seedLabelsTotal": len(labels),
        "outOfScopeLabels": out_of_scope,
        "candidateRows": len(rows),
        "excluded": sum(1 for r in rows if r["status"] == "excluded"),
        "duplicates": sum(1 for r in rows if r["status"] == "duplicate"),
        "unresolved": sum(1 for r in rows if r["status"] == "unresolved"),
        "eligible": len(eligible),
        "eligiblePositives": len(pos),
        "eligibleNegatives": len(neg_d) + len(neg_r),
        "selectedPositives": len(sel_pos),
        "selectedNegatives": len(sel_neg),
        "trainingPoolFiles": len(training),
        "trainingPoolLineageUnresolved":
            sum(1 for t in training if not t["inCatalog"]),
        "devCases": len(dev),
        "referenceImages": len(ref_stems),
    }
    return rows, training, summary, date_tag


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo-root", required=True)
    ap.add_argument("--out-root", required=True,
                    help="worktree root receiving docs/poi-holdout/")
    ap.add_argument("--date", required=True, help="YYYY-MM-DD run date tag")
    args = ap.parse_args()

    repo_root = Path(args.repo_root)
    out_root = Path(args.out_root)
    rows, training, summary, date_tag = build(repo_root, args.date)

    # ---- PRIVATE outputs (gitignored output/ tree) ----------------------
    priv_dir = repo_root / "output/person-eval-private" / date_tag
    priv_dir.mkdir(parents=True, exist_ok=True)

    skeleton = {
        "generated": date_tag,
        "generator": "tools/person-eval/build_holdout_queue_skeleton.py",
        "seed": "validation_labels.json (Rick in-app labels, June 2026)",
        "summary": summary,
        "trainingLineageLedger": training,
        "cases": rows,
    }
    with open(priv_dir / "label-queue-skeleton.private.json", "w") as f:
        json.dump(skeleton, f, indent=1, sort_keys=True)
        f.write("\n")

    with open(priv_dir / "training-lineage-ledger.private.json", "w") as f:
        json.dump({"generated": date_tag, "files": training}, f,
                  indent=1, sort_keys=True)
        f.write("\n")

    # Grader-only provenance CSV (prefilled). NOT Rick's review artifact —
    # the neutral blind CSV comes from make_neutral_review_csv.py.
    with open(priv_dir / "grader-provenance-queue.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["caseId", "selected", "status", "role", "seedRating",
                    "decade", "fullPath", "flags",
                    "rickConfirm(yes/no)", "notes"])
        for r in sorted(rows, key=lambda r: (not r.get("selected", False),
                                             r["role"], r["decade"])):
            w.writerow([r["caseId"], "YES" if r.get("selected") else "",
                        r["status"], r["role"], r["seedRating"], r["decade"],
                        r["fullPath"], ";".join(r["flags"]), "", ""])

    # ---- COMMITTED output: aggregate-only summary -----------------------
    doc_dir = out_root / "docs/poi-holdout"
    doc_dir.mkdir(parents=True, exist_ok=True)
    with open(doc_dir / "label-queue-summary.generated.json", "w") as f:
        json.dump({"generated": date_tag, "summary": summary}, f,
                  indent=1, sort_keys=True)
        f.write("\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
