"""A fake ClipService for VideoScanCore's PythonClipWorker / EraJob tests — no model, no media.

Built by `bench.py worker --factory import:<this dir>:fake_clip_service:<factory>`, so the
REAL worker loop (bench.py `worker_command`) carries every request.  Behaviour by path:
  "hang"  → never answers (the per-clip watchdog must kill it)
  "die"   → the process exits mid-clip
  "boom"  → raises (comes back as an error reply)
  "stamp" → the 5 OCR stills read "JUN 21 1991"; windows cite the stamp
  "blank" → no valid era window, no date
  "generr" → every era window is a generation error (the model never answered), no date
             ("generr-stamp": the same, beside five stills that read the stamp)
  "ripfail" → every frame failed to rip: no window, no still, three frame_failed records
  "flaky"  → "ripfail" for the first two analyze calls of that path (counted in FAKE_CLIP_LOG),
             then as below — a file that recovers before the try limit
  "tools" → first runs `ffprobe -version` then `ffmpeg -version` BY BARE NAME, exactly as
            bench.py's probe_duration / rip_frame do, so a worker started with a PATH that has
            no Homebrew raises FileNotFoundError (the 2026-11-03 launchd bug); then as below
  else    → three era windows 1990-1994 / 1991-1995 / 1991-1995
FAKE_CLIP_LOG (env): a file each load / analyze_clip appends one line to (the tests count loads).
FAKE_LOAD_SECONDS (env): load sleeps this long first.
FAKE_ALL_HANG (env): every analyze_clip hangs — a model that answers nothing (EraCanary's model check).
"""
import json
import os
import subprocess
import sys
import time


def _note(line):
    path = os.environ.get("FAKE_CLIP_LOG")
    if path:
        with open(path, "a", encoding="utf-8") as stream:
            stream.write(line + "\n")


def _era(window, lo, hi, stamp):
    cues = [{"kind": "technical", "text": "tracking lines", "atS": window[0] + 1.0}]
    if stamp:
        cues.append({"kind": "onScreenText", "text": "JUN 21 1991", "atS": window[0] + 2.0})
    return json.dumps({"family": "era", "window": window, "yearRange": [lo, hi], "rationale": "synthetic",
                       "cues": cues, "selfConfidence": 0.7})


def _analyses(path):
    """How many `analyze <path>` lines FAKE_CLIP_LOG holds (this call's included)."""
    log = os.environ.get("FAKE_CLIP_LOG")
    if not log or not os.path.exists(log):
        return 0
    with open(log, encoding="utf-8") as stream:
        return sum(1 for line in stream if line.rstrip("\n") == "analyze " + path)


