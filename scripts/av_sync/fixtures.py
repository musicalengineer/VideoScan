#!/usr/bin/env python3
"""Synthetic fixtures for the A/V sync check (brief C08). ffmpeg only, generated
on demand into a temp directory: nothing here reads or writes real media.

    scripts/av_sync/fixtures.py OUTDIR [--duration 60]

The ORIGINAL is a small `testsrc2` picture with full-frame flashes, and a
sound made of spoken-like bursts (an `aevalsrc` warbling tone) over quiet
`anoisesrc` room tone. The flashes and the bursts share one irregular gate:
four incommensurate sines summed and thresholded, so the on/off pattern never
repeats within the lag search range (a periodic pattern would correlate at
several lags and could not be measured). Each IMPROVED variant re-encodes and
2x-upscales the picture, as Topaz does, and applies one sound change.
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys

# One irregular gate, shared by the sound bursts and the picture flashes.
GATE = ("gt(sin(2*PI*0.53*t)+sin(2*PI*0.89*t+1)+sin(2*PI*1.37*t+2)"
        "+sin(2*PI*2.21*t+3)+0.6*sin(2*PI*3.7*t+4),1.4)")
BURST = f"0.45*{GATE}*sin(2*PI*(260*t+20*sin(2*PI*4.1*t)))"

# name -> (audio filter or None, extra output args, container ext, expected)
# expected: (verdict, offset_ms, drift_ms) with None = "don't assert"
VARIANTS: dict[str, tuple] = {
    "in_sync":       (None, [], "mov", ("in_sync", 0, 0)),
    "plus40":        ("adelay=40:all=1", [], "mov", ("offset", 40, 0)),
    "minus120":      ("atrim=start=0.120,asetpts=PTS-STARTPTS", [], "mov", ("offset", -120, 0)),
    "plus500":       ("adelay=500:all=1", [], "mov", ("offset", 500, 0)),
    "drift200":      (None, [], "mov", ("drifting", 0, 200)),          # atempo built per duration
    "clockdrift200": (None, [], "mov", ("drifting", 0, 200)),          # asetrate: a capture clock
    "sr44100":       ("aresample=44100", ["-ar", "44100"], "mov", ("in_sync", 0, 0)),
    "aac":           (None, ["-c:a", "aac", "-b:a", "128k"], "mp4", ("in_sync", 0, 0)),
    "trim2s":        (None, [], "mov", ("in_sync", -2000, 0)),         # cut built with -ss
    "stereo":        (None, ["-ac", "2"], "mov", ("in_sync", 0, 0)),
    # The PICTURE starts 200 ms late (first frame held), the sound untouched:
    # audio vs audio sees nothing; only the picture check can.
    "video_late200": (None, [], "mov", ("offset", 0, 0)),
}

# Picture changes on top of the Topaz-like re-encode, per variant.
VIDEO_FILTERS = {"video_late200": "tpad=start_duration=0.2:start_mode=clone"}


def ff(args: list[str]) -> None:
    p = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", *args],
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if p.returncode != 0:
        raise RuntimeError("ffmpeg failed: " + p.stderr.decode(errors="replace")[-400:])


def make_original(path: str, duration: float, quiet: bool = False) -> str:
    """320x180 25 fps h264 + 48 kHz mono PCM in a .mov."""
    if quiet:
        audio = f"anoisesrc=color=pink:amplitude=0.0005:sample_rate=48000:duration={duration}"
        fc = "[1:a]aformat=channel_layouts=mono[a]"
        inputs = ["-f", "lavfi", "-i", audio]
    else:
        inputs = ["-f", "lavfi", "-i", f"aevalsrc='{BURST}':s=48000:d={duration}",
                  "-f", "lavfi", "-i", f"anoisesrc=color=pink:amplitude=0.01:sample_rate=48000:duration={duration}"]
        fc = "[1:a][2:a]amix=inputs=2:normalize=0,aformat=channel_layouts=mono[a]"
    video = (f"testsrc2=s=320x180:r=25:d={duration},"
             f"drawbox=x=0:y=0:w=iw:h=ih:color=white@0.85:t=fill:enable='{GATE}'")
    ff(["-f", "lavfi", "-i", video, *inputs,
        "-filter_complex", fc, "-map", "0:v", "-map", "[a]",
        "-c:v", "libx264", "-preset", "ultrafast", "-crf", "23", "-pix_fmt", "yuv420p",
        "-c:a", "pcm_s16le", "-t", str(duration), path])
    return path


def make_improved(original: str, outdir: str, name: str, duration: float) -> str:
    afilter, extra, ext, _ = VARIANTS[name]
    out = os.path.join(outdir, f"improved_{name}.{ext}")
    pre: list[str] = []
    if name == "drift200":
        # The sound ends 200 ms later than the picture over the length:
        # tempo = D / (D + 0.2). atempo keeps the pitch (time-stretch).
        afilter = f"atempo={duration / (duration + 0.2):.8f}"
    if name == "clockdrift200":
        # The same 200 ms, as a slow sample clock makes it: every sample
        # stretched by D/(D+0.2) (pitch drops 0.3 %, as a tape deck's would).
        afilter = f"asetrate={48000 * duration / (duration + 0.2):.4f},aresample=48000"
    if name == "trim2s":
        pre = ["-ss", "2"]                                    # both streams cut
    vf = "scale=iw*2:ih*2:flags=bicubic"                      # Topaz-like re-encode + upscale
    if name in VIDEO_FILTERS:
        vf = VIDEO_FILTERS[name] + "," + vf
    args = [*pre, "-i", original, "-vf", vf,
            "-c:v", "libx264", "-preset", "ultrafast", "-crf", "28", "-pix_fmt", "yuv420p"]
    if afilter:
        args += ["-af", afilter]
    if "-c:a" not in extra:
        args += ["-c:a", "pcm_s16le"]
    args += [*extra, out]
    ff(args)
    return out


def build_all(outdir: str, duration: float = 60.0) -> dict[str, str]:
    os.makedirs(outdir, exist_ok=True)
    orig = make_original(os.path.join(outdir, "original.mov"), duration)
    paths = {"original": orig}
    for name in VARIANTS:
        paths[name] = make_improved(orig, outdir, name, duration)
    qdir = os.path.join(outdir, "quiet")                     # own folder: same variant names
    os.makedirs(qdir, exist_ok=True)
    paths["quiet_original"] = make_original(os.path.join(qdir, "original.mov"), duration, quiet=True)
    paths["quiet_improved"] = make_improved(paths["quiet_original"], qdir, "in_sync", duration)
    return paths


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("outdir")
    ap.add_argument("--duration", type=float, default=60.0)
    a = ap.parse_args()
    for k, v in build_all(a.outdir, a.duration).items():
        print(k, v)
    sys.exit(0)
