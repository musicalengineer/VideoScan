#!/usr/bin/env python3
"""corpus_shrink.py — the corpus copies the stratified sample dropped: planned, then deleted after green.

DECISIONS 2026-11-24 ("Disk budgets per drive…"): the M4's corpus becomes a stratified sample
(scripts/corpus_select.py select); "shrinking the copy deletes a dropped file only after a run on the
new sample is green; originals are never touched". Run on the M4, through corpus_select.py:

    corpus_select.py plan-shrink --sample <new manifest> [--current <manifest>] --out <folder>
    corpus_select.py apply-shrink --plan <folder>/shrink-plan.json --after-green <check run stamp>

plan — READ ONLY. Every row of the current manifest (default: the one installed in ~/corpus) whose copy
  root is internal or external and that the sample does not hold on that root — neither its SHA-256 there
  nor its place — and whose copy is THERE (a regular file of the manifest's size at its place) is listed.
  Written to <folder>/shrink-plan.json (the places are real paths: <folder> is refused inside the
  repository and inside the corpus's pristine parts); printed: files and GB per root, and how many
  dropped rows have no copy to delete (never copied) or could not be looked at (the external volume away).
  Deletes nothing.

apply — THE ONLY DELETION. Refused unless ALL of:
  1. the seal (corpus_run.Seal.check: the M4, the marked ~/corpus, its folders themselves);
  2. the manifest installed in ~/corpus is, byte for byte, the sample the plan was made for (SHA-256);
  3. <stamp> names exactly one stored run of the CHECK lane (every present file through every engine) and
     that run: had its engine, was not SMOKE nor --limit, is GREEN (corpus_run.verdict_of over its own
     stored diff), read THIS manifest (its `manifest_sha256`), and found every sample file present —
     nothing missing, NOT RUN, mismatched, vanished or changed in any root.
  Then per planned file, each answered by a word and counted (never a path):
     kept_in_sample  the installed sample names it on that root (by SHA-256 or by place): never deleted;
     not_mounted     its root is the external volume and that is not proven now (Seal.external);
     absent          nothing at its place;
     refused_*       a link on the way, not a regular file, another volume, a second name (hard link),
                     a lock flag, or not the planned size: left as it is;
     deleted         unlinked through folder descriptors from the root's media folder down
                     (C++: openat/unlinkat), never following a link nor leaving the root's device.
  The ro root is never deleted from (it holds no copy). Folders the deletion leaves empty go too, up to
  (never including) the root's media folder. A receipt line (counts and bytes only) is appended to
  ~/corpus/state/shrink-history.jsonl. The originals are never named: a place is always relative to a
  root's media folder, ~/corpus/media or <the adopted X10>/corpus/media.

PRIVACY. Prints counts, bytes and words only. Memory: the two manifests (~6,400 rows, a few MB).
Python 3.9 is the floor.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import stat
import sys
import time
from collections import Counter
from pathlib import Path
from typing import Dict, List, Optional, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
import corpus_run as cr  # noqa: E402

COPY_ROOTS = ("internal", "external")
PLAN = "shrink-plan.json"
HISTORY = "shrink-history.jsonl"
LOCK_FLAGS = getattr(stat, "UF_IMMUTABLE", 0x2) | getattr(stat, "SF_IMMUTABLE", 0x20000) \
    | getattr(stat, "UF_APPEND", 0x4) | getattr(stat, "SF_APPEND", 0x40000)
Refused = cr.Refused


def _rows(value) -> List[dict]:
    if not isinstance(value, list) or not all(isinstance(r, dict) and "sha256" in r and "path" in r for r in value):
        raise Refused("refused: a manifest is not a list of corpus rows")
    return value


def place_of(original: str) -> str:
    """A copy's place under its root's media folder: the original /Volumes path less its leading slash."""
    if not original.startswith("/Volumes/") or ".." in original.split("/"):
        raise Refused("refused: a manifest row is not an original /Volumes path")
    return original.lstrip("/")


def _holds(sample: List[dict]) -> Tuple[set, set]:
    """What the sample keeps on each copy root: (sha, root) pairs and (root, place) pairs."""
    keys, places = set(), set()
    for r in sample:
        root = str(r.get("root", "internal"))
        keys.add((str(r["sha256"]).lower(), root))
        places.add((root, place_of(str(r["path"]))))
    return keys, places


def media_of(seal: cr.Seal, root: str) -> Optional[Path]:
    """A copy root's media folder, proven; None when the external volume is not proven now."""
    if root == "internal":
        return seal.media
    if root == "external":
        external = seal.external()
        return external.media if external.state == "ok" else None
    raise Refused("refused: only the internal and external roots hold copies")


