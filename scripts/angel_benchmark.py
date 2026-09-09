#!/usr/bin/env python3
"""Opt-in 100-file Archive Angel benchmark, using the app's test-hosted job.

Does not mount RAM disks, change models, promote media, or install schedules.
Source lists are explicit JSON arrays of 100 paths; media is read-only.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import plistlib
import signal
import statistics
import subprocess
import time
import uuid


MODES = ("direct", "ssd-staged", "ram-staged")


def stop_group(process, grace=15, kill_wait=5):
    """Bound cleanup even if the leader exits before its descendants."""
    def alive():
        try:
            os.killpg(process.pid, 0)
            return True
        except ProcessLookupError:
            return False
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    deadline = time.monotonic() + grace
    while alive() and time.monotonic() < deadline:
        process.poll()
        time.sleep(0.05)
    if alive():
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    try:
        process.wait(timeout=kill_wait)
    except subprocess.TimeoutExpired:
        return False
    return not alive()


def atomic_json(path, data):
    path = Path(path)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(data, indent=2) + "\n")
    temporary.replace(path)


def digest(path):
    value = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def storage_info(path):
    """Record physical backing evidence; a mode name alone doesn't prove RAM."""
    try:
        completed = subprocess.run(["/usr/sbin/diskutil", "info", "-plist", str(path)],
                                   capture_output=True, check=True, timeout=15)
        data = plistlib.loads(completed.stdout)
        return {key: data.get(key) for key in (
            "DeviceIdentifier", "VolumeUUID", "MountPoint", "FilesystemType", "BusProtocol", "Internal", "SolidState", "Virtual")}
    except (OSError, ValueError, subprocess.SubprocessError):
        return {"unverified": True}


def validate_paths(paths):
    if not isinstance(paths, list) or len(paths) != 100:
        raise ValueError("Exactly 100 explicit source paths are required")
    resolved = []
    for item in paths:
        path = Path(item)
        if not path.is_absolute() or path.is_symlink() or not path.is_file():
            raise ValueError(f"Source must be an absolute, regular, non-symlink file: {path}")
        resolved.append(path.resolve())
    if len(set(resolved)) != 100:
        raise ValueError("Source paths must be distinct")
    return resolved


def probe(path, executable):
    result = subprocess.run([executable, "-v", "error", "-show_streams", "-show_format",
                             "-of", "json", str(path)], check=True, capture_output=True,
                            text=True, timeout=60)
    data = json.loads(result.stdout)
    video = next((s for s in data["streams"] if s.get("codec_type") == "video"
                  and not s.get("disposition", {}).get("attached_pic")), None)
    audio = next((s for s in data["streams"] if s.get("codec_type") == "audio"), None)
    if video is None:
        raise ValueError(f"No video stream: {path}")
    duration = float(data.get("format", {}).get("duration", video.get("duration", 0)))
    if duration < 8:
        raise ValueError(f"Fixture must clear Angel's eight-second human-marked floor: {path}")
    return dict(path=str(path), sha256=digest(path), durationSeconds=duration,
                videoCodec=video.get("codec_name", ""), audioCodec=audio.get("codec_name", "") if audio else "",
                streamType="videoAndAudio" if audio else "videoOnly")


def prepare(args):
    paths = validate_paths(json.loads(args.files.read_text()))
    if args.output.exists():
        raise ValueError("Refusing to overwrite an existing corpus manifest")
    rows = [probe(path, args.ffprobe) for path in paths]
    atomic_json(args.output, dict(schemaVersion=1, files=rows))


def verdict(summary, exit_code):
    # A quick failure/fallback or partial run is never a faster successful run.
    if exit_code != 0 or not summary:
        return "failed" if exit_code != 124 else "incomplete"
    if summary.get("requested") != 100 or summary.get("completed") != 100:
        return "incomplete"
    if summary.get("passed") != 100 or summary.get("failed") != 0 or summary.get("incomplete") != 0:
        return "failed"
    rows = summary.get("results", [])
    if len(rows) != 100 or any(not r.get("success") or not r.get("sourceUnchanged") for r in rows):
        return "failed"
    return "ok"


def compare_reports(baseline, candidate):
    for report in (baseline, candidate):
        if report.get("status") != "ok" or verdict(report.get("summary"), report.get("exitCode")) != "ok":
            raise ValueError("Only complete, successful 100-file runs may be compared")
    for key in ("buildSHA", "corpusSHA256", "configuration", "machine", "makeLossless", "runRoot"):
        if key not in baseline or baseline[key] != candidate.get(key):
            raise ValueError(f"Comparison requires matching {key}")
    for report in (baseline, candidate):
        if not report.get("outputStorage", {}).get("DeviceIdentifier"):
            raise ValueError("Comparison requires verified output storage")
    if baseline["outputStorage"] != candidate["outputStorage"]:
        raise ValueError("Comparison requires identical output storage")
    if baseline.get("mode") != "direct" or candidate.get("mode") not in MODES[1:]:
        raise ValueError("Compare direct with SSD-staged or RAM-staged")
    def timings(report):
        values = sorted(float(r["endToEndSeconds"]) for r in report["summary"]["results"])
        if any(not math.isfinite(v) or v <= 0 for v in values):
            raise ValueError("Missing or invalid per-file end-to-end timings")
        return dict(totalSeconds=sum(values), medianSeconds=statistics.median(values), p95Seconds=values[94])
    a, b = timings(baseline), timings(candidate)
    return dict(baseline=a, candidate=b,
                reductionPct=100 * (a["totalSeconds"] - b["totalSeconds"]) / a["totalSeconds"],
                caveat="External-prefetch prototype; uncontrolled OS cache; repeat with reversed mode order")


