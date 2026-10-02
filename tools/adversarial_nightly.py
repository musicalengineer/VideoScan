#!/usr/bin/env python3
"""Nightly adversarial review of the day's merges to local main (2026-10-01).

Design: docs/design/nightly_adversarial_review_design_2026-10-01.md
Installed in SHADOW MODE: a review doc, a ledger row and a
morning-brief line only — no issues filed, no codex, no commits.

    python3 tools/adversarial_nightly.py scope   [--range A..B] [--json]
    python3 tools/adversarial_nightly.py brief   [--range A..B] --out DIR
    python3 tools/adversarial_nightly.py run     [--range A..B] [--date YYYY-MM-DD]   (launchd 00:30)
    python3 tools/adversarial_nightly.py confirm [--date YYYY-MM-DD]                  (launchd 05:30)
    python3 tools/adversarial_nightly.py close   --fp <hash> --test <Suite/test> --sha <fix>
    python3 tools/adversarial_nightly.py decline --fp <hash> --reason "…"
    python3 tools/adversarial_nightly.py status  [--json]
    python3 tools/adversarial_nightly.py enable                                       (after a self-disable)

Range: `<state>/last_sha..main`, the baseline advanced ONLY when every brief
ran and parsed (copied from tools/model-fitness/nightly_review.sh), so a failed
night carries its SHAs forward. Scope: `git diff --name-status -M90%`, pure
renames (R100), tests, docs/ and non-Swift dropped, then intersected with the
`paths:` globs in docs/practices/invariants/*.md. Briefs: ≤12 files each, ≤3
per night, grouped by invariants file; overflow is listed as NOT REVIEWED.

Tier A: headless `claude -p` (Opus 5.5, effort xhigh for data-risk, high for
truth), read-only tools, a dollar cap, in a detached scratch worktree under
~/Library/Caches/VideoScan/adv-review/ that is removed afterwards. The answer
must follow codex_review's contract (first line `Credits spent: … | Finding
count: N`, a `Verdict:` line), so codex_review.parse_output()/validate_brief()
work unchanged, plus one `### F<n> — P<0-3> — <title>` block per finding.

Outputs (state dir, default ~/Library/Logs/VideoScan/adversarial-review/):
    ledger.jsonl   one row per run (+ close/decline/confirm events)
    latest.json    what the morning hook reads
    findings.json  every fingerprint ever reported, with its status
    runs/<date>/   briefs, raw answers, parsed findings, the review doc
START/OUTCOME lines go to ~/Library/Logs/VideoScan/adversarial_review.log.
The review doc is staged in the state dir, NOT written into the checkout: the
2 AM nightly tests ~/dev/VideoScan and must find it clean, and an untracked
file there would block a later fast-forward that adds the same path. The
Manager copies it to docs/reviews/adversarial/<date>.md when triaging.

Stop rules: >5 P1 in one run = noisy (flagged); 3 failed nights in a row =
self-disable (flag file; `enable` clears it); the morning line says so.

Stdlib only. Test seams (environment):
    VIDEOSCAN_ADV_REPO        repository (default: this file's repo)
    VIDEOSCAN_ADV_STATE       state dir
    VIDEOSCAN_ADV_LOG         START/OUTCOME log
    VIDEOSCAN_ADV_CACHE       scratch worktree parent
    VIDEOSCAN_CLAUDE_BIN      claude executable (default ~/.local/bin/claude)
    VIDEOSCAN_ADV_TIMEOUT     seconds per brief (default 2400)
    VIDEOSCAN_ADV_NO_GH=1     skip `gh issue list` (no network)
    VIDEOSCAN_REVIEW_CYCLES   honoured by codex_review (review-cycles.json)
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOLS))

import codex_review  # noqa: E402  (parse_output, validate_brief, cycles, kill_group)
import invariants  # noqa: E402

# ---------------------------------------------------------------- settings

# SHADOW MODE (Rick, 2026-10-01): doc + ledger + morning line only. Turning
# filing / Tier B on is a code change reviewed with the shadow-week results,
# not a flag someone flips at 00:30. scripts/adversarial/install.sh refuses to
# install unless this is True.
SHADOW_MODE = True

MODEL = "claude-opus-5-5"
EFFORT = {"data-risk": "xhigh", "truth": "high"}
MAX_BUDGET_USD = 10
MAX_FILES_PER_BRIEF = 12
MAX_BRIEFS = 3
MAX_CALLERS_PER_SYMBOL = 8
MAX_SYMBOLS_PER_FILE = 12
NOISY_P1 = 5
DISABLE_AFTER_FAILURES = 3
DEFAULT_TIMEOUT = 2400          # 40 min wall clock per brief (design §6)
MAX_DIFF_LINES_PER_FILE = 1500
SEVERITIES = ("P0", "P1", "P2", "P3")

FINDING_HEAD_RE = re.compile(
    r"^#{2,4}\s*F(?P<n>\d+)\s*[—–-]+\s*(?P<sev>P[0-3])\s*[—–-]+\s*(?P<title>.+?)\s*$", re.M)
FIELD_RE = re.compile(r"^\s*[-*]\s*(?P<k>File|Invariant|Key|Claim)\s*:\s*(?P<v>.+?)\s*$", re.M | re.I)
SWIFT_BLOCK_RE = re.compile(r"```swift\s*\n(?P<code>.*?)```", re.S)
CLEAN_RE = re.compile(r"read,\s*no findings\s*:?\s*`?(?P<path>[\w./+\-]+\.swift)`?", re.I)


def repo() -> Path:
    override = os.environ.get("VIDEOSCAN_ADV_REPO")
    return Path(override).expanduser() if override else TOOLS.parent


def state_dir() -> Path:
    override = os.environ.get("VIDEOSCAN_ADV_STATE")
    return Path(override).expanduser() if override else (
        Path.home() / "Library" / "Logs" / "VideoScan" / "adversarial-review")


def log_path() -> Path:
    override = os.environ.get("VIDEOSCAN_ADV_LOG")
    return Path(override).expanduser() if override else (
        Path.home() / "Library" / "Logs" / "VideoScan" / "adversarial_review.log")


def cache_dir() -> Path:
    override = os.environ.get("VIDEOSCAN_ADV_CACHE")
    return Path(override).expanduser() if override else (
        Path.home() / "Library" / "Caches" / "VideoScan" / "adv-review")


def claude_bin() -> str:
    return os.environ.get("VIDEOSCAN_CLAUDE_BIN") or str(Path.home() / ".local" / "bin" / "claude")


def brief_timeout() -> float:
    return float(os.environ.get("VIDEOSCAN_ADV_TIMEOUT") or DEFAULT_TIMEOUT)


def invariants_dir() -> Path:
    return repo() / "docs" / "practices" / "invariants"


def declined_path() -> Path:
    return repo() / "docs" / "reviews" / "adversarial" / "declined.jsonl"


def repo_doc_rel(date: str) -> str:
    return f"docs/reviews/adversarial/{date}.md"


def today() -> str:
    return datetime.now().strftime("%Y-%m-%d")


def now_local() -> str:
    return datetime.now().strftime("%Y-%m-%dT%H:%M:%S")


# ---------------------------------------------------------------- one sink

def log_line(kind: str, message: str) -> None:
    """START / PROGRESS / OUTCOME / ERROR lines, one place (design §6)."""
    line = f"{now_local()} {kind} {message}"
    print(line)
    try:
        path = log_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(line + "\n")
    except OSError as error:  # a log failure never fails the run
        print(f"adversarial_nightly: cannot write {log_path()}: {error}", file=sys.stderr)


# ---------------------------------------------------------------- state files

def write_atomic(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def append_jsonl(path: Path, row: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a", encoding="utf-8") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        handle.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")


def read_jsonl(path: Path) -> list[dict]:
    rows = []
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if isinstance(row, dict):
                rows.append(row)
    except OSError:
        pass
    return rows


def read_json(path: Path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


@contextmanager
def state_lock(name: str = "state"):
    sd = state_dir()
    sd.mkdir(parents=True, exist_ok=True)
    with open(sd / f".{name}.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


@contextmanager
def run_lock():
    """One run/confirm at a time; a second one exits instead of waiting."""
    sd = state_dir()
    sd.mkdir(parents=True, exist_ok=True)
    with open(sd / ".run.lock", "a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit("adversarial_nightly: another run holds the lock")
        yield


def ledger_path() -> Path:
    return state_dir() / "ledger.jsonl"


def latest_path() -> Path:
    return state_dir() / "latest.json"


def findings_path() -> Path:
    return state_dir() / "findings.json"


def disabled_path() -> Path:
    return state_dir() / "DISABLED"


def run_dir(date: str) -> Path:
    return state_dir() / "runs" / date


def load_findings() -> dict:
    data = read_json(findings_path(), {})
    return data if isinstance(data, dict) else {}


def save_findings(data: dict) -> None:
    write_atomic(findings_path(), json.dumps(data, indent=2, ensure_ascii=False, sort_keys=True) + "\n")


# ---------------------------------------------------------------- git

def git(*args: str, check: bool = True) -> str:
    result = subprocess.run(["git", "-C", str(repo()), *args], capture_output=True, text=True,
                            stdin=subprocess.DEVNULL)
    if check and result.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {result.stderr.strip()}")
    return result.stdout


def resolve_range(explicit: str | None) -> tuple[str, str, str | None]:
    """Return (range, head, base). Without --range: last_sha..main, falling
    back to main~10 on a first run or a baseline that is not an ancestor."""
    head = git("rev-parse", "main").strip()
    if explicit:
        base = explicit.split("..")[0] if ".." in explicit else None
        end = explicit.split("..")[1] if ".." in explicit else explicit
        end_sha = git("rev-parse", end or "HEAD").strip()
        return explicit, end_sha, base
    last = (state_dir() / "last_sha").read_text().strip() if (state_dir() / "last_sha").exists() else ""
    if last and subprocess.run(["git", "-C", str(repo()), "merge-base", "--is-ancestor", last, head],
                               capture_output=True).returncode == 0:
        return f"{last}..{head}", head, last
    fallback = git("rev-parse", "-q", "--verify", f"{head}~10", check=False).strip()
    if fallback:
        return f"{fallback}..{head}", head, fallback
    return head, head, None


def ends_at_main(head: str) -> bool:
    """Only a range that ends at main moves the baseline (a one-off review of
    an older range must not skip today's merges)."""
    return head == git("rev-parse", "main", check=False).strip()


def advance_baseline(head: str) -> None:
    write_atomic(state_dir() / "last_sha", head + "\n")


# ---------------------------------------------------------------- scope

def parse_name_status(text: str) -> list[dict]:
    """`git diff --name-status -M90%` lines → [{status, path, old}]."""
    entries = []
    for line in text.splitlines():
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        status = parts[0].strip()
        if status.startswith(("R", "C")) and len(parts) >= 3:
            entries.append({"status": status, "old": parts[1], "path": parts[2]})
        else:
            entries.append({"status": status, "old": None, "path": parts[1]})
    return entries


def is_test_path(path: str) -> bool:
    return any("Tests" in part for part in path.split("/"))


def filter_entries(entries: list[dict]) -> tuple[list[dict], dict]:
    """Drop pure renames, deletions, tests, docs/ and non-Swift. Returns
    (kept, dropped-counts) — the counts go into the doc so a filter that
    swallows everything is visible."""
    kept, dropped = [], {"rename": 0, "deleted": 0, "tests": 0, "docs": 0, "non-swift": 0}
    for entry in entries:
        status, path = entry["status"], entry["path"]
        if status == "R100" or (status.startswith("R") and status[1:] == "100"):
            dropped["rename"] += 1
        elif status.startswith("D"):
            dropped["deleted"] += 1
        elif path.startswith("docs/"):
            dropped["docs"] += 1
        elif not path.endswith(".swift"):
            dropped["non-swift"] += 1
        elif is_test_path(path):
            dropped["tests"] += 1
        else:
            kept.append(entry)
    return kept, dropped


def comment_only(diff_text: str) -> bool:
    """True when every changed line is blank or a Swift comment line — nothing
    a reviewer could attack. An empty diff is not comment-only (mode change etc.)."""
    changed = [line[1:].strip() for line in diff_text.splitlines()
               if line[:1] in "+-" and not line.startswith(("+++", "---"))]
    return bool(changed) and all(not c or c.startswith(("//", "/*", "*", "*/")) for c in changed)


def compute_scope(rng: str, inv_files: list | None = None) -> dict:
    inv_files = inv_files if inv_files is not None else invariants.load_all(invariants_dir())
    diff_range = rng if ".." in rng else f"{rng}~1..{rng}"
    raw = git("diff", "--name-status", "-M90%", diff_range)
    kept, dropped = filter_entries(parse_name_status(raw))
    files, out_of_scope = [], []
    dropped["comment-only"] = 0
    for entry in kept:
        covering = invariants.covering(entry["path"], inv_files)
        bucket = invariants.bucket_for(entry["path"], inv_files)
        if not bucket:
            out_of_scope.append(entry["path"])
            continue
        if entry["status"] == "M" and comment_only(git("diff", "-U0", diff_range, "--", entry["path"], check=False)):
            # e.g. the 10-01 docs/ reorg rewrote doc paths in 40 Swift comments
            dropped["comment-only"] += 1
            continue
        primary = next((f for f in covering if f.tier == bucket), covering[0])
        files.append({**entry, "bucket": bucket, "group": primary.name,
                      "invariants": [f.name for f in covering]})
    return {"range": rng, "diffRange": diff_range, "files": files, "dropped": dropped,
            "outOfScope": out_of_scope}


def split_briefs(files: list[dict]) -> tuple[list[list[dict]], list[dict]]:
    """≤MAX_FILES_PER_BRIEF files per brief, ≤MAX_BRIEFS briefs, each brief
    one bucket, grouped by invariants file, data-risk first. Returns
    (briefs, overflow). Overflow is reported, never dropped silently."""
    order = {"data-risk": 0, "truth": 1}
    groups: dict[tuple, list[dict]] = {}
    for f in sorted(files, key=lambda f: (order[f["bucket"]], f["group"], f["path"])):
        groups.setdefault((f["bucket"], f["group"]), []).append(f)
    bins: list[list[dict]] = []
    for (bucket, _group), members in groups.items():
        while members:
            target = next((b for b in bins if b[0]["bucket"] == bucket
                           and len(b) + len(members) <= MAX_FILES_PER_BRIEF), None)
            if target is None:
                take, members = members[:MAX_FILES_PER_BRIEF], members[MAX_FILES_PER_BRIEF:]
                bins.append(list(take))
            else:
                target.extend(members)
                members = []
    return bins[:MAX_BRIEFS], [f for b in bins[MAX_BRIEFS:] for f in b]


# ---------------------------------------------------------------- brief parts

FUNC_RE = re.compile(r"\bfunc\s+([A-Za-z_]\w*)")
TYPE_RE = re.compile(r"\b(?:class|struct|enum|actor|extension|protocol)\s+([A-Za-z_]\w*)")


def file_diff(diff_range: str, entry: dict) -> str:
    paths = [entry["old"], entry["path"]] if entry.get("old") else [entry["path"]]
    return git("diff", "-M90%", diff_range, "--", *paths, check=False)


def changed_symbols(diff_text: str) -> list[str]:
    """func names on added/removed lines and in hunk headers, most-touched first."""
    counts: dict[str, int] = {}
    for line in diff_text.splitlines():
        if line.startswith(("+++", "---")):
            continue
        if line.startswith(("+", "-")) or line.startswith("@@"):
            for name in FUNC_RE.findall(line):
                counts[name] = counts.get(name, 0) + 1
    return [n for n, _ in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))][:MAX_SYMBOLS_PER_FILE]


