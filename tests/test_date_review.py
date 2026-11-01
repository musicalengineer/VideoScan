"""tools/date-review/date_review.py — the DV-datecode review page (read-only builder + loopback server).

  * LOGIC: deterministic selection with your dated clips first (disagreeing first) and the
    variety quotas; the catalog join (removed rows, files not on disk, first existing copy);
    the date table (missing -> '—', 1904 / zero / 1970 / future container dates -> '—' with the
    reason); filename dates; the inferred source as a kind, never a folder name; verdict append
    and re-read (last wins, torn line skipped, notes kept, bad input refused).
  * TRUTH: the container line is what the file carries now (ffprobe), not the catalog's stored
    value; the DV line is the results' datecode; "File modified" is the file's stat.
  * MEDIA MATRIX: posters and filmstrips ripped from raw .dv and DV in mov / avi / mkv / mxf.
  * ISOLATION: a torn results line, a garbage file, a digest missing from the catalog — the build
    completes and the page shows "no picture"; the preview cache is used when it has pictures.
  * SENSOR / PRIVACY: the run dir must be under .scratch/; only loopback binds; a foreign Host,
    a form POST and a path-traversal media name are refused; no path in anything served except
    the file name; the catalog is read only through catalog_db.
  * SCALE: candidates + selection over 100k rows within a budget.
"""
from __future__ import annotations

import ast
import hashlib
import json
import os
import shutil
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools" / "date-review"))
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tests"))

import date_review as dr  # noqa: E402
from catalog_sqlite_fixture import Catalog  # noqa: E402

SCRIPT = ROOT / "tools" / "date-review" / "date_review.py"
FFMPEG, FFPROBE = dr._tool("ffmpeg"), dr._tool("ffprobe")
needs_ffmpeg = pytest.mark.skipif(not (FFMPEG and FFPROBE), reason="ffmpeg/ffprobe (Brewfile) required")


def _hex(name: str) -> str:
    return hashlib.sha256(name.encode()).hexdigest()


def _cand(i: int, **kw) -> dict:
    year = 2001 + i % 10
    c = {"digest": _hex(f"c{i}"), "kind": "wrapped" if i % 7 == 0 else "raw", "path": f"/v/{i}.dv",
         "filename": f"clip{i}.dv", "ext": "dv", "duration": 60.0,
         "rdt_first": f"{year}-06-01 12:00:00", "rdt_last": f"{year}-06-01 12:30:00", "rdt_year": year,
         "mtime_year": year + (i % 3), "user_date": None, "user_confidence": None,
         "catalog_container": None, "container_year": None, "filename_years": [],
         "inferred_date": None, "inferred_range": None, "inferred_source": None, "inferred_reason": None,
         "inferred_confidence": None}
    c.update(kw)
    return c


def _pool(n=300):
    pool = [_cand(i) for i in range(n)]
    pool[10] = _cand(10, user_date="2004", rdt_first="2003-12-27 15:34:46", rdt_year=2003)
    pool[200] = _cand(200, user_date="1965", rdt_first="2001-11-11 15:20:04", rdt_year=2001)
    pool[50] = _cand(50, rdt_last="2001-06-02 00:10:00")  # two days (year 2001)
    pool[51] = _cand(51, rdt_first="2002-06-01 23:50:00", rdt_last="2002-06-02 00:10:00")
    pool[52] = _cand(52, rdt_first="2002-06-01 23:50:00", rdt_last="2002-06-03 00:10:00")
    pool[60] = _cand(60, mtime_year=2026, rdt_year=2001)                  # the largest gap
    pool[70] = _cand(70, container_year=2009)
    pool[80] = _cand(80, filename_years=[2005])
    return pool


# ---------------------------------------------------------------- selection

