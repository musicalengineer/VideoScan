"""scripts/dv_datecode.py — the DV recording-datecode tabulation (read-only evidence test).

  * LOGIC: parse_rdt on fixture XML (with rdt, without, torn, empty, several days,
    implausible years); the window plan; the byte-window reader on a synthetic file;
    the summary arithmetic; the selection rules over catalog-shaped records.
  * TRUTH: a synthetic DV file whose datecode was written by ffmpeg's DV muxer reads back
    as exactly that date — the reported rdt comes from the frames, never from the catalog.
  * MEDIA MATRIX: the same frames as raw .dv and stream-copied into mov / avi / mkv / mxf;
    a capture lead-in (no datecode for the first frames) found by the extended head; a
    datecode only in the middle; a 1970 datecode (muxer with no date) never reported.
  * ISOLATION: a stalled dvrescue becomes a timeout, not a hang; a torn results line is
    skipped; resume skips done digests; an interrupt keeps the lines already written.
  * CATALOG GUARD: the script reads the catalog only through catalog_db.connect().
  * SCALE: summary and selection over 100k rows within a budget.
"""
from __future__ import annotations

import ast
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tests"))

import dv_datecode as dvd  # noqa: E402
from catalog_sqlite_fixture import Catalog  # noqa: E402

SCRIPT = ROOT / "scripts" / "dv_datecode.py"
DVRESCUE = dvd._tool("dvrescue")
FFMPEG = dvd._tool("ffmpeg")
needs_tools = pytest.mark.skipif(not (DVRESCUE and FFMPEG), reason="dvrescue and ffmpeg (Brewfile) required")
TOOLS = {"dvrescue": DVRESCUE, "ffmpeg": FFMPEG}
SMALL_RAW = (("head", 0, 1_200_000), ("extended", 0, 2_400_000), ("middle", None, 1_200_000))
SMALL_WRAPPED = (("head", 0, 10), ("extended", 0, 20), ("middle", None, 10))

HEADER = ('<?xml version="1.0" encoding="UTF-8"?>\n<dvrescue xmlns="https://mediaarea.net/dvrescue" version="1.2.1">\n'
          '\t<media ref="/x/y.dv" format="DV" size="7080000">\n')


def _xml(*frames_blocks: tuple[int, list[str]], close: bool = True) -> str:
    body = ""
    for count, frames in frames_blocks:
        body += f'\t\t<frames count="{count}" pts="00:00:00.000000" size="720x480" video_rate="30000/1001">\n'
        body += "".join(f"\t\t\t<frame {f}/>\n" for f in frames)
        body += "\t\t</frames>\n"
    return HEADER + body + ("\t</media>\n</dvrescue>\n" if close else "")


# ---------------------------------------------------------------- parse_rdt

def test_parse_rdt_with_a_datecode():
    xml = _xml((59, ['n="0" pos="0" tc="00:42:06;29" rdt="2007-07-20 20:00:56" rec_start="1" seqn="5"',
                     'n="58" pos="6960000" tc="00:42:08;27" rdt="2007-07-20 20:00:58" seqn="3"']))
    got = dvd.parse_rdt(xml, max_year=2026)
    assert got == {"first": "2007-07-20 20:00:56", "last": "2007-07-20 20:00:58", "days": ["2007-07-20"],
                   "frames": 59, "tc_first": "00:42:06;29", "implausible": 0}


def test_parse_rdt_without_a_datecode():
    xml = _xml((138204, ['n="0" pos="0" tc="00:40:40:00" seqn="2"', 'n="1" pos="120000" tc="00:40:40:00" tc_r="1"']))
    got = dvd.parse_rdt(xml, max_year=2026)
    assert got["first"] is None and got["last"] is None and got["days"] == []
    assert got["frames"] == 138204 and got["tc_first"] == "00:40:40:00" and got["implausible"] == 0


