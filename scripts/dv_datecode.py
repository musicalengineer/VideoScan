#!/usr/bin/env python3
"""dv_datecode.py — tabulate the DV recording datecode over the catalog's DV files.

A one-day evidence test (docs/design/machine_intelligence.md §11;
docs/design/background_service.md §10 "DV datecode — yes, a day").
A DV camcorder writes the recording date/time into every frame (VAUX/SSYB
packs); a stream copy keeps it, a re-encode loses it, and analog tape passed
through a DV bridge never had one. `dvrescue` (MediaArea, Brewfile) reports it
as the `rdt` attribute of the `<frame>` elements it lists at segment
boundaries. This script asks: on how many of our DV files is it there, and how
often does it disagree with the file-system mtime (the transfer date)?

READ-ONLY. The catalog is read only through scripts/catalog_db.connect(); the
media is opened for reading; nothing is written except the results file.

How a file is read (head-only by default; `--full` reads the whole file):
  * raw DV (the file starts with a DIF header block, 1F 07 00): byte windows
    copied to a temp file and handed to dvrescue — the head (12 MB, ~100 NTSC
    frames); if no rdt there, the head extended to 120 MB (a capture's lead-in
    of black or blue can run several seconds before the camcorder's first
    recorded frame); if still none, 12 MB from the middle. Window offsets are
    aligned to 1,440,000 bytes, a whole number of frames for NTSC/PAL DV25 and
    DV50 (an unaligned window decodes garbage dates — seen on the corpus).
  * wrapped DV (mov/mxf/avi/mkv; `--include-wrapped`): the same windows in
    frames (100, 1000, 100 at the middle), cut with `ffmpeg -c copy -f rawvideo`,
    which copies the DIF frames byte for byte (VAUX included; `-f dv` would
    re-write the packs and must not be used).
  * an rdt is a date only if it parses and its year is in [1995, this year]
    (DV shipped in 1995; ffmpeg's muxer writes 1970 when it has no date);
    others are counted as `implausible` and never reported as a date.

Output: one JSON line per content digest (identity is the whole-file SHA-256;
no paths, no names) in .scratch/dv-datecode/<stamp>.jsonl (git-ignored), and
a SUMMARY of counts on stdout. `--resume FILE` appends to FILE and skips the
digests already in it; Ctrl-C stops after the current file and still prints
the summary.

Worst-case memory: one window is streamed to a temp file in 1 MB chunks
(disk: <= 120 MB per file, deleted after); dvrescue's XML is read line by
line, so a --full read of a 13 h tape holds one line plus the parsed result
(first/last rdt, the set of distinct days: <= a few thousand short strings).
The catalog load (catalog_db.records) is the one O(records) structure.

Usage:
  venv/bin/python3 scripts/dv_datecode.py [--include-wrapped] [--limit N]
      [--timeout S] [--resume FILE] [--full --digest PREFIX ...]
  venv/bin/python3 scripts/dv_datecode.py --summarize FILE
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from collections import Counter
from datetime import datetime
from pathlib import Path
from typing import Callable, Iterable

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

DV_CODECS = {"dvvideo", "dv 25", "dv25", "dv 50", "dv50", "dvcpro", "dvcpro50"}
DIF_MAGIC = b"\x1f\x07\x00"
FRAME_ALIGN = 1_440_000            # lcm of 120000/144000/240000/288000 bytes (NTSC/PAL DV25, DV50)
RAW_WINDOWS = (("head", 0, 12_000_000), ("extended", 0, 120_000_000), ("middle", None, 12_000_000))
WRAPPED_WINDOWS = (("head", 0, 100), ("extended", 0, 1000), ("middle", None, 100))
MIN_YEAR = 1995
CHUNK = 1 << 20

_FRAME = re.compile(r"<frame\s[^>]*>")
_FRAMES_COUNT = re.compile(r'<frames\s[^>]*?\bcount="(\d+)"')
_ATTR = {k: re.compile(rf'\b{k}="([^"]*)"') for k in ("rdt", "tc")}


# ---------------------------------------------------------------- parsing (pure)

def parse_rdt_lines(lines: Iterable[str], max_year: int | None = None) -> dict:
    """dvrescue XML (as lines; a torn tail is fine) -> the recording-date facts.

    first/last: the first and last plausible rdt in stream order ("YYYY-MM-DD HH:MM:SS");
    days: sorted distinct plausible days; frames: frames dvrescue analysed (sum of
    <frames count>); tc_first: the first timecode; implausible: rdt values that do not
    parse or fall outside [MIN_YEAR, max_year]."""
    max_year = max_year or datetime.now().year
    first = last = tc_first = None
    days: set[str] = set()
    frames = implausible = 0
    for line in lines:
        for m in _FRAMES_COUNT.finditer(line):
            frames += int(m.group(1))
        for el in _FRAME.findall(line):
            tc = _ATTR["tc"].search(el)
            if tc and tc_first is None:
                tc_first = tc.group(1)
            rdt = _ATTR["rdt"].search(el)
            if not rdt:
                continue
            value = rdt.group(1)
            try:
                when = datetime.strptime(value, "%Y-%m-%d %H:%M:%S")
            except ValueError:
                implausible += 1
                continue
            if not MIN_YEAR <= when.year <= max_year:
                implausible += 1
                continue
            first = first or value
            last = value
            days.add(value[:10])
    return {"first": first, "last": last, "days": sorted(days), "frames": frames,
            "tc_first": tc_first, "implausible": implausible}


def parse_rdt(xml: str, max_year: int | None = None) -> dict:
    """parse_rdt_lines over one XML string (tests, small outputs)."""
    return parse_rdt_lines((xml or "").splitlines(), max_year)


def is_raw_dv(head: bytes) -> bool:
    """A raw DV stream starts with a DIF header block (SCT 0, Dseq 0, DBN 0)."""
    return head[:3] == DIF_MAGIC


def aligned(offset: int, align: int = FRAME_ALIGN) -> int:
    return offset - offset % align


# ---------------------------------------------------------------- selection (pure)

def select_dv(records: list[dict], include_wrapped: bool, exists: Callable[[str], bool] = os.path.exists,
              digests: list[str] | None = None) -> tuple[list[dict], dict]:
    """Live catalog records -> one target per content digest (first existing path, sorted).

    Raw DV: ext dv, or a DV codec in a container the catalog calls DV. Wrapped: a DV codec in
    any other container (only with include_wrapped). Returns (targets, counts)."""
    by_digest: dict[str, dict] = {}
    for rec in records:
        if rec.get("removal") is not None:
            continue
        digest = (rec.get("contentFixity") or {}).get("sha256")
        if not digest:
            continue
        if digests and not any(digest.startswith(p) for p in digests):
            continue
        ext = (rec.get("ext") or "").lower()
        codec = (rec.get("videoCodec") or "").lower()
        container = (rec.get("container") or "").lower()
        dv_codec = codec in DV_CODECS
        if ext == "dv" or (dv_codec and container.startswith("dv")):
            kind = "raw"
        elif dv_codec and include_wrapped:
            kind = "wrapped"
        else:
            continue
        slot = by_digest.setdefault(digest, {"digest": digest, "kind": kind, "paths": [],
                                             "duration": rec.get("durationSeconds")})
        if kind == "raw":
            slot["kind"] = "raw"
        if rec.get("fullPath"):
            slot["paths"].append(rec["fullPath"])
    targets, missing = [], 0
    for digest in sorted(by_digest):
        slot = by_digest[digest]
        path = next((p for p in sorted(slot["paths"]) if exists(p)), None)
        if path is None:
            missing += 1
            continue
        targets.append({"digest": digest, "kind": slot["kind"], "path": path, "duration": slot["duration"]})
    return targets, {"selected": len(by_digest), "not_on_disk": missing}


# ---------------------------------------------------------------- summary (pure)

def summarize(results: list[dict]) -> dict:
    """Per-file results -> counts only (no digests, no paths). Last line per digest wins."""
    latest = {r["digest"]: r for r in results if r.get("digest")}
    rows = list(latest.values())
    s = Counter()
    decades, windows, kinds = Counter(), Counter(), Counter()
    for r in rows:
        s["probed"] += 1
        kinds[r.get("kind") or "?"] += 1
        status = r.get("status")
        s[status] += 1
        if status != "rdt":
            continue
        windows[r.get("window") or "?"] += 1
        year = int(r["rdt_first"][:4])
        decades[f"{year // 10 * 10}s"] += 1
        my = r.get("mtime_year")
        if my is None:
            s["mtime_unknown"] += 1
        elif year == my:
            s["rdt_year_eq_mtime"] += 1
        elif year < my:
            s["rdt_year_lt_mtime"] += 1
        else:
            s["rdt_year_gt_mtime"] += 1
        if len(r.get("days") or []) > 1:
            s["several_days"] += 1
    return {"probed": s["probed"], "with_rdt": s["rdt"], "without_rdt": s["no-rdt"],
            "implausible_only": s["implausible"], "not_dv": s["not-dv"], "timeouts": s["timeout"], "errors": s["error"],
            "rdt_year_eq_mtime": s["rdt_year_eq_mtime"], "rdt_year_lt_mtime": s["rdt_year_lt_mtime"],
            "rdt_year_gt_mtime": s["rdt_year_gt_mtime"], "mtime_unknown": s["mtime_unknown"],
            "several_days": s["several_days"],
            "by_decade": dict(sorted(decades.items())), "found_in_window": dict(sorted(windows.items())),
            "by_kind": dict(sorted(kinds.items())),
            "elapsed_s": round(sum(float(r.get("elapsed_s") or 0) for r in rows), 1)}


def format_summary(s: dict, extra: dict | None = None) -> str:
    lines = ["SUMMARY dv_datecode"]
    for k, v in (extra or {}).items():
        lines.append(f"  {k}: {v}")
    for k in ("probed", "with_rdt", "without_rdt", "implausible_only", "not_dv", "timeouts", "errors",
              "rdt_year_eq_mtime", "rdt_year_lt_mtime", "rdt_year_gt_mtime", "mtime_unknown", "several_days"):
        lines.append(f"  {k}: {s[k]}")
    for k in ("by_decade", "found_in_window", "by_kind"):
        lines.append(f"  {k}: " + (", ".join(f"{a} {b}" for a, b in s[k].items()) or "-"))
    lines.append(f"  probe_time_s (sum over files): {s['elapsed_s']}")
    return "\n".join(lines)


def load_results(path: Path) -> list[dict]:
    """Every whole JSON line of a results file; a torn last line (interrupted write) is skipped."""
    out = []
    if not path.exists():
        return out
    with path.open(encoding="utf-8") as f:
        for line in f:
            try:
                out.append(json.loads(line))
            except ValueError:
                continue
    return out


# ---------------------------------------------------------------- reading media

class ProbeTimeout(Exception):
    pass


def _with_timeout(fn: Callable[[], object], seconds: float):
    """Run fn on a daemon thread; ProbeTimeout if it does not finish (a stalled volume).
    C++: a std::async you stop waiting for; the thread is abandoned, not killed."""
    box: dict = {}

    def run():
        try:
            box["value"] = fn()
        except BaseException as e:  # noqa: BLE001 — re-raised on the caller's thread
            box["error"] = e
    t = threading.Thread(target=run, daemon=True)
    t.start()
    t.join(seconds)
    if t.is_alive():
        raise ProbeTimeout()
    if "error" in box:
        raise box["error"]
    return box.get("value")


def _read_head(src: Path, n: int = 4) -> bytes:
    with open(src, "rb") as f:
        return f.read(n)


def copy_window(src: Path, offset: int, length: int, dest: Path) -> int:
    """Copy src[offset:offset+length] to dest in CHUNK pieces; returns bytes written."""
    written = 0
    with open(src, "rb") as f, open(dest, "wb") as out:
        f.seek(offset)
        while written < length:
            block = f.read(min(CHUNK, length - written))
            if not block:
                break
            out.write(block)
            written += len(block)
    return written


def run_dvrescue(dvrescue: str, path: Path, timeout: float, max_year: int | None = None) -> dict:
    """dvrescue <path>, XML streamed line by line into parse_rdt_lines; killed at timeout.
    Killed by our timer -> ProbeTimeout; died of its own signal (a crash) -> RuntimeError."""
    proc = subprocess.Popen([dvrescue, str(path)], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            text=True, errors="replace")
    fired = threading.Event()

    def expire():
        fired.set()
        proc.kill()
    timer = threading.Timer(timeout, expire)
    timer.start()
    try:
        parsed = parse_rdt_lines(proc.stdout, max_year)
        code = proc.wait()
    finally:
        timer.cancel()
        if proc.poll() is None:
            proc.kill()
            proc.wait()
    if fired.is_set():
        raise ProbeTimeout()
    if code < 0:
        raise RuntimeError(f"dvrescue signal {-code}")
    if code != 0:
        raise RuntimeError(f"dvrescue exit {code}")
    return parsed


class NotDV(Exception):
    """The catalog's codec label said DV; the bytes say otherwise (no frames to read, or not DIF)."""


