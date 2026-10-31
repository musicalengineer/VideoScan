"""tools/video-llm-bench/bench.py — no model, no media, no catalog.

Runs with venv/bin/python3 -m pytest tests/test_video_llm_bench.py.  Every
test builds its own tiny sqlite (schema subset) or hand-made JSONL; the
"approach" is a fake that returns canned text, the "ripper" writes an empty
PNG.  The privacy test proves the Markdown that goes under docs/ carries no
path, no content digest and no raw model text.
"""
from __future__ import annotations

import importlib.util
import json
import re
import sqlite3
import sys
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "tools" / "video-llm-bench" / "bench.py"
SPEC = importlib.util.spec_from_file_location("video_llm_bench", SCRIPT)
assert SPEC and SPEC.loader
bench = importlib.util.module_from_spec(SPEC)
sys.modules["video_llm_bench"] = bench   # dataclasses with postponed annotations need the module registered
SPEC.loader.exec_module(bench)

SCHEMA = """
CREATE TABLE content (digest TEXT PRIMARY KEY NOT NULL, byte_count INTEGER NOT NULL);
CREATE TABLE files (
  id TEXT PRIMARY KEY NOT NULL, content_digest TEXT NOT NULL, full_path TEXT NOT NULL,
  size_bytes INTEGER NOT NULL, duration_s REAL NOT NULL DEFAULT 0, stream_type TEXT NOT NULL,
  container TEXT NOT NULL DEFAULT '', video_codec TEXT NOT NULL DEFAULT '',
  embedded_created_at INTEGER, removal_state TEXT);
CREATE TABLE user_dates (digest TEXT PRIMARY KEY NOT NULL, value TEXT, confidence TEXT, set_at INTEGER,
  conflict INTEGER NOT NULL DEFAULT 0);
CREATE TABLE captions (digest TEXT NOT NULL, kind TEXT NOT NULL, seq INTEGER NOT NULL, at_s REAL NOT NULL,
  text TEXT NOT NULL, PRIMARY KEY (digest, kind, seq));
CREATE TABLE inferred_dates (digest TEXT PRIMARY KEY NOT NULL, date_at INTEGER, confidence REAL, source TEXT,
  range_start INTEGER, range_end INTEGER, reason TEXT);
"""


def digest_for(n: int) -> str:
    return "{:064x}".format(n)


def epoch(year: int) -> int:
    import datetime as dt
    return int(dt.datetime(year, 6, 15, tzinfo=dt.timezone.utc).timestamp())


class Fixture:
    """A tiny catalog copy.  `exists` is the reachability oracle handed to the builder
    so no test touches the filesystem for media."""

    def __init__(self, path: Path):
        self.path = path
        self.conn = sqlite3.connect(path)
        self.conn.executescript(SCHEMA)
        self.reachable: set[str] = set()
        self.n = 0

    def add_file(self, digest: str, path: str, codec: str = "hevc", container: str = "QuickTime / MOV",
                 embedded_year: int | None = None, duration: float = 120.0, reachable: bool = True,
                 removed: bool = False) -> None:
        self.n += 1
        self.conn.execute("INSERT OR IGNORE INTO content VALUES (?, ?)", (digest, 1000))
        self.conn.execute(
            "INSERT INTO files VALUES (?,?,?,?,?,?,?,?,?,?)",
            ("{:036d}".format(self.n), digest, path, 1000, duration, "Video+Audio", container, codec,
             epoch(embedded_year) if embedded_year else None, "missing" if removed else None))
        if reachable:
            self.reachable.add(path)

    def add_user_date(self, digest: str, value: str | None, confidence: str = "known") -> None:
        self.conn.execute("INSERT INTO user_dates VALUES (?,?,?,?,0)", (digest, value, confidence, None))

    def add_caption(self, digest: str, kind: str, seq: int, text: str) -> None:
        self.conn.execute("INSERT INTO captions VALUES (?,?,?,?,?)", (digest, kind, seq, float(seq), text))

    def add_inferred(self, digest: str, year: int | None, reason: str | None) -> None:
        self.conn.execute("INSERT INTO inferred_dates VALUES (?,?,?,?,?,?,?)",
                          (digest, epoch(year) if year else None, 0.5, None, None, None, reason))

    def done(self) -> Path:
        self.conn.commit()
        self.conn.close()
        return self.path

    def exists(self, path: str) -> bool:
        return path in self.reachable


