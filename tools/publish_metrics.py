#!/usr/bin/env python3
"""The one publisher for LOCAL metrics -> the public `metrics` branch (Rick, 2026-10-02).

Some metrics exist only on the M4: per-folder coverage (tools/nightly_coverage.py)
and the adversarial review ledger (tools/adversarial_nightly.py). The metrics page
(docs/index.html, served by GitHub Pages) can only read what is on GitHub, so this
script rebuilds three small, sanitized streams and pushes them to `metrics`:

    metrics/coverage.jsonl        one row per day: per-folder all % and logic %
    metrics/adversarial.jsonl     one row per night: files, findings by severity,
                                  confirmed-red, kept / declined, precision, cost
    metrics/codex_reviews.jsonl   one row per day: codex passes, findings, closed
                                  passes (parsed from docs/reviews/codex headers)
    metrics/summary_latest.json   ONE object for the page's summary-first view
                                  (GH #310): app version, GitHub counts (open
                                  bugs, open "High Priority" issues, sprint
                                  milestone), demo tags, and the
                                  last 90 nights of the 2 AM run per Mac, each
                                  night classified green / watch / red / did_not_run by
                                  classify_nightly_row(). Rebuilt on every run.
    metrics/github_daily.jsonl    one row per UTC day: open issues, open bugs,
                                  bugs opened / closed in the last 7 days and
                                  in the last 1 day (the page sums the 1-day
                                  counts per ISO week for its opened-vs-closed
                                  bars), open "High Priority" issues. A day
                                  that publishes twice keeps the
                                  later row; a day on which `gh` failed gets
                                  NO row (never nulls in a trend).
    metrics/modules.jsonl         one row per day: per-module counts for the
                                  page's Module health table, published by
                                  scripts/complexity_backfill.py --modules
    metrics/events_latest.json    ONE object: the event-recognition prototype's
                                  counts (scripts/events_prototype.py
                                  --stats-json): records with captions /
                                  transcripts, clips with evidence, candidate
                                  and strong events per category, Rick's ✓/✗
                                  marks. Any failure of the script = the
                                  stream is left as published.

It runs at the end of the 4 AM coverage job and of the adversarial confirm job.
Both call it the same way; a run with nothing new commits nothing.

SUMMARY INPUTS. The nights come from metrics/testdriver.jsonl as already
published on the branch (read from the publisher's worktree after the fetch).
GitHub numbers come from `gh`; every call is tolerant — on any failure the
field is null and the page shows a grey "—". Nothing here can fail the publish
except the privacy gate.

PRIVACY GATE (mandatory). The repo and the page are public, and finding titles
can name family-data code paths. Every row is checked against SCHEMAS before any
file is written: only numbers, dates, folder names, tool names and severity keys
pass. A string that is not a date, a listed enum value or a source folder name
fails the whole publish, and nothing is pushed. Titles, paths, test names, hosts,
commit text and person names never leave this machine.

GIT. All git work happens in a dedicated, DETACHED worktree (default
~/Library/Caches/VideoScan/metrics-publish-wt). The main checkout is asked only
`worktree prune` and `worktree add --detach --no-checkout` to create it; its
HEAD, index and files are never touched. (Detached because the 2 AM nightly
already has branch `metrics` checked out in its own worktree; git allows a branch
in only one worktree at a time.) The push is `HEAD:refs/heads/metrics`, never
forced. A rejected push means someone else published first: fetch, reset the
worktree to origin/metrics, merge again, retry.

    python3 tools/publish_metrics.py               # publish everything available
    python3 tools/publish_metrics.py --dry-run     # print sanitized rows; no git, no writes
    python3 tools/publish_metrics.py --out-dir D   # write sanitized files into D; no git

Environment: VIDEOSCAN_PUBLISH_METRICS=0 makes it a no-op (exit 0).
The last stdout line is always `OUTCOME <word>: <detail>`; callers log it.
Memory: every input is a small local file (ledger ~10 KB, one coverage JSON
~5 KB per day, ~40 review docs); worst case is a few MB.
Stdlib only; runs under /usr/bin/python3 (3.9) from launchd.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Callable, Dict, List, Optional

REPO = Path(__file__).resolve().parent.parent
GITHUB_REPO = "musicalengineer/VideoScan"
PBXPROJ = REPO / "VideoScan" / "VideoScan.xcodeproj" / "project.pbxproj"
LOGS = Path.home() / "Library/Logs/VideoScan"
COVERAGE_DIR = LOGS / "coverage"
ADV_DIR = LOGS / "adversarial-review"
CODEX_DIR = REPO / "docs" / "reviews" / "codex"
DEFAULT_WT = Path.home() / "Library/Caches/VideoScan/metrics-publish-wt"
APP_SOURCES = REPO / "VideoScan" / "VideoScan"

REMOTE_REF = "refs/remotes/origin/metrics"
FETCH_SPEC = "+refs/heads/metrics:" + REMOTE_REF
PUSH_SPEC = "HEAD:refs/heads/metrics"
PUSH_ATTEMPTS = 4
SCHEMA_VERSION = 1


class PrivacyError(ValueError):
    """A row carries something the allowlist does not permit. Nothing is published."""


class PublishError(RuntimeError):
    """The git side could not complete safely."""


# ---------------------------------------------------------------- privacy gate

DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
# A source folder name: one path component, letters/digits only, or "(app root)".
# No "/", no spaces, no punctuation, so it can never carry a path or a sentence.
FOLDER_RE = re.compile(r"^(?:[A-Z][A-Za-z0-9]{0,39}|\(app root\))$")
SEVERITIES = ("P0", "P1", "P2", "P3")
TEST_STATUS = ("ok", "failed", "skipped", "unknown")
RUN_STATUS = ("findings", "failed", "disabled", "nothing", "none", "other")

_CX_BUCKET = {"files": "int", "functions": "int", "ccn_over_15": "int", "ccn_over_30": "int",
              "nloc_over_80": "int", "offenders": "int", "files_over_800": "int", "mean_ccn": "num?"}
_MOD_BUCKET = {"lines": "int", "files": "int", "functions": "int", "mean_ccn": "num?", "max_ccn": "int",
               "ccn_over_15": "int", "ccn_over_30": "int", "files_over_1000": "int",
               "fix_commits_90d": "int?", "fix_commits_all": "int?"}
TS_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
SHA_RE = re.compile(r"^[0-9a-f]{7,40}$")
# Exposure / problem-file streams name app SOURCE files and Swift identifiers,
# both already public in the repo. A source path is repo-relative under the
# measured Swift roots, ends in .swift, and has no spaces, "..", or anything
# else that could carry a sentence; an identifier is dotted Swift names only.
_SWIFT_ROOTS = r"(?:VideoScan/VideoScan|VideoScan/VideoScanCore/Sources|swift_cli)"
SRCPATH_RE = re.compile(r"^" + _SWIFT_ROOTS + r"/(?:[A-Za-z0-9_+-]+(?:\.[A-Za-z0-9_+-]+)*/)*"
                        r"[A-Za-z0-9_+-]+(?:\.[A-Za-z0-9_+-]+)*\.swift$")
IDENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*){0,7}$")
_EX_BUCKET = {"files": "int", "decls": "int", "could_be_private": "int",
              "widened_for_split": "int", "fine": "int"}
_EX_CLASS = ("could-be-private", "widened-for-split")
_EX_KIND = ("func", "var", "let", "init", "subscript", "struct", "class", "enum", "actor")
_SWIFT_FOLDER = ("either", "folder", ("enum", ("swift_cli",)))
_SHA = ("either", "sha", ("enum", ("unknown",)))

_COV_NUMS = {"lines": "int", "covered": "int", "pct": "num?",
             "logic_lines": "int", "logic_covered": "int", "logic_pct": "num?", "files": "int"}

# Summary stream (GH #310). The strings it may carry:
#   code      a machine reason/status code the nightly script prints
#             ("build-timeout:5400s", "zero-tests-ran:test-rc=65",
#             "quality-holdout-not-configured"); lowercase, no spaces, no path
#   hostlabel the Mac, as a short label ("M4", "M5", "M1") — never the host name
#   vers      MARKETING_VERSION / CURRENT_PROJECT_VERSION ("5.1", "1")
#   tagname   a git tag starting with "demo" (Rick's demo-day markers)
#   pubtext   a GitHub milestone title ("Week of Oct 12"): short, printable,
#             and already public on github.com — the only free-ish text allowed
CODE_RE = re.compile(r"^[a-z][a-z0-9-]{0,31}(?:[:=][a-z0-9=.:-]{1,24})?$")
HOSTLABEL_RE = re.compile(r"^[A-Z][A-Za-z0-9]{0,5}$")     # "M4", "Ultra"; a host NAME does not fit
VERS_RE = re.compile(r"^[0-9]+(?:\.[0-9]+){0,3}$")
TAGNAME_RE = re.compile(r"^demo[A-Za-z0-9._/-]{0,59}$")
PUBTEXT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 .,:'/#+()-]{0,59}$")
EVENTCAT_RE = re.compile(r"^[A-Z][a-z]{1,19}(?: / [a-z]{1,19})?$")   # "Birthday", "Beach / vacation"; never a name
NIGHT_STATES = ("green", "watch", "red", "did_not_run")
# Rick, 2026-10-15: "if fail < 10 make it orange or yellow, but red means
# broken." Fewer than this many failed tests, with the suite otherwise
# intact, is WATCH (yellow on the page); red is reserved for a broken run.
WATCH_MAX_FAILED = 10
SUMMARY_DAYS = 90
_NIGHT = {"state": ("enum", NIGHT_STATES), "passed": "int", "failed": "int", "total": "int",
          "reason": "code?"}

# One spec per stream. Every row must have EXACTLY these keys (no extras, none
# missing). Specs: "int" / "int?" non-negative int (or null); "num" / "num?"
# finite number (or null); "date"; ("enum", values); "folder";
# ("obj", spec); ("list", spec); ("sev", "int") a P0..P3 -> int map; ("opt", spec) spec or null.
SCHEMAS: Dict[str, dict] = {
    "coverage.jsonl": {
        "schemaVersion": "int",
        "date": "date",
        "app_status": ("enum", TEST_STATUS),
        "core_status": ("enum", TEST_STATUS),
        "total": ("obj", _COV_NUMS),
        "folders": ("list", ("obj", dict(_COV_NUMS, folder="folder"))),
    },
    "adversarial.jsonl": {
        "schemaVersion": "int",
        "date": "date",
        "status": ("enum", RUN_STATUS),
        "runs": "int",
        "failed_runs": "int",
        "files_in_scope": "int?",
        "files_reviewed": "int?",
        "findings": ("opt", ("sev", "int")),
        "confirmed_red": "int?",
        "confirm_considered": "int?",
        "kept": "int",
        "declined": "int",
        "precision": "num?",
        "cost_usd": "num?",
    },
    "codex_reviews.jsonl": {
        "schemaVersion": "int",
        "date": "date",
        "docs": "int",
        "unparsed_docs": "int",
        "passes": "int",
        "findings": "int",
        "closed_passes": "int",
    },
    # Complexity trend BACKFILL rows (scripts/complexity_backfill.py). Counts
    # and folder names only: no top-15, no file paths, no function names.
    # The nightly's own rows on this stream come from GitHub CI, are kept
    # verbatim and never re-validated here (APPEND_ONLY below).
    "complexity.jsonl": {
        "schemaVersion": "int",
        "ts": "ts",
        "sha": "sha",
        "run_kind": ("enum", ("backfill",)),
        "backfill": "true",
        "lizard_version": ("opt", ("enum", ("1.22.1",))),
        "thresholds": ("obj", {"ccn": "int", "nloc": "int", "file_lines": "int"}),
        "totals": ("obj", {"swift": ("obj", _CX_BUCKET), "python": ("obj", _CX_BUCKET),
                           "all": ("obj", _CX_BUCKET)}),
        "swift_by_folder": ("opt", ("map", ("either", "folder", ("enum", ("swift_cli",))), ("obj", _CX_BUCKET))),
        "python_by_folder": ("opt", ("map", ("enum", ("scripts", "tools")), ("obj", _CX_BUCKET))),
        "folders_mapped_pct": "num?",
    },
    # Per-module history for the page's Module health table
    # (scripts/complexity_backfill.py --modules, 2026-10-18): one row per day,
    # counts and module names only ("Catalog", "Core", "Core/Store",
    # "swift_cli"). The nightly carries the same numbers, plus names, as
    # `modules` on its complexity.jsonl row.
    "modules.jsonl": {
        "schemaVersion": "int",
        "ts": "ts",
        "sha": "sha",
        "run_kind": ("enum", ("backfill",)),
        "modules": ("map", "module", ("obj", _MOD_BUCKET)),
        "files_mapped_pct": "num?",
    },
    # Over-exposure (scripts/exposure_metrics.py) and the problem-files table
    # (scripts/problem_files.py), published by the GitHub nightly's aggregate
    # job after `--validate` (Rick 2026-10-07). Counts, folder names, source
    # paths and Swift identifiers only.
    "exposure.jsonl": {
        "schemaVersion": "int",
        "ts": "ts",
        "sha": _SHA,
        "run_kind": ("enum", ("nightly", "manual")),
        "totals": ("obj", _EX_BUCKET),
        "by_folder": ("map", _SWIFT_FOLDER, ("obj", _EX_BUCKET)),
        "top20": ("list", ("obj", {"file": "srcpath", "could_be_private": "int",
                                   "widened_for_split": "int", "decls": "int"})),
        "baseline_before": "int",
        "baseline_after": "int",
        "new": "int",
        "fixed": "int",
        "shrink_skipped": "bool",
    },
    "exposure_new_latest.json": {
        "schemaVersion": "int",
        "ts": "ts",
        "sha": _SHA,
        "new": ("list", ("obj", {"key": "declkey", "file": "srcpath", "name": "ident",
                                 "kind": ("enum", _EX_KIND), "classification": ("enum", _EX_CLASS)})),
        "fixed": "int",
        "baseline_before": "int",
        "baseline_after": "int",
        "shrink_skipped": "bool",
    },
    "exposure_files_latest.json": {
        "schemaVersion": "int",
        "ts": "ts",
        "sha": _SHA,
        "files": ("map", "srcpath", ("obj", {"lines": "int", "decls": "int",
                                             "could_be_private": ("list", "ident"),
                                             "widened_for_split": ("list", "ident")})),
    },
    "problem_files_latest.json": {
        "schemaVersion": "int",
        "ts": "ts",
        "sha": _SHA,
        "formula_version": "int",
        "files_scored": "int",
        "rows": ("list", ("obj", {"file": "srcpath", "score": "num", "offenders": "int",
                                  "worst_ccn": "int", "new_or_worse": "int", "lines": "int",
                                  "could_be_private": "int", "widened_for_split": "int",
                                  "churn_7d": "int"})),
    },
    # The page's summary-first view (GH #310). One object, rebuilt each run.
    "summary_latest.json": {
        "schemaVersion": "int",
        "generated": "ts",
        "version": ("opt", ("obj", {"marketing": "vers", "build": "vers"})),
        "github": ("obj", {"open_issues": "int?", "open_bugs": "int?", "bugs_opened_7d": "int?",
                           "bugs_closed_7d": "int?", "high_priority_open": "int?",
                           "main_sha": "sha?", "main_date": "date?"}),
        "sprint": ("opt", ("obj", {"title": "pubtext", "open": "int", "closed": "int", "due": "date?"})),
        "tags": ("list", ("obj", {"date": "date", "name": "tagname"})),
        "person": ("opt", ("obj", {"status": "code", "readiness_pct": "num?", "quality_score": "num?"})),
        "nightly": ("obj", {"days": "int", "hosts": ("list", "hostlabel"),
                            "off_rota": ("list", "hostlabel"),
                            "nights": ("list", ("obj", {"date": "date",
                                                        "hosts": ("map", "hostlabel", ("obj", _NIGHT))}))}),
    },
    # The bug trend (GH #310 follow-up): one row per UTC day, numbers only, no
    # nulls — a day gh failed on is absent, so the page's lines break there.
    "github_daily.jsonl": {
        "ts": "ts",
        "open_issues": "int", "open_bugs": "int",
        "bugs_opened_7d": "int", "bugs_closed_7d": "int",
        "bugs_opened_1d": "int", "bugs_closed_1d": "int",
        # Added 2026-10-12: every new row carries it (never null; the day is skipped
        # instead). "maybe" = the key may be ABSENT on rows published before then,
        # which the gate re-validates on every publish; present means a count.
        "high_priority_open": ("maybe", "int"),
    },
    # Event recognition prototype v0 (scripts/events_prototype.py --stats-json):
    # ONE object, rebuilt each publish. Counts only; category names are the
    # script's CATEGORIES constants (EVENTCAT_RE), never a clip, a person or a word
    # said. Marks are null until Rick has exported some.
    "events_latest.json": {
        "schemaVersion": "int",
        "ts": "ts",
        "active_records": "int", "with_captions": "int", "with_transcripts": "int",
        "clips_with_evidence": "int", "candidate_events": "int", "strong_events": "int",
        "by_category": ("map", "eventcat", "int"),
        "marks_yes": "int?", "marks_no": "int?",
        "precision_by_category": ("opt", ("map", "eventcat", ("obj", {"yes": "int", "no": "int"}))),
    },
}
EVENTS_KEYS = ("ts", "active_records", "with_captions", "with_transcripts", "clips_with_evidence",
               "candidate_events", "strong_events", "by_category", "marks_yes", "marks_no", "precision_by_category")
EVENTS_SCRIPT = REPO / "scripts" / "events_prototype.py"
GITHUB_DAILY_KEYS = ("open_issues", "open_bugs", "bugs_opened_7d", "bugs_closed_7d",
                     "bugs_opened_1d", "bugs_closed_1d", "high_priority_open")
GITHUB_SUMMARY_KEYS = ("open_issues", "open_bugs", "bugs_opened_7d", "bugs_closed_7d", "high_priority_open",
                       "main_sha", "main_date")
HIGH_PRIORITY_LABEL = "High Priority"      # the exact GitHub label name

# Streams whose existing rows were published by someone else (GitHub CI):
# fresh rows are validated and appended (deduplicated by ts + sha); rows
# already on the branch are kept exactly as they are.
APPEND_ONLY = {"complexity.jsonl"}
# Streams that are ONE JSON object, replaced whole on every publish.
SINGLE_OBJECT = {"summary_latest.json", "events_latest.json"}


def source_folders() -> set:
    """Folder names the coverage stream may name: the app's top-level source
    folders plus the two synthetic buckets nightly_coverage.py uses."""
    names = {"Core", "(app root)"}
    if APP_SOURCES.is_dir():
        names |= {p.name for p in APP_SOURCES.iterdir() if p.is_dir() and FOLDER_RE.match(p.name)}
    return names


def _is_int(v) -> bool:
    return not isinstance(v, bool) and isinstance(v, int) and v >= 0


def _is_num(v) -> bool:
    return not isinstance(v, bool) and isinstance(v, (int, float)) and math.isfinite(v)


def _matches(regex):
    return lambda v: isinstance(v, str) and bool(regex.match(v))


# Scalar specs: name -> (test, what the value should have been).
_SCALARS = {
    "int": (_is_int, "expected a non-negative integer"),
    "num": (_is_num, "expected a finite number"),
    "true": (lambda v: v is True, "expected true"),
    "ts": (_matches(TS_RE), "expected a YYYY-MM-DDTHH:MM:SSZ timestamp"),
    "sha": (_matches(SHA_RE), "expected a hex commit SHA"),
    "date": (_matches(DATE_RE), "expected a YYYY-MM-DD date"),
    "bool": (lambda v: isinstance(v, bool), "expected true or false"),
    "srcpath": (lambda v: isinstance(v, str) and len(v) <= 200 and bool(SRCPATH_RE.match(v)),
                "expected a repo-relative app .swift path"),
    "ident": (lambda v: isinstance(v, str) and len(v) <= 160 and bool(IDENT_RE.match(v)),
              "expected a dotted Swift identifier"),
    "declkey": (lambda v: isinstance(v, str) and v.count("::") == 1
                and bool(SRCPATH_RE.match(v.split("::")[0])) and bool(IDENT_RE.match(v.split("::")[1]))
                and len(v) <= 360, "expected file.swift::Type.name"),
    "code": (_matches(CODE_RE), "expected a lowercase machine reason/status code"),
    "hostlabel": (_matches(HOSTLABEL_RE), "expected a short Mac label such as M4"),
    "vers": (_matches(VERS_RE), "expected a dotted version number"),
    "tagname": (_matches(TAGNAME_RE), "expected a demo* git tag name"),
    "pubtext": (_matches(PUBTEXT_RE), "expected a short public milestone title"),
    "eventcat": (_matches(EVENTCAT_RE), "expected an event category constant such as Birthday"),
}


def _bad(where: str, value, why: str) -> PrivacyError:
    return PrivacyError(f"{where}: {why} (value type {type(value).__name__})")


def _check_folder(value, where: str, folders: Optional[set]) -> None:
    if not isinstance(value, str) or not FOLDER_RE.match(value):
        raise _bad(where, value, "expected a plain source-folder name")
    if folders is not None and value not in folders:
        raise _bad(where, value, "not a source folder of this repo")


CORE_SOURCES = REPO / "VideoScan" / "VideoScanCore" / "Sources" / "VideoScanCore"


def core_subfolders() -> set:
    """VideoScanCore's subfolders: the "Core/<name>" modules a row may name."""
    if not CORE_SOURCES.is_dir():
        return set()
    return {p.name for p in CORE_SOURCES.iterdir() if p.is_dir() and FOLDER_RE.match(p.name)}


