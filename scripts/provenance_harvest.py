#!/usr/bin/env python3
"""provenance_harvest.py — Provenance Phase 0: gather the evidence (READ-ONLY).

Produces machine-inferred provenance DRAFTS, each value tagged with state, confidence
and evidence, for (a) every archive Master (archive_copies digests) and (b) every file
of the July 2026 VHS batch (any path containing `Converted_VHS_Tapes_2026/`), grouped
by proposed tape (carrier).  Lens 4 of the provenance deep dive
(docs/research/provenance_deep_dive_2026-10-23.md): real drafts to judge the design by.

    python3 scripts/provenance_harvest.py <catalog-backup.sqlite> \
        [--out-dir DIR] [--csv PATH] [--html PATH] [--no-probe] [--no-thumbs] [--july-root DIR]

Hard rules honoured here:
  * the catalog is opened with `file:...?mode=ro` (URI) — never the live catalog;
  * media is only probed (DV frame reads at seek points, ffmpeg frame grabs for
    thumbnails); nothing under /Volumes is written, renamed or moved; tool output
    goes to --out-dir only;
  * a user value (user_dates) is state=confirmed and is never re-emitted as inferred;
  * values derived from Rick's Promote-time archive name (the `YYYY-MM-DD_` prefix
    and the `30_Video/<decade>/<year>/` folder) are tier B evidence: used only as a
    fallback, flagged `derived_from_user`, and excluded from the accuracy self-check.

Vocabulary (deep dive §1): PBCore instantiationPhysical (VHS, MiniDV, 8mm film …),
instantiationGenerations (Original, Dub, Preservation, Copy: Access, Master: production,
Work tapes), dateType created/digitized/ingested; states inferred|confirmed.
"""
from __future__ import annotations

import argparse
import base64
import collections
import csv
import datetime as dt
import html
import json
import os
import re
import sqlite3
import subprocess
import sys
import time
from zoneinfo import ZoneInfo

LOCAL_TZ = ZoneInfo("America/New_York")
JULY_MARK = "Converted_VHS_Tapes_2026/"
ARCHIVE_ROOT = "/Volumes/FamilyArchive/Breen_Family_Archive/30_Video/"
JULY_ENCODER = "Lavf61.7.100"
DV_FRAME_NTSC = 120000
YEAR_RE = re.compile(r"(?<!\d)(19[4-9]\d|20[0-2]\d)(?!\d)")
DECADE_RE = re.compile(r"(?<!\d)(19[4-9]0|20[0-2]0)s(?!\d)")
CLOCK_NAME_RE = re.compile(r"^(\d{4})-(\d\d)-(\d\d)_(\d\d)-(\d\d)-(\d\d)")
ARCHIVE_PREFIX_RE = re.compile(r"^((\d{4}|x{4})-(\d\d|xx)-(\d\d|xx)_)+")
DERIV_SUFFIXES = [
    (r"\.vs\.archive$", "access"), (r"-vs-archive$", "access"),
    (r"\.vs\.preserve$", "preserve"), (r"-vs-preserve$", "preserve"),
    (r"\.vs\.edit$", "edit"), (r"-vs-edit$", "edit"),
    (r"_0\d$", "copy"), (r"_trimmed$", "edit"), (r"_balanced$", "restore"),
    (r"_cleaned$", "restore"), (r"_repaired$", "restore"), (r"_prob4$", "restore"),
    (r"_hyp\d$", "restore"), (r"_nyx\d$", "restore"), (r"_thm\d$", "restore"),
    (r"_denoise$", "restore"), (r"_Improved_slp$", "restore"), (r"_old_codec$", "copy"),
    (r"_compilation$", "edit"), (r"_v\d$", "copy"), (r"_Recovered$", "recovered"),
    (r"[-_]edit$", "edit"), (r"_part_x$", "variant"), (r"_misc$", "variant"), (r"_etc$", "variant"),
    # capture-variant markers (pixel format / test captures) — NOT derivatives
    (r"_P216(_\d)?$", "variant"), (r"_NV12(_\d)?$", "variant"), (r"_422_8bit$", "variant"),
    (r"_1080p_ProResLT$", "variant"), (r"-archive$", "variant"),
]
DERIV_KINDS = {"access", "preserve", "edit", "copy", "restore", "recovered"}
TEST_NAME_RE = re.compile(r"(^|[_-])(P216|NV12|prob\d|test)([_-]|$|\.)", re.I)
EDIT_WORDS_RE = re.compile(r"(Sequence|Part\d|part\d|Chapters|compilation|Section|edit)", re.I)
APPLE_DV_ENCODERS = ("DV/DVCPRO - NTSC", "DV - NTSC")


# ----------------------------------------------------------------------------- helpers
def utc(ts):
    return None if ts is None else dt.datetime.fromtimestamp(ts, dt.timezone.utc)


def local_date(ts):
    d = utc(ts)
    return None if d is None else d.astimezone(LOCAL_TZ).date().isoformat()


def local_dt(ts):
    d = utc(ts)
    return None if d is None else d.astimezone(LOCAL_TZ).strftime("%Y-%m-%d %H:%M")


def strip_archive_prefix(name):
    return ARCHIVE_PREFIX_RE.sub("", name)


def split_name(filename):
    base = filename
    ext = ""
    m = re.match(r"^(.*?)((\.[A-Za-z0-9]{1,5})+)$", filename)
    if m and not filename.startswith("."):
        base, ext = m.group(1), m.group(2)
    return base, ext


def stem_core(filename):
    """The capture/original stem: archive date prefixes and derivative suffixes removed."""
    base, _ = split_name(filename)
    base = strip_archive_prefix(base)
    kinds = []
    changed = True
    while changed:
        changed = False
        for pat, kind in DERIV_SUFFIXES:
            new = re.sub(pat, "", base, flags=re.I)
            if new != base:
                base, changed = new, True
                kinds.append(kind)
    # dotted derivative markers in the middle (`Christmas_1994_etc.vs.edit.vs.archive`)
    base = re.sub(r"\.vs\.(edit|archive|preserve)", "", base, flags=re.I)
    core = base.strip("_- ").lower()
    if not core:  # `NV12.mkv` → keep the name itself
        core = strip_archive_prefix(split_name(filename)[0]).strip("_- ").lower()
    return core, [k for k in kinds if k in DERIV_KINDS]


def years_in(text):
    """4-digit years in a name, oldest-first order of appearance; a capture-clock prefix
    (`2026-07-05_12-55-56`) and decade words (`1960s`) are removed first."""
    text = CLOCK_NAME_RE.sub("", text or "")
    text = DECADE_RE.sub(" ", text)
    out = []
    for m in YEAR_RE.finditer(text):
        y = int(m.group(1))
        if y not in out:
            out.append(y)
    return out


def norm_key(s):
    return re.sub(r"[^a-z0-9]+", "", (s or "").lower())


def pct(n, d):
    return 0.0 if not d else round(100.0 * n / d, 1)


# ----------------------------------------------------------------------------- DV probe
def bcd(b):
    return ((b >> 4) & 0xF) * 10 + (b & 0xF)


def dv_packs(frame):
    """Count the REC DATE (0x62) / REC TIME (0x63) packs in one DV frame (VAUX + subcode)."""
    c = collections.Counter()
    for i in range(0, len(frame) - 79, 80):
        blk = frame[i:i + 80]
        sct = blk[0] >> 5
        if sct == 1:   # subcode: 3-byte ID then 6 SSYBs of (3-byte ID + 5-byte pack)
            for s in range(6):
                p = blk[6 + s * 8:11 + s * 8]
                if len(p) == 5 and p[0] in (0x62, 0x63):
                    c[bytes(p)] += 1
        elif sct == 2:  # VAUX: 3-byte ID then 15 packs of 5 bytes
            for s in range(15):
                p = blk[3 + s * 5:8 + s * 5]
                if len(p) == 5 and p[0] in (0x62, 0x63):
                    c[bytes(p)] += 1
    return c


def dv_decode(frame):
    """(date 'YYYY-MM-DD' | None, time 'HH:MM:SS' | None) from the most common packs."""
    date = tm = None
    for p, _ in dv_packs(frame).most_common():
        if p[0] == 0x62 and date is None and p[4] != 0xFF and p[2] != 0xFF:
            day, mon, yr = bcd(p[2] & 0x3F), bcd(p[3] & 0x1F), bcd(p[4])
            yr += 2000 if yr < 75 else 1900
            if 1 <= mon <= 12 and 1 <= day <= 31:
                date = f"{yr:04d}-{mon:02d}-{day:02d}"
        if p[0] == 0x63 and tm is None and p[4] != 0xFF and p[3] != 0xFF:
            tm = f"{bcd(p[4] & 0x3F):02d}:{bcd(p[3] & 0x7F):02d}:{bcd(p[2] & 0x7F):02d}"
    return date, tm


def dv_frame_raw(path, idx):
    with open(path, "rb") as f:
        f.seek(idx * DV_FRAME_NTSC)
        return f.read(DV_FRAME_NTSC)


def dv_frame_container(path, seconds):
    r = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-ss", f"{seconds:.3f}", "-i", path,
                        "-map", "0:v:0", "-c", "copy", "-frames:v", "1", "-f", "rawvideo", "-"],
                       capture_output=True, timeout=120)
    return r.stdout[:DV_FRAME_NTSC]


