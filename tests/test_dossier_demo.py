"""tools/dossier-demo/dossier_demo.py — the pure parts of the three-layer demo.

Synthetic data only: no models, no media, no catalog.
  * LOGIC (layer 1): ffprobe JSON parsing; the "what it suggests" rules (DV 32 kHz = consumer camcorder,
    a ProRes creation_time is a transfer stamp, sentinel dates rejected, mtime is transfer history);
    the hard-date ranking (Rick > DV clock > camera tag; a transfer stamp is never one).
  * LOGIC (layer 2): the model answer decoder fails closed; burned-in stamp years.
  * LOGIC (layer 3): capture-setup clustering; date windows from a hard date to setup siblings (never
    across a transfer setup); era vs hard date; re-recording; event candidates.
  * PICKING: exclusions, one per digest, bucket spread, `usable` called once per candidate, seed-stable.
  * SCALE: picking and clustering 100k synthetic rows inside a time budget.
  * GUARDS: no network module imported; the catalog is never named or opened directly.
"""
from __future__ import annotations

import ast
import importlib.util
import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "tools" / "dossier-demo" / "dossier_demo.py"
_spec = importlib.util.spec_from_file_location("dossier_demo", SCRIPT)
dd = importlib.util.module_from_spec(_spec)
sys.modules["dossier_demo"] = dd
_spec.loader.exec_module(dd)

NOW = datetime(2026, 11, 5, tzinfo=timezone.utc)


def labels(rows):
    return {label: (value, why) for label, value, why in rows}


def dv_facts(**over):
    f = {"container": "dv", "codec": "dvvideo", "width": 720, "height": 480, "sar": "8:9", "dar": "4:3",
         "fps": 29.97, "avg_fps": 29.97, "field_order": "bb", "audio_codec": "pcm_s16le", "audio_rate": 32000,
         "audio_bits": 16, "audio_channels": 4, "has_video": True, "duration": 600.0, "bit_rate": 28.8e6,
         "mtime": "2008-06-28 10:00"}
    f.update(over)
    return f


def item(name, facts=None, **over):
    it = {"name": name, "facts": facts or {}, "folder": "/f/" + name, "user_date": None, "rdt": None, "model": None}
    it.update(over)
    return it


# ------------------------------------------------------------------ layer 1: parsing

def test_parse_ffprobe_sums_dv_audio_pairs_and_skips_cover_art():
    data = {"format": {"format_name": "mov,mp4,m4a", "duration": "12.5", "bit_rate": "1000",
                       "tags": {"creation_time": "2003-02-11T10:00:00.000000Z", "encoder": "Lavf58.1.100"}},
            "streams": [
                {"codec_type": "video", "codec_name": "mjpeg", "width": 300, "height": 300,
                 "disposition": {"attached_pic": 1}},
                {"codec_type": "video", "codec_name": "dvvideo", "width": 720, "height": 480,
                 "r_frame_rate": "30000/1001", "avg_frame_rate": "30000/1001", "field_order": "bb",
                 "sample_aspect_ratio": "8:9", "display_aspect_ratio": "4:3"},
                {"codec_type": "audio", "codec_name": "pcm_s16le", "sample_rate": "32000", "channels": 2,
                 "bits_per_sample": 16},
                {"codec_type": "audio", "codec_name": "pcm_s16le", "sample_rate": "32000", "channels": 2}]}
    f = dd.parse_ffprobe(json.dumps(data))
    assert f["codec"] == "dvvideo" and f["container"] == "mov"
    assert f["fps"] == pytest.approx(29.97, abs=0.001)
    assert f["audio_channels"] == 4 and f["audio_streams"] == 2 and f["audio_rate"] == 32000
    assert f["encoder"] == "Lavf58.1.100" and f["creation_time"].startswith("2003")


def test_parse_ffprobe_garbage_is_empty():
    assert dd.parse_ffprobe("not json") == {}


def test_parse_mediainfo_reads_measured_scan():
    mi = {"media": {"track": [{"@type": "General", "Recorded_Date": "1997-12-25 14:02:00"},
                              {"@type": "Video", "ScanType": "Interlaced", "ScanOrder": "BFF", "Standard": "NTSC"}]}}
    f = dd.parse_mediainfo(json.dumps(mi))
    assert f == {"mi_recorded_date": "1997-12-25 14:02:00", "mi_scan_type": "Interlaced",
                 "mi_scan_order": "BFF", "mi_standard": "NTSC"}


