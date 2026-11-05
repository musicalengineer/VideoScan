"""tools/video-llm-bench/bench.py — ClipService, the background helper's clip worker.

No model, no media, no catalog: venv/bin/python3 -m pytest tests/test_video_llm_bench_service.py.
Background service step 1, item 4: VideoScan Background's EraJob spawns
`bench.py worker --factory clip-service:a2-py:<model dir>` and sends one
`analyze_clip(path, duration_s, context)` per file.  These tests pin:
  * the reply is ONE bench clip record (header, era window_results, the 5 OCR
    stills' `date` results, footer) plus the clip-level summary;
  * it is the benchmark's code path: the same fake approach through
    `run_corpus_a1` (A2 settings) writes the same records, field for field
    (timings and the run's own digest / run id aside);
  * frames are ripped into a temp dir that is gone after the reply;
  * fusion: a stamp cited in two windows collapses the median range; an x.5
    median is widened to whole years, never narrowed;
  * the worker protocol end to end: one JSON reply per request line, model
    chatter on stderr never on the protocol stdout, `__peak_rss__`, `__exit__`;
  * the factory ref builds a ClipService on the seated A2 (no load).
"""
from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "tools" / "video-llm-bench" / "bench.py"
SPEC = importlib.util.spec_from_file_location("video_llm_bench_service_under_test", SCRIPT)
assert SPEC and SPEC.loader
bench = importlib.util.module_from_spec(SPEC)
sys.modules["video_llm_bench_service_under_test"] = bench
SPEC.loader.exec_module(bench)

THIS_DIR = str(Path(__file__).resolve().parent)
THIS_MODULE = Path(__file__).stem


def era_json(window, year_range=(1991, 1995), cues=None, confidence=0.7):
    return json.dumps({"family": "era", "window": [window["start_s"], window["end_s"]], "yearRange": list(year_range),
                       "rationale": "4:3, camcorder OSD", "selfConfidence": confidence,
                       "cues": cues if cues is not None else [{"kind": "technical", "text": "tracking lines",
                                                               "atS": window["frame_times_s"][0]}]})


class FakeA2:
    """A2's surface without a model: era answers from `ranges` (per window index),
    `date` answers from `date_text`.  Prints to stdout on load, as mlx does."""
    id = "a2-py"
    model_id = "mlx-community/Qwen3-VL-8B-Instruct-4bit"

    def __init__(self, ranges=None, date_text="JUN 21 1991", stamp_in_windows=()):
        self.ranges = ranges or {}
        self.date_text = date_text
        self.stamp_in_windows = set(stamp_in_windows)
        self.seeds = []
        self.after = 0

    def load(self):
        print("loading weights... (model chatter on stdout)")
        return {"model": self.model_id, "weights_sha256": "ab" * 32, "load_s": 0.1}

    def seed(self, value):
        self.seeds.append(value)

    def after_clip(self):
        self.after += 1

    def answer(self, image_path, prompt_kind):
        assert Path(image_path).is_file(), "the still exists while it is asked about"
        return self.date_text, {"prompt_tokens": 300}

    def answer_window(self, image_paths, family, window, context=None):
        assert family == "era" and all(Path(p).is_file() for p in image_paths)
        cues = None
        if window["index"] in self.stamp_in_windows:
            cues = [{"kind": "onScreenText", "text": "JUN 21 1991", "atS": window["frame_times_s"][0]}]
        return era_json(window, self.ranges.get(window["index"], (1991, 1995)), cues), {"prompt_tokens": 2100}


class RipRecorder:
    def __init__(self):
        self.dests = []

    def __call__(self, path, at_s, dest, duration):
        Path(dest).write_bytes(b"\x89PNG fake")
        self.dests.append(Path(dest))
        return True


def make_fake_service():
    """Built by the WORKER process through `import:` (the factory-ref test seam)."""
    return bench.ClipService(FakeA2(stamp_in_windows=(0, 1)), ripper=RipRecorder(), duration_of=lambda p, d: d)


