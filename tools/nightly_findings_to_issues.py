#!/usr/bin/env python3
"""Nightly static-analysis findings -> GitHub issues.

Runs as the last job of .github/workflows/nightly-analysis.yml. It reads the
artifacts every analysis job uploaded, gives each finding a stable
fingerprint, and keeps exactly one GitHub issue per fingerprint.

Inputs: the actions/download-artifact layout, one directory per artifact.
  codeql-results/*.sarif                    CodeQL (security-and-quality)
  strict-concurrency-log/all-warnings.txt   swiftc strict concurrency and
                                            strict memory safety warnings
  tsan-log/*.log                            Thread Sanitizer
  sanitizer-address/*.log                   Address Sanitizer
  sanitizer-undefined/*.log                 Undefined Behavior Sanitizer
  lint-strict/periphery-strict.txt          Periphery (dead code)
Any directory may also hold `nightly-status-<tool>.json` containing
{"complete": bool}. A tool counts as COMPLETE tonight only when its input
parsed, its status file (if any) says complete, and its job result (given
with --job-result) is "success". Findings are still filed from an incomplete
tool, but an incomplete tool never advances the "gone for N nights" counter.
Without that rule, a CodeQL build that broke would look like every CodeQL
finding being fixed.

Fingerprint = sha256(tool, rule, repo-relative file, normalised message),
with no line numbers anywhere, so a finding keeps its issue when code moves.

Issue policy (Rick, 2026-10-01):
  * new fingerprint             -> open an issue (labels: nightly-finding,
                                   the tool name, High Priority if high)
  * open, and it changed        -> one comment (count or severity or detail)
  * open, unchanged             -> nothing
  * gone for 3 complete nights  -> close with a comment
  * came back after auto-close  -> reopen with a comment
  * `wontfix` label, or closed as "not planned" -> never touched again
  * at most --cap (10) issues opened or reopened per night. Everything past
    the cap goes into ONE digest issue, and those findings get their own
    issues on later nights, high severity first.

State lives in the issues themselves, in a hidden JSON marker at the top of
each body, so there is no second database to drift. The digest issue
carries the fingerprints it lists. That is how "newly seen" stays true for
a finding that waited in the digest.

A finding never makes this script fail. It exits non-zero only when the
pipeline is broken: an unreadable input, or a `gh` call that failed.

Usage (CI):
  python3 tools/nightly_findings_to_issues.py --artifacts artifacts \
      --repo "$GITHUB_REPOSITORY" --run-url "$RUN_URL" \
      --job-result codeql=success --job-result strict-concurrency=failure ... \
      --summary-out nightly-findings-summary.json [--dry-run]

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

BASE_LABEL = "nightly-finding"
DIGEST_LABEL = "nightly-digest"
HIGH_LABEL = "High Priority"
WONTFIX_LABEL = "wontfix"
CLOSE_AFTER_NIGHTS = 3
DEFAULT_CAP = 10
MARKER_RE = re.compile(r"<!--\s*nightly-finding\s+(\{.*?\})\s*-->", re.S)
DIGEST_MARKER_RE = re.compile(r"<!--\s*nightly-findings-digest\s+(\{.*?\})\s*-->", re.S)

TOOLS = ("codeql", "strict-concurrency", "tsan", "asan", "ubsan", "periphery")
SEVERITY_RANK = {"high": 0, "medium": 1, "low": 2}
LABEL_COLORS = {
    BASE_LABEL: ("5319e7", "Filed by the nightly static analysis (tools/nightly_findings_to_issues.py)"),
    DIGEST_LABEL: ("bfd4f2", "Nightly overflow digest: findings waiting for their own issue"),
    "codeql": ("1d76db", "CodeQL finding"),
    "strict-concurrency": ("0e8a16", "Swift strict concurrency / memory safety warning"),
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

    @property
    def marker(self) -> dict | None:
        m = MARKER_RE.search(self.body or "")
        if not m:
            return None
        try:
            return json.loads(m.group(1))
        except json.JSONDecodeError:
            return None

    @property
    def is_open(self) -> bool:
        return self.state.upper() == "OPEN"

    @property
    def is_wontfix(self) -> bool:
        if WONTFIX_LABEL in self.labels:
            return True
        return (not self.is_open) and (self.state_reason or "").upper() == "NOT_PLANNED"


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
# Parsers, one per tool
# --------------------------------------------------------------------------


def parse_sarif(path: Path) -> list[Finding]:
    """CodeQL SARIF. High = security-tagged rule or level error."""
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
    owns them, with identity keys and a gate. As issues they would open and
    auto-close forever.
    """
    if _PERF.search(msg):
        return None
    if _MEMSAFE.search(msg):
        return "memory-safety", "medium"
    if _CONCURRENCY.search(msg):
        return "concurrency", ("high" if "data race" in msg.lower() else "medium")
    return "upcoming-feature-or-other", "low"


