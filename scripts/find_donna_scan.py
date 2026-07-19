#!/usr/bin/env python3
"""
find_donna_scan.py — batch "find Donna" driver for VideoScan.

Walks one or more root paths (volumes or folders), runs the Release
VideoScan binary's person-eval CLI (ArcFace, minimum-hits aggregation,
POI cycle 03 schema v2) on every video file, and emits:

  <out>/scan-progress.jsonl   one JSON line per processed file (resume log)
  <out>/donna_candidates.csv  confirmed-first, then by totalHits desc
  <out>/donna_candidates.html self-contained curation page
                              (confirmed + near-miss sections)

Design notes:
  - SEQUENTIAL by default (--jobs 1). Roots are often spinning HDDs;
    parallel decode storms hurt more than they help there.
  - Interrupt-safe: each result is one flushed+fsynced JSONL line;
    Ctrl-C leaves the log valid and a rerun resumes where it left off.
    Reports are (re)generated from the full JSONL on exit, including
    interrupted exits, so partial runs still produce a usable page.
  - Errors (unreadable file, CLI nonzero exit) are recorded, never fatal.
  - Memory: streaming. Worst case is one dict per catalogued file held
    for report generation — ~300 bytes/file, so ~30 MB for a 100k-file
    volume. No frames or media bytes are ever buffered here.

Stdlib only. See docs/find_donna_scan.md for usage and curation guidance.
"""

import argparse
import concurrent.futures
import csv
import glob
import html
import json
import os
import signal
import subprocess
import sys
import threading
import time
import urllib.parse

# ---------------------------------------------------------------------------
# Extension set — copied from scripts/VideoScan.py (VIDEO_EXTENSIONS).
# Keep in sync manually; deliberately NOT imported (that script is a CLI
# with side effects on import-adjacent paths and its own dependency stack).
# ---------------------------------------------------------------------------
VIDEO_EXTENSIONS = {
    ".mov", ".mp4", ".m4v", ".avi", ".mkv", ".mxf",
    ".mts", ".m2ts", ".ts", ".mpg", ".mpeg", ".m2v", ".vob",
    ".wmv", ".asf", ".webm", ".ogv", ".ogg",
    ".rm", ".rmvb", ".divx", ".flv", ".f4v",
    ".3gp", ".3g2", ".dv", ".dif",
    ".braw", ".r3d",
    ".vro", ".mod", ".tod",
}

# Directory names pruned during the walk (lowercased comparison). Mirrors
# the app's aggressive-skip default (ScanOptions.SkipCategories finder/
# windows-trash classes) plus cheaply-identifiable iMovie cache subfolders.
SKIP_DIR_NAMES = {
    ".spotlight-v100", ".fseventsd", ".trashes", ".temporaryitems",
    ".documentrevisions-v100", ".vol", "automount",
    "system volume information", "$recycle.bin", "recycler",
    "imovie cache", "imovie thumbnails", "render files",
    "imovie temporary items", "cache files",
}

# Opaque library bundles we never descend into (media inside is app-managed
# proxies/renders, not source footage).
SKIP_BUNDLE_SUFFIXES = (
    ".imovielibrary", ".photoslibrary", ".fcpbundle", ".aplibrary",
    ".tvlibrary", ".musiclibrary", ".finalcutprojectlibrary", ".lrdata",
)

DEFAULT_REFERENCES = os.path.expanduser(
    "~/Library/Application Support/VideoScan/POI/donna")

NEAR_MISS_MIN_HITS = 3  # presence "none" but totalHits >= this → curation gold


# ---------------------------------------------------------------------------
# Binary discovery
# ---------------------------------------------------------------------------

