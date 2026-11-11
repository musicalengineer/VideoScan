#!/usr/bin/env python3
"""Nightly code-coverage run on the M4 (GH #239, Rick 2026-10-01: "melt M4 at 4am").

Runs AFTER the 2 AM nightly (waits while it is still running), in Debug with
code coverage, into its own derivedData — never touches the nightly's state.

    python3 tools/nightly_coverage.py            # wait for the nightly, then run
    python3 tools/nightly_coverage.py --no-wait  # run now
    python3 tools/nightly_coverage.py --report-only <xcresult> [--core-json <path>]

Output (one sink, START/OUTCOME lines):
    ~/Library/Logs/VideoScan/coverage.log
    ~/Library/Logs/VideoScan/coverage/coverage-<date>.json   per-folder numbers
    ~/Library/Logs/VideoScan/coverage/coverage-<date>.md     human summary
    ~/Library/Logs/VideoScan/coverage/latest.json            for the morning brief
    metrics/coverage.jsonl on the `metrics` branch           via tools/publish_metrics.py
                                                              (folder names + numbers only)

Policy (Rick 2026-10-01): measure every folder; floors/ratchet only for
VideoScanCore, data-risk folders and Hallie answers; SwiftUI views are reported,
never gated. This script MEASURES; gating comes later via the findings tool.

Stdlib only.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LOGS = Path.home() / "Library/Logs/VideoScan"
OUT = LOGS / "coverage"
LOG = LOGS / "coverage.log"
DD = Path.home() / "Library/Caches/VideoScan/coverage-dd"
CORE = REPO / "VideoScan/VideoScanCore"
APP_PREFIX = "VideoScan/VideoScan/"
CORE_PREFIX = "VideoScan/VideoScanCore/Sources/VideoScanCore/"
BUILD_TIMEOUT_S = 3 * 3600
WAIT_LIMIT_S = 4 * 3600

# Folders whose coverage will be gated later (reported with a ★ now).
GATED = {"Core", "Archive", "MediaOps", "FamilyTree", "ArchiveAngel", "Volumes", "Hallie", "Catalog"}


def log(msg: str) -> None:
    LOGS.mkdir(parents=True, exist_ok=True)
    line = f"[{dt.datetime.now().isoformat(timespec='seconds')}] [coverage] {msg}"
    print(line, flush=True)
    with LOG.open("a") as fh:
        fh.write(line + "\n")


def nightly_running() -> bool:
    r = subprocess.run(["pgrep", "-f", "nightly_local_tests.sh|nightly_guarded.sh"],
                       capture_output=True, text=True)
    return r.returncode == 0 and bool(r.stdout.strip())


def wait_for_nightly() -> bool:
    start = time.monotonic()
    while nightly_running():
        if time.monotonic() - start > WAIT_LIMIT_S:
            return False
        time.sleep(60)
    return True


def run(cmd: list[str], cwd: Path, timeout: int, logfile: Path) -> int:
    with logfile.open("w") as fh:
        p = subprocess.Popen(cmd, cwd=cwd, stdout=fh, stderr=subprocess.STDOUT,
                             stdin=subprocess.DEVNULL, start_new_session=True)
        try:
            return p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)
            p.wait()
            return -9


def folder_of(path: str) -> str | None:
    rel = path.split(str(REPO) + "/", 1)[-1]
    if rel.startswith(CORE_PREFIX):
        return "Core"
    if rel.startswith(APP_PREFIX):
        rest = rel[len(APP_PREFIX):]
        return rest.split("/", 1)[0] if "/" in rest else "(app root)"
    return None


_VIEW_CACHE: dict[str, bool] = {}


def is_view(path: str) -> bool:
    """SwiftUI view files are reported, never gated. A file counts as a view when
    its name says so or its source declares a SwiftUI View (`: View` / `some View`)."""
    name = Path(path).name
    if name.endswith(("View.swift", "Sheet.swift", "Card.swift")) or "View+" in name:
        return True
    if path not in _VIEW_CACHE:
        try:
            text = Path(path).read_text(errors="ignore")
            _VIEW_CACHE[path] = ("some View" in text) or (": View {" in text) or (": View," in text)
        except OSError:
            _VIEW_CACHE[path] = False
    return _VIEW_CACHE[path]


def aggregate(files: list[tuple[str, int, int]]) -> dict:
    """files: (path, covered, executable) -> per-folder totals, logic vs views."""
    folders: dict[str, dict] = {}
    for path, cov, exe in files:
        f = folder_of(path)
        if f is None or exe == 0:
            continue
        d = folders.setdefault(f, {"covered": 0, "executable": 0, "logic_covered": 0,
                                   "logic_executable": 0, "files": 0, "zero_files": []})
        d["covered"] += cov
        d["executable"] += exe
        d["files"] += 1
        if not is_view(path):
            d["logic_covered"] += cov
            d["logic_executable"] += exe
            if cov == 0 and exe >= 40:
                d["zero_files"].append(path.split(str(REPO) + "/", 1)[-1])
    for d in folders.values():
        d["pct"] = round(100 * d["covered"] / d["executable"], 1) if d["executable"] else None
        d["logic_pct"] = (round(100 * d["logic_covered"] / d["logic_executable"], 1)
                          if d["logic_executable"] else None)
        d["zero_files"].sort()
    return folders


def app_files(xcresult: Path) -> list[tuple[str, int, int]]:
    r = subprocess.run(["xcrun", "xccov", "view", "--report", "--json", str(xcresult)],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"xccov failed: {r.stderr[:300]}")
    data = json.loads(r.stdout)
    out = []
    for t in data.get("targets", []):
        if "Tests" in t.get("name", ""):
            continue
        for f in t.get("files", []):
            out.append((f["path"], int(f.get("coveredLines", 0)), int(f.get("executableLines", 0))))
    return out


def export_core_coverage(scratch: Path, since: float, run=subprocess.run) -> "Path | None":
    """The Core package's coverage JSON built from the raw profiles, for the nights
    SwiftPM exports none. `swift test --enable-code-coverage` writes its JSON only
    when every test passed; one failed test (2026-11-05 … 11-09: a timing budget
    missed under the instrumented Debug build) and Core vanished from the page's
    coverage number, with one easily missed log line. The .profraw files are
    written whatever the verdict, so merge them and export the same llvm-cov JSON
    SwiftPM would have. Only profiles written at or after `since` (when TODAY's
    Core test run started) count: yesterday's profiles left in the cache after a
    build that failed today are not today's coverage (Codex #275 F7). None when
    there is no such profile or no test binary, or a tool fails. Memory:
    llvm-cov's summary-only JSON (a few hundred KB)."""
    debug = scratch / "debug"

    def fresh(path: Path) -> bool:
        try:
            return path.stat().st_mtime >= since
        except OSError:
            return False

    profiles = [p for p in sorted((debug / "codecov").glob("*.profraw")) if fresh(p)]
    binaries = sorted(debug.glob("*.xctest/Contents/MacOS/*"))
    if not profiles or not binaries:
        return None
    merged = debug / "codecov" / "fallback.profdata"
    out = debug / "codecov" / "fallback.json"
    try:
        merge = run(["xcrun", "llvm-profdata", "merge", "-sparse", *map(str, profiles), "-o", str(merged)],
                    capture_output=True, text=True, timeout=600)
        if merge.returncode != 0:
            return None
        export = run(["xcrun", "llvm-cov", "export", "-summary-only", "-format=text",
                      f"-instr-profile={merged}", str(binaries[0])], capture_output=True, text=True, timeout=600)
        if export.returncode != 0 or not export.stdout.strip():
            return None
        json.loads(export.stdout)                      # a torn export is no export
        out.write_text(export.stdout)
    except (OSError, ValueError, subprocess.SubprocessError):
        return None
    return out


