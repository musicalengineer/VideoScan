#!/usr/bin/env python3
"""check_models.py — are the model weights VideoScan needs on THIS Mac?

Why (Rick, 2026-11-05): the M5 Ultra became the dev Mac on 10/27 without
`mlx-community/whisper-medium-mlx-q4`; the M4 had it, and nothing noticed,
because every test used a fake transcriber. This is the one list of the
models the app and its Python lanes load, and the one check of whether
each is on disk. It never downloads anything.

    python3 scripts/check_models.py            # one line per model, exit 1 if any is missing
    python3 scripts/check_models.py --json     # the same, as one JSON object (the nightly)
    ssh ricksm4.local <venv>/bin/python3 - < scripts/check_models.py   # another Mac, nothing copied

Stdlib only, and self-contained (no repo imports), so it runs from any
Python on any Mac, including piped over ssh. `whisper_transcribe.py` and
`whisper_worker.py` import `resolve_model` from here, so the scripts and
this check agree on what "present" means (one engine).

"Present" means the files a loader would open are really there: the
snapshot folder (Hugging Face hub layout, resolved the way huggingface_hub
resolves it: HF_HUB_CACHE, else HF_HOME/hub, else ~/.cache/huggingface/hub)
or the Swift MLX download folder (~/Library/Caches/models/<repo>, where
mlx-swift-examples' `defaultHubApi` puts the app's VLM), holding
config.json and its weights files, each non-empty, each symlink resolving (a sharded set must have all N shards). A half-finished
download (a *.incomplete blob) is missing.

Snapshot hashes: no loader in the code pins a revision today (every load
asks for `main`), so `pinned` is None for all three. `reference` is the
snapshot the M4 and the M5 Ultra both carried on 2026-11-05; a different
one is printed as a note, not a failure.

Memory: a directory listing and one index JSON (≤ ~200 KB) per model.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple

# The one list. `where`: "hf-hub" = Python (huggingface_hub cache);
# "swift-hub" = the app's mlx-swift-examples HubApi download folder.
REQUIRED: List[Dict[str, object]] = [
    {
        "repo": "mlx-community/whisper-medium-mlx-q4",
        "where": "hf-hub",
        "used_by": "Whisper transcription (scripts/whisper_worker.py, scripts/whisper_transcribe.py)",
        "pinned": None,
        "reference": "1b8a6ee7f882cb5ec97d7e93fee4b7f22405bf87",
    },
    {
        "repo": "mlx-community/Qwen3-VL-8B-Instruct-4bit",
        "where": "hf-hub",
        "used_by": "era/OCR background job (BackgroundJob.swift, tools/video-llm-bench/bench.py)",
        "pinned": None,
        "reference": "defcdea7cc7a4b0858fea563cbbce171d328e457",
    },
    {
        "repo": "mlx-community/Qwen2.5-VL-3B-Instruct-4bit",
        "where": "hf-hub",
        "used_by": "Python captioner (scripts/vlm_caption.py)",
        "pinned": None,
        "reference": "46d4cf06a06ffc1a766c214174f9cbed2f45bcab",
    },
    {
        "repo": "mlx-community/Qwen2.5-VL-3B-Instruct-4bit",
        "where": "swift-hub",
        "used_by": "the app's scene captions (CaptionRunner.swift, VLMRegistry.qwen2_5VL3BInstruct4Bit)",
        "pinned": None,
        "reference": None,
    },
]

WHISPER_REPO = "mlx-community/whisper-medium-mlx-q4"


def hf_hub_cache(env: Optional[Dict[str, str]] = None) -> Path:
    """The hub cache huggingface_hub would use, from the same variables."""
    e = os.environ if env is None else env
    for key in ("HF_HUB_CACHE", "HUGGINGFACE_HUB_CACHE"):
        if e.get(key):
            return Path(e[key]).expanduser()
    if e.get("HF_HOME"):
        return Path(e["HF_HOME"]).expanduser() / "hub"
    if e.get("XDG_CACHE_HOME"):
        return Path(e["XDG_CACHE_HOME"]).expanduser() / "huggingface" / "hub"
    return Path.home() / ".cache" / "huggingface" / "hub"


def swift_hub_dir(repo: str) -> Path:
    """Where mlx-swift-examples' defaultHubApi keeps `repo` (unsandboxed app)."""
    return Path.home() / "Library" / "Caches" / "models" / repo


