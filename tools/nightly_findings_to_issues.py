#!/usr/bin/env python3
"""Nightly static-analysis findings -> ONE nightly ticket + high tracking issues.

Runs as the last analysis job of .github/workflows/nightly-analysis.yml. It
reads the artifacts every analysis job uploaded, gives each finding a stable
fingerprint, and plans (and, when writes are enabled, applies) the issue
changes.

Inputs: the actions/download-artifact layout, one directory per artifact.
  codeql-results/*.sarif                    CodeQL (security-and-quality)
  strict-concurrency-log/all-warnings.txt   swiftc strict concurrency warnings
  strict-concurrency-log/memory-safety-findings.txt
                                            swiftc -strict-memory-safety
                                            (SE-0458), its own build
  tsan-log/*.log                            Thread Sanitizer
  sanitizer-address/*.log                   Address Sanitizer
  sanitizer-undefined/*.log                 Undefined Behavior Sanitizer
  lint-strict/periphery-strict.txt          Periphery (dead code)
Any directory may also hold `nightly-status-<tool>.json` containing
{"complete": bool}. A tool counts as COMPLETE tonight only when its input
parsed, its status file (if any) says complete, and its job result (given
with --job-result) is "success". An incomplete tool never advances the
"gone for N nights" counter, never reports anything as FIXED, and carries
its previous state forward. Without that rule, a CodeQL build that broke
would look like every CodeQL finding being fixed.

Fingerprint = sha256(tool, rule, repo-relative file, normalised message),
with no line numbers anywhere, so a finding keeps its identity when code moves.

Severity (Manager 2026-10-01, amended by Rick 2026-10-02):
  high    CodeQL security-tagged or error-level, data races (compiler
          "data race" warnings), TSan, ASan, UBSan
  medium  CodeQL warning-level
  low     everything else: Periphery dead code, strict-memory-safety
          `unsafe` markers, non-race strict-concurrency / upcoming-feature
          warnings, CodeQL note-level

Issue policy (Rick, 2026-10-02: "organized in such a way as we won't ignore
the issues" -- a mix, biased to one ticket):

  1. ONE "Nightly findings — YYYY-MM-DD" ticket per night (label
     `nightly-findings`). Sections, ordered for action:
       🔴 NEW high · NEW medium · CHANGED · FIXED since last night ·
       Still open (counts per tool and severity + the 10 oldest) ·
       Low severity (per-tool counts and deltas, top 5 new per tool only)
     Every item carries its fingerprint, file, rule and the run link.
     Yesterday's ticket is closed with a link to tonight's, so only ONE is
     open -- EXCEPT a ticket a human commented on in the last 48 h, which is
     left open and linked from tonight's ticket instead. A rerun the same
     night edits the same ticket (it is found by the date in its marker).
     "NEW" and "FIXED" are measured against the most recent EARLIER ticket,
     so a rerun reports the same thing as the first run.

  2. Separate TRACKING issues, HIGH severity only (label nightly-finding +
     tool + High Priority), ONE PER (tool, rule, file) -- coordinator
     2026-10-02: four cleartext-logging hits in one file are one issue. Each
     issue lists its instances with their fingerprints. At most --cap (3)
     opened or reopened per night; issues already opened today count against
     the cap, so a rerun opens nothing more. The rest wait, listed in the
     ticket as "queued". Lifecycle:
       * an instance appears, disappears or changes -> one CHANGED comment
       * zero instances for 3 complete nights       -> close with a comment
       * an instance comes back after auto-close    -> reopen with a comment
       * `wontfix` label, or closed as "not planned" -> never touched again
     The ticket still lists every instance individually.
     Medium findings live in the ticket only. A tracking issue holds only
     HIGH instances: one that drops to medium leaves the issue (CHANGED), and
     an issue with no high instance left counts clean nights and closes.

  3. Vendored / third-party code (SwiftPM checkouts, mlx-swift, Pods,
     anything outside the repo) is counted in ONE line of the ticket and
     never filed.

  4. The morning brief (scripts/nightly_findings_alert.py) prints a 🔴 line
     for any NEW high or medium finding and a ⚠️ line for any high tracking
     issue more than 7 days old, both with the ticket URL.

The 2026-10-01 overflow digest and per-tool low digests are retired: an open
one is closed with a pointer to the ticket.

WRITES are gated by the workflow: it passes --dry-run unless the repo
variable NIGHTLY_FINDINGS_WRITE is 'true' (Rick approved writes 2026-10-02;
the Manager sets the variable). A dry run still reads the real issues and
records the full plan, ticket body included, in the summary JSON and the
--plan-out markdown.

State lives in the issues themselves, in a hidden JSON marker at the top of
each body, so there is no second database to drift. The ticket marker is
bounded (MARKER_BUDGET); past that it degrades in a documented order (see
fit_state) instead of overflowing GitHub's 65,536-character body limit.

A finding never makes this script fail. It exits non-zero only when the
pipeline is broken: an unreadable input, or a `gh` call that failed.

Usage (CI):
  python3 tools/nightly_findings_to_issues.py --artifacts artifacts \
      --repo "$GITHUB_REPOSITORY" --run-url "$RUN_URL" \
      --job-result codeql=success --job-result strict-concurrency=failure ... \
      --summary-out nightly-findings-summary.json --plan-out nightly-findings-plan.md \
      [--dry-run]

Stdlib only, plus the `gh` CLI. Every gh call goes through the GhCli seam,
so the tests drive a fake and never touch the network.
"""
from __future__ import annotations

import argparse
import dataclasses
import datetime as _dt
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Callable, Iterable

# --------------------------------------------------------------------------
# Constants
# --------------------------------------------------------------------------

BASE_LABEL = "nightly-finding"        # high tracking issues
TICKET_LABEL = "nightly-findings"     # the one nightly ticket
DIGEST_LABEL = "nightly-digest"       # retired 2026-10-02 (overflow / low digests)
HIGH_LABEL = "High Priority"
WONTFIX_LABEL = "wontfix"
CLOSE_AFTER_NIGHTS = 3
DEFAULT_CAP = 3
TRACKED_SEVERITIES = ("high",)
HUMAN_GUARD_HOURS = 48
LOW_NEW_SHOWN = 5
OLDEST_SHOWN = 10
SECTION_MAX = 50
BOT_COMMENT_TAG = "<!-- nightly-findings-bot -->"
BOT_LOGINS = {"github-actions", "github-actions[bot]", "app/github-actions"}

MARKER_RE = re.compile(r"<!--\s*nightly-finding\s+(\{.*?\})\s*-->", re.S)
DIGEST_MARKER_RE = re.compile(r"<!--\s*nightly-findings-digest\s+(\{.*?\})\s*-->", re.S)
LOW_DIGEST_MARKER_RE = re.compile(r"<!--\s*nightly-low-digest\s+(\{.*?\})\s*-->", re.S)
TICKET_MARKER_RE = re.compile(r"<!--\s*nightly-findings-ticket\s+(\{.*?\})\s*-->", re.S)

TOOLS = ("codeql", "strict-concurrency", "memory-safety", "tsan", "asan", "ubsan", "periphery")
SEVERITY_RANK = {"high": 0, "medium": 1, "low": 2}
LABEL_COLORS = {
    BASE_LABEL: ("5319e7", "High-severity finding tracked to closure (tools/nightly_findings_to_issues.py)"),
    TICKET_LABEL: ("0052cc", "The nightly findings ticket (one open at a time)"),
    "codeql": ("1d76db", "CodeQL finding"),
    "strict-concurrency": ("0e8a16", "Swift strict concurrency warning"),
    "memory-safety": ("fbca04", "Swift strict memory safety (SE-0458) warning"),
    "tsan": ("b60205", "Thread Sanitizer report"),
    "asan": ("b60205", "Address Sanitizer report"),
    "ubsan": ("d93f0b", "Undefined Behavior Sanitizer report"),
    "periphery": ("c2e0c6", "Periphery dead-code finding"),
}

# --------------------------------------------------------------------------
# Data model
# --------------------------------------------------------------------------


@dataclasses.dataclass
class Finding:
    """One raw occurrence, as a parser saw it."""
    tool: str
    rule: str
    file: str
    line: int | None
    message: str
    severity: str


@dataclasses.dataclass
class FindingGroup:
    """All occurrences that share a fingerprint."""
    fp: str
    tool: str
    rule: str
    file: str
    message: str           # representative (first) raw message
    severity: str          # highest severity among occurrences
    occurrences: list[Finding]

    @property
    def count(self) -> int:
        return len(self.occurrences)

    @property
    def detail_digest(self) -> str:
        """What 'changed' means: severity, occurrence count, the set of detail
        messages. Line numbers are excluded, so moved code is not a change."""
        details = sorted({normalise_detail(o.message) for o in self.occurrences})
        blob = json.dumps([self.severity, self.count, details], sort_keys=True)
        return hashlib.sha256(blob.encode()).hexdigest()[:16]


@dataclasses.dataclass
class Issue:
    number: int
    title: str
    state: str                     # OPEN / CLOSED
    state_reason: str | None       # COMPLETED / NOT_PLANNED / REOPENED / None
    labels: list[str]
    body: str
    comments: list[dict] = dataclasses.field(default_factory=list)   # gh --json comments

    @property
    def marker(self) -> dict | None:
        return _marker(MARKER_RE, self.body)

    @property
    def ticket_marker(self) -> dict | None:
        return _marker(TICKET_MARKER_RE, self.body)

    @property
    def is_open(self) -> bool:
        return self.state.upper() == "OPEN"

    @property
    def is_wontfix(self) -> bool:
        if WONTFIX_LABEL in self.labels:
            return True
        return (not self.is_open) and (self.state_reason or "").upper() == "NOT_PLANNED"


def _marker(regex: re.Pattern, body: str | None) -> dict | None:
    m = regex.search(body or "")
    if not m:
        return None
    try:
        return json.loads(m.group(1))
    except json.JSONDecodeError:
        return None


# --------------------------------------------------------------------------
# Normalisation and fingerprints
# --------------------------------------------------------------------------

_RUNNER_PREFIX = re.compile(r"^/Users/runner/work/[^/]+/[^/]+/")


def relativise(path: str, workspace: str | None = None) -> str:
    """Absolute runner path -> repo-relative path. Leaves non-repo paths alone."""
    if path.startswith("file://"):
        path = path[len("file://"):]
    if workspace:
        ws = workspace.rstrip("/") + "/"
        if path.startswith(ws):
            return path[len(ws):]
    m = _RUNNER_PREFIX.match(path)
    if m:
        return path[m.end():]
    return path.removeprefix("./")


_GROUP_SUFFIX = re.compile(r"\s*\[#[A-Za-z0-9_]+\]\s*$")
_SARIF_LINK = re.compile(r"\[([^\]]*)\]\((?:\d+|[a-z]+://[^)]*)\)")
_HEX = re.compile(r"0x[0-9a-fA-F]+")
_PID = re.compile(r"\(pid=\d+\)")
_LINECOL = re.compile(r"(\.[A-Za-z0-9]+):\d+(?::\d+)?")
_ABS_PATH = re.compile(r"/Users/runner/work/[^/\s]+/[^/\s]+/")
_DIGITS = re.compile(r"\d+")
_WS = re.compile(r"\s+")


