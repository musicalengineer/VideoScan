#!/usr/bin/env python3
"""dossier_demo.py — watch the three dossier layers read ~10 family media files.

A live demo of docs/design/background_service.md Part A (§1–§5): for each file,
  Layer 1  technical facts read from the bytes (ffprobe, mediainfo, stat, dvrescue),
           each with one line on what it suggests (§1's "Tells us" column);
  Layer 2  perceptual answers from LOCAL models on a few stills and the first minute
           of sound (Qwen3-VL-8B-4bit, the era job's model; mlx_whisper if a model is
           already on disk), beside what the catalog already holds for the file;
  Layer 3  deterministic joins across the picked files (§3.4 capture setups, date
           windows bounded by a hard date, model era vs hard dates, §3.6 re-recording,
           event candidates), each with its evidence chain.
Then a summary table, timings, and a Markdown + HTML report.

RULES (CLAUDE.md): everything stays on this Mac (no network: the Hugging Face libraries
are forced offline before they load); the catalog is read only through
scripts/catalog_db.connect() (read-only by construction); media is opened for reading;
everything written (report, stills, temp audio) goes under <repo>/.scratch/dossier-demo/
(git-ignored). The model is shown pixels only, never the file's facts (DECISIONS
2026-10-31: told the codec, the 8B moved a 1965 film to 1975–1985). Nothing here writes
an observation: this is a demo of what the background service does, not a writer.

Order of work: the stages run stage by stage over all files (layer 1 for every file,
then the 8B over every file, then Whisper over every file) so each model is loaded once
and freed before the next one loads. A stage that fails on one file prints why and the
demo goes on.

Worst-case memory: the catalog records (catalog_db.records, ~25k small dicts, < 200 MB)
are dropped after the pick; the 8B ≈ 5.8 GB weights + MLX cache limit 512 MB + one
4-image generation (≈ 1.5k tokens of KV), freed before Whisper loads (≤ 1.6 GB for
large-v3-turbo); stills are 448-px JPEGs (≈ 40 KB each, ≤ 4 per file) on disk; the
HTML report embeds them (≤ 2 MB for 10 files). Media is streamed by ffmpeg/dvrescue,
never read into this process (the DV window copy is 1 MB chunks to a temp file).

Usage:
  venv-mlx/bin/python3 tools/dossier-demo/dossier_demo.py [--n 10] [--seed S]
      [--files A B C] [--skip-models] [--no-color]
"""
from __future__ import annotations

import argparse
import base64
import gc
import html
import json
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import time
from collections import defaultdict
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterable

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SCRIPTS = ROOT / "scripts"
BENCH_DIR = ROOT / "tools" / "video-llm-bench"
OUT_ROOT = ROOT / ".scratch" / "dossier-demo"
HF_HUB = Path.home() / ".cache" / "huggingface" / "hub"
QWEN_REPO_DIR = "models--mlx-community--Qwen3-VL-8B-Instruct-4bit"   # as BackgroundJob.swift's era job finds it
QWEN_LABEL = "Qwen3-VL-8B-Instruct-4bit"

STILLS = 4
MIN_DURATION_S = 3.0
WHISPER_SECONDS = 60
SETUP_PAD_YEARS = 2          # a camera/setup is in use for a few years: a hard date bounds its siblings ± this
EVENT_DAYS = 3               # two hard dates this close are "the same occasion" candidates
WORD_OVERLAP = 0.25          # Jaccard of scene words for "similar scene"

# ============================================================================ pure: vocabulary
# C++ reading: these are `static const std::map`s; the rules below are pure functions.

TRANSFER_CODECS = {"prores": "ProRes", "ffv1": "FFV1", "dnxhd": "DNxHD", "v210": "uncompressed 10-bit",
                   "rawvideo": "uncompressed", "huffyuv": "HuffYUV", "utvideo": "Ut Video", "qtrle": "QuickTime Animation"}
CODEC_WORDS = {
    "dvvideo": "DV: a MiniDV/Digital8 camcorder tape, or an analog tape through a DV bridge; carrier floor 1995",
    "mjpeg": "Motion JPEG: a late-1990s/2000s digital still camera's movie mode, or an analog capture card",
    "mpeg2video": "MPEG-2: DVD, a DVD camcorder or HDV (1996 onward)",
    "mpeg4": "MPEG-4 Part 2 (DivX/XviD, early digicams): 2000s",
    "h263": "H.263: early phone / web video, late 1990s–2000s",
    "svq3": "Sorenson Video 3: an early QuickTime export (2001–2006)",
    "svq1": "Sorenson Video 1: an early QuickTime export (late 1990s)",
    "h264": "H.264/AVC: 2004 onward (cameras, phones, exports); alone it does not date the footage",
    "hevc": "HEVC/H.265: 2013 onward; on an iPhone, 2017 onward",
    "wmv3": "Windows Media 9: a 2000s Windows export", "wmv2": "Windows Media 8: a 2000s Windows export",
    "vp6f": "VP6 Flash video: a 2000s web download", "msmpeg4v3": "DivX ;-) era MPEG-4: late 1990s–2000s",
    "rpza": "Apple Video (road pizza): early-1990s QuickTime", "cinepak": "Cinepak: early-1990s CD-ROM video",
    "gif": "an animated GIF, not a camera video",
}
CONTAINER_WORDS = {
    "dv": "raw DV stream: a direct FireWire capture from a camcorder or deck",
    "mov": "QuickTime wrapper: names the tool family (Apple, Final Cut, iMovie, a capture app), not the footage's age",
    "mp4": "MP4: a camera, a phone or an export (2001 onward)",
    "avi": "AVI: Windows-era capture or export (1990s–2000s tools)",
    "mxf": "MXF: a broadcast/NLE (Avid) wrapper: an edit-suite capture",
    "matroska": "Matroska: a modern archival transfer (usually FFV1)",
    "mpeg": "MPEG program stream: a DVD rip or a DVD camcorder",
    "mpegts": "MPEG transport stream: AVCHD or HDV camcorder",
    "3gp": "3GP: an early mobile phone (2003–2010)",
    "asf": "ASF/WMV: a 2000s Windows export",
    "flv": "Flash video: a 2000s web download",
}
EVENT_WORDS = ("birthday", "christmas", "thanksgiving", "easter", "halloween", "wedding", "graduation", "school",
               "sports", "vacation", "beach", "outdoors", "holiday", "party", "performance", "everyday", "unknown")
WEAK_EVENTS = {"unknown", "everyday", "outdoors"}
STOPWORDS = set("""a an the and or of in on at to with from by for is are was were be been this that these those
it its into over under near some several two three four one man woman people person child children kid kids boy girl
image images frame frames video scene appears appear seems shows showing shown visible there their they he she his her
while who which what as also other each very small large old young adult adults""".split())

# ============================================================================ pure: layer 1


def _num(value: Any) -> float | None:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _rate(text: Any) -> float | None:
    """'30000/1001' -> 29.97; '0/0' or junk -> None."""
    if not text or "/" not in str(text):
        return _num(text)
    num, _, den = str(text).partition("/")
    try:
        value = float(num) / float(den)
    except (ValueError, ZeroDivisionError):
        return None
    return round(value, 3) if 0 < value < 1000 else None


def parse_ffprobe(text: str) -> dict:
    """ffprobe -show_format -show_streams JSON -> the flat fact dict layer 1 interprets."""
    try:
        data = json.loads(text or "{}")
    except ValueError:
        return {}
    fmt = data.get("format") or {}
    streams = data.get("streams") or []
    video = next((s for s in streams if s.get("codec_type") == "video"
                  and not (s.get("disposition") or {}).get("attached_pic")), None)
    audio = [s for s in streams if s.get("codec_type") == "audio"]
    ftags = {k.lower(): v for k, v in (fmt.get("tags") or {}).items()}
    f: dict = {"container": str(fmt.get("format_name") or "").split(",")[0] or None,
               "duration": _num(fmt.get("duration")), "bit_rate": _num(fmt.get("bit_rate")),
               "has_video": video is not None}
    if video:
        vt = {k.lower(): v for k, v in (video.get("tags") or {}).items()}
        f.update(codec=video.get("codec_name"), profile=video.get("profile"),
                 width=video.get("width") or None, height=video.get("height") or None,
                 sar=video.get("sample_aspect_ratio"), dar=video.get("display_aspect_ratio"),
                 fps=_rate(video.get("r_frame_rate")), avg_fps=_rate(video.get("avg_frame_rate")),
                 field_order=video.get("field_order"), pix_fmt=video.get("pix_fmt"),
                 nb_frames=video.get("nb_frames"))
        for key in ("encoder", "creation_time"):
            ftags.setdefault(key, vt.get(key))
    if audio:
        first = audio[0]
        bits = first.get("bits_per_raw_sample") or first.get("bits_per_sample") or None
        f.update(audio_codec=first.get("codec_name"), audio_rate=int(_num(first.get("sample_rate")) or 0) or None,
                 audio_bits=int(_num(bits) or 0) or None,
                 audio_channels=sum(int(s.get("channels") or 0) for s in audio) or None,
                 audio_streams=len(audio))
    f["encoder"] = ftags.get("encoder") or ftags.get("com.apple.quicktime.software") or ftags.get("software")
    f["make"] = ftags.get("com.apple.quicktime.make") or ftags.get("make")
    f["model"] = ftags.get("com.apple.quicktime.model") or ftags.get("model")
    f["creation_time"] = ftags.get("creation_time")
    f["apple_creationdate"] = ftags.get("com.apple.quicktime.creationdate")
    f["location"] = bool(ftags.get("location") or ftags.get("com.apple.quicktime.location.iso6709"))
    return {k: v for k, v in f.items() if v not in (None, "", "unknown")} | {"has_video": f["has_video"]}


def parse_mediainfo(text: str) -> dict:
    """mediainfo --Output=JSON -> the few fields ffprobe does not give (measured scan, standard, recorded date)."""
    try:
        tracks = (json.loads(text or "{}").get("media") or {}).get("track") or []
    except (ValueError, AttributeError):
        return {}
    out: dict = {}
    for t in tracks:
        kind = t.get("@type")
        if kind == "General":
            for key, name in (("Recorded_Date", "mi_recorded_date"), ("Encoded_Application", "mi_application"),
                              ("Encoded_Library", "mi_library")):
                if t.get(key):
                    out[name] = str(t[key])
        elif kind == "Video" and "mi_scan_type" not in out:
            for key, name in (("ScanType", "mi_scan_type"), ("ScanOrder", "mi_scan_order"),
                              ("Standard", "mi_standard"), ("Format_Commercial_IfAny", "mi_commercial")):
                if t.get(key):
                    out[name] = str(t[key])
    return out


