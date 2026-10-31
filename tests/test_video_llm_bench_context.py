"""tools/video-llm-bench/bench.py — the technical-context prompt variant (`--context technical`).

No model, no media, no catalog: venv/bin/python3 -m pytest tests/test_video_llm_bench_context.py.
Rick 2026-10-31: "a codec can often be a good clue; I want it to have access to as much info as
possible." The model is told the file's codec, container, frame size, rate, scan and aspect —
never a date — with a transfer codec named as one so a 1988 tape in FFV1 is not read as 2010s.
"""
from __future__ import annotations

import json
import re

from test_video_llm_bench_a2 import FakeA2, bench, digest_for, entry, fake_ripper


DV_PROBE = json.dumps({"streams": [{"codec_name": "dvvideo", "width": 720, "height": 480, "r_frame_rate": "30000/1001",
                                     "field_order": "bb", "display_aspect_ratio": "4:3"}],
                       "format": {"format_name": "mov,mp4,m4a,3gp,3g2,mj2"}})
FFV1_PROBE = json.dumps({"streams": [{"codec_name": "ffv1", "width": 720, "height": 576, "r_frame_rate": "25/1",
                                       "field_order": "tt", "display_aspect_ratio": "4:3"}],
                         "format": {"format_name": "matroska,webm"}})
HEVC_PROBE = json.dumps({"streams": [{"codec_name": "hevc", "width": 3840, "height": 2160, "r_frame_rate": "60/1",
                                       "field_order": "progressive", "display_aspect_ratio": "16:9"}],
                         "format": {"format_name": "mov,mp4,m4a,3gp,3g2,mj2"}})


def test_parse_technical_reads_the_stream_and_container_and_never_a_date():
    t = bench.parse_technical(DV_PROBE)
    assert t == {"codec": "dvvideo", "width": 720, "height": 480, "fps": 29.97, "scan": "interlaced", "aspect": "4:3", "container": "mov"}
    assert bench.parse_technical(HEVC_PROBE)["scan"] == "progressive" and bench.parse_technical(HEVC_PROBE)["fps"] == 60.0
    assert bench.parse_technical("") == {} and bench.parse_technical("not json") == {} and bench.parse_technical('{"streams": []}') == {}
    assert bench.parse_technical(json.dumps({"streams": [{"codec_name": "h264", "width": 0, "height": 0, "r_frame_rate": "0/0"}]})) == {"codec": "h264"}
    for key in ("creation_time", "date", "embedded_created_at"):
        assert key not in bench.parse_technical(DV_PROBE)


def test_context_line_names_a_transfer_codec_as_such_and_gives_a_native_codec_its_era():
    ffv1 = bench.technical_context_line(bench.parse_technical(FFV1_PROBE))
    assert ffv1.startswith("Technical facts about this file (from its container, not from the pictures): ")
    assert "FFV1 in matroska — a lossless TRANSFER format" in ffv1 and "says nothing about when the footage was recorded" in ffv1
    assert "720×576 pixels; 25 fps; interlaced; aspect 4:3." in ffv1
    dv = bench.technical_context_line(bench.parse_technical(DV_PROBE))
    assert "codec dvvideo in mov — DV camcorder tape (MiniDV / Digital8, 1995 onward)" in dv and "29.97 fps; interlaced" in dv
    hevc = bench.technical_context_line(bench.parse_technical(HEVC_PROBE))
    assert "HEVC/H.265 (2013 onward; phones from 2017)" in hevc and "3840×2160 pixels; 60 fps; progressive; aspect 16:9." in hevc
    assert bench.technical_context_line({}) == ""
    assert "unknowncodec in ?" in bench.technical_context_line({"codec": "unknowncodec"}) and "camera-native" in bench.technical_context_line({"codec": "unknowncodec"})


def test_the_context_goes_first_and_the_contract_text_is_unchanged():
    window = {"index": 0, "start_s": 0.0, "end_s": 60.0, "frame_times_s": [5.0, 25.0, 45.0]}
    plain = bench.format_a1_prompt("era", window)
    with_ctx = bench.format_a1_prompt("era", window, "Technical facts about this file: codec dvvideo.")
    assert with_ctx.startswith("Technical facts about this file: codec dvvideo.\n")
    assert with_ctx.endswith(plain), "the contract text and its JSON keys are untouched below the line"
    assert bench.format_a1_prompt("era", window, None) == plain and bench.format_a1_prompt("era", window, "") == plain
    assert bench.sha256_text(plain) != bench.sha256_text(with_ctx)


class ContextAwareA2(FakeA2):
    """A fake that accepts the fourth argument and records it."""
    def __init__(self):
        super().__init__()
        self.contexts = []

    def answer_window(self, image_paths, family, window, context=None):
        self.contexts.append(context)
        return super().answer_window(image_paths, family, window)


def run(tmp_path, entries, approach, **kw):
    return bench.run_corpus_a1(entries, tmp_path / "run", approach, 6, {"run_id": "t"}, ripper=fake_ripper,
                               duration_of=lambda p, d: d, log=lambda s: None, ocr_sampler=bench.OCR_SAMPLER_STILLS, **kw)