def plan(seal: cr.Seal, current: List[dict], sample: List[dict]) -> Tuple[dict, Dict[str, Counter]]:
    """(the plan, counts per root). Pure but for a stat of each dropped copy's place."""
    keys, places = _holds(_rows(sample))
    files, counts = [], {root: Counter() for root in COPY_ROOTS}
    for r in _rows(current):
        root, sha = str(r.get("root", "internal")), str(r["sha256"]).lower()
        if root not in COPY_ROOTS:
            continue
        rel = place_of(str(r["path"]))
        if (sha, root) in keys or (root, rel) in places:
            continue
        media = media_of(seal, root)
        if media is None:
            counts[root]["not_mounted"] += 1
            continue
        try:
            info = os.lstat(str(media / rel))
        except OSError:
            info = None
        if info is None or not stat.S_ISREG(info.st_mode) or info.st_size != int(r["size"]):
            counts[root]["no_copy"] += 1
            continue
        counts[root]["files"] += 1
        counts[root]["bytes"] += int(r["size"])
        files.append({"sha256": sha, "root": root, "place": rel, "size": int(r["size"])})
    return {"version": 1, "sample_sha256": "", "files": files}, counts


def _digest(path: Path) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def _plain_place(rel) -> bool:
    if not isinstance(rel, str) or not rel.startswith("Volumes/"):
        return False
    return all(part not in ("", ".", "..") for part in rel.split("/"))


def green_run(seal: cr.Seal, stamp: str, manifest_sha256: str) -> str:
    """The stored check run `stamp`, proven GREEN over this very manifest with every file present.
    Returns its name; Refused (saying which condition failed) otherwise."""
    if not re.fullmatch(r"[0-9A-Za-z_]+", stamp or ""):
        raise Refused("refused: --after-green is a check run's stamp (letters, digits and underscores)")
    runs = [run for run in cr.lane_runs(seal, "check") if run.name == stamp]
    if len(runs) != 1:
        raise Refused(f"refused: no single stored check run is named {cr.word(stamp)}")
    try:
        raw = json.loads((runs[0] / "report.json").read_text(encoding="utf-8"))
        report = cr.clean_report(raw)
    except (OSError, ValueError):
        raise Refused("refused: that check run's report cannot be read back")
    against = raw.get("against") if isinstance(raw.get("against"), dict) else None
    why = None
    if not report["engine_present"] or not report["files"]:
        why = "it ran no engine"
    elif report["smoke"] or report["limit"]:
        why = "it was a SMOKE or --limit run (a subset)"
    elif cr.verdict_of(report, against) != "GREEN":
        why = f"its verdict is {cr.verdict_of(report, against)}, not GREEN"
    elif report.get("manifest_sha256") != manifest_sha256:
        why = "it did not run the installed sample (its manifest SHA-256 differs, or it predates the record)"
    elif any(state != "present" and n for counts in report["inventory"].values() for state, n in counts.items()):
        why = "not every sample file was present and run (missing, NOT RUN or a problem state)"
    elif not report["inventory"]:
        why = "it says nothing of what was present"
    if why:
        raise Refused(f"refused: check run {cr.word(stamp)} is not a green run on the installed sample — {why}. Nothing was deleted.")
    return runs[0].name


