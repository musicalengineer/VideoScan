#!/usr/bin/env python3
"""scripts/check_models.py — what "the model is on this Mac" means, on synthetic caches.

The real-model smoke (tests/test_audio_transcribe_smoke.py) proves the happy
path and the empty cache; these pin the poisoned states in between, where a
loader would fail later and less clearly: a half-finished download, a
dangling symlink, a short shard set, an empty weights file, a copy without
refs/, and the env precedence huggingface_hub uses. No model, no network:
every cache here is a few empty-ish files in tmp_path.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
import check_models as cm  # noqa: E402

WHISPER = "mlx-community/whisper-medium-mlx-q4"
SNAP = "1b8a6ee7f882cb5ec97d7e93fee4b7f22405bf87"


def hub_model(cache: Path, repo: str = WHISPER, snap: str = SNAP, files=None, refs: bool = True) -> Path:
    """A hub-layout model: blobs + snapshot symlinks + refs/main, like huggingface_hub writes."""
    root = cache / ("models--" + repo.replace("/", "--"))
    blobs, folder = root / "blobs", root / "snapshots" / snap
    blobs.mkdir(parents=True)
    folder.mkdir(parents=True)
    for i, (name, data) in enumerate((files or {"config.json": b"{}", "weights.npz": b"w" * 16}).items()):
        blob = blobs / f"blob{i}"
        blob.write_bytes(data)
        (folder / name).symlink_to(os.path.relpath(blob, folder))
    if refs:
        (root / "refs").mkdir()
        (root / "refs" / "main").write_text(snap)
    return folder


def env_for(cache: Path) -> dict:
    return {"HF_HUB_CACHE": str(cache)}


def test_a_complete_snapshot_is_present(tmp_path):
    folder = hub_model(tmp_path)
    assert cm.local_hf_snapshot(WHISPER, env=env_for(tmp_path)) == (folder, SNAP)
    path, words = cm.resolve_model(WHISPER, env=env_for(tmp_path))
    assert path == str(folder) and words == f"{WHISPER}@{SNAP}"


def test_an_absent_repo_says_where_it_looked(tmp_path):
    folder, detail = cm.local_hf_snapshot(WHISPER, env=env_for(tmp_path))
    assert folder is None and str(tmp_path) in detail
    path, words = cm.resolve_model(WHISPER, env=env_for(tmp_path))
    assert path is None and f"model {WHISPER} is not on this Mac" in words and "refusing to download" in words


def test_a_half_finished_download_is_missing(tmp_path):
    hub_model(tmp_path)
    (tmp_path / ("models--" + WHISPER.replace("/", "--")) / "blobs" / "abc.incomplete").write_bytes(b"x")
    folder, detail = cm.local_hf_snapshot(WHISPER, env=env_for(tmp_path))
    assert folder is None and "half-finished download" in detail


def test_a_dangling_weights_symlink_is_missing(tmp_path):
    folder = hub_model(tmp_path)
    os.unlink(os.path.realpath(folder / "weights.npz"))
    got, detail = cm.local_hf_snapshot(WHISPER, env=env_for(tmp_path))
    assert got is None and "missing weights weights.npz" in detail


def test_an_empty_weights_file_or_no_config_is_missing(tmp_path):
    hub_model(tmp_path / "a", files={"config.json": b"{}", "weights.npz": b""})
    assert cm.local_hf_snapshot(WHISPER, env=env_for(tmp_path / "a"))[0] is None
    hub_model(tmp_path / "b", files={"weights.npz": b"w"})
    assert "no config.json" in cm.local_hf_snapshot(WHISPER, env=env_for(tmp_path / "b"))[1]
    hub_model(tmp_path / "c", files={"config.json": b"{}"})
    assert "no weights file" in cm.local_hf_snapshot(WHISPER, env=env_for(tmp_path / "c"))[1]


def test_a_short_shard_set_is_missing_but_a_stale_index_is_ignored(tmp_path):
    repo = "mlx-community/Qwen3-VL-8B-Instruct-4bit"
    stale_index = json.dumps({"weight_map": {"a": "model-00001-of-00004.safetensors"}}).encode()
    full = {"config.json": b"{}", "model.safetensors.index.json": stale_index,
            "model-00001-of-00002.safetensors": b"w", "model-00002-of-00002.safetensors": b"w"}
    hub_model(tmp_path / "full", repo=repo, files=full)
    assert cm.local_hf_snapshot(repo, env=env_for(tmp_path / "full"))[0] is not None   # the 8B's real shape
    short = {k: v for k, v in full.items() if "00002-of" not in k}
    hub_model(tmp_path / "short", repo=repo, files=short)
    got, detail = cm.local_hf_snapshot(repo, env=env_for(tmp_path / "short"))
    assert got is None and "1 of 2 weight shards" in detail


def test_a_copy_without_refs_uses_the_newest_snapshot(tmp_path):
    hub_model(tmp_path, snap="aaa", refs=False)
    root = tmp_path / ("models--" + WHISPER.replace("/", "--"))
    newer = root / "snapshots" / "bbb"
    newer.mkdir()
    for f in ("config.json", "weights.npz"):
        (newer / f).write_bytes(b"{}")
    assert cm.local_hf_snapshot(WHISPER, env=env_for(tmp_path)) == (newer, "bbb")


def test_cache_location_follows_huggingface_hub_precedence(tmp_path):
    assert cm.hf_hub_cache({"HF_HUB_CACHE": "/a", "HF_HOME": "/b"}) == Path("/a")
    assert cm.hf_hub_cache({"HUGGINGFACE_HUB_CACHE": "/c", "HF_HOME": "/b"}) == Path("/c")
    assert cm.hf_hub_cache({"HF_HOME": "/b", "XDG_CACHE_HOME": "/x"}) == Path("/b/hub")
    assert cm.hf_hub_cache({"XDG_CACHE_HOME": "/x"}) == Path("/x/huggingface/hub")
    assert cm.hf_hub_cache({}) == Path.home() / ".cache" / "huggingface" / "hub"


def test_a_local_folder_passes_through(tmp_path):
    assert cm.resolve_model(str(tmp_path)) == (str(tmp_path), str(tmp_path))


def test_the_cli_is_red_when_anything_is_missing(tmp_path):
    env = dict(os.environ, HF_HUB_CACHE=str(tmp_path), HOME=str(tmp_path))
    r = subprocess.run([sys.executable, str(REPO / "scripts" / "check_models.py"), "--json"],
                       env=env, capture_output=True, text=True, timeout=60)
    out = json.loads(r.stdout)
    assert r.returncode == 1 and out["ok"] is False
    assert len(out["missing"]) == len(cm.REQUIRED) == len(out["models"])
    assert f"{WHISPER} (hf-hub)" in out["missing"]


def test_the_list_names_the_three_models_and_the_apps_own_vlm_copy():
    names = {(m["repo"], m["where"]) for m in cm.REQUIRED}
    assert names == {(WHISPER, "hf-hub"),
                     ("mlx-community/Qwen3-VL-8B-Instruct-4bit", "hf-hub"),
                     ("mlx-community/Qwen2.5-VL-3B-Instruct-4bit", "hf-hub"),
                     ("mlx-community/Qwen2.5-VL-3B-Instruct-4bit", "swift-hub")}
    assert cm.WHISPER_REPO == WHISPER