def test_parse_rdt_torn_and_empty():
    whole = _xml((3, ['n="0" tc="00:00:01;00" rdt="2006-12-25 13:24:37"', 'n="2" tc="00:00:01;02" rdt="2006-12-25 13:25:51"']))
    torn = whole[: whole.index('n="2"') + 12]  # killed mid-element: the torn element is ignored
    got = dvd.parse_rdt(torn, max_year=2026)
    assert got["first"] == got["last"] == "2006-12-25 13:24:37" and got["frames"] == 3
    for empty in ("", "<?xml", "not xml at all", None):
        assert dvd.parse_rdt(empty) == {"first": None, "last": None, "days": [], "frames": 0,
                                        "tc_first": None, "implausible": 0}


def test_parse_rdt_several_days_and_segments():
    xml = _xml((100, ['n="0" tc="00:00:00;00" rdt="2005-12-24 23:59:58"', 'n="99" rdt="2005-12-25 00:00:01"']),
               (50, ['n="100" tc="00:10:00;00" rdt="2006-01-01 10:00:00"', 'n="149" rdt="2005-12-25 08:00:00"']))
    got = dvd.parse_rdt(xml, max_year=2026)
    assert got["first"] == "2005-12-24 23:59:58"
    assert got["last"] == "2005-12-25 08:00:00"  # stream order, not chronological
    assert got["days"] == ["2005-12-24", "2005-12-25", "2006-01-01"]
    assert got["frames"] == 150


def test_parse_rdt_implausible_dates_are_counted_never_reported():
    xml = _xml((4, ['n="0" rdt="1970-01-01 00:00:00"',          # ffmpeg muxer with no date
                    'n="1" rdt="2034-06-11 13:36:32"',          # an unaligned window's garbage
                    'n="2" rdt="2005-13-45 99:00:00"',          # does not parse
                    'n="3" rdt="1994-12-31 23:59:59"']))        # before DV existed
    got = dvd.parse_rdt(xml, max_year=2026)
    assert got["first"] is None and got["days"] == [] and got["implausible"] == 4


# ---------------------------------------------------------------- byte windows, plan

def test_copy_window_on_a_synthetic_byte_file(tmp_path):
    src = tmp_path / "src.bin"
    src.write_bytes(bytes(range(256)) * 10_000)  # 2.56 MB, CHUNK-crossing
    dest = tmp_path / "w.bin"
    assert dvd.copy_window(src, 0, 1_500_000, dest) == 1_500_000
    assert dest.read_bytes() == src.read_bytes()[:1_500_000]
    assert dvd.copy_window(src, 2_000_000, 10_000_000, dest) == 560_000  # short tail
    assert dest.read_bytes() == src.read_bytes()[2_000_000:]
    assert dvd.copy_window(src, 9_000_000, 100, dest) == 0  # past EOF
    assert dest.read_bytes() == b""


def test_alignment_and_dif_magic():
    for frame in (120_000, 144_000, 240_000, 288_000):
        assert dvd.FRAME_ALIGN % frame == 0
    assert dvd.aligned(3_441_372_345) == 3_440_160_000 and dvd.aligned(1_439_999) == 0
    assert dvd.is_raw_dv(b"\x1f\x07\x00\x3f") and not dvd.is_raw_dv(b"\x00\x00\x00\x14ftyp") and not dvd.is_raw_dv(b"")


def test_plan_windows():
    assert dvd.plan_windows(True, 7_080_000, None) == [("head", 0, 12_000_000)]
    assert dvd.plan_windows(True, 50_000_000, None) == [("head", 0, 12_000_000), ("extended", 0, 120_000_000)]
    big = dvd.plan_windows(True, 6_882_720_000, None)
    assert big[:2] == [("head", 0, 12_000_000), ("extended", 0, 120_000_000)]
    assert big[2][0] == "middle" and big[2][1] % dvd.FRAME_ALIGN == 0 and big[2][1] <= 6_882_720_000 // 2
    assert dvd.plan_windows(False, 10**9, None) == [("head", 0, 100), ("extended", 0, 1000)]
    assert dvd.plan_windows(False, 10**9, 600.0)[2] == ("middle", 300.0, 100)


# ---------------------------------------------------------------- summary arithmetic

def _r(digest, status, rdt=None, mtime=2008, window="head", kind="raw", days=None, elapsed=1.0):
    return {"digest": digest, "status": status, "rdt_first": rdt, "mtime_year": mtime, "window": window,
            "kind": kind, "days": days if days is not None else ([rdt[:10]] if rdt else []), "elapsed_s": elapsed}


