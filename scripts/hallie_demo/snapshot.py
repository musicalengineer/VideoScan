#!/usr/bin/env python3
"""Export read-only TEXT snapshots of the family data for the Hallie
"take two" blind demo.

Reads (never writes):
  - the merged GEDCOM the installed tree was compiled from (path taken from
    family-tree/compiled/<current>/manifest.json), plus the person-refresh
    overlay and the family-identity decisions file next to the GEDCOM;
  - People tab profiles (POI/<uuid>/profile.json) and family groups
    (POI/Families/*.json);
  - CyberBrain (cyberbrain/cyberbrain.json);
  - the catalog (catalog.sqlite, read-only through scripts/catalog_db.py —
    no catalog.cutover ⇒ refused; never the frozen catalog.json), skipping
    purged / deleted / trashed records.

Writes four JSON files into --out:
  tree.json, people.json, brain.json, catalog.json  (+ manifest.json)

Never copies pixels, audio, frames or face embeddings: only names, dates,
places, notes, tags, filenames and short text fields. Photo filenames,
reference paths and face thresholds are dropped from profiles.

Usage:
  venv/bin/python scripts/hallie_demo/snapshot.py --out <dir>
"""
from __future__ import annotations

import argparse
import datetime as dt
import glob
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir))
import catalog_db  # noqa: E402  (the one read-only door to catalog.sqlite)

APP_SUPPORT = os.path.expanduser("~/Library/Application Support/VideoScan")
DEFAULT_OUT = ("/private/tmp/claude-501/-Users-rickb-dev-VideoScan/"
               "8562e4d1-ff42-4e46-b1b8-94e04b855380/scratchpad/hallie_demo/snapshots")
APPLE_EPOCH = dt.datetime(2001, 1, 1, tzinfo=dt.timezone.utc)

TRANSCRIPT_CHARS = 2000
CAPTION_CHARS = 400
MAX_CAPTIONS = 12
SYSTEM_NOTES_CHARS = 300


# ---------------------------------------------------------------- GEDCOM

def year_of(date: str | None) -> int | None:
    if not date:
        return None
    m = re.search(r"\b(\d{4})\b", date) or re.search(r"\b(\d{3})\b", date)
    return int(m.group(1)) if m else None


def split_name(raw: str) -> dict:
    m = re.match(r"^(.*?)/(.*?)/(.*)$", raw.strip())
    if m:
        given, surname, suffix = (m.group(1).strip(), m.group(2).strip(), m.group(3).strip())
    else:
        given, surname, suffix = raw.strip(), "", ""
    full = " ".join(p for p in (given, surname, suffix) if p)
    return {"full": full, "given": given, "surname": surname, "suffix": suffix}