def test_selection_is_deterministic_and_puts_your_dated_clips_first():
    pool = _pool()
    a = dr.select(pool, 25, seed=7)
    b = dr.select(list(reversed(pool)), 25, seed=7)
    assert [c["digest"] for c in a] == [c["digest"] for c in b]
    assert len(a) == 25 and len({c["digest"] for c in a}) == 25
    # the 1965-vs-2001 disagreement first, then the one-year one
    assert a[0]["digest"] == _hex("c200") and "you confirmed 1965" in a[0]["reason"] and "36 y" in a[0]["reason"]
    assert a[1]["digest"] == _hex("c10") and "you confirmed 2004" in a[1]["reason"]
    assert all(not c.get("user_date") for c in a[2:])


def test_selection_covers_the_variety():
    pool = _pool()
    picked = dr.select(pool, 25, seed=7)
    ids = {c["digest"] for c in picked}
    assert sum(1 for c in picked if dr._two_days(c)) >= 2
    assert _hex("c60") in ids                                    # largest mtime gap
    assert _hex("c70") in ids and _hex("c80") in ids             # container disagrees; name carries a year
    assert sum(c["kind"] == "raw" for c in picked) >= 4 and sum(c["kind"] == "wrapped" for c in picked) >= 4
    assert {c["rdt_year"] for c in picked} == {c["rdt_year"] for c in pool}
    assert all(c["reason"] for c in picked)


def test_selection_of_fewer_candidates_than_n_takes_them_all():
    pool = [_cand(i) for i in range(5)]
    assert len(dr.select(pool, 25)) == 5
    assert dr.select([], 25) == []


def _rec(path, digest, **kw):
    r = {"fullPath": path, "filename": Path(path).name, "ext": Path(path).suffix[1:], "contentFixity": {"sha256": digest},
         "removal": None, "durationSeconds": 10.0, "userDate": None, "userDateConfidence": None,
         "embeddedCreationDate": None}
    r.update(kw)
    return r


def test_candidates_join_live_copy_on_disk_only():
    d1, d2, d3, d4 = (_hex(x) for x in "abcd")
    results = [{"digest": d1, "rdt_first": "2003-01-02 03:04:05", "kind": "raw", "mtime_year": 2008},
               {"digest": d2, "rdt_first": "2004-01-02 03:04:05", "kind": "raw"},
               {"digest": d3, "rdt_first": None, "status": "no-rdt"},
               {"digest": d4, "rdt_first": "2005-01-02 03:04:05", "kind": "wrapped"}]
    records = [_rec("/v/b.dv", d1, userDate="2003"), _rec("/v/a.dv", d1, userDate="2003"),   # a sorts first, not on disk
               _rec("/v/c.dv", d1, userDate="2003"),
               _rec("/v/t.dv", d2, removal={"state": "inTrash"}),                           # removed only
               _rec("/v/n.dv", d3), _rec("/v/gone.mov", d4)]
    on_disk = {"/v/b.dv", "/v/c.dv", "/v/t.dv", "/v/n.dv"}
    out = dr.candidates(results, records, lambda p: p in on_disk)
    assert [c["digest"] for c in out] == [d1]
    assert out[0]["path"] == "/v/b.dv" and out[0]["user_date"] == "2003" and out[0]["rdt_year"] == 2003


# ---------------------------------------------------------------- the date table

def test_date_rows_missing_values_are_dashes():
    rows = dr.date_rows({"rdt_first": None, "filename": "clip.dv"}, now_year=2026)
    assert [r["source"] for r in rows] == ["DV camcorder clock", "You confirmed", "Container / embedded",
                                          "Filename", "File modified", "Inferred"]
    assert all(r["value"] == dr.DASH for r in rows)
    assert [r["dv"] for r in rows] == [True, False, False, False, False, False]