# ------------------------------------------------------------------ layer 1: interpretation rules

def test_dv_32khz_four_channel_reads_as_consumer_camcorder():
    rows = labels(dd.interpret(dv_facts(), NOW))
    assert "12-bit 4-channel" in rows["audio"][1] and "camcorder" in rows["audio"][1]
    assert "1995" in rows["video codec"][1]
    assert rows["scan"][0].startswith("interlaced, bottom field first")
    assert "NTSC" in rows["frame size"][1]
    assert "12-bit 4-ch" in dd.one_liner(dv_facts())


def test_prores_creation_time_is_a_transfer_stamp_not_a_capture_date():
    f = {"container": "mov", "codec": "prores", "width": 720, "height": 486, "has_video": True,
         "creation_time": "2026-07-14T12:00:00Z"}
    kind, why = dd.classify_creation_time(f, NOW)
    assert kind == "transfer" and "not when it was shot" in why
    assert "TRANSFER" in labels(dd.interpret(f, NOW))["video codec"][1]
    assert dd.hard_dates(item("p.mov", f), NOW) == []


def test_dv_creation_time_is_the_capture_stamp():
    kind, why = dd.classify_creation_time(dv_facts(creation_time="2003-02-11T10:00:00Z"), NOW)
    assert kind == "capture" and "DV clock" in why


@pytest.mark.parametrize("raw", ["1904-01-01T00:00:00Z", "1970-01-01T00:00:00Z", "2000-01-01T00:00:00Z",
                                 "1979-06-01T00:00:00Z", "2031-01-01T00:00:00Z", "garbage"])
def test_sentinel_and_impossible_dates_are_rejected(raw):
    f = {"codec": "h264", "make": "Apple", "creation_time": raw, "has_video": True}
    assert dd.sane_date(raw, NOW) is None
    assert dd.classify_creation_time(f, NOW)[0] == "rejected"
    assert dd.hard_dates(item("x", f), NOW) == []


def test_camera_native_with_device_tags_is_a_recording_date_and_without_is_weak():
    phone = {"codec": "hevc", "make": "Apple", "model": "iPhone XS", "has_video": True,
             "apple_creationdate": "2019-07-04T21:14:00-0400"}
    assert dd.classify_creation_time(phone, NOW)[0] == "camera"
    assert dd.hard_dates(item("p", phone), NOW)[0]["date"].startswith("2019-07-0")
    bare = {"codec": "h264", "has_video": True, "creation_time": "2012-05-01T00:00:00Z"}
    assert dd.classify_creation_time(bare, NOW)[0] == "weak"
    assert dd.hard_dates(item("b", bare), NOW) == []


def test_mtime_silence_and_upscaled_transfer_rows():
    f = {"container": "matroska", "codec": "ffv1", "width": 1280, "height": 720, "has_video": True,
         "mtime": "2026-07-01 09:00"}
    rows = labels(dd.interpret(f, NOW))
    assert "never the shoot" in rows["mtime"][1]
    assert "silent" in rows["audio"][1]
    assert "upscaled" in rows["frame size"][1]


def test_no_video_stream_is_said_plainly():
    rows = labels(dd.interpret({"container": "mxf", "has_video": False}, NOW))
    assert "reference movie" in rows["video"][1]
    assert dd.one_liner({"has_video": False}).startswith("no playable video")


def test_hard_date_ranking_rick_then_dv_clock_then_camera_tag():
    f = {"codec": "hevc", "make": "Apple", "has_video": True, "creation_time": "2019-07-04T12:00:00Z"}
    it = item("x", f, user_date="2019-07-05", rdt={"rdt_first": "2019-07-04 14:02:00"})
    assert [d["source"] for d in dd.hard_dates(it, NOW)] == ["Rick", "DV clock", "camera tag"]
    assert dd.best_hard(it, NOW)["source"] == "Rick"


# ------------------------------------------------------------------ layer 2 parsing

def test_model_json_decoder_accepts_fenced_json_and_normalises():
    text = ('```json\n{"scene": "Two children at a table.", "event": "Birthday", "setting": "indoor", '
            '"visibleText": "NONE", "dateOverlay": "DEC 25 1997", "yearRange": [1994, 1999], '
            '"eraReason": "CRT and wood panelling."}\n```')
    m, why = dd.parse_model_json(text)
    assert why is None and m["yearRange"] == (1994, 1999)
    assert m["event"] == "birthday" and m["visibleText"] == "" and m["dateOverlay"] == "DEC 25 1997"


