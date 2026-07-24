#!/usr/bin/env python3
"""Validate/publish the fixed synthetic catalog-search benchmark JSONL."""
from __future__ import annotations

import argparse, datetime as dt, json, math, os, platform, re, socket, subprocess, tempfile, uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
METRICS_FILE = Path("metrics/search_benchmarks.jsonl")
BENCHMARK, RECORD_COUNT = "catalog-search", 100_000
CORPUS_SEED = "0xb005eed020260723"
EXPECTED_QUERIES = (
    "d", "don", "donna", "xylotheremin", "zzqx", "donna christmas 1997",
    "1990s", "people:donna", '"cape cod"', "pelicanwharf sunsetreel",
)
EXPECTED_KEYS = {("rebuild", None), ("haystack-footprint", None),
                 ("persist-roundtrip", None), *(("query", q) for q in EXPECTED_QUERIES)}
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
RUN_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$")
PRIVATE_RE = re.compile(r"(?:^|[\s\"'])(?:/Users/|/Volumes/|/private/|file://|~/)")
COMMON_MEASUREMENT_KEYS = {"benchmark", "metric", "operation", "corpusId",
    "corpusVersion", "corpusSeed", "recordCount", "unit", "direction",
    "warmupCount", "sampleCount", "resultCount", "expectedResultCount", "correct"}
PROVENANCE_KEYS = {"host", "machineClass", "macOS", "xcode", "architecture",
    "configuration", "branch", "dirty", "commit"}
RUN_KEYS = {"schemaVersion", "runId", "ts", "benchmark", "corpus", "measurements"} | PROVENANCE_KEYS
CORPUS_KEYS = {"id", "version", "seed", "recordCount", "synthetic"}

class ValidationError(ValueError): pass