def dv_probe(path, duration_s, is_raw_dv, samples=9):
    """Sample `samples` frames across the file; return rec_start/rec_end/dates/samples."""
    t0 = time.time()
    out = {"path": path, "samples": [], "rec_start": None, "rec_end": None, "dates": [],
           "stripped": False, "error": None}
    try:
        if is_raw_dv:
            n = os.path.getsize(path) // DV_FRAME_NTSC
            idxs = sorted({min(n - 1, int(round(i * (n - 1) / (samples - 1)))) for i in range(samples)})
            frames = [(idx / 29.97, dv_frame_raw(path, idx)) for idx in idxs]
        else:
            dur = max(duration_s or 0, 1.0)
            secs = sorted({round(i * max(dur - 1.0, 0) / (samples - 1), 2) for i in range(samples)})
            frames = [(s, dv_frame_container(path, s)) for s in secs]
        for sec, fr in frames:
            if len(fr) < DV_FRAME_NTSC:
                out["samples"].append({"t": round(sec, 1), "date": None, "time": None, "short": True})
                continue
            d, tm = dv_decode(fr)
            out["samples"].append({"t": round(sec, 1), "date": d, "time": tm})
        valid = [s for s in out["samples"] if s["date"]]
        if valid:
            out["rec_start"] = valid[0]["date"] + (" " + valid[0]["time"] if valid[0]["time"] else "")
            out["rec_end"] = valid[-1]["date"] + (" " + valid[-1]["time"] if valid[-1]["time"] else "")
            for s in valid:
                if s["date"] not in out["dates"]:
                    out["dates"].append(s["date"])
        else:
            out["stripped"] = any(not s.get("short") for s in out["samples"])
    except Exception as e:  # noqa: BLE001 — a probe failure is evidence, not a crash
        out["error"] = f"{type(e).__name__}: {e}"
    out["seconds"] = round(time.time() - t0, 2)
    return out


# ----------------------------------------------------------------------------- thumbnails
def grab_thumbs(path, duration_s, n=4, width=160, budget_s=25.0):
    """≤n JPEG frames (base64) at even offsets; gives up when a single grab is slow."""
    thumbs = []
    dur = max(duration_s or 0, 1.0)
    t_all = time.time()
    for i in range(n):
        sec = dur * (i + 0.5) / n
        t0 = time.time()
        try:
            r = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-ss", f"{sec:.2f}", "-i", path,
                                "-frames:v", "1", "-an", "-vf", f"scale={width}:-2", "-f", "image2",
                                "-c:v", "mjpeg", "-q:v", "6", "-"], capture_output=True, timeout=60)
            if r.stdout:
                thumbs.append(base64.b64encode(r.stdout).decode("ascii"))
        except Exception:  # noqa: BLE001
            break
        if time.time() - t0 > budget_s or time.time() - t_all > 2 * budget_s:
            break
    return thumbs


# ----------------------------------------------------------------------------- catalog
def load_catalog(db_path):
    # Read-only by construction (URI mode=ro + query_only), the one door for scripts.
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import catalog_db  # noqa: E402
    con = catalog_db.connect(db_path)
    cat = {}
    cat["files"] = [dict(r) for r in con.execute(
        "SELECT id, content_digest, full_path, filename, ext, directory, size_bytes, fs_created_at, "
        "fs_modified_at, stream_type, duration_s, container, video_codec, audio_codec, "
        "embedded_created_at, embedded_created_source, probe_extra, scanned_at, lifecycle, "
        "archive_stage, removal_state, removal_reason, original_full_path FROM files")]
    for f in cat["files"]:
        try:
            f["extra"] = json.loads(f["probe_extra"] or "{}")
        except json.JSONDecodeError:
            f["extra"] = {}
    cat["by_digest"] = collections.defaultdict(list)
    for f in cat["files"]:
        cat["by_digest"][f["content_digest"]].append(f)
    cat["archive_copies"] = [dict(r) for r in con.execute(
        "SELECT ac.file_id, ac.source_file_id, ac.source_row_id, ac.archived_at, ac.promoted_by, "
        "f.content_digest FROM archive_copies ac JOIN files f ON f.id = ac.file_id")]
    cat["user_dates"] = {r["digest"]: dict(r) for r in con.execute(
        "SELECT digest, value, confidence, set_at, conflict FROM user_dates")}
    cat["inferred_dates"] = {r["digest"]: dict(r) for r in con.execute(
        "SELECT digest, date_at, confidence, source, range_start, range_end, reason FROM inferred_dates")}
    cat["first_seen"] = {r["digest"]: (r["first_seen_at"], r["first_seen_how"]) for r in con.execute(
        "SELECT digest, first_seen_at, first_seen_how FROM content")}
    cat["events_by_digest"] = collections.defaultdict(list)
    for r in con.execute("SELECT em.digest, e.name, e.state, e.kind FROM event_members em "
                         "JOIN events e ON e.event_id = em.event_id"):
        cat["events_by_digest"][r["digest"]].append(f"{r['name']} ({r['state']})")
    cat["lineage"] = collections.defaultdict(list)
    for r in con.execute("SELECT child_digest, parent_digest, kind FROM lineage"):
        cat["lineage"][r["child_digest"]].append((r["parent_digest"], r["kind"]))
    cat["ledger_kinds"] = {r[0] for r in con.execute("SELECT DISTINCT kind FROM ledger")}
    cat["ledger_first"] = {}
    if "cataloged" in cat["ledger_kinds"]:
        for r in con.execute("SELECT digest, min(at) FROM ledger WHERE kind='cataloged' "
                             "AND digest IS NOT NULL GROUP BY digest"):
            cat["ledger_first"][r[0]] = r[1]
    con.close()
    return cat


def july_folder_of(path):
    i = path.find(JULY_MARK)
    if i < 0:
        return None
    rest = path[i + len(JULY_MARK):]
    return rest.split("/")[0] if "/" in rest else None


def pick_representative(rows):
    def rank(f):
        p = f["full_path"]
        return (f["removal_state"] is not None,
                not p.startswith("/Volumes/FamilyArchive/"),
                p.startswith("/Volumes/LaCieWorkspace/") or p.startswith("/Volumes/MediaExpansion/"),
                not os.path.exists(p))
    return sorted(rows, key=rank)[0]


# ----------------------------------------------------------------------------- subjects
class Subject:
    def __init__(self, kind, digest, rep, rows):
        self.kind = kind            # 'master' | 'july'
        self.digest = digest
        self.rep = rep              # representative files row (dict) — may be synthetic for disk-only
        self.rows = rows            # all catalog rows with this digest
        self.fields = {}            # field -> dict(value, state, conf, source, evidence[list])
        self.evidence = []
        self.tape_key = None
        self.notes = []

    # names and years, excluding Rick's Promote-time archive prefix/folder (tier B)
    def original_names(self):
        """Every name this content has carried; archive names with Rick's date prefix stripped
        (the stem after the prefix is the pre-Promote filename)."""
        names = []
        for f in self.rows:
            if f["full_path"].startswith(ARCHIVE_ROOT):
                names.append(strip_archive_prefix(f["filename"]))
            else:
                names.append(f["filename"])
        return list(dict.fromkeys(names))

    def original_folders(self):
        out = []
        for f in self.rows:
            p = f["full_path"]
            if p.startswith(ARCHIVE_ROOT):
                continue
            parts = p.split("/")[1:-1]
            for part in parts:
                if part in ("Volumes", "Users", "rickb", "Movies") or part.startswith("Converted_VHS_Tapes_2026"):
                    continue
                out.append(part)
        return list(dict.fromkeys(out))

    def archive_relpath(self):
        for f in self.rows:
            if f["full_path"].startswith(ARCHIVE_ROOT):
                return f["full_path"][len(ARCHIVE_ROOT):]
        return ""

    def set(self, field, value, conf, source, evidence, state="inferred", **extra):
        d = {"value": value, "state": state, "conf": round(conf, 2), "source": source,
             "evidence": evidence if isinstance(evidence, list) else [evidence]}
        d.update(extra)
        self.fields[field] = d
        return d

    def get(self, field, key="value"):
        d = self.fields.get(field)
        return None if d is None else d.get(key)


def build_subjects(cat, july_root):
    """One subject per distinct content (SHA-256). kind = master | july | master+july.
    Byte-identical copies (staging folders, archive + source) are listed on the one row."""
    subjects = []
    by_digest = {}
    # (a) archive Masters: one subject per digest in archive_copies
    for digest in dict.fromkeys(ac["content_digest"] for ac in cat["archive_copies"]):
        rows = cat["by_digest"][digest]
        s = Subject("master", digest, pick_representative(rows), rows)
        subjects.append(s)
        by_digest[digest] = s
    # (b) July batch: every catalog row whose path contains the July marker (incl. trashed)
    july_rows = [f for f in cat["files"] if JULY_MARK in f["full_path"]]
    for f in july_rows:
        d = f["content_digest"]
        if d in by_digest:
            if by_digest[d].kind == "master":
                by_digest[d].kind = "master+july"
                by_digest[d].notes.append("archive Master byte-identical to a July capture file (same SHA-256)")
            continue
        rows = cat["by_digest"][d]
        rep = sorted(rows, key=lambda r: (r["removal_state"] is not None, not r["full_path"].startswith("/Volumes/MediaExpansion/")))[0]
        s = Subject("july", d, rep, rows)
        subjects.append(s)
        by_digest[d] = s
    # (b') files on disk under the July root that the backup does not know (read-only stat)
    known = {f["full_path"] for f in july_rows}
    if july_root and os.path.isdir(july_root):
        for dirpath, _dirs, files in os.walk(july_root):
            for name in files:
                if name.startswith("."):
                    continue
                p = os.path.join(dirpath, name)
                if p in known:
                    continue
                st = os.stat(p)
                rep = {"id": None, "content_digest": None, "full_path": p, "filename": name,
                       "ext": os.path.splitext(name)[1].lstrip("."), "directory": dirpath,
                       "size_bytes": st.st_size, "fs_created_at": int(getattr(st, "st_birthtime", st.st_mtime)),
                       "fs_modified_at": int(st.st_mtime), "stream_type": "", "duration_s": 0.0,
                       "container": "", "video_codec": "", "audio_codec": "", "embedded_created_at": None,
                       "embedded_created_source": None, "probe_extra": "{}", "extra": {}, "scanned_at": None,
                       "lifecycle": "(not in backup)", "archive_stage": "", "removal_state": None,
                       "removal_reason": None, "original_full_path": None}
                s = Subject("july", None, rep, [rep])
                s.notes.append("on disk but not in the backup catalog (stat only, not probed)")
                subjects.append(s)
    return subjects


