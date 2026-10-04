"""Tests for scripts/footage_spectrum.py (the helper behind "Compare Footage…").

Pure parts (alignment, ribbon words, coverage, formatting, the PROGRESS line) run
everywhere numpy is installed. The media matrix generates tiny synthetic fixtures
with ffmpeg lavfi (test_* names, never real media) and skips cleanly when ffmpeg
is not on PATH.
"""
import importlib.util
import json
import os
import shutil
import subprocess
import sys

import pytest

np = pytest.importorskip("numpy")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "scripts", "footage_spectrum.py")

spec = importlib.util.spec_from_file_location("footage_spectrum", SCRIPT)
fs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fs)

FFMPEG = shutil.which("ffmpeg")
FFPROBE = shutil.which("ffprobe")
needs_ffmpeg = pytest.mark.skipif(not (FFMPEG and FFPROBE), reason="ffmpeg/ffprobe not on PATH")


def strip(n, seed):
    rng = np.random.default_rng(seed)
    # smooth-ish random colour columns: n seconds x 48 rows x RGB
    base = rng.integers(0, 256, size=(n, 1, 3)).astype(np.float32)
    rows = rng.integers(-30, 30, size=(n, fs.ROWS, 3)).astype(np.float32)
    return np.clip(base + rows, 0, 255).astype(np.uint8)


# ------------------------------------------------------------------ alignment

def test_identical_strips_align_at_zero():
    a = fs.unit_rows(fs.band_feature(strip(120, 1)))
    r = fs.slide(a, a)
    assert r["offset"] == 0
    assert r["score"] > 0.95
    assert r["overlap"] == 120


def test_excerpt_aligns_at_its_offset():
    full = strip(200, 2)
    part = full[50:110]
    a, b = fs.unit_rows(fs.band_feature(full)), fs.unit_rows(fs.band_feature(part))
    r = fs.slide(a, b)
    assert r["offset"] == 50
    assert r["score"] > 0.9
    assert r["next"] is None or r["next"] < r["score"] - 0.3


def test_different_strips_score_low():
    a = fs.unit_rows(fs.band_feature(strip(150, 3)))
    b = fs.unit_rows(fs.band_feature(strip(150, 4)))
    assert fs.slide(a, b)["score"] < 0.5


def test_ribbon_of_identical_is_all_same_and_excerpt_maps_to_reference():
    full = fs.band_feature(strip(100, 5))
    rib, whole = fs.ribbon(full, full, 0)
    assert np.nanmin(rib) >= fs.GREEN and whole > 0.99
    part = full[30:60]
    rib, _ = fs.ribbon(full, part, 30)
    assert len(rib) == 30 and np.nanmin(rib) >= fs.GREEN


def test_ribbon_marks_seconds_without_reference_as_none():
    ref = fs.band_feature(strip(40, 6))
    cand = fs.band_feature(strip(60, 6))      # 20 s longer than the reference
    rib, _ = fs.ribbon(ref, cand, 0)
    q = fs.quantize_ribbon(rib)
    assert (q[40:] == fs.RIBBON_NONE).all()


# ---------------------------------------------------------- ribbon -> words

@pytest.mark.parametrize("v,expected", [
    (fs.RIBBON_NONE, "none"), (250, "same"), (213, "same"), (212, "close"),
    (150, "close"), (149, "diff"), (0, "diff"),
])
def test_ribbon_classification_thresholds(v, expected):
    assert fs.classify_second(v) == expected


def test_verdict_classes():
    same = np.full(100, 240, np.uint8)
    assert fs.verdict(same, 100)["cls"] == "same"
    close = np.full(100, 180, np.uint8)
    assert fs.verdict(close, 100)["cls"] == "close"
    part = np.concatenate([np.full(30, 240), np.full(70, 10)]).astype(np.uint8)
    assert fs.verdict(part, 1000)["cls"] == "part"
    diff = np.full(100, 10, np.uint8)
    assert fs.verdict(diff, 100)["cls"] == "diff"
    # a short candidate that covers the whole reference is "same"
    contains = np.concatenate([np.full(50, 240), np.full(50, 10)]).astype(np.uint8)
    assert fs.verdict(contains, 50)["cls"] == "same"


def test_coverage_ranges_merge_close_runs_and_drop_short_ones():
    q = np.full(200, 10, np.uint8)
    q[0:40] = 240
    q[55:100] = 200       # 15 s gap -> merged with the first run
    q[150:160] = 240      # 10 s run -> dropped
    assert fs.coverage_ranges([(q, 0)], 200) == [(0, 100)]
    # offsets place the candidate on the reference's time line; outside is ignored
    assert fs.coverage_ranges([(np.full(50, 240, np.uint8), 180)], 200) == []
    assert fs.coverage_ranges([(np.full(50, 240, np.uint8), 100)], 200) == [(100, 150)]


# ----------------------------------------------------------------- formatting