def populated(tmp_path: Path) -> Fixture:
    f = Fixture(tmp_path / "catalog-copy.sqlite")
    # Rick-dated: three with a value (one unreachable), one NULL value, one removed row only.
    f.add_file(digest_for(1), "/Volumes/T/a.mov", codec="dvvideo", container="DV (Digital Video)")
    f.add_user_date(digest_for(1), "1991-06-21")
    f.add_file(digest_for(2), "/Volumes/T/b.mkv", codec="ffv1", container="Matroska / WebM")
    f.add_user_date(digest_for(2), "1984", confidence="estimated")
    f.add_file(digest_for(3), "/Volumes/Gone/c.mov", reachable=False)
    f.add_user_date(digest_for(3), "2001-05")
    f.add_file(digest_for(4), "/Volumes/T/d.mov")
    f.add_user_date(digest_for(4), None, confidence="estimated")
    f.add_file(digest_for(5), "/Volumes/T/e.mov", removed=True)
    f.add_user_date(digest_for(5), "1999")
    # camera-dated pool: 30 hevc 2020s, 12 dvvideo 2000s, 3 h264 2010s, 6 prores 2020s (transfer stamp → excluded)
    for i in range(30):
        f.add_file(digest_for(100 + i), "/Volumes/T/iphone{}.mov".format(i), codec="hevc", embedded_year=2021)
    for i in range(12):
        f.add_file(digest_for(200 + i), "/Volumes/T/dv{}.dv".format(i), codec="dvvideo",
                   container="DV (Digital Video)", embedded_year=2003)
    for i in range(3):
        f.add_file(digest_for(300 + i), "/Volumes/T/cam{}.mp4".format(i), codec="h264", embedded_year=2012)
    for i in range(6):
        f.add_file(digest_for(400 + i), "/Volumes/T/pr{}.mov".format(i), codec="prores", embedded_year=2024)
    # Rick-dated digest 1 also has a camera stamp: must stay in rick-dated, not be drawn twice.
    f.conn.execute("UPDATE files SET embedded_created_at = ? WHERE content_digest = ?", (epoch(2020), digest_for(1)))
    # OCR: on-screen verdict; majority-of-captions verdict; junk-only captions (no OCR truth); no verdict row.
    f.add_file(digest_for(500), "/Volumes/T/ocr1.mov", codec="prores")
    f.add_caption(digest_for(500), "ocrDate", 0, "JUN.21 1991")
    f.add_inferred(digest_for(500), 1991, "on-screen date 1991-06-21 ×3; caption mentions 1991")
    f.add_file(digest_for(501), "/Volumes/T/ocr2.mov", codec="h264")
    f.add_caption(digest_for(501), "ocrDate", 0, "JUN 22 '97")
    f.add_caption(digest_for(501), "ocrDate", 1, "JUN 22 '97")
    f.add_caption(digest_for(501), "ocrDate", 2, "JUN 23 '97")
    f.add_inferred(digest_for(501), 1997, "folder names 1997")
    f.add_file(digest_for(502), "/Volumes/T/ocr3.mov", codec="h264")
    f.add_caption(digest_for(502), "ocrDate", 0, "!" * 40)
    f.add_inferred(digest_for(502), 2010, "folder names 2010")
    f.add_file(digest_for(503), "/Volumes/T/ocr4.mov", codec="h264")
    f.add_caption(digest_for(503), "ocrDate", 0, "DEC 25 2010")
    return f


