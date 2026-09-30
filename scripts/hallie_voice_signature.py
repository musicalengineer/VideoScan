#!/usr/bin/env python3
"""Hallie's voice signature — a regression sensor for how she SOUNDS.

Rick 2026-09-29, after macOS 27 / Xcode 27 silently swapped Hallie's neural
voice (Kokoro "Bella") for Apple speech: "we'll make a recording … and
create a regression test that listens to the voice … if that sig changes by
too much we know we regressed."

A signature is a few numbers that describe a voice, not the words:
  * duration (s)                — pacing / speed setting
  * median pitch (Hz)           — voice identity (autocorrelation, voiced frames)
  * timbre: the mean log-mel spectrum over voiced frames, level-normalised
    (40 bands, 60 Hz – 8 kHz) — the "colour" of the voice.
Two renders of the same voice, text and speed match closely; another Kokoro
voice or Apple speech does not (see tests/test_hallie_voice_signature.py for
the calibration).

    python3 scripts/hallie_voice_signature.py sig FILE.wav        # print JSON
    python3 scripts/hallie_voice_signature.py compare REF.json FILE.wav

numpy only (the project venv). Mono or stereo WAV, any rate (resampled
by decimation-free interpolation to 24 kHz).
"""
from __future__ import annotations

import json
import sys
import wave
from pathlib import Path

import numpy as np

RATE = 24_000
BANDS = 40
FRAME = 600      # 25 ms at 24 kHz
HOP = 240        # 10 ms

# Thresholds, calibrated 2026-09-29 on the M4 (Bella twice, Heart, Apple
# "say"); the test file pins that they separate those cases.
MAX_DURATION_CHANGE = 0.10      # ±10 %
MAX_PITCH_CHANGE = 0.12         # ±12 %
MIN_TIMBRE_SIMILARITY = 0.985   # cosine of level-normalised mean log-mel


def read_wav(path: str | Path) -> np.ndarray:
    with wave.open(str(path), "rb") as w:
        n, ch, width, rate = w.getnframes(), w.getnchannels(), w.getsampwidth(), w.getframerate()
        raw = w.readframes(n)
    if width == 2:
        x = np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32768.0
    elif width == 4:
        x = np.frombuffer(raw, dtype="<i4").astype(np.float64) / 2147483648.0
    else:
        raise ValueError(f"unsupported sample width {width}")
    if ch > 1:
        x = x.reshape(-1, ch).mean(axis=1)
    if rate != RATE:
        t = np.arange(int(len(x) * RATE / rate)) * (rate / RATE)
        x = np.interp(t, np.arange(len(x)), x)
    return x


def _mel_filters() -> np.ndarray:
    def hz_to_mel(f):
        return 2595.0 * np.log10(1.0 + f / 700.0)

    def mel_to_hz(m):
        return 700.0 * (10 ** (m / 2595.0) - 1.0)

    bins = FRAME // 2 + 1
    freqs = np.linspace(0, RATE / 2, bins)
    edges = mel_to_hz(np.linspace(hz_to_mel(60.0), hz_to_mel(8_000.0), BANDS + 2))
    fb = np.zeros((BANDS, bins))
    for b in range(BANDS):
        lo, mid, hi = edges[b], edges[b + 1], edges[b + 2]
        up = (freqs - lo) / (mid - lo)
        down = (hi - freqs) / (hi - mid)
        fb[b] = np.clip(np.minimum(up, down), 0, None)
    return fb


def _frames(x: np.ndarray) -> np.ndarray:
    if len(x) < FRAME:
        x = np.pad(x, (0, FRAME - len(x)))
    count = 1 + (len(x) - FRAME) // HOP
    idx = np.arange(FRAME)[None, :] + HOP * np.arange(count)[:, None]
    return x[idx] * np.hanning(FRAME)[None, :]


def _pitch(frame: np.ndarray) -> float | None:
    f = frame - frame.mean()
    ac = np.correlate(f, f, mode="full")[FRAME - 1:]
    lo, hi = RATE // 400, RATE // 70           # 70–400 Hz
    if ac[0] <= 0:
        return None
    seg = ac[lo:hi]
    k = int(np.argmax(seg)) + lo
    return RATE / k if ac[k] / ac[0] > 0.45 else None


def signature(path: str | Path) -> dict:
    x = read_wav(path)
    fr = _frames(x)
    power = np.abs(np.fft.rfft(fr, axis=1)) ** 2
    energy = 10 * np.log10(power.sum(axis=1) + 1e-12)
    voiced = energy > energy.max() - 35.0
    mel = np.log10(power[voiced] @ _mel_filters().T + 1e-10)
    timbre = mel.mean(axis=0)
    timbre = timbre - timbre.mean()                 # level-normalised
    pitches = [p for p in (_pitch(f) for f in fr[voiced]) if p]
    return {
        "duration_s": round(len(x) / RATE, 3),
        "median_pitch_hz": round(float(np.median(pitches)), 1) if pitches else None,
        "timbre": [round(float(v), 4) for v in timbre],
    }


def compare(ref: dict, got: dict) -> tuple[bool, list[str]]:
    """(same voice?, reasons) — every measure must hold."""
    notes = []
    ok = True
    d = abs(got["duration_s"] - ref["duration_s"]) / ref["duration_s"]
    notes.append(f"duration {ref['duration_s']}s → {got['duration_s']}s ({d:.1%}, limit {MAX_DURATION_CHANGE:.0%})")
    ok &= d <= MAX_DURATION_CHANGE
    if ref["median_pitch_hz"] and got["median_pitch_hz"]:
        p = abs(got["median_pitch_hz"] - ref["median_pitch_hz"]) / ref["median_pitch_hz"]
        notes.append(f"pitch {ref['median_pitch_hz']} → {got['median_pitch_hz']} Hz ({p:.1%}, limit {MAX_PITCH_CHANGE:.0%})")
        ok &= p <= MAX_PITCH_CHANGE
    else:
        notes.append("pitch: not measurable")
        ok = False
    a, b = np.array(ref["timbre"]), np.array(got["timbre"])
    cos = float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))
    notes.append(f"timbre similarity {cos:.4f} (limit {MIN_TIMBRE_SIMILARITY})")
    ok &= cos >= MIN_TIMBRE_SIMILARITY
    return bool(ok), notes


def main(argv: list[str]) -> int:
    if len(argv) == 3 and argv[1] == "sig":
        print(json.dumps(signature(argv[2]), indent=1))
        return 0
    if len(argv) == 4 and argv[1] == "compare":
        ok, notes = compare(json.loads(Path(argv[2]).read_text()), signature(argv[3]))
        print(("SAME VOICE" if ok else "VOICE CHANGED") + "\n  " + "\n  ".join(notes))
        return 0 if ok else 1
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
