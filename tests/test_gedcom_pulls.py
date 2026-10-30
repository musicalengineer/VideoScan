"""scripts/gedcom_pulls.py — which GEDCOM pulls a Mac's tree was built from and
their export dates, for the nightly Hallie row and the metrics page's GEDCOM
line. Mirrors the cases of VideoScanCore GedcomPullFactsTests (the app's
"<Surname> GEDCOM <date>" lines) so the two readers cannot drift.

Synthetic /Testsurname/ fixtures in tmp_path only; never App Support or the
archive. The public shape must never carry a surname or a file name.
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import time
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("gedcom_pulls", REPO / "scripts/gedcom_pulls.py")
gp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gp)


def pull(surname="Testsurname", head_date="26 Aug 2026", time_="05:07:30", source="getmyancestors",
         first_name=None, vs_sources=()):
    s = "0 HEAD\n1 CHAR UTF-8\n1 GEDC\n2 VERS 5.5.1\n"
    s += f"1 SOUR {source}\n2 VERS 1.2.0\n2 NAME {source}\n2 DATE 1 JAN 1999\n"
    if head_date is not None:
        s += f"1 DATE {head_date}\n"
    if time_ is not None:
        s += f"2 TIME {time_}\n"
    for name, sha in vs_sources:
        s += f"1 _VS_SOURCE {name}\n2 _VS_SHA256 {sha}\n"
    s += "0 @SUBM@ SUBM\n1 NAME Test Submitter\n2 DATE 2 FEB 1998\n"
    s += f"0 @I1@ INDI\n1 NAME {first_name or f'Pat Example /{surname}/ Jr'}\n1 SEX M\n"
    s += f"0 @I2@ INDI\n1 NAME Kid /{surname}/\n0 TRLR\n"
    return s


def write(root: Path, rel: str, text: str, mtime=None) -> Path:
    p = root / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(text.encode())
    if mtime is not None:
        os.utime(p, (mtime, mtime))
    return p


def sha(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


# ---------------------------------------------------------------- header truth

def test_getmyancestors_header_and_print(capsys):
    f = gp.header_facts_from_lines(pull().splitlines())
    print("GEDCOM header facts:", f)
    assert f["date"] == "2026-08-26" and f["time"] == "05:07:30"
    assert f["program"] == "getmyancestors" and f["surname"] == "Testsurname"
    assert gp.day_text(f["date"]) == "26 Aug 2026"


def test_ancestry_and_videoscan_merge_headers():
    a = gp.header_facts_from_lines(
        "0 HEAD\n1 SOUR Ancestry.com Family Trees\n1 DATE 6 Aug 2026\n0 @P1@ INDI\n1 NAME Lee /Ancestrytest/\n".splitlines())
    assert (a["date"], a["time"], a["surname"]) == ("2026-08-06", None, "Ancestrytest")
    v = gp.header_facts_from_lines(pull(head_date="17 SEP 2026", time_=None, source="VideoScan").splitlines())
    assert v["date"] == "2026-09-17" and gp.day_text(v["date"]) == "17 Sep 2026"


def test_missing_head_date_is_none_and_sour_date_is_not_taken():
    f = gp.header_facts_from_lines(pull(head_date=None).splitlines())
    assert f["date"] is None and f["time"] is None


@pytest.mark.parametrize("text", ["26 August 2026", "Aug 26 2026", "32 Aug 2026", "29 FEB 2025", "26 Aug 26",
                                  "ABT 2026", "26 Aug 2026 extra", "", "0 Aug 2026", "2026-08-26", "26 Xyz 2026"])
def test_malformed_dates_are_none(text):
    assert gp.header_facts_from_lines(pull(head_date=text, time_=None).splitlines())["date"] is None


def test_malformed_time_keeps_the_day():
    f = gp.header_facts_from_lines(pull(time_="25:99").splitlines())
    assert f["date"] == "2026-08-26" and f["time"] is None


def test_no_indi_or_no_slashes_is_no_label():
    assert gp.header_facts_from_lines("0 HEAD\n1 DATE 1 Jan 2026\n0 @F1@ FAM\n".splitlines())["surname"] is None
    assert gp.header_facts_from_lines(pull(first_name="Plain Name").splitlines())["surname"] is None
    no_name = "0 HEAD\n0 @I1@ INDI\n1 SEX M\n0 @I2@ INDI\n1 NAME Later /Notfirst/\n"
    assert gp.header_facts_from_lines(no_name.splitlines())["surname"] is None


def test_crlf_bom_and_cr_only_files(tmp_path):
    crlf = write(tmp_path, "a.ged", "﻿" + pull().replace("\n", "\r\n"))
    cr = write(tmp_path, "b.ged", pull().replace("\n", "\r"))
    for p in (crlf, cr):
        f = gp.header_facts(p)
        assert f["date"] == "2026-08-26" and f["surname"] == "Testsurname", p


# ---------------------------------------------------------------- resolution

def test_found_in_subdir_by_name_and_hash(tmp_path):
    p = write(tmp_path, "pulls/x.ged", pull())
    [entry] = gp.describe([("x.ged", sha(p))], [tmp_path])
    assert entry["on_disk"] and entry["label"] == "Testsurname" and entry["date"] == "2026-08-26"
    assert entry["sha"] == sha(p)[:8]


def test_wrong_hash_and_missing_file_are_not_on_disk(tmp_path):
    write(tmp_path, "x.ged", pull())
    wrong, missing = gp.describe([("x.ged", "0" * 64), ("gone.ged", "f" * 64)], [tmp_path])
    assert not wrong["on_disk"] and wrong["label"] is None
    assert not missing["on_disk"]


def test_hidden_folders_and_symlinks_are_ignored(tmp_path):
    real = write(tmp_path, ".hidden/h.ged", pull())
    (tmp_path / "h.ged").symlink_to(real)
    assert not gp.describe([("h.ged", sha(real))], [tmp_path])[0]["on_disk"]


def test_header_read_on_100mb_pull_is_fast(tmp_path):
    p = tmp_path / "huge.ged"
    with open(p, "wb") as fh:
        fh.write(pull().replace("0 TRLR\n", "").encode())
        block = b"0 @Ix@ INDI\n1 NAME Filler /Filler/\n" * 30_000
        while fh.tell() < 100_000_000:
            fh.write(block)
    t0 = time.monotonic()
    f = gp.header_facts(p)
    assert time.monotonic() - t0 < 0.1
    assert f["surname"] == "Testsurname"


# ---------------------------------------------------------------- which tree

def compiled_fixture(tmp_path: Path):
    gedcom = tmp_path / "GEDCOM"
    a = write(gedcom, "tree-20generations.ged", pull("Alphasurname", "26 Aug 2026"))
    b = write(gedcom, "pulls/beta.ged", pull("Betasurname", "28 Aug 2026"))
    merged = write(gedcom, "merged.ged", pull("Alphasurname", "17 SEP 2026", None, "VideoScan",
                                              vs_sources=[("tree-20generations.ged", sha(a)),
                                                          ("tree-3gen.ged", "f0351347" + "a" * 56),
                                                          ("beta.ged", sha(b))]))
    root = tmp_path / "compiled"
    gen = root / "gen-1"
    gen.mkdir(parents=True)
    (root / "current.json").write_text(json.dumps({"current": "gen-1"}))
    (gen / "manifest.json").write_text(json.dumps({
        "generation": "gen-1", "createdAt": "2026-10-21T21:10:45Z",
        "sources": [{"fileName": "merged.ged", "path": str(merged), "sha256": sha(merged)}],
        "logicalSources": [{"fileName": "tree-20generations.ged", "sha256": sha(a)},
                           {"fileName": "tree-3gen.ged", "sha256": "f0351347" + "a" * 56},
                           {"fileName": "beta.ged", "sha256": sha(b)}]}))
    return gedcom, root, a, b


def test_compiled_tree_live_shape(tmp_path):
    gedcom, root, a, b = compiled_fixture(tmp_path)
    r = gp.from_compiled(root)
    print("\n".join(gp.text_lines(r)))
    assert r["status"] == "ok" and r["generation"] == "gen-1"
    assert [(p["label"], p["date"], p["on_disk"]) for p in r["pulls"]] == [
        ("Alphasurname", "2026-08-26", True), (None, None, False), ("Betasurname", "2026-08-28", True)]


def test_gedcom_folder_newest_merge_lists_its_pulls(tmp_path):
    gedcom, _, a, b = compiled_fixture(tmp_path)
    os.utime(a, (1_000, 1_000))
    os.utime(b, (1_000, 1_000))
    r = gp.from_gedcom(gedcom)
    assert r["tree_file"] == "merged.ged"
    assert [p["sha"] for p in r["pulls"]] == [sha(a)[:8], "f0351347", sha(b)[:8]]
    assert [p["on_disk"] for p in r["pulls"]] == [True, False, True]


def test_gedcom_single_plain_file_describes_itself(tmp_path):
    p = write(tmp_path, "only.ged", pull("Solosurname"))
    r = gp.from_gedcom(p)
    assert [(x["label"], x["on_disk"]) for x in r["pulls"]] == [("Solosurname", True)]


def test_no_tree_is_reported_not_guessed(tmp_path):
    assert gp.from_compiled(tmp_path / "nope")["status"] == "no-tree"
    (tmp_path / "empty").mkdir()
    assert gp.from_gedcom(tmp_path / "empty")["status"] == "no-tree"


def test_public_shape_has_no_names(tmp_path):
    _, root, _, _ = compiled_fixture(tmp_path)
    pub = gp.public(gp.from_compiled(root))
    text = json.dumps(pub)
    assert "surname" not in text and ".ged" not in text and "label" not in text
    assert set(pub) == {"status", "pulls"}
    assert all(set(p) == {"date", "sha", "on_disk"} for p in pub["pulls"])


def test_cli_public_json_honours_the_compiled_root_override(tmp_path, monkeypatch, capsys):
    _, root, a, _ = compiled_fixture(tmp_path)
    assert gp.main(["--compiled-root", str(root), "--public"]) == 0
    out = json.loads(capsys.readouterr().out)
    assert out["pulls"][0] == {"date": "2026-08-26", "sha": sha(a)[:8], "on_disk": True}