def callers(symbol: str, head: str, own_path: str) -> list[str]:
    out = git("grep", "-n", "-w", "-I", symbol, head, "--", "*.swift", check=False)
    hits = []
    for line in out.splitlines():
        # "<rev>:<path>:<line>:<text>"
        parts = line.split(":", 3)
        if len(parts) < 4:
            continue
        path, lineno, text = parts[1], parts[2], parts[3]
        if path == own_path or is_test_path(path) or re.search(rf"\bfunc\s+{re.escape(symbol)}\b", text):
            continue
        hits.append(f"{path}:{lineno}")
        if len(hits) >= MAX_CALLERS_PER_SYMBOL:
            break
    return hits


def merge_subjects(rng: str) -> list[str]:
    spec = [rng] if ".." in rng else ["-1", rng]
    out = git("log", "--first-parent", "--format=%h %s", *spec, check=False)
    return [line for line in out.splitlines() if line.strip()][:40]


def green_clauses(subjects: list[str]) -> list[str]:
    found = []
    for subject in subjects:
        for clause in re.findall(r"([^.;:()]*\bgreen\b[^.;()]*)", subject, re.I):
            found.append(f"{subject.split()[0]}: {clause.strip()}")
    return found


def latest_testdriver_row() -> str:
    for ref in ("origin/metrics", "metrics"):
        text = git("show", f"{ref}:metrics/testdriver.jsonl", check=False)
        if not text:
            continue
        rows = [r for r in (json.loads(l) for l in text.splitlines() if l.strip().startswith("{"))
                if r.get("branch", "main") == "main"]
        if rows:
            r = rows[-1]
            return (f"{r.get('ts')} {r.get('source')} {r.get('configuration', '?')} commit {r.get('commit')}: "
                    f"status {r.get('status')} {r.get('reason') or ''} — passed {r.get('passed')}, "
                    f"failed {r.get('failed')}, total {r.get('total')}").strip()
    return "no testdriver row found"