# ----------------------------------------------------------------------------- inference
def classify(s):
    """Coarse class from codec/encoder/name: july_capture | app_derived | dv | born_digital |
    avid | reencode | other."""
    r = s.rep
    enc = (r["extra"].get("originEncoder") or "").strip()
    make = (r["extra"].get("originMake") or "").strip()
    model = (r["extra"].get("originModel") or "").strip()
    codec = r["video_codec"]
    res = r["extra"].get("resolution") or ""
    born = utc(r["fs_created_at"])
    _, deriv = stem_core(r["filename"])
    in_july_window = born is not None and dt.date(2026, 6, 28) <= born.date() <= dt.date(2026, 7, 31)
    sd_geometry = res in ("720x480", "704x480", "640x480", "352x240", "320x240", "696x470", "712x478")
    in_july_folder = any(july_folder_of(f["full_path"]) for f in s.rows)
    if codec == "ffv1" and enc == JULY_ENCODER and res == "1280x720":
        return "july_capture"
    if codec == "dvvideo" and not enc.startswith("Lavf"):
        return "dv"                      # a DV25 stream the app did not write (raw .dv, Apple/Avid QuickTime)
    if codec == "dvvideo" and enc.startswith("Avid"):
        return "avid"
    if deriv or enc.startswith("Lavf6") or (in_july_folder and codec in ("prores", "hevc", "h264", "ffv1")):
        return "app_derived"             # VideoScan/ffmpeg output, a derivative name, or a conversion inside a July tape folder
    if enc.startswith("Avid"):
        return "avid"
    if enc.startswith(("HandBrake", "vlc", "Encoded with cleaner", "Sorenson")) or codec in ("svq3", "mpeg4", "mpeg2video", "mjpeg"):
        return "reencode"
    if codec in ("h264", "hevc", "prores", "dnxhd"):
        emb_year = utc(r["embedded_created_at"]).year if r["embedded_created_at"] else None
        if sd_geometry and not model and (emb_year is None or emb_year < 2012):
            return "reencode"            # SD geometry from a Mac in the 2000s = a transfer of tape, not a camera file
        if make or model or r["embedded_created_at"]:
            return "born_digital"
    return "other"


