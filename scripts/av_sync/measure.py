#!/usr/bin/env python3
"""A/V sync check for an improved copy against its original (GH #309, brief C08).

    scripts/av_sync/measure.py ORIGINAL IMPROVED [--no-video] [--max-lag-ms N]

Prints one JSON object:

    offset_ms        constant lag of IMPROVED's audio behind ORIGINAL's audio at
                     the start of the file (positive = the improved sound is LATE)
    drift_ms         change in that lag over the original's length
    confidence       0..1
    windows          per-window lag (ms) and correlation peak
    video_offset_ms  the same lag measured on the PICTURE (frame-difference
                     envelope), or null when either file has no video / --no-video
    av_offset_ms     offset_ms - video_offset_ms: how far the improved copy's
                     sound moved relative to its OWN picture (what a viewer sees)
    trim_ms          sound AND picture moved by the same amount (a cut at the
                     start, not a sync error), or null
    verdict          in_sync | offset | drifting | unsure

Method (brief C08): decode each audio track with ffmpeg to mono 8 kHz float,
take an onset envelope at 1 kHz (half-wave-rectified rise of log energy), and
cross-correlate it (FFT, normalised) in five windows spread across the
original. The lag per window is refined to sub-millisecond with a parabola
through the peak. A Theil-Sen line through the confident windows gives the
offset (its value at t = 0) and the drift (its slope x the length). A window
is confident only when its peak is clearly above everything else in the
search range (peak-to-sidelobe ratio); fewer than three confident windows, or
a near-silent track, gives "unsure".

Why audio vs audio: improvers (Topaz) re-encode the picture, so the
original's sound is the one reference that survives intact. Why the picture
check as well: audio vs audio cannot see a shift of the PICTURE. A copy cut
2 s at the start shows -2000 ms of audio lag with a perfectly synced picture;
the picture check measures the same -2000 ms and so tells a trim from a sync
error (av_offset_ms ~ 0).

Only numpy and scipy, plus ffmpeg/ffprobe on PATH. (C++ terms for Rick: this
is a matched filter. Each window of the original's envelope is the filter
kernel, slid over the improved envelope; the best-matching shift is the lag.)
"""
from __future__ import annotations

import argparse
import json
import math
import shutil
import subprocess
import sys
from dataclasses import dataclass, asdict

import numpy as np
from scipy import signal, stats
from scipy.ndimage import gaussian_filter1d

AUDIO_RATE = 8000          # decode rate (brief: mono 8 kHz)
ENV_RATE = 1000            # envelope rate: 1 ms per sample
VIDEO_ENV_RATE = 100       # picture envelope: frames resampled to 100 fps (10 ms)
N_WINDOWS = 5
ONSET_SMOOTH_MS = 8.0     # Gaussian sigma on the onset envelope
TRIM_MIN_MS = 80.0        # the picture moved >= 2 frames at 25 fps: a cut, not jitter
DEFAULT_MAX_LAG_MS = 3000  # covers +-500 ms offsets and a 2 s start trim

# Verdict thresholds (what the measurement calls out; the APP's warn / Repair
# thresholds are separate, see the report): a lag or drift under these is
# inside the method's error budget and reads as "in sync".
OFFSET_THRESHOLD_MS = 20.0
DRIFT_THRESHOLD_MS = 20.0

# Confidence rules, tuned on the synthetic matrix (see the report).
MIN_PEAK = 0.20            # normalised cross-correlation peak
MIN_PSR = 1.5              # peak / best sidelobe outside +-SIDELOBE_GUARD_MS
SIDELOBE_GUARD_MS = 40
MIN_CONFIDENT_WINDOWS = 3
SILENCE_DBFS = -55.0       # 95th-percentile frame RMS below this = too quiet
OUTLIER_MS = 40.0          # a window this far from the line is dropped


class MeasureError(RuntimeError):
    pass


# ── decode ────────────────────────────────────────────────────────────────

def _run(cmd: list[str], timeout: float) -> bytes:
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    except subprocess.TimeoutExpired as e:
        raise MeasureError(f"{cmd[0]} timed out after {timeout:.0f} s") from e
    if p.returncode != 0:
        tail = p.stderr.decode(errors="replace").strip().splitlines()[-1:] or ["(no message)"]
        raise MeasureError(f"{cmd[0]} exited {p.returncode}: {tail[0]}")
    return p.stdout