def normalise_detail(message: str) -> str:
    """Remove what changes without the finding changing: line numbers,
    addresses, pids, runner paths, diagnostic-group suffixes."""
    s = _GROUP_SUFFIX.sub("", message or "")
    s = _SARIF_LINK.sub(r"\1", s)
    s = _ABS_PATH.sub("", s)
    s = _HEX.sub("0x#", s)
    s = _PID.sub("", s)
    s = _LINECOL.sub(r"\1", s)
    return _WS.sub(" ", s).strip()


def normalise_key(message: str) -> str:
    """normalise_detail plus every digit run -> '#'. Use this for identity.
    It also absorbs timings ("took 113ms"), sizes and closure numbering."""
    return _DIGITS.sub("#", normalise_detail(message))


def fingerprint(tool: str, rule: str, file: str, message: str) -> str:
    blob = "\x1f".join([tool, rule, file, normalise_key(message)])
    return hashlib.sha256(blob.encode()).hexdigest()[:16]


def group_findings(findings: Iterable[Finding]) -> dict[str, FindingGroup]:
    groups: dict[str, FindingGroup] = {}
    for f in findings:
        fp = fingerprint(f.tool, f.rule, f.file, f.message)
        g = groups.get(fp)
        if g is None:
            groups[fp] = FindingGroup(fp, f.tool, f.rule, f.file, f.message, f.severity, [f])
        else:
            g.occurrences.append(f)
            if SEVERITY_RANK[f.severity] < SEVERITY_RANK[g.severity]:
                g.severity = f.severity
    return groups


# --------------------------------------------------------------------------
# Vendored / third-party code
# --------------------------------------------------------------------------

# A path segment that marks code we did not write. Matched against the
# repo-relative path, so "DerivedData/SourcePackages/checkouts/mlx-swift/..."
# (the sanitizer job's derived data inside the workspace) is caught.
_VENDORED = re.compile(
    r"(^|/)(SourcePackages/checkouts|\.build/checkouts|checkouts|Carthage|Pods|node_modules"
    r"|third[_-]?party|ThirdParty|[Vv]endor(ed)?)/"
    r"|(^|/)mlx-swift(/|$)|(^|/)Cmlx(/|$)")
# Module-only sanitizer frames, e.g. "<libmlx.dylib>". System frames such as
# <libswiftCore.dylib> are NOT vendored: a race that surfaces in swift_retain
# is almost always our own code racing on a reference.
_VENDORED_MODULE = re.compile(r"^<(lib)?(mlx|Cmlx)[^>]*>$", re.I)


def is_vendored(path: str) -> bool:
    """True for third-party code: dependency checkouts, vendored trees, and any
    absolute path (relativise() leaves only paths OUTSIDE the repo absolute)."""
    if not path or path == "?":
        return False
    if path.startswith("<"):
        return bool(_VENDORED_MODULE.match(path))
    if path.startswith("/"):
        return True
    return bool(_VENDORED.search(path))


def vendored_root(path: str) -> str:
    """Short label for the one-line vendored report, e.g. "mlx-swift"."""
    m = re.search(r"checkouts/([^/]+)", path)
    if m:
        return m.group(1)
    if "mlx-swift" in path:
        return "mlx-swift"
    return path.split("/", 2)[1] if path.startswith("/") and path.count("/") > 1 else path.split("/", 1)[0]


def split_vendored(groups: dict[str, FindingGroup]) -> tuple[dict[str, FindingGroup], list[FindingGroup]]:
    ours: dict[str, FindingGroup] = {}
    vendored: list[FindingGroup] = []
    for fp, g in groups.items():
        if is_vendored(g.file):
            vendored.append(g)
        else:
            ours[fp] = g
    return ours, vendored


# --------------------------------------------------------------------------
# Parsers, one per tool
# --------------------------------------------------------------------------


def parse_sarif(path: Path) -> list[Finding]:
    """CodeQL SARIF. High = security-tagged rule or level error; warning =
    medium; note/none = low."""
    doc = json.loads(path.read_text(encoding="utf-8"))
    out: list[Finding] = []
    for run in doc.get("runs") or []:
        rules: dict[str, dict] = {}
        driver = (run.get("tool") or {}).get("driver") or {}
        for comp in [driver] + list((run.get("tool") or {}).get("extensions") or []):
            for r in comp.get("rules") or []:
                if r.get("id"):
                    rules[r["id"]] = r
        for res in run.get("results") or []:
            rule_id = res.get("ruleId") or (res.get("rule") or {}).get("id") or "?"
            meta = rules.get(rule_id, {})
            props = meta.get("properties") or {}
            tags = [str(t).lower() for t in props.get("tags") or []]
            level = (res.get("level")
                     or (meta.get("defaultConfiguration") or {}).get("level")
                     or "warning").lower()
            if "security" in tags or "security-severity" in props or level == "error":
                sev = "high"
            elif level == "warning":
                sev = "medium"
            else:
                sev = "low"
            uri, line = "?", None
            for loc in res.get("locations") or []:
                pl = loc.get("physicalLocation") or {}
                uri = relativise((pl.get("artifactLocation") or {}).get("uri") or "?")
                line = (pl.get("region") or {}).get("startLine")
                break
            msg = (res.get("message") or {}).get("text") or rule_id
            out.append(Finding("codeql", rule_id, uri, line, msg, sev))
    return out


_COMPILER_LINE = re.compile(
    r"^(?P<path>/[^:]+?\.swift):(?P<line>\d+):(?P<col>\d+): warning: (?P<msg>.+)$")
_PERF = re.compile(r"took \d+ms to type-check")
_MEMSAFE = re.compile(
    r"\[#StrictMemorySafety\]|unsafe constructs|involves unsafe|not marked with 'unsafe'"
    r"|'@unsafe'|@unsafe\b|unsafe (type|conformance|declaration)", re.I)
_CONCURRENCY = re.compile(
    r"sendable|data race|actor-isolated|concurrency|main actor|nonisolated|@Sendable"
    r"|concurrently-executing", re.I)


def classify_compiler_warning(msg: str) -> tuple[str, str] | None:
    """(rule, severity) for a strict-build warning, or None to skip it.

    Type-check timing warnings are skipped. They jitter around the 100 ms
    line from night to night, and scripts/typecheck_timing_ratchet.py already
    owns them, with identity keys and a gate.
    """
    if _PERF.search(msg):
        return None
    if _MEMSAFE.search(msg):
        # SE-0458 flags every unsafe construct not ACKNOWLEDGED with
        # `unsafe` (1,590 sites on 2026-10-01): annotation debt, not a
        # demonstrated memory error. ASan finds real ones, and it is high.
        return "memory-safety", "low"
    if _CONCURRENCY.search(msg):
        # Only a warning that names a data race is high. The rest are
        # Swift 6 migration warnings (isolation, Sendable) - low.
        return "concurrency", ("high" if "data race" in msg.lower() else "low")
    return "upcoming-feature-or-other", "low"


def parse_compiler_warnings(path: Path, workspace: str | None,
                            tool: str = "strict-concurrency") -> list[Finding]:
    """`tool` = "memory-safety" keeps only SE-0458 lines, from the separate
    -strict-memory-safety build. "strict-concurrency" drops them, so a
    memory-safety line never lives under two tools."""
    out: list[Finding] = []
    seen: set[str] = set()
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        m = _COMPILER_LINE.match(raw.strip())
        if not m or raw in seen:
            continue
        seen.add(raw)
        cls = classify_compiler_warning(m.group("msg"))
        if cls is None:
            continue
        rule, sev = cls
        if (rule == "memory-safety") != (tool == "memory-safety"):
            continue
        out.append(Finding(tool, rule, relativise(m.group("path"), workspace),
                           int(m.group("line")), m.group("msg"), sev))
    return out


_PERIPHERY_LINE = re.compile(
    r"^(?P<path>/[^:]+?):(?P<line>\d+):(?P<col>\d+): warning: (?P<msg>.+)$")


def parse_periphery(path: Path, workspace: str | None) -> list[Finding]:
    out: list[Finding] = []
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        m = _PERIPHERY_LINE.match(raw.strip())
        if not m:
            continue
        msg = m.group("msg")
        rule = re.sub(r"'[^']*'", "'…'", msg)          # "Unused function '…'"
        out.append(Finding("periphery", rule, relativise(m.group("path"), workspace),
                           int(m.group("line")), msg, "low"))
    return out


_SAN_SUMMARY = re.compile(
    r"SUMMARY: (?P<san>AddressSanitizer|ThreadSanitizer|UndefinedBehaviorSanitizer): (?P<rest>.+)$")
_SAN_LOC = re.compile(r"^(?P<kind>.+?) (?P<loc>/\S+|\([^)]*\))(?: in (?P<func>.+))?$")
_UBSAN_LINE = re.compile(
    r"(?P<path>/[^\s:]+):(?P<line>\d+):(?P<col>\d+): runtime error: (?P<msg>.+)$")
_SAN_TOOL = {"AddressSanitizer": "asan", "ThreadSanitizer": "tsan",
             "UndefinedBehaviorSanitizer": "ubsan"}
# Rick 2026-10-02: every sanitizer hit in our own code is tracked to closure.
_SAN_SEVERITY = {"asan": "high", "tsan": "high", "ubsan": "high"}


def _san_location(loc: str, workspace: str | None) -> tuple[str, int | None]:
    if loc.startswith("("):
        # "(libfoo.dylib:arm64e+0x1234)": module only, no source line.
        module = loc.strip("()").split(":", 1)[0].split("+", 1)[0]
        return f"<{Path(module).name}>", None
    m = re.match(r"^(?P<p>.+?)(?::(?P<l>\d+))?(?::\d+)?$", loc)
    p = m.group("p") if m else loc
    line = int(m.group("l")) if m and m.group("l") else None
    return relativise(p, workspace), line


def parse_sanitizer_log(path: Path, tool: str, workspace: str | None) -> list[Finding]:
    """ASan/TSan: one finding per SUMMARY line. UBSan: one per `runtime error:`
    line, because UBSan does not always print a SUMMARY."""
    out: list[Finding] = []
    seen: set[str] = set()
    sev = _SAN_SEVERITY[tool]
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if tool == "ubsan":
            m = _UBSAN_LINE.search(raw)
            if not m:
                continue
            key = normalise_detail(raw)
            if key in seen:
                continue
            seen.add(key)
            msg = m.group("msg").strip()
            rule = normalise_key(re.split(r"[:,]", msg, maxsplit=1)[0])
            out.append(Finding(tool, rule, relativise(m.group("path"), workspace),
                               int(m.group("line")), msg, sev))
            continue
        m = _SAN_SUMMARY.search(raw)
        if not m or _SAN_TOOL[m.group("san")] != tool:
            continue
        rest = m.group("rest").strip()
        lm = _SAN_LOC.match(rest)
        if lm:
            kind = lm.group("kind").strip()
            file, line = _san_location(lm.group("loc"), workspace)
            func = (lm.group("func") or "").strip()
        else:
            kind, file, line, func = rest, "?", None, ""
        msg = f"{kind} in {func}" if func else kind
        out.append(Finding(tool, kind, file, line, msg, sev))
    return out