@pytest.mark.parametrize("nbytes,text", [
    (412_000_000, "412 MB"), (999_000_000, "999 MB"), (1_250_000_000, "1.25 GB"), (12_340_000_000, "12.3 GB"),
])
def test_size_formatting(nbytes, text):
    assert fs.fmt_size(nbytes) == text


def test_progress_line_format_and_clamping():
    line = fs.progress_line(2, 5, "B · clip.mov", "reading", 1.7)
    kind, _, body = line.partition(" ")
    assert kind == "PROGRESS"
    assert json.loads(body) == {"file": 2, "of": 5, "label": "B · clip.mov", "phase": "reading", "fraction": 1.0}
    assert json.loads(fs.progress_line(1, 1, "", "aligning", float("nan")).partition(" ")[2])["fraction"] == 0.0
    assert "\n" not in line


def test_progress_seconds_reads_the_last_out_time():
    text = "frame=10\nout_time_us=1500000\nprogress=continue\nout_time_us=2500000\nprogress=continue\n"
    assert fs.progress_seconds(text) == 2.5
    assert fs.progress_seconds("progress=continue\n") is None


def test_estimate_and_reference_order():
    assert fs.estimate_seconds(100, "h264") == round(fs.STARTUP_S + 100 * fs.CODEC_FACTOR["h264"], 1)
    assert fs.estimate_seconds(100, "weird") == round(fs.STARTUP_S + 100 * fs.DEFAULT_FACTOR, 1)
    assert fs.estimate_seconds(100, "h264", cached=True) == fs.CACHED_S
    s = {"files": [{"label": "a"}, {"label": "b"}, {"label": "c"}], "reference": 2}
    assert [f["label"] for f in fs.ordered_files(s)] == ["c", "a", "b"]
    assert [f["label"] for f in fs.ordered_files({"files": s["files"]})] == ["a", "b", "c"]


def test_missing_files_are_skipped_and_too_few_is_an_error(tmp_path):
    sets = tmp_path / "sets.json"
    sets.write_text(json.dumps([{"title": "t", "files": [{"label": "A", "path": str(tmp_path / "test_gone1.mp4")},
                                                          {"label": "B", "path": str(tmp_path / "test_gone2.mp4")}]}]))
    out = subprocess.run([sys.executable, SCRIPT, "--sets", str(sets), "--out", str(tmp_path / "page.html"),
                          "--cache-dir", str(tmp_path / "cache"), "--progress",
                          "--ffmpeg", FFMPEG or sys.executable, "--ffprobe", FFPROBE or sys.executable],
                         capture_output=True, text=True, timeout=60)
    assert out.returncode != 0
    err = [line for line in out.stdout.splitlines() if line.startswith("ERROR ")]
    assert len(err) == 1
    body = json.loads(err[0][6:])
    assert "fewer than two" in body["message"]
    assert [s["label"] for s in body["skipped"]] == ["A", "B"]
    assert not (tmp_path / "page.html").exists()


def test_missing_ffmpeg_is_named(tmp_path):
    sets = tmp_path / "sets.json"
    sets.write_text("[]")
    out = subprocess.run([sys.executable, SCRIPT, "--sets", str(sets), "--out", str(tmp_path / "p.html"),
                          "--progress", "--ffmpeg", str(tmp_path / "no-ffmpeg"), "--ffprobe", str(tmp_path / "no")],
                         capture_output=True, text=True, timeout=60)
    assert out.returncode == 3
    assert json.loads(out.stdout.strip().splitlines()[-1][6:])["missing"] == "ffmpeg"


# --------------------------------------------------------------- media matrix

