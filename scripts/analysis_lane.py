#!/usr/bin/env python3
"""analysis_lane.py — the verdicts of the nightly Swift 6 analysis lane (stage 2).

scripts/nightly_analysis_lane.sh runs the tools (clean builds, swiftlint,
periphery, the sanitizers) and hands their logs to one subcommand each. Every
subcommand prints EXACTLY ONE line that carries a number (CLAUDE.md rule 9: a
lane that prints no number is red) and writes <dir>/<stage>.json. `report`
reads those files, applies the rule — a missing result or a result without an
integer `number` is red — and writes latest.json / runs.jsonl / the markdown
report that the morning reads.

  ratchet   --app-log L --core-log L [--app-rc N --core-rc N] [--clean]    warnings vs scripts/warnings_baseline.tsv
  census    --state J                                                        escape hatches (escape_hatch_census.py)
  lint      --report J [--rc N]                                              swiftlint analyze findings
  periphery --report J [--rc N]                                              unused declarations, third-party excluded
  memsafe   --probe-rc N --probe-out F --app-log L --core-log L [--rc …]     -strict-memory-safety diagnostics
  sanitizer --kind thread|address --row J                                    weekly_sanitizer.py's latest-<kind>.json
  report    --dir D --expect ratchet,census,… --latest J --runs J --markdown F
  alert     [--latest J] [--now ISO] [--max-age-hours H]                     the morning lines

The nightly VERIFIES and REPORTS; it never commits (decision 2026-10-25). When
`ratchet` sees a clean build whose counts are below the committed baseline it
says "baseline can be lowered: B → N" and the merging session runs
`warning_ratchet.py update --clean`. The file is never written here.

Stage result JSON: {"stage", "status": ok|red|unavailable, "number": int|null,
"line": str, "detail": [str], "extra": {…}}. `unavailable` is for the one
stage whose tool may not exist on a toolchain (-strict-memory-safety on a
pre-6.2 swiftc): it reads 🟡 with the measured reason, never green, never red.

Memory: logs are read whole (a clean xcodebuild log is ~50–150 MB; the
warning parser is regex over the text, same as warning_ratchet.py); the
stage JSON files are a few KB each.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import shutil
import sys
import tempfile
from collections import Counter
from pathlib import Path
from typing import Dict, List, Optional, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))      # scripts/
import warning_ratchet as wr                                    # noqa: E402
import escape_hatch_census as ehc                               # noqa: E402

REPO = Path(__file__).resolve().parent.parent
BUILD_FAILED_RE = re.compile(r"\*\* (?:TEST )?BUILD FAILED \*\*|error: (?:emit-module|compile) command failed|"
                             r"error: fatalError|xcodebuild: error:")
MEMSAFE_TAG = "StrictMemorySafety"
THIRD_PARTY = {".build", "DerivedData", "SourcePackages", "checkouts"}
LANE_STAGES = ["ratchet", "census", "lint", "periphery", "memsafe"]


# ---------------------------------------------------------------- helpers

def result(stage: str, status: str, number: Optional[int], line: str, detail: Optional[List[str]] = None,
           extra: Optional[dict] = None) -> dict:
    return {"stage": stage, "status": status, "number": number, "line": line,
            "detail": detail or [], "extra": extra or {}}


def emit(res: dict, out_dir: Optional[Path]) -> int:
    print(res["line"], flush=True)
    for d in res["detail"][:12]:
        print(f"    {d}", flush=True)
    if out_dir:
        out_dir.mkdir(parents=True, exist_ok=True)
        (out_dir / f"{res['stage']}.json").write_text(json.dumps(res, indent=1) + "\n")
    return 0 if res["status"] in ("ok", "unavailable") else 1


def log_problem(path: Optional[Path], rc: Optional[int], what: str) -> Optional[str]:
    """Why a build log cannot be trusted, or None."""
    if path is None:
        return f"{what} log not given"
    if not path.exists():
        return f"{what} log missing: {path}"
    if path.stat().st_size == 0:
        return f"{what} log is empty: {path}"
    if rc not in (None, 0):
        return f"{what} build exited {rc}"
    if BUILD_FAILED_RE.search(path.read_text(errors="replace")):
        return f"{what} build FAILED (see {path})"
    return None


def _ours(path_text: str) -> Optional[str]:
    try:
        rel = Path(path_text).resolve().relative_to(REPO)
    except (ValueError, OSError):
        return None
    if THIRD_PARTY.intersection(rel.parts):
        return None
    return rel.as_posix()


# ---------------------------------------------------------------- stages

def ratchet(app_log: Path, core_log: Path, app_rc: Optional[int], core_rc: Optional[int], clean: bool,
            baseline: Path = wr.BASELINE) -> dict:
    stage = "ratchet"
    problems = [p for p in (log_problem(app_log, app_rc, "app"), log_problem(core_log, core_rc, "Core")) if p]
    if problems:
        return result(stage, "red", None, f"ratchet: RED — {'; '.join(problems)}", problems)
    logs = [app_log, core_log]
    red, n, files = wr.check(logs, baseline)
    base_counts, meta = wr.read_baseline(baseline)
    base_total = sum(base_counts.values())
    status = "red" if red else "ok"
    line = (f"ratchet: {n} warning(s) in {files} file(s) — {'RED' if red else 'GREEN'} against the baseline "
            f"({base_total} recorded {meta.get('recorded', '?')})")
    detail = list(red)
    extra: dict = {"baseline_total": base_total, "clean": clean}
    if clean and not red and baseline.exists():
        # Dry-run `update` on a COPY: the same refusal rules the merging session will meet.
        with tempfile.TemporaryDirectory() as d:
            tmp = Path(d) / baseline.name
            shutil.copy(baseline, tmp)
            rc, msgs = wr.update(logs, tmp, force=False, recorded=dt.date.today().isoformat())
            new_total = sum(wr.read_baseline(tmp)[0].values()) if rc == 0 else None
        if rc == 0 and new_total is not None and new_total < base_total:
            line += f"; baseline can be lowered: {base_total} → {new_total} (merging session: warning_ratchet.py update --clean)"
            extra["lowerable_to"] = new_total
        elif rc == 0:
            line += "; baseline is current"
        else:
            line += f"; baseline NOT lowerable: {msgs[0] if msgs else 'update refused'}"
            detail += msgs
    extra["progress_markdown"] = wr.progress(baseline, markdown=True) if baseline.exists() else "(no baseline)"
    extra["categories"] = wr.categorize(logs)
    return result(stage, status, n, line, detail, extra)


def census(state: Optional[Path], swiftlint: str, with_force_unwrap: bool = True) -> dict:
    cur = ehc.census(REPO, swiftlint, with_force_unwrap=with_force_unwrap)
    if not with_force_unwrap:
        cur["red"].append("force-unwrap not counted")
    prev = ehc.load_state(state) if state else None
    line = ehc.summary_line(cur, prev)
    moved = ehc.deltas(prev, cur)
    detail = [f"{'+' if y > x else '−'} {label}: {rel} [{kind}] {x} → {y}" for label, rel, kind, x, y in moved]
    if state:
        state.parent.mkdir(parents=True, exist_ok=True)
        state.write_text(json.dumps(cur, indent=1) + "\n")
    extra = {"kinds": cur["kinds"], "targets": {k: {"total": v["total"], "kinds": v["kinds"]} for k, v in cur["targets"].items()},
             "deltas": moved, "todo": "report mode; ratchet the opt-out kinds once quiet for a week (design §7)"}
    return result("census", "red" if cur["red"] else "ok", cur["total"], line, detail, extra)


def _load_json(path: Optional[Path]) -> Tuple[Optional[object], Optional[str]]:
    """The tool's stdout+stderr land in one file (the watchdog merges them), so
    a `warning:` line from periphery or swiftlint may precede the JSON: parse
    from the first line that opens a JSON value."""
    if path is None or not path.exists():
        return None, f"report missing: {path}"
    text = path.read_text(errors="replace")
    if not text.strip():
        return None, f"report is empty: {path}"
    lines = text.splitlines()
    start = next((i for i, l in enumerate(lines) if l.lstrip()[:1] in ("[", "{")), None)
    if start is None:
        return None, f"report holds no JSON ({lines[0][:120]}): {path}"
    try:
        return json.loads("\n".join(lines[start:])), None
    except ValueError as e:
        return None, f"report is not JSON ({e}): {path}"


def lint(report: Optional[Path], rc: Optional[int]) -> dict:
    """swiftlint analyze --reporter json: a list of violations with absolute `file`."""
    stage = "lint"
    rows, why = _load_json(report)
    if why or not isinstance(rows, list):
        return result(stage, "red", None, f"swiftlint analyze: RED — {why or 'report is not a list'}")
    if rc not in (None, 0, 2):           # 2 = violations at error severity; anything else is the tool failing
        return result(stage, "red", None, f"swiftlint analyze: RED — swiftlint exited {rc}")
    by_rule: Counter = Counter()
    by_file: Counter = Counter()
    for r in rows:
        rel = _ours(str(r.get("file", "")))
        if not rel:
            continue
        by_rule[r.get("rule_id", "?")] += 1
        by_file[rel] += 1
    n = sum(by_rule.values())
    rules = ", ".join(f"{k} {v}" for k, v in by_rule.most_common()) or "none"
    line = f"swiftlint analyze: {n} finding(s) in {len(by_file)} file(s) ({rules})"
    detail = [f"{p} ({c})" for p, c in by_file.most_common(10)]
    return result(stage, "ok", n, line, detail, {"by_rule": dict(by_rule)})


def periphery(report: Optional[Path], rc: Optional[int]) -> dict:
    """periphery scan --format json: a list of {location: "path:line:col", kind, name, …}."""
    stage = "periphery"
    rows, why = _load_json(report)
    if why or not isinstance(rows, list):
        return result(stage, "red", None, f"periphery: RED — {why or 'report is not a list'}")
    if rc not in (None, 0):
        return result(stage, "red", None, f"periphery: RED — periphery exited {rc}")
    by_kind: Counter = Counter()
    by_file: Counter = Counter()
    third_party = 0
    for r in rows:
        loc = str(r.get("location", ""))
        rel = _ours(loc.split(":", 1)[0]) if loc else None
        if not rel:
            third_party += 1
            continue
        by_kind[str(r.get("kind", "?")).replace("var.instance", "property").replace("function.method.instance", "method")] += 1
        by_file[rel] += 1
    n = sum(by_kind.values())
    kinds = ", ".join(f"{k} {v}" for k, v in by_kind.most_common(6)) or "none"
    line = f"periphery: {n} unused declaration(s) in {len(by_file)} file(s) ({kinds}; {third_party} third-party excluded)"
    detail = [f"{p} ({c})" for p, c in by_file.most_common(10)]
    return result(stage, "ok", n, line, detail, {"by_kind": dict(by_kind), "third_party_excluded": third_party})


def memsafe(probe_rc: Optional[int], probe_out: Optional[Path], app_log: Optional[Path], core_log: Optional[Path],
            app_rc: Optional[int], core_rc: Optional[int]) -> dict:
    stage = "memsafe"
    probe_text = probe_out.read_text(errors="replace") if probe_out and probe_out.exists() else ""
    version = next((l for l in probe_text.splitlines() if "Swift version" in l), "swiftc version unknown")
    if probe_rc not in (None, 0):
        return result(stage, "unavailable", None,
                      f"memsafe: n/a — this swiftc rejects -strict-memory-safety ({version.strip()})", [probe_text[-300:]])
    if probe_text and MEMSAFE_TAG not in probe_text and "unsafe" not in probe_text:
        return result(stage, "unavailable", None,
                      f"memsafe: n/a — swiftc accepted -strict-memory-safety but did not diagnose the probe ({version.strip()}); counts would not be evidence")
    problems = [p for p in (log_problem(app_log, app_rc, "app"), log_problem(core_log, core_rc, "Core")) if p]
    if problems:
        return result(stage, "red", None, f"memsafe: RED — {'; '.join(problems)}", problems)
    diags = {d for d in wr.parse_logs([p for p in (app_log, core_log) if p]) if MEMSAFE_TAG in d[3] or "unsafe" in d[3]}
    by_file = Counter(d[0] for d in diags)
    line = f"memsafe: {len(diags)} -strict-memory-safety diagnostic(s) in {len(by_file)} file(s)"
    detail = [f"{p} ({c})" for p, c in by_file.most_common(10)]
    return result(stage, "ok", len(diags), line, detail, {"by_file": dict(by_file)})


def sanitizer(kind: str, row_path: Optional[Path]) -> dict:
    stage = f"sanitizer-{kind}"
    row, why = _load_json(row_path)
    if why or not isinstance(row, dict):
        return result(stage, "red", None, f"sanitizer {kind}: RED — {why or 'row is not an object'}")
    status = row.get("status", "?")
    findings = row.get("unique_findings") or []
    tests = int(row.get("tests") or 0)
    detail = list(findings[:8])
    if status == "tests-failed":
        detail += [f"failed: {n}" for n in (row.get("failed_tests") or [])[:8]]
    cfg = row.get("configuration", "?")
    targets = ",".join(row.get("targets") or ["app"])
    subset = row.get("subset", "full")
    line = (f"sanitizer {kind}: {len(findings)} unique finding(s), {tests} tests ({targets}, {cfg}, {subset}) — "
            f"{'GREEN' if status == 'ok' else 'RED: ' + str(status)} — log {row.get('log', '?')}")
    return result(stage, "ok" if status == "ok" else "red", len(findings) if tests or findings else None, line, detail,
                  {"status": status, "tests": tests, "elapsed": row.get("finished")})


# ---------------------------------------------------------------- report

def verdict(results: Dict[str, Optional[dict]], expected: List[str]) -> Tuple[str, List[str]]:
    """Lane status and the red reasons. Rule 9: a missing stage result or one
    without an integer number is red, whatever its own status says."""
    reasons: List[str] = []
    yellow = False
    for stage in expected:
        r = results.get(stage)
        if r is None:
            reasons.append(f"{stage}: no result (the stage did not run or wrote nothing)")
            continue
        if r.get("status") == "unavailable":
            yellow = True
            continue
        if not isinstance(r.get("number"), int) or isinstance(r.get("number"), bool):
            reasons.append(f"{stage}: printed no number — {r.get('line', '')}")
            continue
        if r.get("status") != "ok":
            reasons.append(f"{stage}: {r.get('line', 'red')}")
    if reasons:
        return "red", reasons
    return ("yellow" if yellow else "ok"), []


def report(stage_dir: Path, expected: List[str], latest: Path, runs: Optional[Path], markdown: Optional[Path],
           commit: str, host: str, elapsed_s: Optional[float]) -> dict:
    results: Dict[str, Optional[dict]] = {}
    for stage in expected:
        p = stage_dir / f"{stage}.json"
        try:
            results[stage] = json.loads(p.read_text())
        except (OSError, ValueError):
            results[stage] = None
    status, reasons = verdict(results, expected)
    icon = {"ok": "🟢", "yellow": "🟡", "red": "🔴"}[status]
    numbers = " · ".join(f"{s} {results[s]['number'] if results.get(s) and isinstance(results[s].get('number'), int) else '—'}"
                         for s in expected)
    headline = f"{icon} Swift 6 analysis lane {status.upper()} ({commit}, {host}): {numbers}"
    today = dt.date.today().isoformat()
    row = {"date": today, "ts": dt.datetime.now().astimezone().isoformat(timespec="seconds"), "status": status,
           "commit": commit, "host": host, "elapsed_s": elapsed_s, "headline": headline, "reasons": reasons,
           "stages": {s: ({k: v for k, v in r.items() if k != "extra"} if r else None) for s, r in results.items()},
           "report": str(markdown) if markdown else None}
    latest.parent.mkdir(parents=True, exist_ok=True)
    latest.write_text(json.dumps(row, indent=1) + "\n")
    if runs:
        with runs.open("a") as fh:
            fh.write(json.dumps(row) + "\n")
    if markdown:
        md = [f"# Swift 6 analysis lane — {today} ({commit}, {host})", "", headline, ""]
        if reasons:
            md += ["## Red", ""] + [f"- {r}" for r in reasons] + [""]
        md += ["## Stages", ""]
        for s in expected:
            r = results.get(s)
            md.append(f"- {r['line'] if r else s + ': no result'}")
            for d in (r or {}).get("detail", [])[:12]:
                md.append(f"    - {d}")
        md.append("")
        rt = results.get("ratchet") or {}
        if rt.get("extra", {}).get("progress_markdown"):
            md += [rt["extra"]["progress_markdown"], "", "### Categories (tonight's clean build)", "",
                   "```", rt["extra"].get("categories", ""), "```", ""]
        cs = results.get("census") or {}
        if cs.get("extra"):
            md += ["## Escape hatches", "", "| target | " + " | ".join(ehc.KINDS) + " | total |",
                   "|---|" + "---|" * (len(ehc.KINDS) + 1)]
            for label, t in cs["extra"].get("targets", {}).items():
                md.append(f"| {label} | " + " | ".join(str(t['kinds'].get(k, 0)) for k in ehc.KINDS) + f" | {t['total']} |")
            md += ["", cs["extra"].get("todo", ""), ""]
        md += ["", "The nightly verifies and reports; it never writes `scripts/warnings_baseline.tsv` "
               "(the merging session lowers it with `warning_ratchet.py update --clean`)."]
        markdown.parent.mkdir(parents=True, exist_ok=True)
        markdown.write_text("\n".join(md) + "\n")
    return row


def alert_lines(row: Optional[dict], now: dt.datetime, max_age_hours: float = 36) -> List[str]:
    """Morning lines. Quiet with no row at all (another Mac). 🟡 stale, 🔴 red
    with the reasons, one plain line when green."""
    if not row:
        return []
    try:
        ts = dt.datetime.fromisoformat(row["ts"])
    except (KeyError, ValueError):
        return [f"🔴 Swift 6 analysis lane: latest.json unreadable ({row.get('date', '?')})"]
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=dt.timezone.utc)
    age_h = (now - ts).total_seconds() / 3600
    if age_h > max_age_hours:
        return [f"🟡 Swift 6 analysis lane has not run for {age_h / 24:.1f} days (last {row.get('date', '?')}, {row.get('status', '?')})"]
    out = [row.get("headline", f"Swift 6 analysis lane {row.get('status', '?')}")]
    if row.get("status") == "red":
        out += [f"   ✘ {r}" for r in (row.get("reasons") or [])[:6]]
        if row.get("report"):
            out.append(f"   report: {row['report']}")
    return out


# ---------------------------------------------------------------- CLI

def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out-dir", type=Path, default=None, help="where <stage>.json goes")
    sub = ap.add_subparsers(dest="cmd", required=True)

    r = sub.add_parser("ratchet")
    r.add_argument("--app-log", type=Path, required=True); r.add_argument("--core-log", type=Path, required=True)
    r.add_argument("--app-rc", type=int, default=None); r.add_argument("--core-rc", type=int, default=None)
    r.add_argument("--clean", action="store_true", help="the logs are from CLEAN builds: probe whether the baseline could be lowered")
    r.add_argument("--baseline", type=Path, default=wr.BASELINE)

    c = sub.add_parser("census")
    c.add_argument("--state", type=Path, default=None); c.add_argument("--swiftlint", default="swiftlint")
    c.add_argument("--no-force-unwrap", action="store_true")

    for name in ("lint", "periphery"):
        p = sub.add_parser(name); p.add_argument("--report", type=Path, required=True); p.add_argument("--rc", type=int, default=None)

    m = sub.add_parser("memsafe")
    m.add_argument("--probe-rc", type=int, default=None); m.add_argument("--probe-out", type=Path, default=None)
    m.add_argument("--app-log", type=Path, default=None); m.add_argument("--core-log", type=Path, default=None)
    m.add_argument("--app-rc", type=int, default=None); m.add_argument("--core-rc", type=int, default=None)

    s = sub.add_parser("sanitizer")
    s.add_argument("--kind", choices=["thread", "address"], required=True); s.add_argument("--row", type=Path, required=True)

    rp = sub.add_parser("report")
    rp.add_argument("--dir", type=Path, required=True); rp.add_argument("--expect", required=True, help="comma-separated stages")
    rp.add_argument("--latest", type=Path, required=True); rp.add_argument("--runs", type=Path, default=None)
    rp.add_argument("--markdown", type=Path, default=None); rp.add_argument("--commit", default="?")
    rp.add_argument("--host", default="?"); rp.add_argument("--elapsed", type=float, default=None)

    al = sub.add_parser("alert")
    al.add_argument("--latest", type=Path, default=Path.home() / "Library/Logs/VideoScan/swift6-analysis/latest.json")
    al.add_argument("--now", default=None); al.add_argument("--max-age-hours", type=float, default=36)
    a = ap.parse_args(argv)

    if a.cmd == "ratchet":
        return emit(ratchet(a.app_log, a.core_log, a.app_rc, a.core_rc, a.clean, a.baseline), a.out_dir)
    if a.cmd == "census":
        return emit(census(a.state, a.swiftlint, with_force_unwrap=not a.no_force_unwrap), a.out_dir)
    if a.cmd == "lint":
        return emit(lint(a.report, a.rc), a.out_dir)
    if a.cmd == "periphery":
        return emit(periphery(a.report, a.rc), a.out_dir)
    if a.cmd == "memsafe":
        return emit(memsafe(a.probe_rc, a.probe_out, a.app_log, a.core_log, a.app_rc, a.core_rc), a.out_dir)
    if a.cmd == "sanitizer":
        return emit(sanitizer(a.kind, a.row), a.out_dir)
    if a.cmd == "report":
        expected = [s for s in a.expect.split(",") if s]
        row = report(a.dir, expected, a.latest, a.runs, a.markdown, a.commit, a.host, a.elapsed)
        print(row["headline"])
        for s in expected:
            st = (row["stages"].get(s) or {})
            print(f"  {st.get('line', s + ': no result')}")
        for reason in row["reasons"]:
            print(f"  ✘ {reason}", file=sys.stderr)
        return 1 if row["status"] == "red" else 0
    if a.cmd == "alert":
        try:
            row = json.loads(a.latest.read_text())
        except (OSError, ValueError):
            return 0
        now = dt.datetime.fromisoformat(a.now) if a.now else dt.datetime.now().astimezone()
        if now.tzinfo is None:
            now = now.replace(tzinfo=dt.timezone.utc)
        for line in alert_lines(row, now, a.max_age_hours):
            print(line)
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
