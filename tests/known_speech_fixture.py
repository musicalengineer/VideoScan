#!/usr/bin/env python3
"""known_speech_fixture.py — a short video whose audio track says a known sentence.

Generated at test time, never family media: macOS `say` speaks SENTENCE,
ffmpeg muxes it with a lavfi test pattern into an ~8 s .mov (h264 + AAC,
the shape most family camcorder exports have). Used by
tests/test_audio_transcribe_smoke.py and scripts/audio_smoke.sh.

    python3 tests/known_speech_fixture.py <out.mov> [shape]   # writes it, prints the voice used

Voice: "Daniel" (en_GB, a built-in voice on the M4 and the M5 Ultra, checked
2026-11-05 with `say -v '?'`); when a Mac lacks it, the system default
voice. Whisper does not need the bytes to match across Macs, only the words,
so generating beats a checked-in binary.

Memory: one ~8 s AIFF (~0.7 MB) and one ~8 s clip per shape (h264 < 1 MB,
ProRes/FFV1/MXF 2-4 MB, DV ~30 MB), in the caller's temp folder.
"""
from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path
from typing import List, Optional

SENTENCE = ("VideoScan audio check. The quick brown fox jumps over the lazy dog. "
            "Seventeen purple elephants.")
# What a correct transcript must contain, lower-cased, punctuation stripped.
KEY_PHRASES = ("quick brown fox", "lazy dog", "purple elephants")
PREFERRED_VOICE = "Daniel"
DURATION_SECONDS = 8

# The media matrix (CLAUDE.md rule 8): container → (video args, audio args).
# Whisper decodes through ffmpeg, so each container/codec pair is a separate
# way for "no audio" to happen. Sizes/rates are what each codec requires
# (DV: 720x480 NTSC, 4:1:1, 48 kHz PCM; MXF OP1a: MPEG-2 + PCM).
SHAPES = {
    "mov-h264-aac":   ("mov", ["-s", "320x240", "-r", "30", "-c:v", "libx264", "-pix_fmt", "yuv420p"],
                       ["-c:a", "aac", "-ar", "48000", "-ac", "2"]),
    "mp4-h264-aac":   ("mp4", ["-s", "320x240", "-r", "30", "-c:v", "libx264", "-pix_fmt", "yuv420p"],
                       ["-c:a", "aac", "-ar", "48000", "-ac", "2"]),
    "mov-prores-pcm": ("mov", ["-s", "320x240", "-r", "30", "-c:v", "prores_ks", "-profile:v", "0"],
                       ["-c:a", "pcm_s16le", "-ar", "48000", "-ac", "2"]),
    "mkv-ffv1-pcm":   ("mkv", ["-s", "320x240", "-r", "30", "-c:v", "ffv1"],
                       ["-c:a", "pcm_s16le", "-ar", "48000", "-ac", "2"]),
    "mxf-mpeg2-pcm":  ("mxf", ["-s", "720x480", "-r", "30000/1001", "-c:v", "mpeg2video", "-b:v", "8M"],
                       ["-c:a", "pcm_s16le", "-ar", "48000", "-ac", "1"]),
    "avi-dv-pcm":     ("avi", ["-s", "720x480", "-r", "30000/1001", "-c:v", "dvvideo", "-pix_fmt", "yuv411p"],
                       ["-c:a", "pcm_s16le", "-ar", "48000", "-ac", "2"]),
}
DEFAULT_SHAPE = "mov-h264-aac"

_BREW = ("/opt/homebrew/bin", "/usr/local/bin")


def tool(name: str) -> str:
    """Absolute path of a Homebrew tool (the app's PATH rule), else `which`."""
    for d in _BREW:
        p = Path(d) / name
        if p.is_file():
            return str(p)
    found = shutil.which(name)
    if not found:
        raise FileNotFoundError(f"{name} is not installed (brew bundle installs it)")
    return found


def available_voice(preferred: str = PREFERRED_VOICE) -> Optional[str]:
    """`preferred` if `say` has it, else None (= the system default voice)."""
    listing = subprocess.run(["/usr/bin/say", "-v", "?"], capture_output=True, text=True, check=True).stdout
    names = {line.split("  ")[0].strip() for line in listing.splitlines() if line.strip()}
    return preferred if preferred in names else None


def make_known_speech(out: Path, shape: str = DEFAULT_SHAPE) -> str:
    """Write the fixture to `out` in `shape` (a SHAPES key); return the voice used."""
    _, vargs, aargs = SHAPES[shape]
    out.parent.mkdir(parents=True, exist_ok=True)
    aiff = out.with_name(out.stem + ".speech.aiff")
    voice = available_voice()
    say: List[str] = ["/usr/bin/say"] + (["-v", voice] if voice else []) + ["-o", str(aiff), SENTENCE]
    subprocess.run(say, check=True, capture_output=True)
    r = subprocess.run([
        tool("ffmpeg"), "-hide_banner", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", f"testsrc=size=320x240:rate=30:duration={DURATION_SECONDS}",
        "-i", str(aiff),
        "-af", "apad", "-t", str(DURATION_SECONDS),
        *vargs, *aargs,
        str(out),
    ], capture_output=True, text=True)
    aiff.unlink(missing_ok=True)
    if r.returncode != 0:
        raise RuntimeError(f"ffmpeg could not make the {shape} fixture: {r.stderr.strip()[-400:]}")
    return voice or "default"


def make_known_speech_mov(out: Path) -> str:
    """The default fixture: .mov, h264 + AAC."""
    return make_known_speech(out, DEFAULT_SHAPE)


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and sys.argv[2] not in SHAPES):
        print(__doc__ + "\nshapes: " + ", ".join(SHAPES), file=sys.stderr)
        sys.exit(2)
    print(make_known_speech(Path(sys.argv[1]), sys.argv[2] if len(sys.argv) == 3 else DEFAULT_SHAPE))
