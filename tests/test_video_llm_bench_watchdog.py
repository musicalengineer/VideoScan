"""tools/video-llm-bench/bench.py — the watchdog (#406).

No model, no media, no catalog: venv/bin/python3 -m pytest tests/test_video_llm_bench_watchdog.py.
On 2026-10-30 one mlx-vlm generation wedged and held the Ultra's GPU for twelve hours. These
tests pin the cure: the model runs in a worker PROCESS; a generation past the cap kills the
worker (the GPU goes with it), is recorded as a timeout, and the next call respawns; a run-level
deadline stops between clips, resume-safe.

RED 2026-10-31: set VIDEO_LLM_BENCH_SCRIPT to a bench.py without the watchdog (main at 78d9abdc)
and every test here fails (no SubprocessApproach, no `timeouts`, no `deadline`).
"""
from __future__ import annotations

import datetime as dt
import importlib.util
import json
import os
import sys
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = Path(os.environ.get("VIDEO_LLM_BENCH_SCRIPT") or ROOT / "tools" / "video-llm-bench" / "bench.py")
SPEC = importlib.util.spec_from_file_location("video_llm_bench_watchdog_under_test", SCRIPT)
assert SPEC and SPEC.loader
bench = importlib.util.module_from_spec(SPEC)
sys.modules["video_llm_bench_watchdog_under_test"] = bench
SPEC.loader.exec_module(bench)

THIS_DIR = str(Path(__file__).resolve().parent)
THIS_MODULE = Path(__file__).stem


# ---------------------------------------------------------------------------
# A fake approach the WORKER PROCESS builds by import (so the parent never sees it)
# ---------------------------------------------------------------------------
class SleepyApproach:
    """`hang` sleeps far past any test cap; `boom` raises; anything else answers at once
    and reports the worker's pid so a respawn is visible."""
    id = "sleepy"

    def load(self):
        return {"load_s": 0.0, "weights_sha256": "f" * 64, "weights_bytes": 1}

    def seed(self, value):
        return None

    def after_clip(self):
        return None

    def answer(self, image_path, prompt_kind):
        if prompt_kind == "hang":
            time.sleep(120)
        if prompt_kind == "boom":
            raise ValueError("deliberate")
        return "answer:" + prompt_kind, {"pid": os.getpid()}

    def answer_window(self, image_paths, family, window):
        if family == "hang":
            time.sleep(120)
        return json.dumps({"family": family, "n": len(image_paths)}), {"pid": os.getpid()}


def sleepy_ref() -> str:
    return "import:{}:{}:SleepyApproach".format(THIS_DIR, THIS_MODULE)


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def wait_dead(pid: int, timeout_s: float = 10.0) -> bool:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if not pid_alive(pid):
            return True
        time.sleep(0.05)
    return not pid_alive(pid)


@pytest.fixture
def worker():
    approach = bench.SubprocessApproach(sleepy_ref(), timeout_s=1.5, load_timeout_s=60, approach_id="sleepy",
                                        log=lambda s: None)
    try:
        yield approach
    finally:
        approach.close()
        if approach.worker_pid is not None:
            wait_dead(approach.worker_pid)


# ---------------------------------------------------------------------------
# The process boundary
# ---------------------------------------------------------------------------
def test_worker_answers_through_the_pipe_and_load_reports_the_watchdog(worker, tmp_path):
    info = worker.load()
    assert info["weights_sha256"] == "f" * 64
    assert info["watchdog"] == {"generation_timeout_s": 1.5, "load_timeout_s": 60.0, "worker_pid": worker.worker_pid}
    text, counters = worker.answer(tmp_path / "x.png", "date")
    assert text == "answer:date" and counters["pid"] == worker.worker_pid
    assert counters["pid"] != os.getpid(), "the model runs in another process"
    text, counters = worker.answer_window([tmp_path / "a.png", tmp_path / "b.png"], "era", {"index": 0})
    assert json.loads(text) == {"family": "era", "n": 2}
    worker.seed(7)
    worker.after_clip()
    assert worker.stats() == {"timeouts": 0, "respawns": 0, "worker_pid": worker.worker_pid}


def test_a_wedged_generation_is_killed_recorded_and_the_next_call_respawns(worker, tmp_path):
    worker.load()
    first_pid = worker.worker_pid
    started = time.monotonic()
    with pytest.raises(bench.GenerationTimeout) as caught:
        worker.answer(tmp_path / "x.png", "hang")
    assert time.monotonic() - started < 10, "the cap is 1.5 s; the parent must not wait for the sleep"
    assert "exceeded 2 s" in str(caught.value) or "exceeded 1 s" in str(caught.value)
    assert wait_dead(first_pid), "the wedged worker must be gone (that is what frees the GPU)"
    # The next call brings a fresh worker and reloads the model.
    text, counters = worker.answer(tmp_path / "x.png", "date")
    assert text == "answer:date"
    assert counters["pid"] == worker.worker_pid != first_pid
    assert worker.stats()["timeouts"] == 1 and worker.stats()["respawns"] == 1