# --------------------------------------------------------------------------
# Collecting every tool's input from the artifacts tree
# --------------------------------------------------------------------------


@dataclasses.dataclass
class ToolRun:
    tool: str
    input_found: bool = False
    complete: bool = False
    findings: list[Finding] = dataclasses.field(default_factory=list)
    notes: list[str] = dataclasses.field(default_factory=list)
    job: str | None = None         # the job result passed with --job-result, if any

    @property
    def is_disabled(self) -> bool:
        """The job never ran (disabled with `if: false`, or skipped): no
        artifact and no failure. Still incomplete, just not alarming."""
        return not self.input_found and self.job in (None, "skipped")


def _status_complete(artifacts: Path, tool: str) -> bool | None:
    for p in artifacts.rglob(f"nightly-status-{tool}.json"):
        try:
            return bool(json.loads(p.read_text()).get("complete"))
        except (OSError, json.JSONDecodeError):
            return False
    return None


def collect(artifacts: Path, job_results: dict[str, str], workspace: str | None) -> dict[str, ToolRun]:
    runs = {t: ToolRun(t) for t in TOOLS}

    def files(sub: str, pattern: str) -> list[Path]:
        # Top level only: download-artifact puts each uploaded file at
        # <artifacts>/<artifact-name>/<file>, and an uploaded .xcresult bundle
        # holds its own *.log files that are not sanitizer output.
        d = artifacts / sub
        return sorted(p for p in d.glob(pattern) if p.is_file()) if d.is_dir() else []

    sources: dict[str, tuple[list[Path], Callable[[Path], list[Finding]]]] = {
        "codeql": (files("codeql-results", "*.sarif"), parse_sarif),
        "strict-concurrency": (files("strict-concurrency-log", "all-warnings.txt"),
                               lambda p: parse_compiler_warnings(p, workspace)),
        "memory-safety": (files("strict-concurrency-log", "memory-safety-findings.txt"),
                          lambda p: parse_compiler_warnings(p, workspace, "memory-safety")),
        "tsan": (files("tsan-log", "*.log"), lambda p: parse_sanitizer_log(p, "tsan", workspace)),
        "asan": (files("sanitizer-address", "*.log"), lambda p: parse_sanitizer_log(p, "asan", workspace)),
        "ubsan": (files("sanitizer-undefined", "*.log"), lambda p: parse_sanitizer_log(p, "ubsan", workspace)),
        "periphery": (files("lint-strict", "periphery-strict.txt"),
                      lambda p: parse_periphery(p, workspace)),
    }
    for tool, (paths, parser) in sources.items():
        tr = runs[tool]
        tr.job = job_results.get(tool)
        if not paths:
            tr.notes.append("no input artifact")
            continue
        tr.input_found = True
        for p in paths:
            tr.findings.extend(parser(p))   # a parse error propagates: broken pipeline
        status = _status_complete(artifacts, tool)
        job = job_results.get(tool)
        tr.complete = (status is not False) and (job in (None, "success"))
        if status is False:
            tr.notes.append("status file says incomplete")
        if job not in (None, "success"):
            tr.notes.append(f"job result {job}")
    return runs


# --------------------------------------------------------------------------
# GitHub seam
# --------------------------------------------------------------------------


class GhCli:
    """Thin wrapper over the `gh` CLI. Tests substitute FakeGh."""

    def __init__(self, repo: str, runner: Callable[..., subprocess.CompletedProcess] = subprocess.run):
        self.repo = repo
        self._run = runner

    def _gh(self, args: list[str], stdin: str | None = None) -> str:
        proc = self._run(["gh", *args, "--repo", self.repo], input=stdin,
                         capture_output=True, text=True)
        if proc.returncode != 0:
            raise RuntimeError(f"gh {' '.join(args[:3])} failed: {proc.stderr.strip()[:500]}")
        return proc.stdout

    def list_issues(self, label: str, with_comments: bool = False) -> list[Issue]:
        fields = "number,title,state,stateReason,labels,body" + (",comments" if with_comments else "")
        out = self._gh(["issue", "list", "--label", label, "--state", "all", "--limit", "5000",
                        "--json", fields])
        return [Issue(i["number"], i.get("title", ""), i.get("state", "OPEN"),
                      i.get("stateReason"), [lb["name"] for lb in i.get("labels") or []],
                      i.get("body") or "", list(i.get("comments") or []))
                for i in json.loads(out or "[]")]

    def list_labels(self) -> set[str]:
        out = self._gh(["label", "list", "--limit", "500", "--json", "name"])
        return {lb["name"] for lb in json.loads(out or "[]")}

    def create_label(self, name: str, color: str, description: str) -> None:
        self._gh(["label", "create", name, "--color", color, "--description", description])

    def create_issue(self, title: str, body: str, labels: list[str]) -> int:
        args = ["issue", "create", "--title", title, "--body-file", "-"]
        for lb in labels:
            args += ["--label", lb]
        url = self._gh(args, stdin=body).strip().splitlines()[-1]
        return int(url.rstrip("/").rsplit("/", 1)[-1])

    def comment(self, number: int, body: str) -> None:
        self._gh(["issue", "comment", str(number), "--body-file", "-"], stdin=body)

    def edit_body(self, number: int, body: str) -> None:
        self._gh(["issue", "edit", str(number), "--body-file", "-"], stdin=body)

    def add_labels(self, number: int, labels: list[str]) -> None:
        args = ["issue", "edit", str(number)]
        for lb in labels:
            args += ["--add-label", lb]
        self._gh(args)

    def close(self, number: int, comment: str) -> None:
        self._gh(["issue", "close", str(number), "--reason", "completed", "--comment", comment])

    def reopen(self, number: int, comment: str) -> None:
        self._gh(["issue", "reopen", str(number), "--comment", comment])


class DryRunGh:
    """Reads go to the real seam; writes are recorded, never sent."""

    def __init__(self, inner):
        self.inner = inner
        self.writes: list[tuple] = []
        self._next = 900000

    def list_issues(self, label, with_comments=False):
        return self.inner.list_issues(label, with_comments=with_comments)

    def list_labels(self):
        return self.inner.list_labels()

    def _record(self, *w):
        self.writes.append(w)

    def create_label(self, name, color, description):
        self._record("create_label", name)

    def create_issue(self, title, body, labels):
        self._next += 1
        self._record("create_issue", self._next, title, tuple(labels))
        return self._next

    def comment(self, number, body):
        self._record("comment", number)

    def edit_body(self, number, body):
        self._record("edit_body", number)

    def add_labels(self, number, labels):
        self._record("add_labels", number, tuple(labels))

    def close(self, number, comment):
        self._record("close", number)

    def reopen(self, number, comment):
        self._record("reopen", number)


def list_all_issues(gh) -> list[Issue]:
    """Tracking issues + legacy digests (nightly-finding) and tickets
    (nightly-findings, with comments for the human-comment guard)."""
    seen: dict[int, Issue] = {}
    for iss in gh.list_issues(BASE_LABEL):
        seen[iss.number] = iss
    for iss in gh.list_issues(TICKET_LABEL, with_comments=True):
        seen[iss.number] = iss
    return [seen[n] for n in sorted(seen)]


# --------------------------------------------------------------------------
# Tracking issue rendering (high severity)
# --------------------------------------------------------------------------

MAX_INSTANCES_SHOWN = 40
GITHUB_BODY_LIMIT = 65536
TICKET_BODY_BUDGET = 60000      # headroom under GitHub's limit
MARKER_BUDGET = 36000           # the ticket's state marker, at most
HM_FULL_BUDGET = 14000          # full high/medium records inside the marker
DIGEST_FP_CHARS = 8             # 32 bits per fp: ~2,000 entries -> collision odds ~0.05%


def issue_title(g: FindingGroup) -> str:
    """Title for ONE instance (used in the ticket and the summary)."""
    msg = normalise_detail(g.message)
    if len(msg) > 110:
        msg = msg[:107] + "…"
    return f"[nightly/{g.tool}] {Path(g.file).name}: {msg}"[:250]


def group_key(tool: str, rule: str, file: str) -> str:
    """Tracking-issue identity (coordinator 2026-10-02): one issue per
    (tool, rule, file). The instances inside keep their own fingerprints."""
    return hashlib.sha256("\x1f".join([tool, rule, file]).encode()).hexdigest()[:16]


@dataclasses.dataclass
class TrackGroup:
    """Every instance (fingerprint) of one (tool, rule, file)."""
    gk: str
    tool: str
    rule: str
    file: str
    instances: list[FindingGroup]

    @property
    def severity(self) -> str:
        return min((i.severity for i in self.instances), key=lambda s: SEVERITY_RANK[s])

    @property
    def fps(self) -> list[str]:
        return [i.fp for i in self.instances]


def track_groups(groups: dict[str, FindingGroup]) -> dict[str, TrackGroup]:
    """HIGH instances only. strict-concurrency files data races (high) and
    isolation warnings (low) under the same rule, so grouping every severity
    would pull lows into a high issue and keep it open after the race is
    fixed. An instance that drops below high leaves its issue (a CHANGED
    "gone" event); the nightly ticket still lists it."""
    out: dict[str, TrackGroup] = {}
    for g in sorted(groups.values(), key=lambda g: g.fp):
        if g.severity not in TRACKED_SEVERITIES:
            continue
        gk = group_key(g.tool, g.rule, g.file)
        tg = out.get(gk)
        if tg is None:
            out[gk] = TrackGroup(gk, g.tool, g.rule, g.file, [g])
        else:
            tg.instances.append(g)
    return out


def track_title(tg: TrackGroup) -> str:
    """Set once at creation. A one-instance issue reads like the finding; a
    multi-instance one names the rule and the count at creation."""
    if len(tg.instances) == 1:
        return issue_title(tg.instances[0])
    return f"[nightly/{tg.tool}] {Path(tg.file).name}: {tg.rule} ({len(tg.instances)} instances)"[:250]


def render_marker(state: dict) -> str:
    return f"<!-- nightly-finding {json.dumps(state, sort_keys=True)} -->"