def sane_date(text: str | None, now: datetime | None = None) -> datetime | None:
    """An embedded date that could be a real date (EmbeddedDateSanity's rule): parses, not a sentinel
    (1904, 1970-01-01, 2000-01-01), not before 1980, not in the future. Else None."""
    if not text:
        return None
    now = now or datetime.now(timezone.utc)
    s = str(text).strip().replace("Z", "+00:00")
    when = None
    for candidate in (s, s[:19], s[:10]):
        try:
            when = datetime.fromisoformat(candidate)
            break
        except ValueError:
            continue
    if when is None:
        return None
    if when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc)
    if when.year < 1980 or when > now or when.strftime("%m-%d") == "01-01" and when.year in (1970, 2000):
        return None
    return when


def is_transfer(f: dict) -> bool:
    return str(f.get("codec") or "").lower() in TRANSFER_CODECS


def scan_of(f: dict) -> str | None:
    """interlaced / progressive: mediainfo's reading first, then ffprobe's flag."""
    mi = str(f.get("mi_scan_type") or "").lower()
    if mi:
        return "interlaced" if "interlaced" in mi or "mbaff" in mi else "progressive"
    fo = f.get("field_order")
    if fo in ("tt", "bb", "tb", "bt"):
        return "interlaced"
    if fo == "progressive":
        return "progressive"
    return None


def field_order_word(f: dict) -> str:
    order = str(f.get("mi_scan_order") or "").upper()
    fo = f.get("field_order")
    if order.startswith("TFF") or order == "TOP" or fo in ("tt", "tb"):
        return "top field first"
    if order.startswith("BFF") or order == "BOTTOM" or fo in ("bb", "bt"):
        return "bottom field first"
    return ""


def classify_creation_time(f: dict, now: datetime | None = None) -> tuple[str, str]:
    """(kind, why) for the embedded creation date. kind: none | rejected | transfer | capture | camera | weak.
    Only `camera` is a recording date (a hard date)."""
    raw = f.get("apple_creationdate") or f.get("creation_time")
    if not raw:
        return "none", "no embedded creation date"
    when = sane_date(raw, now)
    if when is None:
        return "rejected", f"{raw} is a sentinel or impossible date (1904/1970/2000-01-01, pre-1980 or future): not evidence"
    codec = str(f.get("codec") or "").lower()
    if codec in TRANSFER_CODECS:
        return "transfer", f"{TRANSFER_CODECS[codec]} files are transfers: {when:%Y-%m-%d} is when the carrier was digitised, not when it was shot"
    if codec == "dvvideo":
        return "capture", f"{when:%Y-%m-%d} is when the DV was copied to a computer; the DV clock (below) is the recording date"
    if f.get("apple_creationdate") or f.get("make") or f.get("model"):
        return "camera", f"camera-native file with device tags: {when:%Y-%m-%d} is the recording date"
    return "weak", f"{when:%Y-%m-%d} could be the camera's clock or an export; no device tag says which, so it is a weak date"


def interpret(f: dict, now: datetime | None = None) -> list[tuple[str, str, str]]:
    """Layer-1 facts -> [(label, value, what it suggests)], in §1's order. Pure."""
    rows: list[tuple[str, str, str]] = []
    container = str(f.get("container") or "")
    if container:
        rows.append(("container", container, CONTAINER_WORDS.get(container, "a wrapper: bounds the file's era, never the footage's")))
    codec = str(f.get("codec") or "").lower()
    if codec:
        word = (f"{TRANSFER_CODECS[codec]}: a lossless/master TRANSFER codec; says nothing about when the footage was shot"
                if codec in TRANSFER_CODECS else CODEC_WORDS.get(codec, "camera-native or export codec"))
        rows.append(("video codec", codec + (f" ({f['profile']})" if f.get("profile") else ""), word))
    elif not f.get("has_video"):
        rows.append(("video", "none", "no playable video stream: a reference movie, an essence-less MXF or audio only"))
    w, h = f.get("width"), f.get("height")
    if w and h:
        size = f"{w}×{h}"
        if (w, h) in ((720, 480), (720, 486), (704, 480)):
            s = "NTSC standard definition: analog or DV era (North America / Japan)"
        elif (w, h) in ((720, 576), (704, 576)):
            s = "PAL standard definition: a European/PAL-country source"
        elif (w, h) in ((352, 240), (352, 288)):
            s = "VCD resolution: a 1990s Video CD or a low-bit-rate copy"
        elif (w, h) in ((640, 480), (320, 240), (160, 120)):
            s = "VGA-class: a digital still camera / webcam movie mode (late 1990s–2000s)"
        elif h in (720, 1080) or (w, h) in ((1440, 1080),):
            s = ("HD frame holding a transfer: an SD tape upscaled at capture" if codec in TRANSFER_CODECS
                 else "HD: born-digital 2005 onward (AVCHD, HDV, phone)")
        elif h >= 2160:
            s = "4K/UHD: a 2014-onward phone or camera, or a modern film scan"
        else:
            s = "an uncommon size: an edit or web export"
        rows.append(("frame size", size, s))
    sar, dar = f.get("sar"), f.get("dar")
    if dar and dar not in ("0:1", "N/A"):
        square = sar in (None, "1:1", "0:1", "N/A")
        if dar in ("16:9",) and h and h <= 576:
            s = "16:9 standard definition: late DV / DVD era (2000s)"
        elif dar == "4:3" and not square:
            s = "4:3 with non-square pixels: SD video of the analog/DV era (pre-2010)"
        elif dar == "4:3":
            s = "4:3 square pixels: a computer/digicam frame or a re-scaled transfer"
        elif dar == "16:9":
            s = "16:9 HD"
        else:
            s = "an unusual aspect: a crop, a film ratio or an export"
        rows.append(("PAR / DAR", f"{sar or '?'} / {dar}", s))
    fps, avg = f.get("fps"), f.get("avg_fps")
    if fps:
        if abs(fps - 29.97) < 0.02 or abs(fps - 59.94) < 0.03:
            s = "NTSC timing (29.97): North American video"
        elif abs(fps - 25) < 0.01 or abs(fps - 50) < 0.01:
            s = "PAL timing (25): a PAL-country source"
        elif abs(fps - 23.976) < 0.01 or abs(fps - 24) < 0.01:
            s = "24 fps: a film scan or a modern cinema mode"
        elif fps in (18.0, 16.0):
            s = "16/18 fps: a native-rate film scan (8 mm / Super 8)"
        elif fps <= 15:
            s = "≤ 15 fps: an early webcam, digicam or phone"
        elif fps == 30:
            s = "30 fps exactly: a digicam, webcam or phone"
        else:
            s = "an uncommon rate"
        if avg and abs(avg - fps) / fps > 0.05:
            s += "; average differs from nominal: variable frame rate (a phone)"
        rows.append(("frame rate", f"{fps:g}" + (f" (avg {avg:g})" if avg and abs(avg - fps) > 0.01 else ""), s))
    scan = scan_of(f)
    if scan:
        order = field_order_word(f)
        if scan == "interlaced":
            s = "interlaced: analog tape or DV-era video (a camcorder, not a computer)"
        elif w and h and h <= 576 and codec not in ("mjpeg",):
            s = "progressive SD: a later re-encode or deinterlaced transfer (flags can lie after a re-encode)"
        else:
            s = "progressive: a digital camera, phone, film scan or export"
        src = "measured by mediainfo" if f.get("mi_scan_type") else "as flagged"
        rows.append(("scan", f"{scan}{', ' + order if order else ''} ({src})", s))
    if f.get("mi_standard"):
        rows.append(("standard", str(f["mi_standard"]), "the TV system the signal was recorded in"))
    acodec = str(f.get("audio_codec") or "").lower()
    if acodec:
        rate, bits, ch = f.get("audio_rate"), f.get("audio_bits"), f.get("audio_channels")
        value = f"{acodec} {rate or '?'} Hz {bits or '?'}-bit {ch or '?'} ch"
        if rate == 32000 and codec == "dvvideo":
            s = "32 kHz in DV: the camcorder's 12-bit 4-channel mode: a consumer DV/Digital8 camcorder"
        elif rate == 32000:
            s = "32 kHz: a DV 12-bit mode carried through a transfer"
        elif rate == 48000 and acodec.startswith("pcm"):
            s = "48 kHz PCM: DV 16-bit mode or any modern capture"
        elif rate == 44100:
            s = "44.1 kHz: a CD-era computer capture card or export"
        elif rate and rate <= 22050:
            s = "≤ 22 kHz: a web export, an early digicam or a phone"
        elif acodec in ("aac",):
            s = "AAC: a phone, a camera or an export"
        elif acodec in ("ac3",):
            s = "AC-3: DVD audio"
        else:
            s = "audio present"
        rows.append(("audio", value, s))
    elif f.get("has_video"):
        rows.append(("audio", "none", "silent file: a film scan, a video-only essence (its audio may be a sibling file)"))
    enc = f.get("encoder") or f.get("mi_application") or f.get("mi_library")
    if enc:
        e = str(enc).lower()
        if e.startswith("lavf") or "ffmpeg" in e:
            s = "ffmpeg (libavformat): a transfer or remux tool; one capture setup"
        elif "handbrake" in e:
            s = "HandBrake: a re-encode (a DVD rip or a downsized copy)"
        elif "imovie" in e or "final cut" in e or "quicktime" in e:
            s = "Apple editing/capture software: the file was made on a Mac"
        elif "avid" in e or "media composer" in e:
            s = "Avid: an edit-suite capture"
        else:
            s = "the tool that wrote the file: one capture setup"
        rows.append(("encoder / muxer", str(enc)[:60], s))
    if f.get("make") or f.get("model"):
        rows.append(("make / model", f"{f.get('make') or ''} {f.get('model') or ''}".strip(),
                     "the physical camera: a hardware lineage across years (§3.4)"))
    if f.get("location"):
        rows.append(("GPS", "present", "where it was filmed (a phone or GPS camera)"))
    kind, why = classify_creation_time(f, now)
    if kind != "none":
        rows.append(("creation_time", str(f.get("apple_creationdate") or f.get("creation_time"))[:25], why))
    if f.get("mi_recorded_date"):
        rows.append(("recorded date (mediainfo)", str(f["mi_recorded_date"])[:25], "read from the stream by mediainfo"))
    if f.get("duration"):
        mbps = (f.get("bit_rate") or 0) / 1e6
        if codec == "dvvideo" or codec in TRANSFER_CODECS:
            s = "high constant rate: a capture or master, not a distribution copy"
        elif mbps and w and h and h <= 576 and mbps < 4:
            s = "low bit rate SD: a distribution or web copy (a later generation)"
        else:
            s = "duration and rate"
        rows.append(("duration / rate", f"{f['duration']:.1f} s, {mbps:.1f} Mb/s", s))
    if f.get("mtime"):
        rows.append(("mtime", str(f["mtime"])[:10], "file-system date: the transfer/copy history only, never the shoot"))
    return rows


