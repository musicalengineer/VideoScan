"""tools/household-roster/roster.py — no model, no media, no real catalog.

Runs with venv/bin/python3 -m pytest tests/test_household_roster.py.  Every test builds its own
synthetic tree (a GEDCOM string + People-tab profile.json files + a cyberbrain.json) and a tiny
sqlite with the catalog's schema subset.  The privacy test proves the Markdown that goes under
docs/ carries none of the synthetic names, digests or paths.

Dimensions: logic (dates, ages, bands, candidates, prior, tag resolution, truth set), scale
(100k tagged files under a time budget), isolation (poisoned profiles / unparseable dates /
blank tags do not crash and are counted), truth (the counts come from the catalog rows).
Media matrix and sensor do not apply (no media is read; Python tool, no sensor lane).
"""
from __future__ import annotations

import datetime as dt
import importlib.util
import json
import sqlite3
import sys
import time
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "tools" / "household-roster" / "roster.py"
SPEC = importlib.util.spec_from_file_location("household_roster", SCRIPT)
assert SPEC and SPEC.loader
roster = importlib.util.module_from_spec(SPEC)
sys.modules["household_roster"] = roster   # dataclasses need the module registered
SPEC.loader.exec_module(roster)

D = dt.date
PD = roster.PartialDate

# --- synthetic family (names chosen to never collide with English words in the report) ---
NAMES = ["Zebulonx", "Quillaria", "Ottokar", "Philippa", "Barnabyq", "Wendeline", "Thaddeusz",
         "Ignatiusz", "Leopoldy", "Hortensia", "Cuthbertq", "Grimbald", "Zebby"]

GEDCOM = """0 HEAD
0 @I1@ INDI
1 NAME Zebulonx /Testfam/
1 SEX M
1 BIRT
2 DATE 4 Mar 1959
1 FAMC @F2@
1 FAMS @F1@
0 @I2@ INDI
1 NAME Quillaria /Otherfam/
1 SEX F
1 BIRT
2 DATE 4 Aug 1959
1 FAMC @F3@
1 FAMS @F1@
0 @I3@ INDI
1 NAME Ottokar /Testfam/
1 SEX M
1 BIRT
2 DATE 21 Feb 1929
1 RESI
2 DATE 1940
1 DEAT
2 DATE 25 Jun 2008
1 FAMS @F2@
0 @I4@ INDI
1 NAME Philippa /Elderfam/
1 SEX F
1 BIRT
2 DATE 31 Aug 1930
1 DEAT
2 DATE ABT 2023
1 FAMS @F2@
0 @I5@ INDI
1 NAME Barnabyq /Otherfam/
1 SEX M
1 BIRT
2 DATE june 1928
1 FAMS @F3@
0 @I6@ INDI
1 NAME Wendeline /Ma/
1 SEX F
1 BIRT
2 DATE jan 16 1933
1 FAMS @F3@
0 @F1@ FAM
1 HUSB @I1@
1 WIFE @I2@
1 MARR
2 DATE 14 Feb 1981
0 @F2@ FAM
1 HUSB @I3@
1 WIFE @I4@
1 CHIL @I1@
0 @F3@ FAM
1 HUSB @I5@
1 WIFE @I6@
1 CHIL @I2@
0 TRLR
"""


def secs(day: dt.date) -> float:
    """People-tab encoding: seconds since 2001-01-01 UTC, at 17:00 UTC (noon Eastern)."""
    return (dt.datetime(day.year, day.month, day.day, 17, tzinfo=dt.timezone.utc) - roster.APPLE_EPOCH).total_seconds()


def profile(uid, name, sex, birth, aliases=(), kin=(), death=None, hair=None, folder=None):
    p = {"uuid": uid, "name": name, "sex": sex, "aliases": list(aliases), "legacyFolderName": folder or name.lower(),
         "kinships": [{"relation": r, "relativeTo": {"profile": {"id": t}}} for r, t in kin]}
    if birth is not None:
        p["birthdate"] = secs(birth)
    if death is not None:
        p["deathdate"] = secs(death)
    if hair:
        p["hairColor"] = hair
    return p