def test_loop_probes_once_per_clip_tells_the_model_and_records_it(tmp_path):
    probes = []
    def technical_of(path):
        probes.append(path)
        return bench.parse_technical(DV_PROBE)
    approach = ContextAwareA2()
    e = entry(digest_for(21))
    progress = run(tmp_path, [e], approach, prompt_context=bench.PROMPT_CONTEXT_TECHNICAL, technical_of=technical_of)
    assert progress["done"] == 1 and probes == [e["path"]], "one probe per clip"
    assert len(approach.contexts) == 6 and all(c and c.startswith("Technical facts") for c in approach.contexts)
    records = bench.read_clip_records(bench.clip_file(tmp_path / "run", e["digest"]))
    header = records["header"]
    assert header["prompt_context"] == "technical" and header["technical"]["codec"] == "dvvideo"
    assert header["context_line"] == bench.technical_context_line(bench.parse_technical(DV_PROBE))
    assert all(r["context_sha256"] == bench.sha256_text(header["context_line"]) for r in records["window_results"])
    assert all(r["prompt_sha256"] == bench.sha256_text(bench.A1_PROMPTS[r["family"]]) for r in records["window_results"]), "the template hash stays the template's"
    # The review page shows the line.
    state = bench.review_state(tmp_path / "run", {"clips": [e]})
    assert state["clips"][0]["context_line"] == header["context_line"] and state["clips"][0]["technical"]["fps"] == 29.97


def test_without_the_flag_nothing_changes_and_a_three_argument_fake_still_works(tmp_path):
    approach = FakeA2()                                            # answer_window(image_paths, family, window) only
    e = entry(digest_for(22))
    run(tmp_path, [e], approach, technical_of=lambda p: (_ for _ in ()).throw(AssertionError("must not probe")))
    header = bench.read_clip_records(bench.clip_file(tmp_path / "run", e["digest"]))["header"]
    assert "prompt_context" not in header and "technical" not in header
    assert len(approach.window_calls) == 6


def test_a_failed_probe_or_an_ocr_only_clip_gets_no_line_and_the_run_goes_on(tmp_path):
    approach = ContextAwareA2()
    e1 = entry(digest_for(23))
    e2 = entry(digest_for(24), corpus="ocr", stratum="ocr/dvvideo")
    def technical_of(path):
        raise RuntimeError("ffprobe exploded")
    progress = run(tmp_path, [e1, e2], approach, prompt_context=bench.PROMPT_CONTEXT_TECHNICAL, technical_of=technical_of)
    assert progress["done"] == 2 and progress["failed"] == 0
    h1 = bench.read_clip_records(bench.clip_file(tmp_path / "run", e1["digest"]))["header"]
    assert h1["prompt_context"] == "technical" and h1["technical"] == {} and h1["context_line"] is None
    assert approach.contexts == [None] * 6, "no facts → the plain prompt, said so in the record"


def test_cli_and_run_record_carry_the_context():
    args = bench.make_parser().parse_args(["run", "--manifest", "m", "--out", "o", "--approach", "a2-py", "--context", "technical"])
    assert args.context == "technical"
    assert bench.make_parser().parse_args(["run", "--manifest", "m", "--out", "o"]).context == "none"


def test_every_generate_call_uses_one_prefill_step_larger_than_any_prompt():
    """2026-10-31: mlx-vlm 0.5.0 chunks a prompt longer than 2048 tokens and the short tail
    chunk dies in Metal (ten worker crashes, all at "Prefill 2048/205x"). Sensor: both generate
    calls pass PREFILL_STEP_SIZE and it is above the 8-frame prompt (≈ 2,080 tokens) by a wide
    margin; the run record says which step was used."""
    import inspect
    assert bench.PREFILL_STEP_SIZE >= 4096
    source = inspect.getsource(bench)
    calls = re.findall(r"generate\(self\.model, self\.processor,.*?verbose=False(?:, [^)]*)?\)", source, re.S)
    assert len(calls) == 2, "the single-image and the multi-image generate calls"
    assert all("prefill_step_size=PREFILL_STEP_SIZE" in c for c in calls), calls


def test_picture_only_context_says_what_the_picture_is_and_never_names_the_codec():
    """After the first A/B (2026-10-31): a 1965 film transferred to DV moved from 1960–1975 to
    1975–1985 once the model was told 'DV camcorder tape (1995 onward)'. The picture variant
    keeps size / rate / scan / aspect and drops every codec word."""
    line = bench.technical_context_line(bench.parse_technical(DV_PROBE), picture_only=True)
    assert line.startswith("Picture facts about this file")
    assert "720×480 pixels; 29.97 fps; interlaced; aspect 4:3." in line
    for word in ("dvvideo", "DV camcorder", "codec", "1995"):
        assert word not in line
    assert "later transfer of older footage" in line
    assert bench.technical_context_line({"codec": "dvvideo"}, picture_only=True) == "", "codec alone leaves nothing to say"
    args = bench.make_parser().parse_args(["run", "--manifest", "m", "--out", "o", "--context", "picture"])
    assert args.context == "picture"
