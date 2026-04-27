#!/usr/bin/env python3.12
"""
find_person.py — CLI: find videos containing a known person across one or
more volumes, using a face gallery built by fd_diagnostic.py.

Pipeline per video:
  1. ffprobe for duration (skip < min_duration, > max_duration, unreadable)
  2. ffmpeg samples N frames via per-timestamp seek (works on long videos)
  3. MTCNN detects faces in each frame
  4. FaceNet (VGGFace2 InceptionResnetV1) embeds each face
  5. For each face, compute min cosine distance to the gallery
  6. Classify each frame-face as strong / weak / miss by threshold
  7. Classify the video as STRONG / WEAK / NO by hit counts

Streams CSV as it goes; produces an HTML report at the end.

Usage:
    python3.12 find_person.py [<root> ...] [options]

Examples:
    # one volume, donna gallery, both csv+html
    python3.12 find_person.py /Volumes/MyBook3Terabytes --person donna

    # multiple volumes
    python3.12 find_person.py /Volumes/A /Volumes/B --person donna

    # interactive: choose person and roots from prompts
    python3.12 find_person.py --interactive

    # what galleries exist?
    python3.12 find_person.py --list-persons
"""

from __future__ import annotations
import argparse
import csv
import html
import os
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

REPO = Path(__file__).resolve().parent.parent
EMB_PATH = REPO / "output/fd_diagnostic/embeddings.npz"
OUT_DIR = REPO / "output/find_person"

VIDEO_EXTS = {
    ".mp4", ".mov", ".m4v", ".avi", ".mkv", ".wmv", ".flv",
    ".mts", ".m2ts", ".mpg", ".mpeg", ".3gp", ".webm", ".ogv",
    ".dv", ".divx", ".vob", ".ts"
}
SKIP_DIR_PATTERNS = {
    ".Spotlight-V100", ".Trashes", ".DocumentRevisions-V100",
    ".fseventsd", "System Volume Information", "$RECYCLE.BIN",
    ".TemporaryItems", "node_modules", ".git", "venv", ".venv",
}

DEFAULT_FRAME_INTERVAL = 5.0       # seconds between samples
DEFAULT_MAX_FRAMES = 120
DEFAULT_STRONG_THRESH = 0.60       # cosine distance
DEFAULT_WEAK_THRESH = 0.75
DEFAULT_MIN_DURATION = 30.0        # seconds
DEFAULT_MAX_DURATION = 4 * 3600.0
STRONG_HIT_COUNT = 3               # ≥ this many strong → STRONG verdict
WEAK_VIA_WEAK_COUNT = 5            # ≥ this many weak (with no strong) → WEAK


# ============================================================================
# Pure functions (unit-testable without torch/ffmpeg)
# ============================================================================

def compute_sample_timestamps(duration: float, interval_s: float,
                                max_frames: int) -> list[float]:
    """Evenly-spaced timestamps inside [2, duration-2], cap at max_frames.

    Used by ffmpeg per-timestamp seeking. Avoids the very start/end so we
    don't sample slates or end credits.
    """
    if duration <= 4.0 or max_frames <= 0 or interval_s <= 0:
        return []
    usable = duration - 4.0
    n = min(max_frames, max(4, int(usable / interval_s)))
    return [2.0 + (i + 0.5) * usable / n for i in range(n)]


def verdict_for_counts(strong_hits: int, weak_hits: int) -> str:
    """Classify a video given strong/weak frame-hit counts."""
    if strong_hits >= STRONG_HIT_COUNT:
        return "STRONG"
    if strong_hits >= 1 or weak_hits >= WEAK_VIA_WEAK_COUNT:
        return "WEAK"
    return "NO"


def is_video_path(path: Path) -> bool:
    """True if filename has a known video extension and isn't a dotfile."""
    if path.name.startswith("."):
        return False
    return path.suffix.lower() in VIDEO_EXTS


def should_skip_dir(name: str) -> bool:
    """True if a directory name should be pruned during the walk."""
    if name.startswith("."):
        return True
    return name in SKIP_DIR_PATTERNS