def profiles():
    return [
        profile("P-OWN", "Zebulonx", "male", D(1959, 3, 4), ["Zebby"], hair="brown",
                kin=[("child", "P-FA"), ("child", "P-MO"), ("parent", "P-C1"), ("parent", "P-C2"),
                     ("parent", "P-C3"), ("parent", "P-C4"), ("sibling", "P-SIB")]),
        profile("P-SP", "Quillaria", "female", D(1959, 8, 4), kin=[("spouse", "P-OWN")], hair="blonde"),
        profile("P-FA", "Ottokar", "male", D(1929, 2, 21), ["Grimbald"], death=D(2008, 6, 25)),
        profile("P-MO", "Philippa", "female", D(1930, 8, 31), death=D(2023, 3, 3)),
        profile("P-C1", "Thaddeusz", "male", D(1982, 2, 1), hair="brown"),
        profile("P-C2", "Ignatiusz", "male", D(1983, 11, 20), hair="blonde"),
        profile("P-C3", "Leopoldy", "male", D(1994, 6, 3), hair="brown"),
        profile("P-C4", "Cuthbertq", "male", D(1996, 4, 22), hair="brown"),
        profile("P-SIB", "Hortensia", "female", D(1961, 11, 30)),
        profile("P-OFF", "Wendelinea", "female", D(2018, 4, 9)),   # granddaughter: off-roster
    ]


@pytest.fixture()
def household():
    indis, fams = roster.parse_gedcom(GEDCOM)
    h, rep = roster.build_household(indis, fams, profiles(), "@I1@")
    return h, rep


# ------------------------------------------------------------------------------- dates & ages

def test_gedcom_dates_in_the_wild():
    assert roster.parse_gedcom_date("4 Mar 1959") == PD(1959, 3, 4)
    assert roster.parse_gedcom_date("june 1928") == PD(1928, 6)
    assert roster.parse_gedcom_date("jan 16 1933") == PD(1933, 1, 16)
    assert roster.parse_gedcom_date("ABT 1930") == PD(1930)
    assert roster.parse_gedcom_date("BET 1930 AND 1935") == PD(1930)
    assert roster.parse_gedcom_date("31 Feb 1950") == PD(1950, 2)      # impossible day dropped
    assert roster.parse_gedcom_date("unknown") is None
    assert PD(1990).as_date() == D(1990, 7, 1) and PD(1984, 11).as_date() == D(1984, 11, 15)


def test_user_date_and_apple_reference_dates():
    assert roster.parse_user_date("1990") == PD(1990)
    assert roster.parse_user_date("2000-05") == PD(2000, 5)
    assert roster.parse_user_date("2000-05-06") == PD(2000, 5, 6)
    assert roster.parse_user_date("") is None
    assert roster.apple_reference_to_date(0) == D(2001, 1, 1)
    assert roster.apple_reference_to_date(secs(D(1959, 3, 4))) == D(1959, 3, 4)


def test_age_at_the_birthday_boundary():
    b = D(1959, 3, 4)
    assert roster.age_years(b, D(1969, 3, 3)) == 9
    assert roster.age_years(b, D(1969, 3, 4)) == 10      # the birthday counts on the day
    assert roster.age_years(b, D(1959, 3, 4)) == 0


def test_a_leap_day_birthday_counts_on_the_first_of_march():
    b = D(2000, 2, 29)
    assert roster.age_years(b, D(2001, 2, 28)) == 0
    assert roster.age_years(b, D(2001, 3, 1)) == 1
    assert roster.age_years(b, D(2004, 2, 29)) == 4


@pytest.mark.parametrize("age,band", [(0, "0–2"), (2, "0–2"), (3, "3–5"), (5, "3–5"), (6, "6–12"),
                                      (12, "6–12"), (13, "13–19"), (19, "13–19"), (20, "20–29"),
                                      (39, "30–39"), (49, "40–49"), (50, "50–64"), (64, "50–64"),
                                      (65, "65+"), (104, "65+")])
