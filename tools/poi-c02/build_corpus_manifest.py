#!/usr/bin/env python3
"""Build a person_eval.py manifest from the DYNAMIC Donna corpus (POI loop).

Lives in tools/poi-c02/ — tools/person-eval/ (the frozen grading harness) is
deliberately untouched, same discipline as cycle 1.

Per Rick's 2026-07-17 ruling there is no frozen manifest: ground truth is
directory membership under tests/fixtures/videos/DonnaTestVideos/{Donna,
NotDonna}, enumerated fresh at run start. This script emits a schemaVersion-1
manifest for tools/person-eval/person_eval.py (which stays frozen), stamped
with the corpus fingerprint (sha256 over sorted relative filenames and
file-content hashes).

Arm flags are appended verbatim to the engine command, e.g.:

  legacy arm (production defaults):
    build_corpus_manifest.py --out legacy.json

  cycle-02 candidate arm (canonical in-memory audited calibration):
    build_corpus_manifest.py --out candidate.json \
        --arm-flags "--reference-calibration audited"
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import shlex

VIDEO_EXTS = {".mov", ".mp4", ".m4v", ".avi", ".mts", ".m2ts", ".mkv", ".mxf"}
DEFAULT_CORPUS = pathlib.Path("/Users/rickb/dev/VideoScan/tests/fixtures/videos/DonnaTestVideos")
DEFAULT_REFERENCES = ("/Users/rickb/Library/Application Support/VideoScan/POI/donna")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", type=pathlib.Path, default=DEFAULT_CORPUS)
    parser.add_argument("--references", default=DEFAULT_REFERENCES)
    parser.add_argument("--frame-step", type=int, default=10)
    parser.add_argument("--arm-flags", default="",
                        help="extra CLI flags for this arm (shell-quoted)")
    parser.add_argument("--suite", default="DonnaTestVideos dynamic corpus")
    parser.add_argument("--out", type=pathlib.Path, required=True)
    args = parser.parse_args(argv)

    entries = []
    for sub, positive in (("Donna", True), ("NotDonna", False)):
        for path in sorted((args.corpus / sub).iterdir()):
            if path.suffix.lower() not in VIDEO_EXTS or path.name.startswith("."):
                continue
            entries.append((f"{sub}/{path.name}", path, positive))
    fingerprint = hashlib.sha256()
    for rel, path, positive in sorted(entries):
        fingerprint.update(f"{rel}\n".encode())
        fingerprint.update(hashlib.sha256(path.read_bytes()).digest())
    cases = [{
        "id": rel.replace("/", "-").rsplit(".", 1)[0].lower(),
        "video": str(path),
        "tags": ["positive"] if positive else ["negative", "hard-negative"],
        "expected": {"anyFace": True, "targetPerson": positive},
    } for rel, path, positive in entries]

    command = ["{app}", "--person-eval", "--engine", "arcface",
               "--person", "{person}", "--references", "{references}",
               "--video", "{video}", "--frame-step", str(args.frame_step)]
    command += shlex.split(args.arm_flags)

    manifest = {
        "schemaVersion": 1,
        "suite": args.suite,
        "corpusFingerprint": fingerprint.hexdigest(),
        "publication": {"tier": "development",
                        "datasetVersion": None, "holdout": False},
        "engine": {"name": "ArcFace", "person": "Donna",
                   "referencePath": args.references,
                   "timeoutSeconds": 1800, "command": command},
        "cases": cases,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(manifest, indent=1, sort_keys=True) + "\n")
    print(f"{args.out}: {len(cases)} cases, fingerprint {fingerprint.hexdigest()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
