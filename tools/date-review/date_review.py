#!/usr/bin/env python3
"""date_review.py — a loopback page to check the DV recording datecode against the other dates.

Rick, 2026-11-01: "pick 25 with dates from dv and various sources so we can compare … If there
are dates confirmed by me that differ from the DV embedded dates, I'd want to see these first."

Two commands:
  build  — read the DV datecode results (scripts/dv_datecode.py output), the catalog (READ-ONLY,
           through scripts/catalog_db only) and the media (read-only); pick N clips
           deterministically; write <run>/selection.json (digests, reasons, the date table, the
           file NAME — never a path) and <run>/media/*.jpg (poster + filmstrip, from the app's
           preview cache when it has them, else ripped with ffmpeg).
  serve  — a page on 127.0.0.1 only: one clip at a time, the date table with the DV line
           highlighted, "Is the DV date the recording date?" Right (1) / Wrong (2) / Unsure (3),
           a note, a Summary tab. Verdicts are appended to <run>/verdicts.jsonl
           ({digest, verdict, at, notes?}); the last line per digest wins.

Truth (CLAUDE.md rule 1): the DV line is the datecode read out of the frames by dvrescue; the
container line is what ffprobe reads from the file NOW (the catalog's stored value is shown only
as a note when it differs); "File modified" is os.stat at build time; "You confirmed" is
user_dates; "Inferred" is inferred_dates with its source named by kind (never a folder name).

Privacy: the run directory must sit under a `.scratch/` folder (git-ignored; family pixels and
names); the server binds a loopback address only, refuses a foreign Host header (DNS rebinding)
and a non-JSON POST (cross-site form posts).

Worst-case memory: the catalog load (catalog_db.records, O(records): ~12k rows today, tens of MB)
is the one big structure and is dropped after selection; the results file is O(DV files) dicts
(~700); the server holds selection.json (25 clips, a few KB) and reads one JPEG (<~200 KB) per
request. ffmpeg/ffprobe stream the media; nothing reads a whole media file into memory.

Usage:
  venv/bin/python3 tools/date-review/date_review.py build --results <dv_datecode.jsonl> [--run DIR]
  venv/bin/python3 tools/date-review/date_review.py serve [--run DIR] [--port 8767] [--open]
"""
from __future__ import annotations

import argparse
import ipaddress
import json
import os
import random
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Iterable

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

DEFAULT_RUN = ROOT / ".scratch" / "date-review" / "dv-25"
DEFAULT_PORT = 8767
DEFAULT_SEED = 20261101
DEFAULT_N = 25
PREVIEW_CACHE = Path.home() / "Library" / "Application Support" / "VideoScan" / "preview-cache"
SELECTION_FILE = "selection.json"
VERDICTS_FILE = "verdicts.jsonl"
VERDICTS = ("right", "wrong", "unsure")
DASH = "—"
STRIP_FRAMES = 8
NOTES_MAX = 4000
TOOL_TIMEOUT_S = 60.0
_DIGEST = re.compile(r"[0-9a-f]{64}")
_MEDIA_NAME = re.compile(r"[0-9a-f]{64}-(poster|strip-\d\d)\.jpg")


# ---------------------------------------------------------------- guards (pure)

def assert_scratch(path: Path) -> Path:
    """The run directory lives under a `.scratch` folder (family pixels and names), or nothing runs."""
    resolved = Path(path).resolve()
    if ".scratch" not in resolved.parts:
        raise SystemExit(f"refusing {resolved}: the review run directory must be under a .scratch/ folder")
    return resolved


def assert_loopback(host: str) -> str:
    """Only a loopback IP literal (127.0.0.0/8, ::1) may be bound; a name or a LAN address is refused."""
    try:
        if ipaddress.ip_address(host).is_loopback:
            return host
    except ValueError:
        pass
    raise SystemExit(f"refusing to bind {host!r}: the review page serves the loopback interface only")


# ---------------------------------------------------------------- the date table (pure)

def _utc(value) -> datetime | None:
    """Unix seconds or ISO-8601 text -> an aware UTC datetime; None when it does not parse."""
    if value is None or value == "":
        return None
    try:
        if isinstance(value, (int, float)):
            return datetime.fromtimestamp(value, tz=timezone.utc)
        when = datetime.fromisoformat(str(value).strip().replace("Z", "+00:00"))
        return when if when.tzinfo else when.replace(tzinfo=timezone.utc)
    except (ValueError, OverflowError, OSError):
        return None


