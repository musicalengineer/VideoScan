#!/usr/bin/env python3
"""corpus_run.py — the real-data corpus harness, host side (phase 1).

DECISIONS 2026-11-17, "The M4 holds a real-data test corpus": a curated copy
of real family media plus a `.backup` of the catalog lives on the M4 under
~/corpus, and automation runs the app's engines across it. This file is what
runs ON THE M4; `scripts/corpus_run.sh` launches it from the Ultra through
`scripts/m4_run.sh corpus` (the testbed lock, the per-run LaunchAgent, the
`--ref` checkout). It is also fed to `python3 - status` over ssh.

  host prepare   build the sealed state: ~/corpus/state/<the catalog file>
  host check     probe · Check Media (quick) · Verify Audio · the A/V pair link, every corpus file
  host proof     Balance Audio into work/, then the balanced-copy proof
  host verbs     the verbs that move, trash and promote — on CLONES in work/
  host coverage  opt-in: the three lanes on an instrumented build beside the suite; which of
                 our code only the corpus runs (scripts/corpus_coverage.py)
  status         the newest run of each lane, judged against the lane's baseline
  accept <lane>  bless the lane's newest run as its baseline (who, when, which run)

THE VERDICT OF A LANE IS THE DIFF. A run is compared, file by file (by SHA-256),
with the lane's BASELINE: the run `accept` blessed (reports/<lane>/baseline.json),
or — until one is accepted — the lane's first whole clean run.
  RED    a file crashed an engine or ran past its deadline (never acceptable,
         whatever the baseline holds), or the accepted baseline cannot be read back;
  AMBER  some file's outcome word differs from the baseline — each is listed by
         SHA-256 prefix with `engine: old -> new`;
  GREEN  nothing moved. An engine's own "error:…" word is an outcome like any
         other: known in the baseline, it is not news.

THE SEAL (every entry point passes `Seal.check` first; tests/test_corpus_run.py):
  1. the hostname is the M4's (`ALLOWED_HOSTS`); the Ultra is refused by name;
  2. ~/corpus exists and carries THIS_IS_TEST_DATA.txt;
  3. the state root resolves (symlinks followed) under ~/corpus/state and is
     nowhere near "Library/Application Support";
  4. ~/corpus/{state,work,reports} ARE those folders: one that is a symlink, or
     resolves anywhere but directly under the corpus folder, is refused — a
     `work` pointing into `media` would otherwise make media "writable";
  5. every path this file writes resolves under ~/corpus/{state,work,reports}
     (`Seal.writable`) — and never under /Volumes, ~/corpus/media or
     ~/corpus/live, whatever it resolved through;
  6. what it READS BACK as its own (the sealed catalog, a stored run, a
     baseline) must resolve inside the folder it belongs to (`Seal.contained`):
     a symlink out — to a live catalog, to a file elsewhere — is refused;
  7. files written into the lane's <out> folder (`out_write`) never follow a
     symlink and never land in the corpus's read-only parts.
  The home directory comes from the account database (pwd), not $HOME, so an
  overridden HOME cannot move the seal. There is no flag, environment
  variable or config key that relaxes any of it.

The engines run inside the app's own unit-test host (the gauntlet's way of
driving the app headless: Runner.swift `prepareRoots`/`patch`): the host gets
HOME = CFFIXED_USER_HOME = ~/corpus/state/home through a patched .xctestrun,
where `TestEnvironment.isTestHost` already makes the shared catalog store,
catalog sync and the background service inert. The driver sources
(scripts/corpus/*.swift) are laid over the testbed worktree as UNTRACKED
files for the length of the run, so a ref that predates the harness can be
run, and are moved out again afterwards.

PRIVACY. The corpus is real family media. What this file prints, and what
it writes into <out>/corpus-summary.txt (which the caller reads back), is
counts, outcome words, container/codec names and durations only. Per-file
results are keyed by SHA-256 and stay under ~/corpus/reports on the M4. No
filename, path, caption or transcript is ever printed: every word that
reaches a report goes through `word()`, which cannot carry a path.

THE VERBS LANE (`VerbsLane`; DECISIONS 2026-11-17: "verbs that move or trash may be
exercised there because every file is a copy"). A small stratified sample of the
corpus is CLONED (`cp -c`, APFS copy-on-write: no extra space) into
work/<run>/vol/, a catalog is built over the clones by `prepare`'s own transform,
and the app's real engines run against them in the test host with its HOME inside
the run's work folder: Find Duplicates + Delete Duplicates on byte-identical
clones, Move to Trash, Remove (purge) and Remove from Catalog (set aside) each
followed by a real rescan, and Promote into a scratch archive under work/<run>/.
Nothing under ~/corpus/media is ever a target: the lane proves it by a size+mtime
sweep of every corpus file before and after (any difference is RED), and the
in-app driver proves every surviving clone still matches its SHA-256. The Trash
is a folder in the run's own work folder, given to each engine through its own
injectable Trash step — never the Finder Trash, and not the app's test-host
Trash either (that one is in the system's temporary folder, outside the run:
it is counted afterwards and must be empty); the archive root is refused
unless it is under ~/corpus/work.

This file never signals a process. A file that overruns its deadline is cut
by the driver exiting its own test host (CorpusDriverSupport.swift); the
whole lane sits under m4_run.sh's existing lane watchdog.

Memory: the manifest (234 rows) and one JSON line per engine per file — KBs.
Disk: the sealed catalog (~1 MB); the proof lane holds one balanced copy at
a time under ~/corpus/work/<run>/ and the run's work folder is removed at
the end. The verbs lane's clones share their blocks with the corpus (0 bytes
until written; nothing writes them); its scratch archive holds real copies of
the promoted files — at most VERBS_PROMOTE_BYTES (4 GB) — and the lane refuses
to start with less than VERBS_FREE_FLOOR (20 GB) free. Python 3.9 (the M4's /usr/bin/python3) is the floor.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import pwd
import re
import shutil
import socket
import sqlite3
import stat
import subprocess
import sys
import time
import urllib.parse
from collections import Counter, defaultdict
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple

ALLOWED_HOSTS = frozenset({"ricksm4"})
FORBIDDEN_HOSTS = frozenset({"ricksultra"})        # Rick's machine: refused by name
MARKER = "THIS_IS_TEST_DATA.txt"
MANIFEST = "corpus-manifest-v1.json"
SHA_LIST = "corpus-sha-v1.txt"
SOURCE_BACKUP = "catalog-source-backup.sqlite"
TRANSFORM_VERSION = 2            # 2: pair links carried as row_knowledge 'pair' rows

OVERLAY_DIR = "VideoScan/VideoScanTests/CorpusHarnessOverlay"     # untracked, in the testbed, for one run
PROOF_ENGINE_GLOB = "VideoScan/VideoScan/MediaOps/BalancedCopyProof*.swift"
PROOF_STRATUM = "one-sided sound"

# lane -> (XCTest class, its engines in order, default per-file deadline in seconds, driver sources)
LANES = {
    "check": ("CorpusCheckDriver", ["probe", "check", "audio", "pair"], 300,
              ["CorpusSeal.swift", "CorpusDriverSupport.swift", "CorpusCheckDriver.swift"]),
    "proof": ("CorpusProofDriver", ["balance", "proof"], 3600,
              ["CorpusSeal.swift", "CorpusDriverSupport.swift", "CorpusProofDriver.swift"]),
    "verbs": ("CorpusVerbsDriver", ["group", "trash_copy", "dedupe", "trash_last", "purge", "set_aside", "promote", "intact"],
              3600, ["CorpusSeal.swift", "CorpusDriverSupport.swift", "CorpusVerbsDriver.swift"]),
}
VERBS_SAMPLE = 20                                # files the verbs lane clones (--limit changes it)
VERBS_ROLES = ("dup", "purge", "set_aside", "promote")     # dealt round-robin over the sample
VERBS_COPIES = 2                                 # extra byte-identical clones of each `dup` file
VERBS_MAX_FILE = 2 << 30                         # a sampled file is at most 2 GiB (every engine reads it whole, some twice)
VERBS_PROMOTE_BYTES = 4 << 30                    # Promote makes real copies: at most this much in the scratch archive
VERBS_FREE_FLOOR = 20 << 30                      # refuse to start with less free space than this
LOSS_WORDS = ("LOST", "MISMATCH")                # a clone that is gone or no longer its SHA-256: RED
HARNESS_WORDS = ("crash", "timeout", "not_run", "no_record")       # outcomes the harness itself assigns

EXIT_GREEN, EXIT_RED, EXIT_REFUSED, EXIT_AMBER, EXIT_NORUN = 0, 1, 2, 3, 4
BASELINE, BASELINE_LOG = "baseline.json", "baseline-history.jsonl"     # in reports/<lane>/
CUT_WORDS = ("crash", "timeout")                # an engine that died or overran on a file: RED
KEEP_RUNS = 20                                   # stored runs kept per lane (plus the baseline and every RED run)
STALE_WORK_SECONDS = 6 * 3600                    # a work folder this old belongs to no live run (lanes hold the testbed lock)
LISTED = 40                                      # changed files a summary lists; the rest are counted
VERDICT_FILE = "corpus-verdict.json"      # in <out>: the lane's verdict as counts, for m4_run_summary.py --testbed


class Refused(Exception):
    """The seal or a precondition said no. The message is safe to print (no corpus path)."""


# ── The seal ──────────────────────────────────────────────────────────────

def real_home() -> Path:
    return Path(pwd.getpwuid(os.getuid()).pw_dir)


def short_hostname() -> str:
    return socket.gethostname().split(".")[0].lower()


def _under(path: Path, root: Path) -> bool:
    p, r = Path(os.path.realpath(str(path))), Path(os.path.realpath(str(root)))
    return p == r or r in p.parents


class Seal:
    """Where the harness may run and write. Built from the real home and hostname by
    `Seal.here()`; tests build one over a temporary folder — no CLI path does."""

    def __init__(self, home: Path, hostname: str, state_root: Optional[Path] = None):
        self.home = Path(home)
        self.hostname = hostname.split(".")[0].lower()
        self.corpus = self.home / "corpus"
        self.state = Path(state_root) if state_root is not None else self.corpus / "state"
        self.work_root = self.corpus / "work"
        self.reports = self.corpus / "reports"
        self.media = self.corpus / "media"
        self.out_root = self.home / "m4run" / "out"          # where m4_run.sh puts a run's folder

    @classmethod
    def here(cls, state_root: Optional[str] = None) -> "Seal":
        return cls(real_home(), short_hostname(), Path(state_root) if state_root else None)

    def check(self) -> "Seal":
        if self.hostname in FORBIDDEN_HOSTS:
            raise Refused(f"refused: this is {self.hostname} (the M5 Ultra, Rick's machine); the corpus harness runs only on the M4")
        if self.hostname not in ALLOWED_HOSTS:
            raise Refused(f"refused: host '{self.hostname}' is not the M4; the corpus harness runs only on the M4")
        if not (self.corpus / MARKER).is_file():
            raise Refused(f"refused: no {MARKER} under ~/corpus — this is not the test corpus")
        if not _under(self.state, self.corpus / "state"):
            raise Refused("refused: the state root is not under ~/corpus/state")
        resolved = os.path.realpath(str(self.state))
        if "/Library/Application Support" in resolved or resolved.startswith("/Volumes/"):
            raise Refused("refused: the state root resolves to a live location")
        # The three writable folders, and media, are themselves — never an alias (Codex #311 F1).
        corpus_real = os.path.realpath(str(self.corpus))
        for name in ("state", "work", "reports", "media"):
            folder = self.corpus / name
            if os.path.islink(str(folder)) or (os.path.lexists(str(folder))
                                               and os.path.realpath(str(folder)) != os.path.join(corpus_real, name)):
                raise Refused(f"refused: ~/corpus/{name} is a symlink or resolves somewhere else — the corpus folders must be themselves")
        return self

    def pristine(self, path: Path) -> bool:
        """True when `path` resolves inside the parts of the corpus nothing may write: the media
        copies, the read-only mount, or one of the corpus documents."""
        if _under(path, self.media) or _under(path, self.corpus / "live"):
            return True
        resolved = os.path.realpath(str(path))
        return any(resolved == os.path.realpath(str(self.corpus / name)) for name in (MANIFEST, SHA_LIST, SOURCE_BACKUP, MARKER))

    def contained(self, path: Path, root: Path) -> Path:
        """`path`, or Refused unless it resolves inside `root` (which itself must be inside the
        corpus): for what the harness reads back as its own. A symlink out is refused before
        anything is opened (Codex #311 F4)."""
        if not _under(root, self.corpus) or not _under(path, root) or os.path.islink(str(path)):
            raise Refused("refused: a file the harness reads back as its own resolves outside the folder it belongs to")
        return Path(path)

    def writable(self, path: Path) -> Path:
        """`path`, or Refused unless it resolves inside ~/corpus/{state,work,reports}."""
        path = Path(path)
        resolved = os.path.realpath(str(path))
        if resolved.startswith("/Volumes/") or "/Library/Application Support" in resolved:
            raise Refused("refused: a write was aimed at a live location")
        if self.pristine(path):
            raise Refused("refused: a write was aimed at the pristine corpus (the corpus sources are read-only)")
        if not any(_under(path, root) for root in (self.state, self.work_root, self.reports)):
            raise Refused("refused: a write was aimed outside ~/corpus/{state,work,reports} (the corpus sources are read-only)")
        return path

    def mkdir(self, path: Path) -> Path:
        self.writable(path).mkdir(parents=True, exist_ok=True)
        return path

    def write_text(self, path: Path, text: str, append: bool = False) -> None:
        """Every file the harness keeps under ~/corpus/{state,work,reports}: the path must be
        writable (`writable`), and the file is opened through `guarded_open` — never through a
        link, never a file with a second name (Codex #315-1)."""
        with os.fdopen(guarded_open(self.writable(path), append), "w", encoding="utf-8") as f:
            f.write(text)

    def write_json(self, path: Path, value) -> None:
        self.write_text(path, json.dumps(value, indent=1, sort_keys=True) + "\n")

    def out_folder(self, out: Path) -> Path:
        """The lane's <out> folder, or Refused: it is a real folder (no link in its way) directly
        under ~/m4run/out — the run folder m4_run.sh made — or that run's own corpus-<lane>
        folder, and nowhere else (Codex #313 F3)."""
        out = Path(out)
        # ~/m4run and ~/m4run/out are themselves: an alias would carry every "run folder" with it (Codex #315-2).
        m4run = self.out_root.parent
        if (os.path.islink(str(m4run)) or os.path.islink(str(self.out_root))
                or os.path.realpath(str(self.out_root)) != os.path.join(os.path.realpath(str(self.home)), "m4run", "out")):
            raise Refused("refused: ~/m4run or ~/m4run/out is a symlink or resolves somewhere else")
        root, real = os.path.realpath(str(self.out_root)), os.path.realpath(str(out))
        run_folder = real == os.path.join(root, out.name)
        # Inside a testbed run each corpus lane has its own folder in the run folder: <run>/corpus-<lane>.
        lane_folder = (out.name in {"corpus-" + lane for lane in LANES} and not os.path.islink(str(out.parent))
                       and real == os.path.join(root, out.parent.name, out.name))
        if (os.path.islink(str(out)) or not os.path.isdir(str(out)) or not (run_folder or lane_folder)
                or self.pristine(out) or _under(out, self.corpus)):
            raise Refused("refused: the lane's output folder is not a run folder under ~/m4run/out")
        return out

    def out_open(self, out: Path, name: str, append: bool = False) -> int:
        """A file descriptor on one of the lane's own files in its <out> folder (counts, words
        and build logs; outside the corpus). The folder is proven (`out_folder`); the file is
        opened without following a link and must be a regular file with ONE name — a hard link
        would share its bytes with a file somewhere else — and only then is it emptied
        (Codex #311 F2, #313 F2/F3)."""
        if "/" in name or name in ("", ".", ".."):
            raise Refused("refused: an output file is named by a bare file name")
        return guarded_open(self.out_folder(out) / name, append)

    def out_write(self, out: Path, name: str, text: str, append: bool = False) -> None:
        with os.fdopen(self.out_open(out, name, append), "w", encoding="utf-8") as f:
            f.write(text)


def guarded_open(path: Path, append: bool = False) -> int:
    """THE way the harness opens a file to write: never through a symlink (O_NOFOLLOW), only a
    regular file, and only one with ONE name — a hard link would share its bytes with a file
    somewhere else (a pristine copy). Only then is it emptied (or appended to). Returns the fd."""
    target = str(path)
    if os.path.islink(target):
        raise Refused("refused: a file the harness writes would be written through a link")
    try:
        fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | (os.O_APPEND if append else 0), 0o644)
    except OSError as error:
        raise Refused(f"refused: a file the harness writes could not be opened safely ({type(error).__name__})")
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        os.close(fd)
        raise Refused("refused: a file the harness writes has a second name or is not a plain file")
    if not append:
        os.ftruncate(fd, 0)
    return fd