@pytest.mark.parametrize("bad", ["", "no json here", '{"yearRange": [1999, 1994]}', '{"yearRange": "1990s"}',
                                 '{"yearRange": [1800, 1810]}', '{"yearRange": [true, 1990]}', "[1, 2]"])
def test_model_json_decoder_fails_closed(bad):
    m, why = dd.parse_model_json(bad)
    assert m is None and why


def test_unknown_event_word_reads_as_unknown_and_keeps_the_raw():
    m, _ = dd.parse_model_json('{"event": "picnic", "yearRange": [1990, 1995]}')
    assert m["event"] == "unknown" and m["event_raw"] == "picnic"


def test_stamp_year_needs_two_stills_or_the_only_one():
    assert dd.stamp_year(dd.ocr_years(["NONE", "DEC 25 1997", "12:02 DEC 25 1997", "NONE"])) == 1997
    assert dd.stamp_year(dd.ocr_years(["JAN 1 1991", "MAR 3 1994"])) is None
    assert dd.stamp_year(dd.ocr_years(["MAY 1 1989"])) == 1989
    assert dd.stamp_year(dd.ocr_years(["NONE", "NONE"])) is None


# ------------------------------------------------------------------ layer 3

def test_setups_cluster_across_encoder_versions_and_split_on_audio_mode():
    a = item("a", dv_facts(encoder="Lavf58.1.100"))
    b = item("b", dv_facts(encoder="Lavf61.7.100"))
    c = item("c", dv_facts(audio_rate=48000, audio_channels=2))
    clusters = dd.cluster_setups([a, b, c])
    assert [sorted(cl["members"]) for cl in clusters] == [[0, 1], [2]]
    assert "Lavf" in clusters[0]["label"] and not clusters[0]["transfer"]


def test_a_hard_date_bounds_its_setup_sibling_with_the_chain():
    items = [item("anchor.dv", dv_facts(), rdt={"rdt_first": "1997-12-25 14:02:00"}),
             item("undated.dv", dv_facts()),
             item("other.avi", {"codec": "mjpeg", "width": 640, "height": 480, "has_video": True})]
    out = dd.setup_date_windows(items, dd.cluster_setups(items), now=NOW)
    window = [w for w in out if w["member"] == 1]
    assert len(window) == 1 and window[0]["kind"] == "window" and window[0]["window"] == (1995, 1999)
    assert any("anchor.dv: DV clock 1997-12-25" in c for c in window[0]["chain"])
    assert all(w["member"] != 2 for w in out)          # a lone setup gets nothing


def test_a_hard_date_outside_its_siblings_window_is_flagged():
    items = [item("a.dv", dv_facts(), user_date="1996"), item("b.dv", dv_facts(), user_date="2004")]
    kinds = {w["member"]: w["kind"] for w in dd.setup_date_windows(items, dd.cluster_setups(items), now=NOW)}
    assert kinds == {0: "outside", 1: "outside"}
    items[1]["user_date"] = "1997"
    kinds = {w["member"]: w["kind"] for w in dd.setup_date_windows(items, dd.cluster_setups(items), now=NOW)}
    assert kinds == {0: "consistent", 1: "consistent"}


def test_a_transfer_setup_never_bounds_a_sibling():
    pr = {"container": "mov", "codec": "prores", "width": 720, "height": 486, "fps": 29.97, "has_video": True}
    items = [item("t1.mov", dict(pr), user_date="1965"), item("t2.mov", dict(pr))]
    out = dd.setup_date_windows(items, dd.cluster_setups(items), now=NOW)
    assert [w["kind"] for w in out] == ["transfer"] and out[0]["window"] is None


def test_era_vs_hard_date_verdicts():
    items = [item("in", user_date="1990", model={"yearRange": (1985, 1995)}),
             item("near", user_date="1984", model={"yearRange": (1985, 1995)}),
             item("off", user_date="1965", model={"yearRange": (1980, 1990)}),
             item("no-hard", model={"yearRange": (1980, 1990)})]
    got = {items[e["member"]]["name"]: (e["verdict"], e["gap"]) for e in dd.era_vs_hard(items, NOW)}
    assert got == {"in": ("agree", 0), "near": ("near", 1), "off": ("disagree", 15)}