def fingerprint(path: str, symbol: str, invariant: str) -> str:
    return hashlib.sha1(f"{path}#{symbol}#{invariant}".encode()).hexdigest()


def load_declined() -> dict[str, dict]:
    return {r["fp"]: r for r in read_jsonl(declined_path()) if r.get("fp")}


def gh_reported() -> tuple[dict[str, str], str | None]:
    """fp → '#N' for adversarial-review issues; (empty, reason) if gh is off/unavailable."""
    if os.environ.get("VIDEOSCAN_ADV_NO_GH") == "1":
        return {}, "gh lookup disabled"
    try:
        result = subprocess.run(
            ["gh", "issue", "list", "--label", "adversarial-review", "--state", "all",
             "--limit", "200", "--json", "number,body"],
            cwd=repo(), capture_output=True, text=True, timeout=30, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired) as error:
        return {}, f"gh unavailable: {error}"
    if result.returncode != 0:
        return {}, f"gh failed: {result.stderr.strip()[:200]}"
    found = {}
    try:
        for issue in json.loads(result.stdout or "[]"):
            for fp in re.findall(r"adv-fp:([0-9a-f]{40})", issue.get("body") or ""):
                found[fp] = f"#{issue.get('number')}"
    except ValueError:
        return {}, "gh output unreadable"
    return found, None


def already_reported(paths: list[str]) -> list[str]:
    lines = []
    known = load_findings()
    for fp, rec in sorted(known.items()):
        if rec.get("path") in paths:
            lines.append(f"- {fp[:8]} `{rec.get('key')}` — {rec.get('title')} ({rec.get('status')}, first seen {rec.get('firstSeen')})")
    for fp, rec in sorted(load_declined().items()):
        if rec.get("path") in paths and fp not in known:
            lines.append(f"- {fp[:8]} `{rec.get('key')}` — declined: {rec.get('reason')}")
    # Prior review docs that name these files (codex + adversarial), newest first.
    reviews = repo() / "docs" / "reviews"
    docs = sorted(list((repo() / "docs").glob("codex-review-*.md"))      # pre-reorg layout
                  + [p for sub in ("codex", "adversarial", "qa") for p in (reviews / sub).glob("*.md")
                     if p.name.lower() != "readme.md"],
                  key=lambda p: p.name, reverse=True)
    for path in paths:
        base = Path(path).name
        named = [d for d in docs if base in d.read_text(encoding="utf-8", errors="replace")][:4]
        if named:
            rels = ", ".join(str(d.relative_to(repo())) for d in named)
            lines.append(f"- `{base}` was reviewed before in: {rels} (read their findings; do not re-report closed ones)")
    return lines