MATRIX = {
    "test_h264.mp4": ["-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "aac"],
    "test_prores.mov": ["-c:v", "prores_ks", "-profile:v", "0", "-c:a", "pcm_s16le"],
    "test_ffv1.mkv": ["-c:v", "ffv1", "-c:a", "pcm_s16le"],
    "test_mpeg2.mxf": ["-c:v", "mpeg2video", "-b:v", "4M", "-c:a", "pcm_s16le", "-ar", "48000", "-f", "mxf"],
    "test_dv.avi": ["-s", "720x576", "-pix_fmt", "yuv420p", "-c:v", "dvvideo", "-c:a", "pcm_s16le", "-ar", "48000"],
}


def make_clip(path, seconds, extra, size="320x240"):
    src = (f"testsrc2=s={size}:r=25:d={seconds},"
           f"hue=h=47*t+90*sin(t/2):s=1+0.5*sin(t/5)")
    cmd = [FFMPEG, "-v", "error", "-y", "-f", "lavfi", "-i", src,
           "-f", "lavfi", "-i", f"sine=frequency=440:beep_factor=4:duration={seconds}",
           "-shortest"] + extra + [str(path)]
    subprocess.run(cmd, check=True, timeout=120)


@needs_ffmpeg
@pytest.mark.parametrize("name", sorted(MATRIX))
def test_media_matrix_columns(tmp_path, name):
    clip = tmp_path / name
    make_clip(clip, 4, MATRIX[name])
    fs.FFMPEG, fs.FFPROBE = FFMPEG, FFPROBE
    d = fs.extract(str(clip), str(tmp_path / "cache"), False, 160)
    assert 4 <= d["meta"]["T"] <= 5, d["meta"]
    assert d["cols"].shape[1:] == (fs.ROWS, 3)
    assert d["meta"]["has_audio"]
    # the cache answers the second time
    assert fs.extract(str(clip), str(tmp_path / "cache"), False, 160)["cached"]


@needs_ffmpeg
def test_end_to_end_excerpt_aligns_at_its_offset(tmp_path):
    full, part = tmp_path / "test_full.mp4", tmp_path / "test_excerpt.mov"
    make_clip(full, 30, MATRIX["test_h264.mp4"])
    subprocess.run([FFMPEG, "-v", "error", "-y", "-ss", "9", "-t", "12", "-i", str(full),
                    "-c:v", "prores_ks", "-profile:v", "0", "-c:a", "pcm_s16le", str(part)], check=True, timeout=120)
    before = {p: (os.path.getsize(p), os.path.getmtime(p)) for p in (full, part)}
    sets = tmp_path / "sets.json"
    sets.write_text(json.dumps([{"title": "test", "reference": 0, "files": [
        {"label": "A · test_full.mp4", "path": str(full)},
        {"label": "B · test_excerpt.mov", "path": str(part)},
        {"label": "C · test_missing.mp4", "path": str(tmp_path / "test_missing.mp4")}]}]))
    out = subprocess.run([sys.executable, SCRIPT, "--sets", str(sets), "--out", str(tmp_path / "run" / "page.html"),
                          "--cache-dir", str(tmp_path / "cache"), "--progress",
                          "--ffmpeg", FFMPEG, "--ffprobe", FFPROBE],
                         capture_output=True, text=True, timeout=300)
    assert out.returncode == 0, out.stdout + out.stderr
    lines = out.stdout.splitlines()
    assert all(line.split(" ", 1)[0] in ("ESTIMATE", "PROGRESS", "DONE") for line in lines), lines
    done = json.loads([line for line in lines if line.startswith("DONE ")][0][5:])
    assert done["files"] == 2
    assert [s["label"] for s in done["skipped"]] == ["C · test_missing.mp4"]
    excerpt = [r for r in done["results"] if r["label"].startswith("B")][0]
    assert excerpt["verdict"] == "same"
    assert abs(excerpt["offset"] - 9) <= 1
    assert os.path.exists(done["html"])
    assert "/*__DATA__*/" not in open(done["html"]).read()
    # the media were only read
    assert before == {p: (os.path.getsize(p), os.path.getmtime(p)) for p in (full, part)}
    # no stray temp files in the cache
    assert all(f.endswith(".npz") and ".part" not in f for f in os.listdir(tmp_path / "cache"))


# ------------------------------------------------------------ QA 2026-10-03

def test_machine_lines_are_pure_ascii_so_a_split_pipe_read_cannot_drop_them():
    # Labels carry " · " (U+00B7) and names may carry é, ü… ProcessRunner's line
    # streamer decodes each pipe chunk on its own and drops a chunk that ends
    # mid-character, so every machine line must be 7-bit (JSON escapes keep it exact).
    for line in (fs.progress_line(1, 2, "A · Café.mov", "reading", 0.5),
                 fs.machine_line("DONE", {"results": [{"label": "B · Ürlaub.mov"}]}),
                 fs.machine_line("ERROR", {"message": "could not be read (Ü)", "skipped": []})):
        assert line.isascii(), line
    assert json.loads(fs.progress_line(1, 2, "A · Café.mov", "reading", 0.5)[9:])["label"] == "A · Café.mov"


def test_two_extractions_of_one_file_never_share_temp_files(tmp_path, monkeypatch):
    # Two runs over the same file share the cache folder; a shared <key>.tmp.cols
    # would let one ffmpeg -y truncate the other's output and cache a damaged strip.
    clip = tmp_path / "test_clip.mov"
    clip.write_bytes(b"x" * 1024)
    seen = []

    def fake_single_pass(path, info, step, tmp, hwaccel, tw, limit_s=0, on_progress=None):
        seen.append(tmp)
        return None, "timeout"

    monkeypatch.setattr(fs, "single_pass", fake_single_pass)
    info = {"duration": 10.0, "codec": "h264", "width": 320, "height": 240, "audio": None}
    for _ in range(2):
        with pytest.raises(RuntimeError):
            fs.extract(str(clip), str(tmp_path / "cache"), True, 160, info=info)
    assert len(seen) == 2 and seen[0] != seen[1], seen


def test_aligning_reports_a_fraction_per_pair():
    # P3-4: the alignment phase keeps the watchdog and the time left honest.
    lines = []
    fs.MACHINE = True
    try:
        orig = fs.emit
        fs.emit = lines.append
        fs.align_progress(3, 4, 4, 2)
    finally:
        fs.emit = orig
        fs.MACHINE = False
    body = json.loads(lines[0][9:])
    assert body["phase"] == "aligning" and body["fraction"] == 0.667 and body["file"] == 4