# ── Words that may leave the M4 ───────────────────────────────────────────

_NOT_WORD = re.compile(r"[^A-Za-z0-9_,:+\-]")
_LONG_HEX = re.compile(r"[0-9a-fA-F]{24,}")      # a digest (or most of one) is not a word: only `sha_prefix` shortens one


def word(text, limit: int = 64) -> str:
    """An outcome word, codec or container name. Anything holding a character outside
    letters, digits and `_ , : + -` — a slash, a dot, a space — is not a word and becomes
    `scrubbed` whole, so a path, a filename with its extension or a sentence cannot pass.
    (The drivers emit enum case names only; this is the second lock, not the first.)"""
    text = "" if text is None else str(text)
    if not text:
        return "none"
    if _NOT_WORD.search(text) or len(text) > limit or _LONG_HEX.search(text):
        return "scrubbed"
    return text


def stratum_word(why: str) -> str:
    """The manifest's `why` (a fixed phrase per stratum, e.g. "one-sided sound") as one word."""
    return re.sub(r"[^A-Za-z0-9]+", "_", why).strip("_")[:48] or "none"


def sha_prefix(sha: str) -> str:
    return sha[:12] if re.fullmatch(r"[0-9a-f]{64}", sha) else "scrubbed"


# ── Manifest ──────────────────────────────────────────────────────────────

class Entry:
    __slots__ = ("sha", "original", "size", "stratum", "path")

    def __init__(self, sha: str, original: str, size: int, stratum: str, path: Path):
        self.sha, self.original, self.size, self.stratum, self.path = sha, original, size, stratum, path