def render_body(tg: TrackGroup, state: dict, run_url: str) -> str:
    rows = []
    for g in sorted(tg.instances, key=lambda g: (SEVERITY_RANK[g.severity], g.fp))[:MAX_INSTANCES_SHOWN]:
        lines = sorted({o.line for o in g.occurrences if o.line is not None})
        shown = ", ".join(str(n) for n in lines[:10]) + (" …" if len(lines) > 10 else "")
        rows.append(f"| `{g.fp}` | {g.severity} | {g.count} | {shown or '–'} | "
                    f"{_short(normalise_detail(g.message), 140)} |")
    more = len(tg.instances) - len(rows)
    carried = [fp for fp in (state.get("instances") or {}) if fp not in set(tg.fps)]
    return "\n".join([
        render_marker(state),
        f"**Tool:** `{tg.tool}` · **Rule:** `{tg.rule}` · **Severity:** **{tg.severity}**",
        f"**File:** `{tg.file}` · **Group key:** `{tg.gk}`",
        "",
        f"### Instances ({len(tg.instances)})",
        "",
        "| Fingerprint | Severity | Occurrences | Lines | Detail |",
        "|---|---|---:|---|---|",
        *rows,
        *([f"| … | | | | and {more} more |"] if more > 0 else []),
        *([""] + [f"Carried from the last complete run (tool incomplete tonight): "
                  + ", ".join(f"`{fp}`" for fp in carried)] if carried else []),
        "",
        "Line numbers are informational only. Fingerprints ignore them, so instances follow",
        "the code when it moves. An instance appearing or disappearing is a change, noted below.",
        "",
        f"First seen: {state.get('first_seen', '?')} · Run: {run_url or 'n/a'}",
        "",
        "---",
        "_High-severity tracking issue (one per tool + rule + file), managed by "
        "`tools/nightly_findings_to_issues.py`; the nightly `nightly-findings` ticket lists every "
        f"instance every night. It closes itself after {CLOSE_AFTER_NIGHTS} consecutive complete "
        "nightly runs with zero instances. To silence it for good, add the `wontfix` label (or "
        "close it as not planned)._",
    ])


def with_state(body: str, state: dict) -> str:
    """Replace the marker in an existing body, leaving everything else alone."""
    if MARKER_RE.search(body or ""):
        return MARKER_RE.sub(lambda _m: render_marker(state), body, count=1)
    return render_marker(state) + "\n" + (body or "")


def digest_fp_blob(fps: Iterable[str]) -> str:
    """Compact membership set: sorted 8-hex prefixes, concatenated. 1,700
    findings cost ~14 KB, not ~35 KB of JSON."""
    return "".join(sorted({fp[:DIGEST_FP_CHARS] for fp in fps}))


def blob_to_set(blob: str | None) -> set[str]:
    k = DIGEST_FP_CHARS
    return {blob[i:i + k] for i in range(0, len(blob or ""), k)}


def labels_for(g) -> list[str]:
    """`g`: a FindingGroup or a TrackGroup (anything with .tool and .severity)."""
    labels = [BASE_LABEL, g.tool]
    if g.severity == "high":
        labels.append(HIGH_LABEL)
    return labels


# --------------------------------------------------------------------------
# Planning (pure) and applying (through the seam)
# --------------------------------------------------------------------------


@dataclasses.dataclass
class Action:
    kind: str          # create | reopen | comment | edit | add_label | close |
                       # ticket_create | ticket_edit | ticket_close | legacy_close
    number: int | None = None
    title: str = ""
    body: str = ""
    labels: list[str] = dataclasses.field(default_factory=list)
    comment: str = ""
    fp: str = ""       # tracking actions: the group key
    meta: dict = dataclasses.field(default_factory=dict)


@dataclasses.dataclass
class TrackingPlan:
    actions: list[Action]
    opened: list[str]              # group keys getting a new or reopened tracking issue tonight
    pending: list[TrackGroup]      # high groups with no tracking issue yet, past tonight's cap
    skipped_wontfix: list[str]     # instance fingerprints silenced by a wontfix issue
    commented: list[str]           # group keys whose open issue got a CHANGED comment
    missing_counted: list[str]
    closed: list[str]              # group keys auto-closed tonight
    held_incomplete: list[str]     # open issues left alone because their tool was incomplete
    budget_used_before: int = 0    # tracking issues already opened earlier today (reruns)


@dataclasses.dataclass
class IssueIndex:
    by_gk: dict[str, Issue]
    tickets: list[Issue]
    legacy_digests: list[Issue]

    def tracking_for(self, g: FindingGroup) -> Issue | None:
        return self.by_gk.get(group_key(g.tool, g.rule, g.file))


def index_issues(issues: list[Issue]) -> IssueIndex:
    """Tracking issues are found by the group key in their marker. (The
    per-fingerprint v1 markers of 2026-10-01 never reached GitHub: writes were
    off until this design, so there is nothing to migrate.)"""
    by_gk: dict[str, Issue] = {}
    tickets: list[Issue] = []
    legacy: list[Issue] = []

    def better(new: Issue, cur: Issue | None) -> bool:
        # Prefer a wontfix issue (Rick's ruling wins), then an open one, then the oldest.
        return cur is None or (new.is_wontfix and not cur.is_wontfix) or (
            new.is_open and not cur.is_open and not cur.is_wontfix)

    for iss in sorted(issues, key=lambda i: i.number):
        if iss.ticket_marker is not None:
            tickets.append(iss)
            continue
        if (LOW_DIGEST_MARKER_RE.search(iss.body or "") or DIGEST_MARKER_RE.search(iss.body or "")
                or DIGEST_LABEL in iss.labels):
            legacy.append(iss)
            continue
        mk = iss.marker
        if not mk or "gk" not in mk:
            continue
        if better(iss, by_gk.get(mk["gk"])):
            by_gk[mk["gk"]] = iss
    return IssueIndex(by_gk, tickets, legacy)


def _instances_state(tg: TrackGroup) -> dict[str, list]:
    return {g.fp: [g.detail_digest, g.count, g.severity] for g in tg.instances}


def _change_note(tg: TrackGroup, old: dict[str, list], new: dict[str, list],
                 old_sev: str | None, today: str, run_url: str) -> str | None:
    """None when nothing changed. Otherwise the CHANGED comment: instances
    that appeared, disappeared, or changed (count / detail / severity)."""
    appeared = sorted(set(new) - set(old))
    gone = sorted(set(old) - set(new))
    changed = sorted(fp for fp in set(new) & set(old) if list(old[fp])[:1] != list(new[fp])[:1])
    if not (appeared or gone or changed or old_sev != tg.severity):
        return None
    by_fp = {g.fp: g for g in tg.instances}
    note = [f"**Changed in the nightly of {today}.**"]
    if old_sev != tg.severity:
        note.append(f"Severity: {old_sev} → {tg.severity}")
    if appeared:
        note.append("New instance(s):\n" + "\n".join(
            f"- `{fp}` {_short(normalise_detail(by_fp[fp].message), 120)}" for fp in appeared))
    if gone:
        note.append("Gone instance(s):\n" + "\n".join(f"- `{fp}`" for fp in gone))
    for fp in changed:
        o, n = old[fp], new[fp]
        what = []
        if len(o) > 1 and o[1] != n[1]:
            what.append(f"occurrences {o[1]} → {n[1]}")
        if len(o) > 2 and o[2] != n[2]:
            what.append(f"severity {o[2]} → {n[2]}")
        note.append(f"`{fp}`: " + ("; ".join(what) if what else "detail text changed"))
    note.append(f"Instances now: {len(new)}. Run: {run_url or 'n/a'}")
    return "\n\n".join(note)


def plan_tracking(groups: dict[str, FindingGroup], idx: IssueIndex, complete: dict[str, bool],
                  today: str, run_url: str, cap: int = DEFAULT_CAP) -> TrackingPlan:
    """High-severity tracking issues, one per (tool, rule, file). `groups`
    must already exclude vendored code."""
    by_gk = idx.by_gk
    tgs = track_groups(groups)
    actions: list[Action] = []
    opened: list[str] = []
    pending: list[TrackGroup] = []
    skipped, commented, missing_counted, closed, held = [], [], [], [], []
    # A rerun the same night must not open another `cap` issues.
    already = sum(1 for iss in by_gk.values()
                  if (iss.marker or {}).get("opened_on") == today and not iss.is_wontfix)
    budget = max(0, cap - already)

    for tg in sorted(tgs.values(), key=lambda t: (SEVERITY_RANK[t.severity], t.tool, t.file, t.rule)):
        iss = by_gk.get(tg.gk)
        if iss is not None and iss.is_wontfix:
            skipped += tg.fps
            continue
        if iss is not None and iss.is_open:
            # The issue exists: record instance changes (an empty group is
            # handled below as a clean night).
            st = dict(iss.marker or {})
            old = dict(st.get("instances") or {})
            new = _instances_state(tg)
            if not complete.get(tg.tool, False):
                # Incomplete tool: an instance missing tonight is unknown, not gone.
                for fp, v in old.items():
                    new.setdefault(fp, v)
            note = _change_note(tg, old, new, st.get("severity"), today, run_url)
            was_missing = bool(st.get("missing_dates"))
            if note is None and not was_missing:
                continue
            st.update({"instances": new, "severity": tg.severity, "missing_dates": []})
            if note is not None:
                actions.append(Action("comment", iss.number, comment=note, fp=tg.gk, title=iss.title))
                actions.append(Action("edit", iss.number, body=render_body(tg, st, run_url), fp=tg.gk))
                if tg.severity == "high" and HIGH_LABEL not in iss.labels:
                    actions.append(Action("add_label", iss.number, labels=[HIGH_LABEL], fp=tg.gk))
                commented.append(tg.gk)
            else:
                actions.append(Action("edit", iss.number, body=with_state(iss.body, st), fp=tg.gk))
            continue
        if tg.severity not in TRACKED_SEVERITIES:
            continue                       # medium and low live in the nightly ticket only
        if budget <= 0:
            pending.append(tg)
            continue
        budget -= 1
        opened.append(tg.gk)
        meta = {"severity": tg.severity, "tool": tg.tool, "instances": len(tg.instances)}
        if iss is None:
            st = {"v": 2, "gk": tg.gk, "tool": tg.tool, "rule": tg.rule, "file": tg.file,
                  "first_seen": today, "opened_on": today, "severity": tg.severity,
                  "instances": _instances_state(tg), "missing_dates": []}
            actions.append(Action("create", title=track_title(tg), body=render_body(tg, st, run_url),
                                  labels=labels_for(tg), fp=tg.gk, meta=meta))
        else:
            st = dict(iss.marker or {})
            st.update({"instances": _instances_state(tg), "severity": tg.severity,
                       "missing_dates": [], "opened_on": today})
            actions.append(Action("reopen", iss.number, title=iss.title, fp=tg.gk, meta=meta,
                                  comment=f"**Reappeared in the nightly of {today}** after being closed "
                                          f"({len(tg.instances)} instance(s)). Run: {run_url or 'n/a'}"))
            actions.append(Action("edit", iss.number, body=render_body(tg, st, run_url), fp=tg.gk))

    # Open tracking issues with ZERO instances tonight: a clean night.
    for gk, iss in sorted(by_gk.items(), key=lambda kv: kv[1].number):
        if gk in tgs or not iss.is_open or iss.is_wontfix:
            continue
        st = dict(iss.marker or {})
        tool = st.get("tool", "?")
        if not complete.get(tool, False):
            held.append(gk)
            continue
        dates = list(st.get("missing_dates") or [])
        if today in dates:
            continue                       # this night was already counted
        first_clean = not dates
        dates.append(today)
        st["missing_dates"] = dates
        gone = sorted(st.get("instances") or {})
        if first_clean and gone:
            # The last instances disappearing is itself a change.
            actions.append(Action("comment", iss.number, fp=gk, title=iss.title, comment=(
                f"**Changed in the nightly of {today}.**\n\nGone instance(s):\n"
                + "\n".join(f"- `{fp}`" for fp in gone)
                + f"\n\nInstances now: 0. Closes after {CLOSE_AFTER_NIGHTS} clean nights. "
                  f"Run: {run_url or 'n/a'}")))
            commented.append(gk)
        st["instances"] = {}
        if len(dates) >= CLOSE_AFTER_NIGHTS:
            actions.append(Action("edit", iss.number, body=with_state(iss.body, st), fp=gk))
            actions.append(Action("close", iss.number, fp=gk, title=iss.title, comment=(
                f"Zero instances reported by `{tool}` in {CLOSE_AFTER_NIGHTS} consecutive complete "
                f"nightly runs ({', '.join(dates[-CLOSE_AFTER_NIGHTS:])}). Closing as fixed. It will "
                f"reopen if an instance comes back. Run: {run_url or 'n/a'}")))
            closed.append(gk)
        else:
            actions.append(Action("edit", iss.number, body=with_state(iss.body, st), fp=gk))
            missing_counted.append(gk)

    return TrackingPlan(actions, opened, pending, skipped, commented, missing_counted,
                        closed, held, min(already, cap))


