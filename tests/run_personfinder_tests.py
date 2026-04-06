#!/usr/bin/env python3
"""
Manifest-driven sanity/regression runner for VideoScan person-finder fixtures.

This is intentionally outside the app binary:
- easy to run in a loop from CLI
- easy to use in CI later
- same fixture manifest can be wrapped by Xcode tests if desired
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any


def load_manifest(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def abs_path(root: Path, maybe_relative: str) -> str:
    p = Path(maybe_relative)
    if not p.is_absolute():
        p = root / p
    return str(p.resolve())


def build_command(root: Path, defaults: dict[str, Any], case: dict[str, Any]) -> tuple[list[str], list[str]]:
    cfg = defaults | case
    python = abs_path(root, cfg["python"]) if "python" in cfg else sys.executable
    script = abs_path(root, cfg["script"])
    required_paths = [python, script]

    if cfg.get("self_test"):
        return [python, script, "--self-test"], required_paths

    ref_path = abs_path(root, cfg["ref_path"])
    video = abs_path(root, cfg["video"])
    required_paths.extend([ref_path, video])

    return [
        python,
        script,
        "--ref-path", ref_path,
        "--video", video,
        "--threshold", str(cfg["threshold"]),
        "--frame-step", str(cfg["frame_step"]),
        "--min-conf", str(cfg["min_conf"]),
        "--pad", str(cfg["pad"]),
        "--min-duration", str(cfg["min_duration"]),
    ], required_paths


def check_expectations(result: dict[str, Any], expect: dict[str, Any]) -> list[str]:
    failures: list[str] = []

    expected_error = expect.get("error", None)
    actual_error = result.get("error")
    if expected_error is None:
        if actual_error is not None:
            failures.append(f"expected no error, got {actual_error!r}")
    elif actual_error != expected_error:
        failures.append(f"expected error {expected_error!r}, got {actual_error!r}")

    numeric_fields = [
        ("faces_detected_min", "faces_detected"),
        ("hits_min", "hits"),
        ("segments_min", None),
    ]
    for expect_key, result_key in numeric_fields:
        if expect_key not in expect:
            continue
        minimum = expect[expect_key]
        actual = len(result.get("segments", [])) if result_key is None else result.get(result_key, 0)
        if actual < minimum:
            failures.append(f"expected {expect_key}={minimum}, got {actual}")

    if "best_dist_max" in expect:
        best_dist = result.get("best_dist")
        if best_dist is None or best_dist > expect["best_dist_max"]:
            failures.append(f"expected best_dist <= {expect['best_dist_max']}, got {best_dist}")

    return failures


def run_case(root: Path, defaults: dict[str, Any], case: dict[str, Any]) -> dict[str, Any]:
    timeout = int(case.get("timeout_sec", defaults.get("timeout_sec", 120)))
    max_rss_mb = str(case.get("max_rss_mb", defaults.get("max_rss_mb", 4096)))
    cmd, required_paths = build_command(root, defaults, case)

    missing = [path for path in required_paths if not Path(path).exists()]
    if missing:
        return {
            "name": case["name"],
            "ok": True,
            "skipped": True,
            "skip_reason": f"missing required path(s): {', '.join(missing)}",
        }

    # Propagate memory ceiling to the child process
    env = os.environ.copy()
    env["FACE_RECOG_MAX_RSS_MB"] = max_rss_mb

    started = time.monotonic()
    proc = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=timeout,
        cwd=root,
        env=env,
    )
    elapsed = time.monotonic() - started

    try:
        payload = json.loads(proc.stdout.strip())
    except json.JSONDecodeError as exc:
        return {
            "name": case["name"],
            "ok": False,
            "elapsed_sec": round(elapsed, 2),
            "returncode": proc.returncode,
            "failures": [f"stdout was not valid JSON: {exc}"],
            "stderr_tail": proc.stderr.strip().splitlines()[-10:],
        }

    failures = []
    if proc.returncode != 0 and payload.get("error") is None:
        failures.append(f"process exited with code {proc.returncode} but payload had no error")

    failures.extend(check_expectations(payload, case.get("expect", {})))

    return {
        "name": case["name"],
        "ok": not failures,
        "elapsed_sec": round(elapsed, 2),
        "returncode": proc.returncode,
        "result": payload,
        "failures": failures,
        "stderr_tail": proc.stderr.strip().splitlines()[-10:],
    }


def print_summary(case_result: dict[str, Any]) -> None:
    if case_result.get("skipped"):
        print(f"[SKIP] {case_result['name']}")
        print(f"  {case_result['skip_reason']}")
        return

    status = "PASS" if case_result["ok"] else "FAIL"
    print(f"[{status}] {case_result['name']}  {case_result['elapsed_sec']:.2f}s")
    if "result" in case_result:
        result = case_result["result"]
        print(
            "  "
            f"faces={result.get('faces_detected', 0)}  "
            f"hits={result.get('hits', 0)}  "
            f"segments={len(result.get('segments', []))}  "
            f"best_dist={result.get('best_dist')}"
        )
    for failure in case_result.get("failures", []):
        print(f"  {failure}")
    if case_result.get("stderr_tail") and not case_result["ok"]:
        print("  stderr:")
        for line in case_result["stderr_tail"]:
            print(f"    {line}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--manifest",
        default="./tests/personfinder_cases.json",
        help="Path to the JSON test manifest",
    )
    parser.add_argument(
        "--case",
        action="append",
        default=[],
        help="Run only the named case(s)",
    )
    parser.add_argument(
        "--json-report",
        default="",
        help="Optional path to write the full result report as JSON",
    )
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[1]
    manifest_path = Path(args.manifest)
    if not manifest_path.is_absolute():
        manifest_path = (root / manifest_path).resolve()

    manifest = load_manifest(manifest_path)
    defaults = manifest.get("defaults", {})
    cases = manifest.get("cases", [])
    if args.case:
        selected = set(args.case)
        cases = [case for case in cases if case["name"] in selected]

    if not cases:
        print("No test cases selected.", file=sys.stderr)
        return 2

    report = []
    failed = 0
    skipped = 0
    for case in cases:
        result = run_case(root, defaults, case)
        report.append(result)
        print_summary(result)
        if result.get("skipped"):
            skipped += 1
        elif not result["ok"]:
            failed += 1

    if args.json_report:
        out_path = Path(args.json_report)
        if not out_path.is_absolute():
            out_path = (root / out_path).resolve()
        out_path.write_text(json.dumps(report, indent=2), encoding="utf-8")

    print("")
    passed = len(report) - failed - skipped
    print(f"Ran {len(report)} case(s): {passed} passed, {skipped} skipped, {failed} failed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