def infer_subject(s, cat, ctx):
    r = s.rep
    extra = r["extra"]
    enc = (extra.get("originEncoder") or "").strip()
    make = (extra.get("originMake") or "").strip()
    model = (extra.get("originModel") or "").strip()
    codec = r["video_codec"]
    res = extra.get("resolution") or ""
    fps = extra.get("frameRate") or ""
    cls = classify(s)
    s.cls = cls
    core, deriv = stem_core(r["filename"])
    s.core = core
    s.cores = {stem_core(f["filename"])[0] for f in s.rows} | {core}
    names = s.original_names()
    folders = s.original_folders()
    born_local = local_date(r["fs_created_at"])
    emb = r["embedded_created_at"]
    emb_local = local_date(emb)

    # ---------- confirmed user data (never re-emitted as inferred)
    ud = cat["user_dates"].get(s.digest) if s.digest else None
    user_year = None
    if ud and ud.get("value"):
        user_year = int(ud["value"][:4])
    evs = cat["events_by_digest"].get(s.digest, []) if s.digest else []
    app_inf = cat["inferred_dates"].get(s.digest) if s.digest else None

    # ---------- tier A year evidence (independent of Rick's promote name)
    tierA = []   # (year, conf, source, evidence_text)
    year_label = None
    name_years = []
    for nm in names:
        base = split_name(nm)[0]
        ys = years_in(base)
        if ys:
            name_years.extend(ys)
            if len(ys) > 1 and ys[1] == ys[0] + 1:
                year_label = f"{ys[0]}–{str(ys[1])[2:]}"
        else:
            dm = DECADE_RE.search(base)
            if dm:
                tierA.append((int(dm.group(1)) + 5, 0.35, "name-decade", f"decade '{dm.group(0)}' in '{nm}' (range {dm.group(1)}–{int(dm.group(1)) + 9})"))
            if re.search(r"2000-something", base, re.I):
                tierA.append((2004, 0.25, "name-vague", f"'2000-something' in '{nm}' (range 2000–2009)"))
    if name_years:
        # Rick's rule: the tape year is the FIRST event's year → earliest year across all names
        first = min(name_years)
        others = sorted(set(name_years) - {first})
        tierA.insert(0, (first, 0.6, "name-year", f"year {first} in name(s) {names}" + (f"; other years in names: {others}" if others else "")))
        if others and others[0] == first + 1 and not year_label:
            year_label = f"{first}–{str(others[0])[2:]}"
    for fo in folders:
        ys = years_in(fo)
        if ys and fo != "30_Video":
            tierA.append((ys[0], 0.5, "folder-year", f"year {ys[0]} in folder '{fo}'"))
    jf = None
    for f in s.rows:
        jf = jf or july_folder_of(f["full_path"])
    if jf:
        ys = years_in(jf)
        if ys:
            tierA.append((ys[0], 0.55, "july-folder-year", f"year {ys[0]} in July tape folder '{jf}'"))

    # ---------- class-specific facts
    dv = ctx["dv_probes"].get(s.digest) if s.digest else None
    rdt_year = None
    if dv and dv.get("rec_start"):
        rdt_year = int(dv["rec_start"][:4])
    name_year_guess = tierA[0][0] if tierA else None

    # format / carrier
    if cls == "july_capture" or jf:
        s.set("carrier_format", "VHS", 0.85, "july-batch",
              [f"folder {JULY_MARK}{jf or '?'}", f"encoder {enc or JULY_ENCODER}, {res} {fps}p, {r['audio_codec']}", f"born {born_local} (July 2026 capture window)"])
    elif cls == "dv" or (cls == "avid" and codec == "dvvideo"):
        y = user_year or rdt_year if (user_year or (rdt_year and (not name_year_guess or abs(rdt_year - name_year_guess) <= 1))) else name_year_guess
        if y is not None and y < 1995:
            s.set("carrier_format", "analog tape (VHS/Video8?) → DV dub", 0.5, "dv-era-rule",
                  [f"DV25 NTSC stream but content year ≈{y} predates MiniDV (1995)", "the DV file is a dub/transfer, original carrier unknown"])
            if y < 1983:
                s.set("carrier_format", "8mm film → DV transfer", 0.5, "dv-era-rule",
                      [f"content year ≈{y} predates consumer video", "DV25 NTSC stream = a telecine/transfer dub"])
        else:
            s.set("carrier_format", "MiniDV", 0.65, "codec",
                  [f"DV25 NTSC ({codec}, {res}, {fps})", "consumer DV25 could also be Digital8; MiniDV is the family default"])
    elif cls == "born_digital":
        s.set("carrier_format", "none (born digital)", 0.8, "codec+device",
              [f"{codec} {res}", f"make/model: {make or '?'} {model}".strip(), f"creation_time {emb_local or '?'}"])
    elif cls == "app_derived":
        s.set("carrier_format", "(inherits parent)", 0.5, "derived", [f"derivative markers {deriv or ['encoder ' + enc]}"])
    elif cls == "reencode":
        s.set("carrier_format", "unknown (re-encode)", 0.3, "encoder", [f"encoder '{enc}', codec {codec}"])
    else:
        s.set("carrier_format", "unknown", 0.2, "none", ["no carrier signature"])

    # role / generation
    if cls == "july_capture":
        s.set("role", "Preservation", 0.6, "july-capture", ["FFV1 capture master of the July batch (longest file in its folder decides; see tape)"])
        if TEST_NAME_RE.search(r["filename"]) and (r["duration_s"] or 0) < 300:
            s.set("role", "Work tapes (Test)", 0.6, "name+duration", [f"test-style name '{r['filename']}'", f"{round(r['duration_s'] or 0)} s"])
        elif TEST_NAME_RE.search(r["filename"]):
            s.notes.append("test-style name but long duration → treated as a real capture (deep dive: longest decides)")
    elif cls == "app_derived":
        if "access" in deriv or (codec == "hevc" and enc.startswith("Lavf63")):
            s.set("role", "Copy: Access", 0.8, "derivative", [f"HEVC access copy ({enc}), markers {deriv}"])
        elif "preserve" in deriv or codec == "ffv1":
            s.set("role", "Preservation", 0.6, "derivative", [f"FFV1 encode by ffmpeg {enc or '?'} ({res}), markers {deriv or '—'}", "derived — a conversion, so it inherits the carrier from its parent"])
        elif "edit" in deriv or codec == "prores":
            s.set("role", "Master: production", 0.7, "derivative", [f"ProRes edit master ({enc}), markers {deriv}"])
        elif "restore" in deriv:
            s.set("role", "Master: production", 0.6, "derivative", [f"restoration/repair output, markers {deriv}"])
        elif "recovered" in deriv:
            s.set("role", "unknown (recovered file)", 0.3, "derivative", ["recovered from damaged media; role unknown"])
        else:
            s.set("role", "Copy: Access", 0.4, "derivative", [f"markers {deriv}, encoder {enc}"])
    elif cls == "dv":
        y = user_year or name_year_guess
        if y is not None and y < 1995:
            s.set("role", "Dub", 0.6, "dv-era-rule", [f"DV carries ≈{y} content → DV tape is a dub of an analog original"])
        elif EDIT_WORDS_RE.search(core):
            s.set("role", "Master: production", 0.55, "name", [f"edit words in '{r['filename']}'"])
        else:
            s.set("role", "Original", 0.6, "dv", ["camcorder DV25 stream, no edit markers"])
    elif cls == "avid":
        if EDIT_WORDS_RE.search(core):
            s.set("role", "Master: production", 0.65, "avid+name", [f"Avid export ({enc}), edit words in name"])
        else:
            s.set("role", "Dub", 0.45, "avid", [f"Avid export ({enc}) of captured footage"])
    elif cls == "born_digital":
        s.set("role", "Original", 0.85, "device", [f"camera original ({make} {model})".replace("( ", "(").replace(" )", ")") if make else "camera original (creation_time present)"])
    elif cls == "reencode":
        s.set("role", "Copy: Access", 0.6, "encoder", [f"re-encode by '{enc}' ({codec})"])
    else:
        s.set("role", "unknown", 0.2, "none", [])

    # event date (value, range, conf, source) — confirmed first
    if ud and (ud.get("value") or ud.get("conflict")):
        if ud.get("value"):
            s.set("event_date", ud["value"], 1.0 if ud.get("confidence") == "known" else 0.8, "user_dates",
                  [f"Rick: {ud['value']} ({ud.get('confidence') or 'no confidence'}){', set ' + local_date(ud['set_at']) if ud.get('set_at') else ''}"],
                  state="confirmed")
        else:
            s.set("event_date", "(conflict)", 0.0, "user_dates", ["user_dates row has conflict=1 and no value"], state="confirmed")
    # the machine's own guess is always computed (for the self-check and as the inferred draft)
    guess = None
    if cls == "born_digital" and emb is not None:
        ey = utc(emb).year
        if name_year_guess is None or abs(name_year_guess - ey) <= 1:
            guess = (local_date(emb), 0.85 if (make or model) else 0.7, "device-clock", f"creation_time {emb_local} ({make} {model})".strip(), ey)
        else:
            guess = (str(name_year_guess), 0.55, "name-year", f"name says {name_year_guess}; creation_time {emb_local} is the encode date", name_year_guess)
    if guess is None and rdt_year is not None:
        if name_year_guess is None or abs(rdt_year - name_year_guess) <= 1:
            rng = f"{dv['rec_start'][:10]}..{dv['rec_end'][:10]}" if dv["rec_end"] else dv["rec_start"][:10]
            guess = (dv["rec_start"][:10], 0.8, "dv-rdt", f"DV REC DATE {rng} ({len(dv['dates'])} day(s) sampled)", rdt_year)
        else:
            s.notes.append(f"DV REC DATE {dv['rec_start'][:10]} ≠ name year {name_year_guess}: tape clock marks the DUB, not the event")
    if guess is None and cls == "dv" and emb is not None and name_year_guess is not None and abs(utc(emb).year - name_year_guess) <= 1:
        guess = (local_date(emb), 0.7, "capture-clock", f"QuickTime creation_time {emb_local} within a year of name year {name_year_guess}", utc(emb).year)
    if guess is None and tierA:
        best = sorted(tierA, key=lambda t: -t[1])[0]
        guess = (str(best[0]), best[1], best[2], best[3], best[0])
    if guess is None and cls in ("dv", "avid", "other") and emb is not None and name_year_guess is None:
        guess = (local_date(emb), 0.4, "creation_time", f"creation_time {emb_local} (may be the transfer, not the event)", utc(emb).year)
    # a re-encode's creation_time is the encode date, never the event: no guess from it
    tierB = None
    rel = s.archive_relpath()
    if rel:
        m = re.match(r"^\d{4}-\d{4}/(\d{4})/", rel)
        pm = re.match(r"^(\d{4})-(\d\d|xx)-(\d\d|xx)_", rel.split("/")[-1])
        if pm:
            val = pm.group(1) + ("" if pm.group(2) == "xx" else "-" + pm.group(2) + ("" if pm.group(3) == "xx" else "-" + pm.group(3)))
            tierB = (val, 0.6, "archive-name (Rick at Promote)", f"archive name prefix '{pm.group(0)}'", int(pm.group(1)))
        elif m:
            tierB = (m.group(1), 0.5, "archive-folder (Rick at Promote)", f"archive folder {m.group(0)}", int(m.group(1)))
    s.machine_year = guess[4] if guess else None
    s.machine_guess = guess
    if "event_date" not in s.fields:
        if guess:
            s.set("event_date", guess[0], guess[1], guess[2], [guess[3]])
        elif tierB:
            s.set("event_date", tierB[0], tierB[1], tierB[2], [tierB[3]], derived_from_user=True)
        else:
            s.set("event_date", None, 0.0, "none", ["no date evidence"])
    else:
        s.fields["event_date"]["machine_guess"] = guess[0] if guess else None
        s.fields["event_date"]["machine_source"] = guess[2] if guess else None
    if year_label:
        s.fields["event_date"]["year_label"] = year_label
    if app_inf and app_inf.get("date_at"):
        s.fields["event_date"]["evidence"].append(f"app inferred_dates: {local_date(app_inf['date_at'])} ({app_inf.get('source') or 'auto'}, {app_inf.get('confidence')})")
    for e in evs:
        s.fields["event_date"]["evidence"].append(f"user event: {e}")

    # digitized_on (dateType digitized)
    if cls == "july_capture":
        s.set("digitized_on", born_local, 0.9, "file-birth", [f"FFV1 born {local_dt(r['fs_created_at'])} local; July capture window", "Montana clock-named files prove birth = capture start"])
        cm = CLOCK_NAME_RE.match(r["filename"])
        if cm:
            s.fields["digitized_on"]["evidence"].append(f"capture clock in name {cm.group(0)}")
    elif cls == "dv" or (cls == "avid" and codec == "dvvideo"):
        if rdt_year is not None and name_year_guess is not None and abs(rdt_year - name_year_guess) > 1:
            s.set("digitized_on", dv["rec_start"][:10], 0.7, "dv-rdt-as-dub", [f"DV REC DATE {dv['rec_start']} marks the dub to DV tape (content ≈{name_year_guess})"])
        elif emb is not None:
            s.set("digitized_on", local_date(emb), 0.65, "creation_time", [f"QuickTime creation_time {emb_local} = Apple DV capture/import"])
        else:
            oldest = min((f["fs_created_at"] for f in s.rows if f["fs_created_at"]), default=None)
            s.set("digitized_on", local_date(oldest), 0.45, "oldest-birth", [f"oldest copy born {local_dt(oldest)}"] if oldest else ["no birth time"])
        if dv and dv.get("stripped"):
            s.fields["digitized_on"]["evidence"].append("DV REC DATE packs are 0xFF (stripped by the export path)")
    elif cls == "born_digital":
        s.set("digitized_on", "n/a (born digital)", 0.8, "codec+device", ["no carrier; created = digitized"])
    elif cls == "app_derived":
        s.set("digitized_on", "(inherits parent)", 0.5, "derived", [f"this file was made {born_local}; the capture date belongs to its parent"])
    elif cls in ("avid", "reencode"):
        s.set("digitized_on", local_date(emb) if emb else None, 0.4 if emb else 0.0, "creation_time", [f"creation_time {emb_local} = encode/export date (capture date unknown)"] if emb else ["no creation_time"])
    else:
        s.set("digitized_on", None, 0.0, "none", [])

    # cataloged_on (dateType ingested) = first seen
    scans = [f["scanned_at"] for f in s.rows if f.get("scanned_at")]
    fs = cat["first_seen"].get(s.digest) if s.digest else None
    cands = []
    if scans:
        cands.append((min(scans), "min(files.scanned_at)"))
    if fs and fs[0]:
        cands.append((fs[0], f"content.first_seen_at ({fs[1]})"))
    if s.digest in cat["ledger_first"]:
        cands.append((cat["ledger_first"][s.digest], "ledger first 'cataloged' line"))
    if cands:
        best = min(cands)
        s.set("cataloged_on", local_date(best[0]), 0.9, best[1], [f"{src}: {local_date(ts)}" for ts, src in cands] + (["ledger has no 'cataloged' kind in this backup"] if not cat["ledger_first"] else []))
    else:
        s.set("cataloged_on", None, 0.0, "none", ["not in the backup catalog"])

    # capture setup
    if cls == "july_capture" or jf:
        s.set("capture_setup", "July 2026 VHS setup: VHS deck → capture device (scaled + deinterlaced to 1280×720p30, bt709) → ffmpeg Lavf61.7.100 FFV1 + pcm_s32le/MKV",
              0.85, "encoder+geometry", [f"encoder {enc}", f"{res} {fps} fps {extra.get('colorSpace')}", f"audio {r['audio_codec']}", "deck / scaler / capture card names: Rick, once for the batch"])
    elif cls == "dv":
        if r["container"].startswith("DV") or r["ext"].lower() == "dv":
            s.set("capture_setup", "DV camcorder/deck → FireWire → Mac (iMovie DV capture, raw .dv)", 0.6, "container+folder", [f"raw DV stream in '{folders[-1] if folders else '?'}'"])
        else:
            s.set("capture_setup", "DV camcorder/deck → FireWire → Mac, QuickTime DV capture (iMovie/FCP)", 0.6, "encoder", [f"QuickTime DV, encoder '{enc or '—'}', make {make or '—'}"])
    elif cls == "avid":
        s.set("capture_setup", "Avid (DV25/DNxHD export) on the Mac Pro", 0.65, "encoder", [f"encoder '{enc}'"])
    elif cls == "born_digital":
        s.set("capture_setup", f"camera: {make} {model}".strip() if (make or model) else "camera unknown (born digital)", 0.7 if (make or model) else 0.4, "device", [f"creation_time {emb_local}", f"{codec} {res}"])
    elif cls == "app_derived":
        s.set("capture_setup", f"VideoScan app / ffmpeg {enc} (derived; setup is the parent's)", 0.7, "encoder", [f"encoder {enc}", f"made {born_local}"])
    elif cls == "reencode":
        s.set("capture_setup", f"re-encode: {enc or codec}", 0.5, "encoder", [f"encoder '{enc}', creation_time {emb_local}"])
    else:
        s.set("capture_setup", None, 0.0, "none", [])

    # DV probe facts straight onto the subject
    if dv:
        s.dv = dv
    s.user_date = ud
    s.user_events = evs
    s.app_inferred = app_inf