def delete_copy(media_fd: int, rel: str, size: int) -> str:
    """Unlink the copy at `rel` under the open media folder: one descriptor per folder on the way, none
    followed through a link nor onto another device; the file must be a regular file with one name, no lock
    flag and the planned size. Then the folders it leaves empty, up to (not including) the media folder.
    Returns the outcome word."""
    parts = rel.split("/")
    dev = os.fstat(media_fd).st_dev
    fds = [media_fd]
    try:
        for name in parts[:-1]:
            try:
                info = os.stat(name, dir_fd=fds[-1], follow_symlinks=False)
            except FileNotFoundError:
                return "absent"
            if stat.S_ISLNK(info.st_mode):
                return "refused_link"
            if not stat.S_ISDIR(info.st_mode):
                return "refused_not_a_file"
            if info.st_dev != dev:
                return "refused_other_volume"
            fd = os.open(name, cr.O_DIR, dir_fd=fds[-1])
            opened = os.fstat(fd)
            fds.append(fd)
            if (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino):
                return "refused_other_volume"                 # swapped between the look and the open
        name = parts[-1]
        try:
            info = os.stat(name, dir_fd=fds[-1], follow_symlinks=False)
        except FileNotFoundError:
            return "absent"
        if stat.S_ISLNK(info.st_mode):
            return "refused_link"
        if not stat.S_ISREG(info.st_mode):
            return "refused_not_a_file"
        if info.st_dev != dev:
            return "refused_other_volume"
        if info.st_nlink != 1:
            return "refused_second_name"
        if getattr(info, "st_flags", 0) & LOCK_FLAGS:
            return "refused_locked"
        if info.st_size != size:
            return "refused_size"
        os.unlink(name, dir_fd=fds[-1])
        for depth in range(len(fds) - 1, 0, -1):               # the folders it leaves empty, deepest first
            os.close(fds.pop())
            try:
                os.rmdir(parts[depth - 1], dir_fd=fds[-1])
            except OSError:
                break                                        # not empty (or not ours to remove): stop climbing
        return "deleted"
    except OSError:
        return "refused_error"
    finally:
        for fd in fds[1:]:
            os.close(fd)


def _open_media(seal: cr.Seal, root: str) -> Optional[int]:
    """The root's media folder, opened: the folder itself (no link), on its root's own device."""
    media = media_of(seal, root)
    if media is None or not os.path.isdir(str(media)):
        return None
    if os.path.islink(str(media)):
        raise Refused("refused: a corpus media folder is a link")
    fd = os.open(os.path.realpath(str(media)), cr.O_DIR)
    anchor = seal.home_device() if root == "internal" else os.lstat(str(seal.external().mount)).st_dev
    if os.fstat(fd).st_dev != anchor:
        os.close(fd)
        raise Refused("refused: a corpus media folder is on another volume than its root (something is mounted over it)")
    return fd