def test_summary_arithmetic():
    rows = [_r("a", "rdt", "2007-07-20 20:00:56", 2008),
            _r("b", "rdt", "2005-12-25 13:15:12", 2005, window="extended"),
            _r("c", "rdt", "1999-01-01 00:00:00", 2023, days=["1999-01-01", "1999-01-02"]),
            _r("d", "rdt", "2012-01-01 00:00:00", 2010, kind="wrapped", window="middle"),
            _r("e", "no-rdt"), _r("f", "implausible"), _r("g", "timeout"), _r("h", "error"), _r("j", "not-dv"),
            _r("i", "no-rdt"),
            _r("i", "rdt", "2003-06-28 22:08:14", 2003)]  # a later line for the same digest wins
    s = dvd.summarize(rows)
    assert (s["probed"], s["with_rdt"], s["without_rdt"], s["implausible_only"], s["not_dv"], s["timeouts"],
            s["errors"]) == (10, 5, 1, 1, 1, 1, 1)
    assert s["probed"] == (s["with_rdt"] + s["without_rdt"] + s["implausible_only"] + s["not_dv"] + s["timeouts"]
                           + s["errors"])
    assert (s["rdt_year_eq_mtime"], s["rdt_year_lt_mtime"], s["rdt_year_gt_mtime"]) == (2, 2, 1)
    assert s["by_decade"] == {"1990s": 1, "2000s": 3, "2010s": 1}
    assert s["found_in_window"] == {"extended": 1, "head": 3, "middle": 1}
    assert s["by_kind"] == {"raw": 9, "wrapped": 1} and s["several_days"] == 1 and s["elapsed_s"] == 10.0
    text = dvd.format_summary(s)
    assert "probed: 10" in text and "2000s 3" in text
    rows_named = [dict(r, digest="feedface" + r["digest"]) for r in rows]
    assert "feedface" not in dvd.format_summary(dvd.summarize(rows_named))  # counts only, never a digest


def test_summary_of_nothing_is_zeros():
    s = dvd.summarize([])
    assert s["probed"] == 0 and s["by_decade"] == {} and "by_decade: -" in dvd.format_summary(s)


def test_load_results_skips_a_torn_line(tmp_path):
    p = tmp_path / "r.jsonl"
    p.write_text(json.dumps(_r("a", "rdt", "2007-07-20 20:00:56")) + "\n" + '{"digest": "b", "sta')
    assert [r["digest"] for r in dvd.load_results(p)] == ["a"]
    assert dvd.load_results(tmp_path / "absent.jsonl") == []


# ---------------------------------------------------------------- selection

def _rec(path, digest, ext="dv", codec="dvvideo", container="DV (Digital Video)", removal=None, duration=60.0):
    return {"fullPath": path, "ext": ext, "videoCodec": codec, "container": container, "durationSeconds": duration,
            "contentFixity": {"sha256": digest} if digest else None, "removal": removal}


def test_select_dv_rules():
    recs = [_rec("/v/b/a.dv", "d1"), _rec("/v/a/a.dv", "d1"),                      # one digest, two copies
            _rec("/v/x.dv", "d2", removal={"state": "inTrash"}),                    # removed: not selected
            _rec("/v/nohash.dv", None),                                             # no identity: skipped
            _rec("/v/raw_noext", "d3", ext=""),                                     # DV container, no ext
            _rec("/v/w.mov", "d4", ext="mov", container="QuickTime / MOV"),         # wrapped
            _rec("/v/w.mxf", "d5", ext="mxf", codec="DV 25", container="MXF (CDCI)"),
            _rec("/v/h.mp4", "d6", ext="mp4", codec="h264", container="MPEG-4"),    # not DV
            _rec("/gone/g.dv", "d7")]                                               # not on disk
    exists = lambda p: not p.startswith("/gone")  # noqa: E731
    targets, counts = dvd.select_dv(recs, False, exists)
    assert [(t["digest"], t["kind"], t["path"]) for t in targets] == [("d1", "raw", "/v/a/a.dv"), ("d3", "raw", "/v/raw_noext")]
    assert counts == {"selected": 3, "not_on_disk": 1}
    targets, counts = dvd.select_dv(recs, True, exists)
    assert {t["digest"]: t["kind"] for t in targets} == {"d1": "raw", "d3": "raw", "d4": "wrapped", "d5": "wrapped"}
    targets, _ = dvd.select_dv(recs, True, exists, digests=["d4"])
    assert [t["digest"] for t in targets] == ["d4"]