def contract_text() -> str:
    return """## (i) Output contract (required, exact)
First line exactly: `Credits spent: <amount or unavailable> | Finding count: <N>`
A line: `Verdict: <merge | fix | block> — <one-line reason>`
Then, per finding (N of them, numbered F1…FN):

### F<n> — P<0-3> — <short title>
- File: <repo-relative path>:<line>
- Invariant: <ID from section (d), e.g. FT-3>
- Key: <repo-relative path>#<symbol>#<invariant ID>
- Claim: <the concrete counterexample: inputs, interleaving, what ends up on disk or on screen>

```swift
// target: app        (or: core — VideoScanCore)
// test: <SuiteName>/<testName>
<one self-contained Swift Testing red test: `import Testing`, `@testable import VideoScan`
 (or VideoScanCore), a `@Suite struct <SuiteName>` holding `@Test func <testName>()`.
 It FAILS on the current code when the claim is true and passes once fixed.>
```

P0, P1 and P2 findings MUST carry the swift block; P3 may omit it.
After the findings, one line per in-scope file with nothing to report: `read, no findings: <path>`.

Severity: P0 = family media, the archive or the family record is lost/corrupted in ordinary use; P1 = loss, corruption or a false family fact is reachable; P2 = a narrower or recoverable version; P3 = hardening, logging, coverage.
Red-test rules (a static lint rejects violations, and the test then counts as unconfirmed): synthetic data only, files only under `FileManager.default.temporaryDirectory`; never mention `/Volumes`, `applicationSupportDirectory`, `homeDirectoryForCurrentUser`, `FamilyArchive`, `00_Index` as a real path, `Process(`, `URLSession`, or any absolute path; no UI, no app launch, no network, no sleeps over 2 s.
"""


def build_brief(date: str, index: int, total: int, group: list[dict], scope: dict, head: str,
                inv_files: list, diff_dir_rel: str, diffs: dict[str, str]) -> str:
    bucket = group[0]["bucket"]
    paths = [f["path"] for f in group]
    by_name = {f.name: f for f in inv_files}
    lines = [
        f"Nightly adversarial review {date}, brief {index} of {total} — {bucket}, effort {EFFORT[bucket]}.",
        f"Range {scope['range']} (head {head[:8]}). You are a read-only adversarial reviewer: find ways the code in scope "
        "breaks the invariants below. Report only what you can show with a concrete counterexample.",
        "",
        "## (a) Range and merges",
    ]
    lines += [f"- {s}" for s in merge_subjects(scope["range"])] or ["- (no commits)"]
    lines += ["", "## (b) Files in scope (do not explore outside these files; callers in (c) are for reading only)",
              f"The working directory is a checkout of {head[:8]}. You have Read, Grep and Glob only. Each file's diff "
              f"for this range is at `{diff_dir_rel}/<n>.diff` (listed below) — read it first, then the file."]
    symbols_by_file = {}
    for n, f in enumerate(group, 1):
        syms = changed_symbols(diffs.get(f["path"], ""))
        symbols_by_file[f["path"]] = syms
        renamed = f" (renamed from {f['old']})" if f.get("old") else ""
        lines.append(f"- `{f['path']}`{renamed} [{f['status']}; {', '.join(f['invariants'])}] — diff `{diff_dir_rel}/{n}.diff`"
                     + (f" — changed: {', '.join(syms)}" if syms else ""))
    lines += ["", "## (c) Callers (read-only context, at most 8 per symbol)"]
    any_callers = False
    for path, syms in symbols_by_file.items():
        for sym in syms:
            hits = callers(sym, head, path)
            if hits:
                any_callers = True
                lines.append(f"- `{sym}` ({Path(path).name}): " + ", ".join(hits))
    if not any_callers:
        lines.append("- (no callers outside the files in scope)")
    lines += ["", "## (d) Invariants to attack (rank findings by data-loss / false-fact risk)"]
    for name in sorted({n for f in group for n in f["invariants"]}):
        inv = by_name.get(name)
        if not inv:
            continue
        lines.append(f"### {inv.name} ({inv.tier})")
        lines += [f"{n}. **{i}** {t}" for n, (i, t) in enumerate(inv.invariants, 1)]
        if inv.known_accepted:
            lines.append("Known and accepted (do not report):")
            lines += [f"- {k}" for k in inv.known_accepted]
        lines.append("")
    lines += ["## (e) Already reported (do not re-report; if one still holds unchanged, say `dup of <fp8>` in one line)"]
    lines += already_reported(paths) or ["- nothing reported before for these files"]
    lines += ["", "## (f) Tests already run",
              f"- Latest nightly row for main: {latest_testdriver_row()}"]
    lines += [f"- {c}" for c in green_clauses(merge_subjects(scope["range"]))] or ["- (no 'green' claims in merge subjects)"]
    lines += ["", "## (g) Coverage and logging",
              "For each invariant you attack, name the test that pins it (Grep VideoScan/VideoScanTests and "
              "VideoScan/VideoScanCore/Tests) or say `no pinning test found` — a P3 finding when the invariant is data-risk. "
              "Check logging on the changed paths: actionable START/OUTCOME with context, no flooding, and no person "
              "names, URLs, transcriptions or media paths in logs.",
              "", "## (h) Privacy",
              "Public repo: no real family names, addresses, dates or file paths in any finding or fixture — synthetic data only.",
              "", contract_text()]
    return "\n".join(lines).rstrip() + "\n"


def prepare_briefs(scope: dict, head: str, date: str, out_dir: Path, diff_dir_rel: str) -> list[dict]:
    """Write <out_dir>/<i>/<n>.diff and <out_dir>/brief-<i>.md; return brief records."""
    inv_files = invariants.load_all(invariants_dir())
    groups, overflow = split_briefs(scope["files"])
    scope["notReviewed"] = [f["path"] for f in overflow]
    briefs = []
    for i, group in enumerate(groups, 1):
        diffs = {}
        for n, f in enumerate(group, 1):
            text = file_diff(scope["diffRange"], f)
            lines = text.splitlines()
            if len(lines) > MAX_DIFF_LINES_PER_FILE:
                text = "\n".join(lines[:MAX_DIFF_LINES_PER_FILE]) + (
                    f"\n\n[diff truncated at {MAX_DIFF_LINES_PER_FILE} of {len(lines)} lines — read the file itself]\n")
            diffs[f["path"]] = text
            write_atomic(out_dir / str(i) / f"{n}.diff", text)
        text = build_brief(date, i, len(groups), group, scope, head, inv_files, f"{diff_dir_rel}/{i}", diffs)
        problem = codex_review.validate_brief(text)
        if problem:
            raise RuntimeError(f"brief {i} fails codex_review.validate_brief: {problem}")
        write_atomic(out_dir / f"brief-{i}.md", text)
        briefs.append({"index": i, "bucket": group[0]["bucket"], "effort": EFFORT[group[0]["bucket"]],
                       "files": [f["path"] for f in group], "text": text})
    return briefs


# ---------------------------------------------------------------- parse

