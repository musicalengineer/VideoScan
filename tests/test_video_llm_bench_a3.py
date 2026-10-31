"""tools/video-llm-bench/bench.py — approach a3-py (Qwen3-VL-32B on the Rick-dated stratum).

No model, no media, no catalog: venv/bin/python3 -m pytest tests/test_video_llm_bench_a3.py.
Covers the registry entry, the pure clip selector (`--stratum-prefix`, the one new knob),
the A3-vs-A2 reading with a missing baseline, the A3 Markdown's privacy, and the summary order.
Shares the handmade run with the A2 tests so the same `bench` module object is under test.
"""
from __future__ import annotations

import argparse
import json
import re

import pytest

from test_video_llm_bench_a2 import PROPER_NOUNS, bench, handmade_run


def test_a3_is_registered_with_the_32b_model_through_a2s_paths():
    spec = bench.APPROACHES["a3-py"]
    assert spec["cls"] is bench.A3Python and spec["model"] == "mlx-community/Qwen3-VL-32B-Instruct-4bit"
    assert spec["windows"] is True and spec["ocr_sampler"] == bench.OCR_SAMPLER_STILLS
    assert spec["default_frames"] == bench.APPROACHES["a2-py"]["default_frames"]
    approach = bench.resolve_approach("a3-py", "/m/32b")
    assert isinstance(approach, bench.A1Python) and approach.id == "a3-py" and approach.model_id == bench.A3_MODEL_ID
    assert bench.factory_ref_for_approach("a3-py", "/m/32b") == "approach:a3-py:/m/32b"
    assert bench.make_parser().parse_args(["run", "--manifest", "m", "--out", "o", "--approach", "a3-py",
                                           "--stratum-prefix", "rick-dated/"]).stratum_prefix == "rick-dated/"


def entry(i, corpus="era", stratum="rick-dated/1990s", duration=400.0):
    return {"digest": "{:064x}".format(i), "path": "/Volumes/FamilyArchive/x{}.mov".format(i), "duration_s": duration,
            "corpus": corpus, "stratum": stratum, "truth": {"year": 1991}}


def test_select_entries_is_pure_and_names_the_selection():
    entries = [entry(1), entry(2, stratum="rick-dated/1980s"), entry(3, stratum="camera/2020s/hevc"),
               entry(4, corpus="ocr", stratum="ocr/dvvideo"), entry(5, stratum="rick-dated/2000s", duration=30.0)]
    chosen, word = bench.select_entries(entries)
    assert [e["digest"] for e in chosen] == [e["digest"] for e in entries] and word is None
    chosen, word = bench.select_entries(entries, stratum_prefix="rick-dated/")
    assert [int(e["digest"], 16) for e in chosen] == [1, 2, 5] and word == "stratum-rick-dated"
    chosen, word = bench.select_entries(entries, corpus="era", stratum_prefix="rick-dated/", limit=2)
    assert [int(e["digest"], 16) for e in chosen] == [1, 2]
    chosen, word = bench.select_entries(entries, stratum_prefix="rick-dated/", smoke=2)
    assert [int(e["digest"], 16) for e in chosen] == [1, 2], "smoke picks one ≥ 60 s clip per decade inside the stratum"
    assert word == "stratum-rick-dated+stratified-smoke-2"
    assert bench.select_entries(entries, stratum_prefix="vhs/")[0] == []
    assert len(entries) == 5, "the input list is never mutated"


def test_a3_reading_against_a2_and_without_it(tmp_path):
    a3_dir, manifest = handmade_run(tmp_path, "a3-py", bench.A3_MODEL_ID)
    a2_dir, _ = handmade_run(tmp_path, "a2-py", bench.A2_MODEL_ID, era_range=(1980, 1990))
    a3 = bench.summarize_a1_run(a3_dir, manifest)
    a2 = bench.summarize_a1_run(a2_dir, manifest)
    lines = bench.a3_reading(a3, a2)
    assert len(lines) == 2
    assert "MAE A2 6.0 → A3 1.0 y" in lines[0]
    assert lines[1].startswith("2. **Cost, 32B vs 8B:**") and "Rick-dated stratum only" in lines[1]
    alone = bench.a3_reading(a3, None)
    assert "MAE A2 — → A3 1.0 y" in alone[0], "a missing A2 prints as —, never invented"


def test_a3_markdown_carries_no_path_digest_model_text_or_proper_noun(tmp_path):
    out, manifest = handmade_run(tmp_path, "a3-py", bench.A3_MODEL_ID)
    md = bench.format_a3_markdown(bench.summarize_a1_run(out, manifest), None)
    assert md.startswith("## Approach `a3-py` — Qwen3-VL-32B")
    assert "A3 vs A2" in md and "Rick-dated stratum only" in md
    assert "/Volumes" not in md and "/Users" not in md and "secret" not in md
    assert not re.search(r"[0-9a-f]{40,}", md)
    for clip in manifest["clips"]:
        assert clip["digest"][:12] not in md
    for text in ("JUN 21 1991", "Charlotte", "camcorder OSD", "boxy sedan", "family at") + PROPER_NOUNS:
        assert text not in md and text.lower() not in md.lower()
    assert "catalog.sqlite" not in md


def test_summarize_command_puts_a3_last(tmp_path):
    a3_dir, manifest = handmade_run(tmp_path, "a3-py", bench.A3_MODEL_ID)
    a2_dir, _ = handmade_run(tmp_path, "a2-py", bench.A2_MODEL_ID)
    mpath = tmp_path / "manifest.json"
    mpath.write_text(json.dumps(manifest))
    md_path, json_path = tmp_path / "bench.md", tmp_path / "bench.json"
    args = argparse.Namespace(manifest=str(mpath), run=[str(a3_dir), str(a2_dir)], out=str(md_path), json_out=str(json_path))
    assert bench.summarize_command(args) == 0
    md = md_path.read_text()
    assert md.index("## Approach `a2-py`") < md.index("## Approach `a3-py`")
    assert md.count("**A3 vs A2**") == 1
    assert set(json.loads(json_path.read_text())) == {"a0", "a1", "a2", "a3"}