def test_date_rows_with_every_source():
    fact = {"rdt_first": "2003-12-24 19:44:37", "rdt_last": "2003-12-25 00:10:00", "user_date": "2003",
            "user_confidence": "known", "container": "2003-12-28T05:08:56.000000Z",
            "catalog_container": "2003-12-28T05:08:56Z", "filename": "2003-12-25_Christmas2003.mov",
            "mtime": 1_700_000_000, "inferred_date": "2003-01-01T00:00:00Z",
            "inferred_range": {"startYear": 2000, "endYear": 2003}, "inferred_source": None,
            "inferred_reason": "spoken now-cue 'christmas 2003'; folder 'X' names 2003", "inferred_confidence": 0.5}
    rows = {r["source"]: r for r in dr.date_rows(fact, now_year=2026)}
    assert rows["DV camcorder clock"]["value"] == "2003-12-24"
    assert "last frame 2003-12-25" in rows["DV camcorder clock"]["note"]
    assert rows["You confirmed"]["value"] == "2003" and rows["You confirmed"]["note"] == "known"
    assert rows["Container / embedded"]["value"] == "2003-12-28" and "catalog says" not in rows["Container / embedded"]["note"]
    assert rows["Filename"]["value"] == "2003-12-25" and rows["Filename"]["note"] == "also 2003"
    assert rows["File modified"]["value"].startswith("2023-11-1")
    assert rows["Inferred (speech)"]["value"] == "2000–2003" and rows["Inferred (speech)"]["note"] == "confidence 50%"


@pytest.mark.parametrize("value,why", [
    ("1904-01-01T00:00:00Z", "QuickTime's zero"), (-2082844800, "QuickTime's zero"), (0, "1970"), ("1970-01-01T00:00:00Z", "1970"),
    ("2031-05-01T00:00:00Z", "future"), ("not a date", "unreadable"), (None, "none in the file")])
def test_container_sentinel_dates_are_dashes_with_the_reason(value, why):
    rows = {r["source"]: r for r in dr.date_rows({"container": value}, now_year=2026)}
    assert rows["Container / embedded"]["value"] == dr.DASH
    assert why in rows["Container / embedded"]["note"]


def test_filename_dates():
    assert dr.filename_dates("2008-xx-xx_2009-01-06_Christmas2008.mov") == ["2008", "2009-01-06"]
    assert dr.filename_dates("Christmas 2005.dv") == ["2005"]
    assert dr.filename_dates("clip_20031225.dv") == []          # 8 digits: not a year we can trust
    assert dr.filename_dates("1965-xx-xx_1960s-with-music.mov") == ["1965", "1960s"]
    assert dr.filename_dates("2003-13-45 x.dv") == ["2003"]      # impossible month/day -> the year only
    assert dr.filename_dates("tape 12.dv") == []


def test_inferred_source_is_a_kind_never_the_folder_name():
    kind = dr.inferred_kind("folder 'Cape Cod 2007 - Day 10' names 2007; DV era floor 1995", "propagated from x")
    assert kind == "folder name, propagated from a copy" and "Cape" not in kind
    assert dr.inferred_kind("on-screen date 2001-04-15 ×3", "catch-up") == "on-screen date, catch-up"
    assert dr.inferred_kind("age 75 fits 12 known birth years", None) == "a person's age"
    assert dr.inferred_kind("something new", None) == "other evidence"


# ---------------------------------------------------------------- verdicts

def test_verdict_append_and_reread(tmp_path):
    d = _hex("v")
    dr.write_verdict(tmp_path, d, "unsure")
    dr.write_verdict(tmp_path, d, "wrong", "a 1965 film re-recorded by the camcorder in 2001")
    with (tmp_path / dr.VERDICTS_FILE).open("a") as f:
        f.write('{"digest": "' + d + '", "verd')        # torn last line
    got = dr.read_verdicts(tmp_path)
    assert got[d]["verdict"] == "wrong" and got[d]["notes"].startswith("a 1965 film") and got[d]["at"].endswith("Z")
    lines = (tmp_path / dr.VERDICTS_FILE).read_text().splitlines()
    assert len(lines) == 3 and "notes" not in json.loads(lines[0])
    with pytest.raises(ValueError):
        dr.write_verdict(tmp_path, d, "maybe")
    with pytest.raises(ValueError):
        dr.write_verdict(tmp_path, "../etc", "right")
    with pytest.raises(ValueError):
        dr.write_verdict(tmp_path, d, "right", known=[_hex("other")])


# ---------------------------------------------------------------- server guards