def probe(path: str) -> dict:
    out = _run(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", path], 60)
    info = json.loads(out)
    streams = info.get("streams", [])
    return {
        "duration": float(info.get("format", {}).get("duration") or 0.0),
        "has_audio": any(s.get("codec_type") == "audio" for s in streams),
        "has_video": any(s.get("codec_type") == "video" for s in streams),
    }


def decode_audio(path: str, timeout: float = 600) -> np.ndarray:
    """First audio stream, downmixed to mono, resampled to 8 kHz, float32."""
    raw = _run(["ffmpeg", "-nostdin", "-v", "error", "-i", path, "-map", "0:a:0", "-vn",
                "-ac", "1", "-ar", str(AUDIO_RATE), "-f", "f32le", "-"], timeout)
    return np.frombuffer(raw, dtype="<f4").astype(np.float64)


def _frame_times(path: str, timeout: float = 600) -> np.ndarray:
    """Presentation time of every video frame, in seconds (handles VFR)."""
    out = _run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                "frame=pts_time,best_effort_timestamp_time", "-of", "csv=p=0", path], timeout)
    times = []
    for line in out.decode().splitlines():
        for field in line.split(","):
            try:
                times.append(float(field))
                break
            except ValueError:
                continue
    return np.array(times)


def decode_video_envelope(path: str, timeout: float = 600) -> np.ndarray:
    """Frame-difference envelope on a 100 Hz grid: mean |frame - previous
    frame| on a 64x36 grey thumbnail, placed at each frame's own timestamp.
    Decoding at the native rate (no fps filter) and placing by timestamp puts
    two files with different frame rates on one clock, at a third of the cost
    of resampling every file to 100 fps first."""
    w, h = 64, 36
    raw = _run(["ffmpeg", "-nostdin", "-v", "error", "-i", path, "-map", "0:v:0", "-an",
                "-fps_mode", "passthrough", "-vf", f"scale={w}:{h}:flags=area,format=gray",
                "-f", "rawvideo", "-"], timeout)
    frames = np.frombuffer(raw, dtype=np.uint8)
    n = frames.size // (w * h)
    if n < 2:
        return np.zeros(0)
    frames = frames[: n * w * h].reshape(n, w * h).astype(np.float32)
    diff = np.abs(np.diff(frames, axis=0)).mean(axis=1)
    times = _frame_times(path, timeout)
    if times.size != n:                     # timestamps unreadable: assume constant rate
        info = json.loads(_run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                                "stream=avg_frame_rate", "-of", "json", path], 60))
        num, _, den = (info["streams"][0].get("avg_frame_rate") or "25/1").partition("/")
        fps = float(num) / float(den or 1) if float(num) else 25.0
        times = np.arange(n) / fps
    times = times - times[0]
    env = np.zeros(int(math.ceil(times[-1] * VIDEO_ENV_RATE)) + 2)
    np.add.at(env, np.round(times[1:] * VIDEO_ENV_RATE).astype(int), diff)
    return env


# ── envelopes ─────────────────────────────────────────────────────────────

def onset_envelope(x: np.ndarray) -> tuple[np.ndarray, float]:
    """1 kHz onset envelope and the track's loudness (95th-pct frame RMS, dBFS).

    Energy in 8 ms frames hopped every 1 ms, log-compressed, then the
    half-wave-rectified first difference: attacks (syllables, door slams,
    claps) become spikes, steady tones and hiss become ~0. Attacks survive
    resampling, AAC, a mono downmix and atempo's time-stretch, where the raw
    waveform would not."""
    hop = AUDIO_RATE // ENV_RATE           # 8 samples
    frame = 8 * hop                        # 64 samples = 8 ms
    if x.size < frame:
        return np.zeros(0), -120.0
    n = 1 + (x.size - frame) // hop
    c = np.concatenate([[0.0], np.cumsum(x * x)])
    starts = np.arange(n) * hop
    energy = (c[starts + frame] - c[starts]) / frame
    rms_db = 10.0 * np.log10(np.percentile(energy, 95) + 1e-20)
    loge = np.log10(energy + 1e-7)         # floor ~ -70 dBFS keeps hiss from dominating
    onset = np.maximum(0.0, np.diff(loge, prepend=loge[0]))
    # Smooth to ~8 ms: a time-stretch (atempo / WSOLA) moves each attack by a
    # few ms and breaks 1 ms spikes apart; the smoothed bumps still overlap.
    # The parabola through the correlation peak keeps sub-ms precision.
    return gaussian_filter1d(onset, ONSET_SMOOTH_MS * ENV_RATE / 1000), float(rms_db)


# ── correlation ───────────────────────────────────────────────────────────

@dataclass
class Window:
    center_s: float
    lag_ms: float | None
    peak: float
    psr: float
    confident: bool