def cut_wrapped(ffmpeg: str, src: Path, start_s: float | None, frames: int, dest: Path, timeout: float) -> None:
    """The first `frames` video frames from start_s, stream-copied byte for byte into dest.
    NotDV when no frame was copied or the copied bytes are not DIF (checked, not assumed)."""
    if dest.exists():
        dest.unlink()  # the temp window file of the previous step, in our own TemporaryDirectory
    cmd = [ffmpeg, "-nostdin", "-v", "error", "-y"]
    if start_s:
        cmd += ["-ss", f"{start_s:.3f}"]
    cmd += ["-i", str(src), "-map", "0:v:0?", "-c", "copy", "-frames:v", str(frames), "-f", "rawvideo", str(dest)]
    try:
        done = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=timeout)
    except subprocess.TimeoutExpired as e:
        raise ProbeTimeout() from e
    head = _read_head(dest, 3) if dest.exists() else b""
    if not head:
        # `0:v:0?` matched nothing, or the frames live elsewhere (a QuickTime reference movie:
        # a few KB of tables pointing at media files; seen on the corpus): no frames to read.
        raise NotDV("no video frames read")
    if done.returncode != 0:
        raise RuntimeError(f"ffmpeg exit {done.returncode}")
    if not is_raw_dv(head):
        raise NotDV("video is not DV")