def one_liner(f: dict) -> str:
    """The layer-1 verdict in one line."""
    codec = str(f.get("codec") or "").lower()
    w, h = f.get("width"), f.get("height")
    size = f"{w}×{h}" if w and h else "?"
    scan = scan_of(f)
    if not f.get("has_video"):
        return "no playable video (reference movie / essence-less MXF / audio)"
    if codec == "dvvideo":
        std = "PAL" if h == 576 else "NTSC"
        mode = ", 12-bit 4-ch audio (consumer camcorder)" if f.get("audio_rate") == 32000 else ""
        return f"DV camcorder/deck capture, {std} {size}{mode}"
    if codec in TRANSFER_CODECS:
        return f"{TRANSFER_CODECS[codec]} transfer master {size}{' interlaced' if scan == 'interlaced' else ''}: carrier unknown"
    if f.get("make") or f.get("model"):
        return f"camera-native {codec} {size} from {(str(f.get('make') or '') + ' ' + str(f.get('model') or '')).strip()}"
    if codec == "mjpeg" and h and h <= 480:
        return f"digital still camera movie mode (Motion JPEG {size})"
    if codec == "mpeg2video" and h and h <= 576:
        return f"DVD / DVD-camcorder MPEG-2 {size}"
    return f"{codec or '?'} {size} {(f.get('fps') or 0):g} fps in {f.get('container') or '?'}"


# ============================================================================ pure: hard dates


def _year(text: str | None) -> int | None:
    m = re.match(r"(\d{4})", str(text or ""))
    return int(m.group(1)) if m else None


def hard_dates(item: dict, now: datetime | None = None) -> list[dict]:
    """The dates that are evidence, strongest first: Rick's date (a decision), the DV camcorder clock,
    a camera-native embedded date. Each {date, year, source, why}."""
    out = []
    if item.get("user_date"):
        out.append({"date": item["user_date"], "year": _year(item["user_date"]), "source": "Rick",
                    "why": "Rick's date (a decision)"})
    rdt = (item.get("rdt") or {}).get("rdt_first")
    if rdt:
        out.append({"date": rdt[:10], "year": _year(rdt), "source": "DV clock",
                    "why": "camcorder clock in every DV frame (dvrescue rdt): recorded no later than this"})
    f = item.get("facts") or {}
    kind, _ = classify_creation_time(f, now)
    if kind == "camera":
        when = sane_date(f.get("apple_creationdate") or f.get("creation_time"), now)
        out.append({"date": f"{when:%Y-%m-%d}", "year": when.year, "source": "camera tag",
                    "why": "camera-native embedded date with device tags"})
    return [d for d in out if d["year"]]


def best_hard(item: dict, now: datetime | None = None) -> dict | None:
    dates = hard_dates(item, now)
    return dates[0] if dates else None


# ============================================================================ pure: layer 2 parsing

ERA_PROMPT = (
    "These {n} images are frames from ONE home video, in time order.\n"
    "Look only at the pictures. Answer with ONLY this JSON object and nothing else:\n"
    '{{"scene": "TWO SENTENCES", "event": "EVENT", "setting": "SETTING", "visibleText": "TEXT", '
    '"dateOverlay": "DATE", "yearRange": [FROM_YEAR, TO_YEAR], "eraReason": "ONE SENTENCE"}}\n'
    "Rules: scene describes the people (apparent ages and roles), the place and what they are doing, "
    "never a person's name. EVENT is one of: " + ", ".join(EVENT_WORDS) + ". SETTING is one of indoor, outdoor, "
    "mixed, unknown. TEXT is any readable text (signs, banners, a cake, a screen) or NONE. DATE is a date or "
    "time burned into the picture by the camera, exactly as shown, or NONE. FROM_YEAR and TO_YEAR are integers "
    "from 1900 to 2100, FROM_YEAR not after TO_YEAR, estimated from picture quality, the camcorder's on-screen "
    "display, clothing, hairstyles, cars, technology and decor. eraReason names the cues you used."
)
ERA_MAX_TOKENS = 380
OCR_PROMPT_KEY = "date"   # bench.PROMPTS["date"]: the seated OCR prompt, one still per call


def parse_model_json(text: str) -> tuple[dict | None, str | None]:
    """The 8B's answer -> (fields, None) or (None, why). Fails closed on a bad yearRange;
    an event outside the vocabulary reads as 'unknown' (kept raw in event_raw)."""
    if not text:
        return None, "empty answer"
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end <= start:
        return None, "no JSON object in the answer"
    try:
        obj = json.loads(text[start:end + 1])
    except ValueError as e:
        return None, f"invalid JSON ({e.msg})"
    if not isinstance(obj, dict):
        return None, "answer is not an object"
    yr = obj.get("yearRange")
    if not (isinstance(yr, list) and len(yr) == 2 and all(isinstance(y, int) and not isinstance(y, bool) for y in yr)
            and 1900 <= yr[0] <= yr[1] <= 2100):
        return None, f"yearRange is not [from, to] years: {yr!r}"
    out = {"yearRange": (yr[0], yr[1])}
    for key in ("scene", "visibleText", "dateOverlay", "eraReason", "setting"):
        value = obj.get(key)
        out[key] = str(value).strip() if value is not None else ""
    event = str(obj.get("event") or "").strip().lower()
    out["event_raw"] = event
    out["event"] = event if event in EVENT_WORDS else "unknown"
    for key in ("visibleText", "dateOverlay"):
        if out[key].upper() in ("NONE", "N/A", "NULL", ""):
            out[key] = ""
    return out, None


_YEAR4 = re.compile(r"(?<!\d)(19[5-9]\d|20[0-3]\d)(?!\d)")


def ocr_years(answers: Iterable[str], parse_dates: Callable[[str], list] | None = None) -> list[int]:
    """Years cited by the per-still date OCR answers ('NONE' ignored); parse_dates (bench.py's) adds
    2-digit-year stamps like '12.25.97'."""
    years: list[int] = []
    for a in answers:
        if not a or a.strip().upper().startswith("NONE"):
            continue
        found = [int(d[:4]) for d in (parse_dates(a) if parse_dates else [])] or [int(y) for y in _YEAR4.findall(a)]
        years.extend(found)
    return years


def stamp_year(years: list[int]) -> int | None:
    """A burned-in year counts when two stills cite it (or the only still that answered)."""
    if not years:
        return None
    counts: dict[int, int] = defaultdict(int)
    for y in years:
        counts[y] += 1
    best = max(counts, key=lambda y: (counts[y], -y))
    return best if counts[best] >= 2 or len(years) == 1 else None


# ============================================================================ pure: layer 3


def encoder_family(enc: str | None) -> str:
    """'Lavf61.7.100' -> 'Lavf'; 'HandBrake 1.7.3' -> 'HandBrake'. Versions differ across one setup."""
    if not enc:
        return ""
    m = re.match(r"[A-Za-z][A-Za-z ._-]*?(?=[\s\d]|$)", str(enc).strip())
    return (m.group(0) if m else str(enc)).strip()


def setup_fingerprint(f: dict) -> tuple | None:
    """§3.4's capture-setup vector: codec, frame size, rate, scan, audio codec/rate/channels, encoder family,
    make/model. Exact equality, with the encoder's version dropped (a tolerance for tape captures)."""
    if not f or not f.get("codec"):
        return None
    return (str(f.get("codec")).lower(), f"{f.get('width')}x{f.get('height')}", f"{(f.get('fps') or 0):.2f}",
            scan_of(f) or "?", str(f.get("audio_codec") or "none"), int(f.get("audio_rate") or 0),
            int(f.get("audio_channels") or 0), encoder_family(f.get("encoder")),
            f"{f.get('make') or ''} {f.get('model') or ''}".strip())


def setup_label(fp: tuple) -> str:
    codec, size, fps, scan, acodec, arate, ach, enc, mm = fp
    parts = [codec, size, f"{float(fps):g} fps", scan]
    parts.append("silent" if acodec == "none" else f"{acodec} {arate // 1000 if arate else '?'} kHz {ach} ch")
    if enc:
        parts.append(enc)
    if mm:
        parts.append(mm)
    return " · ".join(parts)


def cluster_setups(items: list[dict]) -> list[dict]:
    """Group the files by setup fingerprint; [{fingerprint, label, members (indexes), transfer}], biggest first."""
    groups: dict[tuple, list[int]] = defaultdict(list)
    for i, it in enumerate(items):
        fp = setup_fingerprint(it.get("facts") or {})
        if fp:
            groups[fp].append(i)
    out = [{"fingerprint": fp, "label": setup_label(fp), "members": idx,
            "transfer": fp[0] in TRANSFER_CODECS} for fp, idx in groups.items()]
    return sorted(out, key=lambda c: (-len(c["members"]), c["label"]))


def setup_date_windows(items: list[dict], clusters: list[dict], pad: int = SETUP_PAD_YEARS,
                       now: datetime | None = None) -> list[dict]:
    """A hard date on one member bounds the others in its setup (§3.4 + §3.8), with the chain.
    A transfer setup bounds nothing (one transfer chain digitises tapes of any decade).
    -> [{setup, kind: 'window'|'consistent'|'outside'|'transfer', member, window, chain}]"""
    out = []
    for c in clusters:
        if len(c["members"]) < 2:
            continue
        anchors = [(i, best_hard(items[i], now)) for i in c["members"]]
        anchors = [(i, d) for i, d in anchors if d]
        if c["transfer"]:
            out.append({"setup": c["label"], "kind": "transfer", "member": None, "window": None,
                        "chain": [f"{items[i]['name']}" for i in c["members"]],
                        "note": "same transfer setup: one digitising session/tool, so it says nothing about when each tape was shot"})
            continue
        for i in c["members"]:
            others = [(k, d) for k, d in anchors if k != i]
            if not others:
                continue
            lo = min(d["year"] for _, d in others) - pad
            hi = max(d["year"] for _, d in others) + pad
            chain = [f"{items[k]['name']}: {d['source']} {d['date']}" for k, d in others]
            mine = best_hard(items[i], now)
            if mine is None:
                kind = "window"
            else:
                kind = "consistent" if lo <= mine["year"] <= hi else "outside"
                chain = chain + [f"{items[i]['name']} itself: {mine['source']} {mine['date']}"]
            out.append({"setup": c["label"], "kind": kind, "member": i, "window": (lo, hi), "chain": chain})
    return out


def era_vs_hard(items: list[dict], now: datetime | None = None) -> list[dict]:
    """Model era range vs the file's strongest hard date: agree (inside), near (≤ 2 y outside), disagree."""
    out = []
    for i, it in enumerate(items):
        era = (it.get("model") or {}).get("yearRange")
        hard = best_hard(it, now)
        if not era or not hard:
            continue
        lo, hi = era
        y = hard["year"]
        gap = 0 if lo <= y <= hi else (lo - y if y < lo else y - hi)
        verdict = "agree" if gap == 0 else ("near" if gap <= 2 else "disagree")
        out.append({"member": i, "era": (lo, hi), "hard": hard, "gap": gap, "verdict": verdict})
    return out


CARRIER_FLOOR = {"dvvideo": 1995, "hevc": 2013, "h264": 2004}