def assign_tapes(subjects, ctx):
    """Group key = proposed carrier. Order of rules: July folder (byte copy) › name stem › size+duration › class."""
    july_by_core = {}
    july_by_sizedur = {}
    for s in subjects:
        for f in s.rows:
            jf = july_folder_of(f["full_path"])
            if jf:
                july_by_core.setdefault(stem_core(f["filename"])[0], jf)
                july_by_sizedur.setdefault((f["size_bytes"], round(f["duration_s"] or 0)), jf)
                july_by_sizedur.setdefault(("dur", round(f["duration_s"] or 0)), jf)
    for s in subjects:
        r = s.rep
        jf = None
        for f in s.rows:
            jf = jf or july_folder_of(f["full_path"])
        if jf:
            s.tape_key = f"vhs2026:{jf}"
            s.set("carrier", jf, 0.9, "july-folder", [f"byte-identical copy under {JULY_MARK}{jf}/"])
            continue
        core = s.core
        hit_core = next((c for c in sorted(s.cores) if c in july_by_core), None)
        if hit_core:
            jf = july_by_core[hit_core]
            s.tape_key = f"vhs2026:{jf}"
            s.set("carrier", jf, 0.7, "name-stem", [f"stem '{hit_core}' matches a July capture in folder {jf}"])
            continue
        key = ("dur", round(r["duration_s"] or 0))
        if s.cls in ("app_derived", "july_capture") and (r["extra"].get("resolution") == "1280x720") and key in july_by_sizedur and round(r["duration_s"] or 0) > 60:
            jf = july_by_sizedur[key]
            s.tape_key = f"vhs2026:{jf}"
            s.set("carrier", jf, 0.55, "duration-match", [f"1280×720 derivative with the same duration ({key[1]} s) as a July capture in {jf}"])
            continue
        if s.cls == "july_capture":
            s.tape_key = f"vhs2026:?{core}"
            s.set("carrier", f"? {core}", 0.5, "july-signature", ["July encoder/geometry/birth window but no folder copy; tape named from the file"])
            continue
        if s.cls == "born_digital":
            y = s.machine_year or "?"
            s.tape_key = f"born-digital:{y}"
            s.set("carrier", "none (born digital)", 0.8, "codec+device", [])
            continue
        if s.cls in ("dv", "avid") or (s.cls == "app_derived" and r["extra"].get("resolution") in ("720x480", "704x480")):
            # DV family: group by source project folder, else by stem
            proj = None
            for f in s.rows:
                for part in f["full_path"].split("/"):
                    if part.endswith((".iMovieProject", ".imovielibrary", ".fcpbundle")):
                        proj = part
            if proj:
                s.tape_key = f"dv:{proj}"
                s.set("carrier", f"DV tape — {proj}", 0.5, "project-folder", [f"source project '{proj}'"])
            else:
                s.tape_key = f"dv:{core}"
                s.set("carrier", f"DV tape — {core}", 0.4, "name-stem", [f"stem '{core}'"])
            continue
        s.tape_key = f"other:{core}"
        s.set("carrier", f"? {core}", 0.2, "name-stem", [f"stem '{core}' (no carrier signature)"])
    # derived files inherit the parent's carrier when a sibling sharing any name-core sits in a better group
    by_core = collections.defaultdict(list)
    for s in subjects:
        for c in s.cores:
            by_core[c].append(s)
    for core, members in by_core.items():
        if len(members) < 2:
            continue
        best = sorted(members, key=lambda m: -(m.fields["carrier"]["conf"] if "carrier" in m.fields else 0))[0]
        for m in members:
            if m is best:
                continue
            if (m.fields["carrier"]["conf"] if "carrier" in m.fields else 0) < best.fields["carrier"]["conf"]:
                m.tape_key = best.tape_key
                m.set("carrier", best.fields["carrier"]["value"], round(best.fields["carrier"]["conf"] - 0.1, 2), "inherited",
                      [f"inherited from '{best.rep['filename']}' (shared stem '{core}')"] + best.fields["carrier"]["evidence"])
    # DV groups: merge by recording date when two project-less groups share a REC DATE
    by_date = collections.defaultdict(list)
    for s in subjects:
        dv = getattr(s, "dv", None)
        if s.tape_key and s.tape_key.startswith("dv:") and dv and dv.get("rec_start"):
            by_date[dv["rec_start"][:10]].append(s)
    for d, members in by_date.items():
        keys = {m.tape_key for m in members}
        if len(keys) > 1:
            target = sorted(keys)[0]
            for m in members:
                m.tape_key = target
                m.fields["carrier"]["evidence"].append(f"merged: same DV REC DATE {d}")
    # an SD group with no DV stream in it is a transfer of unknown carrier, not a DV tape
    groups = collections.defaultdict(list)
    for s in subjects:
        groups[s.tape_key].append(s)
    for key, members in groups.items():
        if key.startswith("dv:") and not any(m.rep["video_codec"] == "dvvideo" for m in members):
            for m in members:
                m.tape_key = "sd:" + key[3:]
                m.fields["carrier"]["value"] = "SD transfer, carrier unknown — " + key[3:]
                m.fields["carrier"]["evidence"].append("no DV stream among the copies: the tape is unknown")
    # July folders: one folder may hold several tapes — each long FFV1 capture with a distinct
    # duration is a 'take'; derived files attach to the take whose duration they share
    for key, members in groups.items():
        if not key.startswith("vhs2026:"):
            continue
        caps = sorted([m for m in members if m.cls == "july_capture" and (m.rep["duration_s"] or 0) >= 300],
                      key=lambda m: m.rep["fs_created_at"] or 0)
        takes = []
        for m in caps:
            d = round(m.rep["duration_s"] or 0)
            for t in takes:
                if abs(t["duration"] - d) <= 2:
                    t["members"].append(m)
                    t["cores"] |= m.cores
                    break
            else:
                takes.append({"n": len(takes) + 1, "duration": d, "stem": m.core, "members": [m], "cores": set(m.cores), "born": local_date(m.rep["fs_created_at"])})

        def match_take(m):
            d = round(m.rep["duration_s"] or 0)
            hit = next((t for t in takes if abs(t["duration"] - d) <= 2), None)
            if hit is None:  # an edit/trim: shares a name-core with the take and is not longer than it
                hit = next((t for t in takes if (m.cores & t["cores"]) and d <= t["duration"] + 2), None)
            return hit

        # long content with no kept FFV1 capture (only derived/converted copies) is its own take
        for m in sorted(members, key=lambda m: m.rep["fs_created_at"] or 0):
            d = round(m.rep["duration_s"] or 0)
            if m.cls != "july_capture" and d >= 300 and match_take(m) is None:
                takes.append({"n": len(takes) + 1, "duration": d, "stem": m.core + " (no FFV1 capture kept)", "members": [m], "cores": set(m.cores), "born": local_date(m.rep["fs_created_at"])})
                m.notes.append("no FFV1 capture of this content in the folder — the capture master was not kept, or lives elsewhere")
        for m in members:
            hit = match_take(m)
            if hit is None and takes and m.cls != "july_capture":
                hit = max(takes, key=lambda t: t["duration"])
                m.notes.append("short file matching no take; attached to the longest capture")
            m.take = hit["n"] if hit else None
        for m in members:
            m.folder_takes = takes


def tape_headers(subjects):
    groups = collections.OrderedDict()
    for s in sorted(subjects, key=lambda x: (x.tape_key or "", x.rep["full_path"])):
        groups.setdefault(s.tape_key, []).append(s)
    headers = {}
    for key, members in groups.items():
        # year = FIRST event's year: confirmed first, else min machine year
        conf_years = sorted({int(m.user_date["value"][:4]) for m in members if m.user_date and m.user_date.get("value")})
        mach_years = sorted({m.machine_year for m in members if m.machine_year})
        if conf_years:
            year, ystate, yconf = conf_years[0], "confirmed", 1.0
            ysrc = "min confirmed year among members"
        elif mach_years:
            year, ystate, yconf = mach_years[0], "inferred", max(m.fields["event_date"]["conf"] for m in members if m.machine_year)
            ysrc = "min machine-inferred year among members"
        else:
            tb = [m.fields["event_date"] for m in members if m.fields["event_date"].get("derived_from_user")]
            if tb:
                year, ystate, yconf, ysrc = int(tb[0]["value"][:4]), "inferred", 0.5, "archive name (Rick at Promote) — tier B"
            else:
                year, ystate, yconf, ysrc = None, "inferred", 0.0, "none"
        allyears = sorted(set(conf_years) | set(mach_years))
        label = str(year) if year else "?"
        if year and any(y == year + 1 for y in allyears):
            label = f"{year}–{str(year + 1)[2:]}"
        for m in members:
            yl = m.fields["event_date"].get("year_label")
            if yl and yl.startswith(str(year)):
                label = yl
        fmt = collections.Counter(m.fields["carrier_format"]["value"] for m in members if m.fields["carrier_format"]["value"] not in ("(inherits parent)",))
        fmt_v = fmt.most_common(1)[0][0] if fmt else "unknown"
        fmt_c = max((m.fields["carrier_format"]["conf"] for m in members if m.fields["carrier_format"]["value"] == fmt_v), default=0)
        if fmt_v.startswith("unknown") and key.startswith("dv:"):
            fmt_v, fmt_c = "DV family (derived copies only; parent DV stream not in scope)", 0.35
        if fmt_v.startswith("unknown") and key.startswith("sd:"):
            fmt_v, fmt_c = "SD transfer of an unknown tape", 0.3
        setups = collections.Counter(m.fields["capture_setup"]["value"] for m in members if m.fields["capture_setup"]["value"] and not m.fields["capture_setup"]["value"].startswith("VideoScan app"))
        setup = setups.most_common(1)[0][0] if setups else "(derived files only — see parent tape)"
        gen = "Original" if key.startswith("vhs2026:") else ("Dub" if fmt_v.endswith("DV dub") or fmt_v.endswith("DV transfer") else ("n/a" if key.startswith("born-digital") else "Original"))
        # which July file is the capture master: per take, the FFV1 capture (longest if several)
        master = None
        masters_by_take = []
        if key.startswith("vhs2026:"):
            caps = [m for m in members if m.cls == "july_capture"]
            takes_here = getattr(members[0], "folder_takes", []) if members else []
            for t in takes_here:
                tcaps = [m for m in caps if getattr(m, "take", None) == t["n"]]
                if not tcaps:
                    continue
                tm = max(tcaps, key=lambda m: m.rep["duration_s"] or 0)
                masters_by_take.append(f"take {t['n']}: {tm.rep['filename']}")
                for m in tcaps:
                    if m is tm:
                        m.fields["role"]["evidence"].append(f"FFV1 capture of take {t['n']} → its capture master")
                        m.fields["role"]["conf"] = max(m.fields["role"]["conf"], 0.75)
                    elif m.fields["role"]["value"] == "Preservation":
                        m.set("role", "Preservation (retake)", 0.5, "july-capture", [f"second capture of take {t['n']} with the same duration"])
            for m in caps:
                if getattr(m, "take", None) is None and m.fields["role"]["value"] == "Preservation":
                    m.set("role", "Work tapes (Test)", 0.55, "july-capture", [f"short capture ({round(m.rep['duration_s'] or 0)} s) matching no take"])
            if masters_by_take:
                master = type("M", (), {"rep": {"filename": "; ".join(masters_by_take)}})()
        # members with no event-date evidence borrow the tape's year from their siblings:
        # machine years propagate as inferred; a confirmed sibling year is flagged tier B (Rick's)
        sib_machine = sorted({m.machine_year for m in members if m.machine_year})
        for m in members:
            ed = m.fields["event_date"]
            if ed["state"] == "confirmed" or (ed["value"] and not ed.get("derived_from_user")):
                continue
            if sib_machine:
                m.set("event_date", str(sib_machine[0]), 0.45, "tape-siblings", [f"no own evidence; earliest machine year among files on this tape = {sib_machine[0]} ({', '.join(str(y) for y in sib_machine)})"])
            elif conf_years and not ed["value"]:
                m.set("event_date", str(conf_years[0]), 0.5, "tape-sibling confirmed date (Rick)", [f"no own evidence; a sibling on this tape is confirmed {conf_years[0]}"], derived_from_user=True)
        digitized = sorted({m.fields["digitized_on"]["value"] for m in members if m.fields["digitized_on"]["value"] and re.match(r"^\d{4}-\d\d-\d\d$", m.fields["digitized_on"]["value"] or "")})
        takes = getattr(members[0], "folder_takes", []) if key.startswith("vhs2026:") else []
        headers[key] = {"key": key, "label": key.split(":", 1)[1], "year": year, "year_label": label, "year_state": ystate,
                        "year_conf": round(yconf, 2), "year_source": ysrc, "format": fmt_v, "format_conf": fmt_c,
                        "generation": gen, "setup": setup, "n": len(members), "digitized": digitized,
                        "master": master.rep["filename"] if master else None, "members": members,
                        "takes": [{k: v for k, v in t.items() if k not in ("members", "cores")} for t in takes],
                        "videographer": "— (Rick, once per tape)", "shelf": "— (Rick assigns)"}
    return headers