def _check_module(value, where: str, folders: Optional[set]) -> None:
    """A Module health table name: a source folder, "swift_cli", or
    "Core/<subfolder>" (one plain component after the slash, and with a
    folder set given, a subfolder that exists)."""
    if value == "swift_cli":
        return
    if isinstance(value, str) and value.startswith("Core/"):
        sub = value[len("Core/"):]
        if not FOLDER_RE.match(sub) or sub == "(app root)":
            raise _bad(where, value, "expected Core/<plain folder name>")
        if folders is not None and sub not in core_subfolders():
            raise _bad(where, value, "not a VideoScanCore subfolder of this repo")
        return
    _check_folder(value, where, folders)


def _check_obj(spec, value, where, folders) -> None:
    if not isinstance(value, dict):
        raise _bad(where, value, "expected an object")
    # ("maybe", spec): the key may be absent (added to the stream after rows were
    # published); when present it must match spec. Every other key is required.
    maybe = {k for k, sub in spec[1].items() if isinstance(sub, tuple) and sub and sub[0] == "maybe"}
    if not (set(spec[1]) - maybe <= set(value) <= set(spec[1])):
        raise PrivacyError(f"{where}: keys {sorted(value)} != allowlist {sorted(spec[1])}")
    for key, sub in spec[1].items():
        if key in value:
            _check(sub[1] if key in maybe else sub, value[key], f"{where}.{key}", folders)


