#!/usr/bin/env python3
"""Run the Archive Angel performance testbed and print its table.

Rick 2026-09-19: "build a small testbed that tries mimicking various AA
activities so we can get real numbers and find where the dials are" — after
robustness. The testbed itself is ArchiveAngelTestbed (VideoScanTests); this
drives it through xcodebuild (Release, for production-parity numbers, per
the build-mode policy) and prints report.md.

    python3 scripts/angel_testbed.py                      # 30 s clips, all formats, lossless on
    python3 scripts/angel_testbed.py --seconds 30,120 --formats mov,mxf
    python3 scripts/angel_testbed.py --lossless off --debug

Fixtures are synthetic (ffmpeg test patterns), cached in
~/Library/Logs/VideoScan/angel-testbed/fixtures/. Reports go to
~/Library/Logs/VideoScan/angel-testbed/<run-id>/report.{json,md}.
Nothing here touches personal media, the live buffer or the catalog.
"""
import argparse
import datetime
import os
from pathlib import Path
import subprocess
import sys

REPO = Path(__file__).resolve().parent.parent
LOGS = Path.home() / "Library/Logs/VideoScan/angel-testbed"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--seconds", default="30", help="comma-separated clip lengths (default 30)")
    ap.add_argument("--formats", default="", help="subset, e.g. mp4,mov,mkv,mxf,avi,mp4-leftonly (default all)")
    ap.add_argument("--lossless", choices=["on", "off"], default="on")
    ap.add_argument("--debug", action="store_true", help="Debug build (faster to build, slower to run)")
    ap.add_argument("--derived-data", default=str(Path("/tmp") / "vs-angel-testbed-dd"))
    args = ap.parse_args()

    run_id = "run-" + datetime.datetime.now().strftime("%Y%m%dT%H%M%S")
    env = dict(os.environ)
    env.update({
        "TEST_RUNNER_VIDEOSCAN_ANGEL_TESTBED": "1",
        "TEST_RUNNER_VIDEOSCAN_ANGEL_TESTBED_RUN_ID": run_id,
        "TEST_RUNNER_VIDEOSCAN_ANGEL_TESTBED_SECONDS": args.seconds,
        "TEST_RUNNER_VIDEOSCAN_ANGEL_TESTBED_LOSSLESS": "1" if args.lossless == "on" else "0",
    })
    if args.formats:
        env["TEST_RUNNER_VIDEOSCAN_ANGEL_TESTBED_FORMATS"] = args.formats
    cmd = ["xcodebuild", "test",
           "-project", str(REPO / "VideoScan/VideoScan.xcodeproj"),
           "-scheme", "VideoScan",
           "-configuration", "Debug" if args.debug else "Release",
           "-destination", "platform=macOS",
           "-derivedDataPath", args.derived_data,
           "-skip-testing:VideoScanUITests",
           "-only-testing:VideoScanTests/ArchiveAngelTestbed"]
    print(f"Angel testbed {run_id}: seconds={args.seconds} formats={args.formats or 'all'} "
          f"lossless={args.lossless} build={'Debug' if args.debug else 'Release'}", flush=True)
    result = subprocess.run(cmd, env=env, capture_output=True, text=True)
    (LOGS / run_id).mkdir(parents=True, exist_ok=True)
    (LOGS / run_id / "xcodebuild.log").write_text(result.stdout + result.stderr)
    report = LOGS / run_id / "report.md"
    if report.exists():
        print(report.read_text())
    else:
        print("no report written — see", LOGS / run_id / "xcodebuild.log", file=sys.stderr)
    print(f"xcodebuild exit {result.returncode}; full log {LOGS / run_id / 'xcodebuild.log'}")
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