def container_date(value, now_year: int | None = None) -> tuple[str | None, str]:
    """A container creation time -> (YYYY-MM-DD or None, note). The sentinel dates a muxer
    writes when it has no date are not dates: 1904-01-01 (QuickTime's zero), 1970 / zero
    (Unix zero; ffmpeg's default), a year in the future."""
    if value is None or value == "":
        return None, "none in the file"
    when = _utc(value)
    if when is None:
        return None, "unreadable"
    if when.year == 1904:
        return None, "1904 is QuickTime's zero date, not a date"
    if when.year <= 1970:
        return None, f"{when.year} is a zero/no-date value, not a date"
    if when.year > (now_year or datetime.now().year):
        return None, f"{when.year} is in the future, not a date"
    return when.strftime("%Y-%m-%d"), when.strftime("%H:%M UTC")


_NAME_DATE = re.compile(r"(?<!\d)(19[5-9]\d|20[0-4]\d)(?:[-_.](\d\d|xx)[-_.](\d\d|xx)|(s))?(?!\d)")


def filename_dates(name: str) -> list[str]:
    """Dates and years a file NAME carries, in order, distinct: '2003-12-25', '2003' ('2003-xx-xx' -> '2003'),
    a decade as '1960s'."""
    out: list[str] = []
    for m in _NAME_DATE.finditer(name or ""):
        year, month, day = m.group(1), m.group(2), m.group(3)
        token = year + "s" if m.group(4) else year
        if month and day and month != "xx" and day != "xx" and 1 <= int(month) <= 12 and 1 <= int(day) <= 31:
            token = f"{year}-{month}-{day}"
        if token not in out:
            out.append(token)
    return out


_INFERRED_KINDS = (("on-screen date", "on-screen date"), ("folder", "folder name"), ("spoken", "speech"),
                   ("mentioned in speech", "speech"), ("caption", "caption"), ("age ", "a person's age"),
                   ("export stamp", "export stamp"), ("filename", "file name"))


def inferred_kind(reason: str | None, source: str | None) -> str:
    """The inferred date's source as a KIND word — never the reason's text (it quotes folder names)."""
    first = (reason or "").split(";", 1)[0].strip().lower()
    kind = next((word for key, word in _INFERRED_KINDS if first.startswith(key)), "other evidence")
    src = (source or "").lower()
    if src.startswith("propagated"):
        kind += ", propagated from a copy"
    elif src == "catch-up":
        kind += ", catch-up"
    return kind


def inferred_value(date_iso: str | None, range_years: dict | None) -> str | None:
    """A year-range inference reads as its years ('2007', '2000–2010'); a dated one as its day."""
    if range_years and range_years.get("startYear") is not None:
        a, b = range_years["startYear"], range_years.get("endYear", range_years["startYear"])
        return str(a) if a == b else f"{a}–{b}"
    when = _utc(date_iso)
    return when.strftime("%Y-%m-%d") if when else None


def date_rows(fact: dict, now_year: int | None = None) -> list[dict]:
    """One clip's facts -> the table the page shows: {source, value (a date or '—'), note, dv}."""
    rows = []

    def add(source, value, note="", dv=False):
        rows.append({"source": source, "value": value or DASH, "note": note or "", "dv": dv})

    first, last = fact.get("rdt_first"), fact.get("rdt_last")
    note = first[11:16] if first else "no datecode in the frames"
    if first and last and last[:10] != first[:10]:
        note += f" … last frame {last[:10]} {last[11:16]}"
    add("DV camcorder clock", first[:10] if first else None, note, dv=True)

    conf = fact.get("user_confidence")
    add("You confirmed", fact.get("user_date"), conf or ("" if fact.get("user_date") else "not set"))

    value, note = container_date(fact.get("container"), now_year)
    stored, _ = container_date(fact.get("catalog_container"), now_year)
    if stored != value and stored is not None:
        note += f" (the catalog says {stored})"
    add("Container / embedded", value, note)

    names = filename_dates(fact.get("filename") or "")
    add("Filename", names[0] if names else None, " · ".join(names[1:]) and "also " + " · ".join(names[1:]))

    mtime = fact.get("mtime")
    when = datetime.fromtimestamp(mtime) if mtime is not None else None
    add("File modified", when.strftime("%Y-%m-%d") if when else None,
        "the copy/transfer date" if when else "not readable")

    inf = inferred_value(fact.get("inferred_date"), fact.get("inferred_range"))
    if inf or fact.get("inferred_reason"):
        label = f"Inferred ({inferred_kind(fact.get('inferred_reason'), fact.get('inferred_source'))})"
        conf = fact.get("inferred_confidence")
        add(label if inf else "Inferred", inf, f"confidence {round(conf * 100)}%" if inf and conf is not None
            else ("examined, no evidence" if not inf else ""))
    else:
        add("Inferred", None, "not examined")
    return rows