def re_recordings(items: list[dict], gap: int = 10) -> list[dict]:
    """§3.6: content older than its carrier. The model's era ends ≥ `gap` years before the DV clock or the
    carrier floor of a camera-native codec -> a transfer of older footage (film/tape through a camcorder)."""
    out = []
    for i, it in enumerate(items):
        f = it.get("facts") or {}
        rick = _year(it.get("user_date"))
        if rick and str(f.get("codec") or "").lower() == "dvvideo" and rick < CARRIER_FLOOR["dvvideo"]:
            out.append({"member": i, "era": None, "witness": f"Rick's date {it['user_date']}",
                        "note": f"Rick dates the content {rick}; DV did not exist before {CARRIER_FLOOR['dvvideo']}: "
                                "older footage (film or analog tape) transferred onto DV"})
            continue
        era = (it.get("model") or {}).get("yearRange")
        if not era:
            continue
        rdt = (it.get("rdt") or {}).get("rdt_first")
        if rdt and _year(rdt) - era[1] >= gap:
            out.append({"member": i, "era": era, "witness": f"DV clock {rdt[:10]}",
                        "note": f"picture says {era[0]}–{era[1]}, the camcorder clock says {rdt[:4]}: "
                                f"older footage re-recorded through a DV camcorder"})
            continue
        floor = CARRIER_FLOOR.get(str(f.get("codec") or "").lower())
        if floor and floor - era[1] >= gap and str(f.get("codec")).lower() == "dvvideo":
            out.append({"member": i, "era": era, "witness": f"DV carrier floor {floor}",
                        "note": f"picture says {era[0]}–{era[1]}, DV did not exist before {floor}: "
                                f"a transfer of older footage onto DV"})
    return out


def is_degenerate(text: str) -> bool:
    """bench.py's rule: ten or more of one punctuation glyph in a row is the 3B's failure mode, not a caption."""
    return bool(re.search(r"([^\w\s])\1{9,}", text or ""))


def scene_words(text: str) -> set[str]:
    return {w for w in re.findall(r"[a-z]{3,}", (text or "").lower()) if w not in STOPWORDS}


def jaccard(a: set, b: set) -> float:
    return len(a & b) / len(a | b) if a and b else 0.0


def _day(text: str | None) -> datetime | None:
    try:
        return datetime.strptime(str(text)[:10], "%Y-%m-%d")
    except (TypeError, ValueError):
        return None


def event_candidates(items: list[dict], now: datetime | None = None) -> list[dict]:
    """Pairs that may be one occasion: close in time (hard dates ≤ EVENT_DAYS apart, or the same folder) AND
    at least one more witness (same setup, same event word, similar scene words). Deterministic; each pair
    carries its reasons."""
    out = []
    fps = [setup_fingerprint(it.get("facts") or {}) for it in items]
    for i in range(len(items)):
        for j in range(i + 1, len(items)):
            a, b = items[i], items[j]
            reasons, close = [], False
            da, db = best_hard(a, now), best_hard(b, now)
            ta, tb = _day(da and da["date"]), _day(db and db["date"])
            if ta and tb and abs((ta - tb).days) <= EVENT_DAYS:
                close = True
                reasons.append(f"hard dates {da['date']} / {db['date']} within {EVENT_DAYS} days")
            if a.get("folder") and a.get("folder") == b.get("folder"):
                close = True
                reasons.append("same folder")
            if fps[i] and fps[i] == fps[j]:
                reasons.append("same capture setup")
            ea, eb = (a.get("model") or {}).get("event"), (b.get("model") or {}).get("event")
            if ea and ea == eb and ea not in WEAK_EVENTS:
                reasons.append(f"both look like '{ea}'")
            sim = jaccard(scene_words((a.get("model") or {}).get("scene", "")),
                          scene_words((b.get("model") or {}).get("scene", "")))
            if sim >= WORD_OVERLAP:
                reasons.append(f"scene words overlap {sim:.0%}")
            if close and len(reasons) >= 2:
                out.append({"pair": (i, j), "reasons": reasons})
    return out


# ============================================================================ pure: picking files


def container_short(container: str | None, ext: str | None) -> str:
    c = (container or "").lower()
    e = (ext or "").lower()
    if e in ("mp4", "m4v"):
        return "mp4"
    for key, short in (("quicktime", "mov"), ("dv (", "dv"), ("mxf", "mxf"), ("avi", "avi"), ("matroska", "mkv"),
                       ("mpeg-ts", "ts"), ("mpeg-ps", "mpg"), ("raw mpeg", "mpg"), ("asf", "wmv"), ("flv", "flv")):
        if key in c:
            return short
    return e or "?"


def codec_class(codec: str | None) -> str:
    c = (codec or "").lower()
    if c in ("dvvideo", "dv 25", "dv25", "dv 50", "dvcpro", "dvcpro50"):
        return "dv"
    if c == "mpeg2video":
        return "mpeg2"
    return c or "?"


PREFERRED_BUCKETS = [("dv", "dv"), ("mov", "prores"), ("mp4", "h264"), ("avi", "mjpeg"), ("mpg", "mpeg2"),
                     ("mxf", "dnxhd"), ("mkv", "ffv1"), ("mov", "hevc"), ("mov", "mjpeg"), ("mov", "dv"),
                     ("mov", "h264"), ("ts", "h264"), ("mxf", "dv"), ("mov", "svq3"), ("avi", "mpeg4")]


def record_decade(rec: dict) -> int | None:
    y = _year(rec.get("userDate"))
    if y is None and codec_class(rec.get("videoCodec")) not in ("prores", "ffv1", "dnxhd", "rawvideo", "dv"):
        y = _year(rec.get("embeddedCreationDate"))
    return y // 10 * 10 if y else None


# Not family footage, by name (a demo-pick heuristic, never a fact shown): software splash screens,
# partial downloads, samples.
JUNK_NAME = re.compile(r"(logo|splash|intro|trailer|sample|tutorial)(?![a-z])|\.part$", re.IGNORECASE)


def evidence_tier(rec: dict) -> int:
    """0: Rick dated it (surely family, and a truth to set beside the model); 1: a camera-native date; 2: other."""
    if rec.get("userDate"):
        return 0
    return 1 if record_decade(rec) is not None else 2


def plan_candidates(records: list[dict], seed: int) -> list[dict]:
    """Live video records (>= MIN_DURATION_S, not audio-only, not a junk name, one per digest), ordered
    tier by tier (evidence_tier) and, inside a tier, round-robin over (container, codec) buckets with the
    preferred buckets first. Pure."""
    rng = random.Random(seed)
    seen: set[str] = set()
    buckets: dict[tuple, list[dict]] = defaultdict(list)
    for rec in sorted(records, key=lambda r: str(r.get("fullPath") or "")):
        if rec.get("removal") is not None or not rec.get("fullPath"):
            continue
        if str(rec.get("streamTypeRaw") or "") not in ("Video+Audio", "Video only"):
            continue
        if (rec.get("durationSeconds") or 0) < MIN_DURATION_S or JUNK_NAME.search(Path(rec["fullPath"]).name):
            continue
        digest = (rec.get("contentFixity") or {}).get("sha256") or rec.get("fullPath")
        if digest in seen:
            continue
        seen.add(digest)
        buckets[(container_short(rec.get("container"), rec.get("ext")), codec_class(rec.get("videoCodec")))].append(rec)
    for recs in buckets.values():
        rng.shuffle(recs)
    rest = [k for k in buckets if k not in PREFERRED_BUCKETS]
    rng.shuffle(rest)
    order = [k for k in PREFERRED_BUCKETS if k in buckets] + rest
    out = []
    for tier in (0, 1, 2):
        lanes = {k: [r for r in buckets[k] if evidence_tier(r) == tier] for k in order}
        depth = 0
        while any(depth < len(lane) for lane in lanes.values()):
            for k in order:
                if depth < len(lanes[k]):
                    out.append(dict(lanes[k][depth], _bucket=k))
            depth += 1
    return out


def pick(candidates: list[dict], n: int, usable: Callable[[dict], bool]) -> list[dict]:
    """Three passes over the ordered candidates: (1) a new bucket, a new folder and a new decade; (2) a new
    folder; (3) anything. `usable` (the I/O check: reachable, decodable) is called at most once per candidate."""
    chosen: list[dict] = []
    tried: dict[int, bool] = {}
    buckets, folders, decades = set(), set(), set()

    def ok(idx: int) -> bool:
        if idx not in tried:
            tried[idx] = bool(usable(candidates[idx]))
        return tried[idx]

    rules = (lambda r: r["_bucket"] not in buckets and r.get("directory") not in folders
             and (record_decade(r) is None or record_decade(r) not in decades),
             lambda r: r.get("directory") not in folders,
             lambda r: True)
    taken: set[int] = set()
    for rule in rules:
        for idx, rec in enumerate(candidates):
            if len(chosen) >= n:
                return chosen
            if idx in taken or not rule(rec) or not ok(idx):
                continue
            taken.add(idx)
            chosen.append(rec)
            buckets.add(rec["_bucket"])
            folders.add(rec.get("directory"))
            if record_decade(rec) is not None:
                decades.add(record_decade(rec))
    return chosen


# ============================================================================ terminal


class Paint:
    """ANSI colour, off when not a terminal. C++ reading: a tiny struct of string-wrapping functions."""

    def __init__(self, on: bool):
        self.on = on

    def _w(self, code: str, s: str) -> str:
        return f"\033[{code}m{s}\033[0m" if self.on else s

    def b(self, s): return self._w("1", s)
    def dim(self, s): return self._w("2", s)
    def red(self, s): return self._w("31", s)
    def green(self, s): return self._w("32", s)
    def yellow(self, s): return self._w("33", s)
    def blue(self, s): return self._w("34", s)
    def mag(self, s): return self._w("35", s)
    def cyan(self, s): return self._w("36", s)


P = Paint(False)
WIDTH = 100


def say(s: str = "") -> None:
    print(s, flush=True)


def wrap(text: str, indent: str) -> str:
    return textwrap.fill(text, width=max(60, WIDTH), initial_indent=indent, subsequent_indent=indent + "  ")


def banner(title: str, color=None) -> None:
    color = color or P.cyan
    say()
    say(color("━" * min(WIDTH, 100)))
    say(color(P.b("  " + title)))
    say(color("━" * min(WIDTH, 100)))


class Clock:
    """Seconds per stage, summed across files."""

    def __init__(self):
        self.t: dict[str, float] = defaultdict(float)
        self.start = time.monotonic()

    @contextmanager
    def stage(self, name: str):
        t0 = time.monotonic()
        try:
            yield
        finally:
            self.t[name] += time.monotonic() - t0


# ============================================================================ I/O: tools


def tool(name: str) -> str | None:
    brewed = Path("/opt/homebrew/bin") / name
    return str(brewed) if brewed.exists() else shutil.which(name)