def _ncc_lags(ref: np.ndarray, target: np.ndarray, start: int, max_lag: int) -> tuple[np.ndarray, np.ndarray]:
    """Normalised cross-correlation of ref (a window of the original starting
    at `start`) against target, for lags -max_lag..+max_lag samples.
    Lags whose target span falls more than 10 % outside `target` are -inf."""
    w = ref.size
    ref = ref - ref.mean()
    rnorm = np.linalg.norm(ref)
    lags = np.arange(-max_lag, max_lag + 1)
    if rnorm == 0:
        return lags, np.full(lags.size, -np.inf)
    lo = start - max_lag
    hi = start + max_lag + w
    pad_l = max(0, -lo)
    pad_r = max(0, hi - target.size)
    seg = np.concatenate([np.zeros(pad_l), target[max(lo, 0): min(hi, target.size)], np.zeros(pad_r)])
    valid_mask = np.concatenate([np.zeros(pad_l), np.ones(seg.size - pad_l - pad_r), np.zeros(pad_r)])
    dots = signal.fftconvolve(seg, ref[::-1], mode="valid")           # one value per lag
    c1 = np.concatenate([[0.0], np.cumsum(seg)])
    c2 = np.concatenate([[0.0], np.cumsum(seg * seg)])
    cv = np.concatenate([[0.0], np.cumsum(valid_mask)])
    s1 = c1[w:] - c1[:-w]
    s2 = c2[w:] - c2[:-w]
    cover = (cv[w:] - cv[:-w]) / w
    var = np.maximum(s2 - s1 * s1 / w, 0.0)
    with np.errstate(invalid="ignore", divide="ignore"):
        ncc = dots / (rnorm * np.sqrt(var))
    ncc[~np.isfinite(ncc)] = -np.inf
    ncc[cover < 0.9] = -np.inf
    return lags, ncc


def _peak(lags: np.ndarray, ncc: np.ndarray, rate: int) -> tuple[float | None, float, float]:
    """Lag (ms, parabola-refined), peak height, peak-to-sidelobe ratio."""
    if not np.isfinite(ncc).any():
        return None, 0.0, 0.0
    i = int(np.argmax(ncc))
    p = float(ncc[i])
    guard = max(1, int(SIDELOBE_GUARD_MS * rate / 1000))
    side = np.concatenate([ncc[: max(0, i - guard)], ncc[i + guard + 1:]])
    side = side[np.isfinite(side)]
    best_side = float(side.max()) if side.size else 0.0
    psr = p / best_side if best_side > 1e-9 else (math.inf if p > 0 else 0.0)
    frac = 0.0
    if 0 < i < ncc.size - 1 and np.isfinite(ncc[i - 1]) and np.isfinite(ncc[i + 1]):
        a, b, c = ncc[i - 1], ncc[i], ncc[i + 1]
        den = a - 2 * b + c
        if den < 0:
            frac = 0.5 * (a - c) / den
    return (lags[i] + frac) * 1000.0 / rate, p, psr


def window_lags(ref_env: np.ndarray, tgt_env: np.ndarray, rate: int, max_lag_ms: float) -> list[Window]:
    n = ref_env.size
    duration = n / rate
    win_s = min(15.0, max(2.0, duration / 8))
    w = int(win_s * rate)
    max_lag = int(max_lag_ms * rate / 1000)
    out = []
    if n < w + 2:
        return out
    for k in range(N_WINDOWS):
        center = duration * (k + 0.5) / N_WINDOWS
        start = int(min(max(0, center * rate - w / 2), n - w))
        lags, ncc = _ncc_lags(ref_env[start: start + w], tgt_env, start, max_lag)
        lag, p, psr = _peak(lags, ncc, rate)
        ok = lag is not None and p >= MIN_PEAK and psr >= MIN_PSR
        out.append(Window((start + w / 2) / rate, lag, p, psr, ok))
    return out


@dataclass
class LagFit:
    offset_ms: float | None
    drift_ms: float | None
    confidence: float
    used: int


def fit_lags(windows: list[Window], duration_s: float) -> LagFit:
    good = [wd for wd in windows if wd.confident]
    if len(good) < MIN_CONFIDENT_WINDOWS:
        return LagFit(None, None, 0.0, len(good))
    t = np.array([wd.center_s for wd in good])
    lag = np.array([wd.lag_ms for wd in good])
    slope, intercept, *_ = stats.theilslopes(lag, t)
    resid = np.abs(lag - (intercept + slope * t))
    keep = resid <= OUTLIER_MS
    if keep.sum() < MIN_CONFIDENT_WINDOWS:
        return LagFit(None, None, 0.0, int(keep.sum()))
    if keep.sum() < len(good):
        slope, intercept, *_ = stats.theilslopes(lag[keep], t[keep])
        for wd, k in zip(good, keep):
            if not k:
                wd.confident = False
    drift = slope * duration_s
    if abs(drift) < DRIFT_THRESHOLD_MS:
        # No real drift: the median is the robust constant lag.
        intercept, drift = float(np.median(lag[keep])), float(drift)
    per = [min(1.0, wd.peak / 0.5) * min(1.0, (wd.psr - 1.0) / 1.0) for wd, k in zip(good, keep) if k]
    conf = float(np.mean(per)) * (int(keep.sum()) / len(windows))
    return LagFit(float(intercept), float(drift), round(max(0.0, min(1.0, conf)), 3), int(keep.sum()))


