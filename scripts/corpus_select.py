#!/usr/bin/env python3
"""corpus_select.py — which real files make the M4's real-data corpus: a stratified SAMPLE.

DECISIONS 2026-11-17 (the M4 holds a real-data corpus), 2026-11-19 (two roots, the wish list) and
2026-11-24 ("Disk budgets per drive…": the corpus is a stratified SAMPLE, ~12% of each stratum, not a
copy of everything; what fits neither drive is read read-only from the Ultra; shrinking deletes a
dropped copy only after a green run on the new sample). The v2 rule this file held until 2026-11-24
(every content under 8 GB, one large file per codec mix; `grow` never removed anything) is retired.

    corpus_select.py select --catalog <catalog .backup> --current <corpus-manifest-v2.json> --out <folder>
                            [--pins <pins.json>] [--assume-readable]
    corpus_select.py plan-shrink --sample <new manifest> [--current <manifest>] --out <folder>    (on the M4)
    corpus_select.py apply-shrink --plan <shrink-plan.json> --after-green <check run stamp>      (on the M4)

select — THE RULES (each one is a test in tests/test_corpus_select.py):
  1. the universe: every distinct content_digest of the catalog's live rows (removal_state IS NULL)
     with a size. Its path: the current manifest's (its copy already sits there) — else one readable
     /Volumes path, away from /Volumes/FamilyArchive/ (the Master Archive), then the smallest path.
     A content with neither is counted ("no readable copy"), never guessed.
  2. its STRATUM: (container, video_codec, audio_codec) plus the odd-case flags the catalog can state
     (`flags_of`): no_audio, sound_short, odd_rate, odd_size, damaged, very_short (< 5 s), very_long (> 2 h).
  3. per stratum: ceil(12%) of its members, at least 3; a stratum of 3 or fewer is taken whole (`quota`).
  4. the picks are SPREAD (`spread`): the stratum, smallest first, is cut into as many bins as picks are
     wanted, one pick per bin; inside a bin the source volume picked least so far wins, then a member whose
     copy is already made, then the member nearest the bin's middle, then the smallest digest. Deterministic: the same catalog, the same sample.
  5. ALWAYS taken, and counted toward their stratum's quota: every pin (--pins, default
     scripts/corpus_pins.json: files a bug or a regression test is tied to) and every current row whose
     `why` is a hand-curated case (v1's "one-sided sound", "raw DV", "Avid video half", …: anything but
     the generic whys in GENERIC_WHYS). The proof lane and the balanced-copy findings rest on those.
  6. ROOTS (`place`): a pick whose copy already sits on internal/external keeps that root while the root's
     budget holds (moving a copy is churn and reads `vanished`). The rest, smallest first: a file under
     8 GB goes to EXTERNAL (the Crucial X10, EXTERNAL_BUDGET), else INTERNAL; a file of 8 GB or more to
     INTERNAL (the M4's SSD, INTERNAL_BUDGET) only if it fits, else EXTERNAL; what fits neither is `ro`:
     read from its original path on the Ultra's drives over a read-only share (not mounted yet: a run
     counts those files NOT RUN, as it does an unplugged external volume).
  The catalog is opened read-only and immutable: nothing is written beside it.
  It writes into <folder>: corpus-manifest-v2.json (the sample: every row {sha256, path, size, why, root,
  stratum}; install it as ~/corpus/corpus-manifest-v2.json), selection.json ({root: [[digest, path, size]…]}
  of the files a root does not hold yet), and v2_<root>.sha / v2_<root>.files for internal and external
  (the copies still to make: `shasum -a 256 -c` from the root's media folder; rsync --files-from, from /).
  --assume-readable: every /Volumes path counts as readable — for a size ESTIMATE on a Mac that cannot
  read the Ultra's drives (the M4); said on every line it prints; its lists are not for copying.

plan-shrink / apply-shrink: scripts/corpus_shrink.py (the plan lists the copies the sample dropped and
deletes nothing; apply deletes them only after a GREEN check run on the installed sample).

PRIVACY. What this prints is counts and bytes only. Its outputs hold real paths: they are written to
the folder named, which must not be in the repository (refused), and never go into git.

Memory: one tuple per live catalog row (~11k rows: a few MB) plus each digest's flags.
Python 3.9 (the M4's /usr/bin/python3) is the floor.
"""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
import urllib.parse
from collections import Counter, defaultdict
from pathlib import Path
from typing import Callable, Dict, Iterable, List, NamedTuple, Optional, Set, Tuple