def _check_either(spec, value, where, folders) -> None:
    try:
        _check(spec[1], value, where, folders)
    except PrivacyError:
        _check(spec[2], value, where, folders)


def _check_map(spec, value, where, folders) -> None:
    if not isinstance(value, dict):
        raise _bad(where, value, "expected an object")
    for key, item in value.items():
        _check(spec[1], key, f"{where}<key>", folders)
        _check(spec[2], item, f"{where}.{key}", folders)


def _check_list(spec, value, where, folders) -> None:
    if not isinstance(value, list):
        raise _bad(where, value, "expected a list")
    for i, item in enumerate(value):
        _check(spec[1], item, f"{where}[{i}]", folders)


def _check_sev(spec, value, where, folders) -> None:
    if not isinstance(value, dict) or set(value) != set(SEVERITIES):
        raise _bad(where, value, "expected exactly the P0..P3 severity keys")
    for key in SEVERITIES:
        _check(spec[1], value[key], f"{where}.{key}", folders)


def _check_enum(spec, value, where, folders) -> None:
    if value not in spec[1]:
        raise _bad(where, value, "not an allowed enum value")


def _check_opt(spec, value, where, folders) -> None:
    if value is not None:
        _check(spec[1], value, where, folders)


_COMPOSITES = {"enum": _check_enum, "opt": _check_opt, "obj": _check_obj, "either": _check_either,
               "map": _check_map, "list": _check_list, "sev": _check_sev}