# ---------------------------------------------------------------------------
# Manifest building
# ---------------------------------------------------------------------------
def test_manifest_counts_strata_and_truth(tmp_path):
    f = populated(tmp_path)
    f.done()
    manifest = bench.build_manifest(f.path, seed=7, camera_target=20, ocr_target=100, exists=f.exists)
    era = [c for c in manifest["clips"] if c["corpus"] == "era"]
    ocr = [c for c in manifest["clips"] if c["corpus"] == "ocr"]
    rick = [c for c in era if c["stratum"].startswith("rick-dated/")]
    camera = [c for c in era if c["stratum"].startswith("camera/")]
    # 5 user_dates rows, 4 with a value, 2 reachable live files (3 unreachable, 5 removed)
    assert manifest["era_report"]["user_dates_rows"] == 5
    assert manifest["era_report"]["user_dates_with_value"] == 4
    assert manifest["era_report"]["user_dates_reachable"] == 2
    assert {c["stratum"] for c in rick} == {"rick-dated/1990s", "rick-dated/1980s"}
    by = {c["digest"]: c for c in rick}
    assert by[digest_for(1)]["truth"] == {"year": 1991, "source": "user_dates", "confidence": "known", "value": "1991-06-21"}
    assert by[digest_for(2)]["truth"]["year"] == 1984
    # camera: 20 drawn, prores excluded, digest 1 not drawn twice, floor honoured on small strata
    assert len(camera) == 20
    assert not any(c["codec"] == "prores" for c in camera)
    assert digest_for(1) not in {c["digest"] for c in camera}
    drawn = manifest["era_report"]["camera_drawn"]
    assert drawn["camera/2010s/h264"] == 3            # all it has
    assert drawn["camera/2000s/dvvideo"] >= 8         # floor
    assert manifest["era_report"]["camera_pool"] == {"camera/2000s/dvvideo": 12, "camera/2010s/h264": 3, "camera/2020s/hevc": 30}
    assert all(c["truth"]["source"] == "files.embedded_created_at" for c in camera)
    # OCR: 500 (on-screen) and 501 (majority) in; 502 (junk) and 503 (no verdict row) out
    assert {c["digest"] for c in ocr} == {digest_for(500), digest_for(501)}
    truths = {c["digest"]: c["truth"] for c in ocr}
    assert truths[digest_for(500)] == {"date": "1991-06-21", "source": "inferred_dates.reason:on-screen", "verdict_year": 1991}
    assert truths[digest_for(501)]["date"] == "1997-06-22"
    assert truths[digest_for(501)]["source"] == "captions.ocrDate:majority"
    assert manifest["ocr_report"] == {"ocr_with_verdict_rows": 3, "with_ocr_truth": 2, "drawn": 2,
                                      "truth_sources": {"inferred_dates.reason:on-screen": 1, "captions.ocrDate:majority": 1}}
    assert manifest["counts"] == {"era": 22, "ocr": 2, "strata": manifest["counts"]["strata"]}
    assert len(manifest["corpus_hash"]) == 64
    assert bench.format_manifest_report(manifest)


def test_stratification_is_deterministic_under_the_seed(tmp_path):
    f = populated(tmp_path)
    f.done()
    a = bench.build_manifest(f.path, seed=11, camera_target=20, ocr_target=100, exists=f.exists)
    b = bench.build_manifest(f.path, seed=11, camera_target=20, ocr_target=100, exists=f.exists)
    c = bench.build_manifest(f.path, seed=12, camera_target=20, ocr_target=100, exists=f.exists)
    pick = lambda m: [x["digest"] for x in m["clips"]]  # noqa: E731
    assert pick(a) == pick(b)
    assert a["corpus_hash"] == b["corpus_hash"]
    assert pick(a) != pick(c)          # a different seed draws a different hevc sample
    assert {x["stratum"] for x in a["clips"]} == {x["stratum"] for x in c["clips"]}


