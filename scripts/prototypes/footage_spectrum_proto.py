#!/usr/bin/env python3
"""Footage Spectrum — rapid prototype v2 (look-and-tweak demo, NOT app code).

Reads a JSON "sets" file (kept OUTSIDE the repo, in the cache folder). Each set
is a REFERENCE (the first file) and CANDIDATES. For every video it extracts a
colour-over-time strip ("spectrum" / movie barcode) and a sound band, aligns
each candidate with the reference, computes a per-second MATCH RIBBON, and writes ONE self-contained local
HTML page (set picker, play, blink comparator, verdicts).

    venv/bin/python scripts/prototypes/footage_spectrum_proto.py [--sets PATH] [--refresh] [--png]

Everything it writes goes to ~/Library/Caches/VideoScan/spectrum-proto/ :
    sets.json            input   [{title, note, files:[{label, path}]}]  (files[0] = reference)
    cache/<key>.npz      per-file strip + sound + viewer-frame cache (key = hash of path+size+mtime)
    spectrum.html        the page (local file, no external requests)
    set_N.png            optional check renderings (--png)

The media files are only ever READ. No media path or name lives in this script.
See docs/design/footage_spectrum_design_2026-10-03.md.
"""
import argparse
import base64
import hashlib
import json
import math
import os
import shutil
import subprocess
import sys
import time

import numpy as np

OUT_DIR = os.path.expanduser("~/Library/Caches/VideoScan/spectrum-proto")
ROWS = 48                  # colour bands per second-column
THUMB_W = 160              # default viewer-frame width (--thumb-width)
THUMB_Q = 6
THUMB_CAP = 1200
AUDIO_HZ = 8000
N_BANDS = 8
SINGLE_PASS_LIMIT_S = 360  # a file slower than this is skipped (never one ffmpeg per frame)
RIBBON_HALF_WINDOW = 2     # ± seconds
CACHE_VERSION = "v1"       # strips/sound (unchanged since v1 so old caches are reused)

FFMPEG = shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"
FFPROBE = shutil.which("ffprobe") or "/opt/homebrew/bin/ffprobe"


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


def single_pass(path, info, step, tmp, hwaccel, tw):
    """ONE ffmpeg decode per file: columns -> tmp file, audio -> tmp file, viewer frames -> stdout."""
    cols_tmp, aud_tmp, err_tmp = tmp + ".cols", tmp + ".pcm", tmp + ".err"
    fc = (f"[0:v:0]fps=1,split=2[a][b];[a]scale=1:{ROWS}:flags=area[c];"
          f"[b]select='not(mod(n\\,{step}))',scale={tw}:-2[t]")
    cmd = [FFMPEG, "-v", "error", "-nostdin"]
    if hwaccel:
        cmd += ["-hwaccel", "videotoolbox"]
    cmd += ["-i", path, "-filter_complex", fc,
            "-map", "[c]", "-f", "rawvideo", "-pix_fmt", "rgb24", "-y", cols_tmp,
            "-map", "[t]", "-fps_mode", "passthrough", "-c:v", "mjpeg",
            "-q:v", str(THUMB_Q), "-f", "image2pipe", "-"]
    if info["audio"]:
        cmd += ["-map", "0:a:0", "-vn", "-ac", "1", "-ar", str(AUDIO_HZ), "-f", "s16le", "-y", aud_tmp]
    t0 = last = time.time()
    chunks, timed_out = [], False
    with open(err_tmp, "wb") as ef:
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=ef)
        while True:
            b = p.stdout.read(1 << 16)
            if not b:
                break
            chunks.append(b)
            now = time.time()
            if now - last > 10:
                last = now
                done = os.path.getsize(cols_tmp) // (ROWS * 3) if os.path.exists(cols_tmp) else 0
                print(f"      … {done}/{int(info['duration'])} s of video, {now - t0:.0f} s elapsed", flush=True)
            if now - t0 > SINGLE_PASS_LIMIT_S:
                p.kill()
                timed_out = True
                break
        rc = p.wait()
    err = open(err_tmp, "rb").read().decode("utf8", "replace").strip()
    os.remove(err_tmp)
    cols = np.fromfile(cols_tmp, dtype=np.uint8) if os.path.exists(cols_tmp) else np.zeros(0, np.uint8)
    pcm = np.fromfile(aud_tmp, dtype="<i2") if (info["audio"] and os.path.exists(aud_tmp)) else None
    for f in (cols_tmp, aud_tmp):
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


def extract(path, cache_dir, refresh, tw):
    key, size = file_key(path)
    npz = os.path.join(cache_dir, key + ".npz")
    if os.path.exists(npz) and not refresh:
        z = np.load(npz, allow_pickle=False)
        if "thumb_blob" in z.files:
            d = {k: z[k] for k in ("cols", "loud", "bands", "thumb_blob", "thumb_offs")}
            d["meta"] = json.loads(str(z["meta"]))
            d["meta"].setdefault("size", size)
            d.update(key=key, cached=True)
            return d
    info = probe(path)
    dur = info["duration"]
    step = 2 if dur < 180 else 5
    step = max(step, math.ceil(dur / THUMB_CAP))
    tmp = os.path.join(cache_dir, key + ".tmp")
    t0 = time.time()
    method = "single pass, VideoToolbox decode, 1 sample/s"
    res, err = single_pass(path, info, step, tmp, True, tw)
    if res is None and err != "timeout":
        print(f"      hwaccel pass failed ({err[:120]}); retrying in software", flush=True)
        method = "single pass, software decode, 1 sample/s"
        res, err = single_pass(path, info, step, tmp, False, tw)
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
    np.savez_compressed(npz, cols=cols, loud=loud, bands=bands, thumb_blob=blob, thumb_offs=offs,
                        meta=np.array(json.dumps(meta)))
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