def _empty_run(root: Path) -> Path:
    run = root / ".scratch" / "run"
    (run / "media").mkdir(parents=True)
    (run / dr.SELECTION_FILE).write_text(json.dumps({"clips": []}))
    return run


def test_server_refuses_a_run_dir_outside_scratch(tmp_path):
    run = tmp_path / "public"
    run.mkdir()
    (run / dr.SELECTION_FILE).write_text(json.dumps({"clips": []}))
    with pytest.raises(SystemExit, match=r"\.scratch"):
        dr.make_server(run, port=0)
    with pytest.raises(SystemExit, match=r"\.scratch"):
        dr.build(tmp_path / "r.jsonl", run, db=str(tmp_path / "nope"))


@pytest.mark.parametrize("host", ["0.0.0.0", "192.168.1.10", "::", "example.com", "localhost"])
def test_server_refuses_a_non_loopback_bind(tmp_path, host):
    with pytest.raises(SystemExit, match="loopback"):
        dr.make_server(_empty_run(tmp_path), host=host, port=0)


# ---------------------------------------------------------------- end to end (real catalog shape, real media)

def _ff(*args):
    subprocess.run([FFMPEG, "-nostdin", "-v", "error", "-y", *args], check=True)


def _dv(path: Path, when: str) -> Path:
    _ff("-f", "lavfi", "-i", "testsrc=size=720x480:rate=30000/1001", "-frames:v", "30", "-c:v", "dvvideo",
        "-pix_fmt", "yuv411p", "-an", "-metadata", f"creation_time={when}", "-f", "dv", str(path))
    return path


SECRET_DIR = "Hudson Family Private 2003"


def _world(tmp_path):
    """Media under a distinctive folder name, a synthetic catalog, a results file, an empty cache."""
    src = tmp_path / "media" / SECRET_DIR
    src.mkdir(parents=True)
    raw = _dv(src / "Christmas2003-tape.dv", "2003-12-24T19:44:37Z")
    files = {"dv": raw}
    for ext, extra in (("mov", ["-metadata", "creation_time=2009-01-06T10:00:00Z"]), ("avi", []), ("mkv", []),
                       ("mxf", ["-an"])):
        files[ext] = src / f"Cape Cod 2007 - {ext}.{ext}"
        _ff("-r", "30000/1001", "-i", str(raw), "-c", "copy", *extra, str(files[ext]))
    garbage = src / "broken.dv"
    garbage.write_bytes(b"\x1f\x07\x00" + b"\x00" * 5000)
    files["garbage"] = garbage
    for p in files.values():
        os.utime(p, (1_700_000_000, 1_700_000_000))
    (tmp_path / "db").mkdir()
    cat = Catalog(tmp_path / "db")
    digests = {k: _hex(k) for k in files}
    for k, p in files.items():
        rid = cat.add(str(p), digest=digests[k], duration=1.0, user_date="1965" if k == "mov" else None)
        cat.conn.execute("UPDATE files SET video_codec = 'dvvideo', container = 'QuickTime / MOV', "
                         "embedded_created_at = ?, embedded_created_source = ? WHERE id = ?",
                         (1_300_000_000, "format:creation_time", rid) if k == "mov" else (None, None, rid))
    cat.conn.execute("INSERT INTO inferred_dates (digest, date_at, confidence, range_start, range_end, reason) "
                     "VALUES (?, 1041379200, 0.5, 2003, 2003, ?)", (digests["dv"], f"folder '{SECRET_DIR}' names 2003"))
    db = cat.close()
    results = tmp_path / "results.jsonl"
    with results.open("w") as f:
        for k in files:
            f.write(json.dumps({"digest": digests[k], "rdt_first": "2003-12-24 19:44:37", "rdt_last": "2003-12-24 19:45:00",
                                "kind": "raw" if k in ("dv", "garbage") else "wrapped", "mtime_year": 2023,
                                "status": "rdt"}) + "\n")
        f.write(json.dumps({"digest": _hex("not-in-catalog"), "rdt_first": "2006-01-01 00:00:00"}) + "\n")
        f.write('{"digest": "torn')
    cache = tmp_path / "cache"
    cache.mkdir()
    return files, digests, db, results, cache