def test_re_recording_from_dv_clock_and_from_ricks_date():
    film_on_dv = item("film.dv", dv_facts(), rdt={"rdt_first": "2001-03-03 10:00:00"},
                      model={"yearRange": (1960, 1970)})
    tape_on_dv = item("vhs.dv", dv_facts(), user_date="1984")
    honest = item("ok.dv", dv_facts(), rdt={"rdt_first": "1997-12-25 10:00:00"}, model={"yearRange": (1994, 1999)})
    out = dd.re_recordings([film_on_dv, tape_on_dv, honest])
    assert [r["member"] for r in out] == [0, 1]
    assert "DV clock 2001-03-03" in out[0]["witness"] and "Rick's date 1984" in out[1]["witness"]


def test_event_candidates_need_closeness_and_a_second_witness():
    bday = {"yearRange": (1995, 1999), "event": "birthday", "scene": "cake candles table kitchen"}
    a = item("a.dv", dv_facts(), rdt={"rdt_first": "1997-06-01 10:00:00"}, model=dict(bday))
    b = item("b.dv", dv_facts(), rdt={"rdt_first": "1997-06-02 11:00:00"}, model=dict(bday))
    far = item("c.dv", dv_facts(), rdt={"rdt_first": "1999-12-25 11:00:00"}, model=dict(bday))
    out = dd.event_candidates([a, b, far], NOW)
    assert [e["pair"] for e in out] == [(0, 1)]
    reasons = " ".join(out[0]["reasons"])
    assert "within 3 days" in reasons and "same capture setup" in reasons and "birthday" in reasons


def test_same_folder_counts_as_close_but_weak_event_words_do_not_count():
    every = {"yearRange": (1990, 1995), "event": "everyday", "scene": "a"}
    a = item("a", {"codec": "mjpeg", "width": 640, "height": 480}, folder="/x", model=dict(every))
    b = item("b", {"codec": "h264", "width": 1920, "height": 1080}, folder="/x", model=dict(every))
    assert dd.event_candidates([a, b], NOW) == []          # close, but no second witness
    a["model"]["event"] = b["model"]["event"] = "wedding"
    assert len(dd.event_candidates([a, b], NOW)) == 1


# ------------------------------------------------------------------ picking files

def rec(path, codec="dvvideo", container="DV (Digital Video)", ext="dv", dur=60.0, stream="Video+Audio",
        digest=None, user_date=None, removal=None, directory=None):
    return {"fullPath": path, "videoCodec": codec, "container": container, "ext": ext, "durationSeconds": dur,
            "streamTypeRaw": stream, "contentFixity": {"sha256": digest or path}, "userDate": user_date,
            "removal": removal, "directory": directory or str(Path(path).parent)}


def test_plan_excludes_short_audio_removed_and_duplicate_content():
    records = [rec("/a/short.dv", dur=2.0), rec("/a/audio.m4a", stream="Audio only"),
               rec("/a/gone.dv", removal={"state": "missing"}), rec("/a/one.dv", digest="d1"),
               rec("/b/copy.dv", digest="d1"), rec("/a/ok.mov", codec="prores", container="QuickTime / MOV", ext="mov")]
    names = [Path(r["fullPath"]).name for r in dd.plan_candidates(records, seed=1)]
    assert sorted(names) == ["ok.mov", "one.dv"]


def test_plan_puts_preferred_buckets_first_and_ricks_dated_files_first_in_a_bucket():
    records = [rec("/x/hevc.mov", codec="hevc", container="QuickTime / MOV", ext="mov"),
               rec("/x/undated.dv"), rec("/y/dated.dv", user_date="1997"),
               rec("/z/p.mov", codec="prores", container="QuickTime / MOV", ext="mov")]
    plan = dd.plan_candidates(records, seed=3)
    assert [Path(r["fullPath"]).name for r in plan] == ["dated.dv", "undated.dv", "p.mov", "hevc.mov"]


def test_plan_takes_ricks_dated_files_across_buckets_before_any_undated_file():
    records = [rec(f"/u/dv{i}.dv") for i in range(5)]
    records += [rec("/d/old.mov", codec="prores", container="QuickTime / MOV", ext="mov", user_date="1965"),
                rec("/d/kid.mp4", codec="h264", container="QuickTime / MOV", ext="mp4", user_date="2006")]
    plan = dd.plan_candidates(records, seed=8)
    assert [Path(r["fullPath"]).name for r in plan[:2]] == ["old.mov", "kid.mp4"]


@pytest.mark.parametrize("name", ["divxlogo_splash_v2.divx.part", "intro.rm", "Trailer.mov", "sample.avi"])
def test_plan_skips_software_splashes_and_partial_downloads(name):
    assert dd.plan_candidates([rec(f"/x/{name}", codec="mpeg4", container="AVI", ext="avi")], seed=1) == []


