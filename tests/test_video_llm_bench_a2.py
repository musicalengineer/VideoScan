"""tools/video-llm-bench/bench.py — approach a2-py (Qwen3-VL-8B through A1's paths).

No model, no media, no catalog: venv/bin/python3 -m pytest tests/test_video_llm_bench_a2.py.
Covers the approach registry (a2-py → the 8B model, run record carries the weights digest
and both sampler ids), the two-sampler routing as a pure function (ERA → windows, OCR →
A0's 5 stills), the A2 run loop with a fake approach, the A2-vs-A0/A1 reading, and the
privacy gate on the A2 Markdown (no path, no digest, no raw model text, no proper noun).
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import math
import re
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "tools" / "video-llm-bench" / "bench.py"
SPEC = importlib.util.spec_from_file_location("video_llm_bench_a2_under_test", SCRIPT)
assert SPEC and SPEC.loader
bench = importlib.util.module_from_spec(SPEC)
sys.modules["video_llm_bench_a2_under_test"] = bench
SPEC.loader.exec_module(bench)


def digest_for(n: int) -> str:
    return "{:064x}".format(n)


def era_obj(**over):
    obj = {"family": "era", "window": [120.0, 180.0], "yearRange": [1991, 1995],
           "rationale": "4:3, camcorder OSD, boxy sedan",
           "cues": [{"kind": "technical", "text": "tracking lines", "atS": 131.0}], "selfConfidence": 0.7}
    obj.update(over)
    return obj


def room_obj(**over):
    obj = {"family": "roomFeatures", "window": [0.0, 60.0], "setting": "indoor",
           "locationType": "residential living room", "features": ["green shag carpet", "brick fireplace"],
           "selfConfidence": 0.8}
    obj.update(over)
    return obj


# ---------------------------------------------------------------------------
# Registration + run record
# ---------------------------------------------------------------------------
def test_a2_is_registered_with_the_8b_model_and_the_stills_ocr_sampler():
    spec = bench.APPROACHES["a2-py"]
    assert spec["cls"] is bench.A2Python and spec["model"] == "mlx-community/Qwen3-VL-8B-Instruct-4bit"
    assert spec["windows"] is True and spec["ocr_sampler"] == bench.OCR_SAMPLER_STILLS
    # A0 and A1 are unchanged by the registry.
    assert bench.APPROACHES["a0-py"]["model"] == bench.APPROACHES["a1-py"]["model"] == bench.MODEL_ID
    assert bench.APPROACHES["a1-py"]["ocr_sampler"] == bench.OCR_SAMPLER_WINDOW_FRAMES
    approach = bench.resolve_approach("a2-py", None)
    assert isinstance(approach, bench.A1Python) and approach.id == "a2-py"
    assert approach.model_id == bench.A2_MODEL_ID
    assert bench.resolve_approach("a1-py", None).model_id == bench.MODEL_ID
    with pytest.raises(SystemExit):
        bench.resolve_approach("a9-py", None)
    args = bench.make_parser().parse_args(["run", "--approach", "a2-py", "--manifest", "m", "--out", "o"])
    assert args.approach == "a2-py"


def test_weights_digest_covers_every_shard_and_moves_when_a_byte_changes(tmp_path):
    (tmp_path / "model-00001-of-00002.safetensors").write_bytes(b"a" * 100)
    (tmp_path / "model-00002-of-00002.safetensors").write_bytes(b"b" * 50)
    (tmp_path / "config.json").write_text("{}")
    digest, size = bench.weights_digest(tmp_path)
    assert size == 150 and re.fullmatch(r"[0-9a-f]{64}", digest)
    (tmp_path / "model-00002-of-00002.safetensors").write_bytes(b"b" * 49 + b"c")
    assert bench.weights_digest(tmp_path)[0] != digest
    with pytest.raises(RuntimeError):
        bench.weights_digest(tmp_path / "nothing-here")


class Stub:
    id = "a2-py"


def test_a2_run_record_carries_model_digest_and_both_samplers(tmp_path):
    manifest = {"seed": 1, "corpus_hash": "ef" * 32}
    load_info = {"model": bench.A2_MODEL_ID, "weights_sha256": "ab" * 32, "weights_bytes": 5_760_000_000,
                 "load_s": 0.5, "mlx_vlm_version": "0.5.0", "mlx_version": "0.31.2", "transformers_version": "5.9.0"}
    record = bench.build_run_record(manifest, tmp_path / "m.json", Stub(), load_info, 6, None, None, "r")
    assert record["approach_id"] == "a2-py" and record["model"] == bench.A2_MODEL_ID
    assert record["weights_sha256"] == "ab" * 32 and record["mlx_vlm_version"] == "0.5.0"
    assert record["frames_per_window"] == 6 and record["frames_per_clip"] is None
    assert record["sampler_id"] == "windows-3x6-max60s-middle90"
    assert record["sampler_id_by_corpus"] == {"era": "windows-3x6-max60s-middle90", "ocr": "stills-5-middle90"}
    assert record["ocr_sampler"] == "stills" and record["ocr_stills"] == 5
    # The A1 r3 prompts, verbatim; the OCR prompt is A0's.
    assert record["prompts_sha256"] == {"era": bench.sha256_text(bench.A1_ERA_PROMPT),
                                        "roomFeatures": bench.sha256_text(bench.A1_ROOM_PROMPT),
                                        "date": bench.sha256_text(bench.PROMPTS["date"])}
    assert record["prompt_revision"] == bench.A1_PROMPT_REVISION


# ---------------------------------------------------------------------------
# Two-sampler routing (pure)
# ---------------------------------------------------------------------------
def test_ocr_clip_routes_to_a0_stills_and_era_clip_to_windows():
    ocr = bench.plan_clip_sampling({"ocr"}, 1000.0, 6, bench.OCR_SAMPLER_STILLS)
    assert ocr["windows"] == [] and ocr["date_on_window_frames"] is False
    assert ocr["ocr_still_times_s"] == [round(t, 3) for t in bench.frames_evenly_spaced(5, 1000.0)]
    assert ocr["ocr_still_times_s"] == [50.0, 275.0, 500.0, 725.0, 950.0]
    era = bench.plan_clip_sampling({"era"}, 1000.0, 6, bench.OCR_SAMPLER_STILLS)
    assert era["windows"] == bench.plan_windows(6, 1000.0) and len(era["windows"]) == 3
    assert era["ocr_still_times_s"] == [] and era["date_on_window_frames"] is False
    both = bench.plan_clip_sampling({"era", "ocr"}, 1000.0, 6, bench.OCR_SAMPLER_STILLS)
    assert both["windows"] == era["windows"] and both["ocr_still_times_s"] == ocr["ocr_still_times_s"]


def test_a1_routing_is_unchanged_date_on_window_frames():
    for corpora in ({"ocr"}, {"era"}, {"era", "ocr"}):
        plan = bench.plan_clip_sampling(corpora, 1000.0, 6)
        assert plan["windows"] == bench.plan_windows(6, 1000.0)
        assert plan["ocr_still_times_s"] == [] and plan["date_on_window_frames"] == ("ocr" in corpora)


@pytest.mark.parametrize("duration", [0.0, -3.0, float("nan"), float("inf")])
def test_nothing_to_look_at_plans_no_frame(duration):
    plan = bench.plan_clip_sampling({"era", "ocr"}, duration, 6, bench.OCR_SAMPLER_STILLS)
    assert plan["windows"] == [] and plan["ocr_still_times_s"] == []


def test_unknown_sampler_is_refused():
    with pytest.raises(ValueError):
        bench.plan_clip_sampling({"ocr"}, 10.0, 6, "keyframes")


# ---------------------------------------------------------------------------
# Run loop with a fake approach (no model, no media)
# ---------------------------------------------------------------------------
class FakeA2:
    id = bench.A2_APPROACH_ID

    def __init__(self):
        self.window_calls = []
        self.date_calls = []
        self.seeds = self.cleared = 0

    def seed(self, value):
        self.seeds += 1

    def after_clip(self):
        self.cleared += 1

    def answer(self, image_path, prompt_kind):
        assert Path(image_path).is_file()
        self.date_calls.append((prompt_kind, Path(image_path).name))
        return "JUN 21 1991", {}

    def answer_window(self, image_paths, family, window):
        assert all(Path(p).is_file() for p in image_paths)
        self.window_calls.append((family, window["index"], len(image_paths)))
        return json.dumps(era_obj() if family == "era" else room_obj()), {}


def fake_ripper(path, at_s, dest, duration):
    Path(dest).write_bytes(b"\x89PNG fake")
    return True


def entry(digest, corpus="era", stratum="rick-dated/1990s", duration=1000.0):
    return {"digest": digest, "path": "/Volumes/FamilyArchive/{}.mov".format(digest[:6]), "size_bytes": 1,
            "duration_s": duration, "corpus": corpus, "stratum": stratum,
            "truth": {"year": 1991} if corpus == "era" else {"date": "1991-06-21"},
            "codec": "dvvideo", "container": "DV"}


def run(tmp_path, entries, approach, ripper=fake_ripper):
    return bench.run_corpus_a1(entries, tmp_path / "run", approach, 6, {"run_id": "t"}, ripper=ripper,
                               duration_of=lambda p, d: d, log=lambda s: None,
                               ocr_sampler=bench.OCR_SAMPLER_STILLS)


def test_a2_loop_ocr_clip_gets_five_stills_era_clip_gets_windows_only(tmp_path):
    approach = FakeA2()
    entries = [entry(digest_for(1)), entry(digest_for(2), corpus="ocr", stratum="ocr/prores")]
    progress = run(tmp_path, entries, approach)
    assert progress["done"] == 2 and progress["failed"] == 0 and progress["frames_done"] == 18 + 5
    assert approach.window_calls == [(f, w, 6) for w in range(3) for f in ("era", "roomFeatures")]
    assert [k for k, _ in approach.date_calls] == ["date"] * 5
    assert all(name.startswith("s_") for _, name in approach.date_calls)   # stills, not window frames
    era = bench.read_clip_records(bench.clip_file(tmp_path / "run", digest_for(1)))
    assert len(era["window_results"]) == 6 and era["results"] == []
    assert era["header"]["ocr_sampler"] == "stills" and era["header"]["ocr_still_times_s"] == []
    ocr = bench.read_clip_records(bench.clip_file(tmp_path / "run", digest_for(2)))
    assert ocr["window_results"] == [] and len(ocr["results"]) == 5
    assert [r["at_s"] for r in ocr["results"]] == [50.0, 275.0, 500.0, 725.0, 950.0]
    assert all(r["sampler"] == "stills" and r["window_index"] is None for r in ocr["results"])
    assert ocr["results"][0]["prompt_sha256"] == bench.sha256_text(bench.PROMPTS["date"])
    assert ocr["header"]["windows"] == [] and ocr["header"]["frames_requested"] == 5
    assert bench.score_ocr_clip("1991-06-21", ocr["results"])["majority_exact"] is True
    assert approach.seeds == 2 and approach.cleared == 2
    assert not list((tmp_path / "run").rglob("*.png"))


def test_a2_digest_in_both_corpora_gets_windows_and_stills_once(tmp_path):
    approach = FakeA2()
    progress = run(tmp_path, [entry(digest_for(3)), entry(digest_for(3), corpus="ocr", stratum="ocr/dvvideo")],
                   approach)
    assert progress["total_clips"] == 1 and progress["frames_done"] == 23
    assert len(approach.window_calls) == 6 and len(approach.date_calls) == 5


def test_a2_unrippable_still_is_recorded_and_never_asked(tmp_path):
    approach = FakeA2()
    calls = []

    def flaky(path, at_s, dest, duration):
        calls.append(at_s)
        return False if len(calls) == 2 else fake_ripper(path, at_s, dest, duration)

    run(tmp_path, [entry(digest_for(4), corpus="ocr", stratum="ocr/h264")], approach, ripper=flaky)
    lines = [json.loads(l) for l in bench.clip_file(tmp_path / "run", digest_for(4)).read_text().splitlines()]
    failed = [l for l in lines if l["record_type"] == "frame_failed"]
    assert len(failed) == 1 and failed[0]["sampler"] == "stills" and failed[0]["at_s"] == 275.0
    assert len(approach.date_calls) == 4 and lines[-1]["frames_failed"] == 1


def test_a2_resume_skips_done_and_redoes_partial(tmp_path):
    run(tmp_path, [entry(digest_for(5), corpus="ocr", stratum="ocr/h264"), entry(digest_for(6))], FakeA2())
    partial = bench.clip_file(tmp_path / "run", digest_for(6))
    partial.write_text("\n".join(partial.read_text().splitlines()[:-1]) + "\n")
    second = FakeA2()
    progress = run(tmp_path, [entry(digest_for(5), corpus="ocr", stratum="ocr/h264"), entry(digest_for(6))], second)
    assert progress["skipped_resume"] == 1 and len(second.window_calls) == 6 and second.date_calls == []


# ---------------------------------------------------------------------------
# Summary, reading, privacy gate
# ---------------------------------------------------------------------------
PROPER_NOUNS = ("Hornets", "Smith", "Disney", "Middlefield")


def wr(family, value, window_index=0):
    text = value if isinstance(value, str) else json.dumps(value)
    decoded, _ = bench.decode_contract(family, text)
    return {"record_type": "window_result", "family": family, "window_index": window_index, "raw_text": text,
            "schema_valid": decoded is not None, "decoded": decoded, "elapsed_s": 4.0, "rip_s": 0.6, "error": None}


def handmade_run(tmp_path, approach_id="a2-py", model=None, era_range=(1990, 1994)):
    out = tmp_path / approach_id
    clips = [
        {"digest": digest_for(11), "corpus": "era", "stratum": "rick-dated/1990s", "truth": {"year": 1991}},
        {"digest": digest_for(12), "corpus": "era", "stratum": "camera/2020s/hevc", "truth": {"year": 2021}},
        {"digest": digest_for(13), "corpus": "ocr", "stratum": "ocr/prores", "truth": {"date": "1991-06-21"}},
    ]
    manifest = {"record_type": "manifest", "schema_version": 1, "seed": 1, "corpus_hash": "ef" * 32,
                "counts": {"era": 2, "ocr": 1, "strata": {}},
                "clips": [{**c, "path": "/Volumes/FamilyArchive/secret/{}.mov".format(c["digest"][:8]),
                           "size_bytes": 1, "duration_s": 1000.0, "codec": "x", "container": "y"} for c in clips]}
    (out / "clips").mkdir(parents=True)
    (out / "run.json").write_text(json.dumps({
        "run_id": "20261031T000000-" + approach_id, "approach_id": approach_id, "model": model or bench.A2_MODEL_ID,
        "weights_sha256": "ab" * 32, "sampler_id": "windows-3x6-max60s-middle90", "frames_per_window": 6,
        "ocr_sampler": "stills" if approach_id == "a2-py" else None,
        "host": "RicksUltra", "git_sha": "cd" * 20, "corpus_hash": "ef" * 32, "load_s": 0.5,
        "prompts_sha256": {"era": "12" * 32}}))
    (out / "progress.json").write_text(json.dumps({"state": "finished"}))

    def write(digest, records, frames):
        with bench.clip_file(out, digest).open("w") as stream:
            stream.write(json.dumps({"record_type": "clip", "digest": digest}) + "\n")
            for r in records:
                stream.write(json.dumps({**r, "digest": digest}) + "\n")
            stream.write(json.dumps({"record_type": "clip_done", "digest": digest, "frames_ok": frames,
                                     "peak_rss_bytes": 7_100_000_000}) + "\n")

    write(digest_for(11), [
        wr("era", era_obj(yearRange=list(era_range), rationale="Charlotte Hornets jacket, 1990s"), 0),
        wr("roomFeatures", room_obj(features=["green shag carpet", "Hornets poster", "Smith family couch"]), 0),
        wr("era", "The Smith family at Disney, around 1991.", 1),
    ], 12)
    write(digest_for(12), [wr("era", era_obj(yearRange=[2018, 2022]), 0), wr("roomFeatures", "{}", 0)], 6)
    write(digest_for(13), [{"record_type": "result", "frame_index": i, "window_index": None, "sampler": "stills",
                            "prompt_kind": "date", "raw_text": "JUN 21 1991" if i % 2 else "NONE",
                            "elapsed_s": 0.4, "rip_s": 0.1, "error": None} for i in range(5)], 5)
    return out, manifest


def test_summarize_a2_math_and_family_decade_group(tmp_path):
    out, manifest = handmade_run(tmp_path)
    s = bench.summarize_a1_run(out, manifest)
    assert s["approach_id"] == "a2-py" and s["model"] == bench.A2_MODEL_ID and s["ocr_sampler"] == "stills"
    assert s["era"]["by_family"]["rick-dated"]["mae_years"] == 1.0          # [1990, 1994] → 1992 vs 1991
    assert s["era"]["by_family_decade"]["camera/2020s"]["mae_years"] == 1.0  # [2018, 2022] → 2020 vs 2021
    assert s["ocr"]["all"]["date_frames"] == 5 and s["ocr"]["all"]["majority_exact"] == 1.0
    assert s["cost"]["date_generations"] == 5 and s["cost"]["s_per_date_generation"] == pytest.approx(0.4)
    assert s["cost"]["frames"] == 23 and s["cost"]["peak_rss_gb"] == 7.1


def test_a2_reading_names_a0_a1_and_a2_numbers(tmp_path):
    a2_dir, manifest = handmade_run(tmp_path)
    a1_dir, _ = handmade_run(tmp_path, "a1-py", bench.MODEL_ID, era_range=(1980, 1990))
    a2 = bench.summarize_a1_run(a2_dir, manifest)
    a1 = bench.summarize_a1_run(a1_dir, manifest)
    lines = bench.a2_reading(a2, None, a1)
    assert len(lines) == 3
    assert "A0 — / A1 6.0 / A2 1.0 y" in lines[0]          # A0 missing → "—", never invented
    assert "camera-dated 2020s A1 1.0 → A2 1.0 y" in lines[0]
    assert "A0 — → A2 " in lines[1]
    assert lines[2].startswith("3. **Cost vs A1:**")


def test_a2_markdown_carries_no_path_digest_model_text_or_proper_noun(tmp_path):
    out, manifest = handmade_run(tmp_path)
    md = bench.format_a2_markdown(bench.summarize_a1_run(out, manifest), None, None)
    assert md.startswith("## Approach `a2-py` — Qwen3-VL-8B")
    assert "stills-5-middle90" in md and "A2 vs A0 and A1" in md
    assert "/Volumes" not in md and "/Users" not in md and "secret" not in md
    assert not re.search(r"[0-9a-f]{40,}", md)
    for clip in manifest["clips"]:
        assert clip["digest"][:12] not in md
    for text in ("JUN 21 1991", "Charlotte", "camcorder OSD", "boxy sedan", "family at") + PROPER_NOUNS:
        assert text not in md
        assert text.lower() not in md.lower()
    assert "catalog.sqlite" not in md


def test_summarize_command_puts_a0_a1_a2_in_order(tmp_path):
    a2_dir, manifest = handmade_run(tmp_path)
    a1_dir, _ = handmade_run(tmp_path, "a1-py", bench.MODEL_ID)
    a0 = tmp_path / "a0"
    (a0 / "clips").mkdir(parents=True)
    (a0 / "run.json").write_text(json.dumps({"approach_id": "a0-py", "run_id": "r0"}))
    mpath = tmp_path / "manifest.json"
    mpath.write_text(json.dumps(manifest))
    md_path = tmp_path / "bench.md"
    args = argparse.Namespace(manifest=str(mpath), run=[str(a2_dir), str(a0), str(a1_dir)], out=str(md_path),
                              json_out=None)
    assert bench.summarize_command(args) == 0
    md = md_path.read_text()
    assert md.index("## Approach `a0-py`") < md.index("## Approach `a1-py`") < md.index("## Approach `a2-py`")
    assert md.count("**A1 vs A0**") == 1 and md.count("**A2 vs A0 and A1**") == 1


def test_a2_scale_100k_still_records_score_inside_the_budget():
    """Scale: 100k OCR still records (20k clips × 5) are scored in well under a minute."""
    import time
    records = [{"prompt_kind": "date", "raw_text": "JUN 21 1991" if i % 2 else "NONE"} for i in range(5)]
    started = time.perf_counter()
    for _ in range(20_000):
        bench.score_ocr_clip("1991-06-21", records)
    assert time.perf_counter() - started < 30.0
    assert math.isclose(bench.aggregate_ocr([bench.score_ocr_clip("1991-06-21", records)])["frames_with_date_rate"], 0.4)