def iter_videos(root: Path):
    """Yield every video file under `root`, pruning skip-list directories."""
    for dirpath, dirnames, filenames in os.walk(root, topdown=True,
                                                  followlinks=False):
        dirnames[:] = [d for d in dirnames if not should_skip_dir(d)]
        for fn in filenames:
            p = Path(dirpath) / fn
            if is_video_path(p):
                yield p


def min_distance_to_gallery(face_emb, gallery) -> float:
    """Minimum cosine distance from a single L2-normed face embedding to
    any vector in an L2-normed gallery (each row is a unit vector).

    Pure numpy; testable with synthetic inputs.
    """
    import numpy as np
    sims = gallery @ face_emb
    return float(1.0 - np.max(sims))


# ============================================================================
# Gallery loading
# ============================================================================

def list_persons_in_gallery() -> dict[str, int]:
    """Return {person_name: usable_facenet_photo_count} from embeddings.npz."""
    import numpy as np
    if not EMB_PATH.exists():
        return {}
    data = np.load(EMB_PATH, allow_pickle=True)
    persons = data["persons"]
    fnet_mask = data["facenet_mask"]
    counts: dict[str, int] = {}
    for p, ok in zip(persons, fnet_mask):
        if ok:
            counts[str(p)] = counts.get(str(p), 0) + 1
    return dict(sorted(counts.items()))


def load_gallery(person: str):
    """Load FaceNet embeddings for `person` from embeddings.npz."""
    import numpy as np
    if not EMB_PATH.exists():
        sys.exit(f"No gallery at {EMB_PATH}. Run fd_diagnostic.py first.")
    data = np.load(EMB_PATH, allow_pickle=True)
    persons = data["persons"]
    fnet_mask = data["facenet_mask"]
    fnet = data["facenet"]
    indices = []
    fnet_idx = 0
    for i, p in enumerate(persons):
        if fnet_mask[i]:
            if str(p) == person:
                indices.append(fnet_idx)
            fnet_idx += 1
    if not indices:
        avail = ", ".join(list_persons_in_gallery().keys())
        sys.exit(f"No facenet embeddings for '{person}'. Available: {avail}")
    return fnet[indices]


# ============================================================================
# Video utilities (call out to ffmpeg/ffprobe)
# ============================================================================

def ffprobe_duration(path: Path) -> Optional[float]:
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", str(path)],
            capture_output=True, text=True, timeout=30)
        if out.returncode != 0:
            return None
        s = out.stdout.strip()
        return float(s) if s else None
    except Exception:
        return None


def extract_frames_at(path: Path, timestamps: list[float],
                       tmpdir: Path) -> list[Path]:
    """One ffmpeg call per timestamp. Each is fast (keyframe-accurate seek)."""
    frames: list[Path] = []
    for i, ts in enumerate(timestamps):
        out = tmpdir / f"f_{i:05d}.jpg"
        cmd = [
            "ffmpeg", "-y", "-v", "error",
            "-ss", f"{ts:.2f}",
            "-i", str(path),
            "-frames:v", "1",
            "-vf", "scale='min(640,iw)':'-2'",
            "-q:v", "4", "-an",
            str(out)
        ]
        try:
            subprocess.run(cmd, timeout=15, capture_output=True)
        except subprocess.TimeoutExpired:
            continue
        except Exception:
            continue
        if out.exists() and out.stat().st_size > 0:
            frames.append(out)
    return frames


# ============================================================================
# Embedding (lazy-imported torch path)
# ============================================================================