def test_band_edges(age, band):
    assert roster.band_of(age) == band


def test_negative_age_has_no_band():
    with pytest.raises(ValueError):
        roster.band_of(-1)


# ------------------------------------------------------------------------------- the household

def test_household_roles_from_tree_and_people_tab(household):
    h, rep = household
    roles = [m.role for m in h.members]
    assert roles == ["owner", "spouse", "child 1", "child 2", "child 3", "child 4", "owner's father",
                     "owner's mother", "spouse's father", "spouse's mother", "owner's sibling 1"]
    assert h.marriage == PD(1981, 2, 14)
    # the spouse's parents exist only in the tree; the tree's date wins over the People tab's
    assert h.member("spouse's father").birth == PD(1928, 6)
    assert h.member("owner's father").death == PD(2008, 6, 25)        # RESI DATE 1940 not taken
    assert rep.date_disagreements == ["owner's mother death"]          # tree ABT 2023 vs 3 Mar 2023
    assert rep.tree_children_listed == 0
    assert "wendelinea" in rep.off_roster_keys


def test_roster_before_a_birth_leaves_the_child_out(household):
    h, _ = household
    roles = {p.role for p in roster.roster(h, D(1983, 11, 19))}
    assert "child 1" in roles and "child 2" not in roles
    assert "child 2" in {p.role for p in roster.roster(h, D(1983, 11, 20))}


def test_roster_after_a_death_marks_not_alive_and_the_death_day_is_alive(household):
    h, _ = household
    on_day = {p.role: p for p in roster.roster(h, D(2008, 6, 25))}
    after = {p.role: p for p in roster.roster(h, D(2008, 6, 26))}
    assert on_day["owner's father"].alive
    assert not after["owner's father"].alive and not after["owner's father"].in_household
    assert [p.role for p in roster.candidates(h, D(2008, 6, 25), "M", "65+")] == ["owner's father", "spouse's father"]
    assert [p.role for p in roster.candidates(h, D(2008, 6, 26), "M", "65+")] == ["spouse's father"]


def test_household_membership_childhood_then_own_home(household):
    h, _ = household
    kid = {p.role: p.in_household for p in roster.roster(h, D(1965, 7, 1))}
    assert kid["owner"] and kid["owner's father"] and kid["owner's mother"] and kid["owner's sibling 1"]
    grown = {p.role: p.in_household for p in roster.roster(h, D(1990, 7, 1))}
    assert grown["owner"] and grown["spouse"] and grown["child 1"]
    assert not grown["owner's father"] and not grown["owner's sibling 1"]
    later = {p.role: p.in_household for p in roster.roster(h, D(2005, 7, 1))}
    assert not later["child 1"] and later["child 3"]                   # 23 has left; 11 has not


# ------------------------------------------------------------------------------- candidates & prior

def test_candidate_counting_two_boys_in_one_band(household):
    h, _ = household
    at = D(2005, 7, 1)                                 # children 3 and 4 are 11 and 9
    assert sorted(p.role for p in roster.candidates(h, at, "M", "6–12")) == ["child 3", "child 4"]
    assert [p.role for p in roster.candidates(h, at, "F", "40–49")] == ["spouse", "owner's sibling 1"]
    core = h.restricted(["core"])
    assert [p.role for p in roster.candidates(core, at, "F", "40–49")] == ["spouse"]


def test_widening_the_band_only_adds_candidates(household):
    h, _ = household
    at = D(2010, 7, 1)                                 # children are 28, 26, 16 and 14
    exact = {p.role for p in roster.candidates(h, at, "M", "20–29")}
    wide = {p.role for p in roster.candidates(h, at, "M", "20–29", widen=5)}
    assert exact == {"child 1", "child 2"} and exact < wide and "child 3" in wide and "child 4" not in wide