def test_a_worker_exception_comes_back_as_an_error_not_a_hang(worker, tmp_path):
    worker.load()
    with pytest.raises(RuntimeError, match="ValueError: deliberate"):
        worker.answer(tmp_path / "x.png", "boom")
    # The worker is still the same process: an exception is not a kill.
    text, counters = worker.answer(tmp_path / "x.png", "date")
    assert counters["pid"] == worker.worker_pid and worker.stats()["respawns"] == 0


def test_close_ends_the_worker(tmp_path):
    approach = bench.SubprocessApproach(sleepy_ref(), timeout_s=5, load_timeout_s=60, log=lambda s: None)
    approach.load()
    pid = approach.worker_pid
    approach.close()
    assert wait_dead(pid)


def test_factory_ref_round_trip_for_registered_approaches():
    assert bench.factory_ref_for_approach("a2-py", None) == "approach:a2-py:"
    assert bench.factory_ref_for_approach("a1-py", "/m/dir") == "approach:a1-py:/m/dir"
    built = bench.build_from_factory_ref("approach:a2-py:/m/dir")
    assert isinstance(built, bench.A2Python) and built.model_dir_override == Path("/m/dir")
    with pytest.raises(ValueError):
        bench.build_from_factory_ref("telnet:host")


# ---------------------------------------------------------------------------
# The run loops record a timeout and carry on
# ---------------------------------------------------------------------------
class TimingOutApproach:
    """In-process stand-in for SubprocessApproach: raises GenerationTimeout where told."""
    id = "a2-py"

    def __init__(self, hang_families=(), hang_kinds=()):
        self.hang_families = set(hang_families)
        self.hang_kinds = set(hang_kinds)
        self.calls = 0

    def seed(self, value):
        return None

    def after_clip(self):
        return None

    def answer(self, image_path, prompt_kind):
        self.calls += 1
        if prompt_kind in self.hang_kinds:
            raise bench.GenerationTimeout("answer exceeded 120 s; worker killed, GPU freed")
        return "JUN 21 1991", {}

    def answer_window(self, image_paths, family, window):
        self.calls += 1
        if family in self.hang_families:
            raise bench.GenerationTimeout("answer_window exceeded 120 s; worker killed, GPU freed")
        return json.dumps({"family": "roomFeatures", "window": [0.0, 60.0], "setting": "indoor",
                           "locationType": "kitchen", "features": ["tile"], "selfConfidence": 0.5}), {}


def fake_ripper(path, at_s, dest, duration):
    Path(dest).write_bytes(b"\x89PNG fake")
    return True


def digest_for(n: int) -> str:
    return "{:064x}".format(n)


def entry(digest, corpus="era", stratum="rick-dated/1990s", duration=1000.0):
    return {"digest": digest, "path": "/Volumes/FamilyArchive/{}.mov".format(digest[:6]), "size_bytes": 1,
            "duration_s": duration, "corpus": corpus, "stratum": stratum,
            "truth": {"year": 1991} if corpus == "era" else {"date": "1991-06-21"},
            "codec": "dvvideo", "container": "DV"}


def test_a1_loop_records_each_timeout_and_the_run_goes_on(tmp_path):
    approach = TimingOutApproach(hang_families={"era"})
    progress = bench.run_corpus_a1([entry(digest_for(1)), entry(digest_for(2))], tmp_path / "run", approach, 6,
                                   {"run_id": "t"}, ripper=fake_ripper, duration_of=lambda p, d: d,
                                   log=lambda s: None, ocr_sampler=bench.OCR_SAMPLER_STILLS)
    assert progress["done"] == 2 and progress["state"] == "finished"
    assert progress["timeouts"] == 6, "3 windows × era family × 2 clips"
    records = bench.read_clip_records(bench.clip_file(tmp_path / "run", digest_for(1)))
    era = [r for r in records["window_results"] if r["family"] == "era"]
    room = [r for r in records["window_results"] if r["family"] == "roomFeatures"]
    assert len(era) == 3 and all(r["error"].startswith("GenerationTimeout") for r in era)
    assert all(r["schema_valid"] is False and r["schema_invalid_reason"] == "timeout" for r in era)
    assert len(room) == 3 and all(r["schema_valid"] for r in room), "the other family still ran"


def test_a0_loop_records_a_timeout_on_one_prompt_and_keeps_the_others(tmp_path):
    approach = TimingOutApproach(hang_kinds={"date"})
    progress = bench.run_corpus([entry(digest_for(3), corpus="ocr", stratum="ocr/dvvideo")], tmp_path / "run",
                                approach, 2, {"run_id": "t"}, ripper=fake_ripper, duration_of=lambda p, d: d,
                                log=lambda s: None)
    assert progress["done"] == 1 and progress["timeouts"] == 2 and progress["state"] == "finished"
    header, results, footer = bench.read_clip_results(bench.clip_file(tmp_path / "run", digest_for(3)))
    dates = [r for r in results if r["prompt_kind"] == "date"]
    others = [r for r in results if r["prompt_kind"] != "date"]
    assert len(dates) == 2 and all(r["error"].startswith("GenerationTimeout") and r["raw_text"] == "" for r in dates)
    assert others and all(r["error"] is None for r in others)