def ensure_labels(gh, needed: Iterable[str]) -> None:
    have = gh.list_labels()
    for name in sorted(set(needed) - have):
        color, desc = LABEL_COLORS.get(name, ("ededed", "nightly analysis"))
        gh.create_label(name, color, desc)


def apply(actions: list[Action], gh) -> tuple[dict[str, int], list[str]]:
    """Executes tracking actions. Returns (group key -> issue number for
    creates and reopens, errors). One failed call does not stop the rest; the caller
    exits non-zero."""
    numbers: dict[str, int] = {}
    errors: list[str] = []
    for a in actions:
        try:
            if a.kind == "create":
                numbers[a.fp] = gh.create_issue(a.title, a.body, a.labels)
            elif a.kind == "reopen":
                gh.reopen(a.number, a.comment)
                numbers[a.fp] = a.number
            elif a.kind == "comment":
                gh.comment(a.number, a.comment)
            elif a.kind == "edit":
                gh.edit_body(a.number, a.body)
            elif a.kind == "add_label":
                gh.add_labels(a.number, a.labels)
            elif a.kind == "close":
                gh.close(a.number, a.comment)
        except Exception as exc:          # noqa: BLE001 - report every failure, keep going
            errors.append(f"{a.kind} #{a.number or '-'} {a.fp}: {exc}")
    return numbers, errors


# --------------------------------------------------------------------------
# The nightly ticket: state, analysis, rendering, rotation
# --------------------------------------------------------------------------
#
# Ticket marker (JSON in an HTML comment at the top of the body):
#   {"v": 1, "date": "YYYY-MM-DD",
#    "hm":  {fp16: [tool, severity, first_seen, detail_digest, file, rule, msg]},
#    "hm8": {tool: "<8-hex fp prefixes concatenated>"},   # high/medium past HM_FULL_BUDGET
#    "low": {tool: {"count": n, "date": d, "fp8": "<blob>" | null}},
#    "degraded": [what fit_state had to drop, if anything]}
# hm and hm8 together are EVERY high/medium fingerprint reported (or carried
# for an incomplete tool), which is what makes NEW / FIXED exact.

def parse_ts(s: str | None) -> _dt.datetime | None:
    if not s:
        return None
    try:
        t = _dt.datetime.fromisoformat(str(s).replace("Z", "+00:00"))
    except ValueError:
        return None
    return t if t.tzinfo else t.replace(tzinfo=_dt.timezone.utc)


def recent_human_comment(iss: Issue, now: _dt.datetime, hours: float = HUMAN_GUARD_HOURS) -> bool:
    """A comment by a person (not the Actions bot, not this tool) in the last
    `hours`. An unparseable timestamp counts as recent: when unsure, keep the
    conversation open."""
    for c in iss.comments or []:
        login = str(((c.get("author") or {}).get("login")) or "")
        if login in BOT_LOGINS or login.endswith("[bot]"):
            continue
        if BOT_COMMENT_TAG in (c.get("body") or ""):
            continue
        ts = parse_ts(c.get("createdAt"))
        if ts is None or (now - ts) <= _dt.timedelta(hours=hours):
            return True
    return False


def ticket_title(today: str) -> str:
    return f"Nightly findings — {today}"


def render_ticket_marker(state: dict) -> str:
    return "<!-- nightly-findings-ticket " + json.dumps(state, sort_keys=True, ensure_ascii=False) + " -->"


def _record(g: FindingGroup, first_seen: str) -> list:
    return [g.tool, g.severity, first_seen, g.detail_digest, g.file, g.rule,
            normalise_detail(g.message)[:90]]


def fit_state(state: dict, budget: int = MARKER_BUDGET) -> dict:
    """Bound the marker. At real scale (tens of high/medium, ~2,000 low) it
    is ~17 KB and nothing degrades. Past the budget, in this order:
      1. high/medium records beyond HM_FULL_BUDGET keep only their 8-hex
         prefix (still exact for NEW / FIXED; CHANGED and first-seen lost)
      2. per-tool low fp blobs are dropped, largest first (next night shows
         a count delta but no new/gone split for that tool)
      3. the remaining full records are demoted to prefixes
      4. hm8 prefixes are truncated (those findings would read as NEW again;
         needs more than ~4,000 high/medium fingerprints in one night)
    Each step is recorded in state["degraded"] and shown in the ticket."""
    degraded: list[str] = []
    items = sorted(state["hm"].items(), key=lambda kv: (SEVERITY_RANK.get(kv[1][1], 9), kv[1][2], kv[0]))
    full: dict[str, list] = {}
    hm8: dict[str, set[str]] = {t: blob_to_set(b) for t, b in (state.get("hm8") or {}).items()}
    used = 0
    spilled = 0
    for fp, rec in items:
        size = len(json.dumps({fp: rec}, ensure_ascii=False))
        if used + size <= HM_FULL_BUDGET:
            full[fp] = rec
            used += size
        else:
            hm8.setdefault(rec[0], set()).add(fp[:DIGEST_FP_CHARS])
            spilled += 1
    if spilled:
        degraded.append(f"{spilled} high/medium record(s) kept as fingerprint prefix only")
    state["hm"] = full
    state["hm8"] = {t: "".join(sorted(s)) for t, s in sorted(hm8.items()) if s}

    def size() -> int:
        return len(json.dumps(state, sort_keys=True, ensure_ascii=False))

    if size() > budget:
        for tool, rec in sorted((state.get("low") or {}).items(),
                                key=lambda kv: -len(kv[1].get("fp8") or "")):
            if rec.get("fp8"):
                rec["fp8"] = None
                degraded.append(f"low fingerprints for {tool} dropped (count kept)")
                if size() <= budget:
                    break
    if size() > budget and state["hm"]:
        # Demote full records to prefixes, lowest priority first (a prefix
        # still keeps NEW / FIXED exact: ~10 bytes instead of ~150). Batched
        # by the measured excess, so this is O(n log n), not O(n^2).
        demoted = 0
        order = sorted(state["hm"].items(),
                       key=lambda kv: (SEVERITY_RANK.get(kv[1][1], 9), kv[1][2], kv[0]))
        while size() > budget and order:
            excess = size() - budget
            saved = 0
            while order and saved < excess:
                fp, rec = order.pop()
                del state["hm"][fp]
                hm8.setdefault(rec[0], set()).add(fp[:DIGEST_FP_CHARS])
                saved += len(json.dumps({fp: rec}, ensure_ascii=False)) - DIGEST_FP_CHARS - 2
                demoted += 1
            state["hm8"] = {t: "".join(sorted(s)) for t, s in sorted(hm8.items()) if s}
        degraded.append(f"{demoted} more high/medium record(s) demoted to prefix")
    if size() > budget:
        for tool in sorted(state["hm8"], key=lambda t: -len(state["hm8"][t])):
            over = size() - budget
            blob = state["hm8"][tool]
            keep = max(0, len(blob) - over - DIGEST_FP_CHARS)
            keep -= keep % DIGEST_FP_CHARS
            state["hm8"][tool] = blob[:keep]
            degraded.append(f"high/medium prefixes for {tool} truncated")
            if size() <= budget:
                break
    state["degraded"] = degraded
    return state


@dataclasses.dataclass
class TicketPlan:
    actions: list[Action]
    state: dict
    body: str
    tonight: Issue | None
    previous: Issue | None
    left_open: list[int]               # earlier tickets kept open by the human-comment guard
    closing: list[int]                 # earlier tickets closed tonight
    new_high: list[FindingGroup]
    new_medium: list[FindingGroup]
    changed: list[tuple[FindingGroup, list]]
    fixed: list[tuple[str, list | None]]   # (fp or fp8, record or None)
    still_open: list[tuple[FindingGroup, str]]   # (group, first_seen), not NEW
    low: dict[str, dict]
    held_tools: list[str]
    vendored: list[FindingGroup]
    tracked_refs: dict[str, str]


def _short(s: str, n: int) -> str:
    s = (s or "").replace("|", "\\|").replace("\n", " ")
    return s if len(s) <= n else s[:n - 1] + "…"


def _item_line(fp: str, file: str, rule: str, msg: str, count: int | None,
               ref: str, run_url: str) -> str:
    s = f"- `{fp}` · `{file}` · `{_short(rule, 60)}` · {_short(msg, 110)}"
    if count and count > 1:
        s += f" (×{count})"
    if ref:
        s += f" · {ref}"
    if run_url:
        s += f" · [run]({run_url})"
    return s


def _capped(lines: list[str], total: int) -> list[str]:
    if total > len(lines):
        lines = lines + [f"- … and {total - len(lines)} more: the full list is in the "
                         "`nightly-findings-summary` artifact of the run."]
    return lines


