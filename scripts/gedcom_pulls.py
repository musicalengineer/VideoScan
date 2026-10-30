#!/usr/bin/env python3
"""Which GEDCOM pulls this Mac's family tree was built from, and when each was
exported. Read-only: opens files, writes nothing.

The Family Tree tab shows the same facts under its title ("<Surname> GEDCOM
26 Aug 2026"); the rules here mirror VideoScanCore/GedcomPullFacts.swift and
tests/test_gedcom_pulls.py pins them with the same synthetic cases:

  * export date = `1 DATE` (+ `2 TIME`) directly under `0 HEAD`, GEDCOM
    date_exact "D MON YYYY", month case-insensitive; missing/malformed → None
  * label = surname (between slashes) of the FIRST INDI's first NAME
  * a pull counts only when a file with its name, under the GEDCOM folder
    (recursively), has the SHA-256 the tree recorded; otherwise "not on disk"

Which tree:
  * default        the promoted compiled generation (current.json → manifest),
                   as the app and the nightly Hallie replay ("archive") load it
  * --gedcom PATH  what `--gedcom` hands the Hallie shell: a .ged, or a folder
                   whose newest top-level .ged wins (FamilyGraphFileLoader rule
                   4); a VideoScan merge lists its pulls as `1 _VS_SOURCE` +
                   `2 _VS_SHA256` in HEAD

Output: text lines for a person, or --json. --public keeps only what may go in
the public metrics row (privacy rule 13): per pull the export day, the short
hash and on_disk — no surname, no file name.

Memory: the header read stops at the first INDI's NAME or 8 MiB; hashing
streams 4 MiB chunks.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Iterable, List, Optional, Tuple

# The same override the app's compiled store honours (FamilyGraphCompiledStore
# .compiledRootEnvironmentKey), so a test can point both at a temp folder.
DEFAULT_COMPILED = Path(os.environ.get("VIDEOSCAN_FAMILY_TREE_COMPILED_ROOT")
                        or Path.home() / "Library/Application Support/VideoScan/family-tree/compiled")
BYTE_CAP = 8 << 20
MONTHS = {m: i + 1 for i, m in enumerate(
    ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"])}
MONTH_NAMES = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
_TIME_RE = re.compile(r"^(\d{1,2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?$")


# ---------------------------------------------------------------- header

def parse_export_date(text: Optional[str]) -> Optional[date]:
    """GEDCOM date_exact "D MON YYYY" → date; anything else → None."""
    if not text:
        return None
    parts = text.split()
    if len(parts) != 3:
        return None
    d, mon, y = parts
    if not (1 <= len(d) <= 2 and d.isdigit() and len(y) == 4 and y.isdigit()):
        return None
    month = MONTHS.get(mon.upper())
    if month is None:
        return None
    try:
        return date(int(y), month, int(d))
    except ValueError:
        return None


def parse_time(text: Optional[str]) -> Optional[str]:
    m = _TIME_RE.match((text or "").strip())
    if not m:
        return None
    h, mi, s = int(m.group(1)), int(m.group(2)), int(m.group(3) or 0)
    if h > 23 or mi > 59 or s > 59:
        return None
    return f"{h:02d}:{mi:02d}:{s:02d}"


def surname_of(name: str) -> Optional[str]:
    m = re.search(r"/([^/]*)/", name)
    if not m or not m.group(1).strip():
        return None
    return m.group(1).strip()


def _split(line: str) -> Optional[Tuple[int, str, str]]:
    line = line.lstrip("﻿").lstrip(" \t")
    fields = line.split(" ", 1)
    if len(fields) != 2 or not fields[0].isdigit():
        return None
    level, rest = int(fields[0]), fields[1].lstrip(" ")
    if rest.startswith("@"):
        sub = rest.split(" ", 1)
        if len(sub) != 2:
            return None
        rest = sub[1].lstrip(" ")
    tag, _, value = rest.partition(" ")
    return level, tag.upper(), value.strip()


def header_facts_from_lines(lines: Iterable[str]) -> dict:
    facts = {"date": None, "time": None, "program": None, "surname": None, "vs_sources": []}
    section, head_seen, indi_seen, level1 = "pre", False, False, None
    date_text = time_text = None
    for raw in lines:
        parsed = _split(raw.rstrip("\r\n"))
        if parsed is None:
            continue
        level, tag, value = parsed
        if level == 0:
            if section == "indi":
                break
            if tag == "HEAD" and not head_seen:
                section, head_seen = "head", True
            elif tag == "INDI" and not indi_seen:
                section, indi_seen = "indi", True
            else:
                section = "other"
            continue
        if section == "head":
            if level == 1:
                level1 = tag
                if tag == "DATE" and date_text is None:
                    date_text = value
                elif tag == "SOUR" and facts["program"] is None and value:
                    facts["program"] = value
                elif tag == "_VS_SOURCE":
                    facts["vs_sources"].append([value, None])
            elif level == 2 and level1 == "DATE" and tag == "TIME" and time_text is None:
                time_text = value
            elif level == 2 and level1 == "_VS_SOURCE" and tag == "_VS_SHA256" and value:
                facts["vs_sources"][-1][1] = value.lower()
        elif section == "indi" and level == 1 and tag == "NAME":
            facts["surname"] = surname_of(value)
            break
    d = parse_export_date(date_text)
    facts["date"] = d.isoformat() if d else None
    facts["time"] = parse_time(time_text) if d else None
    return facts


def _read_lines(path: Path, byte_cap: int) -> Iterable[str]:
    """Lines split on CR, LF or CRLF, read in 64 KiB chunks up to `byte_cap`;
    a line is truncated at 64 KiB (bounded memory even for a CR-only file)."""
    pending, read = b"", 0
    with open(path, "rb") as fh:
        while read < byte_cap:
            chunk = fh.read(min(64 << 10, byte_cap - read))
            if not chunk:
                break
            read += len(chunk)
            pieces = (pending + chunk).replace(b"\r\n", b"\n").replace(b"\r", b"\n").split(b"\n")
            pending = pieces.pop()[: 64 << 10]
            for piece in pieces:
                if piece:
                    yield piece[: 64 << 10].decode("utf-8", "replace")
    if pending:
        yield pending.decode("utf-8", "replace")


def header_facts(path: Path, byte_cap: int = BYTE_CAP) -> dict:
    return header_facts_from_lines(_read_lines(path, byte_cap))


def day_text(iso: Optional[str]) -> Optional[str]:
    if not iso:
        return None
    d = date.fromisoformat(iso)
    return f"{d.day} {MONTH_NAMES[d.month - 1]} {d.year}"


# ---------------------------------------------------------------- files

def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(4 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def ged_files_by_name(roots: Iterable[Path], max_entries: int = 20_000) -> dict:
    out: dict = {}
    seen, visited = set(), 0
    for root in roots:
        if not root.is_dir():
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
            for name in sorted(filenames):
                visited += 1
                if visited > max_entries:
                    return out
                if name.startswith(".") or not name.lower().endswith(".ged"):
                    continue
                p = Path(dirpath) / name
                if p.is_symlink() or not p.is_file():
                    continue
                key = str(p.resolve())
                if key in seen:
                    continue
                seen.add(key)
                out.setdefault(name, []).append(p)
    return out


def describe(sources: List[Tuple[str, str]], roots: List[Path]) -> List[dict]:
    index = ged_files_by_name(roots)
    pulls = []
    for name, sha in sources:
        sha = sha.lower()
        entry = {"file": name, "sha": sha[:8], "on_disk": False, "label": None,
                 "date": None, "time": None, "program": None}
        for p in index.get(name, []):
            try:
                if sha256_file(p) != sha:
                    continue
            except OSError:
                continue
            facts = header_facts(p)
            entry.update(on_disk=True, label=facts["surname"], date=facts["date"],
                         time=facts["time"], program=facts["program"], path=str(p))
            break
        pulls.append(entry)
    return pulls


# ---------------------------------------------------------------- which tree

def from_compiled(root: Path) -> dict:
    try:
        pointer = json.loads((root / "current.json").read_text())
        manifest = json.loads((root / pointer["current"] / "manifest.json").read_text())
    except (OSError, ValueError, KeyError, TypeError):
        return {"status": "no-tree", "source": "compiled", "pulls": []}
    logical = [(s["fileName"], s["sha256"]) for s in manifest.get("logicalSources") or [] if s.get("sha256")]
    physical = [(s["fileName"], s["sha256"]) for s in manifest.get("sources") or [] if s.get("sha256")]
    roots = []
    for s in manifest.get("sources") or []:
        parent = Path(s.get("path", "")).parent
        if str(parent) not in map(str, roots):
            roots.append(parent)
    return {"status": "ok", "source": "compiled", "generation": manifest.get("generation"),
            "ingest": manifest.get("createdAt"),
            "pulls": describe(logical or physical, roots)}


def newest_ged(folder: Path) -> Optional[Path]:
    files = [p for p in folder.iterdir()
             if p.suffix.lower() == ".ged" and not p.name.startswith(".") and p.is_file() and not p.is_symlink()]
    if not files:
        return None
    return sorted(files, key=lambda p: (p.stat().st_mtime, p.name), reverse=True)[0]


def from_gedcom(path: Path) -> dict:
    tree = newest_ged(path) if path.is_dir() else path
    if tree is None or not tree.is_file():
        return {"status": "no-tree", "source": "gedcom", "pulls": []}
    folder = path if path.is_dir() else path.parent
    facts = header_facts(tree)
    listed = [(n, s) for n, s in facts["vs_sources"] if n and s]
    sources = listed or [(tree.name, sha256_file(tree))]
    return {"status": "ok", "source": "gedcom", "generation": None, "ingest": None,
            "tree_file": tree.name, "pulls": describe(sources, [folder])}


def public(result: dict) -> dict:
    """Only what may be published (privacy rule 13): no surname, no file name."""
    return {"status": result["status"],
            "pulls": [{"date": p["date"], "sha": p["sha"], "on_disk": p["on_disk"]} for p in result["pulls"]]}


def text_lines(result: dict) -> List[str]:
    if result["status"] != "ok":
        return [f"no readable tree ({result['source']})"]
    out = []
    for p in result["pulls"]:
        if p["on_disk"]:
            when = day_text(p["date"]) or "no date in file"
            out.append(f"{p['label'] or '(no label)'} GEDCOM {when}{' ' + p['time'] if p['time'] else ''}"
                       f" · {p['sha']} · {p['file']}")
        else:
            out.append(f"NOT ON DISK · {p['sha']} · {p['file']}")
    if result.get("generation"):
        out.append(f"generation {result['generation']} ingested {result.get('ingest')}")
    return out


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--compiled-root", type=Path, default=DEFAULT_COMPILED)
    ap.add_argument("--gedcom", type=Path, help="tree file or folder, as given to the Hallie shell")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--public", action="store_true", help="drop surnames and file names")
    args = ap.parse_args(argv)
    result = from_gedcom(args.gedcom) if args.gedcom else from_compiled(args.compiled_root)
    if args.public:
        result = public(result)
    if args.json or args.public:
        print(json.dumps(result, separators=(",", ":")))
    else:
        print("\n".join(text_lines(result)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