def run(args):
    if args.timeout <= 0:
        raise ValueError("Timeout must be positive")
    if args.mode != "direct" and args.staging_root is None:
        raise ValueError("Staged modes require an explicit dedicated --staging-root")
    corpus = json.loads(args.corpus.read_text())
    validate_paths([r["path"] for r in corpus["files"]])
    root = args.run_root.resolve()
    root.mkdir(parents=True, exist_ok=True)
    run_id = uuid.uuid4().hex
    folder = root / ("test_angel_run_" + run_id)
    folder.mkdir()
    outputs = folder / "outputs"
    outputs.mkdir()
    manifest = dict(schemaVersion=1, runID=run_id, mode=args.mode, outputRoot=str(outputs),
                    makeLossless=args.lossless, files=corpus["files"])
    if args.staging_root:
        if not args.staging_root.is_dir():
            raise ValueError("Staging root must already exist; this runner never mounts RAM")
        manifest["stagingRoot"] = str(args.staging_root.resolve())
    atomic_json(folder / "manifest.json", manifest)
    provenance = dict(buildSHA=args.build_sha, configuration="Release", machine=platform.node(),
                      platform=platform.platform(), mode=args.mode, runID=run_id,
                      corpusSHA256=digest(args.corpus), cacheCondition="uncontrolled OS cache",
                      stagingRoot=manifest.get("stagingRoot"), outputRoot=str(outputs), runRoot=str(root),
                      startedAt=time.time(), timeoutSeconds=args.timeout, makeLossless=args.lossless,
                      implementation="real ArchiveAngelJob with external per-file prefetch")
    provenance["outputStorage"] = storage_info(outputs)
    provenance["stagingStorage"] = storage_info(args.staging_root) if args.staging_root else None
    atomic_json(folder / "provenance.json", provenance)
    command = [args.xcodebuild, "test-without-building", "-project", str(args.project.resolve()),
               "-scheme", "VideoScan", "-configuration", "Release",
               "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", str(args.derived_data.resolve()),
               "-resultBundlePath", str(folder / "results.xcresult"),
               "-only-testing:VideoScanTests/ArchiveAngelBenchmarkTests", "CODE_SIGNING_ALLOWED=NO"]
    env = dict(os.environ, TEST_RUNNER_VIDEOSCAN_ANGEL_BENCHMARK_MANIFEST=str(folder / "manifest.json"))
    with (folder / "xcodebuild.log").open("w") as log:
        process = subprocess.Popen(command, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            provenance["processGroupCleanupConfirmed"] = stop_group(process)
            code = 124
    summary_path = outputs / ("test_angel_" + run_id) / "summary.json"
    try:
        summary = json.loads(summary_path.read_text())
    except (OSError, ValueError):
        summary = None
    report = dict(provenance, elapsedSeconds=time.time() - provenance["startedAt"],
                  exitCode=code, status=verdict(summary, code), summary=summary)
    atomic_json(folder / "report.json", report)
    print(json.dumps(dict(status=report["status"], report=str(folder / "report.json"))))
    return 0 if report["status"] == "ok" else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    p = commands.add_parser("prepare")
    p.add_argument("--files", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--ffprobe", default="/opt/homebrew/bin/ffprobe")
    r = commands.add_parser("run")
    r.add_argument("--corpus", type=Path, required=True)
    r.add_argument("--mode", choices=MODES, required=True)
    r.add_argument("--run-root", type=Path, required=True)
    r.add_argument("--staging-root", type=Path)
    r.add_argument("--project", type=Path, required=True)
    r.add_argument("--derived-data", type=Path, required=True)
    r.add_argument("--build-sha", required=True, help="SHA attested by the Release build producer")
    r.add_argument("--timeout", type=int, default=28800)
    r.add_argument("--lossless", action="store_true")
    r.add_argument("--xcodebuild", default="/usr/bin/xcodebuild")
    c = commands.add_parser("compare")
    c.add_argument("--baseline", type=Path, required=True)
    c.add_argument("--candidate", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == "compare":
            print(json.dumps(compare_reports(json.loads(args.baseline.read_text()),
                                             json.loads(args.candidate.read_text())), indent=2))
            return 0
        return prepare(args) if args.command == "prepare" else run(args)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        parser.exit(2, f"Benchmark refused: {error}\n")


if __name__ == "__main__":
    raise SystemExit(main())