def test_camera_operator_prior_ranks_owner_then_spouse_then_oldest(household):
    h, _ = household
    assert [r for r, _ in roster.camera_operator_prior(h, D(1990, 7, 1), ["child 1"])] == ["owner", "spouse"]
    assert [r for r, _ in roster.camera_operator_prior(h, D(1990, 7, 1), ["owner"])] == ["spouse"]
    # in the owner's childhood the adults are his parents, oldest first; the child owner is not an operator
    assert [r for r, _ in roster.camera_operator_prior(h, D(1965, 7, 1), [])] == ["owner's father", "owner's mother"]


def test_camera_operator_prior_is_empty_when_every_adult_is_tagged(household):
    h, _ = household
    assert roster.camera_operator_prior(h, D(2002, 7, 6), ["owner", "spouse", "child 4"]) == []


def test_tag_resolution_alias_folder_ambiguity_and_off_roster(household):
    h, rep = household
    assert roster.resolve_tag(h, " zebby ", rep.off_roster_keys)[1].role == "owner"        # alias, trimmed
    assert roster.resolve_tag(h, "Grimbald", rep.off_roster_keys)[1].role == "owner's father"
    assert roster.resolve_tag(h, "Barnabyq", rep.off_roster_keys)[1].role == "spouse's father"  # tree given name
    assert roster.resolve_tag(h, "Wendelinea", rep.off_roster_keys)[0] == "off_roster"
    assert roster.resolve_tag(h, "Some Family", rep.off_roster_keys)[0] == "unresolved"
    twin = roster.Household(h.members + (roster.Member("owner's sibling 2", "M", PD(1960), None, ("zebby",)),))
    assert roster.resolve_tag(twin, "Zebby", ())[0] == "ambiguous_name"


# ------------------------------------------------------------------------------- truth set (catalog)

SCHEMA = """
CREATE TABLE files (id TEXT PRIMARY KEY, content_digest TEXT NOT NULL, video_codec TEXT NOT NULL DEFAULT '',
  embedded_created_at INTEGER, removal_state TEXT);
CREATE TABLE user_dates (digest TEXT PRIMARY KEY, value TEXT, confidence TEXT, set_at INTEGER,
  conflict INTEGER NOT NULL DEFAULT 0);
CREATE TABLE people_tags (digest TEXT NOT NULL, name TEXT NOT NULL, kind TEXT NOT NULL, confirmed_at INTEGER,
  conflict INTEGER NOT NULL DEFAULT 0, provenance TEXT, PRIMARY KEY (digest, name, kind));
"""


def ts(day: dt.date) -> int:
    return int(dt.datetime(day.year, day.month, day.day, 12, tzinfo=dt.timezone.utc).timestamp())


def digest(n: int) -> str:
    return "{:064x}".format(0xABCDEF0000 + n)


def make_catalog(path: Path) -> Path:
    c = sqlite3.connect(path)
    c.executescript(SCHEMA)
    rows = [
        # (n, tags, user date, codec, camera stamp)
        (1, ["Leopoldy", "Cuthbertq"], "2005", "h264", D(2024, 1, 1)),   # Rick's date wins over the stamp
        (2, ["Quillaria"], None, "h264", D(2011, 7, 10)),               # camera-dated
        (3, ["Quillaria"], None, "prores", D(2011, 7, 10)),             # transfer codec: not truth
        (4, ["Ottokar", "Philippa"], "1991", "", None),
        (5, ["Thaddeusz", "Ignatiusz"], "1984-11", "ffv1", None),
        (6, ["Some Family"], "1995", "", None),
        (7, ["Ottokar"], None, "dvvideo", D(2008, 7, 3)),               # a stamp after his death
        (8, [], "1999", "", None),                                       # dated, untagged
    ]
    for n, tags, user, codec, stamp in rows:
        c.execute("INSERT INTO files VALUES (?,?,?,?,NULL)", ("r{}".format(n), digest(n), codec,
                                                              ts(stamp) if stamp else None))
        if user:
            c.execute("INSERT INTO user_dates (digest, value, confidence) VALUES (?,?, 'known')", (digest(n), user))
        for t in tags:
            c.execute("INSERT INTO people_tags (digest, name, kind, confirmed_at) VALUES (?,?, 'confirmed', 1)",
                      (digest(n), t))
    c.execute("INSERT INTO people_tags (digest, name, kind, provenance) VALUES (?, 'Quillaria', 'detected', 'bound')",
              (digest(9),))
    c.commit()
    c.close()
    return path


