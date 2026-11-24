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
  adopt-volume <mount>   once, by a person: the external root's volume (below)

THE WISH LIST (DECISIONS 2026-11-19). The manifest names what the corpus SHOULD hold; a run uses
what has arrived. `prepare` ingests each newly arrived file once (SHA-256 against the manifest, into
~/corpus/state/corpus-ledger.json) and builds the sealed catalog over the files proven so far; a
lane runs the PRESENT files and counts the rest per root (`present N · missing M`). Missing never
moves a verdict or blocks prepare or a lane; mismatched / vanished / changed are AMBER, named. The
baseline diff compares files present in both runs; a file new since the baseline is counted, not
AMBER. `accept` takes a run with missing files (the baseline is per file: a missing file simply has
no row and is compared once it is there) but not a --limit run or one with the external volume
away (a slice or a fault, not the corpus as it stands); a run with problems is never the implicit
first baseline. The ingest section below has the states.

TWO ROOTS (v2, DECISIONS 2026-11-19). The corpus rests on the M4's SSD and on an external
volume (the Crucial X10, ~6,100 files under 8 GB). corpus-manifest-v2.json, when present, IS
the manifest: v1's 234 rows and v2's, each with its `root`. An INTERNAL file's copy is
~/corpus/media/<original path>; an EXTERNAL one's is <mount>/corpus/media/<original path>,
where <mount> and the volume UUID come from ~/corpus/external-volume.json, written once by
`adopt-volume` (scripts/corpus_select.py chose v2 and writes the manifest). The external root
is accepted only while that path is itself (no link), a volume is mounted exactly there, it
carries THIS_IS_TEST_DATA.txt and its UUID is the pinned one (`Seal.external`; the in-app seal
asks the same, CorpusSeal.external). Nothing ever writes on it, mounted or not.
  - prepare ingests what it can reach: with the volume away its files are simply not looked at.
  - a lane with the volume away runs the internal files and says how many external files it
    did NOT RUN: AMBER — not RED, because no engine failed and no copy is at risk, and not
    GREEN, because those files proved nothing; such a run is never a baseline (accept
    refuses it, and it is never the implicit one).
  - a volume at the mount point that is not the adopted one, unmarked, or reached through a
    link: the lane is refused (exit 2) and runs nothing.
  - proof never outlives its evidence (Codex #331 F2): the lane proves the volume again before
    every launch, and the in-app driver before every engine on every file (CorpusSeal.mayOpen);
    a file it came to after the volume went is `external_volume_not_proven` — NOT RUN, AMBER.
  - the HOME VOLUME is the only one written (Codex #331-#333): `Seal.writable` and `out_folder`
    refuse a path any of whose folders is on another volume; `Seal.check` refuses ~/corpus or its
    own folders on another volume; an internal copy must be on the home volume (`verify_catalog`);
    files are moved by rename only (`move_file`), never copied-then-deleted; every tree is removed
    by `remove_tree` — never one with a mount anywhere in it, descriptor by descriptor, never into
    another device. The run holds the UUID it proved and refuses another volume adopted at the
    same mount during the run.
  - the verbs lane clones from the INTERNAL root only: `cp -c` makes an APFS clone only
    within one volume, and the clones live in ~/corpus/work on the SSD.
  - the ONE writer on the corpus roots is `scripts/corpus_shrink.py apply` (DECISIONS 2026-11-24): it
    deletes copies the sample dropped, only after a GREEN check run on the installed sample.

A THIRD ROOT, `ro` (DECISIONS 2026-11-24): a sample file that fits neither copy root is read from its
original on the Ultra's drives over a read-only share. That share is not set up yet: an `ro` row is in
the manifest and the inventory, and every run counts it NOT RUN — AMBER, never a baseline — exactly as
an unplugged external volume's files (`not_run_ro`). Nothing opens anything under RO_NOT_MOUNTED.
  - the proof lane takes v1's one-sided-sound stratum, then the files the newest whole check
    run heard one-sided (Verify Audio's channelImbalance:leftOnly / :rightOnly), smallest
    first, PROOF_CAP (40) in all, and refuses to start unless the balanced copy of the
    largest leaves the disk under TRANSIENT_CEILING (95% used).

THE VERDICT OF A LANE IS THE DIFF. A run is compared, file by file (by SHA-256),
with the lane's BASELINE: the run `accept` blessed (reports/<lane>/baseline.json),
or — until one is accepted — the lane's first whole clean run.
  RED    a file crashed an engine or ran past its deadline (never acceptable,
         whatever the baseline holds), or the accepted baseline cannot be read back, or the
         test host could read NO external file of the run (`host_refused`, GH #498: macOS's
         privacy prompt, an environment failure — the reason is said first; never a baseline);
  AMBER  some file's outcome word differs from the baseline — each is listed by
         SHA-256 prefix with `engine: old -> new`; or a file is mismatched, vanished or
         changed (named by SHA-256 prefix; "ingest" below), or the external volume is away;
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

N FILES IN FLIGHT (`default_jobs`, `--jobs`): the check and proof drivers keep `jobs`
files in flight (CorpusPool.swift), each under its own deadline. A launch of
N that dies is judged by no one: the files it left unfinished are run again
one at a time, and only such a launch writes `crash` or `timeout` (`settle`).

Memory: the manifest (6,351 rows in v2, ~2 MB as JSON) and the run's event lines
(~6 per file: a few MB), read once per launch; the config handed to the driver
lists every pending file (~1 MB).
Disk: the sealed catalog (~1 MB per 234 files: ~30 MB in v2); the proof lane holds one balanced copy per
file in flight under ~/corpus/work/<run>/ — as many as the disk holds under TRANSIENT_CEILING
(`proof_width`), at most `jobs` — and the run's work folder is removed at the end. The verbs lane's clones share their blocks with the corpus (0 bytes
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
SHA_LIST = "corpus-sha-v1.txt"                   # `<sha256>  media/Volumes/…`, relative to ~/corpus
SOURCE_BACKUP = "catalog-source-backup.sqlite"
# v2 (DECISIONS 2026-11-19): the corpus on two roots. When MANIFEST_V2 is there it is THE manifest
# (v1's rows and v2's, each with its root) and SOURCE_BACKUP_V2 is the backup it was chosen from.
MANIFEST_V2 = "corpus-manifest-v2.json"
SHA_LIST_V2_INTERNAL = "corpus-sha-v2-internal.txt"     # `<sha256>  Volumes/…`, relative to ~/corpus/media
SHA_LIST_V2_EXTERNAL = "corpus-sha-v2-external.txt"     # on the external volume: <mount>/corpus/, relative to <mount>/corpus/media
SOURCE_BACKUP_V2 = "catalog-source-backup-v2.sqlite"
VOLUME_PIN = "external-volume.json"              # the adopted external volume: {mount, volume_uuid} (`adopt-volume`)
ROOTS = ("internal", "external", "ro")
# Where an `ro` row's file would be read: no share is mounted yet, so a path that never exists (/var/empty
# is the system's empty, root-owned folder). Every `ro` file is NOT RUN until the share is set up.
RO_NOT_MOUNTED = Path("/var/empty/corpus-ro-share-not-mounted")
DOCUMENTS = (MANIFEST, SHA_LIST, SOURCE_BACKUP, MARKER, MANIFEST_V2, SHA_LIST_V2_INTERNAL, SOURCE_BACKUP_V2, VOLUME_PIN)
VOLUMES = "/Volumes"                             # adopt-volume takes a volume mounted directly in this folder
_UUID = re.compile(r"[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}")
TRANSFORM_VERSION = 2            # 2: pair links carried as row_knowledge 'pair' rows

OVERLAY_DIR = "VideoScan/VideoScanTests/CorpusHarnessOverlay"     # untracked, in the testbed, for one run
PROOF_ENGINE_GLOB = "VideoScan/VideoScan/MediaOps/BalancedCopyProof*.swift"
PROOF_STRATUM = "one-sided sound"
# The proof lane's files: v1's one-sided-sound stratum, then every file the newest whole check run
# found one-sided (Verify Audio's channelImbalance finding, with its side), smallest first, PROOF_CAP
# in all. Each file is balanced into a copy of about its own size under ~/corpus/work: the lane
# refuses to start unless the largest of them still leaves the disk under TRANSIENT_CEILING.
PROOF_CAP = 40
ONE_SIDED_KINDS = frozenset({"channelImbalance:leftOnly", "channelImbalance:rightOnly"})
TRANSIENT_CEILING = 0.95                         # DECISIONS 2026-11-19: a run may take the M4 to 95% used, never past it
# SMOKE (DECISIONS 2026-11-19: "a subset to verify the design of it ... and it runs in 15 mins and we see the
# harness works"): each lane on a small STRATIFIED subset of the present files, chosen deterministically —
# check: the smallest file of each (stratum, container, video, audio) mix, strata dealt round-robin, at most
# SMOKE_CHECK; proof: the SMOKE_PROOF smallest of its usual files; verbs: one file per role (every verb once).
# The verdict then means "the harness, the host and the code run end to end"; a smoke run is never a baseline.
SMOKE_CHECK = 60
SMOKE_PROOF = 2
SMOKE_NOTE = "SMOKE: a stratified subset — the verdict means the harness, the host and the code run end to end; never a baseline"

# lane -> (XCTest class, its engines in order, default per-file deadline in seconds, driver sources)
LANES = {
    "check": ("CorpusCheckDriver", ["probe", "check", "audio", "pair"], 300,
              ["CorpusSeal.swift", "CorpusDriverSupport.swift", "CorpusPool.swift", "CorpusCheckDriver.swift"]),
    "proof": ("CorpusProofDriver", ["balance", "proof"], 3600,
              ["CorpusSeal.swift", "CorpusDriverSupport.swift", "CorpusPool.swift", "CorpusProofDriver.swift"]),
    "verbs": ("CorpusVerbsDriver", ["group", "trash_copy", "dedupe", "trash_last", "purge", "set_aside", "promote", "intact"],
              3600, ["CorpusSeal.swift", "CorpusDriverSupport.swift", "CorpusPool.swift", "CorpusVerbsDriver.swift"]),
}
# N FILES IN FLIGHT (Rick 2026-11-20: "2 hour testbeds in serial is not performant design … N == 1 does not sound
# good"). The check and proof drivers walk their files through CorpusPool.swift, `jobs` at a time, each file under
# its own deadline; the config carries `jobs`. The default is half the host's logical cores (Rick 2026-11-20: the
# M4's 16 -> 8, the Ultra's 30 -> 15; the other half is left for the machine — the work is ffprobe/ffmpeg children,
# several threads each). No lower cap for memory: N files hold ~N x 2.5 MB of engine output (ProcessRunner's caps)
# and the hosts have 64-96 GB. `--jobs` sets it, 1..JOBS_MAX, and `--jobs 1` is the serial
# run exactly. A launch with more than one file in flight NEVER convicts: a crash or a deadline there leaves every
# file it had not finished to be run again ALONE (`settle`'s `alone`), and only a launch of one file at a time
# writes `crash` or `timeout` — a file is never RED for what the file beside it did, or for sharing the cores.
# The verbs lane is one batch (its steps act on the whole sample together): always one launch of width 1.
JOBS_MAX = 32
# ONE BUILD (Charter §7; Rick: "obviously you don't want to recompile if you don't have to"), the gauntlet's
# pattern (scripts/gauntlet/Runner.swift: one build-for-testing, then test-without-building per stage): the
# overlay always holds EVERY lane's driver, so one build serves check, proof and verbs. After a build the
# lane leaves BUILD_MARK in the DerivedData folder — the commit, the config, the coverage flag, the
# SHA-256 of the driver sources and of the built VideoScanTests binary — and a later lane reuses the
# build (test-without-building on its own patched copy of the .xctestrun) while all of them still hold.
# Another build into that folder (the ui lane, the smoke testbed's sensor lane) changes the binary, so
# the next corpus lane builds again. The full suite lane is NOT this build: it builds Release into its
# own folder (nightly_local_tests.sh) and must never compile the untracked driver sources; the smoke
# testbed's sensor lane builds Debug without the overlay; so a testbed run makes two builds, not four.
ALL_DRIVERS = ("CorpusSeal.swift", "CorpusPool.swift", "CorpusDriverSupport.swift", "CorpusCheckDriver.swift",
               "CorpusProofDriver.swift", "CorpusVerbsDriver.swift")
BUILD_MARK = "corpus-build.json"
VERBS_SAMPLE = 20                                # files the verbs lane clones (--limit changes it)
VERBS_ROLES = ("dup", "purge", "set_aside", "promote")     # dealt round-robin over the sample
VERBS_COPIES = 2                                 # extra byte-identical clones of each `dup` file
VERBS_MAX_FILE = 2 << 30                         # a sampled file is at most 2 GiB (every engine reads it whole, some twice)
VERBS_PROMOTE_BYTES = 4 << 30                    # Promote makes real copies: at most this much in the scratch archive
VERBS_FREE_FLOOR = 20 << 30                      # refuse to start with less free space than this
LOSS_WORDS = ("LOST", "MISMATCH")                # a clone that is gone or no longer its SHA-256: RED
# A file on the external root that was not run because the volume was no longer proven when the run
# came to it (the driver's word, CorpusSeal.mayOpen; or the lane's, between launches): NOT RUN, AMBER.
EXTERNAL_GONE = "external_volume_not_proven"
HARNESS_WORDS = ("crash", "timeout", "not_run", "no_record")       # outcomes the harness itself assigns
# GH #498 (c), seen 2026-11-20 (reported GREEN) and 2026-11-22 (AMBER) on the M4: the test host waited on macOS's
# Removable Volumes prompt and EVERY external file came back unopenable. A privacy refusal applies to the whole
# process, and `prepare` had hashed those files, so "every external file in the run unreadable by the host" is an
# ENVIRONMENT failure: RED, with the reason, never a corpus finding and never a baseline. A file counts as unread
# when every engine below that ran on it gave one of these words (the engines that open the file; `pair` and the
# proof step read nothing new). Only lanes whose host reads the external volume have such engines: check and
# proof. The verbs lane runs clones of internal files only (the harness sweeps the volume, the host never reads it).
UNREAD_WORDS = {"probe": ("unopenable",), "check": ("unopenable", "error:couldNotRead"),
                "audio": ("error:probeFailed",), "balance": ("error:probeFailed",)}
ACCESS_REASON = ("the test app could not read any file on the external volume ({n} of {n} unreadable) — most likely "
                 "macOS is asking for access on the M4's screen (VideoScan → Files and Folders / Removable Volumes) — "
                 "click Allow and run again; nothing was judged")

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


def plain_absolute(path: str) -> bool:
    """Absolute, not "/", and every component a plain name (no "", ".", ".."): the same rule as
    CorpusSeal.isPlainAbsolute (Codex #331 F4: normpath keeps a leading "//")."""
    parts = path.split("/")
    return path.startswith("/") and len(parts) > 1 and all(part not in ("", ".", "..") for part in parts[1:])


def diskutil_volume_uuid(mount: str) -> str:
    """The APFS volume UUID of what is mounted at `mount`, as `diskutil info` reads it (the same
    value Foundation's volumeUUIDString gives the in-app seal; measured equal 2026-11-19), or ""."""
    try:
        done = subprocess.run(["/usr/sbin/diskutil", "info", "-plist", mount], capture_output=True, timeout=60,
                              stdin=subprocess.DEVNULL)
        return str(plistlib.loads(done.stdout).get("VolumeUUID", "")).upper() if done.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError, ValueError, plistlib.InvalidFileException):
        return ""


# ── The access probe (the macOS privacy prompt on a headless M4) ─────────
# A Python that reads a removable volume for the first time makes macOS (TCC) ask "Python would like
# to access files on a removable volume" — and the asking open() blocks in the kernel until someone
# clicks. Under the per-run LaunchAgent (gui/501) on the headless M4 nobody does: 2026-11-19 `prepare`
# sat 35+ minutes at 0% CPU in open() on the external root, the lock held, until the lane watchdog.
# So before anything of ours reads the external root, a CHILD process of the same interpreter (the
# grant is per interpreter path) reads there; if it does not finish in time the run is refused and
# the child is left behind (never waited on, never signalled: it may be stuck in the kernel).
ACCESS_PROBE_TIMEOUT_S = 20.0            # a readable volume answers in milliseconds; the prompt never does
ACCESS_PROBE_DENIED = 13                 # the child's exit status when a read is refused (EPERM/EACCES)
# The child: list the volume, read 64 bytes of the marker and of one media file (TCC may gate a
# file's contents, not only its name). Any OSError but a permission one is not the probe's to judge
# (the seal's own checks speak for a missing marker or folder): exit 0. Bounded: at most 64 names a
# folder and 16 folders deep on the way to the first file.
_ACCESS_PROBE_CHILD = r"""
import errno, os, sys
mount = sys.argv[1]
def read(path):
    with open(path, "rb") as f:
        f.read(64)
def first_file(folder, depth=0):
    if depth > 16:
        return None
    with os.scandir(folder) as names:
        entries = sorted((e for _, e in zip(range(64), names)), key=lambda e: e.name)
    for e in entries:
        if e.is_file(follow_symlinks=False):
            return e.path
    for e in entries:
        if e.is_dir(follow_symlinks=False):
            found = first_file(e.path, depth + 1)
            if found:
                return found
    return None
try:
    os.listdir(mount)
    for step in (lambda: read(os.path.join(mount, "THIS_IS_TEST_DATA.txt")),
                 lambda: (lambda f: f and read(f))(first_file(os.path.join(mount, "corpus", "media")))):
        try:
            step()
        except OSError as error:
            if isinstance(error, PermissionError) or error.errno in (errno.EPERM, errno.EACCES):
                raise
except OSError as error:
    if isinstance(error, PermissionError) or error.errno in (errno.EPERM, errno.EACCES):
        sys.exit(13)
sys.exit(0)
"""


# GH #498 (2026-11-21): the corpus test host reads the external volume, so macOS asks it for Removable
# Volumes access. An ad-hoc signature (CODE_SIGN_IDENTITY=-) gives every build a new identity (cdhash),
# so the M4 asked again after every build, on a screen nobody watches. Signed with the Mac's own
# Apple Development identity (the project's team), the designated requirement stays the same across
# builds and one Allow lasts. A Mac without that identity keeps the ad-hoc build and says why.
CORPUS_SIGN_TEAM = "V9SVEQF26M"                  # the project's DEVELOPMENT_TEAM (project.pbxproj)
CORPUS_SIGN_IDENTITY = "Apple Development"


def has_signing_identity(team: str = CORPUS_SIGN_TEAM, runner=subprocess.run) -> bool:
    """True when the login keychain holds a valid Apple Development identity of `team`."""
    try:
        listed = runner(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"],
                        capture_output=True, text=True, timeout=30).stdout or ""
    except (OSError, subprocess.SubprocessError):
        return False
    if CORPUS_SIGN_IDENTITY not in listed:
        return False
    try:
        pem = runner(["/usr/bin/security", "find-certificate", "-c", CORPUS_SIGN_IDENTITY, "-p"],
                     capture_output=True, text=True, timeout=30).stdout or ""
        subject = runner(["/usr/bin/openssl", "x509", "-noout", "-subject"], input=pem,
                         capture_output=True, text=True, timeout=30).stdout or ""
    except (OSError, subprocess.SubprocessError):
        return False
    return f"OU={team}" in subject.replace(" ", "")


def corpus_signing(out: Optional[Path] = None, available=has_signing_identity) -> List[str]:
    """The build settings that sign the corpus test host. VIDEOSCAN_CORPUS_SIGN=adhoc forces the old build."""
    if os.environ.get("VIDEOSCAN_CORPUS_SIGN") != "adhoc" and available():
        return [f"CODE_SIGN_IDENTITY={CORPUS_SIGN_IDENTITY}", f"DEVELOPMENT_TEAM={CORPUS_SIGN_TEAM}",
                "CODE_SIGN_STYLE=Manual"]
    note = ("corpus: building the test host ad hoc (no Apple Development identity of team "
            f"{CORPUS_SIGN_TEAM} in the keychain) — macOS will ask it for access to the external "
            "volume again after every build (GH #498)")
    print(note, file=sys.stderr, flush=True)
    return ["CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual"]


def access_probe_command(mount: str) -> List[str]:
    """The probe child's command line: THIS interpreter (TCC grants per executable path), isolated.
    A seam: the tests put a child that sleeps past the timeout or is refused in its place."""
    return [sys.executable, "-I", "-c", _ACCESS_PROBE_CHILD, mount]


def access_probe(mount: str, timeout: Optional[float] = None) -> None:
    """Refused unless a child process of this interpreter can list the external root and read a few
    bytes of its marker and of one media file within `timeout` seconds (ACCESS_PROBE_TIMEOUT_S).
    Worst case: one child process and `timeout` seconds; nothing is kept."""
    limit = ACCESS_PROBE_TIMEOUT_S if timeout is None else timeout
    interpreter = os.path.realpath(sys.executable)
    where = (f"in System Settings › Privacy & Security › Files and Folders (Removable Volumes) or Full Disk Access "
             f"allow {interpreter} — the grant is per interpreter path, so a Homebrew Python upgrade (a new Cellar "
             f"path) needs it again. Nothing ran.")
    try:
        child = subprocess.Popen(access_probe_command(mount), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL)
    except OSError as error:
        raise Refused(f"refused: the external-volume access probe could not start ({type(error).__name__}). Nothing ran.")
    try:
        code = child.wait(timeout=limit)
    except subprocess.TimeoutExpired:
        # Left as it is, never waited on and never signalled (the harness sends no signal: SealTests):
        # it holds no pipe of ours (all three streams are /dev/null), so nothing downstream waits for
        # it; it exits by itself once the prompt is answered, or with the LaunchAgent's process group.
        raise Refused(f"refused: macOS is waiting for permission to read the external volume (a privacy prompt on the "
                      f"M4's screen; the probe got no answer in {limit:g} s). Click Allow on the M4 (Screen Sharing), or "
                      + where)
    if code == ACCESS_PROBE_DENIED:
        raise Refused("refused: macOS does not let this Python read the external volume (Operation not permitted). "
                      "On the M4, " + where)
    if code != 0:
        raise Refused(f"refused: the external-volume access probe failed (exit {code}). Nothing ran.")


class External:
    """The external root as the seal found it. `state`: "none" (no volume was adopted), "absent"
    (adopted, and nothing is mounted at its mount point) or "ok" (mounted there, the marker on it,
    the adopted volume UUID). A volume mounted there that is not the adopted one never gets here:
    `Seal.external` refuses it."""

    def __init__(self, state: str, mount: Optional[Path] = None, uuid: Optional[str] = None):
        self.state, self.mount, self.uuid = state, mount, uuid      # uuid: the volume proven ("ok" only)

    @property
    def media(self) -> Optional[Path]:
        return self.mount / "corpus" / "media" if self.mount is not None else None


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
        self.volumes = Path(VOLUMES)                         # adopt-volume's folder of mounts (tests: a temporary one)
        self.volume_uuid = diskutil_volume_uuid              # a seam: the tests ask diskutil about a real disk image too
        self.hasher = sha256_file                            # a seam: the tests' fake media stand for their manifest SHA-256
        self._external: Optional[External] = None
        self.access_probe = access_probe                     # a seam (tests); asked once per mount per process:
        self._readable: set = set()                          # the TCC grant is the process's, not the run's

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
        # ~/corpus and its own folders are on the home volume: a volume mounted over one of them (the
        # adopted one included) would make its files "writable" or "removable" (Codex #332 F2).
        home_dev = self.home_device()
        if (os.path.islink(str(self.corpus))
                or os.path.realpath(str(self.corpus)) != os.path.join(os.path.realpath(str(self.home)), "corpus")):
            raise Refused("refused: ~/corpus is a link or resolves somewhere else — it must be itself")   # Codex #334 F4
        for folder in [self.corpus] + [self.corpus / name for name in ("state", "work", "reports", "media")]:
            if os.path.lexists(str(folder)) and os.lstat(str(folder)).st_dev != home_dev:
                raise Refused("refused: a corpus folder is on another volume (something is mounted over it)")
        self.pin()                                           # an adopted volume's record that is not one stops everything
        return self

    def home_device(self) -> int:
        """The device of the home folder (the account database's): the one volume the harness writes and removes on."""
        return os.lstat(str(self.home)).st_dev

    def on_home_volume(self, path: Path) -> bool:
        """True when what `path` resolves to is on the home volume: its deepest existing part (the
        file, or the folder it would be made in) is on the home folder's device. Everything below a
        mount point is on the mounted volume, so a volume mounted anywhere on the way (inside
        reports/, over a run folder, at an out folder, in the testbed) makes it False (Codex #333 F1,
        #334 F3). CorpusSeal.onHomeVolume is the same rule."""
        here = os.path.realpath(str(path))
        while not os.path.lexists(here):
            up = os.path.dirname(here)
            if up == here:
                return False
            here = up
        return os.lstat(here).st_dev == self.home_device()

    def pin(self) -> Optional[dict]:
        """The adopted external volume, {mount, volume_uuid}, or None when none was adopted. Refused
        when ~/corpus/external-volume.json is there and is not a plain file of the corpus holding one."""
        path = self.corpus / VOLUME_PIN
        if not os.path.lexists(str(path)):
            return None
        bad = Refused(f"refused: ~/corpus/{VOLUME_PIN} is not the record `adopt-volume` writes (a link, or not one volume)")
        if (os.path.islink(str(path)) or not path.is_file() or os.lstat(str(path)).st_nlink != 1
                or os.path.realpath(str(path)) != os.path.join(os.path.realpath(str(self.corpus)), VOLUME_PIN)):
            raise bad                                        # a second name could be a run's progress file (Codex #331 F3)
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
            mount, uuid = value["mount"], str(value["volume_uuid"]).upper()
        except (OSError, ValueError, KeyError, TypeError, AttributeError):
            raise bad
        if not isinstance(mount, str) or not plain_absolute(mount) or not _UUID.fullmatch(uuid):
            raise bad
        return {"mount": mount, "volume_uuid": uuid}

    def pinned_mount(self) -> Optional[Path]:
        """The adopted mount point, for what must never be written; None when there is no readable pin."""
        try:
            pin = self.pin()
        except Refused:
            return None
        return Path(pin["mount"]) if pin else None

    def external(self) -> External:
        """The external root, proven (asked once per process; a lane is minutes, a mount is not
        swapped under it by anything of ours). Absent: nothing is mounted at the adopted mount point
        (it is not there, or is a plain folder). Refused: the mount point is reached through a link,
        this interpreter may not read it in time (`access_probe`: the macOS privacy prompt), or what
        is mounted there carries no marker or is not the adopted volume (its volume UUID)."""
        if self._external is not None:
            return self._external
        pin = self.pin()
        if pin is None:
            self._external = External("none")
            return self._external
        mount = pin["mount"]
        if not os.path.lexists(mount):
            self._external = External("absent", Path(mount))
            return self._external
        if os.path.realpath(mount) != mount:
            raise Refused("refused: the external corpus volume is reached through a link")
        if not os.path.ismount(mount):
            self._external = External("absent", Path(mount))
            return self._external
        # Before the first read of anything on it (the marker below, the lists, the media): may this
        # interpreter read there at all, or is macOS holding the read for a privacy click nobody makes?
        if mount not in self._readable:
            self.access_probe(mount)
            self._readable.add(mount)
        try:
            marker = os.lstat(os.path.join(mount, MARKER))
        except OSError:
            marker = None
        if marker is None or not stat.S_ISREG(marker.st_mode):
            raise Refused(f"refused: the volume at the external root carries no {MARKER}")
        if self.volume_uuid(mount) != pin["volume_uuid"]:
            raise Refused("refused: the volume mounted at the external root is not the adopted one (its volume UUID differs)")
        media = os.path.join(mount, "corpus", "media")
        if os.path.lexists(media) and os.path.realpath(media) != media:
            raise Refused("refused: the external corpus volume is reached through a link")
        self._external = External("ok", Path(mount), pin["volume_uuid"])
        return self._external

    def reprove_external(self) -> External:
        """The external root proven AFRESH (the cached proof dropped): for a step that must know the volume
        is still the adopted one at this moment (corpus_shrink.py, after it opened the X10's media folder)."""
        self._external = None
        return self.external()

    def pristine(self, path: Path) -> bool:
        """True when `path` resolves inside the parts of the corpus nothing may write: the media
        copies, the read-only mount, the adopted external volume (whole, mounted or not), or one
        of the corpus documents."""
        if _under(path, self.media) or _under(path, self.corpus / "live"):
            return True
        mount = self.pinned_mount()
        if mount is not None and _under(path, mount):
            return True
        resolved = os.path.realpath(str(path))
        return any(resolved == os.path.realpath(str(self.corpus / name)) for name in DOCUMENTS)

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
        if not self.on_home_volume(path):
            raise Refused("refused: a write was aimed at another volume (something is mounted on the way)")
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
                or self.pristine(out) or _under(out, self.corpus) or not self.on_home_volume(out)):
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
    __slots__ = ("sha", "original", "size", "stratum", "path", "root")

    def __init__(self, sha: str, original: str, size: int, stratum: str, path: Path, root: str = "internal"):
        self.sha, self.original, self.size, self.stratum, self.path, self.root = sha, original, size, stratum, path, root

    @property
    def folder(self) -> str:
        """The media folder the copy sits under (the path less the original's own): a root's media, or a run's clones."""
        path = str(self.path)
        return path[: len(path) - len(self.original)] if path.endswith(self.original) else "/unresolvable"


def manifest_name(seal: Seal) -> str:
    """v2 when its manifest is there (it holds v1's rows too), else v1."""
    return MANIFEST_V2 if os.path.lexists(str(seal.corpus / MANIFEST_V2)) else MANIFEST


def load_manifest(seal: Seal, data: Optional[bytes] = None) -> List[Entry]:
    """Every corpus file, each with its root and the place its copy sits: an internal file under
    ~/corpus/media, an external one under <the adopted mount>/corpus/media (whether or not that is
    mounted now: whether it may be run is the lane's question, `Seal.external`). `data`: the manifest's
    bytes as the caller already read them (a lane hashes the very bytes it parses: Codex #359 F7)."""
    name = manifest_name(seal)
    try:
        rows = json.loads((data if data is not None else (seal.corpus / name).read_bytes()).decode("utf-8"))
    except (OSError, ValueError):
        raise Refused(f"refused: ~/corpus/{name} is missing or unreadable")
    pin = seal.pin()
    entries, seen = [], set()
    for row in rows if isinstance(rows, list) else []:
        sha, original = str(row["sha256"]).lower(), str(row["path"])
        root = str(row.get("root", "internal")) if name == MANIFEST_V2 else "internal"
        if not re.fullmatch(r"[0-9a-f]{64}", sha) or not original.startswith("/Volumes/") or ".." in original.split("/"):
            raise Refused("refused: a manifest row is not a sha256 plus an original /Volumes path")
        if root not in ROOTS:
            raise Refused("refused: a manifest row's root is not internal, external or ro")
        if sha in seen:
            raise Refused("refused: the manifest lists one content twice")
        if root == "external" and pin is None:
            raise Refused("refused: the manifest has files on the external volume and no volume was adopted — "
                          "run `scripts/corpus_run.sh adopt-volume <mount>` first")
        seen.add(sha)
        folder = (seal.media if root == "internal" else RO_NOT_MOUNTED if root == "ro"
                  else Path(pin["mount"]) / "corpus" / "media")
        entries.append(Entry(sha, original, int(row["size"]), str(row.get("why", "")), folder / original.lstrip("/"), root))
    if not entries:
        raise Refused("refused: the manifest is empty")
    return sorted(entries, key=lambda e: e.sha)


def sha_lists(seal: Seal, external: External) -> List[Tuple[Path, Path, str]]:
    """The second documents (sha256 + relative path), each with the folder its paths are relative
    to and the root whose copies it lists. v1: one, relative to ~/corpus (internal). v2: that one,
    ~/corpus's list of the v2 internal files (relative to ~/corpus/media), and — when the external
    volume is there — its own list (external)."""
    lists = [(seal.corpus / SHA_LIST, seal.corpus, "internal")]
    if manifest_name(seal) == MANIFEST_V2:
        lists.append((seal.corpus / SHA_LIST_V2_INTERNAL, seal.media, "internal"))
        if external.state == "ok":
            lists.append((external.mount / "corpus" / SHA_LIST_V2_EXTERNAL, external.media, "external"))
    return lists


def check_sha_list(seal: Seal, entries: List[Entry], external: Optional[External] = None) -> int:
    """The second documents (sha256 + relative path) never contradict the manifest: a listed
    content that IS a manifest entry must be at the manifest's place. A list may be shorter than the
    manifest (the manifest is the wish list; a copy list names what was sent so far), and may name
    content the manifest no longer holds (the sample dropped it, DECISIONS 2026-11-24: its copy waits
    for `corpus_shrink.py apply`): that line is no longer the manifest's business. Each list is held
    only to the manifest's rows on ITS OWN root: a content the sample moved to the other drive leaves a
    dropped copy on the old one, named by the old drive's list (reviewer 2026-11-24)."""
    wanted = {(e.sha, e.root): os.path.normpath(str(e.path)) for e in entries if e.root != "ro"}  # ro: no copy
    wrong = 0
    for document, base, root in sha_lists(seal, external or External("none")):
        if os.path.islink(str(document)):
            raise Refused("refused: a corpus SHA-256 list is a link")
        try:
            text = document.read_text(encoding="utf-8")
        except FileNotFoundError:
            continue                                         # nothing sent to that root yet
        except OSError:
            raise Refused("refused: a corpus SHA-256 list is unreadable")
        for line in text.splitlines():
            if line.strip():
                sha, rel = line.split(None, 1)
                key = (sha.lower(), root)
                if key in wanted and wanted[key] != os.path.normpath(str(base / rel.strip().lstrip("*"))):
                    wrong += 1
    return wrong


# ── ingest: what is PRESENT is earned once (DECISIONS 2026-11-19, the wish list) ──
#
# The manifest is the wish list. A file is PRESENT when `prepare` has read it whole and its SHA-256
# is the manifest's: the ledger (~/corpus/state/corpus-ledger.json) then records its root, size, mtime
# and inode, and later runs trust those against it (a stat per file, no hashing; a same-size file renamed
# into place is a new inode and is hashed again). A lane checks each file again right before each launch
# (the build takes minutes): one that moved since is dropped from the run and counted. Per file:
#   missing     not in the ledger: not copied yet, still copying, or not the manifest's size (a file
#               whose size differs is never hashed: rsync renames a copy into place only when whole)
#   mismatched  hashed, and its bytes are not the manifest's SHA-256 — never run (AMBER)
#   vanished    ingested, and gone now (AMBER)
#   changed     ingested, and its size or mtime moved (AMBER; `prepare` hashes it again)
#   not_run     on the external volume while it is not mounted (the whole root; AMBER as before)
#   present     ingested, unchanged, and in the sealed catalog — the only files a lane runs
# Missing never moves a verdict and never blocks prepare or a lane.
# Memory: the ledger is one dict of ~6,400 small records (~1 MB as JSON); hashing streams 8 MiB at a time.

LEDGER = "corpus-ledger.json"
HASH_CHUNK = 8 << 20
LEDGER_CHECKPOINT_S = 60                         # an interrupted ingest keeps what it hashed up to a minute ago
STATES = ("present", "missing", "mismatched", "vanished", "changed", "not_run")
PROBLEM_STATES = ("mismatched", "vanished", "changed")


class Ledger:
    """What `ingest` proved, by SHA-256: {sha: {root, size, mtime_ns, status: ok|mismatched}}."""

    def __init__(self, seal: Seal, files: Optional[Dict[str, dict]] = None):
        self.seal, self.files = seal, files or {}
        self.path = seal.state / LEDGER

    @classmethod
    def load(cls, seal: Seal) -> "Ledger":
        path = seal.state / LEDGER
        if not os.path.lexists(str(path)):
            return cls(seal)
        bad = Refused(f"refused: ~/corpus/state/{LEDGER} cannot be read back — move it into ~/corpus/.trash and run "
                      "`scripts/corpus_run.sh prepare` (every file is hashed again)")
        try:
            value = json.loads(seal.contained(path, seal.state).read_text(encoding="utf-8"))
            files = value["files"]
            ok = (value.get("version") == 1 and isinstance(files, dict) and all(
                re.fullmatch(r"[0-9a-f]{64}", sha) and isinstance(r, dict) and r.get("root") in ROOTS
                and r.get("status") in ("ok", "mismatched")
                and all(isinstance(r.get(k), int) and not isinstance(r.get(k), bool) for k in ("size", "mtime_ns", "ino"))
                for sha, r in files.items()))
        except (OSError, ValueError, KeyError, TypeError, AttributeError):
            raise bad
        if not ok:
            raise bad
        return cls(seal, files)

    def save(self) -> None:
        """Whole or not at all: a new file beside it, renamed over it."""
        pending = self.seal.state / f"{LEDGER}.{os.getpid()}"
        self.seal.write_text(pending, json.dumps({"version": 1, "files": self.files}, sort_keys=True) + "\n")
        os.replace(str(pending), str(self.seal.writable(self.path)))


def sha256_file(path: Path, size: int) -> Optional[Tuple[str, int, int, int]]:
    """(SHA-256, size, mtime_ns, inode) of the regular file at `path` if it is `size` bytes and does
    not change while it is read; None otherwise. Opened without following a link; read only."""
    try:
        fd = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return None
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_size != size:
            return None
        digest = hashlib.sha256()
        while True:
            chunk = os.read(fd, HASH_CHUNK)
            if not chunk:
                break
            digest.update(chunk)
        after = os.fstat(fd)
        if (after.st_size, after.st_mtime_ns) != (before.st_size, before.st_mtime_ns):
            return None                                      # still being written: not ingested this time
        return digest.hexdigest(), after.st_size, after.st_mtime_ns, after.st_ino
    except OSError:
        return None
    finally:
        os.close(fd)


def same_file(record: dict, info) -> bool:
    """The file the ledger proved: the same size, mtime AND inode — a same-size replacement renamed
    into place with the old mtime is a new inode, so it is hashed again (Codex #336 F3)."""
    return (record["size"], record["mtime_ns"], record.get("ino")) == (info.st_size, info.st_mtime_ns, info.st_ino)


def _stat(entry: Entry):
    try:
        info = os.lstat(str(entry.path))
    except OSError:
        return None
    return info if stat.S_ISREG(info.st_mode) else None


def ingest(seal: Seal, entries: List[Entry], ledger: Ledger, unavailable: Iterable[str] = (),
           hasher=sha256_file) -> Dict[str, int]:
    """Hash each file that arrived (or changed) since the last ingest, if it is the manifest's size.
    Idempotent: a file the ledger already holds at the same size and mtime is not read again."""
    skip, counts, last = set(unavailable), Counter(), time.time()
    for e in entries:
        if e.sha in skip:
            continue
        info, record = _stat(e), ledger.files.get(e.sha)
        if info is None or info.st_size != e.size:
            continue                                         # missing, vanished, or not whole: never hashed
        if record and same_file(record, info):
            continue                                         # proven before, unchanged
        got = hasher(e.path, e.size)
        if got is None:
            counts["unsettled"] += 1
            continue
        digest, size, mtime_ns, ino = got
        status = "ok" if digest == e.sha else "mismatched"
        counts["rehashed" if record else "hashed"] += 1
        counts[status] += 1
        counts["bytes"] += size
        ledger.files[e.sha] = {"root": e.root, "size": size, "mtime_ns": mtime_ns, "ino": ino, "status": status}
        if time.time() - last > LEDGER_CHECKPOINT_S:
            ledger.save()
            last = time.time()
    ledger.save()
    return dict(counts)


def classify(entries: List[Entry], ledger: Ledger, unavailable: Iterable[str] = (),
             built_over: Optional[Iterable[str]] = None) -> Dict[str, str]:
    """Each file's state now (see above), by a stat against the ledger — no hashing. `built_over`:
    the files the sealed catalog holds; an ingested file it does not hold yet reads `missing`."""
    skip = set(unavailable)
    built = set(built_over) if built_over is not None else None
    states = {}
    for e in entries:
        record = ledger.files.get(e.sha)
        info = None if e.sha in skip else _stat(e)
        if e.sha in skip:
            states[e.sha] = "not_run"
        elif record is None:
            states[e.sha] = "missing"
        elif info is None:
            states[e.sha] = "vanished"
        elif not same_file(record, info):
            states[e.sha] = "changed"
        elif record["status"] != "ok":
            states[e.sha] = "mismatched"
        elif built is not None and e.sha not in built:
            states[e.sha] = "missing"                        # proven after the last prepare: waits for the next
        else:
            states[e.sha] = "present"
    return states


def inventory(entries: List[Entry], states: Dict[str, str]) -> Tuple[Dict[str, Dict[str, int]], Dict[str, List[str]]]:
    """Counts per root and state, and the problem files named by SHA-256 prefix (at most LISTED each)."""
    counts: Dict[str, Dict[str, int]] = {root: {} for root in ROOTS}
    named: Dict[str, List[str]] = {}
    for e in entries:
        state = states[e.sha]
        counts[e.root][state] = counts[e.root].get(state, 0) + 1
        if state in PROBLEM_STATES:
            named.setdefault(state, []).append(sha_prefix(e.sha))
    return {r: c for r, c in counts.items() if c}, {k: sorted(v)[:LISTED] for k, v in named.items()}


def inventory_line(counts: Dict[str, Dict[str, int]]) -> str:
    """`internal present 250 · missing 5 | external present 6,000 · missing 96`: the order of STATES, zeros left out."""
    return " | ".join(f"{root} " + " · ".join(f"{state} {n:,}" for state in STATES for n in [c.get(state, 0)]
                                               if n or state in ("present", "missing"))
                      for root, c in counts.items())


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


def build_catalog(seal: Seal, source: Path, entries: List[Entry], dest: Path) -> Dict[str, int]:
    """Create `dest` (new file, rollback journal) from `source` as described above. Each row's
    paths are rewritten under ITS entry's folder (`Entry.folder`): ~/corpus/media or the external
    volume's corpus/media, or (the verbs lane) a run's folder of clones laid out the same way."""
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

        conn.execute("CREATE TEMP TABLE chosen (sha TEXT PRIMARY KEY, original TEXT NOT NULL, file_id TEXT, prefix TEXT NOT NULL)")
        if any(not e.folder.startswith("/") for e in entries):
            raise Refused("refused: a corpus file's place is not its original path under a media folder")
        conn.executemany("INSERT INTO chosen (sha, original, prefix) VALUES (?, ?, ?)",
                         [(e.sha, e.original, e.folder) for e in entries])
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

        columns = _columns(conn, "src", "files")
        for needed in ("id", "full_path", "path_fold", "directory", "volume_case_sensitive", "content_digest", "size_bytes"):
            if needed not in columns:
                raise Refused(f"refused: the backup's files table has no {needed} column — the schema moved; update the transform")
        select = []
        for column in columns:
            if column == "full_path":
                select.append("c.prefix || f.full_path")
            elif column == "directory":
                select.append("CASE WHEN f.directory IS NULL THEN NULL ELSE c.prefix || f.directory END")
            elif column == "path_fold":
                select.append("CASE WHEN f.volume_case_sensitive = 0 THEN lower(c.prefix) ELSE c.prefix END || f.path_fold")
            elif column in AUDIT_COLUMNS:
                select.append("NULL")
            else:
                select.append("f." + column)
        conn.execute(f"INSERT INTO main.files ({', '.join(columns)}) SELECT {', '.join(select)} "
                     "FROM src.files f JOIN chosen c ON c.file_id = f.id ORDER BY f.id")
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


def verify_catalog(seal: Seal, database: Path, entries: List[Entry], root: Optional[Path] = None,
                   checked: Optional[Iterable[str]] = None) -> Dict[str, int]:
    """Through the scripts' read-only door: the catalog holds exactly `entries` (the files it was
    built over), each row at its copy's place, and names no Master Archive. `root` (the verbs lane):
    every row under that folder of clones; otherwise each under its own root's media folder.
    `checked`: the files whose copy is looked at now (the present ones; None = all) — the other
    rows are counted (`not_checked`)."""
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
              "file_missing": 0, "size_differs": 0, "outside_corpus": 0, "removed_rows": 0, "not_checked": 0,
              "archive_designation": 0 if not designation or designation[0] is None else 1}
    wanted = {e.sha: e for e in entries}
    look = None if checked is None else set(checked)
    home_dev = seal.home_device()
    result["without_row"] = sum(1 for sha in wanted if sha not in by_sha)
    for sha, path, size, removal in rows:
        entry = wanted.get(sha)
        if entry is None:
            result["row_not_in_manifest"] += 1
            continue
        if removal is not None:
            result["removed_rows"] += 1
        if os.path.normpath(path) != os.path.normpath(str(entry.path)) or not _under(Path(path), root if root is not None else Path(entry.folder)):
            result["outside_corpus"] += 1
            continue
        if root is None and entry.folder not in (str(seal.media), str(Path(seal.pinned_mount() or "/unresolvable") / "corpus" / "media")):
            result["outside_corpus"] += 1                    # the sealed catalog names a copy in one of the two roots, nowhere else
            continue
        if look is not None and sha not in look:
            result["not_checked"] += 1
            continue
        try:
            info = os.stat(path)
            if entry.root == "internal" and info.st_dev != home_dev:
                result["outside_corpus"] += 1                # an internal copy is on the home volume, not on one mounted inside media
                continue
            if info.st_size != size or size != entry.size:
                result["size_differs"] += 1
        except OSError:
            result["file_missing"] += 1
    result["ok"] = int(result["rows"] == result["manifest"] and not any(
        result[k] for k in ("without_row", "row_not_in_manifest", "file_missing", "size_differs",
                            "outside_corpus", "removed_rows", "archive_designation")))
    return result


def source_backup(seal: Seal) -> Path:
    """The catalog backup the manifest was chosen from: v2's own, or v1's."""
    return seal.corpus / (SOURCE_BACKUP_V2 if manifest_name(seal) == MANIFEST_V2 else SOURCE_BACKUP)


def source_stamp(seal: Seal) -> List[int]:
    """The source backup's size and mtime: a new backup in its place rebuilds the catalog."""
    info = os.stat(str(source_backup(seal)))
    return [info.st_size, info.st_mtime_ns]


def prepared_record(seal: Seal) -> Optional[dict]:
    """~/corpus/state/prepare.json, or None when it cannot be read back as one."""
    try:
        value = json.loads(seal.contained(seal.state / "prepare.json", seal.state).read_text(encoding="utf-8"))
    except (OSError, ValueError, Refused):
        return None
    return value if isinstance(value, dict) else None


def prepare(seal: Seal, out: Optional[Path] = None) -> Tuple[int, List[str]]:
    """Ingest what arrived, then build the sealed catalog over the files proven so far. Nothing
    missing blocks it — not a file still copying, not an unplugged external volume.

    The catalog is REBUILT, whole, whenever the proven set differs from the one it was built over,
    and left alone when it does not ("nothing new"). Not appended to, by choice: it is a derived,
    sealed snapshot built from an immutable backup in seconds; one build path gives the same
    catalog for the same set whatever order the files arrived in, and the new file replaces the
    old one only once it verifies (never a half-updated catalog)."""
    seal.check()
    database_name, latch_name = _catalog_names()
    entries = load_manifest(seal)
    external = seal.external()
    unavailable = {e.sha for e in entries if e.root == "external" and external.state != "ok"}
    ro = {e.sha for e in entries if e.root == "ro"}             # the read-only share is not mounted yet
    disagree = check_sha_list(seal, entries, external)
    if disagree:
        raise Refused(f"refused: {manifest_name(seal)} and the SHA-256 lists disagree on {disagree} entries")
    if not source_backup(seal).is_file():
        raise Refused("refused: the catalog source backup is missing")
    seal.mkdir(seal.state)
    for name in ("home", "caches"):
        seal.mkdir(seal.state / name)
    ledger = Ledger.load(seal)
    ingested = ingest(seal, entries, ledger, unavailable | ro, hasher=seal.hasher)
    states = classify(entries, ledger, unavailable | ro)
    # Built over every proven file that is there or merely unplugged (an unplugged drive does not shrink it).
    # Never an `ro` file, whatever an earlier ingest proved of it on another root (Codex #359 F9).
    build = [e for e in entries if e.root != "ro" and (states[e.sha] == "present"
             or (states[e.sha] == "not_run" and (ledger.files.get(e.sha) or {}).get("status") == "ok"))]
    built_over = sorted(e.sha for e in build)
    previous = prepared_record(seal) or {}
    database = seal.state / database_name
    present = [e.sha for e in build if states[e.sha] == "present"]
    unchanged = (previous.get("built_over") == built_over and previous.get("transform_version") == TRANSFORM_VERSION
                 and previous.get("source_stamp") == source_stamp(seal)
                 and database.is_file() and (seal.state / latch_name).is_file()
                 and verify_catalog(seal, database, build, checked=present)["ok"])
    if unchanged:
        counts, verdict = previous.get("counts") or {}, verify_catalog(seal, database, build, checked=present)
    else:
        building = seal.state / f"building-{os.getpid()}"
        if building.exists():
            raise Refused("refused: a build folder with this pid is already there")
        seal.mkdir(building)
        stamp = source_stamp(seal)
        try:
            counts = build_catalog(seal, source_backup(seal), build, building / database_name)
            if source_stamp(seal) != stamp:                  # a new backup put in place while this one was read (Codex #336 F5)
                raise Refused("refused: the catalog source backup changed during prepare — run prepare again")
            seal.write_text(building / latch_name, "{}\n")   # the read doors want the latch beside the file
            verdict = verify_catalog(seal, building / database_name, build, checked=present)
            if not verdict["ok"]:
                raise Refused("refused: the built catalog did not verify — " + ", ".join(
                    f"{k}={v}" for k, v in sorted(verdict.items()) if v and k not in ("rows", "manifest", "not_checked")))
            os.replace(str(building / database_name), str(seal.writable(database)))
            os.replace(str(building / latch_name), str(seal.writable(seal.state / latch_name)))
        finally:
            remove_tree(seal, building)
    counts_by_root, named = inventory(entries, states)
    record = {"transform_version": TRANSFORM_VERSION, "prepared_at": time.strftime("%Y-%m-%d %H:%M:%S"),
              "manifest": manifest_name(seal),
              "manifest_sha256": hashlib.sha256((seal.corpus / manifest_name(seal)).read_bytes()).hexdigest(),
              "source_stamp": previous.get("source_stamp") if unchanged else stamp,
              "files": len(entries), "bytes": sum(e.size for e in entries), "built_over": built_over,
              "inventory": counts_by_root, "problems": named, "ingested": ingested,
              "strata": dict(Counter(e.stratum for e in entries)), "counts": counts, "verify": verdict,
              "rebuilt": not unchanged}
    seal.write_json(seal.state / "prepare.json", record)
    problems = sum(n for c in counts_by_root.values() for state, n in c.items() if state in PROBLEM_STATES)
    word_ = "AMBER" if problems else "GREEN"
    lines = [f"corpus prepare: {word_} {verdict['rows']} rows for {len(entries)} manifest files — "
             + ("nothing new, the sealed catalog is as it was" if unchanged else "the sealed catalog rebuilt over the files proven so far"),
             "  files: " + inventory_line(counts_by_root),
             f"  ingested this time: {ingested.get('hashed', 0)} new and {ingested.get('rehashed', 0)} changed files hashed "
             f"({ingested.get('bytes', 0) / 1e9:.1f} GB): {ingested.get('ok', 0)} match their SHA-256, "
             f"{ingested.get('mismatched', 0)} do not; {ingested.get('unsettled', 0)} changed while being read (next time)"]
    lines += [f"  {state} (AMBER): " + " ".join(named[state]) for state in PROBLEM_STATES if named.get(state)]
    if unavailable:
        lines.append(f"  external volume NOT MOUNTED: its {len(unavailable)} files were not looked at")
    if ro:
        lines.append(f"  read-only share NOT MOUNTED: its {len(ro)} files were not looked at")
    if counts:
        lines.append(f"  carried: files={counts.get('files')} content={counts.get('content')} volumes={counts.get('volumes')} "
                     f"user_dates={counts.get('user_dates')} workflow_tags={counts.get('workflow_tags')} "
                     f"migrations={counts.get('grdb_migrations')}; schema v{counts.get('schema_version')}, "
                     f"{counts.get('triggers')} of {counts.get('source_triggers')} triggers in place; "
                     f"source backup rows={counts.get('source_files')} (not opened for writing)")
        lines.append(f"  pair links carried: {counts.get('pair_links')} ({counts.get('pair_links_from_import')} from the import, "
                     f"{counts.get('pair_links_from_app')} the app's own) — {counts.get('pair_groups_whole')} pairs with two or more halves "
                     f"in the corpus, {counts.get('pair_halves_alone')} halves whose partner is not in the corpus")
    lines.append("  not carried: other copies and removed rows, the import evidence, captions/transcripts/notes/people, the Master Archive designation")
    if out is not None:
        seal.out_write(Path(out), "corpus-summary.txt", "\n".join(lines) + "\n")
    return (EXIT_AMBER if problems else EXIT_GREEN), lines


def current_states(seal: Seal, entries: List[Entry], unavailable: Iterable[str] = ()) -> Dict[str, str]:
    """Each file's state now, against the ledger and the set the sealed catalog was built over."""
    built = (prepared_record(seal) or {}).get("built_over")
    return classify(entries, Ledger.load(seal), unavailable, built if isinstance(built, list) else [])


def sealed_state_ready(seal: Seal, entries: List[Entry], states: Dict[str, str]) -> Tuple[Path, set]:
    """The sealed catalog, proven to hold exactly the files the last prepare built it over, each
    PRESENT one at its place; returns it and that set. Refused (run prepare) otherwise."""
    database_name, latch_name = _catalog_names()
    database = seal.state / database_name
    if not database.is_file() or not (seal.state / latch_name).is_file():
        raise Refused("refused: the sealed catalog is not built — run `scripts/corpus_run.sh prepare` first")
    record = prepared_record(seal) or {}
    if record.get("transform_version") != TRANSFORM_VERSION:
        raise Refused(f"refused: the sealed catalog was built by transform {word(str(record.get('transform_version')))}, "
                      f"this harness wants {TRANSFORM_VERSION} — run `scripts/corpus_run.sh prepare`")
    built = record.get("built_over")
    if not isinstance(built, list) or not all(isinstance(x, str) for x in built):
        raise Refused("refused: the sealed catalog does not say what it was built over — run `scripts/corpus_run.sh prepare`")
    built_over = set(built)
    held = [e for e in entries if e.sha in built_over]
    present = [e.sha for e in held if states.get(e.sha) == "present"]
    if len(held) != len(built_over) or not verify_catalog(seal, database, held, checked=present)["ok"]:
        raise Refused("refused: the sealed catalog no longer matches the corpus — run `scripts/corpus_run.sh prepare`")
    return database, built_over


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


def settle(events: List[dict], engines: List[str], results: Dict[str, dict], width: int = 1,
           alone: Optional[set] = None) -> Tuple[int, Optional[str]]:
    """Fold one launch's events into `results` (sha -> record). A file that began and never
    ended is a `crash` at the engine it was in; a file the driver cut at its deadline arrives
    with `timeout` already written. Engines after either are `not_run`. Returns (files settled,
    the driver's refusal word if it refused).

    `width` is how many files the launch had in flight. Above one, the lines of N files
    interleave (the order of the lines is not the order of the files: every fold here is by
    SHA-256) and a launch that died left several files unfinished, only one of which — if any —
    did it. So such a launch convicts no one: each file it began and did not END cleanly (no
    `end`, or an `end` cut at its deadline) is left unsettled and added to `alone`, to be run
    again in a launch of its own width 1, where this same fold convicts as it always has."""
    began, ended, cut_short, refusal = [], set(), set(), None
    per = defaultdict(dict)
    for ev in events:
        kind, sha = ev.get("ev"), ev.get("sha")
        if kind == "refused":
            refusal = word(ev.get("why"))
        elif kind == "begin" and sha:
            began.append(sha)
        elif kind == "end" and sha:
            ended.add(sha)
            if ev.get("cut"):
                cut_short.add(sha)
        elif kind == "facts" and sha:
            per[sha].setdefault("facts", {}).update(ev)      # a driver may report facts in more than one step
        elif kind == "engine" and sha:
            per[sha].setdefault("engines", {})[str(ev.get("engine"))] = ev
    settled = 0
    for sha in began:
        if sha not in results or results[sha].get("settled"):
            continue
        if width > 1 and (sha not in ended or sha in cut_short):
            if alone is not None:
                alone.add(sha)                               # judged again on its own; nothing of this launch is kept
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
                 xcodebuild: str = "xcodebuild", smoke: bool = False, jobs: Optional[int] = None):
        self.seal, self.lane, self.sha, self.stamp = seal, lane, sha, stamp
        self.smoke = smoke
        self.jobs = int(jobs or default_jobs())              # files in flight at most (default_jobs); a launch takes fewer when it has fewer
        self.database: Optional[Path] = None
        self.out, self.worktree, self.derived_data, self.bin_dir = Path(out), Path(worktree), Path(derived_data), Path(bin_dir)
        self.test_class, self.engines, default_deadline, self.sources = LANES[lane]
        self.deadline = int(deadline or default_deadline)
        self.limit, self.xcodebuild = limit, xcodebuild
        self.work = seal.work_root / f"{stamp}-{lane}"
        self.report_dir = seal.reports / lane / sha / stamp
        self.lines: List[str] = []
        self.launches = 0
        self.build_seconds = 0.0
        self.build_reused = False
        self.overlay_installed = False
        self.closing: Dict[str, int] = {}
        self.housekeeping: List[str] = []
        self.not_run_external = 0                            # files on an external volume that is not mounted
        self.not_run_ro = 0                                  # files on the read-only share (not mounted yet)
        self.manifest_sha256 = ""                            # the manifest this run read (corpus_shrink.py apply asks)
        # Launches of N that died with files in flight (their widths), and the files they left to be run again alone:
        # said in the report, and the run is AMBER at best — a fault only files in flight together cause (an engine
        # race, memory pressure) is a finding, never absorbed (review of 327576126).
        self.cut_widths: List[int] = []
        self.ran_alone: set = set()
        self.proven_uuid: Optional[str] = None               # the external volume proven at the start (its UUID)
        self.inventory: Dict[str, Dict[str, int]] = {}       # per root, files by state (present, missing, ...)
        self.ledger: Optional["Ledger"] = None
        self.originals: Dict[str, Entry] = {}
        self.problems: Dict[str, List[str]] = {}             # mismatched / vanished / changed, by SHA-256 prefix
        self.picked: Dict[str, object] = {}                  # the proof lane: where its files came from
        # The coverage run (corpus_coverage.py) sets this: the build is instrumented and every launch
        # leaves its result bundle (with coverage) here, in the coverage run's own work folder. None: no coverage.
        self.profiles: Optional[Path] = None

    # -- the overlay: untracked driver sources in the testbed, for this run only

    def clear_overlay(self) -> None:
        overlay = self.worktree / OVERLAY_DIR
        if overlay.exists():
            kept = self.out / f"overlay-{int(time.time() * 1000)}"
            try:                                             # moved out, never deleted in place — and only renamed:
                os.rename(str(overlay), str(kept))           # a folder is never copied across a volume (Codex #332 F1)
            except OSError:
                raise Refused("refused: the testbed's overlay folder could not be moved aside (another volume, or not a folder)")

    def install_overlay(self) -> None:
        tracked = subprocess.run(["git", "-C", str(self.worktree), "ls-files", "--", OVERLAY_DIR],
                                 capture_output=True, text=True).stdout.strip()
        if tracked:
            raise Refused("refused: this ref tracks files in the harness's overlay folder")
        # The overlay's parent is the testbed's own test folder: a ref that makes it (or anything
        # above it) a symlink would send the driver sources somewhere else (Codex #311 F2).
        parent = (self.worktree / OVERLAY_DIR).parent
        expected = os.path.join(os.path.realpath(str(self.worktree)), os.path.dirname(OVERLAY_DIR))
        if (os.path.realpath(str(parent)) != expected or self.seal.pristine(parent) or _under(self.worktree, self.seal.corpus)
                or not self.seal.on_home_volume(parent)):        # never on a volume mounted in the testbed (Codex #334 F3)
            raise Refused("refused: the testbed's test folder is not a folder of the testbed (a symlink in this ref?)")
        self.clear_overlay()
        overlay = self.worktree / OVERLAY_DIR
        overlay.mkdir(parents=True)
        self.overlay_installed = True
        for name in ALL_DRIVERS:                             # every lane's driver: one build serves them all
            shutil.copyfile(str(self.bin_dir / name), str(overlay / name))

    # -- one build per commit (see ALL_DRIVERS)

    def build_identity(self) -> Optional[dict]:
        """What the build in the DerivedData folder must be for this lane to reuse it, less the binary."""
        try:
            digest = hashlib.sha256(b"".join((self.bin_dir / name).read_bytes() for name in ALL_DRIVERS)).hexdigest()
        except OSError:
            return None
        return {"sha": self.sha, "config": "Debug", "coverage": self.profiles is not None, "drivers": digest}

    def selected_build(self) -> Optional[Tuple[Path, Path]]:
        """(the .xctestrun a launch will use — find_xctestrun's choice — and the VideoScanTests binary IT
        names), so the mark describes exactly what runs (Codex #336 F4); None when it cannot be read."""
        try:
            xctestrun = find_xctestrun(self.derived_data)
            with open(xctestrun, "rb") as f:
                plan = plistlib.load(f)
        except (Refused, OSError, ValueError, plistlib.InvalidFileException):
            return None
        root = str(xctestrun.parent)

        def targets(value):
            if isinstance(value, list):
                for v in value:
                    yield from targets(v)
            elif isinstance(value, dict):
                if value.get("BlueprintName") == "VideoScanTests" and "TestBundlePath" in value:
                    yield value
                for v in value.values():
                    yield from targets(v)
        target = next(targets(plan), None)
        if target is None:
            return None
        host = str(target.get("TestHostPath", "")).replace("__TESTROOT__", root)
        bundle = str(target["TestBundlePath"]).replace("__TESTHOST__", host).replace("__TESTROOT__", root)
        binary = Path(bundle) / "Contents" / "MacOS" / "VideoScanTests"
        return (xctestrun, binary) if binary.is_file() and not binary.is_symlink() else None

    def binary_digest(self) -> Optional[str]:
        """The SHA-256 of the selected .xctestrun and of the binary it names, as one word."""
        selected = self.selected_build()
        if selected is None:
            return None
        xctestrun, binary = selected
        plan = sha256_file(xctestrun, os.path.getsize(str(xctestrun)))
        built = sha256_file(binary, os.path.getsize(str(binary)))
        return f"{xctestrun.name}:{plan[0]}:{built[0]}" if plan and built else None

    def build_reusable(self) -> bool:
        """True when the DerivedData folder holds this commit's build with these drivers, untouched since."""
        mark = self.derived_data / BUILD_MARK
        try:
            if mark.is_symlink() or not self.seal.on_home_volume(mark):
                return False
            recorded = json.loads(mark.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return False
        identity = self.build_identity()
        return (isinstance(recorded, dict) and identity is not None
                and all(recorded.get(k) == v for k, v in identity.items())
                and recorded.get("binary") is not None and recorded.get("binary") == self.binary_digest())

    def mark_build(self) -> None:
        identity = self.build_identity()
        digest = self.binary_digest()
        if identity is None or digest is None or not self.seal.on_home_volume(self.derived_data):
            return                                           # no mark: the next lane simply builds
        fd = guarded_open(self.derived_data / BUILD_MARK)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(json.dumps(dict(identity, binary=digest), sort_keys=True) + "\n")

    def engine_present(self) -> bool:
        return self.lane != "proof" or any(self.worktree.glob(PROOF_ENGINE_GLOB))

    # -- build and launches

    def build(self) -> int:
        # The builder writes into DerivedData and the testbed: both on the home volume, or nothing is built (Codex #335 F1).
        if not all(self.seal.on_home_volume(p) for p in (self.derived_data / "Build" / "Products", self.derived_data, self.worktree)):
            raise Refused("refused: DerivedData or the testbed is on another volume (something is mounted there)")
        t0 = time.time()
        coverage = ["-enableCodeCoverage", "YES"] if self.profiles is not None else []
        rc = _run([self.xcodebuild, "build-for-testing", "-project", str(self.worktree / "VideoScan/VideoScan.xcodeproj"),
                   "-scheme", "VideoScan", "-configuration", "Debug", "-destination", "platform=macOS",
                   "-derivedDataPath", str(self.derived_data), *coverage, *corpus_signing(self.out)],
                  self.seal, self.out, "corpus-build.log", dict(os.environ), self.worktree)
        self.build_seconds = time.time() - t0
        return rc

    def launch(self, pending: List[Entry], database: Path, xctestrun: Path, width: int = 1) -> List[dict]:
        """One test-host launch over `pending`, `width` files in flight (the config's `jobs`)."""
        self.launches += 1
        seal = self.seal
        config = self.work / f"config-{self.launches}.json"
        progress = self.work / f"progress-{self.launches}.jsonl"
        seal.write_json(config, {
            "lane": self.lane, "corpusRoot": str(seal.corpus), "stateRoot": str(seal.state), "catalog": str(database),
            "mediaRoot": str(seal.media), "work": str(self.work), "progress": str(progress),
            "deadlineSeconds": self.deadline, "jobs": width,
            "pending": [self.pending_item(e) for e in pending], **self.config_extra()})
        seal.write_text(progress, "")
        home = self.home()
        sealed = {"HOME": str(home), "CFFIXED_USER_HOME": str(home),
                  "TMPDIR": str(self.work / "tmp") + "/", "VS_CORPUS_CONFIG": str(config)}
        patched = xctestrun.with_name(f"corpus-{self.stamp}-{self.launches}.xctestrun")    # beside it: __TESTROOT__ is relative
        if (os.path.lexists(str(patched)) or seal.pristine(patched) or _under(patched, seal.corpus)
                or not seal.on_home_volume(patched.parent)):     # never on a volume mounted under DerivedData (Codex #334 F3)
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
        # The launch's own DerivedData, in the lane's work folder and removed after it: with no -derivedDataPath
        # xcodebuild makes ~/Library/Developer/Xcode/DerivedData/VideoScan-<hash of the patched path> per launch
        # (its default result bundle inside) and nothing removes it (2026-11-24: 729 folders, 25 GB on the Ultra).
        launch_dd = self.seal.writable(self.work / "xcode-dd")
        try:
            _run([self.xcodebuild, "test-without-building", "-xctestrun", str(patched), "-derivedDataPath", str(launch_dd),
                  "-destination", "platform=macOS,arch=arm64", "-parallel-testing-enabled", "NO",
                  "-test-timeouts-enabled", "NO",            # one test method walks every file; the per-file deadline is the driver's
                  f"-only-testing:VideoScanTests/{self.test_class}", *coverage],
                 self.seal, self.out, "corpus-test.log", env, self.worktree)
        finally:
            if patched.exists():
                move_file(self.seal, patched, self.out / patched.name)
            remove_tree(self.seal, launch_dd)
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
            entries, self.picked = proof_files(self.seal, entries)
            if self.smoke:
                entries = sorted(entries, key=lambda e: (e.size, e.sha))[:SMOKE_PROOF]
        elif self.smoke:
            entries = smoke_sample(entries, mixes(self.database) if self.database else {})
        return entries[: self.limit] if self.limit else entries

    def stage(self, entries: List[Entry], database: Path) -> Tuple[List[Entry], Path]:
        """After the build: the files and the catalog the driver will be given."""
        return entries, database

    def after(self, results: Dict[str, dict], report: dict) -> None:
        """After the launches, before the report is stored."""

    def run_files(self, entries: List[Entry], database: Path) -> Tuple[Dict[str, dict], Dict[str, object]]:
        results = {e.sha: {"stratum": stratum_word(e.stratum), "size": e.size, "root": e.root, **self.record_extra(e)}
                   for e in entries}
        hello: Dict[str, object] = {}
        xctestrun = find_xctestrun(self.derived_data)
        self.seal.mkdir(self.work / "tmp")
        alone: set = set()                                   # left unfinished by a launch of N: each is run again on its own
        while True:
            pending = [e for e in entries if not results[e.sha].get("settled")]
            if pending:                                      # proven at go(); again after the build and at each relaunch
                pending = self.reprove(pending, results)
            if not pending:
                break
            solo = [e for e in pending if e.sha in alone]
            batch = solo or pending                          # those to be judged alone first, one at a time
            width = 1 if solo else min(self.launch_width(), len(batch))
            if self.launches and self.lane != "verbs":      # what a dead launch's engines left half-written goes first
                sweep_work(self.seal, self.work)
            events = self.launch(batch, database, xctestrun, width)
            for ev in events:
                if ev.get("ev") == "hello" and not hello:
                    hello = {k: ev.get(k) for k in ("homeSealed", "records", "archiveDesignation", "testHost")}
                if ev.get("ev") == "verbs":                  # the verbs driver's closing counts
                    self.closing = {k: ev[k] for k in ("trashFiles", "trashedByEngines", "strayTrashFiles", "receiptsInRun",
                                                       "receiptsOutsideTheRun", "records")
                                    if isinstance(ev.get(k), int) and not isinstance(ev.get(k), bool)}
            before = len(alone)
            settled, refusal = settle(events, self.engines, results, width=width, alone=alone)
            if refusal:
                raise Refused(f"refused by the driver: {refusal}")
            # No progress: never loop on a driver that cannot start. A launch of N that only left files to be run
            # alone did progress (those launches are width 1 and settle every file they begin).
            if settled == 0 and len(alone) == before:
                raise Refused("the driver started no file — see corpus-test.log on the host")
            if len(alone) > before:
                self.cut_widths.append(width)
        self.ran_alone = set(alone)
        return results, hello

    def launch_width(self) -> int:
        """Files in flight in a launch of this lane (before a launch caps it at its own file count)."""
        return self.jobs

    def restat(self, pending: List[Entry], results: Dict[str, dict]) -> List[Entry]:
        """Each pending file is still the one the ledger proved (size, mtime, inode), right before the
        launch — the build takes minutes (Codex #336 F2). One that is not is dropped from the run and
        counted changed or vanished, named."""
        if self.ledger is None:
            return pending
        kept = []
        for e in pending:
            source = self.originals.get(e.sha, e)               # the verbs lane runs clones: its source is checked
            record, info = self.ledger.files.get(e.sha), (None if source.root == "external" and not
                                                          self.seal.external().state == "ok" else _stat(source))
            if record is None or info is None or not same_file(record, info):
                state = "vanished" if info is None else "changed"
                results[e.sha] = {"dropped": state, "settled": True}
                counts = self.inventory.setdefault(e.root, {})
                counts["present"] = counts.get("present", 1) - 1
                counts[state] = counts.get(state, 0) + 1
                self.problems.setdefault(state, []).append(sha_prefix(e.sha))
                continue
            kept.append(e)
        return kept

    def reprove(self, pending: List[Entry], results: Dict[str, dict]) -> List[Entry]:
        """Before each launch, the external root is proven again (Codex #331 F2: no proof outlives
        its evidence). Another volume there, or its marker gone: Refused. Unplugged: its pending
        files are NOT RUN (EXTERNAL_GONE), the internal ones go on."""
        pending = self.restat(pending, results)
        self.seal._external = None
        now = self.seal.external()
        if now.state == "ok" and self.proven_uuid and now.uuid != self.proven_uuid:
            raise Refused("refused: the external volume changed during the run (another volume adopted at its mount)")
        if now.state == "ok" and now.uuid == self.proven_uuid:
            return pending
        for e in pending:
            if e.root == "external":
                results[e.sha].update({engine: EXTERNAL_GONE for engine in self.engines}, settled=True)
        return [e for e in pending if e.root != "external"]

    # -- the report

    def report(self, results: Dict[str, dict], hello: Dict[str, object], wall: float, engine_present: bool = True) -> dict:
        engines = self.engines
        totals = {e: Counter() for e in engines}
        by_stratum: Dict[str, dict] = {}
        by_format: Dict[str, dict] = {}
        failures = Counter()
        gone = 0                                             # external files the run came to and could not prove
        external_ran = external_unreadable = 0               # external files the host ran an engine on; of them, unread (UNREAD_WORDS)
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
            if any(record.get(e) == EXTERNAL_GONE for e in engines):
                gone += 1
            elif record.get("root") == "external" and any(record.get(e, "not_run") not in ("not_run", "no_record") for e in engines):
                external_ran += 1
                if unread(record, engines):
                    external_unreadable += 1
        return {"lane": self.lane, "sha": self.sha, "stamp": self.stamp, "host": self.seal.hostname,
                "engine_present": engine_present, "files": len(results),
                "bytes": sum(r.get("size", 0) for r in results.values()),
                "media_seconds": round(sum(r.get("duration", 0) or 0 for r in results.values()), 1),
                "wall_s": round(wall, 1), "build_s": round(self.build_seconds, 1), "build_reused": self.build_reused,
                "launches": self.launches, "jobs": self.jobs,
                "launches_cut_short": len(self.cut_widths), "cut_short_width": max(self.cut_widths, default=0),
                "run_again_alone": len(self.ran_alone),
                "failed_alone": sum(1 for sha in self.ran_alone if sha in results and (
                    results[sha].get("unfinished") or any(results[sha].get(e) in CUT_WORDS for e in engines))),
                "limit": self.limit, "not_run_external": self.not_run_external + gone, "not_run_ro": self.not_run_ro,
                "manifest_sha256": self.manifest_sha256, "picked": self.picked,
                "external_ran": external_ran, "external_unreadable": external_unreadable,
                "inventory": self.inventory, "problems": self.problems, "smoke": self.smoke,
                "problem_count": sum(n for c in self.inventory.values() for st, n in c.items() if st in PROBLEM_STATES),
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
        try:
            manifest_bytes = (seal.corpus / manifest_name(seal)).read_bytes()
        except OSError:
            raise Refused(f"refused: ~/corpus/{manifest_name(seal)} is missing or unreadable")
        self.manifest_sha256 = hashlib.sha256(manifest_bytes).hexdigest()
        entries = load_manifest(seal, manifest_bytes)
        # The external root: run when proven; NOT RUN (and said, with the count) when it is not mounted;
        # refused (exit 2, nothing run) when something else is mounted there.
        external = seal.external()
        self.proven_uuid = external.uuid
        unavailable = {e.sha for e in entries if e.root == "external" and external.state != "ok"}
        self.not_run_external = len(unavailable)
        ro = {e.sha for e in entries if e.root == "ro"}             # no read-only share yet: NOT RUN, AMBER
        self.not_run_ro = len(ro)
        unavailable |= ro
        # The wish list: only the files proven present run; the rest are counted (DECISIONS 2026-11-19).
        self.ledger = Ledger.load(seal)
        states = current_states(seal, entries, unavailable)
        database, _ = sealed_state_ready(seal, entries, states)
        self.database = database
        self.inventory, self.problems = inventory(entries, states)
        entries = self.scope([e for e in entries if states[e.sha] == "present"])
        self.originals = {e.sha: e for e in entries}
        if not entries:                                      # nothing arrived yet: said, not refused (Codex #336 F6)
            seal.out_folder(self.out)
            report = self.report({}, {}, time.time() - t0)
            report["against"] = None
            self.store(report, {})
            return {"GREEN": EXIT_GREEN, "AMBER": EXIT_AMBER}.get(verdict_of(report, None), EXIT_RED)
        if self.lane == "proof":                             # one balanced copy per file in flight: what the engine asks for
            lengths = durations(self.database) if self.database else {}
            self.jobs = transient_room(seal, [proof_need(e.size, lengths.get(e.sha, 0.0)) for e in entries], self.jobs)
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
                self.build_reused = self.build_reusable()
                if not self.build_reused:
                    self.install_overlay()
                if not self.build_reused and self.build() != 0:
                    self.lines = [f"corpus {self.lane}{' SMOKE' if self.smoke else ''}: RED the driver did not build against {self.sha[:9]} "
                                  "(corpus-build.log on the host); no file was run"]
                    seal.out_write(self.out, "corpus-summary.txt", self.lines[0] + "\n")
                    return EXIT_RED
                if not self.build_reused:
                    self.mark_build()
                entries, database = self.stage(entries, database)
                results, hello = self.run_files(entries, database)
                results = {sha: r for sha, r in results.items() if not r.get("dropped")}     # changed before its launch
            finally:
                if self.overlay_installed:                   # never a folder this run did not lay down
                    self.clear_overlay()
            report = self.report(results, hello, time.time() - t0)
            self.after(results, report)
            report["against"] = against_baseline(seal, self.lane, results, self.engines)
            self.store(report, results)
            return {"GREEN": EXIT_GREEN, "AMBER": EXIT_AMBER}.get(verdict_of(report, report["against"]), EXIT_RED)
        finally:
            self.collect_progress()
            self.remove_work()

    def collect_progress(self) -> None:
        """The raw event lines are part of the record: each progress file goes with the run's report,
        by `move_file` — a rename of a one-name regular file on the home volume, never a folder and
        never a copy (Codex #332 F1: shutil.move copies a tree across volumes and deletes the source)."""
        seal = self.seal
        for name in sorted(os.listdir(str(self.work))) if self.work.is_dir() else []:
            if name.startswith("progress-"):
                seal.mkdir(self.report_dir)
                move_file(seal, self.work / name, seal.writable(self.report_dir / name))

    def remove_work(self) -> None:
        """The run's work folder goes, whole, through `remove_tree` (Promote's locks cleared on this
        run's own files; never a tree with a mount in it)."""
        work = str(self.seal.writable(self.work))
        if not os.path.isdir(work):
            return
        remove_tree(self.seal, self.work)
        if os.path.isdir(work):
            note = "  the run's work folder could NOT be removed whole (it is still on the M4 under ~/corpus/work)"
            self.lines.append(note)
            try:
                self.seal.out_write(self.out, "corpus-summary.txt", note + "\n", append=True)
            except (OSError, Refused):
                pass


def mixes(database: Path) -> Dict[str, Tuple[str, str, str]]:
    """Each sealed row's (container, video, audio) as the catalog has them, by SHA-256 (read-only door)."""
    import catalog_db
    conn = catalog_db.connect(database)
    try:
        return {sha: (c or "", v or "", a or "") for sha, c, v, a in
                conn.execute("SELECT content_digest, container, video_codec, audio_codec FROM files")}
    finally:
        conn.close()


def smoke_sample(entries: List[Entry], codecs: Dict[str, Tuple[str, str, str]], cap: int = SMOKE_CHECK) -> List[Entry]:
    """The smallest file of each (stratum, container, video, audio) mix; strata dealt round-robin
    (each stratum's mixes smallest first) until `cap`. Deterministic: the same corpus, the same files."""
    by_stratum: Dict[str, Dict[Tuple[str, str, str], Entry]] = defaultdict(dict)
    for e in sorted(entries, key=lambda e: (e.size, e.sha)):
        by_stratum[e.stratum].setdefault(codecs.get(e.sha, ("", "", "")), e)
    queues = [sorted(mix.values(), key=lambda e: (e.size, e.sha)) for _, mix in sorted(by_stratum.items())]
    picked: List[Entry] = []
    while len(picked) < cap and any(queues):
        for queue in queues:
            if queue and len(picked) < cap:
                picked.append(queue.pop(0))
    return sorted(picked, key=lambda e: e.sha)


def durations(database: Path) -> Dict[str, float]:
    """Each sealed row's duration in seconds as the catalog has it, by SHA-256 (read-only door)."""
    import catalog_db
    conn = catalog_db.connect(database)
    try:
        return {sha: float(d or 0.0) for sha, d in conn.execute("SELECT content_digest, duration_s FROM files")}
    finally:
        conn.close()


def proof_need(size: int, seconds: float) -> int:
    """What the balancing engine asks free for one copy (BalanceAudioFix.requiredFreeBytes, the app's own rule):
    the source's size, plus 200 KB per second of sound (lossy -> 48 kHz stereo PCM), plus a 64 MB cushion."""
    return int(size) + int(max(0.0, float(seconds or 0.0)) * 200_000) + (64 << 20)


def sweep_work(seal: Seal, work: Path) -> None:
    """Before a relaunch: the loose files a dead launch's engines left in the run's work folder (a balanced
    copy half-written when the host exited — `_exit` runs no cleanup) go, through `_remove_at`. Only regular
    files with ONE name on the home volume; never the launches' own config-*/progress-* files, never a
    folder, a link or a second name of anything."""
    path = str(seal.writable(work))
    dev = seal.home_device()
    try:
        fd = os.open(path, O_DIR)
    except OSError:
        return
    try:
        if os.fstat(fd).st_dev != dev:
            return
        for name in os.listdir(fd):
            if name.startswith(("config-", "progress-")):
                continue
            try:
                info = os.stat(name, dir_fd=fd, follow_symlinks=False)
            except OSError:
                continue
            if stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_dev == dev:
                _remove_at(fd, name, os.path.join(path, name), dev)
    finally:
        os.close(fd)


_HOST = object()


def default_jobs(cpus=_HOST) -> int:
    """Files in flight by default: half the host's logical cores (each file's engines are ffprobe/ffmpeg
    children, some of them threaded), at least 1, at most JOBS_MAX. `cpus` is a seam for the tests."""
    count = os.cpu_count() if cpus is _HOST else cpus
    return max(1, min(JOBS_MAX, (count or 1) // 2))


def proof_width(free: int, total: int, sizes: List[int], jobs: int) -> int:
    """How many proof files may be in flight: each holds one balanced copy about its own size under
    ~/corpus/work at once, so the `width` LARGEST of them together must leave the disk under
    TRANSIENT_CEILING used. The largest that fits, at most `jobs`; Refused when not even one copy fits."""
    room = free - total * (1 - TRANSIENT_CEILING)
    largest = sorted(sizes, reverse=True)
    if not largest or largest[0] > room:
        need = largest[0] if largest else 0
        raise Refused(f"refused: {free / 1e9:.0f} GB free on the M4 and this lane may write {need / 1e9:.0f} GB — "
                      f"a run stops short of {TRANSIENT_CEILING:.0%} used")
    width, used = 0, 0
    for size in largest[:max(1, jobs)]:
        if used + size > room:
            break
        width, used = width + 1, used + size
    return width


def transient_room(seal: Seal, sizes: List[int], jobs: int = 1) -> int:
    """The proof lane's width on the M4's disk now (`proof_width`); Refused when one copy would pass the ceiling."""
    usage = shutil.disk_usage(str(seal.corpus))
    return proof_width(usage.free, usage.total, sizes, jobs)


def proof_files(seal: Seal, entries: List[Entry], cap: int = PROOF_CAP) -> Tuple[List[Entry], Dict[str, object]]:
    """The proof lane's files (see PROOF_CAP): v1's one-sided-sound stratum first, then what the
    newest WHOLE check run (not limited, nothing NOT RUN: Codex #331 F5) heard as one-sided,
    smallest first; at most `cap`. Returns them and
    where they came from (counts and the check run's name: words only)."""
    fixed = [e for e in entries if e.stratum == PROOF_STRATUM]
    heard, source = set(), "none"
    runs = [run for run, report in usable_runs(seal, "check")
            if not report.get("limit") and not report.get("not_run_external") and not report.get("not_run_ro")
            and not report.get("smoke")
            and not host_refused(report)]
    if runs:
        try:
            heard = {sha for sha, record in _outcomes(runs[-1]).items()
                     if ONE_SIDED_KINDS & {str(k) for k in record.get("audio_kinds") or []}}
            source = runs[-1].name
        except (OSError, ValueError):
            heard = set()
    extra = sorted((e for e in entries if e.sha in heard and e.stratum != PROOF_STRATUM), key=lambda e: (e.size, e.sha))
    chosen = (fixed + extra)[:cap]
    return chosen, {"stratum": len(fixed), "heard": len(extra), "cap": cap, "taken": len(chosen), "check_run": source}


def media_sweep(seal: Seal, entries: List[Entry]) -> Dict[str, Tuple[int, int]]:
    """Size, modification time, file flags, link count and inode of every corpus file given (both
    roots), by SHA-256, plus the count of files under ~/corpus/media and — when it is mounted — the
    external volume's corpus/media (key `files`): what must be identical before and after a verbs run."""
    seen: Dict[str, Tuple[int, int]] = {}
    for e in entries:
        try:
            st = os.lstat(str(e.path))
            # size, mtime — and the flags, the number of names and the inode: a lock cleared, a
            # hard link made into the run, or the file replaced, moves none of the first two.
            seen[e.sha] = (st.st_size, st.st_mtime_ns, getattr(st, "st_flags", 0), st.st_nlink, st.st_ino)
        except OSError:
            seen[e.sha] = (-1, -1)
    folders = [seal.media] + ([seal.external().media] if seal.external().state == "ok" else [])
    seen["files"] = (sum(len(names) for folder in folders for _, _, names in os.walk(str(folder))), 0)
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
        self.jobs = 1                                        # one batch: every step acts on the whole sample together

    def home(self) -> Path:
        return self.work / "home"                           # nothing this run's engines remember outlives the run

    def launch_width(self) -> int:
        return 1

    def scope(self, entries: List[Entry]) -> List[Entry]:
        self.all_entries = entries
        # Clones (cp -c) are made within ONE APFS volume: only the internal root's files are sampled.
        count = self.limit or (len(VERBS_ROLES) if self.smoke else VERBS_SAMPLE)    # smoke: every verb once
        sample = verbs_sample([e for e in entries if e.root == "internal"], count)
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
        if not _under(source, self.seal.media) or _under(dest, self.seal.media) or not self.seal.on_home_volume(source):
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
            clone = Entry(e.sha, e.original, e.size, e.stratum, self.vol / e.original.lstrip("/"), e.root)
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
        build_catalog(seal, source_backup(seal), clones, seed / database_name)
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


def unread(record: dict, engines: List[str]) -> bool:
    """Every file-opening engine (UNREAD_WORDS) that ran on this file said it could not read it — and one did."""
    said = [(e, record.get(e, "not_run")) for e in engines if e in UNREAD_WORDS]
    said = [(e, outcome) for e, outcome in said if outcome != "not_run"]
    return bool(said) and all(outcome in UNREAD_WORDS[e] for e, outcome in said)


def host_refused(report: dict) -> int:
    """How many external files the test host could not read, when it could read NONE of them (GH #498 (c)):
    the environment failed, not the corpus. 0 otherwise — some unreadable and the rest read is a corpus fact."""
    ran, unreadable = report.get("external_ran") or 0, report.get("external_unreadable") or 0
    return unreadable if ran and unreadable == ran else 0


def verdict_of(report: dict, against: Optional[dict]) -> str:
    """The lane's verdict (the module docstring's rule): `against` is its diff with the baseline."""
    if not report.get("engine_present", True):
        return "NORUN"
    if cut_count(report) or (against or {}).get("problem") or host_refused(report):
        return "RED"
    # Files NOT RUN because the external volume is not mounted: AMBER, never GREEN (the run proves
    # nothing about them) and never RED (no engine failed and no copy is at risk; the count is said).
    # Files mismatched, vanished or changed: AMBER, named. Files MISSING (not yet copied) never move it.
    # A launch of N that died (its files then ran alone): AMBER — the fault needed files in flight together.
    return "AMBER" if ((against or {}).get("changed") or report.get("not_run_external") or report.get("not_run_ro")
                       or report.get("problem_count") or report.get("launches_cut_short")) else "GREEN"


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
        return [f"corpus {lane}{' SMOKE' if report.get('smoke') else ''}: NOT RUN at {report['sha'][:9]} — this ref has no balanced-copy proof engine "
                "(MediaOps/BalancedCopyProof*.swift); run it with a --ref that contains it"]
    failed = sum(report["failures"].values())
    ran = (f"{report['files']} files ({report['bytes'] / 1e9:.1f} GB, "
           f"{report['media_seconds'] / 3600:.1f} h of media) at {report['sha'][:9]} — wall {report['wall_s']:.0f}s "
           + ("(the build reused: same commit, same drivers)" if report.get("build_reused") else f"(build {report['build_s']:.0f}s)")
           + f", {report['launches']} launch(es)"
           + (f", {report['jobs']} file{'s' if report['jobs'] != 1 else ''} at a time" if report.get("jobs") else "")
           + f", per-file deadline {report['deadline_s']}s"
           + (f", limited to {report['limit']} files" if report.get("limit") else ""))
    head = f"corpus {lane}{' SMOKE' if report.get('smoke') else ''}: "
    refused = host_refused(report)
    lines = ([head + "RED " + ACCESS_REASON.format(n=refused), "  ran " + ran] if refused
             else [head + f"{verdict_of(report, against)} " + ran])
    for e in engines:
        lines.append(f"  {e}: {_counts(report['engines'][e])}")
    cut = cut_count(report)
    lines.append("  engine failures (crash / timeout / error): " + (_counts(report["failures"]) if failed else "none")
                 + (f" — {cut} crashed or timed out: RED" if cut else ""))
    seal = report.get("seal") or {}
    lines.append(f"  seal: home sealed={seal.get('homeSealed')} test host={seal.get('testHost')} "
                 f"archive designation={seal.get('archiveDesignation')} catalog records={seal.get('records')}")
    if report.get("smoke"):
        lines.append("  " + SMOKE_NOTE)
    if report.get("inventory"):
        lines.append("  files: " + inventory_line(report["inventory"]))
    for state in PROBLEM_STATES:
        if (report.get("problems") or {}).get(state):
            lines.append(f"  {state} (AMBER): " + " ".join(report["problems"][state]))
    if report.get("launches_cut_short"):
        cut, failed = report["launches_cut_short"], report.get("failed_alone", 0)
        lines.append(f"  {cut} launch{'es' if cut != 1 else ''} of {report.get('cut_short_width', 0)} cut short; "
                     f"{report.get('run_again_alone', 0)} files run again alone ("
                     + (f"{failed} failed alone)" if failed else "none failed alone) — AMBER: a fault only files in flight "
                        "together cause (an engine race, memory pressure); --jobs 1 runs one at a time"))
    if report.get("not_run_external"):
        lines.append(f"  external volume NOT MOUNTED: {report['not_run_external']} files on it NOT RUN — AMBER; "
                     "mount it and run again (a run without them is never a baseline)")
    if report.get("not_run_ro"):
        lines.append(f"  read-only share NOT MOUNTED: {report['not_run_ro']} files read from the Ultra's drives NOT RUN — "
                     "AMBER (a run without them is never a baseline)")
    return lines + against_lines(against)


def render(report: dict, per_file: Optional[Dict[str, dict]] = None, against: Optional[dict] = None) -> List[str]:
    lane = report["lane"]
    engines = [e for e in LANES[lane][1] if e in report["engines"]]
    lines = head_lines(report, against)
    if not report.get("engine_present", True):
        return lines
    picked = report.get("picked") or {}
    if picked:
        lines.append(f"  files: {picked.get('stratum')} of the one-sided-sound stratum + {picked.get('heard')} the check run "
                     f"{word(picked.get('check_run'))} heard one-sided — {picked.get('taken')} taken (cap {picked.get('cap')})")
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
    if report.get("not_run_external"):
        facts["notes"].append(f"{report['not_run_external']} files NOT RUN: the external volume is not mounted")
    if report.get("not_run_ro"):
        facts["notes"].append(f"{report['not_run_ro']} files NOT RUN: the read-only share is not mounted")
    if report.get("smoke"):
        facts["smoke"] = True
        facts["notes"].insert(0, SMOKE_NOTE)
    if host_refused(report):                                 # the one thing to act on comes first
        facts["notes"].insert(0, ACCESS_REASON.format(n=host_refused(report)))
    if report.get("inventory"):
        facts["notes"].append("files: " + inventory_line(report["inventory"]))
    if report.get("problem_count"):
        facts["notes"].append(f"{report['problem_count']} files mismatched, vanished or changed (named in the summary): AMBER")
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
        if (run != exclude and not cut_count(report) and not report.get("limit") and not report.get("not_run_external")
                and not report.get("not_run_ro")
                and not report.get("problem_count") and not report.get("smoke") and not report.get("launches_cut_short")
                and not host_refused(report) and report.get("files")):
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


UF_IMMUTABLE = 0x2                              # what Promote sets on what it archives
O_DIR = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


def _one_device(root: str) -> bool:
    """True when every entry under `root` (links not followed) is on `root`'s own device and the
    whole tree could be read: a tree with a mount anywhere in it — the external corpus volume,
    wherever it is mounted — is not one."""
    unreadable = []
    try:
        dev = os.lstat(root).st_dev
    except OSError:
        return False
    for parent, dirs, names in os.walk(root, onerror=unreadable.append):
        for name in dirs + names:
            try:
                if os.lstat(os.path.join(parent, name)).st_dev != dev:
                    return False
            except OSError:
                return False
    return not unreadable


def _remove_at(dir_fd: int, name: str, path: str, dev: int) -> None:
    """Remove `name` of the open folder `dir_fd` (whose path is `path`'s parent): a folder by
    descending through descriptors, never following a link and never entering another device; a
    file by unlinking that name. Promote's lock (UF_IMMUTABLE) is cleared first on a regular file
    with ONE name on this device — a second name could be a pristine file's (Codex #311 F3). The
    lock is cleared by path (Python has no fchflags) only after the path is proven to be the very
    file the descriptor walk found (same device and inode); what can still slip between the two is
    a rename, and it would only clear a flag — the unlink itself is by descriptor."""
    try:
        info = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
    except OSError:
        return
    if info.st_dev != dev:
        return                                               # another volume: never entered, never unlinked
    if stat.S_ISDIR(info.st_mode):
        try:
            fd = os.open(name, O_DIR, dir_fd=dir_fd)
        except OSError:
            return
        try:
            if os.fstat(fd).st_dev != dev:
                return
            for child in os.listdir(fd):
                _remove_at(fd, child, os.path.join(path, child), dev)
        finally:
            os.close(fd)
        try:
            os.rmdir(name, dir_fd=dir_fd)
        except OSError:
            pass
        return
    if stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and getattr(info, "st_flags", 0) & UF_IMMUTABLE:
        try:
            again = os.lstat(path)
            if (again.st_dev, again.st_ino) == (info.st_dev, info.st_ino):
                os.lchflags(path, again.st_flags & ~UF_IMMUTABLE)
        except (OSError, AttributeError):
            return
    try:
        os.unlink(name, dir_fd=dir_fd)
    except OSError:
        pass


def move_file(seal: Seal, source: Path, dest: Path) -> bool:
    """Move one of the harness's own files: a regular file with ONE name on the home volume, by
    rename only (a rename never copies and never crosses a volume). Anything else stays where it is.
    Returns True when moved."""
    try:
        info = os.lstat(str(source))
    except OSError:
        return False
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_dev != seal.home_device():
        return False
    try:
        os.rename(str(source), str(dest))
    except OSError:
        return False
    return True


def remove_tree(seal: Seal, folder: Path) -> bool:
    """THE way the harness removes a tree — a run's work folder, a dead run's, an old stored run,
    prepare's build folder (Codex #331 F1: one engine, five callers). Only inside
    ~/corpus/{state,work,reports} and nowhere pristine (`Seal.writable`); only a tree wholly on
    its own device — one with a mount anywhere in it is left WHOLE (nothing of it is removed); then
    through folder descriptors that never follow a link nor enter another device, so a volume
    mounted there after the check is not entered either. (C++: openat/unlinkat on a dirfd.)
    Returns True when the tree is gone."""
    path = str(seal.writable(folder))
    if not os.path.lexists(path):
        return True
    dev = seal.home_device()                                 # anchored to the home volume, not to the target (Codex #332 F2)
    if os.path.islink(path) or not os.path.isdir(path) or os.lstat(path).st_dev != dev or not _one_device(path):
        return False
    try:
        parent = os.open(os.path.dirname(path), O_DIR)
    except OSError:
        return False
    try:
        if os.fstat(parent).st_dev != dev:
            return False
        _remove_at(parent, os.path.basename(path), path, dev)
    finally:
        os.close(parent)
    return not os.path.lexists(path)


def prune(seal: Seal, lane: str, keep: Optional[int] = None, now: Optional[float] = None) -> List[str]:
    """Housekeeping at the start of a lane (the 115 GB the M4 has free is the corpus's own disk).
    Stored runs of the lane: the newest `keep`, every RED run and the BASELINE are kept; the
    rest go, and a commit folder left empty with them. Nothing is pruned while the accepted
    baseline cannot be read back — the stored runs are then the evidence. Work folders older
    than STALE_WORK_SECONDS are what a run that died left behind: removed (`remove_tree`: never a
    tree with a mount in it)."""
    lines = []
    seal.check()                                             # nothing is removed unless the folders are themselves
    keep = KEEP_RUNS if keep is None else keep
    baseline, _, problem = baseline_of(seal, lane)
    runs = lane_runs(seal, lane)
    kept_whole = 0
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
            if not remove_tree(seal, run):
                kept_whole += 1
                continue
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
        if remove_tree(seal, folder):
            stale += 1
        else:
            kept_whole += 1
    if stale:
        lines.append(f"  housekeeping: {stale} work folders left by runs that died were removed")
    if kept_whole:
        lines.append(f"  housekeeping: {kept_whole} old folders could not be removed whole (a mount, a link or a locked "
                     "file with a second name inside) — left as they are on the M4")
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
    if report.get("smoke"):
        raise Refused(f"refused: the newest {lane} run was a SMOKE run (a subset that proves the harness runs) — never the baseline")
    if report.get("launches_cut_short"):
        raise Refused(f"refused: in the newest {lane} run a launch of files in flight together was cut short "
                      f"({report['launches_cut_short']}) — an AMBER finding is never the baseline; run it again")
    if host_refused(report):
        raise Refused(f"refused: in the newest {lane} run the test app could not read the external volume "
                      f"({host_refused(report)} of {host_refused(report)} files unreadable) — a RED run is never the baseline")
    if report.get("not_run_external"):
        raise Refused(f"refused: the newest {lane} run did not run {report['not_run_external']} files (the external volume "
                      "was not mounted) — a partial run is never the baseline")
    if report.get("not_run_ro"):
        raise Refused(f"refused: the newest {lane} run did not run {report['not_run_ro']} files (the read-only share "
                      "is not mounted) — a partial run is never the baseline")
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


def adopt_volume(seal: Seal, mount: str, who: str) -> List[str]:
    """The one-time, explicit step that makes a volume the corpus's external root: it must be
    mounted directly in /Volumes, not through a link, carry the marker at its root and a
    corpus/media folder; its volume UUID (diskutil) is pinned in ~/corpus/external-volume.json,
    a new file that is never replaced — to adopt another volume, a person moves that file into
    ~/corpus/.trash first. Every later run accepts the external root only on that volume."""
    seal.check()
    pin_path = seal.corpus / VOLUME_PIN
    if os.path.lexists(str(pin_path)):
        raise Refused(f"refused: a volume is already adopted — to adopt another, move ~/corpus/{VOLUME_PIN} into ~/corpus/.trash first")
    volumes = os.path.realpath(str(seal.volumes))
    name = os.path.basename(mount)
    if (os.path.dirname(mount) != volumes or not re.fullmatch(r"[A-Za-z0-9_.-]+", name) or name in (".", "..")
            or os.path.realpath(mount) != mount):
        raise Refused("refused: adopt-volume takes a volume mounted directly in /Volumes, named plainly, not through a link")
    if not os.path.ismount(mount):
        raise Refused("refused: nothing is mounted there")
    marker = os.path.join(mount, MARKER)
    if os.path.islink(marker) or not os.path.isfile(marker):
        raise Refused(f"refused: the volume carries no {MARKER} at its root — it is not marked as test data")
    media = os.path.join(mount, "corpus", "media")
    if os.path.islink(os.path.join(mount, "corpus")) or os.path.realpath(media) != media or not os.path.isdir(media):
        raise Refused("refused: the volume has no corpus/media folder of its own")
    uuid = seal.volume_uuid(mount)
    if not _UUID.fullmatch(uuid):
        raise Refused("refused: diskutil gave no volume UUID for it")
    record = {"mount": mount, "volume_uuid": uuid, "adopted_at": time.strftime("%Y-%m-%d %H:%M:%S"), "adopted_by": who_word(who)}
    # The one file the harness writes outside ~/corpus/{state,work,reports}: created new, never through a link.
    try:
        fd = os.open(str(pin_path), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
    except OSError:
        raise Refused("refused: the adopted-volume record could not be created new")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(json.dumps(record, indent=1, sort_keys=True) + "\n")
    seal._external = None
    return [f"corpus: adopted the volume {word(name)} (volume UUID {uuid}) as the external root — "
            f"accepted from now on only while that volume is mounted at that path"]


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
            "jobs": int(number(report.get("jobs"))) or None,
            "launches_cut_short": int(number(report.get("launches_cut_short"))),
            "cut_short_width": int(number(report.get("cut_short_width"))),
            "run_again_alone": int(number(report.get("run_again_alone"))),
            "failed_alone": int(number(report.get("failed_alone"))),
            "deadline_s": int(number(report.get("deadline_s"))), "limit": int(number(report.get("limit"))) or None,
            "not_run_external": int(number(report.get("not_run_external"))),
            "not_run_ro": int(number(report.get("not_run_ro"))),
            "manifest_sha256": (report["manifest_sha256"] if re.fullmatch(r"[0-9a-f]{64}", str(report.get("manifest_sha256")))
                                else None),
            "external_ran": int(number(report.get("external_ran"))),
            "external_unreadable": int(number(report.get("external_unreadable"))),
            "problem_count": int(number(report.get("problem_count"))),
            "smoke": report.get("smoke") is True,
            "build_reused": report.get("build_reused") is True,
            "inventory": {root: {state: int(number(n)) for state, n in counts.items() if state in STATES}
                          for root, counts in (report.get("inventory") or {}).items()
                          if root in ROOTS and isinstance(counts, dict)} if isinstance(report.get("inventory"), dict) else {},
            "problems": {state: [sha_prefix(x) if re.fullmatch(r"[0-9a-f]{12}", str(x)) is None else str(x)
                                 for x in names if isinstance(x, str)][:LISTED]
                         for state, names in (report.get("problems") or {}).items()
                         if state in PROBLEM_STATES and isinstance(names, list)} if isinstance(report.get("problems"), dict) else {},
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
                     f"{int(prepared['files'])} files in the manifest, {float(prepared['bytes']) / 1e9:.1f} GB")
        shown = clean_report({"lane": "check", "sha": "0" * 40, "inventory": prepared.get("inventory")})["inventory"]
        if shown:
            lines.append("  files at that prepare: " + inventory_line(shown))
    except (OSError, ValueError, KeyError, TypeError, Refused):
        lines.append("corpus: not prepared — run `scripts/corpus_run.sh prepare`")
    try:
        state = seal.external().state
        lines.append({"none": "corpus: no external volume adopted",
                      "absent": "corpus: the external volume is NOT MOUNTED — its files are not run until it is",
                      "ok": "corpus: the external volume is mounted and is the adopted one"}[state])
    except Refused as refusal:
        lines.append(f"corpus: RED {refusal}")
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
    adopting = sub.add_parser("adopt-volume")
    adopting.add_argument("mount")
    adopting.add_argument("--by", default="unknown")
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
    host.add_argument("--jobs", type=int, help=f"files in flight (1..{JOBS_MAX}; default half the logical cores)")
    host.add_argument("--smoke", action="store_true")
    args = parser.parse_args(argv)
    lines: List[str] = []
    try:
        seal = seal or Seal.here()
        if args.command == "status":
            lines, code = status(seal), EXIT_GREEN
        elif args.command == "accept":
            lines, code = accept(seal, args.lane, args.by), EXIT_GREEN
        elif args.command == "adopt-volume":
            lines, code = adopt_volume(seal, args.mount, args.by), EXIT_GREEN
        elif args.lane == "prepare":
            sys.path.insert(0, args.bin)
            code, lines = prepare(seal, Path(args.out))
        else:
            if not re.fullmatch(r"[0-9a-f]{40}", args.sha) or not re.fullmatch(r"[0-9A-Za-z_]+", args.stamp):
                raise Refused("refused: --sha is a full commit id and --stamp is letters, digits and underscores")
            sys.path.insert(0, args.bin)
            if args.smoke and args.lane not in ("check", "proof", "verbs"):
                raise Refused("refused: --smoke is for check, proof and verbs")
            if args.jobs is not None and not 1 <= args.jobs <= JOBS_MAX:
                raise Refused(f"refused: --jobs is a number of files in flight, 1 to {JOBS_MAX}")
            if args.lane == "coverage":                      # the three lanes instrumented, beside the suite (corpus_coverage.py)
                import corpus_coverage
                run = corpus_coverage.CoverageRun(seal, args.sha, args.stamp, Path(args.out), Path(args.worktree),
                                                  Path(args.derived_data), Path(args.bin), args.deadline, args.limit,
                                                  xcodebuild, cp=cp, xcrun=xcrun, swift=swift, jobs=args.jobs)
                code = run.go()
                print("\n".join(run.lines))
                return code
            lane = Lane(seal, args.lane, args.sha, args.stamp, Path(args.out), Path(args.worktree),
                        Path(args.derived_data), Path(args.bin), args.deadline, args.limit, xcodebuild,
                        smoke=args.smoke, jobs=args.jobs) if args.lane != "verbs" else \
                VerbsLane(seal, args.lane, args.sha, args.stamp, Path(args.out), Path(args.worktree),
                          Path(args.derived_data), Path(args.bin), args.deadline, args.limit, xcodebuild, cp=cp,
                          smoke=args.smoke)
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