# ---------------------------------------------------------------- catalog guard

def test_reads_the_catalog_only_through_catalog_db():
    tree = ast.parse(SCRIPT.read_text(encoding="utf-8"))
    strings = [n.value for n in ast.walk(tree) if isinstance(n, ast.Constant) and isinstance(n.value, str)]
    assert not any("catalog.sqlite" in s or "catalog.json" in s for s in strings)
    imports = {a.name for n in ast.walk(tree) if isinstance(n, (ast.Import, ast.ImportFrom))
               for a in n.names} | {n.module for n in ast.walk(tree) if isinstance(n, ast.ImportFrom)}
    assert "sqlite3" not in imports and "catalog_db" in imports
    calls = [n for n in ast.walk(tree) if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)
             and isinstance(n.func.value, ast.Name) and n.func.value.id == "catalog_db"]
    assert {c.func.attr for c in calls} <= {"connect", "records"} and "connect" in {c.func.attr for c in calls}


# ---------------------------------------------------------------- media (real dvrescue + ffmpeg)

def _ff(*args):
    subprocess.run([FFMPEG, "-nostdin", "-v", "error", "-y", *args], check=True)


def _dv(path: Path, frames: int, when: str | None) -> Path:
    """NTSC DV25 frames; `when` → the DV muxer writes it as the datecode; None → encoder-only (no VAUX date)."""
    src = ["-f", "lavfi", "-i", "testsrc=size=720x480:rate=30000/1001", "-frames:v", str(frames),
           "-c:v", "dvvideo", "-pix_fmt", "yuv411p", "-an"]
    if when:
        _ff(*src, "-metadata", f"creation_time={when}", "-f", "dv", str(path))
    else:
        _ff(*src, "-f", "rawvideo", str(path))
    return path


def _cat(dest: Path, *parts: Path) -> Path:
    dest.write_bytes(b"".join(p.read_bytes() for p in parts))
    return dest


def _probe(path: Path, tmp: Path, kind="raw", duration=None, **kw):
    work = tmp / "work"
    work.mkdir(exist_ok=True)
    return dvd.probe({"digest": path.name, "kind": kind, "path": str(path), "duration": duration}, TOOLS,
                     full=kw.pop("full", False), timeout=kw.pop("timeout", 30), tmp=work,
                     raw_windows=SMALL_RAW, wrapped_windows=SMALL_WRAPPED, max_year=2026, **kw)


@needs_tools
def test_truth_the_reported_date_is_the_one_in_the_frames(tmp_path):
    f = _dv(tmp_path / "cam.dv", 30, "2003-06-28T22:08:14Z")
    os.utime(f, (1_700_000_000, 1_700_000_000))  # the transfer: mtime 2023
    r = _probe(f, tmp_path)
    assert (r["status"], r["window"], r["kind"]) == ("rdt", "head", "raw")
    assert r["rdt_first"] == "2003-06-28 22:08:14" and r["days"] == ["2003-06-28"] and r["mtime_year"] == 2023
    assert "path" not in r and str(tmp_path) not in json.dumps(r)


@needs_tools
@pytest.mark.parametrize("ext,extra", [("mov", []), ("avi", []), ("mkv", []), ("mxf", ["-an"])])
def test_media_matrix_wrapped_dv_keeps_the_datecode(tmp_path, ext, extra):
    raw = _dv(tmp_path / "cam.dv", 30, "2006-12-25T13:24:37Z")
    wrapped = tmp_path / f"cam.{ext}"
    _ff("-r", "30000/1001", "-i", str(raw), "-c", "copy", *extra, str(wrapped))
    r = _probe(wrapped, tmp_path, kind="wrapped", duration=1.0)
    assert (r["status"], r["kind"], r["window"], r["rdt_first"][:10]) == ("rdt", "wrapped", "head", "2006-12-25")