def plan_windows(raw: bool, size: int, duration: float | None,
                 raw_windows=RAW_WINDOWS, wrapped_windows=WRAPPED_WINDOWS) -> list[tuple[str, float, int]]:
    """The head-only reads, in order: (name, start, amount). Raw: start/amount in bytes, the
    middle aligned to whole frames, windows that add nothing for a short file dropped. Wrapped:
    start in seconds, amount in frames, no middle without a duration."""
    plan = []
    for name, start, amount in (raw_windows if raw else wrapped_windows):
        if start is None:
            if raw:
                start = aligned(size // 2)
                if plan and start < plan[-1][1] + plan[-1][2]:
                    continue  # the middle is inside what the head already read
            elif duration:
                start = duration / 2
            else:
                continue
        elif raw and plan and plan[-1][2] >= size:
            continue  # the previous window already read the whole file
        plan.append((name, start, amount))
    return plan


def probe(target: dict, tools: dict, *, full: bool, timeout: float, tmp: Path,
          raw_windows=RAW_WINDOWS, wrapped_windows=WRAPPED_WINDOWS, max_year: int | None = None) -> dict:
    """One file -> one result line (no path in it). Stops at the first window with a plausible rdt."""
    src = Path(target["path"])
    t0 = time.monotonic()
    out = {"digest": target["digest"], "kind": target["kind"], "mode": "full" if full else "head",
           "window": None, "status": None, "rdt_first": None, "rdt_last": None, "days": [],
           "tc_first": None, "frames": 0, "implausible": 0, "mtime_year": None, "size": None}
    try:
        st = _with_timeout(lambda: os.stat(src), timeout)
        out["size"] = st.st_size
        out["mtime_year"] = datetime.fromtimestamp(st.st_mtime).year
        raw = is_raw_dv(_with_timeout(lambda: _read_head(src), timeout))
        out["kind"] = "raw" if raw else "wrapped"
        window_file = tmp / "window.dv"
        if full:
            plan = [("full", 0, 0)]
        else:
            plan = plan_windows(raw, st.st_size, target.get("duration"), raw_windows, wrapped_windows)
        parsed = None
        for name, start, amount in plan:
            if full:
                got = run_dvrescue(tools["dvrescue"], src, timeout, max_year)
            else:
                if raw:
                    _with_timeout(lambda: copy_window(src, int(start), amount, window_file), timeout)
                else:
                    cut_wrapped(tools["ffmpeg"], src, start or None, amount, window_file, timeout)
                got = run_dvrescue(tools["dvrescue"], window_file, timeout, max_year)
            out["implausible"] += got["implausible"]
            if parsed is None or got["frames"]:
                parsed = got
            if got["first"]:
                parsed, out["window"] = got, name
                break
            if not raw and not full and name == "head" and got["frames"] < amount:
                break  # the stream ended inside the head: nothing more to read
        parsed = parsed or parse_rdt("")
        out.update(rdt_first=parsed["first"], rdt_last=parsed["last"], days=parsed["days"],
                   tc_first=parsed["tc_first"], frames=parsed["frames"])
        out["status"] = "rdt" if parsed["first"] else ("implausible" if out["implausible"] else "no-rdt")
    except ProbeTimeout:
        out["status"] = "timeout"
    except NotDV as e:
        out["status"] = "not-dv"
        out["error"] = str(e)
    except (OSError, RuntimeError, subprocess.CalledProcessError) as e:
        out["status"] = "error"
        out["error"] = type(e).__name__ + (f" {e}" if isinstance(e, RuntimeError) else "")  # never a path
    out["elapsed_s"] = round(time.monotonic() - t0, 3)
    return out


# ---------------------------------------------------------------- CLI

def _tool(name: str) -> str | None:
    brewed = Path("/opt/homebrew/bin") / name
    return str(brewed) if brewed.exists() else shutil.which(name)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--include-wrapped", action="store_true", help="also DV inside mov/mxf/avi/mkv")
    ap.add_argument("--limit", type=int, default=0, help="probe at most N files this run (0 = all)")
    ap.add_argument("--timeout", type=float, default=60.0, help="seconds per step of one file")
    ap.add_argument("--full", action="store_true", help="read whole files (use with --digest)")
    ap.add_argument("--digest", action="append", default=[], help="digest prefix (repeatable): a named sample")
    ap.add_argument("--resume", type=Path, help="append to this results file, skipping its digests")
    ap.add_argument("--out-dir", type=Path, default=ROOT / ".scratch" / "dv-datecode")
    ap.add_argument("--summarize", type=Path, help="print the summary of a results file and exit")
    ap.add_argument("--db", help=argparse.SUPPRESS)
    args = ap.parse_args(argv)

    if args.summarize:
        print(format_summary(summarize(load_results(args.summarize))))
        return 0
    if args.full and not args.digest:
        ap.error("--full reads whole files; name the sample with --digest")
    tools = {"dvrescue": _tool("dvrescue"), "ffmpeg": _tool("ffmpeg")}
    if not tools["dvrescue"]:
        print("dvrescue not found (brew bundle; see Brewfile)", file=sys.stderr)
        return 2

    import catalog_db
    conn = catalog_db.connect(args.db)
    try:
        records = catalog_db.records(conn)
    finally:
        conn.close()
    targets, counts = select_dv(records, args.include_wrapped, digests=args.digest or None)
    del records

    if args.resume:
        out_path = args.resume
    else:
        args.out_dir.mkdir(parents=True, exist_ok=True)
        suffix = "-full" if args.full else ""
        out_path = args.out_dir / f"{datetime.now().strftime('%Y%m%d-%H%M%S')}{suffix}.jsonl"
    done = {r["digest"] for r in load_results(out_path)}
    todo = [t for t in targets if t["digest"] not in done]
    if args.limit:
        todo = todo[: args.limit]
    print(f"START dv_datecode selected={counts['selected']} not_on_disk={counts['not_on_disk']} "
          f"already_done={len(targets) - len([t for t in targets if t['digest'] not in done])} "
          f"this_run={len(todo)} mode={'full' if args.full else 'head'} out={out_path.name}", file=sys.stderr)

    stop = {"flag": False}
    signal.signal(signal.SIGTERM, lambda *_: stop.__setitem__("flag", True))
    t0 = time.monotonic()
    n = 0
    tally = Counter()
    try:
        with tempfile.TemporaryDirectory(prefix="dv-datecode-") as tmp, out_path.open("a", encoding="utf-8") as sink:
            for target in todo:
                if stop["flag"]:
                    break
                result = probe(target, tools, full=args.full, timeout=args.timeout, tmp=Path(tmp))
                sink.write(json.dumps(result, sort_keys=True) + "\n")
                sink.flush()
                n += 1
                tally[result["status"]] += 1
                if n % 25 == 0 or n == len(todo):
                    print(f"  {n}/{len(todo)} " + " ".join(f"{k}={v}" for k, v in sorted(tally.items()))
                          + f" elapsed={time.monotonic() - t0:.0f}s", file=sys.stderr, flush=True)
    except KeyboardInterrupt:
        stop["flag"] = True
    elapsed = round(time.monotonic() - t0, 1)
    outcome = "interrupted" if stop["flag"] else "complete"
    print(f"OUTCOME dv_datecode {outcome} probed_this_run={n} elapsed={elapsed}s", file=sys.stderr)
    print(format_summary(summarize(load_results(out_path)),
                         {"selected digests": counts["selected"], "not on disk": counts["not_on_disk"],
                          "this run": f"{n} files, {elapsed} s wall, {outcome}"}))
    return 130 if outcome == "interrupted" else 0


if __name__ == "__main__":
    sys.exit(main())