# ---------------------------------------------------------------- selection (pure)

def _year(text: str | None) -> int | None:
    m = re.match(r"(\d{4})", text or "")
    return int(m.group(1)) if m else None


def candidates(results: Iterable[dict], records: Iterable[dict],
               exists: Callable[[str], bool] = os.path.exists) -> list[dict]:
    """DV results with a datecode, joined to the live catalog row of the copy that is on disk
    (first existing path, sorted — dv_datecode's choice). `path` is internal: never serialized."""
    dated = {r["digest"]: r for r in results if r.get("digest") and r.get("rdt_first")}
    rows: dict[str, list[dict]] = {}
    for rec in records:
        digest = (rec.get("contentFixity") or {}).get("sha256")
        if digest in dated and rec.get("removal") is None and rec.get("fullPath"):
            rows.setdefault(digest, []).append(rec)
    out = []
    for digest in sorted(rows):
        rec = next((r for r in sorted(rows[digest], key=lambda r: r["fullPath"]) if exists(r["fullPath"])), None)
        if rec is None:
            continue
        res = dated[digest]
        rdt_year = _year(res["rdt_first"])
        user = rec.get("userDate")
        names = filename_dates(rec.get("filename") or "")
        out.append({
            "digest": digest, "kind": res.get("kind") or "raw", "path": rec["fullPath"],
            "filename": rec.get("filename") or Path(rec["fullPath"]).name, "ext": (rec.get("ext") or "").lower(),
            "duration": rec.get("durationSeconds"),
            "rdt_first": res["rdt_first"], "rdt_last": res.get("rdt_last"), "rdt_year": rdt_year,
            "mtime_year": res.get("mtime_year"),
            "user_date": user, "user_confidence": rec.get("userDateConfidence"),
            "catalog_container": rec.get("embeddedCreationDate"),
            "container_year": _year(container_date(rec.get("embeddedCreationDate"))[0]),
            "filename_years": sorted({int(t[:4]) for t in names}),
            "inferred_date": rec.get("inferredRecordDate"), "inferred_range": rec.get("inferredDateRange"),
            "inferred_source": rec.get("inferredDateSource"), "inferred_reason": rec.get("inferredDateReason"),
            "inferred_confidence": rec.get("inferredDateConfidence"),
        })
    return out


def _gap(c: dict) -> int:
    return (c["mtime_year"] - c["rdt_year"]) if c.get("mtime_year") and c.get("rdt_year") else 0


def _two_days(c: dict) -> bool:
    return bool(c.get("rdt_last")) and c["rdt_last"][:10] != c["rdt_first"][:10]


def select(cands: list[dict], n: int = DEFAULT_N, seed: int = DEFAULT_SEED) -> list[dict]:
    """Deterministic pick of n clips, each with its reason, in page order: every clip you dated
    (those that DISAGREE with the DV clock first, widest gap first), then variety — two that span
    two days, the four largest mtime gaps, four whose container date disagrees, four whose name
    carries a year, at least four raw and four wrapped, then one per DV year round-robin.
    The input order does not matter (sorted by digest, then a seeded RNG)."""
    rng = random.Random(seed)
    pool = sorted(cands, key=lambda c: c["digest"])
    chosen: list[dict] = []
    taken: set[str] = set()

    def take(c, reason):
        if len(chosen) < n and c["digest"] not in taken:
            taken.add(c["digest"])
            chosen.append({**c, "reason": reason})

    def pick(pred, k, reason, key=None):
        eligible = [c for c in pool if c["digest"] not in taken and pred(c)]
        if key:
            eligible.sort(key=key)
        else:
            rng.shuffle(eligible)
        for c in eligible[:max(0, k)]:
            take(c, reason(c))

    def user_gap(c):
        return abs((_year(c["user_date"]) or c["rdt_year"]) - c["rdt_year"])

    dated = sorted((c for c in pool if c.get("user_date")), key=lambda c: (-user_gap(c), c["digest"]))
    for c in dated:
        how = f"differs by {user_gap(c)} y" if user_gap(c) else "same year"
        take(c, f"you confirmed {c['user_date']}; DV clock {c['rdt_first'][:10]} ({how})")
    pick(_two_days, 2, lambda c: f"DV clock spans two days ({c['rdt_first'][:10]} … {c['rdt_last'][:10]})")
    pick(lambda c: _gap(c) > 0, 4, lambda c: f"file modified {c['mtime_year']}, DV clock {c['rdt_year']} "
         f"(gap {_gap(c)} y)", key=lambda c: (-_gap(c), c["digest"]))
    pick(lambda c: c.get("container_year") and c["container_year"] != c["rdt_year"], 4,
         lambda c: f"container date {c['container_year']} vs DV clock {c['rdt_year']}")
    pick(lambda c: c["filename_years"], 4,
         lambda c: f"name carries {', '.join(map(str, c['filename_years']))}; DV clock {c['rdt_year']}")
    for kind in ("raw", "wrapped"):
        have = sum(1 for c in chosen if c["kind"] == kind)
        pick(lambda c, k=kind: c["kind"] == k, 4 - have, lambda c: f"{c['kind']} DV ({c['ext'] or '?'}), "
             f"DV clock {c['rdt_year']}")
    years = sorted({c["rdt_year"] for c in pool if c.get("rdt_year")})
    while len(chosen) < n and any(c["digest"] not in taken for c in pool):
        for year in years:
            pick(lambda c, y=year: c["rdt_year"] == y, 1, lambda c: f"year spread: DV clock {c['rdt_year']}")
    return chosen