def run(cmd: list[str], timeout: float) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, check=False,
                          stdin=subprocess.DEVNULL, errors="replace")


def probe_facts(path: str) -> dict:
    """Layer 1 for one file: ffprobe (+ mediainfo when installed) + stat. Raises on no ffprobe answer."""
    r = run([tool("ffprobe") or "ffprobe", "-v", "error", "-show_format", "-show_streams", "-of", "json", path], 90)
    facts = parse_ffprobe(r.stdout)
    if not facts.get("container") and not facts.get("has_video"):
        raise RuntimeError((r.stderr.strip().splitlines() or ["ffprobe gave no answer"])[-1][:200])
    suffix = Path(path).suffix.lower().lstrip(".")
    if facts.get("container") == "mov" and suffix in ("mp4", "m4v", "3gp"):
        facts["container"] = "3gp" if suffix == "3gp" else "mp4"   # ffprobe names the whole ISO-BMFF family "mov"
    mi = tool("mediainfo")
    if mi:
        try:
            facts.update(parse_mediainfo(run([mi, "--Output=JSON", path], 60).stdout))
        except subprocess.TimeoutExpired:
            facts["mi_error"] = "mediainfo timed out"
    st = os.stat(path)
    facts["mtime"] = datetime.fromtimestamp(st.st_mtime).strftime("%Y-%m-%d %H:%M")
    facts["size"] = st.st_size
    return facts


def import_helpers():
    """scripts/dv_datecode.py and tools/video-llm-bench/bench.py, imported on demand (bench imports catalog_db)."""
    for p in (str(SCRIPTS), str(BENCH_DIR)):
        if p not in sys.path:
            sys.path.insert(0, p)
    import dv_datecode  # noqa: E402
    return dv_datecode


def bench_module():
    import_helpers()
    import bench  # noqa: E402
    return bench


def find_qwen() -> Path | None:
    snaps = HF_HUB / QWEN_REPO_DIR / "snapshots"
    names = sorted(p.name for p in snaps.iterdir()) if snaps.is_dir() else []
    for name in reversed(names):          # BackgroundJob.swift: names.max()
        if (snaps / name / "config.json").is_file():
            return snaps / name
    return None


WHISPER_PREFERENCE = ("whisper-small", "whisper-base", "whisper-large-v3-turbo", "whisper-medium", "whisper-tiny",
                      "whisper-large")


def find_whisper() -> tuple[str, Path] | None:
    """The smallest good mlx whisper model already on disk (never downloads)."""
    if not HF_HUB.is_dir():
        return None
    found = {}
    for repo in HF_HUB.glob("models--mlx-community--whisper-*"):
        snaps = repo / "snapshots"
        for snap in sorted(snaps.iterdir()) if snaps.is_dir() else []:
            if (snap / "config.json").is_file() and (any(snap.glob("*.npz")) or any(snap.glob("*.safetensors"))):
                found[repo.name.split("--")[-1]] = snap
    for pref in WHISPER_PREFERENCE:
        for name in sorted(found):
            if name.startswith(pref):
                return name, found[name]
    return None


# ============================================================================ I/O: catalog


def catalog_open():
    import_helpers()
    import catalog_db  # noqa: E402
    return catalog_db, catalog_db.connect()


def catalog_knows(conn, digest: str | None) -> dict:
    """What the background service and Rick already wrote for this content (read-only)."""
    if not digest:
        return {}
    q = lambda sql: [tuple(r) for r in conn.execute(sql, (digest,))]  # noqa: E731
    k: dict = {}
    pa = q("SELECT field, value, by, at FROM provenance_assertions WHERE subject_kind='content' AND subject_id=? ORDER BY seq")
    k["era_fused"] = [(v, by) for f, v, by, _ in pa if f == "era.fused"]
    k["era_windows"] = [v for f, v, _, _ in pa if f == "era.yearRange"]
    k["era_none"] = any(f == "era.none" for f, *_ in pa)
    k["ocr_dates"] = [v for f, v, _, _ in pa if f == "ocr.date"]
    k["rick_assertions"] = [(f, v) for f, v, by, _ in pa if by == "rick"]
    caps = q("SELECT kind, at_s, text FROM captions WHERE digest=? ORDER BY kind, seq")
    k["scene"] = [t for kind, _, t in caps if kind == "scene"]
    k["cap_ocr_date"] = [t for kind, _, t in caps if kind == "ocrDate"]
    k["cap_ocr_text"] = [t for kind, _, t in caps if kind == "ocrText"]
    tr = q("SELECT text, model FROM transcripts WHERE digest=?")
    k["transcript"] = tr[0] if tr else None
    people = q("SELECT name, kind FROM people_tags WHERE digest=? AND conflict=0")
    k["people_confirmed"] = sorted(n for n, kind in people if kind == "confirmed")
    k["people_machine"] = sum(1 for _, kind in people if kind in ("detected", "suspected"))
    inf = q("SELECT date_at, source, range_start, range_end, reason FROM inferred_dates WHERE digest=?")
    k["inferred"] = inf[0] if inf else None
    return k


# ============================================================================ the demo