def written_since(path: str, since: float) -> bool:
    """`path` names a file written at or after `since` (today's run), not a leftover."""
    try:
        return bool(path) and Path(path).stat().st_mtime >= since
    except OSError:
        return False


def core_files(codecov_json: Path) -> list[tuple[str, int, int]]:
    data = json.loads(codecov_json.read_text())
    out = []
    for blob in data.get("data", []):
        for f in blob.get("files", []):
            name = f.get("filename", "")
            if "/Sources/VideoScanCore/" not in name:
                continue
            lines = f.get("summary", {}).get("lines", {})
            out.append((name, int(lines.get("covered", 0)), int(lines.get("count", 0))))
    return out


def write_report(folders: dict, meta: dict) -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    day = meta["date"]
    payload = {"meta": meta, "folders": folders}
    (OUT / f"coverage-{day}.json").write_text(json.dumps(payload, indent=2))
    (OUT / "latest.json").write_text(json.dumps(payload, indent=2))
    rows = sorted(folders.items(), key=lambda kv: (kv[0] not in GATED, kv[0]))
    md = [f"# Coverage {day}", "",
          f"Commit `{meta.get('commit')}` · Debug · machine {meta.get('host')} · app tests {meta.get('app_status')} · core tests {meta.get('core_status')}",
          "", "★ = will be gated (floor + no-drop ratchet); views reported only.", "",
          "| Folder | Lines | Covered | All % | Logic % (no views) | Zero-coverage logic files ≥40 lines |",
          "|---|---:|---:|---:|---:|---|"]
    for name, d in rows:
        star = "★ " if name in GATED else ""
        zeros = ", ".join(Path(z).name for z in d["zero_files"][:6]) + (" …" if len(d["zero_files"]) > 6 else "")
        md.append(f"| {star}{name} | {d['executable']} | {d['covered']} | {d['pct']} | {d['logic_pct']} | {zeros} |")
    (OUT / f"coverage-{day}.md").write_text("\n".join(md) + "\n")