# ----------------------------------------------------------------------------- outputs
CSV_COLS = ["subject_kind", "tape_key", "tape_label", "tape_year", "tape_year_label", "tape_year_state", "tape_format",
            "tape_generation", "tape_setup", "digest", "path", "archive_relpath", "lifecycle", "archive_stage", "removal_state",
            "copies_in_catalog", "class", "codec", "container", "resolution", "fps", "duration_s", "size_bytes", "encoder",
            "carrier", "carrier_conf", "carrier_source", "take",
            "carrier_format", "carrier_format_conf", "role", "role_conf", "role_source",
            "event_date", "event_date_state", "event_date_conf", "event_date_source", "event_date_derived_from_user",
            "machine_event_guess", "machine_event_source", "confirmed_user_date", "confirmed_user_confidence",
            "digitized_on", "digitized_conf", "digitized_source", "cataloged_on", "cataloged_source",
            "dv_rec_start", "dv_rec_end", "dv_rec_dates", "dv_probe_note",
            "app_inferred_date", "app_inferred_source", "user_events", "evidence", "notes"]


def subject_row(s, hdr):
    r = s.rep
    f = s.fields
    dv = getattr(s, "dv", None)
    ev = []
    for name in ("carrier", "carrier_format", "role", "event_date", "digitized_on", "cataloged_on", "capture_setup"):
        d = f.get(name)
        if d:
            ev.append(f"{name}[{d['state']} {d['conf']}] " + " · ".join(d["evidence"]))
    ud = s.user_date or {}
    return {
        "subject_kind": s.kind, "tape_key": s.tape_key, "tape_label": hdr["label"], "tape_year": hdr["year"],
        "tape_year_label": hdr["year_label"], "tape_year_state": hdr["year_state"], "tape_format": hdr["format"],
        "tape_generation": hdr["generation"], "tape_setup": hdr["setup"],
        "digest": s.digest or "", "path": r["full_path"], "archive_relpath": s.archive_relpath(),
        "lifecycle": r["lifecycle"], "archive_stage": r["archive_stage"], "removal_state": r["removal_state"] or "",
        "copies_in_catalog": len(s.rows), "class": s.cls, "codec": r["video_codec"], "container": r["container"],
        "resolution": r["extra"].get("resolution", ""), "fps": r["extra"].get("frameRate", ""),
        "duration_s": round(r["duration_s"] or 0, 1), "size_bytes": r["size_bytes"], "encoder": r["extra"].get("originEncoder", ""),
        "carrier": f["carrier"]["value"], "carrier_conf": f["carrier"]["conf"], "carrier_source": f["carrier"]["source"],
        "take": getattr(s, "take", None) or "",
        "carrier_format": f["carrier_format"]["value"], "carrier_format_conf": f["carrier_format"]["conf"],
        "role": f["role"]["value"], "role_conf": f["role"]["conf"], "role_source": f["role"]["source"],
        "event_date": f["event_date"]["value"] or "", "event_date_state": f["event_date"]["state"],
        "event_date_conf": f["event_date"]["conf"], "event_date_source": f["event_date"]["source"],
        "event_date_derived_from_user": "yes" if f["event_date"].get("derived_from_user") else "",
        "machine_event_guess": s.machine_guess[0] if s.machine_guess else "", "machine_event_source": s.machine_guess[2] if s.machine_guess else "",
        "confirmed_user_date": ud.get("value") or "", "confirmed_user_confidence": ud.get("confidence") or "",
        "digitized_on": f["digitized_on"]["value"] or "", "digitized_conf": f["digitized_on"]["conf"], "digitized_source": f["digitized_on"]["source"],
        "cataloged_on": f["cataloged_on"]["value"] or "", "cataloged_source": f["cataloged_on"]["source"],
        "dv_rec_start": dv["rec_start"] if dv else "", "dv_rec_end": dv["rec_end"] if dv else "",
        "dv_rec_dates": " ".join(dv["dates"]) if dv else "",
        "dv_probe_note": (dv["error"] or ("REC DATE stripped (0xFF)" if dv["stripped"] else f"{len(dv['samples'])} frames sampled in {dv['seconds']} s")) if dv else "",
        "app_inferred_date": local_date(s.app_inferred["date_at"]) if s.app_inferred and s.app_inferred.get("date_at") else "",
        "app_inferred_source": (s.app_inferred or {}).get("source") or "",
        "user_events": "; ".join(s.user_events), "evidence": " | ".join(ev), "notes": "; ".join(s.notes),
    }


def self_check(subjects, cat):
    """Machine tier-A year vs Rick's user_dates year — over in-scope subjects and over every
    user_dates digest in the backup (one representative file row each)."""
    def compare(pairs):
        n = len(pairs)
        exact = sum(1 for g, c in pairs if g == c)
        within1 = sum(1 for g, c in pairs if abs(g - c) <= 1)
        return {"n": n, "exact": exact, "within1": within1, "exact_pct": pct(exact, n), "within1_pct": pct(within1, n)}
    in_scope = []
    seen = set()
    misses = []
    for s in subjects:
        if not s.user_date or not s.user_date.get("value") or s.digest in seen:
            continue
        seen.add(s.digest)
        c = int(s.user_date["value"][:4])
        if s.machine_year:
            in_scope.append((s.machine_year, c))
            if s.machine_year != c:
                misses.append((s.rep["filename"], s.machine_year, c, s.machine_guess[2] if s.machine_guess else ""))
        else:
            misses.append((s.rep["filename"], None, c, "no tier-A evidence"))
    covered = len(in_scope)
    total_conf = len(seen)
    # whole-backup check
    all_pairs = []
    no_guess = 0
    for digest, ud in cat["user_dates"].items():
        if not ud.get("value") or digest not in cat["by_digest"]:
            continue
        rows = cat["by_digest"][digest]
        s = Subject("check", digest, pick_representative(rows), rows)
        infer_subject(s, cat, {"dv_probes": {}})
        c = int(ud["value"][:4])
        if s.machine_year:
            all_pairs.append((s.machine_year, c))
        else:
            no_guess += 1
    return {"in_scope": compare(in_scope), "in_scope_confirmed": total_conf, "in_scope_covered": covered,
            "all": compare(all_pairs), "all_confirmed": len([u for u in cat["user_dates"].values() if u.get("value")]),
            "all_no_guess": no_guess, "misses": misses}


def write_csv(path, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=CSV_COLS)
        w.writeheader()
        for r in rows:
            w.writerow(r)


def esc(x):
    return html.escape("" if x is None else str(x))


def fv(d, show_conf=True):
    """Render a field: inferred = lighter italic, confirmed = solid."""
    if d is None:
        return "<span class=inf>—</span>"
    v = d["value"] if d["value"] not in (None, "") else "—"
    cls = "conf" if d["state"] == "confirmed" else "inf"
    tip = esc(" · ".join(d["evidence"]))
    c = f" <small class=c>{d['conf']}</small>" if show_conf else ""
    du = " <small class=tb title='derived from Rick\\'s Promote-time archive name'>tier B</small>" if d.get("derived_from_user") else ""
    return f"<span class='{cls}' title=\"{tip}\">{esc(v)}</span>{c}{du}"


