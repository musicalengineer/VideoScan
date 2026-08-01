#!/usr/bin/env python3
"""Materialize a curated reference set from a refset manifest (POI cycle 2).

Lives in tools/poi-c02/ — tools/person-eval/ (the frozen grading harness) is
deliberately untouched, same discipline as cycle 1.

ROLE: cross-check utility only. The canonical C2 candidate is the in-memory
audited calibration (`--reference-calibration audited` on the source
reference folder); a materialized folder exists so external tooling can
inspect or double-check the kept set. It is valid only when the manifest is
marked "faithful" (file-level == face-level curation).

Safety contract (all-or-nothing):
  1. Every kept file must exist in the source AND have a sha256 recorded in
     the manifest AND match it. ALL files are validated before a single byte
     is copied; any failure aborts with nothing written.
  2. The target must be fresh: nonexistent or empty. An existing
     materialization can be replaced with --replace, but only if it carries
     the provenance marker this script writes — never someone else's data.
  3. Files are copied into a staging directory next to the target, the
     copies are re-hashed, a provenance marker is written, and staging is
     renamed into place. Fresh-target publication is atomic. `--replace`
     validates and stages first, but its remove-then-rename swap has a brief
     crash window in which the prior target may be absent; it never publishes
     a partially populated replacement.

NEVER writes to the source directory — production reference data is
read-only for the eval loop.

Usage:
  tools/poi-c02/make_refset.py <manifest.json> <target-dir> [--replace]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import shutil
import sys

MARKER_NAME = "refset.provenance.json"


def sha256_of(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fail(message: str, code: int) -> int:
    print(message, file=sys.stderr)
    return code


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=pathlib.Path)
    parser.add_argument("target", type=pathlib.Path)
    parser.add_argument("--replace", action="store_true",
                        help="replace an existing materialization (requires the "
                             f"{MARKER_NAME} marker from a previous run)")
    args = parser.parse_args(argv)

    manifest = json.loads(args.manifest.read_text())
    if manifest.get("schemaVersion") != 2:
        return fail("unsupported manifest schemaVersion (expected 2 — regenerate "
                    "with tools/poi-c02/audit_references.py --emit-manifest)", 2)
    if manifest.get("faithful") is not True:
        return fail("manifest is not faithful: file-level materialization cannot "
                    "reproduce the face-level candidate; refusing", 2)

    source = pathlib.Path(manifest["sourceReferencePath"])
    if not source.is_dir():
        return fail(f"source reference directory missing: {source}", 2)
    if args.target.resolve() == source.resolve():
        return fail("refusing: target equals the source reference directory", 2)

    # Phase 1 — validate EVERYTHING before any write.
    kept = list(manifest["keptFiles"])
    hashes = manifest.get("fileHashes", {})
    problems = []
    for name in kept:
        src = source / name
        if not src.is_file():
            problems.append(f"missing source file: {src}")
            continue
        expected = hashes.get(name)
        if not expected:
            problems.append(f"no manifest hash for kept file: {name}")
        elif sha256_of(src) != expected:
            problems.append(f"hash mismatch (source changed since audit): {name}")
    if problems:
        for problem in problems:
            print(problem, file=sys.stderr)
        return fail(f"validation failed ({len(problems)} problem(s)); nothing written", 3)

    # Phase 2 — target freshness.
    target = args.target
    existing = [p.name for p in target.iterdir()] if target.is_dir() else []
    if target.exists() and not target.is_dir():
        return fail(f"target exists and is not a directory: {target}", 2)
    if existing:
        if not args.replace:
            return fail(f"target is not empty: {target} — choose a fresh directory "
                        f"or pass --replace to swap out a prior materialization", 2)
        if MARKER_NAME not in existing:
            return fail(f"--replace refused: {target} has no {MARKER_NAME} marker, "
                        f"so it is not a materialization this tool made", 2)

    # Phase 3 — stage, re-verify the copies, then rename into place.
    staging = target.parent / f".{target.name}.staging-{os.getpid()}"
    if staging.exists():
        shutil.rmtree(staging)
    target.parent.mkdir(parents=True, exist_ok=True)
    staging.mkdir()
    try:
        for name in kept:
            shutil.copy2(source / name, staging / name)
            if sha256_of(staging / name) != hashes[name]:
                raise RuntimeError(f"copy verification failed for {name}")
        (staging / MARKER_NAME).write_text(json.dumps({
            "manifest": manifest,
            "manifestPath": str(args.manifest.resolve()),
        }, indent=1, sort_keys=True) + "\n")
        if existing:
            shutil.rmtree(target)
        os.rename(staging, target)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise

    print(f"materialized {len(kept)} reference files into {target} "
          f"(verified against manifest '{manifest.get('name')}')")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