def write_tree(tmp: Path) -> dict:
    ged = tmp / "tree.ged"
    ged.write_text(GEDCOM, encoding="utf-8")
    poi = tmp / "POI"
    for p in profiles():
        d = poi / p["uuid"]
        d.mkdir(parents=True)
        (d / "profile.json").write_text(json.dumps(p), encoding="utf-8")
    cb = tmp / "cyberbrain.json"
    cb.write_text(json.dumps({"people": [{"canonicalName": "Zebulonx Testfam", "gedcomPersonID": "@I1@"}],
                              "sources": [{"type": "firstPerson", "attribution": "Zebulonx Testfam"}]}),
                  encoding="utf-8")
    return {"gedcom": str(ged), "poi": str(poi), "cyberbrain": str(cb)}


def test_owner_comes_from_the_cyberbrain_first_person():
    cb = {"people": [{"canonicalName": "A", "gedcomPersonID": "@X@"}, {"canonicalName": "B", "gedcomPersonID": "@Y@"}],
          "sources": [{"type": "firstPerson", "attribution": "B"}, {"type": "firstPerson", "attribution": "B"},
                      {"type": "research", "attribution": "A"}]}
    assert roster.owner_xref_from_cyberbrain(cb) == "@Y@"
    assert roster.owner_xref_from_cyberbrain({"people": [], "sources": []}) is None


def test_truth_set_rules_and_counts(tmp_path):
    conn = roster.open_ro(str(make_catalog(tmp_path / "c.sqlite")))
    truth, rep = roster.load_truth(conn)
    by = {t.digest: t for t in truth}
    assert set(by) == {digest(n) for n in (1, 2, 4, 5, 6, 7)}
    assert by[digest(1)].source == "user_dates" and by[digest(1)].date == PD(2005)
    assert by[digest(2)].source == "camera" and by[digest(2)].date == PD(2011, 7, 10)
    assert rep["tagged_files"] == 7 and rep["tagged_without_trusted_date"] == 1
    assert rep["user_dated_without_tags"] == 1 and rep["machine_tagged_files"] == 1
    assert rep["camera_vs_rick"] == {"agree": 0, "disagree": 1}
    with pytest.raises(sqlite3.OperationalError):
        conn.execute("INSERT INTO user_dates (digest, value) VALUES ('x', '2000')")   # opened read-only


def test_measure_counts_ties_widening_and_the_prior(tmp_path, household):
    h, rep = household
    conn = roster.open_ro(str(make_catalog(tmp_path / "c.sqlite")))
    truth, _ = roster.load_truth(conn)
    a = roster.measure(h, truth, rep.off_roster_keys)["aggregate"]
    assert a["files"] == 6
    assert a["tag_outcomes"] == {"resolved": 7, "unresolved": 1, "tagged_after_death": 1}
    # file 1: two boys 6–12 → 2 + 2; file 5: two infants → 2 + 2; file 2: spouse alone → 1;
    # file 4: owner's father / mother vs spouse's father / mother (all 50–64 in 1991) → 2 + 2
    assert a["sizes"] == {"1": 1, "2": 6}
    assert a["ambiguous"]["child 3 + child 4 | male 6–12 | 2000s"] == 2
    # spouse 51 alone in female 50–64; widened ±5 the owner's 49-year-old sibling joins her
    assert a["by_decade"]["2010s"] == {"files": 1, "tags": 1, "unambiguous": 1, "unambiguous_widened": 0}
    assert a["camera_top"] == {"owner": 4}
    # hair: child 3 and 4 share hair (not broken); child 1 / 2 differ (broken twice)
    assert a["hair_breaks"]["broken"] == 2