def _weights_problem(folder: Path) -> Optional[str]:
    """None when config.json and every weights file are present and non-empty."""
    def ok(p: Path) -> bool:
        try:
            return p.is_file() and p.stat().st_size > 0   # stat follows the symlink
        except OSError:
            return False

    if not ok(folder / "config.json"):
        return "no config.json"
    # The MLX loaders glob *.safetensors (mlx_whisper: weights.safetensors
    # or weights.npz); they do not read model.safetensors.index.json, and
    # mlx-community repos often carry the ORIGINAL model's index (the 8B's
    # names 4 shards, its 4-bit weights are 2). So: every weights file the
    # folder holds is non-empty, and a sharded set "model-0000k-of-0000N"
    # has all N.
    weights = sorted(p.name for p in folder.iterdir() if p.suffix in (".safetensors", ".npz"))
    if not weights:
        return "no weights file"
    empty = [w for w in weights if not ok(folder / w)]
    if empty:
        return "missing weights " + ", ".join(empty)
    sets: Dict[str, int] = {}
    for w in weights:
        m = re.search(r"-of-(\d+)\.safetensors$", w)
        if m:
            sets[m.group(0)] = sets.get(m.group(0), 0) + 1
    for suffix, have in sets.items():
        n = int(re.search(r"\d+", suffix).group(0))  # type: ignore[union-attr]
        if have != n:
            return f"{have} of {n} weight shards"
    return None


def local_hf_snapshot(repo: str, revision: Optional[str] = None,
                      env: Optional[Dict[str, str]] = None) -> Tuple[Optional[Path], str]:
    """(snapshot folder, detail) for `repo` in the hub cache; folder None when missing.

    revision None → refs/main, else the newest snapshot folder (the rule
    BackgroundJob.defaultModelSnapshot uses), which covers a copy made
    without its refs/ folder. Never touches the network.
    """
    cache = hf_hub_cache(env)
    root = cache / ("models--" + repo.replace("/", "--"))
    if not root.is_dir():
        return None, f"not in {cache}"
    blobs = root / "blobs"
    if blobs.is_dir() and any(p.name.endswith(".incomplete") for p in blobs.iterdir()):
        return None, f"half-finished download in {blobs}"
    snaps = root / "snapshots"
    names = sorted(p.name for p in snaps.iterdir() if p.is_dir()) if snaps.is_dir() else []
    if revision is None:
        ref = root / "refs" / "main"
        revision = ref.read_text(encoding="utf-8").strip() if ref.is_file() else (names[-1] if names else None)
    if not revision or revision not in names:
        return None, f"no snapshot {revision or '(any)'} under {snaps}"
    folder = snaps / revision
    problem = _weights_problem(folder)
    if problem:
        return None, f"{problem} in {folder}"
    return folder, revision


def resolve_model(model: str, env: Optional[Dict[str, str]] = None) -> Tuple[Optional[str], str]:
    """(local folder to hand mlx_whisper, words) for the Whisper scripts; folder None = refuse.

    A local folder passes through. A repo id resolves ONLY from the local
    hub cache. Never a download: mlx_whisper given a repo id calls
    snapshot_download, which on a Mac without the weights fetched ~244 MB
    silently (online) or failed every file with an opaque
    LocalEntryNotFoundError (offline). The words are what the app log shows.
    """
    if Path(model).is_dir():
        return model, model
    folder, detail = local_hf_snapshot(model, env=env)
    if folder is None:
        return None, (f"model {model} is not on this Mac ({detail}); "
                      f"refusing to download it. Copy it from another Mac or run "
                      f"`venv-mlx/bin/hf download {model}`, then check with scripts/check_models.py")
    return str(folder), f"{model}@{detail}"


def check_one(spec: Dict[str, object]) -> Dict[str, object]:
    repo = str(spec["repo"])
    row: Dict[str, object] = {"repo": repo, "where": spec["where"], "used_by": spec["used_by"]}
    if spec["where"] == "hf-hub":
        folder, detail = local_hf_snapshot(repo, spec.get("pinned"))  # type: ignore[arg-type]
        row["present"] = folder is not None
        row["path"] = str(folder) if folder else None
        row["snapshot"] = detail if folder else None
        row["detail"] = detail
        ref = spec.get("reference")
        if folder and ref and detail != ref:
            row["note"] = f"snapshot {detail} differs from the fleet reference {ref}"
    else:
        folder = swift_hub_dir(repo)
        problem = _weights_problem(folder) if folder.is_dir() else f"not in {folder.parent}"
        row["present"] = problem is None
        row["path"] = str(folder) if problem is None else None
        row["snapshot"] = None
        row["detail"] = str(folder) if problem is None else problem
    return row


def check_all() -> List[Dict[str, object]]:
    return [check_one(spec) for spec in REQUIRED]


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="Which required model weights are on this Mac (never downloads).")
    ap.add_argument("--json", action="store_true", help="print one JSON object instead of lines")
    args = ap.parse_args(argv)
    rows = check_all()
    missing = [r for r in rows if not r["present"]]
    host = os.uname().nodename.split(".")[0]
    if args.json:
        print(json.dumps({"host": host, "ok": not missing, "models": rows,
                          "missing": [f"{r['repo']} ({r['where']})" for r in missing]}))
    else:
        for r in rows:
            mark = "present" if r["present"] else "MISSING"
            print(f"{mark:8} {r['repo']} [{r['where']}] — {r['detail']}" + (f"  NOTE: {r['note']}" if r.get("note") else ""))
        print(f"{host}: {len(rows) - len(missing)}/{len(rows)} required models present"
              + ("" if not missing else f" — RED: {len(missing)} missing"))
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