def command(*args: str, cwd: Path = ROOT) -> str:
    return subprocess.run(args, cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()

def finite(value, field, line):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(float(value)):
        raise ValidationError(f"line {line}: {field} must be finite")
    if value < 0: raise ValidationError(f"line {line}: {field} must be non-negative")
    return float(value)

def positive_int(value, field, line):
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise ValidationError(f"line {line}: {field} must be a positive integer")

def validate_measurement(row, line):
    missing = sorted(COMMON_MEASUREMENT_KEYS - row.keys())
    if missing: raise ValidationError(f"line {line}: missing {', '.join(missing)}")
    if row["benchmark"] != BENCHMARK: raise ValidationError(f"line {line}: wrong benchmark")
    if row["recordCount"] != RECORD_COUNT: raise ValidationError(f"line {line}: recordCount must be 100000")
    if (row["corpusId"], row["corpusVersion"]) != ("catalog-search-synthetic", 1):
        raise ValidationError(f"line {line}: unexpected corpus identity")
    if row["corpusSeed"] != CORPUS_SEED: raise ValidationError(f"line {line}: invalid corpusSeed")
    if isinstance(row["warmupCount"], bool) or not isinstance(row["warmupCount"], int) or row["warmupCount"] < 0:
        raise ValidationError(f"line {line}: warmupCount must be a non-negative integer")
    positive_int(row["sampleCount"], "sampleCount", line)
    for field in ("resultCount", "expectedResultCount"):
        if isinstance(row[field], bool) or not isinstance(row[field], int) or row[field] < 0:
            raise ValidationError(f"line {line}: {field} must be a non-negative integer")
    if row["correct"] is not True or row["resultCount"] != row["expectedResultCount"]:
        raise ValidationError(f"line {line}: measured result count does not match expected result count")
    key = (row["operation"], row.get("query"))
    if key not in EXPECTED_KEYS: raise ValidationError(f"line {line}: unexpected operation/query {key!r}")
    if row["operation"] == "haystack-footprint":
        unknown = row.keys() - (COMMON_MEASUREMENT_KEYS | {"value"})
        if unknown: raise ValidationError(f"line {line}: unknown fields: {', '.join(sorted(unknown))}")
        if (row["metric"], row["unit"], row["direction"]) != ("catalog_search_haystack_footprint", "bytes", "lower"):
            raise ValidationError(f"line {line}: invalid footprint metric typing")
        if "value" not in row: raise ValidationError(f"line {line}: footprint requires value")
        if (row["warmupCount"], row["sampleCount"]) != (0, 1):
            raise ValidationError(f"line {line}: footprint requires 0 warmups and 1 sample")
        finite(row["value"], "value", line)
        if any(k in row for k in ("min", "median", "p95")):
            raise ValidationError(f"line {line}: footprint must use value")
    else:
        allowed = COMMON_MEASUREMENT_KEYS | {"min", "median", "p95"}
        if row["operation"] == "query": allowed.add("query")
        unknown = row.keys() - allowed
        if unknown: raise ValidationError(f"line {line}: unknown fields: {', '.join(sorted(unknown))}")
        if (row["metric"], row["unit"], row["direction"]) != ("catalog_search_latency", "milliseconds", "lower"):
            raise ValidationError(f"line {line}: invalid latency metric typing")
        expected_samples = 20 if row["operation"] == "query" else 3
        if (row["warmupCount"], row["sampleCount"]) != (3, expected_samples):
            raise ValidationError(f"line {line}: unexpected fixed-matrix warmup/sample counts")
        stats = [finite(row.get(k), k, line) for k in ("min", "median", "p95")]
        if stats != sorted(stats): raise ValidationError(f"line {line}: require minimum <= median <= p95")
        if "value" in row: raise ValidationError(f"line {line}: latency cannot use value")
    return key

def load_raw(path: Path):
    if not path.is_file(): raise ValidationError(f"raw benchmark file not found: {path}")
    if path.stat().st_size > 1_000_000: raise ValidationError("raw benchmark file too large")
    text = path.read_text(encoding="utf-8")
    if PRIVATE_RE.search(text): raise ValidationError("raw benchmark contains a private or real-catalog path")
    rows, keys = [], set()
    for number, raw in enumerate(text.splitlines(), 1):
        if not raw.strip(): continue
        try: row = json.loads(raw)
        except json.JSONDecodeError as error: raise ValidationError(f"line {number}: invalid JSON") from error
        if not isinstance(row, dict): raise ValidationError(f"line {number}: measurement must be an object")
        key = validate_measurement(row, number)
        if key in keys: raise ValidationError(f"line {number}: duplicate operation/query {key!r}")
        keys.add(key); rows.append(row)
    if keys != EXPECTED_KEYS or len(rows) != 13:
        missing = sorted(map(str, EXPECTED_KEYS - keys))
        raise ValidationError(f"incomplete 100k matrix: missing={missing}")
    corpus = {(r["corpusId"], r["corpusVersion"], r["corpusSeed"], r["recordCount"]) for r in rows}
    if len(corpus) != 1: raise ValidationError("measurements do not share corpus provenance")
    return rows

def machine_class():
    if os.environ.get("VIDEOSCAN_MACHINE_CLASS"): return os.environ["VIDEOSCAN_MACHINE_CLASS"].lower()
    try:
        match = re.search(r"Chip:\s*Apple\s+(M\d+)", command("system_profiler", "SPHardwareDataType"), re.I)
        return match.group(1).lower() if match else "unknown"
    except (OSError, subprocess.CalledProcessError): return "unknown"

def collect_provenance():
    branch, commit = command("git", "branch", "--show-current"), command("git", "rev-parse", "HEAD")
    if branch != "main": raise ValidationError(f"publication requires branch main, got {branch or 'detached HEAD'}")
    if command("git", "status", "--porcelain"): raise ValidationError("publication requires a clean worktree")
    if not SHA_RE.fullmatch(commit): raise ValidationError("publication requires a 40-character commit")
    if platform.machine() != "arm64": raise ValidationError("publication requires arm64")
    xcode = command("xcodebuild", "-version").splitlines()
    if len(xcode) < 2: raise ValidationError("could not determine Xcode provenance")
    return {"host": socket.gethostname().split(".")[0], "machineClass": machine_class(),
        "macOS": {"version": command("sw_vers", "-productVersion"), "build": command("sw_vers", "-buildVersion")},
        "xcode": {"version": xcode[0], "build": xcode[1]}, "architecture": "arm64",
        "configuration": "Release", "branch": "main", "dirty": False, "commit": commit}

def build_run(raw_path, run_id, provenance=None, timestamp=None):
    if not RUN_ID_RE.fullmatch(run_id): raise ValidationError("runId must be 8-128 safe identifier characters")
    rows, p = load_raw(raw_path), (provenance or collect_provenance())
    if PROVENANCE_KEYS - p.keys(): raise ValidationError("missing run provenance")
    if p.keys() - PROVENANCE_KEYS: raise ValidationError("unknown run provenance fields")
    if p["configuration"] != "Release" or p["architecture"] != "arm64": raise ValidationError("run provenance must be Release on arm64")
    if p["branch"] != "main" or p["dirty"] is not False: raise ValidationError("run provenance must be clean main")
    if not SHA_RE.fullmatch(str(p["commit"])): raise ValidationError("commit must be a 40-character lowercase SHA")
    if p["machineClass"] not in {"m1", "m4", "m5"}: raise ValidationError("machineClass must identify M1, M4, or M5")
    for obj, keys in ((p["macOS"], ("version", "build")), (p["xcode"], ("version", "build"))):
        if not isinstance(obj, dict) or any(not isinstance(obj.get(k), str) or not obj[k] for k in keys):
            raise ValidationError("invalid OS/Xcode provenance")
        if obj.keys() != set(keys): raise ValidationError("unknown OS/Xcode provenance fields")
    row = {"schemaVersion": 1, "runId": run_id,
        "ts": timestamp or dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "benchmark": BENCHMARK, **p,
        "corpus": {"id": rows[0]["corpusId"], "version": rows[0]["corpusVersion"], "seed": rows[0]["corpusSeed"], "recordCount": RECORD_COUNT, "synthetic": True},
        "measurements": rows}
    encoded = json.dumps(row, allow_nan=False)
    if PRIVATE_RE.search(encoded): raise ValidationError("published row contains a private path")
    validate_run_row(row)
    return row

def validate_run_row(row):
    if not isinstance(row, dict) or row.keys() != RUN_KEYS: raise ValidationError("published run has unknown or missing fields")
    if row["schemaVersion"] != 1 or row["benchmark"] != BENCHMARK: raise ValidationError("invalid published run identity")
    if not RUN_ID_RE.fullmatch(str(row["runId"])): raise ValidationError("invalid published runId")
    if not isinstance(row["corpus"], dict) or row["corpus"].keys() != CORPUS_KEYS:
        raise ValidationError("published corpus has unknown or missing fields")
    if row["corpus"] != {"id": "catalog-search-synthetic", "version": 1, "seed": CORPUS_SEED,
                         "recordCount": RECORD_COUNT, "synthetic": True}:
        raise ValidationError("invalid published corpus provenance")
    if row["configuration"] != "Release" or row["architecture"] != "arm64" or row["branch"] != "main" or row["dirty"] is not False:
        raise ValidationError("invalid published build provenance")
    if not SHA_RE.fullmatch(str(row["commit"])): raise ValidationError("invalid published commit")
    if row["machineClass"] not in {"m1", "m4", "m5"}: raise ValidationError("invalid published machineClass")
    if not isinstance(row["host"], str) or not row["host"]: raise ValidationError("invalid published host")
    for obj in (row["macOS"], row["xcode"]):
        if not isinstance(obj, dict) or obj.keys() != {"version", "build"}: raise ValidationError("invalid published OS/Xcode fields")
    if not isinstance(row["measurements"], list) or len(row["measurements"]) != 13:
        raise ValidationError("published run requires 13 measurements")
    keys = {validate_measurement(value, index) for index, value in enumerate(row["measurements"], 1)}
    if keys != EXPECTED_KEYS: raise ValidationError("published run has incomplete measurement matrix")
    if PRIVATE_RE.search(json.dumps(row, allow_nan=False)): raise ValidationError("published run contains private paths")

def serialize(row):
    validate_run_row(row)
    return json.dumps(row, separators=(",", ":"), sort_keys=True, allow_nan=False) + "\n"

def atomic_append(path: Path, row):
    path.parent.mkdir(parents=True, exist_ok=True)
    old = path.read_text() if path.exists() else ""
    if len(old.encode()) > 20_000_000: raise ValidationError("existing stream too large")
    wanted = serialize(row)
    for number, line in enumerate(old.splitlines(), 1):
        if not line.strip(): continue
        try: prior = json.loads(line)
        except json.JSONDecodeError as error: raise ValidationError(f"existing stream line {number}: invalid JSON") from error
        if prior.get("runId") == row["runId"]:
            if serialize(prior) == wanted: return False
            raise ValidationError(f"runId {row['runId']} already exists with different content")
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent, text=True)
    try:
        with os.fdopen(fd, "w") as handle:
            handle.write(old + ("\n" if old and not old.endswith("\n") else "") + wanted); handle.flush(); os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)
    return True