def parse_claude_json(stdout: str) -> dict:
    """claude --output-format json → {text, cost, tokens, isError, subtype}. A
    non-JSON stdout is kept as text (a fake or a future format) and fails later
    only if the contract is missing."""
    stdout = stdout.strip()
    data = None
    for candidate in [stdout] + [l for l in reversed(stdout.splitlines()) if l.lstrip().startswith(("{", "["))]:
        try:
            data = json.loads(candidate)
            break
        except ValueError:
            continue
    if data is None:
        return {"text": stdout, "cost": None, "tokens": None, "isError": False, "subtype": "text"}
    if isinstance(data, list):  # stream-ish array: take the result element
        data = next((d for d in reversed(data) if isinstance(d, dict) and d.get("type") == "result"), {})
    if not isinstance(data, dict):
        return {"text": stdout, "cost": None, "tokens": None, "isError": False, "subtype": "text"}
    usage = data.get("usage") or {}
    tokens = sum(int(usage.get(k) or 0) for k in (
        "input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")) or None
    return {"text": data.get("result") or "", "cost": data.get("total_cost_usd"), "tokens": tokens,
            "isError": bool(data.get("is_error")), "subtype": data.get("subtype"),
            "durationMs": data.get("duration_ms"), "turns": data.get("num_turns")}


def parse_findings(text: str) -> list[dict]:
    heads = list(FINDING_HEAD_RE.finditer(text))
    findings = []
    for k, head in enumerate(heads):
        end = heads[k + 1].start() if k + 1 < len(heads) else len(text)
        body = text[head.end():end]
        clean = CLEAN_RE.search(body)
        if clean:  # the trailing "read, no findings" lines belong to no finding
            body = body[:clean.start()]
        fields = {m.group("k").lower(): m.group("v").strip().strip("`") for m in FIELD_RE.finditer(body)}
        file_field = fields.get("file", "")
        path = file_field.split(":")[0].strip()
        inv = (re.match(r"[A-Z]+-\d+", fields.get("invariant", "")) or [None])[0] or fields.get("invariant", "?")
        key = fields.get("key", "")
        key_parts = key.split("#")
        if len(key_parts) == 3 and key_parts[0]:
            path_k, symbol, inv_k = key_parts
        else:
            path_k, symbol, inv_k = path, "?", inv
        swift = SWIFT_BLOCK_RE.search(body)
        code = swift.group("code") if swift else None
        target = test = None
        if code:
            t = re.search(r"//\s*target:\s*(app|core)", code, re.I)
            target = t.group(1).lower() if t else None
            s = re.search(r"//\s*test:\s*([A-Za-z_]\w*)/([A-Za-z_]\w*)", code)
            test = f"{s.group(1)}/{s.group(2)}" if s else None
        findings.append({
            "n": int(head.group("n")), "severity": head.group("sev"), "title": head.group("title"),
            "file": file_field, "path": path_k, "symbol": symbol, "invariant": inv_k,
            "key": f"{path_k}#{symbol}#{inv_k}", "fp": fingerprint(path_k, symbol, inv_k),
            "claim": fields.get("claim"), "redTest": code, "target": target, "test": test,
        })
    return findings


def clean_files(text: str) -> list[str]:
    return sorted({m.group("path") for m in CLEAN_RE.finditer(text)})


def dedupe(findings: list[dict], date: str) -> None:
    """Mark each finding new / dup-of. Fingerprint = sha1(path#symbol#ID)."""
    known = load_findings()
    declined = load_declined()
    issues, _ = gh_reported()
    seen_now: set[str] = set()
    for f in findings:
        fp = f["fp"]
        if fp in seen_now:
            f["dup"] = "same run"
        elif fp in issues:
            f["dup"] = issues[fp]
        elif fp in declined:
            f["dup"] = f"declined: {declined[fp].get('reason')}"
        elif fp in known and known[fp].get("firstSeen") != date:
            f["dup"] = f"{known[fp].get('status')} since {known[fp].get('firstSeen')}"
        else:
            f["dup"] = None
        seen_now.add(fp)


def record_findings(findings: list[dict], date: str) -> None:
    with state_lock("findings"):
        known = load_findings()
        for f in findings:
            rec = known.get(f["fp"]) or {
                "fp": f["fp"], "key": f["key"], "path": f["path"], "invariant": f["invariant"],
                "firstSeen": date, "status": "open"}
            rec.update({"title": f["title"], "severity": f["severity"], "lastSeen": date,
                        "test": f.get("test"), "target": f.get("target")})
            rec.setdefault("runs", [])
            if date not in rec["runs"]:
                rec["runs"].append(date)
            known[f["fp"]] = rec
        save_findings(known)


# ---------------------------------------------------------------- scratch worktree

def add_worktree(head: str, label: str) -> Path:
    parent = cache_dir()
    parent.mkdir(parents=True, exist_ok=True)
    path = parent / f"{label}-{datetime.now().strftime('%Y%m%d-%H%M%S')}-{os.getpid()}"
    git("worktree", "add", "--detach", "--force", str(path), head)
    return path


def remove_worktree(path: Path) -> None:
    git("worktree", "remove", "--force", str(path), check=False)
    if path.exists():
        shutil.rmtree(path, ignore_errors=True)
    git("worktree", "prune", check=False)


def claude_command(effort: str) -> list[str]:
    # Flags verified against `claude --help` (2.1.287) on 2026-10-01.
    # --safe-mode is an addition to the design's command: it stops CLAUDE.md
    # (project AND ~/.claude), hooks and plugins loading into the reviewer, so
    # the brief is the whole instruction and nothing personal rides along.
    return [claude_bin(), "-p", "--model", MODEL, "--effort", effort, "--restricted",
            "--tools", "Read,Grep,Glob", "--strict-mcp-config", "--safe-mode",
            "--permission-mode", "dontAsk", "--no-session-persistence",
            "--max-budget-usd", str(MAX_BUDGET_USD), "--output-format", "json"]


def run_claude(brief_text: str, effort: str, cwd: Path, out: Path, err: Path,
               timeout: float) -> tuple[int | None, str | None]:
    """Run one brief. Returns (exit code, failure reason or None)."""
    with open(out, "w") as o, open(err, "w") as e:
        try:
            # start_new_session ≈ setsid(): the timeout kills claude's whole group.
            proc = subprocess.Popen(claude_command(effort), cwd=cwd, stdin=subprocess.PIPE,
                                    stdout=o, stderr=e, text=True, start_new_session=True)
        except OSError as error:
            return None, f"cannot start claude: {error}"
        try:
            proc.stdin.write(brief_text)
            proc.stdin.close()
        except (BrokenPipeError, OSError):
            pass
        try:
            code = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            codex_review.kill_group(proc)
            return None, f"timeout after {int(timeout)}s"
        except KeyboardInterrupt:
            codex_review.kill_group(proc)
            return None, "interrupted"
    return code, None


# ---------------------------------------------------------------- the run

def write_latest(payload: dict) -> None:
    write_atomic(latest_path(), json.dumps(payload, indent=2, ensure_ascii=False) + "\n")


def consecutive_failures() -> int:
    try:
        return int((state_dir() / "consecutive_failures").read_text().strip() or 0)
    except (OSError, ValueError):
        return 0


def set_failures(n: int) -> None:
    write_atomic(state_dir() / "consecutive_failures", f"{n}\n")


