#!/usr/bin/env python3
"""corpus_run.py — the real-data corpus harness, host side (phase 1).

DECISIONS 2026-11-17, "The M4 holds a real-data test corpus": a curated copy
of real family media plus a `.backup` of the catalog lives on the M4 under
~/corpus, and automation runs the app's engines across it. This file is what
runs ON THE M4; `scripts/corpus_run.sh` launches it from the Ultra through
`scripts/m4_run.sh corpus` (the testbed lock, the per-run LaunchAgent, the
`--ref` checkout). It is also fed to `python3 - status` over ssh.

  host prepare   build the sealed state: ~/corpus/state/<the catalog file>
  host check     probe · Check Media (quick) · Verify Audio, every corpus file
  host proof     Balance Audio into work/, then the balanced-copy proof
  status         the newest run of each lane and what changed since the last

THE SEAL (every entry point passes `Seal.check` first; tests/test_corpus_run.py):
  1. the hostname is the M4's (`ALLOWED_HOSTS`); the Ultra is refused by name;
  2. ~/corpus exists and carries THIS_IS_TEST_DATA.txt;
  3. the state root resolves (symlinks followed) under ~/corpus/state and is
     nowhere near "Library/Application Support";
  4. every path this file writes resolves under ~/corpus/{state,work,reports}
     (`Seal.writable`) — never under /Volumes, ~/corpus/media or ~/corpus/live.
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

This file never signals a process. A file that overruns its deadline is cut
by the driver exiting its own test host (CorpusDriverSupport.swift); the
whole lane sits under m4_run.sh's existing lane watchdog.

Memory: the manifest (234 rows) and one JSON line per engine per file — KBs.
Disk: the sealed catalog (~1 MB); the proof lane holds one balanced copy at
a time under ~/corpus/work/<run>/ and the run's work folder is removed at
the end. Python 3.9 (the M4's /usr/bin/python3) is the floor.
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
TRANSFORM_VERSION = 1

OVERLAY_DIR = "VideoScan/VideoScanTests/CorpusHarnessOverlay"     # untracked, in the testbed, for one run
PROOF_ENGINE_GLOB = "VideoScan/VideoScan/MediaOps/BalancedCopyProof*.swift"
PROOF_STRATUM = "one-sided sound"

# lane -> (XCTest class, its engines in order, default per-file deadline in seconds, driver sources)
LANES = {
    "check": ("CorpusCheckDriver", ["probe", "check", "audio"], 300,
              ["CorpusDriverSupport.swift", "CorpusCheckDriver.swift"]),
    "proof": ("CorpusProofDriver", ["balance", "proof"], 3600,
              ["CorpusDriverSupport.swift", "CorpusProofDriver.swift"]),
}
HARNESS_WORDS = ("crash", "timeout", "not_run", "no_record")       # outcomes the harness itself assigns

EXIT_GREEN, EXIT_RED, EXIT_REFUSED, EXIT_AMBER, EXIT_NORUN = 0, 1, 2, 3, 4
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
        return self

    def writable(self, path: Path) -> Path:
        """`path`, or Refused unless it resolves inside ~/corpus/{state,work,reports}."""
        path = Path(path)
        resolved = os.path.realpath(str(path))
        if resolved.startswith("/Volumes/") or "/Library/Application Support" in resolved:
            raise Refused("refused: a write was aimed at a live location")
        if not any(_under(path, root) for root in (self.state, self.work_root, self.reports)):
            raise Refused("refused: a write was aimed outside ~/corpus/{state,work,reports} (the corpus sources are read-only)")
        return path

    def mkdir(self, path: Path) -> Path:
        self.writable(path).mkdir(parents=True, exist_ok=True)
        return path

    def write_text(self, path: Path, text: str) -> None:
        with open(self.writable(path), "w", encoding="utf-8") as f:
            f.write(text)

    def write_json(self, path: Path, value) -> None:
        self.write_text(path, json.dumps(value, indent=1, sort_keys=True) + "\n")


# ── Words that may leave the M4 ───────────────────────────────────────────

_NOT_WORD = re.compile(r"[^A-Za-z0-9_,:+\-]")


def word(text, limit: int = 64) -> str:
    """An outcome word, codec or container name. Anything holding a character outside
    letters, digits and `_ , : + -` — a slash, a dot, a space — is not a word and becomes
    `scrubbed` whole, so a path, a filename with its extension or a sentence cannot pass.
    (The drivers emit enum case names only; this is the second lock, not the first.)"""
    text = "" if text is None else str(text)
    if not text:
        return "none"
    if _NOT_WORD.search(text) or len(text) > limit:
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
#
# Everything else is left empty. NOT carried, and why: other copies of the
# same content and removed rows (no corpus file stands behind them);
# captions, transcripts, notes, people (family text the engines do not
# need); pair links — they live in the import evidence (import_runs →
# import_items → legacy_pair_ids) and `import_runs_open_first` refuses a
# finished run, so a video half reads as unpaired here. volume_uuid and the
# identity stamps still describe the ORIGINAL drive and file.

CARRIED_BY_DIGEST = ("user_dates", "workflow_tags")
AUDIT_COLUMNS = ("audit_seen_volume_uuid", "audit_seen_mount_from", "audit_seen_device_key", "audit_seen_at")


def _catalog_names() -> Tuple[str, str]:
    """The catalog's file name and its latch name, from the one module that names them
    (scripts/catalog_db.py, shipped beside this file; `main` puts its folder on the path)."""
    import catalog_db
    return catalog_db.DATABASE_FILE_NAME, catalog_db.LATCH_FILE_NAME


def _columns(conn: sqlite3.Connection, schema: str, table: str) -> List[str]:
    return [row[1] for row in conn.execute(f"PRAGMA {schema}.table_info({table})")]


def build_catalog(seal: Seal, source: Path, entries: List[Entry], dest: Path) -> Dict[str, int]:
    """Create `dest` (new file, rollback journal) from `source` as described above."""
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

        prefix = str(seal.media)
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
        return counts
    except sqlite3.Error as error:
        # The engine's words name tables, columns and triggers — never a row's values.
        raise Refused("refused: the schema would not take the transform — " + str(error).splitlines()[0][:160])
    finally:
        conn.close()


def verify_catalog(seal: Seal, database: Path, entries: List[Entry]) -> Dict[str, int]:
    """Through the scripts' read-only door: every manifest file has a row, every row's file
    exists with the row's size, and the catalog names no Master Archive."""
    import catalog_db
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
        if os.path.normpath(path) != os.path.normpath(str(entry.path)) or not _under(Path(path), seal.media):
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
    lines.append("  not carried: other copies and removed rows, pair links, captions/transcripts/notes/people, the Master Archive designation")
    if out is not None:
        Path(out, "corpus-summary.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return EXIT_GREEN, lines


def sealed_state_ready(seal: Seal, entries: List[Entry]) -> Path:
    database_name, latch_name = _catalog_names()
    database = seal.state / database_name
    if not database.is_file() or not (seal.state / latch_name).is_file():
        raise Refused("refused: the sealed catalog is not built — run `scripts/corpus_run.sh prepare` first")
    verdict = verify_catalog(seal, database, entries)
    if not verdict["ok"]:
        raise Refused("refused: the sealed catalog no longer matches the corpus — run `scripts/corpus_run.sh prepare`")
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
    with open(dest, "wb") as f:
        plistlib.dump(patch(plist), f)


def _run(command: List[str], log: Path, env: Dict[str, str], cwd: Path) -> int:
    """One child, output appended to `log`, waited for. Never signalled from here. fd 9 is the
    testbed lock (m4_run.sh take_lock): passed on so the lock lives as long as the work."""
    try:
        os.fstat(9)
        pass_fds: Tuple[int, ...] = (9,)
    except OSError:
        pass_fds = ()
    with open(log, "ab") as f:
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
        rc = _run([self.xcodebuild, "build-for-testing", "-project", str(self.worktree / "VideoScan/VideoScan.xcodeproj"),
                   "-scheme", "VideoScan", "-configuration", "Debug", "-destination", "platform=macOS",
                   "-derivedDataPath", str(self.derived_data), "CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual"],
                  self.out / "corpus-build.log", dict(os.environ), self.worktree)
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
            "deadlineSeconds": self.deadline, "pending": [{"sha": e.sha, "path": str(e.path)} for e in pending]})
        seal.write_text(progress, "")
        sealed = {"HOME": str(seal.state / "home"), "CFFIXED_USER_HOME": str(seal.state / "home"),
                  "TMPDIR": str(self.work / "tmp") + "/", "VS_CORPUS_CONFIG": str(config)}
        patched = xctestrun.with_name(f"corpus-{self.stamp}-{self.launches}.xctestrun")    # beside it: __TESTROOT__ is relative
        patch_xctestrun(xctestrun, patched, sealed)
        env = dict(os.environ)
        env.update({k: v for k, v in sealed.items() if k != "VS_CORPUS_CONFIG"})
        for key in ("CLANG_MODULE_CACHE_PATH", "SWIFT_MODULECACHE_PATH", "SWIFTPM_MODULECACHE_OVERRIDE", "XDG_CACHE_HOME"):
            env[key] = str(seal.state / "caches")
        try:
            _run([self.xcodebuild, "test-without-building", "-xctestrun", str(patched), "-destination",
                  "platform=macOS,arch=arm64", "-parallel-testing-enabled", "NO",
                  "-test-timeouts-enabled", "NO",            # one test method walks every file; the per-file deadline is the driver's
                  f"-only-testing:VideoScanTests/{self.test_class}"],
                 self.out / "corpus-test.log", env, self.worktree)
        finally:
            if patched.exists():
                shutil.move(str(patched), str(self.out / patched.name))
        return read_events(progress)

    def run_files(self, entries: List[Entry], database: Path) -> Tuple[Dict[str, dict], Dict[str, object]]:
        results = {e.sha: {"stratum": stratum_word(e.stratum), "size": e.size} for e in entries}
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
            for table, key in ((by_stratum, record["stratum"]), (by_format, fmt)):
                row = table.setdefault(key, {"files": 0, **{e: Counter() for e in engines}})
                row["files"] += 1
                for e in engines:
                    row[e][record.get(e, "not_run")] += 1
            for e in engines:
                outcome = record.get(e, "not_run")
                totals[e][outcome] += 1
                if outcome in ("crash", "timeout") or outcome.startswith("error"):
                    failures[e + ":" + outcome] += 1
        return {"lane": self.lane, "sha": self.sha, "stamp": self.stamp, "host": self.seal.hostname,
                "engine_present": engine_present, "files": len(results),
                "bytes": sum(r.get("size", 0) for r in results.values()),
                "media_seconds": round(sum(r.get("duration", 0) or 0 for r in results.values()), 1),
                "wall_s": round(wall, 1), "build_s": round(self.build_seconds, 1), "launches": self.launches,
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
            kept = {k: v for k, v in record.items() if k != "settled"}
            kept["outcome"] = outcome_of(record, self.engines)
            outcomes[sha] = kept
        seal.write_json(self.report_dir / "outcomes.json", outcomes)
        seal.write_json(self.report_dir / "report.json", report)
        text = render(report, per_file=outcomes if self.lane == "proof" else None)
        seal.write_text(self.report_dir / "report.txt", "\n".join(text) + "\n")
        (self.out / "corpus-summary.txt").write_text("\n".join(text) + "\n", encoding="utf-8")
        (self.out / VERDICT_FILE).write_text(json.dumps(verdict_facts(report), indent=1, sort_keys=True) + "\n",
                                             encoding="utf-8")
        self.lines = text

    def go(self) -> int:
        seal = self.seal.check()
        t0 = time.time()
        entries = load_manifest(seal)
        database = sealed_state_ready(seal, entries)
        if self.lane == "proof":
            entries = [e for e in entries if e.stratum == PROOF_STRATUM]
        if self.limit:
            entries = entries[: self.limit]
        if not entries:
            raise Refused("refused: no corpus file is in this lane's scope")
        seal.mkdir(self.work)
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
                    (self.out / "corpus-summary.txt").write_text(self.lines[0] + "\n", encoding="utf-8")
                    return EXIT_RED
                results, hello = self.run_files(entries, database)
            finally:
                if self.overlay_installed:                   # never a folder this run did not lay down
                    self.clear_overlay()
            report = self.report(results, hello, time.time() - t0)
            report["against"] = against_previous(seal, self.lane, results, self.engines)
            self.store(report, results)
            return EXIT_AMBER if report["failures"] else EXIT_GREEN
        finally:
            for name in sorted(os.listdir(str(self.work))) if self.work.is_dir() else []:
                if name.startswith("progress-"):             # the raw event lines are part of the record
                    seal.mkdir(self.report_dir)
                    shutil.move(str(self.work / name), str(seal.writable(self.report_dir / name)))
            shutil.rmtree(str(seal.writable(self.work)), ignore_errors=True)


# ── Reading reports back: render, diff, status ────────────────────────────

def _counts(counter: Dict[str, int]) -> str:
    return ", ".join(f"{k} {v}" for k, v in sorted(counter.items(), key=lambda kv: (-kv[1], kv[0]))) or "none"


def render(report: dict, per_file: Optional[Dict[str, dict]] = None) -> List[str]:
    lane = report["lane"]
    engines = [e for e in LANES[lane][1] if e in report["engines"]]         # the lane's own order, not the JSON's
    if not report.get("engine_present", True):
        return [f"corpus {lane}: NOT RUN at {report['sha'][:9]} — this ref has no balanced-copy proof engine "
                "(MediaOps/BalancedCopyProof*.swift); run it with a --ref that contains it"]
    failed = sum(report["failures"].values())
    verdict = "AMBER" if failed else "GREEN"
    lines = [f"corpus {lane}: {verdict} {report['files']} files ({report['bytes'] / 1e9:.1f} GB, "
             f"{report['media_seconds'] / 3600:.1f} h of media) at {report['sha'][:9]} — wall {report['wall_s']:.0f}s "
             f"(build {report['build_s']:.0f}s), {report['launches']} launch(es), per-file deadline {report['deadline_s']}s"]
    for e in engines:
        lines.append(f"  {e}: {_counts(report['engines'][e])}")
    lines.append("  engine failures (crash / timeout / error): " + (_counts(report["failures"]) if failed else "none"))
    seal = report.get("seal") or {}
    lines.append(f"  seal: home sealed={seal.get('homeSealed')} test host={seal.get('testHost')} "
                 f"archive designation={seal.get('archiveDesignation')} catalog records={seal.get('records')}")
    lines.append("  by stratum:")
    for name, row in sorted(report["by_stratum"].items()):
        lines.append(f"    {name} ({row['files']}): " + " · ".join(f"{e}: {_counts(row[e])}" for e in engines))
    lines.append("  by container | video | audio:")
    for name, row in sorted(report["by_format"].items(), key=lambda kv: (-kv[1]["files"], kv[0])):
        lines.append(f"    {name} ({row['files']}): " + " · ".join(f"{e}: {_counts(row[e])}" for e in engines))
    if per_file:
        lines.append("  per file (sha256 prefix):")
        for sha, record in sorted(per_file.items()):
            kinds = " ".join(f"{e}[{','.join(record.get(e + '_kinds') or [])}]" for e in engines if record.get(e + "_kinds"))
            peak = f" peak={record['peak_dbfs']:.1f}dBFS" if isinstance(record.get("peak_dbfs"), (int, float)) else ""
            took = " ".join(f"{e}={record[e + '_s']:.0f}s" for e in engines if isinstance(record.get(e + "_s"), (int, float)))
            lines.append(f"    {sha_prefix(sha)} {record.get('container', 'unknown')}/{record.get('vcodec', 'unknown')}/"
                         f"{record.get('acodec', 'unknown')}: {record['outcome']} {kinds}{peak}".rstrip() + (f" (wall {took})" if took else ""))
    return lines


def verdict_facts(report: dict) -> dict:
    """What a lane's run says to the testbed block: its verdict, counts and what changed —
    numbers and outcome words only (every word in a report already went through `word()`)."""
    if not report.get("engine_present", True):
        verdict = "NORUN"
    else:
        verdict = "AMBER" if report["failures"] else "GREEN"
    return {"lane": report["lane"], "verdict": verdict, "sha": report["sha"][:9], "files": report["files"],
            "bytes": report["bytes"], "wall_s": report["wall_s"], "engines": report["engines"],
            "engine_order": [e for e in LANES[report["lane"]][1] if e in report["engines"]],
            "failures": report["failures"], "against": report.get("against")}


def lane_runs(seal: Seal, lane: str) -> List[Path]:
    """Every stored run of a lane, oldest first (the stamp sorts by time)."""
    root = seal.reports / lane
    runs = [p.parent for p in root.glob("*/*/report.json")] if root.is_dir() else []
    return sorted(runs, key=lambda p: p.name)


def diff(old: Dict[str, dict], new: Dict[str, dict], engines: List[str]) -> dict:
    """What changed between two runs, by content: counts and outcome-word transitions only."""
    transitions = Counter()
    changed = 0
    for sha in sorted(set(old) & set(new)):
        moved = False
        for e in engines:
            a, b = old[sha].get(e, "not_run"), new[sha].get(e, "not_run")
            if a != b:
                transitions[f"{e}: {a} -> {b}"] += 1
                moved = True
        changed += moved
    return {"compared": len(set(old) & set(new)), "changed": changed, "only_new": len(set(new) - set(old)),
            "only_old": len(set(old) - set(new)), "transitions": dict(transitions)}


def usable_runs(seal: Seal, lane: str) -> List[Path]:
    """The stored runs a later run can be compared against, oldest first: those that ran the
    lane's engine. A run whose report cannot be read is not one of them."""
    runs = []
    for run in lane_runs(seal, lane):
        try:
            if json.loads((run / "report.json").read_text(encoding="utf-8")).get("engine_present", True):
                json.loads((run / "outcomes.json").read_text(encoding="utf-8"))
                runs.append(run)
        except (OSError, ValueError):
            continue
    return runs


def against_previous(seal: Seal, lane: str, results: Dict[str, dict], engines: List[str]) -> Optional[dict]:
    """This run's diff against the newest stored run of the lane (None: there is none)."""
    earlier = usable_runs(seal, lane)
    if not earlier:
        return None
    previous = earlier[-1]
    delta = diff(json.loads((previous / "outcomes.json").read_text(encoding="utf-8")), results, engines)
    return {"what": "the previous run", "run": previous.name, "sha": previous.parent.name[:9], **delta}


def status(seal: Seal) -> List[str]:
    seal.check()
    lines = []
    try:
        prepared = json.loads((seal.state / "prepare.json").read_text(encoding="utf-8"))
        lines.append(f"corpus: prepared {prepared['prepared_at']} — {prepared['verify']['rows']} rows, "
                     f"{prepared['files']} files, {prepared['bytes'] / 1e9:.1f} GB")
    except (OSError, ValueError, KeyError):
        lines.append("corpus: not prepared — run `scripts/corpus_run.sh prepare`")
    for lane in LANES:
        runs = lane_runs(seal, lane)
        if not runs:
            lines.append(f"corpus {lane}: no run yet")
            continue
        newest = runs[-1]
        report = json.loads((newest / "report.json").read_text(encoding="utf-8"))
        lines.append(f"newest {lane} run: {newest.name}")
        lines += render(report)[: 3 + len(report["engines"])]
        if not report.get("engine_present", True):
            continue
        earlier = [r for r in runs[:-1] if json.loads((r / "report.json").read_text(encoding="utf-8")).get("engine_present", True)]
        if not earlier:
            lines.append("  changed since the previous run: no previous run (this one is the baseline)")
            continue
        previous = earlier[-1]
        delta = diff(json.loads((previous / "outcomes.json").read_text(encoding="utf-8")),
                     json.loads((newest / "outcomes.json").read_text(encoding="utf-8")), LANES[lane][1])
        lines.append(f"  changed since {previous.name} at {previous.parent.name[:9]}: {delta['changed']} of "
                     f"{delta['compared']} files (new in this run {delta['only_new']}, not in this run {delta['only_old']})")
        for transition, n in sorted(delta["transitions"].items(), key=lambda kv: (-kv[1], kv[0])):
            lines.append(f"    {transition} x{n}")
    return lines


# ── Command line ──────────────────────────────────────────────────────────

def main(argv: Optional[List[str]] = None, seal: Optional[Seal] = None, xcodebuild: str = "xcodebuild") -> int:
    parser = argparse.ArgumentParser(prog="corpus_run.py", description="the real-data corpus harness (host side)")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("status")
    host = sub.add_parser("host")
    host.add_argument("lane", choices=["prepare"] + sorted(LANES))
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
        elif args.lane == "prepare":
            sys.path.insert(0, args.bin)
            code, lines = prepare(seal, Path(args.out))
        else:
            if not re.fullmatch(r"[0-9a-f]{40}", args.sha) or not re.fullmatch(r"[0-9A-Za-z_]+", args.stamp):
                raise Refused("refused: --sha is a full commit id and --stamp is letters, digits and underscores")
            sys.path.insert(0, args.bin)
            lane = Lane(seal, args.lane, args.sha, args.stamp, Path(args.out), Path(args.worktree),
                        Path(args.derived_data), Path(args.bin), args.deadline, args.limit, xcodebuild)
            code = lane.go()
            lines = lane.lines
    except Refused as refusal:
        lines, code = [f"corpus: RED {refusal}"], EXIT_REFUSED
        out = getattr(args, "out", None)
        if out and os.path.isdir(out):
            Path(out, "corpus-summary.txt").write_text(lines[0] + "\n", encoding="utf-8")
    print("\n".join(lines))
    return code


if __name__ == "__main__":
    sys.exit(main())