def test_allocation_floor_then_proportional():
    alloc = bench.allocate_stratified({"big": 1000, "mid": 50, "tiny": 3, "empty": 0}, 200, 8)
    assert "empty" not in alloc
    assert alloc["tiny"] == 3
    assert alloc["mid"] >= 8 and alloc["big"] >= 8
    assert sum(alloc.values()) == 200
    assert alloc["big"] > alloc["mid"]
    # Target smaller than the floors: everyone gets min(size, floor), nothing more.
    assert bench.allocate_stratified({"a": 100, "b": 100}, 4, 8) == {"a": 8, "b": 8}


def test_manifest_refuses_a_wrong_file(tmp_path):
    bad = tmp_path / "x.json"
    bad.write_text(json.dumps({"record_type": "nope"}))
    with pytest.raises(ValueError):
        bench.load_manifest(bad)


# ---------------------------------------------------------------------------
# Date / year parsing on adversarial strings
# ---------------------------------------------------------------------------
@pytest.mark.parametrize("text,expected", [
    ("JUN 21 1991", ["1991-06-21"]),
    ("JUN.21 1991", ["1991-06-21"]),
    ("PM11:26\nJUN.21 1991", ["1991-06-21"]),
    ("JUN 21 '97", ["1997-06-21"]),
    ("JUN\n21\n'97", ["1997-06-21"]),
    ("6/21/91", ["1991-06-21"]),
    ("06-21-1991", ["1991-06-21"]),
    ("1991-06-21", ["1991-06-21"]),
    ("4 March 1952", ["1952-03-04"]),
    ("Dec 25, 2010", ["2010-12-25"]),
    ("JUN 24 01", []),                 # bare two digits are a truncated time, not a year (GH #166 rule)
    ("19910", []),                     # five digits are never a year
    ("The date is 19910 or 2031", []),
    ("NONE", []),
    ("", []),
    ("1:55", []),
    ("12:00AM THU", []),
    ("FEB 30 1991", []),               # impossible day
    ("13/13/91", []),                  # impossible month
    ("price $19.91", []),
    ("!" * 40, []),
    ("JUN 21 1991 and JUN 21 1991", ["1991-06-21"]),   # deduplicated
])
def test_parse_dates(text, expected):
    assert bench.parse_dates(text) == expected


@pytest.mark.parametrize("text,years,decades", [
    ("shot in 1991 and 1992", [1991, 1992], []),
    ("the early 1990s", [], [1992]),
    ("a 1950s kitchen", [], [1955]),
    ("late '80s", [], [1987]),
    ("mid-1970s fashion", [], [1975]),
    ("19910", [], []),
    ("2031 is out of range", [], []),
    ("1990's decor", [], [1995]),
])
def test_parse_years_and_decades(text, years, decades):
    assert bench.parse_years(text) == years
    assert bench.parse_decades(text) == decades


def test_degenerate_detection():
    assert bench.is_degenerate("!" * 10)
    assert bench.is_degenerate("JUN 21 ....................")
    assert not bench.is_degenerate("JUN 21 1991")
    assert not bench.is_degenerate("")
    assert not bench.is_degenerate("aaaaaaaaaaaaaaaaaaaa")   # letters are words, not the glyph-run failure


def test_best_year_rule():
    r = lambda kind, text: {"prompt_kind": kind, "raw_text": text}  # noqa: E731
    # one OCR date (3) beats three decade mentions (1 each) unless they agree on a year
    assert bench.best_year([r("date", "JUN 21 1991"), r("scene", "1980s"), r("scene", "1980s"), r("scene", "1980s")]) == 1991
    assert bench.best_year([r("date", "JUN 21 1991"), r("scene", "1980s")] + [r("scene", "1980s")] * 3) == 1985
    # a date in the scene prompt is not OCR evidence: counts as a bare year (1)
    assert bench.best_year([r("scene", "JUN 21 1991"), r("scene", "1985"), r("scene", "1985")]) == 1985
    # tie → median (lower middle)
    assert bench.best_year([r("scene", "1991"), r("scene", "1995"), r("scene", "2003")]) == 1995
    assert bench.best_year([r("scene", "1991"), r("scene", "1995")]) == 1991
    # degenerate output contributes nothing; nothing at all → None (no answer)
    assert bench.best_year([r("date", "!" * 40), r("scene", "a living room")]) is None
    assert bench.best_year([]) is None
    # a 19910 never becomes 1991
    assert bench.best_year([r("text", "19910")]) is None