def find_binary(explicit):
    """Resolve the Release VideoScan binary (person-eval entry point)."""
    candidates = []
    if explicit:
        candidates.append(explicit)
    env = os.environ.get("VIDEOSCAN_BIN")
    if env:
        candidates.append(env)
    # Newest Release product across DerivedData locations, then /Applications.
    patterns = [
        os.path.expanduser("~/dev/VideoScan/.claude/worktrees/*/DerivedData/"
                           "Build/Products/Release/VideoScan.app/Contents/MacOS/VideoScan"),
        os.path.expanduser("~/Library/Developer/Xcode/DerivedData/VideoScan-*/"
                           "Build/Products/Release/VideoScan.app/Contents/MacOS/VideoScan"),
        "/Volumes/XcodeRAM/DerivedData/VideoScan-*/"
        "Build/Products/Release/VideoScan.app/Contents/MacOS/VideoScan",
        "/Applications/VideoScan.app/Contents/MacOS/VideoScan",
    ]
    found = []
    for pattern in patterns:
        found.extend(glob.glob(pattern))
    found.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    candidates.extend(found)
    for path in candidates:
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    sys.exit("error: VideoScan Release binary not found.\n"
             "Build it first:\n"
             "  xcodebuild build -project VideoScan/VideoScan.xcodeproj "
             "-scheme VideoScan -configuration Release\n"
             "then pass --binary <path-to>/VideoScan.app/Contents/MacOS/VideoScan "
             "or set VIDEOSCAN_BIN.")


# ---------------------------------------------------------------------------
# Enumeration
# ---------------------------------------------------------------------------

def is_skipped_dir(name):
    lower = name.lower()
    if name.startswith("."):        # hidden dirs (covers .Trashes etc. too)
        return True
    if lower in SKIP_DIR_NAMES:
        return True
    return lower.endswith(SKIP_BUNDLE_SUFFIXES)


def enumerate_videos(roots):
    """Yield absolute paths of video files under each root, sorted per root."""
    for root in roots:
        root = os.path.abspath(root)
        if os.path.isfile(root):
            if os.path.splitext(root)[1].lower() in VIDEO_EXTENSIONS:
                yield root
            continue
        for dirpath, dirnames, filenames in os.walk(root, topdown=True,
                                                    followlinks=False):
            dirnames[:] = sorted(d for d in dirnames if not is_skipped_dir(d))
            for name in sorted(filenames):
                if name.startswith("."):     # hidden + AppleDouble ._files
                    continue
                if os.path.splitext(name)[1].lower() in VIDEO_EXTENSIONS:
                    yield os.path.join(dirpath, name)


# ---------------------------------------------------------------------------
# Per-file evaluation
# ---------------------------------------------------------------------------

def probe_duration(path):
    """Best-effort media duration in seconds via ffprobe (None if unknown)."""
    try:
        proc = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", path],
            capture_output=True, text=True, timeout=30)
        if proc.returncode == 0:
            return round(float(proc.stdout.strip()), 2)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        pass
    return None


def evaluate_file(binary, path, args):
    """Run the person-eval CLI on one file. Returns a JSONL-ready record."""
    started = time.monotonic()
    record = {"path": path, "presence": "none", "totalHits": 0,
              "duration": probe_duration(path), "elapsed": 0.0, "error": None}
    cmd = [
        binary, "--person-eval",
        "--engine", "arcface",
        "--person", args.person,
        "--references", args.references,
        "--video", path,
        "--frame-step", str(args.frame_step),
        "--aggregation", "minimum-hits",
        "--min-hits", str(args.min_hits),
    ]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True)
        payload = None
        # JSON is the last stdout line (schema v2); stderr carries logs.
        for line in reversed(proc.stdout.splitlines()):
            line = line.strip()
            if line.startswith("{"):
                try:
                    payload = json.loads(line)
                except json.JSONDecodeError:
                    pass
                break
        if payload is not None:
            record["presence"] = payload.get("presence", "none")
            record["totalHits"] = payload.get("hits", 0)
            if payload.get("error"):
                record["error"] = str(payload["error"])
        if proc.returncode != 0 and record["error"] is None:
            stderr_tail = proc.stderr.strip().splitlines()[-1:] or ["(no stderr)"]
            record["error"] = "exit %d: %s" % (proc.returncode, stderr_tail[0])
    except OSError as exc:
        record["error"] = "launch failed: %s" % exc
    record["elapsed"] = round(time.monotonic() - started, 2)
    return record


# ---------------------------------------------------------------------------
# Resume log
# ---------------------------------------------------------------------------