class FaceEmbedder:
    """Wraps MTCNN (cpu) + InceptionResnetV1 (mps if available)."""

    def __init__(self) -> None:
        import torch
        from facenet_pytorch import MTCNN, InceptionResnetV1
        self.torch = torch
        self.device = (torch.device("mps")
                       if torch.backends.mps.is_available()
                       else torch.device("cpu"))
        # MTCNN on cpu (avoids MPS adaptive-pool bug)
        self.mtcnn = MTCNN(keep_all=True,
                            device=torch.device("cpu"),
                            post_process=False, min_face_size=40)
        self.resnet = InceptionResnetV1(pretrained="vggface2") \
                        .eval().to(self.device)

    def embed_frame(self, img_path: Path):
        """Return list of 512-D L2-normed embeddings for faces in frame."""
        import numpy as np
        from PIL import Image, ImageOps
        try:
            img = Image.open(img_path)
            img = ImageOps.exif_transpose(img).convert("RGB")
        except Exception:
            return []
        boxes, _ = self.mtcnn.detect(img)
        if boxes is None:
            return []
        embs = []
        for b in boxes:
            x1, y1, x2, y2 = b
            w, h = x2 - x1, y2 - y1
            if w < 24 or h < 24:
                continue
            cx, cy = x1 + w/2, y1 + h/2
            side = max(w, h) * 1.2
            fx1 = max(0, cx - side/2)
            fy1 = max(0, cy - side/2)
            fx2 = min(img.width, cx + side/2)
            fy2 = min(img.height, cy + side/2)
            face = img.crop((fx1, fy1, fx2, fy2)) \
                       .resize((160, 160), Image.BILINEAR)
            arr = np.asarray(face, dtype=np.float32)
            arr = (arr - 127.5) / 128.0
            tensor = (self.torch.from_numpy(arr)
                      .permute(2, 0, 1).unsqueeze(0).to(self.device))
            with self.torch.no_grad():
                e = self.resnet(tensor).cpu().numpy()[0]
            e = e / (np.linalg.norm(e) + 1e-9)
            embs.append(e)
        return embs


# ============================================================================
# Scan logic
# ============================================================================

@dataclass
class VideoResult:
    path: Path
    duration: Optional[float]
    frames_scanned: int = 0
    frames_with_faces: int = 0
    strong_hits: int = 0
    weak_hits: int = 0
    best_min_dist: float = 1.0
    avg_min_dist: float = 1.0
    err: str = ""

    def verdict(self) -> str:
        return verdict_for_counts(self.strong_hits, self.weak_hits)


def scan_one_video(path: Path, embedder: FaceEmbedder, gallery,
                    cfg) -> VideoResult:
    import numpy as np
    dur = ffprobe_duration(path)
    if dur is None:
        return VideoResult(path, None, err="probe_failed")
    if dur < cfg.min_duration or dur > cfg.max_duration:
        return VideoResult(path, dur, err="out_of_range")

    interval = max(cfg.frame_interval, dur / cfg.max_frames)
    timestamps = compute_sample_timestamps(dur, interval, cfg.max_frames)
    with tempfile.TemporaryDirectory(prefix="fdvol_") as td:
        tmpdir = Path(td)
        frames = extract_frames_at(path, timestamps, tmpdir)
        if not frames:
            return VideoResult(path, dur, err="no_frames")
        min_dists: list[float] = []
        strong = weak = 0
        frames_with_faces = 0
        for fp in frames:
            face_embs = embedder.embed_frame(fp)
            if not face_embs:
                continue
            frames_with_faces += 1
            frame_min = min(min_distance_to_gallery(e, gallery)
                             for e in face_embs)
            min_dists.append(frame_min)
            if frame_min < cfg.strong_thresh:
                strong += 1
            elif frame_min < cfg.weak_thresh:
                weak += 1
        r = VideoResult(path, dur,
                        frames_scanned=len(frames),
                        frames_with_faces=frames_with_faces,
                        strong_hits=strong, weak_hits=weak)
        if min_dists:
            r.best_min_dist = float(min(min_dists))
            r.avg_min_dist = float(np.mean(min_dists))
        return r


# ============================================================================
# Output writers
# ============================================================================

CSV_COLS = ["path", "duration_s", "frames_scanned", "frames_with_faces",
            "strong_hits", "weak_hits", "best_min_dist", "avg_min_dist",
            "verdict", "error"]