def test_analyze_clip_is_one_bench_record_and_its_frames_are_gone():
    rip = RipRecorder()
    fake = FakeA2()
    service = bench.ClipService(fake, ripper=rip, duration_of=lambda p, d: d)
    record = service.analyze_clip("/synthetic/clip.mov", 600.0)
    assert set(record) == {"header", "window_results", "results", "frames_failed", "footer", "summary"}
    header = record["header"]
    assert header["record_type"] == "clip" and header["ocr_sampler"] == "stills" and header["duration_s"] == 600.0
    assert len(header["windows"]) == 3
    assert all(len(w["frame_times_s"]) == 8 for w in header["windows"]), "N = 8 frames per window"
    assert [w["family"] for w in record["window_results"]] == ["era"] * 3, "the era family only"
    assert all(w["schema_valid"] for w in record["window_results"])
    assert len(record["results"]) == 5 and all(r["prompt_kind"] == "date" for r in record["results"])
    assert record["results"][0]["parsed"]["dates"] == ["1991-06-21"]
    assert record["footer"]["record_type"] == "clip_done" and record["footer"]["frames_ok"] == 29
    assert fake.seeds == [bench.MLX_SEED] and fake.after == 1
    assert rip.dests and not any(d.exists() for d in rip.dests), "every frame removed"
    assert not rip.dests[0].parent.exists(), "the temp dir removed"


def test_it_is_the_benchmarks_code_path(tmp_path):
    entry = {"digest": "c" * 64, "path": "/synthetic/clip.mov", "duration_s": 600.0, "corpus": "era",
             "stratum": "rick-dated/1990s", "truth": None}
    entries = [entry, dict(entry, corpus="ocr")]
    bench.run_corpus_a1(entries, tmp_path, FakeA2(stamp_in_windows=(0,)), 8, {"run_id": "r"}, ripper=RipRecorder(),
                        duration_of=lambda p, d: d, log=lambda s: None, families=("era",),
                        ocr_sampler=bench.OCR_SAMPLER_STILLS)
    bench_records = bench.read_clip_records(bench.clip_file(tmp_path, entry["digest"]))
    service = bench.ClipService(FakeA2(stamp_in_windows=(0,)), ripper=RipRecorder(), duration_of=lambda p, d: d)
    record = service.analyze_clip(entry["path"], 600.0)
    volatile = {"elapsed_s", "rip_s", "digest", "clip_s", "finished_at", "peak_rss_bytes", "run_id", "corpus", "stratum"}

    def strip(r):
        return {k: v for k, v in r.items() if k not in volatile}

    assert [strip(r) for r in record["window_results"]] == [strip(r) for r in bench_records["window_results"]]
    assert [strip(r) for r in record["results"]] == [strip(r) for r in bench_records["results"]]
    assert strip(record["header"]) == strip(bench_records["header"])


def test_a_stamp_cited_in_two_windows_collapses_the_range():
    service = bench.ClipService(FakeA2(stamp_in_windows=(0, 2)), ripper=RipRecorder(), duration_of=lambda p, d: d)
    summary = service.analyze_clip("/synthetic/clip.mov", 600.0)["summary"]
    assert summary["year_range"] == [1991.0, 1995.0]
    assert summary["burned_in_years"] == [1991, 1991]
    assert summary["fused"] == [1991.0, 1991.0] and summary["fused_years"] == [1991, 1991]
    assert summary["valid_era_windows"] == 3


def test_a_half_year_median_is_widened_never_narrowed():
    ranges = {0: (1990, 1994), 1: (1991, 1995)}
    service = bench.ClipService(FakeA2(ranges=ranges, date_text="NONE"), ripper=RipRecorder(), duration_of=lambda p, d: d)
    record = service.analyze_clip("/synthetic/clip.mov", 600.0)
    # Two windows (an even count) give a median of x.5 on both ends.
    two = bench.clip_service_record([record["header"]] + record["window_results"][:2] + [record["footer"]])
    assert two["summary"]["year_range"] == [1990.5, 1994.5]
    assert two["summary"]["fused_years"] == [1990, 1995]


