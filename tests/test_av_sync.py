"""A/V sync check prototype (brief C08, GH #309): accuracy over a synthetic
fixture matrix. Every fixture is generated with ffmpeg into a temp dir at
test time (testsrc2 / aevalsrc / anoisesrc); no real media is read or kept.

Needs numpy, scipy and ffmpeg/ffprobe; skips cleanly without them (the Linux
CI job installs numpy but not scipy or ffmpeg). The 10-minute runtime check
runs only with AV_SYNC_LONG=1 (it spends ~2 min generating its fixture).
"""
import importlib.util
import os
import shutil
import sys
import time
from pathlib import Path

import pytest

pytest.importorskip("numpy")
pytest.importorskip("scipy")
if shutil.which("ffmpeg") is None or shutil.which("ffprobe") is None:
    pytest.skip("ffmpeg/ffprobe not on PATH", allow_module_level=True)

ROOT = Path(__file__).resolve().parents[1] / "scripts" / "av_sync"


def _load(name):
    spec = importlib.util.spec_from_file_location(f"av_sync_{name}", ROOT / f"{name}.py")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    return mod


measure = _load("measure")
fixtures = _load("fixtures")

OFFSET_TOL = 10.0
DRIFT_TOL = 15.0
DURATION = 60.0


@pytest.fixture(scope="module")
def fx(tmp_path_factory):
    d = tmp_path_factory.mktemp("av_sync_fx")
    return fixtures.build_all(str(d), DURATION)


@pytest.fixture(scope="module")
def results(fx):
    out, times = {}, {}
    for name in fixtures.VARIANTS:
        t = time.perf_counter()
        out[name] = measure.measure(fx["original"], fx[name])
        times[name] = time.perf_counter() - t
    out["_times"] = times
    return out


STRICT = [n for n in fixtures.VARIANTS if n != "drift200"]


@pytest.mark.parametrize("name", STRICT)
def test_fixture_verdict_offset_and_drift(results, name):
    verdict, offset, drift = fixtures.VARIANTS[name][3]
    r = results[name]
    assert r["verdict"] == verdict, r
    assert abs(r["offset_ms"] - offset) <= OFFSET_TOL, r
    assert abs(r["drift_ms"] - drift) <= DRIFT_TOL, r
    assert r["confidence"] >= 0.5, r


def test_atempo_drift_is_measured_but_atempo_itself_shifts_the_start(results):
    # atempo (WSOLA time-stretch) moves the whole track ~10-20 ms EARLY by
    # itself (measured with clicks: -21 ms; see the C08 report), so this
    # fixture's true start offset is not 0. The drift is exact; the start
    # offset gets atempo's own shift as extra tolerance.
    r = results["drift200"]
    assert r["verdict"] == "drifting", r
    assert abs(r["drift_ms"] - 200) <= DRIFT_TOL, r
    assert -25.0 <= r["offset_ms"] <= OFFSET_TOL, r


def test_trim_is_told_apart_from_a_sync_error(results):
    r = results["trim2s"]
    assert abs(r["offset_ms"] + 2000) <= OFFSET_TOL          # the sound moved 2 s...
    assert abs(r["video_offset_ms"] + 2000) <= 40            # ...and so did the picture
    assert abs(r["av_offset_ms"]) <= OFFSET_TOL               # so the copy is in sync with itself
    assert r["trim_ms"] is not None
    assert abs(r["duration_delta_ms"] + 2000) <= 50           # and it is 2 s shorter
    assert r["verdict"] == "in_sync"


def test_a_sound_shift_is_not_mistaken_for_a_trim(results):
    r = results["plus500"]
    assert abs(r["video_offset_ms"]) <= 20                    # picture did not move
    assert r["trim_ms"] is None
    assert abs(r["av_offset_ms"] - 500) <= OFFSET_TOL


def test_a_picture_shift_is_caught_only_by_the_picture_check(results, fx):
    r = results["video_late200"]
    assert abs(r["offset_ms"]) <= OFFSET_TOL                  # the sound did not move
    assert abs(r["video_offset_ms"] - 200) <= 20              # the picture did
    assert abs(r["av_offset_ms"] + 200) <= 20                 # so the sound now leads the picture
    assert r["verdict"] == "offset" and r["trim_ms"] is None
    audio_only = measure.measure(fx["original"], fx["video_late200"], use_video=False)
    assert audio_only["verdict"] == "in_sync"                 # blind without the picture


def test_audio_only_check_still_reports_the_raw_lag(fx):
    r = measure.measure(fx["original"], fx["trim2s"], use_video=False)
    assert r["video_offset_ms"] is None
    assert r["verdict"] == "offset"                           # without the picture, a cut looks like a lag
    assert abs(r["offset_ms"] + 2000) <= OFFSET_TOL


def test_near_silent_original_is_unsure(fx):
    r = measure.measure(fx["quiet_original"], fx["quiet_improved"])
    assert r["verdict"] == "unsure", r
    assert r["offset_ms"] is None
    assert any("quiet" in n for n in r["notes"])


def test_no_audio_track_is_unsure(fx, tmp_path):
    silent_video = str(tmp_path / "noaudio.mov")
    fixtures.ff(["-i", fx["original"], "-an", "-c:v", "copy", silent_video])
    r = measure.measure(fx["original"], silent_video)
    assert r["verdict"] == "unsure"
    assert any("no audio" in n for n in r["notes"])


def test_unrelated_sound_is_unsure_not_a_confident_lag(tmp_path):
    # Two different recordings (different gate) must not "match" at some lag.
    a = fixtures.make_original(str(tmp_path / "a.mov"), 30.0)
    other = str(tmp_path / "b.mov")
    fixtures.ff(["-f", "lavfi", "-i", "testsrc2=s=320x180:r=25:d=30",
                 "-f", "lavfi", "-i", "aevalsrc='0.4*gt(sin(2*PI*0.71*t)+sin(2*PI*1.9*t+2)"
                 "+sin(2*PI*2.9*t+1),1.2)*sin(2*PI*330*t)':s=48000:d=30",
                 "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "pcm_s16le", "-shortest", other])
    r = measure.measure(a, other, use_video=False)
    assert r["verdict"] == "unsure", r


def test_cli_prints_json(fx, capsys):
    rc = measure.main([fx["original"], fx["plus40"], "--no-video"])
    assert rc == 0
    import json
    out = json.loads(capsys.readouterr().out)
    assert out["verdict"] == "offset" and abs(out["offset_ms"] - 40) <= OFFSET_TOL


def test_runtime_60s(results):
    t = results["_times"]
    print("\nC08 runtime, 60 s fixtures (s):", {k: round(v, 2) for k, v in t.items()})
    assert max(t.values()) < 30.0


@pytest.mark.skipif(os.environ.get("AV_SYNC_LONG") != "1", reason="set AV_SYNC_LONG=1 for the 10-minute run")
def test_runtime_10min(tmp_path):
    orig = fixtures.make_original(str(tmp_path / "original.mov"), 600.0)
    imp = fixtures.make_improved(orig, str(tmp_path), "plus40", 600.0)
    t = time.perf_counter()
    r = measure.measure(orig, imp)
    took = time.perf_counter() - t
    print(f"\nC08 runtime, 10 min fixture: {took:.1f} s; {r['verdict']} {r['offset_ms']} ms")
    assert r["verdict"] == "offset" and abs(r["offset_ms"] - 40) <= OFFSET_TOL
    assert took < 120.0