def plan_ticket(groups: dict[str, FindingGroup], vendored: list[FindingGroup], idx: IssueIndex,
                runs: dict[str, ToolRun], tp: TrackingPlan, numbers: dict[str, int],
                today: str, now: _dt.datetime, run_url: str, dry_run: bool,
                cap: int = DEFAULT_CAP) -> TicketPlan:
    complete = {t: r.complete for t, r in runs.items()}
    tickets = [t for t in idx.tickets if (t.ticket_marker or {}).get("date")]
    tonight_all = sorted((t for t in tickets if t.ticket_marker["date"] == today),
                         key=lambda t: (not t.is_open, t.number))
    tonight = tonight_all[0] if tonight_all else None
    earlier = [t for t in tickets if str(t.ticket_marker["date"]) < today]
    previous = max(earlier, key=lambda t: (t.ticket_marker["date"], t.number)) if earlier else None
    prev = (previous.ticket_marker if previous else None) or {}
    prev_hm: dict[str, list] = dict(prev.get("hm") or {})
    prev_hm8: dict[str, set[str]] = {t: blob_to_set(b) for t, b in (prev.get("hm8") or {}).items()}
    prev_hm8_all = set().union(*prev_hm8.values()) if prev_hm8 else set()
    prev_low: dict[str, dict] = dict(prev.get("low") or {})
    wontfix = set(tp.skipped_wontfix)

    # Tracking-issue reference per instance fingerprint, via its group key.
    refs: dict[str, str] = {}
    pending_gks = {t.gk for t in tp.pending}
    for fp, g in groups.items():
        if g.severity not in TRACKED_SEVERITIES or fp in wontfix:
            continue
        gk = group_key(g.tool, g.rule, g.file)
        n = numbers.get(gk)
        iss = idx.by_gk.get(gk)
        if n is not None:
            verb = "reopened" if iss is not None else "opened"
            refs[fp] = f"tracking: would be {verb}" if dry_run else f"tracking #{n} ({verb} tonight)"
        elif iss is not None and iss.is_open:
            refs[fp] = f"tracking #{iss.number}"
        elif gk in pending_gks:
            refs[fp] = f"tracking issue queued (cap {cap}/night)"

    def known_before(g: FindingGroup) -> bool:
        if g.fp in prev_hm or g.fp[:DIGEST_FP_CHARS] in prev_hm8_all:
            return True
        iss = idx.tracking_for(g)
        # An instance already listed on a tracking issue open before tonight also counts.
        mk = (iss.marker or {}) if iss is not None else {}
        return (iss is not None and iss.is_open and mk.get("opened_on") != today
                and g.fp in (mk.get("instances") or {}))

    new_high, new_medium, changed, still = [], [], [], []
    hm_now: dict[str, list] = {}
    for g in sorted(groups.values(), key=lambda g: (SEVERITY_RANK[g.severity], g.tool, g.file, g.fp)):
        if g.severity not in ("high", "medium") or g.fp in wontfix:
            continue
        rec = prev_hm.get(g.fp)
        if not known_before(g):
            (new_high if g.severity == "high" else new_medium).append(g)
            first_seen = today
        else:
            tiss = idx.tracking_for(g)
            tracked_first = (tiss.marker or {}).get("first_seen") if tiss is not None and \
                g.fp in ((tiss.marker or {}).get("instances") or {}) else None
            candidates = [d for d in (rec[2] if rec else None, tracked_first,
                                      None if rec else prev.get("date")) if d]
            first_seen = min(candidates) if candidates else today
            if rec and rec[3] != g.detail_digest:
                changed.append((g, rec))
            still.append((g, first_seen))
        hm_now[g.fp] = _record(g, first_seen)

    # FIXED: on the previous ticket, absent tonight, and its tool ran completely.
    fixed: list[tuple[str, list | None]] = []
    hm8_now: dict[str, set[str]] = {}
    held_tools = sorted(t for t in TOOLS if not complete.get(t, False)
                        and (any(r[0] == t for r in prev_hm.values()) or prev_hm8.get(t)
                             or t in prev_low or runs[t].input_found))
    current_fps = set(groups)
    current_fp8 = {fp[:DIGEST_FP_CHARS] for fp in groups}
    for fp, rec in sorted(prev_hm.items(), key=lambda kv: (SEVERITY_RANK.get(kv[1][1], 9), kv[1][0], kv[1][4])):
        if fp in current_fps:
            continue
        if complete.get(rec[0], False):
            fixed.append((fp, rec))
        else:
            hm_now.setdefault(fp, rec)        # carried: the tool did not run completely
    for tool, prefixes in sorted(prev_hm8.items()):
        gone = prefixes - current_fp8
        if complete.get(tool, False):
            fixed += [(p, None) for p in sorted(gone)]
        elif gone:
            hm8_now.setdefault(tool, set()).update(gone)
    fixed_closed = [(gk, idx.by_gk[gk]) for gk in tp.closed if gk in idx.by_gk]
    live_gks = {group_key(g.tool, g.rule, g.file) for g in groups.values()}
    for fp, rec in fixed:
        if rec is None:
            continue
        gk = group_key(rec[0], rec[5], rec[4])
        iss = idx.by_gk.get(gk)
        if iss is None or iss.is_wontfix:
            continue
        if gk in tp.closed:
            refs[fp] = f"tracking #{iss.number} auto-closed tonight"
        elif iss.is_open and gk in live_gks:
            refs[fp] = f"instance gone from tracking #{iss.number} (other instances remain)"
        elif iss.is_open:
            refs[fp] = f"tracking #{iss.number} closes after {CLOSE_AFTER_NIGHTS} clean nights"

    # Low: per-tool counts and deltas against the previous ticket.
    lows_by_tool: dict[str, list[FindingGroup]] = {}
    for g in groups.values():
        if g.severity == "low" and g.fp not in wontfix:
            lows_by_tool.setdefault(g.tool, []).append(g)
    low_state: dict[str, dict] = {}
    low_view: dict[str, dict] = {}
    for tool in TOOLS:
        cur = lows_by_tool.get(tool, [])
        p = prev_low.get(tool)
        if not complete.get(tool, False):
            if p is not None:
                low_state[tool] = dict(p)
                low_view[tool] = {"count": p.get("count", 0), "held": True, "since": p.get("date"),
                                  "first": False, "prev_count": p.get("count"), "new_total": None,
                                  "gone": None, "top_new": []}
            continue
        if not cur and p is None:
            continue
        # p is None: first count for this tool (baseline). p without "fp8":
        # the previous marker dropped it (fit_state), so only counts compare.
        prev_set = blob_to_set(p.get("fp8")) if p and p.get("fp8") is not None else None
        ordered_lows = sorted(cur, key=lambda g: (g.rule, g.file, g.fp))
        if prev_set is None:
            new, new_total, gone = ordered_lows, None, None
        else:
            new = [g for g in ordered_lows if g.fp[:DIGEST_FP_CHARS] not in prev_set]
            new_total = len(new)
            gone = len(prev_set - {g.fp[:DIGEST_FP_CHARS] for g in cur})
        low_state[tool] = {"count": len(cur), "date": today, "fp8": digest_fp_blob(g.fp for g in cur)}
        low_view[tool] = {"count": len(cur), "held": False, "first": p is None,
                          "prev_count": (p or {}).get("count"), "new_total": new_total,
                          "gone": gone,
                          "top_new": new[:LOW_NEW_SHOWN] if (p is None or new_total is not None) else []}

    state = fit_state({"v": 1, "date": today, "hm": hm_now,
                       "hm8": {t: "".join(sorted(s)) for t, s in hm8_now.items()},
                       "low": low_state})

    # Rotation: every other open ticket is closed, unless a human is talking in it.
    left_open: list[int] = []
    closing: list[int] = []
    for t in tickets:
        if t is tonight or not t.is_open:
            continue
        if recent_human_comment(t, now):
            left_open.append(t.number)
        else:
            closing.append(t.number)

    body = render_ticket(state, today, run_url, previous, groups, new_high, new_medium, changed,
                         fixed, fixed_closed, still, low_view, held_tools, runs, vendored,
                         refs, left_open, tp, cap, dry_run)

    actions: list[Action] = []
    if tonight is None:
        actions.append(Action("ticket_create", title=ticket_title(today), body=body,
                              labels=[TICKET_LABEL]))
    elif tonight.body != body:
        actions.append(Action("ticket_edit", tonight.number, title=tonight.title, body=body))
    for n in closing:
        actions.append(Action("ticket_close", n, comment=(
            f"Superseded by {{TICKET}}, the nightly findings ticket for {today}. Only one nightly "
            f"ticket stays open; everything still reported is carried there.\n\n{BOT_COMMENT_TAG}")))
    for d in idx.legacy_digests:
        if d.is_open and not d.is_wontfix:
            actions.append(Action("legacy_close", d.number, title=d.title, comment=(
                "Digest issues were retired on 2026-10-02 (Rick's ruling): medium and low findings "
                f"now live in the one nightly ticket, {{TICKET}}.\n\n{BOT_COMMENT_TAG}")))

    return TicketPlan(actions, state, body, tonight, previous, left_open, closing, new_high,
                      new_medium, changed, fixed, still, low_view, held_tools, vendored, refs)