def fmt_t(t):
    neg = t < 0
    t = abs(int(round(t)))
    h, m, s = t // 3600, t % 3600 // 60, t % 60
    return ("-" if neg else "") + (f"{h}:{m:02d}:{s:02d}" if h else f"{m}:{s:02d}")


# ---------------------------------------------------------------------- facts

def drive_of(path):
    parts = path.split("/")
    if len(parts) > 2 and parts[1] == "Volumes":
        return parts[2]
    if "/Library/Caches/" in path:
        return "this Mac (cache — made for this demo)"
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
                           np.where((v >= 0.85)[:, None], [46, 158, 79],
                                    np.where((v >= 0.6)[:, None], [224, 176, 0], [214, 69, 69])))
            img[y + sh:y + sh + rh, ok] = col
    write_png(path, img)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--sets", default=os.path.join(OUT_DIR, "sets.json"))
    ap.add_argument("--out", default=os.path.join(OUT_DIR, "spectrum.html"))
    ap.add_argument("--refresh", action="store_true", help="ignore the per-file caches")
    ap.add_argument("--png", action="store_true", help="also write set_N.png check renderings")
    ap.add_argument("--thumb-width", type=int, default=THUMB_W, help="viewer-frame width for NEW extractions")
    ap.add_argument("--wobble", type=int, default=2, help="± seconds of local drift the match ribbon tolerates")
    args = ap.parse_args()

    out_dir = os.path.dirname(os.path.abspath(args.out))
    cache_dir = os.path.join(out_dir, "cache")
    os.makedirs(cache_dir, exist_ok=True)
    sets_in = json.load(open(args.sets))

    files, thumbsets, ex, sets_out = {}, {}, {}, []
    for si, s in enumerate(sets_in):
        print(f"\n=== Set {si + 1}: {s['title']}")
        members = []
        for f in s["files"]:
            p = f["path"]
            if not os.path.isfile(p):
                print(f"   SKIP (offline/missing): {f['label']}")
                if not members:
                    break            # no reference -> no set
                continue
            if p not in ex:
                print(f"   extracting {f['label']} …", flush=True)
                try:
                    ex[p] = extract(p, cache_dir, args.refresh, args.thumb_width)
                except Exception as e:  # noqa: BLE001 — prototype: report and carry on
                    print(f"   FAILED {f['label']}: {e}")
                    if not members:
                        break
                    continue
            d = ex[p]
            m = d["meta"]
            print(f"   {f['label']:<40} T={m['T']:>5}  dur={m['duration']:.1f}s  {m['codec']}"
                  f"  {m['width']}x{m['height']}  {m['size'] / 1e9:.2f} GB  audio={'yes' if m['has_audio'] else 'none'}"
                  f"  extract={m['extract_seconds']}s{' (cached)' if d['cached'] else ''}  [{m['method']}]")
            members.append((f, d))
        if len(members) < 2:
            print("   set skipped — reference or candidates unavailable")
            continue

        raw = [band_feature(d["cols"]) for _, d in members]
        pf = [unit_rows(x) for x in raw]
        sf = [unit_rows(d["bands"]) if d["meta"]["has_audio"] else None for _, d in members]
        n = len(members)
        short = [f["label"].split(" ")[0] for f, _ in members]

        # every candidate against the reference (index 0)
        offsets, scores, ribbons = [0] * n, [None] * n, [None] * n
        pairs = []
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
            g, y = float((rib >= 0.85).sum()) / T, float(((rib >= 0.6) & (rib < 0.85)).sum()) / T
            print(f"   {short[0]} <-> {short[j]}: search {pic['score']:.2f} at {off:+d} s ({fmt_t(off)}) "
                  f"(overlap {pic['overlap']} s; next best {pic['next']}) · over the overlap {whole:.3f} · "
                  f"ribbon green {g:.0%} yellow {y:.0%} · covers {(rib >= 0.85).sum() / len(raw[0]):.0%} of the reference"
                  + (f" · sound {snd['score']:.2f} at {snd['offset'] if a == 0 else -snd['offset']:+d} s (next {snd['next']})" if snd else " · sound n/a"))
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
                "ribbon": None if rib is None else b64(np.where(np.isnan(rib), 255, np.round(np.nan_to_num(rib) * 250)).astype(np.uint8)),
            })
        sets_out.append({"title": s["title"], "note": s.get("note", ""), "grid": 0, "gridBase": 0,
                         "files": out_files, "pairs": pairs})
        if args.png:
            png = os.path.join(out_dir, f"set_{si + 1}.png")
            render_png(png, [(d["cols"], offsets[i], ribbons[i]) for i, (_, d) in enumerate(members)])
            print(f"   check rendering: {png}")

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
    html = open(os.path.join(here, "footage_spectrum_proto.html")).read()
    payload = json.dumps(data, separators=(",", ":")).replace("</", "<\\/")
    with open(args.out, "w") as fh:
        fh.write(html.replace("/*__DATA__*/", payload))
    print(f"\nwrote {args.out}  ({os.path.getsize(args.out) / 1e6:.1f} MB)")
    print(f"open {args.out}")


if __name__ == "__main__":
    sys.exit(main())
