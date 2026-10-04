#!/usr/bin/env python3
"""Footage Spectrum — colour-over-time strips for a few videos, aligned on one time axis.

The helper behind the app's "Compare Footage…" (trial, 2026-10-03), promoted from
scripts/prototypes/footage_spectrum_proto.py with its behaviour kept. See
docs/design/footage_spectrum_design_2026-10-03.md.

Reads a JSON "sets" file. Each set is a REFERENCE and CANDIDATES. For every video it
extracts a colour-over-time strip ("spectrum" / movie barcode) and a sound band, aligns
each candidate with the reference, computes a per-second MATCH RIBBON, and writes ONE
self-contained local HTML page (set picker, play, blink comparator, verdicts).

    venv/bin/python scripts/footage_spectrum.py --sets SETS.json --out PAGE.html \
        --cache-dir DIR [--progress] [--refresh] [--png]

    SETS.json   [{title, note, files:[{label, path}], reference: <index, optional>}]
                (the reference is files[reference], default files[0])
    PAGE.html   the page (local file, no external requests)
    DIR         per-file strip + sound + viewer-frame cache, <key>.npz
                (key = hash of path + size + mtime; default: "cache" beside PAGE.html)

With --progress, stdout carries one machine-readable line per event, flushed, and the
human chatter moves to stderr:

    ESTIMATE {"files":[{"file":1,"label":"…","seconds":12.5,"duration":600.0,"codec":"h264","cached":false}],"total_seconds":12.5}
    PROGRESS {"file":1,"of":5,"label":"…","phase":"reading","fraction":0.42}
    PROGRESS {"file":5,"of":5,"label":"","phase":"aligning","fraction":0.0}
    PROGRESS {"file":5,"of":5,"label":"","phase":"writing","fraction":0.0}
    DONE {"html":"<path>","files":5,"skipped":[{"label":"…","reason":"…"}],
          "summary":{"same":3,"close":1,"part":0,"different":1,"covered":0.82},
          "results":[{"label":"…","verdict":"reference","offset":0}, …]}

and on failure, a non-zero exit after

    ERROR {"message":"…","missing":"numpy"|"ffmpeg"|"ffprobe"|null,"skipped":[…]}

A missing or unreadable file is skipped with a reason — never fatal. The run fails only
when fewer than two files of every set can be read.

The media files are only ever READ (ffprobe + one ffmpeg decode per file, output to the
cache folder and a pipe). No media path or name lives in this script.

Memory, worst case per file (one file at a time): the viewer frames (at most THUMB_CAP
JPEGs ≈ 6 MB), the columns (48 × 3 bytes per second ≈ 1 MB for two hours) and the mono
8 kHz sound read back from its temp file (2 bytes × 8000 per second ≈ 115 MB for two
hours, transformed 300 s at a time). The page embeds every file's frames as base64, so
eight two-hour files make a page of a few tens of MB.
"""
import argparse
import base64
import hashlib
import json
import math
import os
import shutil
import signal
import subprocess
import sys
import threading
import time

try:
    import numpy as np
except ImportError:  # reported as ERROR {"missing": "numpy"} by main()
    np = None

DEFAULT_OUT_DIR = os.path.expanduser("~/Library/Caches/VideoScan/spectrum")
ROWS = 48                  # colour bands per second-column
THUMB_W = 160              # default viewer-frame width (--thumb-width)
THUMB_Q = 6
THUMB_CAP = 1200
AUDIO_HZ = 8000
N_BANDS = 8
RIBBON_HALF_WINDOW = 2     # ± seconds
CACHE_VERSION = "v1"       # strips/sound (unchanged since v1 so old caches are reused)
GREEN = 0.85               # ribbon: same at or above
YELLOW = 0.60              # ribbon: close at or above
RIBBON_SCALE = 250         # ribbon bytes: 0…250 = similarity, 255 = the reference has nothing here
RIBBON_NONE = 255
PROGRESS_EVERY_S = 0.5

# Seconds of work per second of media — a first guess per codec so the job row can show
# "about N left" before anything has been measured. The app re-scales by the rate it
# actually observes; tune these from real runs.
CODEC_FACTOR = {
    "h264": 0.02, "hevc": 0.03, "mpeg2video": 0.02, "mpeg4": 0.02, "dvvideo": 0.03,
    "mjpeg": 0.04, "prores": 0.06, "dnxhd": 0.06, "rawvideo": 0.05, "ffv1": 0.15,
}
DEFAULT_FACTOR = 0.05
STARTUP_S = 0.5
CACHED_S = 0.1

FFMPEG = shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"
FFPROBE = shutil.which("ffprobe") or "/opt/homebrew/bin/ffprobe"

MACHINE = False            # --progress: machine lines on stdout, chatter on stderr
_child = None              # the ffmpeg in flight, so a Stop takes it down too


class Failure(Exception):
    """A run-ending problem with a friendly message (becomes the ERROR line)."""

    def __init__(self, message, code=1, missing=None):
        super().__init__(message)
        self.code = code
        self.missing = missing


# ------------------------------------------------------------------- reporting