SAMPLE_PERCENT = 12                               # rule 3 (Rick: "say 10-15%")
SAMPLE_FLOOR = 3                                  # rule 3: at least this many; a stratum this small is taken whole
SPLIT_BYTES = 8_000_000_000                       # rule 6: "large" (decimal GB)
# Rule 6, the budgets (DECISIONS 2026-11-24). The X10 is 2 TB (1.8 TiB formatted): the sample's copies rest
# under 90% of it. The SSD gives the testbed ~500 GB in all: 400 GB of copies leaves 100 GB for a run's
# scratch (the proof lane's balanced copies, the verbs lane's 20 GB floor, the per-run DerivedData).
EXTERNAL_BUDGET = 1_800_000_000_000
INTERNAL_BUDGET = 400_000_000_000
ROOTS = ("internal", "external", "ro")
ARCHIVE_PREFIX = "/Volumes/FamilyArchive/"        # rule 1: a copy here is the last choice
SHORT_SECONDS, LONG_SECONDS = 5.0, 7200.0         # rule 2: very short, very long
# Rule 2, "odd": a picture whose frame rate or size is none of the standard ones. The sizes include
# 1920x1440 (4:3 at 1440 lines: the commonest picture size in this catalog, 2026-11-24, so not odd here).
STANDARD_RATES = (23.976, 24.0, 25.0, 29.97, 30.0, 50.0, 59.94, 60.0)
STANDARD_SIZES = frozenset({"640x480", "704x480", "720x480", "720x486", "704x576", "720x576", "1280x720",
                            "1440x1080", "1920x1080", "1920x1440", "3840x2160", "4096x2160"})
DAMAGED_STREAMS = frozenset({"ffprobe failed", "No A/V streams"})          # files.stream_type
DAMAGED_PLAYABLE = frozenset({"Damaged file", "No streams"})               # probe_extra.isPlayable
DAMAGED_CHECKS = frozenset({"damaged", "broken"})                          # media_checks.status
WHY_SAMPLE, WHY_PINNED = "sample", "pinned"
FLAGS = ("no_audio", "sound_short", "odd_rate", "odd_size", "damaged", "very_short", "very_long")
# Rule 5: the whys that say "picked by a rule", not "picked by hand for what it is".
# `pinned` is generic too: a pin is always taken while it is IN the pins file, and once taken out of it
# the file is sampled like any other (reviewer 2026-11-24).
GENERIC_WHYS = frozenset({"", "codec/container combo", "v2 every content under 8 GB",
                          "v2 large, one per container and codecs", WHY_SAMPLE, WHY_PINNED})
REPO = Path(__file__).resolve().parents[1]
PINS = REPO / "scripts" / "corpus_pins.json"

# (rowid, digest, full_path, size, container, video_codec, audio_codec, stream_type, duration_s, probe_extra)
Row = Tuple
Pick = Tuple[str, str, int]                        # (digest, path, size)


class Refused(Exception):
    """A precondition said no. The message carries no path."""


class Candidate(NamedTuple):
    digest: str
    path: str
    size: int
    stratum: Tuple[str, ...]
    volume: str                                   # the source volume's name (in memory only; never printed)
    root: Optional[str] = None                    # the root its copy already sits on (current manifest), if any


def readable(path: str) -> bool:
    return os.path.isfile(path) and os.access(path, os.R_OK)


def placeable(path: str) -> bool:
    """A path copy_place accepts: absolute under /Volumes/, no `..`."""
    return path.startswith("/Volumes/") and ".." not in path.split("/")


def volume_of(path: str) -> str:
    parts = path.split("/")
    return parts[2] if len(parts) > 2 else ""


# ── The catalog, read-only ────────────────────────────────────────────────

class Evidence(NamedTuple):
    rows: List[Row]
    sound: Dict[str, Set[str]]                    # digest -> sound_attempts.outcome words
    checks: Dict[str, Set[str]]                   # digest -> media_checks.status words
    missing: List[str]                            # the columns/tables this catalog does not have