@needs_tools
def test_a_capture_lead_in_is_read_past_by_the_extended_head(tmp_path):
    f = _cat(tmp_path / "leadin.dv", _dv(tmp_path / "a", 15, None), _dv(tmp_path / "b", 10, "2005-12-25T13:15:12Z"))
    r = _probe(f, tmp_path)
    assert (r["status"], r["window"], r["rdt_first"]) == ("rdt", "extended", "2005-12-25 13:15:12")


@needs_tools
def test_a_datecode_only_in_the_middle_is_found_by_the_middle_window(tmp_path):
    f = _cat(tmp_path / "mid.dv", _dv(tmp_path / "a", 60, None), _dv(tmp_path / "b", 60, "2009-05-31T00:08:34Z"))
    r = _probe(f, tmp_path)
    assert (r["status"], r["window"], r["rdt_first"][:10]) == ("rdt", "middle", "2009-05-31")
    full = _probe(f, tmp_path, full=True)
    assert (full["status"], full["window"], full["rdt_first"][:10]) == ("rdt", "full", "2009-05-31")


@needs_tools
def test_no_datecode_and_a_1970_datecode_are_never_a_date(tmp_path):
    bridge = _dv(tmp_path / "bridge.dv", 30, None)
    r = _probe(bridge, tmp_path)
    assert (r["status"], r["rdt_first"], r["window"]) == ("no-rdt", None, None)
    assert r["frames"] == 20  # frames of the last window read: the 20-frame extended head (the middle overlaps it)
    epoch = _dv(tmp_path / "epoch.dv", 10, "1970-01-01T00:00:00Z")
    r = _probe(epoch, tmp_path)
    assert r["status"] == "implausible" and r["rdt_first"] is None and r["implausible"] > 0


# ---------------------------------------------------------------- isolation

def test_a_stalled_dvrescue_is_a_timeout_not_a_hang(tmp_path):
    stall = tmp_path / "stall.sh"
    stall.write_text("#!/bin/sh\nexec sleep 30\n")
    stall.chmod(0o755)
    f = tmp_path / "x.dv"
    f.write_bytes(dvd.DIF_MAGIC + b"\0" * 1000)
    t0 = time.monotonic()
    r = dvd.probe({"digest": "x", "kind": "raw", "path": str(f), "duration": None},
                  {"dvrescue": str(stall), "ffmpeg": FFMPEG}, full=False, timeout=0.5, tmp=tmp_path)
    assert r["status"] == "timeout" and time.monotonic() - t0 < 5


def test_an_unreadable_file_is_an_error_without_its_path(tmp_path):
    r = dvd.probe({"digest": "x", "kind": "raw", "path": str(tmp_path / "secret-name.dv"), "duration": None},
                  TOOLS, full=False, timeout=5, tmp=tmp_path)
    assert r["status"] == "error" and "secret-name" not in json.dumps(r)


def test_a_crashing_dvrescue_is_an_error_not_a_timeout(tmp_path):
    """Seen on the corpus: dvrescue died of SIGBUS in 0.1 s on MPEG-2 bytes and was counted as a timeout."""
    crash = tmp_path / "crash.sh"
    crash.write_text("#!/bin/sh\nkill -BUS $$\n")
    crash.chmod(0o755)
    f = tmp_path / "x.dv"
    f.write_bytes(dvd.DIF_MAGIC + b"\0" * 1000)
    r = dvd.probe({"digest": "x", "kind": "raw", "path": str(f), "duration": None},
                  {"dvrescue": str(crash), "ffmpeg": FFMPEG}, full=False, timeout=10, tmp=tmp_path)
    assert r["status"] == "error" and "signal" in r["error"]