def parse_gedcom(path: str) -> dict:
    people: dict[str, dict] = {}
    fams: dict[str, dict] = {}
    roots: list[str] = []
    cur = None
    cur_kind = None
    event = None
    with open(path, encoding="utf-8-sig", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\r\n")
            parts = line.split(" ", 2)
            if len(parts) < 2:
                continue
            level = parts[0]
            if level == "0":
                event = None
                if len(parts) == 3 and parts[2] == "INDI":
                    cur = {"id": parts[1], "names": [], "sex": None, "birth": {}, "death": {},
                           "famc": [], "fams": [], "fsid": None}
                    people[parts[1]] = cur
                    cur_kind = "INDI"
                elif len(parts) == 3 and parts[2] == "FAM":
                    cur = {"id": parts[1], "husb": None, "wife": None, "children": [], "marriage": {}}
                    fams[parts[1]] = cur
                    cur_kind = "FAM"
                else:
                    cur, cur_kind = None, "HEAD" if parts[1] == "HEAD" else None
                continue
            tag = parts[1]
            val = parts[2] if len(parts) == 3 else ""
            if cur_kind == "HEAD" and level == "1" and tag == "_VS_ROOT":
                roots.append(val.strip())
                continue
            if cur is None:
                continue
            if level == "1":
                event = None
                if cur_kind == "INDI":
                    if tag == "NAME":
                        cur["names"].append(split_name(val))
                    elif tag == "SEX":
                        cur["sex"] = val.strip() or None
                    elif tag in ("BIRT", "CHR") and (tag == "BIRT" or not cur["birth"]):
                        event = "birth"
                    elif tag in ("DEAT", "BURI") and (tag == "DEAT" or not cur["death"]):
                        event = "death"
                    elif tag == "FAMC":
                        cur["famc"].append(val.strip())
                    elif tag == "FAMS":
                        cur["fams"].append(val.strip())
                    elif tag == "_FSFTID":
                        cur["fsid"] = val.strip()
                else:
                    if tag == "HUSB":
                        cur["husb"] = val.strip()
                    elif tag == "WIFE":
                        cur["wife"] = val.strip()
                    elif tag == "CHIL":
                        cur["children"].append(val.strip())
                    elif tag == "MARR":
                        event = "marriage"
            elif level == "2" and event and tag in ("DATE", "PLAC"):
                key = "date" if tag == "DATE" else "place"
                cur[event][key] = val.strip()
    return {"people": people, "families": fams, "roots": roots}


def build_tree(app: str) -> tuple[dict, dict]:
    ft = os.path.join(app, "family-tree")
    current = json.load(open(os.path.join(ft, "compiled", "current.json")))
    manifest = json.load(open(os.path.join(ft, "compiled", current["current"], "manifest.json")))
    src = manifest["sources"][0]
    ged_path = src["path"]
    parsed = parse_gedcom(ged_path)
    people = parsed["people"]

    # person-refresh overlay (keyed by FamilySearch id)
    overlay_path = os.path.join(ft, "person-refresh", "overlay.json")
    applied = []
    by_fsid = {p["fsid"]: p for p in people.values() if p["fsid"]}
    if os.path.exists(overlay_path):
        ov = json.load(open(overlay_path))
        for fsid, entry in ov.get("entries", {}).items():
            p = by_fsid.get(fsid)
            if not p:
                continue
            facts = entry.get("facts", {})
            if "birthDate" in facts:
                p["birth"]["date"] = facts["birthDate"]["value"]
            if "birthPlace" in facts:
                p["birth"]["place"] = facts["birthPlace"]["value"]
            if "name" in facts and p["names"]:
                n = split_name(p["names"][0]["full"])
                newfull = facts["name"]["value"]
                if n["surname"] and newfull.endswith(n["surname"]):
                    given = newfull[: -len(n["surname"])].strip()
                    p["names"][0] = {"full": newfull, "given": given, "surname": n["surname"], "suffix": n["suffix"]}
            applied.append(fsid)

    decisions = []
    dec_path = os.path.join(os.path.dirname(ged_path), "family-identity-decisions.json")
    if os.path.exists(dec_path):
        decisions = json.load(open(dec_path))
    for d in decisions:
        p = by_fsid.get(d.get("key"))
        if p is not None:
            p["identityDecision"] = {k: d[k] for k in ("note", "verified", "duplicateOf") if k in d}

    owner_fsid = read_owner_fsid()
    owner = None
    if owner_fsid and owner_fsid in by_fsid:
        owner = by_fsid[owner_fsid]["id"]
    elif parsed["roots"]:
        owner = parsed["roots"][0]

    for p in people.values():
        p["birth"]["year"] = year_of(p["birth"].get("date"))
        p["death"]["year"] = year_of(p["death"].get("date"))
        if not p["birth"].get("date") and not p["birth"].get("place"):
            p["birth"] = {}
        if not p["death"].get("date") and not p["death"].get("place"):
            p["death"] = {}
    for f in parsed["families"].values():
        if f["marriage"]:
            f["marriage"]["year"] = year_of(f["marriage"].get("date"))

    tree = {
        "source": {"gedcom": os.path.basename(ged_path), "generation": current["current"],
                   "peopleCount": len(people), "familyCount": len(parsed["families"])},
        "owner": owner,
        "ownerFamilySearchID": owner_fsid,
        "roots": parsed["roots"],
        "overlayApplied": applied,
        "people": people,
        "families": parsed["families"],
    }
    return tree, {"gedcom": ged_path}


def read_owner_fsid() -> str | None:
    try:
        out = subprocess.run(["defaults", "read", "Rick-Breen.VideoScan", "hallie.ownerFamilySearchID"],
                             capture_output=True, text=True, timeout=10)
        v = out.stdout.strip()
        return v or None
    except Exception:
        return None


# ---------------------------------------------------------------- People tab

def apple_date(v) -> str | None:
    if v is None:
        return None
    try:
        return (APPLE_EPOCH + dt.timedelta(seconds=float(v))).date().isoformat()
    except Exception:
        return None


PROFILE_KEEP = ("uuid", "name", "middleName", "surname", "maidenName", "suffix", "aliases", "titles",
                "sex", "notes", "identityNotes", "notInFamilyTree", "treeIdentityAttestation")


def build_people(app: str) -> dict:
    profiles = []
    for p in sorted(glob.glob(os.path.join(app, "POI", "*", "profile.json"))):
        d = json.load(open(p))
        slim = {k: d.get(k) for k in PROFILE_KEEP if d.get(k) not in (None, "", [])}
        slim["birthDate"] = apple_date(d.get("birthdate"))
        slim["deathDate"] = apple_date(d.get("deathdate"))
        fsid = (d.get("treeIdentity") or {}).get("familySearchID")
        if fsid:
            slim["familySearchID"] = fsid
        slim["kinships"] = [{"relation": k.get("relation"),
                             "to": ((k.get("relativeTo") or {}).get("profile") or {}).get("id")}
                            for k in d.get("kinships") or []]
        slim["featuredVideos"] = [v.get("filename") for v in d.get("featuredVideos") or []]
        profiles.append(slim)
    families = []
    for p in sorted(glob.glob(os.path.join(app, "POI", "Families", "*.json"))):
        d = json.load(open(p))
        families.append({"uuid": d.get("uuid"), "name": d.get("name"),
                         "featuredVideos": [v.get("filename") for v in d.get("featuredVideos") or []]})
    return {"profiles": profiles, "families": families}


# ---------------------------------------------------------------- CyberBrain

def build_brain(app: str) -> dict:
    cb = json.load(open(os.path.join(app, "cyberbrain", "cyberbrain.json")))
    people, items = [], []
    for p in cb.get("people", []):
        people.append({"id": p["id"], "canonicalName": p.get("canonicalName"),
                       "aliases": p.get("aliases") or [], "terminology": p.get("terminology") or [],
                       "gedcomPersonID": p.get("gedcomPersonID")})
        for key in ("biographyPassages", "notes", "lifeEvents", "anecdotes"):
            for it in p.get(key) or []:
                if it.get("status", "active") != "active":
                    continue
                row = {k: it.get(k) for k in ("id", "kind", "text", "confidence", "privacy",
                                               "sourceIDs", "subjectPersonIDs", "createdAt")}
                if it.get("service"):
                    row["service"] = it["service"]
                row["ownerPersonID"] = p["id"]
                items.append(row)
    sources = [{k: s.get(k) for k in ("id", "title", "attribution", "type")} for s in cb.get("sources", [])]
    # One item may be listed under several people; keep one copy.
    seen, uniq = set(), []
    for it in items:
        if it["id"] in seen:
            continue
        seen.add(it["id"])
        uniq.append(it)
    return {"people": people, "items": uniq, "sources": sources}


# ---------------------------------------------------------------- Catalog

SKIP_STAGES = {"Deleted", "Trashed"}
MACHINE_NOTE = re.compile(r"^(ffprobe:|recipe:|Reconcile |Relocat|Promot|Dedup|Repair|scan:)", re.I)


def best_year(r: dict) -> tuple[int | None, str | None]:
    if r.get("userDate"):
        y = year_of(r["userDate"])
        if y:
            return y, "userDate"
    rng = r.get("inferredDateRange")
    if rng and rng.get("startYear"):
        return rng["startYear"], "inferredDateRange"
    # A year typed into the filename ("AtHudsons-Thanksgiving-1984.mov") beats
    # the file's own creation stamp, which is usually the transfer date.
    m = re.search(r"(?<!\d)(19[3-9]\d|20[0-2]\d)(?!\d)", r.get("filename", ""))
    if m:
        return int(m.group(1)), "filename"
    if r.get("inferredRecordDate"):
        return year_of(r["inferredRecordDate"]), "inferred"
    if r.get("embeddedCreationDate"):
        return year_of(r["embeddedCreationDate"]), "embedded"
    return None, None


def names_of(v) -> list[str]:
    out = []
    for x in v or []:
        if isinstance(x, str):
            out.append(x)
        elif isinstance(x, dict) and x.get("name"):
            out.append(x["name"])
    return sorted(set(out))


def build_catalog(app: str) -> tuple[dict, dict]:
    all_records, generation = catalog_db.load(os.path.join(app, catalog_db.DATABASE_FILE_NAME))
    recs, skipped = [], {"purged": 0, "deletedOrTrashed": 0}
    for r in all_records:
        if r.get("purgedAt"):
            skipped["purged"] += 1
            continue
        if r.get("lifecycleStage") in SKIP_STAGES:
            skipped["deletedOrTrashed"] += 1
            continue
        year, ysrc = best_year(r)
        sys_notes = "\n".join(l for l in (r.get("notes") or "").splitlines()
                              if l.strip() and not MACHINE_NOTE.match(l.strip()))
        caps = [{"t": round(c.get("timestamp") or 0, 1), "text": (c.get("text") or "")[:CAPTION_CHARS]}
                for c in (r.get("sceneCaptions") or [])[:MAX_CAPTIONS]]
        rec = {
            "id": r["id"],
            "filename": r.get("filename"),
            "path": r.get("fullPath"),
            "volume": (r.get("scanContext") or {}).get("volumeName"),
            "durationSeconds": r.get("durationSeconds"),
            "streamType": r.get("streamTypeRaw"),
            "lifecycleStage": r.get("lifecycleStage"),
            "archiveStage": r.get("archiveStage"),
            "contentHash": r.get("contentHash"),
            "duplicateGroupID": r.get("duplicateGroupID"),
            "dateCreated": r.get("dateCreated") or r.get("dateCreatedRaw"),
            "embeddedCreationDate": r.get("embeddedCreationDate"),
            "userDate": r.get("userDate"),
            "inferredRecordDate": r.get("inferredRecordDate"),
            "inferredDateRange": r.get("inferredDateRange"),
            "year": year,
            "yearSource": ysrc,
            "userPlace": r.get("userPlace"),
            "tags": r.get("tags") or [],
            "starRating": r.get("starRating"),
            "confirmedPeople": names_of(r.get("confirmedByUserPeople")),
            "detectedPeople": names_of(r.get("detectedPeople")),
            "suspectedPeople": names_of(r.get("suspectedPeople")),
            "rejectedPeople": names_of(r.get("rejectedPeople")),
            "userNotes": r.get("userNotes"),
            "systemNotes": sys_notes[:SYSTEM_NOTES_CHARS] or None,
            "transcriptSnippet": (r.get("audioTranscript") or "")[:TRANSCRIPT_CHARS] or None,
            "captions": caps,
        }
        recs.append({k: v for k, v in rec.items() if v not in (None, "", [])})
    meta = {"source": catalog_db.DATABASE_FILE_NAME, "generation": generation,
            "recordsInCatalog": len(all_records), "recordsKept": len(recs), "skipped": skipped}
    return {"meta": meta, "records": recs}, meta


# ---------------------------------------------------------------- main

def write(out: str, name: str, obj) -> int:
    path = os.path.join(out, name)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(obj, fh, ensure_ascii=False, separators=(",", ":"))
    os.replace(tmp, path)
    return os.path.getsize(path)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--app-support", default=APP_SUPPORT)
    a = ap.parse_args(argv)
    os.makedirs(a.out, exist_ok=True)
    tree, tree_meta = build_tree(a.app_support)
    people = build_people(a.app_support)
    brain = build_brain(a.app_support)
    catalog, cat_meta = build_catalog(a.app_support)
    sizes = {
        "tree.json": write(a.out, "tree.json", tree),
        "people.json": write(a.out, "people.json", people),
        "brain.json": write(a.out, "brain.json", brain),
        "catalog.json": write(a.out, "catalog.json", catalog),
    }
    manifest = {
        "createdAt": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "sources": {"gedcom": tree_meta["gedcom"], "appSupport": a.app_support},
        "counts": {"treePeople": len(tree["people"]), "treeFamilies": len(tree["families"]),
                   "profiles": len(people["profiles"]), "familyGroups": len(people["families"]),
                   "brainPeople": len(brain["people"]), "brainItems": len(brain["items"]),
                   **cat_meta},
        "owner": tree["owner"],
        "bytes": sizes,
    }
    write(a.out, "manifest.json", manifest)
    json.dump(manifest, sys.stdout, indent=1)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