# ---------------------------------------------------------------------------
# The run-level deadline
# ---------------------------------------------------------------------------
def test_deadline_stops_between_clips_and_a_resume_finishes_the_rest(tmp_path):
    ticks = iter([0.0, 100.0, 100.0, 100.0])               # one clock read per clip: clip 1 before the deadline, clip 2 after
    approach = TimingOutApproach()
    entries = [entry(digest_for(4)), entry(digest_for(5)), entry(digest_for(6))]
    progress = bench.run_corpus_a1(entries, tmp_path / "run", approach, 6, {"run_id": "t"}, ripper=fake_ripper,
                                   duration_of=lambda p, d: d, log=lambda s: None,
                                   ocr_sampler=bench.OCR_SAMPLER_STILLS, deadline=50.0, clock=lambda: next(ticks))
    assert progress["state"] == "deadline" and progress["done"] == 1
    saved = json.loads((tmp_path / "run" / "progress.json").read_text())
    assert saved["state"] == "deadline"
    assert bench.clip_is_done(bench.clip_file(tmp_path / "run", digest_for(4)))
    assert not bench.clip_file(tmp_path / "run", digest_for(5)).exists(), "the deadline stops BEFORE a clip, never inside one"
    # Resume without a deadline: the finished clip is skipped, the rest run.
    again = bench.run_corpus_a1(entries, tmp_path / "run", approach, 6, {"run_id": "t"}, ripper=fake_ripper,
                                duration_of=lambda p, d: d, log=lambda s: None, ocr_sampler=bench.OCR_SAMPLER_STILLS)
    assert again["state"] == "finished" and again["skipped_resume"] == 1 and again["done"] == 2


def test_a0_loop_honours_the_deadline_too(tmp_path):
    progress = bench.run_corpus([entry(digest_for(7), corpus="ocr", stratum="ocr/dvvideo")], tmp_path / "run",
                                TimingOutApproach(), 2, {"run_id": "t"}, ripper=fake_ripper,
                                duration_of=lambda p, d: d, log=lambda s: None, deadline=1.0, clock=lambda: 2.0)
    assert progress["state"] == "deadline" and progress["done"] == 0


def test_parse_deadline_is_the_next_such_wall_clock_time():
    now = dt.datetime(2026, 10, 31, 11, 30)
    assert dt.datetime.fromtimestamp(bench.parse_deadline("13:45", now)) == dt.datetime(2026, 10, 31, 13, 45)
    assert dt.datetime.fromtimestamp(bench.parse_deadline("01:30", now)) == dt.datetime(2026, 11, 1, 1, 30)
    assert dt.datetime.fromtimestamp(bench.parse_deadline("11:30", now)) == dt.datetime(2026, 11, 1, 11, 30)
    for bad in ("25:00", "12:60", "noon", "12"):
        with pytest.raises(SystemExit):
            bench.parse_deadline(bad, now)


# ---------------------------------------------------------------------------
# CLI wiring
# ---------------------------------------------------------------------------
def test_run_defaults_to_a_120_s_cap_and_accepts_a_deadline():
    parser = bench.make_parser()
    args = parser.parse_args(["run", "--manifest", "m.json", "--approach", "a2-py", "--out", "o"])
    assert args.generation_timeout == 120.0 and args.load_timeout == 900.0 and args.deadline is None
    args = parser.parse_args(["run", "--manifest", "m.json", "--out", "o", "--generation-timeout", "45",
                              "--deadline", "01:30"])
    assert args.generation_timeout == 45.0 and args.deadline == "01:30"
    worker = parser.parse_args(["worker", "--factory", "approach:a2-py:"])
    assert worker.func is bench.worker_command and worker.factory == "approach:a2-py:"


def test_run_record_from_a_worker_carries_the_watchdog_block(tmp_path):
    approach = bench.SubprocessApproach(sleepy_ref(), timeout_s=5, load_timeout_s=60, approach_id="a2-py",
                                        log=lambda s: None)
    try:
        info = approach.load()
        manifest = {"corpus_hash": "c" * 64, "seed": 1, "clips": [], "catalog_copy": "x",
                    "generated_at": "2026-10-31T00:00:00+00:00", "counts": {}}
        record = bench.build_run_record(manifest, tmp_path / "m.json", approach, info, 8, None, None, "run-1", None)
        assert record["watchdog"]["generation_timeout_s"] == 5.0 and record["weights_sha256"] == "f" * 64
        assert record["approach_id"] == "a2-py"
    finally:
        approach.close()
