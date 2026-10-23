#!/usr/bin/env python3
"""catalog_tests.py — "run the catalog unit tests and regression tests" (Rick, 2026-10-23).

The gauntlet Runner can only pick whole stages (`--only unit,regression`), needs
an away window and a cold Release build, so this is the quick, named lane for
the catalog alone, in Debug (CLAUDE.md "Build mode policy": iteration):

  * app half  — `xcodebuild test` (Debug, NOT parallel: the test plan says
    behaviour tests share state) with `-only-testing:` for every VideoScanTests
    suite whose name starts with `Catalog`, plus the catalog P0 suites in
    EXTRA_APP_SUITES. Counts come from the .xcresult, like the gauntlet.
  * core half — `swift test --filter 'VideoScanCoreTests\\.(<suites>)/'` for
    every VideoScanCore suite whose name starts with Catalog, counted from the
    log with the sensor lane's rules.

Only files the gauntlet manifest assigns to its unit or regression stage are
eligible (blocked there or not — this lane runs in your normal environment,
like the nightly, not the gauntlet's confinement); performance, stress and
hallie suites stay out. Suites are DISCOVERED each run with the gauntlet's own
inventory (`scripts/gauntlet/inventory.swift --discover`), so a new Catalog*
suite joins once the manifest assigns it (inventory --validate insists). Each half must execute at least the declarations of the
files it fully selects (the inventory floor) — a filter that ran 0 tests, or a
nested suite that matched nothing, is RED, never green.

Exit codes: 0 GREEN (all ran, none failed, none skipped) · 1 RED (a failure, a
build failure, or below the floor) · 2 INCOMPLETE (no failures, but tests were
SKIPPED — e.g. ProductionShapeRescanSensorTests off Rick's Mac; a skip is never
reported as a pass).

  scripts/run_catalog_tests.sh                       # both halves
  scripts/run_catalog_tests.sh --list                # what it would run, no build
  scripts/run_catalog_tests.sh --app-only | --core-only
  scripts/run_catalog_tests.sh --derived-data <dir>  # reuse your Debug build

DerivedData defaults to the sensor lane's (~/Library/Caches/videoscan-sensor-dd/
<checkout>) with the same build settings, so one Debug build serves both.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sensor_lane  # noqa: E402  (REPO, PROJECT, CORE_PKG, checkout_key, count)

REPO = sensor_lane.REPO
# Catalog P0 regression suites whose names do not start with "Catalog".
EXTRA_APP_SUITES = ["ProductionShapeRescanSensorTests", "P0TruthRemainingTests",
                    "P0TruthRegressionTests", "P0TruthFixtureTests"]
SKIP_RE = re.compile(r"^\s*(?:➜ Test .+ skipped|Test Case '.+' skipped \()", re.M)
KNOWN_RE = re.compile(r"━ Test (?!run with ).* passed after .* known issue", re.M)  # sensor_lane counts these as passes


def discover(scratch: Path) -> list[dict]:
    out = subprocess.run(["swift", "-module-cache-path", str(scratch / "inventory-cache"),
                          str(REPO / "scripts/gauntlet/inventory.swift"), "--discover", str(REPO)],
                         capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def unit_and_regression_paths() -> set[str]:
    """Files the gauntlet manifest puts in the unit or regression stage (blocked
    there or not): performance / stress / hallie suites stay out of this lane."""
    manifest = json.loads((REPO / "scripts/gauntlet/manifest.json").read_text())
    return {a["path"] for a in manifest["assignments"] if a["stage"] in ("unit", "regression")}


def select(files: list[dict], kind: str, wanted, stages: set[str]) -> tuple[list[str], int]:
    """(suites to run, floor). The floor counts only files whose every suite is
    selected, so it never exceeds what the filter can run."""
    suites: list[str] = []
    floor = 0
    for f in files:
        if f["kind"] != kind or f["path"] not in stages:
            continue
        hits = [s for s in f["suites"] if wanted(s)]
        suites += [s for s in hits if s not in suites]
        if hits and len(hits) == len(f["suites"]):
            floor += len(f["tests"])
    return suites, floor


def run_app(suites: list[str], floor: int, dd: Path, logs: Path) -> tuple[str, str]:
    bundle = logs / f"catalog-app-{int(time.time())}.xcresult"
    args = ["xcodebuild", "test", "-project", str(sensor_lane.PROJECT), "-scheme", "VideoScan",
            "-configuration", "Debug", "-destination", "platform=macOS,arch=arm64",
            "-derivedDataPath", str(dd), "-skip-testing:VideoScanUITests",
            "-parallel-testing-enabled", "NO", "-resultBundlePath", str(bundle),
            "CODE_SIGN_IDENTITY=-", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_ENTITLEMENTS=",
            "ONLY_ACTIVE_ARCH=YES"] + [f"-only-testing:VideoScanTests/{s}" for s in suites]
    log = logs / "catalog-app.log"
    with open(log, "w") as fh:
        rc = subprocess.run(args, stdout=fh, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL).returncode
    summary = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle)],
                             capture_output=True, text=True)
    try:
        s = json.loads(summary.stdout)
        p, f, k, known = s["passedTests"], s["failedTests"], s["skippedTests"], s.get("expectedFailures", 0)
    except (ValueError, KeyError):
        return "red", f"no test counts (xcodebuild rc={rc}) — see {log}"
    names = sensor_lane.count(log.read_text(errors="replace"))[2]
    return verdict("app ", rc, p, f, k, known, floor, names, log)


def run_core(suites: list[str], floor: int, logs: Path) -> tuple[str, str]:
    log = logs / "catalog-core.log"
    # One regex over the selected suites; the "/" stops a suite matching a longer name.
    pattern = r"VideoScanCoreTests\.(" + "|".join(re.escape(s) for s in suites) + ")/"
    with open(log, "w") as fh:
        rc = subprocess.run(["swift", "test", "--package-path", str(sensor_lane.CORE_PKG), "--filter", pattern],
                            stdout=fh, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL).returncode
    text = log.read_text(errors="replace")
    p, f, names = sensor_lane.count(text)
    known = len(KNOWN_RE.findall(text))
    return verdict("core", rc, p - known, f, len(SKIP_RE.findall(text)), known, floor, names, log)


def verdict(half, rc, p, f, k, known, floor, names, log) -> tuple[str, str]:
    line = f"  {half}: {p} passed, {f} failed, {k} skipped, {known} known issues, floor {floor}, rc={rc} — {log}"
    # As in the gauntlet's classify(): a withKnownIssue is a tracked bug, never a pass.
    if f or known or rc != 0 or p + f + known < max(1, floor):
        return "red", line + "".join(f"\n    ✘ {n}" for n in names)
    return ("incomplete" if k else "green"), line


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--list", action="store_true", help="print the selection and floors; build nothing")
    ap.add_argument("--app-only", action="store_true")
    ap.add_argument("--core-only", action="store_true")
    ap.add_argument("--derived-data", default=None)
    ap.add_argument("--log-dir", default=None)
    a = ap.parse_args(argv)

    logs = Path(a.log_dir).expanduser() if a.log_dir else \
        Path(os.environ.get("TMPDIR", "/tmp")) / f"catalog-tests-{sensor_lane.checkout_key()}"
    logs.mkdir(parents=True, exist_ok=True)
    files = discover(logs)
    stages = unit_and_regression_paths()
    app, app_floor = select(files, "xcode", lambda s: s.startswith("Catalog") or s in EXTRA_APP_SUITES, stages)
    core, core_floor = select(files, "package", lambda s: s.startswith("Catalog"), stages)
    missing = [s for s in EXTRA_APP_SUITES if s not in app]
    if missing or not app or not core:
        print(f"CATALOG TESTS RED: discovery found app={len(app)} core={len(core)}; missing {missing}", file=sys.stderr)
        return 1
    print(f"catalog tests (Debug): {len(app)} app suites (floor {app_floor}) + {len(core)} core suites (floor {core_floor})")
    if a.list:
        print("\n".join([f"  VideoScanTests/{s}" for s in app] + [f"  VideoScanCoreTests.{s}" for s in core]))
        return 0

    dd = Path(a.derived_data).expanduser() if a.derived_data else \
        Path.home() / "Library" / "Caches" / "videoscan-sensor-dd" / sensor_lane.checkout_key()
    results = []
    if not a.core_only:
        results.append(run_app(app, app_floor, dd, logs))
    if not a.app_only:
        results.append(run_core(core, core_floor, logs))
    for _, line in results:
        print(line)
    states = {s for s, _ in results}
    if "red" in states:
        print("CATALOG TESTS RED", file=sys.stderr)
        return 1
    if "incomplete" in states:
        print("CATALOG TESTS INCOMPLETE — tests were SKIPPED (not a pass); see the skipped counts above")
        return 2
    print("catalog tests GREEN")
    return 0


if __name__ == "__main__":
    sys.exit(main())