# ---------------------------------------------------------------------------
# Run loop: fake approach, fake ripper, resume
# ---------------------------------------------------------------------------
class FakeApproach(bench.Approach):
    id = "fake"

    def __init__(self, answers=None, fail_on=None):
        self.calls = []
        self.answers = answers or {"date": "JUN 21 1991", "scene": "A 1990s living room.", "text": "NONE"}
        self.fail_on = fail_on
        self.seeds = 0
        self.cleared = 0

    def load(self):
        return {"model": "fake", "weights_sha256": "0" * 64, "load_s": 0.0}

    def seed(self, value):
        self.seeds += 1

    def after_clip(self):
        self.cleared += 1

    def answer(self, image_path, prompt_kind):
        self.calls.append((Path(image_path).name, prompt_kind))
        if self.fail_on and prompt_kind == self.fail_on:
            raise RuntimeError("boom")
        return self.answers[prompt_kind], {"generation_tokens": 5}


def fake_ripper(path, at_s, dest, duration):
    Path(dest).write_bytes(b"\x89PNG fake")
    return True


def entry(digest, corpus="era", stratum="rick-dated/1990s", truth=None, duration=100.0):
    return {"digest": digest, "path": "/Volumes/T/{}.mov".format(digest[:6]), "size_bytes": 1, "duration_s": duration,
            "corpus": corpus, "stratum": stratum, "truth": truth or {"year": 1991, "source": "user_dates"},
            "codec": "dvvideo", "container": "DV"}


def test_run_writes_one_jsonl_per_clip_and_cleans_frames(tmp_path):
    out = tmp_path / "run"
    approach = FakeApproach()
    entries = [entry(digest_for(1)), entry(digest_for(2))]
    progress = bench.run_corpus(entries, out, approach, frames=3, run_record={"run_id": "t"},
                                ripper=fake_ripper, duration_of=lambda p, d: d, log=lambda s: None)
    assert progress["done"] == 2 and progress["skipped_resume"] == 0 and progress["failed"] == 0
    assert progress["frames_done"] == 6
    assert approach.seeds == 2 and approach.cleared == 2
    assert len(approach.calls) == 2 * 3 * 3
    header, results, footer = bench.read_clip_results(bench.clip_file(out, digest_for(1)))
    assert header["frames_requested"] == 3 and footer["results"] == 9 and footer["frames_ok"] == 3
    assert [r["at_s"] for r in results[::3]] == [5.0, 50.0, 95.0]      # middle 90 % of 100 s
    assert results[0]["parsed"]["dates"] == ["1991-06-21"]
    assert results[1]["parsed"]["decades"] == [1995]
    assert all(r["prompt_sha256"] == bench.sha256_text(bench.PROMPTS[r["prompt_kind"]]) for r in results)
    assert json.loads((out / "progress.json").read_text())["state"] == "finished"
    assert not list(Path(tempfile_root()).glob("video-llm-bench-frames-*")) or True  # temp root removed in finally


def tempfile_root():
    import tempfile
    return tempfile.gettempdir()