def csv_row_for(r: VideoResult) -> list:
    return [
        str(r.path),
        f"{r.duration:.1f}" if r.duration is not None else "",
        r.frames_scanned, r.frames_with_faces,
        r.strong_hits, r.weak_hits,
        f"{r.best_min_dist:.3f}",
        f"{r.avg_min_dist:.3f}",
        r.verdict(),
        r.err,
    ]


def write_html_report(results: list[VideoResult], person: str, roots: list[Path],
                       html_path: Path) -> None:
    """Sortable HTML table of all hits."""
    ranked = [r for r in results if r.strong_hits or r.weak_hits]
    ranked.sort(key=lambda r: (-r.strong_hits, -r.weak_hits, r.best_min_dist))
    n_strong = sum(1 for r in results if r.verdict() == "STRONG")
    n_weak = sum(1 for r in results if r.verdict() == "WEAK")

    rows = []
    for rank, r in enumerate(ranked, 1):
        verdict = r.verdict()
        css = verdict.lower()
        dur_min = f"{r.duration/60:.1f}m" if r.duration else "?"
        rows.append(f"""
        <tr class="{css}">
          <td>{rank}</td>
          <td>{verdict}</td>
          <td class="num">{r.strong_hits}</td>
          <td class="num">{r.weak_hits}</td>
          <td class="num">{r.best_min_dist:.3f}</td>
          <td class="num">{r.avg_min_dist:.3f}</td>
          <td>{dur_min}</td>
          <td><a href="file://{html.escape(str(r.path))}">{html.escape(r.path.name)}</a><br>
              <span class="path">{html.escape(str(r.path.parent))}</span></td>
        </tr>""")

    roots_html = "".join(f"<li><code>{html.escape(str(p))}</code></li>"
                          for p in roots)
    html_body = f"""<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>find_person: {html.escape(person)}</title>
<style>
  body {{ font: 14px -apple-system, system-ui, sans-serif; padding: 1em 2em;
          color: #222; background: #fafafa; max-width: 1400px; }}
  h1 {{ font-size: 1.6em; margin-bottom: 0.2em; }}
  .meta {{ color: #666; margin-bottom: 1em; }}
  .stats {{ display: flex; gap: 2em; margin: 1em 0; }}
  .stat {{ background: white; border: 1px solid #ddd; padding: 0.6em 1em;
           border-radius: 6px; }}
  .stat .num {{ font-size: 1.6em; font-weight: 600; }}
  table {{ border-collapse: collapse; width: 100%; background: white;
          border: 1px solid #ddd; }}
  th, td {{ padding: 6px 10px; text-align: left;
           border-bottom: 1px solid #eee; }}
  th {{ background: #f0f0f0; cursor: pointer; user-select: none;
        position: sticky; top: 0; }}
  td.num {{ text-align: right; font-variant-numeric: tabular-nums; }}
  tr.strong {{ background: #e7f7ea; }}
  tr.weak {{ background: #fff7e0; }}
  .path {{ color: #888; font-size: 0.85em; font-family: monospace; }}
  a {{ color: #0a52cc; text-decoration: none; font-weight: 500; }}
  a:hover {{ text-decoration: underline; }}
</style>
<script>
  function sortBy(col, numeric) {{
    const tbody = document.querySelector('tbody');
    const rows = Array.from(tbody.rows);
    const dir = tbody.dataset.dir === 'asc' ? -1 : 1;
    tbody.dataset.dir = dir === 1 ? 'asc' : 'desc';
    rows.sort((a,b) => {{
      let av = a.cells[col].innerText, bv = b.cells[col].innerText;
      if (numeric) {{ av = parseFloat(av) || 0; bv = parseFloat(bv) || 0; }}
      return av < bv ? -dir : av > bv ? dir : 0;
    }});
    rows.forEach(r => tbody.appendChild(r));
  }}
</script>
</head><body>
<h1>find_person: <code>{html.escape(person)}</code></h1>
<div class="meta">Generated {time.strftime('%Y-%m-%d %H:%M')}.
Scanned roots:<ul>{roots_html}</ul></div>
<div class="stats">
  <div class="stat"><div class="num">{len(results)}</div>videos walked</div>
  <div class="stat"><div class="num" style="color:#1a8f3a">{n_strong}</div>STRONG</div>
  <div class="stat"><div class="num" style="color:#b08620">{n_weak}</div>WEAK</div>
  <div class="stat"><div class="num">{len(ranked)}</div>any hit</div>
</div>
<p><strong>Click a column header to sort.</strong> Click a filename to open
in browser (file:// — works for many formats; copy path otherwise).</p>
<table>
<thead><tr>
  <th onclick="sortBy(0,true)">#</th>
  <th onclick="sortBy(1,false)">verdict</th>
  <th onclick="sortBy(2,true)">strong</th>
  <th onclick="sortBy(3,true)">weak</th>
  <th onclick="sortBy(4,true)">best dist</th>
  <th onclick="sortBy(5,true)">avg dist</th>
  <th onclick="sortBy(6,false)">duration</th>
  <th onclick="sortBy(7,false)">file</th>
</tr></thead>
<tbody>{"".join(rows)}</tbody></table></body></html>"""
    html_path.write_text(html_body)