# ------------------------------------------------------------------------------- privacy (markdown)

def test_markdown_contains_none_of_the_synthetic_names_digests_or_paths(tmp_path):
    paths = write_tree(tmp_path)
    cat = make_catalog(tmp_path / "c.sqlite")
    results = roster.run_measure(str(cat), paths["gedcom"], paths["poi"], paths["cyberbrain"], None)
    results = json.loads(json.dumps(results, default=str))     # same round-trip as the CLI
    text = roster.render_markdown(results)
    low = text.lower()
    for name in NAMES + ["Testfam", "Otherfam", "Elderfam", "Wendelinea", "Some Family"]:
        assert name.lower() not in low, name
    for n in range(1, 10):
        assert digest(n) not in low and digest(n)[:12] not in low
    assert str(tmp_path) not in text and "/Users/" not in text and "/Volumes/" not in text
    assert roster.privacy_violations(text, results["forbidden"]) == []
    assert "owner" in text and "child 3 + child 4" in text


def test_summarize_refuses_to_write_a_leaking_markdown(tmp_path):
    paths = write_tree(tmp_path)
    cat = make_catalog(tmp_path / "c.sqlite")
    out = tmp_path / "results.json"
    assert roster.main(["measure", "--catalog", str(cat), "--out", str(out), *sum(
        (["--" + k, v] for k, v in paths.items()), [])]) == 0
    md = tmp_path / "out.md"
    assert roster.main(["summarize", "--results", str(out), "--md", str(md), "--verdict", "fine"]) == 0
    assert md.exists()
    leak = tmp_path / "leak.md"
    assert roster.main(["summarize", "--results", str(out), "--md", str(leak), "--verdict", "Thaddeusz is easy"]) == 2
    assert not leak.exists()


# ------------------------------------------------------------------------------- isolation & scale

def test_poisoned_profiles_and_dates_do_not_crash_and_are_counted():
    indis, fams = roster.parse_gedcom(GEDCOM + "0 @I9@ INDI\n1 SEX\n1 BIRT\n2 DATE ???\ngarbage line\n")
    bad = profiles()
    bad[4] = profile("P-C1", "Thaddeusz", "", None)                  # child 1: no sex, no birth
    bad[1]["kinships"].append({"relation": "spouse", "relativeTo": {}})  # malformed kinship
    h, rep = roster.build_household(indis, fams, bad, "@I1@")
    assert "child 4" in [m.role for m in h.members]                  # undated child sorts last
    assert rep.missing_birth == ["child 4"] and rep.missing_sex == ["child 4"]
    assert all(p.role != "child 4" for p in roster.roster(h, D(2000, 1, 1)))
    truth = [roster.TruthFile("d", PD(2000), "user_dates", ["Thaddeusz", "  ", "Ottokar"])]
    a = roster.measure(h, truth, rep.off_roster_keys)["aggregate"]
    assert a["tag_outcomes"] == {"member_missing_facts": 1, "unresolved": 1, "resolved": 1}
    with pytest.raises(ValueError):
        roster.build_household(indis, fams, bad, "@NOPE@")


def test_scale_100k_tagged_files_within_budget(household):
    h, rep = household
    truth = [roster.TruthFile(digest(n), PD(1985 + n % 40, 1 + n % 12, 1 + n % 28), "user_dates",
                              ["Quillaria", "Leopoldy"] if n % 2 else ["Zebby"]) for n in range(100_000)]
    start = time.perf_counter()
    a = roster.measure(h, truth, rep.off_roster_keys)["aggregate"]
    elapsed = time.perf_counter() - start
    assert a["files"] == 100_000 and sum(a["tag_outcomes"].values()) == 150_000
    assert elapsed < 30.0, elapsed