def severity_counts(findings: list[dict], new_only: bool = False) -> dict:
    counts = {s: 0 for s in SEVERITIES}
    for f in findings:
        if new_only and f.get("dup"):
            continue
        counts[f["severity"]] = counts.get(f["severity"], 0) + 1
    return counts


def summary_words(counts: dict, confirmed: int | None) -> str:
    parts = [f"{counts[s]} {s}" for s in SEVERITIES if counts.get(s)]
    text = ", ".join(parts) if parts else "no findings"
    if confirmed is not None:
        text += f" ({confirmed} confirmed-red)"
    return text


def write_doc(path: Path, ctx: dict) -> None:
    counts = ctx["counts"]
    lines = [
        f"# Adversarial review — {ctx['date']} (Tier A, shadow mode)",
        "",
        f"- Range: `{ctx['range']}` (head `{ctx['head'][:8]}`)",
        f"- Tier: A — `claude -p` {MODEL}, effort {', '.join(sorted(set(b['effort'] for b in ctx['briefs'])) or ['-'])}",
        f"- Files in scope: {ctx['filesInScope']} (reviewed {ctx['filesReviewed']}; NOT REVIEWED {len(ctx['notReviewed'])})",
        f"- Dropped by the filter: {ctx['dropped']}",
        f"- Tokens: {ctx['tokens'] if ctx['tokens'] is not None else 'not reported'}",
        f"- Notional cost: ${ctx['cost']:.2f}" if ctx["cost"] is not None else "- Notional cost: not reported",
        f"- Findings: {summary_words(counts, None)}; new {sum(severity_counts(ctx['findings'], True).values())}, "
        f"duplicates {sum(1 for f in ctx['findings'] if f.get('dup'))}",
        "- Confirmed-red: pending (05:30 confirm step)",
        f"- Verdict: {ctx['verdict']}",
        f"- Wall time: {ctx['wall']:.0f} s; run {ctx['startedAt']} (cycles {', '.join('#' + str(c) for c in ctx['cycles'])})",
        f"- Canonical home: `{repo_doc_rel(ctx['date'])}` (the Manager commits it with triage decisions)",
        "",
    ]
    if ctx.get("noisy"):
        lines += [f"**NOISY: {counts['P1']} P1 in one run (> {NOISY_P1}) — read with suspicion; Tier B would be skipped.**", ""]
    if ctx["notReviewed"]:
        lines += ["## NOT REVIEWED (over the 12-files × 3-briefs cap)", ""]
        lines += [f"- `{p}`" for p in ctx["notReviewed"]] + [""]
    lines += ["## Findings", ""]
    if not ctx["findings"]:
        lines += ["None.", ""]
    for f in ctx["findings"]:
        dup = f" — dup ({f['dup']})" if f.get("dup") else ""
        lines += [f"### {f['severity']} — {f['title']}{dup}",
                  f"- fp `{f['fp'][:12]}` · key `{f['key']}` · file `{f['file']}` · brief {f.get('brief')}",
                  f"- Red test: `{f.get('test') or 'none'}` ({f.get('target') or '-'}) — confirm: pending",
                  "", f.get("claim") or "", ""]
    lines += ["## Read, no findings", ""] + ([f"- `{p}`" for p in ctx["clean"]] or ["- (none listed)"]) + [""]
    for b in ctx["briefs"]:
        lines += [f"## Reviewer answer — brief {b['index']} ({b['bucket']}, {b['effort']})", "",
                  (b.get("answer") or "(no answer)").strip(), ""]
    for b in ctx["briefs"]:
        lines += [f"## Brief {b['index']}", "", b["text"].strip(), ""]
    write_atomic(path, "\n".join(lines))


def finish(date: str, status: str, ctx: dict, failure: str | None = None) -> dict:
    """Ledger row + latest.json + OUTCOME line, for every exit path."""
    counts = ctx.get("counts") or {s: 0 for s in SEVERITIES}
    row = {
        "event": "run", "date": date, "status": status, "failure": failure,
        "startedAt": ctx.get("startedAt"), "finishedAt": now_local(), "wallSeconds": round(ctx.get("wall") or 0, 1),
        "range": ctx.get("range"), "head": ctx.get("head"), "tier": "A", "model": MODEL,
        "effort": sorted(set(b["effort"] for b in ctx.get("briefs", []))),
        "filesInScope": ctx.get("filesInScope", 0), "filesReviewed": ctx.get("filesReviewed", 0),
        "notReviewed": ctx.get("notReviewed", []), "briefs": len(ctx.get("briefs", [])),
        "tokens": ctx.get("tokens"), "costUsd": ctx.get("cost"), "findings": counts,
        "newFindings": severity_counts(ctx.get("findings", []), True),
        "confirmedRed": None, "noisy": bool(ctx.get("noisy")), "doc": ctx.get("doc"),
        "cycles": ctx.get("cycles", []), "shadow": SHADOW_MODE,
    }
    append_jsonl(ledger_path(), row)
    write_latest({
        "date": date, "status": status, "failure": failure, "range": ctx.get("range"),
        "findings": counts, "newFindings": row["newFindings"], "confirmedRed": None,
        "filesInScope": row["filesInScope"], "filesReviewed": row["filesReviewed"],
        "notReviewed": len(row["notReviewed"]), "doc": ctx.get("doc"), "repoDoc": repo_doc_rel(date),
        "costUsd": ctx.get("cost"), "tokens": ctx.get("tokens"), "wallSeconds": row["wallSeconds"],
        "noisy": row["noisy"], "finishedAt": row["finishedAt"], "shadow": SHADOW_MODE,
        "disabled": disabled_path().exists(),
    })
    cost = f"${ctx['cost']:.2f}" if ctx.get("cost") is not None else "n/a"
    log_line("OUTCOME", f"run {date} status={status}" + (f" reason={failure!r}" if failure else "")
             + f" range={ctx.get('range')} files={row['filesInScope']} findings={summary_words(counts, None)}"
             + f" cost={cost} tokens={ctx.get('tokens')} wall={row['wallSeconds']}s doc={ctx.get('doc')}")
    return row


def fail_night(date: str, ctx: dict, reason: str) -> int:
    n = consecutive_failures() + 1
    set_failures(n)
    if n >= DISABLE_AFTER_FAILURES:
        write_atomic(disabled_path(), f"{now_local()} disabled after {n} failed nights; last: {reason}\n")
        log_line("ERROR", f"self-disabled after {n} failed nights in a row (run `adversarial_nightly.py enable`)")
    finish(date, "failed", ctx, reason)
    return 1


