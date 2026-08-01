#!/usr/bin/env python3
"""POI cycle 04 — training-data extraction (per-face ArcFace embeddings).

Runs the VideoScan person-eval CLI once per corpus clip with
``--dump-embeddings``, so every embedding comes from the PRODUCTION ArcFace
path (same decoder, sampling, detector, crop, alignment, CoreML model, and
L2 normalization the grader exercises). Nothing is reinvented here; this
script only orchestrates the CLI and files the results.

Outputs (under --out, one file pair per clip):
    <label>/<clip>.jsonl        one JSON object per face:
                                {"t": secs, "bestCosine": c, "embedding": [512 floats]}
    <label>/<clip>.result.json  the CLI's stdout JSON (schemaVersion 2)
    manifest.json               corpus fingerprint + per-clip row counts

SENSITIVE DATA (cycle-2 rule): the JSONL dumps contain raw biometric face
embeddings. The output directory must stay in local scratch (default under
/private/tmp) and must NEVER be committed, attached to issues, or logged.
Only the trained weights vector (see train_donna_lr.py) is committable.

The corpus directories are opened READ-ONLY; clips are never moved,
modified, or renamed.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import subprocess
import sys
import time

VIDEO_SUFFIXES = {".mov", ".mp4", ".m4v", ".avi", ".mts", ".m2ts", ".mxf", ".mkv"}
DEFAULT_CORPUS = pathlib.Path(
    "/Users/rickb/dev/VideoScan/tests/fixtures/videos/DonnaTestVideos")
DEFAULT_REFERENCES = pathlib.Path(
    "/Users/rickb/Library/Application Support/VideoScan/POI/donna")


def enumerate_corpus(corpus: pathlib.Path) -> dict[str, list[pathlib.Path]]:
    """Enumerate Donna/ and NotDonna/ fresh at run start (dynamic-corpus
    discipline: the corpus is whatever is on disk right now)."""
    labels: dict[str, list[pathlib.Path]] = {}
    for label in ("Donna", "NotDonna"):
        directory = corpus / label
        if not directory.is_dir():
            raise SystemExit(f"corpus directory missing: {directory}")
        clips = sorted(
            p for p in directory.iterdir()
            if p.is_file() and p.suffix.lower() in VIDEO_SUFFIXES
        )
        if not clips:
            raise SystemExit(f"no clips found under {directory}")
        labels[label] = clips
    return labels


def corpus_fingerprint(labels: dict[str, list[pathlib.Path]]) -> str:
    """sha256 over sorted relative filename + byte size (the C2 recipe;
    recorded in the manifest so training data is attributable to an exact
    corpus state)."""
    digest = hashlib.sha256()
    for label in sorted(labels):
        for clip in labels[label]:
            digest.update(f"{label}/{clip.name}|{clip.stat().st_size}\n".encode())
    return digest.hexdigest()


def run_one(app: pathlib.Path, references: pathlib.Path, clip: pathlib.Path,
            jsonl: pathlib.Path, result_json: pathlib.Path,
            frame_step: int, timeout: int) -> int:
    argv = [
        str(app), "--person-eval", "--engine", "arcface",
        "--person", "Donna", "--references", str(references),
        "--video", str(clip), "--frame-step", str(frame_step),
        "--dump-embeddings", str(jsonl),
    ]
    started = time.time()
    proc = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    result_json.write_text(proc.stdout)
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr[-2000:] + "\n")
        raise SystemExit(f"CLI failed ({proc.returncode}) on {clip.name}")
    payload = json.loads(proc.stdout)
    dumped = payload.get("embeddingsDumped")
    lines = sum(1 for _ in jsonl.open())
    if dumped != lines:
        raise SystemExit(
            f"{clip.name}: embeddingsDumped={dumped} but JSONL has {lines} lines")
    print(f"  {clip.name}: {lines} face rows, hits={payload.get('hits')}, "
          f"{time.time() - started:.0f}s", flush=True)
    return lines


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True,
                        help="Path to the built VideoScan executable "
                             "(…/VideoScan.app/Contents/MacOS/VideoScan; "
                             "use the Release build for production parity)")
    parser.add_argument("--corpus", type=pathlib.Path, default=DEFAULT_CORPUS)
    parser.add_argument("--references", type=pathlib.Path, default=DEFAULT_REFERENCES)
    parser.add_argument("--out", type=pathlib.Path, required=True,
                        help="Scratch output dir (NEVER commit its contents)")
    parser.add_argument("--frame-step", type=int, default=10,
                        help="Must match the grading pipeline (default 10)")
    parser.add_argument("--timeout", type=int, default=1200)
    args = parser.parse_args()

    app = pathlib.Path(args.app)
    if not app.is_file():
        raise SystemExit(f"app binary not found: {app}")

    labels = enumerate_corpus(args.corpus)
    fingerprint = corpus_fingerprint(labels)
    print(f"corpus: {sum(len(v) for v in labels.values())} clips, "
          f"fingerprint {fingerprint}")

    manifest: dict = {
        "schemaVersion": 1,
        "purpose": "POI cycle 04 training-data extraction (sensitive; do not commit)",
        "corpusFingerprintRecipe": "sha256(sorted 'label/name|bytes' lines)",
        "corpusFingerprint": fingerprint,
        "frameStep": args.frame_step,
        "clips": [],
    }
    for label, clips in labels.items():
        out_dir = args.out / label
        out_dir.mkdir(parents=True, exist_ok=True)
        for clip in clips:
            jsonl = out_dir / f"{clip.stem}.jsonl"
            result_json = out_dir / f"{clip.stem}.result.json"
            if jsonl.exists() and result_json.exists():
                rows = sum(1 for _ in jsonl.open())
                print(f"  {clip.name}: cached ({rows} face rows)", flush=True)
            else:
                rows = run_one(app, args.references, clip, jsonl, result_json,
                               args.frame_step, args.timeout)
            manifest["clips"].append(
                {"label": label, "clip": clip.name, "faceRows": rows})

    (args.out / "manifest.json").write_text(json.dumps(manifest, indent=2))
    print(f"manifest written: {args.out / 'manifest.json'}")


if __name__ == "__main__":
    main()