def load_progress(jsonl_path):
    """Return (records list, set of already-processed paths). Tolerates a
    truncated final line from an interrupted run."""
    records, seen = [], set()
    if not os.path.exists(jsonl_path):
        return records, seen
    with open(jsonl_path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue  # torn write from a previous Ctrl-C — ignore
            if isinstance(rec, dict) and "path" in rec:
                records.append(rec)
                seen.add(rec["path"])
    return records, seen


def append_progress(fh, lock, record):
    line = json.dumps(record, ensure_ascii=False)
    with lock:
        fh.write(line + "\n")
        fh.flush()
        os.fsync(fh.fileno())


# ---------------------------------------------------------------------------
# Reports
# ---------------------------------------------------------------------------

def classify(records):
    """Split into (confirmed, near_miss, errors); each sorted by hits desc."""
    by_hits = lambda r: (-int(r.get("totalHits") or 0), r["path"])  # noqa: E731
    confirmed = sorted((r for r in records if r.get("presence") == "confirmed"),
                       key=by_hits)
    near_miss = sorted(
        (r for r in records
         if r.get("presence") != "confirmed"
         and int(r.get("totalHits") or 0) >= NEAR_MISS_MIN_HITS),
        key=by_hits)
    errors = [r for r in records if r.get("error")]
    return confirmed, near_miss, errors


def write_csv(path, confirmed, near_miss):
    with open(path, "w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        writer.writerow(["path", "presence", "totalHits", "duration"])
        for rec in confirmed + near_miss:
            writer.writerow([rec["path"], rec.get("presence", "none"),
                             rec.get("totalHits", 0),
                             rec.get("duration") if rec.get("duration") is not None else ""])


def fmt_duration(seconds):
    if seconds is None:
        return "—"
    seconds = int(seconds)
    return "%d:%02d" % divmod(seconds, 60)


def html_rows(records):
    rows = []
    for rec in records:
        href = "file://" + urllib.parse.quote(rec["path"])
        rows.append(
            "<tr><td><a href=\"%s\">%s</a></td>"
            "<td class=\"num\">%s</td><td class=\"num\">%s</td></tr>"
            % (href, html.escape(rec["path"]),
               rec.get("totalHits", 0), fmt_duration(rec.get("duration"))))
    return "\n".join(rows)


def write_html(path, confirmed, near_miss, errors, meta):
    doc = """<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<title>Donna candidates</title>
<style>
  body {{ font-family: -apple-system, Helvetica, sans-serif; margin: 2em;
         color: #222; }}
  h1 {{ font-size: 1.4em; }}  h2 {{ font-size: 1.1em; margin-top: 2em; }}
  table {{ border-collapse: collapse; width: 100%; }}
  th, td {{ text-align: left; padding: 4px 10px;
            border-bottom: 1px solid #ddd; font-size: 0.9em; }}
  td.num {{ text-align: right; font-variant-numeric: tabular-nums; }}
  .meta {{ color: #666; font-size: 0.85em; }}
  .note {{ background: #fff8e1; padding: 8px 12px; border-radius: 6px;
           font-size: 0.85em; }}
</style></head><body>
<h1>Donna candidates</h1>
<p class="meta">{meta}</p>
<h2>Confirmed ({nconf}) — presence rule: totalHits &ge; {minhits}</h2>
<table><tr><th>File</th><th>Hits</th><th>Duration</th></tr>
{conf_rows}
</table>
<h2>Near miss ({nnear}) — presence none, totalHits &ge; {nearfloor}</h2>
<p class="note">Curation gold: each near miss is either a genuine Donna clip
the floor rejected (a potential miss → holdout candidate) or a strong
lookalike (a hard negative → training-pool addition).</p>
<table><tr><th>File</th><th>Hits</th><th>Duration</th></tr>
{near_rows}
</table>
<h2>Errors ({nerr})</h2>
<table><tr><th>File</th><th>Error</th></tr>
{err_rows}
</table>
</body></html>
"""
    err_rows = "\n".join(
        "<tr><td>%s</td><td>%s</td></tr>"
        % (html.escape(r["path"]), html.escape(str(r.get("error"))))
        for r in errors)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(doc.format(
            meta=html.escape(meta), nconf=len(confirmed),
            minhits=html.escape(str(META_MIN_HITS[0])),
            conf_rows=html_rows(confirmed), nnear=len(near_miss),
            nearfloor=NEAR_MISS_MIN_HITS, near_rows=html_rows(near_miss),
            nerr=len(errors), err_rows=err_rows))


META_MIN_HITS = [7]  # filled from args at runtime (module-level for the template)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def parse_args(argv):
    parser = argparse.ArgumentParser(
        description="Batch Donna scan: person-eval every video under the "
                    "given roots and emit a curation report.")
    parser.add_argument("roots", nargs="+",
                        help="volume(s) or folder(s) to scan")
    parser.add_argument("--out", required=True, help="report directory")
    parser.add_argument("--frame-step", type=int, default=10)
    parser.add_argument("--min-hits", type=int, default=7,
                        help="confirmation floor (POI C3 default: 7)")
    parser.add_argument("--limit", type=int, default=None,
                        help="process at most N files this session (testing)")
    parser.add_argument("--resume", action=argparse.BooleanOptionalAction,
                        default=True,
                        help="skip files already in scan-progress.jsonl "
                             "(default on; --no-resume archives the old log)")
    parser.add_argument("--jobs", type=int, default=1,
                        help="parallel evaluations (default 1 — keep it there "
                             "for HDD roots)")
    parser.add_argument("--binary", default=None,
                        help="path to the Release VideoScan binary")
    parser.add_argument("--person", default="Donna")
    parser.add_argument("--references", default=DEFAULT_REFERENCES,
                        help="reference photo dir (default: production Donna refs)")
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    META_MIN_HITS[0] = args.min_hits
    binary = find_binary(args.binary)
    if not os.path.isdir(args.references):
        sys.exit("error: references dir not found: %s" % args.references)

    os.makedirs(args.out, exist_ok=True)
    jsonl_path = os.path.join(args.out, "scan-progress.jsonl")
    csv_path = os.path.join(args.out, "donna_candidates.csv")
    html_path = os.path.join(args.out, "donna_candidates.html")

    if not args.resume and os.path.exists(jsonl_path):
        backup = jsonl_path + ".bak-" + time.strftime("%Y%m%d-%H%M%S")
        os.rename(jsonl_path, backup)
        print("moved previous progress log to %s" % backup)

    prior_records, seen = load_progress(jsonl_path)
    if prior_records:
        print("resuming: %d file(s) already recorded" % len(prior_records))

    print("enumerating %s ..." % ", ".join(args.roots))
    all_files = list(enumerate_videos(args.roots))
    todo = [p for p in all_files if p not in seen]
    if args.limit is not None:
        todo = todo[:args.limit]
    total = len(todo)
    print("found %d video file(s); %d to process (binary: %s)"
          % (len(all_files), total, binary))

    session_records = []
    started = time.monotonic()
    lock = threading.Lock()
    counter = [0]
    interrupted = False

    def report_line(record):
        with lock:
            counter[0] += 1
            n = counter[0]
        verdict = record["presence"]
        if record["error"]:
            verdict = "ERROR"
        print("[%d/%d] %s — %s (%d hits) [%.1fs]"
              % (n, total, os.path.basename(record["path"]), verdict,
                 record.get("totalHits", 0), record["elapsed"]), flush=True)

    with open(jsonl_path, "a", encoding="utf-8") as progress_fh:
        def work(path):
            record = evaluate_file(binary, path, args)
            append_progress(progress_fh, lock, record)
            session_records.append(record)
            report_line(record)

        try:
            if args.jobs <= 1:
                for path in todo:
                    work(path)
            else:
                with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
                    futures = [pool.submit(work, p) for p in todo]
                    for future in concurrent.futures.as_completed(futures):
                        future.result()
        except KeyboardInterrupt:
            interrupted = True
            print("\ninterrupted — progress log is valid; rerun to resume.",
                  flush=True)

    # Reports cover EVERYTHING recorded so far (prior sessions + this one).
    all_records = prior_records + session_records
    confirmed, near_miss, errors = classify(all_records)
    meta = ("Roots: %s • generated %s • frame-step %d, min-hits %d • "
            "%d files recorded"
            % (", ".join(args.roots), time.strftime("%Y-%m-%d %H:%M"),
               args.frame_step, args.min_hits, len(all_records)))
    write_csv(csv_path, confirmed, near_miss)
    write_html(html_path, confirmed, near_miss, errors, meta)

    elapsed = time.monotonic() - started
    print("\n=== summary ===")
    print("processed this session: %d  (total recorded: %d)"
          % (len(session_records), len(all_records)))
    print("confirmed: %d   near-miss: %d   errors: %d"
          % (len(confirmed), len(near_miss), len(errors)))
    print("elapsed: %s" % fmt_duration(elapsed))
    print("report: %s" % html_path)
    return 130 if interrupted else 0


if __name__ == "__main__":
    signal.signal(signal.SIGINT, signal.default_int_handler)
    sys.exit(main())