def run(explicit_range: str | None, date: str | None, keep_worktree: bool = False) -> int:
    date = date or today()
    started = time.monotonic()
    ctx: dict = {"date": date, "startedAt": now_local(), "briefs": [], "findings": [], "cycles": [],
                 "cost": None, "tokens": None, "wall": 0.0}
    if disabled_path().exists():
        reason = disabled_path().read_text().strip()
        log_line("START", f"run {date} — DISABLED, not running ({reason})")
        finish(date, "disabled", ctx, reason)
        return 0
    try:
        rng, head, _base = resolve_range(explicit_range)
    except RuntimeError as error:
        log_line("START", f"run {date}")
        return fail_night(date, ctx, f"range: {error}")
    ctx.update({"range": rng, "head": head})
    scope = compute_scope(rng)
    ctx["filesInScope"] = len(scope["files"])
    log_line("START", f"run {date} range={rng} head={head[:8]} files-in-scope={len(scope['files'])} "
                      f"dropped={scope['dropped']} shadow={SHADOW_MODE}")
    if not scope["files"]:
        if ends_at_main(head):
            advance_baseline(head)
        set_failures(0)
        ctx["wall"] = time.monotonic() - started
        finish(date, "nothing", ctx)
        return 0

    rdir = run_dir(date)
    rdir.mkdir(parents=True, exist_ok=True)
    worktree = None
    try:
        worktree = add_worktree(head, "tierA")
        rel = ".adv-review"
        briefs = prepare_briefs(scope, head, date, worktree / rel, rel)
        for b in briefs:
            write_atomic(rdir / f"brief-{b['index']}.md", b["text"])
        ctx.update({"briefs": briefs, "notReviewed": scope["notReviewed"],
                    "filesReviewed": sum(len(b["files"]) for b in briefs),
                    "doc": str(rdir / f"{date}.md"), "dropped": scope["dropped"]})
        failure = None
        total_cost, total_tokens = 0.0, 0
        cost_seen = tokens_seen = False
        for b in briefs:
            title = f"adv {date} {b['index']}/{len(briefs)}"
            cycle = codex_review.new_cycle(title, rng, ctx["doc"])
            ctx["cycles"].append(cycle["id"])
            out, err = rdir / f"answer-{b['index']}.json", rdir / f"answer-{b['index']}.stderr"
            log_line("PROGRESS", f"brief {b['index']}/{len(briefs)} {b['bucket']} effort={b['effort']} "
                                 f"files={len(b['files'])} cycle=#{cycle['id']}")
            codex_review.update_cycle(cycle["id"], phase="running")
            code, why = run_claude(b["text"], b["effort"], worktree, out, err, brief_timeout())
            stdout = out.read_text(errors="replace") if out.exists() else ""
            parsed = parse_claude_json(stdout) if why is None else {}
            if why is None and code != 0:
                why = f"claude exit {code}" + (f" ({parsed.get('subtype')})" if parsed.get("subtype") else "")
            if why is None and parsed.get("isError"):
                why = f"claude error result ({parsed.get('subtype')})"
            contract = codex_review.parse_output(parsed.get("text", ""), "") if why is None else {}
            if why is None and "failure" in contract:
                why = contract["failure"]
            if parsed.get("cost") is not None:
                total_cost += float(parsed["cost"])
                cost_seen = True
            if parsed.get("tokens") is not None:
                total_tokens += int(parsed["tokens"])
                tokens_seen = True
            if why is not None:
                codex_review.update_cycle(cycle["id"], phase="failed", failure=why)
                failure = failure or f"brief {b['index']}: {why}"
                log_line("ERROR", f"brief {b['index']} failed: {why}")
                if why == "interrupted":
                    break           # a person stopped the run: do not start the next brief
                continue
            b["answer"] = parsed["text"]
            found = parse_findings(parsed["text"])
            for f in found:
                f["brief"] = b["index"]
            if len(found) != contract["findings"]:
                log_line("PROGRESS", f"brief {b['index']}: 'Finding count: {contract['findings']}' but "
                                     f"{len(found)} finding blocks parsed")
            ctx["findings"] += found
            ctx.setdefault("clean", [])
            ctx["clean"] += clean_files(parsed["text"])
            ctx.setdefault("verdicts", []).append(f"{b['index']}: {contract['verdictText']}")
            done = contract["findings"] == 0 and contract["verdict"] == "merge"
            codex_review.update_cycle(cycle["id"], phase="closed" if done else "fixing",
                                      tokens=parsed.get("tokens"), findings=contract["findings"],
                                      verdict=contract["verdict"], **({"closedBy": head[:8]} if done else {}))
        ctx["cost"] = round(total_cost, 4) if cost_seen else None
        ctx["tokens"] = total_tokens if tokens_seen else None
        dedupe(ctx["findings"], date)
        ctx["counts"] = severity_counts(ctx["findings"])
        ctx["noisy"] = ctx["counts"]["P1"] > NOISY_P1
        ctx["verdict"] = "; ".join(ctx.get("verdicts", [])) or "none"
        ctx.setdefault("clean", [])
        ctx["wall"] = time.monotonic() - started
        write_atomic(rdir / "findings.json", json.dumps(ctx["findings"], indent=2, ensure_ascii=False) + "\n")
        write_doc(Path(ctx["doc"]), ctx)
        if failure:
            return fail_night(date, ctx, failure)
        record_findings(ctx["findings"], date)
        if ends_at_main(head):
            advance_baseline(head)
        set_failures(0)
        new = severity_counts(ctx["findings"], True)
        finish(date, "findings" if sum(new.values()) else "clean", ctx)
        return 0
    except Exception as error:  # every failure is a 'failed' night, never silent
        ctx["wall"] = time.monotonic() - started
        return fail_night(date, ctx, f"{type(error).__name__}: {error}")
    finally:
        if worktree is not None and not keep_worktree:
            remove_worktree(worktree)


# ---------------------------------------------------------------- triage

def find_fp(prefix: str) -> str:
    known = load_findings()
    matches = [fp for fp in known if fp.startswith(prefix)]
    if len(prefix) < 8:
        raise SystemExit("--fp needs at least 8 hex characters")
    if len(matches) != 1:
        raise SystemExit(f"--fp {prefix}: {'no' if not matches else 'ambiguous'} match in {findings_path()}")
    return matches[0]


def close_finding(prefix: str, test: str, sha: str) -> int:
    with state_lock("findings"):
        known = load_findings()
        fp = find_fp(prefix)
        known[fp].update({"status": "closed", "closedBy": sha, "pinTest": test, "closedAt": now_local()})
        save_findings(known)
        rec = known[fp]
    append_jsonl(ledger_path(), {"event": "close", "fp": fp, "key": rec["key"], "severity": rec.get("severity"),
                                 "test": test, "sha": sha, "at": now_local(), "kept": True})
    log_line("OUTCOME", f"close {fp[:8]} {rec['key']} test={test} sha={sha}")
    close_cycles_if_done()
    print(f"closed {fp[:8]} {rec['key']}")
    return 0