def test_plan_keeps_family_names_that_merely_contain_a_junk_word():
    assert len(dd.plan_candidates([rec("/x/introduction_to_baby.dv"), rec("/x/samples_of_cake.dv")], seed=1)) == 2


def test_pick_spreads_buckets_folders_and_decades_and_checks_each_file_once():
    records = [rec(f"/d{i}/f{i}.dv", user_date=str(1995 + i % 3)) for i in range(6)]
    records += [rec("/m/a.avi", codec="mjpeg", container="AVI (Audio Video Interleaved)", ext="avi"),
                rec("/m/b.avi", codec="mjpeg", container="AVI (Audio Video Interleaved)", ext="avi")]
    calls = []

    def usable(r):
        calls.append(r["fullPath"])
        return not r["fullPath"].endswith("f0.dv")      # one unreachable file
    chosen = dd.pick(dd.plan_candidates(records, seed=5), 3, usable)
    assert len(chosen) == 3
    assert len({r["directory"] for r in chosen}) == 3
    assert len(calls) == len(set(calls))
    assert all(not r["fullPath"].endswith("f0.dv") for r in chosen)
    assert {dd.codec_class(r["videoCodec"]) for r in chosen} >= {"dv", "mjpeg"}


def test_pick_is_reproducible_with_a_seed():
    records = [rec(f"/d{i}/f{i}.dv") for i in range(50)]
    a = [r["fullPath"] for r in dd.pick(dd.plan_candidates(records, 42), 5, lambda r: True)]
    b = [r["fullPath"] for r in dd.pick(dd.plan_candidates(records, 42), 5, lambda r: True)]
    assert a == b


# ------------------------------------------------------------------ scale

def test_scale_100k_rows_pick_and_cluster_within_budget():
    codecs = [("dvvideo", "DV (Digital Video)", "dv"), ("prores", "QuickTime / MOV", "mov"),
              ("h264", "QuickTime / MOV", "mp4"), ("mjpeg", "AVI (Audio Video Interleaved)", "avi")]
    records = [rec(f"/v{i % 500}/f{i}.x", codec=codecs[i % 4][0], container=codecs[i % 4][1], ext=codecs[i % 4][2],
                   user_date=str(1980 + i % 40) if i % 7 == 0 else None) for i in range(100_000)]
    t0 = time.monotonic()
    chosen = dd.pick(dd.plan_candidates(records, seed=9), 10, lambda r: True)
    items = [item(f"f{i}", dv_facts(audio_rate=32000 if i % 2 else 48000), user_date=str(1995 + i % 10))
             for i in range(100_000)]
    clusters = dd.cluster_setups(items)
    elapsed = time.monotonic() - t0
    assert len(chosen) == 10 and len(clusters) == 2
    assert elapsed < 15, f"{elapsed:.1f} s"


# ------------------------------------------------------------------ guards

def test_no_network_module_and_no_direct_catalog_access():
    tree = ast.parse(SCRIPT.read_text(encoding="utf-8"))
    imported = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            imported |= {a.name.split(".")[0] for a in node.names}
        elif isinstance(node, ast.ImportFrom) and node.module:
            imported.add(node.module.split(".")[0])
    assert not imported & {"socket", "urllib", "http", "requests", "httpx", "ftplib", "smtplib", "sqlite3"}
    text = SCRIPT.read_text(encoding="utf-8")
    assert "catalog.sqlite" not in text and "catalog_db.connect()" in text
    assert 'os.environ["HF_HUB_OFFLINE"] = "1"' in text


def test_pick_clustered_takes_siblings_from_each_folder_and_skips_singletons():
    cands = [
        {"directory": "/a", "n": 1}, {"directory": "/b", "n": 2}, {"directory": "/a", "n": 3},
        {"directory": "/c", "n": 4}, {"directory": "/b", "n": 5}, {"directory": "/a", "n": 6},
        {"directory": "/b", "n": 7},
    ]
    got = dd.pick_clustered(cands, 4, 2, lambda r: True)
    assert [r["n"] for r in got] == [1, 3, 2, 5]           # /a ×2, /b ×2; /c has one file, skipped
    got = dd.pick_clustered(cands, 10, 3, lambda r: r["n"] != 3)
    assert [r["n"] for r in got] == [1, 6, 2, 5, 7]         # an unusable file is passed over