def load_manifest(seal: Seal) -> List[Entry]:
    try:
        rows = json.loads((seal.corpus / MANIFEST).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise Refused(f"refused: ~/corpus/{MANIFEST} is missing or unreadable")
    entries, seen = [], set()
    for row in rows:
        sha, original = str(row["sha256"]).lower(), str(row["path"])
        if not re.fullmatch(r"[0-9a-f]{64}", sha) or not original.startswith("/Volumes/") or ".." in original.split("/"):
            raise Refused("refused: a manifest row is not a sha256 plus an original /Volumes path")
        if sha in seen:
            raise Refused("refused: the manifest lists one content twice")
        seen.add(sha)
        entries.append(Entry(sha, original, int(row["size"]), str(row.get("why", "")), seal.media / original.lstrip("/")))
    if not entries:
        raise Refused("refused: the manifest is empty")
    return sorted(entries, key=lambda e: e.sha)


def check_sha_list(seal: Seal, entries: List[Entry]) -> int:
    """The second document (sha256 + relative path) names the same contents at the same places."""
    listed = {}
    for line in (seal.corpus / SHA_LIST).read_text(encoding="utf-8").splitlines():
        if line.strip():
            sha, rel = line.split(None, 1)
            listed[sha.lower()] = os.path.normpath(str(seal.corpus / rel.strip().lstrip("*")))
    wrong = sum(1 for e in entries if listed.get(e.sha) != os.path.normpath(str(e.path)))
    return wrong + abs(len(listed) - len(entries))


def missing_or_wrong_size(entries: Iterable[Entry]) -> Tuple[int, int]:
    missing = wrong = 0
    for e in entries:
        try:
            if os.stat(str(e.path)).st_size != e.size:
                wrong += 1
        except OSError:
            missing += 1
    return missing, wrong


# ── prepare: the sealed catalog ───────────────────────────────────────────
#
# An offline transform, documented here because the catalog has no supported
# export/import of a subset. It never opens, edits or deletes from the
# source: a NEW database is created with the source's own schema objects
# (every table, index and TRIGGER, copied verbatim from its sqlite_master),
# and the rows are INSERTed through those triggers:
#
#   grdb_migrations   every row (the app's read-only open checks they are complete)
#   catalog_state     its schema_version; master_archive is left NULL — the
#                     sealed catalog names no Master Archive
#   generations       the one row
#   volumes           the rows the chosen files name
#   content           one row per manifest digest
#   files             per manifest entry, the ONE live row at the manifest's
#                     path with the manifest's digest; full_path, path_fold
#                     and directory get the corpus prefix, and the audit-seen
#                     stamp is NULL (what the schema's own
#                     files_path_change_clears_audit_stamp does on a move)
#   user_dates, workflow_tags   the rows for those digests (Check Media's
#                     sound-presence rule reads the date and the tags)
#   row_knowledge     ONE 'pair' row per chosen file that has an A/V pair link
#                     in the source: the link the app would load for that row
#                     — the newest row_knowledge 'pair' value of the row, else
#                     its import-era link (import_items → legacy_pair_ids) —
#                     written the way the app itself writes a link today
#                     (field 'pair', source 'app:corpus-prepare', the JSON
#                     object the loader reads). The import evidence itself is
#                     NOT carried: `import_runs_open_first` refuses a finished
#                     run and a run cannot be finished without every one of
#                     its occurrences; row_knowledge is the schema's own door
#                     for a link, and the loader lets it win. The ids inside a
#                     link are carried verbatim, so a half whose partner is
#                     not in the corpus keeps a link to a row that is not here.
#
# Everything else is left empty. NOT carried, and why: other copies of the
# same content and removed rows (no corpus file stands behind them);
# captions, transcripts, notes, people (family text the engines do not
# need); the import evidence. volume_uuid and the identity stamps still
# describe the ORIGINAL drive and file.

CARRIED_BY_DIGEST = ("user_dates", "workflow_tags")
AUDIT_COLUMNS = ("audit_seen_volume_uuid", "audit_seen_mount_from", "audit_seen_device_key", "audit_seen_at")


def _catalog_names() -> Tuple[str, str]:
    """The catalog's file name and its latch name, from the one module that names them
    (scripts/catalog_db.py, shipped beside this file; `main` puts its folder on the path)."""
    import catalog_db
    return catalog_db.DATABASE_FILE_NAME, catalog_db.LATCH_FILE_NAME


def _columns(conn: sqlite3.Connection, schema: str, table: str) -> List[str]:
    return [row[1] for row in conn.execute(f"PRAGMA {schema}.table_info({table})")]


def build_catalog(seal: Seal, source: Path, entries: List[Entry], dest: Path, root: Optional[Path] = None) -> Dict[str, int]:
    """Create `dest` (new file, rollback journal) from `source` as described above. `root` is
    the folder the rows' paths are rewritten under: the corpus media, or (the verbs lane) a
    run's folder of clones laid out the same way."""
    seal.writable(dest)
    for suffix in ("-wal", "-journal", "-shm"):
        if os.path.exists(str(source) + suffix):
            raise Refused(f"refused: the source backup has a {suffix} file beside it — it is not a finished backup")
    if not source.is_file():
        raise Refused(f"refused: ~/corpus/{SOURCE_BACKUP} is missing")
    if dest.exists():
        raise Refused("refused: the build file already exists")
    uri = "file:" + urllib.parse.quote(str(source.resolve())) + "?immutable=1"      # never written, no sidecar made
    conn = sqlite3.connect("file:" + urllib.parse.quote(str(dest)), uri=True, isolation_level=None)
    try:
        conn.execute("PRAGMA journal_mode = DELETE")
        conn.execute("PRAGMA foreign_keys = ON")
        conn.execute("ATTACH DATABASE ? AS src", (uri,))
        objects = conn.execute(
            "SELECT type, name, tbl_name, sql FROM src.sqlite_master WHERE sql IS NOT NULL "
            "ORDER BY CASE type WHEN 'table' THEN 0 WHEN 'index' THEN 1 WHEN 'view' THEN 2 ELSE 3 END, rowid").fetchall()
        virtual = [name for kind, name, _, sql in objects if kind == "table" and sql.upper().startswith("CREATE VIRTUAL")]
        conn.execute("BEGIN")
        for kind, name, table, sql in objects:
            if name.startswith("sqlite_") or any(table != v and table.startswith(v + "_") for v in virtual):
                continue                                    # internal tables; an FTS table makes its own shadow tables
            conn.execute(sql)
        for pragma in ("user_version", "application_id"):
            conn.execute(f"PRAGMA main.{pragma} = {int(conn.execute(f'PRAGMA src.{pragma}').fetchone()[0])}")

        conn.execute("CREATE TEMP TABLE chosen (sha TEXT PRIMARY KEY, original TEXT NOT NULL, file_id TEXT)")
        conn.executemany("INSERT INTO chosen (sha, original) VALUES (?, ?)", [(e.sha, e.original) for e in entries])
        conn.execute(
            "UPDATE chosen SET file_id = (SELECT f.id FROM src.files f WHERE f.content_digest = chosen.sha "
            "AND f.full_path = chosen.original AND f.removal_state IS NULL) "
            "WHERE (SELECT count(*) FROM src.files f WHERE f.content_digest = chosen.sha "
            "AND f.full_path = chosen.original AND f.removal_state IS NULL) = 1")
        unmatched = conn.execute("SELECT count(*) FROM chosen WHERE file_id IS NULL").fetchone()[0]
        if unmatched:
            raise Refused(f"refused: {unmatched} manifest entries do not have exactly one live row at their path and digest in the backup")

        if not conn.execute("SELECT count(*) FROM src.sqlite_master WHERE name = 'grdb_migrations'").fetchone()[0]:
            raise Refused("refused: the backup has no grdb_migrations table — it is not a catalog the app has opened")
        conn.execute("INSERT INTO main.grdb_migrations SELECT * FROM src.grdb_migrations")
        conn.execute("INSERT INTO main.catalog_state (singleton, schema_version, master_archive, imported_from) "
                     "SELECT 1, schema_version, NULL, NULL FROM src.catalog_state WHERE singleton = 1")
        generation_columns = ", ".join(_columns(conn, "src", "generations"))
        conn.execute(f"INSERT INTO main.generations ({generation_columns}) SELECT {generation_columns} FROM src.generations")
        conn.execute("INSERT INTO main.volumes SELECT * FROM src.volumes WHERE volume_uuid IN "
                     "(SELECT f.volume_uuid FROM src.files f JOIN chosen c ON c.file_id = f.id)")
        conn.execute("INSERT INTO main.content SELECT * FROM src.content WHERE digest IN (SELECT sha FROM chosen)")

        prefix = str(root if root is not None else seal.media)
        columns = _columns(conn, "src", "files")
        for needed in ("id", "full_path", "path_fold", "directory", "volume_case_sensitive", "content_digest", "size_bytes"):
            if needed not in columns:
                raise Refused(f"refused: the backup's files table has no {needed} column — the schema moved; update the transform")
        select = []
        for column in columns:
            if column == "full_path":
                select.append("? || f.full_path")
            elif column == "directory":
                select.append("CASE WHEN f.directory IS NULL THEN NULL ELSE ? || f.directory END")
            elif column == "path_fold":
                select.append("CASE WHEN f.volume_case_sensitive = 0 THEN lower(?) ELSE ? END || f.path_fold")
            elif column in AUDIT_COLUMNS:
                select.append("NULL")
            else:
                select.append("f." + column)
        binds = []
        for column in columns:
            binds += [prefix] if column in ("full_path", "directory") else [prefix, prefix] if column == "path_fold" else []
        conn.execute(f"INSERT INTO main.files ({', '.join(columns)}) SELECT {', '.join(select)} "
                     "FROM src.files f JOIN chosen c ON c.file_id = f.id ORDER BY f.id", binds)
        for table in CARRIED_BY_DIGEST:
            conn.execute(f"INSERT INTO main.{table} SELECT * FROM src.{table} WHERE digest IN (SELECT sha FROM chosen)")
        pairs = carry_pair_links(conn)
        conn.execute("COMMIT")

        integrity = [row[0] for row in conn.execute("PRAGMA main.integrity_check")]
        if integrity != ["ok"]:
            raise Refused("refused: the built catalog fails integrity_check")
        if conn.execute("PRAGMA main.foreign_key_check").fetchall():
            raise Refused("refused: the built catalog fails foreign_key_check")
        counts = {t: conn.execute(f"SELECT count(*) FROM main.{t}").fetchone()[0]
                  for t in ("files", "content", "volumes", "grdb_migrations") + CARRIED_BY_DIGEST}
        counts["triggers"] = conn.execute("SELECT count(*) FROM main.sqlite_master WHERE type = 'trigger'").fetchone()[0]
        counts["source_triggers"] = conn.execute("SELECT count(*) FROM src.sqlite_master WHERE type = 'trigger'").fetchone()[0]
        counts["source_files"] = conn.execute("SELECT count(*) FROM src.files").fetchone()[0]
        counts["schema_version"] = conn.execute("SELECT schema_version FROM main.catalog_state").fetchone()[0]
        counts.update(pairs)
        return counts
    except sqlite3.Error as error:
        # The engine's own message goes to the lane's log on the M4 (stderr), never into what a
        # caller reads back: a trigger's words are the schema's, but nothing here proves it (Codex #311 F8).
        print("corpus prepare: sqlite said: " + str(error), file=sys.stderr)
        raise Refused(f"refused: the schema would not take the transform ({type(error).__name__}; "
                      "the engine's message is in corpus.log on the M4)")
    finally:
        conn.close()


def carry_pair_links(conn: sqlite3.Connection) -> Dict[str, int]:
    """Inside the build transaction: one row_knowledge 'pair' row per chosen file whose source
    row has an A/V pair link (see the transform's notes above). Returns counts: links carried,
    how many came from each source, and how many pair groups have two or more halves here."""
    have = {row[0] for row in conn.execute("SELECT name FROM src.sqlite_master WHERE type = 'table'")}
    links: Dict[str, str] = {}
    counts = {"pair_links": 0, "pair_links_from_import": 0, "pair_links_from_app": 0, "pair_groups_whole": 0,
              "pair_halves_alone": 0}
    if "row_knowledge" not in have or "row_knowledge" not in {
            row[0] for row in conn.execute("SELECT name FROM main.sqlite_master WHERE type = 'table'")}:
        return counts                                        # a catalog from before the link had a table of its own
    if {"import_items", "legacy_pair_ids"} <= have:
        for file_id, paired_with, group in conn.execute(
                "SELECT ii.landed_ref, lp.paired_with_id, lp.pair_group_id FROM src.import_items ii "
                "JOIN src.legacy_pair_ids lp ON lp.import_run = ii.import_run AND lp.source_ordinal = ii.source_ordinal "
                "JOIN chosen c ON c.file_id = ii.landed_ref "
                "WHERE ii.item_kind = 'row' AND ii.landed_table = 'files'"):     # 'row' = an occurrence of the old catalog file (the schema's CHECK)
            link = {k: v for k, v in (("pairedWithID", paired_with), ("pairGroupID", group)) if v is not None}
            links[file_id] = json.dumps(link, sort_keys=True)
            counts["pair_links_from_import"] += 1
    for file_id, value in conn.execute(
            "SELECT rk.file_id, rk.value_json FROM src.row_knowledge rk JOIN chosen c ON c.file_id = rk.file_id "
            "WHERE rk.field = 'pair' AND rk.write_id = (SELECT max(write_id) FROM src.row_knowledge "
            "WHERE file_id = rk.file_id AND field = 'pair')"):
        if file_id in links:
            counts["pair_links_from_import"] -= 1            # the app's later word replaces the import's
        links[file_id] = value
        counts["pair_links_from_app"] += 1
    generation = 0
    if "generation" in _columns(conn, "src", "generations"):
        generation = int(conn.execute("SELECT coalesce(max(generation), 0) FROM src.generations").fetchone()[0])
    groups: Counter = Counter()
    now = int(time.time())
    for file_id, value in sorted(links.items()):
        try:
            link = json.loads(value)
        except ValueError:
            link = None
        if not isinstance(link, dict) or not link:           # '{}' and 'null' both say: no link
            counts["pair_links_from_app"] -= 1
            continue
        conn.execute("INSERT INTO main.row_knowledge (file_id, digest, field, value_json, set_at, source, import_run, generation) "
                     "SELECT id, content_digest, 'pair', ?, ?, 'app:corpus-prepare', NULL, ? FROM main.files WHERE id = ?",
                     (json.dumps(link, sort_keys=True), now, generation, file_id))
        counts["pair_links"] += 1
        groups[str(link.get("pairGroupID") or link.get("pairedWithID") or file_id)] += 1
    counts["pair_groups_whole"] = sum(1 for n in groups.values() if n >= 2)
    counts["pair_halves_alone"] = sum(1 for n in groups.values() if n == 1)
    return counts


def verify_catalog(seal: Seal, database: Path, entries: List[Entry], root: Optional[Path] = None) -> Dict[str, int]:
    """Through the scripts' read-only door: every manifest file has a row, every row's file
    exists with the row's size, and the catalog names no Master Archive."""
    import catalog_db
    seal.contained(database, Path(database).parent)          # the file itself, never a link to another catalog
    if not (_under(database, seal.state) or _under(database, seal.work_root)):
        raise Refused("refused: the catalog to verify is not inside ~/corpus/{state,work}")
    conn = catalog_db.connect(database)
    try:
        rows = conn.execute("SELECT content_digest, full_path, size_bytes, removal_state FROM files").fetchall()
        designation = conn.execute("SELECT master_archive FROM catalog_state WHERE singleton = 1").fetchone()
    finally:
        conn.close()
    by_sha = {row[0]: row for row in rows}
    result = {"rows": len(rows), "manifest": len(entries), "without_row": 0, "row_not_in_manifest": 0,
              "file_missing": 0, "size_differs": 0, "outside_corpus": 0, "removed_rows": 0,
              "archive_designation": 0 if not designation or designation[0] is None else 1}
    wanted = {e.sha: e for e in entries}
    result["without_row"] = sum(1 for sha in wanted if sha not in by_sha)
    for sha, path, size, removal in rows:
        entry = wanted.get(sha)
        if entry is None:
            result["row_not_in_manifest"] += 1
            continue
        if removal is not None:
            result["removed_rows"] += 1
        if os.path.normpath(path) != os.path.normpath(str(entry.path)) or not _under(Path(path), root if root is not None else seal.media):
            result["outside_corpus"] += 1
            continue
        try:
            if os.stat(path).st_size != size or size != entry.size:
                result["size_differs"] += 1
        except OSError:
            result["file_missing"] += 1
    result["ok"] = int(result["rows"] == result["manifest"] and not any(
        result[k] for k in ("without_row", "row_not_in_manifest", "file_missing", "size_differs",
                            "outside_corpus", "removed_rows", "archive_designation")))
    return result


def prepare(seal: Seal, out: Optional[Path] = None) -> Tuple[int, List[str]]:
    seal.check()
    database_name, latch_name = _catalog_names()
    entries = load_manifest(seal)
    lines = []
    disagree = check_sha_list(seal, entries)
    if disagree:
        raise Refused(f"refused: {MANIFEST} and {SHA_LIST} disagree on {disagree} entries")
    missing, wrong = missing_or_wrong_size(entries)
    if missing or wrong:
        raise Refused(f"refused: {missing} corpus files are missing and {wrong} are not the manifest's size")
    seal.mkdir(seal.state)
    for name in ("home", "caches"):
        seal.mkdir(seal.state / name)
    building = seal.state / f"building-{os.getpid()}"
    if building.exists():
        raise Refused("refused: a build folder with this pid is already there")
    seal.mkdir(building)
    try:
        counts = build_catalog(seal, seal.corpus / SOURCE_BACKUP, entries, building / database_name)
        seal.write_text(building / latch_name, "{}\n")       # the read doors want the latch beside the file
        verdict = verify_catalog(seal, building / database_name, entries)
        if not verdict["ok"]:
            raise Refused("refused: the built catalog did not verify — " + ", ".join(
                f"{k}={v}" for k, v in sorted(verdict.items()) if v and k not in ("rows", "manifest")))
        os.replace(str(building / database_name), str(seal.writable(seal.state / database_name)))
        os.replace(str(building / latch_name), str(seal.writable(seal.state / latch_name)))
    finally:
        shutil.rmtree(str(seal.writable(building)), ignore_errors=True)
    strata = Counter(e.stratum for e in entries)
    record = {"transform_version": TRANSFORM_VERSION, "prepared_at": time.strftime("%Y-%m-%d %H:%M:%S"),
              "manifest_sha256": hashlib.sha256((seal.corpus / MANIFEST).read_bytes()).hexdigest(),
              "files": len(entries), "bytes": sum(e.size for e in entries), "strata": dict(strata),
              "counts": counts, "verify": verdict}
    seal.write_json(seal.state / "prepare.json", record)
    lines.append(f"corpus prepare: GREEN {verdict['rows']} rows for {len(entries)} manifest files "
                 f"({record['bytes'] / 1e9:.1f} GB), every file present at its row's size")
    lines.append(f"  carried: files={counts['files']} content={counts['content']} volumes={counts['volumes']} "
                 f"user_dates={counts['user_dates']} workflow_tags={counts['workflow_tags']} "
                 f"migrations={counts['grdb_migrations']}; schema v{counts['schema_version']}, "
                 f"{counts['triggers']} of {counts['source_triggers']} triggers in place; "
                 f"source backup rows={counts['source_files']} (not opened for writing)")
    lines.append(f"  pair links carried: {counts['pair_links']} ({counts['pair_links_from_import']} from the import, "
                 f"{counts['pair_links_from_app']} the app's own) — {counts['pair_groups_whole']} pairs with two or more halves "
                 f"in the corpus, {counts['pair_halves_alone']} halves whose partner is not in the corpus")
    lines.append("  not carried: other copies and removed rows, the import evidence, captions/transcripts/notes/people, the Master Archive designation")
    if out is not None:
        seal.out_write(Path(out), "corpus-summary.txt", "\n".join(lines) + "\n")
    return EXIT_GREEN, lines


def sealed_state_ready(seal: Seal, entries: List[Entry]) -> Path:
    database_name, latch_name = _catalog_names()
    database = seal.state / database_name
    if not database.is_file() or not (seal.state / latch_name).is_file():
        raise Refused("refused: the sealed catalog is not built — run `scripts/corpus_run.sh prepare` first")
    verdict = verify_catalog(seal, database, entries)
    if not verdict["ok"]:
        raise Refused("refused: the sealed catalog no longer matches the corpus — run `scripts/corpus_run.sh prepare`")
    try:
        built_by = json.loads(seal.contained(seal.state / "prepare.json", seal.state).read_text(encoding="utf-8")).get("transform_version")
    except (OSError, ValueError, AttributeError, Refused):
        built_by = None
    if built_by != TRANSFORM_VERSION:
        raise Refused(f"refused: the sealed catalog was built by transform {word(str(built_by))}, this harness wants "
                      f"{TRANSFORM_VERSION} — run `scripts/corpus_run.sh prepare`")
    return database


# ── Running a lane ────────────────────────────────────────────────────────

def read_events(progress: Path) -> List[dict]:
    events = []
    try:
        with open(progress, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    events.append(json.loads(line))
                except ValueError:
                    continue                                 # a line cut by a crash mid-write
    except OSError:
        pass
    return events


def settle(events: List[dict], engines: List[str], results: Dict[str, dict]) -> Tuple[int, Optional[str]]:
    """Fold one launch's events into `results` (sha -> record). A file that began and never
    ended is a `crash` at the engine it was in; a file the driver cut at its deadline arrives
    with `timeout` already written. Engines after either are `not_run`. Returns (files settled,
    the driver's refusal word if it refused)."""
    began, ended, refusal = [], set(), None
    per = defaultdict(dict)
    for ev in events:
        kind, sha = ev.get("ev"), ev.get("sha")
        if kind == "refused":
            refusal = word(ev.get("why"))
        elif kind == "begin" and sha:
            began.append(sha)
        elif kind == "end" and sha:
            ended.add(sha)
        elif kind == "facts" and sha:
            per[sha].setdefault("facts", {}).update(ev)      # a driver may report facts in more than one step
        elif kind == "engine" and sha:
            per[sha].setdefault("engines", {})[str(ev.get("engine"))] = ev
    settled = 0
    for sha in began:
        if sha not in results or results[sha].get("settled"):
            continue
        record, seen = results[sha], per[sha].get("engines", {})
        facts = per[sha].get("facts", {})
        for key in ("container", "vcodec", "acodec"):
            if key in facts:
                record[key] = word(facts[key])
        for key in ("duration", "bytes", "audio_streams", "peak_dbfs"):
            if isinstance(facts.get(key), (int, float)):
                record[key] = facts[key]
        cut = False
        for engine in engines:
            ev = seen.get(engine)
            if ev is not None:
                record[engine] = word(ev.get("outcome"))
                record[engine + "_kinds"] = sorted({word(k) for k in ev.get("kinds") or []})
                if isinstance(ev.get("s"), (int, float)):
                    record[engine + "_s"] = round(float(ev["s"]), 2)
                cut = cut or record[engine] == "timeout"
            elif cut:
                record[engine] = "not_run"
            elif sha in ended:
                record[engine] = "not_run"
            else:
                record[engine], cut = "crash", True
        if sha not in ended and not cut:
            record["unfinished"] = True                      # the host died after its last answer and before `end` (Codex #311 F6)
        record["settled"] = True
        settled += 1
    return settled, refusal


def outcome_of(record: dict, engines: List[str]) -> str:
    return " ".join(f"{e}={record.get(e, 'not_run')}" for e in engines)


def find_xctestrun(derived_data: Path) -> Path:
    products = derived_data / "Build" / "Products"
    candidates = sorted((p for p in products.glob("*.xctestrun") if not p.name.startswith("corpus-")),
                        key=lambda p: p.stat().st_mtime, reverse=True)
    def targets(value) -> Iterable[dict]:
        if isinstance(value, list):
            for v in value:
                yield from targets(v)
        elif isinstance(value, dict):
            if "TestBundlePath" in value:
                yield value
            for v in value.values():
                yield from targets(v)

    for candidate in candidates:                             # one per test plan; the UI plans carry no unit-test target
        try:
            with open(candidate, "rb") as f:
                plist = plistlib.load(f)
        except (OSError, ValueError, plistlib.InvalidFileException):
            continue
        if any(t.get("BlueprintName") == "VideoScanTests" for t in targets(plist)):
            return candidate
    raise Refused("refused: the build produced no .xctestrun with the VideoScanTests target")


def patch_xctestrun(source: Path, dest: Path, environment: Dict[str, str]) -> None:
    """The gauntlet's patch (Runner.swift `patch`): every test target's host gets the sealed roots."""
    def patch(value):
        if isinstance(value, list):
            return [patch(v) for v in value]
        if isinstance(value, dict):
            out = {k: patch(v) for k, v in value.items()}
            if "TestBundlePath" in out:
                env = dict(out.get("EnvironmentVariables") or {})
                env.update(environment)
                out["EnvironmentVariables"] = env
                env.pop("OS_ACTIVITY_DT_MODE", None)         # do not mirror the engines' os_log lines (they name files) into the test log
                for key in ("OnlyTestIdentifiers", "SkipTestIdentifiers"):     # the plan's own lists; -only-testing picks the driver
                    out.pop(key, None)
            return out
        return value
    with open(source, "rb") as f:
        plist = plistlib.load(f)
    fd = os.open(str(dest), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)    # a new file, never through a link
    with os.fdopen(fd, "wb") as f:
        plistlib.dump(patch(plist), f)


def _run(command: List[str], seal: Seal, out: Path, log_name: str, env: Dict[str, str], cwd: Path) -> int:
    """One child, output appended to the lane's own log in <out> (opened through the seal: never
    through a link, Codex #313 F2), waited for. Never signalled from here. fd 9 is the testbed
    lock (m4_run.sh take_lock): passed on so the lock lives as long as the work."""
    try:
        os.fstat(9)
        pass_fds: Tuple[int, ...] = (9,)
    except OSError:
        pass_fds = ()
    with os.fdopen(seal.out_open(out, log_name, append=True), "ab") as f:
        f.write(("\n$ " + " ".join(command[:6]) + " …\n").encode())
        f.flush()
        return subprocess.call(command, cwd=str(cwd), stdin=subprocess.DEVNULL, stdout=f, stderr=subprocess.STDOUT,
                               env=env, pass_fds=pass_fds)


class Lane:
    """One lane run on the host. `xcodebuild` is a seam for the tests (a fake driver)."""

    def __init__(self, seal: Seal, lane: str, sha: str, stamp: str, out: Path, worktree: Path, derived_data: Path,
                 bin_dir: Path, deadline: Optional[int] = None, limit: Optional[int] = None,
                 xcodebuild: str = "xcodebuild"):
        self.seal, self.lane, self.sha, self.stamp = seal, lane, sha, stamp
        self.out, self.worktree, self.derived_data, self.bin_dir = Path(out), Path(worktree), Path(derived_data), Path(bin_dir)
        self.test_class, self.engines, default_deadline, self.sources = LANES[lane]
        self.deadline = int(deadline or default_deadline)
        self.limit, self.xcodebuild = limit, xcodebuild
        self.work = seal.work_root / f"{stamp}-{lane}"
        self.report_dir = seal.reports / lane / sha / stamp
        self.lines: List[str] = []
        self.launches = 0
        self.build_seconds = 0.0
        self.overlay_installed = False
        self.closing: Dict[str, int] = {}
        self.housekeeping: List[str] = []
        # The coverage run (corpus_coverage.py) sets this: the build is instrumented and every launch
        # leaves its result bundle (with coverage) here, in the coverage run's own work folder. None: no coverage.
        self.profiles: Optional[Path] = None

    # -- the overlay: untracked driver sources in the testbed, for this run only

    def clear_overlay(self) -> None:
        overlay = self.worktree / OVERLAY_DIR
        if overlay.exists():
            kept = self.out / f"overlay-{int(time.time() * 1000)}"
            shutil.move(str(overlay), str(kept))             # moved out, never deleted in place

    def install_overlay(self) -> None:
        tracked = subprocess.run(["git", "-C", str(self.worktree), "ls-files", "--", OVERLAY_DIR],
                                 capture_output=True, text=True).stdout.strip()
        if tracked:
            raise Refused("refused: this ref tracks files in the harness's overlay folder")
        # The overlay's parent is the testbed's own test folder: a ref that makes it (or anything
        # above it) a symlink would send the driver sources somewhere else (Codex #311 F2).
        parent = (self.worktree / OVERLAY_DIR).parent
        expected = os.path.join(os.path.realpath(str(self.worktree)), os.path.dirname(OVERLAY_DIR))
        if os.path.realpath(str(parent)) != expected or self.seal.pristine(parent) or _under(self.worktree, self.seal.corpus):
            raise Refused("refused: the testbed's test folder is not a folder of the testbed (a symlink in this ref?)")
        self.clear_overlay()
        overlay = self.worktree / OVERLAY_DIR
        overlay.mkdir(parents=True)
        self.overlay_installed = True
        for name in self.sources:
            shutil.copyfile(str(self.bin_dir / name), str(overlay / name))

    def engine_present(self) -> bool:
        return self.lane != "proof" or any(self.worktree.glob(PROOF_ENGINE_GLOB))

    # -- build and launches

    def build(self) -> int:
        t0 = time.time()
        coverage = ["-enableCodeCoverage", "YES"] if self.profiles is not None else []
        rc = _run([self.xcodebuild, "build-for-testing", "-project", str(self.worktree / "VideoScan/VideoScan.xcodeproj"),
                   "-scheme", "VideoScan", "-configuration", "Debug", "-destination", "platform=macOS",
                   "-derivedDataPath", str(self.derived_data), *coverage, "CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual"],
                  self.seal, self.out, "corpus-build.log", dict(os.environ), self.worktree)
        self.build_seconds = time.time() - t0
        return rc

    def launch(self, pending: List[Entry], database: Path, xctestrun: Path) -> List[dict]:
        self.launches += 1
        seal = self.seal
        config = self.work / f"config-{self.launches}.json"
        progress = self.work / f"progress-{self.launches}.jsonl"
        seal.write_json(config, {
            "lane": self.lane, "corpusRoot": str(seal.corpus), "stateRoot": str(seal.state), "catalog": str(database),
            "mediaRoot": str(seal.media), "work": str(self.work), "progress": str(progress),
            "deadlineSeconds": self.deadline, "pending": [self.pending_item(e) for e in pending], **self.config_extra()})
        seal.write_text(progress, "")
        home = self.home()
        sealed = {"HOME": str(home), "CFFIXED_USER_HOME": str(home),
                  "TMPDIR": str(self.work / "tmp") + "/", "VS_CORPUS_CONFIG": str(config)}
        patched = xctestrun.with_name(f"corpus-{self.stamp}-{self.launches}.xctestrun")    # beside it: __TESTROOT__ is relative
        if os.path.lexists(str(patched)) or seal.pristine(patched) or _under(patched, seal.corpus):
            raise Refused("refused: the patched test-run file would land somewhere it must not")
        patch_xctestrun(xctestrun, patched, sealed)
        env = dict(os.environ)
        env.update({k: v for k, v in sealed.items() if k != "VS_CORPUS_CONFIG"})
        for key in ("CLANG_MODULE_CACHE_PATH", "SWIFT_MODULECACHE_PATH", "SWIFTPM_MODULECACHE_OVERRIDE", "XDG_CACHE_HOME"):
            env[key] = str(seal.state / "caches")
        # Coverage: xcodebuild collects it into the launch's result bundle (the test host is ended without
        # its exit handlers, so a bare LLVM_PROFILE_FILE writes nothing, and with -xctestrun no raw profile
        # is left on disk — both measured on the M4, 2026-11-18). The bundle goes in the coverage run's
        # folder (`profiles`), which outlives this lane's work folder; corpus_coverage.py reads it with xccov.
        coverage = (["-enableCodeCoverage", "YES",
                     "-resultBundlePath", str(seal.writable(self.profiles / f"result-{self.launches}.xcresult"))]
                    if self.profiles is not None else [])
        try:
            _run([self.xcodebuild, "test-without-building", "-xctestrun", str(patched), "-destination",
                  "platform=macOS,arch=arm64", "-parallel-testing-enabled", "NO",
                  "-test-timeouts-enabled", "NO",            # one test method walks every file; the per-file deadline is the driver's
                  f"-only-testing:VideoScanTests/{self.test_class}", *coverage],
                 self.seal, self.out, "corpus-test.log", env, self.worktree)
        finally:
            if patched.exists():
                shutil.move(str(patched), str(self.out / patched.name))
        return read_events(progress)

    # -- what a lane may change about a launch (VerbsLane does)

    def record_extra(self, entry: Entry) -> dict:
        return {}

    def home(self) -> Path:
        """The test host's HOME: the sealed state's, kept between runs."""
        return self.seal.state / "home"

    def pending_item(self, entry: Entry) -> dict:
        return {"sha": entry.sha, "path": str(entry.path)}

    def config_extra(self) -> dict:
        return {}

    def scope(self, entries: List[Entry]) -> List[Entry]:
        if self.lane == "proof":
            entries = [e for e in entries if e.stratum == PROOF_STRATUM]
        return entries[: self.limit] if self.limit else entries

    def stage(self, entries: List[Entry], database: Path) -> Tuple[List[Entry], Path]:
        """Before the build: the files and the catalog the driver will be given."""
        return entries, database

    def after(self, results: Dict[str, dict], report: dict) -> None:
        """After the launches, before the report is stored."""

    def run_files(self, entries: List[Entry], database: Path) -> Tuple[Dict[str, dict], Dict[str, object]]:
        results = {e.sha: {"stratum": stratum_word(e.stratum), "size": e.size, **self.record_extra(e)} for e in entries}
        hello: Dict[str, object] = {}
        xctestrun = find_xctestrun(self.derived_data)
        self.seal.mkdir(self.work / "tmp")
        while True:
            pending = [e for e in entries if not results[e.sha].get("settled")]
            if not pending:
                break
            events = self.launch(pending, database, xctestrun)
            for ev in events:
                if ev.get("ev") == "hello" and not hello:
                    hello = {k: ev.get(k) for k in ("homeSealed", "records", "archiveDesignation", "testHost")}
                if ev.get("ev") == "verbs":                  # the verbs driver's closing counts
                    self.closing = {k: ev[k] for k in ("trashFiles", "trashedByEngines", "strayTrashFiles", "receiptsInRun",
                                                       "receiptsOutsideTheRun", "records")
                                    if isinstance(ev.get(k), int) and not isinstance(ev.get(k), bool)}
            settled, refusal = settle(events, self.engines, results)
            if refusal:
                raise Refused(f"refused by the driver: {refusal}")
            if settled == 0:                                 # no progress: never loop on a driver that cannot start
                raise Refused("the driver started no file — see corpus-test.log on the host")
        return results, hello

    # -- the report

    def report(self, results: Dict[str, dict], hello: Dict[str, object], wall: float, engine_present: bool = True) -> dict:
        engines = self.engines
        totals = {e: Counter() for e in engines}
        by_stratum: Dict[str, dict] = {}
        by_format: Dict[str, dict] = {}
        failures = Counter()
        for record in results.values():
            fmt = "{} | {} | {}".format(record.get("container", "unknown"), record.get("vcodec", "unknown"),
                                        record.get("acodec", "unknown"))
            for table, key in ((by_stratum, record.get("role") or record["stratum"]), (by_format, fmt)):
                row = table.setdefault(key, {"files": 0, **{e: Counter() for e in engines}})
                row["files"] += 1
                for e in engines:
                    row[e][record.get(e, "not_run")] += 1
            for e in engines:
                outcome = record.get(e, "not_run")
                totals[e][outcome] += 1
                if outcome in ("crash", "timeout") or outcome.startswith("error") or any(w in outcome for w in LOSS_WORDS):
                    failures[e + ":" + outcome] += 1
            if record.get("unfinished"):
                failures["end:crash"] += 1                   # RED: a file that began and never ended
        return {"lane": self.lane, "sha": self.sha, "stamp": self.stamp, "host": self.seal.hostname,
                "engine_present": engine_present, "files": len(results),
                "bytes": sum(r.get("size", 0) for r in results.values()),
                "media_seconds": round(sum(r.get("duration", 0) or 0 for r in results.values()), 1),
                "wall_s": round(wall, 1), "build_s": round(self.build_seconds, 1), "launches": self.launches,
                "limit": self.limit,
                "deadline_s": self.deadline, "engines": {e: dict(c) for e, c in totals.items()},
                "failures": dict(failures), "seal": hello,
                "by_stratum": {k: {kk: (dict(vv) if isinstance(vv, Counter) else vv) for kk, vv in v.items()}
                               for k, v in by_stratum.items()},
                "by_format": {k: {kk: (dict(vv) if isinstance(vv, Counter) else vv) for kk, vv in v.items()}
                              for k, v in by_format.items()}}

    def store(self, report: dict, results: Dict[str, dict]) -> None:
        seal = self.seal
        seal.mkdir(self.report_dir)
        outcomes = {}
        for sha, record in results.items():
            kept = {k: v for k, v in record.items() if k not in ("settled",)}
            kept["outcome"] = outcome_of(record, self.engines)
            outcomes[sha] = kept
        seal.write_json(self.report_dir / "outcomes.json", outcomes)
        seal.write_json(self.report_dir / "report.json", report)
        text = render(report, per_file=outcomes if self.lane in ("proof", "verbs") else None, against=report.get("against"))
        text += self.housekeeping
        seal.write_text(self.report_dir / "report.txt", "\n".join(text) + "\n")
        seal.out_write(self.out, "corpus-summary.txt", "\n".join(text) + "\n")
        seal.out_write(self.out, VERDICT_FILE, json.dumps(verdict_facts(report), indent=1, sort_keys=True) + "\n")
        self.lines = text

    def go(self) -> int:
        seal = self.seal.check()
        t0 = time.time()
        entries = load_manifest(seal)
        database = sealed_state_ready(seal, entries)
        entries = self.scope(entries)
        if not entries:
            raise Refused("refused: no corpus file is in this lane's scope")
        seal.out_folder(self.out)
        self.housekeeping = prune(seal, self.lane)
        # The run's work folder is made by this run and by nothing before it: whatever is found
        # in it later (the verbs lane's scratch, its archive) was put there by this run (Codex #313 F4).
        seal.mkdir(seal.work_root)
        try:
            os.mkdir(str(seal.writable(self.work)))
        except FileExistsError:
            raise Refused("refused: a work folder with this run's name is already there — it is not this run's")
        try:
            if not self.engine_present():
                report = self.report({}, {}, time.time() - t0, engine_present=False)
                self.store(report, {})
                return EXIT_NORUN
            try:
                self.install_overlay()
                if self.build() != 0:
                    self.lines = [f"corpus {self.lane}: RED the driver did not build against {self.sha[:9]} "
                                  "(corpus-build.log on the host); no file was run"]
                    seal.out_write(self.out, "corpus-summary.txt", self.lines[0] + "\n")
                    return EXIT_RED
                entries, database = self.stage(entries, database)
                results, hello = self.run_files(entries, database)
            finally:
                if self.overlay_installed:                   # never a folder this run did not lay down
                    self.clear_overlay()
            report = self.report(results, hello, time.time() - t0)
            self.after(results, report)
            report["against"] = against_baseline(seal, self.lane, results, self.engines)
            self.store(report, results)
            return {"GREEN": EXIT_GREEN, "AMBER": EXIT_AMBER}.get(verdict_of(report, report["against"]), EXIT_RED)
        finally:
            for name in sorted(os.listdir(str(self.work))) if self.work.is_dir() else []:
                if name.startswith("progress-"):             # the raw event lines are part of the record
                    seal.mkdir(self.report_dir)
                    shutil.move(str(self.work / name), str(seal.writable(self.report_dir / name)))
            self.remove_work()

    def remove_work(self) -> None:
        """The run's work folder goes, whole. Promote locks what it archives (the user
        immutable flag): the lock is cleared first, on files under this run's work folder only."""
        work = str(self.seal.writable(self.work))
        if not os.path.isdir(work):
            return
        _unlock_tree(work)
        shutil.rmtree(work, ignore_errors=True)
        if os.path.isdir(work):
            note = "  the run's work folder could NOT be removed whole (it is still on the M4 under ~/corpus/work)"
            self.lines.append(note)
            try:
                self.seal.out_write(self.out, "corpus-summary.txt", note + "\n", append=True)
            except (OSError, Refused):
                pass


def media_sweep(seal: Seal, entries: List[Entry]) -> Dict[str, Tuple[int, int]]:
    """Size, modification time, file flags, link count and inode of every corpus file, by
    SHA-256, plus the count of files under ~/corpus/media (key `files`): what must be identical
    before and after a verbs run."""
    seen: Dict[str, Tuple[int, int]] = {}
    for e in entries:
        try:
            st = os.lstat(str(e.path))
            # size, mtime — and the flags, the number of names and the inode: a lock cleared, a
            # hard link made into the run, or the file replaced, moves none of the first two.
            seen[e.sha] = (st.st_size, st.st_mtime_ns, getattr(st, "st_flags", 0), st.st_nlink, st.st_ino)
        except OSError:
            seen[e.sha] = (-1, -1)
    seen["files"] = (sum(len(names) for _, _, names in os.walk(str(seal.media))), 0)
    return seen


def verbs_sample(entries: List[Entry], count: int) -> List[Tuple[Entry, str]]:
    """The verbs lane's files, each with its role. Deterministic: strata in name order, the
    smallest files of each first, one stratum at a time until `count`; roles dealt round-robin.
    A `promote` file that would take the scratch archive past VERBS_PROMOTE_BYTES is a `purge`
    file instead (Promote makes real copies; the other verbs do not)."""
    by_stratum: Dict[str, List[Entry]] = defaultdict(list)
    for e in entries:
        if 0 < e.size <= VERBS_MAX_FILE:
            by_stratum[e.stratum].append(e)
    queues = [sorted(group, key=lambda e: (e.size, e.sha)) for _, group in sorted(by_stratum.items())]
    picked: List[Entry] = []
    while len(picked) < count and any(queues):
        for queue in queues:
            if queue and len(picked) < count:
                picked.append(queue.pop(0))
    sample, promoting = [], 0
    for i, e in enumerate(picked):
        role = VERBS_ROLES[i % len(VERBS_ROLES)]
        if role == "promote":
            if promoting + e.size > VERBS_PROMOTE_BYTES:
                role = "purge"
            else:
                promoting += e.size
        sample.append((e, role))
    return sample


class VerbsLane(Lane):
    """Lane `verbs`: the destructive verbs, on clones (the module docstring). The build, the
    launch, the events, the report and the baseline diff are `Lane`'s; this adds the clones,
    the catalog over them, a HOME inside the run's work folder, and the media sweep."""

    def __init__(self, *args, cp: str = "/bin/cp", **kwargs):
        super().__init__(*args, **kwargs)
        self.cp = cp
        self.vol = self.work / "vol"
        self.roles: Dict[str, str] = {}
        self.copies: Dict[str, List[str]] = {}
        self.before: Dict[str, Tuple[int, int]] = {}
        self.all_entries: List[Entry] = []
        self.free_before = 0

    def home(self) -> Path:
        return self.work / "home"                           # nothing this run's engines remember outlives the run

    def scope(self, entries: List[Entry]) -> List[Entry]:
        self.all_entries = entries
        sample = verbs_sample(entries, self.limit or VERBS_SAMPLE)
        self.roles = {e.sha: role for e, role in sample}
        return [e for e, _ in sample]

    def record_extra(self, entry: Entry) -> dict:
        return {"role": self.roles[entry.sha]}

    def pending_item(self, entry: Entry) -> dict:
        return {"sha": entry.sha, "path": str(entry.path), "role": self.roles[entry.sha], "copies": self.copies.get(entry.sha, [])}

    def config_extra(self) -> dict:
        return {"volRoot": str(self.vol), "archiveRoot": str(self.work / "archive"), "scratch": str(self.work / "scratch")}

    def clone(self, source: Path, dest: Path) -> None:
        """`cp -c -p`: an APFS clone (copy-on-write; the times kept). The source is opened for
        reading only; the destination is proven to be inside this run's work folder first."""
        self.seal.mkdir(dest.parent)
        self.seal.writable(dest)
        if not _under(source, self.seal.media) or _under(dest, self.seal.media):
            raise Refused("refused: a clone is made FROM ~/corpus/media INTO the run's work folder, never the other way")
        if subprocess.call([self.cp, "-c", "-p", str(source), str(dest)], stdin=subprocess.DEVNULL,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) != 0:
            raise Refused("refused: a corpus file could not be cloned into the run's work folder")

    def stage(self, entries: List[Entry], database: Path) -> Tuple[List[Entry], Path]:
        seal = self.seal
        database_name, latch_name = _catalog_names()
        free = shutil.disk_usage(str(seal.corpus)).free
        if free < VERBS_FREE_FLOOR:
            raise Refused(f"refused: {free / 1e9:.0f} GB free on the M4 — the verbs lane wants {VERBS_FREE_FLOOR / 1e9:.0f} GB")
        self.before = media_sweep(seal, self.all_entries)
        self.free_before = free
        clones = []
        for e in entries:
            clone = Entry(e.sha, e.original, e.size, e.stratum, self.vol / e.original.lstrip("/"))
            self.clone(e.path, clone.path)
            clones.append(clone)
            if self.roles[e.sha] == "dup":
                self.copies[e.sha] = []
                for k in range(1, VERBS_COPIES + 1):
                    copy = self.vol / "Copies" / f"copy{k}" / e.sha[:12] / e.path.name
                    self.clone(e.path, copy)
                    self.copies[e.sha].append(str(copy))
        seed = self.work / "seed"
        seal.mkdir(seed)
        for name in ("home", "scratch", "archive"):
            seal.mkdir(self.work / name)
        build_catalog(seal, seal.corpus / SOURCE_BACKUP, clones, seed / database_name, root=self.vol)
        seal.write_text(seed / latch_name, "{}\n")
        verdict = verify_catalog(seal, seed / database_name, clones, root=self.vol)
        if not verdict["ok"]:
            raise Refused("refused: the catalog over the clones did not verify — " + ", ".join(
                f"{k}={v}" for k, v in sorted(verdict.items()) if v and k not in ("rows", "manifest")))
        return clones, seed / database_name

    def after(self, results: Dict[str, dict], report: dict) -> None:
        after = media_sweep(self.seal, self.all_entries)
        changed = sum(1 for key in self.before if key != "files" and after.get(key) != self.before[key])
        files_delta = after["files"][0] - self.before["files"][0]
        report["media"] = {"swept": len(self.before) - 1, "changed": changed, "files_delta": files_delta}
        report["roles"] = dict(Counter(self.roles.values()))
        report["clones"] = len(self.roles) + sum(len(c) for c in self.copies.values())
        report["free_delta_bytes"] = shutil.disk_usage(str(self.seal.corpus)).free - self.free_before
        report["trash"] = self.closing
        if self.closing.get("strayTrashFiles"):              # RED: a clone left the run through the app's own Trash call
            report["failures"]["trash:LOST_outside_the_run"] = self.closing["strayTrashFiles"]
        if changed or files_delta:
            report["failures"]["media:MISMATCH"] = changed + abs(files_delta)       # RED: the pristine copies moved


# ── Reading reports back: render, diff, status ────────────────────────────

def _counts(counter: Dict[str, int]) -> str:
    return ", ".join(f"{k} {v}" for k, v in sorted(counter.items(), key=lambda kv: (-kv[1], kv[0]))) or "none"


def cut_count(report: dict) -> int:
    """Files on which an engine crashed or ran past the deadline (failure keys are `engine:outcome`)."""
    return sum(n for key, n in (report.get("failures") or {}).items()
               if key.split(":", 1)[-1] in CUT_WORDS or any(w in key for w in LOSS_WORDS))


def verdict_of(report: dict, against: Optional[dict]) -> str:
    """The lane's verdict (the module docstring's rule): `against` is its diff with the baseline."""
    if not report.get("engine_present", True):
        return "NORUN"
    if cut_count(report) or (against or {}).get("problem"):
        return "RED"
    return "AMBER" if (against or {}).get("changed") else "GREEN"


def against_lines(against: Optional[dict]) -> List[str]:
    """What changed against the baseline: counts, transitions, then the files by SHA-256 prefix."""
    if not against:
        return ["  baseline: this run (the lane has no earlier whole clean run to compare with)"]
    if against.get("problem"):
        return ["  baseline: " + against["problem"]]
    accepted = f" (accepted {against['accepted_at']} by {against['accepted_by']})" if against.get("accepted_at") else ""
    lines = [f"  against {against['what']} {against['run']} at {against['sha'][:9]}{accepted}: {against['changed']} of "
             f"{against['compared']} files changed (new in this run {against['only_new']}, not in this run {against['only_old']})"]
    for transition, n in sorted(against["transitions"].items(), key=lambda kv: (-kv[1], kv[0])):
        lines.append(f"    {transition} x{n}")
    lines += ["    " + line for line in against.get("listed") or []]
    if against.get("listed_more"):
        lines.append(f"    … +{against['listed_more']} more files (the whole list is in the run's report.json on the M4)")
    if against.get("kinds_changed"):
        lines.append(f"  finding kinds moved in {against['kinds_changed']} files whose outcome words did not (not part of the verdict)")
    previous = against.get("previous")
    if previous:
        lines.append(f"  since the previous run {previous['run']} at {previous['sha'][:9]}: {previous['changed']} of "
                     f"{previous['compared']} files changed")
    return lines


def head_lines(report: dict, against: Optional[dict]) -> List[str]:
    """The verdict line, the engines' counts, the seal and the diff — what `status` shows of a run."""
    lane = report["lane"]
    engines = [e for e in LANES[lane][1] if e in report["engines"]]         # the lane's own order, not the JSON's
    if not report.get("engine_present", True):
        return [f"corpus {lane}: NOT RUN at {report['sha'][:9]} — this ref has no balanced-copy proof engine "
                "(MediaOps/BalancedCopyProof*.swift); run it with a --ref that contains it"]
    failed = sum(report["failures"].values())
    lines = [f"corpus {lane}: {verdict_of(report, against)} {report['files']} files ({report['bytes'] / 1e9:.1f} GB, "
             f"{report['media_seconds'] / 3600:.1f} h of media) at {report['sha'][:9]} — wall {report['wall_s']:.0f}s "
             f"(build {report['build_s']:.0f}s), {report['launches']} launch(es), per-file deadline {report['deadline_s']}s"
             + (f", limited to {report['limit']} files" if report.get("limit") else "")]
    for e in engines:
        lines.append(f"  {e}: {_counts(report['engines'][e])}")
    cut = cut_count(report)
    lines.append("  engine failures (crash / timeout / error): " + (_counts(report["failures"]) if failed else "none")
                 + (f" — {cut} crashed or timed out: RED" if cut else ""))
    seal = report.get("seal") or {}
    lines.append(f"  seal: home sealed={seal.get('homeSealed')} test host={seal.get('testHost')} "
                 f"archive designation={seal.get('archiveDesignation')} catalog records={seal.get('records')}")
    return lines + against_lines(against)


def render(report: dict, per_file: Optional[Dict[str, dict]] = None, against: Optional[dict] = None) -> List[str]:
    lane = report["lane"]
    engines = [e for e in LANES[lane][1] if e in report["engines"]]
    lines = head_lines(report, against)
    if not report.get("engine_present", True):
        return lines
    if report.get("media"):
        media = report["media"]
        lines.append(f"  corpus media sweep (size, mtime, flags, links and inode of {media['swept']} files, before and after): {media['changed']} changed, "
                     f"file count {media['files_delta']:+d}" + (" — RED: ~/corpus/media was touched" if media["changed"] or media["files_delta"] else " — untouched"))
        lines.append(f"  clones: {report.get('clones')} (roles: {_counts(report.get('roles') or {})}); free space on the M4 "
                     f"{report.get('free_delta_bytes', 0) / 1e9:+.2f} GB while the run's work folder was still there")
        trash = report.get("trash") or {}
        lines.append(f"  the run's own Trash folder (under its work folder; never the Finder Trash): "
                     f"{trash.get('trashFiles', 'no count of')} files, the engines reported moving {trash.get('trashedByEngines', 'no count')}; "
                     f"files found in the app's own test-host Trash outside the run: {trash.get('strayTrashFiles', 'no count')}")
        lines.append(f"  deletion receipts the engines wrote: {trash.get('receiptsInRun', 'no count of')} inside the run, "
                     f"{trash.get('receiptsOutsideTheRun', 'no count of')} outside it (the system temporary folder on the M4: "
                     "the engines take no folder for a receipt; recorded, not moved)")
    lines.append("  by role:" if lane == "verbs" else "  by stratum:")
    for name, row in sorted(report["by_stratum"].items()):
        lines.append(f"    {name} ({row['files']}): " + " · ".join(f"{e}: {_counts(row[e])}" for e in engines))
    if lane != "verbs":
        lines.append("  by container | video | audio:")
    for name, row in sorted(report["by_format"].items(), key=lambda kv: (-kv[1]["files"], kv[0])) if lane != "verbs" else []:
        lines.append(f"    {name} ({row['files']}): " + " · ".join(f"{e}: {_counts(row[e])}" for e in engines))
    if per_file:
        lines.append("  per file (sha256 prefix):")
        for sha, record in sorted(per_file.items()):
            kinds = " ".join(f"{e}[{','.join(record.get(e + '_kinds') or [])}]" for e in engines if record.get(e + "_kinds"))
            peak = f" peak={record['peak_dbfs']:.1f}dBFS" if isinstance(record.get("peak_dbfs"), (int, float)) else ""
            took = " ".join(f"{e}={record[e + '_s']:.0f}s" for e in engines if isinstance(record.get(e + "_s"), (int, float)))
            what = (record.get("role") if lane == "verbs" else
                    f"{record.get('container', 'unknown')}/{record.get('vcodec', 'unknown')}/{record.get('acodec', 'unknown')}")
            shown = (" ".join(f"{e}={record[e]}" for e in engines if record.get(e, "not_run") != "not_run") or "nothing ran"
                     if lane == "verbs" else record["outcome"])
            lines.append(f"    {sha_prefix(sha)} {what}: {shown} {kinds}{peak}".rstrip() + (f" (wall {took})" if took else ""))
    return lines


def verdict_facts(report: dict) -> dict:
    """What a lane's run says to the testbed block: its verdict, counts and what changed —
    numbers, outcome words and SHA-256 prefixes only (every word already went through `word()`)."""
    against = report.get("against")
    facts = {"lane": report["lane"], "verdict": verdict_of(report, against), "sha": report["sha"][:9],
             "files": report["files"], "bytes": report["bytes"], "wall_s": report["wall_s"], "engines": report["engines"],
             "engine_order": [e for e in LANES[report["lane"]][1] if e in report["engines"]],
             "failures": report["failures"], "against": None, "notes": []}
    if cut_count(report):
        facts["notes"].append(f"{cut_count(report)} files crashed an engine or ran past the deadline: RED")
    if against and against.get("problem"):
        facts["notes"].append("baseline: " + against["problem"])
    elif against:
        facts["against"] = {k: against.get(k) for k in ("what", "run", "sha", "compared", "changed", "only_new", "only_old",
                                                        "transitions", "listed")}
        if against.get("listed_more"):
            facts["notes"].append(f"… +{against['listed_more']} more changed files")
    return facts


def lane_runs(seal: Seal, lane: str) -> List[Path]:
    """Every stored run of a lane, oldest first (the stamp sorts by time)."""
    root = seal.reports / lane
    runs = []
    if (lane not in LANES or os.path.islink(str(root)) or os.path.islink(str(seal.reports))
            or os.path.realpath(str(root)) != os.path.join(os.path.realpath(str(seal.reports)), lane)):
        return runs                                          # reports/<lane> is itself, or the lane has no runs (Codex #313 F5)
    for report in root.glob("*/*/report.json") if root.is_dir() else []:
        run = report.parent
        # A run is a real folder inside reports/<lane>/<commit>/, holding real files: a symlinked
        # run, commit folder, report or outcomes file is not a run (Codex #311 F4).
        if (re.fullmatch(r"[0-9a-f]{40}", run.parent.name) and re.fullmatch(r"[0-9A-Za-z_]+", run.name)
                and not any(os.path.islink(str(p)) for p in (run, run.parent, report, run / "outcomes.json"))
                and _under(run, root)):
            runs.append(run)
    return sorted(runs, key=lambda p: p.name)


def diff(old: Dict[str, dict], new: Dict[str, dict], engines: List[str]) -> dict:
    """What changed between two runs, by content: counts, outcome-word transitions, and per
    changed file its SHA-256 with `engine: old -> new` (`moved`; the caller shortens the SHA)."""
    transitions = Counter()
    moved: List[Tuple[str, str]] = []
    kinds_changed = 0
    shared = sorted(sha for sha in set(old) & set(new) if isinstance(old[sha], dict) and isinstance(new[sha], dict))
    for sha in shared:
        words = []
        for e in engines:
            if e not in old[sha]:
                continue                                     # an engine the lane did not have then: nothing to compare
            a, b = word(old[sha].get(e, "not_run")), word(new[sha].get(e, "not_run"))   # a stored file is not trusted to hold words
            if a != b:
                transitions[f"{e}: {a} -> {b}"] += 1
                words.append(f"{e}: {a} -> {b}")
        if words:
            moved.append((sha, "; ".join(words)))
        elif any(sorted(old[sha].get(e + "_kinds") or []) != sorted(new[sha].get(e + "_kinds") or [])
                 for e in engines if e in old[sha]):         # an engine the lane did not have then has no kinds to compare
            kinds_changed += 1
    return {"compared": len(shared), "changed": len(moved), "only_new": len(set(new) - set(old)),
            "only_old": len(set(old) - set(new)), "transitions": dict(transitions), "moved": moved,
            "kinds_changed": kinds_changed}


def usable_runs(seal: Seal, lane: str) -> List[Tuple[Path, dict]]:
    """The stored runs of a lane that ran its engine, oldest first, each with its report.
    A run whose report or outcomes cannot be read is not one of them."""
    runs = []
    for run in lane_runs(seal, lane):
        try:
            report = clean_report(json.loads((run / "report.json").read_text(encoding="utf-8")))
            if report["engine_present"]:
                _outcomes(run)                               # readable, and every row a record
                runs.append((run, report))
        except (OSError, ValueError):
            continue
    return runs


def _outcomes(run: Path) -> Dict[str, dict]:
    value = json.loads((run / "outcomes.json").read_text(encoding="utf-8"))
    if not isinstance(value, dict) or not all(isinstance(row, dict) for row in value.values()):
        raise ValueError("outcomes.json is not a table of records")      # a row that is not a record compares as nothing (Codex #313 F9)
    return value


def baseline_of(seal: Seal, lane: str, exclude: Optional[Path] = None) -> Tuple[Optional[Path], dict, Optional[str]]:
    """(the baseline run, how it is described, a problem). The accepted one when
    reports/<lane>/baseline.json exists — proven still to be the run that was accepted, by the
    SHA-256 of its outcomes — else the lane's first whole clean run other than `exclude`."""
    record_path = seal.reports / lane / BASELINE
    if os.path.lexists(str(record_path)):
        try:
            seal.contained(record_path, seal.reports)        # the record itself, never a link to a file elsewhere
            record = json.loads(record_path.read_text(encoding="utf-8"))
            if not re.fullmatch(r"[0-9a-f]{40}", record["sha"]) or not re.fullmatch(r"[0-9A-Za-z_]+", record["run"]):
                raise ValueError("not a run")
            run = seal.reports / lane / record["sha"] / record["run"]
            if run not in lane_runs(seal, lane):
                raise ValueError("not a stored run of this lane")
            if hashlib.sha256((run / "outcomes.json").read_bytes()).hexdigest() != record["outcomes_sha256"]:
                raise ValueError("changed")
            _outcomes(run)
        except (OSError, ValueError, KeyError, TypeError, Refused):
            return None, {}, (f"the accepted baseline of {lane} cannot be read back (missing, or changed since it was "
                              f"accepted) — look, then `scripts/corpus_run.sh accept {lane}` blesses a run again")
        return run, {"what": "its accepted baseline", "accepted_at": word(str(record.get("accepted_at", "")).replace(" ", "_")),
                     "accepted_by": who_word(record.get("accepted_by"))}, None
    for run, report in usable_runs(seal, lane):
        if run != exclude and not cut_count(report) and not report.get("limit"):
            return run, {"what": "its first run (no baseline accepted yet)"}, None
    return None, {}, None


def against_baseline(seal: Seal, lane: str, results: Dict[str, dict], engines: List[str],
                     this_run: Optional[Path] = None) -> Optional[dict]:
    """A run's diff against the lane's baseline, ready for a report: None when the run is its
    own baseline (nothing earlier), `problem` when the accepted baseline is unreadable. Also
    the count against the newest earlier run when that is not the baseline."""
    run, described, problem = baseline_of(seal, lane, exclude=this_run)
    if problem:
        return {"problem": problem}
    if run is None or run == this_run:
        return None if run is None else {**described, "run": run.name, "sha": run.parent.name, "compared": len(results),
                                         "changed": 0, "only_new": 0, "only_old": 0, "transitions": {}, "listed": [],
                                         "listed_more": 0, "kinds_changed": 0, "changes": [], "previous": None}
    delta = diff(_outcomes(run), results, engines)
    moved = delta.pop("moved")
    against = {**described, "run": run.name, "sha": run.parent.name, **delta,
               "listed": [f"{sha_prefix(sha)} {words}" for sha, words in moved[:LISTED]],
               "listed_more": max(0, len(moved) - LISTED),
               "changes": [[sha, words] for sha, words in moved], "previous": None}
    earlier = [r for r, _ in usable_runs(seal, lane) if r != this_run and (this_run is None or r.name < this_run.name)]
    if earlier and earlier[-1] != run:
        try:
            since = diff(_outcomes(earlier[-1]), results, engines)
            against["previous"] = {"run": earlier[-1].name, "sha": earlier[-1].parent.name,
                                   "changed": since["changed"], "compared": since["compared"]}
        except (OSError, ValueError):
            pass
    return against


_RUN_WORK = re.compile(r"[0-9A-Za-z_]+-(?:%s)" % "|".join(sorted(LANES) + ["coverage"]))     # work/<stamp>-<lane>; corpus_coverage's own


def _unlock_tree(folder: str) -> None:
    """Clear the user immutable flag (what Promote sets on what it archives) under `folder` —
    on regular files with ONE name only: a hard link could share its inode with a file outside
    the run, and clearing the flag here would clear it there (Codex #311 F3)."""
    for parent, _, names in os.walk(folder):
        for name in names:
            path = os.path.join(parent, name)
            try:
                info = os.lstat(path)
                if stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_flags & 0x2:     # UF_IMMUTABLE
                    os.lchflags(path, info.st_flags & ~0x2)
            except (OSError, AttributeError):
                continue


def prune(seal: Seal, lane: str, keep: Optional[int] = None, now: Optional[float] = None) -> List[str]:
    """Housekeeping at the start of a lane (the 115 GB the M4 has free is the corpus's own disk).
    Stored runs of the lane: the newest `keep`, every RED run and the BASELINE are kept; the
    rest go, and a commit folder left empty with them. Nothing is pruned while the accepted
    baseline cannot be read back — the stored runs are then the evidence. Work folders older
    than STALE_WORK_SECONDS are what a run that died left behind: removed, unlocked first."""
    lines = []
    seal.check()                                             # nothing is removed unless the folders are themselves
    keep = KEEP_RUNS if keep is None else keep
    baseline, _, problem = baseline_of(seal, lane)
    runs = lane_runs(seal, lane)
    if problem is None and len(runs) > keep:
        removed = 0
        for run in runs[:-keep]:
            if run == baseline:
                continue
            try:
                report = json.loads((run / "report.json").read_text(encoding="utf-8"))
                if verdict_of(report, report.get("against")) == "RED":
                    continue
            except (OSError, ValueError, KeyError, TypeError):
                continue                                     # unreadable: left for a person to look at
            shutil.rmtree(str(seal.writable(run)), ignore_errors=True)
            removed += 1
            try:
                run.parent.rmdir()                           # only when empty
            except OSError:
                pass
        if removed:
            lines.append(f"  housekeeping: {removed} old {lane} runs removed from the reports (the newest {keep}, the baseline and every RED run stay)")
    now = time.time() if now is None else now
    stale = 0
    for folder in sorted(seal.work_root.iterdir()) if seal.work_root.is_dir() else []:
        try:
            if (folder.is_symlink() or not folder.is_dir() or not _RUN_WORK.fullmatch(folder.name)
                    or now - folder.lstat().st_mtime < STALE_WORK_SECONDS):
                continue                                     # not a run's folder (Codex #311 F7), or not old
        except OSError:
            continue
        _unlock_tree(str(seal.writable(folder)))
        shutil.rmtree(str(folder), ignore_errors=True)
        stale += 1
    if stale:
        lines.append(f"  housekeeping: {stale} work folders left by runs that died were removed")
    return lines


def who_word(text) -> str:
    """Who accepted a baseline, as one word: `rickb@RicksUltra`. No dot (nothing shaped like a
    file name), no long run of hex."""
    name = re.sub(r"[^A-Za-z0-9_@-]", "_", str(text or "unknown"))[:48] or "unknown"
    return "scrubbed" if _LONG_HEX.search(name) else name


def accept(seal: Seal, lane: str, who: str) -> List[str]:
    """Bless the lane's newest run as its baseline. Refused for a run that crashed or timed
    out, ran only part of the corpus, or had no engine: none of those is a state to hold a
    later run to. The record names the run, its commit, who and when, and the SHA-256 of the
    run's outcomes so a later reader knows it is the same run."""
    seal.check()
    if lane not in LANES:
        raise Refused("refused: accept wants one of " + ", ".join(sorted(LANES)))
    runs = lane_runs(seal, lane)
    if not runs:
        raise Refused(f"refused: {lane} has no run to accept")
    newest = runs[-1]
    try:
        report = clean_report(json.loads((newest / "report.json").read_text(encoding="utf-8")))
        digest = hashlib.sha256((newest / "outcomes.json").read_bytes()).hexdigest()
        _outcomes(newest)
    except (OSError, ValueError):
        raise Refused(f"refused: the newest {lane} run cannot be read back")
    if not report.get("engine_present", True):
        raise Refused(f"refused: the newest {lane} run did not run (its ref had no engine)")
    if cut_count(report):
        raise Refused(f"refused: the newest {lane} run has {cut_count(report)} files that crashed or timed out — a RED run is never the baseline")
    if report.get("limit"):
        raise Refused(f"refused: the newest {lane} run was limited to {report['limit']} files — a partial run is never the baseline")
    folder = seal.reports / lane
    try:
        was = json.loads(seal.contained(folder / BASELINE, seal.reports).read_text(encoding="utf-8")).get("run")
    except (OSError, ValueError, AttributeError, Refused):
        was = None
    record = {"lane": lane, "run": newest.name, "sha": newest.parent.name, "files": report["files"],
              "accepted_at": time.strftime("%Y-%m-%d %H:%M:%S"), "accepted_by": who_word(who),
              "outcomes_sha256": digest, "replaces": was}
    pending = folder / f"{BASELINE}.{os.getpid()}"
    seal.write_json(pending, record)
    os.replace(str(pending), str(seal.writable(folder / BASELINE)))          # whole or not at all
    seal.write_text(folder / BASELINE_LOG, json.dumps(record, sort_keys=True) + "\n", append=True)
    return [f"corpus {lane}: the baseline is now run {newest.name} at {newest.parent.name[:9]} ({report['files']} files) — "
            f"accepted {record['accepted_at']} by {record['accepted_by']}"
            + (f"; it replaces {word(was)}" if was else "; the lane had no accepted baseline before")]


def clean_report(report) -> dict:
    """A STORED report as `status` may print it: rebuilt from words and numbers only. A report
    file is read back from disk and is not trusted to hold what `report()` wrote — a counter's
    key, the seal's values or a number could be anything (Codex #313 F8). Raises ValueError for
    a file that is not a report of a known lane."""
    if not isinstance(report, dict) or report.get("lane") not in LANES or not re.fullmatch(r"[0-9a-f]{40}", str(report.get("sha"))):
        raise ValueError("not a report")

    def number(value, default=0):
        return value if isinstance(value, (int, float)) and not isinstance(value, bool) else default

    def counter(value) -> Dict[str, int]:
        return {word(k): int(number(v)) for k, v in value.items()} if isinstance(value, dict) else {}

    lane = report["lane"]
    engines = report.get("engines") if isinstance(report.get("engines"), dict) else {}
    seal_facts = report.get("seal") if isinstance(report.get("seal"), dict) else {}
    return {"lane": lane, "sha": report["sha"], "engine_present": report.get("engine_present", True) is not False,
            "files": int(number(report.get("files"))), "bytes": number(report.get("bytes")),
            "media_seconds": number(report.get("media_seconds")), "wall_s": number(report.get("wall_s")),
            "build_s": number(report.get("build_s")), "launches": int(number(report.get("launches"))),
            "deadline_s": int(number(report.get("deadline_s"))), "limit": int(number(report.get("limit"))) or None,
            "engines": {e: counter(engines.get(e)) for e in LANES[lane][1] if e in engines},
            "failures": counter(report.get("failures")),
            "seal": {k: (seal_facts.get(k) if isinstance(seal_facts.get(k), (bool, int)) else None)
                     for k in ("homeSealed", "testHost", "archiveDesignation", "records")}}


def status(seal: Seal) -> List[str]:
    seal.check()
    lines = []
    try:
        prepared = json.loads(seal.contained(seal.state / "prepare.json", seal.state).read_text(encoding="utf-8"))
        lines.append(f"corpus: prepared {word(str(prepared['prepared_at']).replace(' ', '_'))} — {int(prepared['verify']['rows'])} rows, "
                     f"{int(prepared['files'])} files, {float(prepared['bytes']) / 1e9:.1f} GB")
    except (OSError, ValueError, KeyError, TypeError, Refused):
        lines.append("corpus: not prepared — run `scripts/corpus_run.sh prepare`")
    for lane in LANES:
        runs = lane_runs(seal, lane)
        if not runs:
            lines.append(f"corpus {lane}: no run yet")
            continue
        newest = runs[-1]
        try:
            report = clean_report(json.loads((newest / "report.json").read_text(encoding="utf-8")))
            results = _outcomes(newest) if report.get("engine_present", True) else {}
        except (OSError, ValueError):
            lines.append(f"newest {lane} run: {newest.name} — RED its report cannot be read back")
            continue
        lines.append(f"newest {lane} run: {newest.name}")
        # Judged against the baseline as it stands NOW: an `accept` since the run changes the answer.
        lines += head_lines(report, against_baseline(seal, lane, results, LANES[lane][1], this_run=newest)
                            if report.get("engine_present", True) else None)
    return lines


# ── Command line ──────────────────────────────────────────────────────────

def main(argv: Optional[List[str]] = None, seal: Optional[Seal] = None, xcodebuild: str = "xcodebuild",
         cp: str = "/bin/cp", xcrun: str = "xcrun", swift: str = "swift") -> int:
    parser = argparse.ArgumentParser(prog="corpus_run.py", description="the real-data corpus harness (host side)")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("status")
    accepting = sub.add_parser("accept")
    accepting.add_argument("lane")
    accepting.add_argument("--by", default="unknown")
    host = sub.add_parser("host")
    host.add_argument("lane", choices=["prepare", "coverage"] + sorted(LANES))
    host.add_argument("--sha", required=True)
    host.add_argument("--stamp", required=True)
    host.add_argument("--out", required=True)
    host.add_argument("--worktree", required=True)
    host.add_argument("--derived-data", required=True)
    host.add_argument("--bin", required=True)
    host.add_argument("--deadline", type=int)
    host.add_argument("--limit", type=int)
    args = parser.parse_args(argv)
    lines: List[str] = []
    try:
        seal = seal or Seal.here()
        if args.command == "status":
            lines, code = status(seal), EXIT_GREEN
        elif args.command == "accept":
            lines, code = accept(seal, args.lane, args.by), EXIT_GREEN
        elif args.lane == "prepare":
            sys.path.insert(0, args.bin)
            code, lines = prepare(seal, Path(args.out))
        else:
            if not re.fullmatch(r"[0-9a-f]{40}", args.sha) or not re.fullmatch(r"[0-9A-Za-z_]+", args.stamp):
                raise Refused("refused: --sha is a full commit id and --stamp is letters, digits and underscores")
            sys.path.insert(0, args.bin)
            if args.lane == "coverage":                      # the three lanes instrumented, beside the suite (corpus_coverage.py)
                import corpus_coverage
                run = corpus_coverage.CoverageRun(seal, args.sha, args.stamp, Path(args.out), Path(args.worktree),
                                                  Path(args.derived_data), Path(args.bin), args.deadline, args.limit,
                                                  xcodebuild, cp=cp, xcrun=xcrun, swift=swift)
                code = run.go()
                print("\n".join(run.lines))
                return code
            lane = Lane(seal, args.lane, args.sha, args.stamp, Path(args.out), Path(args.worktree),
                        Path(args.derived_data), Path(args.bin), args.deadline, args.limit, xcodebuild) if args.lane != "verbs" else \
                VerbsLane(seal, args.lane, args.sha, args.stamp, Path(args.out), Path(args.worktree),
                          Path(args.derived_data), Path(args.bin), args.deadline, args.limit, xcodebuild, cp=cp)
            code = lane.go()
            lines = lane.lines
    except Refused as refusal:
        lines, code = [f"corpus: RED {refusal}"], EXIT_REFUSED
        out = getattr(args, "out", None)
        # The refusal is said in the lane's <out> too — but never on a Mac that is not the M4
        # (there the harness writes nothing at all), and never through a symlink (Codex #311 F2).
        if out and os.path.isdir(out) and seal is not None and seal.hostname in ALLOWED_HOSTS:
            try:
                seal.out_write(Path(out), "corpus-summary.txt", lines[0] + "\n")
            except (OSError, Refused):
                pass
    print("\n".join(lines))
    return code


if __name__ == "__main__":
    sys.exit(main())