def decline_finding(prefix: str, reason: str) -> int:
    with state_lock("findings"):
        known = load_findings()
        fp = find_fp(prefix)
        known[fp].update({"status": "declined", "reason": reason, "declinedAt": now_local()})
        save_findings(known)
        rec = known[fp]
    append_jsonl(declined_path(), {"fp": fp, "key": rec["key"], "path": rec.get("path"),
                                   "title": rec.get("title"), "reason": reason, "at": now_local()})
    append_jsonl(ledger_path(), {"event": "decline", "fp": fp, "key": rec["key"],
                                 "severity": rec.get("severity"), "reason": reason, "at": now_local()})
    log_line("OUTCOME", f"decline {fp[:8]} {rec['key']}: {reason}")
    close_cycles_if_done()
    print(f"declined {fp[:8]} {rec['key']} → {declined_path()}")
    return 0


def close_cycles_if_done() -> None:
    """A run's review cycles close once none of its findings is still open."""
    known = load_findings()
    for row in read_jsonl(ledger_path()):
        if row.get("event") != "run" or not row.get("cycles"):
            continue
        date = row["date"]
        open_left = [r for r in known.values() if date in (r.get("runs") or []) and r.get("status") == "open"]
        if open_left:
            continue
        for cid in row["cycles"]:
            cycle = next((c for c in codex_review.load_cycles() if c.get("id") == cid), None)
            if cycle and cycle.get("phase") == "fixing":
                codex_review.update_cycle(cid, phase="closed", closedBy="triaged")


# ---------------------------------------------------------------- status

def status(as_json: bool) -> int:
    rows = read_jsonl(ledger_path())
    runs = [r for r in rows if r.get("event") == "run"]
    known = load_findings()
    kept = [r for r in known.values() if r.get("status") == "closed"]
    declined = [r for r in known.values() if r.get("status") == "declined"]
    cost = sum(float(r.get("costUsd") or 0) for r in runs)
    kept_p12 = sum(1 for r in kept if r.get("severity") in ("P1", "P2"))
    info = {
        "shadow": SHADOW_MODE, "disabled": disabled_path().read_text().strip() if disabled_path().exists() else None,
        "consecutiveFailures": consecutive_failures(),
        "baseline": (state_dir() / "last_sha").read_text().strip() if (state_dir() / "last_sha").exists() else None,
        "runs": len(runs), "open": sum(1 for r in known.values() if r.get("status") == "open"),
        "kept": len(kept), "declined": len(declined), "notionalCostUsd": round(cost, 2),
        "keptP1P2PerDollar": round(kept_p12 / cost, 3) if cost else None,
        "precision": round(len(kept) / (len(kept) + len(declined)), 2) if (kept or declined) else None,
        "latest": read_json(latest_path(), None),
    }
    if as_json:
        print(json.dumps(info, indent=2))
        return 0
    print(f"shadow mode: {'ON' if SHADOW_MODE else 'off'}; "
          + (f"DISABLED: {info['disabled']}" if info["disabled"] else "enabled")
          + f"; consecutive failures {info['consecutiveFailures']}; baseline {info['baseline']}")
    for r in runs[-7:]:
        print(f"  {r.get('date')} {r.get('status'):9} {r.get('range')} files {r.get('filesInScope')} "
              f"{summary_words(r.get('findings') or {}, r.get('confirmedRed'))} cost {r.get('costUsd')}"
              + (f" — {r.get('failure')}" if r.get("failure") else ""))
    print(f"findings: {info['open']} open, {info['kept']} kept, {info['declined']} declined; "
          f"precision {info['precision']}; kept P1/P2 per $ {info['keptP1P2PerDollar']}")
    latest = info["latest"] or {}
    if latest.get("doc"):
        print(f"latest doc: {latest['doc']} → copy to {latest.get('repoDoc')} when triaging")
    return 0


def enable() -> int:
    if disabled_path().exists():
        trash = state_dir() / ".trash"
        trash.mkdir(parents=True, exist_ok=True)
        disabled_path().rename(trash / f"DISABLED.{datetime.now().strftime('%Y%m%d-%H%M%S')}")
    set_failures(0)
    log_line("OUTCOME", "re-enabled by hand")
    print("enabled")
    return 0


# ---------------------------------------------------------------- CLI

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="adversarial_nightly.py", description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("scope")
    p.add_argument("--range", dest="rng")
    p.add_argument("--json", action="store_true")
    p = sub.add_parser("brief")
    p.add_argument("--range", dest="rng")
    p.add_argument("--out", required=True)
    p.add_argument("--date")
    p = sub.add_parser("run")
    p.add_argument("--range", dest="rng")
    p.add_argument("--date")
    p.add_argument("--keep-worktree", action="store_true")
    p = sub.add_parser("confirm")
    p.add_argument("--date")
    p.add_argument("--no-sandbox", action="store_true")
    p.add_argument("--no-app-run", action="store_true",
                   help="build app drafts but do not launch the app-hosted test run")
    p = sub.add_parser("close")
    p.add_argument("--fp", required=True)
    p.add_argument("--test", required=True)
    p.add_argument("--sha", required=True)
    p = sub.add_parser("decline")
    p.add_argument("--fp", required=True)
    p.add_argument("--reason", required=True)
    p = sub.add_parser("status")
    p.add_argument("--json", action="store_true")
    sub.add_parser("enable")
    args = parser.parse_args(argv)

    if args.cmd == "scope":
        rng, head, _ = resolve_range(args.rng)
        scope = compute_scope(rng)
        groups, overflow = split_briefs(scope["files"])
        if args.json:
            print(json.dumps({**scope, "head": head, "briefs": [[f["path"] for f in g] for g in groups],
                              "notReviewed": [f["path"] for f in overflow]}, indent=2))
        else:
            print(f"range {rng} (head {head[:8]}); dropped {scope['dropped']}; out of scope {len(scope['outOfScope'])}")
            for i, g in enumerate(groups, 1):
                print(f"brief {i} ({g[0]['bucket']}, {EFFORT[g[0]['bucket']]}):")
                for f in g:
                    print(f"  {f['status']:5} {f['path']}  [{', '.join(f['invariants'])}]")
            for f in overflow:
                print(f"  NOT REVIEWED {f['path']}")
            if not groups:
                print("nothing in scope")
        return 0
    if args.cmd == "brief":
        rng, head, _ = resolve_range(args.rng)
        scope = compute_scope(rng)
        out = Path(args.out).expanduser().resolve()
        briefs = prepare_briefs(scope, head, args.date or today(), out, str(out))
        print(f"{len(briefs)} brief(s) in {out}; NOT REVIEWED {len(scope.get('notReviewed', []))}")
        return 0
    if args.cmd == "run":
        with run_lock():
            return run(args.rng, args.date, args.keep_worktree)
    if args.cmd == "confirm":
        import adversarial_confirm  # stage 3 lives beside this file
        with run_lock():
            return adversarial_confirm.confirm(args.date or today(), sandbox=not args.no_sandbox,
                                               app_run=not args.no_app_run)
    if args.cmd == "close":
        return close_finding(args.fp, args.test, args.sha)
    if args.cmd == "decline":
        return decline_finding(args.fp, args.reason)
    if args.cmd == "status":
        return status(args.json)
    if args.cmd == "enable":
        return enable()
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