def _check(spec, value, where: str, folders: Optional[set]) -> None:
    if isinstance(spec, str):
        if spec.endswith("?"):
            if value is None:
                return
            spec = spec[:-1]
        if spec == "folder":
            _check_folder(value, where, folders)
            return
        if spec == "module":
            _check_module(value, where, folders)
            return
        if spec in _SCALARS:
            test, why = _SCALARS[spec]
            if not test(value):
                raise _bad(where, value, why)
            return
    elif isinstance(spec, tuple) and spec and spec[0] in _COMPOSITES:
        _COMPOSITES[spec[0]](spec, value, where, folders)
        return
    raise PrivacyError(f"{where}: unknown schema spec {spec!r}")


def validate(stream: str, row: dict, folders: Optional[set] = None) -> None:
    """Raise PrivacyError unless `row` is exactly the allowlisted shape for `stream`."""
    if stream not in SCHEMAS:
        raise PrivacyError(f"{stream}: not a publishable stream")
    _check(("obj", SCHEMAS[stream]), row, stream, folders)


# ---------------------------------------------------------------- builders

def _pct(covered: int, total: int) -> Optional[float]:
    return round(100.0 * covered / total, 1) if total else None


def _status_word(text) -> str:
    """nightly_coverage.py writes free text ("exit 65 (tests may have failed…)");
    only its category is published."""
    if text == "ok":
        return "ok"
    if text == "skipped":
        return "skipped"
    if isinstance(text, str) and text:
        return "failed"
    return "unknown"


def _int(value) -> int:
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else 0


def coverage_row(payload: dict) -> dict:
    """One coverage-<date>.json (tools/nightly_coverage.py) -> one sanitized row.
    Only the numbers are copied; `zero_files` (paths), host and commit are dropped."""
    meta = payload.get("meta") or {}
    folders = []
    tot = {"lines": 0, "covered": 0, "logic_lines": 0, "logic_covered": 0, "files": 0}
    for name, d in sorted((payload.get("folders") or {}).items()):
        lines, covered = _int(d.get("executable")), _int(d.get("covered"))
        llines, lcovered = _int(d.get("logic_executable")), _int(d.get("logic_covered"))
        files = _int(d.get("files"))
        folders.append({"folder": name, "lines": lines, "covered": covered, "pct": _pct(covered, lines),
                        "logic_lines": llines, "logic_covered": lcovered,
                        "logic_pct": _pct(lcovered, llines), "files": files})
        for key, val in (("lines", lines), ("covered", covered), ("logic_lines", llines),
                         ("logic_covered", lcovered), ("files", files)):
            tot[key] += val
    total = dict(tot, pct=_pct(tot["covered"], tot["lines"]),
                 logic_pct=_pct(tot["logic_covered"], tot["logic_lines"]))
    return {"schemaVersion": SCHEMA_VERSION, "date": meta.get("date"),
            "app_status": _status_word(meta.get("app_status")),
            "core_status": _status_word(meta.get("core_status")),
            "total": total, "folders": folders}


def coverage_rows(cov_dir: Path) -> Optional[List[dict]]:
    """Every coverage-YYYY-MM-DD.json in cov_dir. None when the directory is absent
    (the stream is then left as it is on the branch)."""
    if not cov_dir.is_dir():
        return None
    rows = []
    for path in sorted(cov_dir.glob("coverage-*.json")):
        m = re.match(r"^coverage-(\d{4}-\d{2}-\d{2})\.json$", path.name)
        if not m:
            continue
        try:
            payload = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        meta = payload.setdefault("meta", {})
        meta["date"] = m.group(1)   # the file name is the authority for the date
        rows.append(coverage_row(payload))
    return rows


def _read_jsonl(path: Path) -> List[dict]:
    rows = []
    try:
        text = path.read_text()
    except OSError:
        return rows
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if isinstance(obj, dict):
            rows.append(obj)
    return rows


def _sev(counts) -> Optional[dict]:
    if not isinstance(counts, dict):
        return None
    return {s: _int(counts.get(s)) for s in SEVERITIES}


def adversarial_rows(ledger: Path, findings: Optional[Path] = None) -> Optional[List[dict]]:
    """Per-night counts from the adversarial ledger. Never copies a title, key, path,
    test name, range or doc path; only counts, dates, severities and cost.

    A night = the `date` of its `run` events. Close/decline events carry no date:
    they are credited to the night that FIRST saw the finding (findings.json
    `runs`), falling back to the latest run before them in the ledger."""
    if not ledger.is_file():
        return None
    first_seen: Dict[str, str] = {}
    if findings is not None and findings.is_file():
        try:
            known = json.loads(findings.read_text())
        except (OSError, ValueError):
            known = {}
        if isinstance(known, dict):
            for fp, rec in known.items():
                runs = [r for r in (rec.get("runs") or []) if isinstance(r, str) and DATE_RE.match(r)]
                if runs:
                    first_seen[fp] = min(runs)

    nights: Dict[str, dict] = {}

    def night(date: str) -> dict:
        return nights.setdefault(date, {"runs": [], "confirms": [], "kept": 0, "declined": 0})

    last_run_date = None
    for ev in _read_jsonl(ledger):
        kind = ev.get("event")
        if kind == "run" and isinstance(ev.get("date"), str) and DATE_RE.match(ev["date"]):
            night(ev["date"])["runs"].append(ev)
            last_run_date = ev["date"]
        elif kind == "confirm" and isinstance(ev.get("date"), str) and DATE_RE.match(ev["date"]):
            night(ev["date"])["confirms"].append(ev)
        elif kind in ("close", "decline"):
            date = first_seen.get(ev.get("fp")) or last_run_date
            if date is None:
                at = str(ev.get("at") or "")[:10]
                date = at if DATE_RE.match(at) else None
            if date is None:
                continue
            n = night(date)
            if kind == "close" and ev.get("kept") is not False:
                n["kept"] += 1
            else:
                n["declined"] += 1

    rows = []
    for date in sorted(nights):
        n = nights[date]
        runs = n["runs"]
        good = [r for r in runs if r.get("status") != "failed"]
        last = good[-1] if good else (runs[-1] if runs else None)
        status = "none"
        if last is not None:
            status = last.get("status") if last.get("status") in RUN_STATUS else "other"
        confirms = [c for c in n["confirms"] if not c.get("skipped")]
        confirm = confirms[-1] if confirms else None
        costs = [float(r["costUsd"]) for r in runs
                 if isinstance(r.get("costUsd"), (int, float)) and not isinstance(r.get("costUsd"), bool)]
        closed = n["kept"] + n["declined"]
        rows.append({
            "schemaVersion": SCHEMA_VERSION, "date": date, "status": status,
            "runs": len(runs), "failed_runs": sum(1 for r in runs if r.get("status") == "failed"),
            "files_in_scope": _int(last.get("filesInScope")) if last else None,
            "files_reviewed": _int(last.get("filesReviewed")) if last else None,
            "findings": _sev(last.get("findings")) if last else None,
            "confirmed_red": _int(confirm.get("confirmedRed")) if confirm and confirm.get("confirmedRed") is not None else None,
            "confirm_considered": _int(confirm.get("considered")) if confirm and confirm.get("considered") is not None else None,
            "kept": n["kept"], "declined": n["declined"],
            "precision": round(n["kept"] / closed, 3) if closed else None,
            "cost_usd": round(sum(costs), 2) if costs else None,
        })
    return rows