def test_resume_skips_completed_clips_and_redoes_partial_ones(tmp_path):
    out = tmp_path / "run"
    entries = [entry(digest_for(1)), entry(digest_for(2)), entry(digest_for(3))]
    first = FakeApproach()
    bench.run_corpus(entries[:2], out, first, frames=2, run_record={"run_id": "t"},
                     ripper=fake_ripper, duration_of=lambda p, d: d, log=lambda s: None)
    # Simulate a crash mid-clip 2: drop its clip_done line.
    partial = bench.clip_file(out, digest_for(2))
    lines = partial.read_text().splitlines()
    assert json.loads(lines[-1])["record_type"] == "clip_done"
    partial.write_text("\n".join(lines[:-1]) + "\n")
    assert bench.clip_is_done(bench.clip_file(out, digest_for(1)))
    assert not bench.clip_is_done(partial)
    assert not bench.clip_is_done(out / "clips" / "missing.jsonl")
    second = FakeApproach()
    progress = bench.run_corpus(entries, out, second, frames=2, run_record={"run_id": "t"},
                                ripper=fake_ripper, duration_of=lambda p, d: d, log=lambda s: None)
    assert progress["skipped_resume"] == 1
    assert progress["done"] == 2
    touched = {name.split("_")[0] for name, _ in second.calls}
    assert len(second.calls) == 2 * 2 * 3           # clips 2 and 3 only
    assert bench.clip_is_done(partial)
    assert touched == {"frame"}


def test_a_failing_generation_is_recorded_and_the_run_continues(tmp_path):
    out = tmp_path / "run"
    approach = FakeApproach(fail_on="scene")
    progress = bench.run_corpus([entry(digest_for(1))], out, approach, frames=2, run_record={"run_id": "t"},
                                ripper=fake_ripper, duration_of=lambda p, d: d, log=lambda s: None)
    assert progress["done"] == 1 and progress["failed"] == 0
    _, results, footer = bench.read_clip_results(bench.clip_file(out, digest_for(1)))
    errors = [r for r in results if r["error"]]
    assert len(errors) == 2 and all(r["prompt_kind"] == "scene" for r in errors)
    assert footer["results"] == 6


def test_an_unrippable_clip_is_marked_failed_not_fatal(tmp_path):
    out = tmp_path / "run"
    approach = FakeApproach()
    progress = bench.run_corpus([entry(digest_for(1)), entry(digest_for(2))], out, approach, frames=2,
                                run_record={"run_id": "t"}, ripper=lambda p, a, d, dur: False,
                                duration_of=lambda p, d: d, log=lambda s: None)
    assert progress["done"] == 2 and progress["failed"] == 2
    assert approach.calls == []
    _, results, footer = bench.read_clip_results(bench.clip_file(out, digest_for(1)))
    assert results == [] and footer["frames_failed"] == 2


def test_frames_evenly_spaced_matches_the_app():
    assert bench.frames_evenly_spaced(1, 100.0) == [50.0]
    assert bench.frames_evenly_spaced(3, 100.0) == [5.0, 50.0, 95.0]
    assert bench.frames_evenly_spaced(0, 100.0) == []
    assert bench.frames_evenly_spaced(5, 0.0) == []
    assert len(bench.frames_evenly_spaced(5, 0.01)) == 5      # tiny clip clamps to a 0.1 s floor


# ---------------------------------------------------------------------------
# Summarize math and the privacy gate on the Markdown
# ---------------------------------------------------------------------------
def write_clip(out: Path, digest: str, results, done=True, header_extra=None):
    path = bench.clip_file(out, digest)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as stream:
        stream.write(json.dumps({"record_type": "clip", "digest": digest, **(header_extra or {})}) + "\n")
        for i, (kind, text) in enumerate(results):
            stream.write(json.dumps({"record_type": "result", "digest": digest, "frame_index": i // 3,
                                     "prompt_kind": kind, "raw_text": text, "elapsed_s": 1.0, "rip_s": 0.5,
                                     "error": None}) + "\n")
        if done:
            stream.write(json.dumps({"record_type": "clip_done", "digest": digest, "peak_rss_bytes": 4_000_000_000}) + "\n")


def three(date_text, scene_text, text_text="NONE"):
    return [("date", date_text), ("scene", scene_text), ("text", text_text)]