@needs_tools
@pytest.mark.parametrize("ext,args", [
    ("mxf", ["-f", "lavfi", "-i", "testsrc=size=720x480:rate=30000/1001", "-frames:v", "10",
             "-c:v", "mpeg2video", "-an"]),                                                     # MPEG-2 labelled "DV 25"
    ("mov", ["-f", "lavfi", "-i", "sine=r=48000", "-t", "1", "-c:a", "pcm_s16le"]),             # no video stream at all
])
def test_a_wrapped_file_that_is_not_dv_is_not_dv_not_an_error(tmp_path, ext, args):
    """Seen on the corpus: 159 MXF rows the catalog calls DV were MPEG-2 or had no video stream."""
    f = tmp_path / f"notdv.{ext}"
    _ff(*args, str(f))
    r = _probe(f, tmp_path, kind="wrapped", duration=1.0)
    assert (r["status"], r["rdt_first"]) == ("not-dv", None)


def _catalog_with_dv(tmp_path, files):
    (tmp_path / "db").mkdir()
    cat = Catalog(tmp_path / "db")
    for path in files:
        rid = cat.add(str(path), digest=path.stem.ljust(64, "0"))
        cat.conn.execute("UPDATE files SET video_codec = 'dvvideo', container = 'DV (Digital Video)' WHERE id = ?", (rid,))
    return cat.close()


def test_main_resumes_and_an_interrupt_keeps_what_was_written(tmp_path, monkeypatch, capsys):
    files = []
    for i in range(3):
        p = tmp_path / f"d{i}.dv"
        p.write_bytes(dvd.DIF_MAGIC)
        files.append(p)
    db = _catalog_with_dv(tmp_path, files)
    calls, interrupt_at = [], {"n": 2}

    def fake_probe(target, tools, **kw):
        calls.append(target["digest"])
        if len(calls) == interrupt_at["n"]:
            raise KeyboardInterrupt  # Ctrl-C during the second file
        return {"digest": target["digest"], "kind": "raw", "status": "no-rdt", "elapsed_s": 0.1}
    monkeypatch.setattr(dvd, "probe", fake_probe)
    out = tmp_path / "r.jsonl"
    assert dvd.main(["--db", str(db), "--resume", str(out)]) == 130
    assert len(dvd.load_results(out)) == 1 and "probed: 1" in capsys.readouterr().out
    calls.clear()
    interrupt_at["n"] = 0
    assert dvd.main(["--db", str(db), "--resume", str(out)]) == 0
    assert len(calls) == 2 and len({r["digest"] for r in dvd.load_results(out)}) == 3
    calls.clear()
    assert dvd.main(["--db", str(db), "--resume", str(out)]) == 0 and calls == []
    assert "probed: 3" in capsys.readouterr().out


@needs_tools
def test_main_end_to_end_on_a_synthetic_catalog(tmp_path, capsys):
    cam = _dv(tmp_path / "c1.dv", 10, "2007-10-22T20:22:16Z")
    bridge = _dv(tmp_path / "c2.dv", 10, None)
    db = _catalog_with_dv(tmp_path, [cam, bridge])
    out_dir = tmp_path / "out"
    assert dvd.main(["--db", str(db), "--out-dir", str(out_dir), "--limit", "5"]) == 0
    text = capsys.readouterr().out
    assert "probed: 2" in text and "with_rdt: 1" in text and "without_rdt: 1" in text and "2000s 1" in text
    assert str(tmp_path) not in text and "c1" not in text
    (results,) = list(out_dir.glob("*.jsonl"))
    assert {r["status"] for r in dvd.load_results(results)} == {"rdt", "no-rdt"}


# ---------------------------------------------------------------- scale

def test_scale_100k_rows():
    rows = [_r(f"{i:064x}", "rdt" if i % 3 else "no-rdt", f"{1995 + i % 30}-06-01 12:00:00" if i % 3 else None,
               2008) for i in range(100_000)]
    t0 = time.monotonic()
    s = dvd.summarize(rows)
    assert time.monotonic() - t0 < 2.0
    assert s["probed"] == 100_000 and s["with_rdt"] + s["without_rdt"] == 100_000
    recs = [_rec(f"/v/{i}.dv", f"{i:064x}") for i in range(100_000)]
    t0 = time.monotonic()
    targets, counts = dvd.select_dv(recs, True, lambda p: True)
    assert time.monotonic() - t0 < 2.0 and len(targets) == 100_000 and counts["not_on_disk"] == 0