def render_ticket(state: dict, today: str, run_url: str, previous: Issue | None,
                  groups: dict[str, FindingGroup], new_high, new_medium, changed, fixed,
                  fixed_closed, still, low_view, held_tools, runs, vendored, refs,
                  left_open, tp: TrackingPlan, cap: int, dry_run: bool) -> str:
    run = run_url or ""
    marker = render_ticket_marker(state)
    prev_txt = (f"#{previous.number} ({previous.ticket_marker['date']})" if previous
                else "nothing (first nightly ticket: everything high/medium counts as NEW)")
    out = [
        marker,
        f"# Nightly findings — {today}",
        "",
        f"**🔴 {len(new_high)} NEW high · {len(new_medium)} NEW medium · {len(changed)} changed · "
        f"{len(fixed)} fixed · {len(still)} still open (high/medium)**",
        "",
        f"Run: {run or 'n/a'} · Compared with: {prev_txt}",
    ]
    if left_open:
        out.append("Earlier ticket(s) left open because someone commented in the last "
                   f"{HUMAN_GUARD_HOURS} h: " + ", ".join(f"#{n}" for n in left_open))
    out.append("")

    def group_lines(gs: list[FindingGroup]) -> list[str]:
        lines = [_item_line(g.fp, g.file, g.rule, normalise_detail(g.message), g.count,
                            refs.get(g.fp, ""), run) for g in gs[:SECTION_MAX]]
        return _capped(lines, len(gs)) or ["(none)"]

    out += [f"## 🔴 NEW high ({len(new_high)})", ""] + group_lines(new_high) + [""]
    out += [f"## NEW medium ({len(new_medium)})", ""] + group_lines(new_medium) + [""]

    out += [f"## CHANGED ({len(changed)})", ""]
    ch = []
    for g, rec in changed[:SECTION_MAX]:
        what = []
        if rec[1] != g.severity:
            what.append(f"severity {rec[1]} → {g.severity}")
        what.append(f"now ×{g.count}")
        ch.append(_item_line(g.fp, g.file, g.rule, normalise_detail(g.message), None,
                             "; ".join(what) + (f" · {refs[g.fp]}" if g.fp in refs else ""), run))
    out += (_capped(ch, len(changed)) or ["(none)"]) + [""]

    out += [f"## FIXED since last night ({len(fixed)})", ""]
    fx = []
    for fp, rec in fixed[:SECTION_MAX]:
        if rec is None:
            fx.append(f"- `{fp}` · (details not retained: the marker was over budget) · no longer reported")
        else:
            fx.append(_item_line(fp, rec[4], rec[5], rec[6], None,
                                 f"{rec[1]}, no longer reported" + (f" · {refs[fp]}" if fp in refs else ""),
                                 run))
    out += _capped(fx, len(fixed)) or ["(none)"]
    if fixed_closed:
        out += ["", f"Tracking issues auto-closed tonight (absent {CLOSE_AFTER_NIGHTS} complete nights): "
                + ", ".join(f"#{iss.number}" for _fp, iss in fixed_closed)]
    out.append("")

    # Still open: counts of everything reported tonight, per tool and severity.
    counts: dict[str, dict[str, int]] = {}
    for g in groups.values():
        counts.setdefault(g.tool, {"high": 0, "medium": 0, "low": 0})[g.severity] += 1
    out += [f"## Still open ({len(still)} high/medium seen before tonight)", "",
            "Everything reported tonight, NEW included, per tool and severity:", "",
            "| Tool | High | Medium | Low |", "|---|---:|---:|---:|"]
    for t in TOOLS:
        if t in counts:
            c = counts[t]
            out.append(f"| {t} | {c['high']} | {c['medium']} | {c['low']} |")
    if not counts:
        out.append("| (nothing reported) | 0 | 0 | 0 |")
    oldest = sorted(still, key=lambda x: (x[1], SEVERITY_RANK[x[0].severity], x[0].fp))[:OLDEST_SHOWN]
    out += ["", f"Oldest {len(oldest)} still open:", ""]
    out += [_item_line(g.fp, g.file, g.rule, normalise_detail(g.message), g.count,
                       f"{g.severity}, since {fs}" + (f" · {refs[g.fp]}" if g.fp in refs else ""), run)
            for g, fs in oldest] or ["(none)"]
    if tp.pending:
        n_inst = sum(len(t.instances) for t in tp.pending)
        out += ["", f"{len(tp.pending)} high tracking issue(s) ({n_inst} instance(s)) are queued "
                    f"(at most {cap} new per night; one issue per tool + rule + file)."]
    out.append("")

    out += ["## Low severity (counts and deltas; never filed)", "",
            "| Tool | Findings | New | Gone | Note |", "|---|---:|---:|---:|---|"]
    for t in TOOLS:
        v = low_view.get(t)
        if v is None:
            continue
        if v["held"]:
            out.append(f"| {t} | {v['count']} | – | – | incomplete tonight; count as of {v.get('since') or '?'} |")
        elif v["first"]:
            out.append(f"| {t} | {v['count']} | – | – | first count (baseline) |")
        elif v["new_total"] is None:
            out.append(f"| {t} | {v['count']} | ? | ? | was {v['prev_count']}; per-item delta unavailable |")
        else:
            out.append(f"| {t} | {v['count']} | +{v['new_total']} | −{v['gone']} | was {v['prev_count']} |")
    if not low_view:
        out.append("| (none) | 0 | 0 | 0 | |")
    for t in TOOLS:
        v = low_view.get(t)
        if not v or not v["top_new"]:
            continue
        label = (f"first {len(v['top_new'])} of {v['count']}, baseline" if v["first"]
                 else f"top {len(v['top_new'])} of {v['new_total']} new")
        out += ["", f"**{t}** ({label}):"]
        out += [_item_line(g.fp, g.file, g.rule, normalise_detail(g.message), g.count, "", run)
                for g in v["top_new"]]
    out.append("")

    notes = []
    if vendored:
        by_tool: dict[str, int] = {}
        roots: dict[str, int] = {}
        for g in vendored:
            by_tool[g.tool] = by_tool.get(g.tool, 0) + 1
            roots[vendored_root(g.file)] = roots.get(vendored_root(g.file), 0) + 1
        notes.append(f"Vendored / third-party (not filed): {len(vendored)} finding(s) — "
                     + ", ".join(f"{t} {n}" for t, n in sorted(by_tool.items())) + " in "
                     + ", ".join(r for r, _ in sorted(roots.items(), key=lambda kv: -kv[1])[:5]) + ".")
    # A job that did not run at all (e.g. TSan, `if: false` since 2026-05-12)
    # is reported as disabled, not as a failure.
    disabled = [t for t in TOOLS if not runs[t].complete and runs[t].is_disabled]
    incomplete = [t for t in TOOLS if not runs[t].complete and not runs[t].is_disabled]
    if disabled:
        notes.append("Not run tonight (disabled job): " + ", ".join(disabled) + ".")
    if incomplete:
        notes.append("Incomplete tonight (nothing from these counted as fixed; state carried): "
                     + ", ".join(f"{t} ({'; '.join(runs[t].notes) or 'incomplete'})" for t in incomplete) + ".")
    if tp.skipped_wontfix:
        notes.append(f"Silenced by `wontfix`: {len(tp.skipped_wontfix)}.")
    if state.get("degraded"):
        notes.append("State marker over budget: " + "; ".join(state["degraded"]) + ".")
    if dry_run:
        notes.append("DRY RUN: this body was planned, not written.")
    if notes:
        out += ["## Notes", ""] + [f"- {n}" for n in notes] + [""]
    out += ["---",
            "_One nightly ticket stays open; tomorrow's closes this one (unless someone commented "
            f"here in the last {HUMAN_GUARD_HOURS} h). High findings also get a `{BASE_LABEL}` tracking "
            "issue that stays open until fixed. Managed by `tools/nightly_findings_to_issues.py`._"]
    body = "\n".join(out)
    if len(body) > TICKET_BODY_BUDGET:
        body = body[:TICKET_BODY_BUDGET] + ("\n\n… (truncated to fit GitHub's limit; the full lists "
                                            "are in the `nightly-findings-summary` artifact)")
    return body


def apply_ticket(tk: TicketPlan, gh) -> tuple[int | None, list[str]]:
    """Create or edit tonight's ticket FIRST; earlier tickets are closed only
    once tonight's exists, so there is never a moment with none open."""
    errors: list[str] = []
    number = tk.tonight.number if tk.tonight is not None else None
    for a in tk.actions:
        try:
            if a.kind == "ticket_create":
                number = gh.create_issue(a.title, a.body, a.labels)
            elif a.kind == "ticket_edit":
                gh.edit_body(a.number, a.body)
            elif a.kind in ("ticket_close", "legacy_close"):
                if number is None:
                    errors.append(f"{a.kind} #{a.number}: skipped, tonight's ticket was not created")
                    continue
                gh.close(a.number, a.comment.replace("{TICKET}", f"#{number}"))
        except Exception as exc:          # noqa: BLE001
            errors.append(f"{a.kind} #{a.number or '-'}: {exc}")
    return number, errors


# --------------------------------------------------------------------------
# Summary and the planned-changes record
# --------------------------------------------------------------------------


def _issue_url(repo: str, n: int | None, dry_run: bool) -> str | None:
    return f"https://github.com/{repo}/issues/{n}" if (n and repo and not dry_run) else None


def build_summary(runs: dict[str, ToolRun], groups: dict[str, FindingGroup], tp: TrackingPlan,
                  tk: TicketPlan, idx: IssueIndex, numbers: dict[str, int], ticket_number: int | None,
                  errors: list[str], today: str, run_url: str, dry_run: bool, repo: str) -> dict:
    def tracking_no(gk: str) -> int | None:
        if gk in numbers:
            return numbers[gk]
        iss = idx.by_gk.get(gk)
        return iss.number if iss is not None and iss.is_open and not iss.is_wontfix else None

    def item(g: FindingGroup) -> dict:
        gk = group_key(g.tool, g.rule, g.file)
        n = tracking_no(gk) if g.severity in TRACKED_SEVERITIES else None
        return {"fp": g.fp, "gk": gk, "tool": g.tool, "rule": g.rule, "file": g.file,
                "severity": g.severity, "count": g.count, "title": issue_title(g),
                "issue": n, "url": _issue_url(repo, n, dry_run)}

    tgs = track_groups(groups)

    def group_item(tg: TrackGroup) -> dict:
        n = tracking_no(tg.gk)
        return {"gk": tg.gk, "tool": tg.tool, "rule": tg.rule, "file": tg.file,
                "severity": tg.severity, "instances": tg.fps, "title": track_title(tg),
                "issue": n, "url": _issue_url(repo, n, dry_run)}

    sev_counts = {"high": 0, "medium": 0, "low": 0}
    for g in groups.values():
        sev_counts[g.severity] += 1
    vend_by_tool: dict[str, int] = {}
    for g in tk.vendored:
        vend_by_tool[g.tool] = vend_by_tool.get(g.tool, 0) + 1

    # Open high tracking issues and when they were opened (the alert's ⚠️ age).
    open_high = []
    for gk, iss in sorted(idx.by_gk.items(), key=lambda kv: kv[1].number):
        mk = iss.marker or {}
        if not iss.is_open or iss.is_wontfix or gk in tp.closed or gk in tp.opened:
            continue
        if mk.get("severity") != "high" and HIGH_LABEL not in iss.labels:
            continue
        open_high.append({"issue": iss.number, "title": iss.title, "gk": gk,
                          "since": mk.get("opened_on") or mk.get("first_seen"),
                          "url": _issue_url(repo, iss.number, False)})
    for gk in tp.opened:
        tg = tgs.get(gk)
        if tg is None:
            continue
        open_high.append({"issue": None if dry_run else numbers.get(gk), "title": track_title(tg),
                          "gk": gk, "since": today,
                          "url": _issue_url(repo, numbers.get(gk), dry_run)})

    ticket_action = "create" if tk.tonight is None else ("edit" if any(
        a.kind == "ticket_edit" for a in tk.actions) else "unchanged")
    low = {t: {k: v for k, v in d.items() if k != "top_new"} for t, d in tk.low.items()}
    return {
        "v": 3,
        "date": today,
        "run_url": run_url,
        "dry_run": dry_run,
        "tools": {t: {"input": r.input_found, "complete": r.complete, "findings": len(r.findings),
                      "fingerprints": sum(1 for g in groups.values() if g.tool == t),
                      "vendored": vend_by_tool.get(t, 0), "notes": r.notes}
                  for t, r in runs.items()},
        "fingerprints": len(groups),
        "by_severity": sev_counts,
        "ticket": {"number": None if dry_run else ticket_number,
                   "url": _issue_url(repo, ticket_number, dry_run),
                   "title": ticket_title(today), "action": ticket_action,
                   "previous": tk.previous.number if tk.previous else None,
                   "closed": tk.closing, "left_open": tk.left_open},
        "new_high": [item(g) for g in tk.new_high],
        "new_medium": [item(g) for g in tk.new_medium],
        "changed": [item(g) for g, _ in tk.changed],
        "fixed": [{"fp": fp, "tool": rec[0] if rec else None, "severity": rec[1] if rec else None,
                   "file": rec[4] if rec else None, "rule": rec[5] if rec else None}
                  for fp, rec in tk.fixed],
        "still_open": len(tk.still_open),
        "tracking": {"opened": [group_item(tgs[gk]) for gk in tp.opened if gk in tgs],
                     "pending": len(tp.pending),
                     "pending_instances": sum(len(t.instances) for t in tp.pending),
                     "commented": len(tp.commented),
                     "missing_counted": len(tp.missing_counted),
                     "closed": [idx.by_gk[gk].number for gk in tp.closed if gk in idx.by_gk],
                     "held_incomplete": len(tp.held_incomplete),
                     "skipped_wontfix": len(tp.skipped_wontfix),
                     "open_high": open_high},
        "vendored": {"count": len(tk.vendored), "by_tool": vend_by_tool},
        "low": low,
        "low_held": [t for t, d in tk.low.items() if d.get("held")],
        "state_degraded": tk.state.get("degraded") or [],
        "plan": plan_record(tp, tk),
        "errors": errors,
    }