def publish_metrics() -> None:
    """Hand the numbers to the one metrics publisher (tools/publish_metrics.py),
    which pushes a sanitized copy (folder names + numbers only) to the public
    `metrics` branch for the metrics page. Never fails the coverage job: a failed
    publish is logged, and tomorrow's run re-reads every coverage-<date>.json."""
    try:
        r = subprocess.run([sys.executable, str(REPO / "tools/publish_metrics.py")],
                           capture_output=True, text=True, timeout=600, stdin=subprocess.DEVNULL)
        lines = (r.stdout or "").strip().splitlines()
        log(f"publish: {lines[-1] if lines else f'no output (exit {r.returncode})'}")
    except (OSError, subprocess.TimeoutExpired) as exc:
        log(f"publish: OUTCOME failed: {exc}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-wait", action="store_true")
    ap.add_argument("--report-only")
    ap.add_argument("--core-json")
    a = ap.parse_args()
    day = dt.date.today().isoformat()
    commit = subprocess.run(["git", "-C", str(REPO), "rev-parse", "--short", "HEAD"],
                            capture_output=True, text=True).stdout.strip()
    host = os.uname().nodename
    meta = {"date": day, "commit": commit, "host": host, "app_status": "skipped", "core_status": "skipped"}

    if a.report_only:
        files = app_files(Path(a.report_only))
        if a.core_json:
            files += core_files(Path(a.core_json))
        write_report(aggregate(files), meta)
        publish_metrics()
        log(f"OUTCOME report-only written for {day}")
        return 0

    log(f"START coverage run on {host} at {commit}")
    if not a.no_wait and not wait_for_nightly():
        log("OUTCOME failed: the nightly was still running after 4 h — skipped")
        return 2

    OUT.mkdir(parents=True, exist_ok=True)
    xcresult = OUT / f"app-{day}.xcresult"
    if xcresult.exists():
        subprocess.run(["rm", "-rf", str(xcresult)])
    app_rc = run(["xcodebuild", "test", "-project", "VideoScan/VideoScan.xcodeproj", "-scheme", "VideoScan",
                  "-configuration", "Debug", "-destination", "platform=macOS,arch=arm64",
                  "-skip-testing:VideoScanUITests", "-enableCodeCoverage", "YES",
                  "-derivedDataPath", str(DD), "-resultBundlePath", str(xcresult)],
                 REPO, BUILD_TIMEOUT_S, OUT / f"app-{day}.log")
    meta["app_status"] = "ok" if app_rc == 0 else f"exit {app_rc} (tests may have failed; coverage still read)"
    log(f"app tests finished: {meta['app_status']}")

    core_started = time.time() - 2          # the profiles this run writes are newer than this
    core_rc = run(["swift", "test", "--package-path", str(CORE), "--enable-code-coverage",
                   "--scratch-path", str(DD / "core-build")],
                  REPO, BUILD_TIMEOUT_S, OUT / f"core-{day}.log")
    meta["core_status"] = "ok" if core_rc == 0 else f"exit {core_rc}"
    log(f"core tests finished: {meta['core_status']}")

    files: list[tuple[str, int, int]] = []
    try:
        if xcresult.exists():
            files += app_files(xcresult)
    except Exception as exc:  # noqa: BLE001 — report, don't die
        log(f"app coverage unreadable: {exc}")
    cov_path = subprocess.run(["swift", "test", "--package-path", str(CORE), "--show-codecov-path",
                               "--scratch-path", str(DD / "core-build")],
                              capture_output=True, text=True).stdout.strip()
    # Today's export only: SwiftPM names the same path every day, and a build that
    # fails today leaves yesterday's JSON there (Codex #276 F7).
    if written_since(cov_path, core_started):
        files += core_files(Path(cov_path))
    else:
        fallback = export_core_coverage(DD / "core-build", since=core_started)
        core = core_files(fallback) if fallback else []
        if core:
            files += core
            log(f"core coverage: SwiftPM exported none ({meta['core_status']}); built from the raw profiles — {len(core)} Core files")
        else:
            meta["core_coverage"] = "missing"
            log("core coverage MISSING: no SwiftPM export and no usable raw profiles — the Core folders are NOT in today's numbers")

    if not files:
        log("OUTCOME failed: no coverage data produced")
        return 1
    folders = aggregate(files)
    write_report(folders, meta)
    publish_metrics()
    total_e = sum(d["executable"] for d in folders.values())
    total_c = sum(d["covered"] for d in folders.values())
    log(f"OUTCOME ok: {len(folders)} folders, {total_c}/{total_e} lines "
        f"({round(100 * total_c / total_e, 1) if total_e else 0}%) → {OUT / f'coverage-{day}.md'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
