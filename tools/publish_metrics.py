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

It runs at the end of the 4 AM coverage job and of the adversarial confirm job.
Both call it the same way; a run with nothing new commits nothing.

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
from pathlib import Path
from typing import Callable, Dict, List, Optional

REPO = Path(__file__).resolve().parent.parent
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

_COV_NUMS = {"lines": "int", "covered": "int", "pct": "num?",
             "logic_lines": "int", "logic_covered": "int", "logic_pct": "num?", "files": "int"}

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
}


def source_folders() -> set:
    """Folder names the coverage stream may name: the app's top-level source
    folders plus the two synthetic buckets nightly_coverage.py uses."""
    names = {"Core", "(app root)"}
    if APP_SOURCES.is_dir():
        names |= {p.name for p in APP_SOURCES.iterdir() if p.is_dir() and FOLDER_RE.match(p.name)}
    return names


def _check(spec, value, where: str, folders: Optional[set]) -> None:
    def bad(why: str) -> PrivacyError:
        return PrivacyError(f"{where}: {why} (value type {type(value).__name__})")

    if isinstance(spec, str) and spec.endswith("?"):
        if value is None:
            return
        spec = spec[:-1]
    if spec == "int":
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise bad("expected a non-negative integer")
        return
    if spec == "num":
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
            raise bad("expected a finite number")
        return
    if spec == "date":
        if not isinstance(value, str) or not DATE_RE.match(value):
            raise bad("expected a YYYY-MM-DD date")
        return
    if spec == "folder":
        if not isinstance(value, str) or not FOLDER_RE.match(value):
            raise bad("expected a plain source-folder name")
        if folders is not None and value not in folders:
            raise bad("not a source folder of this repo")
        return
    kind = spec[0]
    if kind == "enum":
        if value not in spec[1]:
            raise bad("not an allowed enum value")
        return
    if kind == "opt":
        if value is not None:
            _check(spec[1], value, where, folders)
        return
    if kind == "obj":
        if not isinstance(value, dict):
            raise bad("expected an object")
        if set(value) != set(spec[1]):
            raise PrivacyError(f"{where}: keys {sorted(value)} != allowlist {sorted(spec[1])}")
        for key, sub in spec[1].items():
            _check(sub, value[key], f"{where}.{key}", folders)
        return
    if kind == "list":
        if not isinstance(value, list):
            raise bad("expected a list")
        for i, item in enumerate(value):
            _check(spec[1], item, f"{where}[{i}]", folders)
        return
    if kind == "sev":
        if not isinstance(value, dict) or set(value) != set(SEVERITIES):
            raise bad("expected exactly the P0..P3 severity keys")
        for key in SEVERITIES:
            _check(spec[1], value[key], f"{where}.{key}", folders)
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


# ---------------------------------------------------------------- merge + render

def merge_rows(existing: List[dict], fresh: List[dict]) -> List[dict]:
    """Union keyed by date; a fresh row replaces the published row for its date.
    Days only on the branch (e.g. a coverage JSON since deleted locally) are kept."""
    by_date = {}
    for row in existing:
        if isinstance(row.get("date"), str):
            by_date[row["date"]] = row
    for row in fresh:
        by_date[row["date"]] = row
    return [by_date[d] for d in sorted(by_date)]


def render(rows: List[dict]) -> str:
    return "".join(json.dumps(r, sort_keys=True, separators=(",", ":")) + "\n" for r in rows)


def sanitized_files(fresh: Dict[str, Optional[List[dict]]], existing_dir: Optional[Path],
                    folders: Optional[set]) -> Dict[str, str]:
    """name -> full file text, merged with what is already published, every row
    validated. Raises PrivacyError before anything is written."""
    out = {}
    for name, rows in fresh.items():
        if rows is None:
            continue
        existing = _read_jsonl(existing_dir / name) if existing_dir is not None else []
        merged = merge_rows(existing, rows)
        for row in merged:
            validate(name, row, folders)
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
            say: Callable[[str], None] = print) -> str:
    """Merge, validate, commit and push. Returns "pushed" or "unchanged"."""
    git = git or Git()
    wt = wt.expanduser().resolve()
    ensure_worktree(repo, wt, git)
    for attempt in range(1, PUSH_ATTEMPTS + 1):
        git(wt, "fetch", "--quiet", "origin", FETCH_SPEC)
        git(wt, "reset", "--hard", "--quiet", REMOTE_REF)
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

def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--dry-run", action="store_true", help="print sanitized rows; no git, no writes")
    ap.add_argument("--out-dir", help="write sanitized files into this directory; no git")
    ap.add_argument("--worktree", default=str(DEFAULT_WT))
    ap.add_argument("--coverage-dir", default=str(COVERAGE_DIR))
    ap.add_argument("--adversarial-dir", default=str(ADV_DIR))
    ap.add_argument("--codex-dir", default=str(CODEX_DIR))
    a = ap.parse_args(argv)

    if os.environ.get("VIDEOSCAN_PUBLISH_METRICS") == "0":
        print("OUTCOME skipped: VIDEOSCAN_PUBLISH_METRICS=0")
        return 0
    fresh = build_streams(Path(a.coverage_dir).expanduser(), Path(a.adversarial_dir).expanduser(),
                          Path(a.codex_dir).expanduser())
    available = sorted(k for k, v in fresh.items() if v is not None)
    folders = source_folders()
    try:
        if a.dry_run or a.out_dir:
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
        result = publish(fresh, wt=Path(a.worktree), folders=folders)
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