@pytest.fixture
def built(tmp_path, capsys):
    files, digests, db, results, cache = _world(tmp_path)
    run = tmp_path / ".scratch" / "date-review" / "dv-test"
    selection = dr.build(results, run, n=25, seed=1, db=str(db), cache=cache, now_year=2026)
    out = capsys.readouterr().out
    return {"tmp": tmp_path, "files": files, "digests": digests, "run": run, "selection": selection, "out": out}


@needs_ffmpeg
def test_build_media_matrix_posters_and_strips(built):
    clips = {c["digest"]: c for c in built["selection"]["clips"]}
    assert len(clips) == 6
    for k in ("dv", "mov", "avi", "mkv", "mxf"):
        c = clips[built["digests"][k]]
        assert c["poster"] and (built["run"] / "media" / c["poster"]).read_bytes()[:2] == b"\xff\xd8", k
        assert len(c["strip"]) == dr.STRIP_FRAMES, k
    assert "START date_review build" in built["out"] and "OUTCOME date_review build complete clips=6" in built["out"]


@needs_ffmpeg
def test_isolation_a_garbage_file_still_shows_with_no_picture(built):
    c = next(c for c in built["selection"]["clips"] if c["digest"] == built["digests"]["garbage"])
    assert c["poster"] is None and c["strip"] == []
    assert next(r for r in c["rows"] if r["dv"])["value"] == "2003-12-24"


@needs_ffmpeg
def test_truth_container_line_is_the_file_not_the_catalog(built):
    clips = built["selection"]["clips"]
    assert clips[0]["digest"] == built["digests"]["mov"] and clips[0]["user_dated"]   # your date first
    rows = {r["source"]: r for r in clips[0]["rows"]}
    assert rows["Container / embedded"]["value"] == "2009-01-06"                     # ffprobe, now
    assert "the catalog says 2011-03-13" in rows["Container / embedded"]["note"]      # the stored value differs
    assert rows["You confirmed"]["value"] == "1965"
    assert rows["DV camcorder clock"]["value"] == "2003-12-24"
    assert rows["File modified"]["value"].startswith("2023-11-1")
    raw = next(c for c in clips if c["digest"] == built["digests"]["dv"])
    assert {r["source"]: r for r in raw["rows"]}["Inferred (folder name)"]["value"] == "2003"


def _get(url, host=None, data=None, ctype="application/json"):
    req = urllib.request.Request(url, data=data, method="POST" if data is not None else "GET")
    if host:
        req.add_header("Host", host)
    if data is not None:
        req.add_header("Content-Type", ctype)
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


@needs_ffmpeg
def test_served_page_has_no_path_but_the_filename_and_verdicts_round_trip(built):
    server = dr.make_server(built["run"], port=0)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    try:
        status, page = _get(base + "/")
        assert status == 200 and b"Is the DV date the recording date?" in page
        status, body = _get(base + "/state.json")
        assert status == 200
        text = body.decode()
        assert SECRET_DIR not in text and str(built["tmp"]) not in text and "/media/" not in text
        assert "Christmas2003-tape.dv" in text                                   # the name itself is shown
        on_disk = (built["run"] / dr.SELECTION_FILE).read_text()
        assert SECRET_DIR not in on_disk and str(built["tmp"]) not in on_disk
        state = json.loads(text)
        assert state["counts"] == {"right": 0, "wrong": 0, "unsure": 0, "unanswered": 6}
        poster = state["clips"][0]["poster"]
        assert _get(base + "/media/" + poster)[0] == 200
        assert _get(base + "/media/..%2F" + dr.SELECTION_FILE)[0] == 404
        assert _get(base + "/media/../" + dr.SELECTION_FILE)[0] == 404
        assert _get(base + "/state.json", host="evil.example:8767")[0] == 403    # DNS rebinding
        d = state["clips"][0]["digest"]
        vote = json.dumps({"digest": d, "verdict": "wrong", "notes": "film from 1965, transferred in 2001"}).encode()
        assert _get(base + "/verdict", data=vote, ctype="text/plain")[0] == 415   # a cross-site form post
        assert _get(base + "/verdict", data=json.dumps({"digest": _hex("x"), "verdict": "right"}).encode())[0] == 400
        assert _get(base + "/verdict", data=vote)[0] == 200
        state = json.loads(_get(base + "/state.json")[1])
        assert state["clips"][0]["verdict"] == "wrong" and state["clips"][0]["notes"].startswith("film from 1965")
        assert state["counts"]["wrong"] == 1 and state["counts"]["unanswered"] == 5
        assert dr.read_verdicts(built["run"])[d]["verdict"] == "wrong"
    finally:
        server.shutdown()
        server.server_close()