class Demo:
    def __init__(self, args):
        self.args = args
        self.clock = Clock()
        self.items: list[dict] = []
        self.notes: list[str] = []          # stage-level failures and skips, for the report
        self.stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        self.out = OUT_ROOT / self.stamp
        self.frames = self.out / "frames"
        self.models_used: dict[str, str] = {}

    # ------------------------------------------------------------------ pick
    def choose(self) -> None:
        banner("VideoScan dossier demo — three layers, all local", P.mag)
        say(P.dim(f"  output (git-ignored): {self.out}"))
        say(P.dim("  privacy: no network; the catalog is opened read-only; media is only read"))
        records, conn = [], None
        try:
            with self.clock.stage("catalog read"):
                catalog_db, conn = catalog_open()
                records = catalog_db.records(conn)
            say(f"  catalog: {len(records):,} records read in {self.clock.t['catalog read']:.1f} s")
        except Exception as e:  # noqa: BLE001 — the demo still runs on --files without a catalog
            self.notes.append(f"catalog unavailable: {e}")
            say(P.red(f"  catalog unavailable ({e}); continuing without it"))
        self.conn = conn
        by_path = {r.get("fullPath"): r for r in records if r.get("fullPath")}
        dv = import_helpers()
        with self.clock.stage("pick files"):
            if self.args.files:
                chosen = []
                for p in self.args.files:
                    rec = dict(by_path.get(str(Path(p).resolve())) or by_path.get(p) or {})
                    rec.setdefault("fullPath", str(Path(p).resolve()))
                    chosen.append(rec)
            else:
                seed = self.args.seed
                say(f"  picking {self.args.n} files (seed {seed}; rerun with --seed {seed} for the same pick)")

                def usable(rec: dict) -> bool:
                    try:
                        if not dv._with_timeout(lambda: os.path.exists(rec["fullPath"]), 5):
                            return False
                        r = run([tool("ffprobe") or "ffprobe", "-v", "error", "-select_streams", "v:0", "-count_packets",
                                 "-read_intervals", "%+#5", "-show_entries", "stream=width,nb_read_packets", "-of", "json",
                                 rec["fullPath"]], 20)
                        s = (json.loads(r.stdout or "{}").get("streams") or [{}])[0]
                        return bool(s.get("width")) and int(s.get("nb_read_packets") or 0) > 0
                    except Exception:  # noqa: BLE001 — unreachable / stalled / undecodable: not a candidate
                        return False
                chosen = pick(plan_candidates(records, seed), self.args.n, usable)
        del records, by_path
        gc.collect()
        for rec in chosen:
            path = rec["fullPath"]
            self.items.append({
                "name": Path(path).name, "path": path, "folder": rec.get("directory") or str(Path(path).parent),
                "digest": (rec.get("contentFixity") or {}).get("sha256"),
                "user_date": rec.get("userDate"), "user_date_conf": rec.get("userDateConfidence"),
                "in_catalog": bool(rec.get("contentFixity") or rec.get("id")),
                "facts": {}, "interp": [], "rdt": None, "stills": [], "model": None, "ocr": [], "whisper": None,
                "known": {}, "errors": {}})
        say(f"  {len(self.items)} files (pick took {self.clock.t['pick files']:.1f} s):")
        for i, it in enumerate(self.items, 1):
            rd = f"  Rick's date {it['user_date']}" if it["user_date"] else ""
            say(f"   {i:>2}. {P.b(it['name'])}{P.green(rd)}")
        if not self.items:
            say(P.red("  nothing to analyse"))

    # ------------------------------------------------------------------ layer 1
    def layer1(self) -> None:
        banner("LAYER 1 — technical facts from the bytes (deterministic)")
        dv = import_helpers()
        tools = {"dvrescue": tool("dvrescue"), "ffmpeg": tool("ffmpeg")}
        with tempfile.TemporaryDirectory(prefix="dossier-dv-", dir=self._tmp_root()) as tmp:
            for n, it in enumerate(self.items, 1):
                say()
                say(P.b(P.blue(f"[{n}/{len(self.items)}] {it['name']}")))
                t0 = time.monotonic()
                try:
                    with self.clock.stage("layer 1 probe (ffprobe+mediainfo)"):
                        it["facts"] = probe_facts(it["path"])
                        it["interp"] = interpret(it["facts"])
                except Exception as e:  # noqa: BLE001
                    it["errors"]["probe"] = f"{type(e).__name__}: {e}"
                    say(P.red(f"   probe failed: {it['errors']['probe']}"))
                    continue
                for label, value, why in it["interp"]:
                    say(f"   {P.cyan(label.ljust(16))} {P.b(str(value))}")
                    say(P.dim(wrap("→ " + why, " " * 20)))
                if str(it["facts"].get("codec")).lower() == "dvvideo":
                    if not tools["dvrescue"]:
                        it["errors"]["dvrescue"] = "dvrescue not installed"
                    else:
                        with self.clock.stage("DV clock (dvrescue)"):
                            target = {"digest": it["digest"] or "-", "kind": "raw", "path": it["path"],
                                      "duration": it["facts"].get("duration")}
                            it["rdt"] = dv.probe(target, tools, full=False, timeout=60, tmp=Path(tmp))
                    self._say_rdt(it)
                say(P.yellow(f"   ⇒ {one_liner(it['facts'])}") + P.dim(f"   ({time.monotonic() - t0:.1f} s)"))

    def _say_rdt(self, it: dict) -> None:
        r = it.get("rdt") or {}
        label = P.cyan("DV clock".ljust(16))
        if r.get("status") == "rdt":
            first, last = r["rdt_first"], r["rdt_last"]
            span = f"{first} → {last}" if last and last != first else first
            my = r.get("mtime_year")
            lag = f"; {my - _year(first)} y before the file's mtime ({my}): copied later" if my and my > _year(first) else ""
            where = f"(dvrescue, {r.get('window')} window, {r.get('elapsed_s')} s)"
            say(f"   {label} {P.green(P.b(span))}  {P.dim(where)}")
            say(P.dim(wrap(f"→ the camcorder's clock when Record was pressed: the content is no later than this{lag}. "
                           "A DV clock dates the DV stream; footage re-recorded from film or VHS is older.", " " * 20)))
        elif r:
            why = {"no-rdt": "no recording date in the frames: an analog tape through a DV bridge, or a deck without a clock",
                   "implausible": "only impossible dates (1970 from a muxer, an unset clock): not evidence",
                   "not-dv": "the bytes are not DV after all", "timeout": "dvrescue timed out (slow volume)"}.get(
                r.get("status"), r.get("error") or r.get("status"))
            say(f"   {label} {P.yellow(str(r.get('status')))}")
            say(P.dim(wrap("→ " + why, " " * 20)))
        else:
            say(f"   {label} {P.red(it['errors'].get('dvrescue', 'not read'))}")

    # ------------------------------------------------------------------ layer 2: stills + 8B
    def _tmp_root(self) -> Path:
        tmp = self.out / "tmp"
        tmp.mkdir(parents=True, exist_ok=True)
        return tmp

    def rip_stills(self) -> None:
        bench = bench_module()
        say()
        say(P.b(f"  Ripping {STILLS} evenly spaced stills per file (448-px, letterboxed; the model's input)"))
        for n, it in enumerate(self.items, 1):
            dur = (it["facts"] or {}).get("duration") or 0
            if not it["facts"].get("has_video") or dur <= 0:
                it["errors"]["stills"] = "no video stream to rip"
                say(P.red(f"   [{n}] {it['name']}: no video stream to rip"))
                continue
            folder = self.frames / f"{n:02d}"
            folder.mkdir(parents=True, exist_ok=True)
            with self.clock.stage("rip stills (ffmpeg)"):
                for k, at in enumerate(bench.frames_evenly_spaced(STILLS, dur)):
                    dest = folder / f"still{k + 1}_{at:07.1f}s.jpg"
                    why = bench.rip_frame_why(it["path"], at, dest, dur)
                    if why is None:
                        it["stills"].append((round(at, 1), dest))
                    else:
                        it["errors"]["stills"] = why
            got = len(it["stills"])
            msg = f"   [{n}] {it['name']}: {got}/{STILLS} stills" + (
                f" at {', '.join(f'{t:g}s' for t, _ in it['stills'])}" if got else "")
            say(P.green(msg) if got else P.red(msg + f" ({it['errors'].get('stills')})"))

    def layer2_vision(self) -> None:
        banner("LAYER 2 — perceptual: what local models see and hear (pixels and sound only)")
        self.rip_stills()
        if self.args.skip_models:
            self.notes.append("models skipped (--skip-models)")
            say(P.yellow("  models skipped (--skip-models)"))
            self._say_known_all()
            return
        model_dir = find_qwen()
        if model_dir is None:
            self.notes.append(f"{QWEN_LABEL} is not on this Mac; vision stage skipped")
            say(P.red(f"  {QWEN_LABEL} not found under {HF_HUB / QWEN_REPO_DIR}; vision stage skipped"))
            self._say_known_all()
            return
        bench = bench_module()
        say()
        say(P.b(f"  Loading {QWEN_LABEL} (the era job's model; local snapshot, offline) …"))
        try:
            with self.clock.stage("8B load"):
                import mlx.core as mx
                from mlx_vlm import generate, load
                from mlx_vlm.prompt_utils import apply_chat_template
                mx.set_cache_limit(bench.MLX_CACHE_LIMIT_BYTES)
                model, processor = load(str(model_dir))
                config = getattr(model, "config", None)
        except Exception as e:  # noqa: BLE001
            self.notes.append(f"8B load failed: {type(e).__name__}: {e}")
            say(P.red(f"  8B load failed: {type(e).__name__}: {e}"))
            self._say_known_all()
            return
        self.models_used["vision"] = f"{QWEN_LABEL} ({model_dir.name[:12]})"
        say(P.dim(f"  loaded in {self.clock.t['8B load']:.1f} s"))

        def ask(images: list[Path], system: str, prompt: str, max_tokens: int) -> str:
            messages = [{"role": "system", "content": system}, {"role": "user", "content": prompt}]
            templated = apply_chat_template(processor, config, messages, num_images=len(images))
            result = generate(model, processor, templated, image=[str(p) for p in images], max_tokens=max_tokens,
                              temperature=0.0, top_p=1.0, verbose=False, prefill_step_size=bench.PREFILL_STEP_SIZE)
            return (result if isinstance(result, str) else getattr(result, "text", str(result))).strip()

        for n, it in enumerate(self.items, 1):
            say()
            say(P.b(P.blue(f"[{n}/{len(self.items)}] {it['name']}")))
            if it["stills"]:
                t0 = time.monotonic()
                try:
                    with self.clock.stage("8B inference"):
                        imgs = [p for _, p in it["stills"]]
                        raw = ask(imgs, bench.A1_SYSTEM_PROMPT, ERA_PROMPT.format(n=len(imgs)), ERA_MAX_TOKENS)
                        it["model_raw"] = raw
                        parsed, why = parse_model_json(raw)
                        if parsed is None:
                            it["errors"]["8B"] = f"answer not usable: {why}"
                        it["model"] = parsed
                        for at, p in it["stills"]:
                            it["ocr"].append((at, ask([p], bench.SYSTEM_PROMPT, bench.PROMPTS[OCR_PROMPT_KEY],
                                                     bench.GEN_PARAMS[OCR_PROMPT_KEY]["max_tokens"])))
                        mx.clear_cache()
                except Exception as e:  # noqa: BLE001
                    it["errors"]["8B"] = f"{type(e).__name__}: {e}"
                self._say_model(it, bench, time.monotonic() - t0)
            else:
                say(P.red(f"   no stills, so nothing for the model to look at ({it['errors'].get('stills', '?')})"))
            self._say_known(it)
        with self.clock.stage("8B free"):
            del model, processor, config
            gc.collect()
            mx.clear_cache()
        say(P.dim("\n  8B unloaded (memory returned before the next model)"))

    def _say_model(self, it: dict, bench, secs: float) -> None:
        m = it.get("model")
        tag = P.mag("8B (live)".ljust(16))
        if m:
            lo, hi = m["yearRange"]
            say(f"   {tag} {P.b('scene')}  " + wrap(m["scene"] or "—", "").replace("\n", "\n" + " " * 26))
            say(f"   {' ' * 16} {P.b('event')}  {m['event']}" + (f" (said '{m['event_raw']}')" if m["event"] != m["event_raw"] else "")
                + f"   {P.b('setting')} {m['setting'] or '—'}")
            say(f"   {' ' * 16} {P.b('text')}   {m['visibleText'] or 'none seen'}")
            say(f"   {' ' * 16} {P.b('date overlay')} {m['dateOverlay'] or 'none seen'}")
            say(f"   {' ' * 16} {P.b('era guess')} {P.yellow(P.b(f'{lo}–{hi}'))}  " + P.dim(m["eraReason"][:220]))
        elif it["errors"].get("8B"):
            say(f"   {tag} {P.red(it['errors']['8B'])}")
            if it.get("model_raw"):
                say(P.dim(wrap("raw: " + it["model_raw"][:240], " " * 20)))
        if it["ocr"]:
            years = ocr_years([a for _, a in it["ocr"]], bench.parse_dates)
            seen = [f"{at:g}s: {a[:40]}" for at, a in it["ocr"] if a and not a.upper().startswith("NONE")]
            sy = stamp_year(years)
            it["stamp_year"] = sy
            say(f"   {' ' * 16} {P.b('date OCR per still')} " + ("; ".join(seen) if seen else "NONE on every still")
                + (P.green(f"  → stamp year {sy}") if sy else ""))
        hard = best_hard(it)
        if m and hard:
            lo, hi = m["yearRange"]
            y = hard["year"]
            ok = lo <= y <= hi
            mark = P.green("inside the range") if ok else P.red(f"outside the range by {lo - y if y < lo else y - hi} y")
            say(f"   {' ' * 16} {P.b('vs hard date')} {hard['source']} {hard['date']}: {mark}")
        say(P.dim(f"   {' ' * 16} ({secs:.1f} s)"))

    def _say_known_all(self) -> None:
        for n, it in enumerate(self.items, 1):
            say()
            say(P.b(P.blue(f"[{n}/{len(self.items)}] {it['name']}")))
            self._say_known(it)

    def _say_known(self, it: dict) -> None:
        if not self.conn or not it.get("digest"):
            say(P.dim(f"   {'catalog'.ljust(16)} not in the catalog"))
            return
        try:
            with self.clock.stage("catalog lookups"):
                k = catalog_knows(self.conn, it["digest"])
        except Exception as e:  # noqa: BLE001
            say(P.red(f"   catalog lookup failed: {e}"))
            return
        for key in ("scene", "cap_ocr_text", "cap_ocr_date"):
            k[key + "_degenerate"] = sum(1 for t in k.get(key, []) if is_degenerate(t))
            k[key] = [t for t in k.get(key, []) if not is_degenerate(t)]
        it["known"] = k
        tag = P.green("catalog already".ljust(16))
        lines = []
        if it.get("user_date"):
            lines.append(f"Rick's date {it['user_date']}" + (f" ({it['user_date_conf']})" if it.get("user_date_conf") else ""))
        if k.get("era_fused"):
            v, by = k["era_fused"][-1]
            lines.append(f"machine era {v} (background service, {by.split(':', 1)[-1]}, unconfirmed; "
                         f"{len(k['era_windows'])} window answers)")
        elif k.get("era_none"):
            lines.append("background service looked: no era answer")
        else:
            lines.append("no machine era yet (the background service has not reached it)")
        if k.get("ocr_dates"):
            lines.append("machine OCR dates: " + ", ".join(k["ocr_dates"][:3]))
        if k.get("scene"):
            lines.append(f"{len(k['scene'])} scene captions, e.g. “{k['scene'][0][:140]}”")
        bad = k.get("scene_degenerate", 0) + k.get("cap_ocr_text_degenerate", 0)
        if bad:
            lines.append(f"{bad} old 3B caption(s) were junk ('!!!!…', #402) and are not shown")
        if k.get("cap_ocr_text"):
            lines.append("caption OCR text: " + "; ".join(t[:40] for t in k["cap_ocr_text"][:2]))
        if k.get("transcript"):
            text, model = k["transcript"]
            lines.append(f"transcript ({model or '?'}): " + (f"“{text[:120]}”" if text.strip() else "ran, no speech"))
        if k.get("people_confirmed") or k.get("people_machine"):
            lines.append(f"people: {len(k['people_confirmed'])} confirmed by Rick"
                         + (f" ({', '.join(k['people_confirmed'][:4])})" if k["people_confirmed"] else "")
                         + f", {k['people_machine']} machine face suggestions")
        if k.get("inferred") and k["inferred"][1]:
            lines.append(f"inferred date: {k['inferred'][1]} {k['inferred'][2] or ''}–{k['inferred'][3] or ''}".rstrip("–"))
        say(f"   {tag} " + lines[0])
        for line in lines[1:]:
            say(wrap(line, " " * 20))

    # ------------------------------------------------------------------ layer 2: sound
    def layer2_sound(self) -> None:
        if self.args.skip_models:
            return
        say()
        say(P.b("  Sound: Whisper on the first ≤ 60 s of each file"))
        found = find_whisper()
        if not found:
            msg = ("no mlx whisper model is downloaded on this Mac (~/.cache/huggingface/hub has none); "
                   "transcription skipped rather than downloading one. The catalog's own transcripts are shown above.")
            self.notes.append(msg)
            say(P.yellow(wrap(msg, "   ")))
            return
        name, snap = found
        try:
            with self.clock.stage("whisper load"):
                import mlx_whisper  # noqa: F401
        except Exception as e:  # noqa: BLE001
            self.notes.append(f"mlx_whisper import failed: {e}")
            say(P.red(f"   mlx_whisper import failed: {e}"))
            return
        self.models_used["sound"] = name
        say(P.dim(f"   model: {name} (local)"))
        ffmpeg = tool("ffmpeg") or "ffmpeg"
        with tempfile.TemporaryDirectory(prefix="dossier-audio-", dir=self._tmp_root()) as tmp:
            for n, it in enumerate(self.items, 1):
                if not (it["facts"] or {}).get("audio_codec"):
                    say(P.dim(f"   [{n}] {it['name']}: no audio stream"))
                    it["whisper"] = {"speech": "none", "why": "no audio stream"}
                    continue
                wav = Path(tmp) / f"{n:02d}.wav"
                try:
                    with self.clock.stage("whisper transcribe"):
                        r = run([ffmpeg, "-nostdin", "-v", "error", "-y", "-i", it["path"], "-t", str(WHISPER_SECONDS),
                                 "-vn", "-ac", "1", "-ar", "16000", str(wav)], 120)
                        if r.returncode != 0 or not wav.exists():
                            raise RuntimeError((r.stderr.strip().splitlines() or ["ffmpeg failed"])[-1][:160])
                        res = mlx_whisper.transcribe(str(wav), path_or_hf_repo=str(snap), verbose=None,
                                                     condition_on_previous_text=False)
                    segs = res.get("segments") or []
                    text = (res.get("text") or "").strip()
                    nsp = [s.get("no_speech_prob", 0) for s in segs]
                    speech = "speech" if text and (not nsp or sum(nsp) / len(nsp) < 0.6) else "none"
                    it["whisper"] = {"language": res.get("language"), "text": text, "speech": speech}
                    say(f"   [{n}] {it['name']}: {P.b(speech)} lang={res.get('language')} "
                        + (f"“{text[:150]}”" if speech == "speech" else ""))
                except Exception as e:  # noqa: BLE001
                    it["errors"]["whisper"] = f"{type(e).__name__}: {e}"
                    say(P.red(f"   [{n}] {it['name']}: whisper failed: {it['errors']['whisper']}"))
                finally:
                    if wav.exists():
                        wav.unlink()   # our own temp file under .scratch
        with self.clock.stage("whisper free"):
            gc.collect()
            try:
                import mlx.core as mx
                mx.clear_cache()
            except Exception:  # noqa: BLE001
                pass

    # ------------------------------------------------------------------ layer 3
    def layer3(self) -> dict:
        banner("LAYER 3 — across the files: deterministic joins, each with its evidence chain")
        with self.clock.stage("layer 3 joins"):
            clusters = cluster_setups(self.items)
            windows = setup_date_windows(self.items, clusters)
            eras = era_vs_hard(self.items)
            rerec = re_recordings(self.items)
            events = event_candidates(self.items)
        name = lambda i: self.items[i]["name"]  # noqa: E731
        say(P.b("\n  1. Capture setups (§3.4: the same technical fingerprint = one device chain)"))
        multi = [c for c in clusters if len(c["members"]) > 1]
        for c in clusters:
            members = ", ".join(name(i) for i in c["members"])
            line = f"   {'■' if len(c['members']) > 1 else '·'} {c['label']}" + (P.dim("  [transfer]") if c["transfer"] else "")
            say(P.yellow(line) if len(c["members"]) > 1 else line)
            say(P.dim(wrap(f"{len(c['members'])} file(s): {members}", "       ")))
        if not multi:
            say(P.dim("   every file has its own setup: no sibling to share a bound with"))
        say(P.b("\n  2. Date windows (a hard date on one member bounds its setup siblings, ±%d y)" % SETUP_PAD_YEARS))
        if not windows:
            say(P.dim("   none: no setup with two members and a hard date"))
        for w in windows:
            if w["kind"] == "transfer":
                say(f"   {P.yellow('transfer setup')} {w['setup']}: {w['note']}")
                continue
            lo, hi = w["window"]
            verdict = {"window": P.green(f"likely {lo}–{hi}"), "consistent": P.green(f"own date fits {lo}–{hi}"),
                       "outside": P.red(f"own date falls outside {lo}–{hi}")}[w["kind"]]
            say(f"   {name(w['member'])}: {verdict}")
            say(P.dim(wrap("chain: " + " ⟶ ".join(w["chain"]) + f" ⟶ same setup ({w['setup']})", "       ")))
        say(P.b("\n  3. The model's era vs the hard dates (the convergence check)"))
        if not eras:
            say(P.dim("   no file has both a model era and a hard date"))
        for e in eras:
            lo, hi = e["era"]
            col = {"agree": P.green, "near": P.yellow, "disagree": P.red}[e["verdict"]]
            say(f"   {name(e['member'])}: model {lo}–{hi} vs {e['hard']['source']} {e['hard']['date']} → "
                + col(e["verdict"] + (f" ({e['gap']} y off)" if e["gap"] else "")))
        if eras:
            agree = sum(1 for e in eras if e["verdict"] == "agree")
            say(P.dim(f"   {agree} of {len(eras)} inside the range (the catalog-wide figure is Catalog Status' convergence line)"))
        say(P.b("\n  4. Re-recordings (§3.6: content older than its carrier)"))
        if not rerec:
            say(P.dim("   none found among these files"))
        for r in rerec:
            say(f"   {name(r['member'])}: {P.red(r['note'])}  " + P.dim(f"[{r['witness']}]"))
        say(P.b("\n  5. Event candidates (close in time + the same setup / event / scene words)"))
        if not events:
            say(P.dim("   none: these files look like different occasions (expected for a spread-out pick)"))
        for ev in events:
            i, j = ev["pair"]
            say(f"   {name(i)} + {name(j)}: " + P.green("; ".join(ev["reasons"])))
        cats = defaultdict(list)
        for it in self.items:
            ev = (it.get("model") or {}).get("event")
            if ev:
                cats[ev].append(it["name"])
        if cats:
            say(P.dim("   event words the model used: " + ", ".join(f"{k} ×{len(v)}" for k, v in sorted(cats.items()))))
        say(P.b(f"\n  6. {len(self.items)} files is a tiny corpus"))
        for line in self.scale_note():
            say(wrap(line, "   "))
        return {"clusters": clusters, "windows": windows, "eras": eras, "rerec": rerec, "events": events}

    def scale_note(self) -> list[str]:
        ran = sum(1 for it in self.items if it.get("model") or it.get("ocr"))
        per_file = self.clock.t.get("8B inference", 0) / ran if ran else 7.0   # 7 s: the era job's measured rate (§4.3)
        hours = per_file * 20000 / 3600
        return [
            f"With {len(self.items)} files the joins have almost nothing to join: a setup needs siblings and an event "
            "needs neighbours in time. They are the same code at any size; what grows is the evidence.",
            "At ~20,000 files: the probe cache partitions the corpus into a few hundred capture setups (one camcorder, "
            "one transfer rig, one phone each), and every DV clock, camera tag and Rick's date in a setup bounds its "
            "undated siblings; the model's era gets a measured hit rate against all hard dates (the convergence line); "
            "re-recordings surface wherever the picture is a decade older than the DV clock; and files close in time on "
            "one setup become occasion candidates for Events, each with its chain.",
            f"Cost at that size: layer 1 is minutes; the 8B at {'this run' if ran else 'the era job'}'s {per_file:.1f} s per file would be ≈ "
            f"{hours:.0f} h of model time, which is why the background service runs it overnight, oldest first, once per signer.",
        ]

    # ------------------------------------------------------------------ summary + report
    def summary(self, l3: dict) -> list[list[str]]:
        banner("SUMMARY", P.mag)
        rows = []
        for i, it in enumerate(self.items, 1):
            m = it.get("model") or {}
            era = f"{m['yearRange'][0]}–{m['yearRange'][1]}" if m.get("yearRange") else "—"
            known = (it.get("known") or {}).get("era_fused")
            if known:
                era += f" (bg {known[-1][0]})"
            hard = best_hard(it)
            rows.append([str(i), it["name"], one_liner(it["facts"]) if it["facts"] else "probe failed",
                         era, f"{hard['date']} ({hard['source']})" if hard else "—", m.get("event") or "—"])
        heads = ["#", "file", "layer 1", "era guess (live / bg)", "hard date", "event"]
        caps = [3, 30, 52, 24, 24, 12]
        cut = lambda s, w: s if len(s) <= w else s[: w - 1] + "…"  # noqa: E731
        say(P.b("  " + "  ".join(h.ljust(w) for h, w in zip(heads, caps))))
        for r in rows:
            say("  " + "  ".join(cut(c, w).ljust(w) for c, w in zip(r, caps)))
        total = time.monotonic() - self.clock.start
        say(P.b(f"\n  Total {total:.1f} s") + P.dim(f" for {len(self.items)} files"))
        for k, v in self.clock.t.items():
            say(f"    {k.ljust(36)} {v:7.1f} s")
        if self.notes:
            say(P.yellow("\n  Notes:"))
            for nline in self.notes:
                say(wrap("- " + nline, "   "))
        return rows

    def write_reports(self, l3: dict, rows: list[list[str]]) -> tuple[Path, Path]:
        self.out.mkdir(parents=True, exist_ok=True)
        md, ht = self.out / "dossier.md", self.out / "dossier.html"
        md.write_text(render_markdown(self, l3, rows), encoding="utf-8")
        ht.write_text(render_html(self, l3, rows), encoding="utf-8")
        tmp = self.out / "tmp"
        if tmp.exists() and not any(tmp.iterdir()):
            tmp.rmdir()
        return md, ht