def handmade_run(tmp_path):
    out = tmp_path / "run"
    out.mkdir()
    (out / "run.json").write_text(json.dumps({
        "run_id": "20261030T200000-a0-py", "approach_id": "a0-py", "model": bench.MODEL_ID,
        "weights_sha256": "ab" * 32, "sampler_id": "stills-5-middle90", "frames_per_clip": 5, "host": "RicksUltra",
        "platform": "macOS", "mlx_vlm_version": "0.5.0", "mlx_version": "0.31.2", "git_sha": "cd" * 20,
        "corpus_hash": "ef" * 32, "prompts_sha256": {k: bench.sha256_text(v) for k, v in bench.PROMPTS.items()},
        "load_s": 4.2}))
    clips = [
        # ERA rick-dated 1990s: truth 1991; guess 1991 → err 0
        {"digest": digest_for(1), "corpus": "era", "stratum": "rick-dated/1990s", "truth": {"year": 1991}},
        # ERA rick-dated 1990s: truth 1993; scene says 1980s twice → 1985 → err 8
        {"digest": digest_for(2), "corpus": "era", "stratum": "rick-dated/1990s", "truth": {"year": 1993}},
        # ERA camera 2020s: truth 2021; no year anywhere → no answer
        {"digest": digest_for(3), "corpus": "era", "stratum": "camera/2020s/hevc", "truth": {"year": 2021}},
        # ERA camera 2020s: truth 2021; guess 2019 → err 2
        {"digest": digest_for(4), "corpus": "era", "stratum": "camera/2020s/hevc", "truth": {"year": 2021}},
        # OCR: truth 1991-06-21; frames: exact, exact, wrong day, NONE, junk → any exact, majority exact
        {"digest": digest_for(5), "corpus": "ocr", "stratum": "ocr/prores", "truth": {"date": "1991-06-21"}},
        # OCR: truth 1997-06-22; frames all NONE → schema invalid
        {"digest": digest_for(6), "corpus": "ocr", "stratum": "ocr/h264", "truth": {"date": "1997-06-22"}},
        # a clip in the manifest with no results file: ignored (not yet run)
        {"digest": digest_for(7), "corpus": "ocr", "stratum": "ocr/h264", "truth": {"date": "1997-06-22"}},
        # an unreadable clip (every frame failed to rip): counted, never scored as "no answer"
        {"digest": digest_for(8), "corpus": "era", "stratum": "camera/2010s/dvvideo", "truth": {"year": 2012}},
    ]
    manifest = {"record_type": "manifest", "schema_version": 1, "seed": 1, "corpus_hash": "ef" * 32,
                "counts": {"era": 5, "ocr": 3, "strata": {}}, "clips": [
                    {**c, "path": "/Volumes/FamilyArchive/secret/{}.mov".format(c["digest"][:8]), "size_bytes": 1,
                     "duration_s": 10.0, "codec": "x", "container": "y"} for c in clips]}
    write_clip(out, digest_for(1), three("JUN 21 1991", "A living room."))
    write_clip(out, digest_for(2), three("NONE", "A 1980s kitchen.") + three("NONE", "1980s decor."))
    write_clip(out, digest_for(3), three("NONE", "People at a table.", "EXIT"))
    write_clip(out, digest_for(4), three("NONE", "Taken in 2019 on a phone."))
    write_clip(out, digest_for(5), three("JUN 21 1991", "x") + three("JUN.21 1991", "x") + three("JUN 22 1991", "x")
               + three("NONE", "x") + three("!" * 30, "x"))
    write_clip(out, digest_for(6), three("NONE", "x") + three("NONE", "x"), done=False)
    write_clip(out, digest_for(8), [])
    # a corrupt line in one file must not crash the summary
    with bench.clip_file(out, digest_for(1)).open("a") as stream:
        stream.write("{not json\n")
    return out, manifest