@needs_ffmpeg
def test_a_one_frame_clip_still_gets_a_poster(tmp_path):
    """Found by the live build: a 120 KB raw DV file (one frame, 0.033 s) got no poster —
    the seek to 10 % of the duration lands past the only frame."""
    one = tmp_path / "one.dv"
    _ff("-f", "lavfi", "-i", "testsrc=size=720x480:rate=30000/1001", "-frames:v", "1", "-c:v", "dvvideo",
        "-pix_fmt", "yuv411p", "-an", "-f", "dv", str(one))
    cache, media = tmp_path / "cache", tmp_path / "media"
    cache.mkdir()
    media.mkdir()
    poster, strip = dr.gather_media({"digest": _hex("one"), "path": str(one)}, media, FFMPEG, 0.033367, cache)
    assert poster and (media / poster).read_bytes()[:2] == b"\xff\xd8"


def test_the_preview_cache_is_used_in_strip_order(tmp_path):
    d = _hex("cached")
    cache, media = tmp_path / "cache", tmp_path / "media"
    cache.mkdir()
    media.mkdir()
    (cache / f"{d}-best.jpg").write_bytes(b"\xff\xd8best")
    for n in (10, 2, 0):
        (cache / f"{d}-strip-{n}-of-16-{n * 1000}.jpg").write_bytes(f"\xff\xd8{n}".encode("latin-1"))
    poster, strip = dr.gather_media({"digest": d, "path": "/nope"}, media, None, None, cache)
    assert poster == f"{d}-poster.jpg" and (media / poster).read_bytes() == b"\xff\xd8best"
    assert [(media / s).read_bytes()[2:] for s in strip] == [b"0", b"2", b"10"]


# ---------------------------------------------------------------- guard + scale

def test_reads_the_catalog_only_through_catalog_db():
    tree = ast.parse(SCRIPT.read_text(encoding="utf-8"))
    strings = [n.value for n in ast.walk(tree) if isinstance(n, ast.Constant) and isinstance(n.value, str)]
    assert not any("catalog.sqlite" in s or "catalog.json" in s for s in strings)
    imports = {a.name for n in ast.walk(tree) if isinstance(n, (ast.Import, ast.ImportFrom)) for a in n.names}
    assert "sqlite3" not in imports and "catalog_db" in imports
    calls = {n.func.attr for n in ast.walk(tree) if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)
             and isinstance(n.func.value, ast.Name) and n.func.value.id == "catalog_db"}
    assert calls == {"connect", "records"}


def test_scale_100k_candidates():
    results = [{"digest": _hex(f"s{i}"), "rdt_first": f"{1995 + i % 18}-01-01 00:00:00", "kind": "raw",
                "mtime_year": 2010} for i in range(100_000)]
    records = [_rec(f"/v/{i}.dv", _hex(f"s{i}"), filename=f"clip {1990 + i % 30}.dv") for i in range(100_000)]
    t0 = time.monotonic()
    cands = dr.candidates(results, records, lambda p: True)
    picked = dr.select(cands, 25)
    assert time.monotonic() - t0 < 10.0
    assert len(cands) == 100_000 and len(picked) == 25