def public_clip(c: dict, rows: list[dict], poster: str | None, strip: list[str]) -> dict:
    """What selection.json (and so the page) carries for one clip: no path, the file NAME only."""
    return {"digest": c["digest"], "filename": c["filename"], "kind": c["kind"], "reason": c["reason"],
            "user_dated": bool(c.get("user_date")), "rows": rows, "poster": poster, "strip": strip}


# ---------------------------------------------------------------- verdicts

def write_verdict(run_dir: Path, digest: str, verdict: str, notes: str | None = None,
                  known: Iterable[str] | None = None) -> dict:
    """Append one verdict line; refuses an unknown word, a non-digest, a digest not in the selection."""
    if verdict not in VERDICTS:
        raise ValueError(f"verdict must be one of {VERDICTS}")
    if not _DIGEST.fullmatch(digest or ""):
        raise ValueError("digest must be a sha256 hex")
    if known is not None and digest not in set(known):
        raise ValueError("digest is not in this selection")
    record = {"digest": digest, "verdict": verdict,
              "at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
    if notes and str(notes).strip():
        record["notes"] = str(notes).strip()[:NOTES_MAX]
    with (Path(run_dir) / VERDICTS_FILE).open("a", encoding="utf-8") as sink:
        sink.write(json.dumps(record, sort_keys=True) + "\n")
    return record


def read_verdicts(run_dir: Path) -> dict[str, dict]:
    """digest -> the LAST verdict line for it; a torn or malformed line is skipped."""
    out: dict[str, dict] = {}
    path = Path(run_dir) / VERDICTS_FILE
    if not path.is_file():
        return out
    for line in path.read_text(encoding="utf-8").splitlines():
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        if isinstance(rec, dict) and rec.get("verdict") in VERDICTS and isinstance(rec.get("digest"), str):
            out[rec["digest"]] = rec
    return out


def review_state(run_dir: Path) -> dict:
    """The page's state: selection.json's clips + their latest verdicts + the counts."""
    selection = json.loads((Path(run_dir) / SELECTION_FILE).read_text(encoding="utf-8"))
    verdicts = read_verdicts(run_dir)
    clips = []
    for c in selection["clips"]:
        v = verdicts.get(c["digest"]) or {}
        clips.append({**c, "verdict": v.get("verdict"), "notes": v.get("notes", ""), "at": v.get("at")})
    counts = {w: sum(1 for c in clips if c["verdict"] == w) for w in VERDICTS}
    counts["unanswered"] = sum(1 for c in clips if not c["verdict"])
    return {"clips": clips, "counts": counts, "built_at": selection.get("built_at"), "seed": selection.get("seed")}


# ---------------------------------------------------------------- media (read-only)

def _tool(name: str) -> str | None:
    brewed = Path("/opt/homebrew/bin") / name
    return str(brewed) if brewed.exists() else shutil.which(name)


def probe_container(ffprobe: str, path: str) -> tuple[str | None, float | None]:
    """(creation_time the file carries now, duration) — format tag first, else the first stream tag."""
    try:
        done = subprocess.run([ffprobe, "-v", "error", "-show_entries",
                               "format=duration:format_tags=creation_time:stream_tags=creation_time",
                               "-of", "json", path], capture_output=True, text=True, timeout=TOOL_TIMEOUT_S)
        info = json.loads(done.stdout or "{}")
    except (subprocess.TimeoutExpired, ValueError, OSError):
        return None, None
    fmt = info.get("format") or {}
    when = (fmt.get("tags") or {}).get("creation_time")
    if not when:
        when = next(((s.get("tags") or {}).get("creation_time") for s in info.get("streams") or []
                     if (s.get("tags") or {}).get("creation_time")), None)
    try:
        duration = float(fmt["duration"])
    except (KeyError, TypeError, ValueError):
        duration = None
    return when, duration


# DV is 720x480/576 with non-square pixels and interlaced: deinterlace, square the pixels, 640 wide.
_VF = "yadif,scale=trunc(ih*dar/2)*2:ih,setsar=1,scale=640:-2"


def rip_frame(ffmpeg: str, path: str, at_s: float, dest: Path, first_if_none: bool = False) -> bool:
    """One frame at at_s into dest (JPEG); ffmpeg seeks, so it reads a few frames, not the file.
    first_if_none: when the seek finds no frame (a one-frame clip: 10 % of 0.033 s is past it),
    take the first frame instead."""
    seeks = [f"{max(0.0, at_s):.3f}"] + (["0"] if first_if_none and at_s > 0 else [])
    for seek in seeks:
        try:
            subprocess.run([ffmpeg, "-nostdin", "-v", "error", "-y", "-ss", seek, "-i", path,
                            "-frames:v", "1", "-vf", _VF, "-q:v", "4", str(dest)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=TOOL_TIMEOUT_S)
        except (subprocess.TimeoutExpired, OSError):
            return False
        if dest.is_file() and dest.stat().st_size > 0:
            return True
    return False


def _strip_index(name: str) -> int:
    m = re.search(r"-strip-(\d+)-of-", name)
    return int(m.group(1)) if m else 0


def gather_media(c: dict, media: Path, ffmpeg: str | None, duration: float | None,
                 cache: Path = PREVIEW_CACHE) -> tuple[str | None, list[str]]:
    """Poster + filmstrip for one clip into media/: the app's preview cache when it has them,
    else ripped (poster at 10 % of the duration, STRIP_FRAMES evenly spaced). Returns names."""
    digest = c["digest"]
    poster = media / f"{digest}-poster.jpg"
    cached = cache / f"{digest}-best.jpg"
    if cached.is_file():
        shutil.copyfile(cached, poster)  # read the app's cache; write only into the run folder
    elif ffmpeg and duration:
        rip_frame(ffmpeg, c["path"], duration * 0.10, poster, first_if_none=True)
    strip = []
    cached_strip = sorted(cache.glob(f"{digest}-strip-*-of-*.jpg"), key=lambda p: _strip_index(p.name))
    if cached_strip:
        for i, src in enumerate(cached_strip[:16]):
            dest = media / f"{digest}-strip-{i:02d}.jpg"
            shutil.copyfile(src, dest)
            strip.append(dest.name)
    elif ffmpeg and duration:
        for i in range(STRIP_FRAMES):
            dest = media / f"{digest}-strip-{i:02d}.jpg"
            if rip_frame(ffmpeg, c["path"], duration * (i + 0.5) / STRIP_FRAMES, dest):
                strip.append(dest.name)
    return (poster.name if poster.is_file() else None), strip


def load_results(path: Path) -> list[dict]:
    """Every whole JSON line of a dv_datecode results file; the last line per digest wins; torn lines skipped."""
    latest: dict[str, dict] = {}
    with Path(path).open(encoding="utf-8") as f:
        for line in f:
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if isinstance(rec, dict) and rec.get("digest"):
                latest[rec["digest"]] = rec
    return list(latest.values())


def build(results_path: Path, run_dir: Path, n: int = DEFAULT_N, seed: int = DEFAULT_SEED,
          db: str | None = None, cache: Path = PREVIEW_CACHE, now_year: int | None = None) -> dict:
    run_dir = assert_scratch(run_dir)
    import catalog_db
    conn = catalog_db.connect(db)
    try:
        records = catalog_db.records(conn)
    finally:
        conn.close()
    cands = candidates(load_results(results_path), records)
    del records
    chosen = select(cands, n, seed)
    print(f"START date_review build candidates={len(cands)} selected={len(chosen)} seed={seed}", flush=True)
    media = run_dir / "media"
    media.mkdir(parents=True, exist_ok=True)
    ffmpeg, ffprobe = _tool("ffmpeg"), _tool("ffprobe")
    clips = []
    for i, c in enumerate(chosen, 1):
        container, duration = probe_container(ffprobe, c["path"]) if ffprobe else (None, None)
        try:
            mtime = os.stat(c["path"]).st_mtime
        except OSError:
            mtime = None
        fact = {**c, "container": container, "mtime": mtime}
        poster, strip = gather_media(c, media, ffmpeg, duration or c.get("duration"), cache)
        clips.append(public_clip(c, date_rows(fact, now_year), poster, strip))
        print(f"  {i}/{len(chosen)} {c['digest'][:8]} poster={'yes' if poster else 'no'} strip={len(strip)}",
              flush=True)
    selection = {"built_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "seed": seed,
                 "candidates": len(cands), "clips": clips}
    tmp = run_dir / (SELECTION_FILE + ".tmp")
    tmp.write_text(json.dumps(selection, indent=1, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp, run_dir / SELECTION_FILE)
    print(f"OUTCOME date_review build complete clips={len(clips)} "
          f"posters={sum(1 for c in clips if c['poster'])}", flush=True)
    return selection


# ---------------------------------------------------------------- the page

PAGE = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>DV date review</title>
<style>
:root{--bg:#0d1117;--panel:#161b22;--border:#30363d;--fg:#e6edf3;--muted:#8b949e;--good:#3fb950;--warn:#d29922;--bad:#f85149;--accent:#58a6ff}
body{margin:0;background:var(--bg);color:var(--fg);font:15px -apple-system,system-ui,sans-serif}
nav{display:flex;gap:4px;padding:10px 20px;border-bottom:1px solid var(--border);align-items:center}
nav button.tab{background:none;border:none;color:var(--muted);padding:6px 12px;font-weight:600}
nav button.tab.on{color:var(--fg);border-bottom:2px solid var(--accent)}
nav .prog{margin-left:auto;color:var(--muted)}
main{padding:18px 26px;max-width:1100px}
h1{font-size:19px;margin:0 0 4px;overflow-wrap:anywhere}
.sub{color:var(--muted);margin-bottom:12px}
.grid{display:grid;grid-template-columns:minmax(320px,1fr) 1fr;gap:22px;align-items:start}
.poster{width:100%;background:#000;border-radius:8px;cursor:pointer;min-height:200px;object-fit:contain}
.nopic{display:flex;align-items:center;justify-content:center;color:var(--muted);background:#000;border-radius:8px;height:240px}
.strip{display:flex;gap:6px;flex-wrap:wrap;margin-top:10px}
.strip img{width:150px;border-radius:5px;background:#000}
table{border-collapse:collapse;width:100%}
td{padding:8px 10px;border-bottom:1px solid var(--border);vertical-align:top}
td.src{color:var(--muted);width:38%}
td.val{font-size:18px;font-weight:700;white-space:nowrap}
td.note{color:var(--muted);font-size:13px}
tr.dv td{background:#1f2a3a}tr.dv td.src{color:var(--accent);font-weight:700}
.q{margin:18px 0 8px;font-size:17px;font-weight:600}
button{font:inherit;font-weight:600;padding:9px 16px;border-radius:8px;border:1px solid var(--border);background:var(--panel);color:var(--fg);cursor:pointer}
button.right{border-color:var(--good)}button.wrong{border-color:var(--bad)}button.unsure{border-color:var(--muted)}
button.on{outline:2px solid var(--accent)}
kbd{font-size:11px;color:var(--muted);border:1px solid var(--border);border-radius:4px;padding:0 4px;margin-left:6px}
textarea{width:100%;min-height:64px;background:var(--panel);color:var(--fg);border:1px solid var(--border);border-radius:8px;padding:8px;font:inherit;box-sizing:border-box}
.row{display:flex;gap:10px;align-items:center;flex-wrap:wrap}
.muted{color:var(--muted)}.saved{color:var(--good);font-size:13px}
.sum td{font-size:14px}.big{font-size:28px;font-weight:700;margin-right:22px}
</style></head><body>
<nav><button class="tab on" id="t-review" onclick="tab('review')">Review</button><button class="tab" id="t-sum" onclick="tab('sum')">Summary</button><span class="prog" id="prog"></span></nav>
<main id="main"><div class="muted">Loading…</div></main>
<script>
const $=s=>document.querySelector(s); let S=null, i=0, view="review", showStrip=false, status="";
const esc=t=>String(t??"").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
const WORD={right:"Right",wrong:"Wrong",unsure:"Unsure"};
async function load(){const r=await fetch("/state.json",{cache:"no-store"}); S=await r.json(); render()}
function tab(v){view=v; render()}
function render(){
  if(!S)return; const n=S.clips.length, c=S.counts;
  $("#t-review").classList.toggle("on",view==="review"); $("#t-sum").classList.toggle("on",view==="sum");
  $("#prog").textContent=`${Math.min(i+1,n)} of ${n} · right ${c.right} · wrong ${c.wrong} · unsure ${c.unsure}`;
  if(view==="sum"){renderSummary();return}
  const k=S.clips[i]; if(!k){$("#main").innerHTML='<div class="muted">No clips.</div>';return}
  const pic=k.poster?`<img class="poster" src="/media/${esc(k.poster)}" title="click for the filmstrip" onclick="showStrip=!showStrip;render()">`:`<div class="nopic">no picture</div>`;
  const strip=showStrip?(k.strip.length?`<div class="strip">${k.strip.map(s=>`<img src="/media/${esc(s)}" loading="lazy">`).join("")}</div>`:`<div class="muted">no filmstrip</div>`):"";
  const rows=k.rows.map(r=>`<tr class="${r.dv?"dv":""}"><td class="src">${esc(r.source)}</td><td class="val">${esc(r.value)}</td><td class="note">${esc(r.note)}</td></tr>`).join("");
  $("#main").innerHTML=`<h1>${esc(k.filename)}</h1><div class="sub">${esc(k.kind)} DV · picked because: ${esc(k.reason)}</div>
  <div class="grid"><div>${pic}${strip}</div><div><table>${rows}</table>
  <div class="q">Is the DV date the recording date?</div>
  <div class="row">${["right","wrong","unsure"].map((w,j)=>`<button class="${w} ${k.verdict===w?"on":""}" onclick="verdict('${w}')">${WORD[w]}<kbd>${j+1}</kbd></button>`).join("")}</div>
  <p class="muted" style="margin:14px 0 4px">Why? (optional; saved with the verdict)</p>
  <textarea id="notes" placeholder="e.g. a 1965 film re-recorded by the camcorder in 2001">${esc(k.notes)}</textarea>
  <div class="row" style="margin-top:8px"><button onclick="saveNote()" ${k.verdict?"":"disabled title='pick Right / Wrong / Unsure first'"}>Save note</button><span class="saved">${esc(status)}</span>
  <span class="muted" style="margin-left:auto">← back · → next</span></div></div></div>`;
  status="";
}
function renderSummary(){
  const c=S.counts;
  const rows=S.clips.map((k,j)=>`<tr><td><a href="#" onclick="i=${j};tab('review');return false" style="color:var(--accent)">${j+1}. ${esc(k.filename)}</a></td><td>${esc((k.rows.find(r=>r.dv)||{}).value)}</td><td>${k.verdict?esc(WORD[k.verdict]):'<span class="muted">—</span>'}</td><td class="note">${esc(k.notes)}</td></tr>`).join("");
  $("#main").innerHTML=`<div style="margin-bottom:16px"><span class="big">${c.right}</span>right <span class="big">${c.wrong}</span>wrong <span class="big">${c.unsure}</span>unsure <span class="big">${c.unanswered}</span>not yet</div>
  <table class="sum"><tr><td class="muted">Clip</td><td class="muted">DV clock</td><td class="muted">Verdict</td><td class="muted">Note</td></tr>${rows}</table>`;
}
async function post(word){const k=S.clips[i]; const notes=($("#notes")||{}).value||"";
  const r=await fetch("/verdict",{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({digest:k.digest,verdict:word,notes})});
  if(!r.ok){status="not saved: "+await r.text();render();return false} await load(); return true}
async function verdict(word){if(await post(word)){if(i<S.clips.length-1){i++;showStrip=false} render()}}
async function saveNote(){const k=S.clips[i]; if(k.verdict&&await post(k.verdict)){status="note saved";render()}}
document.addEventListener("keydown",e=>{if(!S||view!=="review"||e.target.tagName==="TEXTAREA")return;
  if(e.key==="1")verdict("right"); if(e.key==="2")verdict("wrong"); if(e.key==="3")verdict("unsure");
  if(e.key==="ArrowRight"&&i<S.clips.length-1){i++;showStrip=false;render()} if(e.key==="ArrowLeft"&&i>0){i--;showStrip=false;render()}});
load();
</script></body></html>
"""


def make_server(run_dir: Path, host: str = "127.0.0.1", port: int = DEFAULT_PORT):
    """The loopback server over a built run dir: GET / · /state.json · /media/<digest>-….jpg (files in
    <run>/media only); POST /verdict (JSON). Returned unstarted. C++: a class defined inside a
    function closes over run_dir like a lambda capture."""
    import http.server
    run_dir = assert_scratch(run_dir)
    assert_loopback(host)
    if not (run_dir / SELECTION_FILE).is_file():
        raise SystemExit(f"no {SELECTION_FILE} in the run dir: run `build` first")
    media = run_dir / "media"

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):  # quiet: verdicts are logged explicitly
            pass

        def _send(self, status: int, body: bytes, kind: str = "text/plain; charset=utf-8"):
            self.send_response(status)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def _host_ok(self) -> bool:
            # DNS rebinding: a page on evil.example resolved to 127.0.0.1 still sends its own Host.
            name = (self.headers.get("Host") or "").rsplit(":", 1)[0].strip("[]")
            return name in ("127.0.0.1", "localhost", "::1")

        def do_GET(self):  # noqa: N802 — http.server's name
            if not self._host_ok():
                return self._send(403, b"forbidden host")
            path = self.path.split("?", 1)[0]
            if path == "/":
                return self._send(200, PAGE.encode("utf-8"), "text/html; charset=utf-8")
            if path == "/state.json":
                return self._send(200, json.dumps(review_state(run_dir)).encode("utf-8"), "application/json")
            if path.startswith("/media/"):
                name = path[len("/media/"):]
                target = media / name
                if _MEDIA_NAME.fullmatch(name) and target.is_file():
                    return self._send(200, target.read_bytes(), "image/jpeg")
            return self._send(404, b"not found")

        def do_POST(self):  # noqa: N802
            if not self._host_ok():
                return self._send(403, b"forbidden host")
            if self.path.split("?", 1)[0] != "/verdict":
                return self._send(404, b"not found")
            if not (self.headers.get("Content-Type") or "").startswith("application/json"):
                return self._send(415, b"JSON only")
            try:
                length = min(int(self.headers.get("Content-Length") or 0), 64_000)
                body = json.loads(self.rfile.read(length).decode("utf-8") or "{}")
                known = [c["digest"] for c in review_state(run_dir)["clips"]]
                record = write_verdict(run_dir, body.get("digest"), body.get("verdict"), body.get("notes"), known)
            except (ValueError, TypeError, AttributeError, OSError) as exc:
                return self._send(400, str(exc).encode("utf-8"))
            print(f"verdict {record['digest'][:8]} {record['verdict']}{' +note' if 'notes' in record else ''}",
                  flush=True)
            return self._send(200, json.dumps(record).encode("utf-8"), "application/json")

    return http.server.ThreadingHTTPServer((host, port), Handler)


# ---------------------------------------------------------------- CLI

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="command", required=True)
    b = sub.add_parser("build", help="pick the clips, write selection.json and the pictures")
    b.add_argument("--results", type=Path, required=True, help="dv_datecode.py results (.jsonl)")
    b.add_argument("--run", type=Path, default=DEFAULT_RUN, help="run directory (under .scratch/)")
    b.add_argument("--n", type=int, default=DEFAULT_N)
    b.add_argument("--seed", type=int, default=DEFAULT_SEED)
    b.add_argument("--db", help=argparse.SUPPRESS)
    s = sub.add_parser("serve", help="serve the review page on 127.0.0.1")
    s.add_argument("--run", type=Path, default=DEFAULT_RUN)
    s.add_argument("--port", type=int, default=DEFAULT_PORT)
    s.add_argument("--host", default="127.0.0.1", help=argparse.SUPPRESS)
    s.add_argument("--open", action="store_true", help="open the page in the default browser")
    args = ap.parse_args(argv)

    if args.command == "build":
        t0 = time.monotonic()
        build(args.results, args.run, args.n, args.seed, args.db)
        print(f"  elapsed {time.monotonic() - t0:.1f} s", flush=True)
        return 0
    server = make_server(args.run, args.host, args.port)
    url = f"http://127.0.0.1:{server.server_address[1]}/"
    print(f"START date_review serve {url}", flush=True)
    if args.open:
        subprocess.Popen(["open", url])
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        print("OUTCOME date_review serve stopped", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
