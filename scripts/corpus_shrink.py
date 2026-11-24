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
  Written to <folder>/shrink-plan.json as a NEW file renamed into place (never through a link or a second
  name: Codex #359 F1); <folder> is refused inside the repository and the corpus's pristine parts. Printed:
  files and GB per root, and how many dropped rows have no copy (never copied) or could not be looked at
  (the external volume away). Deletes nothing.

apply — THE ONLY DELETION. Refused, with nothing deleted, unless ALL of:
  1. the seal (corpus_run.Seal.check: the M4, the marked ~/corpus, its folders themselves);
  2. the manifest installed in ~/corpus is, byte for byte, the sample the plan was made for (SHA-256 of the
     very bytes then parsed);
  3. <stamp> names exactly one stored check-lane run whose own report says lane `check`, that stamp and that
     commit; it had its engine, was not SMOKE nor --limit; its stored diff is a diff (no problem, 0 changed,
     no transitions) and its verdict GREEN; it read THIS manifest (`manifest_sha256`); its inventory is
     exactly the sample's rows per root, all `present`; its outcomes.json names exactly the sample's files,
     each through every check engine with a real outcome (never not_run / no_record / crash / timeout /
     external_volume_not_proven) — the evidence itself, not only the summary (Codex #359 F6). A sample with
     an `ro` row cannot pass: no run reads the read-only share yet;
  4. the receipt (~/corpus/state/shrink-history.jsonl, via Seal: never through a link) opens, and every root
     the plan names is proven and its media folder opened — BEFORE the first deletion (F8, F2).
  Media folders are opened descriptor by descriptor from the home folder / the X10's mount, never following
  a link (a ~/corpus swapped for a link after the seal is refused: F2); the X10 is proven AGAIN after its
  media folder is open and the descriptor must be on the device mounted there before and after that proof.
  Then per planned file, each answered by a word and counted (never a path):
     kept_in_sample  the installed sample names it on that root — by SHA-256, by place, by place case-folded,
                     or by file identity (device, inode) of any copy the sample names (case aliases: F3);
     not_mounted     its root is the external volume and that is not proven now;
     absent          nothing at its place;
     refused_*       entry (not a plain `Volumes/…` place, a NUL, no size or digest), root (`ro`), link,
                     not_a_file, other_volume, second_name (hard link), locked, size, digest (its bytes are
                     not the planned SHA-256: F4), changed (another file at that name by the time of the
                     unlink: F5), error (anything else the OS said): left as it is;
     left_hidden     renamed to its hidden `.corpus-shrink-*` name and then neither unlinked nor renamed back
                     (the name was taken again, or the unlink failed): the receipt names it by root and
                     SHA-256 prefix so a person can find it;
     deleted         read whole and its SHA-256 proven to be the planned content, then RENAMED within its
                     folder to a random name, proven again to be the same inode, and only then unlinked by
                     that name (C++: openat / renameat / unlinkat). A file swapped in at any step is renamed
                     back, not deleted.
  Folders the deletion leaves empty go too, up to (never including) the root's media folder. The receipt
  gets a `start` line before the first deletion and the counts at the end, whatever happened between.
  The originals are never named: a place is always relative to a root's media folder.

Cost: every deleted file is read once (SHA-256, 8 MiB at a time): ~1.4 TB at the X10's ~1 GB/s is ~25 minutes.
PRIVACY. Prints counts, bytes and words only. Memory: the two manifests (~6,400 rows, a few MB), one 8 MiB
read buffer, the sample's file identities (one pair of ints per file).
Python 3.9 is the floor.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import secrets
import stat
import sys
import time
from collections import Counter
from pathlib import Path
from typing import Callable, Dict, List, Optional, Set, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
import corpus_run as cr  # noqa: E402

COPY_ROOTS = ("internal", "external")
PLAN = "shrink-plan.json"
HISTORY = "shrink-history.jsonl"
LOCK_FLAGS = getattr(stat, "UF_IMMUTABLE", 0x2) | getattr(stat, "SF_IMMUTABLE", 0x20000) \
    | getattr(stat, "UF_APPEND", 0x4) | getattr(stat, "SF_APPEND", 0x40000)
NOT_RAN = frozenset(cr.HARNESS_WORDS) | {cr.EXTERNAL_GONE}
CHUNK = 8 << 20
BEFORE_UNLINK: Optional[Callable[[str], None]] = None      # seams: the tests swap a file in at the last moment,
AFTER_RENAME: Optional[Callable[[str], None]] = None       # or take the name again once it was renamed away
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
    """What the sample keeps on each copy root: (sha, root) pairs and (root, place case-folded) pairs."""
    keys, places = set(), set()
    for r in sample:
        root = str(r.get("root", "internal"))
        keys.add((str(r["sha256"]).lower(), root))
        places.add((root, place_of(str(r["path"])).casefold()))
    return keys, places


def media_of(seal: cr.Seal, root: str) -> Optional[Path]:
    """A copy root's media folder (for the read-only plan); None when the external volume is not proven now."""
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
        if (sha, root) in keys or (root, rel.casefold()) in places:
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


def write_new(path: Path, text: str) -> None:
    """A new file beside `path` (O_EXCL, never through a link), renamed over it: a link or a second name at
    `path` is replaced as a name, its target never written (Codex #359 F1)."""
    pending = path.with_name(f".{path.name}.{os.getpid()}.{secrets.token_hex(4)}")
    fd = os.open(str(pending), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(str(pending), str(path))


def _plain_place(rel) -> bool:
    if not isinstance(rel, str) or not rel.startswith("Volumes/") or "\x00" in rel:
        return False
    return all(part not in ("", ".", "..") for part in rel.split("/"))


def _diff(against) -> Optional[dict]:
    """The run's stored diff, only if it is one that says nothing moved (else Refused)."""
    if against is None:
        return None
    if (not isinstance(against, dict) or against.get("problem") or against.get("changed") != 0
            or against.get("transitions") not in (None, {}) or against.get("listed") not in (None, [])):
        raise ValueError("the run's diff against its baseline is not a diff in which nothing moved")
    return against


def green_run(seal: cr.Seal, stamp: str, manifest_sha256: str, sample: List[dict]) -> str:
    """The stored check run `stamp`, proven GREEN over this very manifest, every sample file present and through
    every engine (its outcomes, not only its counts). Returns its name; Refused (saying which) otherwise."""
    if not re.fullmatch(r"[0-9A-Za-z_]+", stamp or ""):
        raise Refused("refused: --after-green is a check run's stamp (letters, digits and underscores)")
    runs = [run for run in cr.lane_runs(seal, "check") if run.name == stamp]
    if len(runs) != 1:
        raise Refused(f"refused: no single stored check run is named {cr.word(stamp)}")
    run = runs[0]
    why = None
    try:
        raw = json.loads((run / "report.json").read_text(encoding="utf-8"))
        report = cr.clean_report(raw)
        outcomes = cr._outcomes(run)
        against = _diff(raw.get("against"))
    except (OSError, ValueError) as error:
        raise Refused(f"refused: check run {cr.word(stamp)} cannot be read back as a green run "
                      f"({cr.word(type(error).__name__)}). Nothing was deleted.")
    engines = cr.LANES["check"][1]
    wanted = Counter(str(r.get("root", "internal")) for r in sample)
    shas = {str(r["sha256"]).lower() for r in sample}
    if raw.get("lane") != "check" or raw.get("stamp") != run.name or raw.get("sha") != run.parent.name:
        why = "its report is not that check run's own (lane, stamp or commit)"
    elif not report["engine_present"] or not report["files"]:
        why = "it ran no engine"
    elif report["smoke"] or report["limit"]:
        why = "it was a SMOKE or --limit run (a subset)"
    elif cr.verdict_of(report, against) != "GREEN":
        why = f"its verdict is {cr.verdict_of(report, against)}, not GREEN"
    elif report.get("manifest_sha256") != manifest_sha256:
        why = "it did not run the installed sample (its manifest SHA-256 differs, or it predates the record)"
    elif wanted.get("ro"):
        why = f"not every sample file can have run: {wanted['ro']} are on the read-only share, which no run reads yet"
    elif report["inventory"] != {root: {"present": n} for root, n in wanted.items()}:
        why = "not every sample file was present and run (its inventory is not the sample's, all present)"
    elif set(outcomes) != shas or any(not isinstance(outcomes[s].get(e), str) or outcomes[s].get(e) in NOT_RAN
                                      for s in shas for e in engines):
        why = "its outcomes do not show every sample file through every check engine"
    if why:
        raise Refused(f"refused: check run {cr.word(stamp)} is not a green run on the installed sample — {why}. Nothing was deleted.")
    return run.name


def _open_chain(start: str, names: List[str]) -> int:
    """A descriptor on start/names[0]/…, each step opened without following a link (C++: openat O_NOFOLLOW)."""
    fd = os.open(start, cr.O_DIR)
    try:
        for name in names:
            child = os.open(name, cr.O_DIR, dir_fd=fd)
            os.close(fd)
            fd = child
    except BaseException:
        os.close(fd)
        raise
    return fd


def _open_media(seal: cr.Seal, root: str) -> Optional[int]:
    """The root's media folder, opened from its anchor without following a link and bound to its device.
    None: the external volume is not proven now, or the folder is not there."""
    try:
        if root == "internal":
            fd = _open_chain(os.path.realpath(str(seal.home)), ["corpus", "media"])
            if os.fstat(fd).st_dev != seal.home_device():
                os.close(fd)
                raise Refused("refused: ~/corpus/media is on another volume (something is mounted over it)")
            return fd
        proven = seal.external()
        if proven.state != "ok":
            return None
        mount = str(proven.mount)
        fd = _open_chain(mount, ["corpus", "media"])
    except FileNotFoundError:
        return None
    except OSError:
        raise Refused(f"refused: the {root} media folder could not be opened as itself (a link on the way?)")
    # The X10 proven AGAIN with the folder open: the descriptor is on the device mounted at the adopted path
    # before and after a fresh UUID proof (a volume swapped in between is refused).
    try:
        before = os.lstat(mount).st_dev
        again = seal.reprove_external()
        after = os.lstat(mount).st_dev
        bound = (again.state == "ok" and str(again.mount) == mount and again.uuid == proven.uuid
                 and os.fstat(fd).st_dev == before == after)
    except (OSError, Refused):
        bound = False
    if not bound:
        os.close(fd)
        raise Refused("refused: the external volume changed while its media folder was opened")
    return fd


def _identities(media_fd: int, sample: List[dict], root: str) -> Set[Tuple[int, int]]:
    """(device, inode) of every copy the sample names on this root: the files no name may delete."""
    out = set()
    for r in sample:
        if str(r.get("root", "internal")) == root:
            try:
                info = os.stat(place_of(str(r["path"])), dir_fd=media_fd, follow_symlinks=False)
                out.add((info.st_dev, info.st_ino))
            except (OSError, ValueError):
                pass
    return out


def _sha256_fd(fd: int) -> str:
    digest = hashlib.sha256()
    while True:
        chunk = os.read(fd, CHUNK)
        if not chunk:
            return digest.hexdigest()
        digest.update(chunk)


def delete_copy(media_fd: int, rel: str, size: int, sha: str, protected: Set[Tuple[int, int]]) -> str:
    """Delete the copy at `rel` under the open media folder if, and only if, it is the planned content (see
    the module header for every check and the order). Returns the outcome word."""
    parts = rel.split("/")
    dev = os.fstat(media_fd).st_dev
    fds = [media_fd]
    leaf = -1
    hidden = ""
    folder = media_fd
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
        name, folder = parts[-1], fds[-1]
        try:
            info = os.stat(name, dir_fd=folder, follow_symlinks=False)
        except FileNotFoundError:
            return "absent"
        if stat.S_ISLNK(info.st_mode):
            return "refused_link"
        if not stat.S_ISREG(info.st_mode):
            return "refused_not_a_file"
        if info.st_dev != dev:
            return "refused_other_volume"
        if (info.st_dev, info.st_ino) in protected:
            return "kept_in_sample"
        if info.st_nlink != 1:
            return "refused_second_name"
        if getattr(info, "st_flags", 0) & LOCK_FLAGS:
            return "refused_locked"
        if info.st_size != size:
            return "refused_size"
        leaf = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=folder)
        held = os.fstat(leaf)
        if (held.st_dev, held.st_ino) != (info.st_dev, info.st_ino):
            return "refused_changed"
        if _sha256_fd(leaf) != sha:
            return "refused_digest"
        done = os.fstat(leaf)
        if (done.st_size, done.st_mtime_ns) != (held.st_size, held.st_mtime_ns):
            return "refused_changed"
        if BEFORE_UNLINK is not None:
            BEFORE_UNLINK(name)
        # Bind the unlink to the file proven above: rename it to a name nobody else knows, prove THAT is the
        # inode we hold, and only then unlink it. Anything else found there is renamed back, never deleted.
        hidden = f".corpus-shrink-{os.getpid()}-{secrets.token_hex(8)}"
        os.rename(name, hidden, src_dir_fd=folder, dst_dir_fd=folder)
        if AFTER_RENAME is not None:
            AFTER_RENAME(name)
        moved = os.stat(hidden, dir_fd=folder, follow_symlinks=False)
        if (moved.st_dev, moved.st_ino) != (held.st_dev, held.st_ino):
            try:
                os.stat(name, dir_fd=folder, follow_symlinks=False)
                return "left_hidden"                         # the name was taken again: the file stays hidden
            except FileNotFoundError:
                os.rename(hidden, name, src_dir_fd=folder, dst_dir_fd=folder)
            return "refused_changed"
        os.unlink(hidden, dir_fd=folder)
        hidden = ""
        for depth in range(len(fds) - 1, 0, -1):               # the folders it leaves empty, deepest first
            os.close(fds.pop())
            try:
                os.rmdir(parts[depth - 1], dir_fd=fds[-1])
            except OSError:
                break                                        # not empty: stop climbing
        return "deleted"
    except (OSError, ValueError):
        if hidden:
            try:
                os.stat(hidden, dir_fd=folder, follow_symlinks=False)
                return "left_hidden"                         # renamed away and never unlinked: said, by digest
            except (OSError, ValueError):
                pass
        return "refused_error"
    finally:
        if leaf >= 0:
            os.close(leaf)
        for fd in fds[1:]:
            os.close(fd)


def _entry(f, keys: set, places: set) -> Tuple[str, str]:
    """(root, word): what the preflight says of one plan entry before anything is opened."""
    root = f.get("root") if isinstance(f, dict) else None
    if root not in COPY_ROOTS:
        return "other", "refused_root"
    sha, rel, size = str(f.get("sha256", "")).lower(), f.get("place"), f.get("size")
    if (not _plain_place(rel) or not isinstance(size, int) or isinstance(size, bool) or size < 0
            or not re.fullmatch(r"[0-9a-f]{64}", sha)):
        return root, "refused_entry"
    if (sha, root) in keys or (root, rel.casefold()) in places:
        return root, "kept_in_sample"
    return root, ""


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
    if os.path.islink(str(installed)):
        raise Refused("refused: the installed manifest is a link. Nothing was deleted.")
    data = installed.read_bytes()                            # hashed and parsed from the same bytes (Codex #359 F7)
    if hashlib.sha256(data).hexdigest() != sample_sha:
        raise Refused("refused: the manifest installed in ~/corpus is not the sample this plan was made for. Nothing was deleted.")
    try:
        sample = _rows(json.loads(data.decode("utf-8")))
    except ValueError:
        raise Refused("refused: the installed manifest cannot be read. Nothing was deleted.")
    run = green_run(seal, stamp, sample_sha, sample)
    keys, places = _holds(sample)
    counts: Dict[str, Counter] = {root: Counter() for root in COPY_ROOTS}
    todo = []
    for f in files:                                          # preflight: every entry judged before anything opens
        root, word = _entry(f, keys, places)
        if word:
            counts.setdefault(root, Counter())[word] += 1
        else:
            todo.append(f)
    seal.mkdir(seal.state)
    receipt = cr.guarded_open(seal.writable(seal.state / HISTORY), append=True)     # Refused through a link: F8
    record = {"at": time.strftime("%Y-%m-%d %H:%M:%S"), "after_green": run, "sample_sha256": sample_sha}
    os.write(receipt, (json.dumps(dict(record, step="start", planned=len(files)), sort_keys=True) + "\n").encode())
    opened: Dict[str, Optional[int]] = {}
    hidden_left: List[dict] = []                             # a file left under a `.corpus-shrink-*` name
    try:
        for root in sorted({f["root"] for f in todo}):       # proven and opened BEFORE the first deletion (F2)
            opened[root] = _open_media(seal, root)
        protected = {root: _identities(fd, sample, root) for root, fd in opened.items() if fd is not None}
        for f in todo:
            root = f["root"]
            if opened.get(root) is None:
                counts[root]["not_mounted" if root == "external" else "absent"] += 1
                continue
            outcome = delete_copy(opened[root], f["place"], f["size"], str(f["sha256"]).lower(), protected[root])
            counts[root][outcome] += 1
            if outcome == "left_hidden":
                hidden_left.append({"root": root, "sha256_prefix": str(f["sha256"]).lower()[:12]})
            if outcome == "deleted":
                counts[root]["bytes"] += f["size"]
    finally:
        for fd in opened.values():
            if fd is not None:
                os.close(fd)
        os.write(receipt, (json.dumps(dict(record, step="end", counts={r: dict(c) for r, c in counts.items()},
                                           left_hidden=hidden_left), sort_keys=True) + "\n").encode())
        os.close(receipt)
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
            sample_bytes = sample_path.read_bytes()
            current_path = Path(args.current) if args.current else seal.corpus / cr.manifest_name(seal)
            the_plan, counts = plan(seal, json.loads(current_path.read_text(encoding="utf-8")),
                                    json.loads(sample_bytes.decode("utf-8")))
            the_plan["sample_sha256"] = hashlib.sha256(sample_bytes).hexdigest()
            out.mkdir(parents=True, exist_ok=True)
            write_new(out / PLAN, json.dumps(the_plan, indent=0) + "\n")
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