class FakeClipService:
    def load(self):
        seconds = float(os.environ.get("FAKE_LOAD_SECONDS") or 0)
        if seconds:
            time.sleep(seconds)
        print("fake model chatter on stdout")       # the worker must route this to stderr
        _note("load")
        return {"approach_id": "qwen3-vl-8b-4bit/era-v1/window-60s", "revision": 3,
                "model": "mlx-community/Qwen3-VL-8B-Instruct-4bit", "prompts_sha256": {"era": "e" * 64, "date": "d" * 64},
                "frames_per_window": 8, "ocr_stills": 5, "families": ["era"], "pid": os.getpid()}

    def analyze_clip(self, path, duration_s, context=None):
        _note("analyze " + path)
        if os.environ.get("FAKE_ALL_HANG"):   # the model answers nothing, whatever the file (synthetic canary included)
            time.sleep(600)
        if "hang" in path:
            time.sleep(600)
        if "die" in path:
            sys.stderr.write("fake worker dying on purpose\n")
            sys.stderr.flush()
            os._exit(3)
        if "boom" in path:
            raise RuntimeError("deliberate")
        if "tools" in path:
            for tool in ("ffprobe", "ffmpeg"):
                subprocess.run([tool, "-version"], capture_output=True, timeout=30, check=True)
        if "flaky" in path and _analyses(path) <= 2:
            path = path.replace("flaky", "ripfail")
        if "ripfail" in path:
            return {"header": {"record_type": "clip", "duration_s": float(duration_s or 100.0), "windows": []},
                    "window_results": [], "results": [],
                    "frames_failed": [{"record_type": "frame_failed", "frame_index": k, "at_s": float(k)} for k in range(3)],
                    "footer": {"record_type": "clip_done", "frames_ok": 0, "frames_failed": 3, "clip_s": 0.01, "peak_rss_bytes": 123456},
                    "summary": {"year_range": None, "burned_in_years": [], "fused": None, "fused_years": None, "valid_era_windows": 0}}
        stamp = "stamp" in path
        generr = "generr" in path
        blank = "blank" in path or generr
        d = float(duration_s or 100.0)
        windows = [[round(d * 0.05, 3), round(d * 0.05 + 10, 3)], [round(d / 2 - 5, 3), round(d / 2 + 5, 3)],
                   [round(d * 0.95 - 10, 3), round(d * 0.95, 3)]]
        ranges = [(1990, 1994), (1991, 1995), (1991, 1995)]
        window_results = []
        for i, (w, (lo, hi)) in enumerate(zip(windows, ranges)):
            raw = "" if generr else ("not json" if blank else _era(w, lo, hi, stamp))
            window_results.append({"record_type": "window_result", "window_index": i, "window": w,
                                   "frame_times_s": [w[0] + k for k in range(8)], "frames_shown": 8, "family": "era",
                                   "prompt_sha256": "e" * 64, "raw_text": raw,
                                   "error": "GenerationTimeout: synthetic" if generr else None, "schema_valid": not blank,
                                   "schema_invalid_reason": ("timeout" if generr else "not json") if blank else None, "elapsed_s": 0.5})
        results = []
        for k in range(5):
            text = "JUN 21 1991" if stamp else "NONE"
            results.append({"record_type": "result", "frame_index": 24 + k, "window_index": None, "sampler": "stills",
                            "at_s": round(d * (0.05 + 0.225 * k), 3), "prompt_kind": "date", "raw_text": text,
                            "error": None, "parsed": {"dates": ["1991-06-21"] if stamp else [], "years": [1991] if stamp else [],
                                                      "decades": [], "degenerate": False}})
        fused = None if blank else ([1991, 1991] if stamp else [1991, 1995])
        return {"header": {"record_type": "clip", "duration_s": d, "windows": [{"index": i, "start_s": w[0], "end_s": w[1]} for i, w in enumerate(windows)]},
                "window_results": window_results, "results": results, "frames_failed": [],
                "footer": {"record_type": "clip_done", "frames_ok": 29, "clip_s": 0.01, "peak_rss_bytes": 123456},
                "summary": {"year_range": None if blank else [1991.0, 1995.0], "burned_in_years": [1991, 1991, 1991] if stamp else [],
                            "fused": fused, "fused_years": fused, "valid_era_windows": 0 if blank else 3}}

    def after_clip(self):
        pass


class WrongIdService(FakeClipService):
    def load(self):
        info = FakeClipService.load(self)
        info["approach_id"] = "not an id"
        return info


def make_service():
    return FakeClipService()


def make_wrong_id_service():
    return WrongIdService()


# --- Real frames, fake model -------------------------------------------------
# `make_real_rip_service`: bench.py's OWN ClipService — real ffprobe, real
# ffmpeg frame rips, the real sampler and record shape — with a fake approach
# in place of the 8B, so a media-matrix test proves what the service does with
# files that decode and files that do not, in seconds, with no weights.
# The worker runs bench.py as __main__ under `python -I` (no script dir on
# sys.path), so the module is reached through sys.modules, never `import bench`.

class FakeEraApproach:
    """Answers every era window with a valid r3 contract (1990–1995) and every
    date still with NONE.  Duck-types bench.py's Approach for ClipService."""
    id = "fake-era"
    model_id = "mlx-community/Qwen3-VL-8B-Instruct-4bit"

    def load(self):
        _note("load")
        return {"model": self.model_id, "pid": os.getpid()}

    def seed(self, value):
        pass

    def answer(self, png, kind):
        return "NONE", {}

    def answer_window(self, pngs, family, window, context=None):
        w = [window["start_s"], window["end_s"]]
        return json.dumps({"family": "era", "window": w, "yearRange": [1990, 1995], "rationale": "synthetic",
                           "cues": [{"kind": "technical", "text": "synthetic test pattern", "atS": w[0]}],
                           "selfConfidence": 0.6}), {}

    def after_clip(self):
        pass


class _NotingClipService:
    """bench.ClipService plus the FAKE_CLIP_LOG line per analyze (tests count tries)."""
    def __init__(self, inner):
        self.inner = inner

    def load(self):
        return self.inner.load()

    def analyze_clip(self, path, duration_s, context=None):
        _note("analyze " + path)
        return self.inner.analyze_clip(path, duration_s, context)

    def after_clip(self):
        self.inner.after_clip()

    def __getattr__(self, name):          # any other worker verb goes to the real service
        return getattr(self.inner, name)


def make_real_rip_service():
    bench = sys.modules["__main__"]
    return _NotingClipService(bench.ClipService(approach=FakeEraApproach()))