def write_html(path, headers, subjects, summary, check, thumbs, meta):
    css = """
    :root{--bg:#fff;--fg:#1b1b1b;--mut:#6b6b6b;--line:#ddd;--card:#f6f6f6;--acc:#2a6fdb;--warn:#b35c00;--ok:#2d7d46}
    @media(prefers-color-scheme:dark){:root{--bg:#121416;--fg:#e6e6e6;--mut:#9a9a9a;--line:#2d3136;--card:#1b1f24;--acc:#6ea8ff;--warn:#f0a050;--ok:#6fcf8a}}
    body{background:var(--bg);color:var(--fg);font:14px/1.45 -apple-system,system-ui,sans-serif;margin:0;padding:16px;max-width:1500px}
    h1{font-size:22px;margin:0 0 4px}h2{font-size:17px;margin:28px 0 6px;border-top:1px solid var(--line);padding-top:14px}
    .sum{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:10px;margin:12px 0}
    .tile{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:10px}
    .tile b{display:block;font-size:22px}.tile span{color:var(--mut);font-size:12px}
    .hdr{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:10px 12px;margin:8px 0;display:flex;gap:16px;flex-wrap:wrap;align-items:flex-start}
    .hdr .f{min-width:150px}.hdr .k{color:var(--mut);font-size:11px;text-transform:uppercase;letter-spacing:.04em}
    .inf{color:var(--mut);font-style:italic;border-bottom:1px dotted var(--mut)}.conf{font-weight:600}
    small.c{color:var(--mut);font-size:10px}small.tb{color:var(--warn);font-size:10px}
    table{border-collapse:collapse;width:100%;font-size:13px}th,td{border-bottom:1px solid var(--line);padding:5px 6px;text-align:left;vertical-align:top}
    th{color:var(--mut);font-weight:500;font-size:11px;text-transform:uppercase;letter-spacing:.04em}
    td.p{font-family:ui-monospace,Menlo,monospace;font-size:11.5px;word-break:break-all;max-width:360px}
    details{margin:2px 0}summary{cursor:pointer;color:var(--acc);font-size:12px}ul.ev{margin:4px 0 6px 14px;padding:0;color:var(--mut);font-size:12px}
    .thumbs img{height:90px;border-radius:4px;margin-right:4px;border:1px solid var(--line)}
    .tag{display:inline-block;border:1px solid var(--line);border-radius:10px;padding:0 7px;font-size:11px;color:var(--mut);margin-right:4px}
    .warn{color:var(--warn)}.ok{color:var(--ok)}.weak td{background:rgba(240,160,80,.08)}
    .toc{columns:3;font-size:12px;margin:8px 0 0}.toc a{color:var(--acc);text-decoration:none}
    """
    out = [f"<!doctype html><html lang=en><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>"
           f"<title>Provenance drafts</title><style>{css}</style><body>"]
    out.append(f"<h1>Provenance Phase 0 — machine drafts for review</h1>"
               f"<div style='color:var(--mut)'>{esc(meta['when'])} · backup {esc(os.path.basename(meta['db']))} · "
               f"read-only · <i class=inf>inferred values</i> are lighter italic, <b class=conf>confirmed</b> solid; hover a value for its evidence</div>")
    out.append("<div class=sum>")
    for k, v, sub in summary["tiles"]:
        out.append(f"<div class=tile><b>{esc(v)}</b>{esc(k)}<br><span>{esc(sub)}</span></div>")
    out.append("</div>")
    # accuracy
    ins, al = check["in_scope"], check["all"]
    out.append("<h2>Accuracy self-check (machine tier-A year vs Rick's confirmed year)</h2>"
               f"<p>In scope (Masters + July): <b>{ins['exact_pct']}%</b> exact ({ins['exact']}/{ins['n']}), "
               f"<b>{ins['within1_pct']}%</b> within ±1 year; {check['in_scope_covered']} of {check['in_scope_confirmed']} confirmed digests had a tier-A guess. "
               f"Whole backup (every user_dates digest, same rules, no DV probe): <b>{al['exact_pct']}%</b> exact ({al['exact']}/{al['n']}), "
               f"<b>{al['within1_pct']}%</b> within ±1; {check['all_no_guess']} of {check['all_confirmed']} had no tier-A evidence. "
               "Tier B (Rick's Promote-time archive name) is excluded from this check because it would be circular.</p>")
    if check["misses"]:
        out.append("<details><summary>Misses and no-guesses in scope</summary><ul class=ev>")
        for fn, g, c, src in check["misses"]:
            out.append(f"<li>{esc(fn)}: machine {esc(g) if g else '—'} vs Rick {c} ({esc(src)})</li>")
        out.append("</ul></details>")
    # weakest
    out.append("<h2>The 10 weakest event-date guesses</h2><table><tr><th>file</th><th>tape</th><th>guess</th><th>conf</th><th>why</th></tr>")
    for s in summary["weakest"]:
        d = s.fields["event_date"]
        out.append(f"<tr class=weak><td class=p>{esc(s.rep['filename'])}</td><td>{esc(s.tape_key)}</td><td>{fv(d)}</td><td>{d['conf']}</td><td>{esc(' · '.join(d['evidence']))}</td></tr>")
    out.append("</table>")
    # surprises
    if summary["surprises"]:
        out.append("<h2>Worth a look</h2><ul>")
        for t in summary["surprises"]:
            out.append(f"<li>{esc(t)}</li>")
        out.append("</ul>")
    # TOC
    out.append("<h2>Proposed tapes</h2><div class=toc>")
    for key, h in headers.items():
        out.append(f"<div><a href='#{esc(norm_key(key))}'>{esc(h['label'])}</a> <span style='color:var(--mut)'>{esc(h['year_label'])} · {h['n']}</span></div>")
    out.append("</div>")
    # groups
    for key, h in headers.items():
        ys = "conf" if h["year_state"] == "confirmed" else "inf"
        out.append(f"<h2 id='{esc(norm_key(key))}'>{esc(h['label'])} <span class=tag>{esc(key.split(':')[0])}</span><span class=tag>{h['n']} file(s)</span></h2>")
        out.append("<div class=hdr>")
        out.append(f"<div class=f><div class=k>tape year</div><span class='{ys}'>{esc(h['year_label'])}</span> <small class=c>{h['year_conf']}</small><br><small class=c>{esc(h['year_source'])}</small></div>")
        out.append(f"<div class=f><div class=k>format</div><span class=inf>{esc(h['format'])}</span> <small class=c>{h['format_conf']}</small></div>")
        out.append(f"<div class=f><div class=k>generation</div><span class=inf>{esc(h['generation'])}</span> <small class=c>default</small></div>")
        out.append(f"<div class=f><div class=k>videographer</div><span class=inf>{esc(h['videographer'])}</span></div>")
        out.append(f"<div class=f><div class=k>shelf</div><span class=inf>{esc(h['shelf'])}</span></div>")
        out.append(f"<div class=f><div class=k>digitized</div><span class=inf>{esc(', '.join(h['digitized']) or '—')}</span></div>")
        if h["master"]:
            out.append(f"<div class=f><div class=k>capture master</div><span class=inf>{esc(h['master'])}</span></div>")
        if len(h.get("takes", [])) > 1:
            tk = "; ".join(f"take {t['n']}: {t['stem']} ({t['duration']} s, {t['born']})" for t in h["takes"])
            out.append(f"<div class=f style='flex:1;min-width:280px'><div class=k>takes</div><span class=warn>{len(h['takes'])} long captures in one folder — one tape in parts, or several tapes? Rick decides.</span><br><small class=c>{esc(tk)}</small></div>")
        out.append(f"<div class=f style='flex:1;min-width:280px'><div class=k>capture setup</div><span class=inf>{esc(h['setup'])}</span></div>")
        if thumbs.get(key):
            out.append("<div class=thumbs>" + "".join(f"<img alt='' src='data:image/jpeg;base64,{t}'>" for t in thumbs[key]) + "</div>")
        out.append("</div>")
        out.append("<table><tr><th>file</th><th>kind</th><th>take</th><th>role</th><th>event date</th><th>digitized</th><th>cataloged</th><th>DV rec</th><th>state</th></tr>")
        for s in h["members"]:
            r = s.rep
            dv = getattr(s, "dv", None)
            dvtxt = "—"
            if dv:
                dvtxt = (dv["rec_start"][:16] + (" → " + dv["rec_end"][:16] if dv["rec_end"] and dv["rec_end"][:10] != dv["rec_start"][:10] else "")) if dv.get("rec_start") else ("stripped" if dv.get("stripped") else (dv.get("error") or "no date"))
            state = []
            if r["removal_state"]:
                state.append(f"<span class=warn>{esc(r['removal_state'])}</span>")
            if r["archive_stage"] == "Master":
                state.append("Master")
            if len(s.rows) > 1:
                state.append(f"{len(s.rows)} copies")
            if s.user_events:
                state.append("event: " + esc("; ".join(s.user_events)))
            ev_items = []
            for name in ("carrier", "carrier_format", "role", "event_date", "digitized_on", "cataloged_on", "capture_setup"):
                d = s.fields.get(name)
                if d:
                    ev_items.append(f"<li><b>{name}</b> [{d['state']} {d['conf']}, {esc(d['source'])}] {esc(' · '.join(d['evidence']))}</li>")
            for n in s.notes:
                ev_items.append(f"<li class=warn>{esc(n)}</li>")
            if s.machine_guess and s.fields["event_date"]["state"] == "confirmed":
                ev_items.append(f"<li>machine would have said <i>{esc(s.machine_guess[0])}</i> ({esc(s.machine_guess[2])})</li>")
            arch = s.archive_relpath()
            out.append("<tr>"
                       f"<td class=p>{esc(r['filename'])}<br><small class=c>{esc(arch or r['full_path'])}</small>"
                       f"<details><summary>evidence</summary><ul class=ev>{''.join(ev_items)}</ul></details></td>"
                       f"<td>{esc(s.kind)}<br><small class=c>{esc(s.cls)} · {esc(r['video_codec'])} {esc(r['extra'].get('resolution',''))}</small></td>"
                       f"<td>{esc(getattr(s, 'take', None) or '')}</td>"
                       f"<td>{fv(s.fields['role'])}</td><td>{fv(s.fields['event_date'])}</td><td>{fv(s.fields['digitized_on'])}</td>"
                       f"<td>{fv(s.fields['cataloged_on'], show_conf=False)}</td><td><small>{dvtxt}</small></td><td><small>{' · '.join(state)}</small></td></tr>")
        out.append("</table>")
    out.append(f"<h2>Method</h2><ul class=ev>{''.join('<li>' + esc(x) + '</li>' for x in meta['method'])}</ul>")
    out.append("</body></html>")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(out))