def test_no_valid_window_means_no_fused_range():
    class Garbage(FakeA2):
        def answer_window(self, image_paths, family, window, context=None):
            return "I think the nineties", {}
    record = bench.ClipService(Garbage(date_text="NONE"), ripper=RipRecorder(), duration_of=lambda p, d: d).analyze_clip("/x.mov", 600.0)
    assert record["summary"]["fused_years"] is None and record["summary"]["valid_era_windows"] == 0
    assert all(not w["schema_valid"] for w in record["window_results"])


def test_an_unknown_context_is_refused():
    with pytest.raises(ValueError):
        bench.ClipService(FakeA2(), ripper=RipRecorder()).analyze_clip("/x.mov", 10.0, "everything")


def test_load_reply_names_the_approach_revision_and_model():
    info = bench.ClipService(FakeA2()).load()
    assert info["approach_id"] == "qwen3-vl-8b-4bit/era-v1/window-60s"
    assert info["revision"] == bench.A1_PROMPT_REVISION
    assert info["model"] == bench.A2_MODEL_ID
    assert info["frames_per_window"] == 8 and info["ocr_stills"] == 5 and info["families"] == ["era"]
    assert info["prompts_sha256"]["era"] == bench.sha256_text(bench.A1_ERA_PROMPT)
    assert info["prefill_step_size"] == bench.PREFILL_STEP_SIZE


def test_the_factory_ref_builds_a_clip_service_on_the_seated_a2():
    built = bench.build_from_factory_ref("clip-service:a2-py:/models/qwen3-vl-8b")
    assert isinstance(built, bench.ClipService)
    assert isinstance(built.approach, bench.A2Python)
    assert str(built.approach.model_dir_override) == "/models/qwen3-vl-8b"


def test_the_worker_protocol_end_to_end():
    ref = "import:{}:{}:make_fake_service".format(THIS_DIR, THIS_MODULE)
    requests = [{"method": "load"}, {"method": "analyze_clip", "args": ["/synthetic/a.mov", 300.0, None]},
                {"method": "analyze_clip", "args": ["/synthetic/b.mov", 300.0, "nonsense"]},
                {"method": "__peak_rss__"}, {"method": "__exit__"}]
    proc = subprocess.run([sys.executable, "-I", str(SCRIPT), "worker", "--factory", ref],
                          input="".join(json.dumps(r) + "\n" for r in requests), capture_output=True, text=True,
                          timeout=120, env=dict(os.environ))
    assert proc.returncode == 0, proc.stderr
    lines = proc.stdout.splitlines()
    assert len(lines) == 4, "one reply per request before __exit__: {}".format(proc.stdout[:400])
    replies = [json.loads(line) for line in lines]
    assert replies[0]["ok"]["approach_id"] == "qwen3-vl-8b-4bit/era-v1/window-60s"
    assert replies[1]["ok"]["summary"]["fused_years"] == [1991, 1991]
    assert replies[2]["type"] == "ValueError"
    assert isinstance(replies[3]["ok"], int) and replies[3]["ok"] > 0
    assert "model chatter on stdout" in proc.stderr, "the model's prints go to stderr"


# ---------------------------------------------------------------------------
# Media matrix (rule 8): the REAL ripper and duration probe on five synthetic
# clips — mp4/h264, mov/prores, mkv/ffv1+pcm, mxf/mpeg2, avi/dv — generated by
# ffmpeg's lavfi test source (no family media).  Skipped without ffmpeg.
# ---------------------------------------------------------------------------
import shutil as _shutil

MEDIA_MATRIX = [
    ("mp4", ["-c:v", "libx264", "-pix_fmt", "yuv420p"], "640x360"),
    ("mov", ["-c:v", "prores_ks", "-profile:v", "0"], "640x360"),
    ("mkv", ["-c:v", "ffv1", "-c:a", "pcm_s16le"], "640x360"),
    ("mxf", ["-c:v", "mpeg2video", "-b:v", "8M", "-c:a", "pcm_s16le", "-ar", "48000"], "720x576"),
    ("avi", ["-c:v", "dvvideo", "-pix_fmt", "yuv411p", "-r", "30000/1001", "-c:a", "pcm_s16le", "-ar", "48000"], "720x480"),
]