def _open(catalog: Path) -> sqlite3.Connection:
    for suffix in ("-wal", "-journal"):
        if os.path.exists(str(catalog) + suffix):
            raise Refused(f"refused: the catalog has a {suffix} file beside it — give it a finished .backup")
    uri = "file:" + urllib.parse.quote(str(Path(catalog).resolve())) + "?immutable=1"
    return sqlite3.connect(uri, uri=True)


def _columns(conn: sqlite3.Connection, table: str) -> List[str]:
    return [r[1] for r in conn.execute(f"PRAGMA table_info({table})")]


def catalog_evidence(catalog: Path) -> Evidence:
    """The live rows and the odd-case evidence, through an immutable read-only open (no sidecar is made).
    A column or table this catalog does not have reads as unknown and is listed in `missing`."""
    conn = _open(catalog)
    try:
        have = set(_columns(conn, "files"))
        missing = []
        picked = []
        for name in ("stream_type", "duration_s", "probe_extra"):
            if name in have:
                picked.append(name)
            else:
                picked.append("NULL")
                missing.append("files." + name)
        rows = conn.execute(
            "SELECT rowid, content_digest, full_path, size_bytes, container, video_codec, audio_codec, "
            + ", ".join(picked) + " FROM files "
            "WHERE removal_state IS NULL AND content_digest IS NOT NULL AND full_path IS NOT NULL ORDER BY rowid").fetchall()
        sound: Dict[str, Set[str]] = defaultdict(set)
        checks: Dict[str, Set[str]] = defaultdict(set)
        for table, column, into in (("sound_attempts", "outcome", sound), ("media_checks", "status", checks)):
            if not {"digest", column} <= set(_columns(conn, table)):
                missing.append(f"{table}.{column}")
                continue
            for digest, word in conn.execute(f"SELECT digest, {column} FROM {table} WHERE digest IS NOT NULL"):
                into[str(digest).lower()].add(str(word))
        return Evidence(rows, dict(sound), dict(checks), missing)
    finally:
        conn.close()


def catalog_rows(catalog: Path) -> List[Row]:
    return catalog_evidence(catalog).rows


# ── The rule, pure ────────────────────────────────────────────────────────

def _probe(extra) -> dict:
    try:
        value = json.loads(extra) if isinstance(extra, str) else {}
    except ValueError:
        return {}
    return value if isinstance(value, dict) else {}


def flags_of(stream_type: Optional[str], duration: Optional[float], probe_extra: Optional[str],
             video_codec: Optional[str] = None, audio_codec: Optional[str] = None,
             sound: Iterable[str] = (), checks: Iterable[str] = ()) -> Tuple[str, ...]:
    """Rule 2: the odd cases this content's catalog facts state, in FLAGS order. Unknown is not odd:
    a fact the catalog does not hold raises no flag."""
    probe, sound, checks = _probe(probe_extra), set(sound), set(checks)
    video = stream_type in ("Video only", "Video+Audio") if stream_type is not None else bool(video_codec)
    no_audio = stream_type == "Video only" if stream_type is not None else bool(video_codec) and not audio_codec
    found = set()
    if no_audio:
        found.add("no_audio")
    if "heardTooLittle" in sound:
        found.add("sound_short")
    if video and probe:
        try:
            rate = float(probe.get("frameRate") or "nan")
        except (TypeError, ValueError):
            rate = float("nan")
        if not any(abs(rate - standard) < 0.01 for standard in STANDARD_RATES):
            found.add("odd_rate")
        if str(probe.get("resolution") or "") not in STANDARD_SIZES:
            found.add("odd_size")
    if (stream_type in DAMAGED_STREAMS or probe.get("isPlayable") in DAMAGED_PLAYABLE
            or checks & DAMAGED_CHECKS or "failed" in sound):
        found.add("damaged")
    if isinstance(duration, (int, float)) and 0 < duration < SHORT_SECONDS:
        found.add("very_short")
    if isinstance(duration, (int, float)) and duration > LONG_SECONDS:
        found.add("very_long")
    return tuple(f for f in FLAGS if f in found)