_CONTRACT_RE = re.compile(
    r"^\W*Credits spent:[^\n|]*\|\s*\**\s*(?:Finding count|Remaining findings[^:\n]*):\s*\**\s*(\d+)",
    re.IGNORECASE | re.MULTILINE)
_CLOSED_RE = re.compile(r"^##\s+Clos(?:ed|ure)\b", re.MULTILINE)
_DOC_DATE_RE = re.compile(r"(\d{4})[-_](\d{2})[-_](\d{2})")


def codex_rows(codex_dir: Path) -> Optional[List[dict]]:
    """Per-day codex review counts from docs/reviews/codex/*.md.

    A pass = one `Credits spent: … | Finding count: N` contract line (the first line
    codex_review.py makes codex print). Closed passes = `## Closed` / `## Closure`
    sections, capped at the doc's pass count. Docs written before the contract
    existed have no parseable header: they count as `unparsed_docs`, never as zero
    findings."""
    if not codex_dir.is_dir():
        return None
    days: Dict[str, dict] = {}
    for path in sorted(codex_dir.glob("*.md")):
        m = _DOC_DATE_RE.search(path.name)
        if not m:
            continue
        date = "-".join(m.groups())
        try:
            text = path.read_text(errors="ignore")
        except OSError:
            continue
        counts = [int(x) for x in _CONTRACT_RE.findall(text)]
        d = days.setdefault(date, {"docs": 0, "unparsed_docs": 0, "passes": 0, "findings": 0, "closed_passes": 0})
        d["docs"] += 1
        if not counts:
            d["unparsed_docs"] += 1
            continue
        d["passes"] += len(counts)
        d["findings"] += sum(counts)
        d["closed_passes"] += min(len(_CLOSED_RE.findall(text)), len(counts))
    return [dict({"schemaVersion": SCHEMA_VERSION, "date": date}, **days[date]) for date in sorted(days)]


def build_streams(cov_dir: Path = COVERAGE_DIR, adv_dir: Path = ADV_DIR,
                  codex_dir: Path = CODEX_DIR) -> Dict[str, Optional[List[dict]]]:
    """name -> fresh rows, or None when that source is not on this machine."""
    return {
        "coverage.jsonl": coverage_rows(cov_dir),
        "adversarial.jsonl": adversarial_rows(adv_dir / "ledger.jsonl", adv_dir / "findings.json"),
        "codex_reviews.jsonl": codex_rows(codex_dir),
    }


def events_object(raw) -> Optional[dict]:
    """The events_latest.json object from the script's --stats-json output:
    the allowlisted keys only (anything else the script may ever add is dropped
    here, and the gate still has the last word), or None if it is not an object."""
    if not isinstance(raw, dict):
        return None
    return dict({"schemaVersion": SCHEMA_VERSION}, **{k: raw.get(k) for k in EVENTS_KEYS})


def events_stats(run: Callable = subprocess.run, script: Path = EVENTS_SCRIPT,
                 python: str = sys.executable, timeout: int = 900) -> Optional[dict]:
    """Run `scripts/events_prototype.py --no-open --stats-json <tmp>` and return
    its counts, or None on ANY failure (script missing, non-zero exit, timeout,
    unreadable or non-JSON output): the stream is then simply not written."""
    import tempfile
    try:
        with tempfile.TemporaryDirectory(prefix="videoscan-events-") as tmp:
            out = Path(tmp) / "events.json"
            proc = run([python, str(script), "--no-open", "--stats-json", str(out)],
                       capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=timeout)
            if proc.returncode != 0:
                return None
            return events_object(json.loads(out.read_text(encoding="utf-8")))
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


# ---------------------------------------------------------------- summary (GH #310)

def classify_nightly_row(row: dict) -> str:
    """THE rule for one 2 AM run (Rick, GH #310): a night where no test ran —
    build timeout, build error, zero tests, dirty tree, skipped — DID NOT RUN.
    It is amber on the page, never red. WATCH (Rick 2026-10-15, yellow): the
    suite ran to the end and fewer than WATCH_MAX_FAILED tests failed. RED
    means broken: that many or more failed, or a run killed part-way (a
    reason other than the plain failed-tests count: the exit code is
    evidence). Green: tests ran, status ok, nothing failed. The row's
    `crashed_names` never decides the colour: the nightly's "host died"
    detection is a log heuristic that also lists a NAMED Swift Testing test
    that merely failed (10/15: the Angel boundary ratchet)."""
    if _int(row.get("total")) == 0:
        return "did_not_run"
    failed = _int(row.get("failed"))
    reason = row.get("reason")
    ran_to_the_end = row.get("status") == "ok" or (isinstance(reason, str) and reason.startswith("failed-tests:"))
    if 0 < failed < WATCH_MAX_FAILED and ran_to_the_end:
        return "watch"
    if row.get("status") == "failed" or failed > 0:
        return "red"
    return "green"


def host_label(host) -> Optional[str]:
    """"RicksM4" -> "M4". The host NAME never leaves the machine; only a short
    label does, and a host whose label does not fit the allowlist is dropped."""
    if not isinstance(host, str):
        return None
    label = re.sub(r"^ricks", "", host.strip(), flags=re.IGNORECASE)
    return label if HOSTLABEL_RE.match(label) else None


def reason_code(reason) -> Optional[str]:
    """Keep the nightly's machine code ("build-timeout:5400s"); when the detail
    part is not code-shaped ("dirty-tree:<paths>"), keep the kind alone."""
    if not isinstance(reason, str) or not reason:
        return None
    if CODE_RE.match(reason):
        return reason
    kind = reason.split(":", 1)[0]
    return kind if CODE_RE.match(kind) else None


HOST_ORDER = ("M4", "Ultra")   # the two Mac Studios (Rick 2026-10-28)
# THE nightly rotation (GH #360): which Macs run the 2 AM nightly. One file, read by
# the installer, the failover guard, the morning digest and this publisher.
NIGHTLY_ROTA = REPO / "scripts" / "nightly_rota.json"