# ============================================================================
# CLI
# ============================================================================

def cmd_list_persons() -> None:
    counts = list_persons_in_gallery()
    if not counts:
        print(f"No gallery at {EMB_PATH}.")
        print("Run scripts/fd_diagnostic.py first to build one.")
        return
    print(f"Galleries available in {EMB_PATH}:\n")
    print(f"  {'person':<12} {'photos':>6}")
    print(f"  {'-'*12} {'-'*6}")
    for p, n in counts.items():
        flag = "  ✓" if n >= 8 else "  (low — recommend ≥8)"
        print(f"  {p:<12} {n:>6}{flag}")


def cmd_interactive() -> argparse.Namespace:
    """Prompt for person and roots, then return args namespace."""
    persons = list_persons_in_gallery()
    if not persons:
        sys.exit("No gallery — run fd_diagnostic.py first.")
    print("Available people:")
    keys = list(persons.keys())
    for i, p in enumerate(keys, 1):
        print(f"  [{i}] {p}  ({persons[p]} photos)")
    sel = input("Pick person (number or name): ").strip()
    if sel.isdigit() and 1 <= int(sel) <= len(keys):
        person = keys[int(sel) - 1]
    elif sel in persons:
        person = sel
    else:
        sys.exit(f"Unknown person: {sel}")
    roots_input = input("Roots to scan (space-separated paths): ").strip()
    roots = [Path(p).expanduser() for p in roots_input.split() if p]
    if not roots:
        sys.exit("Need at least one root.")
    return argparse.Namespace(
        roots=roots, person=person,
        frame_interval=DEFAULT_FRAME_INTERVAL,
        max_frames=DEFAULT_MAX_FRAMES,
        strong_thresh=DEFAULT_STRONG_THRESH,
        weak_thresh=DEFAULT_WEAK_THRESH,
        min_duration=DEFAULT_MIN_DURATION,
        max_duration=DEFAULT_MAX_DURATION,
        limit=0, format="both", out_dir=OUT_DIR,
    )


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(
        description="Find videos containing a known person across volumes.")
    ap.add_argument("roots", type=Path, nargs="*",
                     help="Directories/volumes to scan")
    ap.add_argument("--person", default="donna",
                     help="Gallery name (default: donna)")
    ap.add_argument("--frame-interval", type=float,
                     default=DEFAULT_FRAME_INTERVAL,
                     help=f"Seconds between sampled frames (default {DEFAULT_FRAME_INTERVAL})")
    ap.add_argument("--max-frames", type=int, default=DEFAULT_MAX_FRAMES,
                     help=f"Max frames per video (default {DEFAULT_MAX_FRAMES})")
    ap.add_argument("--strong-thresh", type=float,
                     default=DEFAULT_STRONG_THRESH,
                     help=f"Cosine distance for STRONG (default {DEFAULT_STRONG_THRESH})")
    ap.add_argument("--weak-thresh", type=float,
                     default=DEFAULT_WEAK_THRESH,
                     help=f"Cosine distance for WEAK (default {DEFAULT_WEAK_THRESH})")
    ap.add_argument("--min-duration", type=float,
                     default=DEFAULT_MIN_DURATION,
                     help="Skip videos shorter than this (s)")
    ap.add_argument("--max-duration", type=float,
                     default=DEFAULT_MAX_DURATION,
                     help="Skip videos longer than this (s)")
    ap.add_argument("--limit", type=int, default=0,
                     help="Stop after N videos (0 = unlimited)")
    ap.add_argument("--format", choices=("csv", "html", "both"),
                     default="both",
                     help="Output format (default: both)")
    ap.add_argument("--out-dir", type=Path, default=OUT_DIR,
                     help="Where to write outputs")
    ap.add_argument("--list-persons", action="store_true",
                     help="List galleries and exit")
    ap.add_argument("--interactive", action="store_true",
                     help="Prompt for person + roots")
    return ap.parse_args()