def plan_record(tp: TrackingPlan, tk: TicketPlan) -> dict:
    """Everything the run would do, readable without the issues."""
    rec = {"would_open": [], "would_reopen": [], "would_comment": [], "would_close": [],
           "would_label": [], "marker_edits": 0,
           "ticket": {"action": "unchanged", "issue": tk.tonight.number if tk.tonight else None,
                      "body": tk.body},
           "ticket_closes": [], "legacy_closes": []}
    for a in tp.actions:
        if a.kind == "create":
            rec["would_open"].append({"title": a.title, "fp": a.fp, "labels": a.labels, **a.meta})
        elif a.kind == "reopen":
            rec["would_reopen"].append({"issue": a.number, "title": a.title, "fp": a.fp, **a.meta})
        elif a.kind == "comment":
            rec["would_comment"].append({"issue": a.number, "title": a.title, "fp": a.fp,
                                         "comment": a.comment})
        elif a.kind == "close":
            rec["would_close"].append({"issue": a.number, "title": a.title, "fp": a.fp})
        elif a.kind == "add_label":
            rec["would_label"].append({"issue": a.number, "labels": a.labels, "fp": a.fp})
        elif a.kind == "edit":
            rec["marker_edits"] += 1
    for a in tk.actions:
        if a.kind == "ticket_create":
            rec["ticket"]["action"] = "create"
        elif a.kind == "ticket_edit":
            rec["ticket"]["action"] = "edit"
        elif a.kind == "ticket_close":
            rec["ticket_closes"].append(a.number)
        elif a.kind == "legacy_close":
            rec["legacy_closes"].append(a.number)
    return rec


def summary_markdown(s: dict) -> str:
    dry = s["dry_run"]
    t = s["ticket"]
    out = ["## Nightly findings" + (" (DRY RUN — nothing written)" if dry else ""), ""]
    if dry:
        out += ["Writes are off for this run (repo variable `NIGHTLY_FINDINGS_WRITE` not `true`, "
                "a non-main ref, or a dry_run dispatch).", ""]
    ref = t["url"] or ("(would " + s["plan"]["ticket"]["action"] + ")")
    out.append(f"Ticket: **{t['title']}** {ref}")
    out.append(f"🔴 NEW high {len(s['new_high'])} · NEW medium {len(s['new_medium'])} · "
               f"changed {len(s['changed'])} · fixed {len(s['fixed'])} · still open {s['still_open']}")
    tr = s["tracking"]
    verb = "would " if dry else ""
    out.append(f"Tracking (high): {verb}open {len(tr['opened'])} · queued {tr['pending']} · "
               f"{verb}comment {tr['commented']} · {verb}close {len(s['plan']['would_close'])} · "
               f"held (tool incomplete) {tr['held_incomplete']} · wontfix {tr['skipped_wontfix']}")
    if s["vendored"]["count"]:
        out.append(f"Vendored (not filed): {s['vendored']['count']}")
    out += ["", "| Tool | Input | Complete | Findings | Fingerprints | Vendored |",
            "|---|---|---|---:|---:|---:|"]
    for name, r in s["tools"].items():
        out.append(f"| {name} | {'yes' if r['input'] else 'no'} | {'yes' if r['complete'] else 'no'} "
                   f"| {r['findings']} | {r['fingerprints']} | {r['vendored']} |")
    if s["errors"]:
        out += ["", f"❌ **{len(s['errors'])} gh error(s)**:"] + [f"- {e}" for e in s["errors"][:20]]
    return "\n".join(out) + "\n"


def plan_markdown(s: dict) -> str:
    """The full planned list, ticket body included, as an artifact a human can
    read top to bottom."""
    pr = s["plan"]
    out = [f"# Nightly findings plan, {s['date']}" + (" (DRY RUN)" if s["dry_run"] else ""),
           "", f"Run: {s['run_url'] or 'n/a'}", ""]
    tk = pr["ticket"]
    out += [f"## Ticket: {tk['action']}" + (f" #{tk['issue']}" if tk.get("issue") else ""), ""]
    if pr["ticket_closes"]:
        out.append("Closes earlier ticket(s): " + ", ".join(f"#{n}" for n in pr["ticket_closes"]))
    if s["ticket"]["left_open"]:
        out.append("Left open (human comment < 48 h): "
                   + ", ".join(f"#{n}" for n in s["ticket"]["left_open"]))
    if pr["legacy_closes"]:
        out.append("Closes retired digest issue(s): " + ", ".join(f"#{n}" for n in pr["legacy_closes"]))
    out += ["", "<details><summary>Ticket body</summary>", "", tk["body"], "", "</details>", ""]
    out += [f"## Tracking issues: would open ({len(pr['would_open'])})", ""]
    out += [f"- [{o.get('severity')}] {o['title']}" for o in pr["would_open"]] or ["(none)"]
    out += ["", f"## Would reopen ({len(pr['would_reopen'])})", ""]
    out += [f"- #{o['issue']} {o['title']}" for o in pr["would_reopen"]] or ["(none)"]
    out += ["", f"## Would comment ({len(pr['would_comment'])})", ""]
    out += [f"- #{o['issue']} {o['title']}: {o['comment'].splitlines()[0]}"
            for o in pr["would_comment"]] or ["(none)"]
    out += ["", f"## Would close ({len(pr['would_close'])})", ""]
    out += [f"- #{o['issue']} {o['title']}" for o in pr["would_close"]] or ["(none)"]
    return "\n".join(out) + "\n"


# --------------------------------------------------------------------------
# One night, end to end (shared by run() and the tests)
# --------------------------------------------------------------------------


@dataclasses.dataclass
class NightResult:
    tracking: TrackingPlan
    ticket: TicketPlan
    index: IssueIndex
    numbers: dict[str, int]
    ticket_number: int | None
    errors: list[str]
    groups: dict[str, FindingGroup]


def run_night(gh, runs: dict[str, ToolRun], today: str, now: _dt.datetime, run_url: str,
              cap: int = DEFAULT_CAP, dry_run: bool = False) -> NightResult:
    all_groups = group_findings(f for r in runs.values() for f in r.findings)
    groups, vendored = split_vendored(all_groups)
    complete = {t: r.complete for t, r in runs.items()}
    idx = index_issues(list_all_issues(gh))
    errors: list[str] = []
    tp = plan_tracking(groups, idx, complete, today, run_url, cap)
    needed = {lb for a in tp.actions for lb in a.labels} | {TICKET_LABEL}
    try:
        ensure_labels(gh, needed)
    except Exception as exc:              # noqa: BLE001
        errors.append(f"labels: {exc}")
    numbers, errs = apply(tp.actions, gh)
    errors += errs
    tk = plan_ticket(groups, vendored, idx, runs, tp, numbers, today, now, run_url, dry_run, cap)
    ticket_number, errs = apply_ticket(tk, gh)
    errors += errs
    return NightResult(tp, tk, idx, numbers, ticket_number, errors, groups)


# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------


def parse_job_results(pairs: list[str]) -> dict[str, str]:
    out = {}
    for p in pairs or []:
        if "=" not in p:
            raise SystemExit(f"--job-result expects tool=result, got {p!r}")
        k, v = p.split("=", 1)
        out[k.strip()] = v.strip()
    return out


def run(argv: list[str] | None = None, gh_factory=None) -> int:
    ap = argparse.ArgumentParser(description="Nightly findings -> one nightly ticket + high tracking issues")
    ap.add_argument("--artifacts", type=Path, required=True)
    ap.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", ""))
    ap.add_argument("--run-url", default="")
    ap.add_argument("--job-result", action="append", default=[],
                    help="tool=result (success|failure|cancelled|skipped); non-success = incomplete")
    ap.add_argument("--cap", type=int, default=DEFAULT_CAP,
                    help="high tracking issues opened or reopened per night (default 3)")
    ap.add_argument("--today", default=None, help="YYYY-MM-DD (default: today, UTC)")
    ap.add_argument("--now", default=None, help="ISO time for the 48 h comment guard (default: now, UTC)")
    ap.add_argument("--summary-out", type=Path, default=Path("nightly-findings-summary.json"))
    ap.add_argument("--plan-out", type=Path, help="markdown plan (ticket body + tracking changes)")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)

    now = parse_ts(args.now) if args.now else _dt.datetime.now(_dt.timezone.utc)
    if now is None:
        print(f"::error::--now {args.now!r} is not an ISO time")
        return 2
    today = args.today or now.strftime("%Y-%m-%d")

    workspace = os.environ.get("GITHUB_WORKSPACE")
    runs = collect(args.artifacts, parse_job_results(args.job_result), workspace)

    if gh_factory is not None:
        gh = gh_factory(args.repo)
    else:
        if not args.repo:
            print("::error::--repo (or GITHUB_REPOSITORY) is required")
            return 2
        gh = GhCli(args.repo)
    if args.dry_run:
        gh = DryRunGh(gh)

    try:
        res = run_night(gh, runs, today, now, args.run_url, args.cap, args.dry_run)
    except Exception as exc:              # noqa: BLE001 - listing failed: nothing was planned
        print(f"::error::cannot list existing nightly issues: {exc}")
        return 1

    summary = build_summary(runs, res.groups, res.tracking, res.ticket, res.index, res.numbers,
                            res.ticket_number, res.errors, today, args.run_url, args.dry_run, args.repo)
    args.summary_out.write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    if args.plan_out:
        args.plan_out.write_text(plan_markdown(summary), encoding="utf-8")
    md = summary_markdown(summary)
    print(md)
    if isinstance(gh, DryRunGh):
        print(f"dry run: {len(gh.writes)} write(s) suppressed")
    step = os.environ.get("GITHUB_STEP_SUMMARY")
    if step:
        with open(step, "a", encoding="utf-8") as fh:
            fh.write(md)
    if res.errors:
        for e in res.errors:
            print(f"::error::{e}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(run())