def say(msg=""):
    """Human chatter: stdout normally, stderr when stdout is the machine channel."""
    print(msg, file=sys.stderr if MACHINE else sys.stdout, flush=True)


def machine_line(kind, payload):
    """One machine line, 7-bit only: the app's line reader decodes each pipe chunk on its
    own and a chunk that ends mid-character is lost, so non-ASCII is JSON-escaped."""
    return f"{kind} {json.dumps(payload, separators=(',', ':'), ensure_ascii=True)}"


def progress_line(file, of, label, phase, fraction):
    """One PROGRESS line. `fraction` is clamped to 0…1 and rounded to 3 places."""
    frac = 0.0 if fraction is None or fraction != fraction else max(0.0, min(1.0, float(fraction)))
    return machine_line("PROGRESS", {"file": int(file), "of": int(of), "label": label,
                                     "phase": phase, "fraction": round(frac, 3)})


def emit(line):
    if MACHINE:
        print(line, flush=True)


def fmt_size(nbytes):
    """'412 MB' under 1000 MB, then '1.25 GB' (two places under 10 GB, one above)."""
    mb = round(nbytes / 1e6)
    if mb < 1000:
        return f"{mb} MB"
    gb = nbytes / 1e9
    return f"{gb:.2f} GB" if gb < 10 else f"{gb:.1f} GB"


def fmt_t(t):
    neg = t < 0
    t = abs(int(round(t)))
    h, m, s = t // 3600, t % 3600 // 60, t % 60
    return ("-" if neg else "") + (f"{h}:{m:02d}:{s:02d}" if h else f"{m}:{s:02d}")


def estimate_seconds(duration, codec, cached=False):
    """How long reading one file should take, before anything is measured."""
    if cached:
        return CACHED_S
    return round(STARTUP_S + max(0.0, duration) * CODEC_FACTOR.get(codec, DEFAULT_FACTOR), 1)


# ----------------------------------------------------------------- extraction

def probe(path):
    out = subprocess.run(
        [FFPROBE, "-v", "error", "-show_entries",
         "format=duration:stream=codec_type,codec_name,width,height",
         "-of", "json", path], capture_output=True, text=True).stdout
    j = json.loads(out or "{}")
    v = [s for s in j.get("streams", []) if s.get("codec_type") == "video"]
    a = [s for s in j.get("streams", []) if s.get("codec_type") == "audio"]
    if not v:
        raise RuntimeError("no video stream")
    return {
        "duration": float(j.get("format", {}).get("duration", 0) or 0),
        "codec": v[0].get("codec_name", "?"),
        "width": v[0].get("width", 0), "height": v[0].get("height", 0),
        "audio": a[0].get("codec_name") if a else None,
    }


def split_jpegs(blob):
    """Split a concatenated MJPEG byte stream on SOI/EOI markers."""
    out, pos = [], 0
    while True:
        s = blob.find(b"\xff\xd8\xff", pos)
        if s < 0:
            break
        nxt = blob.find(b"\xff\xd9\xff\xd8\xff", s)
        if nxt < 0:
            e = blob.rfind(b"\xff\xd9")
            if e > s:
                out.append(blob[s:e + 2])
            break
        out.append(blob[s:nxt + 2])
        pos = nxt + 2
    return out


def progress_seconds(text):
    """Media seconds done, from the tail of an ffmpeg `-progress` file (None = not yet known)."""
    best = None
    for line in text.splitlines():
        key, _, value = line.partition("=")
        if key.strip() in ("out_time_us", "out_time_ms"):   # both are microseconds
            try:
                best = int(value.strip()) / 1e6
            except ValueError:
                pass
    return best