# ── top level ─────────────────────────────────────────────────────────────

def _verdict(offset: float | None, drift: float | None) -> str:
    if offset is None or drift is None:
        return "unsure"
    if abs(drift) >= DRIFT_THRESHOLD_MS:
        return "drifting"
    if abs(offset) >= OFFSET_THRESHOLD_MS:
        return "offset"
    return "in_sync"


def measure(original: str, improved: str, use_video: bool = True,
            max_lag_ms: float = DEFAULT_MAX_LAG_MS) -> dict:
    po, pi = probe(original), probe(improved)
    notes: list[str] = []
    result = {"offset_ms": None, "drift_ms": None, "confidence": 0.0, "windows": [],
              "video_offset_ms": None, "av_offset_ms": None, "trim_ms": None,
              "duration_delta_ms": round((pi["duration"] - po["duration"]) * 1000.0, 1),
              "verdict": "unsure", "notes": notes}
    if not (po["has_audio"] and pi["has_audio"]):
        notes.append("a file has no audio track")
        return result

    ref_env, ref_db = onset_envelope(decode_audio(original))
    tgt_env, tgt_db = onset_envelope(decode_audio(improved))
    if ref_db < SILENCE_DBFS or tgt_db < SILENCE_DBFS:
        notes.append(f"too quiet to measure (original {ref_db:.0f} dBFS, improved {tgt_db:.0f} dBFS)")
        return result
    duration = ref_env.size / ENV_RATE
    wins = window_lags(ref_env, tgt_env, ENV_RATE, max_lag_ms)
    fit = fit_lags(wins, duration)
    result["windows"] = [{"center_s": round(w.center_s, 2),
                          "lag_ms": None if w.lag_ms is None else round(w.lag_ms, 1),
                          "peak": round(w.peak, 3), "psr": round(min(w.psr, 99.0), 2),
                          "confident": w.confident} for w in wins]
    result["confidence"] = fit.confidence
    if fit.offset_ms is None:
        notes.append(f"only {fit.used} of {len(wins)} windows matched clearly")
        return result
    result["offset_ms"] = round(fit.offset_ms, 1)
    result["drift_ms"] = round(fit.drift_ms, 1)
    av_offset, av_drift = fit.offset_ms, fit.drift_ms

    if use_video and po["has_video"] and pi["has_video"]:
        vo, vi = decode_video_envelope(original), decode_video_envelope(improved)
        vfit = fit_lags(window_lags(vo, vi, VIDEO_ENV_RATE, max_lag_ms), vo.size / VIDEO_ENV_RATE)
        if vfit.offset_ms is not None:
            result["video_offset_ms"] = round(vfit.offset_ms, 1)
            av_offset = fit.offset_ms - vfit.offset_ms
            av_drift = fit.drift_ms - vfit.drift_ms
            result["av_offset_ms"] = round(av_offset, 1)
            if abs(vfit.offset_ms) >= TRIM_MIN_MS:
                if abs(av_offset) < OFFSET_THRESHOLD_MS:
                    result["trim_ms"] = round(vfit.offset_ms, 1)
                    notes.append("the picture moved by the same amount: a cut at the start, not a sync error")
                else:
                    notes.append(f"the picture moved {vfit.offset_ms:+.0f} ms and the sound did not follow")
        else:
            notes.append("picture check inconclusive (too little motion); verdict is audio vs audio only")

    result["verdict"] = _verdict(av_offset, av_drift)
    return result


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("original")
    ap.add_argument("improved")
    ap.add_argument("--no-video", action="store_true", help="skip the picture-vs-picture check")
    ap.add_argument("--max-lag-ms", type=float, default=DEFAULT_MAX_LAG_MS)
    a = ap.parse_args(argv)
    for tool in ("ffmpeg", "ffprobe"):
        if shutil.which(tool) is None:
            print(json.dumps({"error": f"{tool} not on PATH"}))
            return 2
    try:
        print(json.dumps(measure(a.original, a.improved, not a.no_video, a.max_lag_ms), indent=2))
    except MeasureError as e:
        print(json.dumps({"error": str(e)}))
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