def apply(seal: cr.Seal, plan_path: Path, stamp: str) -> Tuple[List[str], Dict[str, Counter]]:
    seal.check()
    try:
        value = json.loads(Path(plan_path).read_text(encoding="utf-8"))
        files, sample_sha = value["files"], str(value["sample_sha256"])
        if value.get("version") != 1 or not isinstance(files, list):
            raise ValueError("not a plan")
    except (OSError, ValueError, KeyError, TypeError):
        raise Refused("refused: the plan cannot be read back (it is not what plan-shrink writes)")
    installed = seal.corpus / cr.manifest_name(seal)
    if os.path.islink(str(installed)) or _digest(installed) != sample_sha:
        raise Refused("refused: the manifest installed in ~/corpus is not the sample this plan was made for. Nothing was deleted.")
    run = green_run(seal, stamp, sample_sha)
    keys, places = _holds(_rows(json.loads(installed.read_text(encoding="utf-8"))))
    counts = {root: Counter() for root in COPY_ROOTS}
    seal.mkdir(seal.state)
    # Every root the plan names is proven and opened BEFORE the first deletion: a refusal (another volume
    # at the X10's mount, a media folder that is a link) stops the whole step with nothing deleted.
    opened: Dict[str, Optional[int]] = {}
    try:
        for root in sorted({f.get("root") for f in files if isinstance(f, dict)} & set(COPY_ROOTS)):
            opened[root] = _open_media(seal, root)
        for f in files:
            root = f.get("root") if isinstance(f, dict) else None
            if root not in COPY_ROOTS:
                counts.setdefault("other", Counter())["refused_root"] += 1
                continue
            sha, rel, size = str(f.get("sha256", "")).lower(), f.get("place"), f.get("size")
            if not _plain_place(rel) or not isinstance(size, int) or isinstance(size, bool):
                counts[root]["refused_entry"] += 1
                continue
            if (sha, root) in keys or (root, rel) in places:
                counts[root]["kept_in_sample"] += 1
                continue
            if opened.get(root) is None:
                counts[root]["not_mounted" if root == "external" else "absent"] += 1
                continue
            outcome = delete_copy(opened[root], rel, size)
            counts[root][outcome] += 1
            if outcome == "deleted":
                counts[root]["bytes"] += size
    finally:
        for fd in opened.values():
            if fd is not None:
                os.close(fd)
    record = {"at": time.strftime("%Y-%m-%d %H:%M:%S"), "after_green": run, "sample_sha256": sample_sha,
              "counts": {root: dict(c) for root, c in counts.items()}}
    seal.write_text(seal.state / HISTORY, json.dumps(record, sort_keys=True) + "\n", append=True)
    lines = [f"corpus shrink: after the green check run {cr.word(run)} on the installed sample"]
    for root, c in counts.items():
        rest = " · ".join(f"{k} {n}" for k, n in sorted(c.items()) if k not in ("deleted", "bytes"))
        lines.append(f"corpus shrink: {root} deleted {c['deleted']} files {c['bytes'] / 1e9:.1f} GB" + (f"; {rest}" if rest else ""))
    return lines, counts


def main(args, seal: Optional[cr.Seal] = None) -> int:
    seal = seal or cr.Seal.here()
    try:
        if args.command == "plan-shrink":
            seal.check()
            out = Path(args.out)
            repo = Path(__file__).resolve().parents[1]
            if out.resolve() == repo or repo in out.resolve().parents or seal.pristine(out):
                raise Refused("refused: the plan names real places — write it outside the repository and the corpus's media")
            sample_path = Path(args.sample)
            current_path = Path(args.current) if args.current else seal.corpus / cr.manifest_name(seal)
            the_plan, counts = plan(seal, json.loads(current_path.read_text(encoding="utf-8")),
                                    json.loads(sample_path.read_text(encoding="utf-8")))
            the_plan["sample_sha256"] = _digest(sample_path)
            out.mkdir(parents=True, exist_ok=True)
            (out / PLAN).write_text(json.dumps(the_plan, indent=0) + "\n")
            for root, c in counts.items():
                print(f"corpus plan-shrink: {root} {c['files']} present copies no longer in the sample, {c['bytes'] / 1e9:.1f} GB"
                      + (f"; {c['no_copy']} dropped rows have no copy" if c["no_copy"] else "")
                      + (f"; {c['not_mounted']} not looked at (the external volume is not mounted)" if c["not_mounted"] else ""))
            total = sum(c["bytes"] for c in counts.values())
            print(f"corpus plan-shrink: {sum(c['files'] for c in counts.values())} files {total / 1e9:.1f} GB in all — "
                  "nothing deleted; `apply-shrink --after-green <check run>` after a GREEN check run on this sample")
            return 0
        lines, _ = apply(seal, Path(args.plan), args.after_green)
        print("\n".join(lines))
        return 0
    except Refused as refusal:
        print(f"corpus shrink: RED {refusal}")
        return 2