def quota(n: int) -> int:
    """Rule 3: ceil(12%), at least 3; a stratum of 3 or fewer whole."""
    if n <= SAMPLE_FLOOR:
        return n
    return max(SAMPLE_FLOOR, -(-n * SAMPLE_PERCENT // 100))


def spread(members: List[Candidate], k: int, taken: Iterable[Candidate] = ()) -> List[Candidate]:
    """Rule 4: k picks in all (the `taken` ones count), spread over size bins and source volumes; inside a bin,
    after the volume, a file whose copy is already made wins (a re-select over a newer catalog keeps it)."""
    taken = list(taken)
    held = {c.digest for c in taken}
    pool = sorted((c for c in members if c.digest not in held), key=lambda c: (c.size, c.digest))
    need = k - len(taken)
    if need <= 0:
        return []
    if need >= len(pool):
        return pool
    uses = Counter(c.volume for c in taken)
    picks = []
    for i in range(need):
        lo, hi = i * len(pool) // need, (i + 1) * len(pool) // need
        middle = (lo + hi - 1) / 2
        best = min(range(lo, hi), key=lambda j: (uses[pool[j].volume], pool[j].root is None, abs(j - middle), pool[j].digest))
        picks.append(pool[best])
        uses[pool[best].volume] += 1
    return picks


def sample(candidates: Iterable[Candidate], always: Iterable[str] = ()) -> List[Candidate]:
    """Rules 3-5 over the candidates: per stratum its quota, the always-taken counted first."""
    always = set(always)
    strata: Dict[Tuple[str, ...], List[Candidate]] = defaultdict(list)
    for c in candidates:
        strata[c.stratum].append(c)
    chosen = []
    for key in sorted(strata):
        members = strata[key]
        taken = sorted((c for c in members if c.digest in always), key=lambda c: c.digest)
        chosen += taken + spread(members, quota(len(members)), taken)
    return sorted(chosen, key=lambda c: c.digest)


def place(picks: Iterable[Candidate], internal_budget: int = INTERNAL_BUDGET,
          external_budget: int = EXTERNAL_BUDGET) -> Dict[str, str]:
    """Rule 6: digest -> root. Copies already in place first (they keep their root while it has room),
    then the rest smallest first; what fits neither copy root is `ro`."""
    budget = {"internal": internal_budget, "external": external_budget}
    spent = {"internal": 0, "external": 0}
    roots: Dict[str, str] = {}
    rest = []
    for c in sorted(picks, key=lambda c: (c.root not in budget, c.size, c.digest)):
        if c.root in budget and spent[c.root] + c.size <= budget[c.root]:
            spent[c.root] += c.size
            roots[c.digest] = c.root
        else:
            rest.append(c)
    for c in sorted(rest, key=lambda c: (c.size, c.digest)):
        order = ("internal", "external") if c.size >= SPLIT_BYTES else ("external", "internal")
        root = next((r for r in order if spent[r] + c.size <= budget[r]), "ro")
        if root != "ro":
            spent[root] += c.size
        roots[c.digest] = root
    return roots


def _pad(row) -> tuple:
    return tuple(row) + (None,) * (10 - len(row))


def candidates_of(rows: Iterable[Row], current: List[dict], can_read: Callable[[str], bool],
                  sound: Dict[str, Set[str]], checks: Dict[str, Set[str]],
                  stats: Dict[str, int]) -> Dict[str, Candidate]:
    """Rule 1 and 2: one candidate per live digest with a size, its path and stratum."""
    have = {str(r["sha256"]).lower(): r for r in current}
    by_digest: Dict[str, List[tuple]] = defaultdict(list)
    for row in rows:
        row = _pad(row)
        if row[3] is None:
            stats["no_size"] += 1
            continue
        by_digest[str(row[1]).lower()].append(row)
    out: Dict[str, Candidate] = {}
    for digest, group in by_digest.items():
        facts = min(group, key=lambda r: r[0])                       # the digest's first live row states its facts
        known = have.get(digest)
        if known is not None and placeable(str(known["path"])):
            path, size, root = str(known["path"]), int(known["size"]), str(known.get("root", "internal"))
        else:
            readable_rows = [r for r in group if placeable(r[2]) and can_read(r[2])]
            if not readable_rows:
                stats["unreadable"] += 1
                continue
            preferred = [r for r in readable_rows if not r[2].startswith(ARCHIVE_PREFIX)] or readable_rows
            chosen = min(preferred, key=lambda r: r[2])
            path, size, root = chosen[2], int(chosen[3]), None
        flags = flags_of(facts[7], facts[8], facts[9], facts[5], facts[6], sound.get(digest, ()), checks.get(digest, ()))
        out[digest] = Candidate(digest, path, size, (facts[4] or "", facts[5] or "", facts[6] or "") + flags,
                                volume_of(path), root if root in ("internal", "external") else None)
    return out


def load_pins(path: Optional[Path]) -> Dict[str, str]:
    """{sha256: why} from a pins file: {"pins": [{"sha256": …, "why": "<the test or issue>"}…]}."""
    if path is None or not Path(path).exists():
        return {}
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
        pins = {str(p["sha256"]).lower(): str(p.get("why", "")) for p in value["pins"]}
    except (OSError, ValueError, KeyError, TypeError):
        raise Refused("refused: the pins file is not {\"pins\": [{\"sha256\": …, \"why\": …}]}")
    if not all(len(d) == 64 and all(ch in "0123456789abcdef" for ch in d) for d in pins):
        raise Refused("refused: a pin is not a SHA-256")
    return pins


def select(rows: Iterable[Row], current: List[dict], can_read: Callable[[str], bool] = readable,
           pins: Optional[Dict[str, str]] = None, sound: Optional[Dict[str, Set[str]]] = None,
           checks: Optional[Dict[str, Set[str]]] = None, internal_budget: int = INTERNAL_BUDGET,
           external_budget: int = EXTERNAL_BUDGET, stats: Optional[Dict[str, int]] = None) -> List[dict]:
    """The sample manifest: the rules above as a pure function (`can_read` is the one question asked
    of the disk). `stats` gets: unreadable, no_size, pins_not_found, strata."""
    stats = {} if stats is None else stats
    stats.update(unreadable=0, no_size=0, pins_not_found=0)
    pins = pins or {}
    cands = candidates_of(rows, current, can_read, sound or {}, checks or {}, stats)
    stats["strata"] = len({c.stratum for c in cands.values()})
    curated = {str(r["sha256"]).lower(): r for r in current if str(r.get("why", "")) not in GENERIC_WHYS}
    always = set(pins) | set(curated)
    picked = {c.digest: c for c in sample(cands.values(), always)}
    # Always taken although the catalog no longer holds them live: from the current manifest's row.
    for digest in sorted(always - set(picked)):
        row = curated.get(digest) or next((r for r in current if str(r["sha256"]).lower() == digest), None)
        if row is None or not placeable(str(row["path"])):
            stats["pins_not_found"] += 1
            continue
        stratum = tuple(row["stratum"]) if isinstance(row.get("stratum"), list) else ("not in the catalog",)
        root = str(row.get("root", "internal"))
        picked[digest] = Candidate(digest, str(row["path"]), int(row["size"]), stratum, volume_of(str(row["path"])),
                                   root if root in ("internal", "external") else None)
    roots = place(picked.values(), internal_budget, external_budget)
    whys = {str(r["sha256"]).lower(): str(r.get("why", "")) for r in current}
    out = []
    for digest in sorted(picked):
        c = picked[digest]
        copy_place(c.path)
        why = whys.get(digest) or (WHY_PINNED if digest in pins else WHY_SAMPLE)
        out.append({"sha256": digest, "path": c.path, "size": c.size, "why": why, "root": roots[digest],
                    "stratum": list(c.stratum)})
    return out


def to_copy(sample_rows: List[dict], current: List[dict]) -> Dict[str, List[Pick]]:
    """Per copy root, the sample's files that root does not hold yet (by the current manifest)."""
    held = {(str(r["sha256"]).lower(), str(r.get("root", "internal"))) for r in current}
    out: Dict[str, List[Pick]] = {root: [] for root in ROOTS}
    for r in sample_rows:
        if (r["sha256"], r["root"]) not in held:
            out[r["root"]].append((r["sha256"], r["path"], int(r["size"])))
    return out


def copy_place(original: str) -> str:
    """Where a copy sits under its root's media folder: the original path less its leading slash."""
    if not placeable(original):
        raise Refused("refused: a chosen path is not an absolute /Volumes path")
    return original.lstrip("/")


def outside_repo(out: Path) -> Path:
    out = Path(out)
    if out.resolve() == REPO or REPO in out.resolve().parents:
        raise Refused("refused: the output names real files — write it outside the repository")
    return out


def write_selection(selection: Dict[str, List[Pick]], out: Path) -> None:
    """selection.json (every root) and, per copy root, its SHA-256 list and rsync list."""
    out = outside_repo(out)
    out.mkdir(parents=True, exist_ok=True)
    for root in ("internal", "external"):
        picks = selection.get(root, [])
        (out / f"v2_{root}.sha").write_text("".join(f"{d}  {copy_place(p)}\n" for d, p, _ in picks))
        (out / f"v2_{root}.files").write_text("".join(f"{copy_place(p)}\n" for _, p, _ in picks))
    (out / "selection.json").write_text(json.dumps({k: [list(p) for p in v] for k, v in selection.items()}) + "\n")


def write_whole(path: Path, text: str) -> None:
    """Whole or not at all: a new file beside it, renamed into place (Codex #336 F1)."""
    pending = path.with_name(f".{path.name}.{os.getpid()}")
    pending.write_text(text)
    os.replace(str(pending), str(path))


def totals(rows: Iterable[dict]) -> Dict[str, Tuple[int, int]]:
    """{root: (files, bytes)}."""
    out = {root: [0, 0] for root in ROOTS}
    for r in rows:
        root = str(r.get("root", "internal"))
        if root in out:
            out[root][0] += 1
            out[root][1] += int(r["size"])
    return {k: (v[0], v[1]) for k, v in out.items()}


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="corpus_select.py", description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    choose = sub.add_parser("select")
    choose.add_argument("--catalog", required=True)
    choose.add_argument("--current", required=True, help="the corpus manifest the copies were made from")
    choose.add_argument("--out", required=True)
    choose.add_argument("--pins", default=str(PINS))
    choose.add_argument("--assume-readable", action="store_true")
    planning = sub.add_parser("plan-shrink")
    planning.add_argument("--sample", required=True)
    planning.add_argument("--current")
    planning.add_argument("--out", required=True)
    applying = sub.add_parser("apply-shrink")
    applying.add_argument("--plan", required=True)
    applying.add_argument("--after-green", required=True, dest="after_green")
    args = parser.parse_args(argv)
    try:
        if args.command in ("plan-shrink", "apply-shrink"):
            import corpus_shrink                           # the deletion lives apart: its own review scope
            return corpus_shrink.main(args)
        tag = "corpus select" + (" ESTIMATE (every /Volumes path assumed readable; not for copying)" if args.assume_readable else "")
        current = json.loads(Path(args.current).read_text(encoding="utf-8"))
        evidence = catalog_evidence(Path(args.catalog))
        stats: Dict[str, int] = {}
        rows = select(evidence.rows, current, (lambda p: True) if args.assume_readable else readable,
                      pins=load_pins(Path(args.pins)), sound=evidence.sound, checks=evidence.checks, stats=stats)
        out = outside_repo(Path(args.out))
        write_selection(to_copy(rows, current), out)
        write_whole(out / "corpus-manifest-v2.json", json.dumps(rows, indent=0) + "\n")
        before, after = totals(current), totals(rows)
        print(f"{tag}: {len(current)} -> {len(rows)} files; {stats['strata']} strata")
        for root in ROOTS:
            print(f"{tag}: {root} {before[root][0]} files {before[root][1] / 1e9:.1f} GB -> "
                  f"{after[root][0]} files {after[root][1] / 1e9:.1f} GB")
        copying = to_copy(rows, current)
        for root in ("internal", "external"):
            print(f"{tag}: {root} to copy {len(copying[root])} files {sum(p[2] for p in copying[root]) / 1e9:.1f} GB")
        if stats["unreadable"]:
            print(f"{tag}: {stats['unreadable']} contents skipped: no readable copy")
        if stats["no_size"]:
            print(f"{tag}: {stats['no_size']} rows skipped: no size_bytes")
        if stats["pins_not_found"]:
            print(f"{tag}: {stats['pins_not_found']} pinned or curated contents not found (no live row, no manifest row)")
        if evidence.missing:
            print(f"{tag}: not in this catalog (read as unknown): {', '.join(evidence.missing)}")
    except Refused as refusal:
        print(f"corpus select: RED {refusal}")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
