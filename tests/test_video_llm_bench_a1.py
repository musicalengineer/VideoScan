"""tools/video-llm-bench/bench.py — approach a1-py (windows + strict JSON contract).

No model, no media, no catalog: venv/bin/python3 -m pytest tests/test_video_llm_bench_a1.py.
Covers window planning, the fail-closed contract decoder (a Python mirror of the Swift
`ContractDecoder`), the yearRange midpoint / inside-range scoring, the A1 run loop with a
fake approach and ripper, and the privacy gate on the A1 Markdown (no path, no digest,
no raw model text, no capitalised proper noun).
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
SPEC = importlib.util.spec_from_file_location("video_llm_bench_a1_under_test", SCRIPT)
assert SPEC and SPEC.loader
bench = importlib.util.module_from_spec(SPEC)
sys.modules["video_llm_bench_a1_under_test"] = bench
SPEC.loader.exec_module(bench)

SWIFT_CONTRACTS = ROOT / "VideoScan" / "VideoScanCore" / "Sources" / "VideoScanCore" / "ModelLab" / "ApproachOutputContracts.swift"


def digest_for(n: int) -> str:
    return "{:064x}".format(n)


# ---------------------------------------------------------------------------
# Window planning
# ---------------------------------------------------------------------------
def assert_well_formed(windows, duration, n):
    lo, hi = duration * 0.05, duration * 0.95
    for i, w in enumerate(windows):
        assert w["index"] == i
        assert lo - 1e-6 <= w["start_s"] < w["end_s"] <= hi + 1e-6
        times = w["frame_times_s"]
        assert 1 <= len(times) <= n
        assert times == sorted(times) and len(set(times)) == len(times)
        assert all(w["start_s"] < t < w["end_s"] for t in times)      # never on a boundary
    for left, right in zip(windows, windows[1:]):
        assert left["end_s"] <= right["start_s"] + 1e-6               # no overlap, chronological


def test_long_clip_gets_three_minute_windows_at_start_middle_and_end():
    windows = bench.plan_windows(6, 1000.0)
    assert len(windows) == 3
    assert_well_formed(windows, 1000.0, 6)
    assert [(w["start_s"], w["end_s"]) for w in windows] == [(50.0, 110.0), (470.0, 530.0), (890.0, 950.0)]
    assert all(len(w["frame_times_s"]) == 6 for w in windows)
    assert windows[0]["frame_times_s"] == [55.0, 65.0, 75.0, 85.0, 95.0, 105.0]


def test_medium_clip_gets_three_contiguous_thirds_without_overlap():
    windows = bench.plan_windows(6, 60.0)            # middle 90 % = 3…57 s, span 54 s ≥ 30 s
    assert len(windows) == 3
    assert_well_formed(windows, 60.0, 6)
    assert windows[0]["start_s"] == pytest.approx(3.0) and windows[-1]["end_s"] == pytest.approx(57.0)
    assert windows[0]["end_s"] == pytest.approx(windows[1]["start_s"])


def test_short_clip_gets_one_window():
    windows = bench.plan_windows(6, 20.0)            # span 18 s < 3 × 10 s
    assert len(windows) == 1
    assert_well_formed(windows, 20.0, 6)
    assert (windows[0]["start_s"], windows[0]["end_s"]) == (1.0, 19.0)
    assert len(windows[0]["frame_times_s"]) == 6


def test_tiny_clip_gets_fewer_frames_not_duplicates():
    windows = bench.plan_windows(6, 1.0)             # span 0.9 s → at most 3 frames 0.25 s apart
    assert len(windows) == 1 and len(windows[0]["frame_times_s"]) == 3
    assert_well_formed(windows, 1.0, 6)


@pytest.mark.parametrize("duration,n", [(0.0, 6), (-5.0, 6), (float("nan"), 6), (float("inf"), 6), (100.0, 0)])
def test_nothing_to_look_at_plans_no_window(duration, n):
    assert bench.plan_windows(n, duration) == []


# ---------------------------------------------------------------------------
# Fail-closed decoder
# ---------------------------------------------------------------------------
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


def decode(family, value):
    text = value if isinstance(value, str) else json.dumps(value)
    return bench.decode_contract(family, text)


def test_valid_era_and_room_decode():
    value, reason = decode("era", era_obj())
    assert reason is None and value["yearRange"] == [1991, 1995] and value["cues"][0]["atS"] == 131.0
    value, reason = decode("roomFeatures", room_obj())
    assert reason is None and value["features"] == ["green shag carpet", "brick fireplace"]
    # Swift Int accepts an integral JSON number written with a fraction; so does the mirror.
    value, reason = decode("era", era_obj(yearRange=[1991.0, 1995]))
    assert reason is None and value["yearRange"] == [1991, 1995]
    assert decode("era", era_obj(cues=[]))[1] is None                  # no cue is an honest answer


@pytest.mark.parametrize("family,payload,needle", [
    ("era", era_obj(confidence_score=0.9), "unknown key"),
    ("roomFeatures", room_obj(extra="x"), "unknown key"),
    ("era", era_obj(cues=[{"kind": "technical", "text": "x", "atS": 1.0, "why": "y"}]), "unknown key"),
    ("era", era_obj(yearRange=["1991", "1995"]), "wrong type"),
    ("era", era_obj(yearRange=[1991.5, 1995]), "not representable"),
    ("era", era_obj(yearRange=[True, 1995]), "wrong type"),
    ("era", era_obj(selfConfidence="high"), "wrong type"),
    ("era", era_obj(selfConfidence=True), "wrong type"),
    ("era", era_obj(window="120.0 s to 180.0 s"), "wrong type"),
    ("era", era_obj(rationale=None), "null"),
    ("roomFeatures", room_obj(features="carpet"), "wrong type"),
    ("roomFeatures", room_obj(features=["carpet", 3]), "wrong type"),
    ("era", era_obj(yearRange=[19910, 19950]), "outside 1900"),
    ("era", era_obj(yearRange=[1899, 1950]), "outside 1900"),
    ("era", era_obj(yearRange=[1995, 1991]), "reversed"),
    ("era", era_obj(yearRange=[1991]), "two years"),
    ("era", era_obj(window=[180.0, 120.0]), "before its start"),
    ("era", era_obj(window=[-1.0, 10.0]), "at or after 0"),
    ("era", era_obj(family="roomFeatures"), "where 'era' was asked for"),
    ("roomFeatures", room_obj(family="outdoor"), "unknown family"),
    ("era", era_obj(selfConfidence=1.5), "outside 0"),
    ("era", era_obj(cues=[{"kind": "onScreen", "text": "x", "atS": 1.0}]), "not one of"),
    ("era", era_obj(cues=[{"kind": "technical", "text": "x", "atS": -2.0}]), "frame time"),
    ("era", era_obj(cues=[{"kind": "technical", "text": "x", "atS": 1.0}] * 65), "cap"),
    ("era", era_obj(rationale="   "), "is empty"),
    ("roomFeatures", room_obj(setting="inside"), "not one of"),
    ("roomFeatures", room_obj(features=["carpet", " "]), "empty item"),
])
def test_contract_violations_are_schema_invalid(family, payload, needle):
    value, reason = decode(family, payload)
    assert value is None and needle in reason


def test_missing_key_is_schema_invalid():
    obj = era_obj()
    del obj["cues"]
    value, reason = decode("era", obj)
    assert value is None and reason == "missing key 'cues'"
    obj = era_obj(cues=[{"kind": "technical", "text": "x"}])
    assert decode("era", obj)[1] == "missing key 'cues.0.atS'"


@pytest.mark.parametrize("text,needle", [
    ("", "empty"),
    ("NONE", "not valid JSON"),
    ("The footage looks like the 1990s.", "not valid JSON"),
    ("[1991, 1995]", "expected Object"),
    (json.dumps([era_obj()]), "expected Object"),
    ("```json\n" + json.dumps(era_obj()) + "\n```", "not valid JSON"),       # a fence is not stripped
    ("Here you go: " + json.dumps(era_obj()), "not valid JSON"),             # no "find the first {"
    (json.dumps(era_obj()) + " Hope this helps.", "not valid JSON"),         # no trailing text
    (json.dumps(era_obj())[:-10], "not valid JSON"),                          # truncated at max_tokens
    (json.dumps(era_obj()).replace("0.7", "NaN"), "not a JSON number"),      # Foundation rejects NaN
    ('{"family": "era", "family": "era"}', "duplicate key"),
    ("x" * (64 * 1024 + 1), "cap"),
])
def test_garbage_is_schema_invalid_never_rescued(text, needle):
    value, reason = bench.decode_contract("era", text)
    assert value is None and needle in reason


def test_a_family_without_a_contract_is_refused():
    assert bench.decode_contract("ocrDate", json.dumps({"family": "ocrDate"}))[0] is None


def test_python_contract_keys_match_the_swift_contract():
    swift = SWIFT_CONTRACTS.read_text(encoding="utf-8")

    def keys_of(extension: str) -> tuple:
        block = swift[swift.index("extension {}: Decodable".format(extension)):]
        match = re.search(r"case ([a-zA-Z, ]+) \}", block)
        assert match, extension
        return tuple(k.strip() for k in match.group(1).split(","))

    assert keys_of("EraContract") == bench._ERA_KEYS
    assert keys_of("RoomFeaturesContract") == bench._ROOM_KEYS
    assert keys_of("ContractCue") == bench._CUE_KEYS
    assert "static let maxJSONBytes = 64 * 1024" in swift and bench.CONTRACT_MAX_JSON_BYTES == 64 * 1024
    assert "static let maxListItems = 64" in swift and bench.CONTRACT_MAX_LIST_ITEMS == 64
    assert "static let yearRange = 1900...2100" in swift
    for word in bench.CUE_KINDS + bench.ROOM_SETTINGS + bench.FIELD_FAMILIES:
        assert word in swift


def test_each_prompt_names_every_contract_key_and_the_window():
    window = {"index": 0, "start_s": 12.0, "end_s": 72.0, "frame_times_s": [17.0, 27.0, 37.0]}
    era = bench.format_a1_prompt("era", window)
    room = bench.format_a1_prompt("roomFeatures", window)
    for key in bench._ERA_KEYS + bench._CUE_KEYS:
        assert '"{}"'.format(key) in era
    for key in bench._ROOM_KEYS:
        assert '"{}"'.format(key) in room
    assert "[12.0, 72.0]" in era and "[12.0, 72.0]" in room and "17.0, 27.0, 37.0" in era
    for word in bench.CUE_KINDS:
        assert word in era
    for word in bench.ROOM_SETTINGS:
        assert word in room


# ---------------------------------------------------------------------------
# Scoring: midpoint and inside-range
# ---------------------------------------------------------------------------
def wr(family, value, window_index=0, valid_flag=None, error=None):
    text = value if isinstance(value, str) else json.dumps(value)
    decoded, _ = bench.decode_contract(family, text)
    return {"record_type": "window_result", "family": family, "window_index": window_index, "raw_text": text,
            "schema_valid": decoded is not None if valid_flag is None else valid_flag, "decoded": decoded,
            "elapsed_s": 2.0, "rip_s": 0.6, "error": error}


def test_midpoint_and_inside_range():
    windows = [wr("era", era_obj(yearRange=[1990, 2000]), 0), wr("era", era_obj(yearRange=[1980, 1990]), 1),
               wr("era", era_obj(yearRange=[1980, 1990]), 2)]
    assert bench.clip_year_range(windows) == (1980.0, 1990.0)
    row = bench.score_a1_era_clip(1991, windows)
    assert row["guess"] == 1985.0 and row["abs_err"] == 6.0 and row["inside"] is False and row["width"] == 10.0
    row = bench.score_a1_era_clip(1988, windows)
    assert row["inside"] is True and row["abs_err"] == 3.0
    assert bench.score_a1_era_clip(1990, windows)["inside"] is True        # inclusive bounds
    # two windows: median of FROM and of TO separately
    two = [wr("era", era_obj(yearRange=[1990, 2000])), wr("era", era_obj(yearRange=[1980, 1990]))]
    assert bench.clip_year_range(two) == (1985.0, 1995.0)


def test_scoring_redecodes_and_never_trusts_the_stored_flag():
    lying = wr("era", "```json\n" + json.dumps(era_obj(yearRange=[1950, 1950])) + "\n```", valid_flag=True)
    errored = wr("era", era_obj(yearRange=[1960, 1960]), error="RuntimeError: boom")
    room = wr("roomFeatures", room_obj())
    assert bench.clip_year_range([lying, errored, room]) is None
    row = bench.score_a1_era_clip(1991, [lying, errored, room])
    assert row["guess"] is None and row["abs_err"] is None and row["inside"] is None


def test_aggregate_rates():
    rows = [bench.score_a1_era_clip(1991, [wr("era", era_obj(yearRange=[1990, 2000]))]),     # mid 1995, inside, err 4
            bench.score_a1_era_clip(1970, [wr("era", era_obj(yearRange=[1980, 1990]))]),     # mid 1985, outside, err 15
            bench.score_a1_era_clip(2021, [wr("era", "NONE")])]                              # no answer
    agg = bench.aggregate_a1_era(rows)
    assert agg["n"] == 3 and agg["answered"] == 2
    assert agg["answered_rate"] == pytest.approx(2 / 3)
    assert agg["mae_years"] == pytest.approx(9.5)
    assert agg["within_5_of_answered"] == pytest.approx(0.5) and agg["within_5_of_all"] == pytest.approx(1 / 3)
    assert agg["inside_of_answered"] == pytest.approx(0.5) and agg["inside_of_all"] == pytest.approx(1 / 3)
    assert agg["median_width_years"] == 10.0
    empty = bench.aggregate_a1_era([])
    assert empty["answered_rate"] is None and empty["median_width_years"] is None


# ---------------------------------------------------------------------------
# Run loop with a fake approach (no model, no media)
# ---------------------------------------------------------------------------
class FakeA1:
    id = bench.A1_APPROACH_ID

    def __init__(self, era_text=None, room_text=None, fail_family=None):
        self.era_text = era_text if era_text is not None else json.dumps(era_obj())
        self.room_text = room_text if room_text is not None else json.dumps(room_obj())
        self.fail_family = fail_family
        self.window_calls = []
        self.date_calls = []
        self.seeds = self.cleared = 0

    def seed(self, value):
        self.seeds += 1

    def after_clip(self):
        self.cleared += 1

    def answer(self, image_path, prompt_kind):
        assert Path(image_path).is_file()
        self.date_calls.append(prompt_kind)
        return "JUN 21 1991", {}

    def answer_window(self, image_paths, family, window):
        assert all(Path(p).is_file() for p in image_paths)
        self.window_calls.append((family, window["index"], len(image_paths)))
        if family == self.fail_family:
            raise RuntimeError("boom")
        return (self.era_text if family == "era" else self.room_text), {"generation_tokens": 9}


def fake_ripper(path, at_s, dest, duration):
    Path(dest).write_bytes(b"\x89PNG fake")
    return True


def entry(digest, corpus="era", stratum="rick-dated/1990s", truth=None, duration=1000.0):
    return {"digest": digest, "path": "/Volumes/FamilyArchive/{}.mov".format(digest[:6]), "size_bytes": 1,
            "duration_s": duration, "corpus": corpus, "stratum": stratum,
            "truth": truth or ({"year": 1991} if corpus == "era" else {"date": "1991-06-21"}),
            "codec": "dvvideo", "container": "DV"}


def run(tmp_path, entries, approach, **kw):
    return bench.run_corpus_a1(entries, tmp_path / "run", approach, 6, {"run_id": "t"}, ripper=fake_ripper,
                               duration_of=lambda p, d: d, log=lambda s: None, **kw)


def test_era_clip_gets_one_generation_per_window_and_family_ocr_clip_gets_date_per_frame(tmp_path):
    approach = FakeA1()
    entries = [entry(digest_for(1)), entry(digest_for(2), corpus="ocr", stratum="ocr/prores")]
    progress = run(tmp_path, entries, approach)
    assert progress["done"] == 2 and progress["failed"] == 0 and progress["frames_done"] == 36
    assert approach.window_calls == [(f, w, 6) for w in range(3) for f in ("era", "roomFeatures")]
    assert approach.date_calls == ["date"] * 18
    era = bench.read_clip_records(bench.clip_file(tmp_path / "run", digest_for(1)))
    assert len(era["window_results"]) == 6 and era["results"] == []
    assert all(r["schema_valid"] for r in era["window_results"])
    assert era["window_results"][0]["prompt_sha256"] == bench.sha256_text(bench.A1_ERA_PROMPT)
    ocr = bench.read_clip_records(bench.clip_file(tmp_path / "run", digest_for(2)))
    assert ocr["window_results"] == [] and len(ocr["results"]) == 18
    assert ocr["results"][0]["prompt_sha256"] == bench.sha256_text(bench.PROMPTS["date"])
    assert ocr["results"][0]["parsed"]["dates"] == ["1991-06-21"]
    assert approach.seeds == 2 and approach.cleared == 2
    assert not list((tmp_path / "run").rglob("*.png"))


def test_a_digest_in_both_corpora_is_run_once_with_both_prompt_sets(tmp_path):
    approach = FakeA1()
    entries = [entry(digest_for(3)), entry(digest_for(3), corpus="ocr", stratum="ocr/dvvideo")]
    progress = run(tmp_path, entries, approach)
    assert progress["total_clips"] == 1 and progress["done"] == 1
    assert len(approach.window_calls) == 6 and len(approach.date_calls) == 18


def test_invalid_output_is_recorded_schema_invalid_with_its_reason(tmp_path):
    approach = FakeA1(era_text="```json\n" + json.dumps(era_obj()) + "\n```", fail_family="roomFeatures")
    run(tmp_path, [entry(digest_for(4))], approach)
    rec = bench.read_clip_records(bench.clip_file(tmp_path / "run", digest_for(4)))
    era = [r for r in rec["window_results"] if r["family"] == "era"]
    room = [r for r in rec["window_results"] if r["family"] == "roomFeatures"]
    assert all(not r["schema_valid"] and r["decoded"] is None and "not valid JSON" in r["schema_invalid_reason"] for r in era)
    assert all(r["error"].startswith("RuntimeError") and not r["schema_valid"] for r in room)
    assert rec["footer"]["window_results"] == 6


def test_resume_skips_done_clips_and_redoes_partial(tmp_path):
    first = FakeA1()
    run(tmp_path, [entry(digest_for(5)), entry(digest_for(6))], first)
    partial = bench.clip_file(tmp_path / "run", digest_for(6))
    lines = partial.read_text().splitlines()
    partial.write_text("\n".join(lines[:-1]) + "\n")
    second = FakeA1()
    progress = run(tmp_path, [entry(digest_for(5)), entry(digest_for(6))], second)
    assert progress["skipped_resume"] == 1 and progress["done"] == 1 and len(second.window_calls) == 6
    assert bench.clip_is_done(partial)


def test_an_unrippable_clip_runs_nothing_and_is_failed(tmp_path):
    approach = FakeA1()
    progress = bench.run_corpus_a1([entry(digest_for(7))], tmp_path / "run", approach, 6, {"run_id": "t"},
                                   ripper=lambda p, a, d, dur: False, duration_of=lambda p, d: d, log=lambda s: None)
    assert progress["failed"] == 1 and approach.window_calls == [] and approach.date_calls == []


# ---------------------------------------------------------------------------
# Summary + privacy gate on the Markdown
# ---------------------------------------------------------------------------
PROPER_NOUNS = ("Hornets", "Smith", "Disney", "Middlefield")


def handmade_a1_run(tmp_path):
    out = tmp_path / "a1"
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
        "run_id": "20261030T220000-a1-py", "approach_id": "a1-py", "model": bench.MODEL_ID,
        "weights_sha256": "ab" * 32, "sampler_id": "windows-3x6-max60s-middle90", "frames_per_window": 6,
        "host": "RicksUltra", "git_sha": "cd" * 20, "corpus_hash": "ef" * 32, "load_s": 1.4,
        "prompts_sha256": {"era": "12" * 32}}))
    (out / "progress.json").write_text(json.dumps({"state": "finished"}))

    def write(digest, records):
        with bench.clip_file(out, digest).open("w") as stream:
            stream.write(json.dumps({"record_type": "clip", "digest": digest}) + "\n")
            for r in records:
                stream.write(json.dumps({**r, "digest": digest}) + "\n")
            stream.write(json.dumps({"record_type": "clip_done", "digest": digest, "frames_ok": 18,
                                     "peak_rss_bytes": 3_800_000_000}) + "\n")

    write(digest_for(11), [
        wr("era", era_obj(yearRange=[1990, 2000], rationale="Charlotte Hornets jacket, 1990s"), 0),
        wr("roomFeatures", room_obj(features=["green shag carpet", "Hornets poster", "Smith family couch",
                                              "brick fireplace"]), 0),
        wr("era", "The Smith family at Disney, around 1991.", 1),
        wr("roomFeatures", room_obj(features=["green shag carpet", "wood-paneled walls"], setting="indoor"), 1),
    ])
    write(digest_for(12), [wr("era", "NONE", 0), wr("roomFeatures", "{}", 0)])
    write(digest_for(13), [{"record_type": "result", "frame_index": i, "window_index": i // 6, "prompt_kind": "date",
                            "raw_text": "JUN 21 1991" if i % 2 else "NONE", "elapsed_s": 0.2, "rip_s": 0.1,
                            "error": None} for i in range(18)])
    return out, manifest


def test_summarize_a1_math(tmp_path):
    out, manifest = handmade_a1_run(tmp_path)
    s = bench.summarize_a1_run(out, manifest)
    assert s["schema"]["era"] == {"windows": 3, "valid": 1, "valid_rate": pytest.approx(1 / 3),
                                  "invalid_by_class": {"not JSON (prose, fence, truncated, trailing text)": 2}}
    assert s["schema"]["roomFeatures"]["valid"] == 2 and s["schema"]["roomFeatures"]["invalid_by_class"] == {"missing key": 1}
    era = s["era"]["all"]
    assert era["n"] == 2 and era["answered"] == 1 and era["mae_years"] == 4.0 and era["inside_of_answered"] == 1.0
    assert s["ocr"]["all"]["any_frame_exact"] == 1.0 and s["ocr"]["all"]["date_frames"] == 18
    room = s["room"]
    assert room["feature_items"] == 6 and room["vocabulary"] == 5 and room["dropped_unsafe_items"] == 2
    assert room["top20"][0] == ("green shag carpet", 2)
    assert {name for name, _ in room["top20"]} == {"green shag carpet", "brick fireplace", "wood-paneled walls"}
    assert s["cost"]["window_generations"] == 6 and s["cost"]["date_generations"] == 18
    assert s["cost"]["s_per_window_generation"] == pytest.approx(2.0)
    assert s["clips"]["unreadable"] == 0 and s["clips"]["era_scored"] == 2


def test_a1_markdown_carries_no_path_digest_model_text_or_proper_noun(tmp_path):
    out, manifest = handmade_a1_run(tmp_path)
    md = bench.format_a1_markdown(bench.summarize_a1_run(out, manifest), None)
    assert "/Volumes" not in md and "/Users" not in md and "secret" not in md
    assert not re.search(r"[0-9a-f]{40,}", md)
    for clip in manifest["clips"]:
        assert clip["digest"][:12] not in md
    for text in ("JUN 21 1991", "Charlotte", "camcorder OSD", "boxy sedan", "family at") + PROPER_NOUNS:
        assert text not in md
        assert text.lower() not in md.lower()          # not even after the vocabulary's lower-casing
    top = md[md.index("| # | feature | occurrences"):]
    for row in top.splitlines()[2:]:
        if row.startswith("|"):
            assert not re.search(r"[A-Z]", row.split("|")[2]), row
    assert "| **all** | 2 | 1 | 50% | 4.0 |" in md


def test_summarize_command_puts_a0_and_a1_side_by_side(tmp_path):
    out, manifest = handmade_a1_run(tmp_path)
    a0 = tmp_path / "a0"
    (a0 / "clips").mkdir(parents=True)
    (a0 / "run.json").write_text(json.dumps({"approach_id": "a0-py", "run_id": "r0"}))
    mpath = tmp_path / "manifest.json"
    mpath.write_text(json.dumps(manifest))
    md_path = tmp_path / "bench.md"
    args = argparse.Namespace(manifest=str(mpath), run=[str(a0), str(out)], out=str(md_path), json_out=None)
    assert bench.summarize_command(args) == 0
    md = md_path.read_text()
    assert md.startswith("# Video LLM benchmarks")
    assert md.index("## Approach `a0-py`") < md.index("## Approach `a1-py`")
    assert "1. **Answered rate:**" in md and "3. **Cost:**" in md


def test_a1_scale_100k_window_records_summarise_inside_the_budget(tmp_path):
    """Scale: 100k window records (≈ 16k clips × 6) are scored in well under a minute."""
    import time
    records = [wr("era", era_obj(yearRange=[1980 + i % 30, 1990 + i % 30])) for i in range(64)]
    started = time.perf_counter()
    for i in range(100_000 // 64 + 1):
        bench.clip_year_range(records)
    assert time.perf_counter() - started < 30.0
    assert math.isclose(bench.clip_year_range(records)[0], float(sorted(1980 + i % 30 for i in range(64))[31] +
                                                                  sorted(1980 + i % 30 for i in range(64))[32]) / 2)