@pytest.mark.skipif(_shutil.which("ffmpeg") is None or _shutil.which("ffprobe") is None, reason="ffmpeg/ffprobe not installed")
@pytest.mark.parametrize("ext,codec,size", MEDIA_MATRIX, ids=[m[0] for m in MEDIA_MATRIX])
def test_media_matrix_every_container_yields_frames_through_the_service(tmp_path, ext, codec, size):
    clip = tmp_path / "synthetic.{}".format(ext)
    made = subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=duration=12:size={}:rate=25".format(size),
                           "-f", "lavfi", "-i", "sine=frequency=440:duration=12", "-shortest"] + codec + [str(clip)],
                          capture_output=True, text=True, timeout=120)
    assert made.returncode == 0 and clip.is_file(), made.stderr
    seen = []

    class Recording(FakeA2):
        def answer_window(self, image_paths, family, window, context=None):
            seen.extend(Path(p).stat().st_size for p in image_paths)
            return super().answer_window(image_paths, family, window, context)

    service = bench.ClipService(Recording())          # the real ripper and the real duration probe
    record = service.analyze_clip(str(clip), 0.0)
    assert 11.0 < record["header"]["duration_s"] < 13.0, "ffprobe read the duration"
    assert record["frames_failed"] == [], "every frame ripped"
    assert record["footer"]["frames_ok"] == sum(len(w["frame_times_s"]) for w in record["header"]["windows"]) + 5
    assert seen and all(n > 1000 for n in seen), "real PNGs went to the model"


# --- 2026-11-04: frames that will not decode say why ---------------------------
# 402 files (Avid MXF essences, reference movies) never ripped a frame and the
# helper re-ran them forever with no reason anywhere.  The service's ripper now
# keeps ffmpeg's own last stderr line on every `frame_failed` record; EraJob puts
# it on the give-up line ("gave up after 3 tries: … (ffmpeg: …)").

@pytest.mark.skipif(_shutil.which("ffmpeg") is None, reason="ffmpeg not installed")
def test_an_undecodable_file_fails_every_frame_with_ffmpegs_words(tmp_path):
    garbage = tmp_path / "garbage.mov"
    garbage.write_bytes(bytes((i * 2654435761 >> 13) & 0xFF for i in range(200_000)))
    service = bench.ClipService(FakeA2())             # the real ReasonedRipper
    record = service.analyze_clip(str(garbage), 30.0)  # the catalog once said 30 s
    assert record["footer"]["frames_ok"] == 0
    assert record["frames_failed"], "every planned frame failed"
    assert all(f.get("reason") for f in record["frames_failed"]), record["frames_failed"][:2]
    assert record["window_results"] == [], "no frame, no model call"
    assert record["summary"]["fused_years"] is None


@pytest.mark.skipif(_shutil.which("ffmpeg") is None, reason="ffmpeg not installed")
def test_the_reasoned_ripper_says_none_on_success_and_words_on_failure(tmp_path):
    good = tmp_path / "good.mp4"
    made = subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=duration=2:size=160x120:rate=25",
                           "-c:v", "libx264", "-pix_fmt", "yuv420p", str(good)], capture_output=True, text=True, timeout=60)
    assert made.returncode == 0, made.stderr
    ripper = bench.ReasonedRipper()
    assert ripper(str(good), 1.0, tmp_path / "ok.png", 2.0) is True and ripper.last_error is None
    assert ripper(str(tmp_path / "missing.mov"), 1.0, tmp_path / "no.png", 2.0) is False
    assert ripper.last_error and len(ripper.last_error) <= 300


def test_an_injected_bool_ripper_adds_no_reason():
    """COMPAT: a test or benchmark ripper that returns a bool only leaves the record as it was."""
    service = bench.ClipService(FakeA2(), ripper=lambda p, a, d, du: False, duration_of=lambda p, d: d)
    record = service.analyze_clip("/synthetic/x.mov", 120.0)
    assert record["frames_failed"] and all("reason" not in f for f in record["frames_failed"])