# ============================================================================ reports


def _layer3_lines(demo: Demo, l3: dict) -> list[tuple[str, list[str]]]:
    name = lambda i: demo.items[i]["name"]  # noqa: E731
    sections = []
    sections.append(("Capture setups", [f"{c['label']}{' [transfer]' if c['transfer'] else ''}: "
                                        + ", ".join(name(i) for i in c["members"]) for c in l3["clusters"]]))
    win = []
    for w in l3["windows"]:
        if w["kind"] == "transfer":
            win.append(f"transfer setup {w['setup']}: {w['note']}")
        else:
            win.append(f"{name(w['member'])}: {w['kind']} {w['window'][0]}–{w['window'][1]} — chain: " + " ⟶ ".join(w["chain"]))
    sections.append(("Date windows", win or ["none: no setup with two members and a hard date"]))
    sections.append(("Model era vs hard dates", [
        f"{name(e['member'])}: model {e['era'][0]}–{e['era'][1]} vs {e['hard']['source']} {e['hard']['date']} → {e['verdict']}"
        + (f" ({e['gap']} y)" if e["gap"] else "") for e in l3["eras"]] or ["no file has both"]))
    sections.append(("Re-recordings", [f"{name(r['member'])}: {r['note']} [{r['witness']}]" for r in l3["rerec"]] or ["none"]))
    sections.append(("Event candidates", [f"{name(e['pair'][0])} + {name(e['pair'][1])}: " + "; ".join(e["reasons"])
                                          for e in l3["events"]] or ["none"]))
    sections.append(("Scale", demo.scale_note()))
    return sections