def _read_tail(path, nbytes=4096):
    try:
        with open(path, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            fh.seek(max(0, size - nbytes))
            return fh.read().decode("utf8", "replace")
    except OSError:
        return ""


def single_pass(path, info, step, tmp, hwaccel, tw, limit_s=0, on_progress=None):
    """ONE ffmpeg decode per file: columns -> tmp file, audio -> tmp file, viewer frames -> stdout.

    `limit_s` > 0 gives up after that many seconds (0 = no limit). `on_progress(fraction)`
    is called about twice a second with the share of the file's length decoded so far.
    """
    global _child
    cols_tmp, aud_tmp, err_tmp, prog_tmp = tmp + ".cols", tmp + ".pcm", tmp + ".err", tmp + ".prog"
    fc = (f"[0:v:0]fps=1,split=2[a][b];[a]scale=1:{ROWS}:flags=area[c];"
          f"[b]select='not(mod(n\\,{step}))',scale={tw}:-2[t]")
    cmd = [FFMPEG, "-v", "error", "-nostdin", "-progress", prog_tmp, "-stats_period", "0.5"]
    if hwaccel:
        cmd += ["-hwaccel", "videotoolbox"]
    cmd += ["-i", path, "-filter_complex", fc,
            "-map", "[c]", "-f", "rawvideo", "-pix_fmt", "rgb24", "-y", cols_tmp,
            "-map", "[t]", "-fps_mode", "passthrough", "-c:v", "mjpeg",
            "-q:v", str(THUMB_Q), "-f", "image2pipe", "-"]
    if info["audio"]:
        cmd += ["-map", "0:a:0", "-vn", "-ac", "1", "-ar", str(AUDIO_HZ), "-f", "s16le", "-y", aud_tmp]
    t0 = last_said = time.time()
    chunks, timed_out = [], False
    dur = max(info["duration"], 0.001)
    try:
        with open(err_tmp, "wb") as ef:
            p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=ef)
            _child = p

            def drain():
                while True:
                    b = p.stdout.read(1 << 16)
                    if not b:
                        break
                    chunks.append(b)

            reader = threading.Thread(target=drain, daemon=True)
            reader.start()
            while p.poll() is None:
                time.sleep(PROGRESS_EVERY_S / 2)
                now = time.time()
                done = progress_seconds(_read_tail(prog_tmp))
                if done is not None and on_progress:
                    on_progress(min(1.0, done / dur))
                if now - last_said > 10:
                    last_said = now
                    say(f"      … {int(done or 0)}/{int(info['duration'])} s of video, {now - t0:.0f} s elapsed")
                if limit_s and now - t0 > limit_s:
                    p.kill()
                    timed_out = True
                    break
            rc = p.wait()
            reader.join(timeout=10)
            _child = None
        err = open(err_tmp, "rb").read().decode("utf8", "replace").strip()
        cols = np.fromfile(cols_tmp, dtype=np.uint8) if os.path.exists(cols_tmp) else np.zeros(0, np.uint8)
        pcm = np.fromfile(aud_tmp, dtype="<i2") if (info["audio"] and os.path.exists(aud_tmp)) else None
    finally:
        _child = None
        for f in (cols_tmp, aud_tmp, err_tmp, prog_tmp):
            if os.path.exists(f):
                os.remove(f)
    if timed_out:
        return None, "timeout"
    if rc != 0 or cols.size < ROWS * 3:
        return None, (err or f"ffmpeg exit {rc}")[:300]
    T = cols.size // (ROWS * 3)
    return (cols[:T * ROWS * 3].reshape(T, ROWS, 3), split_jpegs(b"".join(chunks)), pcm), None