def main() -> None:
    args = parse_args()
    if args.list_persons:
        cmd_list_persons()
        return
    if args.interactive:
        args = cmd_interactive()
    if not args.roots:
        sys.exit("Provide one or more roots, or use --interactive / --list-persons")
    for r in args.roots:
        if not r.exists():
            sys.exit(f"Root not found: {r}")

    args.out_dir.mkdir(parents=True, exist_ok=True)
    gallery = load_gallery(args.person)
    print(f"[gallery] {len(gallery)} facenet vectors for '{args.person}'")
    print(f"[init] loading models…")
    embedder = FaceEmbedder()
    print(f"[init] device = {embedder.device}")

    run_tag = time.strftime("%Y%m%d_%H%M%S")
    base = args.out_dir / f"{args.person}_{run_tag}"
    csv_path = base.with_suffix(".csv")
    html_path = base.with_suffix(".html")

    write_csv = args.format in ("csv", "both")
    write_html = args.format in ("html", "both")
    print(f"[out] {csv_path if write_csv else ''} "
          f"{html_path if write_html else ''}")

    t_start = time.time()
    all_results: list[VideoResult] = []
    fh = csv_path.open("w", newline="") if write_csv else None
    writer = csv.writer(fh) if fh else None
    if writer:
        writer.writerow(CSV_COLS)
        fh.flush()

    n_seen = 0
    try:
        for root in args.roots:
            for vpath in iter_videos(root):
                if args.limit and n_seen >= args.limit:
                    break
                n_seen += 1
                try:
                    r = scan_one_video(vpath, embedder, gallery, args)
                except KeyboardInterrupt:
                    raise
                except Exception as exc:
                    r = VideoResult(vpath, None, err=f"scan_err:{exc}")
                if writer:
                    writer.writerow(csv_row_for(r))
                    fh.flush()
                all_results.append(r)
                elapsed = time.time() - t_start
                print(f"[{n_seen:5d}] {elapsed/60:6.1f}min  "
                      f"{r.verdict():6s}  s={r.strong_hits:3d} w={r.weak_hits:3d}  "
                      f"best={r.best_min_dist:.3f}  {r.path.name[:60]}")
            if args.limit and n_seen >= args.limit:
                break
    finally:
        if fh:
            fh.close()

    if write_html:
        write_html_report(all_results, args.person, args.roots, html_path)

    n_strong = sum(1 for r in all_results if r.verdict() == "STRONG")
    n_weak = sum(1 for r in all_results if r.verdict() == "WEAK")
    print(f"\n[done] {len(all_results)} videos | "
          f"STRONG={n_strong} WEAK={n_weak} "
          f"in {(time.time()-t_start)/60:.1f}min")
    if write_csv: print(f"  CSV  → {csv_path}")
    if write_html: print(f"  HTML → {html_path}")


if __name__ == "__main__":
    main()