def load_rota(path: Path = NIGHTLY_ROTA) -> dict:
    """{"on": [labels in slot order], "off": [labels]} from nightly_rota.json.
    A missing or unreadable file means nobody is off the rotation (the table then
    shows every Mac that published, as before) — never a crash."""
    try:
        raw = json.loads(path.read_text())
    except (OSError, ValueError):
        return {"on": list(HOST_ORDER), "off": []}
    on = [h for h in (raw.get("on") or {}) if isinstance(h, str) and HOSTLABEL_RE.match(h)]
    off = [h for h in (raw.get("off") or {}) if isinstance(h, str) and HOSTLABEL_RE.match(h) and h not in on]
    return {"on": on, "off": off}


def nightly_summary(td_rows: List[dict], today: str, days: int = SUMMARY_DAYS,
                    rota: Optional[dict] = None) -> dict:
    """The last `days` nights (ending `today`, a UTC date) of the 2 AM nightly,
    one cell per Mac, from the published testdriver rows. The last row a host
    published on a UTC date wins for that night (a rerun is newer evidence).

    A Mac that is OFF the rotation (nightly_rota.json; GH #360: the M1) has no
    column and no cells — not even its old nights — so its absence can never
    read as a failure or a "no run"; it is listed in `off_rota` instead and the
    page says so."""
    rota = load_rota() if rota is None else rota
    off = set(rota.get("off") or ())
    order = tuple(rota.get("on") or ()) + tuple(h for h in HOST_ORDER if h not in (rota.get("on") or ()))
    end = datetime.strptime(today, "%Y-%m-%d")
    dates = [(end - timedelta(days=days - 1 - i)).strftime("%Y-%m-%d") for i in range(days)]
    wanted = set(dates)
    cells: Dict[str, Dict[str, dict]] = {}
    seen_hosts = set()
    for row in td_rows:
        if row.get("source") != "nightly-local":
            continue
        ts = row.get("ts")
        date = ts[:10] if isinstance(ts, str) and TS_RE.match(ts) else None
        label = host_label(row.get("host"))
        if date is None or date not in wanted or label is None or label in off:
            continue
        seen_hosts.add(label)
        cells.setdefault(date, {})[label] = {
            "state": classify_nightly_row(row), "passed": _int(row.get("passed")),
            "failed": _int(row.get("failed")), "total": _int(row.get("total")),
            "reason": reason_code(row.get("reason")),
        }
    hosts = [h for h in order if h in seen_hosts] + sorted(seen_hosts - set(order))
    return {"days": days, "hosts": hosts, "off_rota": sorted(off),
            "nights": [{"date": d, "hosts": cells.get(d, {})} for d in dates]}


def person_summary(td_rows: List[dict]) -> Optional[dict]:
    """Status code and two numbers from the newest nightly row that carries the
    person-eval fields. Codes only; the page never reads the raw fields."""
    for row in reversed(td_rows):
        if row.get("source") != "nightly-local" or "person_eval_status" not in row:
            continue
        status = reason_code(row.get("person_eval_status")) or "other"
        num = lambda v: v if _is_num(v) else None   # noqa: E731
        return {"status": status, "readiness_pct": num(row.get("person_eval_readiness_pct")),
                "quality_score": num(row.get("person_eval_quality_score"))}
    return None


def app_version(pbxproj: Path = PBXPROJ) -> Optional[dict]:
    """MARKETING_VERSION / CURRENT_PROJECT_VERSION of the VideoScan app target
    (the build configuration whose bundle identifier ends in .VideoScan)."""
    try:
        text = pbxproj.read_text(errors="ignore")
    except OSError:
        return None
    for block in re.finditer(r"buildSettings = \{(.*?)\n\s*\};", text, re.S):
        body = block.group(1)
        if not re.search(r'PRODUCT_BUNDLE_IDENTIFIER = "?[A-Za-z0-9.-]*\.VideoScan"?;', body):
            continue
        mv = re.search(r"MARKETING_VERSION = ([0-9.]+);", body)
        bv = re.search(r"CURRENT_PROJECT_VERSION = ([0-9.]+);", body)
        if mv and bv and VERS_RE.match(mv.group(1)) and VERS_RE.match(bv.group(1)):
            return {"marketing": mv.group(1), "build": bv.group(1)}
    return None


class Gh:
    """`gh <args>` -> stdout, or None on ANY failure (not installed, not logged
    in, offline, timeout, non-zero exit). The summary never fails on GitHub."""

    def __init__(self, binary: Optional[str] = None, timeout: int = 60):
        self.binary = binary or os.environ.get("VIDEOSCAN_GH_BIN") or "gh"
        self.timeout = timeout

    def __call__(self, *args: str) -> Optional[str]:
        try:
            proc = subprocess.run([self.binary, *args], capture_output=True, text=True,
                                  stdin=subprocess.DEVNULL, timeout=self.timeout)
        except (OSError, subprocess.SubprocessError):
            return None
        return proc.stdout if proc.returncode == 0 else None


def _gh_json(gh: Callable[..., Optional[str]], *args: str):
    out = gh(*args)
    if out is None:
        return None
    try:
        return json.loads(out)
    except ValueError:
        return None