def publish_remote(row):
    command("git", "fetch", "origin", "metrics", "--quiet")
    with tempfile.TemporaryDirectory(prefix="videoscan-search-publish-") as directory:
        wt = Path(directory); command("git", "worktree", "add", "--detach", str(wt), "origin/metrics", "--quiet")
        try:
            if not atomic_append(wt / METRICS_FILE, row): return False
            command("git", "add", str(METRICS_FILE), cwd=wt)
            command("git", "commit", "-m", f"bench(search): {row['runId']} {row['machineClass']} 100k [skip ci]", "--quiet", cwd=wt)
            command("git", "push", "origin", "HEAD:metrics", "--quiet", cwd=wt); return True
        finally:
            subprocess.run(["git", "worktree", "remove", str(wt), "--force"], cwd=ROOT, capture_output=True)
            subprocess.run(["git", "worktree", "prune"], cwd=ROOT, capture_output=True)

def main():
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument("raw", type=Path)
    parser.add_argument("--run-id", default=str(uuid.uuid4()))
    out = parser.add_mutually_exclusive_group(); out.add_argument("--local-output", type=Path); out.add_argument("--publish", action="store_true")
    args = parser.parse_args(); row = build_run(args.raw, args.run_id); print(json.dumps(row, indent=2, allow_nan=False))
    if args.publish: print("published" if publish_remote(row) else "already published")
    elif args.local_output: print("updated" if atomic_append(args.local_output, row) else "unchanged")
    else: print("validated only; use --local-output or --publish to write")
    return 0

if __name__ == "__main__":
    try: raise SystemExit(main())
    except ValidationError as error: raise SystemExit(f"error: {error}")