def sound_features(pcm, T):
    """Per-second loudness (dB-ish) and an 8-band log-spaced coarse spectrum."""
    loud = np.zeros(T, np.float32)
    bands = np.zeros((T, N_BANDS), np.float32)
    if pcm is None or pcm.size < AUDIO_HZ:
        return loud, bands, False
    n = min(T, pcm.size // AUDIO_HZ)
    edges = np.round(np.logspace(math.log10(80), math.log10(AUDIO_HZ / 2), N_BANDS + 1)).astype(int)
    win = np.hanning(AUDIO_HZ).astype(np.float32)
    for s in range(0, n, 300):
        e = min(n, s + 300)
        x = pcm[s * AUDIO_HZ:e * AUDIO_HZ].astype(np.float32).reshape(e - s, AUDIO_HZ)
        loud[s:e] = 20 * np.log10(np.sqrt((x * x).mean(axis=1)) + 1.0)
        mag = np.abs(np.fft.rfft(x * win, axis=1))  # 1 Hz per bin
        for b in range(N_BANDS):
            bands[s:e, b] = np.log10(1.0 + mag[:, edges[b]:edges[b + 1]].mean(axis=1))
    return loud, bands, True


def file_key(path):
    st = os.stat(path)
    return hashlib.sha1(f"{CACHE_VERSION}|{path}|{st.st_size}|{int(st.st_mtime)}".encode()).hexdigest()[:16], st.st_size


def load_cached(path, cache_dir):
    """The cached extraction of `path`, or None (absent, older format, or unreadable)."""
    key, size = file_key(path)
    npz = os.path.join(cache_dir, key + ".npz")
    if not os.path.exists(npz):
        return None
    try:
        z = np.load(npz, allow_pickle=False)
        if "thumb_blob" not in z.files:
            return None
        d = {k: z[k] for k in ("cols", "loud", "bands", "thumb_blob", "thumb_offs")}
        d["meta"] = json.loads(str(z["meta"]))
    except Exception:  # noqa: BLE001 — a damaged cache entry is simply re-made
        return None
    d["meta"].setdefault("size", size)
    d.update(key=key, cached=True)
    return d


def extract(path, cache_dir, refresh, tw, info=None, limit_s=0, on_progress=None):
    if not refresh:
        d = load_cached(path, cache_dir)
        if d is not None:
            return d
    key, size = file_key(path)
    os.makedirs(cache_dir, exist_ok=True)
    npz = os.path.join(cache_dir, key + ".npz")
    info = info or probe(path)
    dur = info["duration"]
    step = 2 if dur < 180 else 5
    step = max(step, math.ceil(dur / THUMB_CAP))
    tmp = os.path.join(cache_dir, key + ".tmp")
    t0 = time.time()
    method = "single pass, VideoToolbox decode, 1 sample/s"
    res, err = single_pass(path, info, step, tmp, True, tw, limit_s, on_progress)
    if res is None and err != "timeout":
        say(f"      hwaccel pass failed ({err[:120]}); retrying in software")
        method = "single pass, software decode, 1 sample/s"
        res, err = single_pass(path, info, step, tmp, False, tw, limit_s, on_progress)
    if res is None:
        raise RuntimeError("too slow for a single pass — skipped" if err == "timeout" else err)
    cols, thumbs, pcm = res
    T = cols.shape[0]
    loud, bands, has_audio = sound_features(pcm, T)
    thumbs = thumbs[:THUMB_CAP]
    offs = np.cumsum([0] + [len(t) for t in thumbs]).astype(np.int64)
    blob = np.frombuffer(b"".join(thumbs), np.uint8)
    meta = dict(info, T=T, thumb_step=step, thumb_w=tw, method=method, extract_seconds=round(time.time() - t0, 1),
                has_audio=bool(has_audio), size=size)
    # Written beside its final name, then renamed: a Stop mid-write never leaves a half entry.
    part = os.path.join(cache_dir, key + ".part.npz")
    try:
        np.savez_compressed(part, cols=cols, loud=loud, bands=bands, thumb_blob=blob, thumb_offs=offs,
                            meta=np.array(json.dumps(meta)))
        os.replace(part, npz)
    finally:
        if os.path.exists(part):
            os.remove(part)
    return dict(cols=cols, loud=loud, bands=bands, thumb_blob=blob, thumb_offs=offs, meta=meta, key=key, cached=False)


# ------------------------------------------------------------------ alignment

def band_feature(cols):
    T = cols.shape[0]
    return cols.astype(np.float32).reshape(T, 8, ROWS // 8, 3).mean(axis=2).reshape(T, 24)


def unit_rows(x):
    """Mean-remove per file, L2-normalise per second (used for the offset SEARCH)."""
    x = x - x.mean(axis=0, keepdims=True)
    n = np.linalg.norm(x, axis=1, keepdims=True)
    return np.where(n > 1e-6, x / np.maximum(n, 1e-6), 0.0).astype(np.float32)


def slide(A, B):
    """Slide the shorter B along the longer A. Offset = where B's 0:00 sits on A's timeline (s)."""
    N, M = len(A), len(B)
    minov = min(M, max(10, math.ceil(0.3 * M)))
    offs = np.arange(-(M - minov), N - minov + 1)
    sc = np.empty(len(offs), np.float32)
    for i, o in enumerate(offs):
        a0, a1 = max(0, o), min(N, o + M)
        sc[i] = float((A[a0:a1] * B[a0 - o:a1 - o]).sum()) / (a1 - a0)
    bi = int(np.argmax(sc))
    best = int(offs[bi])
    excl = max(3, min(30, round(0.05 * M)))
    mask = np.abs(offs - best) > excl
    nxt = float(sc[mask].max()) if mask.any() else None
    a0, a1 = max(0, best), min(N, best + M)
    return {"offset": best, "overlap": int(a1 - a0), "score": round(float(sc[bi]), 3),
            "next": None if nxt is None else round(nxt, 3)}


def ribbon(ref_feat, cand_feat, off, wobble=0):
    """Per-second similarity of the candidate to the reference at the aligned position.

    Mean is removed over the OVERLAP only (so material outside it — a blue-screen tail — cannot
    shift the score), then a windowed normalised correlation over ±RIBBON_HALF_WINDOW seconds.
    `wobble` lets each second pick its best local shift within ±wobble s (different transfers of
    one tape drift by a second or two). Returns (values for every candidate second, NaN where the
    reference has nothing; overall score = correlation over the whole overlap).
    """
    Tr, Tc = len(ref_feat), len(cand_feat)
    out = np.full(Tc, np.nan, np.float32)
    c0, c1 = max(0, -off), min(Tc, Tr - off)
    if c1 - c0 < 3:
        return out, 0.0
    r = ref_feat[c0 + off:c1 + off]
    c = cand_feat[c0:c1]
    r = r - r.mean(axis=0, keepdims=True)
    c = c - c.mean(axis=0, keepdims=True)
    n = c1 - c0
    k = np.ones(2 * RIBBON_HALF_WINDOW + 1, np.float32)
    cc = np.convolve((c * c).sum(axis=1), k, "same")
    best = np.full(n, -1.0, np.float32)
    for d in range(-wobble, wobble + 1):
        rs = np.zeros_like(r)
        if d >= 0:
            rs[:n - d] = r[d:]
        else:
            rs[-d:] = r[:n + d]
        num = np.convolve((rs * c).sum(axis=1), k, "same")
        den = np.sqrt(np.convolve((rs * rs).sum(axis=1), k, "same") * cc)
        best = np.maximum(best, np.where(den > 1e-3, num / np.maximum(den, 1e-3), 0.0))
    out[c0:c1] = np.clip(best, 0, 1)
    whole = float((r * c).sum() / max(1e-6, math.sqrt(float((r * r).sum()) * float((c * c).sum()))))
    return out, whole


# ------------------------------------------------------- ribbon -> words (pure)
#
# The page classifies the ribbon in its own script (it has the tuning sliders); these are
# the same rules at the default thresholds, so the app's one-line summary and the page's
# chips agree. Both read the QUANTISED ribbon (one byte per second).

def quantize_ribbon(rib):
    """Similarity 0…1 -> bytes 0…RIBBON_SCALE; NaN (the reference has nothing) -> RIBBON_NONE."""
    return np.where(np.isnan(rib), RIBBON_NONE, np.round(np.nan_to_num(rib) * RIBBON_SCALE)).astype(np.uint8)


def classify_second(v, green=GREEN, yellow=YELLOW):
    """One ribbon byte -> 'none' | 'same' | 'close' | 'diff'."""
    if v == RIBBON_NONE:
        return "none"
    if v >= green * RIBBON_SCALE:
        return "same"
    if v >= yellow * RIBBON_SCALE:
        return "close"
    return "diff"


def verdict(q, ref_T, green=GREEN, yellow=YELLOW):
    """A candidate's quantised ribbon -> {'cls': 'same'|'close'|'part'|'diff', 'share', 'ref_cov', 'close'}."""
    T = len(q)
    if T == 0:
        return {"cls": "diff", "share": 0.0, "ref_cov": 0.0, "close": 0.0}
    valid = q != RIBBON_NONE
    ng = int((valid & (q >= green * RIBBON_SCALE)).sum())
    ny = int((valid & (q >= yellow * RIBBON_SCALE) & (q < green * RIBBON_SCALE)).sum())
    share, ref_cov = ng / T, ng / max(ref_T, 1)
    if share >= 0.9 or ref_cov >= 0.95:
        cls = "same"
    elif (ng + ny) / T >= 0.75:
        cls = "close"
    elif share >= 0.15:
        cls = "part"
    else:
        cls = "diff"
    return {"cls": cls, "share": share, "ref_cov": ref_cov, "close": ny / T}


def coverage_ranges(candidates, ref_T, yellow=YELLOW, join_gap=30, min_len=30):
    """Which stretches of the reference the candidates match (same or close) between them.

    `candidates` = [(quantised ribbon, offset)]. Runs closer than `join_gap` s are merged;
    merged runs shorter than `min_len` s are dropped. Returns [(start, end)] in reference seconds.
    """
    hit = np.zeros(ref_T, bool)
    for q, off in candidates:
        t = np.nonzero((q != RIBBON_NONE) & (q >= yellow * RIBBON_SCALE))[0] + off
        t = t[(t >= 0) & (t < ref_T)]
        hit[t] = True
    runs, start = [], -1
    for t in range(ref_T + 1):
        on = t < ref_T and hit[t]
        if on and start < 0:
            start = t
        elif not on and start >= 0:
            runs.append([start, t])
            start = -1
    merged = []
    for a, b in runs:
        if merged and a - merged[-1][1] <= join_gap:
            merged[-1][1] = b
        else:
            merged.append([a, b])
    return [(a, b) for a, b in merged if b - a >= min_len]


# ---------------------------------------------------------------------- facts

def drive_of(path):
    parts = path.split("/")
    if len(parts) > 2 and parts[1] == "Volumes":
        return parts[2]
    if "/Library/Caches/" in path:
        return "this Mac (cache)"
    return "this Mac"


def role_hint(codec, size, dur):
    mbps = size * 8 / max(dur, 1) / 1e6
    name = {"prores": "ProRes", "ffv1": "FFV1 lossless", "hevc": "HEVC", "h264": "H.264", "dvvideo": "DV",
            "mjpeg": "MJPEG", "rawvideo": "uncompressed", "dnxhd": "DNxHD"}.get(codec, codec)
    if codec in ("ffv1", "rawvideo"):
        return f"large ({name}) — looks like a preservation master"
    if codec in ("prores", "dnxhd"):
        return f"large ({name}) — looks like a master/editable copy"
    if codec == "dvvideo":
        return f"medium ({name}) — looks like a tape transfer or an edit export"
    if codec in ("hevc", "h264"):
        return f"small ({name}) — looks like an access copy" if mbps < 12 else f"({name}) — looks like a camera file or export"
    if codec == "mjpeg" and mbps < 3:
        return f"tiny ({name}) — looks like a proxy/thumbnail movie"
    return name


# ----------------------------------------------------------------------- sets

def ordered_files(s):
    """A set's files with its reference first (`reference` = index into files, default 0)."""
    files = list(s.get("files", []))
    ref = s.get("reference", 0)
    if isinstance(ref, int) and 0 < ref < len(files):
        files.insert(0, files.pop(ref))
    return files


def plan_sets(sets_in, cache_dir, refresh):
    """Look at every file once (stat + ffprobe, or its cache entry): what can be read, and how long.

    Returns (plans, skipped): plans = [{set, members:[{file, info, cached}]}] and
    skipped = [{label, reason}]. Nothing is decoded here.
    """
    plans, skipped, seen = [], [], {}
    for s in sets_in:
        members = []
        for f in ordered_files(s):
            p = f["path"]
            if p in seen:
                if seen[p] is not None:
                    members.append(seen[p] | {"file": f})
                continue
            if not os.path.isfile(p):
                skipped.append({"label": f["label"], "reason": "the file is missing or its drive is not connected"})
                seen[p] = None
                continue
            try:
                cached = None if refresh else load_cached(p, cache_dir)
                info = cached["meta"] if cached else probe(p)
            except Exception as e:  # noqa: BLE001 — one unreadable file never ends the run
                skipped.append({"label": f["label"], "reason": f"could not be read ({str(e)[:120]})"})
                seen[p] = None
                continue
            seen[p] = {"info": info, "cached": cached is not None}
            members.append(seen[p] | {"file": f})
        plans.append({"set": s, "members": members})
    return plans, skipped


# ----------------------------------------------------------------------- main

def b64(a):
    return base64.b64encode(np.ascontiguousarray(a).tobytes()).decode()


def write_png(path, rgb):
    h, w, _ = rgb.shape
    subprocess.run([FFMPEG, "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24",
                    "-s", f"{w}x{h}", "-i", "-", "-frames:v", "1", path],
                   input=rgb.astype(np.uint8).tobytes(), check=True)


def render_png(path, strips, width=1400, sh=48, rh=10, gap=8):
    """Check rendering: strips stacked at their aligned offsets, match ribbon under each candidate."""
    gmin = min(o for _, o, _ in strips)
    gmax = max(o + c.shape[0] for c, o, _ in strips)
    img = np.full((len(strips) * (sh + rh + gap) + gap, width, 3), 46, np.uint8)
    g = gmin + (np.arange(width) + 0.5) * (gmax - gmin) / width
    for i, (c, o, rib) in enumerate(strips):
        t = np.floor(g - o).astype(int)
        ok = (t >= 0) & (t < c.shape[0])
        y = gap + i * (sh + rh + gap)
        img[y:y + sh, ok] = c[t[ok]].transpose(1, 0, 2)
        if rib is not None:
            v = rib[t[ok]]
            col = np.where(np.isnan(v)[:, None], [120, 120, 120],
                           np.where((v >= GREEN)[:, None], [46, 158, 79],
                                    np.where((v >= YELLOW)[:, None], [224, 176, 0], [214, 69, 69])))
            img[y + sh:y + sh + rh, ok] = col
    write_png(path, img)


def parse_args(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--sets", default=os.path.join(DEFAULT_OUT_DIR, "sets.json"))
    ap.add_argument("--out", default=os.path.join(DEFAULT_OUT_DIR, "spectrum.html"))
    ap.add_argument("--cache-dir", default=None, help="per-file extraction cache (default: 'cache' beside --out)")
    ap.add_argument("--progress", action="store_true", help="machine-readable PROGRESS / DONE / ERROR lines on stdout")
    ap.add_argument("--refresh", action="store_true", help="ignore the per-file caches")
    ap.add_argument("--png", action="store_true", help="also write set_N.png check renderings")
    ap.add_argument("--thumb-width", type=int, default=THUMB_W, help="viewer-frame width for NEW extractions")
    ap.add_argument("--wobble", type=int, default=2, help="± seconds of local drift the match ribbon tolerates")
    ap.add_argument("--single-pass-limit", type=int, default=0,
                    help="give up on a file after this many seconds (0 = no limit)")
    ap.add_argument("--ffmpeg", default=None, help="path to ffmpeg (default: PATH, then Homebrew)")
    ap.add_argument("--ffprobe", default=None, help="path to ffprobe (default: PATH, then Homebrew)")
    return ap.parse_args(argv)


def run(args):
    global FFMPEG, FFPROBE
    if np is None:
        raise Failure("numpy is not installed in this Python — the comparison cannot run", code=3, missing="numpy")
    FFMPEG, FFPROBE = args.ffmpeg or FFMPEG, args.ffprobe or FFPROBE
    for tool, path in (("ffmpeg", FFMPEG), ("ffprobe", FFPROBE)):
        if not (os.path.isfile(path) and os.access(path, os.X_OK)):
            raise Failure(f"{tool} was not found — the comparison cannot read video without it", code=3, missing=tool)

    out_dir = os.path.dirname(os.path.abspath(args.out))
    cache_dir = args.cache_dir or os.path.join(out_dir, "cache")
    try:
        sets_in = json.load(open(args.sets))
    except (OSError, ValueError) as e:
        raise Failure(f"the list of files to compare could not be read ({e})", code=2)
    os.makedirs(cache_dir, exist_ok=True)
    os.makedirs(out_dir, exist_ok=True)

    plans, skipped = plan_sets(sets_in, cache_dir, args.refresh)
    todo, order = [], {}
    for plan in plans:
        for m in plan["members"]:
            p = m["file"]["path"]
            if p not in order:
                order[p] = len(todo) + 1
                todo.append(m)
    n_files = len(todo)
    estimates = [{"file": i + 1, "label": m["file"]["label"], "duration": round(m["info"]["duration"], 1),
                  "codec": m["info"]["codec"], "cached": m["cached"],
                  "seconds": estimate_seconds(m["info"]["duration"], m["info"]["codec"], m["cached"])}
                 for i, m in enumerate(todo)]
    emit(machine_line("ESTIMATE", {"files": estimates, "total_seconds": round(sum(e["seconds"] for e in estimates), 1)}))

    files, thumbsets, ex, sets_out, results = {}, {}, {}, [], []
    tally = {"same": 0, "close": 0, "part": 0, "different": 0}
    covered = []
    for si, plan in enumerate(plans):
        s = plan["set"]
        say(f"\n=== Set {si + 1}: {s['title']}")
        members = []
        for m in plan["members"]:
            f, p = m["file"], m["file"]["path"]
            i = order[p]
            if p not in ex:
                say(f"   extracting {f['label']} …")
                emit(progress_line(i, n_files, f["label"], "reading", 0.0))
                last = [0.0]

                def tick(fraction, i=i, label=f["label"], last=last):
                    now = time.time()
                    if now - last[0] >= PROGRESS_EVERY_S:
                        last[0] = now
                        emit(progress_line(i, n_files, label, "reading", fraction))

                try:
                    ex[p] = extract(p, cache_dir, args.refresh, args.thumb_width,
                                    info=None if m["cached"] else m["info"],
                                    limit_s=args.single_pass_limit, on_progress=tick)
                except Exception as e:  # noqa: BLE001 — report, leave it out, carry on
                    say(f"   FAILED {f['label']}: {e}")
                    skipped.append({"label": f["label"], "reason": f"could not be read ({str(e)[:160]})"})
                    ex[p] = None
                emit(progress_line(i, n_files, f["label"], "reading", 1.0))
            d = ex[p]
            if d is None:
                continue
            mt = d["meta"]
            say(f"   {f['label']:<40} T={mt['T']:>5}  dur={mt['duration']:.1f}s  {mt['codec']}"
                f"  {mt['width']}x{mt['height']}  {fmt_size(mt['size'])}  audio={'yes' if mt['has_audio'] else 'none'}"
                f"  extract={mt['extract_seconds']}s{' (cached)' if d['cached'] else ''}  [{mt['method']}]")
            members.append((f, d))
        if len(members) < 2:
            say("   set skipped — fewer than two of its files could be read")
            continue

        emit(progress_line(n_files, n_files, "", "aligning", 0.0))
        raw = [band_feature(d["cols"]) for _, d in members]
        pf = [unit_rows(x) for x in raw]
        sf = [unit_rows(d["bands"]) if d["meta"]["has_audio"] else None for _, d in members]
        n = len(members)
        short = [f["label"].split(" ")[0] for f, _ in members]

        # every candidate against the reference (index 0)
        offsets, scores, ribbons = [0] * n, [None] * n, [None] * n
        pairs, quantised = [], []
        results.append({"label": members[0][0]["label"], "verdict": "reference", "offset": 0})
        for j in range(1, n):
            a, b = (0, j) if len(pf[0]) >= len(pf[j]) else (j, 0)
            pic = slide(pf[a], pf[b])
            snd = slide(sf[a], sf[b]) if (sf[a] is not None and sf[b] is not None) else None
            off = pic["offset"] if a == 0 else -pic["offset"]
            rib, whole = ribbon(raw[0], raw[j], off, args.wobble)
            offsets[j], scores[j], ribbons[j] = off, round(whole, 3), rib
            pic["whole"] = round(whole, 3)
            pairs.append({"a": a, "b": b, "pic": pic, "snd": snd})
            T = len(rib)
            q = quantize_ribbon(rib)
            v = verdict(q, len(raw[0]))
            quantised.append((q, off))
            tally[{"diff": "different"}.get(v["cls"], v["cls"])] += 1
            results.append({"label": members[j][0]["label"], "verdict": v["cls"], "offset": int(off)})
            g, y = float((rib >= GREEN).sum()) / T, float(((rib >= YELLOW) & (rib < GREEN)).sum()) / T
            say(f"   {short[0]} <-> {short[j]}: search {pic['score']:.2f} at {off:+d} s ({fmt_t(off)}) "
                f"(overlap {pic['overlap']} s; next best {pic['next']}) · over the overlap {whole:.3f} · "
                f"ribbon green {g:.0%} yellow {y:.0%} · covers {(rib >= GREEN).sum() / len(raw[0]):.0%} of the reference"
                + (f" · sound {snd['score']:.2f} at {snd['offset'] if a == 0 else -snd['offset']:+d} s (next {snd['next']})" if snd else " · sound n/a"))
        ref_T = len(raw[0])
        covered.append(sum(b - a for a, b in coverage_ranges(quantised, ref_T)) / max(ref_T, 1))
        # the rest of the pair table (candidate vs candidate), for the Numbers drawer
        if n <= 6:
            for i in range(1, n):
                for j in range(i + 1, n):
                    a, b = (i, j) if len(pf[i]) >= len(pf[j]) else (j, i)
                    pairs.append({"a": a, "b": b, "pic": slide(pf[a], pf[b]),
                                  "snd": slide(sf[a], sf[b]) if (sf[a] is not None and sf[b] is not None) else None})

        out_files = []
        for idx, (f, d) in enumerate(members):
            key, m = d["key"], d["meta"]
            if key not in files:
                cols = d["cols"]
                luma = cols.astype(np.float32) @ np.array([0.299, 0.587, 0.114], np.float32)
                cut = np.zeros(m["T"], np.float32)
                cut[1:] = np.abs(cols[1:].astype(np.int16) - cols[:-1].astype(np.int16)).mean(axis=(1, 2))
                loud, bands = d["loud"], d["bands"]
                if m["has_audio"]:
                    lo, hi = np.percentile(loud, 2), np.percentile(loud, 99.5)
                    loud = np.clip((loud - lo) / max(hi - lo, 1e-6), 0, 1)
                    lo, hi = np.percentile(bands, 5), np.percentile(bands, 99.5)
                    bands = np.clip((bands - lo) / max(hi - lo, 1e-6), 0, 1)
                files[key] = {
                    "name": os.path.basename(f["path"]), "T": m["T"], "dur": m["duration"],
                    "codec": m["codec"], "w": m["width"], "h": m["height"],
                    "hasAudio": m["has_audio"], "method": m["method"], "sec": m["extract_seconds"],
                    "drive": drive_of(f["path"]), "gb": round(m["size"] / 1e9, 2), "mb": round(m["size"] / 1e6),
                    "role": role_hint(m["codec"], m["size"], m["duration"]),
                    "lo": float(np.percentile(luma, 1)), "hi": float(np.percentile(luma, 99)),
                    "cols": b64(cols), "cut": b64(cut.astype("<f4")),
                    "loud": b64((loud * 255).astype(np.uint8)), "bands": b64((bands * 255).astype(np.uint8)),
                }
            tk = key
            if tk not in thumbsets:
                blob, to = d["thumb_blob"].tobytes(), d["thumb_offs"]
                thumbsets[tk] = {"step": m["thumb_step"], "phase": 0, "w": m.get("thumb_w", 160),
                                 "jpg": [base64.b64encode(blob[to[k]:to[k + 1]]).decode() for k in range(len(to) - 1)]}
            rib = ribbons[idx]
            out_files.append({
                "label": f["label"], "key": key, "thumbs": tk, "offset": offsets[idx], "score": scores[idx],
                "ribbon": None if rib is None else b64(quantize_ribbon(rib)),
            })
        sets_out.append({"title": s["title"], "note": s.get("note", ""), "grid": 0, "gridBase": 0,
                         "files": out_files, "pairs": pairs})
        if args.png:
            png = os.path.join(out_dir, f"set_{si + 1}.png")
            render_png(png, [(d["cols"], offsets[i], ribbons[i]) for i, (_, d) in enumerate(members)])
            say(f"   check rendering: {png}")

    if not sets_out:
        failure = Failure("fewer than two of the files could be read, so there is nothing to compare", code=4)
        failure.skipped = skipped
        raise failure

    emit(progress_line(n_files, n_files, "", "writing", 0.0))
    data = {
        "files": files, "thumbs": thumbsets, "sets": sets_out,
        "params": {
            "picture": f"1 sample per second, each a column of {ROWS} colour bands (ffmpeg fps=1, scale=1:{ROWS} area-averaged)",
            "frames": f"JPEG every 5 s (2 s for clips under 3 min), q:v {THUMB_Q}, {args.thumb_width} px wide for new extractions (older caches: 160 px)",
            "sound": f"mono {AUDIO_HZ} Hz; per second: loudness + {N_BANDS} log-spaced bands, normalised per file",
            "align": "8 bands × RGB per second; offset search: mean-removed per file, cosine, shorter slid along longer "
                     "(overlap ≥ max(10 s, 30 % of the shorter))",
            "ribbon": f"at the best offset: mean removed over the overlap, correlation in a ±{RIBBON_HALF_WINDOW} s window, "
                      f"best local shift within ±{args.wobble} s",
            "script": os.path.abspath(__file__),
            "built": time.strftime("%Y-%m-%d %H:%M"),
        },
    }
    here = os.path.dirname(os.path.abspath(__file__))
    html = open(os.path.join(here, "footage_spectrum_page.html")).read()
    payload = json.dumps(data, separators=(",", ":")).replace("</", "<\\/")
    part = args.out + ".part"
    with open(part, "w") as fh:
        fh.write(html.replace("/*__DATA__*/", payload))
    os.replace(part, args.out)   # the page appears whole, or not at all
    say(f"\nwrote {args.out}  ({os.path.getsize(args.out) / 1e6:.1f} MB)")
    say(f"open {args.out}")
    summary = dict(tally, covered=round(sum(covered) / len(covered), 3))
    emit(machine_line("DONE", {"html": os.path.abspath(args.out), "files": sum(len(s["files"]) for s in sets_out),
                               "skipped": skipped, "summary": summary, "results": results}))
    return 0


def _stop(signum, _frame):
    """Stop (SIGTERM from the app) or Ctrl-C: take the ffmpeg in flight down too, then leave."""
    child = _child
    if child is not None and child.poll() is None:
        child.kill()
    raise SystemExit(128 + signum)


def main(argv=None):
    global MACHINE
    args = parse_args(argv)
    MACHINE = args.progress
    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)
    try:
        return run(args)
    except Failure as e:
        print(machine_line("ERROR", {"message": str(e), "missing": e.missing,
                                     "skipped": getattr(e, "skipped", [])}), flush=True)
        return e.code
    except Exception as e:  # noqa: BLE001 — the app shows this line as the reason
        print(machine_line("ERROR", {"message": f"the comparison stopped unexpectedly ({e})", "missing": None,
                                     "skipped": []}), flush=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())