def github_numbers(gh: Callable[..., Optional[str]], now: datetime, repo: str = GITHUB_REPO) -> dict:
    """Every GitHub number both streams draw on, from four `gh` calls: open
    issues; open bugs and bugs opened / closed in the last 7 days and the last
    1 day; open issues labelled "High Priority"; the tip of main. Each field is
    null when its `gh` call fails."""
    g: Dict[str, object] = {k: None for k in GITHUB_SUMMARY_KEYS + ("bugs_opened_1d", "bugs_closed_1d")}
    issues = _gh_json(gh, "issue", "list", "-R", repo, "--state", "open", "--limit", "1000", "--json", "number")
    if isinstance(issues, list):
        g["open_issues"] = len(issues)
    high = _gh_json(gh, "issue", "list", "-R", repo, "--state", "open", "--label", HIGH_PRIORITY_LABEL,
                    "--limit", "1000", "--json", "number")
    if isinstance(high, list):
        g["high_priority_open"] = len(high)
    bugs = _gh_json(gh, "issue", "list", "-R", repo, "--state", "all", "--label", "bug", "--limit", "1000",
                    "--json", "state,createdAt,closedAt")
    if isinstance(bugs, list):
        rows = [b for b in bugs if isinstance(b, dict)]
        g["open_bugs"] = sum(1 for b in rows if b.get("state") == "OPEN")
        for days, suffix in ((7, "7d"), (1, "1d")):
            since = (now - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
            g["bugs_opened_" + suffix] = sum(1 for b in rows if str(b.get("createdAt") or "") >= since)
            g["bugs_closed_" + suffix] = sum(1 for b in rows if str(b.get("closedAt") or "") >= since)
    tip = _gh_json(gh, "api", f"repos/{repo}/commits/main")
    if isinstance(tip, dict):
        sha = tip.get("sha")
        date = str(((tip.get("commit") or {}).get("committer") or {}).get("date") or "")[:10]
        g["main_sha"] = sha[:12] if isinstance(sha, str) and SHA_RE.match(sha) else None
        g["main_date"] = date if DATE_RE.match(date) else None
    return g


def github_summary(gh: Callable[..., Optional[str]], now: datetime, repo: str = GITHUB_REPO) -> dict:
    """The `github` object of summary_latest.json: open issues, open bugs, bugs
    opened / closed in the last 7 days, open "High Priority" issues, and the tip
    of main (nulls on failure)."""
    return summary_github(github_numbers(gh, now, repo))


def summary_github(numbers: dict) -> dict:
    return {k: numbers.get(k) for k in GITHUB_SUMMARY_KEYS}


def github_daily_row(numbers: dict, now: datetime) -> Optional[dict]:
    """Today's row of github_daily.jsonl, or None when any count is missing: a
    trend never carries a null, the day is simply absent and the line breaks."""
    if any(numbers.get(k) is None for k in GITHUB_DAILY_KEYS):
        return None
    return dict({"ts": now.strftime("%Y-%m-%dT%H:%M:%SZ")}, **{k: numbers[k] for k in GITHUB_DAILY_KEYS})


def sprint_summary(gh: Callable[..., Optional[str]], repo: str = GITHUB_REPO) -> Optional[dict]:
    """The open milestone with the nearest due date ("Week of Oct 12"), or null."""
    ms = _gh_json(gh, "api", f"repos/{repo}/milestones?state=open&sort=due_on&direction=asc&per_page=20")
    if not isinstance(ms, list):
        return None
    for m in ms:
        if not isinstance(m, dict) or not PUBTEXT_RE.match(str(m.get("title") or "")):
            continue
        due = str(m.get("due_on") or "")[:10]
        return {"title": m["title"], "open": _int(m.get("open_issues")), "closed": _int(m.get("closed_issues")),
                "due": due if DATE_RE.match(due) else None}
    return None


def demo_tags(git: Callable, wt: Path) -> List[dict]:
    """Rick's demo-day markers: git tags named demo*, with the date each was
    made. Tags are repo-wide refs, so the publisher's worktree sees them."""
    try:
        proc = git(wt, "tag", "-l", "demo*", "--format=%(creatordate:short)|%(refname:short)", check=False)
    except (OSError, subprocess.SubprocessError, PublishError):
        return []
    tags = []
    for line in (proc.stdout or "").splitlines() if proc.returncode == 0 else []:
        date, _, name = line.strip().partition("|")
        if DATE_RE.match(date) and TAGNAME_RE.match(name):
            tags.append({"date": date, "name": name})
    return sorted(tags, key=lambda t: (t["date"], t["name"]))


class SummaryBuilder:
    """build(metrics_dir) -> the summary_latest.json object; daily_rows() ->
    today's github_daily.jsonl row (a one-row list), or None when gh failed.
    The GitHub part is fetched once and reused across push retries; the nightly
    part is re-read from metrics_dir each time (it is what the fetch just
    brought in)."""

    def __init__(self, *, gh: Optional[Callable[..., Optional[str]]] = None, git: Optional[Callable] = None,
                 now: Optional[datetime] = None, pbxproj: Path = PBXPROJ, repo: str = GITHUB_REPO):
        self.gh = gh or Gh()
        self.git = git or Git()
        self.when = now or datetime.now(timezone.utc)
        self.pbxproj = pbxproj
        self.repo = repo
        self._cached: Dict[str, object] = {}

    def _github(self) -> Dict[str, object]:
        if not self._cached:
            self._cached["numbers"] = github_numbers(self.gh, self.when, self.repo)
            self._cached["sprint"] = sprint_summary(self.gh, self.repo)
            self._cached["version"] = app_version(self.pbxproj)
        return self._cached

    def __call__(self, metrics_dir: Path) -> dict:
        c = self._github()
        td_rows = _read_jsonl(Path(metrics_dir) / "testdriver.jsonl")
        return {
            "schemaVersion": SCHEMA_VERSION,
            "generated": self.when.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "version": c["version"],
            "github": summary_github(c["numbers"]),
            "sprint": c["sprint"],
            "tags": demo_tags(self.git, Path(metrics_dir).parent),
            "person": person_summary(td_rows),
            "nightly": nightly_summary(td_rows, self.when.strftime("%Y-%m-%d")),
        }

    def daily_rows(self) -> Optional[List[dict]]:
        row = github_daily_row(self._github()["numbers"], self.when)
        return None if row is None else [row]


def summary_builder(**kwargs) -> SummaryBuilder:
    """See SummaryBuilder; kept as the factory the CLI and tests call."""
    return SummaryBuilder(**kwargs)


# ---------------------------------------------------------------- merge + render

def _day_key(row: dict) -> Optional[str]:
    """The UTC day a row belongs to: its `date`, or the date part of its `ts`
    (the github_daily stream carries a timestamp, one row per day)."""
    if isinstance(row.get("date"), str):
        return row["date"]
    ts = row.get("ts")
    return ts[:10] if isinstance(ts, str) and TS_RE.match(ts) else None


def merge_rows(existing: List[dict], fresh: List[dict]) -> List[dict]:
    """Union keyed by day; a fresh row replaces the published row for its day.
    Days only on the branch (e.g. a coverage JSON since deleted locally) are kept."""
    by_date = {}
    for row in existing:
        key = _day_key(row)
        if key is not None:
            by_date[key] = row
    for row in fresh:
        by_date[_day_key(row)] = row      # a key-less fresh row fails the gate right after
    return [by_date[d] for d in sorted(by_date, key=str)]


def render(rows: List[dict]) -> str:
    return "".join(json.dumps(r, sort_keys=True, separators=(",", ":")) + "\n" for r in rows)


def _published_folders(rows: List[dict]) -> set:
    """Every coverage folder name the rows already on the branch carry."""
    return {f["folder"] for r in rows for f in (r.get("folders") or [])
            if isinstance(f, dict) and isinstance(f.get("folder"), str) and FOLDER_RE.match(f["folder"])}


def sanitized_files(fresh: Dict[str, Optional[List[dict]]], existing_dir: Optional[Path],
                    folders: Optional[set]) -> Dict[str, str]:
    """name -> full file text, merged with what is already published, every row
    validated. Raises PrivacyError before anything is written."""
    out = {}
    for name, rows in fresh.items():
        if rows is None:
            continue
        if name in SINGLE_OBJECT:
            validate(name, rows, folders)
            out[name] = json.dumps(rows, sort_keys=True, separators=(",", ":")) + "\n"
            continue
        existing = _read_jsonl(existing_dir / name) if existing_dir is not None else []
        if name in APPEND_ONLY:
            for row in rows:
                validate(name, row, folders)
            seen = {(r.get("ts"), r.get("sha")) for r in existing}
            merged = existing + [r for r in rows if (r["ts"], r["sha"]) not in seen]
            merged.sort(key=lambda r: str(r.get("ts", "")))
            out[name] = render(merged)
            continue
        merged = merge_rows(existing, rows)
        # A folder named by a row ALREADY on the branch passed this gate when it
        # was published; a source folder deleted since (FamilyMusic, 10/19) must
        # not wedge every later publish. New names still have to exist today.
        allowed = None if folders is None else folders | _published_folders(existing)
        for row in merged:
            validate(name, row, allowed)
        out[name] = render(merged)
    return out


# ---------------------------------------------------------------- git (seam)

class Git:
    """`git -C <path> <args>`; the test suite swaps in a fake. Returns stdout;
    raises PublishError on a non-zero exit unless check=False."""

    def __call__(self, path: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess:
        proc = subprocess.run(["git", "-C", str(path), *args], capture_output=True, text=True,
                              stdin=subprocess.DEVNULL, timeout=180)
        if check and proc.returncode != 0:
            raise PublishError(f"git {' '.join(args[:2])} failed ({proc.returncode}): {proc.stderr.strip()[:300]}")
        return proc


def ensure_worktree(repo: Path, wt: Path, git: Git) -> None:
    """Create (once) and verify the publisher's own detached worktree.
    The only commands ever sent to `repo` are `worktree prune` and `worktree add`."""
    repo, wt = repo.resolve(), wt.expanduser().resolve()
    if wt == repo or wt in repo.parents:
        raise PublishError(f"refusing: worktree path {wt} is the main checkout or contains it")
    if not (wt / ".git").exists():
        if wt.exists() and any(wt.iterdir()):
            raise PublishError(f"refusing: {wt} exists, is not a worktree and is not empty")
        wt.parent.mkdir(parents=True, exist_ok=True)
        git(repo, "worktree", "prune")
        git(repo, "worktree", "add", "--detach", "--no-checkout", str(wt))
    top = Path(git(wt, "rev-parse", "--show-toplevel").stdout.strip()).resolve()
    if top != wt:
        raise PublishError(f"refusing: {wt} resolves to checkout {top}")
    git_dir = git(wt, "rev-parse", "--absolute-git-dir").stdout.strip()
    common = git(wt, "rev-parse", "--path-format=absolute", "--git-common-dir").stdout.strip()
    if Path(git_dir).resolve() == Path(common).resolve():
        raise PublishError(f"refusing: {wt} is a main checkout, not a linked worktree")


def publish(fresh: Dict[str, Optional[List[dict]]], *, repo: Path = REPO, wt: Path = DEFAULT_WT,
            git: Optional[Git] = None, folders: Optional[set] = None,
            say: Callable[[str], None] = print,
            summary: Optional[Callable[[Path], dict]] = None,
            daily: Optional[Callable[[], Optional[List[dict]]]] = None) -> str:
    """Merge, validate, commit and push. Returns "pushed" or "unchanged".
    `summary(metrics_dir)` (see SummaryBuilder) runs after each fetch, so the
    nights it summarizes are the ones just pulled from the branch. `daily()`
    (SummaryBuilder.daily_rows) is today's github_daily.jsonl row, or None to
    leave that stream exactly as published."""
    git = git or Git()
    wt = wt.expanduser().resolve()
    ensure_worktree(repo, wt, git)
    for attempt in range(1, PUSH_ATTEMPTS + 1):
        git(wt, "fetch", "--quiet", "origin", FETCH_SPEC)
        git(wt, "reset", "--hard", "--quiet", REMOTE_REF)
        if summary is not None:
            fresh = dict(fresh, **{"summary_latest.json": summary(wt / "metrics")})
        if daily is not None:
            fresh = dict(fresh, **{"github_daily.jsonl": daily()})
        files = sanitized_files(fresh, wt / "metrics", folders)   # PrivacyError stops here
        changed = []
        for name, text in files.items():
            path = wt / "metrics" / name
            old = path.read_text() if path.is_file() else None
            if old != text:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text)
                changed.append("metrics/" + name)
        if not changed:
            return "unchanged"
        git(wt, "add", "--", *changed)
        git(wt, "-c", "user.name=Metrics Publisher", "-c", "user.email=metrics@videoscan",
            "commit", "--quiet", "-m", "metrics: publish " + ", ".join(sorted(changed)))
        if git(wt, "push", "--quiet", "origin", PUSH_SPEC, check=False).returncode == 0:
            say(f"pushed {', '.join(changed)} (attempt {attempt})")
            return "pushed"
        say(f"push attempt {attempt}/{PUSH_ATTEMPTS} rejected; refetching and retrying")
    raise PublishError(f"push rejected {PUSH_ATTEMPTS} times")


# ---------------------------------------------------------------- CLI

def validate_file(stream: str, path: str, folders: Optional[set] = None) -> int:
    """The privacy gate for a file the GitHub nightly produced (exposure,
    problem files): every row must be exactly its allowlisted shape. Prints
    one OUTCOME line; 0 = publishable, 3 = refused, 1 = unreadable."""
    try:
        text = Path(path).read_text()
        rows = ([json.loads(line) for line in text.splitlines() if line.strip()]
                if stream.endswith(".jsonl") else [json.loads(text)])
    except (OSError, ValueError) as exc:
        print(f"OUTCOME failed: cannot read {stream}: {exc}")
        return 1
    try:
        for row in rows:
            validate(stream, row, folders if folders is not None else source_folders())
    except PrivacyError as exc:
        print(f"OUTCOME failed: privacy gate refused {stream}: {exc}")
        return 3
    print(f"OUTCOME ok: {stream} validated ({len(rows)} row(s))")
    return 0


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--dry-run", action="store_true", help="print sanitized rows; no git, no writes")
    ap.add_argument("--out-dir", help="write sanitized files into this directory; no git")
    ap.add_argument("--worktree", default=str(DEFAULT_WT))
    ap.add_argument("--coverage-dir", default=str(COVERAGE_DIR))
    ap.add_argument("--adversarial-dir", default=str(ADV_DIR))
    ap.add_argument("--codex-dir", default=str(CODEX_DIR))
    ap.add_argument("--validate", nargs=2, metavar=("STREAM", "FILE"),
                    help="privacy-gate one CI-produced file (JSON, or JSONL when STREAM ends in .jsonl) "
                         "against SCHEMAS[STREAM]; exit 0 if it may be published, 3 if not")
    ap.add_argument("--no-summary", action="store_true",
                    help="do not rebuild metrics/summary_latest.json (GH #310 summary view)")
    ap.add_argument("--metrics-dir", help="with --dry-run / --out-dir: build the summary from the "
                                          "published streams in this directory (e.g. the publish "
                                          "worktree's metrics/); without it no summary is produced")
    ap.add_argument("--no-events", action="store_true",
                    help="do not run scripts/events_prototype.py for metrics/events_latest.json")
    ap.add_argument("--events-script", default=str(EVENTS_SCRIPT),
                    help="the script whose --stats-json output becomes metrics/events_latest.json")
    a = ap.parse_args(argv)

    if a.validate:
        return validate_file(*a.validate)

    if os.environ.get("VIDEOSCAN_PUBLISH_METRICS") == "0":
        print("OUTCOME skipped: VIDEOSCAN_PUBLISH_METRICS=0")
        return 0
    fresh = build_streams(Path(a.coverage_dir).expanduser(), Path(a.adversarial_dir).expanduser(),
                          Path(a.codex_dir).expanduser())
    fresh["events_latest.json"] = None if a.no_events else events_stats(script=Path(a.events_script).expanduser())
    summary = None if a.no_summary else summary_builder()
    folders = source_folders()
    try:
        if a.dry_run or a.out_dir:
            if summary is not None and a.metrics_dir:
                fresh["summary_latest.json"] = summary(Path(a.metrics_dir).expanduser())
                fresh["github_daily.jsonl"] = summary.daily_rows()
            available = sorted(k for k, v in fresh.items() if v is not None)
            files = sanitized_files(fresh, None, folders)
            if a.out_dir:
                out = Path(a.out_dir).expanduser()
                out.mkdir(parents=True, exist_ok=True)
                for name, text in files.items():
                    (out / name).write_text(text)
            else:
                for name, text in files.items():
                    print(f"--- metrics/{name}")
                    sys.stdout.write(text)
            print(f"OUTCOME ok: dry run, {len(files)} stream(s) validated: {', '.join(available) or 'none'}")
            return 0
        result = publish(fresh, wt=Path(a.worktree), folders=folders, summary=summary,
                         daily=None if summary is None else summary.daily_rows)
        available = sorted(k for k, v in fresh.items() if v is not None) + ([] if summary is None else ["summary_latest.json"])
        if summary is not None and summary.daily_rows() is not None:
            available.append("github_daily.jsonl")
    except PrivacyError as exc:
        print(f"OUTCOME failed: privacy gate refused the publish: {exc}")
        return 3
    except (PublishError, OSError, subprocess.SubprocessError) as exc:
        print(f"OUTCOME failed: {exc}")
        return 1
    print(f"OUTCOME ok: {result}; streams {', '.join(available) or 'none'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