# ----------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("db", help="catalog BACKUP sqlite (opened read-only via URI; never the live catalog)")
    ap.add_argument("--out-dir", default=None, help="where probe caches / JSON / HTML go (default: <db dir>/prov)")
    ap.add_argument("--csv", default=None, help="CSV output (default: <out-dir>/provenance_drafts.csv)")
    ap.add_argument("--html", default=None, help="review page (default: <out-dir>/review.html)")
    ap.add_argument("--july-root", default="/Volumes/MediaExpansion/Converted_VHS_Tapes_2026")
    ap.add_argument("--no-probe", action="store_true", help="skip DV frame reads")
    ap.add_argument("--no-thumbs", action="store_true", help="skip contact-sheet thumbnails")
    ap.add_argument("--dv-samples", type=int, default=9)
    args = ap.parse_args()

    db = os.path.abspath(args.db)
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import catalog_db  # noqa: E402
    if os.path.abspath(str(catalog_db.DEFAULT_DATABASE)) == db:
        sys.exit("refusing to open the live catalog; pass a backup copy")
    out_dir = args.out_dir or os.path.join(os.path.dirname(db), "prov")
    os.makedirs(out_dir, exist_ok=True)
    csv_path = args.csv or os.path.join(out_dir, "provenance_drafts.csv")
    html_path = args.html or os.path.join(out_dir, "review.html")
    t_start = time.time()

    cat = load_catalog(db)
    subjects = build_subjects(cat, args.july_root)
    for s in subjects:
        s.cls = classify(s)
        s.core = stem_core(s.rep["filename"])[0]
        s.cores = {stem_core(f["filename"])[0] for f in s.rows} | {s.core}

    # DV probes (one per digest; cached)
    cache_path = os.path.join(out_dir, "dv_probe_cache.json")
    cache = {}
    if os.path.exists(cache_path):
        with open(cache_path, encoding="utf-8") as fh:
            cache = json.load(fh)
    dv_probes = {}
    unreachable = []
    if not args.no_probe:
        for s in subjects:
            if s.rep["video_codec"] != "dvvideo" or not s.digest or s.digest in dv_probes:
                continue
            if s.digest in cache and not cache[s.digest].get("error"):
                dv_probes[s.digest] = cache[s.digest]
                continue
            path = None
            for f in sorted(s.rows, key=lambda f: (f["removal_state"] is not None, not f["full_path"].startswith("/Volumes/FamilyArchive/"))):
                if os.path.exists(f["full_path"]):
                    path = f["full_path"]
                    break
            if not path:
                unreachable.append(s.rep["full_path"])
                continue
            is_raw = s.rep["container"].startswith("DV") or path.lower().endswith(".dv") or "." not in os.path.basename(path)
            res = dv_probe(path, s.rep["duration_s"], is_raw, samples=args.dv_samples)
            dv_probes[s.digest] = res
            cache[s.digest] = res
            print(f"dv-probe {os.path.basename(path)}: {res['rec_start'] or ('stripped' if res['stripped'] else res['error'])} ({res['seconds']} s)", file=sys.stderr)
        with open(cache_path, "w", encoding="utf-8") as fh:
            json.dump(cache, fh, indent=1)
    ctx = {"dv_probes": dv_probes}

    for s in subjects:
        infer_subject(s, cat, ctx)
    assign_tapes(subjects, ctx)
    headers = tape_headers(subjects)

    # thumbnails: one small sheet per carrier group (vhs2026 / dv), from the cheapest reachable file
    thumbs = {}
    if not args.no_thumbs:
        for key, h in headers.items():
            if not (key.startswith("vhs2026:") or key.startswith("dv:")):
                continue
            cands = []
            for m in h["members"]:
                for f in m.rows:
                    if os.path.exists(f["full_path"]) and f["video_codec"] in ("ffv1", "dvvideo", "prores"):
                        p = f["full_path"]
                        cands.append((not p.startswith("/Volumes/FamilyArchive/"), p.startswith(("/Volumes/LaCieWorkspace/", "/Volumes/MediaExpansion/")), -(f["duration_s"] or 0), p, f["duration_s"]))
            if cands:
                cands.sort()
                _, _, _, p, dur = cands[0]
                t0 = time.time()
                thumbs[key] = grab_thumbs(p, dur)
                print(f"thumbs {h['label']}: {len(thumbs[key])} frames from {os.path.basename(p)} ({time.time() - t0:.1f} s)", file=sys.stderr)

    # summary
    masters = [s for s in subjects if s.kind.startswith("master")]
    july = [s for s in subjects if "july" in s.kind]
    dv_masters = [s for s in masters if s.rep["video_codec"] == "dvvideo"]
    dv_dated = [s for s in dv_masters if getattr(s, "dv", None) and s.dv.get("rec_start")]
    dv_stripped = [s for s in dv_masters if getattr(s, "dv", None) and s.dv.get("stripped")]
    confirmed = [s for s in subjects if s.user_date and s.user_date.get("value")]
    check = self_check(subjects, cat)
    weakest = sorted([s for s in subjects if s.fields["event_date"]["state"] != "confirmed"],
                     key=lambda s: (s.fields["event_date"]["conf"], s.rep["filename"]))[:10]
    surprises = []
    for s in subjects:
        for n in s.notes:
            if "DUB" in n or "≠" in n:
                surprises.append(f"{s.rep['filename']}: {n}")
        if s.user_date and s.user_date.get("value") and s.machine_year and s.machine_year != int(s.user_date["value"][:4]):
            diff = abs(s.machine_year - int(s.user_date["value"][:4]))
            surprises.append(f"{s.rep['filename']}: machine says {s.machine_year} ({s.machine_guess[2]}), Rick says {s.user_date['value']}"
                             + (" — off by one: clock/name vs Rick" if diff == 1 else " — the name/clock is misleading here"))
    if unreachable:
        surprises.append(f"{len(unreachable)} DV Master(s) not reachable on disk: " + "; ".join(os.path.basename(u) for u in unreachable))
    if not cat["ledger_first"]:
        surprises.append("ledger has no 'cataloged' kind in this backup — cataloged-on = min(files.scanned_at) / content.first_seen_at")
    tiles = [
        ("archive Masters (digests)", len(masters), f"{sum(1 for s in masters if s.rep['removal_state'] is None)} live rows, {sum(1 for s in masters if s.rep['removal_state'])} purged-only · {sum(1 for s in masters if s.kind == 'master+july')} are July captures"),
        ("July batch contents", len(july), f"{sum(1 for s in july if s.rep['removal_state'] is None)} present, {sum(1 for s in july if s.rep['removal_state'])} trashed/removed · {sum(len(s.rows) for s in july)} file rows"),
        ("proposed tapes", len([k for k in headers if k.startswith(('vhs2026:', 'dv:'))]), f"{len([k for k in headers if k.startswith('vhs2026:')])} VHS (July) · {len([k for k in headers if k.startswith('dv:')])} DV · {len([k for k in headers if k.startswith('sd:')])} SD transfers · {len([k for k in headers if k.startswith('born-digital')])} born-digital yrs · {len([k for k in headers if k.startswith('other')])} other"),
        ("DV Masters with REC DATE", f"{len(dv_dated)} / {len(dv_masters)}", f"{len(dv_stripped)} stripped (0xFF), {len(unreachable)} unreachable"),
        ("already confirmed (user_dates)", len({s.digest for s in confirmed}), f"{len({s.digest for s in confirmed if s.kind.startswith('master')})} masters · {len({s.digest for s in confirmed if 'july' in s.kind})} July"),
        ("year agreement (in scope)", f"{check['in_scope']['exact_pct']}%", f"±1 yr {check['in_scope']['within1_pct']}% · n={check['in_scope']['n']}"),
    ]
    summary = {"tiles": tiles, "weakest": weakest, "surprises": surprises}
    meta = {"when": dt.datetime.now(LOCAL_TZ).strftime("%Y-%m-%d %H:%M %Z"), "db": db, "method": [
        "Catalog: backup copy opened read-only (URI mode=ro). Masters = distinct digests in archive_copies; July = any files row whose path contains Converted_VHS_Tapes_2026/ (incl. trashed) plus a stat-only walk of the folder.",
        "Tape grouping: July folder (byte-identical copy) › name stem match to a July capture › same duration at 1280×720 › DV source project folder › DV REC DATE merge › born-digital by year.",
        "Event date: user_dates = confirmed (never re-emitted). Machine tier A = device clock (born digital) › DV REC DATE (camera clock; if it disagrees with the name by >1 yr it is the dub date) › Apple DV capture clock within a year of the name › year in original file/folder name › decade words. Tier B = Rick's Promote-time archive name/folder, fallback only, flagged, excluded from the self-check.",
        "Digitized: July = FFV1 birth time (clock-named Montana files prove birth = capture start); DV = REC DATE when it is a dub, else QuickTime creation_time, else oldest copy's birth. Cataloged = min(scanned_at) or content.first_seen_at (ledger has no 'cataloged' kind).",
        f"DV REC DATE/TIME: packs 0x62/0x63 decoded from VAUX + subcode of {args.dv_samples} frames per file (raw .dv by byte offset; .mov via ffmpeg -ss stream copy). dvrescue could not be installed (brew denied), mediainfo at ParseSpeed<1 does not expose it.",
        "Roles use PBCore instantiationGenerations words; formats use instantiationPhysical words. Never inferred: videographer, shelf number, condition, descriptions, generation beyond the default.",
    ]}

    rows = [subject_row(s, headers[s.tape_key]) for s in sorted(subjects, key=lambda x: (x.tape_key or "", x.rep["full_path"]))]
    write_csv(csv_path, rows)
    write_html(html_path, headers, subjects, summary, check, thumbs, meta)
    with open(os.path.join(out_dir, "provenance_drafts.json"), "w", encoding="utf-8") as fh:
        json.dump({"headers": {k: {kk: vv for kk, vv in h.items() if kk != "members"} for k, h in headers.items()},
                   "check": check, "rows": rows}, fh, indent=1, default=str)

    print(json.dumps({
        "csv": csv_path, "html": html_path, "masters": len(masters), "july_files": len(july),
        "tapes": {"vhs2026": len([k for k in headers if k.startswith('vhs2026:')]), "dv": len([k for k in headers if k.startswith('dv:')]), "sd": len([k for k in headers if k.startswith('sd:')]),
                  "born_digital_years": len([k for k in headers if k.startswith('born-digital')]), "other": len([k for k in headers if k.startswith('other')])},
        "dv_masters": len(dv_masters), "dv_with_rec_date": len(dv_dated), "dv_stripped": len(dv_stripped), "dv_unreachable": unreachable,
        "confirmed_digests_in_scope": len({s.digest for s in confirmed}),
        "self_check": {k: v for k, v in check.items() if k != "misses"}, "misses": check["misses"],
        "surprises": surprises, "seconds": round(time.time() - t_start, 1)}, indent=1, default=str))


if __name__ == "__main__":
    main()