def parse_compiler_warnings(path: Path, workspace: str | None) -> list[Finding]:
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
        out.append(Finding("strict-concurrency", rule, relativise(m.group("path"), workspace),
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
_SAN_SEVERITY = {"asan": "high", "tsan": "high", "ubsan": "medium"}


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
        "tsan": (files("tsan-log", "*.log"), lambda p: parse_sanitizer_log(p, "tsan", workspace)),
        "asan": (files("sanitizer-address", "*.log"), lambda p: parse_sanitizer_log(p, "asan", workspace)),
        "ubsan": (files("sanitizer-undefined", "*.log"), lambda p: parse_sanitizer_log(p, "ubsan", workspace)),
        "periphery": (files("lint-strict", "periphery-strict.txt"),
                      lambda p: parse_periphery(p, workspace)),
    }
    for tool, (paths, parser) in sources.items():
        tr = runs[tool]
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

    def list_issues(self, label: str) -> list[Issue]:
        out = self._gh(["issue", "list", "--label", label, "--state", "all", "--limit", "5000",
                        "--json", "number,title,state,stateReason,labels,body"])
        return [Issue(i["number"], i.get("title", ""), i.get("state", "OPEN"),
                      i.get("stateReason"), [lb["name"] for lb in i.get("labels") or []],
                      i.get("body") or "")
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

    def list_issues(self, label):
        return self.inner.list_issues(label)

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


# --------------------------------------------------------------------------
# Rendering
# --------------------------------------------------------------------------

MAX_OCCURRENCES_SHOWN = 40
MAX_DIGEST_ROWS = 250


def issue_title(g: FindingGroup) -> str:
    msg = normalise_detail(g.message)
    if len(msg) > 110:
        msg = msg[:107] + "…"
    return f"[nightly/{g.tool}] {Path(g.file).name}: {msg}"[:250]


def render_marker(state: dict) -> str:
    return f"<!-- nightly-finding {json.dumps(state, sort_keys=True)} -->"


def render_body(g: FindingGroup, state: dict, run_url: str) -> str:
    lines = sorted({o.line for o in g.occurrences if o.line is not None})
    shown = ", ".join(str(n) for n in lines[:MAX_OCCURRENCES_SHOWN])
    if len(lines) > MAX_OCCURRENCES_SHOWN:
        shown += f", … (+{len(lines) - MAX_OCCURRENCES_SHOWN})"
    details = sorted({normalise_detail(o.message) for o in g.occurrences})
    detail_block = "\n".join(f"> {d}" for d in details[:10])
    if len(details) > 10:
        detail_block += f"\n> … and {len(details) - 10} more variants"
    return "\n".join([
        render_marker(state),
        f"**Tool:** `{g.tool}` · **Rule:** `{g.rule}` · **Severity:** **{g.severity}**",
        f"**File:** `{g.file}`",
        "",
        detail_block,
        "",
        f"**Occurrences when last updated:** {g.count}" + (f" (lines {shown})" if shown else ""),
        "Line numbers are informational only. The fingerprint ignores them, so this issue",
        "follows the finding when code moves.",
        "",
        f"First seen: {state.get('first_seen', '?')} · Run: {run_url or 'n/a'}",
        "",
        "---",
        "_Managed by `tools/nightly_findings_to_issues.py`. It closes itself after the finding "
        f"is absent from {CLOSE_AFTER_NIGHTS} consecutive complete nightly runs. To silence it for good, "
        "add the `wontfix` label (or close it as not planned)._",
    ])


def with_state(body: str, state: dict) -> str:
    """Replace the marker in an existing body, leaving everything else alone."""
    if MARKER_RE.search(body or ""):
        return MARKER_RE.sub(lambda _m: render_marker(state), body, count=1)
    return render_marker(state) + "\n" + (body or "")


DIGEST_FP_CHARS = 8          # 32 bits per fp: ~2,000 entries -> collision odds ~0.05%
GITHUB_BODY_LIMIT = 65536
DIGEST_BODY_BUDGET = 60000   # headroom under GitHub's limit


def digest_fp_blob(fps: Iterable[str]) -> str:
    """Compact membership set for the digest marker: sorted 8-hex prefixes,
    concatenated. 1,700 overflow findings cost ~14 KB, not ~35 KB of JSON."""
    return "".join(sorted({fp[:DIGEST_FP_CHARS] for fp in fps}))


def render_digest(overflow: list[FindingGroup], today: str, run_url: str, cap: int) -> str:
    marker = ("<!-- nightly-findings-digest "
              f"{json.dumps({'v': 2, 'date': today, 'fp8': digest_fp_blob(g.fp for g in overflow)})} -->")
    by_sev: dict[str, int] = {}
    for g in overflow:
        by_sev[g.severity] = by_sev.get(g.severity, 0) + 1
    head = [
        marker,
        f"## {len(overflow)} nightly findings waiting for their own issue",
        "",
        f"The nightly opens at most {cap} issues per night, high severity first. These are the rest, "
        f"as of {today}. They get their own issues on later nights; nothing to do here.",
        "",
        "Severity: " + ", ".join(f"{k} {by_sev[k]}" for k in ("high", "medium", "low") if k in by_sev),
        f"Run: {run_url or 'n/a'}",
        "",
        "| Severity | Tool | File | Finding |",
        "|---|---|---|---|",
    ]
    rows: list[str] = []
    used = sum(len(x) + 1 for x in head) + 300          # reserve for the tail line
    for g in overflow[:MAX_DIGEST_ROWS]:
        msg = normalise_detail(g.message).replace("|", "\\|")
        if len(msg) > 120:
            msg = msg[:117] + "…"
        row = f"| {g.severity} | {g.tool} | `{g.file}` | {msg} (×{g.count}) |"
        if used + len(row) + 1 > DIGEST_BODY_BUDGET:
            break
        rows.append(row)
        used += len(row) + 1
    tail = []
    if len(overflow) > len(rows):
        tail = ["", f"… and {len(overflow) - len(rows)} more. The full list is in the "
                    "`nightly-findings-summary` artifact of the run."]
    return "\n".join(head + rows + tail)


# --------------------------------------------------------------------------
# Planning (pure) and applying (through the seam)
# --------------------------------------------------------------------------


@dataclasses.dataclass
class Action:
    kind: str                      # create | reopen | comment | edit | add_label | close | digest_*
    number: int | None = None
    title: str = ""
    body: str = ""
    labels: list[str] = dataclasses.field(default_factory=list)
    comment: str = ""
    fp: str = ""


@dataclasses.dataclass
class Plan:
    actions: list[Action]
    newly_seen: list[FindingGroup]
    opened: list[str]              # fps getting a new or reopened issue tonight
    overflow: list[FindingGroup]
    skipped_wontfix: list[str]
    commented: list[str]
    missing_counted: list[str]
    closed: list[str]
    held_incomplete: list[str]     # open issues left alone because their tool was incomplete


def labels_for(g: FindingGroup) -> list[str]:
    labels = [BASE_LABEL, g.tool]
    if g.severity == "high":
        labels.append(HIGH_LABEL)
    return labels


def _index_issues(issues: list[Issue]) -> tuple[dict[str, Issue], Issue | None]:
    by_fp: dict[str, Issue] = {}
    digest: Issue | None = None
    for iss in sorted(issues, key=lambda i: i.number):
        if DIGEST_MARKER_RE.search(iss.body or "") or DIGEST_LABEL in iss.labels:
            if digest is None or (iss.is_open and not digest.is_open):
                digest = iss
            continue
        mk = iss.marker
        if not mk or "fp" not in mk:
            continue
        cur = by_fp.get(mk["fp"])
        # Prefer a wontfix issue (Rick's ruling wins), then an open one, then the oldest.
        if cur is None or (iss.is_wontfix and not cur.is_wontfix) or (
                iss.is_open and not cur.is_open and not cur.is_wontfix):
            by_fp[mk["fp"]] = iss
    return by_fp, digest


def _digest_fps(digest: Issue | None) -> set[str]:
    """8-hex prefixes of the fingerprints the last digest listed."""
    if not digest:
        return set()
    m = DIGEST_MARKER_RE.search(digest.body or "")
    if not m:
        return set()
    try:
        blob = json.loads(m.group(1)).get("fp8") or ""
    except json.JSONDecodeError:
        return set()
    k = DIGEST_FP_CHARS
    return {blob[i:i + k] for i in range(0, len(blob), k)}


def plan(groups: dict[str, FindingGroup], issues: list[Issue], complete: dict[str, bool],
         today: str, run_url: str, cap: int = DEFAULT_CAP) -> Plan:
    by_fp, digest = _index_issues(issues)
    prior_digest = _digest_fps(digest)
    actions: list[Action] = []
    newly_seen: list[FindingGroup] = []
    opened: list[str] = []
    overflow: list[FindingGroup] = []
    skipped, commented, missing_counted, closed, held = [], [], [], [], []
    budget = cap

    ordered = sorted(groups.values(),
                     key=lambda g: (SEVERITY_RANK[g.severity], g.tool, g.file, g.fp))
    for g in ordered:
        iss = by_fp.get(g.fp)
        if iss is not None and iss.is_wontfix:
            skipped.append(g.fp)
            continue
        if iss is not None and iss.is_open:
            st = dict(iss.marker or {})
            changed = st.get("digest") != g.detail_digest
            was_missing = bool(st.get("missing_dates"))
            if not (changed or was_missing):
                continue
            old_count, old_sev = st.get("count"), st.get("severity")
            st.update({"digest": g.detail_digest, "count": g.count, "severity": g.severity,
                       "missing_dates": []})
            if changed:
                body = render_body(g, st, run_url)
                note = [f"**Changed in the nightly of {today}.**"]
                if old_sev != g.severity:
                    note.append(f"Severity: {old_sev} → {g.severity}")
                if old_count != g.count:
                    note.append(f"Occurrences: {old_count} → {g.count}")
                if len(note) == 1:
                    note.append("The detail text changed (see the updated description).")
                note.append(f"Run: {run_url or 'n/a'}")
                actions.append(Action("comment", iss.number, comment="\n\n".join(note), fp=g.fp))
                actions.append(Action("edit", iss.number, body=body, fp=g.fp))
                if g.severity == "high" and HIGH_LABEL not in iss.labels:
                    actions.append(Action("add_label", iss.number, labels=[HIGH_LABEL], fp=g.fp))
                commented.append(g.fp)
            else:
                actions.append(Action("edit", iss.number, body=with_state(iss.body, st), fp=g.fp))
            continue
        # No issue yet, or an auto-closed (completed) one: both need the budget.
        is_new = iss is None and g.fp[:DIGEST_FP_CHARS] not in prior_digest
        if is_new or iss is not None:
            newly_seen.append(g)
        if budget <= 0:
            overflow.append(g)
            continue
        budget -= 1
        opened.append(g.fp)
        if iss is None:
            st = {"v": 1, "fp": g.fp, "tool": g.tool, "first_seen": today,
                  "digest": g.detail_digest, "count": g.count, "severity": g.severity,
                  "missing_dates": []}
            actions.append(Action("create", title=issue_title(g), body=render_body(g, st, run_url),
                                  labels=labels_for(g), fp=g.fp))
        else:
            st = dict(iss.marker or {})
            st.update({"digest": g.detail_digest, "count": g.count, "severity": g.severity,
                       "missing_dates": []})
            actions.append(Action("reopen", iss.number,
                                  comment=f"**Reappeared in the nightly of {today}** after being closed. "
                                          f"Run: {run_url or 'n/a'}", fp=g.fp))
            actions.append(Action("edit", iss.number, body=render_body(g, st, run_url), fp=g.fp))

    # Open issues whose finding is absent tonight.
    for fp, iss in sorted(by_fp.items(), key=lambda kv: kv[1].number):
        if fp in groups or not iss.is_open or iss.is_wontfix:
            continue
        st = dict(iss.marker or {})
        tool = st.get("tool", "?")
        if not complete.get(tool, False):
            held.append(fp)
            continue
        dates = list(st.get("missing_dates") or [])
        if today in dates:
            continue                       # this night was already counted
        dates.append(today)
        st["missing_dates"] = dates
        if len(dates) >= CLOSE_AFTER_NIGHTS:
            actions.append(Action("edit", iss.number, body=with_state(iss.body, st), fp=fp))
            actions.append(Action("close", iss.number, fp=fp, comment=(
                f"Not reported by `{tool}` in {CLOSE_AFTER_NIGHTS} consecutive complete nightly runs "
                f"({', '.join(dates[-CLOSE_AFTER_NIGHTS:])}). Closing as fixed. It will reopen "
                f"if the finding comes back. Run: {run_url or 'n/a'}")))
            closed.append(fp)
        else:
            actions.append(Action("edit", iss.number, body=with_state(iss.body, st), fp=fp))
            missing_counted.append(fp)

    # The one digest issue.
    if overflow:
        body = render_digest(overflow, today, run_url, cap)
        if digest is not None and digest.is_open:
            actions.append(Action("digest_edit", digest.number, body=body))
        else:
            actions.append(Action("digest_create", title="[nightly] Findings waiting for their own issue",
                                  body=body, labels=[BASE_LABEL, DIGEST_LABEL]))
    elif digest is not None and digest.is_open:
        actions.append(Action("digest_close", digest.number,
                              comment=f"Nothing is waiting as of {today}: every finding has its own issue "
                                      "or is gone."))

    return Plan(actions, newly_seen, opened, overflow, skipped, commented,
                missing_counted, closed, held)


def ensure_labels(gh, needed: Iterable[str]) -> None:
    have = gh.list_labels()
    for name in sorted(set(needed) - have):
        color, desc = LABEL_COLORS.get(name, ("ededed", "nightly analysis"))
        gh.create_label(name, color, desc)


def apply(p: Plan, gh) -> tuple[dict[str, int], list[str]]:
    """Executes the plan. Returns (fp -> issue number for creates, errors).
    One failed call does not stop the rest; the caller exits non-zero."""
    numbers: dict[str, int] = {}
    errors: list[str] = []
    for a in p.actions:
        try:
            if a.kind in ("create", "digest_create"):
                n = gh.create_issue(a.title, a.body, a.labels)
                if a.fp:
                    numbers[a.fp] = n
            elif a.kind == "reopen":
                gh.reopen(a.number, a.comment)
                numbers[a.fp] = a.number
            elif a.kind == "comment":
                gh.comment(a.number, a.comment)
            elif a.kind in ("edit", "digest_edit"):
                gh.edit_body(a.number, a.body)
            elif a.kind == "add_label":
                gh.add_labels(a.number, a.labels)
            elif a.kind in ("close", "digest_close"):
                gh.close(a.number, a.comment)
        except Exception as exc:          # noqa: BLE001 - report every failure, keep going
            errors.append(f"{a.kind} #{a.number or '-'} {a.fp}: {exc}")
    return numbers, errors


# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------


def build_summary(runs: dict[str, ToolRun], groups: dict[str, FindingGroup], p: Plan,
                  numbers: dict[str, int], errors: list[str], today: str, run_url: str,
                  dry_run: bool, repo: str) -> dict:
    def item(g: FindingGroup) -> dict:
        n = numbers.get(g.fp)
        return {"fp": g.fp, "tool": g.tool, "rule": g.rule, "file": g.file,
                "severity": g.severity, "count": g.count, "title": issue_title(g),
                "issue": n, "url": f"https://github.com/{repo}/issues/{n}" if (n and repo and not dry_run) else None}

    sev_counts = {"high": 0, "medium": 0, "low": 0}
    for g in groups.values():
        sev_counts[g.severity] += 1
    return {
        "v": 1,
        "date": today,
        "run_url": run_url,
        "dry_run": dry_run,
        "tools": {t: {"input": r.input_found, "complete": r.complete, "findings": len(r.findings),
                      "fingerprints": sum(1 for g in groups.values() if g.tool == t), "notes": r.notes}
                  for t, r in runs.items()},
        "fingerprints": len(groups),
        "by_severity": sev_counts,
        "new": [item(g) for g in p.newly_seen],
        "new_high": [item(g) for g in p.newly_seen if g.severity == "high"],
        "opened_or_reopened": len(p.opened),
        "overflow": len(p.overflow),
        "commented": len(p.commented),
        "missing_counted": len(p.missing_counted),
        "closed": len(p.closed),
        "held_incomplete": len(p.held_incomplete),
        "skipped_wontfix": len(p.skipped_wontfix),
        "errors": errors,
    }


def summary_markdown(s: dict) -> str:
    out = ["## Nightly findings → issues" + (" (DRY RUN — nothing written)" if s["dry_run"] else ""), ""]
    if s["new_high"]:
        out.append(f"🔴 **{len(s['new_high'])} new high-severity finding(s)**")
        for it in s["new_high"][:20]:
            if not it["issue"]:
                ref = "(digest)"
            elif s["dry_run"]:
                ref = "(would open)"
            else:
                ref = f"#{it['issue']}"
            out.append(f"- {ref} {it['title']}")
        out.append("")
    out += ["| Tool | Input | Complete | Findings | Fingerprints |", "|---|---|---|---:|---:|"]
    for t, r in s["tools"].items():
        out.append(f"| {t} | {'yes' if r['input'] else 'no'} | {'yes' if r['complete'] else 'no'} "
                   f"| {r['findings']} | {r['fingerprints']} |")
    out += ["", f"Severity: high {s['by_severity']['high']} · medium {s['by_severity']['medium']} · "
                f"low {s['by_severity']['low']}",
            f"Opened/reopened {s['opened_or_reopened']} · digest {s['overflow']} · commented {s['commented']} · "
            f"missing-counted {s['missing_counted']} · closed {s['closed']} · held (tool incomplete) "
            f"{s['held_incomplete']} · wontfix skipped {s['skipped_wontfix']}"]
    if s["errors"]:
        out += ["", f"❌ **{len(s['errors'])} gh error(s)**:"] + [f"- {e}" for e in s["errors"][:20]]
    return "\n".join(out) + "\n"


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
    ap = argparse.ArgumentParser(description="Nightly findings -> GitHub issues")
    ap.add_argument("--artifacts", type=Path, required=True)
    ap.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", ""))
    ap.add_argument("--run-url", default="")
    ap.add_argument("--job-result", action="append", default=[],
                    help="tool=result (success|failure|cancelled|skipped); non-success = incomplete")
    ap.add_argument("--cap", type=int, default=DEFAULT_CAP)
    ap.add_argument("--today", default=_dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%d"))
    ap.add_argument("--summary-out", type=Path, default=Path("nightly-findings-summary.json"))
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)

    workspace = os.environ.get("GITHUB_WORKSPACE")
    runs = collect(args.artifacts, parse_job_results(args.job_result), workspace)
    all_findings = [f for r in runs.values() for f in r.findings]
    groups = group_findings(all_findings)
    complete = {t: r.complete for t, r in runs.items()}

    if gh_factory is not None:
        gh = gh_factory(args.repo)
    else:
        if not args.repo:
            print("::error::--repo (or GITHUB_REPOSITORY) is required")
            return 2
        gh = GhCli(args.repo)
    if args.dry_run:
        gh = DryRunGh(gh)

    errors: list[str] = []
    try:
        issues = gh.list_issues(BASE_LABEL)
    except Exception as exc:              # noqa: BLE001
        print(f"::error::cannot list existing nightly-finding issues: {exc}")
        return 1
    p = plan(groups, issues, complete, args.today, args.run_url, args.cap)
    needed = {lb for a in p.actions for lb in a.labels}
    try:
        if needed:
            ensure_labels(gh, needed)
    except Exception as exc:              # noqa: BLE001
        errors.append(f"labels: {exc}")
    numbers, apply_errors = apply(p, gh)
    errors += apply_errors

    summary = build_summary(runs, groups, p, numbers, errors, args.today, args.run_url,
                            args.dry_run, args.repo)
    args.summary_out.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    md = summary_markdown(summary)
    print(md)
    if isinstance(gh, DryRunGh):
        print(f"dry run: {len(gh.writes)} write(s) suppressed")
        for w in gh.writes[:60]:
            print("  would", *w[:3])
    step = os.environ.get("GITHUB_STEP_SUMMARY")
    if step:
        with open(step, "a", encoding="utf-8") as fh:
            fh.write(md)
    if errors:
        for e in errors:
            print(f"::error::{e}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(run())