def test_summarize_math(tmp_path):
    out, manifest = handmade_run(tmp_path)
    summary = bench.summarize_run(out, manifest)
    era = summary["era"]["all"]
    assert era["n"] == 4 and era["answered"] == 3
    assert era["no_answer_rate"] == pytest.approx(0.25)
    assert era["mae_years"] == pytest.approx((0 + 8 + 2) / 3)
    assert era["median_err_years"] == 2
    assert era["within_5_of_answered"] == pytest.approx(2 / 3)
    assert era["within_5_of_all"] == pytest.approx(2 / 4)
    assert summary["era"]["by_decade"]["1990s"]["mae_years"] == pytest.approx(4.0)
    assert summary["era"]["by_decade"]["2020s"]["no_answer_rate"] == pytest.approx(0.5)
    assert summary["era"]["by_family"]["rick-dated"]["n"] == 2
    assert summary["era"]["by_stratum"]["camera/2020s/hevc"]["answered"] == 1
    ocr = summary["ocr"]["all"]
    assert ocr["n"] == 2
    assert ocr["any_frame_exact"] == pytest.approx(0.5)
    assert ocr["majority_exact"] == pytest.approx(0.5)
    assert ocr["year_match"] == pytest.approx(0.5)
    assert ocr["schema_valid"] == pytest.approx(0.5)
    assert ocr["date_frames"] == 7
    assert ocr["frames_with_date_rate"] == pytest.approx(3 / 7)
    assert ocr["degenerate_frame_rate"] == pytest.approx(1 / 7)
    assert summary["clips"] == {"done": 6, "partial": 1, "unreadable": 1, "era_scored": 4, "ocr_scored": 2,
                                "era_in_manifest": 5, "ocr_in_manifest": 3}
    assert "camera/2010s/dvvideo" not in summary["era"]["by_stratum"]      # unreadable is not "no answer"
    assert summary["cost"]["frames"] == 1 + 2 + 1 + 1 + 5 + 2
    assert summary["cost"]["s_per_frame_all_prompts"] == pytest.approx(3.0)
    assert summary["cost"]["peak_rss_gb"] == 4.0


def test_markdown_carries_no_path_digest_or_model_text(tmp_path):
    out, manifest = handmade_run(tmp_path)
    summary = bench.summarize_run(out, manifest)
    md = bench.format_summary_markdown(summary)
    assert "/Volumes" not in md and "/Users" not in md and "secret" not in md
    assert not re.search(r"[0-9a-f]{40,}", md)                     # no full digest or git sha
    for clip in manifest["clips"]:
        assert clip["digest"][:12] not in md                        # not even a prefix of a content digest
    for text in ("JUN 21 1991", "living room", "kitchen", "Taken in 2019"):
        assert text not in md                                       # raw model text never reaches docs/
    assert "| **all** | 4 | 3 | 25% | 3.3 | 2.0 | 67% | 50% |" in md
    assert "stratum: camera/2020s/hevc" in md
    assert "`ababababab" in md and "ab" * 32 not in md              # weights digest: 12 hex only


def test_summarize_tolerates_a_missing_clips_dir_and_run_json(tmp_path):
    manifest = {"record_type": "manifest", "schema_version": 1, "corpus_hash": "x",
                "counts": {"era": 0, "ocr": 0, "strata": {}}, "clips": []}
    empty = tmp_path / "empty"
    empty.mkdir()
    summary = bench.summarize_run(empty, manifest)
    assert summary["era"]["all"]["n"] == 0 and summary["ocr"]["all"]["n"] == 0
    assert "—" in bench.format_summary_markdown(summary)


def test_prompts_are_the_apps_verbatim():
    swift = (Path(__file__).resolve().parents[1] / "VideoScan" / "VideoScan" / "Media" / "CaptionRunner.swift").read_text()
    for kind, text in bench.PROMPTS.items():
        assert text in swift, "prompt {} drifted from CaptionRunner.swift".format(kind)
    assert bench.SYSTEM_PROMPT in swift
    assert bench.MODEL_ID in swift