def _known_lines(it: dict) -> list[str]:
    k = it.get("known") or {}
    out = []
    if k.get("era_fused"):
        out.append(f"machine era (background service): {k['era_fused'][-1][0]}")
    if k.get("ocr_dates"):
        out.append("machine OCR dates: " + ", ".join(k["ocr_dates"][:3]))
    if k.get("scene"):
        out.append(f"scene caption: {k['scene'][0][:200]}")
    if k.get("transcript"):
        out.append("transcript: " + (k["transcript"][0][:200] or "(no speech)"))
    if k.get("people_confirmed") or k.get("people_machine"):
        out.append(f"people: {len(k.get('people_confirmed') or [])} confirmed, {k.get('people_machine', 0)} machine suggestions")
    return out


def render_markdown(demo: Demo, l3: dict, rows: list[list[str]]) -> str:
    L = [f"# Dossier demo — {demo.stamp}", "",
         f"{len(demo.items)} files · models: {demo.models_used or 'none'} · local only", "",
         "## Summary", "", "| # | file | layer 1 | era guess (live / bg) | hard date | event |", "|---|---|---|---|---|---|"]
    L += ["| " + " | ".join(c.replace("|", "/") for c in r) + " |" for r in rows]
    for n, it in enumerate(demo.items, 1):
        L += ["", f"## {n}. {it['name']}", "", f"`{it['path']}`", "", "### Layer 1 — technical", "",
              "| fact | value | suggests |", "|---|---|---|"]
        L += [f"| {a} | {str(b).replace('|', '/')} | {c} |" for a, b, c in it["interp"]]
        r = it.get("rdt")
        if r:
            L.append(f"| DV clock | {r.get('rdt_first') or r.get('status')} | dvrescue rdt ({r.get('window') or '-'}) |")
        L += ["", f"**Verdict:** {one_liner(it['facts']) if it['facts'] else 'probe failed'}", "", "### Layer 2 — perceptual", ""]
        m = it.get("model")
        if m:
            L += [f"- scene: {m['scene']}", f"- event: {m['event']} · setting: {m['setting']}",
                  f"- visible text: {m['visibleText'] or 'none'}", f"- date overlay: {m['dateOverlay'] or 'none'}",
                  f"- era guess: {m['yearRange'][0]}–{m['yearRange'][1]} — {m['eraReason']}"]
        if it["ocr"]:
            L.append("- date OCR per still: " + "; ".join(f"{t:g}s {a[:40]}" for t, a in it["ocr"]))
        if it.get("whisper"):
            w = it["whisper"]
            L.append(f"- sound: {w.get('speech')} {w.get('language') or ''} {w.get('text', '')[:200]}")
        L += [f"- catalog: {x}" for x in _known_lines(it)]
        if it["stills"]:
            L.append("")
            L += [f"![{t:g}s]({p.relative_to(demo.out)})" for t, p in it["stills"]]
        if it["errors"]:
            L += ["", "Errors: " + "; ".join(f"{k}: {v}" for k, v in it["errors"].items())]
    L += ["", "## Layer 3 — across the files", ""]
    for title, lines in _layer3_lines(demo, l3):
        L += [f"### {title}", ""] + [f"- {x}" for x in lines] + [""]
    L += ["## Timings", "", "| stage | s |", "|---|---|"] + [f"| {k} | {v:.1f} |" for k, v in demo.clock.t.items()]
    L += ["", f"Total: {time.monotonic() - demo.clock.start:.1f} s"]
    if demo.notes:
        L += ["", "## Notes", ""] + [f"- {x}" for x in demo.notes]
    return "\n".join(L) + "\n"


def render_html(demo: Demo, l3: dict, rows: list[list[str]]) -> str:
    e = html.escape

    def img(p: Path) -> str:
        try:
            data = base64.b64encode(p.read_bytes()).decode("ascii")
        except OSError:
            return ""
        return f'<img src="data:image/jpeg;base64,{data}" alt="">'
    css = ("body{font:14px -apple-system,Helvetica,sans-serif;margin:24px;max-width:1200px;color:#222}"
           "table{border-collapse:collapse;margin:8px 0}td,th{border:1px solid #ccc;padding:4px 8px;vertical-align:top;text-align:left}"
           "th{background:#f3f3f3}.dim{color:#777}.stills img{width:224px;margin:2px;border:1px solid #ddd}"
           "h2{border-bottom:2px solid #446;padding-bottom:2px;margin-top:32px}.verdict{color:#a60;font-weight:bold}"
           "code{font-size:12px}")
    H = [f"<!doctype html><html><head><meta charset='utf-8'><title>Dossier demo {e(demo.stamp)}</title>"
         f"<style>{css}</style></head><body>", f"<h1>Dossier demo — {e(demo.stamp)}</h1>",
         f"<p class='dim'>{len(demo.items)} files · models: {e(str(demo.models_used or 'none'))} · local only</p>",
         "<h2>Summary</h2><table><tr>" + "".join(f"<th>{h}</th>" for h in
                                                ("#", "file", "layer 1", "era guess (live / bg)", "hard date", "event")) + "</tr>"]
    H += ["<tr>" + "".join(f"<td>{e(c)}</td>" for c in r) + "</tr>" for r in rows]
    H.append("</table>")
    for n, it in enumerate(demo.items, 1):
        H += [f"<h2>{n}. {e(it['name'])}</h2>", f"<p class='dim'><code>{e(it['path'])}</code></p>"]
        if it["stills"]:
            H.append("<div class='stills'>" + "".join(img(p) for _, p in it["stills"]) + "</div>")
        H.append("<h3>Layer 1 — technical</h3><table><tr><th>fact</th><th>value</th><th>suggests</th></tr>")
        H += [f"<tr><td>{e(a)}</td><td>{e(str(b))}</td><td>{e(c)}</td></tr>" for a, b, c in it["interp"]]
        r = it.get("rdt")
        if r:
            H.append(f"<tr><td>DV clock</td><td>{e(str(r.get('rdt_first') or r.get('status')))}</td><td>dvrescue rdt</td></tr>")
        H.append(f"</table><p class='verdict'>{e(one_liner(it['facts']) if it['facts'] else 'probe failed')}</p>")
        H.append("<h3>Layer 2 — perceptual</h3><ul>")
        m = it.get("model")
        if m:
            H += [f"<li><b>scene</b> {e(m['scene'])}</li>", f"<li><b>event</b> {e(m['event'])} · <b>setting</b> {e(m['setting'])}</li>",
                  f"<li><b>visible text</b> {e(m['visibleText'] or 'none')}</li>", f"<li><b>date overlay</b> {e(m['dateOverlay'] or 'none')}</li>",
                  f"<li><b>era guess</b> {m['yearRange'][0]}–{m['yearRange'][1]} — {e(m['eraReason'])}</li>"]
        if it["ocr"]:
            H.append("<li><b>date OCR per still</b> " + e("; ".join(f"{t:g}s {a[:40]}" for t, a in it["ocr"])) + "</li>")
        if it.get("whisper"):
            w = it["whisper"]
            H.append(f"<li><b>sound</b> {e(str(w.get('speech')))} {e(str(w.get('language') or ''))} {e(w.get('text', '')[:200])}</li>")
        H += [f"<li class='dim'>catalog: {e(x)}</li>" for x in _known_lines(it)]
        H.append("</ul>")
        if it["errors"]:
            H.append("<p class='dim'>errors: " + e("; ".join(f"{k}: {v}" for k, v in it["errors"].items())) + "</p>")
    H.append("<h2>Layer 3 — across the files</h2>")
    for title, lines in _layer3_lines(demo, l3):
        H += [f"<h3>{e(title)}</h3><ul>"] + [f"<li>{e(x)}</li>" for x in lines] + ["</ul>"]
    H.append("<h2>Timings</h2><table>" + "".join(f"<tr><td>{e(k)}</td><td>{v:.1f} s</td></tr>" for k, v in demo.clock.t.items())
             + f"<tr><th>total</th><th>{time.monotonic() - demo.clock.start:.1f} s</th></tr></table>")
    if demo.notes:
        H.append("<h2>Notes</h2><ul>" + "".join(f"<li>{e(x)}</li>" for x in demo.notes) + "</ul>")
    H.append("</body></html>")
    return "\n".join(H)


# ============================================================================ main


def main(argv: list[str] | None = None) -> int:
    global P, WIDTH
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--n", type=int, default=10, help="how many files to pick (default 10)")
    ap.add_argument("--seed", type=int, default=None, help="make the pick reproducible (printed when omitted)")
    ap.add_argument("--files", nargs="+", help="analyse these files instead of picking from the catalog")
    ap.add_argument("--skip-models", action="store_true", help="layers 1 and 3 only (no 8B, no Whisper)")
    ap.add_argument("--no-color", action="store_true")
    args = ap.parse_args(argv)
    if args.seed is None:
        args.seed = int(time.time()) % 100000
    # Offline before any Hugging Face library loads: nothing leaves this Mac.
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
    P = Paint(sys.stdout.isatty() and not args.no_color)
    WIDTH = min(110, shutil.get_terminal_size((110, 40)).columns - 2)

    demo = Demo(args)
    l3: dict = {"clusters": [], "windows": [], "eras": [], "rerec": [], "events": []}
    try:
        demo.choose()
        if demo.items:
            demo.layer1()
            demo.layer2_vision()
            demo.layer2_sound()
            l3 = demo.layer3()
    except KeyboardInterrupt:
        demo.notes.append("interrupted (Ctrl-C): the report holds what was done")
        say(P.yellow("\n  interrupted — writing what was done"))
    rows = demo.summary(l3)
    with demo.clock.stage("write report"):
        md, ht = demo.write_reports(l3, rows)
    if demo.conn is not None:
        demo.conn.close()
    say(P.b("\n  Report:"))
    say(f"    {md}")
    say(f"    {ht}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
